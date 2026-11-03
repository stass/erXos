/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A naked function whose body is one NOP: it runs off its end into
 * whatever follows it, a path no edge records.
 */

__attribute__((naked)) void
falls_off(void)
{
	__asm__ volatile("nop");
}
