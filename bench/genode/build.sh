#!/bin/sh
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# Genode's guest's build (docs/design-bench.md, "Genode's guest"), run by `tools/erx
# build genode` as the non-root user of an offline container of the oracle's amd64
# toolchain image. Genode's tree sits at GENODE owned by root, but for its contrib/ and
# depot/, which this build writes; the tool chain and the tool packages are already
# extracted into the image's root. /tmp/inputs holds this script, the ports' archives
# under ports/<port>/ and erXos's Genode repository (repo/: the component and its run
# script). Genode's own tools are run as its documentation describes and nothing of the
# tree is read here; the outputs tools/lib/erx/genode_build.rb reads are left in /tmp/out.
# Usage: build.sh JOBS GENODE
set -eu
jobs=$1
genode=$2
build=/tmp/build
out=/tmp/out
run=$build/var/run/erx_peer_bench
make="make -C $build -j$jobs KERNEL=hw BOARD=virt_qemu_arm_v8a"

mkdir -p "$HOME" "$out"
cd "$genode"
./tool/create_builddir arm_v8a BUILD_DIR="$build"
printf 'REPOSITORIES += %s\n' "$genode/repos/libports" /tmp/inputs/repo >> "$build/etc/build.conf"

# Each pinned port: the first, offline run of the port tool fails to download but
# creates contrib/<port>-<fingerprint>.incomplete; the pinned archive is placed there
# under its name, and the second run checks it against Genode's own hash.
for archive in /tmp/inputs/ports/*; do
	port=${archive##*/}
	./tool/ports/prepare_port "$port" > /dev/null 2>&1 || true
	set -- contrib/"$port"-*.incomplete
	if [ $# -ne 1 ] || [ ! -d "$1" ]; then
		echo "build.sh: the port tool made no single directory for $port" >&2
		exit 1
	fi
	fingerprint=${1#contrib/"$port"-}
	fingerprint=${fingerprint%.incomplete}
	case $fingerprint in
	*[!0-9a-f]*) echo "build.sh: $port's fingerprint is not hexadecimal" >&2; exit 1 ;;
	esac
	if [ ${#fingerprint} -ne 40 ]; then
		echo "build.sh: $port's fingerprint is not 40 digits" >&2
		exit 1
	fi
	cp "$archive"/* "$1"/
	./tool/ports/prepare_port "$port"
done

./tool/depot/create genodelabs/bin/arm_v8a/base-hw-virt_qemu_arm_v8a genodelabs/bin/arm_v8a/init \
	genodelabs/bin/arm_v8a/libc genodelabs/bin/arm_v8a/vfs genodelabs/bin/arm_v8a/posix
$make run/erx_peer_bench

# The run tool's output directory, by name and size, for the log.
find "$run" -type f -exec ls -l {} +
cp "$run/image.elf" "$out/image.elf"
configs=$(find "$run" -type f -name config)
if [ "$(printf '%s\n' "$configs" | wc -l)" -ne 1 ] || [ -z "$configs" ]; then
	echo "build.sh: the run tool left not exactly one config" >&2
	exit 1
fi
cp "$configs" "$out/config"
genode-aarch64-gcc --version > "$out/compiler"
