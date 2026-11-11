/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * lfs-format SECTORS OUTPUT: the littlefs volume that installation writes
 * on a data partition of SECTORS 512-byte sectors (docs/design-storage.md,
 * "A mount never formats"), with the geometry the guest mounts it with
 * (erx_littlefs.h). The guest never formats: a mount that finds no volume
 * fails, so a medium's volume exists only because this program wrote it.
 *
 * The format writes only the volume's first blocks; every other block of a
 * fresh medium holds zeros, which is what a block device that erases
 * nothing leaves there. OUTPUT receives the volume from its start through
 * the last block the format wrote, for the medium writer to place at the
 * partition's start. The volume is mounted back before OUTPUT is written,
 * and an existing OUTPUT is refused.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "erx_littlefs.h"
#include "lfs.h"

/*
 * The blocks the format may write, held in memory; a block beyond them reads
 * as zeros and refuses a write, which would mean the format reached further
 * than the medium writer places. littlefs's format writes blocks 0 and 1.
 */
#define ERX_FORMAT_BLOCKS 8u

/* The volume's leading blocks and the highest one written, plus one. */
typedef struct erx_format_disk {
	uint8_t bytes[ERX_FORMAT_BLOCKS * ERX_LFS_BLOCK_SIZE];
	lfs_block_t written;
} erx_format_disk_t;

static int erx_format_read(const struct lfs_config *, lfs_block_t, lfs_off_t, void *, lfs_size_t);
static int erx_format_prog(const struct lfs_config *, lfs_block_t, lfs_off_t, const void *, lfs_size_t);
static int erx_format_erase(const struct lfs_config *, lfs_block_t);
static int erx_format_sync(const struct lfs_config *);
static int erx_sectors_parse(const char *, uint64_t *);
static int erx_output_write(const char *, const uint8_t *, size_t);

/* littlefs keeps block < block_count and off + size <= block_size. */
static int
erx_format_read(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
    void *buffer, lfs_size_t size)
{
	erx_format_disk_t *disk = c->context;

	if (block >= ERX_FORMAT_BLOCKS)
		memset(buffer, 0, size);
	else
		memcpy(buffer, disk->bytes + (size_t)block * ERX_LFS_BLOCK_SIZE + off, size);
	return (0);
}

static int
erx_format_prog(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
    const void *buffer, lfs_size_t size)
{
	erx_format_disk_t *disk = c->context;

	if (block >= ERX_FORMAT_BLOCKS)
		return (LFS_ERR_IO);
	memcpy(disk->bytes + (size_t)block * ERX_LFS_BLOCK_SIZE + off, buffer, size);
	if (block >= disk->written)
		disk->written = block + 1;
	return (0);
}

/* A block device erases nothing, as the guest's (erx_littlefs_nif.c). */
static int
erx_format_erase(const struct lfs_config *c, lfs_block_t block)
{
	(void)c;
	(void)block;
	return (0);
}

static int
erx_format_sync(const struct lfs_config *c)
{
	(void)c;
	return (0);
}

/* A decimal count without sign or leading zeros, no wider than 64 bits. */
static int
erx_sectors_parse(const char *text, uint64_t *value)
{
	uint64_t sum = 0;
	size_t i, length = strlen(text);

	if (length == 0 || length > 20 || (text[0] == '0' && length > 1))
		return (-1);
	for (i = 0; i < length; i++) {
		if (text[i] < '0' || text[i] > '9')
			return (-1);
		if (sum > (UINT64_MAX - (uint64_t)(text[i] - '0')) / 10)
			return (-1);
		sum = sum * 10 + (uint64_t)(text[i] - '0');
	}
	*value = sum;
	return (0);
}

/*
 * Writes bytes to a new file at path; an existing path is refused. A failure
 * removes what was written and leaves errno as the failing call set it.
 */
static int
erx_output_write(const char *path, const uint8_t *bytes, size_t length)
{
	size_t done = 0;
	ssize_t n;
	int fd, saved;

	fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
	if (fd < 0)
		return (-1);
	while (done < length) {
		n = write(fd, bytes + done, length - done);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			saved = n == 0 ? EIO : errno;
			(void)close(fd);
			(void)unlink(path);
			errno = saved;
			return (-1);
		}
		done += (size_t)n;
	}
	if (close(fd) != 0) {
		saved = errno;
		(void)unlink(path);
		errno = saved;
		return (-1);
	}
	return (0);
}

int
main(int argc, char **argv)
{
	static erx_format_disk_t disk;
	static uint8_t read_buffer[ERX_LFS_CACHE_SIZE];
	static uint8_t prog_buffer[ERX_LFS_CACHE_SIZE];
	static uint8_t lookahead_buffer[ERX_LFS_LOOKAHEAD_SIZE];
	struct lfs_config cfg;
	lfs_t lfs;
	uint64_t sectors, blocks;
	int err;

	if (argc != 3 || erx_sectors_parse(argv[1], &sectors) != 0) {
		fprintf(stderr, "usage: lfs-format SECTORS OUTPUT\n");
		return (2);
	}
	/*
	 * The guest's volume: the window's whole blocks, at most the largest
	 * volume (erx_lfs.erl, window/1).
	 */
	blocks = sectors / (ERX_LFS_BLOCK_SIZE / ERX_LFS_SECTOR_SIZE);
	if (blocks > ERX_LFS_MAX_BLOCKS)
		blocks = ERX_LFS_MAX_BLOCKS;
	if (blocks < ERX_LFS_MIN_BLOCKS) {
		fprintf(stderr, "lfs-format: %llu sectors hold fewer than %u blocks\n",
		    (unsigned long long)sectors, ERX_LFS_MIN_BLOCKS);
		return (1);
	}
	erx_lfs_config(&cfg, (lfs_size_t)blocks);
	cfg.context = &disk;
	cfg.read = erx_format_read;
	cfg.prog = erx_format_prog;
	cfg.erase = erx_format_erase;
	cfg.sync = erx_format_sync;
	cfg.read_buffer = read_buffer;
	cfg.prog_buffer = prog_buffer;
	cfg.lookahead_buffer = lookahead_buffer;
	err = lfs_format(&lfs, &cfg);
	if (err == 0) {
		err = lfs_mount(&lfs, &cfg);
		if (err == 0)
			err = lfs_unmount(&lfs);
	}
	if (err != 0 || disk.written == 0) {
		fprintf(stderr, "lfs-format: the format failed: %d\n", err);
		return (1);
	}
	if (erx_output_write(argv[2], disk.bytes,
	    (size_t)disk.written * ERX_LFS_BLOCK_SIZE) != 0) {
		fprintf(stderr, "lfs-format: cannot write %s: %s\n", argv[2], strerror(errno));
		return (1);
	}
	return (0);
}
