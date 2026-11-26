/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_SERVICE_TASK_H
#define ERX_FIASCO_SERVICE_TASK_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/log.h"
#include "erx/core/crash.h"
#include "liberx/backend/core/slot_pool.h"
#include "liberx/backend/fiasco/band.h"
#include "liberx/backend/fiasco/service_wire.h"

/* include/erx/pack.h's; that header's erx_boot_inputs_t is the first stage's, which boot_info.h's readers of this one must not meet. */
typedef struct erx_pack_view erx_pack_view_t;

/*
 * The service's table of tasks (docs/design-fiasco.md, "Task exit", "Capabilities in
 * Fiasco's object space"): each task's capabilities in the root, its threads' states,
 * and the bodies of the calls that make and end one. Only the service touches a row,
 * so nothing here takes a lock, and a body runs to its end before the next receive.
 */

#define ERX_FIASCO_TASK_ROOT		0u
/* A stopped task's status when a fault ended it. */
#define ERX_FIASCO_TASK_STATUS_FAULT	INT64_C(-1)

typedef enum erx_fiasco_task_thread {
	ERX_FIASCO_TASK_THREAD_ABSENT = 0,
	ERX_FIASCO_TASK_THREAD_CREATED,
	ERX_FIASCO_TASK_THREAD_STARTED
} erx_fiasco_task_thread_t;

typedef enum erx_fiasco_task_state {
	ERX_FIASCO_TASK_ABSENT = 0,
	ERX_FIASCO_TASK_LIVE,
	ERX_FIASCO_TASK_STOPPING,	/* no thread of it runs, and its teardown gives its memory back */
	ERX_FIASCO_TASK_ENDED	/* its status waits for erx_fiasco_task_join */
} erx_fiasco_task_state_t;

/*
 * A task's place in the tree of spaces (docs/design-fiasco.md, "Spaces, parents and
 * exit records"), kept from its create until its deletion. The root is no task's child,
 * so 0 ends a list; a child is on its parent's list from its create to its deletion,
 * stopped or not. space is its space record's index plus one, the record every handle
 * to it names, or 0 for the root, which has none.
 */
typedef struct erx_fiasco_task_tree {
	uint32_t	parent;
	uint32_t	child;		/* the first on its list of children */
	uint32_t	sibling;	/* the next on its parent's list */
	uint32_t	space;
} erx_fiasco_task_tree_t;

/*
 * A task's pairs of the root's slot pool (docs/design-fiasco.md, "Handles"), taken with
 * its row and freed at its row's deletion, after the last object in them: its gate and
 * its task object in the first, the semaphore its end ups in the second, whose other
 * slot is unused. Kept from its create until its deletion, as its place in the tree is.
 */
typedef struct erx_fiasco_task_pairs {
	erx_slot_pair_t	objects;
	erx_slot_pair_t	ended;
} erx_fiasco_task_pairs_t;

typedef struct erx_fiasco_task {
	erx_fiasco_task_state_t	 state;
	uint32_t		 flags;		/* ERX_SPACE_* */
	uint32_t		 group;		/* its home group's record index plus one, 0 for none */
	uint32_t		 dispatcher;	/* its dispatcher's thread index plus one, 0 until it is named */
	erx_fiasco_task_tree_t	 tree;
	erx_fiasco_task_pairs_t	 pairs;		/* none in the root's row */
	bool			 first_made;	/* its creator made index 0, so another create there is ERX_ENOTSUP */
	int64_t			 status;
	uint32_t		 stopper;	/* while stopping: the task that stopped it, whom its exit record names */
	uint64_t		 stop_order;	/* while stopping: the count of stops when it stopped, which orders the teardowns */
	erx_fiasco_task_thread_t threads[ERX_FIASCO_THREADS_MAX];
	uint64_t		 affinity[ERX_FIASCO_THREADS_MAX];	/* as last set, 0 for wherever it was created */
	/* Thread n's pair, its thread and its semaphore, from its create's take until its deletion; none in the root's row. */
	erx_slot_pair_t		 thread_pairs[ERX_FIASCO_THREADS_MAX];
	erx_log_rate_t		 log_rate;	/* what its erx_debug_log lines have cost, zero at its start */
	bool			 test_task;	/* the launcher made it, so its task_write reaches the console */
	erx_fiasco_task_band_t	 bands;		/* fixed when it is made (band.h) */
	/* Counted, never printed: its messages the decoder refused, zero at its start. */
	_Atomic uint64_t	 refused;
} erx_fiasco_task_t;

/*
 * The table is pool pages that it takes as it fills (docs/design-fiasco.md, "Table
 * sizes"), so a row exists for every index below its capacity; erx_fiasco_task gives
 * the row of an index the caller knows to have one, a live task's or a decoded space's.
 */
erx_fiasco_task_t	*erx_fiasco_task(uint32_t task);
/*
 * The live task whose row names the group record as its home, by a scan of the rows:
 * the row is the home's one record, so an ended task is no group's home.
 */
bool		erx_fiasco_task_group_home(uint32_t record, uint32_t *task);
/* Whether the index names a live task: what the decoder asks about a gate's label. */
bool		erx_fiasco_task_live(uint32_t task);
/*
 * Marks the root live, once its window is up, with its row the system domain's domain row,
 * whose threads take slice_us as their quantum; NULL, or why the boot cannot go on.
 */
const char	*erx_fiasco_task_table_init(uint32_t slice_us);

/*
 * A thread's pair of the slot pool, which its capabilities in the root name (docs/design-fiasco.md,
 * "Handles"): the take, before any Fiasco call of the thread's create, ERX_ENOMEM with nothing
 * taken when the pool has no free pair; the free, once Fiasco has deleted the thread and its
 * semaphore, by every path that deletes them. The root's own threads keep their fixed slots,
 * so both do nothing for the root.
 */
int		erx_fiasco_task_thread_pair_take(uint32_t task, uint32_t index) ERX_WARN_UNUSED_RESULT;
void		erx_fiasco_task_thread_pair_free(uint32_t task, uint32_t index);

/* A task's capabilities in the root. */
uint64_t	erx_fiasco_task_thread_cap(uint32_t task, uint32_t index);
uint64_t	erx_fiasco_task_semaphore_cap(uint32_t task, uint32_t index);
uint64_t	erx_fiasco_task_gate_cap(uint32_t task);

/*
 * Deletes the kernel objects that the root's capabilities caps[0..count) name, in as few
 * kernel calls as a message holds (docs/design-fiasco.md, "Thread exit"). Fiasco's unmap
 * removes every capability of one call, puts its objects on one reap list, kills each listed
 * thread, and waits for the one RCU grace period the list needs before it returns. So on
 * return the capabilities are gone, no listed thread reaches user mode again, and every slot
 * is free for the caller to reuse. A capability that names nothing is a no-op to the kernel.
 * A refusal ends the machine.
 */
void		erx_fiasco_caps_delete(const uint64_t *caps, size_t count);

/* Sets bit n of map for each thread n the task has created and not reaped, from the table alone. */
void		erx_fiasco_task_thread_map(uint32_t task, uint64_t map[2]);

/* The slot in a task's own space that its threads name the gate by. */
uint64_t	erx_fiasco_task_gate_slot(uint32_t task);

/*
 * The record of a task's thread, through the window: the service alone reads and writes
 * it this way. NULL when the task has given up the table's page.
 */
void		*erx_fiasco_task_record(uint32_t task, uint32_t index);

/*
 * The task and index a thread handle names for the caller: its own handle is the
 * index, and a handle of another task's thread is erx_backend_thread_handle_other's, which names
 * a thread only for the root or that task's creator. ERX_EINVAL for a handle that
 * names no live task's index, or another task the caller did not create. Defined in
 * service.c.
 */
int	erx_fiasco_thread_handle_name(uint32_t caller, uint64_t handle, uint32_t *task, uint32_t *index)
	    ERX_WARN_UNUSED_RESULT;

/* The archive that erx_image_map and erx_image_slice read, which outlives every call; NULL until named. */
void		erx_fiasco_task_set_archive(const erx_pack_view_t *view);
const erx_pack_view_t	*erx_fiasco_task_archive(void);

/*
 * The bodies. caller is the calling task; each result is the call table's. A create
 * with test_task is the launcher's test_space_create, and a domain create the domain library's
 * domain_space_create, which only the root may ask for.
 */
int	erx_fiasco_task_create_body(uint32_t caller, const erx_fiasco_space_create_request_t *request, bool test_task,
	    uint64_t *space);
int	erx_fiasco_task_create_domain_body(uint32_t caller, const erx_fiasco_domain_space_create_request_t *request,
	    uint64_t *space);
int	erx_fiasco_task_image_map_body(uint32_t caller, uint64_t space, uint64_t image, uint64_t entry, uint64_t *start);
int	erx_fiasco_task_stop_body(uint32_t caller, uint64_t space, int64_t status);
/*
 * The root's join of a space it created: ERX_EBUSY with the task's index in *task while
 * the space runs, for the stub to wait on its ended semaphore; once it has stopped, its
 * status, its deletion with every space below it, and the handle's close.
 */
int	erx_fiasco_task_join_body(uint32_t caller, uint64_t space, int64_t *status, uint64_t *ended);
/*
 * The task a call naming space acts on: the caller's for ERX_CAP_SELF, else the live
 * task a space handle in the caller's table names; a handle's refusals as
 * erx_fiasco_object_find gives them, and ERX_EINVAL for a space that has stopped.
 */
int	erx_fiasco_task_space_target(uint32_t caller, uint64_t space, uint32_t *task) ERX_WARN_UNUSED_RESULT;
/*
 * Whether caller made the live task task, by its space record's creator: the one
 * task besides the root that may name the task's threads. The root, which no
 * space record holds, is no task's creation.
 */
bool	erx_fiasco_task_created_by(uint32_t task, uint32_t caller);
/*
 * A space record's end, from object.c: the last handle's close or its creator's
 * destroy or end releases the space, which stops with ERX_EXIT_RELEASED if it runs,
 * finishes its teardown in this call, and is deleted with every space below it. A
 * record whose space was deleted first is no-op.
 */
void	erx_fiasco_task_space_release(uint32_t record);
/*
 * One piece of the teardown of the stopping task that stopped first (docs/design-fiasco.md,
 * "Task exit"), its end once its memory is back, or nothing when no task is stopping. The
 * service's loop runs it between requests.
 */
void	erx_fiasco_task_teardown_step(void);
/* Whether any task is stopping, so the loop has a piece to run. */
bool	erx_fiasco_task_teardown_pending(void);
int	erx_fiasco_task_mem_create_body(uint32_t caller, const erx_fiasco_mem_create_request_t *request, uint64_t *mem);
/*
 * erx_mem_create_paged and erx_mem_seal (docs/design-fiasco.md, "The call table"):
 * erx_fiasco_vm_paged_rule's refusals, then the object's charge to its budget; a seal
 * of an object the caller holds, erx_fiasco_vm_object_seal's results; erx_mem_child's
 * child of a parent the caller holds, charged to its budget, erx_fiasco_vm_child_create's
 * refusals and results.
 */
int	erx_fiasco_task_mem_paged_body(uint32_t caller, const erx_fiasco_mem_create_request_t *request, uint64_t *mem);
int	erx_fiasco_task_mem_seal_body(uint32_t caller, uint64_t mem);
int	erx_fiasco_task_mem_child_body(uint32_t caller, const erx_fiasco_mem_child_request_t *request, uint64_t *mem);
int	erx_fiasco_task_mem_dma_body(uint32_t caller, uint64_t mem, uint64_t offset, uint64_t *addr);
int	erx_fiasco_task_mem_physical_body(uint32_t caller, const erx_fiasco_mem_physical_request_t *request, uint64_t *mem);
int	erx_fiasco_task_mem_contiguous_body(uint32_t caller, const erx_fiasco_mem_contiguous_request_t *request, uint64_t *mem);
int	erx_fiasco_task_vm_map_body(uint32_t caller, const erx_fiasco_vm_map_request_t *request);

/*
 * A task's fault: a fault record at its space's fault gate, its thread left blocked;
 * with no fault gate, its crash record, then its end. The root's own fault never comes here.
 */
void	erx_fiasco_task_fault(uint32_t task, const erx_fault_t *fault);

#endif /* ERX_FIASCO_SERVICE_TASK_H */
