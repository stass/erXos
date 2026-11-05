/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_NS_H
#define ERX_NS_H

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * A domain's namespace and its one resolver (design-files.md, Namespaces and
 * Resolving a path). erx_ns_resolve is a pure function of the table and the
 * path's bytes: it uses no heap and recurses nowhere. `.` and `..` are handled
 * lexically, so no provider ever sees either, and a path reaches a provider
 * only as the names of a result.
 */

typedef enum erx_ns_kind {
	ERX_NS_RELEASE,		/* the domain's release slice, read-only */
	ERX_NS_EROFS,		/* an EROFS image the domain holds a window on */
	ERX_NS_RAM,		/* the domain's RAM file system */
	ERX_NS_SERVER		/* a grant at a file server */
} erx_ns_kind_t;

typedef enum erx_ns_status {
	ERX_NS_OK,
	ERX_NS_EINVAL,		/* not UTF-8, or holds a NUL */
	ERX_NS_ENAMETOOLONG,	/* over a limit of the path, a name or the count */
	ERX_NS_ENOENT		/* empty, or reaches no mount */
} erx_ns_status_t;

/* point and root are normalised and absolute: `/` or `/a/b`. */
typedef struct erx_ns_mount {
	char		point[ERX_PATH_MAX];
	erx_ns_kind_t	kind;
	char		root[ERX_PATH_MAX];
} erx_ns_mount_t;

typedef struct erx_ns {
	uint32_t	count;		/* at most ERX_NS_MOUNTS_MAX */
	erx_ns_mount_t	mounts[ERX_NS_MOUNTS_MAX];
	char		cwd[ERX_PATH_MAX];	/* normalised, absolute */
} erx_ns_t;

/*
 * What a path resolved to; a source check lets only erx_ns_resolve write these
 * fields. res_mount is NULL for the empty root, a read-only
 * directory above the mount points of a narrowed namespace. res_names is the names
 * after the mount's point, under its root, joined by `/` with no leading `/`,
 * and empty at the top. res_path is the whole path, normalised and absolute, which
 * is what a working directory stores. Both are NUL-terminated, and neither
 * holds `.`, `..` or an empty name.
 */
typedef struct erx_ns_result {
	const erx_ns_mount_t *res_mount;
	uint32_t	res_nnames;
	size_t		res_names_length;
	size_t		res_path_length;
	char		res_names[ERX_PATH_MAX];
	char		res_path[ERX_PATH_MAX];
} erx_ns_result_t;

/* Anything but ERX_NS_OK leaves res_mount NULL and every count zero. */
erx_ns_status_t	erx_ns_resolve(const erx_ns_t *, const uint8_t *, size_t,
	    erx_ns_result_t *);

#endif /* ERX_NS_H */
