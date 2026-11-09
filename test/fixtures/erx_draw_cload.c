/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The framing of image(6)'s compressed form that the draw codec's C twin
 * links (erx/draw_codec.h): the walk of 9front's cloadmemimage over its
 * codes, written out without the image it loads into, so it counts the
 * bytes the codes take and stores no pixel. It stands in for cloadmemimage
 * of the 9front build, the twin's oracle in docs/design-display.md
 * ("Verification and testing"), until that build exists (TODO.md).
 */

#include <stddef.h>
#include <stdint.h>

#include <erx/draw_codec.h>

/* cloadmemimage's NMATCH: the shortest back-reference. */
#define CLOAD_MATCH 3

int64_t
erx_draw_cload_frame(const uint8_t *data, size_t size, const int32_t r[4],
    int depth)
{
	int64_t line, left, rows, count;
	size_t at;
	uint8_t c;

	if (r[2] <= r[0] || r[3] <= r[1])
		return (-1);
	line = erx_draw_bytesperline(r[0], r[2], depth);
	rows = (int64_t)r[3] - r[1];
	left = line;
	at = 0;
	for (;;) {
		if (left == 0) {
			if (--rows == 0)
				break;
			left = line;
		}
		if (at == size)
			return (-1);
		c = data[at++];
		if (c >= 128) {
			count = c - 128 + 1;
			if ((uint64_t)count > size - at)
				return (-1);
			at += (size_t)count;
		} else {
			if (at == size)
				return (-1);
			at++;
			count = (c >> 2) + CLOAD_MATCH;
		}
		if (count > left)
			return (-1);
		left -= count;
	}
	return ((int64_t)at);
}
