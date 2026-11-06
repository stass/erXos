/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The resolver of design-files.md, Resolving a path. The path's bytes are
 * untrusted; a namespace's table is built by its domain service, and is read
 * with every string bounded by its field all the same.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/ns.h"

/* The names kept so far, pointing into the path and the working directory. */
typedef struct erx_ns_walk {
	uint32_t	count;
	struct {
		const char	*bytes;
		size_t		 length;
	} names[ERX_NS_NAMES_MAX];
} erx_ns_walk_t;

static bool erx_ns_utf8_valid(const uint8_t *, size_t);
static size_t erx_ns_field_length(const char *);
static erx_ns_status_t erx_ns_walk_names(erx_ns_walk_t *, const char *, size_t);
static bool erx_ns_append(char *, size_t *, const char *, size_t);
static bool erx_ns_normalise(const erx_ns_walk_t *, erx_ns_result_t *);
static bool erx_ns_is_under(const char *, size_t, const char *, size_t);
static const erx_ns_mount_t *erx_ns_longest_mount(const erx_ns_t *,
    const erx_ns_result_t *);
static bool erx_ns_above_a_mount(const erx_ns_t *, const erx_ns_result_t *);
static erx_ns_status_t erx_ns_place_names(const erx_ns_mount_t *,
    erx_ns_result_t *);
static void erx_ns_refuse(erx_ns_result_t *);

/* No NUL, and well-formed UTF-8: no overlong form, surrogate or value past Unicode's end. */
static bool
erx_ns_utf8_valid(const uint8_t *bytes, size_t length)
{
	size_t cursor, count;
	uint32_t point, minimum;

	cursor = 0;
	while (cursor < length) {
		point = bytes[cursor++];
		if (point == 0)
			return (false);
		if (point < 0x80)
			continue;
		if (point >= 0xc2 && point <= 0xdf) {
			point &= 0x1f;
			count = 1;
			minimum = 0x80;
		} else if (point >= 0xe0 && point <= 0xef) {
			point &= 0x0f;
			count = 2;
			minimum = 0x800;
		} else if (point >= 0xf0 && point <= 0xf4) {
			point &= 0x07;
			count = 3;
			minimum = 0x10000;
		} else {
			return (false);
		}
		if (count > length - cursor)
			return (false);
		for (size_t index = 0; index < count; index++) {
			if ((bytes[cursor] & 0xc0) != 0x80)
				return (false);
			point = (point << 6) | (bytes[cursor++] & 0x3f);
		}
		if (point < minimum || point > 0x10ffff ||
		    (point >= 0xd800 && point <= 0xdfff))
			return (false);
	}
	return (true);
}

static size_t
erx_ns_field_length(const char *field)
{
	size_t length;

	length = 0;
	while (length < ERX_PATH_MAX && field[length] != '\0')
		length++;
	return (length);
}

/* Drops empty names and `.`; `..` drops the last name kept, or nothing at `/`. */
static erx_ns_status_t
erx_ns_walk_names(erx_ns_walk_t *walk, const char *bytes, size_t length)
{
	size_t cursor, start, count;

	cursor = 0;
	while (cursor < length) {
		start = cursor;
		while (cursor < length && bytes[cursor] != '/')
			cursor++;
		count = cursor - start;
		cursor++;
		if (count == 0 || (count == 1 && bytes[start] == '.'))
			continue;
		if (count == 2 && bytes[start] == '.' && bytes[start + 1] == '.') {
			if (walk->count > 0)
				walk->count--;
			continue;
		}
		if (count > ERX_NAME_MAX || walk->count == ERX_NS_NAMES_MAX)
			return (ERX_NS_ENAMETOOLONG);
		walk->names[walk->count].bytes = bytes + start;
		walk->names[walk->count].length = count;
		walk->count++;
	}
	return (ERX_NS_OK);
}

/* Keeps a NUL's room at the end of an ERX_PATH_MAX field. */
static bool
erx_ns_append(char *field, size_t *used, const char *bytes, size_t count)
{
	if (count >= ERX_PATH_MAX - *used)
		return (false);
	for (size_t index = 0; index < count; index++)
		field[*used + index] = bytes[index];
	*used += count;
	field[*used] = '\0';
	return (true);
}

static bool
erx_ns_normalise(const erx_ns_walk_t *walk, erx_ns_result_t *out)
{
	size_t used;

	used = 0;
	if (walk->count == 0 && !erx_ns_append(out->res_path, &used, "/", 1))
		return (false);
	for (uint32_t index = 0; index < walk->count; index++) {
		if (!erx_ns_append(out->res_path, &used, "/", 1) ||
		    !erx_ns_append(out->res_path, &used, walk->names[index].bytes,
		    walk->names[index].length))
			return (false);
	}
	out->res_path_length = used;
	return (true);
}

/* Whether path is point or lies below it, comparing whole names. */
static bool
erx_ns_is_under(const char *path, size_t path_length, const char *point,
    size_t point_length)
{
	if (point_length == 1)
		return (true);
	if (point_length > path_length)
		return (false);
	for (size_t index = 0; index < point_length; index++) {
		if (path[index] != point[index])
			return (false);
	}
	return (path_length == point_length || path[point_length] == '/');
}

static const erx_ns_mount_t *
erx_ns_longest_mount(const erx_ns_t *ns, const erx_ns_result_t *out)
{
	const erx_ns_mount_t *longest;
	size_t best, length;

	longest = NULL;
	best = 0;
	for (uint32_t index = 0; index < ns->count; index++) {
		length = erx_ns_field_length(ns->mounts[index].point);
		if (length > best && erx_ns_is_under(out->res_path, out->res_path_length,
		    ns->mounts[index].point, length)) {
			longest = &ns->mounts[index];
			best = length;
		}
	}
	return (longest);
}

static bool
erx_ns_above_a_mount(const erx_ns_t *ns, const erx_ns_result_t *out)
{
	for (uint32_t index = 0; index < ns->count; index++) {
		if (erx_ns_is_under(ns->mounts[index].point,
		    erx_ns_field_length(ns->mounts[index].point), out->res_path,
		    out->res_path_length))
			return (true);
	}
	return (false);
}

/* The names after the mount's point, under its root; or the path's own names. */
static erx_ns_status_t
erx_ns_place_names(const erx_ns_mount_t *mount, erx_ns_result_t *out)
{
	const char *rest;
	size_t root_length, point_length, rest_length, used;

	used = 0;
	out->res_names[0] = '\0';
	rest = out->res_path + 1;
	rest_length = out->res_path_length - 1;
	if (mount != NULL) {
		point_length = erx_ns_field_length(mount->point);
		if (point_length > 1) {
			rest = out->res_path + point_length;
			rest_length = out->res_path_length - point_length;
			if (rest_length > 0) {
				rest++;
				rest_length--;
			}
		}
		root_length = erx_ns_field_length(mount->root);
		if (root_length > 1 && (!erx_ns_append(out->res_names, &used,
		    mount->root + 1, root_length - 1) || (rest_length > 0 &&
		    !erx_ns_append(out->res_names, &used, "/", 1))))
			return (ERX_NS_ENAMETOOLONG);
	}
	if (!erx_ns_append(out->res_names, &used, rest, rest_length))
		return (ERX_NS_ENAMETOOLONG);
	out->res_names_length = used;
	out->res_nnames = used > 0 ? 1 : 0;
	for (size_t index = 0; index < used; index++) {
		if (out->res_names[index] == '/')
			out->res_nnames++;
	}
	return (out->res_nnames > ERX_NS_NAMES_MAX ? ERX_NS_ENAMETOOLONG : ERX_NS_OK);
}

erx_ns_status_t
erx_ns_resolve(const erx_ns_t *ns, const uint8_t *path, size_t length,
    erx_ns_result_t *out)
{
	erx_ns_walk_t walk;
	const erx_ns_mount_t *mount;
	erx_ns_status_t status;

	erx_ns_refuse(out);
	if (length > ERX_PATH_MAX)
		return (ERX_NS_ENAMETOOLONG);
	if (length == 0)
		return (ERX_NS_ENOENT);
	if (!erx_ns_utf8_valid(path, length))
		return (ERX_NS_EINVAL);

	walk.count = 0;
	if (path[0] != '/') {
		status = erx_ns_walk_names(&walk, ns->cwd,
		    erx_ns_field_length(ns->cwd));
		if (status != ERX_NS_OK)
			return (status);
	}
	status = erx_ns_walk_names(&walk, (const char *)path, length);
	if (status != ERX_NS_OK)
		return (status);
	if (!erx_ns_normalise(&walk, out))
		return (ERX_NS_ENAMETOOLONG);

	mount = erx_ns_longest_mount(ns, out);
	if (mount == NULL && !erx_ns_above_a_mount(ns, out)) {
		out->res_path_length = 0;
		return (ERX_NS_ENOENT);
	}
	status = erx_ns_place_names(mount, out);
	if (status != ERX_NS_OK) {
		out->res_nnames = 0;
		out->res_names_length = 0;
		out->res_path_length = 0;
		return (status);
	}
	out->res_mount = mount;
	return (ERX_NS_OK);
}

/* What a refused path leaves in its result. */
static void
erx_ns_refuse(erx_ns_result_t *out)
{
	out->res_mount = NULL;
	out->res_nnames = 0;
	out->res_names_length = 0;
	out->res_path_length = 0;
}

erx_ns_status_t
erx_ns_resolve_two(const erx_ns_t *ns, const uint8_t *first, size_t first_length,
    const uint8_t *second, size_t second_length, erx_ns_result_t *first_out,
    erx_ns_result_t *second_out)
{
	erx_ns_status_t status;

	erx_ns_refuse(second_out);
	status = erx_ns_resolve(ns, first, first_length, first_out);
	if (status == ERX_NS_OK)
		status = erx_ns_resolve(ns, second, second_length, second_out);
	if (status != ERX_NS_OK)
		erx_ns_refuse(first_out);
	return (status);
}

/*
 * The changes to a table, reentrant: their state is on the stack, about 16 KiB
 * for a bind. Each resolves its paths with erx_ns_resolve, so a point
 * is normalised and absolute exactly as a path that reaches it is, then checks
 * the whole change before it writes the one entry it adds or removes.
 */

static bool
erx_ns_same_field(const char *field, const char *bytes, size_t length)
{
	if (erx_ns_field_length(field) != length)
		return (false);
	for (size_t index = 0; index < length; index++) {
		if (field[index] != bytes[index])
			return (false);
	}
	return (true);
}

/* The index of the entry at exactly the point, or ns->count when there is none. */
static uint32_t
erx_ns_find_point(const erx_ns_t *ns, const erx_ns_result_t *at)
{
	uint32_t index;

	for (index = 0; index < ns->count; index++) {
		if (erx_ns_same_field(ns->mounts[index].point, at->res_path,
		    at->res_path_length))
			break;
	}
	return (index);
}

/*
 * Where a new entry would go: the point's path resolves (a narrowed namespace's
 * path above or beside its mounts does not, ERX_NS_ENOENT), no entry is there
 * yet, and the table has room.
 */
static erx_ns_status_t
erx_ns_new_point(const erx_ns_t *ns, const uint8_t *path, size_t length,
    erx_ns_result_t *at)
{
	erx_ns_status_t status;

	status = erx_ns_resolve(ns, path, length, at);
	if (status != ERX_NS_OK)
		return (status);
	if (erx_ns_find_point(ns, at) != ns->count)
		return (ERX_NS_EEXIST);
	if (ns->count >= ERX_NS_MOUNTS_MAX)
		return (ERX_NS_ELIMIT);
	return (ERX_NS_OK);
}

/* One name of a file server's trees: 1 to ERX_NAME_MAX bytes of UTF-8, not `.` or `..`. */
static bool
erx_ns_tree_valid(const uint8_t *tree, size_t length)
{
	if (length == 0 || length > ERX_NAME_MAX || !erx_ns_utf8_valid(tree, length))
		return (false);
	if ((length == 1 && tree[0] == '.') ||
	    (length == 2 && tree[0] == '.' && tree[1] == '.'))
		return (false);
	for (size_t index = 0; index < length; index++) {
		if (tree[index] == '/')
			return (false);
	}
	return (true);
}

erx_ns_status_t
erx_ns_mount(erx_ns_t *ns, const uint8_t *point, size_t point_length,
    uint64_t server, const uint8_t *tree, size_t tree_length,
    erx_ns_rights_t rights)
{
	erx_ns_result_t at;
	erx_ns_mount_t *entry;
	erx_ns_status_t status;
	size_t used;

	status = erx_ns_new_point(ns, point, point_length, &at);
	if (status != ERX_NS_OK)
		return (status);
	if (server == 0 || !erx_ns_tree_valid(tree, tree_length) ||
	    (rights != ERX_NS_RO && rights != ERX_NS_RW && rights != ERX_NS_RX))
		return (ERX_NS_EINVAL);

	entry = &ns->mounts[ns->count];
	used = 0;
	(void)erx_ns_append(entry->point, &used, at.res_path, at.res_path_length);
	used = 0;
	(void)erx_ns_append(entry->root, &used, "/", 1);
	for (size_t index = 0; index < tree_length; index++)
		entry->tree[index] = (char)tree[index];
	entry->tree[tree_length] = '\0';
	entry->kind = ERX_NS_SERVER;
	entry->server = server;
	entry->rights = rights;
	ns->count++;
	return (ERX_NS_OK);
}

erx_ns_status_t
erx_ns_bind(erx_ns_t *ns, const uint8_t *from, size_t from_length,
    const uint8_t *to, size_t to_length, bool read_only)
{
	erx_ns_result_t source, at;
	erx_ns_mount_t *entry;
	erx_ns_status_t status;
	size_t used;

	status = erx_ns_resolve(ns, from, from_length, &source);
	if (status != ERX_NS_OK)
		return (status);
	if (source.res_mount == NULL)
		return (ERX_NS_ENOENT);
	status = erx_ns_new_point(ns, to, to_length, &at);
	if (status != ERX_NS_OK)
		return (status);
	/* The root is the source's names, under the leading `/` and before a NUL. */
	if (source.res_names_length + 1 >= ERX_PATH_MAX)
		return (ERX_NS_ENAMETOOLONG);

	entry = &ns->mounts[ns->count];
	*entry = *source.res_mount;
	used = 0;
	(void)erx_ns_append(entry->point, &used, at.res_path, at.res_path_length);
	used = 0;
	(void)erx_ns_append(entry->root, &used, "/", 1);
	(void)erx_ns_append(entry->root, &used, source.res_names,
	    source.res_names_length);
	if (read_only)
		entry->rights = ERX_NS_RO;
	ns->count++;
	return (ERX_NS_OK);
}

erx_ns_status_t
erx_ns_unmount(erx_ns_t *ns, const uint8_t *point, size_t length)
{
	erx_ns_result_t at;
	erx_ns_status_t status;
	uint32_t index;

	status = erx_ns_resolve(ns, point, length, &at);
	if (status != ERX_NS_OK)
		return (status);
	if (at.res_path_length == 1)
		return (ERX_NS_EBUSY);
	index = erx_ns_find_point(ns, &at);
	if (index == ns->count)
		return (ERX_NS_EINVAL);
	/* The entries after it move down one, so the table keeps its order. */
	for (; index + 1 < ns->count; index++)
		ns->mounts[index] = ns->mounts[index + 1];
	ns->count--;
	return (ERX_NS_OK);
}

bool
erx_ns_fid_of(uint64_t value, uint32_t *fid)
{
	if ((uint32_t)value == ERX_P9_NOFID)
		return (false);
	*fid = (uint32_t)value;
	return (true);
}
