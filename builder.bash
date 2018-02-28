#!/usr/bin/env bash

# This gets copied into a container image and run.  Multiple repos are
# pulled from Github and Debian x86_64 packages created from them.  The
# resulting .deb files are deposited in the "debs" volume from the
# "docker run" command.  Log files for each package build can also be
# found there.  Packages are always downloaded but may not be built
# per these variables.  "false" and "true" are the executables.

SUPPRESSAMD=false			# Mostly for debugging, 45 minutes
SUPPRESSARM=${suppressarm:-false}	# FIXME: in chroot; 2 hours

set -u

###########################################################################
# Convenience routines.

LOGFILE=

function newlog() {
	LOGFILE="$1"
	mkdir -p `dirname "$LOGFILE"`
}

function log() {
	echo -e "$*" | tee -a "$LOGFILE"
}

function die() {
	log "$*"
	echo "$*" >&2
	exit 1
}

###########################################################################
# Must be called immediately after a command or pipeline of interest.
# Warnings are done manually for now and indicate something odd that
# doesn't seem to prevent success.

declare -a ERRORS WARNINGS

function collect_errors() {
    let SUM=`sed 's/ /+/g' <<< "${PIPESTATUS[@]}"`
    [ $SUM -ne 0 ] && ERRORS+=("$SUM error(s) in a pipeline of $GITPATH")
    return $SUM
}

###########################################################################
# Check if we're running in docker or a chroot.  Counting entries in /proc
# is dodgy as it depends on NOT bind mounting /proc before the chroot,
# typically a good idea.  https://stackoverflow.com/questions/23513045
# is more robust.  Of course this depends on grep being in the target
# environment.  The container always has it, the chroot, maybe not.
# This breaks down for exec -it bash.   Okay, go back.

function inContainer() {
	TMP=`grep 2>&1`
	[[ "$TMP" =~ '.*not found$' ]] && return 1 # no grep == not container
	[ ! -d /proc ] && return 1	# again, dodgy
	[ `ls /proc | wc -l` -gt 0 ]
	return $?
}

function suppressed() {
	if inContainer; then
		REASON=AMD
		$SUPPRESSAMD
	else
		REASON=ARM
		$SUPPRESSARM
	fi
	RET=$?
	[ $RET -eq 0 ] && log "$* ($REASON) is suppressed"
	return $RET
}

###########################################################################
# Sets the configuration file for gbp.  Note that "debian/rules" is an
# executeable file under fakeroot, with a shebang line of "#!/usr/bin/make -f"

GBPOUT=/gbp-build-area/

function set_gbp_config () {
    cat <<EOF > $HOME/.gbp.conf
[DEFAULT]
cleaner = fakeroot debian/rules clean
ignore-new = True

[buildpackage]
export-dir = $GBPOUT

EOF

    # Insert a postbuild command into the middle of the gbp configuration file
    # This indicates to the arm64 chroot which repositories need to be built
    if inContainer; then	# mark repositories to be built
        echo "postbuild=touch ../\$(basename \$(pwd))-update" >> $HOME/.gbp.conf
    else
        # In chroot, mark repositories as already built
        echo "postbuild=rm ../\$(basename \$(pwd))-update" >> $HOME/.gbp.conf
    fi
    cat <<EOF >> $HOME/.gbp.conf
[git-import-orig]
dch = False
EOF
}

###########################################################################
# Should only be run in the container?
# Sets the configuration file for debuild.
# Also checks for a signing key to build packages with

function set_debuild_config() {
    # Check for signing key
    if [ -f $KEYFILE ]; then
        # Remove old keys, import new one, get the key uid
        rm -r $HOME/.gnupg
        gpg --import $KEYFILE
        GPGID=$(gpg -K | grep uid | cut -d] -f2)
        echo "DEBUILD_DPKG_BUILDPACKAGE_OPTS=\"-k'$GPGID' -b -i -j$CORES\"" > $HOME/.devscripts
    else
        echo "DEBUILD_DPKG_BUILDPACKAGE_OPTS=\"-us -uc -b -i -j$CORES\"" > $HOME/.devscripts
    fi
}

###########################################################################
# If there is a branch named "debian", use that;
# Else use the first branch that contains a folder labeled debian;
# Else die.
# Finally, check for prerequisite build packages, and install them as needed.
# Assumes LOGFILE is set.

function get_build_prerequisites() {
    log get_build_prerequisites $GITPATH
    cd "$GITPATH"

    # gbp needs to see relevant branches as local to work (ie, remote/upstream)
    # may exist, but until it gets checked out, gbp doesn't see it).  This
    # may be a shortcoming in my understanding of gbp.  The loop below
    # doesn't always traverse the "git checkout" so force it here.  Some
    # repos have overrides of the default path, so just give it a best effort.

    for B in upstream master; do git checkout $B >/dev/null 2>&1; done

    # Back to finding "debian" directory; give preference to a "debian" branch.
    RBRANCHES=`git branch -r | grep -v HEAD | cut -d'/' -f2`
    if [[ "$RBRANCHES" =~ "debian" ]]; then
        git checkout debian -- &>/dev/null
        [ -d "debian" ] || die "'debian' branch has no 'debian' directory"
	BRANCH=debian
    else
        for BRANCH in $RBRANCHES; do
	    log "Looking for 'debian' dir in branch $BRANCH"
            git checkout $BRANCH -- &>/dev/null
            [ -d "debian" ] && break
	    BRANCH=	# sentinel for exhausting the loop
        done
    fi
    if [ ! "$BRANCH" ]; then
	MSG="No 'debian' directory in any branch of $GITPATH."
	log $MSG
	WARNINGS+=("$MSG")	# not fatal, ie, kernel doesn't care
	return
    fi
    log "Found 'debian' directory in branch $BRANCH"
    if [ -e debian/rules ]; then
    	dpkg-checkbuilddeps &>/dev/null || (echo "y" | mk-build-deps -i -r)
	collect_errors
    else
    	MSG="$GITPATH branch $BRANCH is missing 'debian/rules'"
	log $MSG
	ERRORS+=("$MSG")
    fi
}

###########################################################################
# Builds a new debian/rules file for nvml

function fix_nvml_rules() {
    read -r -d '' rule << "EOF"
#!/usr/bin/make -f
%:
\tdh \$@

override_dh_auto_install:
\tdh_auto_install -- prefix=/usr

override_dh_install:
\tmkdir -p debian/tmp/usr/share/nvml/
\tcp utils/nvml.magic debian/tmp/usr/share/nvml/
\t-mv -f debian/tmp/usr/lib64 debian/tmp/usr/lib
\tdh_install

override_dh_auto_test:
\techo "We do not test this code yet."

override_dh_clean:
\tfind src/ -name 'config.status' -delete
\tfind src/ -name 'config.log' -delete
\tdh_clean
EOF

    echo -e "$rule" > /tmp/rules
    chmod +x /tmp/rules
}

###########################################################################
# Call with a github repository URL, example:
# get_update_path tm-librarian.git
# will be prepended with GHDEFAULT, or supply a "full git path"
# get_update_path https://github.com/SomeOtherOrg/SomeOtherRepo.git
# Sets globals:
# $GITPATH	absolute path to code, will be working dir on success

readonly GHDEFAULT=https://github.com/FabricAttachedMemory

GITPATH="Main program"	# Set scope

function get_update_path() {
    REPO=$1
    BN=`basename "$REPO"`
    newlog $LOGDIR/$BN.log
    RUN_UPDATE=
    echo '-----------------------------------------------------------------'
    log "get_update_path $REPO at `date`"

    BNPREFIX=`basename "$BN" .git`	# strip .git off the end
    [ "$BN" == "$BNPREFIX" ] && \
    	log "$REPO is not a git reference" && return 1
    GITPATH="$BUILD/$BNPREFIX"
    [ "$BN" == "$REPO" ] && REPO="${GHDEFAULT}/${REPO}"

    # Only do git work in the container.  Bind links will expose it to chroot.
    if inContainer; then
        if [ ! -d "$GITPATH"  ]; then	# First time
	    cd $BUILD
	    log Cloning $REPO
            git clone "$REPO" || die "git clone $REPO failed"
	    [ -d "$GITPATH" ] || die "git clone $REPO worked but no $GITPATH"
	else			# Update any branches that need it.
	    cd $GITPATH
            for BRANCH in $(git branch -r | grep -v HEAD | cut -d'/' -f2); do
	        log Checking branch $BRANCH for updates
                git checkout $BRANCH -- &>/dev/null
		[ $? -ne 0 ] && log "git checkout $BRANCH failed" && return 1
                ANS=$(git pull)
		[ $? -ne 0 ] && log "git pull on $BRANCH failed" && return 1
                [[ "$ANS" =~ "Updating" ]] && RUN_UPDATE=yes # && break
            done
	fi
    else
    	# In chroot: check if container path above left a sentinel.
    	[ -f $(basename "$GITPATH-update") ] && RUN_UPDATE=yes
    fi
    get_build_prerequisites
    return $?
}

###########################################################################
# Depends on a correct $GITPATH, branch, and $LOGFILE being preselected.

function build_via_gbp() {
    suppressed "GPB" && return 0
    log "gbp start at `date`"
    GBPARGS="$*"
    cd $GITPATH
    log "$GITPATH args: $GBPARGS"
    eval "gbp buildpackage $GBPARGS" 2>&1 | tee -a $LOGFILE
    collect_errors
    log "gbp finished at `date`"
}

###########################################################################
# Assumes LOGFILE is set

function build_kernel() {
    suppressed "Kernel build" && return 0
    cd $GITPATH
    git checkout mdc/linux-4.14.y || exit 99
    /bin/pwd
    git status

    log "KERNEL BUILD @ `date`"
    if inContainer; then
        cp config.amd64-fame .config
        touch ../$(basename $(pwd))-update
    else
        cp config.arm64-mft .config
    	# Already set in amd, need it for arm January 2018
    	scripts/config --set-str LOCALVERSION "-l4fame"
        rm ../$(basename $(pwd))-update
    fi

    # Suppress debug kernel - save a few minutes and 500M of space
    # https://superuser.com/questions/925079/compile-linux-kernel-deb-pkg-target-without-generating-dbg-package
    scripts/config --disable DEBUG_INFO &>>$LOGFILE

    # See scripts/link-vmlinux.  Reset the final numeric suffix counter,
    # the "NN" in linux-image-4.14.0-l4fame+_4.14.0-l4fame+-NN_amd64.deb.
    rm -f .version	# restarts at 1

    git add . 
    git commit -a -s -m "Removing -dirty"
    log "Now at `/bin/pwd` ready to make"
    make -j$CORES deb-pkg 2>&1 | tee -a $LOGFILE
    collect_errors

    # They end up one above $GITPATH???
    mv -f $BUILD/linux*.* $GBPOUT	# Keep them with all the others

    # Sign the linux*.changes file if applicable
    [ "$GPGID" ] && ( echo "n" | debsign -k"$GPGID" $GBPOUT/linux*.changes )

    log "kernel finished at `date`"
}

###########################################################################
# Possibly create an arm chroot, fix it up, and run this script inside  it.

function maybe_build_arm() {
    ! inContainer && return 1	# infinite recursion
    suppressed "ARM building" && return 0

    # build an arm64 chroot if none exists.  The sentinel is the existence of
    # the directory autocreated by the qemu-debootstrap command, ie, don't
    # manually create the directory first.

    log apt-get install debootstrap qemu-user-static
    apt-get install -y debootstrap qemu-user-static &>> $LOGFILE
    [ ! -d $CHROOT ] && qemu-debootstrap \
    	--arch=arm64 $RELEASE $CHROOT http://deb.debian.org/debian/

    mkdir -p $CHROOT$BUILD		# Root of the chroot
    mkdir -p $CHROOT$DEBS		# Root of the chroot

    # Bind mounts allow access from inside the chroot
    mount --bind $BUILD $CHROOT$BUILD		# ie, the git checkout area
    mkdir -p $DEBS/arm64
    mount --bind $DEBS/arm64 $CHROOT$DEBS	# ARM debs also visible

    [ -f $KEYFILE ] && cp $KEYFILE $CHROOT

    BUILDER="/$(basename $0)"	# Here in the container
    log Next, cp $BUILDER $CHROOT
    cp $BUILDER $CHROOT
    chroot $CHROOT $BUILDER \
    	'cores=$CORES' 'http_proxy=$http_proxy' 'https_proxy=$https_proxy'
    return $?
}

###########################################################################
# MAIN
# Set globals and accommodate docker runtime arguments.

readonly ARMDIR=/arm
readonly RELEASE=stretch
readonly CHROOT=$ARMDIR/$RELEASE
GPGID=

# "docker run ... -v ...". They are the same from both the container and 
# the chroot.

readonly BUILD=/build
readonly DEBS=/debs
readonly KEYFILE=/keyfile.key	# optional
readonly LOGDIR=$DEBS/logs
readonly MASTERLOG=$LOGDIR/1st.log

rm -rf $LOGDIR
mkdir -p $LOGDIR
newlog $MASTERLOG		# Generic; re-set for each package

echo '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
log "Started at `date`"
log "$*"
log "`env | sort`"

ELAPSED=`date +%s`

# "docker run ... -e cores=N" or suppressarm=false
CORES=${cores:-}
[ "$CORES" ] || CORES=$((( $(nproc) + 1) / 2))

for E in CORES SUPPRESSAMD SUPPRESSARM; do
	eval VAL=\$$E
	log "$E=$VAL"
done

# Final setup tasks

if inContainer; then	 # Create the directories used in "docker run -v"
    log In container
    git config --global user.email "example@example.com"   # for commit -s
    git config --global user.name "l4fame-build-container"
    mkdir -p $BUILD		# Root of the container
    mkdir -p $DEBS		# Root of the container
else
    log NOT in container
fi 

export DEBIAN_FRONTEND=noninteractive	# Should be in Dockerfile

apt-get update && apt-get upgrade -y
apt-get install -y git-buildpackage
apt-get install -y libssl-dev bc kmod cpio pkg-config build-essential

# Change into build directory, set the configuration files, then BUILD!
cd $BUILD
set_gbp_config
set_debuild_config

# Using image debian:latest (vs :stretch) seems to have brought along
# a more pedantic gbp that is less forgiving of branch names.
# gbp will take branches like this:
# 1. Only "master" if it has a "debian" directory
# 2. "master" without a "debian" directory if there's a branch named "debian"
#    with a "debian" directory
# 3. "master", "debian", and "upstream" and I don't know what it does
# For all other permutations start slinging options.

# Package		Branches of concern	"debian" dir	src in
# Emulation		debian,master		debian		master
# l4fame-manager	master			master		n/a
# l4fame-node		master			master		n/a
# libfam-atomic		debian,master,upstream	debian,master	All three
# nvml			debian,master,upstream	debian		All three
# tm-hello-world	debian,master		debian		debian,master
# tm-libfuse		debian,upstream		debian		debian,upstream
# tm-librarian		debian,master,upstream	debian,master	All three
# tm-manifesting	master			master		master

# This is what works, trial and error, I stopped at first working solution.
# They might not be optimal or use minimal set of --git-upstream-xxx options.

for REPO in l4fame-node l4fame-manager tm-hello-world tm-libfuse; do
    get_update_path ${REPO}.git && build_via_gbp
done

fix_nvml_rules
get_update_path nvml.git && \
    build_via_gbp "--git-prebuild='mv -f /tmp/rules debian/rules'"

for REPO in libfam-atomic tm-librarian; do 
    get_update_path ${REPO}.git && \
    build_via_gbp --git-upstream-tree=branch --git-upstream-branch=master
done

get_update_path Emulation.git && build_via_gbp --git-upstream-branch=master

# Manifesting has a bad date in debian/changelog that chokes a Perl module.
# They got more strict in "debian:lastest".  I hate Debian.  For now...
# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=795616
get_update_path tm-manifesting.git
sed -ie 's/July/Jul/' debian/changelog
build_via_gbp --git-upstream-tree=branch --git-upstream-branch=master

# The kernel has its own deb build mechanism so ignore retval on...
get_update_path linux-l4fame.git
build_kernel

#--------------------------------------------------------------------------
# That's all, folks!  Move what worked.

cp $GBPOUT/*.deb $DEBS
cp $GBPOUT/*.changes $DEBS

newlog $MASTERLOG
let ELAPSED=`date +%s`-ELAPSED
log "Finished at `date` ($ELAPSED seconds)"

# With set -u, un-altered arrays throw an XXXXX unbound error on reference.
set +u

log "\nWARNINGS:"
for (( I=0; I < ${#WARNINGS[@]}; I++ )); do log "${WARNINGS[$I]}"; done

log "\nERRORS:"
for (( I=0; I < ${#ERRORS[@]}; I++ )); do log "${ERRORS[$I]}"; done

[ ${#ERRORS[@]} -ne 0 ] && die "Error(s) occurred"

set -u

# But wait there's more!  Let all AMD stuff run from here on out.
# The next routine should get into a chroot very quickly.
SUPPRESSAMD=false
maybe_build_arm

exit 0
