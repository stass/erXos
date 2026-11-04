/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * musl's one way to the kernel on erXos (docs/design-stopgap.md, "musl over the
 * backend"). Each offered call is a few lines onto liberx, and __erx_syscall at the
 * end names each call's arguments. Everything else is refused with ENOSYS, which a
 * caller checking for failure sees as a kernel that lacks the call.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <time.h>

#include "futex.h"
#include "pthread_impl.h"
#include "syscall.h"

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"
#include "liberx/backend/fiasco/vm.h"

#define NS_PER_SEC	INT64_C(1000000000)
#define PAGE_MASK	((uint64_t)ERX_PAGE_SIZE - 1)

static long
errno_of(int status)
{
	switch (status) {
	case ERX_OK:
		return (0);
	case ERX_EINVAL:
		return (-EINVAL);
	case ERX_ENOMEM:
	case ERX_ERANGE:
	case ERX_ELIMIT:
		return (-ENOMEM);
	case ERX_ETIMEDOUT:
		return (-ETIMEDOUT);
	case ERX_EBUSY:
		return (-EBUSY);
	case ERX_ERIGHTS:
		return (-EACCES);
	case ERX_EFAULT:
		return (-EFAULT);
	case ERX_EINTR:
		return (-EINTR);
	default:
		return (-ENOSYS);
	}
}

/* A wait given as a length, as umtx's absolute deadline. The wait is valid: see wait_valid. */
static uint64_t
deadline_after(const struct timespec *wait)
{
	/* A wait past what 64 bits of nanoseconds hold is a wait forever. */
	if ((uint64_t)wait->tv_sec > ERX_FIASCO_UMTX_FOREVER / (uint64_t)NS_PER_SEC / 2)
		return (ERX_FIASCO_UMTX_FOREVER);
	return (erx_fiasco_clock_ns() + (uint64_t)wait->tv_sec * (uint64_t)NS_PER_SEC + (uint64_t)wait->tv_nsec);
}

static int
wait_valid(const struct timespec *wait)
{
	return (wait->tv_sec >= 0 && wait->tv_nsec >= 0 && wait->tv_nsec < NS_PER_SEC);
}

static long
futex_call(volatile int *word, int op, int value, const struct timespec *timeout)
{
	switch (op & ~FUTEX_PRIVATE) {
	case FUTEX_WAIT:
		if (timeout != NULL && !wait_valid(timeout))
			return (-EINVAL);
		return (errno_of(erx_umtx_wait((uint64_t)(uintptr_t)word, (uint32_t)value,
		    timeout == NULL ? ERX_FIASCO_UMTX_FOREVER : deadline_after(timeout))));
	case FUTEX_WAKE:
		return (erx_umtx_wake((uint64_t)(uintptr_t)word, (uint32_t)value));
	default:
		return (-ENOSYS);
	}
}

static uint32_t
prot_of(int prot)
{
	if (prot & PROT_WRITE)
		return (ERX_PROT_RW);
	if (prot & PROT_EXEC)
		return (ERX_PROT_RX);
	return (prot & PROT_READ ? ERX_PROT_R : ERX_PROT_NONE);
}

static int
prot_allowed(int prot)
{
	return (!((prot & PROT_WRITE) && (prot & PROT_EXEC)));
}

/* The protect call commits an uncommitted page it makes accessible, so nothing commits first. */
static long
mprotect_call(uint64_t addr, uint64_t size, int prot)
{
	if (!prot_allowed(prot))
		return (-EACCES);
	if (size == 0)
		return (0);
	return (errno_of(erx_space_protect(addr, size, prot_of(prot))));
}

/*
 * What a mapping's flags may say. One space has no other party, so shared and private
 * look the same, and the two hints are taken and do nothing. A flag not listed is
 * refused, so a caller that asked for what this seam does not do learns so.
 */
#define MMAP_FLAGS_OFFERED	(MAP_SHARED | MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE | MAP_STACK)

/* Only anonymous memory is offered: a file mapping needs the personality's files. */
static long
mmap_call(uint64_t addr, uint64_t size, int prot, int flags)
{
	uint64_t base;
	long error;

	if (!(flags & MAP_ANONYMOUS))
		return (-ENOSYS);
	if ((flags & MAP_TYPE) == 0)
		return (-EINVAL);
	if (flags & ~MMAP_FLAGS_OFFERED)
		return (-EOPNOTSUPP);
	if (!prot_allowed(prot))
		return (-EACCES);
	if (size == 0 || size > UINT64_MAX - PAGE_MASK)
		return (-EINVAL);
	size = (size + PAGE_MASK) & ~PAGE_MASK;
	error = errno_of(erx_vm_reserve(addr, size, flags & MAP_FIXED ? ERX_VM_FIXED : 0, &base));
	if (error != 0)
		return (error);
	if (prot != PROT_NONE) {
		error = mprotect_call(base, size, prot);
		if (error != 0) {
			(void)erx_vm_release(base, size);
			return (error);
		}
	}
	return ((long)base);
}

static long
munmap_call(uint64_t addr, uint64_t size)
{
	if (size == 0 || size > UINT64_MAX - PAGE_MASK)
		return (-EINVAL);
	return (errno_of(erx_vm_release(addr, (size + PAGE_MASK) & ~PAGE_MASK)));
}

static long
console_write(int fd, const void *bytes, size_t length)
{
	if (fd != 1 && fd != 2)
		return (-EBADF);
	erx_fiasco_console_write(bytes, length);
	return ((long)length);
}

static long
console_writev(int fd, const struct iovec *vector, int count)
{
	long total = 0;

	if (fd != 1 && fd != 2)
		return (-EBADF);
	if (count < 0 || count > IOV_MAX)
		return (-EINVAL);
	for (int index = 0; index < count; index++)
		total += console_write(fd, vector[index].iov_base, vector[index].iov_len);
	return (total);
}

/* stdio asks this of a stream to learn it is a terminal, which keeps it line buffered. */
static long
ioctl_call(int fd, int request, struct winsize *size)
{
	if (request != TIOCGWINSZ || (fd != 1 && fd != 2))
		return (-ENOSYS);
	bzero(size, sizeof(*size));
	return (0);
}

/*
 * The one clock runs from boot. CLOCK_REALTIME reads it too: Phase 1 has no wall
 * clock, and what a timed wait needs is a clock that advances.
 */
static int
clock_offered(clockid_t clock)
{
	return (clock == CLOCK_REALTIME || clock == CLOCK_MONOTONIC);
}

static long
clock_gettime_call(clockid_t clock, struct timespec *time)
{
	uint64_t now;

	if (!clock_offered(clock))
		return (-EINVAL);
	now = erx_fiasco_clock_ns();
	time->tv_sec = (time_t)(now / (uint64_t)NS_PER_SEC);
	time->tv_nsec = (long)(now % (uint64_t)NS_PER_SEC);
	return (0);
}

/* A sleep is a timed wait on a word nothing wakes. */
static long
sleep_call(const struct timespec *wait)
{
	uint32_t word = 0;
	uint64_t deadline;
	int status;

	if (!wait_valid(wait))
		return (-EINVAL);
	deadline = deadline_after(wait);
	do {
		status = erx_umtx_wait((uint64_t)(uintptr_t)&word, 0, deadline);
	} while (status == ERX_OK);
	return (status == ERX_ETIMEDOUT ? 0 : errno_of(status));
}

static long
clock_nanosleep_call(clockid_t clock, int flags, const struct timespec *wait)
{
	if (!clock_offered(clock) || flags != 0)
		return (-ENOSYS);
	return (sleep_call(wait));
}

/* A thread's identifier is its index plus one, and a program's own handle is the index. */
static long
tid_set_address(uint64_t word)
{
	const uint32_t index = erx_fiasco_thread_self()->index;
	const int status = erx_fiasco_thread_set_clear_word(index, word);

	return (status == ERX_OK ? (long)index + 1 : errno_of(status));
}

static long
set_affinity(long tid, size_t size, const unsigned long *mask)
{
	if (size < sizeof(unsigned long))
		return (-EINVAL);
	return (errno_of(erx_thread_set_affinity(tid == 0 ? erx_fiasco_thread_self()->index : (uint64_t)tid - 1, mask[0])));
}

/*
 * pthread_cancel sets the target's flag and then sends this signal to break it out
 * of a call. No signal is delivered, so the flag alone stands, and it acts at the
 * target's next cancellation point.
 */
static long
tkill_call(int signal)
{
	return (signal == SIGCANCEL ? 0 : -ENOSYS);
}

/* No signal is ever delivered, so every mask reads as empty. */
static long
sigprocmask_call(sigset_t *old, size_t size)
{
	if (size != _NSIG / 8)
		return (-EINVAL);
	if (old != NULL)
		bzero(old, size);
	return (0);
}

/* The program is the machine's one process, and it has no users to tell apart. */
#define ROOT_PID	1
#define ROOT_PARENT	0
#define ROOT_USER	0
#define EXIT_STATUS_MASK	0xff

long
__erx_syscall(long n, long a, long b, long c, long d, long e, long f)
{
	/* Only mmap passes these two, its descriptor and offset, and only anonymous memory is offered. */
	(void)e;
	(void)f;
	switch (n) {
	case SYS_futex:
		return (futex_call((volatile int *)a, (int)b, (int)c, (const struct timespec *)d));
	case SYS_mmap:
		return (mmap_call((uint64_t)a, (uint64_t)b, (int)c, (int)d));
	case SYS_munmap:
		return (munmap_call((uint64_t)a, (uint64_t)b));
	case SYS_mprotect:
		return (mprotect_call((uint64_t)a, (uint64_t)b, (int)c));
	case SYS_brk:
		/* What a kernel with no room says: mallocng then uses mmap alone. */
		return (0);
	case SYS_write:
		return (console_write((int)a, (const void *)b, (size_t)c));
	case SYS_writev:
		return (console_writev((int)a, (const struct iovec *)b, (int)c));
	case SYS_ioctl:
		return (ioctl_call((int)a, (int)b, (struct winsize *)c));
	case SYS_clock_gettime:
		return (clock_gettime_call((clockid_t)a, (struct timespec *)b));
	case SYS_clock_nanosleep:
		return (clock_nanosleep_call((clockid_t)a, (int)b, (const struct timespec *)c));
	case SYS_nanosleep:
		return (sleep_call((const struct timespec *)a));
	case SYS_set_tid_address:
		return (tid_set_address((uint64_t)a));
	case SYS_gettid:
		return ((long)erx_fiasco_thread_self()->index + 1);
	case SYS_getpid:
		return (ROOT_PID);
	case SYS_getppid:
		return (ROOT_PARENT);
	case SYS_getuid:
	case SYS_geteuid:
	case SYS_getgid:
	case SYS_getegid:
		return (ROOT_USER);
	case SYS_exit:
		erx_thread_exit();	/* does not return */
	case SYS_exit_group:
		/* Whoever started the program reads the status's low byte, as POSIX's parent does. */
		return (errno_of(erx_space_stop(ERX_CAP_SELF, a & EXIT_STATUS_MASK)));
	case SYS_sched_setaffinity:
		return (set_affinity(a, (size_t)b, (const unsigned long *)c));
	case SYS_sched_yield:
		erx_yield();
		return (0);
	case SYS_tkill:
		return (tkill_call((int)b));
	case SYS_rt_sigprocmask:
		return (sigprocmask_call((sigset_t *)c, (size_t)d));
	case SYS_set_robust_list:
		/* musl walks the list itself at thread exit; only a task's death needs a kernel's help. */
		return (0);
	default:
		return (-ENOSYS);
	}
}
