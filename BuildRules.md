## Instructions for Building Individual Packages

Each package referenced in builder.bash can be built individually using the following steps:

---
### Setup and Configuration 
Install `git-buildpackage`, it is required for building all packages.
```shell
apt-get install git-buildpackage
```

Add the following configuration to `~/.devscripts`.
```shell
DEBUILD_DPKG_BUILDPACKAGE_OPTS="-us -uc -i"
```

Add the following configuration to `~/.gbp.conf`.
```shell
[DEFAULT]
cleaner = fakeroot debian/rules clean
ignore-new = True
force-create = True

[buildpackage]
export-dir = /gbp-build-area/

[git-import-orig]
dch = False
```

---
### Packages
  * [nvml](#nvml)
  * [tm-librarian](#tm-librarian)
  * [tm-manifesting](#tm-manifesting)
  * [l4fame-node](#l4fame-node)
  * [l4fame-manager](#l4fame-manager)
  * [tm-hello-world](#tm-hello-world)
  * [tm-libfuse](#tm-libfuse)
  * [libfam-atomic](#libfam-atomic)
  * [fame](#fame)
  * [linux-kernel](#linux-kernel)

---
### nvml
**Packages**
```shell
libpmem_[version].deb 
libpmem-dev_[version].deb
```
**Build Requirements** 
```shell
apt-get install uuid-dev 
```
**Build Process**
1. Clone [this repository](https://github.com/FabricAttachedMemory/nvml.git).
2. Checkout `upstream`, then checkout `debian`.
3. Build with 
```shell
gbp buildpackage --git-upstream-tree=branch --git-upstream-branch=debian
```

**Note**
If the build fails with the following error,
```shell
gbp:error: 'debuild -i -I' failed: it exited with 29
```
It is because one of the sub-folders in `../build-area/` is misnamed. To fix this error, run the following to build with a new `rules` file.
```shell
read -r -d '' rule<<"EOF"
#!/usr/bin/make -f
%:
\tdh \$@

override_dh_auto_install:
\tdh_auto_install -- prefix=/usr

override_dh_install:
\tmkdir -p debian/tmp/usr/share/nvml/
\tcp utils/nvml.magic debian/tmp/usr/share/nvml/
\t-mv debian/tmp/usr/lib64 debian/tmp/usr/lib
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

gbp buildpackage --git-prebuild='mv /tmp/rules debian/rules' --git-upstream-tree=branch --git-upstream-branch=debian
```

---
### tm-librarian
**Packages**
```shell
tm-librarian_[version].deb 
python3-tm-librarian_[version].deb 
tm-lfs_[version].deb 
tm-utils_[version].deb 
tm-lmp_[version].deb
```
**Build Requirements** 
```shell
apt-get install dh-exec
```
**Build Process**
1. Clone [this repository](https://github.com/FabricAttachedMemory/tm-librarian.git).
2. Checkout `upstream`, then checkout `debian`.
3. Build with 
```shell
gbp buildpackage
```

---
### tm-manifesting
**Packages**
```shell
tm-manifesting_[version].deb
```
**Build Requirements** 
```shell
apt-get install dh-exec
```
**Build Process**
1. Clone [this repository](https://github.com/keith-packard/tm-manifesting.git).
2. Build with 
```shell
gbp buildpackage --git-upstream-branch=master --git-upstream-tree=branch --git-cleaner=/bin/true
```

---
### l4fame-node
**Packages**
```shell
l4fame-node_[version].deb
```
**Build Requirements**
```shell
# no package requirements
```
**Build Process**
1. Clone [this repository](https://github.com/FabricAttachedMemory/l4fame-node.git).
2. Build with
```shell
gbp buildpackage
```

---
### l4fame-manager
**Packages**
```shell
l4fame-manager_[version].deb
```
**Build Requirements**
```shell
# no package requirements
```
**Build Process**
1. Clone [this repository](https://github.com/FabricAttachedMemory/l4fame-manager.git).
2. Build with 
```shell
gbp buildpackage
```

---
### tm-hello-world
**Packages**
```shell
tm-hello-world_[version].deb
```
**Build Requirements**
```shell
# no package requirements
```
**Build Process**
1. Clone [this repository](https://github.com/FabricAttachedMemory/tm-hello-world.git).
2. Checkout `debian`.
3. Build with
```shell
gbp buildpackage --git-upstream-tree=branch --git-upstream-branch=debian
```

---
### tm-libfuse
**Packages**
```shell
tm-libfuse_[version].deb
```
**Build Requirements**
```shell
apt-get install libselinux-dev
```
**Build Process**
1. Clone [this repository](https://github.com/FabricAttachedMemory/tm-libfuse.git).
2. Checkout `upstream`, then checkout `debian`.
3. Build with
```shell
gbp buildpackage
```

---
### libfam-atomic
**Packages**
```shell
libfam-atomic2_[version].deb 
libfam-atomic2-dev_[version].deb 
libfam-atomic2-dbg_[version].deb 
libfam-atomic2-tests_[version].deb
```
**Build Requirements**
```shell
apt-get install pkg-config autoconf-archive asciidoc libxml2-utils xsltproc docbook-xsl docbook-xml
```
**Build Process**
1. Clone [this repository](https://github.com/FabricAttachedMemory/libfam-atomic.git).
2. Checkout `upstream`, then checkout `debian`.
3. Build with
```shell
gbp buildpackage --git-upstream-tree=branch
```

---
### fame 
**Packages**
```shell
fame_[version].deb
```
**Build Requirements**
```shell
# no package requirements
```
**Build Process**
1. Clone [this repository](https://github.com/FabricAttachedMemory/Emulation.git).
2. Checkout `debian`.
3. Build with
```shell
gbp buildpackage --git-upstream-branch=master
```

---
### linux-kernel 
**Packages**
```shell
linux-firmware-image-4.8.0-l4fame+_[version].deb
linux-headers-4.8.0-l4fame+_[version].deb 
linux-libc-dev_[version].deb 
linux-image-4.8.0-l4fame+_[version].deb 
linux-image-4.8.0-l4fame+-dbg_[version].deb
```
**Build Requirements**
```shell
apt-get install build-essential bc libssl-dev
```
**Build Process**
1. Clone [this repository](https://github.com/FabricAttachedMemory/linux-l4fame.git).
2. Build with
```shell
make deb-pkg
```

