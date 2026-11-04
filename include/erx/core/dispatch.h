/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_DISPATCH_H
#define ERX_CORE_DISPATCH_H

/*
 * The one entry of a kernel call into the cores, as a kernel's trap handler
 * sees it (docs/design-kernel.md, "System-call dispatch"). The handler copies
 * the call number and the argument registers out of the trap frame, names the
 * caller, calls erx_dispatch once, and writes the result words back to the
 * registers ERX_TRAP_REG_RESULTS names.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/core/abi_trap.h"

/* The bytes of a space's opaque log rate state, which starts out zeroed. */
#define ERX_LOG_RATE_STATE_BYTES 24
#define ERX_LOG_RATE_STATE_ALIGN 8

/*
 * Who is calling. The trap handler fills this from its own records, never
 * from anything user mode wrote. utcb is the calling thread's UTCB through the
 * kernel's own mapping of it; user mode may rewrite that memory at any moment,
 * so the cores load each word once. log_rate is the calling space's state,
 * which stays the caller's for the call, and space its number. executor
 * says whether the calling thread is an executor, which the dispatch's
 * executor rule reads.
 */
typedef struct erx_sys_caller {
	const void	*utcb;
	void		*log_rate;
	uint64_t	 space;
	bool		 executor;
} erx_sys_caller_t;

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Decode, admit and run one call. results[0] is the status, zero-extended
 * from its 32 bits as the trap wrappers read it; the other words are the
 * call's results, and zero when it has none or fails, so nothing of the
 * kernel's reaches a result register. The arguments are a private snapshot,
 * and every value in them is untrusted.
 */
void erx_dispatch(const erx_sys_caller_t *caller, uint64_t number,
    const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT]);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_DISPATCH_H */
