#!/bin/bash
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# The F2FS oracle guest's batch (docs/design-f2fs.md, "The Linux oracle guest"): bash
# runs it from the start of the batch disk, as the kernel command line's systemd.run
# asks. tools/lib/erx/f2fs_oracle_guest.rb appends the `hashed` bytes, a `tools` line, a
# `check` line per image, a `probe` line per format of Linux's own and `finish`; the bytes
# after `finish` are never read. Each image is a read-only loop device over its extent of
# the read-only batch disk, so nothing the guest runs writes it. Every result is a line
# beginning `erx-f2fs: ` on the serial console, and the host alone judges them, so no
# command's error messages may reach the console.

set -o pipefail
batch=/dev/disk/by-id/virtio-erxbatch
sbin=/run/f2fs-tools/usr/sbin
exec >/dev/ttyAMA0 2>&1
dmesg -n 1
# The newline ends whatever systemd last wrote to the console, its terminal queries among
# them, so the first line of the batch starts at a line's start.
printf '\nerx-f2fs: kernel %s\n' "$(uname -r)"

# out STEP NAME: stdin as base64, in `erx-f2fs: out NAME STEP CHUNK` lines, then
# `erx-f2fs: size NAME STEP BYTES SHA256` of the bytes, so the host refuses a step
# whose lines the console lost. A step whose bytes cannot be kept prints no size line.
out() {
	cat >/run/erx-out || exit 1
	base64 -w 3000 </run/erx-out | while IFS= read -r chunk; do
		printf 'erx-f2fs: out %s %s %s\n' "$2" "$1" "$chunk"
	done
	printf 'erx-f2fs: size %s %s %s %s\n' "$2" "$1" "$(stat -c %s /run/erx-out)" "$(sha256sum </run/erx-out | head -c 64)"
}

# status STEP NAME CODE: the step's exit status.
status() {
	printf 'erx-f2fs: exit %s %s %s\n' "$2" "$1" "$3"
}

# tools OFFSET SIZE: unpacks f2fs-tools' package from its extent of the batch disk.
tools() {
	dd if="$batch" iflag=skip_bytes,count_bytes skip="$1" count="$2" bs=1M status=none >/run/f2fs-tools.deb || exit 1
	dpkg-deb -x /run/f2fs-tools.deb /run/f2fs-tools || exit 1
	mkdir -p /mnt/f2fs /mnt/probe || exit 1
	dmesg -C
}

# record: the tree under the current directory, each name as seven NUL-terminated
# fields, the form erx_f2fs_listing:record_reader/1 reads: its path, its type and
# permission bits as find prints them (%y, %m), its link count, its inode, its size, and
# `=` and the SHA-256 of a regular file's first $hashed bytes or a symlink's target, `!`
# for content Linux does not let it read (an encrypted file without its key or a path
# past PATH_MAX among them), or nothing for any other kind. find walks by directory, so
# no path length stops it, and a failing find fails the record.
record() {
	find . -printf '%p\0%y\0%m\0%n\0%i\0%s\0' 2>/dev/null | while IFS= read -r -d '' path; do
		IFS= read -r -d '' type && IFS= read -r -d '' mode && IFS= read -r -d '' links &&
			IFS= read -r -d '' inode && IFS= read -r -d '' size || exit 1
		printf '%s\0%s\0%s\0%s\0%s\0%s\0' "$path" "$type" "$mode" "$links" "$inode" "$size"
		case $type in
		f) sum=$(head -c "$hashed" 2>/dev/null <"$path" | sha256sum) && printf '=%.64s' "$sum" || printf '!' ;;
		l) target=$(readlink -n -- "$path" 2>/dev/null && printf x) && printf '=%s' "${target%x}" || printf '!' ;;
		esac
		printf '\0'
	done
}

# examine NAME DEVICE: fsck.f2fs's full check, answering no to every question, then an
# ro,norecovery mount, the mounted tree's record and the kernel's messages, the
# unmount's among them.
examine() {
	yes n 2>/dev/null | "$sbin/fsck.f2fs" -f --dry-run "$2" 2>&1 | out fsck "$1"
	status fsck "$1" "${PIPESTATUS[1]}"
	mount -t f2fs -o ro,norecovery "$2" /mnt/f2fs 2>&1 | out mount "$1"
	mounted=${PIPESTATUS[0]}
	status mount "$1" "$mounted"
	if [ "$mounted" = 0 ]; then
		(cd /mnt/f2fs && record) | out list "$1"
		status list "$1" "${PIPESTATUS[0]}"
		umount /mnt/f2fs || exit 1
	fi
	dmesg -c | out dmesg "$1"
}

# check NAME OFFSET SIZE: examines the image at its extent of the batch disk.
check() {
	dev=$(losetup -r -f --show -o "$2" --sizelimit "$3" "$batch") || exit 1
	examine "$1" "$dev"
	losetup -d "$dev"
}

# probe NAME MIB [ARGUMENT...]: mkfs.f2fs's format, with the arguments, of a blank image
# of MIB MiB on a scratch tmpfs; the image, gzipped, then examined as erXos's are.
probe() {
	name=$1 image=/mnt/probe/$1.img
	mount -t tmpfs -o size=$(($2 + 16))M tmpfs /mnt/probe || exit 1
	truncate -s "$2M" "$image" || exit 1
	shift 2
	"$sbin/mkfs.f2fs" "$@" "$image" 2>&1 | out mkfs "$name"
	status mkfs "$name" "${PIPESTATUS[0]}"
	gzip -1 -c "$image" | out image "$name"
	dev=$(losetup -r -f --show "$image") || exit 1
	examine "$name" "$dev"
	losetup -d "$dev"
	umount /mnt/probe || exit 1
}

finish() {
	printf 'erx-f2fs: done\n'
	poweroff -f
	exit 0
}

