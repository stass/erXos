#!/bin/sh
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# L4Re's guest's build (docs/design-bench.md, "L4Re's guest"), run by `tools/erx build
# l4re` as the non-root user of an offline container of the oracle's arm64 toolchain
# image. /tmp/inputs holds this script, Fiasco's and L4Re's defconfigs and the tool packages; the
# trees sit at the manifest's layout under /tmp, owned by root and so read-only here.
# Upstream Fiasco and L4Re are built by their own make, as L4Re's documentation
# describes, and the outputs tools/lib/erx/l4re_build.rb reads are left in /tmp/out.
# Usage: build.sh JOBS PLATFORM_TYPE IMAGE_TARGET SUFFIX: L4Re's platform, its image target and
# the image's file suffix, which L4ReBuild::TARGETS gives for each board.
set -eu
jobs=$1
platform=$2
image=$3
suffix=$4
tools=/tmp/tools
build=/tmp/build
out=/tmp/out

# The packages are unpacked, never installed: the user cannot write the image's own
# directories, and nothing runs as root.
mkdir -p "$tools" "$build" "$out"
for package in /tmp/inputs/packages/*.deb; do
	dpkg-deb -x "$package" "$tools"
done
PATH=$tools/usr/bin:/usr/local/bin:/usr/bin:/bin
BISON_PKGDATADIR=$tools/usr/share/bison
# gawk, which L4Re's build requires by name, needs libsigsegv from its packages.
LD_LIBRARY_PATH=$tools/usr/lib/aarch64-linux-gnu
export PATH BISON_PKGDATADIR LD_LIBRARY_PATH

make -C /tmp/fiasco B="$build/fiasco" DEFCONFIG=/tmp/inputs/kernel.defconfig
make -C "$build/fiasco" -j"$jobs"

# L4Re's configuration for the target, which L4ReBuild copied into the inputs.
make -C /tmp/l4 B="$build/l4" DEFCONFIG=/tmp/inputs/l4re.defconfig
make -C "$build/l4" -j"$jobs"
make -C "$build/l4" "$image" E=ipcbench PLATFORM_TYPE="$platform" \
	MODULE_SEARCH_PATH="$build/fiasco:/tmp/l4/pkg/ipcbench/conf" \
	MODULES_LIST=/tmp/l4/pkg/ipcbench/conf/modules.list

cp "$build/l4/images/bootstrap_ipcbench.$suffix" "$out/bootstrap.$suffix"
cp "$build/fiasco/globalconfig.out" "$out/globalconfig.out"
cp "$build/l4/.kconfig" "$out/l4re.kconfig"
gcc --version > "$out/compiler"
