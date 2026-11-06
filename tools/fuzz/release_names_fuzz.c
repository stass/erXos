/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_release_fs_add_name, the decoder of the name lists any process hands the
 * release's NIFs. The input is a run of names, each a 16-bit little-endian
 * length and that many bytes, the last cut short by the input's end. Every
 * name is added in turn: an accepted name must extend the list by a `/` and
 * itself, a refused one must leave the list as it was, and the list must stay
 * a list the core may walk: at most ERX_NS_NAMES_MAX names of 1 to
 * ERX_NAME_MAX bytes joined by single `/`s, none `.` or `..`, no NUL, and a
 * NUL's room left in its ERX_PATH_MAX bytes. The walk over an empty release
 * then stops at the first name.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/release_fs.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void check_list(const erx_release_fs_names_t *);
static void check_step(const erx_release_fs_names_t *,
    const erx_release_fs_names_t *, bool, const uint8_t *, size_t);

/* The list's own shape, whatever names reached it. */
static void
check_list(const erx_release_fs_names_t *names)
{
	static const erx_release_fs_t empty = { .files = NULL, .count = 0 };
	erx_release_fs_kind_t stop;
	uint32_t count;
	size_t start, length;

	if (names->count > ERX_NS_NAMES_MAX || names->length >= ERX_PATH_MAX ||
	    (names->count == 0) != (names->length == 0))
		abort();
	count = 0;
	start = 0;
	for (size_t end = 0; names->count > 0 && end <= names->length; end++) {
		if (end < names->length && names->bytes[end] == 0)
			abort();
		if (end < names->length && names->bytes[end] != '/')
			continue;
		length = end - start;
		if (length == 0 || length > ERX_NAME_MAX ||
		    (length == 1 && names->bytes[start] == '.') ||
		    (length == 2 && names->bytes[start] == '.' &&
		    names->bytes[start + 1] == '.'))
			abort();
		count++;
		start = end + 1;
	}
	if (count != names->count)
		abort();
	if (erx_release_fs_walk(&empty, names, &stop) != 0 ||
	    stop != (names->count == 0 ? ERX_RELEASE_FS_DIRECTORY :
	    ERX_RELEASE_FS_MISSING))
		abort();
}

/* One add: the list grew by exactly the name, or did not change at all. */
static void
check_step(const erx_release_fs_names_t *before,
    const erx_release_fs_names_t *after, bool accepted, const uint8_t *name,
    size_t length)
{
	size_t at;

	if (memcmp(after->bytes, before->bytes, before->length) != 0)
		abort();
	if (!accepted) {
		if (after->count != before->count || after->length != before->length)
			abort();
		return;
	}
	at = before->length;
	if (before->count > 0 && after->bytes[at++] != '/')
		abort();
	if (after->count != before->count + 1 || after->length != at + length ||
	    memcmp(after->bytes + at, name, length) != 0)
		abort();
}

int
LLVMFuzzerTestOneInput(const uint8_t *input, size_t size)
{
	static _Thread_local erx_release_fs_names_t names, before;
	size_t cursor, length;
	bool accepted;

	names.count = 0;
	names.length = 0;
	cursor = 0;
	while (size - cursor >= 2) {
		length = (size_t)input[cursor] | (size_t)input[cursor + 1] << 8;
		cursor += 2;
		if (length > size - cursor)
			length = size - cursor;
		before.count = names.count;
		before.length = names.length;
		memcpy(before.bytes, names.bytes, names.length);
		accepted = erx_release_fs_add_name(&names, input + cursor, length);
		check_step(&before, &names, accepted, input + cursor, length);
		check_list(&names);
		cursor += length;
	}
	return (0);
}
