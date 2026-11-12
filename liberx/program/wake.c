/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Wake words and waiter lists (wake.h).  The word is the thread's own, a
 * thread-local umtx word, which only wakes change: a bump comes before
 * the umtx wake, so a sleep on the value read before the bump returns at
 * once, and a wake that finds the thread not yet asleep is not lost.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/program/wake.h"

static _Thread_local _Atomic uint32_t wake_word;

_Atomic uint32_t *
erx_prog_wake_word(void)
{
	return (&wake_word);
}

uint32_t
erx_prog_wake_seen(void)
{
	return (atomic_load(&wake_word));
}

void
erx_prog_waitq_join(erx_prog_waitq_t *q, erx_prog_waiter_t *w)
{
	w->word = &wake_word;
	w->prev = NULL;
	w->next = q->head;
	if (q->head != NULL)
		q->head->prev = w;
	q->head = w;
}

void
erx_prog_waitq_leave(erx_prog_waitq_t *q, erx_prog_waiter_t *w)
{
	if (w->prev != NULL)
		w->prev->next = w->next;
	else
		q->head = w->next;
	if (w->next != NULL)
		w->next->prev = w->prev;
	w->prev = w->next = NULL;
}

void
erx_prog_waitq_wake(const erx_prog_waitq_t *q)
{
	for (const erx_prog_waiter_t *w = q->head; w != NULL; w = w->next) {
		atomic_fetch_add(w->word, 1);
		(void)erx_umtx_wake((uint64_t)(uintptr_t)w->word, 1);
	}
}

void
erx_prog_wake_sleep(uint32_t seen)
{
	(void)erx_umtx_wait((uint64_t)(uintptr_t)&wake_word, seen, ERX_WAIT_FOREVER);
}
