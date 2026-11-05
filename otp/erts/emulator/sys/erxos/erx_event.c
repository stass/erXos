/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The event table's effects: its lock, what a delivery does in ERTS, and the group's ready
 * list. A dispatch runs on a normal scheduler or a dirty CPU scheduler, whichever the
 * kernel woke, so a delivery uses only what is safe on a thread that thread progress does
 * not manage: enif_send with no caller and the port task queue.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "erl_port_task.h"
#include "erx_event.h"
#include "erx_event_table.h"

static erts_rwmtx_t event_lock;
static erx_event_table_t event_table;

void
erx_event_init(void)
{
	erts_rwmtx_init(&event_lock, "erx_event", NIL, ERTS_LOCK_FLAGS_PROPERTY_STATIC | ERTS_LOCK_FLAGS_CATEGORY_IO);
}

static int
add_sink(const erx_event_sink_t *sink, uint32_t *label)
{
	int status;

	erts_rwmtx_rwlock(&event_lock);
	status = erx_event_table_add(&event_table, sink, label);
	erts_rwmtx_rwunlock(&event_lock);
	return (status);
}

int
erx_event_register_process(const ErlNifPid *pid, ERL_NIF_TERM term, uint32_t *label)
{
	ErlNifEnv *const env = enif_alloc_env();
	const erx_event_sink_t sink = { .kind = ERX_EVENT_SINK_PROCESS, .owner = pid->pid,
		.detail = enif_make_copy(env, term), .storage = env };
	const int status = add_sink(&sink, label);

	if (status != ERX_OK)
		enif_free_env(env);
	return (status);
}

int
erx_event_register_port(uint64_t port, uint64_t event, uint32_t *label)
{
	const erx_event_sink_t sink = { .kind = ERX_EVENT_SINK_PORT, .owner = port, .detail = event };

	return (add_sink(&sink, label));
}

void
erx_event_unregister(uint32_t label)
{
	erx_event_sink_t removed;

	erts_rwmtx_rwlock(&event_lock);
	removed = erx_event_table_remove(&event_table, label);
	erts_rwmtx_rwunlock(&event_lock);
	if (removed.kind == ERX_EVENT_SINK_PROCESS)
		enif_free_env(removed.storage);
}

static void
deliver(const erx_event_sink_t *sink, void *arg)
{
	(void)arg;
	switch (sink->kind) {
	case ERX_EVENT_SINK_PROCESS: {
		ErlNifEnv *const env = enif_alloc_env();
		ErlNifPid pid;

		pid.pid = (ERL_NIF_TERM)sink->owner;
		/* A process that has exited is no one to tell, and its owner removes the entry. */
		(void)enif_send(NULL, &pid, env, enif_make_copy(env, (ERL_NIF_TERM)sink->detail));
		enif_free_env(env);
		break;
	}
	case ERX_EVENT_SINK_PORT:
		(void)erts_port_task_schedule((Eterm)sink->owner, NULL, ERTS_PORT_TASK_INPUT,
		    (ErlDrvEvent)(UWord)sink->detail);
		break;
	case ERX_EVENT_SINK_FREE:
		break;
	}
}

static int
take_labels(uint32_t *labels, void *arg)
{
	const int taken = erx_group_take_ready(ERX_MSG_WORDS);

	(void)arg;
	for (int index = 0; index < taken; index++) {
		uint64_t label = 0;

		(void)erx_utcb_mr_load(erx_utcb_self(), (size_t)index, &label);
		labels[index] = (uint32_t)label;
	}
	return (taken);
}

static void
read_lock(void *arg)
{
	(void)arg;
	erts_rwmtx_rlock(&event_lock);
}

static void
read_unlock(void *arg)
{
	(void)arg;
	erts_rwmtx_runlock(&event_lock);
}

static const erx_event_ops_t event_ops = { .take = take_labels, .read_lock = read_lock, .read_unlock = read_unlock,
	.deliver = deliver };

void
erx_event_dispatch(void)
{
	(void)erx_event_dispatch_ready(&event_table, &event_ops);
}

void
erx_event_leave_wait(uint32_t slot)
{
	if (slot != ERX_NO_EXECUTOR_SLOT)
		(void)erx_event_leave_wait_ready(erx_group_status(), &event_table, &event_ops);
}
