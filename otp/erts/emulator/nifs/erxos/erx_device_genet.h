/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The register ring, GENET's descriptor form of the DMA handoff sequencer
 * (docs/design-device-dma.md, "The three descriptor forms" and "Install and reset"; the facts
 * in docs/research-genet-bcm2711.md). It reads no hardware and no shared memory, needs nothing
 * of ERTS and builds for the host, where its tests and its fuzz target run.
 *
 * A queue is one direction of the controller: the one ring the form uses, ring 16 as FreeBSD's
 * (if_genetreg.h:118), over all 256 of the direction's descriptors, and a pool of 256 buffers in
 * the device's memory. The descriptors are registers of the device's window, which the DMA
 * design treats as device memory, so the queue has no ring memory and its pool begins at its
 * first byte. Buffer i is descriptor i's for the life of the queue: the install publishes each
 * descriptor's address once, with the buffer size as its reach, and nothing else ever writes
 * an address. Each queue state is a pair of free-running 16-bit indexes, the one software
 * advances and the last one taken of those the hardware advances:
 *
 *   receive   standing: the install hands every buffer to the device. A completion observes
 *             the producer index, which may run ahead of the consumer index by at most the
 *             queue's size, then the status of each new descriptor, whose length may be at most
 *             the buffer size; it takes those buffers back and copies each frame, then hands
 *             them back and publishes the consumer index past them, whether or not the frame
 *             is good, so an errored frame never holds the ring;
 *   transmit  a post takes the descriptor the producer index names, writes the frame into its
 *             buffer and publishes the descriptor's status, then the producer index. A
 *             completion observes the consumer index, which may advance by at most the number
 *             in flight, and returns each tag with no bytes.
 *
 * An index or a length beyond its bound breaks the queue, which then refuses every call until
 * the reset. Every register offset and field mask comes from the device's generated table,
 * resolved by erx_device_genet_registers; no bit is written here by hand.
 */

#ifndef ERX_DEVICE_GENET_H
#define ERX_DEVICE_GENET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

#include "erx_device_core.h"
#include "erx_device_dma.h"

/*
 * The ring the form uses (ERX_GENET_RING), its descriptors (ERX_GENET_RING_SIZE) and the most
 * pieces of one transmit post (ERX_GENET_PIECES_MAX) are ABI limits, from abi/erx_abi.txt, which
 * the Ethernet driver's Erlang shares.
 */
/* The form's address width: the controller's DMA reaches 40 bits (FreeBSD's if_genet.c:618). */
#define ERX_DEVICE_GENET_ADDRESS_BITS	40u
/* The ring registers a direction's plans publish, which the context lists as owned; the descriptors are owned whole besides. */
#define ERX_DEVICE_GENET_OWNED		13u
/* The most steps of an install (an address per descriptor and the ring's registers), and of a post. */
#define ERX_DEVICE_GENET_INSTALL_STEPS	(ERX_GENET_RING_SIZE + ERX_DEVICE_GENET_OWNED)
#define ERX_DEVICE_GENET_POST_STEPS	(ERX_GENET_PIECES_MAX + 2u)

typedef enum erx_device_genet_direction {
	ERX_DEVICE_GENET_RX,
	ERX_DEVICE_GENET_TX,
} erx_device_genet_direction_t;

/*
 * One direction's registers as window offsets, and the field masks the form uses, in place,
 * from the generated table. `owned` lists the ring registers in the order of the fields from
 * `hardware_index` to `dma_ctrl`.
 */
typedef struct erx_device_genet_registers {
	erx_device_genet_direction_t	direction;
	uint32_t	desc_status;		/* descriptor 0's three registers, then each `desc_stride` on */
	uint32_t	desc_addr_lo;
	uint32_t	desc_addr_hi;
	uint32_t	desc_stride;
	uint32_t	hardware_index;		/* the ring's index the controller advances: RX producer, TX consumer */
	uint32_t	software_index;		/* the one the NIF advances: RX consumer, TX producer */
	uint32_t	buf_size;
	uint32_t	start[2];		/* each a word index into the descriptors: low register, then high */
	uint32_t	end[2];
	uint32_t	hardware_ptr[2];	/* the pointer the controller advances: RX write, TX read */
	uint32_t	software_ptr[2];	/* the one the NIF advances: RX read, TX write */
	uint32_t	ring_cfg;
	uint32_t	dma_ctrl;
	uint32_t	dma_status;		/* not owned: the idle report */
	uint32_t	owned[ERX_DEVICE_GENET_OWNED];
	/* Field masks, in place in their registers. */
	uint32_t	index;			/* INDEX of either ring index */
	uint32_t	buflen;			/* BUFLEN of a descriptor's status */
	uint32_t	sop;			/* SOP and EOP of a descriptor's status */
	uint32_t	eop;
	uint32_t	crc;			/* CRC of a transmit status: append the Ethernet CRC; 0 for receive */
	uint32_t	buf_length;		/* BUF_LENGTH and DESC_COUNT of the ring's size register */
	uint32_t	desc_count;
	uint32_t	ring_enable;		/* ENABLE of the ring configuration */
	uint32_t	dma_enable;		/* EN and RBUF_EN of DMA control */
	uint32_t	dma_ring_enable;
	uint32_t	dma_disabled;		/* DISABLED and RING_DISABLED of DMA status */
	uint32_t	dma_ring_disabled;
} erx_device_genet_registers_t;

/* One queue's bookkeeping, which its caller serialises. */
typedef struct erx_device_genet_queue {
	erx_device_genet_direction_t	direction;
	uint32_t	buffer_size;		/* each buffer's bytes, the reach of each descriptor's address */
	uint32_t	stride;			/* buffer_size rounded up to the granule: buffer i at i * stride */
	uint16_t	software;		/* the index the NIF last published */
	uint16_t	hardware;		/* the controller's index as far as the queue has taken it */
	uint32_t	in_flight;		/* TX: posted and not completed */
	uint32_t	taken;			/* RX: buffers from `software` taken back and not yet handed again */
	uint32_t	reported;		/* RX: the statuses the last erx_device_genet_rx_reports asked for */
	bool		installed;
	bool		broken;
	uint64_t	tags[ERX_GENET_RING_SIZE];	/* TX: each posted buffer's tag */
} erx_device_genet_queue_t;

/* A completed descriptor: its buffer, the bytes to copy (0 for transmit) and its tag. */
typedef struct erx_device_genet_completion {
	uint32_t	buffer;
	uint32_t	length;
	uint64_t	tag;			/* TX: the post's; RX: the status bits below the length, its flags */
} erx_device_genet_completion_t;

/*
 * The direction's registers from the device's table, the one ring's elements of each ring
 * register and descriptor 0's of each descriptor register. False for a table that lacks one,
 * or whose descriptors are not 256 of three registers each.
 */
bool	erx_device_genet_registers(const erx_device_peripheral_t *genet, erx_device_genet_direction_t direction,
	    erx_device_genet_registers_t *regs);

/*
 * An empty queue, not installed, of 256 buffers of `buffer_size` bytes at a stride rounded up to
 * `granule`, whose pool's device addresses from `pool_addr` lie below the form's width. False,
 * touching nothing, for a granule that is not a power of two up to ERX_DEVICE_GRANULE_MAX, a
 * buffer size of 0 or past what the status's and the ring's length fields hold or
 * ERX_DEVICE_BUFFER_MAX, or a pool that reaches the width.
 */
bool	erx_device_genet_init(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
	    uint32_t buffer_size, uint32_t granule, uint64_t pool_addr);
/* The bytes of a queue's pool, at most 256 * ERX_DEVICE_BUFFER_MAX. */
uint64_t	erx_device_genet_bytes(const erx_device_genet_queue_t *queue);

/* The form's facts for the check: its width, its register descriptors and their reach, and the ring registers as owned. */
void	erx_device_genet_form(const erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
	    erx_dma_length_reg_t *length_reg, erx_dma_context_t *context);
/* Who writes each buffer: the device while posted (TX), or while installed and not taken back (RX). */
void	erx_device_genet_view(const erx_device_genet_queue_t *queue, uint64_t pool_offset, erx_dma_state_t *state);

/*
 * The reset (docs/design-device-dma.md, "Install and reset"). The NIF writes DMA control with
 * erx_device_genet_stop's value, the engine and every ring's enable cleared, then observes DMA
 * status with erx_device_genet_idle_report until erx_device_genet_idle says the block and the
 * ring have stopped; only then does erx_device_genet_reset forget every buffer, so the reset's
 * plan takes every buffer back, and the install publishes the ring afresh.
 */
uint32_t	erx_device_genet_stop(const erx_device_genet_registers_t *regs);
void	erx_device_genet_idle_report(const erx_device_genet_registers_t *regs, erx_dma_step_t *step);
bool	erx_device_genet_idle(const erx_device_genet_registers_t *regs, uint64_t status);
/* False, forgetting nothing, unless `status`, DMA status as the idle report read it, shows the stop. */
bool	erx_device_genet_reset(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs, uint64_t status);

/*
 * The install, after the reset's plan: each descriptor's address with the buffer size as its
 * reach; the ring's indexes 0, its size and buffer length, its start, end and four pointers;
 * its configuration and DMA control with the ring's enable. The queue counts itself installed,
 * so the view after it hands a receive queue's every buffer to the device. 0, with nothing
 * changed, for a queue already installed: only init and the reset leave it empty.
 *
 * erx_device_genet_start is the step that follows, as a plan of its own: DMA control with the
 * engine's enable too. The design installs both directions' rings before it starts either
 * engine, receive first, so the caller orders the two directions' starts.
 */
uint32_t	erx_device_genet_install_steps(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
	    uint64_t pool_addr, erx_dma_step_t *steps);
void	erx_device_genet_start(const erx_device_genet_registers_t *regs, erx_dma_step_t *step);

/*
 * A transmit post of `count` pieces, 1..ERX_GENET_PIECES_MAX, laid end to end in the
 * buffer of the descriptor the producer index names, at most the buffer size in all: the
 * pieces' bytes, the descriptor's status (the length, start and end of packet and the appended
 * CRC), then the producer index. False, changing nothing, for a receive or broken queue, no
 * free descriptor, or pieces empty, too many or too long; *full says which of the last two.
 */
bool	erx_device_genet_post(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
	    uint64_t pool_offset, const erx_dma_piece_t *pieces, uint32_t count, uint64_t tag,
	    erx_dma_step_t *steps, uint32_t *step_count, bool *full);

/* The first observation of a completion: the index the controller advances. */
void	erx_device_genet_index_report(const erx_device_genet_registers_t *regs, erx_dma_step_t *step);

/*
 * A transmit completion from the consumer index register as one load read it: the descriptors
 * it moved past, at most `max` of them, each its tag. An advance beyond what is in flight
 * breaks the queue and is false. The decision that follows takes their buffers back with no copy.
 */
bool	erx_device_genet_tx_complete(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
	    uint64_t index_register, uint32_t max, erx_device_genet_completion_t *completions, uint32_t *done);

/*
 * A receive completion's second observation, from the producer index register as one load
 * read it: the status of each new descriptor, at most `max`. An advance beyond the queue's size
 * breaks the queue and is false.
 */
bool	erx_device_genet_rx_reports(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
	    uint64_t index_register, uint32_t max, erx_dma_step_t *steps, uint32_t *count);
/*
 * The decision from the `count` statuses those reports read, in order: each frame's buffer,
 * length and flags, until a length past the buffer size, which breaks the queue after the
 * frames before it. Their buffers are taken back, and the copies follow from
 * erx_device_genet_copy_steps; erx_device_genet_rx_give then hands them back. False, changing
 * nothing, unless `count` is what the reports just asked for on a receive queue whole.
 */
bool	erx_device_genet_rx_complete(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
	    const uint64_t *statuses, uint32_t count, erx_device_genet_completion_t *completions, uint32_t *done);
uint32_t	erx_device_genet_copy_steps(const erx_device_genet_queue_t *queue, uint64_t pool_offset,
	    const erx_device_genet_completion_t *completions, uint32_t count, erx_dma_step_t *steps);
/* The buffers taken back handed to the device again, and the consumer index published past them. */
uint32_t	erx_device_genet_rx_give(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
	    erx_dma_step_t *steps);


/*
 * The form's round function, the one entry the effect layer calls (erx_dma_round_t): each call
 * of erx_dma_request_t as the functions above make its rounds, in their order.
 *
 *   IDLE      the DMA status observed, then the end: ERX_OK when it shows the stop, else
 *             ERX_EBUSY, with the value read;
 *   INSTALL   the reset from that value, the take-back of every buffer, the install, the end;
 *             ERX_EINVAL, breaking the queue, when the value does not show the stop;
 *   START     DMA control with the engine's enable, a publish that keeps the state;
 *   POST      transmit only: the pieces into the buffer the producer index names;
 *   COMPLETE  transmit: the consumer index observed, then the take-back with an answer of no
 *             bytes per tag; receive: the producer index, the statuses, the take-back with a
 *             copy per frame, then the hand-back and the consumer index.
 */
void	erx_device_genet_round(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
	    const erx_dma_request_t *request, erx_dma_round_t *round);

#endif /* ERX_DEVICE_GENET_H */
