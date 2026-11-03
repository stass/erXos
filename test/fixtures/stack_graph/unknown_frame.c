/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A function written in assembly beside a C one: the object has a function
 * symbol for it, but clang writes no stack-usage record of it.
 */

__asm__(".text\n"
        ".globl unrecorded\n"
        ".type unrecorded, %function\n"
        "unrecorded:\n"
        "\tret\n"
        ".size unrecorded, . - unrecorded\n");

int
recorded(void)
{
	return 0;
}
