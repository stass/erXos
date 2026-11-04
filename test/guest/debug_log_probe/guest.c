/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The debug-log probe as a guest program on the stopgap kernel: the root task,
 * freestanding, with the kernel's call as its only service. After the cases it
 * spins, and the harness ends the guest at the "probe end" line.
 */

#include <stddef.h>
#include <stdint.h>

#include "probe.h"

void *memcpy(void *, const void *, size_t);
void *memset(void *, int, size_t);
void erx_probe_main(void);

/* The compiler may call these for a structure copy or an initializer. */
void *
memcpy(void *target, const void *source, size_t length)
{
	volatile uint8_t *to = target;
	const uint8_t *from = source;

	while (length-- > 0)
		*to++ = *from++;
	return (target);
}

void *
memset(void *target, int value, size_t length)
{
	volatile uint8_t *to = target;

	while (length-- > 0)
		*to++ = (uint8_t)value;
	return (target);
}

void
erx_probe_pause(void)
{
	uint64_t frequency, start, now;

	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frequency));
	__asm__ volatile("mrs %0, cntvct_el0" : "=r"(start));
	do {
		__asm__ volatile("mrs %0, cntvct_el0" : "=r"(now));
	} while (now - start < frequency + frequency / 5);
}

void
erx_probe_main(void)
{
	erx_probe_run();
	for (;;)
		__asm__ volatile("yield");
}
