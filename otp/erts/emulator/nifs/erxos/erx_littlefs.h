/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The geometry and limits of a littlefs volume on the data partition, shared
 * by the NIF (erx_littlefs_nif.c) and the image fuzz target
 * (tools/fuzz/lfs_image_fuzz.c), so the fuzzer mounts images exactly as the
 * system domain does.
 */

#ifndef ERX_LITTLEFS_H
#define ERX_LITTLEFS_H

#include <strings.h>

#include "lfs.h"

/* The block service's sector, the unit of every block request. */
#define ERX_LFS_SECTOR_SIZE 512u
#define ERX_LFS_BLOCK_SIZE 4096u
#define ERX_LFS_CACHE_SIZE 4096u
#define ERX_LFS_LOOKAHEAD_SIZE 256u
/* A volume of 8 blocks is the smallest littlefs formats usefully; 2^20
 * blocks is 4 GiB. */
#define ERX_LFS_MIN_BLOCKS 8u
#define ERX_LFS_MAX_BLOCKS (1u << 20)
/* Open files per volume, a path's bytes with its NUL, one read or write,
 * one listing, and the longest a block request may wait. */
#define ERX_LFS_SLOTS 32u
#define ERX_LFS_PATH_MAX 1024u
#define ERX_LFS_IO_MAX 65536u
#define ERX_LFS_READDIR_MAX 256u
#define ERX_LFS_MAX_DEADLINE_MS 600000u

/* Fills cfg's geometry; the caller sets the context, callbacks and buffers. */
static inline void
erx_lfs_config(struct lfs_config *cfg, lfs_size_t blocks)
{
	bzero(cfg, sizeof(*cfg));
	cfg->read_size = ERX_LFS_SECTOR_SIZE;
	cfg->prog_size = ERX_LFS_SECTOR_SIZE;
	cfg->block_size = ERX_LFS_BLOCK_SIZE;
	cfg->block_count = blocks;
	/* A block device levels its own wear. */
	cfg->block_cycles = -1;
	cfg->cache_size = ERX_LFS_CACHE_SIZE;
	cfg->lookahead_size = ERX_LFS_LOOKAHEAD_SIZE;
}

#endif /* ERX_LITTLEFS_H */
