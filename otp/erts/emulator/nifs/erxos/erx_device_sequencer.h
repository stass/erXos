/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The sequencer (docs/design-device-dma.md, "The check", "Publication", "Releases"): the one
 * writer of every record a device reads and the one reader of every record it writes. It is a
 * pure function over the ledger: it reads no hardware and no shared memory, needs nothing of
 * ERTS and builds for the host, where its tests run. The effect layer applies what it returns,
 * in the order this header gives, and stores nothing else into a region holding a structure.
 *
 * A publication is judged by erx_dma_publication_check, then the sequencer places its run (each
 * description at a free record of its table, chained in the plan's order; each table placed in
 * order at its position), encodes every record whole through its meaning's generated encoder,
 * and each region entry through its layout's from the ledger's record of the region it names,
 * derives the activation and begins the publication's holding. A binding command's publication
 * also zeroes the ring it binds, writes the ring's link on lap 0 and cleans the ring, all before
 * the command's activation, as the holding binds it. An install places nothing and
 * begins no holding: it zeroes and cleans every table, derives the queue's size and its rings'
 * device addresses from the layout, and activates with the ready bit, so no ring is live before
 * it is zero in memory. What it returns is applied as:
 *   1. the zeros: rule 1's, every byte of a buffer passing to the device that no fill covers, and
 *      the whole region of an install's tables and of a ring a binding command binds;
 *   2. the fills, the publication's `out` bytes, at the offsets given here; a region entry's
 *      fill is empty here, since its entry is a store;
 *   3. the stores, each record whole, region entries included;
 *   4. the cleans, every range passing to the device, then the publish barrier;
 *   5. an install's registers, in order: virtio-mmio's after the queue's select, which the effect layer writes
 *      first from the record, since it banks them (Virtio 1.2, section 4.2.2);
 *   6. the activation: a run's one store, the clean of its line, then the doorbell; an install's
 *      ready bit.
 *
 * An acquisition reads a structure the device writes in two phases: the validity (a used ring's
 * index, or each event TRB's cycle bit from the consumer position on) gives how many records it
 * covers, then each record is read whole and consumed in order.
 * A record's meaning comes from its selector through the generated erx_report_meaning, and what
 * it ends from its meaning's `releases` mark through erx_report_releases. A record whose selector
 * names no meaning, or that releases no live holding, is refused, and the queue breaks: the
 * sequencer cannot tell what it would release, and a skip would consume a report the design
 * gives no meaning. A record whose meaning releases nothing, or one the form judges the design
 * gives no release, such as a short data stage's event, is passed: consumed, ending nothing.
 */

#ifndef ERX_DEVICE_SEQUENCER_H
#define ERX_DEVICE_SEQUENCER_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"
#include "erx_device_rules.h"

/* The widest record the sequencer writes: an input context's context (xHCI 1.2, 6.2.5, p. 460). */
#define ERX_DMA_STORE_BYTES_MAX		32u
/*
 * The contexts of an input context a publication carries: the input control context, the slot
 * context, and an endpoint context for each binding, or EP0's for Evaluate Context, which binds
 * none (the composition in erx_device_sequencer.c).
 */
#define ERX_DMA_INPUT_PARTS_MAX		(2u + ERX_DMA_BINDS_MAX)
/*
 * Each record of a run, its available entry, a region entry for each fill, each binding's link,
 * the input context, and the DCBAA entry of a slot whose device context EP0's binding hands over
 * (erx_dma_publish_controller).
 */
#define ERX_DMA_STORES_MAX		(ERX_DMA_HELD_RECORDS_MAX + ERX_DMA_FILLS_MAX + ERX_DMA_BINDS_MAX + \
					    ERX_DMA_INPUT_PARTS_MAX + 1u)
/*
 * Rule 1 leaves at most one gap before each fill of a buffer and one after the last; each binding's
 * ring; the device context EP0's binding hands over.
 */
#define ERX_DMA_ZEROS_MAX		(ERX_DMA_HELD_BUFFERS_MAX + ERX_DMA_FILLS_MAX + ERX_DMA_BINDS_MAX + 1u)
/*
 * Each buffer passing to the device, each record and the available entry, each binding's ring, and
 * the device context EP0's binding hands over with its DCBAA entry.
 */
#define ERX_DMA_CLEANS_MAX		(ERX_DMA_HELD_BUFFERS_MAX + ERX_DMA_HELD_RECORDS_MAX + ERX_DMA_BINDS_MAX + 2u)
/* An install's registers before its activation: virtio's four, or xHCI's eight. */
#define ERX_DMA_REGISTERS_MAX		8u

/* `length` bytes from `offset` of the record's memory. */
typedef struct erx_dma_range {
	uint64_t	offset;
	uint64_t	length;
} erx_dma_range_t;

/* One store: `length` bytes of `bytes`, at `offset` of the record's memory. */
typedef struct erx_dma_store {
	uint64_t	offset;
	uint32_t	length;
	uint8_t		bytes[ERX_DMA_STORE_BYTES_MAX];
} erx_dma_store_t;

/*
 * A register an install writes, by what it says: virtio-mmio's (Virtio 1.2, section 4.2.2), or an
 * xHCI controller's (docs/design-usb.md, "Install"). The effect layer maps each to the register or
 * field of its device it owns (erx_device.c), and writes an address as its low word's register,
 * then its high word's.
 */
typedef enum erx_dma_register {
	ERX_DMA_VIRTQ_NUM,	/* the queue's size, its tables' count */
	ERX_DMA_VIRTQ_DESC,	/* the descriptor table's device address */
	ERX_DMA_VIRTQ_DRIVER,	/* the available ring's */
	ERX_DMA_VIRTQ_DEVICE,	/* the used ring's */
	ERX_DMA_VIRTQ_READY,	/* 1: an install's activation */
	ERX_DMA_XHCI_SLOTS,		/* CONFIG.MaxSlotsEn: the slots the layout has */
	ERX_DMA_XHCI_DCBAA,		/* DCBAAP: the DCBAA's device address */
	ERX_DMA_XHCI_EVENT_RING_SIZE,	/* ERSTSZ: the segment table's entries, 1 */
	ERX_DMA_XHCI_INTERRUPT_MODERATION,	/* IMOD: the interval, in 250 ns units; its counter 0 */
	ERX_DMA_XHCI_EVENT_DEQUEUE,	/* ERDP: the event ring's consumer position, its busy bit clear */
	ERX_DMA_XHCI_SEGMENT_TABLE,	/* ERSTBA: the segment table's device address */
	ERX_DMA_XHCI_INTERRUPTER_ENABLE,	/* IMAN.IE: 1 */
	ERX_DMA_XHCI_COMMAND_RING,	/* CRCR: the command ring's position, its cycle state in bit 0 */
	ERX_DMA_XHCI_RUN,		/* USBCMD's run and interrupt enable: 1, an install's activation */
} erx_dma_register_t;

typedef struct erx_dma_register_write {
	erx_dma_register_t	reg;
	uint64_t		value;
} erx_dma_register_write_t;

/* The one write that makes a publication live: a run's store into memory, or an install's register. */
typedef enum erx_dma_activation_kind {
	ERX_DMA_ACTIVATE_STORE,
	ERX_DMA_ACTIVATE_REGISTER,
} erx_dma_activation_kind_t;

typedef struct erx_dma_activation {
	erx_dma_activation_kind_t	kind;
	erx_dma_store_t			store;	/* ERX_DMA_ACTIVATE_STORE's */
	erx_dma_register_write_t	reg;	/* ERX_DMA_ACTIVATE_REGISTER's */
} erx_dma_activation_t;

/* What a publication applies, in the header's order; fills[i] is publication->fills[i]'s place. */
typedef struct erx_dma_sequence {
	uint32_t		zero_count;
	erx_dma_range_t		zeros[ERX_DMA_ZEROS_MAX];
	uint32_t		fill_count;
	erx_dma_range_t		fills[ERX_DMA_FILLS_MAX];
	uint32_t		store_count;
	erx_dma_store_t		stores[ERX_DMA_STORES_MAX];
	uint32_t		clean_count;
	erx_dma_range_t		cleans[ERX_DMA_CLEANS_MAX];
	uint32_t		register_count;
	erx_dma_register_write_t	registers[ERX_DMA_REGISTERS_MAX];
	erx_dma_activation_t	activation;
} erx_dma_sequence_t;

/*
 * Judges `publication` and, when it passes, sequences it into `sequence` and begins its holding
 * in `ledger`; an install begins none. Any other verdict changes neither: it is a bug in the form's core, and the call
 * is badarg with nothing applied.
 */
erx_dma_verdict_t	erx_dma_publish(erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication,
			    erx_dma_sequence_t *sequence);

/*
 * The install of an xHCI controller's memory, laid out as `controller` and as the ledger's layout
 * was derived from it (erx_trb_form_layout), into `sequence` (docs/design-usb.md, "Install"): the
 * check finds the ledger idle, as the controller's halted and reset report leaves it; every byte
 * of the layout is zeroed and cleaned; DCBAA entry 0 names the scratchpad array, or stays 0 with
 * no page asked for; the array names each scratchpad page; the segment table's one entry names
 * the event ring and its TRBs; the command ring's link leads back to its first TRB on lap 0; then
 * the registers, in FreeBSD's order (xhci.c:329-428): the slot count, DCBAAP, the segment table's
 * size, the interrupter's moderation interval, the event ring's dequeue pointer at the ledger's
 * consumer position, the segment table's base, IMAN.IE, the command ring's position with its
 * cycle state; and USBCMD's run with its interrupt enable, the activation. It places nothing and
 * begins no holding. BREAKS_CALLS for a ledger that holds anything; BREAKS_MEANINGS for one with
 * no command or event ring, or an address an encoder refuses, neither of which a form's own layout
 * can have.
 */
erx_dma_verdict_t	erx_dma_install_controller(const erx_dma_ledger_t *ledger, const erx_device_trb_layout_t *controller,
			    erx_dma_sequence_t *sequence);

/*
 * erx_dma_publish for an xHCI controller laid out as `controller`, with the slot's device context
 * (docs/design-usb.md, "Bindings and holdings"). The controller owns slot k's device context
 * exactly while EP0 of slot k is bound: Address Device must bind EP0, the check binds no endpoint
 * already bound unless the command drops it, no command drops EP0, and only Disable Slot's
 * success ends that binding. So a publication that binds EP0 is the slot's first Address Device
 * since its Disable Slot or the controller's reset, and its sequence also zeroes the slot's device
 * context, stores DCBAA entry k naming it, and cleans both, before the activation (xHCI 1.2,
 * 4.3.3 step 6, p. 89; 6.2.1, p. 443). BREAKS_MEANINGS, changing nothing, for an EP0 binding of a
 * slot outside the layout or a context address the entry's encoder refuses.
 */
erx_dma_verdict_t	erx_dma_publish_controller(erx_dma_ledger_t *ledger, const erx_device_trb_layout_t *controller,
			    const erx_dma_publication_t *publication, erx_dma_sequence_t *sequence);

/*
 * Adds to `sequence` the clear of DCBAA entry `slot`, zeroed and cleaned, for the form to call when
 * it consumes a Disable Slot's success, never at its publication: the entry of a slot the
 * controller no longer holds is 0 (xHCI 1.2, 6.1, p. 441; the note of 4.6.4, p. 110). False for a
 * slot outside the layout, or a sequence with no room for the zero or its clean.
 */
bool	erx_dma_clear_slot_entry(const erx_device_trb_layout_t *controller, uint32_t slot, erx_dma_sequence_t *sequence);

/*
 * The validity of table `reports`, a used ring: the records its device-written index `index`
 * covers from the ledger's consumer position, at most `most`, into `*count`, kept in the ledger
 * as what erx_dma_consume may consume (erx_dma_ledger_acquire). False, changing nothing, when it
 * covers more than the live holdings, a malformed index that breaks the queue, or for a table
 * the device does not write.
 */
bool	erx_dma_acquire(erx_dma_ledger_t *ledger, uint32_t reports, uint16_t index, uint32_t most, uint32_t *count);

/*
 * Where the record `k` places past the consumer position of `reports` lies, to read whole;
 * empty past what the acquisition left.
 */
erx_dma_range_t	erx_dma_acquire_record(const erx_dma_ledger_t *ledger, uint32_t reports, uint32_t k);

/*
 * The live holding the record at the consumer position of `reports`, as the acquisition read
 * it, would end, without ending it, so a form judges the rest of the record first; its pointer
 * NULL where erx_dma_consume would refuse it. The pointer is the ledger's, valid until the
 * ledger changes; erx_dma_consume ends the holding only while it is live (erx_dma_found_t).
 */
erx_dma_found_t		erx_dma_report_holding(const erx_dma_ledger_t *ledger, uint32_t reports,
			    const erx_report_record_t *record);

/*
 * Consumes the record at the consumer position of table `reports`, ending the holding `found`
 * names, as erx_dma_report_holding gave it for that record, so the record is decoded once and
 * judged whole before anything ends. False, changing nothing, which breaks the queue, for a
 * NULL holding (a record past what the acquisition covered, one whose selector names no meaning,
 * one that releases nothing the split ring knows, or one naming no live holding) or one that has
 * ended since it was found (erx_dma_ledger_release_holding).
 */
bool	erx_dma_consume(erx_dma_ledger_t *ledger, uint32_t reports, erx_dma_found_t found);
/*
 * Where the cycle word of the record `k` places past the consumer position of table `reports`, an
 * event ring, lies, for the validity's one load of each; empty past one lap or for a table the
 * device does not write as an event ring.
 */
erx_dma_range_t	erx_dma_validity_word(const erx_dma_ledger_t *ledger, uint32_t reports, uint32_t k);
/*
 * The validity of table `reports`, an event ring, from `word_count` cycle words read at the places
 * erx_dma_validity_word gave, in order: the leading records whose cycle bit is the ledger's consumer
 * cycle state there, which toggles where the position wraps, stopping at the first that is not,
 * into `*count`, kept in the ledger as what may be consumed. A record not yet written is never
 * covered. False, changing nothing, for a table that is not an event ring or more words than its
 * records.
 */
bool	erx_dma_acquire_cycles(erx_dma_ledger_t *ledger, uint32_t reports, const uint32_t *words, uint32_t word_count,
	    uint32_t *count);
/*
 * Consumes the record at the consumer position of table `reports`, as the acquisition read it,
 * ending nothing (erx_dma_ledger_pass): one whose meaning releases nothing, or one whose release
 * names a record a live holding holds but not its head, as a short data stage's event names its
 * data stage. False, changing nothing, which breaks the queue, for a record past what the
 * acquisition covered, one whose selector names no meaning, or a release naming a live holding's
 * head, which only erx_dma_consume consumes, or a record no live holding holds.
 */
bool	erx_dma_pass(erx_dma_ledger_t *ledger, uint32_t reports, const erx_report_record_t *record);
/*
 * The device address of the record at the consumer position of table `reports`: what the event
 * ring's dequeue register names once a decision has consumed its reports; 0 for a table the
 * layout lacks.
 */
uint64_t	erx_dma_dequeue_address(const erx_dma_ledger_t *ledger, uint32_t reports);

/*
 * Whether `meaning` is a command whose TRB names the input context, which a publication of it carries
 * (xHCI 1.2, 6.4.3.4 to 6.4.3.6, pp. 490-492): Address Device, Configure Endpoint and Evaluate
 * Context. The one list of them.
 */
bool	erx_dma_carries_input_context(uint32_t meaning);

#endif /* ERX_DEVICE_SEQUENCER_H */
