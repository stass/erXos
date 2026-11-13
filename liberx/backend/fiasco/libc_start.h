/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_LIBC_START_H
#define ERX_FIASCO_LIBC_START_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/cdefs.h"

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

/*
 * The CPU feature words a program's start gives musl as AT_HWCAP and AT_HWCAP2, in the
 * boot information page's encoding (Linux's AT_HWCAP words). An entry with a page passes
 * the page's hwcap and hwcap2; one without passes zeros, which claim no optional feature.
 */
typedef struct erx_fiasco_cpu_features {
	uint64_t	hwcap;
	uint64_t	hwcap2;
} erx_fiasco_cpu_features_t;

/*
 * Runs program as main through musl's start, with features in the auxiliary vector and
 * AT_RANDOM's 16 bytes from erx_entropy_read. exit() ends the program, so this returns
 * only when it cannot start: ERX_FIASCO_TASK_STATUS_ENTROPY (task_start.h) when the
 * generator refused AT_RANDOM's bytes, and musl's start never ran, or
 * ERX_FIASCO_TASK_STATUS_LIBC when musl's start came back, which is a bug.
 */
int64_t	erx_fiasco_libc_start(int (*program)(int, char **, char **), erx_fiasco_cpu_features_t features)
	    ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_LIBC_START_H */
