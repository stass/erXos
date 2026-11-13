/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DEVICE_GENET_MODEL_H
#define ERX_DEVICE_GENET_MODEL_H

/*
 * A model of GENET's controller: the device side of the register ring that
 * erx_device_genet.c drives (docs/design-device-dma.md, "The register ring"). It is the
 * one stand-in for the controller, used by the hosted runtime's stand-in device
 * (erx_device.c, under ERX_DEVICE_STAND_IN) and by the host test harness
 * (test/fixtures/erx_device_genet_model_harness.c), and it reads no ERTS, liberx or global
 * state, so it builds for the host anywhere.
 *
 * The controller sees its registers as a window of plain memory, the descriptors among
 * them, which the driver's stores have already reached when the model is told of them. It
 * reaches buffers only through the device addresses the descriptors hold, by the caller's
 * memory accessor, so a wrong published address shows as a refused or misplaced frame.
 * Each entry point is a step the device takes: a register store it acts on, a register
 * load that may change what it reports, and one move of each engine. The caller
 * serialises them, as the hosted device lock or the single-threaded harness does.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx_device_core.h"
#include "erx_device_genet.h"

/*
 * Device memory by device address: `read` copies the `length` bytes at `addr` into `bytes`,
 * `write` copies `bytes` to them, each false and copying nothing when [addr, addr + length)
 * is not all device memory.
 */
typedef struct erx_device_genet_memory {
	void	*context;
	bool	(*read)(void *context, uint64_t addr, uint8_t *bytes, uint32_t length);
	bool	(*write)(void *context, uint64_t addr, const uint8_t *bytes, uint32_t length);
} erx_device_genet_memory_t;

/* Where a transmitted frame's `length` bytes go, never NULL; the tag is the descriptor's index. */
typedef uint8_t	*erx_device_genet_model_sink_t(void *context, uint64_t tag, uint32_t length);

/* A frame the receive engine writes into the next free buffer. */
typedef struct erx_device_genet_model_frame {
	const uint8_t	*bytes;
	uint32_t	written;	/* how many of `bytes` it writes, at most `length` */
	uint32_t	length;		/* the length its status reports */
	uint32_t	flags;		/* the status bits it reports beside the length */
	bool		aligned;	/* ALIGN_2B: two zero bytes before the frame, counted in the length */
} erx_device_genet_model_frame_t;

typedef struct erx_device_genet_model {
	volatile uint8_t		*window;	/* the registers, by byte offset, 32-bit aligned */
	erx_device_genet_registers_t	regs[2];	/* by erx_device_genet_direction_t */
	uint32_t			stop_reads;	/* DMA status reads a stop takes to show */
	uint32_t			reads[2];	/* DMA status reads since DMA control stopped each engine */
	uint32_t			rev;		/* SYS_REV_CTRL's offset and its MAJOR field */
	uint32_t			rev_major;
	uint32_t			mdio;		/* MDIO_CMD's offset and its fields */
	uint32_t			mdio_busy;
	uint32_t			mdio_read;
	uint32_t			mdio_reg;
	uint32_t			mdio_value;
} erx_device_genet_model_t;

/*
 * A model over `window`, the registers of the device the table `genet` describes; it
 * stores nothing. With `stop_reads` 0 a stop shows at the store that makes it, so the model
 * then keeps nothing between calls but what the window holds; otherwise it shows only after
 * that many reads of DMA status. False for a table that lacks a register or field the
 * model reads.
 */
bool	erx_device_genet_model_init(erx_device_genet_model_t *model, const erx_device_peripheral_t *genet,
	    volatile uint8_t *window, uint32_t stop_reads);

/* The registers' values before the driver stores anything: the revision. */
void	erx_device_genet_model_preset(erx_device_genet_model_t *model);

/*
 * The device's side of the store of `value` at `offset`, which the window already holds: an
 * MDIO command finishes at once, and DMA control starts the stop count of its direction.
 */
void	erx_device_genet_model_stored(erx_device_genet_model_t *model, uint32_t offset, uint32_t value);

/* A load of the register at `offset`, as the driver reads it; a read of DMA status counts toward a stop. */
uint32_t	erx_device_genet_model_load(erx_device_genet_model_t *model, uint32_t offset);

/*
 * Whether the direction's engine moves frames: DMA control's EN and the ring's enable in DMA
 * control and in its configuration, as erx_device_genet.c's start leaves them.
 */
bool	erx_device_genet_model_running(const erx_device_genet_model_t *model, erx_device_genet_direction_t direction);

/* The bytes each of the direction's buffers holds, from its ring's size register. */
uint32_t	erx_device_genet_model_buffer_bytes(const erx_device_genet_model_t *model,
		    erx_device_genet_direction_t direction);

/*
 * The transmit engine, when it runs, sends each descriptor from the consumer index up to the
 * producer index: its bytes to `sink`, tagged with the descriptor's index, counted in
 * `sent`, and the consumer index moved past it. ERX_ECORRUPT, sending nothing, for a producer
 * index more than the ring's size ahead of the consumer index; ERX_ECORRUPT, with the consumer index at the
 * descriptor, for one that is not a whole frame with its CRC (start and end of packet and
 * CRC set), whose length is over the buffer size, or whose address does not reach its bytes;
 * for that last the sink has been handed a buffer for it, which is not counted. ERX_OK
 * otherwise, a stopped engine sending nothing.
 */
int	erx_device_genet_model_transmit(erx_device_genet_model_t *model, const erx_device_genet_memory_t *memory,
	    erx_device_genet_model_sink_t *sink, void *context, uint32_t *sent);

/*
 * The receive engine, when it runs and a buffer is free, writes `frame` into the buffer of
 * the descriptor the producer index names, sets that descriptor's status to the frame's
 * length and flags and moves the producer index past it; `taken` says whether it did.
 * ERX_EINVAL for a frame whose bytes are over its length, or whose length is over the buffer
 * size or the status's length field, taking nothing. ERX_ECORRUPT for a descriptor whose
 * address does not reach the frame's bytes, the status and index left as they were. ERX_OK
 * otherwise, a stopped engine or a full ring taking nothing.
 */
int	erx_device_genet_model_receive(erx_device_genet_model_t *model, const erx_device_genet_memory_t *memory,
	    const erx_device_genet_model_frame_t *frame, bool *taken);

#endif /* ERX_DEVICE_GENET_MODEL_H */
