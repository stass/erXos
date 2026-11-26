/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * map_trace's decision and the root's reader of its window on the host
 * (docs/design-fiasco.md, "The kernel's trace rings", "The root's window" and "Reading"):
 * kernel/core/trace_window.c maps only a well-formed window the rings fit in user space, once,
 * and liberx/backend/fiasco/trace_window.c reads only the root resource's CPU rings that were
 * mapped. Prints "<mode>: ok" or the first broken property, and exits nonzero on one.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/trace_ring.h"
#include "erx/core/trace_window.h"
#include "liberx/backend/fiasco/trace_window.h"

/* The QEMU virt kernel's figures: a 39-bit user space and 8 rings of 513 pages. */
#define USER_LAST	((UINT64_C(1) << 39) - 1)
#define RINGS_BYTES	(UINT64_C(513) << 12)

static const erx_trace_window_limits_t limits = { .user_last = USER_LAST, .page_order = 12,
    .rings_bytes = RINGS_BYTES };

/* Rings that fill a window of order 22 exactly. */
static const erx_trace_window_limits_t exact = { .user_last = USER_LAST, .page_order = 12,
    .rings_bytes = UINT64_C(1) << 22 };

static erx_trace_ring_t rings[2];
static erx_trace_record_t out[ERX_TRACE_READ_MAX];

static int
fail(const char *mode, const char *what)
{
	printf("%s: %s\n", mode, what);
	return (1);
}

/* The root's own call: two words, a read-only flexpage at its window. */
static erx_trace_window_call_t
root_call(void)
{
	return ((erx_trace_window_call_t){ .words = ERX_FIASCO_PFC_MAP_TRACE_WORDS, .mempage = true,
	    .base = ERX_FIASCO_TRACE_WINDOW, .order = ERX_FIASCO_TRACE_WINDOW_ORDER });
}

static erx_trace_window_verdict_t
decide(erx_trace_window_call_t call)
{
	return (erx_fiasco_trace_window(&call, &limits).verdict);
}

static int
window(void)
{
	erx_trace_window_call_t call = root_call();
	erx_trace_window_t decided = erx_fiasco_trace_window(&call, &limits);

	if (decided.verdict != ERX_TRACE_WINDOW_MAP || decided.base != ERX_FIASCO_TRACE_WINDOW ||
	    decided.bytes != RINGS_BYTES)
		return (fail("window", "the root's window was not mapped with the rings' pages alone"));
	call.mapped = true;
	if (decide(call) != ERX_TRACE_WINDOW_MAPPED)
		return (fail("window", "a second call was not refused as mapped"));
	call = root_call();
	call.order = 22;
	call.base = UINT64_C(0x400000);
	if (decide(call) != ERX_TRACE_WINDOW_MAP)
		return (fail("window", "the smallest window the rings fit was refused"));
	call.order = 21;
	call.base = UINT64_C(0x200000);
	if (decide(call) != ERX_TRACE_WINDOW_INVALID)
		return (fail("window", "a window smaller than the rings was accepted"));
	call.order = 22;
	call.base = UINT64_C(0x400000);
	if (erx_fiasco_trace_window(&call, &exact).verdict != ERX_TRACE_WINDOW_MAP)
		return (fail("window", "a window exactly the rings' size was refused"));
	return (0);
}

static int
refusals(void)
{
	erx_trace_window_call_t call;
	static const uint32_t words[] = { 0, 1, 3, 64 };

	for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
		call = root_call();
		call.words = words[i];
		if (decide(call) != ERX_TRACE_WINDOW_INVALID)
			return (fail("refusals", "a call of the wrong word count was accepted"));
	}
	call = root_call();
	call.mempage = false;
	if (decide(call) != ERX_TRACE_WINDOW_INVALID)
		return (fail("refusals", "a window that is no memory flexpage was accepted"));
	call = root_call();
	call.base += UINT64_C(1) << 12;
	if (decide(call) != ERX_TRACE_WINDOW_INVALID)
		return (fail("refusals", "a window not aligned to its size was accepted"));
	call = root_call();
	call.order = 64;
	call.base = 0;
	if (decide(call) != ERX_TRACE_WINDOW_INVALID)
		return (fail("refusals", "a window of order 64 was accepted"));
	call.order = 11;
	if (decide(call) != ERX_TRACE_WINDOW_INVALID)
		return (fail("refusals", "a window under a page was accepted"));
	call = root_call();
	call.base = (USER_LAST + 1) - (UINT64_C(1) << 25);
	if (decide(call) != ERX_TRACE_WINDOW_MAP)
		return (fail("refusals", "the last window of user space was refused"));
	call.base = USER_LAST + 1;
	if (decide(call) != ERX_TRACE_WINDOW_INVALID)
		return (fail("refusals", "a window past user space was accepted"));
	call.order = 40;
	call.base = 0;
	if (decide(call) != ERX_TRACE_WINDOW_INVALID)
		return (fail("refusals", "a window larger than user space was accepted"));
	return (0);
}

static int
reader(void)
{
	erx_trace_read_result_t result;
	const erx_trace_entry_t entry = { .event = ERX_TRACE_EVENT_SWITCH, .thread = 7, .arg = { 9, 0, 0 } };

	erx_trace_ring_clear(&rings[0]);
	erx_trace_ring_clear(&rings[1]);
	(void)erx_trace_ring_put(&rings[1], &entry);
	if (erx_fiasco_trace_window_read(rings, 2, 0, 1, 0, out, 4, &result) != ERX_ERIGHTS ||
	    erx_fiasco_trace_window_read(rings, 2, ERX_ROOT_SLOT_ROOT_RESOURCE + 1, 1, 0, out, 4, &result) != ERX_ERIGHTS)
		return (fail("reader", "a resource other than the root resource was accepted"));
	if (erx_fiasco_trace_window_read(rings, 0, ERX_ROOT_SLOT_ROOT_RESOURCE, 0, 0, out, 4, &result) != ERX_ENOTSUP)
		return (fail("reader", "a boot with no rings mapped did not answer ERX_ENOTSUP"));
	if (erx_fiasco_trace_window_read(rings, 1, ERX_ROOT_SLOT_ROOT_RESOURCE, 1, 0, out, 4, &result) != ERX_EINVAL)
		return (fail("reader", "a CPU past the rings mapped was accepted"));
	memset(out, 0, sizeof(out));
	if (erx_fiasco_trace_window_read(rings, 2, ERX_ROOT_SLOT_ROOT_RESOURCE, 1, 0, out, 4, &result) != ERX_OK ||
	    result.kept != 1 || result.next != 1 || out[0].event != ERX_TRACE_EVENT_SWITCH || out[0].thread != 7 ||
	    out[0].arg[0] != 9)
		return (fail("reader", "the CPU's ring was not read through the window"));
	return (0);
}

int
main(int argc, char **argv)
{
	if (argc != 2)
		return (fail("usage", "trace_window_driver window|refusals|reader"));
	if (strcmp(argv[1], "window") == 0 && window() == 0)
		return (printf("window: ok\n") < 0);
	if (strcmp(argv[1], "refusals") == 0 && refusals() == 0)
		return (printf("refusals: ok\n") < 0);
	if (strcmp(argv[1], "reader") == 0 && reader() == 0)
		return (printf("reader: ok\n") < 0);
	return (1);
}
