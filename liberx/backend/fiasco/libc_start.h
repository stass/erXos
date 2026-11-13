/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_LIBC_START_H
#define ERX_FIASCO_LIBC_START_H

#include <stdbool.h>
#include <stddef.h>

/*
 * Where the program's standard output and standard error go, unchanged: the root writes to
 * the console itself, and a task's bytes go through the service. Either way the caller's
 * write succeeds.
 */
void	erx_fiasco_libc_write(const void *, size_t);

/*
 * The descriptor seam (docs/design-stopgap.md, "musl over the backend"): musl's syscall
 * switch offers it every call that names a descriptor, every munmap, every mmap of a
 * descriptor or with MAP_FIXED, and every rt_sigaction, with the call's number and its six
 * arguments, before any row of its own. true when the build took the call, with *result its return, a value or
 * a negative errno; false leaves it to musl's rows. Every entry file defines it beside
 * erx_fiasco_libc_write, so a build without it fails to link: a program's
 * (program_task.c) answers every such call from its descriptor table, and the others
 * hold no descriptor and take none. For SYS_fstat, args[1] is a struct stat, and for
 * SYS_rt_sigaction args[1] and args[2] are struct sigaction, either NULL.
 */
bool	erx_fiasco_libc_fd(long, const long[6], long *);

/* Runs program as main through musl's start. exit() ends it, so this returns only on a bug. */
void	erx_fiasco_libc_start(int (*program)(int, char **, char **));

#endif /* ERX_FIASCO_LIBC_START_H */
