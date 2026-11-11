/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program that never ends by itself (tools/lib/erx/programs.rb):
 * its one thread runs until the session's port_close/1 stops its space. A loop with
 * no controlling expression may run for ever (C17 6.8.5p6).
 */

int	main(void);

int
main(void)
{
	for (;;)
		;
}
