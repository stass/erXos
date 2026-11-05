/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The runtime's one readiness mechanism (docs/design-runtime.md, "The event table"). A
 * caller registers a sink, binds an IRQ object into the group under the label it got, and
 * unbinds the object before it unregisters. An executor dispatches at its safe point and
 * in its sleep step; a sink treats each delivery as a reason to look at its source.
 */

#ifndef ERX_EVENT_H
#define ERX_EVENT_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erl_nif.h"
#include "liberx/backend/api.h"

void	erx_event_init(void);

/* The process gets a copy of `term` at each delivery. ERX_OK, or ERX_ELIMIT with the table full. */
int	erx_event_register_process(const ErlNifPid *pid, ERL_NIF_TERM term, uint32_t *label);
/* The port gets an input task for `event` at each delivery. */
int	erx_event_register_port(uint64_t port, uint64_t event, uint32_t *label);
void	erx_event_unregister(uint32_t label);

/* Takes the group's ready list and delivers it. Only a thread with an executor slot may. */
void	erx_event_dispatch(void);
/* scheduler_wait's exit after its loop (erx_event_leave_wait_ready). A thread with no slot takes nothing. */
void	erx_event_leave_wait(uint32_t slot);

static inline bool
erx_event_pending(uint32_t slot)
{
	return (slot != ERX_NO_EXECUTOR_SLOT &&
	    atomic_load_explicit(&erx_group_status()->ready, memory_order_acquire) != 0);
}

#endif /* ERX_EVENT_H */
