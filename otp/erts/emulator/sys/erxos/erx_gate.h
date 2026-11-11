/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The gate worker (docs/design-runtime.md, "The event table"): the one thread of the
 * domain that waits in IPC, on the domain's fault gate, which every space the runtime
 * creates names, so every exit and fault record of those spaces arrives there. A port that
 * creates spaces registers the label it gives them with its own IRQ object; the worker
 * keeps each record for that label in the port's slot and triggers the object, and the
 * port's input task takes the records. A record for a label no port registered is dropped.
 *
 * A port's order, so that no record of its spaces is dropped or triggers an object no one
 * hears: create its IRQ object and bind it into the group, register, and only then create
 * the spaces that carry the label; at its end, unregister, and only then close the object.
 */

#ifndef ERX_GATE_H
#define ERX_GATE_H

#include <stddef.h>
#include <stdint.h>

#include "erx_gate_core.h"

/*
 * At start-up, from erl_sys_init: in a domain the boot information gives a sub-space group,
 * creates the fault gate and starts the worker bound to it; anywhere else, nothing. A gate
 * that cannot be made or bound ends the start.
 */
void	erx_gate_worker_init(void);
/* The fault gate's handle, which a port names when it creates a space, or ERX_CAP_NULL where there is none. */
uint64_t erx_gate_worker_handle(void);
/*
 * The worker keeps label's records for the caller and triggers irq after each: ERX_OK,
 * ERX_ENOTSUP with no fault gate, or erx_gate_table_add's refusal. The caller keeps irq
 * until erx_gate_worker_unregister returns, after which the worker triggers it no more.
 */
int	erx_gate_worker_register(uint64_t label, uint64_t irq);
/* Ends the registration; records not taken are dropped. */
void	erx_gate_worker_unregister(uint64_t label);
/*
 * erx_gate_table_take, under the worker's lock. A record's kind is the kernel's, which
 * the caller checks before acting on it. A port that finds *lost above zero has missed
 * records of its spaces, an end among them perhaps, so no status it could report is
 * known: it ends its program as a close of the port does, never with a status it did not
 * read (docs/design-runtime.md, "The event table").
 */
size_t	erx_gate_worker_take(uint64_t label, erx_fault_t records[ERX_GATE_SLOT_RECORDS], uint64_t *lost);

#endif /* ERX_GATE_H */
