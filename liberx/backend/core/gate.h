/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_GATE_H
#define ERX_BACKEND_GATE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "liberx/backend/core/grow_table.h"

/*
 * Fault gates' core (docs/design-stopgap.md, "Fault gates"), which both backends run.
 * A gate is a queue of records, each an erx_fault with its space's label, and the
 * one thread bound to it. It carries records and nothing else.
 *
 * Every queue entry lives in the record it stands for, which the caller owns: a
 * fault's in its space's fault entries, an exit's in its space's row. So posting
 * allocates nothing, and an entry is queued at one gate at most. Each gate keeps
 * its entries oldest first, and a thread's wait takes the oldest record of every
 * gate bound to it, by the order of posting.
 *
 * A thread is listed as waiting while it waits, which is what lets a post wake it.
 * A thread taken off the list by a post or a bind is owed exactly one up of its
 * semaphore, and only such a thread is, which is the umtx
 * table's invariant: a semaphore holds 0 whenever its thread enters a wait.
 *
 * It reads no clock and calls no kernel, so the host's tests run this same code.
 * The service-side steps run under the caller's serialisation (the Fiasco
 * service's one thread), and each returns the thread whose semaphore the
 * caller ups, or ERX_BACKEND_GATE_NO_THREAD; erx_backend_gate_wait is the waiting thread's side of the protocol.
 */

typedef struct erx_backend_gate erx_backend_gate_t;

/* A thread is named by the caller's own nonzero id below 2^32; 0 names none. */
#define ERX_BACKEND_GATE_NO_THREAD	UINT64_C(0)

typedef struct erx_backend_gate_entry erx_backend_gate_entry_t;
struct erx_backend_gate_entry {
	erx_backend_gate_entry_t *next;		/* towards the newest, while queued */
	erx_backend_gate_entry_t *prev;
	erx_backend_gate_t	*gate;		/* where it is queued, or NULL */
	uint64_t		 order;		/* when it was posted, among every gate's records */
	uint64_t		 label;		/* its space's label */
	erx_fault_t		 record;
};

struct erx_backend_gate {
	erx_backend_gate_entry_t  *head;	/* the oldest record */
	erx_backend_gate_entry_t  *tail;
	uint64_t		   thread;	/* the bound thread, or ERX_BACKEND_GATE_NO_THREAD */
	bool			   live;
};

/*
 * Every gate, by the index its creator gave it; the threads listed as waiting, one
 * bit each by id; and the order of the next post.
 */
typedef struct erx_backend_gates {
	erx_backend_grow_table_t table;		/* erx_backend_gate_t */
	erx_backend_grow_table_t listed;	/* uint64_t words */
	uint64_t		 posted;
} erx_backend_gates_t;

/* No gate and no thread listed; the tables' pages come from source. */
void	erx_backend_gates_init(erx_backend_gates_t *, const erx_backend_grow_pages_t *source);

/* An unbound gate at index, with an empty queue. ERX_ENOMEM when the table cannot grow to it. */
int	erx_backend_gate_open(erx_backend_gates_t *, uint32_t index) ERX_WARN_UNUSED_RESULT;

/* The live gate at index, or NULL. */
erx_backend_gate_t *erx_backend_gate_at(const erx_backend_gates_t *, uint32_t index);

/*
 * A gate's end: its queue is dropped, each entry left unqueued, and it is unbound.
 * Who names it as a fault gate is the caller's to clear.
 */
void	erx_backend_gate_close(erx_backend_gates_t *, uint32_t index);

/*
 * Binds the gate to thread, replacing the thread bound before, or unbinds it for
 * ERX_BACKEND_GATE_NO_THREAD. A listed thread that the bind gives a record to wait for is taken off the
 * list and returned, to be upped.
 */
uint64_t	erx_backend_gate_bind(erx_backend_gates_t *, erx_backend_gate_t *, uint64_t thread);

/*
 * Queues the entry at the gate, first withdrawing it if it is queued, with this record and label, as the newest.
 * Its bound thread, when listed, is taken off the list and returned, to be upped.
 */
uint64_t	erx_backend_gate_post(erx_backend_gates_t *, erx_backend_gate_t *,
	    erx_backend_gate_entry_t *, const erx_fault_t *record, uint64_t label);

/*
 * A wait's request: takes the oldest record of every gate bound to thread into
 * *record and *label, unqueuing its entry, and returns ERX_OK with *taken true.
 * With none, lists thread as waiting, *taken false. A thread no gate is bound to is
 * listed too, and waits for a bind or its deadline. ERX_ENOMEM when the list cannot
 * grow to the thread's id, which changes nothing.
 */
int	erx_backend_gate_take(erx_backend_gates_t *, uint64_t thread, bool *taken, erx_fault_t *record,
	    uint64_t *label) ERX_WARN_UNUSED_RESULT;

/*
 * A timed-out wait's request: takes thread off the list. False when a post or a
 * bind took it off already, so its up is on the way.
 */
bool	erx_backend_gate_cancel(erx_backend_gates_t *, uint64_t thread);

/* Unqueues an entry, wherever it is queued; an unqueued one stays as it is. */
void	erx_backend_gate_withdraw(erx_backend_gate_entry_t *);

/*
 * A thread's deletion: every gate bound to it is left unbound with its queue kept,
 * and it is listed no more; no up is owed to a thread that is gone.
 */
void	erx_backend_gate_thread_gone(erx_backend_gates_t *, uint64_t thread);

/* Gives every page of both tables back, leaving no gate and no thread listed. */
void	erx_backend_gates_clear(erx_backend_gates_t *);

/*
 * The waiting thread's side, over its own effects. take asks for the oldest record:
 * true with it in hand, false once listed, or a refusal in *status. down blocks
 * until the thread's up or the deadline, false at the deadline and never before it.
 * cancel is erx_backend_gate_cancel's request, and absorb blocks for an up already
 * on its way.
 */
typedef struct erx_backend_gate_wait_effects {
	bool	(*take)(void *context, int *status);
	bool	(*down)(void *context, uint64_t deadline);
	bool	(*cancel)(void *context);
	void	(*absorb)(void *context);
} erx_backend_gate_wait_effects_t;

/*
 * ERX_OK with a record taken, ERX_ETIMEDOUT at the deadline, or take's refusal. A
 * thread a post took off the list as its deadline passed absorbs that post's up
 * before it times out, so its semaphore is back at 0; the record stays queued for
 * its next wait.
 */
int	erx_backend_gate_wait(const erx_backend_gate_wait_effects_t *, void *context, uint64_t deadline);

#endif /* ERX_BACKEND_GATE_H */
