/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_LOCK_H
#define ERX_FIASCO_LOCK_H

#include <stdatomic.h>
#include <stdint.h>

#include <l4/sys/ipc.h>
#include <l4/sys/thread.h>

/*
 * A backend lock (docs/design-stopgap.md, "Locks"): a spinlock whose failed
 * attempt yields. None is held across a kernel call or a request, and no thread
 * holds two, so a holder always comes back.
 */
typedef _Atomic uint32_t erx_fiasco_lock_t;

static inline void
erx_fiasco_lock(erx_fiasco_lock_t *lock)
{
	while (atomic_exchange_explicit(lock, 1, memory_order_acquire) != 0)
		(void)l4_thread_yield();
}

static inline void
erx_fiasco_unlock(erx_fiasco_lock_t *lock)
{
	atomic_store_explicit(lock, 0, memory_order_release);
}

#endif /* ERX_FIASCO_LOCK_H */
