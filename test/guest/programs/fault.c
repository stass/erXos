/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program that faults (tools/lib/erx/programs.rb): it loads
 * from the null page, which no space maps, so its first thread takes a data
 * abort, and the session's fault gate gets a page-fault record, which ends the
 * program with ERX_EXIT_SIGNAL plus the fault table's SIGSEGV. The pointer is
 * volatile, so the compiler cannot see it is null and replace the load with a
 * trap of its own.
 */

int	main(void);

int
main(void)
{
	int *volatile null = 0;

	return (*null);
}
