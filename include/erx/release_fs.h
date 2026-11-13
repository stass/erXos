/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_RELEASE_FS_H
#define ERX_RELEASE_FS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * The release file system's pure core (design-runtime.md, Files): a view of a
 * sorted list of paths, each a file or an empty directory. `d` is a directory
 * exactly when it is an empty directory's path or some path starts `d/`, and
 * the top always is. The table must be sorted by bytes and hold no path that
 * is a prefix of another at a `/`, which erx_pack_open has checked of the
 * index it is built from, so an empty directory has nothing under it.
 */

typedef struct erx_release_fs_file {
	const uint8_t	*path;		/* with no leading `/` */
	size_t		 length;
	uint64_t	 size;
	uint64_t	 offset;	/* from the release's first byte */
	bool		 directory;	/* an empty directory: size 0 */
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

/*
 * A name list as the release's NIFs take it (design-files.md, Erlang clients):
 * the names joined by `/`, with no leading `/` and no NUL, the top being the
 * empty list. Any process can hand the NIFs any list, so each name passes
 * erx_release_fs_add_name before the core below sees the list.
 */
typedef struct erx_release_fs_names {
	uint32_t	 count;
	size_t		 length;
	uint8_t		 bytes[ERX_PATH_MAX];
} erx_release_fs_names_t;

/*
 * Adds a name to the list, or refuses it and leaves the list as it was: the
 * ERX_NS_NAMES_MAX + 1st name, a name that is not 1 to ERX_NAME_MAX bytes of
 * UTF-8, `.` or `..`, or holds `/` or NUL, and a name the list's ERX_PATH_MAX
 * bytes cannot hold, which no place's names fill.
 */
bool		erx_release_fs_add_name(erx_release_fs_names_t *, const uint8_t *,
		    size_t);
/*
 * Walks the names from the top, as erx_path's walk callback answers
 * (design-files.md, Resolving a path): returns how many leading names are
 * directories, and sets *stop to the kind of the name after them, FILE or
 * MISSING, or to DIRECTORY when every name is one.
 */
uint32_t	erx_release_fs_walk(const erx_release_fs_t *,
		    const erx_release_fs_names_t *, erx_release_fs_kind_t *);
/*
 * names joined as a name list holds them; *file is set for
 * ERX_RELEASE_FS_FILE, and only a file's entry is one: an empty
 * directory's is ERX_RELEASE_FS_DIRECTORY.
 */
erx_release_fs_kind_t erx_release_fs_lookup(const erx_release_fs_t *,
	    const uint8_t *, size_t, uint32_t *);
/* Where a listing of the directory `names` starts. */
uint32_t	erx_release_fs_list_start(const erx_release_fs_t *, const uint8_t *,
	    size_t);
/*
 * The directory's next name, each once, in the index's order; false at the end.
 * The cursor starts from erx_release_fs_list_start, each call repeats the same
 * names, and the name returned points into the table.
 */
bool		erx_release_fs_list_next(const erx_release_fs_t *, const uint8_t *,
	    size_t, uint32_t *, const uint8_t **, size_t *);

#endif /* ERX_RELEASE_FS_H */
