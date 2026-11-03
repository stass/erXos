/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A BL written as its raw word: the assembler emits no relocation for it,
 * so the graph cannot name what it calls.
 */

void
unrelocated_call(void)
{
	__asm__ volatile(".inst 0x94000000" ::: "x30", "memory");
}
