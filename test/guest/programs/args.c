/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program that checks what its startup message gave it
 * (tools/lib/erx/programs.rb, the args case): argv, env, the working
 * directory, the process ids and the file mode creation mask the case's spec
 * names, and no descriptor: every call naming one reaches the program layer's
 * table through musl's descriptor seam (liberx/backend/fiasco/libc_start.h)
 * and fails with EBADF, never the console, and munmap's own checks refuse an
 * address off a page, a length of 0 and an end past 2^64 with EINVAL. It ends
 * with 0 when all agree, and with a code of its own for the first that does
 * not.
 */

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

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

/* Whether the call failed with -1 and set errno to want. */
static int
failed(long got, int want)
{
	return (got == -1 && errno == want);
}

/* 0 when no descriptor is installed and munmap checks its own arguments, else the first check's code. */
static int
descriptors(void)
{
	static char page[4096] __attribute__((aligned(4096)));
	const uintptr_t top = UINTPTR_MAX & ~(uintptr_t)4095;
	struct winsize size;
	struct stat st;
	char byte = 'x';

	if (!failed(write(1, &byte, 1), EBADF))
		return (9);
	if (!failed(read(0, &byte, 1), EBADF))
		return (10);
	if (!failed(fstat(0, &st), EBADF))
		return (11);
	if (!failed(lseek(0, 0, SEEK_SET), EBADF))
		return (12);
	if (!failed(ioctl(1, TIOCGWINSZ, &size), EBADF))
		return (13);
	if (mmap(NULL, 4096, PROT_READ, MAP_SHARED, 3, 0) != MAP_FAILED || errno != EBADF)
		return (14);
	if (!failed(close(3), EBADF))
		return (15);
	if (!failed(munmap(page + 1, 4096), EINVAL))
		return (16);
	if (!failed(munmap(page, 0), EINVAL))
		return (17);
	if (!failed(munmap((void *)top, 8192), EINVAL))
		return (18);
	return (0);
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
	return (descriptors());
}
