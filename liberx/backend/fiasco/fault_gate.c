/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Fault gates on the service: each space's gate part, the bodies of erx_gate_create,
 * erx_gate_bind and erx_ipc_wait's two requests, and the posting of faults and exits.
 * See fault_gate.h.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/semaphore.h>

#include "erx/abi.h"
#include "liberx/backend/core/gate.h"
#include "liberx/backend/core/grow_table.h"
#include "liberx/backend/core/handles.h"
#include "liberx/backend/fiasco/fault_gate.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"

/*
 * A space's fault gate: none, as the launcher makes them; gone, once the gate its
 * creator named has ended; else the gate record's index plus one.
 */
#define GATE_NONE	UINT32_C(0)
#define GATE_GONE	UINT32_MAX
/* A fault record's thread: Fiasco's fault message names only the task. */
#define GATE_THREAD_UNKNOWN	UINT64_MAX

/* A space's gate part. */
typedef struct gate_space {
	uint32_t		 fault_gate;	/* GATE_NONE, GATE_GONE or a record's index plus one */
	uint64_t		 label;		/* its creator's, as given */
	uint64_t		 dropped;	/* records its gone gate, or no free entry, could not take */
	erx_backend_gate_entry_t exit;
	erx_backend_grow_table_t faults;	/* erx_backend_gate_entry_t, one per thread index used */
} gate_space_t;

static gate_space_t	*gate_space(uint32_t);
static uint64_t	gate_thread_id(uint32_t, uint32_t);
static void	gate_thread_name(uint64_t, uint32_t *, uint32_t *);
static void	gate_up(uint64_t);
static erx_backend_gate_t *gate_of(const gate_space_t *);
static int	gate_fill(uint32_t, const void *);

static erx_backend_gates_t gates;
/* Each space's gate part, by its task's index. */
static erx_backend_grow_table_t gate_spaces;

const char *
erx_fiasco_gate_init(void)
{
	erx_backend_gates_init(&gates, &erx_fiasco_vm_records);
	erx_backend_grow_table_init(&gate_spaces, sizeof(gate_space_t), &erx_fiasco_vm_records);
	if (erx_fiasco_gate_space_open(ERX_FIASCO_TASK_ROOT, GATE_NONE, 0) != ERX_OK)
		return ("gates: the pool cannot hold the root's space");
	return (NULL);
}

int
erx_fiasco_gate_named(uint32_t caller, uint64_t fault, uint32_t *gate)
{
	uint32_t index;

	if (fault == ERX_CAP_NULL) {
		*gate = GATE_NONE;
		return (ERX_OK);
	}
	if (erx_fiasco_object_find(caller, fault, ERX_BACKEND_OBJECT_GATE, &index) != ERX_OK || index >= GATE_GONE - 1)
		return (ERX_ETYPE);
	*gate = index + 1;
	return (ERX_OK);
}

/* A row reused after a join is empty: the join withdrew its exit and the task's end freed its faults. */
int
erx_fiasco_gate_space_open(uint32_t task, uint32_t gate, uint64_t label)
{
	gate_space_t *space;

	if (task == UINT32_MAX || erx_backend_grow_table_room(&gate_spaces, task + 1) != ERX_OK)
		return (ERX_ENOMEM);
	space = gate_space(task);
	*space = (gate_space_t){ .fault_gate = gate, .label = label };
	erx_backend_grow_table_init(&space->faults, sizeof(erx_backend_gate_entry_t), &erx_fiasco_vm_records);
	return (ERX_OK);
}

int
erx_fiasco_gate_thread_room(uint32_t task, uint32_t index)
{
	return (erx_backend_grow_table_room(&gate_space(task)->faults, index + 1));
}

void
erx_fiasco_gate_thread_gone(uint32_t task, uint32_t index)
{
	erx_backend_gate_thread_gone(&gates, gate_thread_id(task, index));
}

void
erx_fiasco_gate_task_gone(uint32_t task)
{
	for (uint32_t index = 0; index < ERX_FIASCO_THREADS_MAX; index++)
		erx_fiasco_gate_thread_gone(task, index);
}

/*
 * The exit record names the stopper's space, and no thread: a request's caller index
 * is the stopping task's own word, which the service cannot trust.
 */
void
erx_fiasco_gate_exit(uint32_t task, uint32_t stopper, int64_t status)
{
	gate_space_t *const space = gate_space(task);
	erx_backend_gate_t *const gate = gate_of(space);
	const erx_fault_t record = { .kind = ERX_FAULT_EXIT, .thread = GATE_THREAD_UNKNOWN, .space = stopper,
	    .status = status };

	if (space->fault_gate == GATE_NONE)
		return;
	if (gate == NULL) {
		space->dropped++;
		return;
	}
	gate_up(erx_backend_gate_post(&gates, gate, &space->exit, &record, space->label));
}

void
erx_fiasco_gate_space_close(uint32_t task)
{
	gate_space_t *const space = gate_space(task);
	const uint32_t faults = erx_backend_grow_table_capacity(&space->faults);

	erx_backend_gate_withdraw(&space->exit);
	for (uint32_t entry = 0; entry < faults; entry++)
		erx_backend_gate_withdraw(erx_backend_grow_table_at(&space->faults, entry));
	erx_backend_grow_table_clear(&space->faults);
}

/*
 * The entry is any unqueued one of the space's pool, since the message does not say
 * which thread faulted. A fault blocks its thread until the space stops, and a blocked
 * thread is never reaped unless its own task asks, so the queued faults never
 * outnumber the thread indices the pool was grown for. A task that reaps a faulted
 * thread and faults again at the same index can run the pool out, and its later
 * records are dropped: harm only to itself.
 */
bool
erx_fiasco_gate_fault(uint32_t task, const erx_crash_fault_t *fault)
{
	gate_space_t *const space = gate_space(task);
	erx_backend_gate_t *const gate = gate_of(space);
	const uint32_t faults = erx_backend_grow_table_capacity(&space->faults);
	const erx_fault_t record = { .kind = (erx_fault_kind_t)fault->kind, .cause = fault->cause, .addr = fault->addr,
	    .pc = fault->pc, .thread = GATE_THREAD_UNKNOWN, .space = task };
	erx_backend_gate_entry_t *entry = NULL;

	if (space->fault_gate == GATE_NONE)
		return (false);
	for (uint32_t index = 0; index < faults && entry == NULL; index++) {
		erx_backend_gate_entry_t *const candidate = erx_backend_grow_table_at(&space->faults, index);

		if (candidate->gate == NULL)
			entry = candidate;
	}
	if (gate == NULL || entry == NULL)
		space->dropped++;
	else
		gate_up(erx_backend_gate_post(&gates, gate, entry, &record, space->label));
	return (true);
}

void
erx_fiasco_gate_free(uint32_t index)
{
	const uint32_t spaces = erx_backend_grow_table_capacity(&gate_spaces);

	erx_backend_gate_close(&gates, index);
	for (uint32_t task = 0; task < spaces; task++) {
		gate_space_t *const space = gate_space(task);

		if (space->fault_gate == index + 1)
			space->fault_gate = GATE_GONE;
	}
}

int
erx_fiasco_gate_create_body(uint32_t task, uint64_t budget, uint64_t *gate)
{
	return (erx_fiasco_object_create(task, ERX_BACKEND_OBJECT_GATE, budget, gate_fill, NULL, gate));
}

/*
 * thread is ERX_CAP_NULL, which unbinds; ERX_CAP_SELF_THREAD; or a handle of one of
 * the caller's own threads, its index. The root's handle of another task's thread is
 * ERX_ENOTSUP, as on the stopgap a gate's thread is always its binder's.
 */
int
erx_fiasco_gate_bind_body(uint32_t task, uint32_t caller, uint64_t gate, uint64_t thread)
{
	const erx_fiasco_task_t *const row = erx_fiasco_task(task);
	uint32_t index, named, thread_index;
	uint64_t id;
	int status = erx_fiasco_object_find(task, gate, ERX_BACKEND_OBJECT_GATE, &index);

	if (status != ERX_OK)
		return (status);
	if (thread == ERX_CAP_NULL) {
		id = ERX_BACKEND_GATE_NO_THREAD;
	} else {
		status = erx_fiasco_thread_handle_name(task, thread == ERX_CAP_SELF_THREAD ? caller : thread, &named,
		    &thread_index);
		if (status == ERX_OK && named != task)
			return (ERX_ENOTSUP);
		if (status != ERX_OK || row->threads[thread_index] == ERX_FIASCO_TASK_THREAD_ABSENT)
			return (ERX_EINVAL);
		id = gate_thread_id(task, thread_index);
	}
	gate_up(erx_backend_gate_bind(&gates, erx_backend_gate_at(&gates, index), id));
	return (ERX_OK);
}

/* The record's words go to the caller's public UTCB through the window, whose reply orders them. */
int
erx_fiasco_gate_wait_body(uint32_t task, uint32_t caller, uint64_t *taken, uint64_t *label)
{
	erx_fiasco_thread_record_t *const thread = erx_fiasco_task_record(task, caller);
	uint64_t words[sizeof(erx_fault_t) / sizeof(uint64_t)];
	erx_fault_t record;
	bool took;
	int status;

	_Static_assert(sizeof(words) <= sizeof(thread->utcb.mr), "a record fits the message registers");
	if (thread == NULL || erx_fiasco_task(task)->threads[caller] == ERX_FIASCO_TASK_THREAD_ABSENT)
		return (ERX_EINVAL);
	status = erx_backend_gate_take(&gates, gate_thread_id(task, caller), &took, &record, label);
	if (status != ERX_OK)
		return (status);
	*taken = took;
	if (took) {
		__builtin_memcpy(words, &record, sizeof(words));
		for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++)
			atomic_store_explicit(&thread->utcb.mr[word], words[word], memory_order_relaxed);
	}
	return (ERX_OK);
}

int
erx_fiasco_gate_cancel_body(uint32_t task, uint32_t caller, uint64_t *listed)
{
	if (erx_fiasco_task(task)->threads[caller] == ERX_FIASCO_TASK_THREAD_ABSENT)
		return (ERX_EINVAL);
	*listed = erx_backend_gate_cancel(&gates, gate_thread_id(task, caller));
	return (ERX_OK);
}

static gate_space_t *
gate_space(uint32_t task)
{
	return (erx_backend_grow_table_at(&gate_spaces, task));
}

/* A thread's id in the core: never ERX_BACKEND_GATE_NO_THREAD, and below 2^32 for every task the table can hold. */
static uint64_t
gate_thread_id(uint32_t task, uint32_t index)
{
	return ((uint64_t)task * ERX_FIASCO_THREADS_MAX + index + 1);
}

/* gate_thread_id's inverse, for an id it gave. */
static void
gate_thread_name(uint64_t thread, uint32_t *task, uint32_t *index)
{
	*task = (uint32_t)((thread - 1) / ERX_FIASCO_THREADS_MAX);
	*index = (uint32_t)((thread - 1) % ERX_FIASCO_THREADS_MAX);
}

/* The up a post or a bind owes a thread it took off the list. */
static void
gate_up(uint64_t thread)
{
	uint32_t task, index;

	if (thread == ERX_BACKEND_GATE_NO_THREAD)
		return;
	gate_thread_name(thread, &task, &index);
	(void)l4_semaphore_up(erx_fiasco_task_semaphore_cap(task, index));
}

static erx_backend_gate_t *
gate_of(const gate_space_t *space)
{
	if (space->fault_gate == GATE_NONE || space->fault_gate == GATE_GONE)
		return (NULL);
	return (erx_backend_gate_at(&gates, space->fault_gate - 1));
}

static int
gate_fill(uint32_t index, const void *request)
{
	(void)request;
	return (erx_backend_gate_open(&gates, index));
}
