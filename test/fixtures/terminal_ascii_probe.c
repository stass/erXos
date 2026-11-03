/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/terminal_ascii.h"

_Static_assert(sizeof(erx_terminal_ascii_safe) == 256, "byte class extent");

int main(void);

int
main(void)
{
	bool expected;

	for (uint32_t byte = 0; byte < 256; byte++) {
		expected = (byte >= 0x20 && byte <= 0x7e) || byte == 9;
		if (erx_terminal_ascii_safe[byte] != (uint8_t)expected)
			return (1);
	}
	return (0);
}
