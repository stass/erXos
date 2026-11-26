/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * map_trace's decoding (kernel/core/trace_window.c, docs/design-fiasco.md, "The kernel's
 * trace rings", "The root's window"): whatever the call's words, flexpage and the kernel's
 * figures, the decision is one of its three verdicts, and a map names the call's own base, a
 * window of at least a page aligned to its size, wholly in user space, and maps the rings'
 * bytes alone, no more than the window holds. A call after a map is always refused.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "erx/core/trace_window.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static uint64_t
take(const uint8_t **data, size_t *length, size_t bytes)
{
	uint64_t value = 0;

	for (size_t i = 0; i < bytes && *length > 0; i++, (*data)++, (*length)--)
		value |= (uint64_t)**data << (8 * i);
	return (value);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t length)
{
	const uint64_t flags = take(&data, &length, 1);
	const erx_trace_window_call_t call = { .words = (uint32_t)take(&data, &length, 4), .mempage = (flags & 1) != 0,
	    .mapped = (flags & 2) != 0, .base = take(&data, &length, 8), .order = (uint32_t)take(&data, &length, 1) };
	const erx_trace_window_limits_t limits = { .user_last = take(&data, &length, 8), .page_order = 12,
	    .rings_bytes = take(&data, &length, 4) << 12 };
	const erx_trace_window_t decided = erx_fiasco_trace_window(&call, &limits);
	uint64_t last_offset;

	switch (decided.verdict) {
	case ERX_TRACE_WINDOW_MAPPED:
		if (!call.mapped)
			abort();
		return (0);
	case ERX_TRACE_WINDOW_INVALID:
		if (call.mapped)
			abort();
		return (0);
	case ERX_TRACE_WINDOW_MAP:
		break;
	default:
		abort();
	}
	if (call.mapped || call.words != ERX_FIASCO_PFC_MAP_TRACE_WORDS || !call.mempage || call.order < 12 ||
	    call.order > 63 || decided.base != call.base || decided.bytes != limits.rings_bytes || decided.bytes == 0)
		abort();
	last_offset = (UINT64_C(1) << call.order) - 1;
	if ((call.base & last_offset) != 0 || decided.bytes - 1 > last_offset || last_offset > limits.user_last ||
	    call.base > limits.user_last - last_offset)
		abort();
	return (0);
}
