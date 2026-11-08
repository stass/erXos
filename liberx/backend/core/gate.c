/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Fault gates' core: queues of records linked through their entries, the binding
 * of each gate to a thread, the list of waiting threads, and the wait protocol.
 * See gate.h.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/core/gate.h"

#define GATE_WORD_BITS	64u

static void	gate_unlink(erx_backend_gate_entry_t *);
static uint64_t	gate_wake(erx_backend_gates_t *, erx_backend_gate_t *);
static uint64_t	*gate_listed_word(const erx_backend_gates_t *, uint64_t);
static bool	gate_listed(const erx_backend_gates_t *, uint64_t);
static void	gate_unlist(erx_backend_gates_t *, uint64_t);

void
erx_backend_gates_init(erx_backend_gates_t *gates, const erx_backend_grow_pages_t *source)
{
	erx_backend_grow_table_init(&gates->table, sizeof(erx_backend_gate_t), source);
	erx_backend_grow_table_init(&gates->listed, sizeof(uint64_t), source);
	gates->posted = 0;
}

void
erx_backend_gates_clear(erx_backend_gates_t *gates)
{
	erx_backend_grow_table_clear(&gates->table);
	erx_backend_grow_table_clear(&gates->listed);
}

int
erx_backend_gate_open(erx_backend_gates_t *gates, uint32_t index)
{
	erx_backend_gate_t *gate;

	if (index == UINT32_MAX || erx_backend_grow_table_room(&gates->table, index + 1) != ERX_OK)
		return (ERX_ENOMEM);
	gate = erx_backend_grow_table_at(&gates->table, index);
	*gate = (erx_backend_gate_t){ .live = true };
	return (ERX_OK);
}

erx_backend_gate_t *
erx_backend_gate_at(const erx_backend_gates_t *gates, uint32_t index)
{
	erx_backend_gate_t *const gate = erx_backend_grow_table_at(&gates->table, index);

	return (gate != NULL && gate->live ? gate : NULL);
}

void
erx_backend_gate_close(erx_backend_gates_t *gates, uint32_t index)
{
	erx_backend_gate_t *const gate = erx_backend_gate_at(gates, index);

	if (gate == NULL)
		return;
	while (gate->head != NULL)
		gate_unlink(gate->head);
	*gate = (erx_backend_gate_t){ .live = false };
}

uint64_t
erx_backend_gate_bind(erx_backend_gates_t *gates, erx_backend_gate_t *gate, uint64_t thread)
{
	gate->thread = thread;
	return (gate_wake(gates, gate));
}

uint64_t
erx_backend_gate_post(erx_backend_gates_t *gates, erx_backend_gate_t *gate, erx_backend_gate_entry_t *entry,
    const erx_fault_t *record, uint64_t label)
{
	/* An entry is in one queue at most, so a queued one leaves its place first. */
	erx_backend_gate_withdraw(entry);
	*entry = (erx_backend_gate_entry_t){ .prev = gate->tail, .gate = gate, .order = gates->posted++, .label = label,
	    .record = *record };
	if (gate->tail != NULL)
		gate->tail->next = entry;
	else
		gate->head = entry;
	gate->tail = entry;
	return (gate_wake(gates, gate));
}

int
erx_backend_gate_take(erx_backend_gates_t *gates, uint64_t thread, bool *taken, erx_fault_t *record, uint64_t *label)
{
	const uint32_t capacity = erx_backend_grow_table_capacity(&gates->table);
	erx_backend_gate_entry_t *oldest = NULL;

	for (uint32_t index = 0; index < capacity; index++) {
		const erx_backend_gate_t *const gate = erx_backend_gate_at(gates, index);

		if (gate != NULL && gate->thread == thread && gate->head != NULL &&
		    (oldest == NULL || gate->head->order < oldest->order))
			oldest = gate->head;
	}
	*taken = oldest != NULL;
	if (oldest != NULL) {
		*record = oldest->record;
		*label = oldest->label;
		gate_unlink(oldest);
		return (ERX_OK);
	}
	if (thread > UINT32_MAX ||
	    erx_backend_grow_table_room(&gates->listed, (uint32_t)(thread / GATE_WORD_BITS) + 1) != ERX_OK)
		return (ERX_ENOMEM);
	*gate_listed_word(gates, thread) |= UINT64_C(1) << (thread % GATE_WORD_BITS);
	return (ERX_OK);
}

bool
erx_backend_gate_cancel(erx_backend_gates_t *gates, uint64_t thread)
{
	const bool listed = gate_listed(gates, thread);

	gate_unlist(gates, thread);
	return (listed);
}

void
erx_backend_gate_withdraw(erx_backend_gate_entry_t *entry)
{
	if (entry->gate != NULL)
		gate_unlink(entry);
}

void
erx_backend_gate_thread_gone(erx_backend_gates_t *gates, uint64_t thread)
{
	const uint32_t capacity = erx_backend_grow_table_capacity(&gates->table);

	for (uint32_t index = 0; index < capacity; index++) {
		erx_backend_gate_t *const gate = erx_backend_gate_at(gates, index);

		if (gate != NULL && gate->thread == thread)
			gate->thread = ERX_BACKEND_GATE_NO_THREAD;
	}
	gate_unlist(gates, thread);
}

/*
 * Asks until a record comes or the deadline passes. A thread woken by an up asks
 * again, since the record that woke it may have been withdrawn meanwhile.
 */
int
erx_backend_gate_wait(const erx_backend_gate_wait_effects_t *effects, void *context, uint64_t deadline)
{
	int status = ERX_OK;

	for (;;) {
		if (effects->take(context, &status))
			return (ERX_OK);
		if (status != ERX_OK)
			return (status);
		if (effects->down(context, deadline))
			continue;
		if (!effects->cancel(context))
			effects->absorb(context);
		return (ERX_ETIMEDOUT);
	}
}

static void
gate_unlink(erx_backend_gate_entry_t *entry)
{
	erx_backend_gate_t *const gate = entry->gate;

	if (entry->prev != NULL)
		entry->prev->next = entry->next;
	else
		gate->head = entry->next;
	if (entry->next != NULL)
		entry->next->prev = entry->prev;
	else
		gate->tail = entry->prev;
	entry->next = entry->prev = NULL;
	entry->gate = NULL;
}

/* The bound thread, taken off the list, when it is listed and the gate has a record for it. */
static uint64_t
gate_wake(erx_backend_gates_t *gates, erx_backend_gate_t *gate)
{
	const uint64_t thread = gate->thread;

	if (thread == ERX_BACKEND_GATE_NO_THREAD || gate->head == NULL || !gate_listed(gates, thread))
		return (ERX_BACKEND_GATE_NO_THREAD);
	gate_unlist(gates, thread);
	return (thread);
}

/* The word holding thread's bit, or NULL past what the list has grown to: such a thread was never listed. */
static uint64_t *
gate_listed_word(const erx_backend_gates_t *gates, uint64_t thread)
{
	return (thread > UINT32_MAX ? NULL : erx_backend_grow_table_at(&gates->listed, (uint32_t)(thread / GATE_WORD_BITS)));
}

static bool
gate_listed(const erx_backend_gates_t *gates, uint64_t thread)
{
	const uint64_t *const word = gate_listed_word(gates, thread);

	return (word != NULL && (*word >> (thread % GATE_WORD_BITS) & 1) != 0);
}

static void
gate_unlist(erx_backend_gates_t *gates, uint64_t thread)
{
	uint64_t *const word = gate_listed_word(gates, thread);

	if (word != NULL)
		*word &= ~(UINT64_C(1) << (thread % GATE_WORD_BITS));
}
