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
 * write. The queue owns its buffers too: buffer i, of buffer_size bytes at device address
 * pool + i * buffer_size, belongs to the chain whose head is descriptor i, so no two chains in
 * flight ever share a buffer, and none is taken without being posted. erx_device.c applies a
 * post's plan to the rings and reads each used entry once, and the core decides what that
 * entry may mean:
 *
 *   post      a chain of 1..ERX_DEVICE_CHAIN_MAX segments of the head's buffer becomes a plan of
 *             descriptor writes whose indexes, addresses, NEXT links and WRITE flags the core
 *             alone computes, so no descriptor aims the device at anything but the buffer;
 *   used      the used ring's index, loaded once, says how many entries are new, which
 *             cannot exceed the chains in flight;
 *   complete  each new entry names a head the core posted and a length within what the
 *             chain let the device write, and gives back the tag, the buffer and the ranges
 *             to copy out; its descriptors and its buffer return from the core's own links.
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
/* A buffer's largest size, so a post's copy and a completion's stay within a call's bound. */
#define ERX_DEVICE_BUFFER_MAX		65536u
/* The largest cache-writeback granule a queue lays out on: one page. */
#define ERX_DEVICE_GRANULE_MAX		4096u

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
	uint32_t		buffer_size;	/* each of the size buffers, 1..ERX_DEVICE_BUFFER_MAX */
	uint32_t		stride;		/* buffer_size rounded up to the granule: buffer i is at pool + i * stride */
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

/* A completed chain: its tag, its buffer, and the ranges of the buffer to copy out, in order. */
typedef struct erx_device_completion {
	uint64_t		tag;
	uint32_t		buffer;
	uint32_t		length;		/* what the device wrote, the sum of the ranges */
	uint32_t		range_count;
	erx_device_segment_t	ranges[ERX_DEVICE_CHAIN_MAX];
} erx_device_completion_t;

/*
 * The features a negotiation accepts of those the driver wants and the device offers: the
 * device type's own bits the driver wants; VERSION_1, which this core's split ring of
 * version 1 needs; ACCESS_PLATFORM whenever the device offers it, since every address the
 * NIF gives is the device's own view of memory; and never a bit that changes the ring or
 * the transport (abi/formats/virtio.txt). False for a device that does not offer VERSION_1.
 */
bool	erx_device_queue_features(uint64_t wanted, uint64_t offered, uint64_t *accepted);

/*
 * The rings of `size` entries for a CPU whose cache-writeback granule is `granule`: the used ring
 * starts on a granule and `bytes` is whole granules. False for a size that is not a power of two
 * from 1 to ERX_DEVICE_QUEUE_SIZE_MAX, or a granule that is not one up to ERX_DEVICE_GRANULE_MAX.
 */
bool	erx_device_queue_layout(uint32_t size, uint32_t granule, erx_device_queue_layout_t *layout);

/*
 * An empty queue of `size` entries and `size` buffers of `buffer_size` bytes from device address
 * `pool`, each at a stride of buffer_size rounded up to `granule`, so no two buffers share a
 * granule, as after a reset. False, touching nothing, for a bad size or granule, a buffer size of 0
 * or over ERX_DEVICE_BUFFER_MAX, or a pool whose end the address space cannot hold.
 */
bool	erx_device_queue_init(erx_device_queue_t *queue, uint32_t size, uint32_t buffer_size, uint32_t granule,
	    uint64_t pool);
/* The reset rule's last step: every chain forgotten, the rings empty, the queue whole again. */
void	erx_device_queue_reset(erx_device_queue_t *queue);

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


/*
 * The split ring as a descriptor form of the DMA handoff sequencer (docs/design-device-dma.md,
 * "Calls, observations and plans" and "The three descriptor forms"). Offsets are bytes from the
 * queue's first byte: its rings from 0, its pool at `pool_offset`, at or past the rings' end. Each
 * builder states, as plan steps, only what the core above decided; no builder names a cache
 * operation or a barrier, which erx_device_dma_order derives. The caller keeps the last state
 * it applied and passes it as the next plan's `before`, so the view of the core's bookkeeping
 * after a call is only ever the `after` the check compares with it.
 */
struct erx_dma_context;
struct erx_dma_state;
struct erx_dma_step;
struct erx_dma_request;
struct erx_dma_round;

/* The window offsets of the registers the split ring's plans write, which the NIF owns. */
typedef struct erx_device_queue_registers {
	uint32_t	sel;
	uint32_t	num;
	uint32_t	ready;
	uint32_t	notify;
	uint32_t	desc[2];	/* each address: the low word's register, then the high word's */
	uint32_t	driver[2];
	uint32_t	device[2];
} erx_device_queue_registers_t;

/* The most steps of a post (a write and four descriptor fields per segment, the entry and two publishes) and of an install. */
#define ERX_DEVICE_QUEUE_POST_STEPS	(5u * ERX_DEVICE_CHAIN_MAX + 3u)
#define ERX_DEVICE_QUEUE_INSTALL_STEPS	8u
/* The reports of one used entry: its id and its length. */
#define ERX_DEVICE_QUEUE_ENTRY_REPORTS	2u

/* The form's own facts for the check: its address width, publication and descriptors. */
void	erx_device_queue_form(const erx_device_queue_layout_t *layout, uint32_t size, struct erx_dma_context *context);
/*
 * Who writes each region as the core's bookkeeping gives it: the descriptor table and the
 * available ring the CPU, the used ring the device once installed and the CPU before, and each
 * buffer the device while its chain is posted.
 */
void	erx_device_queue_view(const erx_device_queue_t *queue, const erx_device_queue_layout_t *layout, uint64_t pool_offset,
	    bool installed, struct erx_dma_state *state);
/*
 * The install after a reset, for a queue whose rings' device address is `rings_addr`: both ring
 * regions zeroed, the queue `index` selected and sized, the three ring addresses published
 * with each ring's reach, then ready.
 */
uint32_t	erx_device_queue_install_steps(const erx_device_queue_t *queue, const erx_device_queue_layout_t *layout,
	    const erx_device_queue_registers_t *regs, uint32_t index, uint64_t rings_addr, struct erx_dma_step *steps);
/*
 * Posts a chain over the buffer of its head descriptor, which the completion hands back, and
 * writes the post as plan steps: per segment, a readable one's `bytes` into the head's buffer,
 * then its descriptor's address (`device_base` plus its bytes' offset, its length as its
 * reach), length, flags and next link; then the head into the available ring's entry, the
 * available index and the doorbell of queue `index`. Returns the count of steps, at most
 * ERX_DEVICE_QUEUE_POST_STEPS, or 0, writing nothing, for a broken queue, a count outside
 * 1..ERX_DEVICE_CHAIN_MAX, an empty segment or one outside the buffer, a segment the device
 * reads after one it writes, or too few free descriptors. The core counts the post as made,
 * so the effects apply the plan whole.
 */
uint32_t	erx_device_queue_post(erx_device_queue_t *queue, const erx_device_queue_layout_t *layout, uint64_t device_base,
	    uint64_t pool_offset, const erx_device_segment_t *segments, const uint8_t *const *bytes, uint32_t count,
	    uint64_t tag, const erx_device_queue_registers_t *regs, uint32_t index, struct erx_dma_step *steps);
/* The observation of the used ring's index. */
void	erx_device_queue_index_report(const erx_device_queue_layout_t *layout, struct erx_dma_step *step);
/* The observation of the next `fresh` used entries, at most the queue's size: each id, then each length. */
uint32_t	erx_device_queue_entry_reports(const erx_device_queue_t *queue, const erx_device_queue_layout_t *layout,
	    uint32_t fresh, struct erx_dma_step *steps);
/* The copies of `count` completions, each range of each buffer in order, at most ERX_DEVICE_CHAIN_MAX per completion. */
uint32_t	erx_device_queue_copy_steps(const erx_device_queue_t *queue, uint64_t pool_offset,
	    const erx_device_completion_t *completions, uint32_t count, struct erx_dma_step *steps);


/*
 * The form's round function, the one entry the effect layer calls (erx_dma_round_t): each call
 * of erx_dma_request_t as the functions above make its rounds, in their order.
 *
 *   INSTALL   the reset, whose decision takes every region back, then the install, the end;
 *   POST      the request's pieces as segments of the head's buffer laid end to end, then the
 *             post; ERX_EINVAL for pieces past the buffer, ERX_ECORRUPT for a queue not ready or
 *             broken, ERX_EWOULDBLOCK for too few free descriptors, in that order, then ERX_EINVAL
 *             for a post the core refuses (an empty piece, or one the device reads after one it
 *             writes);
 *   COMPLETE  the used index observed, then the entries it announces, at most answers_max;
 *             the core completes them in order until one is malformed or bytes_max are taken,
 *             and one decision takes their buffers back with a copy per range. ERX_ECORRUPT
 *             when the queue broke and nothing was completed.
 *
 * A piece naming a region is the region's entry, which the device reads like any bytes.
 */
void	erx_device_queue_round(erx_device_queue_t *queue, const erx_device_queue_layout_t *layout,
	    const erx_device_queue_registers_t *regs, const struct erx_dma_request *request, struct erx_dma_round *round);

#endif /* ERX_DEVICE_QUEUE_H */
