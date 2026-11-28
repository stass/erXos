/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The sequencer: see erx_device_sequencer.h.
 *
 * The ERX_DMA_SEED_* macros below plant the faults test/host/erx_device_sequencer_test.rb shows
 * its harness catches (docs/design-device-dma.md, Verification): rule 1's zeros left out, so a
 * stale byte reaches a buffer the device holds. The INSTALL_* seeds, which
 * test/host/erx_device_virtio_core_test.rb shows its harness catches, plant faults in the install:
 * the used ring left unzeroed; the used ring's register given the available ring's address, a
 * value not from the layout's used table; the rings' cleans left out, so the ready bit comes
 * before the zeroing reaches memory. SLOT_CONTEXT_UNZEROED, which
 * test/host/erx_device_trb_form_test.rb shows its harness catches, hands a slot's device context
 * to the controller at its first Address Device with what the slot's former device left in it.
 */

#include "erx_device_sequencer.h"

#include "liberx/backend/core/mem.h"

_Static_assert(sizeof(erx_virtq_desc_t) <= ERX_DMA_STORE_BYTES_MAX &&
    sizeof(erx_virtio_gpu_mem_entry_t) <= ERX_DMA_STORE_BYTES_MAX, "every record the sequencer encodes fits a store");
_Static_assert(sizeof(erx_xhci_trb_normal_t) <= ERX_DMA_STORE_BYTES_MAX, "a TRB fits a store");
/* The split ring's three tables, the only layout an install takes. */
#define SPLIT_RING_TABLES	3u
_Static_assert(SPLIT_RING_TABLES <= ERX_DMA_ZEROS_MAX && SPLIT_RING_TABLES <= ERX_DMA_CLEANS_MAX,
    "an install zeroes and cleans every table");
/*
 * The least time between two of an xHCI interrupter's interrupts, in 250 ns units (xHCI 1.2,
 * 5.5.2.2, Table 5-39, p. 426): FreeBSD's XHCI_IMOD_DEFAULT, 125 us (xhcireg.h:176, written at
 * xhci.c:369). The reset value, 4000 (1 ms), delays an interrupt until 1 ms after the driver cleared
 * the last one's pending bit, so each step of a run of short transfers waits about 1 ms.
 */
#define XHCI_MODERATION_INTERVAL	500u

#ifdef ERX_DMA_SEED_CYCLE_INVERTED
#define SEED_CYCLE_INVERTED	true
#else
#define SEED_CYCLE_INVERTED	false
#endif
#ifdef ERX_DMA_SEED_INSTALL_NOT_ZEROED
#define SEED_INSTALL_NOT_ZEROED	true
#else
#define SEED_INSTALL_NOT_ZEROED	false
#endif
#ifdef ERX_DMA_SEED_INSTALL_REGISTER
#define SEED_INSTALL_REGISTER	true
#else
#define SEED_INSTALL_REGISTER	false
#endif
#ifdef ERX_DMA_SEED_INSTALL_UNCLEANED
#define SEED_INSTALL_UNCLEANED	true
#else
#define SEED_INSTALL_UNCLEANED	false
#endif
#ifdef ERX_DMA_SEED_FIRST_CYCLE_LIVE
#define SEED_FIRST_CYCLE_LIVE	true
#else
#define SEED_FIRST_CYCLE_LIVE	false
#endif

#ifdef ERX_DMA_SEED_NO_ZEROS
#define SEED_NO_ZEROS		true
#else
#define SEED_NO_ZEROS		false
#endif

#ifdef ERX_DMA_SEED_CONFIGURE_ADDS_EP0
#define SEED_CONFIGURE_ADDS_EP0	true
#else
#define SEED_CONFIGURE_ADDS_EP0	false
#endif
#ifdef ERX_DMA_SEED_DEQUEUE_OTHER_RING
#define SEED_DEQUEUE_OTHER_RING	true
#else
#define SEED_DEQUEUE_OTHER_RING	false
#endif
#ifdef ERX_DMA_SEED_DROP_MISSING
#define SEED_DROP_MISSING	true
#else
#define SEED_DROP_MISSING	false
#endif
#ifdef ERX_DMA_SEED_SLOT_CONTEXT_UNZEROED
#define SEED_SLOT_CONTEXT_UNZEROED	true
#else
#define SEED_SLOT_CONTEXT_UNZEROED	false
#endif

/* A binding starts its ring at its first record on lap 0, whose cycle state is 1 (xHCI 1.2, 4.3.3, pp. 88-89; 4.9.2, p. 174). */
#define BINDING_START_CYCLE	1u
/* The average TRB length of a control endpoint's context (xHCI 1.2, 6.2.3, the note on p. 454). */
#define CONTROL_AVERAGE_TRB_LENGTH	8u
_Static_assert(ERX_XHCI_SLOT_CONTEXT_SIZE <= ERX_DMA_STORE_BYTES_MAX &&
    ERX_XHCI_ENDPOINT_CONTEXT_SIZE == ERX_XHCI_SLOT_CONTEXT_SIZE &&
    ERX_XHCI_INPUT_CONTROL_CONTEXT_SIZE == ERX_XHCI_SLOT_CONTEXT_SIZE, "each context is one store of one size");

/* The offset of byte `offset` of buffer `buffer` in the record's memory. */
static uint64_t
buffer_offset(const erx_dma_layout_t *layout, uint32_t buffer, uint64_t offset)
{
	return (erx_dma_layout_buffer_offset(layout, buffer, offset));
}

static uint64_t
record_offset(const erx_dma_layout_t *layout, erx_dma_place_t place)
{
	const erx_dma_table_t *table = &layout->tables[place.table];

	return (table->first + (uint64_t)place.index * table->stride);
}

static void
add_range(erx_dma_range_t *ranges, uint32_t *count, uint64_t offset, uint64_t length)
{
	if (length != 0)
		ranges[(*count)++] = (erx_dma_range_t){ offset, length };
}

/*
 * Rule 1 for one buffer: the gaps between its fills over its first `size` bytes. Each gap ends
 * where a fill begins, or at the end, so a buffer adds at most one more gap than its fills.
 */
static void
zero_gaps(const erx_dma_layout_t *layout, const erx_dma_publication_t *publication, uint32_t buffer,
    erx_dma_sequence_t *sequence)
{
	uint64_t cursor = 0;

	uint32_t pool;
	const uint64_t size = erx_dma_layout_buffer_pool(layout, buffer, &pool)->size;

	while (cursor < size) {
		uint64_t covered = cursor, next = size;

		for (uint32_t index = 0; index < publication->fill_count; index++) {
			const erx_dma_fill_t *fill = &publication->fills[index];

			if (fill->buffer != buffer || fill->length == 0)
				continue;
			if (fill->offset <= cursor && fill->offset + fill->length > covered)
				covered = fill->offset + fill->length;
			else if (fill->offset > cursor && fill->offset < next)
				next = fill->offset;
		}
		if (covered > cursor) {
			cursor = covered;
			continue;
		}
		add_range(sequence->zeros, &sequence->zero_count, buffer_offset(layout, buffer, cursor), next - cursor);
		cursor = next;
	}
}

/*
 * A table's 16-bit running index at its position: exact modulo 2^16 because the table's count,
 * a power of two up to ERX_DEVICE_QUEUE_SIZE_MAX, divides 2^16 (Virtio 1.2, 2.7.6).
 */
static uint16_t
running_index(const erx_dma_ledger_t *ledger, uint32_t table)
{
	const erx_dma_position_t position = erx_dma_ledger_position(ledger, table);

	return ((uint16_t)((uint64_t)position.lap * erx_dma_ledger_layout(ledger)->tables[table].count + position.index));
}

/* The lowest record of `table` no holding holds and not among the `count` already placed. */
static uint32_t
free_record(const erx_dma_ledger_t *ledger, uint32_t table, const erx_dma_place_t *placed, uint32_t count)
{
	uint32_t index = 0;

	for (;; index++) {
		bool taken = erx_dma_ledger_record_held(ledger, (erx_dma_place_t){ table, index });

		for (uint32_t earlier = 0; earlier < count && !taken; earlier++)
			taken = placed[earlier].table == table && placed[earlier].index == index;
		if (!taken)
			return (index);
	}
}

/* A command TRB's 16 bytes, as its encoder wrote them, into `store`. */
static bool
command_store(erx_dma_store_t *store, const void *record)
{
	store->length = ERX_XHCI_TRB_ALIGN;
	bcopy(record, store->bytes, ERX_XHCI_TRB_ALIGN);
	return (true);
}

/* The device address of ring `ring`'s position, where the controller resumes it. */
static uint64_t
ring_position_address(const erx_dma_ledger_t *ledger, uint32_t ring)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(ledger);

	return (layout->device_base + record_offset(layout, (erx_dma_place_t){ ring, erx_dma_ledger_position(ledger, ring).index }));
}

/*
 * One description's record, whole, through its meaning's encoder: its references' addresses
 * from its names and the layout, the chain's link to `next` when the run goes on, and a TRB's
 * cycle bit `cycle`. False for a meaning the sequencer has no encoder for yet, or a value its
 * encoder refuses.
 */
static bool
encode(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication, const erx_dma_description_t *description,
    erx_dma_place_t place, const erx_dma_place_t *next, uint32_t cycle, erx_dma_store_t *store)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(ledger);
	const erx_dma_reach_t *const target = &publication->reach;
	/* A TRB names at most one buffer, its data; one that names none has no address place. */
	const uint64_t data = description->name_count == 0 ? 0 : layout->device_base +
	    buffer_offset(layout, description->names[0].buffer, description->names[0].offset);

	*store = (erx_dma_store_t){ .offset = record_offset(layout, place) };
	switch (description->meaning) {
	case ERX_MEANING_VIRTQ_DESC: {
		const erx_virtq_desc_placed_t placed = {
			.addr = layout->device_base + buffer_offset(layout, description->names[0].buffer,
			    description->names[0].offset),
			.flags_next = next != NULL,
			.next = next != NULL ? next->index : 0,
		};
		erx_virtq_desc_t record;

		if (!erx_virtq_desc_encode(&record, &description->described.virtq_desc, &placed))
			return (false);
		store->length = sizeof(record);
		bcopy(&record, store->bytes, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_NORMAL: {
		const erx_xhci_trb_normal_placed_t placed = { .buffer = data, .control_cycle = cycle };
		erx_xhci_trb_normal_t record;

		if (!erx_xhci_trb_normal_encode(&record, &description->described.xhci_trb_normal, &placed))
			return (false);
		store->length = sizeof(record);
		bcopy(&record, store->bytes, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_DATA: {
		const erx_xhci_trb_data_placed_t placed = { .buffer = data, .control_cycle = cycle };
		erx_xhci_trb_data_t record;

		if (!erx_xhci_trb_data_encode(&record, &description->described.xhci_trb_data, &placed))
			return (false);
		store->length = sizeof(record);
		bcopy(&record, store->bytes, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_SETUP: {
		const erx_xhci_trb_setup_placed_t placed = { .control_cycle = cycle };
		erx_xhci_trb_setup_t record;

		if (!erx_xhci_trb_setup_encode(&record, &description->described.xhci_trb_setup, &placed))
			return (false);
		store->length = sizeof(record);
		bcopy(&record, store->bytes, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_STATUS: {
		const erx_xhci_trb_status_placed_t placed = { .control_cycle = cycle };
		erx_xhci_trb_status_t record;

		if (!erx_xhci_trb_status_encode(&record, &description->described.xhci_trb_status, &placed))
			return (false);
		store->length = sizeof(record);
		bcopy(&record, store->bytes, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_NOOP_COMMAND: {
		const erx_xhci_trb_noop_command_placed_t placed = { .control_cycle = cycle };
		erx_xhci_trb_noop_command_t record;

		return (erx_xhci_trb_noop_command_encode(&record, &placed) && command_store(store, &record));
	}
	case ERX_MEANING_XHCI_TRB_ENABLE_SLOT_COMMAND: {
		const erx_xhci_trb_enable_slot_command_placed_t placed = { .control_cycle = cycle };
		erx_xhci_trb_enable_slot_command_t record;

		return (erx_xhci_trb_enable_slot_command_encode(&record, &placed) && command_store(store, &record));
	}
	case ERX_MEANING_XHCI_TRB_DISABLE_SLOT_COMMAND: {
		const erx_xhci_trb_disable_slot_command_placed_t placed = { .control_cycle = cycle,
		    .control_slot = target->group };
		erx_xhci_trb_disable_slot_command_t record;

		return (erx_xhci_trb_disable_slot_command_encode(&record, &placed) && command_store(store, &record));
	}
	/* The commands that carry the input context name it, the command ring's one buffer: `data`. */
	case ERX_MEANING_XHCI_TRB_ADDRESS_DEVICE_COMMAND: {
		const erx_xhci_trb_address_device_command_placed_t placed = { .parameter_pointer = data,
		    .control_cycle = cycle, .control_slot = target->group };
		erx_xhci_trb_address_device_command_t record;

		return (erx_xhci_trb_address_device_command_encode(&record, &placed) && command_store(store, &record));
	}
	case ERX_MEANING_XHCI_TRB_CONFIGURE_ENDPOINT_COMMAND: {
		const erx_xhci_trb_configure_endpoint_command_placed_t placed = { .parameter_pointer = data,
		    .control_cycle = cycle, .control_slot = target->group };
		erx_xhci_trb_configure_endpoint_command_t record;

		return (erx_xhci_trb_configure_endpoint_command_encode(&record, &placed) && command_store(store, &record));
	}
	case ERX_MEANING_XHCI_TRB_EVALUATE_CONTEXT_COMMAND: {
		const erx_xhci_trb_evaluate_context_command_placed_t placed = { .parameter_pointer = data,
		    .control_cycle = cycle, .control_slot = target->group };
		erx_xhci_trb_evaluate_context_command_t record;

		return (erx_xhci_trb_evaluate_context_command_encode(&record, &placed) && command_store(store, &record));
	}
	case ERX_MEANING_XHCI_TRB_RESET_ENDPOINT_COMMAND: {
		const erx_xhci_trb_reset_endpoint_command_placed_t placed = { .control_cycle = cycle,
		    .control_endpoint = target->index, .control_slot = target->group };
		erx_xhci_trb_reset_endpoint_command_t record;

		return (erx_xhci_trb_reset_endpoint_command_encode(&record, &placed) && command_store(store, &record));
	}
	case ERX_MEANING_XHCI_TRB_STOP_ENDPOINT_COMMAND: {
		const erx_xhci_trb_stop_endpoint_command_placed_t placed = { .control_cycle = cycle,
		    .control_endpoint = target->index, .control_slot = target->group };
		erx_xhci_trb_stop_endpoint_command_t record;

		return (erx_xhci_trb_stop_endpoint_command_encode(&record, &placed) && command_store(store, &record));
	}
	case ERX_MEANING_XHCI_TRB_SET_DEQUEUE_COMMAND: {
		/* The ring bound to its endpoint, at its position, which the reach rule found bound. */
		const int ring = erx_dma_ledger_bound_table(ledger, erx_dma_endpoint(target->group, target->index));
		erx_xhci_trb_set_dequeue_command_placed_t placed = { .control_cycle = cycle,
		    .control_endpoint = target->index, .control_slot = target->group };
		erx_xhci_trb_set_dequeue_command_t record;

		if (ring < 0)
			return (false);
		placed.parameter_pointer = ring_position_address(ledger, (uint32_t)ring);
		placed.parameter_dequeue_cycle = erx_dma_ledger_cycle(ledger, (uint32_t)ring);
		return (erx_xhci_trb_set_dequeue_command_encode(&record, &placed) && command_store(store, &record));
	}
	default:
		return (false);
	}
}

/* A ring's link at `step`, back to the ring's first record, with the cycle state of its lap. */
static bool
encode_link(const erx_dma_layout_t *layout, erx_dma_ring_step_t step, erx_dma_store_t *store)
{
	const erx_xhci_trb_link_placed_t placed = {
		.segment_segment_pointer = layout->device_base + layout->tables[step.place.table].first,
		.control_cycle = step.cycle,
	};
	erx_xhci_trb_link_t record;

	if (!erx_xhci_trb_link_encode(&record, &placed))
		return (false);
	*store = (erx_dma_store_t){ .offset = record_offset(layout, step.place), .length = sizeof(record) };
	bcopy(&record, store->bytes, sizeof(record));
	return (true);
}

/*
 * A ring's run (docs/design-device-dma.md, "Publication"): each description at the next position
 * the ledger gives, with the cycle state there, a link it reaches among them; the first written
 * with the other cycle bit, so the device takes none of the run before the activation, the store
 * of the first's control word with its own. Every meaning of a ring activates on the one bit of
 * that word, which the generator holds for a structure's meanings. Its places begin with the
 * head, the last description, which the report of the TD's end names.
 */
static erx_dma_verdict_t
place_ring(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication, uint32_t table,
    erx_dma_place_t *places, uint32_t *count, erx_dma_sequence_t *out)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	erx_dma_ring_step_t steps[ERX_DMA_RING_STEPS_MAX];
	const uint32_t taken = erx_dma_ledger_ring_run(ledger, table, publication->record_count, steps);
	uint32_t description = 0;
	erx_dma_store_t live;

	*count = 1;
	for (uint32_t step = 0; step < taken; step++) {
		erx_dma_store_t *const store = &out->stores[out->store_count];
		const bool first = description == 0 && !steps[step].link;

		if (steps[step].link) {
			if (!encode_link(layout, steps[step], store))
				return (ERX_DMA_BREAKS_MEANINGS);
			places[(*count)++] = steps[step].place;
		} else {
			const erx_dma_description_t *const record = &publication->records[description];

			if (!encode(ledger, publication, record, steps[step].place, NULL,
			    first && !SEED_FIRST_CYCLE_LIVE ? !steps[step].cycle : steps[step].cycle, store) ||
			    (first && !encode(ledger, publication, record, steps[step].place, NULL, steps[step].cycle, &live)))
				return (ERX_DMA_BREAKS_MEANINGS);
			if (++description == publication->record_count)
				places[0] = steps[step].place;
			else
				places[(*count)++] = steps[step].place;
		}
		if (first) {
			out->activation.kind = ERX_DMA_ACTIVATE_STORE;
			out->activation.store = (erx_dma_store_t){ .offset = live.offset + ERX_XHCI_TRB_NORMAL_OFF_CONTROL,
			    .length = sizeof(uint32_t) };
			bcopy(live.bytes + ERX_XHCI_TRB_NORMAL_OFF_CONTROL, out->activation.store.bytes, sizeof(uint32_t));
		}
		add_range(out->cleans, &out->clean_count, store->offset, store->length);
		out->store_count++;
	}
	return (ERX_DMA_PASSES);
}

/*
 * A region entry, whole, through its layout's encoder, at `at` of the record's memory: the
 * persistent region's device address and whole length. False where the encoder refuses them,
 * which cannot happen: erx_dma_regions_add refuses a length the entry cannot state.
 */
static bool
encode_region_entry(const erx_dma_persistent_region_t *region, uint64_t at, erx_dma_store_t *store)
{
	const erx_virtio_gpu_mem_entry_placed_t placed = { .addr = region->address, .length = region->length };
	erx_virtio_gpu_mem_entry_t record;

	if (!erx_virtio_gpu_mem_entry_encode(&record, &placed))
		return (false);
	*store = (erx_dma_store_t){ .offset = at, .length = sizeof(record) };
	bcopy(&record, store->bytes, sizeof(record));
	return (true);
}

/*
 * The record of the sequencer's own at a table placed in order, and the activation that makes
 * the run live. Only virtio's available ring is such a table: its entry names the chain's head,
 * and the available index, one past the entry's running index, is the activation.
 */
static bool
place_in_order(const erx_dma_ledger_t *ledger, uint32_t table, erx_dma_place_t head, erx_dma_store_t *entry,
    erx_dma_store_t *activation)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const erx_dma_position_t position = erx_dma_ledger_position(ledger, table);
	uint16_t value;

	if (layout->tables[table].structure != ERX_STRUCTURE_VIRTQ_AVAIL)
		return (false);
	value = (uint16_t)head.index;
	*entry = (erx_dma_store_t){ .offset = record_offset(layout, (erx_dma_place_t){ table, position.index }),
	    .length = sizeof(value) };
	bcopy(&value, entry->bytes, sizeof(value));
	value = (uint16_t)(running_index(ledger, table) + 1u);
	*activation = (erx_dma_store_t){ .offset = layout->tables[table].region + ERX_VIRTQ_RING_HEAD_OFF_IDX,
	    .length = sizeof(value) };
	bcopy(&value, activation->bytes, sizeof(value));
	return (true);
}

/*
 * The effects of a binding a publication carries, which its holding makes (erx_dma_ledger_hold):
 * ring `table`'s region zeroed, its link written on lap 0, where the binding starts it, so its
 * cycle bit is that lap's state, and the region cleaned, all before the command's activation, so
 * the controller finds a ring of TRBs whose cycle bit is 0 behind the position. False where the
 * link's encoder refuses the layout's address.
 */
static bool
bind_ring(const erx_dma_layout_t *layout, uint32_t table, erx_dma_sequence_t *out)
{
	const erx_dma_ring_step_t link = { .place = { .table = table, .index = layout->tables[table].count - 1 },
	    .cycle = BINDING_START_CYCLE, .link = true };

	if (!encode_link(layout, link, &out->stores[out->store_count]))
		return (false);
	out->store_count++;
	add_range(out->zeros, &out->zero_count, layout->tables[table].region, layout->tables[table].region_length);
	add_range(out->cleans, &out->clean_count, layout->tables[table].region, layout->tables[table].region_length);
	return (true);
}

/* The device address of a table's region, where a ring's head is: what a queue register names. */
static uint64_t
table_address(const erx_dma_layout_t *layout, int table)
{
	return (layout->device_base + layout->tables[table].region);
}

/*
 * The install of virtio's split ring, which the check found idle: every table's region zeroed and
 * cleaned, then the queue's size and its three rings' addresses from the layout, and the ready bit
 * as the activation. The idle report left every position at 0, where the device starts, so the
 * ledger does not change. BREAKS_CALLS for a layout of a form whose install the sequencer does not
 * write.
 */
static erx_dma_verdict_t
install(const erx_dma_ledger_t *ledger, erx_dma_sequence_t *sequence)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const int desc = erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_DESC);
	const int avail = erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_AVAIL);
	const int used = erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_USED);
	erx_dma_sequence_t out = { 0 };

	if (desc < 0 || avail < 0 || used < 0 || layout->table_count != SPLIT_RING_TABLES)
		return (ERX_DMA_BREAKS_CALLS);
	for (uint32_t table = 0; table < layout->table_count; table++) {
		const erx_dma_table_t *const at = &layout->tables[table];

		if (!(SEED_INSTALL_NOT_ZEROED && (int)table == used))
			add_range(out.zeros, &out.zero_count, at->region, at->region_length);
		if (!SEED_INSTALL_UNCLEANED)
			add_range(out.cleans, &out.clean_count, at->region, at->region_length);
	}
	out.registers[0] = (erx_dma_register_write_t){ ERX_DMA_VIRTQ_NUM, layout->tables[desc].count };
	out.registers[1] = (erx_dma_register_write_t){ ERX_DMA_VIRTQ_DESC, table_address(layout, desc) };
	out.registers[2] = (erx_dma_register_write_t){ ERX_DMA_VIRTQ_DRIVER, table_address(layout, avail) };
	out.registers[3] = (erx_dma_register_write_t){ ERX_DMA_VIRTQ_DEVICE,
	    table_address(layout, SEED_INSTALL_REGISTER ? avail : used) };
	out.register_count = 4;
	out.activation = (erx_dma_activation_t){ .kind = ERX_DMA_ACTIVATE_REGISTER, .reg = { ERX_DMA_VIRTQ_READY, 1 } };
	*sequence = out;
	return (ERX_DMA_PASSES);
}

/*
 * An xHCI install's stores: DCBAA entry 0, the scratchpad array packed four entries to a store, the
 * segment table's entry and the command ring's link.
 */
#define CONTROLLER_ARRAY_STORES	\
	((ERX_DEVICE_TRB_SCRATCHPADS_MAX * ERX_XHCI_SCRATCHPAD_ENTRY_SIZE + ERX_DMA_STORE_BYTES_MAX - 1u) / ERX_DMA_STORE_BYTES_MAX)
/* The stores besides the array's: DCBAA entry 0, the segment table's entry and the command ring's link. */
#define CONTROLLER_FIXED_STORES	3u
_Static_assert(CONTROLLER_FIXED_STORES + CONTROLLER_ARRAY_STORES <= ERX_DMA_STORES_MAX, "an xHCI install's stores fit a sequence");
_Static_assert(sizeof(erx_xhci_scratchpad_entry_t) == ERX_XHCI_SCRATCHPAD_ENTRY_SIZE &&
    sizeof(erx_xhci_dcbaa_entry_t) <= ERX_DMA_STORE_BYTES_MAX &&
    sizeof(erx_xhci_segment_table_entry_t) <= ERX_DMA_STORE_BYTES_MAX, "each install record fits a store");
_Static_assert(ERX_DMA_STORE_BYTES_MAX % ERX_XHCI_SCRATCHPAD_ENTRY_SIZE == 0, "a store holds whole array entries");

/* `length` bytes of `record` stored at `offset` of the record's memory. */
static void
store_record(erx_dma_sequence_t *out, uint64_t offset, const void *record, uint32_t length)
{
	erx_dma_store_t *const store = &out->stores[out->store_count++];

	*store = (erx_dma_store_t){ .offset = offset, .length = length };
	bcopy(record, store->bytes, length);
}

/* The device address of the controller's region `region`. */
static uint64_t
region_address(const erx_device_trb_layout_t *controller, uint16_t region)
{
	return (controller->device_base + controller->regions[region].offset);
}

/*
 * The scratchpad array, after the pages in their region (erx_device_trb.h), each entry naming its
 * page, and DCBAA entry 0 naming the array. With no page asked for, entry 0 stays the zero the
 * install wrote. False where an encoder refuses an address.
 */
static bool
store_scratchpad(const erx_device_trb_layout_t *controller, erx_dma_sequence_t *out)
{
	erx_xhci_dcbaa_entry_placed_t entry;
	erx_xhci_dcbaa_entry_t dcbaa;
	uint8_t packed[ERX_DMA_STORE_BYTES_MAX];
	uint64_t pages, array;

	if (controller->scratchpads == 0)
		return (true);
	pages = controller->regions[controller->scratchpad].offset;
	array = pages + (uint64_t)controller->scratchpads * ERX_XHCI_PAGE_SIZE;
	entry = (erx_xhci_dcbaa_entry_placed_t){ .entry_address = controller->device_base + array };
	for (uint32_t page = 0; page < controller->scratchpads; page++) {
		const erx_xhci_scratchpad_entry_placed_t placed = {
			.entry_page = controller->device_base + pages + (uint64_t)page * ERX_XHCI_PAGE_SIZE };
		const uint32_t at = page * ERX_XHCI_SCRATCHPAD_ENTRY_SIZE % ERX_DMA_STORE_BYTES_MAX;
		erx_xhci_scratchpad_entry_t record;

		if (!erx_xhci_scratchpad_entry_encode(&record, &placed))
			return (false);
		bcopy(&record, packed + at, sizeof(record));
		if (at + sizeof(record) == ERX_DMA_STORE_BYTES_MAX || page + 1u == controller->scratchpads)
			store_record(out, array + (uint64_t)page * ERX_XHCI_SCRATCHPAD_ENTRY_SIZE - at, packed,
			    at + (uint32_t)sizeof(record));
	}
	if (!erx_xhci_dcbaa_entry_encode(&dcbaa, &entry))
		return (false);
	store_record(out, controller->regions[controller->dcbaa].offset, &dcbaa, sizeof(dcbaa));
	return (true);
}

erx_dma_verdict_t
erx_dma_install_controller(const erx_dma_ledger_t *ledger, const erx_device_trb_layout_t *controller,
    erx_dma_sequence_t *sequence)
{
	const erx_dma_publication_t publication = { .call = ERX_DMA_PUBLISH_INSTALL };
	const erx_dma_verdict_t verdict = erx_dma_publication_check(ledger, &publication);
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const int command = erx_dma_ledger_table(ledger, ERX_STRUCTURE_XHCI_COMMAND_RING);
	const int events = erx_dma_ledger_table(ledger, ERX_STRUCTURE_XHCI_EVENT_RING);
	erx_xhci_segment_table_entry_placed_t segment;
	erx_xhci_segment_table_entry_t entry;
	erx_dma_ring_step_t link;
	erx_dma_sequence_t out = { 0 };

	if (verdict != ERX_DMA_PASSES)
		return (verdict);
	if (command < 0 || events < 0)
		return (ERX_DMA_BREAKS_MEANINGS);
	segment = (erx_xhci_segment_table_entry_placed_t){ .base_address = region_address(controller, controller->event_ring),
	    .size_trbs = layout->tables[events].count };
	link = (erx_dma_ring_step_t){ .place = { .table = (uint32_t)command, .index = layout->tables[command].count - 1u },
	    .cycle = BINDING_START_CYCLE, .link = true };
	add_range(out.zeros, &out.zero_count, 0, controller->bytes);
	if (!store_scratchpad(controller, &out) || !erx_xhci_segment_table_entry_encode(&entry, &segment) ||
	    !encode_link(layout, link, &out.stores[out.store_count]))
		return (ERX_DMA_BREAKS_MEANINGS);
	out.store_count++;
	store_record(&out, controller->regions[controller->segment_table].offset, &entry, sizeof(entry));
	add_range(out.cleans, &out.clean_count, 0, controller->bytes);
	out.registers[out.register_count++] = (erx_dma_register_write_t){ ERX_DMA_XHCI_SLOTS, controller->slots };
	out.registers[out.register_count++] = (erx_dma_register_write_t){ ERX_DMA_XHCI_DCBAA,
	    region_address(controller, controller->dcbaa) };
	out.registers[out.register_count++] = (erx_dma_register_write_t){ ERX_DMA_XHCI_EVENT_RING_SIZE, 1 };
	out.registers[out.register_count++] = (erx_dma_register_write_t){ ERX_DMA_XHCI_INTERRUPT_MODERATION,
	    XHCI_MODERATION_INTERVAL };
	out.registers[out.register_count++] = (erx_dma_register_write_t){ ERX_DMA_XHCI_EVENT_DEQUEUE,
	    erx_dma_dequeue_address(ledger, (uint32_t)events) };
	out.registers[out.register_count++] = (erx_dma_register_write_t){ ERX_DMA_XHCI_SEGMENT_TABLE,
	    region_address(controller, controller->segment_table) };
	out.registers[out.register_count++] = (erx_dma_register_write_t){ ERX_DMA_XHCI_INTERRUPTER_ENABLE, 1 };
	out.registers[out.register_count++] = (erx_dma_register_write_t){ ERX_DMA_XHCI_COMMAND_RING,
	    ring_position_address(ledger, (uint32_t)command) | erx_dma_ledger_cycle(ledger, (uint32_t)command) };
	out.activation = (erx_dma_activation_t){ .kind = ERX_DMA_ACTIVATE_REGISTER, .reg = { ERX_DMA_XHCI_RUN, 1 } };
	*sequence = out;
	return (ERX_DMA_PASSES);
}

/* The offset of DCBAA entry `slot` in the record's memory. */
static uint64_t
slot_entry_offset(const erx_device_trb_layout_t *controller, uint32_t slot)
{
	return (controller->regions[controller->dcbaa].offset + (uint64_t)slot * sizeof(erx_xhci_dcbaa_entry_t));
}

erx_dma_verdict_t
erx_dma_publish_controller(erx_dma_ledger_t *ledger, const erx_device_trb_layout_t *controller,
    const erx_dma_publication_t *publication, erx_dma_sequence_t *sequence)
{
	erx_xhci_dcbaa_entry_placed_t placed;
	erx_xhci_dcbaa_entry_t entry;
	erx_device_trb_region_t context;
	erx_dma_verdict_t verdict;
	uint32_t slot = 0;

	/* The one binding of EP0 a publication may carry (the check's reach rule) names the slot. */
	for (uint32_t k = 0; k < publication->bind_count; k++) {
		if (publication->binds[k].endpoint % ERX_DMA_GROUP_ENDPOINTS == 1u)
			slot = publication->binds[k].endpoint / ERX_DMA_GROUP_ENDPOINTS;
	}
	if (slot == 0)
		return (erx_dma_publish(ledger, publication, sequence));
	/* The entry is encoded before the ledger changes, so a refusal changes nothing. */
	if (slot > controller->slots)
		return (ERX_DMA_BREAKS_MEANINGS);
	context = controller->regions[controller->device_context[slot]];
	placed = (erx_xhci_dcbaa_entry_placed_t){ .entry_address = controller->device_base + context.offset };
	if (!erx_xhci_dcbaa_entry_encode(&entry, &placed))
		return (ERX_DMA_BREAKS_MEANINGS);
	verdict = erx_dma_publish(ledger, publication, sequence);
	if (verdict != ERX_DMA_PASSES)
		return (verdict);
	if (!SEED_SLOT_CONTEXT_UNZEROED)
		add_range(sequence->zeros, &sequence->zero_count, context.offset, context.length);
	add_range(sequence->cleans, &sequence->clean_count, context.offset, context.length);
	store_record(sequence, slot_entry_offset(controller, slot), &entry, sizeof(entry));
	add_range(sequence->cleans, &sequence->clean_count, slot_entry_offset(controller, slot), sizeof(entry));
	return (ERX_DMA_PASSES);
}

bool
erx_dma_clear_slot_entry(const erx_device_trb_layout_t *controller, uint32_t slot, erx_dma_sequence_t *sequence)
{
	if (slot < 1 || slot > controller->slots || sequence->zero_count == ERX_DMA_ZEROS_MAX ||
	    sequence->clean_count == ERX_DMA_CLEANS_MAX)
		return (false);
	add_range(sequence->zeros, &sequence->zero_count, slot_entry_offset(controller, slot), sizeof(erx_xhci_dcbaa_entry_t));
	add_range(sequence->cleans, &sequence->clean_count, slot_entry_offset(controller, slot),
	    sizeof(erx_xhci_dcbaa_entry_t));
	return (true);
}

/*
 * What the sequencer derives for a publication's input context, never its poster: whether the
 * slot context is carried (Address Device, Configure Endpoint) with its Context Entries, the drop
 * flags, and, by device context index, each carried endpoint's TR Dequeue Pointer with its cycle
 * state in bit 0, the endpoint context's dequeue word; and the context size, the controller's. They come
 * from the publication's meaning, bindings and drops and the ledger's rings, and the size from its
 * layout.
 */
typedef struct erx_dma_context_derivation {
	bool		slot;
	uint32_t	entries;
	uint32_t	drop;
	uint64_t	dequeue[ERX_XHCI_DEVICE_CONTEXTS];
	uint32_t	context_size;	/* 32 or 64 bytes (HCCPARAMS1.CSZ) */
} erx_dma_context_derivation_t;

/* One context of an input context: its offset from the input context's start, its endpoint's index or 0, its bytes. */
typedef struct erx_dma_context_part {
	uint32_t	offset;
	uint32_t	dci;
	uint8_t		bytes[ERX_XHCI_SLOT_CONTEXT_SIZE];
} erx_dma_context_part_t;

/* The input control context, the slot context and an endpoint context for each index (xHCI 1.2, 6.2.5, p. 460). */
#define CONTEXT_PARTS_MAX	(1u + ERX_XHCI_DEVICE_CONTEXTS)

/* One context's 32 bytes at context `index` of the input context, through its encoder's output. */
static void
add_part(erx_dma_context_part_t *parts, uint32_t *count, uint32_t context_size, uint32_t index, uint32_t dci,
    const void *record)
{
	parts[*count] = (erx_dma_context_part_t){ .offset = index * context_size, .dci = dci };
	bcopy(record, parts[*count].bytes, sizeof(parts[*count].bytes));
	(*count)++;
}

/*
 * The one composition of the input context (xHCI 1.2, 6.2.5, Figure 6-5, p. 460), every context
 * through its layout's generated encoder, into `parts`; their count, or 0 for a refusal. Context k
 * lies at k times the context size, the input control context first and the slot context next, so
 * endpoint context dci at dci + 1 (6.2.5, p. 460, with 64-byte contexts at 40h apart); each part
 * is the context's first 32 bytes, the rest of a 64-byte context reserved and zero (6.2.2,
 * p. 447; 6.2.3, p. 453; 6.2.5.1, p. 461), as is every byte no part covers. The add flags are
 * the contexts written, A0 with the slot context and A(dci) with each endpoint context, so a flag
 * never names a context left zero (Table 6-16, p. 461); the drop flags, Context Entries and each
 * dequeue word are `derived`'s; the average TRB length 8 for a control endpoint and otherwise the
 * packet times the burst plus one (6.2.3, the note on p. 454). Refused: a context size
 * other than 32 or 64, more endpoints than ERX_DEVICE_TRB_DCI_MAX, an index outside 1..31 or
 * written twice, drop flags on indexes 0 and 1 (Table 6-15, p. 461), and a value its encoder
 * refuses. An index both dropped and added is Configure Endpoint's drop-and-add (4.6.6, p. 119).
 */
static uint32_t
input_context(const erx_device_trb_contexts_t *stated, const erx_dma_context_derivation_t *derived,
    erx_dma_context_part_t parts[CONTEXT_PARTS_MAX])
{
	const uint32_t size = derived->context_size;
	erx_xhci_input_control_context_placed_t control = { .drop = derived->drop };
	erx_xhci_input_control_context_t flags;
	uint32_t count = 1;

	if ((size != ERX_XHCI_SLOT_CONTEXT_SIZE && size != 2u * ERX_XHCI_SLOT_CONTEXT_SIZE) ||
	    stated->endpoint_count > ERX_DEVICE_TRB_DCI_MAX || (derived->drop & 0x3u) != 0)
		return (0);
	if (derived->slot) {
		const erx_xhci_slot_context_placed_t placed = { .route_context_entries = derived->entries };
		erx_xhci_slot_context_t record;

		if (!erx_xhci_slot_context_encode(&record, &stated->slot_context, &placed))
			return (0);
		add_part(parts, &count, size, 1, 0, &record);
		control.add |= 1u << 0;
	}
	for (uint32_t k = 0; k < stated->endpoint_count; k++) {
		const erx_device_trb_context_endpoint_t *const endpoint = &stated->endpoints[k];
		const erx_xhci_endpoint_context_free_t *const context = &endpoint->context;
		erx_xhci_endpoint_context_placed_t placed;
		erx_xhci_endpoint_context_t record;

		if (endpoint->dci < 1 || endpoint->dci > ERX_DEVICE_TRB_DCI_MAX || (control.add >> endpoint->dci & 1u) != 0)
			return (0);
		placed = (erx_xhci_endpoint_context_placed_t){
			.dequeue_dequeue_cycle = derived->dequeue[endpoint->dci] & 1u,
			.dequeue_dequeue_pointer = derived->dequeue[endpoint->dci] & ~UINT64_C(1),
			.payload_average_trb_length = context->config_endpoint_type == ERX_XHCI_ENDPOINT_TYPE_CONTROL ?
			    CONTROL_AVERAGE_TRB_LENGTH : context->config_max_packet * (context->config_max_burst + 1u),
		};
		if (!erx_xhci_endpoint_context_encode(&record, context, &placed))
			return (0);
		add_part(parts, &count, size, endpoint->dci + 1u, endpoint->dci, &record);
		control.add |= UINT64_C(1) << endpoint->dci;
	}
	if (SEED_CONFIGURE_ADDS_EP0 && derived->slot)
		control.add |= 1u << 1;
	if (!erx_xhci_input_control_context_encode(&flags, &control))
		return (0);
	/* The input control context, context 0, takes the first part, which the count began past. */
	parts[0] = (erx_dma_context_part_t){ .offset = 0, .dci = 0 };
	bcopy(&flags, parts[0].bytes, sizeof(parts[0].bytes));
	return (count);
}

bool
erx_dma_carries_input_context(uint32_t meaning)
{
	return (meaning == ERX_MEANING_XHCI_TRB_ADDRESS_DEVICE_COMMAND ||
	    meaning == ERX_MEANING_XHCI_TRB_CONFIGURE_ENDPOINT_COMMAND ||
	    meaning == ERX_MEANING_XHCI_TRB_EVALUATE_CONTEXT_COMMAND);
}

/*
 * The dequeue word of the context a publication carries for its endpoint `dci`: the ring the
 * publication binds to it, at the binding's start, its first record on lap 0 with cycle state 1
 * (bind_ring); for Evaluate Context, which binds none, the ring bound to it, at its position with
 * its cycle state, as Set TR Dequeue Pointer writes it. False for an endpoint with no such ring.
 */
static bool
carried_dequeue(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication, uint32_t dci, uint64_t *word)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(ledger);
	const uint32_t endpoint = erx_dma_endpoint(publication->reach.group, dci);
	int ring;

	for (uint32_t k = 0; k < publication->bind_count; k++) {
		const uint32_t table = publication->binds[SEED_DEQUEUE_OTHER_RING ? (k + 1u) % publication->bind_count : k].table;

		if (publication->binds[k].endpoint == endpoint && endpoint != 0) {
			*word = (layout->device_base + layout->tables[table].first) | BINDING_START_CYCLE;
			return (true);
		}
	}
	/* Evaluate Context evaluates EP0's context alone (6.2.3.3, p. 454). */
	if (publication->records[0].meaning != ERX_MEANING_XHCI_TRB_EVALUATE_CONTEXT_COMMAND || dci != 1 || endpoint == 0 ||
	    (ring = erx_dma_ledger_bound_table(ledger, endpoint)) < 0)
		return (false);
	*word = ring_position_address(ledger, (uint32_t)ring) | erx_dma_ledger_cycle(ledger, (uint32_t)ring);
	return (true);
}

/*
 * The derivation of a command's input context (erx_dma_context_derivation_t): the slot context
 * with Address Device and Configure Endpoint; the drop flags the publication's drops; each carried
 * endpoint's dequeue word from its ring (carried_dequeue); Context Entries the last index valid
 * once the command succeeds: EP0's, each endpoint the slot keeps bound and does not drop, and each
 * carried (Table 6-4, p. 445). False when a carried endpoint has no ring, or a binding has no
 * carried context, which would bind a ring the controller is never told of.
 */
static bool
derive_input_context(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication,
    erx_dma_context_derivation_t *derived)
{
	const erx_device_trb_contexts_t *const stated = publication->contexts;
	uint32_t valid = 1u << 1, bound = 0;

	*derived = (erx_dma_context_derivation_t){ .slot = publication->records[0].meaning !=
	    ERX_MEANING_XHCI_TRB_EVALUATE_CONTEXT_COMMAND, .drop = publication->reach.drops,
	    .context_size = erx_dma_ledger_layout(ledger)->context_size };
	if (SEED_DROP_MISSING)
		derived->drop &= derived->drop - 1u;
	for (uint32_t dci = 2; dci <= ERX_DEVICE_TRB_DCI_MAX; dci++) {
		if ((publication->reach.drops >> dci & 1u) == 0 &&
		    erx_dma_ledger_bound_table(ledger, erx_dma_endpoint(publication->reach.group, dci)) >= 0)
			valid |= 1u << dci;
	}
	for (uint32_t k = 0; k < stated->endpoint_count && k < ERX_DEVICE_TRB_DCI_MAX; k++) {
		const uint32_t dci = stated->endpoints[k].dci;

		if (dci < 1 || dci > ERX_DEVICE_TRB_DCI_MAX || !carried_dequeue(ledger, publication, dci, &derived->dequeue[dci]))
			return (false);
		valid |= 1u << dci;
		for (uint32_t b = 0; b < publication->bind_count; b++)
			bound += publication->binds[b].endpoint == erx_dma_endpoint(publication->reach.group, dci);
	}
	derived->entries = 31u - (uint32_t)__builtin_clz(valid);
	return (bound == publication->bind_count);
}

/*
 * The input context a command carries, written whole into the buffer its TRB names: rule 1 zeroes
 * the buffer, and each context of the one composition is a store at its offset, inside the
 * buffer's size. BREAKS_MEANINGS for a command that carries it without its parameters, or that
 * does not and has them, and for contexts the composition refuses or the buffer cannot hold;
 * BREAKS_BINDINGS for a derivation derive_input_context refuses.
 */
static erx_dma_verdict_t
place_input_context(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication, erx_dma_sequence_t *out)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(ledger);
	const erx_dma_description_t *const command = &publication->records[0];
	erx_dma_context_part_t parts[CONTEXT_PARTS_MAX];
	erx_dma_context_derivation_t derived;
	const erx_dma_name_t name = command->names[0];
	uint64_t size;
	uint32_t count, pool;

	if (publication->record_count != 1 || !erx_dma_carries_input_context(command->meaning))
		return (publication->contexts == NULL ? ERX_DMA_PASSES : ERX_DMA_BREAKS_MEANINGS);
	if (publication->contexts == NULL || command->name_count != 1)
		return (ERX_DMA_BREAKS_MEANINGS);
	if (!derive_input_context(ledger, publication, &derived))
		return (ERX_DMA_BREAKS_BINDINGS);
	count = input_context(publication->contexts, &derived, parts);
	size = erx_dma_layout_buffer_pool(layout, name.buffer, &pool)->size;
	if (count == 0 || count > ERX_DMA_INPUT_PARTS_MAX || name.offset > size ||
	    (uint64_t)CONTEXT_PARTS_MAX * layout->context_size > size - name.offset)
		return (ERX_DMA_BREAKS_MEANINGS);
	for (uint32_t part = 0; part < count; part++) {
		erx_dma_store_t *const store = &out->stores[out->store_count++];

		*store = (erx_dma_store_t){ .offset = buffer_offset(layout, name.buffer,
		    name.offset + parts[part].offset), .length = sizeof(parts[part].bytes) };
		bcopy(parts[part].bytes, store->bytes, sizeof(parts[part].bytes));
	}
	return (ERX_DMA_PASSES);
}

erx_dma_verdict_t
erx_dma_publish(erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication, erx_dma_sequence_t *sequence)
{
	const erx_dma_verdict_t verdict = erx_dma_publication_check(ledger, publication);
	erx_dma_verdict_t contexts;
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	erx_dma_place_t places[ERX_DMA_HELD_RECORDS_MAX];
	uint32_t buffers[ERX_DMA_HELD_BUFFERS_MAX], buffer_count, count = 0;
	erx_dma_sequence_t out = { 0 };
	bool activated = false, on_ring = false;
	uint32_t run, pool;

	if (verdict != ERX_DMA_PASSES)
		return (verdict);
	if (publication->call == ERX_DMA_PUBLISH_INSTALL)
		return (install(ledger, sequence));
	/* The check passed: every record is in the run's one table, a ring or one placed free, with room for the run. */
	run = (uint32_t)erx_dma_run_table(ledger, publication);
	if (layout->tables[run].placing == ERX_DMA_PLACED_RING) {
		const erx_dma_verdict_t placed = place_ring(ledger, publication, run, places, &count, &out);

		if (placed != ERX_DMA_PASSES)
			return (placed);
		activated = on_ring = true;
	}
	contexts = place_input_context(ledger, publication, &out);
	if (contexts != ERX_DMA_PASSES)
		return (contexts);
	for (uint32_t k = 0; k < publication->bind_count; k++) {
		if (!bind_ring(layout, publication->binds[k].table, &out))
			return (ERX_DMA_BREAKS_BINDINGS);
	}
	for (uint32_t record = 0; !on_ring && record < publication->record_count; record++) {
		places[count] = (erx_dma_place_t){ run, free_record(ledger, run, places, count) };
		count++;
	}
	for (uint32_t record = 0; !on_ring && record < publication->record_count; record++) {
		const bool chained = record + 1 < publication->record_count && places[record + 1].table == places[record].table;

		if (!encode(ledger, publication, &publication->records[record], places[record], chained ? &places[record + 1] : NULL,
		    0, &out.stores[out.store_count]))
			return (ERX_DMA_BREAKS_MEANINGS);
		add_range(out.cleans, &out.clean_count, out.stores[out.store_count].offset,
		    out.stores[out.store_count].length);
		out.store_count++;
	}
	for (uint32_t table = 0; table < layout->table_count; table++) {
		if (erx_structure_device_writes(layout->tables[table].structure) ||
		    layout->tables[table].placing != ERX_DMA_PLACED_IN_ORDER)
			continue;
		if (activated ||
		    !place_in_order(ledger, table, places[0], &out.stores[out.store_count], &out.activation.store))
			return (ERX_DMA_BREAKS_ROOM);
		out.activation.kind = ERX_DMA_ACTIVATE_STORE;
		activated = true;
		places[count++] = (erx_dma_place_t){ table, erx_dma_ledger_position(ledger, table).index };
		add_range(out.cleans, &out.clean_count, out.stores[out.store_count].offset,
		    out.stores[out.store_count].length);
		out.store_count++;
	}
	if (!activated || !erx_dma_publication_buffers(publication, buffers, &buffer_count))
		return (ERX_DMA_BREAKS_ROOM);
	for (uint32_t index = 0; index < buffer_count; index++) {
		if (!SEED_NO_ZEROS)
			zero_gaps(layout, publication, buffers[index], &out);
		add_range(out.cleans, &out.clean_count, buffer_offset(layout, buffers[index], 0),
		    erx_dma_layout_buffer_pool(layout, buffers[index], &pool)->stride);
	}
	for (uint32_t index = 0; index < publication->fill_count; index++) {
		const erx_dma_fill_t *const fill = &publication->fills[index];
		const uint64_t at = buffer_offset(layout, fill->buffer, fill->offset);

		if (fill->kind != ERX_DMA_FILL_REGION_ENTRY) {
			out.fills[out.fill_count++] = (erx_dma_range_t){ at, fill->length };
			continue;
		}
		/* The check found the region in the ledger. */
		if (!encode_region_entry(erx_dma_ledger_region(ledger, fill->region), at, &out.stores[out.store_count++]))
			return (ERX_DMA_BREAKS_FILLS);
		out.fills[out.fill_count++] = (erx_dma_range_t){ at, 0 };
	}
	if (!erx_dma_ledger_hold(ledger, publication, places, count))
		return (ERX_DMA_BREAKS_ROOM);
	*sequence = out;
	return (ERX_DMA_PASSES);
}

bool
erx_dma_acquire(erx_dma_ledger_t *ledger, uint32_t reports, uint16_t index, uint32_t most, uint32_t *count)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	uint32_t covered;

	if (reports >= layout->table_count || !erx_structure_device_writes(layout->tables[reports].structure))
		return (false);
	covered = (uint16_t)(index - running_index(ledger, reports));
	if (covered > erx_dma_ledger_live(ledger))
		return (false);
	*count = covered < most ? covered : most;
	return (erx_dma_ledger_acquire(ledger, reports, *count));
}

erx_dma_range_t
erx_dma_acquire_record(const erx_dma_ledger_t *ledger, uint32_t reports, uint32_t k)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const erx_dma_table_t *table;
	uint32_t index;

	/* Only a table the device writes has an acquisition. */
	if (k >= erx_dma_ledger_acquired(ledger, reports))
		return ((erx_dma_range_t){ 0, 0 });
	table = &layout->tables[reports];
	index = (uint32_t)(((uint64_t)erx_dma_ledger_position(ledger, reports).index + k) % table->count);
	return ((erx_dma_range_t){ record_offset(layout, (erx_dma_place_t){ reports, index }), table->stride });
}

/*
 * The head of the holding the record at the consumer position of `reports` names, through its
 * meaning's `releases` mark: a record's index in its structure's one table, or a device address,
 * through the layout's one map from address to record. False for a record past what the
 * acquisition covered, one whose selector names no meaning or releases nothing, or one naming no
 * record of a table the ledger has.
 */
static bool
report_head(const erx_dma_ledger_t *ledger, uint32_t reports, const erx_report_record_t *record,
    erx_dma_place_t *head)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	erx_report_release_t release;
	uint32_t meaning;
	int target;

	if (erx_dma_ledger_acquired(ledger, reports) == 0)
		return (false);
	if (!erx_report_meaning(layout->tables[reports].structure, record, &meaning))
		return (false);
	if (!erx_report_releases(meaning, record, &release))
		return (false);
	if (release.address)
		return (erx_dma_layout_place(layout, release.structure, release.value, head));
	target = erx_dma_ledger_table(ledger, release.structure);
	if (target < 0 || release.value >= layout->tables[target].count)
		return (false);
	*head = (erx_dma_place_t){ (uint32_t)target, (uint32_t)release.value };
	return (true);
}

erx_dma_found_t
erx_dma_report_holding(const erx_dma_ledger_t *ledger, uint32_t reports, const erx_report_record_t *record)
{
	erx_dma_place_t head;

	return (report_head(ledger, reports, record, &head) ? erx_dma_ledger_holding(ledger, head) :
	    (erx_dma_found_t){ NULL, 0 });
}

bool
erx_dma_consume(erx_dma_ledger_t *ledger, uint32_t reports, erx_dma_found_t found)
{
	return (erx_dma_ledger_release_holding(ledger, reports, found));
}

erx_dma_range_t
erx_dma_validity_word(const erx_dma_ledger_t *ledger, uint32_t reports, uint32_t k)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const erx_dma_table_t *table;

	if (reports >= layout->table_count || layout->tables[reports].structure != ERX_STRUCTURE_XHCI_EVENT_RING ||
	    k >= layout->tables[reports].count)
		return ((erx_dma_range_t){ 0, 0 });
	table = &layout->tables[reports];
	return ((erx_dma_range_t){ record_offset(layout, (erx_dma_place_t){ reports,
	    (erx_dma_ledger_position(ledger, reports).index + k) % table->count }) + ERX_XHCI_TRB_TRANSFER_EVENT_OFF_CONTROL,
	    sizeof(uint32_t) });
}

/*
 * Every meaning of the event ring activates on the one bit of its control word, which the
 * generator holds for a structure's meanings; the cycle state toggles where the position wraps.
 */
bool
erx_dma_acquire_cycles(erx_dma_ledger_t *ledger, uint32_t reports, const uint32_t *words, uint32_t word_count,
    uint32_t *count)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	uint32_t index, cycle, covered = 0;

	if (reports >= layout->table_count || layout->tables[reports].structure != ERX_STRUCTURE_XHCI_EVENT_RING ||
	    word_count > layout->tables[reports].count)
		return (false);
	index = erx_dma_ledger_position(ledger, reports).index;
	cycle = erx_dma_ledger_cycle(ledger, reports) ^ (SEED_CYCLE_INVERTED ? 1u : 0u);
	while (covered < word_count && erx_xhci_trb_transfer_event_control_cycle_get(words[covered]) == cycle) {
		covered++;
		if (++index == layout->tables[reports].count) {
			index = 0;
			cycle ^= 1u;
		}
	}
	*count = covered;
	return (erx_dma_ledger_acquire(ledger, reports, covered));
}

bool
erx_dma_pass(erx_dma_ledger_t *ledger, uint32_t reports, const erx_report_record_t *record)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	erx_report_release_t release;
	erx_dma_place_t place;
	uint32_t meaning;

	if (reports >= layout->table_count || !erx_report_meaning(layout->tables[reports].structure, record, &meaning))
		return (false);
	/* A releasing record passes only naming a live holding's record other than its head. */
	if (erx_report_releases(meaning, record, &release) &&
	    (!report_head(ledger, reports, record, &place) || !erx_dma_ledger_record_held(ledger, place) ||
	    erx_dma_ledger_holding(ledger, place).holding != NULL))
		return (false);
	return (erx_dma_ledger_pass(ledger, reports));
}

uint64_t
erx_dma_dequeue_address(const erx_dma_ledger_t *ledger, uint32_t reports)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);

	if (reports >= layout->table_count)
		return (0);
	return (layout->device_base + record_offset(layout, (erx_dma_place_t){ reports,
	    erx_dma_ledger_position(ledger, reports).index }));
}
