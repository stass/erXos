/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_NS_H
#define ERX_NS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * A domain's namespace and its one resolver (design-files.md, Namespaces and
 * Resolving a path). erx_ns_resolve is a pure function of the table and the
 * path's bytes: it uses no heap and recurses nowhere. `.` and `..` are handled
 * lexically, so no provider ever sees either, and a path reaches a provider
 * only as the names of a result.
 *
 * erx_ns_mount, erx_ns_bind and erx_ns_unmount are the only changes to a table
 * (design-files.md, Building, binding and mounting). Each is a pure function of the
 * table and its arguments: it checks the whole change first and, on any refusal,
 * leaves the table as it was. The caller owns the table and its locking.
 */

typedef enum erx_ns_kind {
	ERX_NS_RELEASE,		/* the domain's release slice, read-only */
	ERX_NS_EROFS,		/* an EROFS image the domain holds a window on */
	ERX_NS_SERVER		/* a grant at a file server, by pid */
} erx_ns_kind_t;

typedef enum erx_ns_rights {	/* no value writes and runs together (F6) */
	ERX_NS_RO,
	ERX_NS_RW,
	ERX_NS_RX
} erx_ns_rights_t;

typedef enum erx_ns_status {
	ERX_NS_OK,
	ERX_NS_EINVAL,		/* not UTF-8, holds a NUL, or a rename of `/` */
	ERX_NS_ENAMETOOLONG,	/* over a limit of the path, a name or the count */
	ERX_NS_ENOENT,		/* empty, or reaches no mount */
	ERX_NS_EEXIST,		/* a mount or bind at a point the table already has */
	ERX_NS_EBUSY,		/* unmounting `/` */
	ERX_NS_ELIMIT,		/* the table already holds ERX_NS_MOUNTS_MAX entries */
	ERX_NS_EXDEV		/* two paths that one provider cannot take together */
} erx_ns_status_t;

/*
 * point and root are normalised and absolute: `/` or `/a/b`. No two entries of a
 * table share a point. A root other than `/` comes only from erx_ns_bind.
 */
typedef struct erx_ns_mount {
	char		point[ERX_PATH_MAX];
	erx_ns_kind_t	kind;
	uint64_t	server;			/* ERX_NS_SERVER: the grant's pid, as the
						 * runtime names it, never 0; 0 once the
						 * runtime has seen the pid end */
	char		tree[ERX_NAME_MAX + 1];	/* ERX_NS_SERVER: the tree the grant
						 * roots in, its attach name */
	char		root[ERX_PATH_MAX];
	erx_ns_rights_t	rights;			/* what the provider or grant allows
						 * through this entry */
} erx_ns_mount_t;

typedef struct erx_ns {
	uint32_t	count;		/* at most ERX_NS_MOUNTS_MAX */
	erx_ns_mount_t	mounts[ERX_NS_MOUNTS_MAX];
	char		cwd[ERX_PATH_MAX];	/* normalised, absolute */
} erx_ns_t;

/*
 * What a path resolved to; a source check lets only liberx/ns.c write these
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
/*
 * Resolves the two paths of a link, the first into the first result,
 * in one call, so a caller holding its lock across the call sees both on one
 * table. The pair is ERX_NS_OK when one provider takes both: one grant's tree
 * through one set of rights (erx_ns_same_grant), or, for two paths neither on a
 * grant, the runtime's own read-only providers. A path on a grant with any other
 * path is ERX_NS_EXDEV, as between two Unix file systems, and no server is asked
 * (design-files.md, Erlang clients). A path that fails answers its own status,
 * the first path's first. Anything but ERX_NS_OK leaves both results as a refused
 * erx_ns_resolve leaves its one.
 */
erx_ns_status_t	erx_ns_resolve_two(const erx_ns_t *, const uint8_t *, size_t,
	    const uint8_t *, size_t, erx_ns_result_t *, erx_ns_result_t *);
/*
 * erx_ns_resolve_two for a rename, the source first. A source written as `/` is
 * ERX_NS_EINVAL, once both paths resolve and before the pair could be
 * ERX_NS_EXDEV: stock prim_file answers einval for a rename of `/`. Any other
 * source, `//` and the top of a mount or bind included, resolves as
 * erx_ns_resolve_two resolves it (design-files.md, Errors).
 */
erx_ns_status_t	erx_ns_resolve_rename(const erx_ns_t *, const uint8_t *, size_t,
	    const uint8_t *, size_t, erx_ns_result_t *, erx_ns_result_t *);
/*
 * Whether two entries reach the same tree of the same grant through the same
 * rights, whatever their points and roots: a request through one may name
 * anything the other reaches. False unless both are ERX_NS_SERVER.
 */
bool		erx_ns_same_grant(const erx_ns_mount_t *, const erx_ns_mount_t *);

/*
 * Adds an ERX_NS_SERVER entry for the grant `server` at the point the path
 * resolves to, with the tree it roots in, which must be one name, and `rights`.
 */
erx_ns_status_t	erx_ns_mount(erx_ns_t *, const uint8_t *, size_t, uint64_t,
	    const uint8_t *, size_t, erx_ns_rights_t);
/*
 * Adds an entry at the second path's point that shows what the first path
 * resolves to: its mount, with the names below it as its root, read-only if
 * asked. The first path must reach a mount (ERX_NS_ENOENT otherwise).
 */
erx_ns_status_t	erx_ns_bind(erx_ns_t *, const uint8_t *, size_t,
	    const uint8_t *, size_t, bool);
/* Removes the entry whose point is exactly where the path resolves to. */
erx_ns_status_t	erx_ns_unmount(erx_ns_t *, const uint8_t *, size_t);

/*
 * A runtime draws fids from one 64-bit counter (design-files.md, Version and
 * attach): a draw adds one and keeps the low 32 bits, drawing again for 9P's
 * NOFID (ERX_P9_NOFID), which no fid takes. This gives the fid a draw that gave
 * `value` yields, or false for NOFID: draw again.
 */
bool		erx_ns_fid_of(uint64_t, uint32_t *);

#endif /* ERX_NS_H */
