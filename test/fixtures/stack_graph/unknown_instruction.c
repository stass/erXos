/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* An ERET: a control-flow instruction the stack proof does not decode. */

void
unknown_instruction(void)
{
	__asm__ volatile(".inst 0xd69f03e0" ::: "memory");
}
