/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * littlefs images, mounted and read as the system domain's /data does
 * (otp/erts/emulator/nifs/erxos/erx_littlefs.h's geometry), over a RAM block
 * device. The first byte picks the image:
 *
 *   0: the rest of the input is the image, up to eight 4 KiB blocks, the
 *      remainder zero;
 *   1: a volume formatted here, holding a directory and two files, then
 *      damaged by the rest of the input read as patches of three bytes, a
 *      big-endian offset into the image and a byte that replaces the one
 *      there.
 *
 * Either image is mounted, every directory is listed and every file read, to
 * a bounded depth and count, without recursion, and a file is written and
 * synced, so the allocator and the commit path meet the damage too.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>

#include "lfs.h"

#include "erx_littlefs.h"

#define BLOCKS 8u
#define IMAGE_SIZE (BLOCKS * ERX_LFS_BLOCK_SIZE)
#define MAX_DEPTH 8
#define MAX_ENTRIES 256

static uint8_t image[IMAGE_SIZE];
static uint8_t read_buf[ERX_LFS_CACHE_SIZE], prog_buf[ERX_LFS_CACHE_SIZE];
static uint8_t lookahead_buf[ERX_LFS_LOOKAHEAD_SIZE];
static uint8_t file_buf[ERX_LFS_CACHE_SIZE];
static uint8_t data[4096];

static int
ram_read(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
    void *buffer, lfs_size_t size)
{
	if (block >= c->block_count || off > c->block_size ||
	    size > c->block_size - off)
		return (LFS_ERR_IO);
	bcopy(image + (size_t)block * c->block_size + off, buffer, size);
	return (0);
}

static int
ram_prog(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
    const void *buffer, lfs_size_t size)
{
	if (block >= c->block_count || off > c->block_size ||
	    size > c->block_size - off)
		return (LFS_ERR_IO);
	bcopy(buffer, image + (size_t)block * c->block_size + off, size);
	return (0);
}

static int
ram_erase(const struct lfs_config *c, lfs_block_t block)
{
	(void)c;
	(void)block;
	return (0);
}

static int
ram_sync(const struct lfs_config *c)
{
	(void)c;
	return (0);
}

static void
configure(struct lfs_config *cfg)
{
	erx_lfs_config(cfg, BLOCKS);
	cfg->read = ram_read;
	cfg->prog = ram_prog;
	cfg->erase = ram_erase;
	cfg->sync = ram_sync;
	cfg->read_buffer = read_buf;
	cfg->prog_buffer = prog_buf;
	cfg->lookahead_buffer = lookahead_buf;
}

static void
write_file(lfs_t *lfs, const char *path, size_t size)
{
	struct lfs_file_config fcfg;
	lfs_file_t file;

	bzero(&fcfg, sizeof(fcfg));
	fcfg.buffer = file_buf;
	if (lfs_file_opencfg(lfs, &file, path, LFS_O_WRONLY | LFS_O_CREAT,
	    &fcfg) < 0)
		return;
	(void)lfs_file_write(lfs, &file, data, (lfs_size_t)size);
	(void)lfs_file_sync(lfs, &file);
	(void)lfs_file_close(lfs, &file);
}

static void
read_file(lfs_t *lfs, const char *path)
{
	struct lfs_file_config fcfg;
	lfs_file_t file;
	int rounds;

	bzero(&fcfg, sizeof(fcfg));
	fcfg.buffer = file_buf;
	if (lfs_file_opencfg(lfs, &file, path, LFS_O_RDONLY, &fcfg) < 0)
		return;
	(void)lfs_file_size(lfs, &file);
	for (rounds = 0; rounds < 16; rounds++)
		if (lfs_file_read(lfs, &file, data, sizeof(data)) <= 0)
			break;
	(void)lfs_file_close(lfs, &file);
}

/* Lists directories breadth first from a queue of paths, bounded. */
static void
walk(lfs_t *lfs)
{
	static char queue[MAX_ENTRIES][ERX_LFS_PATH_MAX];
	static int depth[MAX_ENTRIES];
	struct lfs_info info;
	lfs_dir_t dir;
	size_t len, name_len;
	int head, tail, seen;
	char path[ERX_LFS_PATH_MAX];

	strcpy(queue[0], "/");
	depth[0] = 0;
	head = 0;
	tail = 1;
	seen = 0;
	while (head < tail && seen < MAX_ENTRIES) {
		const char *dir_path = queue[head];
		int dir_depth = depth[head];

		head++;
		if (lfs_dir_open(lfs, &dir, dir_path) < 0)
			continue;
		while (seen++ < MAX_ENTRIES && lfs_dir_read(lfs, &dir, &info) > 0) {
			if (strcmp(info.name, ".") == 0 ||
			    strcmp(info.name, "..") == 0)
				continue;
			len = strlen(dir_path);
			name_len = strnlen(info.name, sizeof(info.name));
			if (len + 1 + name_len + 1 > sizeof(path))
				continue;
			memcpy(path, dir_path, len);
			if (len > 1)
				path[len++] = '/';
			memcpy(path + len, info.name, name_len);
			path[len + name_len] = '\0';
			(void)lfs_stat(lfs, path, &info);
			if (info.type == LFS_TYPE_REG)
				read_file(lfs, path);
			else if (dir_depth + 1 < MAX_DEPTH && tail < MAX_ENTRIES) {
				strcpy(queue[tail], path);
				depth[tail++] = dir_depth + 1;
			}
		}
		(void)lfs_dir_close(lfs, &dir);
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *input, size_t size)
{
	struct lfs_config cfg;
	lfs_t lfs;
	size_t at, offset;

	if (size == 0)
		return (0);
	bzero(image, sizeof(image));
	memset(data, 'x', sizeof(data));
	configure(&cfg);
	if (input[0] == 0) {
		bcopy(input + 1, image, size - 1 < IMAGE_SIZE ? size - 1 :
		    IMAGE_SIZE);
	} else {
		if (lfs_format(&lfs, &cfg) < 0 || lfs_mount(&lfs, &cfg) < 0)
			return (0);
		(void)lfs_mkdir(&lfs, "/d");
		write_file(&lfs, "/d/small", 16);
		write_file(&lfs, "/big", sizeof(data));
		(void)lfs_unmount(&lfs);
		for (at = 1; at + 3 <= size; at += 3) {
			offset = ((size_t)input[at] << 8 | input[at + 1]) %
			    IMAGE_SIZE;
			image[offset] = input[at + 2];
		}
	}
	if (lfs_mount(&lfs, &cfg) < 0)
		return (0);
	walk(&lfs);
	write_file(&lfs, "/new", 100);
	(void)lfs_fs_size(&lfs);
	(void)lfs_unmount(&lfs);
	return (0);
}
