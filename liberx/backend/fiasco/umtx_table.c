/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The umtx table's queue and protocols: see umtx_table.h for the invariant. The
 * compare and the enqueue share one lock hold, and a waker stores its word before
 * it takes the lock, so no wake falls between them.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/umtx_table.h"

static uint32_t umtx_bucket(uint64_t);
static void umtx_unlink(erx_fiasco_umtx_table_t *, erx_fiasco_umtx_node_t *);

/* A word is four bytes, so the low two bits of its address say nothing. */
static uint32_t
umtx_bucket(uint64_t addr)
{
	return ((uint32_t)((addr >> 2) % ERX_FIASCO_UMTX_BUCKETS));
}

static void
umtx_unlink(erx_fiasco_umtx_table_t *table, erx_fiasco_umtx_node_t *node)
{
	const uint32_t bucket = umtx_bucket(node->addr);

	if (node->prev != NULL)
		node->prev->next = node->next;
	else
		table->head[bucket] = node->next;
	if (node->next != NULL)
		node->next->prev = node->prev;
	else
		table->tail[bucket] = node->prev;
	node->next = NULL;
	node->prev = NULL;
	node->queued = false;
}

void
erx_fiasco_umtx_queue(erx_fiasco_umtx_table_t *table, erx_fiasco_umtx_node_t *node, uint64_t addr)
{
	const uint32_t bucket = umtx_bucket(addr);

	node->addr = addr;
	node->queued = true;
	node->next = NULL;
	node->prev = table->tail[bucket];
	if (node->prev != NULL)
		node->prev->next = node;
	else
		table->head[bucket] = node;
	table->tail[bucket] = node;
}

/* Whether the node was still queued: if not, a waker owes it an up. */
bool
erx_fiasco_umtx_cancel(erx_fiasco_umtx_table_t *table, erx_fiasco_umtx_node_t *node)
{
	if (!node->queued)
		return (false);
	umtx_unlink(table, node);
	return (true);
}

erx_fiasco_umtx_node_t *
erx_fiasco_umtx_take(erx_fiasco_umtx_table_t *table, uint64_t addr, uint32_t count)
{
	erx_fiasco_umtx_node_t *taken = NULL, *last = NULL, *node, *following;
	uint32_t found = 0;

	for (node = table->head[umtx_bucket(addr)]; node != NULL && found < count; node = following) {
		following = node->next;
		if (node->addr != addr)
			continue;
		umtx_unlink(table, node);
		if (last != NULL)
			last->next = node;
		else
			taken = node;
		last = node;
		found++;
	}
	return (taken);
}

int
erx_fiasco_umtx_wait(erx_fiasco_umtx_table_t *table, const erx_fiasco_umtx_effects_t *effects,
    void *context, erx_fiasco_umtx_node_t *node, const _Atomic uint32_t *word, uint32_t expected,
    uint64_t deadline)
{
	bool queued;

	effects->lock(context);
	if (atomic_load_explicit(word, memory_order_acquire) != expected) {
		effects->unlock(context);
		return (ERX_OK);
	}
	erx_fiasco_umtx_queue(table, node, (uint64_t)(uintptr_t)word);
	effects->unlock(context);

	if (effects->down(context, node, deadline))
		return (ERX_OK);

	effects->lock(context);
	queued = erx_fiasco_umtx_cancel(table, node);
	effects->unlock(context);
	if (queued)
		return (ERX_ETIMEDOUT);
	/* A waker took this node as the deadline came: its up is on the way. */
	effects->absorb(context, node);
	return (ERX_OK);
}

uint32_t
erx_fiasco_umtx_wake(erx_fiasco_umtx_table_t *table, const erx_fiasco_umtx_effects_t *effects,
    void *context, const _Atomic uint32_t *word, uint32_t count)
{
	erx_fiasco_umtx_node_t *node, *following;
	uint32_t woken = 0;

	effects->lock(context);
	node = erx_fiasco_umtx_take(table, (uint64_t)(uintptr_t)word, count);
	effects->unlock(context);

	/* A node's thread may run on as soon as its up lands: read next first. */
	for (; node != NULL; node = following) {
		following = node->next;
		effects->up(context, node);
		woken++;
	}
	return (woken);
}
