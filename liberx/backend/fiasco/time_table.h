/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_TIME_TABLE_H
#define ERX_FIASCO_TIME_TABLE_H

#include <stdbool.h>
#include <stdint.h>

/*
 * The arithmetic of the time page and of deadlines (docs/design-fiasco.md,
 * "Deadlines"): pure functions of their arguments, so the host tests them.
 */

typedef struct erx_fiasco_time_scale {
	uint64_t	mult;		/* ns = (counter * mult) >> shift, the product in 128 bits */
	uint32_t	shift;
} erx_fiasco_time_scale_t;

/*
 * The scale of a counter of this frequency. mult is rounded up at the largest shift
 * that keeps it in 64 bits. That gives the exact floor of counter * 10^9 / hz while
 * counter * (hz / gcd(hz, 10^9)) stays below 2^shift, which is years on the frequencies of
 * QEMU and the Raspberry Pi, and at most a nanosecond above it after that, so a wait is
 * never early. A frequency of zero, which no conforming hardware reports, scales every
 * counter to time zero.
 */
erx_fiasco_time_scale_t erx_fiasco_time_scale(uint64_t hz);

uint64_t	erx_fiasco_time_ns(uint64_t counter, erx_fiasco_time_scale_t scale);

/*
 * The whole microseconds a wait asks the kernel for, from now until a later
 * deadline: rounded up, so the wait never ends early, and at most max_us, past which
 * the caller waits again. A deadline under a microsecond away, or already passed, is
 * 0: the kernel is asked for nothing, since Fiasco's one-shot floor would stretch
 * such a wait to 200 us, and erx_fiasco_time_down spins out the rest. That
 * remainder is what a kernel timeout leaves, since Fiasco counts a relative timeout
 * from the microsecond its clock reads and may end it up to a microsecond early.
 */
uint64_t	erx_fiasco_time_wait_us(uint64_t now_ns, uint64_t deadline_ns, uint64_t max_us);

/*
 * The effects of a timed down: the counter's nanoseconds, and one down of the
 * semaphore that blocks at most timeout_us, where 0 is a try that does not block.
 * down returns true when it took the semaphore.
 */
typedef struct erx_fiasco_down_view {
	uint64_t	(*clock_ns)(void *);
	bool		(*down)(void *, uint64_t timeout_us);
} erx_fiasco_down_view_t;

/*
 * Takes the semaphore by deadline_ns: true when taken, false only after the clock
 * has read the deadline, so never early. Every attempt takes an up already posted,
 * the last one, made after that read, included. A remainder under a microsecond,
 * or a deadline already past, is tried without blocking, again until the clock
 * reads the deadline: for a max_us of at least 1, the spin is bounded by that
 * microsecond.
 */
bool		erx_fiasco_time_down(const erx_fiasco_down_view_t *, void *, uint64_t deadline_ns, uint64_t max_us);

#endif /* ERX_FIASCO_TIME_TABLE_H */
