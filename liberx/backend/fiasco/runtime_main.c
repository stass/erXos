/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * main for a program with no main of its own, which is ERTS: alone in its file, so that
 * configure's test programs link with their own main against the same archive.
 */

#include "liberx/backend/runtime_entry.h"

int	main(int, char **, char **);

int
main(int argc, char **argv, char **envp)
{
	(void)argc;
	(void)argv;
	(void)envp;
	erx_runtime_main();
	return (0);
}
