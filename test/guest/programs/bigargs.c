/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program whose startup message is larger than its
 * channel's 16 KiB ring (tools/lib/erx/programs.rb, the bigargs case): one
 * argument of BIG bytes of 'x', which reaches it only if the session writes
 * the message as room returns and liberx's executor copies it as it is
 * published. So the executor parks on the program's doorbell at least once,
 * and this program checks, beside the argument, what its first thread's
 * argument registers held (docs/design-programs.md, "The channel"): the
 * five values of program_arg, each a capability, all distinct, and 0 past
 * the doorbell's; and that every doorbell delivery the executor took
 * carried the channel's fixed label, ERX_PROG_CHANNEL_LABEL. It ends
 * with 0 when all agree, and with a code of its own for the first that does
 * not.
 */

#include <stddef.h>
#include <string.h>

#include "liberx/backend/api.h"
#include "liberx/program/program.h"

#define BIG	130000u

int	main(int, char **, char **);

/* Whether the registers hold five distinct capabilities, then zeros, and the budget allocates. */
static int
registers_hold_the_install(const uint64_t regs[ERX_ARCH_START_ARGS])
{
	uint64_t mem;

	for (size_t at = 0; at < ERX_ARCH_START_ARGS; at++) {
		if ((at <= ERX_PROGRAM_ARG_DOORBELL) != (regs[at] != ERX_CAP_NULL))
			return (0);
		for (size_t other = 0; other < at && at <= ERX_PROGRAM_ARG_DOORBELL; other++) {
			if (regs[other] == regs[at])
				return (0);
		}
	}
	if (erx_mem_create(regs[ERX_PROGRAM_ARG_BUDGET], ERX_PAGE_SIZE, 0, &mem) != ERX_OK)
		return (0);
	return (erx_object_destroy(mem) == ERX_OK);
}

int
main(int argc, char **argv, char **envp)
{
	const erx_prog_self_t *const self = erx_prog_self();

	(void)envp;
	if (argc != 2 || strcmp(argv[0], "bigargs") != 0)
		return (1);
	if (strlen(argv[1]) != BIG)
		return (2);
	for (size_t at = 0; at < BIG; at++) {
		if (argv[1][at] != 'x')
			return (3);
	}
	if (!registers_hold_the_install(self->regs))
		return (4);
	if (self->rings == 0)
		return (5);
	if (self->strays != 0)
		return (6);
	return (0);
}
