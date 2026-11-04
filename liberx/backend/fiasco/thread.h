/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_THREAD_H
#define ERX_FIASCO_THREAD_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "liberx/backend/core/park_table.h"
#include "liberx/backend/fiasco/service_wire.h"
#include "liberx/backend/fiasco/umtx_table.h"

/*
 * The thread table and the thread calls (docs/design-stopgap.md, "Thread
 * creation"). "The task" below is the caller's.
 */

/* What erx_thread_create reads from the head of the caller's public UTCB's mr. */
typedef struct erx_fiasco_start {
	erx_regs_t	regs;
	uint64_t	tls;
} erx_fiasco_start_t;

/*
 * A record's life. CLAIMED is a create in flight, whose kernel objects may not exist
 * yet. Only a start moves CREATED to STARTED, so a start of any other handle touches
 * nothing, the marker least of all: the kernel may already have cleared it, and a
 * stale 1 there would lose the index for good.
 */
typedef enum erx_fiasco_thread_state {
	ERX_FIASCO_THREAD_FREE = 0,
	ERX_FIASCO_THREAD_CLAIMED,
	ERX_FIASCO_THREAD_CREATED,
	ERX_FIASCO_THREAD_STARTED
} erx_fiasco_thread_state_t;

/* One thread's 2 KiB, in a table at a constant address. */
typedef struct erx_fiasco_thread_record {
	erx_utcb_t		utcb;	/* the public UTCB, first */
	erx_fiasco_start_t	start;
	_Atomic uint32_t	used;	/* an erx_fiasco_thread_state_t: claimed under the thread lock */
	uint32_t		index;
	uint64_t		semaphore;	/* the capability, from the create's reply */
	erx_fiasco_umtx_node_t	node;
	uint32_t		executor_slot;	/* its slot in the group, or ERX_BACKEND_PARK_NO_SLOT for a worker */
	uint64_t		clear_word;	/* the reaper stores 0 here and wakes it; 0 for none */
	uint64_t		release_base;	/* a detached thread's range, for the reaper to release */
	uint64_t		release_size;
	struct erx_fiasco_thread_record *reap_next;	/* the reaper's list, under the thread lock */
} erx_fiasco_thread_record_t;

/* The calling thread's record, through its native UTCB's first user word. */
erx_fiasco_thread_record_t *erx_fiasco_thread_self(void);
erx_fiasco_thread_record_t *erx_fiasco_thread_record(uint32_t);
/* The calling thread's public UTCB: the start of its record. */
erx_utcb_t *erx_utcb_self(void);

/* The order of the area holding a task's 128 native UTCB slots. */
#define ERX_FIASCO_UTCB_AREA_ORDER	17u
/* The task's part of another task's thread handle: a task's own handles are indices. */
#define ERX_FIASCO_HANDLE_TASK_SHIFT	8u

/* The first thread's own record, once its table's pages and its semaphore exist. */
void		erx_fiasco_thread_first_init(void);

/* Starts the reaper, on the first thread once the service runs. Returns NULL, or why not. */
const char	*erx_fiasco_reaper_start(void);

/*
 * Blocks on a thread's semaphore until an up or the deadline, returning false at
 * the deadline, never before it. Every other IPC error waits again.
 */
bool		erx_fiasco_semaphore_down(uint64_t semaphore, uint64_t deadline);

#ifdef ERX_FIASCO_TEST_HOOKS
/* A semaphore's up, and an IPC receive wait of the given length with nothing to receive. */
void		erx_fiasco_test_semaphore_up(uint64_t);
void		erx_fiasco_test_ipc_sleep_us(uint64_t);
#endif

/*
 * Where each index's native UTCB is in the table's area, and its capabilities in
 * the root. Index 0, the first thread, has the kernel-given UTCB instead, which is
 * why a claim starts at 1.
 */
uint64_t	erx_fiasco_thread_native_slot(uint32_t);
uint64_t	erx_fiasco_thread_semaphore_cap(uint32_t);
uint64_t	erx_fiasco_thread_cap(uint32_t);

/*
 * The root's capability slots past both per-thread runs, as indexes for
 * erx_fiasco_thread_cap. One list, so that no two users can pick the same slot.
 */
enum {
	ERX_FIASCO_SLOT_SERVICE_GATE = ERX_FIASCO_THREADS_MAX,
	ERX_FIASCO_SLOT_SERVICE_THREAD,
	ERX_FIASCO_SLOT_WATCHDOG,
	/* One slot for each IRQ object. */
	ERX_FIASCO_SLOT_IRQS,
	/* Each task's run of slots: service_task.c divides them. */
	ERX_FIASCO_SLOT_TASK_RUNS = ERX_FIASCO_SLOT_IRQS + ERX_BACKEND_PARK_OBJECTS_MAX
};

/* The first thread's kernel-given UTCB: its page holds the service's and the watchdog's too. */
void		*erx_fiasco_thread_first_utcb(void);

/* The trampoline's entry, and the thread pointer as the caller's thread holds it. */
void		erx_fiasco_thread_trampoline(void);
uint64_t	erx_fiasco_thread_pointer(void);

/*
 * The starting registers are in the caller's public UTCB. space 0 is the caller's
 * own task; the root may also name a task with no thread yet, whose first thread this
 * makes. budget and group are ignored, and an executor takes a slot in the task's one
 * group, or ERX_ENOMEM.
 * No free index is ERX_ENOMEM. *thread is the handle.
 */
int	erx_thread_create(uint64_t budget, uint64_t space, uint64_t group, uint64_t thread_class,
	    uint64_t *thread) ERX_WARN_UNUSED_RESULT;
/* Starting a thread twice, or a handle that names none, is ERX_EINVAL. */
int	erx_thread_start(uint64_t thread) ERX_WARN_UNUSED_RESULT;

/*
 * Runs the thread on one CPU of mask, from its start if it has not started: its
 * own if the mask holds it, as Fiasco chooses (scheduler.cpp:98-103). An empty mask,
 * one that names no CPU, or a handle that names no thread is ERX_EINVAL.
 */
int	erx_thread_set_affinity(uint64_t thread, uint64_t mask) ERX_WARN_UNUSED_RESULT;

/*
 * The word the reaper clears and wakes once this thread can no longer run: musl's
 * SYS_set_tid_address names the caller's own handle, its __clone a new thread's.
 * A handle that names no thread is ERX_EINVAL.
 */
int	erx_fiasco_thread_set_clear_word(uint64_t thread, uint64_t word) ERX_WARN_UNUSED_RESULT;

/* Gives the CPU to the next thread of the caller's priority on it, if any. */
void	erx_yield(void);

/* Hands the calling thread to the reaper and never returns. */
_Noreturn void	erx_thread_exit(void);
/* The same for a detached thread, whose stack is this range. */
_Noreturn void	erx_thread_exit_release(uint64_t base, uint64_t size);

#endif /* ERX_FIASCO_THREAD_H */
