/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Every system call site in musl lands in one function, src/internal/erxos/syscall.c.
 * No trap instruction is left: only liberx reaches the kernel.
 */
#define __SYSCALL_LL_E(x) (x)
#define __SYSCALL_LL_O(x) (x)

hidden long __erx_syscall(long, long, long, long, long, long, long);

static inline long __syscall0(long n)
{
	return __erx_syscall(n, 0, 0, 0, 0, 0, 0);
}

static inline long __syscall1(long n, long a)
{
	return __erx_syscall(n, a, 0, 0, 0, 0, 0);
}

static inline long __syscall2(long n, long a, long b)
{
	return __erx_syscall(n, a, b, 0, 0, 0, 0);
}

static inline long __syscall3(long n, long a, long b, long c)
{
	return __erx_syscall(n, a, b, c, 0, 0, 0);
}

static inline long __syscall4(long n, long a, long b, long c, long d)
{
	return __erx_syscall(n, a, b, c, d, 0, 0);
}

static inline long __syscall5(long n, long a, long b, long c, long d, long e)
{
	return __erx_syscall(n, a, b, c, d, e, 0);
}

static inline long __syscall6(long n, long a, long b, long c, long d, long e, long f)
{
	return __erx_syscall(n, a, b, c, d, e, f);
}

#define IPC_64 0
