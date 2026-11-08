/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "erx/abi.h"
#include "liberx/backend/fiasco/boot_args.h"

#define ARGS_PREFIX		"erx."
#define ARGS_WATCHDOG		"erx.watchdog="
#define ARGS_DET		"erx.det="
#define ARGS_GROUP_REPORT	"erx.group_report="
#define ARGS_HOSTLINK		"erx.hostlink="
#define ARGS_ARG		"erx.arg="
#define ARGS_LEN(prefix)	(sizeof(prefix) - 1)

/* The root reads this line before anything else runs and links no C library when it has no program. */
static const char *
find_byte(const char *bytes, char byte, size_t length)
{
	for (size_t at = 0; at < length; at++) {
		if (bytes[at] == byte)
			return (bytes + at);
	}
	return (NULL);
}

/* The next word on spaces, or false at the end of the line. */
static bool
next_word(const char *bytes, size_t length, size_t *cursor, const char **word, size_t *word_len)
{
	size_t at = *cursor;

	while (at < length && bytes[at] == ' ')
		at++;
	if (at == length) {
		*cursor = at;
		return (false);
	}

	const char *const space = find_byte(bytes + at, ' ', length - at);
	const size_t end = space != NULL ? (size_t)(space - bytes) : length;

	*word = bytes + at;
	*word_len = end - at;
	*cursor = end;
	return (true);
}

static bool
has_prefix(const char *word, size_t length, const char *prefix)
{
	for (size_t at = 0; prefix[at] != '\0'; at++) {
		if (at == length || word[at] != prefix[at])
			return (false);
	}
	return (true);
}

/* Whether a switch's word, whose name with its = is head bytes long, is exactly that name and 1. */
static bool
is_switch_on(const char *word, size_t length, size_t head)
{
	return (length == head + 1 && word[head] == '1');
}

static bool
refuse(erx_boot_args_t *out, const char *word, size_t length)
{
	const char *const equals = find_byte(word, '=', length);

	out->refused = word;
	out->refused_len = equals != NULL ? (size_t)(equals - word) : length;
	return (false);
}

/* Takes one erx.arg value into the count, if it fits the page's strings. */
static bool
count_arg(erx_boot_args_t *out, const char *value, size_t length)
{
	if (length == 0 || find_byte(value, '\0', length) != NULL)
		return (false);
	if (length + 1 > ERX_BOOT_STRINGS_MAX - out->arg_bytes)
		return (false);
	out->arg_count++;
	out->arg_bytes += (uint32_t)length + 1;
	return (true);
}

bool
erx_boot_args_parse(const char *bytes, size_t length, erx_boot_args_t *out)
{
	size_t cursor = 0, word_len = 0;
	const char *word = NULL;

	*out = (erx_boot_args_t){ 0 };
	while (next_word(bytes, length, &cursor, &word, &word_len)) {
		if (!has_prefix(word, word_len, ARGS_PREFIX))
			continue;
		if (has_prefix(word, word_len, ARGS_WATCHDOG)) {
			const size_t head = ARGS_LEN(ARGS_WATCHDOG);

			if (erx_watchdog_parse(word + head, word_len - head, &out->watchdog) != ERX_WATCHDOG_PARSE_OK)
				return (refuse(out, word, word_len));
			out->have_watchdog = true;
		} else if (has_prefix(word, word_len, ARGS_DET)) {
			if (!is_switch_on(word, word_len, ARGS_LEN(ARGS_DET)))
				return (refuse(out, word, word_len));
			out->det = true;
		} else if (has_prefix(word, word_len, ARGS_GROUP_REPORT)) {
			if (!is_switch_on(word, word_len, ARGS_LEN(ARGS_GROUP_REPORT)))
				return (refuse(out, word, word_len));
			out->group_report = true;
		} else if (has_prefix(word, word_len, ARGS_HOSTLINK)) {
			if (!is_switch_on(word, word_len, ARGS_LEN(ARGS_HOSTLINK)))
				return (refuse(out, word, word_len));
			out->hostlink = true;
		} else if (has_prefix(word, word_len, ARGS_ARG)) {
			const size_t head = ARGS_LEN(ARGS_ARG);

			if (!count_arg(out, word + head, word_len - head))
				return (refuse(out, word, word_len));
		} else {
			return (refuse(out, word, word_len));
		}
	}
	return (true);
}

bool
erx_boot_args_next_arg(const char *bytes, size_t length, size_t *cursor, const char **word, size_t *word_len)
{
	const size_t head = ARGS_LEN(ARGS_ARG);

	while (next_word(bytes, length, cursor, word, word_len)) {
		if (has_prefix(*word, *word_len, ARGS_ARG)) {
			*word += head;
			*word_len -= head;
			return (true);
		}
	}
	return (false);
}
