/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_RELEASE_FS_H
#define ERX_RELEASE_FS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The release file system's pure core (design-runtime.md, Files): a view of a
 * sorted list of paths. A directory has no record of its own: `d` is one
 * exactly when some path starts `d/`, and the top always is. The table must be
 * sorted by bytes and hold no path that is a prefix of another at a `/`, which
 * erx_pack_open has checked of the index it is built from.
 */

typedef struct erx_release_fs_file {
	const uint8_t	*path;		/* with no leading `/` */
	size_t		 length;
	uint64_t	 size;
	uint64_t	 offset;	/* from the release's first byte */
} erx_release_fs_file_t;

typedef struct erx_release_fs {
	const erx_release_fs_file_t *files;
	uint32_t	 count;
} erx_release_fs_t;

typedef enum erx_release_fs_kind {
	ERX_RELEASE_FS_FILE,
	ERX_RELEASE_FS_DIRECTORY,
	ERX_RELEASE_FS_MISSING,
	ERX_RELEASE_FS_NOT_DIRECTORY	/* a file used as a directory */
} erx_release_fs_kind_t;

/* names as erx_ns_resolve returns them; *file is set for ERX_RELEASE_FS_FILE. */
erx_release_fs_kind_t erx_release_fs_lookup(const erx_release_fs_t *,
	    const uint8_t *, size_t, uint32_t *);
/* Where a listing of the directory `names` starts. */
uint32_t	erx_release_fs_list_start(const erx_release_fs_t *, const uint8_t *,
	    size_t);
/*
 * The directory's next name, each once, in the index's order; false at the end.
 * The name points into the table.
 */
bool		erx_release_fs_list_next(const erx_release_fs_t *, const uint8_t *,
	    size_t, uint32_t *, const uint8_t **, size_t *);

#endif /* ERX_RELEASE_FS_H */
