/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The iodata walk of erx_bytes's per-byte primitives (erx_iodata.c) over terms the input
 * builds, against a recursive model that shares nothing with it. Terms may share subterms, as
 * Erlang terms do, so a short input can make a walk of any length: the limits on bytes and
 * cells are reached, and the stack moves to the heap. The walk must accept exactly what the
 * model accepts, visit exactly the model's bytes in order with the right offsets, never visit
 * an empty run, release every copy and block it was given, and give NOMEM, never a crash, when
 * its stack cannot grow.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <strings.h>

#include "erx_iodata.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/* The most terms an input builds; each refers only to terms before it, so none is a cycle. */
#define NODES_MAX	512u

/* A term of the input: its kind and, by kind, its byte, its binary or its cell's terms. */
typedef struct node {
	erx_iodata_kind_t	kind;
	uint8_t			byte;
	size_t			offset, size;	/* a binary: input bytes at offset */
	bool			copied;		/* a binary the layer copies, as at a bit offset */
	size_t			head, tail;	/* a cell: indexes of earlier terms */
} node_t;

typedef struct heap {
	const uint8_t	*input;
	node_t		 nodes[NODES_MAX];
	size_t		 count;
	size_t		 blocks;		/* allocations not yet released */
	size_t		 grows_left;		/* stack growths that succeed before one fails */
} heap_t;

/* What the walk visited, checked as it goes. */
typedef struct seen {
	uint8_t	bytes[ERX_BYTES_CALL_MAX];
	size_t	length;
} seen_t;

static void
classify(void *env, erx_iodata_term_t term, size_t room, erx_iodata_item_t *item)
{
	heap_t *heap = env;
	const node_t *node = &heap->nodes[term];
	uint8_t *copy;

	item->copy = NULL;
	item->kind = node->kind;
	switch (node->kind) {
	case ERX_IODATA_CELL:
		item->head = node->head;
		item->tail = node->tail;
		break;
	case ERX_IODATA_BYTE:
		item->value = node->byte;
		break;
	case ERX_IODATA_BINARY:
		if (node->size > room) {
			item->kind = ERX_IODATA_OTHER;
			break;
		}
		item->data = heap->input + node->offset;
		item->size = node->size;
		if (node->copied) {
			copy = malloc(node->size + 1);
			if (copy == NULL)
				abort();
			bcopy(item->data, copy, node->size);
			heap->blocks++;
			item->data = copy;
			item->copy = copy;
		}
		break;
	case ERX_IODATA_NIL:
	case ERX_IODATA_OTHER:
		break;
	}
}

static void *
resize(void *env, void *block, size_t bytes)
{
	heap_t *heap = env;
	void *grown;

	if (heap->grows_left == 0)
		return (NULL);
	heap->grows_left--;
	grown = realloc(block, bytes);
	if (grown == NULL)
		abort();
	if (block == NULL)
		heap->blocks++;
	return (grown);
}

static void
release(void *env, void *block)
{
	heap_t *heap = env;

	if (heap->blocks == 0)
		abort();
	heap->blocks--;
	free(block);
}

static void
visit(void *context, const uint8_t *data, size_t length, size_t before)
{
	seen_t *seen = context;

	if (length == 0 || before != seen->length || length > ERX_BYTES_CALL_MAX - seen->length)
		abort();
	bcopy(data, seen->bytes + seen->length, length);
	seen->length += length;
}

/* The model's walk so far: the bytes and cells taken, and whether a rule has broken. */
typedef struct model {
	uint8_t	bytes[ERX_BYTES_CALL_MAX];
	size_t	length, cells;
	bool	broken;
} model_t;

static void model_list(const heap_t *, size_t, model_t *);

/* Takes n bytes, or breaks the model when they would pass the byte limit. */
static void
model_take(model_t *model, const uint8_t *data, size_t n)
{

	if (n > ERX_BYTES_CALL_MAX - model->length) {
		model->broken = true;
		return;
	}
	bcopy(data, model->bytes + model->length, n);
	model->length += n;
}

/* An element of a list: a byte, a binary or a list. */
static void
model_element(const heap_t *heap, size_t index, model_t *model)
{
	const node_t *node = &heap->nodes[index];

	switch (node->kind) {
	case ERX_IODATA_BYTE:
		model_take(model, &node->byte, 1);
		break;
	case ERX_IODATA_BINARY:
		model_take(model, heap->input + node->offset, node->size);
		break;
	case ERX_IODATA_NIL:
	case ERX_IODATA_CELL:
		model_list(heap, index, model);
		break;
	case ERX_IODATA_OTHER:
		model->broken = true;
		break;
	}
}

/* A term in list position: a list whose tail may end in a binary, or a binary. */
static void
model_list(const heap_t *heap, size_t index, model_t *model)
{
	const node_t *node;

	for (node = &heap->nodes[index]; !model->broken; node = &heap->nodes[node->tail]) {
		switch (node->kind) {
		case ERX_IODATA_CELL:
			if (++model->cells > ERX_IODATA_CELLS_MAX) {
				model->broken = true;
				return;
			}
			model_element(heap, node->head, model);
			continue;
		case ERX_IODATA_BINARY:
			model_take(model, heap->input + node->offset, node->size);
			return;
		case ERX_IODATA_NIL:
			return;
		case ERX_IODATA_BYTE:
		case ERX_IODATA_OTHER:
			model->broken = true;
			return;
		}
	}
}

/*
 * Term 0 is []. The first input byte is how many stack growths succeed (0xff for all); the
 * rest are ops, each adding one term: op % 8 of 0 is [], 1 a byte (the next input byte), 2 and
 * 3 a binary of the next byte's count of input bytes (3 copied, as one at a bit offset is), 4
 * and 5 a cell of two earlier terms named by the next two bytes counting back from the newest,
 * 6 anything else, and 7 the cell [Newest], so a run of 7s nests deeply. The root is the newest.
 */
static void
build(heap_t *heap, const uint8_t *data, size_t size)
{
	node_t *node;
	size_t at = 1, back;
	uint8_t op;

	bzero(&heap->nodes[0], sizeof(heap->nodes[0]));
	heap->nodes[0].kind = ERX_IODATA_NIL;
	heap->count = 1;
	while (at < size && heap->count < NODES_MAX) {
		op = data[at++];
		node = &heap->nodes[heap->count];
		bzero(node, sizeof(*node));
		switch (op % 8) {
		case 0:
			node->kind = ERX_IODATA_NIL;
			break;
		case 1:
			node->kind = ERX_IODATA_BYTE;
			node->byte = at < size ? data[at++] : 0;
			break;
		case 2:
		case 3:
			node->kind = ERX_IODATA_BINARY;
			node->size = at < size ? data[at++] : 0;
			node->offset = at;
			if (node->size > size - at)
				node->size = size - at;
			at += node->size;
			node->copied = op % 8 == 3;
			break;
		case 4:
		case 5:
			node->kind = ERX_IODATA_CELL;
			back = at < size ? data[at++] : 0;
			node->head = heap->count - 1 - back % heap->count;
			back = at < size ? data[at++] : 0;
			node->tail = heap->count - 1 - back % heap->count;
			break;
		case 6:
			node->kind = ERX_IODATA_OTHER;
			break;
		case 7:
			node->kind = ERX_IODATA_CELL;
			node->head = heap->count - 1;
			node->tail = 0;
			break;
		}
		heap->count++;
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static heap_t heap;
	static seen_t seen;
	static model_t model;
	erx_iodata_layer_t layer = {
		.classify = classify, .resize = resize, .release = release, .env = &heap
	};
	erx_iodata_status_t status;
	erx_iodata_walked_t walked;

	if (size < 2)
		return (0);
	bzero(&heap, sizeof(heap));
	heap.input = data;
	heap.grows_left = data[0] == 0xff ? SIZE_MAX : data[0] % 8;
	build(&heap, data, size);
	seen.length = 0;
	status = erx_iodata_walk(&layer, heap.count - 1, visit, &seen, &walked);
	if (heap.blocks != 0)
		abort();
	if (status == ERX_IODATA_NOMEM)
		return (0);
	model.length = 0;
	model.cells = 0;
	model.broken = false;
	model_list(&heap, heap.count - 1, &model);
	if ((status == ERX_IODATA_OK) == model.broken)
		abort();
	if (status == ERX_IODATA_OK && (seen.length != model.length || walked.bytes != model.length ||
	    walked.cells != model.cells || bcmp(seen.bytes, model.bytes, model.length) != 0))
		abort();
	return (0);
}
