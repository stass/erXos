/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_WAKE_H
#define LIBERX_PROGRAM_WAKE_H

/*
 * A thread's wake word and the lists of threads waiting on an object
 * (docs/design-programs.md, "The event executor", and P6).  A wait on an
 * object is one loop: read the thread's wake word, check the call's
 * condition, and sleep on the word with the value read.  A
 * thread that waits on an object puts a waiter, which names its wake
 * word, on the object's list under the object's lock, before it lets that
 * lock go; whoever changes what the waiters wait for, under the same
 * lock, wakes the list: it bumps each waiter's word, then wakes its
 * thread.  So a change after the check bumps the word the thread read,
 * and its sleep returns at once, and a change before the check is seen by
 * it.  One thread may wait on several objects at once, as poll does, with
 * one waiter on each list, all naming its one word.
 *
 * A list is its object's lock's: every call here but erx_prog_wake_word,
 * erx_prog_wake_seen and erx_prog_wake_sleep needs it held.
 */

#include <stdatomic.h>
#include <stdint.h>

/* One thread's place on one object's list; the thread owns it, on its stack. */
typedef struct erx_prog_waiter {
	struct erx_prog_waiter	*prev;
	struct erx_prog_waiter	*next;
	_Atomic uint32_t	*word;		/* the waiting thread's wake word */
} erx_prog_waiter_t;

/* An object's waiters, the object's lock's. */
typedef struct erx_prog_waitq {
	erx_prog_waiter_t	*head;
} erx_prog_waitq_t;

/* The calling thread's wake word, and its value now, which a wait reads before its check. */
_Atomic uint32_t	*erx_prog_wake_word(void);
uint32_t	erx_prog_wake_seen(void);

/* Puts w, naming the calling thread's word, on q. */
void	erx_prog_waitq_join(erx_prog_waitq_t *q, erx_prog_waiter_t *w);
/* Takes w off q. */
void	erx_prog_waitq_leave(erx_prog_waitq_t *q, erx_prog_waiter_t *w);
/* Bumps the word of each waiter on q, then wakes its thread; the waiters stay on q. */
void	erx_prog_waitq_wake(const erx_prog_waitq_t *q);

/*
 * Sleeps on the calling thread's wake word while it still holds seen, the
 * value read before the check, until deadline (ERX_WAIT_FOREVER for none),
 * on erx_clock_ns's clock; returns at once when a wake bumped it.  It may
 * also return early, so the caller checks its condition and the deadline
 * again.
 */
void	erx_prog_wake_sleep(uint32_t seen, uint64_t deadline);

#endif /* !LIBERX_PROGRAM_WAKE_H */
