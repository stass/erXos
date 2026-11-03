/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A B written as its raw word, 64 bytes forward: it carries no relocation
 * and lands outside its function, so it is neither a tail jump nor a
 * branch the function keeps to itself.
 */

void
branch_out(void)
{
	__asm__ volatile(".inst 0x14000010" ::: "memory");
}
