#!/usr/bin/env bash
apt-get update && apt-get upgrade -y;
apt-get install -y git-buildpackage;
apt-get install -y libssl-dev bc kmod cpio pkg-config build-essential;
# Check if we're running in docker or a chroot
if [[ $(ls /proc | wc -l) -gt 0 ]]; then
    # Only needed in the docker container
    apt-get install -y debootstrap qemu qemu-user-static;
fi


# Sets the configuration file for gbp
set_gbp_config () {
# gbp configuration file
cat <<EOF > $HOME/.gbp.conf
[DEFAULT]
cleaner = fakeroot debian/rules clean
ignore-new = True
force-create = True

[buildpackage]
export-dir = /gbp-build-area/

EOF
# Insert a postbuild command into the middle of the gbp configuration file
# This indicates to the arm64 chroot which repositories need to be built
if [[ $(ls /proc | wc -l) -gt 0 ]]; then
    # In docker, mark repositories to be built
    echo "postbuild=touch ../\$(basename \$(pwd))-update" >> $HOME/.gbp.conf;
else
    # In chroot, mark built repositories
    echo "postbuild=rm ../\$(basename \$(pwd))-update" >> $HOME/.gbp.conf;
fi
cat <<EOF >> $HOME/.gbp.conf
[git-import-orig]
dch = False
EOF
}


# Sets the configuration file for debuild
# Also checks for a signing key to build packages with
set_debuild_config () {
    # Check for signing key
    if [ -f "/keyfile.key" ]; then
        # Remove old keys, import keyfile.key, get the key uid
        rm -r $HOME/.gnupg;
        gpg --import /keyfile.key;
        GPGID=$(gpg -K | grep uid | cut -d] -f2);
        echo "DEBUILD_DPKG_BUILDPACKAGE_OPTS=\"-k'$GPGID' -i -j$CORES\"" > $HOME/.devscripts;
    else
        echo "DEBUILD_DPKG_BUILDPACKAGE_OPTS=\"-us -uc -i -j$CORES\"" > $HOME/.devscripts;
    fi
}


# Check for prerequisite build packages, and install them
# If there is a branch named "debian", we use that for installing prerequisites
# Else, use the first branch that contains a folder labeled debian
run_update () {
    if [[ "$(git branch -r | grep -v HEAD | cut -d'/' -f2)" =~ "debian" ]]; then
        git checkout debian -- &>/dev/null;
        if [ -d "debian" ]; then
            ( dpkg-checkbuilddeps &>/dev/null ) || \
            ( echo "y" | mk-build-deps -i -r );
        fi
    else
        for branch in $(git branch -r | grep -v HEAD | cut -d'/' -f2); do
            git checkout $branch -- &>/dev/null;
            if [ -d "debian" ]; then
                ( dpkg-checkbuilddeps &>/dev/null ) || \
                ( echo "y" | mk-build-deps -i -r );
                break;
            fi
        done
    fi
}


# Builds a new debian/rules file for nvml
fix_nvml_rules () {
read -r -d '' rule<<"EOF"
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
echo -e "$rule" > /tmp/rules;
chmod +x /tmp/rules;
}


# Sets $path to the path if a build is required or "" if no build is required
# Call with a github repository URL, example:
# get_update_path https://github.com/FabricAttachedMemory/l4fame-build-container.git
get_update_path () {
    # Get a path from the git URL
    path=$(pwd)"/"$(echo "$1" | cut -d '/' -f 5 | cut -d '.' -f 1);
    # Until proven otherwise, assume we have to build
    BUILD=false;
    # Check if we're running in docker or a chroot
    if [[ $(ls /proc | wc -l) -gt 0 ]]; then
        # Check if the repository needs to be cloned, then clone
        if [ ! -d "$path"  ]; then
            git clone "$1";
            # Ensure that each branch is available to gbp
            for branch in $(cd $path && git branch -r | grep -v HEAD | cut -d'/' -f2); do
                (cd $path && git checkout $branch -- &>/dev/null);
            done
            (cd $path && git checkout $(git branch -r | grep HEAD | cut -d'/' -f3) -- &>/dev/null);
            BUILD=true;
        else
            # Get only the branches that need to be updated
            FETCH=$(cd $path && git fetch -a 2>&1 | tail -n +2)
            if [ "$FETCH" ]; then
                BUILD=true;
                for branch in $(echo "$FETCH" | cut -d'>' -f2 | cut -d'/' -f2-); do
                    echo "Updating branch: $branch"
                    (cd $path && git checkout $branch -- && git merge) &>/dev/null;
                done
            fi
        fi
    else
        # Check if docker marked the repository as needing a rebuild
        if [ -f $(basename $path"-update") ]; then
            # Update found, build package
            BUILD=true;
        fi
    fi
}


# Set .config file for amd64 and arm64, then remove the dirty kernel build messages
set_kernel_config () {
    git config --global user.email "example@example.com";
    git config --global user.name "l4fame-build-container";
    if [[ $(ls /proc | wc -l) -gt 0 ]]; then
        cp config.amd64-fame .config;
    else
        yes '' | make oldconfig;
    fi
    git add . ;
    git commit -a -s -m "Removing -dirty";
}


# Remove build information and then copy produced packages to the external deb folder
copy_built_packages () {
    rm -f /gbp-build-area/*.build*;
    cp /gbp-build-area/* /deb;
}


# If user sets "-e cores=number_of_cores" use that many cores when compiling
if [ "$cores" ]; then
    CORES=$(( $cores ))
# Otherwise set $CORES to half the cpu cores.
else
    CORES=$((( $(nproc) + 1) / 2))
fi

# Check if we're running in docker or a chroot
if [[ $(ls /proc | wc -l) -gt 0 ]]; then
    # Build an arm64 chroot if none exists
    test -d "/arm64" || qemu-debootstrap --arch=arm64 stretch /arm64/stretch http://deb.debian.org/debian/;
    # Make the directories that gbp will download repositories to and build in
    mkdir -p /deb;
    mkdir -p /build;
    mkdir -p /deb/arm64;
    mkdir -p /arm64/stretch/deb;
    mkdir -p /arm64/stretch/build;
    # Mount /deb and /build so we can get at them from inside the chroot
    mount --bind /deb/arm64 /arm64/stretch/deb;
    mount --bind /build /arm64/stretch/build;
    # Copy signing key into the chroot if available
    [ -f "/keyfile.key" ] && cp /keyfile.key /arm64/stretch/keyfile.key;
    # Copy this script into the chroot
    cp "$0" /arm64/stretch;
fi

# Change into the build directory and set the configuration files
cd /build;
set_gbp_config;
set_debuild_config;


fix_nvml_rules;
get_update_path https://github.com/FabricAttachedMemory/nvml.git;
( $BUILD ) && ( cd $path && run_update && gbp buildpackage --git-postexport='mv -f /tmp/rules debian/rules' --git-upstream-tree=branch --git-upstream-branch=debian );

get_update_path https://github.com/FabricAttachedMemory/tm-librarian.git;
( $BUILD ) && ( cd $path && run_update && gbp buildpackage );

get_update_path https://github.com/FabricAttachedMemory/tm-manifesting.git;
( $BUILD ) && ( cd $path && run_update && gbp buildpackage --git-upstream-branch=master --git-upstream-tree=branch --git-cleaner=/bin/true);

get_update_path https://github.com/FabricAttachedMemory/l4fame-node.git;
( $BUILD ) && ( cd $path && run_update && gbp buildpackage );

get_update_path https://github.com/FabricAttachedMemory/l4fame-manager.git;
( $BUILD ) && ( cd $path && run_update && gbp buildpackage );

get_update_path https://github.com/FabricAttachedMemory/tm-hello-world.git;
( $BUILD ) && ( cd $path && run_update && gbp buildpackage --git-upstream-tree=branch --git-upstream-branch=debian);

get_update_path https://github.com/FabricAttachedMemory/tm-libfuse.git;
( $BUILD ) && ( cd $path && run_update && gbp buildpackage );

get_update_path https://github.com/FabricAttachedMemory/libfam-atomic.git;
( $BUILD ) && ( cd $path && run_update && gbp buildpackage --git-upstream-tree=branch );

get_update_path https://github.com/FabricAttachedMemory/Emulation.git;
( $BUILD ) && ( cd $path && run_update && gbp buildpackage --git-upstream-branch=master );

copy_built_packages;


# Build with config.amd64-l4fame in docker and oldconfig in chroot
get_update_path https://github.com/FabricAttachedMemory/linux-l4fame.git;
if $BUILD; then
    ( cd $path && set_kernel_config; make -j$CORES deb-pkg && \
    if [[ $(ls /proc | wc -l) -gt 0 ]]; then
        touch ../$(basename $(pwd))-update;
    else
        rm ../$(basename $(pwd))-update;
    fi );
    mv -f /build/linux*.* /gbp-build-area;
    # Sign the linux*.changes file if applicable
    [ "$GPGID" ] && ( echo "n" | debsign -k"$GPGID" /gbp-build-area/linux*.changes );
    copy_built_packages;
fi

# Change into the chroot and run this script
if [[ $(ls /proc | wc -l) -gt 0 ]]; then
    chroot /arm64/stretch "/$(basename $0)" 'cores=$CORES' 'http_proxy=$http_proxy' 'https_proxy=$https_proxy'
fi
