/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_TRACE_WINDOW_H
#define ERX_CORE_TRACE_WINDOW_H

/*
 * map_trace, the operation the fork adds to Fiasco's platform control object
 * (docs/design-fiasco.md, "The kernel's trace rings", "The root's window"): the decision
 * whether a call maps the kernel's trace rings read-only into the caller's own space, as a
 * pure function over the call's words, so host tests and the fuzz target drive every
 * refusal. The glue (fiasco/kernel/src/erx/erx_trace.cpp) decodes the flexpage with
 * Fiasco's own type, asks here, and maps; the root (liberx/backend/fiasco/trace.c) makes
 * the call. Plain C17 and C++17, inside extern "C", with only <stdbool.h> and <stdint.h>.
 */

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The operation's number in the platform control protocol's first word, clear of
 * upstream's generic operations (0 to 2) and its architectures' (from 0x10).
 */
#define ERX_FIASCO_PFC_MAP_TRACE	0x100u
/* Its message: the operation, then the window as a flexpage word. */
#define ERX_FIASCO_PFC_MAP_TRACE_WORDS	2u

/* What the call carries, as the glue decoded it. */
typedef struct erx_trace_window_call {
	uint32_t	words;		/* the message's untyped words, the operation's included */
	bool		mempage;	/* the second word is a valid memory flexpage */
	uint64_t	base;		/* its first address */
	uint32_t	order;		/* log2 of its size in bytes */
	bool		mapped;		/* an earlier call of this boot mapped the rings, or is mapping them */
} erx_trace_window_call_t;

/* What the kernel holds. */
typedef struct erx_trace_window_limits {
	uint64_t	user_last;	/* the caller's last usable user address */
	uint32_t	page_order;	/* log2 of a page's size */
	uint64_t	rings_bytes;	/* the rings' pages, a whole number of pages */
} erx_trace_window_limits_t;

typedef enum erx_trace_window_verdict {
	ERX_TRACE_WINDOW_MAP,		/* map rings_bytes at base, read-only */
	ERX_TRACE_WINDOW_INVALID,	/* -L4_EINVAL: the message or the window is wrong */
	ERX_TRACE_WINDOW_MAPPED		/* -L4_EEXIST: the rings are mapped already */
} erx_trace_window_verdict_t;

typedef struct erx_trace_window {
	erx_trace_window_verdict_t	verdict;
	uint64_t			base;	/* where the rings go, for ERX_TRACE_WINDOW_MAP */
	uint64_t			bytes;	/* how much is mapped there: the rings' pages, never the window's rest */
} erx_trace_window_t;

/*
 * The decision. A call is refused as mapped once one has mapped; otherwise it maps only
 * when it has exactly ERX_FIASCO_PFC_MAP_TRACE_WORDS words and its window is a memory
 * flexpage of at least a page, aligned to its size, wholly in user space and at least as
 * large as the rings.
 */
erx_trace_window_t	erx_fiasco_trace_window(const erx_trace_window_call_t *call,
			    const erx_trace_window_limits_t *limits);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_TRACE_WINDOW_H */
