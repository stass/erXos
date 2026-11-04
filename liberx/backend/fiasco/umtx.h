/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_UMTX_H
#define ERX_FIASCO_UMTX_H

#include <stdint.h>

/*
 * The calls of the call table's umtx row. deadline is absolute monotonic
 * nanoseconds, or ERX_FIASCO_UMTX_FOREVER. A bad address is a fault. Correct
 * within a task, and nothing shares a word between tasks.
 */
int	erx_umtx_wait(uint64_t addr, uint32_t expected, uint64_t deadline);
/* How many it woke. */
int	erx_umtx_wake(uint64_t addr, uint32_t count);

#ifdef ERX_FIASCO_TEST_HOOKS
#include <stdatomic.h>

/* See umtx.c: how the threads suite's waits came out. */
extern _Atomic uint64_t erx_fiasco_test_umtx_woken, erx_fiasco_test_umtx_timed_out, erx_fiasco_test_umtx_absorbed;
extern _Atomic uint64_t erx_fiasco_test_umtx_stale;
#endif

#endif /* ERX_FIASCO_UMTX_H */
