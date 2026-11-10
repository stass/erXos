/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_IODATA_H
#define ERX_IODATA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The walk of an iodata argument of erx_bytes's per-byte primitives (docs/design-runtime.md,
 * "Per-byte primitives"), written once for both term layers: erXos's BIFs
 * (otp/erts/emulator/nifs/erxos/erx_bytes_bif.c) and the portable NIF library outside erXos
 * (erx_bytes_nif.c beside this file). Each layer says what one term is through its classify
 * function; the walk decides everything else, so both builds accept and refuse the same
 * iodata by construction. Each layer checks a primitive's other arguments (a starting sum,
 * a key, inet_csum_update/3's binaries) itself.
 *
 * iodata here is Erlang's: a binary, or a proper list whose elements are integers 0..255,
 * binaries and such lists, and whose tail may be a binary. One call takes at most
 * ERX_BYTES_CALL_MAX bytes in lists of at most ERX_IODATA_CELLS_MAX cells in all, so its work is
 * bounded whatever the shape: a flood of empty lists or binaries is refused by the cells it
 * takes. Nested lists are walked with an explicit stack that grows on the heap, never by
 * recursion, so a deep list costs memory bounded by the cell limit and no C stack.
 */

/* The most bytes one call of a per-byte primitive works on, so it stays within a slice. */
#define ERX_BYTES_CALL_MAX	65536u

/*
 * The most list cells one walk visits: every byte as an integer in a cell of its own, and as
 * many cells again for the lists around them.
 */
#define ERX_IODATA_CELLS_MAX	(2u * ERX_BYTES_CALL_MAX)

/* A term as a term layer represents it: an Eterm or an ERL_NIF_TERM, both a word. */
typedef uintptr_t erx_iodata_term_t;

/* What a term is, as far as the walk needs to know. */
typedef enum erx_iodata_kind {
	ERX_IODATA_NIL,		/* the empty list */
	ERX_IODATA_CELL,	/* a list cell: head and tail */
	ERX_IODATA_BYTE,	/* an integer 0..255: byte */
	ERX_IODATA_BINARY,	/* a binary of whole bytes, at most room long: data and size */
	ERX_IODATA_OTHER	/* anything else, a binary longer than room included */
} erx_iodata_kind_t;

/*
 * One classified term. A binary at a bit offset is copied into bytes of whole bytes; copy is
 * then the layer's own handle on that copy, which release frees once the walk has visited it,
 * and NULL otherwise.
 */
typedef struct erx_iodata_item {
	erx_iodata_kind_t	kind;
	erx_iodata_term_t	head, tail;	/* ERX_IODATA_CELL */
	uint8_t			value;		/* ERX_IODATA_BYTE */
	const uint8_t		*data;		/* ERX_IODATA_BINARY */
	size_t			size;
	void			*copy;
} erx_iodata_item_t;

/*
 * A term layer. classify says what term is; a binary longer than room is ERX_IODATA_OTHER,
 * decided before anything is copied. resize is realloc for the walk's stack (block NULL for a
 * new one); it returns NULL when it cannot allocate. release frees a block of resize, or an
 * item's copy.
 */
typedef struct erx_iodata_layer {
	void	(*classify)(void *env, erx_iodata_term_t term, size_t room, erx_iodata_item_t *item);
	void	*(*resize)(void *env, void *block, size_t bytes);
	void	(*release)(void *env, void *block);
	void	*env;
} erx_iodata_layer_t;

/* What erx_iodata_walk calls on each run of bytes, with the count of bytes before the run. */
typedef void erx_iodata_visit_t(void *context, const uint8_t *data, size_t length, size_t before);

/* How much a walk did, for the reductions its call is charged. */
typedef struct erx_iodata_walked {
	size_t	bytes;
	size_t	cells;
} erx_iodata_walked_t;

/* Why a walk refused its term. */
typedef enum erx_iodata_status {
	ERX_IODATA_OK,
	ERX_IODATA_BADARG,	/* not iodata, or over either limit */
	ERX_IODATA_NOMEM	/* the stack could not grow */
} erx_iodata_status_t;

/*
 * Walks the iodata term, calling visit on its bytes in order, in runs. A run is a binary, or
 * up to a few dozen integer bytes gathered together; empty runs are not visited. *walked is
 * what the walk took, also on a refusal. On a refusal the walk has stopped where the term
 * broke the rules, and visit may already have run on the bytes before that point, so the
 * caller discards what visit built.
 */
erx_iodata_status_t erx_iodata_walk(const erx_iodata_layer_t *layer, erx_iodata_term_t term,
    erx_iodata_visit_t *visit, void *context, erx_iodata_walked_t *walked);

/*
 * What a call is charged, in reductions, so a loop of calls is preempted like any other. A
 * reduction slice is ERX_BYTES_SLICE_REDS reductions (ERTS's CONTEXT_REDS), about a
 * millisecond. A call over ERX_BYTES_CALL_MAX bytes is charged its primitive's REDS_AT_MAX,
 * in proportion for fewer, and a reduction for each ERX_IODATA_CELLS_PER_REDUCTION cells it
 * walked. Over 64 KiB the Internet checksum takes about 16 microseconds and SipHash-2-4 about
 * 110 on the development host (Apple M3 Max, native, clang 23.1.3 -O2), charged here a fiftieth
 * and a ninth of a slice; slower targets are a watch-list item (docs/todo-performance.md).
 */
#define ERX_BYTES_SLICE_REDS		4000u
#define ERX_IODATA_CELLS_PER_REDUCTION	64u
#define ERX_INET_CSUM_REDS_AT_MAX	80u
#define ERX_SIPHASH_REDS_AT_MAX		440u

/* The reductions of a call that took bytes in cells, its primitive's reds_at_max at 64 KiB. */
static inline size_t
erx_bytes_reductions(size_t bytes, size_t cells, size_t reds_at_max)
{

	return (1 + bytes * reds_at_max / ERX_BYTES_CALL_MAX + cells / ERX_IODATA_CELLS_PER_REDUCTION);
}

#endif
