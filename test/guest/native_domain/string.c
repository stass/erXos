/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The string functions the domain library and the boot page builder call
 * beyond root_mem.c's memcpy and memset, for this suite's stand-in root, which
 * links no C library. In the system domain's root musl defines them.
 */

#include <stddef.h>
#include <string.h>

void *
memchr(const void *bytes, int value, size_t length)
{
	const unsigned char *at = bytes;

	for (size_t index = 0; index < length; index++)
		if (at[index] == (unsigned char)value)
			return ((void *)(at + index));
	return (NULL);
}

int
memcmp(const void *left, const void *right, size_t length)
{
	const unsigned char *a = left, *b = right;

	for (size_t index = 0; index < length; index++)
		if (a[index] != b[index])
			return (a[index] < b[index] ? -1 : 1);
	return (0);
}

size_t
strlen(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	return (length);
}
