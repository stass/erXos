/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The pure core of DMA by devices that are not cache-coherent (docs/design-device-dma.md,
 * "The construction: handoffs of granules" and "Calls, observations and plans"). It reads no
 * hardware and no shared memory, needs nothing of ERTS and builds for the host, where its
 * tests run.
 *
 * A descriptor form describes a queue's memory as regions, each a whole number of granules,
 * and gives each region a writer, the CPU or the device, as a function of the queue's state.
 * A call is a plan, a list of steps over a closed set (write, publish, copy, report), and the
 * queue's state before and after it. From those alone:
 *
 *   erx_device_dma_check  validates the plan whole before any effect: the states differ only
 *                         as the call allows, every step stays inside the regions its kind may
 *                         touch, and every device address it writes lies inside the record's
 *                         memory as the device sees it and below the form's address width;
 *   erx_device_dma_order  derives the handoffs from the change of writers and returns the
 *                         effects in their one valid order: the zeroing, the writes, the
 *                         cleans and the publish barrier before each publish; or the clean and
 *                         invalidates, the completion barrier, the reads and the report
 *                         barrier of an observation; or the clean and invalidates and the
 *                         completion barrier before the copies of a decision that takes back.
 *
 * No form names a handoff, a cache operation or a barrier, so none can forget or misplace
 * one. For a coherent device the maintenance and the completion barrier are absent and the
 * other barriers stay. The effect layer runs the effects in order and decides nothing.
 *
 * Offsets are bytes from the start of the record's memory; a device address is the record's
 * device base plus an offset.
 */

#ifndef ERX_DEVICE_DMA_H
#define ERX_DEVICE_DMA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx_device_queue.h"

/* A queue's regions: each of its buffers, and at most two ring regions. */
#define ERX_DMA_REGIONS_MAX	(ERX_DEVICE_QUEUE_SIZE_MAX + 2u)
/* The marker of a register field left unused: no address is split over a second register. */
#define ERX_DMA_NO_REGISTER	UINT32_MAX
/* The marker of a form that publishes through registers only. */
#define ERX_DMA_NO_PUBLICATION	UINT64_MAX

typedef enum erx_dma_writer {
	ERX_DMA_CPU,
	ERX_DMA_DEVICE,
} erx_dma_writer_t;

typedef enum erx_dma_region_kind {
	ERX_DMA_RING,		/* a part of a queue's rings, written by one side while installed */
	ERX_DMA_BUFFER,		/* a pool buffer, the device's from its post to its completion */
} erx_dma_region_kind_t;

typedef struct erx_dma_region {
	uint64_t		offset;
	uint64_t		length;
	erx_dma_region_kind_t	kind;
	erx_dma_writer_t	writer;		/* in the state this region list describes */
} erx_dma_region_t;

/*
 * Who writes each region of a queue in one of its states, as the form's view of its own
 * bookkeeping gives it. The regions of two states of one queue are the same list in the same
 * order, ascending and disjoint; only the writers differ.
 */
typedef struct erx_dma_state {
	uint32_t		count;
	erx_dma_region_t	regions[ERX_DMA_REGIONS_MAX];
} erx_dma_state_t;

/*
 * The calls of the closed set a plan makes, and how each may change the writers:
 *
 *   OBSERVE   reads only (report steps); no writer changes;
 *   POST      hands over: buffers move from the CPU to the device and nothing else changes;
 *   INSTALL   hands over: from a state where the CPU writes every region, the rings take the
 *             writers the form names and buffers may pass to the device (a standing queue);
 *   COMPLETE  takes back: buffers move from the device to the CPU and nothing else changes;
 *   RESET     takes back, after the device's idle report: every region becomes the CPU's.
 */
typedef enum erx_dma_call {
	ERX_DMA_CALL_OBSERVE,
	ERX_DMA_CALL_POST,
	ERX_DMA_CALL_INSTALL,
	ERX_DMA_CALL_COMPLETE,
	ERX_DMA_CALL_RESET,
} erx_dma_call_t;

typedef enum erx_dma_step_kind {
	ERX_DMA_WRITE,		/* a store into memory the CPU writes: hand-over calls only */
	ERX_DMA_PUBLISH,	/* a write that tells the device: hand-over calls only */
	ERX_DMA_COPY,		/* bytes of a buffer coming back, to the caller: COMPLETE only */
	ERX_DMA_REPORT,		/* a read of the device's report: OBSERVE only */
} erx_dma_step_kind_t;

typedef enum erx_dma_target {
	ERX_DMA_MEMORY,		/* `offset` in the record's memory */
	ERX_DMA_REGISTER,	/* `reg`, a register's offset in the peripheral's window */
} erx_dma_target_t;

typedef enum erx_dma_source {
	ERX_DMA_BYTES,		/* `length` bytes from `bytes`: an out segment's */
	ERX_DMA_ZEROS,		/* `length` zero bytes, such as an install's rings */
	ERX_DMA_VALUE,		/* `value`, `width` bytes little-endian: a ring field or a register */
	ERX_DMA_ADDRESS,	/* `value`, a device address the device may reach `extent` bytes from */
} erx_dma_source_t;

/*
 * One step of a plan. A write names memory and any source; a publish names the form's
 * publication field or an owned register, with a value or an address; a copy names memory
 * and a length; a report names memory or a register, and a width. A register is 32 bits, so a
 * register step has width 4, except an address of width 8 published over two owned registers,
 * its low half in reg and its high half in reg_high, so the check sees the whole address in
 * one step.
 */
typedef struct erx_dma_step {
	erx_dma_step_kind_t	kind;
	erx_dma_target_t	target;
	erx_dma_source_t	source;
	uint32_t		width;		/* bytes of a value, an address or a report: 1, 2, 4 or 8 */
	uint32_t		reg;
	uint32_t		reg_high;	/* or ERX_DMA_NO_REGISTER */
	uint64_t		offset;
	uint64_t		length;		/* bytes, zeros and copies */
	uint64_t		value;
	uint64_t		extent;		/* an address's reach, at least 1 */
	const uint8_t		*bytes;
} erx_dma_step_t;

typedef struct erx_dma_plan {
	erx_dma_call_t		call;
	uint32_t		count;
	const erx_dma_step_t	*steps;
} erx_dma_plan_t;

/*
 * A queue call as every form takes it (docs/design-device-dma.md, "Calls, observations and
 * plans"). The form's round function answers it in rounds: each round is an observation or a
 * decision for the effect layer to run, or the call's end. The record's facts the form needs
 * come in the request, so a form keeps only its own bookkeeping:
 *
 *   INSTALL   the reset's decision, which takes every region back, then the install's; for a
 *             form that reads an idle report, `idle` is the value its IDLE call answered;
 *   POST      `count` pieces under `tag`, on a queue that is `ready` or not;
 *   COMPLETE  the device's completions, at most `answers_max` and, where the form copies bytes,
 *             as many as keep the copies within `bytes_max`;
 *   IDLE      the observation of the device's idle report, answered in `value`: ERX_OK when it
 *             shows the device holds no descriptor, ERX_EBUSY when not (the register ring);
 *   START     the publish that starts the device's engine after its install (the register ring).
 */
typedef enum erx_dma_request_kind {
	ERX_DMA_REQUEST_INSTALL,
	ERX_DMA_REQUEST_POST,
	ERX_DMA_REQUEST_COMPLETE,
	ERX_DMA_REQUEST_IDLE,
	ERX_DMA_REQUEST_START,
} erx_dma_request_kind_t;

/*
 * One piece of a post: `length` bytes the device reads from `bytes`, or `length` bytes it
 * writes. `names_region` says the piece is a region's entry the effect layer resolved, which a
 * form that takes no region refuses.
 */
typedef struct erx_dma_piece {
	const uint8_t	*bytes;
	uint32_t	length;
	bool		device_writes;
	bool		names_region;
} erx_dma_piece_t;

typedef struct erx_dma_request {
	erx_dma_request_kind_t	kind;
	uint32_t		queue;		/* the device's own number for the queue */
	uint64_t		device_base;	/* the device address of the queue's first byte */
	uint64_t		pool_offset;	/* the pool's first byte, past the rings */
	bool			ready;		/* POST: the queue is installed */
	uint64_t		tag;		/* POST */
	uint32_t		count;		/* POST */
	const erx_dma_piece_t	*pieces;	/* POST */
	uint32_t		answers_max;	/* COMPLETE */
	uint64_t		bytes_max;	/* COMPLETE */
	uint64_t		idle;		/* INSTALL */
} erx_dma_request_t;

/*
 * A buffer that came back, as the call answers it: its tag, the bytes the device wrote and the
 * next `copies` copy steps of the round's plan, in order, which fill those bytes end to end.
 */
typedef struct erx_dma_answer {
	uint64_t	tag;
	uint32_t	length;
	uint32_t	copies;
} erx_dma_answer_t;

/*
 * One round. In: its number from 0, and the `value_count` values the last round's observation
 * read, one per report step, by step index. Out: either `ends`, with the call's `status` (and
 * `value` for IDLE), or a plan of `count` steps of `call` written into `steps`, the state after
 * it written into `after` unless `keeps`, which says the plan changes no writer, and
 * `answer_count` answers written into `answers`. The arrays are the effect layer's: `answers`
 * holds ERX_DMA_ANSWERS_MAX, and `steps` the most steps of any form's call, which erx_device.c
 * asserts against each form's step bound. A form writes within its own bounds, never by a
 * count the round hands it, so no round writes more than ERX_DMA_ANSWERS_MAX answers. Each
 * form names its calls' rounds, by the plan each one makes.
 */
typedef struct erx_dma_round {
	uint32_t		round;
	const uint64_t		*values;
	uint32_t		value_count;
	bool			ends;
	int			status;
	uint64_t		value;
	erx_dma_call_t		call;
	uint32_t		count;
	erx_dma_step_t		*steps;
	bool			keeps;
	struct erx_dma_state	*after;
	uint32_t		answer_count;
	erx_dma_answer_t	*answers;
} erx_dma_round_t;

/* The most rounds of any call of any form: a receive completion's two observations, its take-back, its hand-back, its end. */
#define ERX_DMA_ROUNDS_MAX	5u
/* The most answers of one round, which a request's answers_max may not raise. */
#define ERX_DMA_ANSWERS_MAX	32u

/* The end of a call, with its status. */
static inline void
erx_dma_round_end(erx_dma_round_t *round, int status)
{
	round->ends = true;
	round->status = status;
}

/* A plan of `count` report steps from the round's steps, which changes no writer. */
static inline void
erx_dma_round_observe(erx_dma_round_t *round, uint32_t count)
{
	round->call = ERX_DMA_CALL_OBSERVE;
	round->count = count;
	round->keeps = true;
}

/*
 * What the check needs of the record and the form, which the caller takes from the record
 * and the form's own constants, never from the plan.
 */
typedef struct erx_dma_context {
	uint64_t	memory_size;	/* the record's memory, from offset 0 */
	uint64_t	device_base;	/* the device address of offset 0 */
	uint64_t	window_size;	/* the bytes of the peripheral's register window */
	uint32_t	address_bits;	/* the widest device address the form can hold, 1..64 */
	uint32_t	granule;	/* G: a power of two */
	uint64_t	publication;	/* the offset of the ring field the form publishes, or ERX_DMA_NO_PUBLICATION */
	uint32_t	publication_width;
	uint32_t	owned_count;
	const uint32_t	*owned;		/* the window offsets of the registers the NIF owns */
	/*
	 * Where the form's memory holds device addresses: `descriptor_count` descriptors of
	 * `descriptor_size` bytes from offset `descriptors`, each with an address of
	 * `address_width` bytes at `address_field` and the length the device may reach from it, of
	 * `length_width` bytes at `length_field`. A memory write that holds an address is an address
	 * step at a descriptor's address field, and the same plan writes that descriptor's length
	 * equal to the step's reach; nothing but zeros or such an address step stores over an
	 * address field. A count of 0 says the form's memory holds no address.
	 */
	uint64_t	descriptors;
	uint32_t	descriptor_count;
	uint32_t	descriptor_size;
	uint32_t	address_field;
	uint32_t	address_width;
	uint32_t	length_field;
	uint32_t	length_width;
	/*
	 * Where the peripheral's registers hold device addresses, for a form whose descriptors are
	 * registers (the register ring): `reg_descriptor_count` descriptors of `reg_descriptor_size`
	 * bytes from window offset `reg_descriptors`, each with its address over a low register at
	 * `reg_address_field` and a high one at `reg_address_high_field`, and its length in the bits
	 * `reg_length_mask` of the register at `reg_length_field`. The form gives each descriptor one
	 * buffer for the life of the queue, so every descriptor's reach is the one constant
	 * `reg_reach`: an address published at a descriptor is one step over its two registers with
	 * that reach, no other publish names either register, and a value published at a length
	 * register, a descriptor's or one of `length_regs`, holds a length of at most the reach. A
	 * count of 0 says the registers hold no address.
	 */
	uint32_t			reg_descriptors;
	uint32_t			reg_descriptor_count;
	uint32_t			reg_descriptor_size;
	uint32_t			reg_address_field;
	uint32_t			reg_address_high_field;
	uint32_t			reg_length_field;
	uint32_t			reg_length_mask;
	uint64_t			reg_reach;
	uint32_t			length_reg_count;
	const struct erx_dma_length_reg	*length_regs;
} erx_dma_context_t;

/* A register outside the descriptors whose bits `mask` hold a length the device moves at each descriptor's address. */
typedef struct erx_dma_length_reg {
	uint32_t	reg;
	uint32_t	mask;
} erx_dma_length_reg_t;

typedef enum erx_dma_effect_kind {
	ERX_DMA_EFFECT_ZERO,		/* store zeros over [offset, offset + length) */
	ERX_DMA_EFFECT_STEP,		/* run plan step `step`: its store, publish, copy or read */
	ERX_DMA_EFFECT_CLEAN,		/* clean to the point of coherency, at every `line` bytes */
	ERX_DMA_EFFECT_CLEAN_INVAL,	/* clean and invalidate, at every `line` bytes */
	ERX_DMA_EFFECT_BARRIER,
} erx_dma_effect_kind_t;

typedef enum erx_dma_barrier {
	ERX_DMA_BARRIER_PUBLISH,	/* after the handing over, before a write that tells the device */
	ERX_DMA_BARRIER_REPORT,		/* after the read of a report, before what it allows */
	ERX_DMA_BARRIER_COMPLETION,	/* after taking back, before the reads of what came back */
} erx_dma_barrier_t;

/* What a barrier orders before it against what follows it. */
#define ERX_DMA_ORDERS_LOADS	0x1u
#define ERX_DMA_ORDERS_STORES	0x2u

/*
 * One effect. Maintenance covers [offset, offset + length) with one instruction at each
 * multiple of `line` from `offset`; a barrier orders `orders` and, when `completes`, waits for
 * the cache maintenance issued before it, which only a non-coherent device needs.
 */
typedef struct erx_dma_effect {
	erx_dma_effect_kind_t	kind;
	erx_dma_barrier_t	barrier;
	uint32_t		orders;
	bool			completes;
	uint32_t		step;
	uint64_t		offset;
	uint64_t		length;
	uint32_t		line;
} erx_dma_effect_t;

/*
 * Room for the effects of a plan of `steps` steps over `regions` regions: at most one zeroing
 * per buffer and one more per fill inside it (regions + steps), one per write (steps), one
 * clean per region (regions), and a barrier, the step and a line's clean per publish
 * (3 * steps); an observation or a take-back needs fewer.
 */
#define ERX_DMA_EFFECTS_BOUND(regions, steps)	(3u * (regions) + 4u * (steps) + 4u)

typedef struct erx_dma_effects {
	uint32_t		capacity;
	uint32_t		count;
	erx_dma_effect_t	*effects;
} erx_dma_effects_t;

/*
 * True when the plan may run: the context is whole, the two states describe the same regions,
 * each inside the record's memory, on granules, ascending and disjoint, the writers change
 * only as the call allows, and every step is one the call may make, inside a region its kind
 * may touch. False for anything else, which is a bug in the form's core.
 */
bool	erx_device_dma_check(const erx_dma_context_t *context, const erx_dma_state_t *before,
	    const erx_dma_state_t *after, const erx_dma_plan_t *plan);

/*
 * The plan's effects in their one order into `effects`, for a device that is coherent or not,
 * with the CPU's granule G and smallest data cache line L, L <= G, both powers of two; G is
 * the same the check's context gave. False, with effects->count unspecified, when the two
 * states do not have the same number of regions or the effects do not fit; it relies on the
 * check for everything else, so the caller checks the plan first.
 */
bool	erx_device_dma_order(const erx_dma_state_t *before, const erx_dma_state_t *after,
	    const erx_dma_plan_t *plan, bool coherent, uint32_t granule, uint32_t line,
	    erx_dma_effects_t *effects);

#endif /* ERX_DEVICE_DMA_H */
