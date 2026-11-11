/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program that ends by itself (tools/lib/erx/programs.rb):
 * libc_task.c's entry stops the program's space with main's return, which its
 * owner reads as {Port, {exit_status, 42}}.
 */

int	main(void);

int
main(void)
{
	return (42);
}
