/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program that checks what its startup message gave it
 * (tools/lib/erx/programs.rb, the args case): argv, env, the working
 * directory, the process ids and the file mode creation mask the case's spec
 * names. It ends with 0 when all agree, and with a code of its own for the
 * first that does not.
 */

#include <string.h>

#include "liberx/program/program.h"

int	main(int, char **, char **);

static const char *const want_argv[] = { "args", "one", "two words" };
static const char *const want_env[] = { "HOME=/home/u", "TERM=vt100" };

/* Whether list holds exactly the count strings of want, then NULL. */
static int
same(char **list, const char *const want[], size_t count)
{
	for (size_t at = 0; at < count; at++) {
		if (list[at] == NULL || strcmp(list[at], want[at]) != 0)
			return (0);
	}
	return (list[count] == NULL);
}

int
main(int argc, char **argv, char **envp)
{
	extern char **environ;
	const erx_prog_self_t *const self = erx_prog_self();

	if (argc != 3)
		return (1);
	if (!same(argv, want_argv, 3))
		return (2);
	if (!same(envp, want_env, 2) || environ != envp)
		return (3);
	if (self->cwd == NULL || strcmp(self->cwd, "/home/u") != 0)
		return (4);
	if (self->pid != 5 || self->ppid != 1 || self->pgid != 5 || self->spawn)
		return (5);
	if (self->umask != 027)
		return (6);
	if (self->sigmask.bits[0] != UINT64_C(1) << (ERX_SIGTERM - 1) || self->sigmask.bits[1] != 0 ||
	    self->sigignore.bits[0] != 0 || self->sigignore.bits[1] != 0)
		return (7);
	if (self->data_area == NULL || self->data_bytes != 4 * 65536)
		return (8);
	return (0);
}
