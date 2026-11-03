/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* A variable-length array: clang reports the frame as dynamic. */

int
dynamic_frame(int count)
{
	volatile char bytes[count];

	bytes[0] = 1;
	return bytes[0];
}
