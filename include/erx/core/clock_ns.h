/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_CLOCK_NS_H
#define ERX_CORE_CLOCK_NS_H

/*
 * The counter's reading in nanoseconds: the one conversion the root's erx_clock_ns and the
 * kernel's trace rings both use, so their records merge on one clock
 * (docs/design-fiasco.md, "The kernel's trace rings"). Plain C17 and C++17, so Fiasco's
 * glue includes it. A frequency of zero, which no conforming hardware reports, reads as
 * time zero rather than as a division by zero. The split into whole seconds and the rest
 * keeps the product within 64 bits for any counter value.
 */

#include <stdint.h>

static inline uint64_t
erx_clock_ticks_ns(uint64_t ticks, uint64_t frequency)
{
	const uint64_t ns_per_second = UINT64_C(1000000000);

	if (frequency == 0)
		return (0);
	return (ticks / frequency * ns_per_second + ticks % frequency * ns_per_second / frequency);
}

#endif /* ERX_CORE_CLOCK_NS_H */
