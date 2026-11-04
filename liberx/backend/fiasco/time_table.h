/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_TIME_TABLE_H
#define ERX_FIASCO_TIME_TABLE_H

#include <stdint.h>

/*
 * The arithmetic of the time page and of deadlines (docs/design-stopgap.md,
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
 * the caller waits again. A deadline already passed is 0.
 */
uint64_t	erx_fiasco_time_wait_us(uint64_t now_ns, uint64_t deadline_ns, uint64_t max_us);

#endif /* ERX_FIASCO_TIME_TABLE_H */
