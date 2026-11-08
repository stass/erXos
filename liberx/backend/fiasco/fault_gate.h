/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_FAULT_GATE_H
#define ERX_FIASCO_FAULT_GATE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/core/crash.h"

/*
 * Fault gates on the service (docs/design-stopgap.md, "Fault gates"), over the core in
 * liberx/backend/core/gate.c. A gate is an object record of kind gate, made and
 * destroyed through object.c like any object. Each space keeps here the fault gate
 * and label its creator named, its exit record's entry and a pool of fault entries,
 * one more for each thread index it uses, so posting allocates nothing. Only the
 * service thread calls these, each to its end before the next receive.
 *
 * A fault in a space with a fault gate is queued there, its thread field unknown,
 * since Fiasco's fault message names only the task, and the faulting thread stays
 * blocked in its fault message until its space stops. A space whose gate has gone
 * drops its records and counts them; a space made with no fault gate is the test
 * launcher's, whose fault ends it with a crash record.
 */

/* The gate table and the root's space. NULL, or why the boot cannot go on. */
const char	*erx_fiasco_gate_init(void);

/*
 * What erx_space_create's fault names, for the caller: ERX_CAP_NULL is no gate, 0 in
 * *gate; a gate the caller holds is its record's index plus one; anything else is
 * ERX_ETYPE.
 */
int	erx_fiasco_gate_named(uint32_t caller, uint64_t fault, uint32_t *gate) ERX_WARN_UNUSED_RESULT;

/* A new space's part: the gate erx_fiasco_gate_named gave, and its label. ERX_ENOMEM when the pool cannot hold it. */
int	erx_fiasco_gate_space_open(uint32_t task, uint32_t gate, uint64_t label) ERX_WARN_UNUSED_RESULT;
/* A fault entry for each thread index up to index, before that thread exists. ERX_ENOMEM when the pool cannot hold it. */
int	erx_fiasco_gate_thread_room(uint32_t task, uint32_t index) ERX_WARN_UNUSED_RESULT;
/* A thread's deletion: the gates bound to it are left unbound, their queues kept. */
void	erx_fiasco_gate_thread_gone(uint32_t task, uint32_t index);
/* Every thread of the task deleted: as above for each. Its records stay queued until its deletion. */
void	erx_fiasco_gate_task_gone(uint32_t task);
/* The exit record, posted once every thread of the space is deleted; stopper is the stopping task. */
void	erx_fiasco_gate_exit(uint32_t task, uint32_t stopper, int64_t status);
/*
 * The space's deletion, at its join or a failed create: its fault and exit records
 * are withdrawn if no one has taken them, and its fault entries freed.
 */
void	erx_fiasco_gate_space_close(uint32_t task);
/* A task's fault: true when its space has a fault gate, gone or not, and the record went there or was counted. */
bool	erx_fiasco_gate_fault(uint32_t task, const erx_crash_fault_t *fault);
/* The gate record's end: its queue is dropped and every space naming it is left with none. */
void	erx_fiasco_gate_free(uint32_t index);

/* The bodies. task is the calling task and caller its thread's index. */
int	erx_fiasco_gate_create_body(uint32_t task, uint64_t budget, uint64_t *gate) ERX_WARN_UNUSED_RESULT;
int	erx_fiasco_gate_bind_body(uint32_t task, uint32_t caller, uint64_t gate, uint64_t thread) ERX_WARN_UNUSED_RESULT;
int	erx_fiasco_gate_wait_body(uint32_t task, uint32_t caller, uint64_t *taken, uint64_t *label) ERX_WARN_UNUSED_RESULT;
int	erx_fiasco_gate_cancel_body(uint32_t task, uint32_t caller, uint64_t *listed) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_FAULT_GATE_H */
