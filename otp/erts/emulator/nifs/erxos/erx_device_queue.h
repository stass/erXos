/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The pure core of a device's queue (docs/design-runtime.md, "The device NIF", Descriptors
 * and The reset rule), for virtio's split virtqueue, whose layouts abi/formats/virtio.txt
 * fixes. It reads no hardware and no shared memory, needs nothing of ERTS and builds for the
 * host, where its tests and its fuzz target run.
 *
 * The queue's rings lie in memory the device can write, so nothing here reads them. The core
 * keeps its own copy of what it posted: which descriptors are free, which chain each posted
 * head starts, the tag the driver wants back and the ranges of its buffer the device may
 * write. erx_device.c writes a post's plan into the rings and reads each used entry once,
 * and the core decides what that entry may mean:
 *
 *   post      a chain of 1..ERX_DEVICE_CHAIN_MAX segments of one buffer becomes a plan of
 *             descriptors whose addresses, NEXT links and WRITE flags the core alone
 *             computes, so no descriptor aims the device at anything but the buffer;
 *   used      the used ring's index, loaded once, says how many entries are new, which
 *             cannot exceed the chains in flight;
 *   complete  each new entry names a head the core posted and a length within what the
 *             chain let the device write, and gives back the tag, the buffer and the ranges
 *             to copy out; its descriptors return to the free list from the core's own links.
 *
 * Anything else a device writes breaks the queue: every later call fails until reset, so a
 * malformed completion never frees a buffer the device may still write. Reset is the reset
 * rule's last step, after the device has been reset by register writes: the queue forgets
 * every chain and starts again from empty rings.
 */

#ifndef ERX_DEVICE_QUEUE_H
#define ERX_DEVICE_QUEUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Bounds of this record, not of virtio: a queue's size, and the segments of one chain. */
#define ERX_DEVICE_QUEUE_SIZE_MAX	256u
#define ERX_DEVICE_CHAIN_MAX		4u

/* Where a queue of `size` entries puts its rings in one run of memory, and how long it is. */
typedef struct erx_device_queue_layout {
	uint32_t	desc;		/* the descriptor table */
	uint32_t	avail;		/* the available ring: its head, then size entries of u16 */
	uint32_t	used;		/* the used ring: its head, then size used elements */
	uint32_t	bytes;
} erx_device_queue_layout_t;

/* One segment of a chain: a range of the buffer, and whether the device writes it. */
typedef struct erx_device_segment {
	uint32_t	offset;
	uint32_t	length;
	bool		device_writes;
} erx_device_segment_t;

/* What the core remembers of a chain it posted, by the index of its head descriptor. */
typedef struct erx_device_chain {
	bool			posted;
	uint32_t		count;
	uint32_t		buffer;
	uint64_t		tag;
	uint64_t		writable;	/* the sum of the device-writable segments' lengths */
	erx_device_segment_t	segments[ERX_DEVICE_CHAIN_MAX];
} erx_device_chain_t;

/*
 * One queue's bookkeeping, which its caller serialises: the core takes no lock.
 *
 * next[] is both the free list and the links of every posted chain. A post takes its chain's
 * descriptors off the head of the free list in order and leaves their links as they were, so
 * a chain is its head followed by count - 1 steps through next[]; a release puts the chain
 * back at the head of the free list. The free list's tail link, and free_head when free_count
 * is 0, are stale, which is safe because every walk is bounded by count or free_count, never
 * by a link.
 */
typedef struct erx_device_queue {
	uint32_t		size;		/* a power of two, at most ERX_DEVICE_QUEUE_SIZE_MAX */
	uint16_t		avail_idx;	/* the available ring's running index */
	uint16_t		last_used;	/* the next used entry to complete, a running index */
	uint32_t		free_head;
	uint32_t		free_count;
	uint32_t		in_flight;	/* chains posted and not completed */
	/* Used entries from last_used that the last erx_device_queue_used announced; <= in_flight. */
	uint32_t		pending;
	bool			broken;
	uint16_t		next[ERX_DEVICE_QUEUE_SIZE_MAX];	/* free list and chain links */
	erx_device_chain_t	chains[ERX_DEVICE_QUEUE_SIZE_MAX];
} erx_device_queue_t;

/* One descriptor to write: its slot in the table and its fields, little-endian on write. */
typedef struct erx_device_desc_write {
	uint16_t	index;
	uint64_t	addr;
	uint32_t	len;
	uint16_t	flags;
	uint16_t	next;
} erx_device_desc_write_t;

/*
 * A post, decided whole: write the descriptors, then the head into the available ring's
 * slot, then, after a barrier, the ring's index; then ring the doorbell.
 */
typedef struct erx_device_post_plan {
	uint32_t		count;
	erx_device_desc_write_t	descs[ERX_DEVICE_CHAIN_MAX];
	uint16_t		avail_slot;
	uint16_t		head;
	uint16_t		avail_idx;
} erx_device_post_plan_t;

/* A completed chain: what the driver gave, and the ranges of its buffer to copy out, in order. */
typedef struct erx_device_completion {
	uint64_t		tag;
	uint32_t		buffer;
	uint32_t		length;		/* what the device wrote, the sum of the ranges */
	uint32_t		range_count;
	erx_device_segment_t	ranges[ERX_DEVICE_CHAIN_MAX];
} erx_device_completion_t;

/* False for a size that is not a power of two from 1 to ERX_DEVICE_QUEUE_SIZE_MAX. */
bool	erx_device_queue_layout(uint32_t size, erx_device_queue_layout_t *layout);

/* An empty queue of `size` entries, as after a reset; false, touching nothing, for a bad size. */
bool	erx_device_queue_init(erx_device_queue_t *queue, uint32_t size);
/* The reset rule's last step: every chain forgotten, the rings empty, the queue whole again. */
void	erx_device_queue_reset(erx_device_queue_t *queue);

/*
 * Posts a chain over pool buffer `buffer`, an index the core hands back at completion, of
 * `buffer_length` bytes at device address `buffer_addr`. False, changing nothing, for a broken
 * queue, a count outside 1..ERX_DEVICE_CHAIN_MAX, an empty segment or one outside the buffer,
 * a segment the device reads after one it writes, an address that overflows, or too few free
 * descriptors. The core counts the post as made, so the effects apply the plan whole.
 */
bool	erx_device_queue_post(erx_device_queue_t *queue, const erx_device_segment_t *segments, uint32_t count,
	    uint32_t buffer, uint64_t buffer_addr, uint32_t buffer_length, uint64_t tag, erx_device_post_plan_t *plan);

/*
 * How many used entries are new, given the used ring's index as one load read it. More than
 * the chains in flight breaks the queue and is false.
 */
bool	erx_device_queue_used(erx_device_queue_t *queue, uint16_t used_idx, uint32_t *count);
/* The used ring's slot of the next entry to complete. */
uint32_t	erx_device_queue_used_slot(const erx_device_queue_t *queue);

/*
 * Completes the next used entry, whose fields were each loaded once. False with nothing
 * changed when erx_device_queue_used announced no entry left. An id that names no posted
 * head, or a length beyond what the chain let the device write, breaks the queue and is false.
 */
bool	erx_device_queue_complete(erx_device_queue_t *queue, uint32_t id, uint32_t length,
	    erx_device_completion_t *completion);

#endif /* ERX_DEVICE_QUEUE_H */
