/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_THREAD_H
#define ERX_FIASCO_THREAD_H

#include <stdatomic.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "liberx/backend/fiasco/service_wire.h"
#include "liberx/backend/fiasco/umtx_table.h"

/*
 * The thread table and the thread calls (docs/design-stopgap.md, "Thread
 * creation"). These calls serve the root's own threads: "the task" below is the root.
 */

/* What erx_thread_create reads from the head of the caller's public UTCB's mr. */
typedef struct erx_fiasco_start {
	erx_regs_t	regs;
	uint64_t	tls;
} erx_fiasco_start_t;

/* One thread's 2 KiB, in a table at a constant address. */
typedef struct erx_fiasco_thread_record {
	erx_utcb_t		utcb;	/* the public UTCB, first */
	erx_fiasco_start_t	start;
	_Atomic uint32_t	used;	/* claimed under the thread lock; cleared after the service's reply */
	uint32_t		index;
	uint64_t		semaphore;	/* the capability, from the create's reply */
	erx_fiasco_umtx_node_t	node;
} erx_fiasco_thread_record_t;

/* The calling thread's record, through its native UTCB's first user word. */
erx_fiasco_thread_record_t *erx_fiasco_thread_self(void);
erx_fiasco_thread_record_t *erx_fiasco_thread_record(uint32_t);
/* The calling thread's public UTCB: the start of its record. */
erx_utcb_t *erx_utcb_self(void);

/* The first thread's half of the table: its pages, slots, record and semaphore. */
const char	*erx_fiasco_thread_table_init(void);

/*
 * Where each index's native UTCB is in the table's area, and its capabilities in
 * the root. Index 0, the first thread, has the kernel-given UTCB instead, which is
 * why a claim starts at 1.
 */
uint64_t	erx_fiasco_thread_native_slot(uint32_t);
uint64_t	erx_fiasco_thread_semaphore_cap(uint32_t);
uint64_t	erx_fiasco_thread_cap(uint32_t);

/* The trampoline's entry, and the thread pointer as the caller's thread holds it. */
void		erx_fiasco_thread_trampoline(void);
uint64_t	erx_fiasco_thread_pointer(void);

/*
 * The starting registers are in the caller's public UTCB. space 0 is the caller's
 * own task, the only one there is; budget, group and thread_class are ignored.
 * No free index is ERX_ENOMEM. *thread is the handle.
 */
int	erx_thread_create(uint64_t budget, uint64_t space, uint64_t group, uint64_t thread_class,
	    uint64_t *thread) ERX_WARN_UNUSED_RESULT;
/* Starting a thread twice, or a handle that names none, is ERX_EINVAL. */
int	erx_thread_start(uint64_t thread) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_THREAD_H */
