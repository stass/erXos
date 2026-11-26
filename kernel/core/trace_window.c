/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * map_trace's decision (docs/design-fiasco.md, "The kernel's trace rings", "The root's
 * window"); erx/core/trace_window.h states the contract. Pure: it reads only its arguments.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/core/trace_window.h"

/* The window's size, when the call's words make a window the rings fit in user space. */
static bool
trace_window_fits(const erx_trace_window_call_t *call, const erx_trace_window_limits_t *limits)
{
	uint64_t last_offset;

	if (!call->mempage || call->order < limits->page_order || call->order >= 64)
		return (false);
	last_offset = (UINT64_C(1) << call->order) - 1;
	if ((call->base & last_offset) != 0 || last_offset > limits->user_last ||
	    call->base > limits->user_last - last_offset)
		return (false);
	return (limits->rings_bytes != 0 && limits->rings_bytes - 1 <= last_offset);
}

erx_trace_window_t
erx_fiasco_trace_window(const erx_trace_window_call_t *call, const erx_trace_window_limits_t *limits)
{
	if (call->mapped)
		return ((erx_trace_window_t){ .verdict = ERX_TRACE_WINDOW_MAPPED });
	if (call->words != ERX_FIASCO_PFC_MAP_TRACE_WORDS || !trace_window_fits(call, limits))
		return ((erx_trace_window_t){ .verdict = ERX_TRACE_WINDOW_INVALID });
	return ((erx_trace_window_t){ .verdict = ERX_TRACE_WINDOW_MAP, .base = call->base,
	    .bytes = limits->rings_bytes });
}
