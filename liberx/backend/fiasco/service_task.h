/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_SERVICE_TASK_H
#define ERX_FIASCO_SERVICE_TASK_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/log.h"
#include "erx/core/crash.h"
#include "liberx/backend/fiasco/service_wire.h"

/* include/erx/pack.h's; that header's erx_boot_inputs_t is the first stage's, which boot_info.h's readers of this one must not meet. */
typedef struct erx_pack_view erx_pack_view_t;

/*
 * The service's table of tasks (docs/design-stopgap.md, "Task exit", "Capabilities in
 * Fiasco's object space"): each task's capabilities in the root, its threads' states,
 * and the bodies of the calls that make and end one. Only the service touches a row,
 * so nothing here takes a lock, and a body runs to its end before the next receive.
 */

#define ERX_FIASCO_TASK_ROOT		0u
/* A stopped task's status when a fault ended it. */
#define ERX_FIASCO_TASK_STATUS_FAULT	INT64_C(-1)
/* A body's result that sends no reply: its caller's thread is gone. */
#define ERX_FIASCO_NO_REPLY		INT32_MIN

typedef enum erx_fiasco_task_thread {
	ERX_FIASCO_TASK_THREAD_ABSENT = 0,
	ERX_FIASCO_TASK_THREAD_CREATED,
	ERX_FIASCO_TASK_THREAD_STARTED
} erx_fiasco_task_thread_t;

typedef enum erx_fiasco_task_state {
	ERX_FIASCO_TASK_ABSENT = 0,
	ERX_FIASCO_TASK_LIVE,
	ERX_FIASCO_TASK_ENDED	/* its status waits for erx_fiasco_task_join */
} erx_fiasco_task_state_t;

/*
 * A task's place in the tree of spaces (docs/design-stopgap.md, "Spaces, parents and
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

typedef struct erx_fiasco_task {
	erx_fiasco_task_state_t	 state;
	uint32_t		 flags;		/* ERX_SPACE_* */
	uint32_t		 group;		/* its home group's record index plus one, 0 for none */
	uint32_t		 dispatcher;	/* its dispatcher's thread index plus one, 0 until it is named */
	erx_fiasco_task_tree_t	 tree;
	bool			 first_made;	/* its creator made index 0, so another create there is ERX_ENOTSUP */
	int64_t			 status;
	erx_fiasco_task_thread_t threads[ERX_FIASCO_THREADS_MAX];
	uint64_t		 affinity[ERX_FIASCO_THREADS_MAX];	/* as last set, 0 for wherever it was created */
	erx_log_rate_t		 log_rate;	/* what its erx_debug_log lines have cost, zero at its start */
} erx_fiasco_task_t;

/*
 * The table is pool pages that it takes as it fills (docs/design-stopgap.md, "Table
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
/* Marks the root live, once its window is up; NULL, or why the boot cannot go on. */
const char	*erx_fiasco_task_table_init(void);

/* A task's capabilities in the root. */
uint64_t	erx_fiasco_task_thread_cap(uint32_t task, uint32_t index);
uint64_t	erx_fiasco_task_semaphore_cap(uint32_t task, uint32_t index);
uint64_t	erx_fiasco_task_gate_cap(uint32_t task);

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
 * index, and the root's handle of another task's thread carries the task above it.
 * ERX_EINVAL for a handle that names no live task's index. Defined in service.c.
 */
int	erx_fiasco_thread_handle_name(uint32_t caller, uint64_t handle, uint32_t *task, uint32_t *index)
	    ERX_WARN_UNUSED_RESULT;

/* The archive that erx_image_map and erx_image_slice read, which outlives every call; NULL until named. */
void		erx_fiasco_task_set_archive(const erx_pack_view_t *view);
const erx_pack_view_t	*erx_fiasco_task_archive(void);

/* The bodies. caller is the calling task; each result is the call table's. */
int	erx_fiasco_task_create_body(uint32_t caller, const erx_fiasco_space_create_request_t *request, uint64_t *space);
int	erx_fiasco_task_image_map_body(uint32_t caller, uint64_t space, uint64_t entry, uint64_t *start);
int	erx_fiasco_task_stop_body(uint32_t caller, uint64_t space, int64_t status);
/*
 * The root's join of a space it created: ERX_EBUSY with the task's index in *task while
 * the space runs, for the stub to wait on its ended semaphore; once it has stopped, its
 * status, its deletion with every space below it, and the handle's close.
 */
int	erx_fiasco_task_join_body(uint32_t caller, uint64_t space, int64_t *status, uint64_t *task);
/*
 * The task a call naming space acts on: the caller's for ERX_CAP_SELF, else the live
 * task a space handle in the caller's table names; a handle's refusals as
 * erx_fiasco_object_find gives them, and ERX_EINVAL for a space that has stopped.
 */
int	erx_fiasco_task_space_target(uint32_t caller, uint64_t space, uint32_t *task) ERX_WARN_UNUSED_RESULT;
/*
 * A space record's end, from object.c: the last handle's close or its creator's
 * destroy or end releases the space, which stops with ERX_EXIT_RELEASED if it runs and
 * is deleted with every space below it. A record whose space was deleted first is no-op.
 */
void	erx_fiasco_task_space_release(uint32_t record);
int	erx_fiasco_task_mem_create_body(uint32_t caller, const erx_fiasco_mem_create_request_t *request, uint64_t *mem);
int	erx_fiasco_task_mem_dma_body(uint32_t caller, uint64_t mem, uint64_t offset, uint64_t *addr);
int	erx_fiasco_task_mem_physical_body(uint32_t caller, const erx_fiasco_mem_physical_request_t *request, uint64_t *mem);
int	erx_fiasco_task_mem_contiguous_body(uint32_t caller, const erx_fiasco_mem_contiguous_request_t *request, uint64_t *mem);
int	erx_fiasco_task_vm_map_body(uint32_t caller, const erx_fiasco_vm_map_request_t *request);

/*
 * A task's fault: a fault record at its space's fault gate, its thread left blocked;
 * with no fault gate, its crash record, then its end. The root's own fault never comes here.
 */
void	erx_fiasco_task_fault(uint32_t task, const erx_crash_fault_t *fault);

#endif /* ERX_FIASCO_SERVICE_TASK_H */
