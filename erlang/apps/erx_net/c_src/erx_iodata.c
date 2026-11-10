/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The iodata walk of erx_bytes's per-byte primitives (erx_iodata.h). It holds the term it is
 * at in tail position, where a list cell, the empty list or a binary may stand, and looks at
 * each cell's head, where an integer byte, a binary or a list may stand. A head that is a
 * list is walked next, its cell's tail kept on the stack until it is done.
 */

#include "erx_iodata.h"

#include <stddef.h>
#include <stdint.h>
#include <strings.h>

/* The stack entries a walk holds before its stack moves to the heap. */
#define STACK_LOCAL	32u

/* The integer bytes gathered into one run before it is visited. */
#define RUN_BYTES	64u

/* A walk in progress. */
typedef struct walk {
	const erx_iodata_layer_t	*layer;
	erx_iodata_visit_t		*visit;
	void				*context;
	erx_iodata_term_t		 local[STACK_LOCAL];
	erx_iodata_term_t		*stack;		/* local, or a block of layer->resize */
	size_t				 depth, capacity;
	size_t				 bytes, cells;	/* taken so far, run included */
	uint8_t				 run[RUN_BYTES];
	size_t				 run_length;
} walk_t;

/* Visits the integer bytes gathered so far, if any, as one run. */
static void
flush_run(walk_t *walk)
{

	if (walk->run_length == 0)
		return;
	walk->visit(walk->context, walk->run, walk->run_length, walk->bytes - walk->run_length);
	walk->run_length = 0;
}

/* Takes one integer byte; false when it would pass ERX_BYTES_CALL_MAX. */
static bool
take_byte(walk_t *walk, uint8_t byte)
{

	if (walk->bytes == ERX_BYTES_CALL_MAX)
		return (false);
	walk->run[walk->run_length++] = byte;
	walk->bytes++;
	if (walk->run_length == RUN_BYTES)
		flush_run(walk);
	return (true);
}

/*
 * Takes a binary item, whose size classify has already held to the room left, and releases
 * its copy, if it has one.
 */
static void
take_binary(walk_t *walk, const erx_iodata_item_t *item)
{

	flush_run(walk);
	if (item->size > 0)
		walk->visit(walk->context, item->data, item->size, walk->bytes);
	walk->bytes += item->size;
	if (item->copy != NULL)
		walk->layer->release(walk->layer->env, item->copy);
}

/*
 * Keeps a tail for later, doubling the stack when it is full. The cell limit bounds the depth,
 * so the doubling cannot overflow. False when the layer cannot allocate.
 */
static bool
push(walk_t *walk, erx_iodata_term_t tail)
{
	erx_iodata_term_t *grown;
	size_t capacity;

	if (walk->depth == walk->capacity) {
		capacity = 2 * walk->capacity;
		grown = walk->layer->resize(walk->layer->env, walk->stack == walk->local ? NULL : walk->stack,
		    capacity * sizeof(*grown));
		if (grown == NULL)
			return (false);
		if (walk->stack == walk->local)
			bcopy(walk->local, grown, sizeof(walk->local));
		walk->stack = grown;
		walk->capacity = capacity;
	}
	walk->stack[walk->depth++] = tail;
	return (true);
}

/*
 * Takes the head of a cell. A head that is a list becomes *next, the term walked next, and
 * the cell's tail is pushed; otherwise *next is the tail.
 */
static erx_iodata_status_t
take_head(walk_t *walk, const erx_iodata_item_t *cell, erx_iodata_term_t *next)
{
	erx_iodata_item_t head;

	walk->layer->classify(walk->layer->env, cell->head, ERX_BYTES_CALL_MAX - walk->bytes, &head);
	*next = cell->tail;
	switch (head.kind) {
	case ERX_IODATA_BYTE:
		return (take_byte(walk, head.value) ? ERX_IODATA_OK : ERX_IODATA_BADARG);
	case ERX_IODATA_BINARY:
		take_binary(walk, &head);
		return (ERX_IODATA_OK);
	case ERX_IODATA_NIL:
		return (ERX_IODATA_OK);
	case ERX_IODATA_CELL:
		if (!push(walk, cell->tail))
			return (ERX_IODATA_NOMEM);
		*next = cell->head;
		return (ERX_IODATA_OK);
	case ERX_IODATA_OTHER:
		break;
	}
	return (ERX_IODATA_BADARG);
}

/* The walk itself, from term in tail position until the stack is empty or a rule breaks. */
static erx_iodata_status_t
walk_term(walk_t *walk, erx_iodata_term_t term)
{
	erx_iodata_item_t item;
	erx_iodata_status_t status;

	for (;;) {
		walk->layer->classify(walk->layer->env, term, ERX_BYTES_CALL_MAX - walk->bytes, &item);
		switch (item.kind) {
		case ERX_IODATA_CELL:
			if (++walk->cells > ERX_IODATA_CELLS_MAX)
				return (ERX_IODATA_BADARG);
			status = take_head(walk, &item, &term);
			if (status != ERX_IODATA_OK)
				return (status);
			continue;
		case ERX_IODATA_BINARY:
			take_binary(walk, &item);
			break;
		case ERX_IODATA_NIL:
			break;
		case ERX_IODATA_BYTE:
		case ERX_IODATA_OTHER:
			return (ERX_IODATA_BADARG);
		}
		if (walk->depth == 0)
			return (ERX_IODATA_OK);
		term = walk->stack[--walk->depth];
	}
}

erx_iodata_status_t
erx_iodata_walk(const erx_iodata_layer_t *layer, erx_iodata_term_t term, erx_iodata_visit_t *visit,
    void *context, erx_iodata_walked_t *walked)
{
	erx_iodata_status_t status;
	walk_t walk;

	walk.layer = layer;
	walk.visit = visit;
	walk.context = context;
	walk.stack = walk.local;
	walk.depth = 0;
	walk.capacity = STACK_LOCAL;
	walk.bytes = 0;
	walk.cells = 0;
	walk.run_length = 0;
	status = walk_term(&walk, term);
	if (status == ERX_IODATA_OK)
		flush_run(&walk);
	if (walk.stack != walk.local)
		layer->release(layer->env, walk.stack);
	walked->bytes = walk.bytes;
	walked->cells = walk.cells;
	return (status);
}
