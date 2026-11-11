/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The gate worker's effects (erx_gate.h): the domain's fault gate, the worker thread that
 * waits on it, the lock over the table and the trigger of a port's IRQ object. What a
 * record does to the table is erx_gate_core.c's decision. The worker is an ERTS thread
 * that is not a scheduler, so the adapter makes it a worker, which may wait in IPC
 * (docs/design-runtime.md, R3); it touches no process, port or term, only the table under
 * gate_lock and the kernel. This file is ERTS's one caller of erx_ipc_wait
 * (tools/lib/erx/chokepoint_rules/gate.rb).
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdbool.h>
#include <string.h>

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "liberx/backend/api.h"
#include "erx_gate.h"

/*
 * gate_lock covers the table and the start's handshake. The worker holds it across each
 * deposit and the trigger that follows, so once erx_gate_worker_unregister has taken it
 * and freed the sink, no trigger of the sink's object is still to come and its port may
 * close the object. On the stopgap a trigger is a request to the system domain's service,
 * which a scheduler taking the lock meanwhile waits behind (docs/todo-performance.md); no
 * other lock is taken under gate_lock.
 */
static erts_mtx_t gate_lock;
static erts_cnd_t gate_bound;
static erx_gate_table_t gate_table;
/* Set by erx_gate_worker_init before any scheduler runs and never changed after. */
static uint64_t gate = ERX_CAP_NULL;
/* The worker's bind: under gate_lock, status final once binding is false. */
static bool binding;
static int bind_status;

/* A status's ABI name, or its number for one the ABI does not list. */
static const char *
status_text(int status, char buffer[static 16])
{
	const char *const name = erx_status_name(status);

	if (name != NULL)
		return (name);
	erts_snprintf(buffer, 16, "%d", status);
	return (buffer);
}

/*
 * Waits for the oldest record at the gate: the wait's own status, with *whole false for a
 * message that is not one fault record, which only a broken backend could post.
 */
static int
take_record(uint64_t *label, erx_fault_t *record, bool *whole)
{
	uint64_t words[sizeof(*record) / sizeof(uint64_t)];
	erx_msgtag_t tag;
	int status;

	*whole = false;
	status = erx_ipc_wait(ERX_WAIT_FOREVER, &tag, label);
	if (status != ERX_OK)
		return (status);
	if (erx_msgtag_raw_words_get(tag.raw) != sizeof(words) / sizeof(words[0]) ||
	    erx_msgtag_raw_items_get(tag.raw) != 0)
		return (ERX_OK);
	for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++) {
		if (!erx_utcb_mr_load(erx_utcb_self(), word, &words[word]))
			return (ERX_OK);
	}
	memcpy(record, words, sizeof(words));
	*whole = true;
	return (ERX_OK);
}

/*
 * The worker: binds the gate to itself and reports the bind, then for ever takes a record
 * and deposits it or drops it. A message that is not a record is dropped. A refused wait
 * ends the runtime: with no worker, no program the domain runs would ever be seen to end,
 * and the domain's restart is the recovery that already exists.
 */
static void *
gate_main(void *arg)
{
	char buffer[16];
	int status;

	(void)arg;
	status = erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0);
	erts_mtx_lock(&gate_lock);
	bind_status = status;
	binding = false;
	erts_cnd_signal(&gate_bound);
	erts_mtx_unlock(&gate_lock);
	if (status != ERX_OK)
		return (NULL);
	for (;;) {
		erx_gate_outcome_t outcome;
		erx_fault_t record;
		uint64_t label;
		bool whole;

		status = take_record(&label, &record, &whole);
		if (status != ERX_OK)
			break;
		if (!whole)
			continue;
		erts_mtx_lock(&gate_lock);
		outcome = erx_gate_table_deliver(&gate_table, label, &record);
		/* A refused trigger loses only the hint; the record waits for the port's next look. */
		if (outcome.verdict == ERX_GATE_DEPOSIT)
			(void)erx_irq_trigger(outcome.irq);
		erts_mtx_unlock(&gate_lock);
	}
	erts_exit(ERTS_ABORT_EXIT, "erx: the gate worker's wait was refused: %s\n", status_text(status, buffer));
	return (NULL);
}

void
erx_gate_worker_init(void)
{
	erts_thr_opts_t opts = ERTS_THR_OPTS_DEFAULT_INITER;
	const erx_boot_info_t *const boot = erx_runtime_boot();
	char buffer[16];
	erts_tid_t tid;
	int status;

	erts_mtx_init(&gate_lock, "erx_gate", NIL, ERTS_LOCK_FLAGS_PROPERTY_STATIC | ERTS_LOCK_FLAGS_CATEGORY_IO);
	erts_cnd_init(&gate_bound);
	if (boot->spaces_group.raw == ERX_CAP_NULL)
		return;
	status = erx_gate_create(boot->budget.raw, &gate);
	if (status != ERX_OK)
		erts_exit(ERTS_ABORT_EXIT, "erx: the fault gate cannot be made: %s\n", status_text(status, buffer));
	opts.detached = 1;
	opts.name = "erx_gate";
	binding = true;
	erts_thr_create(&tid, gate_main, NULL, &opts);
	erts_mtx_lock(&gate_lock);
	while (binding)
		erts_cnd_wait(&gate_bound, &gate_lock);
	status = bind_status;
	erts_mtx_unlock(&gate_lock);
	if (status != ERX_OK)
		erts_exit(ERTS_ABORT_EXIT, "erx: the fault gate cannot be bound: %s\n", status_text(status, buffer));
}

uint64_t
erx_gate_worker_handle(void)
{
	return (gate);
}

int
erx_gate_worker_register(uint64_t label, uint64_t irq)
{
	int status;

	if (gate == ERX_CAP_NULL)
		return (ERX_ENOTSUP);
	erts_mtx_lock(&gate_lock);
	status = erx_gate_table_add(&gate_table, label, irq);
	erts_mtx_unlock(&gate_lock);
	return (status);
}

void
erx_gate_worker_unregister(uint64_t label)
{
	erts_mtx_lock(&gate_lock);
	erx_gate_table_remove(&gate_table, label);
	erts_mtx_unlock(&gate_lock);
}

size_t
erx_gate_worker_take(uint64_t label, erx_fault_t records[ERX_GATE_SLOT_RECORDS], uint64_t *lost)
{
	size_t count;

	erts_mtx_lock(&gate_lock);
	count = erx_gate_table_take(&gate_table, label, records, lost);
	erts_mtx_unlock(&gate_lock);
	return (count);
}
