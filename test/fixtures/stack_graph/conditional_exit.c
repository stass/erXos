/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A conditional branch to another function, which carries a CONDBR19
 * relocation: neither a call nor a tail jump the proof accepts.
 */

__attribute__((noinline)) int
exit_target(int value)
{
	return value + 1;
}

void
conditional_exit(void)
{
	__asm__ volatile("cbz x0, exit_target" ::: "memory");
}
