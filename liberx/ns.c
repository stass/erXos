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

	out->res_mount = NULL;
	out->res_nnames = 0;
	out->res_names_length = 0;
	out->res_path_length = 0;
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
