/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_UMTX_TABLE_H
#define ERX_FIASCO_UMTX_TABLE_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

/*
 * The umtx table of one task (docs/design-stopgap.md, "The umtx table"): waiters
 * queued by word, in the order they came, and the wait and wake protocols over
 * them. It reads no clock and calls no kernel: the caller's effects lock the
 * table and move a thread's semaphore, so the host's tests run this same code.
 *
 * A thread taken off the queue is owed exactly one up, and only such a thread is.
 * So a semaphore holds 0 whenever its thread enters a wait.
 */

#define ERX_FIASCO_UMTX_BUCKETS	64u
/* A deadline that never comes. */
#define ERX_FIASCO_UMTX_FOREVER	UINT64_MAX

typedef struct erx_fiasco_umtx_node erx_fiasco_umtx_node_t;
struct erx_fiasco_umtx_node {
	erx_fiasco_umtx_node_t	*next;
	erx_fiasco_umtx_node_t	*prev;
	uint64_t		 addr;
	bool			 queued;
};

typedef struct erx_fiasco_umtx_table {
	erx_fiasco_umtx_node_t	*head[ERX_FIASCO_UMTX_BUCKETS];
	erx_fiasco_umtx_node_t	*tail[ERX_FIASCO_UMTX_BUCKETS];
} erx_fiasco_umtx_table_t;

/*
 * down blocks the node's thread until its up or the deadline, and returns false
 * at the deadline, never before it. absorb blocks until an up already on its way
 * arrives. up never blocks. No effect runs with the lock held, except that the
 * word is read under it.
 */
typedef struct erx_fiasco_umtx_effects {
	void	(*lock)(void *);
	void	(*unlock)(void *);
	bool	(*down)(void *, erx_fiasco_umtx_node_t *, uint64_t);
	void	(*absorb)(void *, erx_fiasco_umtx_node_t *);
	void	(*up)(void *, erx_fiasco_umtx_node_t *);
} erx_fiasco_umtx_effects_t;

/* The queue alone, which the caller's lock guards. */
void	erx_fiasco_umtx_queue(erx_fiasco_umtx_table_t *, erx_fiasco_umtx_node_t *, uint64_t);
bool	erx_fiasco_umtx_cancel(erx_fiasco_umtx_table_t *, erx_fiasco_umtx_node_t *);
/* Takes up to count waiters on addr, oldest first; chained through next. */
erx_fiasco_umtx_node_t *erx_fiasco_umtx_take(erx_fiasco_umtx_table_t *, uint64_t, uint32_t);

/* ERX_OK when woken or when the word differs, ERX_ETIMEDOUT at the deadline. */
int	erx_fiasco_umtx_wait(erx_fiasco_umtx_table_t *, const erx_fiasco_umtx_effects_t *, void *,
	    erx_fiasco_umtx_node_t *, const _Atomic uint32_t *, uint32_t, uint64_t);
/* How many waiters it woke. The waker stores the word before this call. */
uint32_t erx_fiasco_umtx_wake(erx_fiasco_umtx_table_t *, const erx_fiasco_umtx_effects_t *, void *,
	    const _Atomic uint32_t *, uint32_t);

#endif /* ERX_FIASCO_UMTX_TABLE_H */
