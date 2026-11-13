/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A session's program as a task (docs/design-programs.md, "Starting a program", step 9):
 * the first thread hands its argument registers, the values of the program's install, to
 * liberx's program layer, and musl's start enters the layer's start-up, which calls the
 * program's main once its startup message is accepted. main's status stops the task, and
 * the session's fault gate reads it.
 *
 * The program's descriptor seam takes every call musl offers it (libc_start.h) but an
 * anonymous mmap, and answers it from the program layer's descriptor table
 * (liberx/program/fd.h): a program writes only to the descriptors its session installed,
 * and a descriptor the table does not hold is EBADF, never the console. rt_sigaction is
 * answered from the program's dispositions (liberx/program/signal.h).
 */

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/uio.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/api.h"
#include "liberx/program/fd.h"
#include "liberx/program/poll.h"
#include "liberx/program/signal.h"
#include "liberx/program/program.h"

/* The seam takes every write, so musl's console row is never reached from a program. */
void
erx_fiasco_libc_write(const void *bytes, size_t length)
{
	(void)bytes;
	(void)length;
	__builtin_trap();
}

/* -EBADF for a descriptor the table does not hold, else what. */
static long
held_or(int fd, long what)
{
	erx_prog_obj_t *const obj = erx_prog_fd_get(fd);

	if (obj == NULL)
		return (-EBADF);
	erx_prog_obj_put(obj);
	return (what);
}

/*
 * readv and writev, one vector entry at a time: the bytes moved, or the first entry's
 * error when none moved. A vector whose lengths sum past SSIZE_MAX is EINVAL before
 * anything moves, and an empty one still answers EBADF for a descriptor the table does
 * not hold. A read ends once any bytes came, so it never waits again with bytes in
 * hand (musl's stdio reads with a two-entry readv); a short write ends a write, as a
 * short transfer ends POSIX's.
 */
static long
vector_call(int fd, const struct iovec *vector, int count, bool writing)
{
	size_t sum = 0;
	long total = 0;

	if (count < 0 || count > IOV_MAX)
		return (-EINVAL);
	for (int index = 0; index < count; index++) {
		if (__builtin_add_overflow(sum, vector[index].iov_len, &sum) || sum > SSIZE_MAX)
			return (-EINVAL);
	}
	if (count == 0)
		return (held_or(fd, 0));
	for (int index = 0; index < count; index++) {
		const size_t len = vector[index].iov_len;
		const ssize_t got = writing ? erx_prog_fd_write(fd, vector[index].iov_base, len) :
		    erx_prog_fd_read(fd, vector[index].iov_base, len);

		if (got < 0)
			return (total > 0 ? total : got);
		total += got;
		if ((size_t)got < len || (!writing && total > 0))
			break;
	}
	return (total);
}

/*
 * mmap through the seam, its arguments in the call's order. A fixed range must miss
 * the mem range; an anonymous mapping is then musl's to make (false), and a mapping of
 * a descriptor the table's.
 */
static bool
mmap_call(const long args[6], long *result)
{
	const uint64_t addr = (uint64_t)args[0], len = (uint64_t)args[1];
	const int prot = (int)args[2], flags = (int)args[3], fd = (int)args[4];
	const off_t offset = (off_t)args[5];
	void *where = NULL;
	int status;

	if (flags & MAP_FIXED) {
		status = erx_prog_fd_fixed_check(addr, len);
		if (status != 0) {
			*result = status;
			return (true);
		}
	}
	if (flags & MAP_ANONYMOUS)
		return (false);
	status = erx_prog_fd_mmap(fd, (size_t)len, prot, flags, offset, &where);
	*result = status != 0 ? status : (long)(uintptr_t)where;
	return (true);
}

/*
 * ppoll, its arguments in the call's order. No signal is ever caught in a program on the
 * stopgap (liberx/program/signal.h), so the mask a ppoll would hold during the wait
 * changes nothing; its size is still checked, as Linux checks it, so a caller that
 * passes one learns of a wrong size.
 */
static long
ppoll_call(struct pollfd *fds, unsigned long nfds, const struct timespec *timeout, bool masked, size_t mask_size)
{
	uint64_t deadline;
	int status;

	if (masked && mask_size != _NSIG / 8)
		return (-EINVAL);
	status = erx_prog_poll_deadline(erx_clock_ns(), timeout, &deadline);
	if (status != 0)
		return (status);
	return (erx_prog_poll(fds, (size_t)nfds, deadline));
}

bool
erx_fiasco_libc_fd(long n, const long args[6], long *result)
{
	const int fd = (int)args[0];

	switch (n) {
	case SYS_read:
		*result = erx_prog_fd_read(fd, (void *)args[1], (size_t)args[2]);
		return (true);
	case SYS_write:
		*result = erx_prog_fd_write(fd, (const void *)args[1], (size_t)args[2]);
		return (true);
	case SYS_readv:
	case SYS_writev:
		*result = vector_call(fd, (const struct iovec *)args[1], (int)args[2], n == SYS_writev);
		return (true);
	case SYS_close:
		*result = erx_prog_fd_close(fd);
		return (true);
	case SYS_lseek:
		*result = erx_prog_fd_lseek(fd);
		return (true);
	case SYS_fstat:
		*result = erx_prog_fd_fstat(fd, (struct stat *)args[1]);
		return (true);
	case SYS_ioctl:
		*result = erx_prog_fd_ioctl(fd);
		return (true);
	case SYS_pread64:
	case SYS_pwrite64:
	case SYS_fcntl:
	case SYS_dup3:
		*result = held_or(fd, -ENOSYS);
		return (true);
	case SYS_munmap:
		*result = erx_prog_fd_munmap((uint64_t)args[0], (uint64_t)args[1]);
		return (true);
	case SYS_mmap:
		return (mmap_call(args, result));
	case SYS_ppoll:
		*result = ppoll_call((struct pollfd *)args[0], (unsigned long)args[1], (const struct timespec *)args[2],
		    args[3] != 0, (size_t)args[4]);
		return (true);
	case SYS_rt_sigaction:
		/* musl's switch hands the seam struct sigaction, not the kernel's layout (libc_start.h). */
		*result = erx_prog_sigaction((int)args[0], (const struct sigaction *)args[1], (struct sigaction *)args[2]);
		return (true);
	default:
		/* pselect6 and pipe2: the table offers neither. */
		*result = -ENOSYS;
		return (true);
	}
}

int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	erx_prog_enter(args);
	erx_fiasco_libc_start(liberx_program_main);
	return (ERX_FIASCO_TASK_STATUS_LIBC);
}
