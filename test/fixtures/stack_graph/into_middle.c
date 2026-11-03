/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A BL whose CALL26 relocation names the second instruction of another
 * function, which no frame record describes as an entry.
 */

__attribute__((noinline)) int
middle_target(int value)
{
	return value * 7 + 1;
}

void
into_middle(void)
{
	__asm__ volatile("bl middle_target + 4" ::: "x0", "x30", "memory");
}
