/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The kernel's trace rings on the host (kernel/core/trace_rings.c, docs/design-fiasco.md,
 * "The kernel's trace rings"): a write reaches only its CPU's ring, a CPU past the rings
 * writes nothing, a ring wraps within itself, and the rings' pages hold the rings alone.
 * Prints "<mode>: ok" or the first broken property, and exits nonzero on one.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/trace_kernel.h"
#include "erx/core/trace_ring.h"

static erx_trace_record_t out[ERX_TRACE_READ_MAX];

static int
fail(const char *mode, const char *what)
{
	printf("%s: %s\n", mode, what);
	return (1);
}

/* An entry whose cpu is not its ring's: the ring writes its own CPU in its place. */
static erx_trace_entry_t
entry_for(uint32_t cpu, uint64_t n)
{
	return ((erx_trace_entry_t){ .time_ns = n, .event = ERX_TRACE_EVENT_SWITCH, .cpu = (uint16_t)(cpu + 1),
	    .thread = n + 1, .space = 2, .arg = { n, cpu, 0 } });
}

/* The ring as the root sees it: the stride of erx_trace_ring_t from the rings' first page. */
static const erx_trace_ring_t *
ring_at(uint32_t cpu)
{
	size_t bytes;

	return ((const erx_trace_ring_t *)erx_trace_kernel_pages(&bytes) + cpu);
}

static uint64_t
head_of(uint32_t cpu)
{
	erx_trace_read_result_t result;

	if (erx_trace_ring_read(ring_at(cpu), UINT64_MAX, out, 1, &result) != ERX_OK)
		return (UINT64_MAX);
	return (result.next);
}

/* The pages past the last ring: nothing a write does lands there. */
static int
padding_zero(const char *mode)
{
	size_t bytes;
	const uint8_t *pages = erx_trace_kernel_pages(&bytes);

	for (size_t at = sizeof(erx_trace_ring_t) * ERX_TRACE_KERNEL_RINGS; at < bytes; at++)
		if (pages[at] != 0)
			return (fail(mode, "a write landed outside the rings"));
	return (0);
}

/* One record on each CPU's ring, and CPU numbers past the rings: each ring holds its own. */
static int
mode_cpus(void)
{
	erx_trace_read_result_t result;
	erx_trace_entry_t entry;

	for (uint32_t cpu = 0; cpu < ERX_TRACE_KERNEL_RINGS + 3; cpu++) {
		entry = entry_for(cpu, 100 + cpu);
		erx_trace_kernel_put(cpu, &entry);
	}
	for (uint32_t cpu = 0; cpu < ERX_TRACE_KERNEL_RINGS; cpu++) {
		if (head_of(cpu) != 1)
			return (fail("cpus", "a ring does not hold exactly its CPU's one record"));
		if (erx_trace_ring_read(ring_at(cpu), 0, out, 4, &result) != ERX_OK || result.kept != 1)
			return (fail("cpus", "a ring's record was not kept"));
		if (out[0].cpu != cpu || out[0].arg[0] != 100 + cpu)
			return (fail("cpus", "a ring holds another CPU's record"));
	}
	return (padding_zero("cpus"));
}

/* A full ring and one more on CPU 0: it wraps within itself and CPU 1's ring stays empty. */
static int
mode_wrap(void)
{
	const uint64_t total = ERX_TRACE_RING_RECORDS + 5;
	erx_trace_read_result_t result;
	erx_trace_entry_t entry;

	for (uint64_t n = 0; n < total; n++) {
		entry = entry_for(0, n);
		erx_trace_kernel_put(0, &entry);
	}
	if (head_of(0) != total)
		return (fail("wrap", "CPU 0's head is not the count written"));
	for (uint32_t cpu = 1; cpu < ERX_TRACE_KERNEL_RINGS; cpu++)
		if (head_of(cpu) != 0)
			return (fail("wrap", "another CPU's ring was written"));
	if (erx_trace_ring_read(ring_at(0), 0, out, 8, &result) != ERX_OK)
		return (fail("wrap", "the read was refused"));
	if (result.overwritten != 5 || result.kept != 8 || out[0].arg[0] != 5)
		return (fail("wrap", "the oldest kept record is not the first not overwritten"));
	if (erx_trace_ring_read(ring_at(0), total - 2, out, 8, &result) != ERX_OK ||
	    result.kept != 2 || out[1].arg[0] != total - 1)
		return (fail("wrap", "the newest record is not the last written"));
	return (0);
}

/* The rings' pages: page-aligned, whole pages, every ring inside them. */
static int
mode_pages(void)
{
	size_t bytes;
	const void *pages = erx_trace_kernel_pages(&bytes);

	if ((uintptr_t)pages % ERX_PAGE_SIZE != 0 || bytes % ERX_PAGE_SIZE != 0)
		return (fail("pages", "the rings are not whole pages"));
	if (bytes < sizeof(erx_trace_ring_t) * ERX_TRACE_KERNEL_RINGS ||
	    bytes >= sizeof(erx_trace_ring_t) * ERX_TRACE_KERNEL_RINGS + ERX_PAGE_SIZE)
		return (fail("pages", "the pages are not the rings rounded up to a page"));
	return (0);
}

int
main(int argc, char **argv)
{
	static const struct {
		const char	*name;
		int		(*run)(void);
	} modes[] = { { "cpus", mode_cpus }, { "wrap", mode_wrap }, { "pages", mode_pages } };

	if (argc != 2)
		return (2);
	for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
		if (strcmp(argv[1], modes[i].name) != 0)
			continue;
		if (modes[i].run() != 0)
			return (1);
		printf("%s: ok\n", modes[i].name);
		return (0);
	}
	return (2);
}
