/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB form's core on the DMA ledger (erx_device_trb_form.h): its layout derived from the
 * form's own, over the form's shape and a small one; the endpoint of a queue; and every sequence
 * of posts and releases up to a fixed depth over the small shape, against a reference model of
 * each ring's positions and cycle state and each pool's buffers, every release through an event
 * the controller writes, across a wrap of the event ring; and the events the form refuses. Until
 * binding commands have meanings, a No Op command on the command ring carries each binding.
 * test/host/erx_device_trb_form_test.rb builds it with each seeded fault and shows it caught.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_trb_form.h"

#define EXPECT(condition, what)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, what);	\
			exit(1);						\
		}								\
	} while (0)

/*
 * The small shape: rings of RING TRBs, the last each one's link; a control block of one buffer and
 * two bulk blocks of two, the first bound to an IN endpoint and the second to an OUT one. Tables
 * 0..2 are the blocks' rings, then the command ring and the event ring.
 */
enum { RING = 6, BLOCKS = 3, COMMANDS = 3, EVENTS = 4, BUFFERS_MAX = 2, LIVE_MAX = 8, DEPTH = 6, COMMAND_DEPTH = 7, EVENT_BATCH = 32 };
enum { CONTROL_BLOCK = 0, IN_BLOCK = 1, OUT_BLOCK = 2 };
enum { POST_CONTROL_DATA, POST_CONTROL, POST_IN, POST_OUT, POSTS };
#define BASE		UINT64_C(0x100000)
#define SLOT		1u
#define NO_BUFFER	UINT32_MAX

static const erx_dma_regions_t no_regions;
static const uint32_t block_dci[BLOCKS] = { 1, 3, 2 };	/* EP0, EP1 IN, EP1 OUT */
static const uint8_t out_bytes[64];

static const erx_device_trb_shape_t small_shape = {
	.ring_trbs = RING, .blocks = { 1, 0, 2 }, .buffers = { 1, 0, 2 }, .buffer_size = { 64, 0, 64 },
};
static const erx_device_trb_controller_t controller = {
	.slots = 2, .ports = 1, .scratchpads = 0, .context_size = 32, .doorbells = 0,
};

/*
 * The model: each ring's position, cycle state and held positions; each block's held buffers; the
 * event ring's consumer position and cycle state.
 */
typedef struct transfer {
	uint32_t	block;
	uint32_t	buffer;		/* the block's buffer, or NO_BUFFER */
	uint32_t	head;
	uint32_t	length;
	uint32_t	data;		/* a control transfer's data stage, or NO_BUFFER */
	bool		short_data;
	uint32_t	moved;
	uint32_t	position_count;
	uint32_t	positions[2 * 3 + 1];
	uint64_t	tag;
	bool		halted;		/* an error event answered it */
} transfer_t;

/* The command in flight, as the model posted it, and whether its stop's event has come. */
typedef struct model_command {
	bool			live;
	erx_trb_command_t	command;
	uint32_t		head;
	uint64_t		tag;
	bool			stop_event;
} model_command_t;

typedef struct model {
	uint32_t	position[BLOCKS];
	uint32_t	cycle[BLOCKS];
	bool		held[BLOCKS][RING];
	bool		buffer_held[BLOCKS][BUFFERS_MAX];
	uint32_t	live;
	transfer_t	transfers[LIVE_MAX];
	uint64_t	next_tag;
	uint32_t	event_index;
	uint32_t	event_cycle;
	erx_dma_endpoint_state_t	state[BLOCKS];	/* each block's endpoint's */
	model_command_t	command;
} model_t;

typedef struct state {
	erx_trb_form_t	form;
	model_t		model;
} state_t;

static erx_device_trb_layout_t trb;
static uint64_t states;

static erx_device_trb_request_t
request(uint32_t post)
{
	/* GET_DESCRIPTOR of 8 bytes, IN; SET_CONFIGURATION 1, with no data stage. */
	static const uint8_t get_descriptor[8] = { 0x80, 6, 0, 1, 0, 0, 8, 0 };
	static const uint8_t set_configuration[8] = { 0x00, 9, 1, 0, 0, 0, 0, 0 };
	erx_device_trb_request_t made = { 0 };

	switch (post) {
	case POST_CONTROL_DATA:
		made = (erx_device_trb_request_t){ .control = true, .data = true, .device_writes = true, .length = 8 };
		memcpy(made.setup, get_descriptor, sizeof(made.setup));
		break;
	case POST_CONTROL:
		made = (erx_device_trb_request_t){ .control = true };
		memcpy(made.setup, set_configuration, sizeof(made.setup));
		break;
	case POST_IN:
		made = (erx_device_trb_request_t){ .device_writes = true, .length = 64 };
		break;
	default:
		made = (erx_device_trb_request_t){ .length = 10, .bytes = out_bytes };
		break;
	}
	return (made);
}

static uint32_t
post_block(uint32_t post)
{
	return (post == POST_IN ? IN_BLOCK : post == POST_OUT ? OUT_BLOCK : CONTROL_BLOCK);
}

static uint32_t
post_trbs(uint32_t post)
{
	return (post == POST_CONTROL_DATA ? 3 : post == POST_CONTROL ? 2 : 1);
}

/* The record offset of position `position` of block `block`'s ring, by the form's own layout. */
static uint64_t
position_offset(uint32_t block, uint32_t position)
{
	return (erx_device_trb_position_offset(&trb, block, position));
}

static const erx_dma_store_t *
stored_at(const erx_dma_sequence_t *sequence, uint64_t offset)
{
	for (uint32_t index = 0; index < sequence->store_count; index++) {
		if (sequence->stores[index].offset == offset)
			return (&sequence->stores[index]);
	}
	return (NULL);
}

/* What the last completion left the effect layer to apply (erx_trb_form_complete). */
static erx_dma_sequence_t delivered;

/* Whether `range` overlaps the DCBAA of the form's layout. */
static bool
in_dcbaa(const erx_device_trb_layout_t *layout, erx_dma_range_t range)
{
	const erx_device_trb_region_t dcbaa = layout->regions[layout->dcbaa];

	return (range.offset < dcbaa.offset + dcbaa.length && dcbaa.offset < range.offset + range.length);
}

/* Whether `sequence` zeroes or stores into the DCBAA, which only a slot's hand-over and its clear write. */
static bool
writes_dcbaa(const erx_device_trb_layout_t *layout, const erx_dma_sequence_t *sequence)
{
	bool writes = false;

	for (uint32_t k = 0; k < sequence->zero_count; k++)
		writes = writes || in_dcbaa(layout, sequence->zeros[k]);
	for (uint32_t k = 0; k < sequence->store_count; k++)
		writes = writes || in_dcbaa(layout, (erx_dma_range_t){ sequence->stores[k].offset, sequence->stores[k].length });
	return (writes);
}

/* Whether `ranges` holds exactly [offset, offset + length). */
static bool
has_range(const erx_dma_range_t *ranges, uint32_t count, uint64_t offset, uint64_t length)
{
	bool found = false;

	for (uint32_t k = 0; k < count; k++)
		found = found || (ranges[k].offset == offset && ranges[k].length == length);
	return (found);
}

/* The offset of DCBAA entry `slot`. */
static uint64_t
slot_entry(const erx_device_trb_layout_t *layout, uint32_t slot)
{
	return (layout->regions[layout->dcbaa].offset + 8u * (uint64_t)slot);
}

/*
 * Whether `sequence` hands slot `slot`'s device context to the controller (xHCI 1.2, 4.3.3 step 6,
 * p. 89; 6.2.1, p. 443): the context zeroed and cleaned, and DCBAA entry `slot` stored, naming
 * it, and cleaned, the only DCBAA write.
 */
static bool
hands_over(const erx_device_trb_layout_t *layout, const erx_dma_sequence_t *sequence, uint32_t slot)
{
	const erx_device_trb_region_t context = layout->regions[layout->device_context[slot]];
	const erx_dma_store_t *const entry = stored_at(sequence, slot_entry(layout, slot));
	uint64_t named = 0;
	uint32_t dcbaa_stores = 0;

	for (uint32_t k = 0; entry != NULL && k < 8; k++)
		named |= (uint64_t)entry->bytes[k] << (8u * k);
	for (uint32_t k = 0; k < sequence->store_count; k++)
		dcbaa_stores += in_dcbaa(layout, (erx_dma_range_t){ sequence->stores[k].offset, sequence->stores[k].length });
	return (has_range(sequence->zeros, sequence->zero_count, context.offset, context.length) &&
	    has_range(sequence->cleans, sequence->clean_count, context.offset, context.length) &&
	    entry != NULL && entry->length == 8 && named == layout->device_base + context.offset &&
	    has_range(sequence->cleans, sequence->clean_count, slot_entry(layout, slot), 8) && dcbaa_stores == 1);
}

/* Whether `sequence` clears DCBAA entry `slot` and nothing else: one zero of its 8 bytes, cleaned. */
static bool
clears_entry(const erx_device_trb_layout_t *layout, const erx_dma_sequence_t *sequence, uint32_t slot)
{
	return (sequence->zero_count == 1 && sequence->zeros[0].offset == slot_entry(layout, slot) &&
	    sequence->zeros[0].length == 8 && sequence->store_count == 0 && sequence->clean_count == 1 &&
	    sequence->cleans[0].offset == slot_entry(layout, slot) && sequence->cleans[0].length == 8);
}

/* A TRB's 64-bit parameter and control word as stored, little-endian. */
static uint64_t
parameter(const erx_dma_store_t *store)
{
	uint64_t value;

	memcpy(&value, store->bytes, sizeof(value));
	return (value);
}

static uint32_t
control_cycle(const uint8_t *word)
{
	uint32_t value;

	memcpy(&value, word, sizeof(value));
	return (value & 1u);
}

/* The record offset of event `index` of the event ring, and of command `index` of the command ring. */
static uint64_t
event_offset(uint32_t index)
{
	return (trb.regions[trb.event_ring].offset + 16u * (uint64_t)index);
}

static uint64_t
command_offset(uint32_t index)
{
	return (trb.regions[trb.command_ring].offset + 16u * (uint64_t)index);
}

/*
 * An event TRB as the controller writes it, its cycle bit left for deliver: the type, slot and
 * endpoint in the control word, the code and residue (or a command's parameter) in the status
 * word, the TRB pointer (or a port event's port, in bits 31:24) in the parameter.
 */
static erx_report_record_t
event_trb(uint32_t type, uint64_t pointer, uint32_t code, uint32_t residue, uint32_t dci)
{
	return ((erx_report_record_t){ .xhci_trb_transfer_event = { .pointer = pointer, .status = code << 24 | residue,
	    .control = (dci == 0 ? 0 : SLOT << 24 | dci << 16) | type << 10 } });
}

/*
 * Hands the form the `count` events `events`, written from the model's consumer position, each
 * with the cycle state there: checks where the acquisition reads each cycle word and each event,
 * that every one is acquired, and that the dequeue pointer after the completion is past the
 * `consumed` events it should consume, where the model's position moves. The completion's status.
 */
static int
deliver(state_t *state, erx_report_record_t *events, uint32_t count, uint32_t consumed, erx_trb_answer_t *answers,
    uint32_t *answered)
{
	model_t *const model = &state->model;
	uint32_t words[EVENT_BATCH], acquired, index = model->event_index, cycle = model->event_cycle;
	uint64_t dequeue;
	int status;

	for (uint32_t k = 0; k < count; k++) {
		events[k].xhci_trb_transfer_event.control |= cycle;
		words[k] = events[k].xhci_trb_transfer_event.control;
		EXPECT(erx_trb_form_validity_word(&state->form, k).offset == event_offset(index) + 12u,
		    "the acquisition reads each event's control word from the consumer position");
		if (++index == ERX_DEVICE_TRB_EVENT_TRBS) {
			index = 0;
			cycle ^= 1u;
		}
	}
	EXPECT(erx_trb_form_acquire(&state->form, words, count, &acquired) == ERX_OK && acquired == count,
	    "every event written with the consumer cycle state is acquired");
	for (uint32_t k = 0; k < count; k++)
		EXPECT(erx_trb_form_event(&state->form, k).offset ==
		    event_offset((model->event_index + k) % ERX_DEVICE_TRB_EVENT_TRBS), "each acquired event is read whole where it lies");
	status = erx_trb_form_complete(&state->form, events, count, answers, answered, &dequeue, &delivered);
	for (uint32_t k = 0; k < consumed; k++) {
		if (++model->event_index == ERX_DEVICE_TRB_EVENT_TRBS) {
			model->event_index = 0;
			model->event_cycle ^= 1u;
		}
	}
	EXPECT(dequeue == BASE + event_offset(model->event_index), "the dequeue pointer is past the consumed events");
	return (status);
}

/*
 * The command that binds ring `table` to `endpoint`, Address Device for EP0 and Configure Endpoint
 * for the others, then its completion with `code`.
 */
/*
 * A binding command adding endpoint `dci` of `slot` on `block`, its parameters in range: an
 * Address Device of a high-speed device at root port 1 with EP0 of 64 bytes, or a Configure
 * Endpoint adding a bulk endpoint of 64-byte packets, IN at an odd index.
 */
static erx_trb_command_t
binding(uint32_t slot, uint32_t dci, uint32_t block)
{
	erx_trb_command_t command = { .slot = slot, .add_count = 1 };

	if (dci == 1) {
		command.kind = ERX_TRB_COMMAND_ADDRESS_DEVICE;
		command.slot_context = (erx_xhci_slot_context_free_t){ .route_speed = ERX_XHCI_SPEED_HIGH, .ports_root_port = 1 };
		command.adds[0] = (erx_trb_add_t){ .dci = 1, .block = block,
		    .context = { .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL, .config_max_packet = 64 } };
		return (command);
	}
	command.kind = ERX_TRB_COMMAND_CONFIGURE_ENDPOINT;
	command.adds[0] = (erx_trb_add_t){ .dci = dci, .block = block, .context = {
	    .config_endpoint_type = (dci & 1u) != 0 ? ERX_XHCI_ENDPOINT_TYPE_BULK_IN : ERX_XHCI_ENDPOINT_TYPE_BULK_OUT,
	    .config_max_packet = 64, .payload_max_esit_payload = 64 } };
	return (command);
}

static void
bind(state_t *state, uint32_t table, uint32_t endpoint, uint32_t code)
{
	const uint32_t dci = endpoint % ERX_DMA_GROUP_ENDPOINTS;
	const erx_trb_command_t command = binding(endpoint / ERX_DMA_GROUP_ENDPOINTS, dci, table);
	const uint32_t head = erx_dma_ledger_position(&state->form.ledger, COMMANDS).index;
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, BASE + command_offset(head),
	    code, 0x2a, 0);
	erx_trb_answer_t answers[ERX_TRB_FORM_ANSWERS_MAX(1)];
	erx_dma_sequence_t sequence;
	uint32_t answered;

	EXPECT(erx_trb_form_command(&state->form, &command, 7, &sequence) == ERX_DEVICE_TRB_ACCEPTED, "a binding command");
	EXPECT(erx_dma_ledger_binding(&state->form.ledger, table) == endpoint, "its publication binds the ring");
	EXPECT(dci == 1 ? hands_over(&state->form.layout, &sequence, endpoint / ERX_DMA_GROUP_ENDPOINTS) :
	    !writes_dcbaa(&state->form.layout, &sequence), "an Address Device, binding EP0, hands over its slot's zeroed "
	    "device context through its DCBAA entry; no other binding writes the DCBAA");
	EXPECT(deliver(state, &event, 1, 1, answers, &answered) == ERX_OK && answered == 1 &&
	    answers[0].kind == ERX_TRB_ANSWER_COMMAND && answers[0].code == code && answers[0].parameter == 0x2a &&
	    erx_dma_ledger_live(&state->form.ledger) == 0, "the command's completion ends its holding on any code");
	EXPECT(erx_dma_ledger_binding(&state->form.ledger, table) ==
	    (code == ERX_XHCI_COMPLETION_SUCCESS || dci == 1 ? endpoint : 0),
	    "a success keeps the binding; a failed Address Device keeps EP0's until Disable Slot (xHCI 1.2, 4.6.5, "
	    "p. 114), and any other failure ends it");
	state->model.state[table] = code == ERX_XHCI_COMPLETION_SUCCESS ? ERX_DMA_ENDPOINT_RUNNING : ERX_DMA_ENDPOINT_DISABLED;
	EXPECT(erx_dma_ledger_endpoint_state(&state->form.ledger, endpoint) == state->model.state[table],
	    "a binding command's success runs its endpoint; its failure leaves it disabled");
}

/*
 * An Enable Slot whose completion, with `code`, names slot `slot` (xHCI 1.2, 4.6.3, p. 108): an
 * Address Device is accepted only on a slot such a success gave since the slot's Disable Slot or
 * the form's reset.
 */
static void
enable_slot(state_t *state, uint32_t slot, uint32_t code)
{
	const erx_trb_command_t command = { .kind = ERX_TRB_COMMAND_ENABLE_SLOT };
	const uint32_t head = erx_dma_ledger_position(&state->form.ledger, COMMANDS).index;
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, BASE + command_offset(head),
	    code, 0, 0);
	erx_trb_answer_t answers[ERX_TRB_FORM_ANSWERS_MAX(1)];
	erx_dma_sequence_t sequence;
	uint32_t answered;

	event.xhci_trb_transfer_event.control |= slot << 24;
	EXPECT(erx_trb_form_command(&state->form, &command, 3, &sequence) == ERX_DEVICE_TRB_ACCEPTED, "an Enable Slot");
	EXPECT(deliver(state, &event, 1, 1, answers, &answered) == ERX_OK && answered == 1 &&
	    answers[0].kind == ERX_TRB_ANSWER_COMMAND && answers[0].slot == slot, "an Enable Slot's completion names its slot");
}

/* Port events, in batches, until the event ring's consumer position is `index`. */
static void
pass_ports(state_t *state, uint32_t index)
{
	erx_report_record_t events[EVENT_BATCH];
	erx_trb_answer_t answers[EVENT_BATCH];
	uint32_t answered;

	while (state->model.event_index != index) {
		const uint32_t left = (index + ERX_DEVICE_TRB_EVENT_TRBS - state->model.event_index) % ERX_DEVICE_TRB_EVENT_TRBS;
		const uint32_t count = left < EVENT_BATCH ? left : EVENT_BATCH;

		for (uint32_t k = 0; k < count; k++)
			events[k] = event_trb(ERX_XHCI_TRB_TYPE_PORT_STATUS_CHANGE_EVENT, UINT64_C(1) << 24,
			    ERX_XHCI_COMPLETION_SUCCESS, 0, 0);
		EXPECT(deliver(state, events, count, count, answers, &answered) == ERX_OK && answered == count &&
		    answers[count - 1u].kind == ERX_TRB_ANSWER_PORT && answers[count - 1u].port == 1,
		    "port events are answered and end nothing");
	}
}

/* The model at a form with no ring bound, as made or after its reset. */
static void
model_idle(model_t *model)
{
	memset(model, 0, sizeof(*model));
	for (uint32_t block = 0; block < BLOCKS; block++)
		model->cycle[block] = 1;
	model->event_cycle = 1;
	model->next_tag = 0x7a90;
}

/*
 * The small form with every block's ring bound, its event ring's consumer position three short of
 * the wrap, so the explored completions cross it.
 */
static void
make_small(state_t *state)
{
	memset(state, 0, sizeof(*state));
	EXPECT(erx_device_trb_layout(&trb, &small_shape, &controller, BASE, 64, UINT64_C(1) << 20), "the small layout");
	EXPECT(erx_trb_form_make(&state->form, &trb, &no_regions), "a form over the small layout");
	model_idle(&state->model);
	enable_slot(state, SLOT, ERX_XHCI_COMPLETION_SUCCESS);
	for (uint32_t block = 0; block < BLOCKS; block++)
		bind(state, block, erx_trb_form_endpoint(SLOT, block_dci[block]), ERX_XHCI_COMPLETION_SUCCESS);
	pass_ports(state, ERX_DEVICE_TRB_EVENT_TRBS - 3u);
}

/* Whether the model's command in flight closes `block`'s endpoint: the one it names, or every one for a disable. */
static bool
model_closed(const model_t *model, uint32_t block)
{
	return (model->command.live && (model->command.command.kind == ERX_TRB_COMMAND_DISABLE_SLOT ||
	    model->command.command.dci == block_dci[block]));
}

/* The ledger's live holdings in the model: its transfers and its command in flight. */
static uint32_t
model_holdings(const model_t *model)
{
	return (model->live + (model->command.live ? 1u : 0));
}

/* The live transfers of `block`'s ring in the model. */
static uint32_t
live_on(const model_t *model, uint32_t block)
{
	uint32_t live = 0;

	for (uint32_t index = 0; index < model->live; index++)
		live += model->transfers[index].block == block;
	return (live);
}

/* A control transfer's data stage: the TRB before its head, in ring order, past any link. */
static uint32_t
data_stage(const transfer_t *transfer)
{
	uint32_t before = NO_BUFFER, last = NO_BUFFER;

	for (uint32_t index = 0; index < transfer->position_count; index++) {
		if (transfer->positions[index] != RING - 1) {
			before = last;
			last = transfer->positions[index];
		}
	}
	return (before);
}

/*
 * The model's run of `count` descriptions on `block`'s ring: the positions it takes from the
 * ring's position, the link where it reaches it or ends just before it; false where one is held.
 */
static bool
model_run(const model_t *model, uint32_t block, uint32_t count, transfer_t *transfer, uint32_t *first)
{
	uint32_t position = model->position[block], described = 0;

	transfer->position_count = 0;
	*first = position;
	while (described < count || position == RING - 1) {
		if (model->held[block][position])
			return (false);
		transfer->positions[transfer->position_count++] = position;
		if (position == RING - 1) {
			position = 0;
		} else {
			transfer->head = position++;
			described++;
		}
	}
	return (true);
}

static void
check_post(state_t *state, uint32_t post)
{
	model_t *const model = &state->model;
	const erx_device_trb_request_t made = request(post);
	const uint32_t block = post_block(post), kind = erx_device_trb_block_kind(&trb.shape, block);
	const uint32_t live = erx_dma_ledger_live(&state->form.ledger);
	transfer_t transfer = { .block = block, .buffer = NO_BUFFER, .tag = model->next_tag++ };
	erx_dma_sequence_t sequence;
	erx_device_trb_verdict_t verdict;
	uint32_t first;
	bool room;

	if (!made.control || made.data) {
		for (uint32_t buffer = 0; buffer < trb.shape.buffers[kind] && transfer.buffer == NO_BUFFER; buffer++) {
			if (!model->buffer_held[block][buffer])
				transfer.buffer = buffer;
		}
		room = transfer.buffer != NO_BUFFER;
	} else {
		room = true;
	}
	room = room && live_on(model, block) < trb.shape.buffers[kind] &&
	    model_run(model, block, post_trbs(post), &transfer, &first);
	verdict = erx_trb_form_post(&state->form, SLOT, block_dci[block], &made, transfer.tag, &sequence);
	if (!room) {
		EXPECT(verdict == ERX_DEVICE_TRB_REFUSE_FULL && erx_dma_ledger_live(&state->form.ledger) == live,
		    "a post with no free buffer, as many TDs as buffers or too few free positions is full and holds nothing");
		return;
	}
	if (model->state[block] != ERX_DMA_ENDPOINT_RUNNING || model_closed(model, block)) {
		EXPECT(verdict == ERX_DEVICE_TRB_REFUSE_HALTED && erx_dma_ledger_live(&state->form.ledger) == live,
		    "a post on an endpoint that is not running, or one the command in flight closes, is refused and "
		    "holds nothing (design-usb.md's queue table)");
		return;
	}
	EXPECT(verdict == ERX_DEVICE_TRB_ACCEPTED, "a post the model has room for is accepted");
	transfer.length = made.length;
	transfer.data = made.control && made.data ? data_stage(&transfer) : NO_BUFFER;

	/* The buffer, the lowest free one of the ring's own block, named by the normal or data TRB. */
	if (transfer.buffer != NO_BUFFER) {
		const uint64_t offset = trb.regions[trb.buffer[block][transfer.buffer]].offset;
		const uint32_t named = made.control ? transfer.positions[transfer.positions[1] == RING - 1 ? 2 : 1] :
		    transfer.head;
		const erx_dma_store_t *const store = stored_at(&sequence, position_offset(block, named));

		EXPECT(store != NULL && parameter(store) == BASE + offset, "the TRB names the lowest free buffer of its block");
		EXPECT(!made.control || named == transfer.data, "the data stage is the TRB before the head");
		if (!made.device_writes)
			EXPECT(sequence.fill_count == 1 && sequence.fills[0].offset == offset &&
			    sequence.fills[0].length == made.length, "an out transfer's bytes fill its buffer from offset 0");
		model->buffer_held[block][transfer.buffer] = true;
	}

	/* Nothing is live before the activation, the first TRB's control word with the ring's cycle. */
	{
		const erx_dma_store_t *const store = stored_at(&sequence, position_offset(block, first));

		EXPECT(sequence.activation.kind == ERX_DMA_ACTIVATE_STORE &&
		    sequence.activation.store.offset == position_offset(block, first) + 12u &&
		    control_cycle(sequence.activation.store.bytes) == model->cycle[block] &&
		    store != NULL && control_cycle(store->bytes + 12) != model->cycle[block],
		    "the first TRB is stored with the other cycle and made live by the activation");
	}

	/* The tag is the head's, the TD's last TRB, which the completion names. */
	{
		uint64_t tag = 0;

		EXPECT(erx_trb_form_tag(&state->form, erx_dma_ledger_holding(&state->form.ledger,
		    (erx_dma_place_t){ block, transfer.head }), &tag) && tag == transfer.tag,
		    "the transfer's tag is kept by its head");
	}

	for (uint32_t index = 0; index < transfer.position_count; index++) {
		model->held[block][transfer.positions[index]] = true;
		if (transfer.positions[index] == RING - 1)
			model->cycle[block] ^= 1u;
	}
	model->position[block] = (transfer.positions[transfer.position_count - 1u] + 1u) % RING;
	model->transfers[model->live++] = transfer;
	model->state[block] = ERX_DMA_ENDPOINT_RUNNING;
	EXPECT(erx_dma_ledger_endpoint_state(&state->form.ledger, erx_trb_form_endpoint(SLOT, block_dci[block])) ==
	    ERX_DMA_ENDPOINT_RUNNING, "a post leaves its endpoint running");
}

/* The model's live transfer `live` ends: its positions and buffer come back. */
static void
model_end(model_t *model, uint32_t live)
{
	const transfer_t transfer = model->transfers[live];

	for (uint32_t index = 0; index < transfer.position_count; index++)
		model->held[transfer.block][transfer.positions[index]] = false;
	if (transfer.buffer != NO_BUFFER)
		model->buffer_held[transfer.block][transfer.buffer] = false;
	/* The live transfers stay in the order they were posted, so a ring's oldest is its first. */
	for (uint32_t later = live + 1u; later < model->live; later++)
		model->transfers[later - 1u] = model->transfers[later];
	model->live--;
}

/* Whether live transfer `live` is the oldest on its ring, the one the controller runs first. */
static bool
model_oldest(const model_t *model, uint32_t live)
{
	for (uint32_t earlier = 0; earlier < live; earlier++) {
		if (model->transfers[earlier].block == model->transfers[live].block)
			return (false);
	}
	return (true);
}

/*
 * The event that completes live transfer `live`, naming its head: Success, or a Short Packet with a
 * residue for an IN transfer. It ends the holding and answers the tag and the bytes moved in the
 * buffer: its length less the residue, or what its short data stage moved.
 */
static void
check_complete(state_t *state, uint32_t live)
{
	model_t *const model = &state->model;
	const transfer_t transfer = model->transfers[live];
	const uint32_t residue = transfer.block == IN_BLOCK ? 3u : 0;
	const uint32_t moved = transfer.short_data ? transfer.moved : transfer.length - residue;
	const erx_dma_found_t found = erx_dma_ledger_holding(&state->form.ledger, (erx_dma_place_t){ transfer.block,
	    transfer.head });
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(transfer.block,
	    transfer.head), residue != 0 ? ERX_XHCI_COMPLETION_SHORT_PACKET : ERX_XHCI_COMPLETION_SUCCESS, residue,
	    block_dci[transfer.block]);
	erx_trb_answer_t answer;
	uint32_t answered;
	uint64_t tag = 0;

	EXPECT(erx_trb_form_tag(&state->form, found, &tag) && tag == transfer.tag, "a completion's head gives its tag");
	EXPECT(deliver(state, &event, 1, 1, &answer, &answered) == ERX_OK && answered == 1 &&
	    answer.kind == ERX_TRB_ANSWER_TRANSFER && answer.tag == transfer.tag &&
	    erx_dma_ledger_live(&state->form.ledger) == model_holdings(model) - 1u, "the completion ends the transfer's holding");
	EXPECT(transfer.buffer == NO_BUFFER ? answer.data.length == 0 :
	    answer.data.offset == trb.regions[trb.buffer[transfer.block][transfer.buffer]].offset &&
	    answer.data.length == moved, "the answer names the bytes moved, from the buffer's first");
	EXPECT(!erx_trb_form_tag(&state->form, found, &tag), "a holding kept past its release gives no tag");
	model_end(model, live);
}

/*
 * A Short Packet on live control transfer `live`'s data stage: it ends nothing and answers
 * nothing, and the bytes the stage moved are what the status stage's event answers.
 */
static void
check_short(state_t *state, uint32_t live)
{
	transfer_t *const transfer = &state->model.transfers[live];
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(transfer->block,
	    transfer->data), ERX_XHCI_COMPLETION_SHORT_PACKET, 5, block_dci[transfer->block]);
	erx_trb_answer_t answer;
	uint32_t answered;

	EXPECT(deliver(state, &event, 1, 1, &answer, &answered) == ERX_OK && answered == 0 &&
	    erx_dma_ledger_live(&state->form.ledger) == model_holdings(&state->model), "a short data stage ends nothing");
	transfer->short_data = true;
	transfer->moved = transfer->length - 5u;
}

static void
check_port(state_t *state)
{
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_PORT_STATUS_CHANGE_EVENT, UINT64_C(1) << 24,
	    ERX_XHCI_COMPLETION_SUCCESS, 0, 0);
	erx_trb_answer_t answer;
	uint32_t answered;

	EXPECT(deliver(state, &event, 1, 1, &answer, &answered) == ERX_OK && answered == 1 &&
	    answer.kind == ERX_TRB_ANSWER_PORT && answer.port == 1 &&
	    erx_dma_ledger_live(&state->form.ledger) == model_holdings(&state->model), "a port event ends nothing");
}

static void refused(state_t *state, erx_report_record_t event, const char *what);
static erx_report_record_t completing(const transfer_t *transfer, uint32_t code, uint32_t residue);

/*
 * Every sequence of posts and events to DEPTH: each post, the completion of each live transfer in
 * any order, across rings, a short data stage of each live control transfer that has had none, and
 * a port event. An event of a transfer that is not its ring's oldest is refused.
 */
static void
explore(const state_t *state, uint32_t depth)
{
	const uint32_t live = state->model.live;

	states++;
	if (depth == DEPTH)
		return;
	for (uint32_t step = 0; step < POSTS + 2u * live + 1u; step++) {
		state_t next = *state;

		if (step < POSTS) {
			check_post(&next, step);
		} else if (step < POSTS + live && !model_oldest(&next.model, step - POSTS)) {
			refused(&next, completing(&next.model.transfers[step - POSTS], ERX_XHCI_COMPLETION_SUCCESS, 0),
			    "the completion of a transfer that is not its ring's oldest");
			continue;
		} else if (step < POSTS + live) {
			check_complete(&next, step - POSTS);
		} else if (step < POSTS + 2u * live) {
			const transfer_t *const transfer = &next.model.transfers[step - POSTS - live];

			if (transfer->data == NO_BUFFER || transfer->short_data || !model_oldest(&next.model, step - POSTS - live))
				continue;
			check_short(&next, step - POSTS - live);
		} else {
			check_port(&next);
		}
		explore(&next, depth + 1);
	}
}

/*
 * An event the form refuses: delivered alone, it is consumed by nothing, answers nothing, breaks
 * the form and ends no holding; the broken form refuses every call until its reset.
 */
static void
refused(state_t *state, erx_report_record_t event, const char *what)
{
	const uint32_t live = erx_dma_ledger_live(&state->form.ledger);
	erx_trb_answer_t answer;
	uint32_t answered, count;

	if (deliver(state, &event, 1, 0, &answer, &answered) != ERX_ECORRUPT || answered != 0 ||
	    erx_dma_ledger_live(&state->form.ledger) != live || erx_trb_form_acquire(&state->form, NULL, 0, &count) != ERX_ECORRUPT) {
		printf("FAILED %s:%d: refused: %s\n", __FILE__, __LINE__, what);
		exit(1);
	}
}

/* A small form with an IN transfer, a control transfer with a data stage and an OUT one posted. */
static void
make_posted(state_t *state)
{
	make_small(state);
	check_post(state, POST_IN);
	check_post(state, POST_CONTROL_DATA);
	check_post(state, POST_OUT);
}

static erx_report_record_t
completing(const transfer_t *transfer, uint32_t code, uint32_t residue)
{
	return (event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(transfer->block, transfer->head),
	    code, residue, block_dci[transfer->block]));
}

/* The model's oldest live transfer on `block`'s ring, the one the controller runs first, or LIVE_MAX. */
static uint32_t
model_oldest_on(const model_t *model, uint32_t block)
{
	for (uint32_t live = 0; live < model->live; live++) {
		if (model->transfers[live].block == block)
			return (live);
	}
	return (LIVE_MAX);
}

/*
 * Whether design-usb.md's queue table accepts `command` in its endpoint's state: Stop Endpoint on
 * a running endpoint, Reset Endpoint on a halted one and Set TR Dequeue Pointer on a stopped one
 * (xHCI 1.2, 4.6.9, p. 140; 4.6.8, p. 129; 4.6.10, p. 141). A Disable Slot names no endpoint.
 */
static bool
model_accepts(const model_t *model, const erx_trb_command_t *command)
{
	for (uint32_t block = 0; block < BLOCKS; block++) {
		if (block_dci[block] != command->dci)
			continue;
		switch (command->kind) {
		case ERX_TRB_COMMAND_STOP_ENDPOINT:
			return (model->state[block] == ERX_DMA_ENDPOINT_RUNNING);
		case ERX_TRB_COMMAND_RESET_ENDPOINT:
			return (model->state[block] == ERX_DMA_ENDPOINT_HALTED);
		case ERX_TRB_COMMAND_SET_TR_DEQUEUE:
			return (model->state[block] == ERX_DMA_ENDPOINT_STOPPED);
		default:
			break;
		}
	}
	return (true);
}

/*
 * Posts `command`, which names an endpoint of the model's blocks or none: refused full while a
 * command is in flight, since it holds the command ring's one buffer; badarg in a state the queue
 * table refuses it; accepted otherwise, closing the endpoints it acts on until its completion.
 * True when it is accepted.
 */
static bool
check_command(state_t *state, erx_trb_command_t command)
{
	model_t *const model = &state->model;
	const uint32_t live = erx_dma_ledger_live(&state->form.ledger);
	const uint32_t head = erx_dma_ledger_position(&state->form.ledger, COMMANDS).index;
	erx_dma_sequence_t sequence;
	const erx_device_trb_verdict_t verdict = erx_trb_form_command(&state->form, &command, model->next_tag, &sequence);

	if (model->command.live) {
		EXPECT(verdict == ERX_DEVICE_TRB_REFUSE_FULL && erx_dma_ledger_live(&state->form.ledger) == live,
		    "a second command while one is in flight is full and holds nothing");
		return (false);
	}
	if (!model_accepts(model, &command)) {
		EXPECT(verdict == ERX_DEVICE_TRB_REFUSE_BADARG && erx_dma_ledger_live(&state->form.ledger) == live &&
		    erx_dma_ledger_position(&state->form.ledger, COMMANDS).index == head,
		    "a command its endpoint's state does not accept is badarg and holds nothing");
		return (false);
	}
	EXPECT(verdict == ERX_DEVICE_TRB_ACCEPTED && erx_dma_ledger_live(&state->form.ledger) == live + 1u,
	    "a command its endpoint's state accepts is posted");
	EXPECT(!writes_dcbaa(&state->form.layout, &sequence), "no publication but an Address Device's writes the DCBAA: a "
	    "Disable Slot's entry stays until its success, since the controller holds the slot until then");
	model->command = (model_command_t){ .live = true, .command = command, .head = head, .tag = model->next_tag++ };
	return (true);
}

/*
 * The completion of the command in flight, a success or a Context State Error: its holding ends and
 * its tag is answered; on success a stop or a Reset Endpoint leaves its endpoint stopped, a Set TR
 * Dequeue Pointer retires every transfer on its ring, and a Disable Slot every transfer and binding.
 */
static void
check_command_end(state_t *state, bool success)
{
	model_t *const model = &state->model;
	const model_command_t command = model->command;
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, BASE + command_offset(command.head),
	    success ? ERX_XHCI_COMPLETION_SUCCESS : ERX_XHCI_COMPLETION_CONTEXT_STATE_ERROR, 0, 0);
	erx_trb_answer_t answers[ERX_TRB_FORM_ANSWERS_MAX(1)];
	uint64_t stopped[LIVE_MAX];
	uint32_t answered, stopped_count = 0;

	EXPECT(deliver(state, &event, 1, 1, answers, &answered) == ERX_OK && answered >= 1 &&
	    answers[answered - 1].kind == ERX_TRB_ANSWER_COMMAND && answers[answered - 1].tag == command.tag,
	    "a command's completion answers its tag last, after the transfers it retires");
	EXPECT(success && command.command.kind == ERX_TRB_COMMAND_DISABLE_SLOT ?
	    clears_entry(&state->form.layout, &delivered, command.command.slot) : delivered.clean_count == 0,
	    "a Disable Slot's consumed success clears the slot's DCBAA entry; no other completion writes memory");
	model->command = (model_command_t){ 0 };
	for (uint32_t block = 0; block < BLOCKS && success; block++) {
		const bool named = command.command.dci == block_dci[block];

		switch (command.command.kind) {
		case ERX_TRB_COMMAND_STOP_ENDPOINT:
		case ERX_TRB_COMMAND_RESET_ENDPOINT:
			if (named)
				model->state[block] = ERX_DMA_ENDPOINT_STOPPED;
			break;
		case ERX_TRB_COMMAND_SET_TR_DEQUEUE:
		case ERX_TRB_COMMAND_DISABLE_SLOT:
			if (!named && command.command.kind == ERX_TRB_COMMAND_SET_TR_DEQUEUE)
				break;
			for (uint32_t live = model->live; live-- > 0;) {
				if (model->transfers[live].block != block)
					continue;
				if (!model->transfers[live].halted)
					stopped[stopped_count++] = model->transfers[live].tag;
				model_end(model, live);
			}
			/* Set TR Dequeue Pointer opens its queue again (design-usb.md's queue table). */
			model->state[block] = command.command.kind == ERX_TRB_COMMAND_DISABLE_SLOT ? ERX_DMA_ENDPOINT_DISABLED :
			    ERX_DMA_ENDPOINT_RUNNING;
			break;
		default:
			break;
		}
	}
	EXPECT(erx_dma_ledger_live(&state->form.ledger) == model_holdings(model), "the ledger's holdings are the model's transfers");
	for (uint32_t block = 0; block < BLOCKS; block++)
		EXPECT(erx_dma_ledger_endpoint_state(&state->form.ledger, erx_trb_form_endpoint(SLOT, block_dci[block])) ==
		    model->state[block], "each endpoint's state is the model's");
	/* Each transfer the success retires is answered `stopped` once, with its own tag; a halted one was answered already. */
	EXPECT(answered == 1u + stopped_count, "a command's success answers each transfer it retires that no error answered");
	for (uint32_t k = 0; k < stopped_count; k++) {
		uint32_t found = 0;

		for (uint32_t answer = 0; answer + 1 < answered; answer++) {
			found += answers[answer].tag == stopped[k] && answers[answer].kind == ERX_TRB_ANSWER_TRANSFER &&
			    answers[answer].code == ERX_XHCI_COMPLETION_STOPPED && answers[answer].data.length == 0;
		}
		EXPECT(found == 1, "a retired transfer is answered stopped, with no bytes, under its own tag, once");
	}
}

/*
 * A Stall on live transfer `live`, its ring's oldest: answered with the code and no bytes, its
 * holding kept, its endpoint halted. A second error for it is refused.
 */
static void
check_halt(state_t *state, uint32_t live)
{
	transfer_t *const transfer = &state->model.transfers[live];
	erx_report_record_t event = completing(transfer, ERX_XHCI_COMPLETION_STALL, 0);
	erx_trb_answer_t answer;
	uint32_t answered;

	if (transfer->halted) {
		refused(state, event, "a second error for one transfer");
		return;
	}
	EXPECT(deliver(state, &event, 1, 1, &answer, &answered) == ERX_OK && answered == 1 &&
	    answer.kind == ERX_TRB_ANSWER_TRANSFER && answer.code == ERX_XHCI_COMPLETION_STALL && answer.tag == transfer->tag &&
	    answer.data.length == 0 && erx_dma_ledger_live(&state->form.ledger) == model_holdings(&state->model),
	    "an error answers the oldest transfer with no bytes and keeps its holding");
	transfer->halted = true;
	state->model.state[transfer->block] = ERX_DMA_ENDPOINT_HALTED;
	EXPECT(erx_dma_ledger_endpoint_state(&state->form.ledger, erx_trb_form_endpoint(SLOT, block_dci[transfer->block])) ==
	    ERX_DMA_ENDPOINT_HALTED, "an error halts its endpoint");
}

/*
 * A stop's event on `block`'s ring, naming its producer position: passed, ending and answering
 * nothing, only as the first for a Stop Endpoint in flight naming the block's endpoint; refused
 * otherwise.
 */
static void
check_stop_event(state_t *state, uint32_t block)
{
	model_t *const model = &state->model;
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(block,
	    model->position[block]), ERX_XHCI_COMPLETION_STOPPED, 0, block_dci[block]);
	erx_trb_answer_t answer;
	uint32_t answered;

	if (!model->command.live || model->command.command.kind != ERX_TRB_COMMAND_STOP_ENDPOINT ||
	    model->command.command.dci != block_dci[block] || model->command.stop_event) {
		refused(state, event, "a stop's event with no Stop Endpoint of its endpoint in flight, or a second one");
		return;
	}
	EXPECT(deliver(state, &event, 1, 1, &answer, &answered) == ERX_OK && answered == 0 &&
	    erx_dma_ledger_live(&state->form.ledger) == model_holdings(model), "a stop's event ends and answers nothing");
	model->command.stop_event = true;
}

/* The command of `kind` naming `block`'s endpoint. */
static erx_trb_command_t
naming(erx_trb_command_kind_t kind, uint32_t block)
{
	return ((erx_trb_command_t){ .kind = kind, .slot = SLOT, .dci = block_dci[block] });
}

static bool check_disable(state_t *state);

enum {
	STEP_POST_IN, STEP_POST_OUT, STEP_COMPLETE_IN, STEP_COMPLETE_OUT, STEP_STALL_IN, STEP_STOP_EVENT_IN,
	STEP_STOP_IN, STEP_RESET_IN, STEP_DEQUEUE_IN, STEP_DISABLE, STEP_SUCCESS, STEP_FAILURE, STEPS
};

/*
 * Every sequence to COMMAND_DEPTH of commands and events against the model's endpoint states: posts
 * on the IN and OUT rings, the completion or a Stall of the IN ring's oldest transfer, the OUT
 * ring's oldest completing, a stop's event on the IN ring, a Stop Endpoint, Reset Endpoint or Set
 * TR Dequeue Pointer naming the IN endpoint, a Disable Slot, and the success or failure of the
 * command in flight. A completion of a halted transfer is refused, and so is a command while one
 * is in flight or in a state the queue table refuses it, and the walk goes no deeper from either.
 */
static void
explore_commands(const state_t *state, uint32_t depth)
{
	states++;
	if (depth == COMMAND_DEPTH)
		return;
	for (uint32_t step = 0; step < STEPS; step++) {
		state_t next = *state;
		const uint32_t in = model_oldest_on(&next.model, IN_BLOCK), out = model_oldest_on(&next.model, OUT_BLOCK);

		switch (step) {
		case STEP_POST_IN:
		case STEP_POST_OUT:
			if (next.model.state[post_block(step == STEP_POST_IN ? POST_IN : POST_OUT)] == ERX_DMA_ENDPOINT_DISABLED)
				continue;
			check_post(&next, step == STEP_POST_IN ? POST_IN : POST_OUT);
			break;
		case STEP_COMPLETE_IN:
		case STEP_COMPLETE_OUT: {
			const uint32_t live = step == STEP_COMPLETE_IN ? in : out;

			if (live == LIVE_MAX)
				continue;
			if (next.model.transfers[live].halted) {
				refused(&next, completing(&next.model.transfers[live], ERX_XHCI_COMPLETION_SUCCESS, 0),
				    "the completion of a halted transfer");
				continue;
			}
			check_complete(&next, live);
			break;
		}
		case STEP_STALL_IN:
			if (in == LIVE_MAX)
				continue;
			check_halt(&next, in);
			if (next.form.broken)
				continue;
			break;
		case STEP_STOP_EVENT_IN:
			check_stop_event(&next, IN_BLOCK);
			if (next.form.broken)
				continue;
			break;
		case STEP_STOP_IN:
		case STEP_RESET_IN:
		case STEP_DEQUEUE_IN:
			if (next.model.state[IN_BLOCK] == ERX_DMA_ENDPOINT_DISABLED)
				continue;
			if (!check_command(&next, naming(step == STEP_STOP_IN ? ERX_TRB_COMMAND_STOP_ENDPOINT :
			    step == STEP_RESET_IN ? ERX_TRB_COMMAND_RESET_ENDPOINT : ERX_TRB_COMMAND_SET_TR_DEQUEUE, IN_BLOCK)))
				continue;
			break;
		case STEP_DISABLE:
			if (next.model.state[IN_BLOCK] == ERX_DMA_ENDPOINT_DISABLED || check_disable(&next))
				continue;
			break;
		default:
			if (!next.model.command.live)
				continue;
			check_command_end(&next, step == STEP_SUCCESS);
			break;
		}
		explore_commands(&next, depth + 1);
	}
}

/*
 * A Disable Slot: refused, changing nothing, while an endpoint of the slot runs with a live
 * transfer (xHCI 1.2, 4.6.4); posted as any command otherwise. True for that refusal.
 */
static bool
check_disable(state_t *state)
{
	const model_t *const model = &state->model;
	const erx_trb_command_t disable = { .kind = ERX_TRB_COMMAND_DISABLE_SLOT, .slot = SLOT };
	const uint32_t live = erx_dma_ledger_live(&state->form.ledger);
	erx_dma_sequence_t sequence;
	bool busy = false;

	for (uint32_t block = 0; block < BLOCKS; block++)
		busy = busy || (model->state[block] == ERX_DMA_ENDPOINT_RUNNING && live_on(model, block) != 0);
	if (!busy || model->command.live) {
		check_command(state, disable);
		return (false);
	}
	EXPECT(erx_trb_form_command(&state->form, &disable, model->next_tag, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_dma_ledger_live(&state->form.ledger) == live, "a Disable Slot with a busy endpoint is refused");
	return (true);
}

/* The commands and their events, each from a small form with transfers posted. */
static void
test_commands(void)
{
	static state_t state, copy;
	erx_dma_sequence_t sequence;
	const uint32_t in_endpoint = erx_trb_form_endpoint(SLOT, block_dci[IN_BLOCK]);
	const erx_device_trb_request_t in = request(POST_IN);

	/* Stop Endpoint: its endpoint closed while it is in flight, one stop's event, stopped on success. */
	make_posted(&state);
	check_command(&state, naming(ERX_TRB_COMMAND_STOP_ENDPOINT, IN_BLOCK));
	check_command(&state, naming(ERX_TRB_COMMAND_RESET_ENDPOINT, OUT_BLOCK));
	check_complete(&state, model_oldest_on(&state.model, IN_BLOCK));
	EXPECT(erx_trb_form_post(&state.form, SLOT, block_dci[IN_BLOCK], &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_HALTED,
	    "the endpoint a Stop Endpoint in flight names takes no post");
	check_post(&state, POST_OUT);
	check_stop_event(&state, IN_BLOCK);
	copy = state;
	check_stop_event(&copy, IN_BLOCK);
	EXPECT(copy.form.broken, "a second stop's event for one Stop Endpoint breaks the form");
	check_command_end(&state, true);
	EXPECT(erx_dma_ledger_endpoint_state(&state.form.ledger, in_endpoint) == ERX_DMA_ENDPOINT_STOPPED,
	    "a stop leaves its endpoint stopped");
	EXPECT(erx_trb_form_post(&state.form, SLOT, block_dci[IN_BLOCK], &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_HALTED,
	    "a stopped endpoint takes no post (design-usb.md's queue table)");
	check_command(&state, naming(ERX_TRB_COMMAND_SET_TR_DEQUEUE, IN_BLOCK));
	check_command_end(&state, true);
	check_post(&state, POST_IN);

	make_posted(&state);
	check_stop_event(&state, IN_BLOCK);
	EXPECT(state.form.broken, "a stop's event with no Stop Endpoint in flight breaks the form");

	/* A halted endpoint: no drop; Reset Endpoint stops it; Set TR Dequeue Pointer retires the halted transfer. */
	make_posted(&state);
	check_halt(&state, model_oldest_on(&state.model, IN_BLOCK));
	{
		const erx_trb_command_t drop = { .kind = ERX_TRB_COMMAND_CONFIGURE_ENDPOINT, .slot = SLOT,
		    .drops = 1u << block_dci[IN_BLOCK] };
		const uint32_t head = state.model.transfers[model_oldest_on(&state.model, IN_BLOCK)].head;

		EXPECT(erx_trb_form_command(&state.form, &drop, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
		    "a drop of a halted endpoint is refused");
		check_command(&state, naming(ERX_TRB_COMMAND_RESET_ENDPOINT, IN_BLOCK));
		check_command_end(&state, true);
		EXPECT(erx_trb_form_post(&state.form, SLOT, block_dci[IN_BLOCK], &in, 1, &sequence) ==
		    ERX_DEVICE_TRB_REFUSE_HALTED && erx_dma_ledger_live(&state.form.ledger) == model_holdings(&state.model),
		    "a post on an endpoint Reset Endpoint stopped, its halted transfer still held, is refused");
		check_command(&state, naming(ERX_TRB_COMMAND_SET_TR_DEQUEUE, IN_BLOCK));
		check_command_end(&state, true);
		EXPECT(erx_dma_ledger_holding(&state.form.ledger, (erx_dma_place_t){ IN_BLOCK, head }).holding == NULL &&
		    erx_dma_ledger_binding(&state.form.ledger, IN_BLOCK) == in_endpoint,
		    "Set TR Dequeue Pointer retires the halted transfer and keeps the binding");
		check_post(&state, POST_IN);
		check_complete(&state, model_oldest_on(&state.model, IN_BLOCK));
	}

	/* Disable Slot: refused with a busy endpoint; on success every binding of the slot ends. */
	make_posted(&state);
	EXPECT(check_disable(&state), "a slot with transfers running is busy");
	make_small(&state);
	check_post(&state, POST_IN);
	check_halt(&state, model_oldest_on(&state.model, IN_BLOCK));
	EXPECT(!check_disable(&state), "a halted endpoint's transfer leaves the slot idle");
	check_command_end(&state, true);
	for (uint32_t block = 0; block < BLOCKS; block++)
		EXPECT(erx_dma_ledger_binding(&state.form.ledger, block) == 0, "a Disable Slot ends each binding of its slot");

	/*
	 * A failed Address Device leaves the slot in the Default state, EP0 enabled on its ring (xHCI 1.2,
	 * 4.6.5, p. 114): the ring stays bound, EP0 disabled, taking no transfer and no command but
	 * Disable Slot, whose success ends the binding.
	 */
	erx_trb_form_reset(&state.form);
	model_idle(&state.model);
	enable_slot(&state, SLOT, ERX_XHCI_COMPLETION_SUCCESS);
	bind(&state, CONTROL_BLOCK, erx_trb_form_endpoint(SLOT, 1), ERX_XHCI_COMPLETION_TRANSACTION_ERROR);
	{
		const erx_device_trb_request_t control = request(POST_CONTROL);
		const erx_trb_command_t again = binding(SLOT, 1, CONTROL_BLOCK);

		EXPECT(erx_trb_form_post(&state.form, SLOT, 1, &control, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_HALTED,
		    "EP0 after a failed Address Device takes no transfer");
		EXPECT(erx_trb_form_command(&state.form, &(erx_trb_command_t){ .kind = ERX_TRB_COMMAND_SET_TR_DEQUEUE,
		    .slot = SLOT, .dci = 1 }, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
		    erx_trb_form_command(&state.form, &(erx_trb_command_t){ .kind = ERX_TRB_COMMAND_STOP_ENDPOINT,
		    .slot = SLOT, .dci = 1 }, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
		    "nor a stop or a restart of it");
		EXPECT(erx_trb_form_command(&state.form, &again, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
		    "nor another Address Device binding it a ring");
		EXPECT(erx_trb_form_command(&state.form, &(erx_trb_command_t){ .kind = ERX_TRB_COMMAND_DISABLE_SLOT,
		    .slot = SLOT, .drops = 1u << 3 }, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
		    "a command whose reach drops nothing carries no drops");
		check_command(&state, (erx_trb_command_t){ .kind = ERX_TRB_COMMAND_DISABLE_SLOT, .slot = SLOT });
		check_command_end(&state, true);
		EXPECT(erx_dma_ledger_binding(&state.form.ledger, CONTROL_BLOCK) == 0, "Disable Slot ends EP0's kept binding");
	}
}

static void
test_refusals(void)
{
	static state_t state;
	const transfer_t *in, *control;
	erx_report_record_t event, events[2];
	erx_trb_answer_t answers[2];
	erx_dma_sequence_t sequence;
	uint32_t answered, count, words[ERX_DEVICE_TRB_EVENT_TRBS + 1u] = { 0 };
	uint64_t dequeue;

	make_posted(&state);
	in = &state.model.transfers[0];
	control = &state.model.transfers[1];
	event = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.pointer = BASE + trb.regions[trb.input_context].offset;
	refused(&state, event, "a pointer outside every ring");

	make_posted(&state);
	event = completing(control, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.pointer = BASE + position_offset(control->block, control->positions[0]);
	refused(&state, event, "a pointer one TRB off the head: the setup stage");
	event = completing(control, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.pointer += 4;
	erx_trb_form_reset(&state.form);
	EXPECT(erx_dma_ledger_idle(&state.form.ledger) && erx_trb_form_acquire(&state.form, NULL, 0, &count) == ERX_OK &&
	    count == 0, "the reset's idle report makes the form whole and ends every holding");

	make_posted(&state);
	refused(&state, event, "a pointer inside the head, not at its start");

	make_posted(&state);
	event = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.control = (event.xhci_trb_transfer_event.control & ~(UINT32_C(0x1f) << 16)) |
	    block_dci[OUT_BLOCK] << 16;
	refused(&state, event, "an event of another endpoint naming this one's head");

	make_posted(&state);
	event = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.control = (event.xhci_trb_transfer_event.control & ~(UINT32_C(0x3f) << 10)) |
	    (uint32_t)ERX_XHCI_TRB_TYPE_HOST_CONTROLLER_EVENT << 10;
	refused(&state, event, "a type no meaning of the event ring selects");

	make_posted(&state);
	refused(&state, completing(in, ERX_XHCI_COMPLETION_SHORT_PACKET, 65), "a residue past the TRB's length");

	make_posted(&state);
	check_short(&state, 1);
	refused(&state, event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(control->block, control->data),
	    ERX_XHCI_COMPLETION_SHORT_PACKET, 5, block_dci[control->block]), "a second short data stage");

	make_posted(&state);
	refused(&state, event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(control->block, control->data),
	    ERX_XHCI_COMPLETION_SHORT_PACKET, 5, block_dci[IN_BLOCK]), "a short data stage of another endpoint's transfer");

	make_posted(&state);
	refused(&state, event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(control->block, control->data),
	    ERX_XHCI_COMPLETION_SHORT_PACKET, 9, block_dci[control->block]), "a short data stage's residue past its length");

	make_posted(&state);
	event = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.control |= 1u << 2;
	refused(&state, event, "the event-data flag");

	make_posted(&state);
	{
		erx_report_record_t stall = completing(in, ERX_XHCI_COMPLETION_STALL, 0);
		const erx_device_trb_request_t again = request(POST_IN);
		const uint32_t endpoint = erx_trb_form_endpoint(SLOT, block_dci[in->block]), live = erx_dma_ledger_live(&state.form.ledger);
		erx_trb_answer_t answer;
		uint32_t answered;

		EXPECT(deliver(&state, &stall, 1, 1, &answer, &answered) == ERX_OK && answered == 1 &&
		    answer.kind == ERX_TRB_ANSWER_TRANSFER && answer.code == ERX_XHCI_COMPLETION_STALL && answer.data.length == 0 &&
		    answer.tag == in->tag && erx_dma_ledger_live(&state.form.ledger) == live &&
		    erx_dma_ledger_endpoint_state(&state.form.ledger, endpoint) == ERX_DMA_ENDPOINT_HALTED,
		    "an error code answers the oldest transfer with no bytes, keeps its holding and halts its endpoint");
		EXPECT(erx_trb_form_post(&state.form, SLOT, block_dci[in->block], &again, 3, &sequence) == ERX_DEVICE_TRB_REFUSE_HALTED,
		    "a halted endpoint takes no post");
		refused(&state, completing(in, ERX_XHCI_COMPLETION_STALL, 0), "a second error for one transfer");
	}

	make_posted(&state);
	refused(&state, event_trb(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, BASE + command_offset(0),
	    ERX_XHCI_COMPLETION_SUCCESS, 0, 0), "a command completion naming no live command");

	/* A record not yet written: its cycle bit is not the consumer cycle state, so it is not acquired. */
	make_posted(&state);
	events[0] = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	events[1] = completing(&state.model.transfers[2], ERX_XHCI_COMPLETION_SUCCESS, 0);
	events[0].xhci_trb_transfer_event.control |= state.model.event_cycle;
	events[1].xhci_trb_transfer_event.control |= state.model.event_cycle ^ 1u;
	words[0] = events[0].xhci_trb_transfer_event.control;
	words[1] = events[1].xhci_trb_transfer_event.control;
	EXPECT(erx_trb_form_acquire(&state.form, words + 1, 1, &count) == ERX_OK && count == 0 &&
	    erx_trb_form_complete(&state.form, events + 1, 1, answers, &answered, &dequeue, &delivered) == ERX_OK && answered == 0 &&
	    dequeue == BASE + event_offset(state.model.event_index) && erx_dma_ledger_live(&state.form.ledger) == 3,
	    "an event with a stale cycle bit is not acquired, consumed or answered");
	EXPECT(erx_trb_form_acquire(&state.form, words, 2, &count) == ERX_OK && count == 1 &&
	    erx_trb_form_complete(&state.form, events, 2, answers, &answered, &dequeue, &delivered) == ERX_OK && answered == 1 &&
	    erx_dma_ledger_live(&state.form.ledger) == 2, "the acquisition stops at the first stale cycle bit");
	EXPECT(erx_trb_form_acquire(&state.form, words, ERX_DEVICE_TRB_EVENT_TRBS + 1u, &count) == ERX_ECORRUPT,
	    "more cycle words than the event ring has breaks the form");

	/* A failing binding command ends its binding, unless a transfer holds the ring (the reach rule's). */
	erx_trb_form_reset(&state.form);
	model_idle(&state.model);
	enable_slot(&state, SLOT, ERX_XHCI_COMPLETION_SUCCESS);
	bind(&state, CONTROL_BLOCK, erx_trb_form_endpoint(SLOT, 1), ERX_XHCI_COMPLETION_SUCCESS);
	bind(&state, IN_BLOCK, erx_trb_form_endpoint(SLOT, block_dci[IN_BLOCK]), ERX_XHCI_COMPLETION_TRB_ERROR);
	{
		/* The reach: a ring a binding command binds takes no transfer until its completion is consumed. */
		const erx_trb_command_t command = binding(SLOT, block_dci[IN_BLOCK], IN_BLOCK);
		const erx_device_trb_request_t in = request(POST_IN);
		const uint32_t head = erx_dma_ledger_position(&state.form.ledger, COMMANDS).index;
		erx_report_record_t failed = event_trb(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, BASE + command_offset(head),
		    ERX_XHCI_COMPLETION_TRB_ERROR, 0, 0);
		erx_trb_answer_t answer;
		uint32_t answered;

		EXPECT(erx_trb_form_command(&state.form, &command, 9, &sequence) == ERX_DEVICE_TRB_ACCEPTED,
		    "a binding command again");
		EXPECT(erx_trb_form_post(&state.form, SLOT, block_dci[IN_BLOCK], &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_HALTED,
		    "a transfer posted before its binding's completion is refused");
		EXPECT(deliver(&state, &failed, 1, 1, &answer, &answered) == ERX_OK && answered == 1 && answer.tag == 9 &&
		    erx_dma_ledger_binding(&state.form.ledger, IN_BLOCK) == 0 && erx_dma_ledger_live(&state.form.ledger) == 0,
		    "its failure ends its binding, and no transfer was on the ring");
	}
}


/* The form's own shape: every block's ring and pool where erx_device_trb_layout put them. */
static void
test_layout(void)
{
	static erx_trb_form_t form;
	static erx_device_trb_layout_t full;
	const erx_device_trb_controller_t four = { .slots = 4, .ports = 2, .scratchpads = 2, .context_size = 64 };
	erx_device_trb_shape_t longer = erx_device_trb_shape;
	erx_dma_layout_t layout;
	uint32_t blocks = 0;

	EXPECT(erx_device_trb_layout(&full, &erx_device_trb_shape, &four, BASE, 64, UINT64_C(1) << 26), "the form's layout");
	EXPECT(erx_trb_form_make(&form, &full, &no_regions), "the ledger takes the form's own shape");
	layout = *erx_dma_ledger_layout(erx_trb_form_ledger(&form));
	for (uint32_t kind = 0; kind < ERX_DEVICE_TRB_KINDS; kind++)
		blocks += erx_device_trb_shape.blocks[kind];
	EXPECT(layout.table_count == blocks + 2u && layout.pool_count == blocks + 1u, "a ring and a pool per block");
	for (uint32_t block = 0; block < blocks; block++) {
		const uint32_t kind = erx_device_trb_block_kind(&erx_device_trb_shape, block);

		EXPECT(layout.tables[block].first == erx_device_trb_position_offset(&full, block, 0) &&
		    layout.tables[block].count == ERX_DEVICE_TRB_RING_TRBS && layout.tables[block].pool == block,
		    "block b's ring is table b, its pool pool b");
		for (uint32_t buffer = 0; buffer < erx_device_trb_shape.buffers[kind]; buffer++)
			EXPECT(layout.pools[block].first + (uint64_t)buffer * layout.pools[block].stride ==
			    full.regions[full.buffer[block][buffer]].offset, "a pool's buffers are its block's regions");
	}
	EXPECT(layout.tables[blocks].first == full.regions[full.command_ring].offset &&
	    layout.tables[blocks].pool == blocks && layout.pools[blocks].count == 1 &&
	    layout.pools[blocks].first == full.regions[full.input_context].offset,
	    "the command ring's pool holds just the input context");
	EXPECT(layout.tables[blocks + 1u].first == full.regions[full.event_ring].offset &&
	    layout.tables[blocks + 1u].count == ERX_DEVICE_TRB_EVENT_TRBS, "the event ring's segment");

	longer.ring_trbs = ERX_DEVICE_TRB_RING_TRBS + 1u;
	EXPECT(erx_device_trb_layout(&full, &longer, &four, BASE, 64, UINT64_C(1) << 26) && !erx_trb_form_layout(&full, &layout),
	    "a ring longer than the tags keep is refused");
}

/* The little-endian bytes the sequence stores at `offset`, inside any one store, `length` of them at most 8. */
static uint64_t
stored_word(const erx_dma_sequence_t *sequence, uint64_t offset, uint32_t length)
{
	uint64_t value = 0;

	for (uint32_t index = 0; index < sequence->store_count; index++) {
		const erx_dma_store_t *const store = &sequence->stores[index];

		if (offset >= store->offset && offset + length <= store->offset + store->length) {
			memcpy(&value, store->bytes + (offset - store->offset), length);
			return (value);
		}
	}
	EXPECT(false, "the install stores the word");
	return (0);
}

static bool
covers(const erx_dma_range_t *ranges, uint32_t count, uint64_t offset, uint64_t length)
{
	for (uint32_t index = 0; index < count; index++) {
		if (ranges[index].offset <= offset && offset + length <= ranges[index].offset + ranges[index].length)
			return (true);
	}
	return (false);
}

/*
 * The install (docs/design-usb.md, "Install"): every region zeroed and cleaned; DCBAA entry 0, the
 * scratchpad array, the segment table's entry and the command ring's link written; the registers
 * in FreeBSD's order from the layout, and USBCMD's run as the activation. Refused while anything is
 * held, and over memory past 32 bits on a controller without AC64.
 */
static void
test_install(void)
{
	static erx_trb_form_t form;
	static erx_dma_sequence_t sequence;
	const erx_device_trb_controller_t three = { .slots = 2, .ports = 1, .scratchpads = 3, .context_size = 32 };
	const erx_trb_command_t enable = { .kind = ERX_TRB_COMMAND_ENABLE_SLOT };
	const erx_dma_register_write_t registers[] = {
		{ ERX_DMA_XHCI_SLOTS, 2 },
		{ ERX_DMA_XHCI_DCBAA, 0 },
		{ ERX_DMA_XHCI_EVENT_RING_SIZE, 1 },
		{ ERX_DMA_XHCI_INTERRUPT_MODERATION, 0 },
		{ ERX_DMA_XHCI_EVENT_DEQUEUE, 0 },
		{ ERX_DMA_XHCI_SEGMENT_TABLE, 0 },
		{ ERX_DMA_XHCI_INTERRUPTER_ENABLE, 1 },
		{ ERX_DMA_XHCI_COMMAND_RING, 0 },
	};
	uint64_t pages, array, values[sizeof(registers) / sizeof(registers[0])];

	EXPECT(erx_device_trb_layout(&trb, &small_shape, &three, BASE, 64, UINT64_C(1) << 20), "the small layout");
	EXPECT(erx_trb_form_make(&form, &trb, &no_regions), "a form over it");
	EXPECT(erx_trb_form_install(&form, false, &sequence) == ERX_OK, "an idle form installs");
	EXPECT(covers(sequence.zeros, sequence.zero_count, 0, trb.bytes) &&
	    covers(sequence.cleans, sequence.clean_count, 0, trb.bytes), "every region is zeroed and cleaned");
	pages = trb.regions[trb.scratchpad].offset;
	array = pages + 3u * ERX_XHCI_PAGE_SIZE;
	EXPECT(stored_word(&sequence, trb.regions[trb.dcbaa].offset, 8) == BASE + array,
	    "DCBAA entry 0 names the scratchpad array");
	for (uint32_t page = 0; page < 3; page++)
		EXPECT(stored_word(&sequence, array + 8u * page, 8) == BASE + pages + (uint64_t)page * ERX_XHCI_PAGE_SIZE,
		    "the scratchpad array names each page");
	EXPECT(stored_word(&sequence, trb.regions[trb.segment_table].offset + ERX_XHCI_SEGMENT_TABLE_ENTRY_OFF_BASE, 8) ==
	    BASE + trb.regions[trb.event_ring].offset &&
	    stored_word(&sequence, trb.regions[trb.segment_table].offset + ERX_XHCI_SEGMENT_TABLE_ENTRY_OFF_SIZE, 4) ==
	    ERX_DEVICE_TRB_EVENT_TRBS, "the segment table's entry is the event ring");
	EXPECT(stored_at(&sequence, command_offset(RING - 1u)) != NULL &&
	    parameter(stored_at(&sequence, command_offset(RING - 1u))) == BASE + command_offset(0) &&
	    control_cycle(stored_at(&sequence, command_offset(RING - 1u))->bytes + ERX_XHCI_TRB_LINK_OFF_CONTROL) == 1u,
	    "the command ring's link leads back to its first TRB on lap 0");
	values[0] = 2;
	values[1] = BASE + trb.regions[trb.dcbaa].offset;
	values[2] = 1;
	values[3] = 500;	/* FreeBSD's moderation interval, 125 us (xhcireg.h:176) */
	values[4] = BASE + event_offset(0);
	values[5] = BASE + trb.regions[trb.segment_table].offset;
	values[6] = 1;
	values[7] = BASE + command_offset(0) + 1u;	/* the ring's cycle state, 1, in bit 0 */
	EXPECT(sequence.register_count == sizeof(registers) / sizeof(registers[0]), "eight registers");
	for (uint32_t at = 0; at < sequence.register_count; at++)
		EXPECT(sequence.registers[at].reg == registers[at].reg && sequence.registers[at].value == values[at],
		    "each register, in FreeBSD's order, from the layout");
	EXPECT(sequence.activation.kind == ERX_DMA_ACTIVATE_REGISTER && sequence.activation.reg.reg == ERX_DMA_XHCI_RUN &&
	    sequence.activation.reg.value == 1, "USBCMD's run is the activation");

	EXPECT(erx_trb_form_command(&form, &enable, 7, &sequence) == ERX_DEVICE_TRB_ACCEPTED, "a command is posted");
	EXPECT(erx_trb_form_install(&form, true, &sequence) == ERX_EBUSY, "nothing installs while a command is held");
	erx_trb_form_reset(&form);
	EXPECT(erx_trb_form_install(&form, true, &sequence) == ERX_OK, "the reset's idle report lets it install again");

	EXPECT(erx_device_trb_layout(&trb, &small_shape, &three, UINT64_C(1) << 32, 64, UINT64_C(1) << 20) &&
	    erx_trb_form_make(&form, &trb, &no_regions), "a layout above 4 GiB");
	EXPECT(erx_trb_form_install(&form, false, &sequence) == ERX_ERANGE, "a controller without AC64 does not reach it");
	EXPECT(erx_trb_form_install(&form, true, &sequence) == ERX_OK, "one with AC64 does");
	EXPECT(erx_device_trb_layout(&trb, &small_shape, &three, (UINT64_C(1) << 32) - (UINT64_C(1) << 20), 64,
	    UINT64_C(1) << 20) && erx_trb_form_make(&form, &trb, &no_regions), "a layout just below 4 GiB");
	EXPECT(erx_trb_form_install(&form, false, &sequence) == ERX_OK, "memory ending below 4 GiB needs no AC64");
	EXPECT(erx_device_trb_layout(&trb, &small_shape, &three, (UINT64_C(1) << 32) - (trb.bytes & ~UINT64_C(63)), 64,
	    UINT64_C(1) << 20) && erx_trb_form_make(&form, &trb, &no_regions), "a layout crossing 4 GiB");
	EXPECT(trb.device_base + trb.bytes > (UINT64_C(1) << 32) && erx_trb_form_install(&form, false, &sequence) == ERX_ERANGE,
	    "memory crossing 4 GiB needs AC64");

	for (uint32_t pages = 0; pages <= ERX_DEVICE_TRB_SCRATCHPADS_MAX; pages++) {
		const erx_device_trb_controller_t asking = { .slots = 2, .ports = 1, .scratchpads = pages, .context_size = 32 };

		EXPECT(erx_device_trb_layout(&trb, &small_shape, &asking, BASE, 64, UINT64_C(1) << 20) &&
		    erx_trb_form_make(&form, &trb, &no_regions) && erx_trb_form_install(&form, true, &sequence) == ERX_OK,
		    "an install over every count of pages");
		if (pages == 0) {
			EXPECT(stored_at(&sequence, trb.regions[trb.dcbaa].offset) == NULL, "with no page DCBAA entry 0 stays zero");
			continue;
		}
		array = trb.regions[trb.scratchpad].offset + (uint64_t)pages * ERX_XHCI_PAGE_SIZE;
		EXPECT(stored_word(&sequence, trb.regions[trb.dcbaa].offset, 8) == BASE + array, "DCBAA entry 0 names the array");
		for (uint32_t page = 0; page < pages; page++)
			EXPECT(stored_word(&sequence, array + 8u * page, 8) ==
			    BASE + trb.regions[trb.scratchpad].offset + (uint64_t)page * ERX_XHCI_PAGE_SIZE,
			    "the array names each page, in whole groups of four and a partial last one");
	}
}

static void
test_endpoints_and_requests(void)
{
	static state_t state;
	const erx_device_trb_request_t in = request(POST_IN), control = request(POST_CONTROL);
	erx_device_trb_request_t made;
	erx_dma_sequence_t sequence;

	EXPECT(erx_trb_form_endpoint(1, 1) == 0x21 && erx_trb_form_endpoint(ERX_DEVICE_TRB_SLOTS_MAX, 31) != 0 &&
	    erx_trb_form_endpoint(0, 1) == 0 && erx_trb_form_endpoint(1, 0) == 0 &&
	    erx_trb_form_endpoint(ERX_DEVICE_TRB_SLOTS_MAX + 1u, 1) == 0 && erx_trb_form_endpoint(1, 32) == 0 &&
	    erx_trb_form_endpoint(UINT32_MAX, UINT32_MAX) == 0, "a pair out of range names no endpoint");
	make_small(&state);
	EXPECT(erx_trb_form_post(&state.form, 0, 3, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_trb_form_post(&state.form, SLOT, 32 + 3, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_trb_form_post(&state.form, 2, 3, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "a queue out of range or with no ring bound is badarg");
	EXPECT(erx_trb_form_post(&state.form, SLOT, 1, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_trb_form_post(&state.form, SLOT, 3, &control, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_trb_form_post(&state.form, SLOT, 2, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "a normal transfer on EP0, a control one on a bulk queue and an IN one on an OUT queue are badarg");
	made = in;
	made.length = 65;
	EXPECT(erx_trb_form_post(&state.form, SLOT, 3, &made, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "a transfer longer than its block's buffer is badarg");
	EXPECT(erx_dma_ledger_live(&state.form.ledger) == 0, "a refused post holds nothing");
}

/*
 * The input context's contents (docs/design-usb.md, "What the DMA check judges"), decoded here by
 * the bit positions of xHCI 1.2, 6.2.2, 6.2.3 and 6.2.5 (Tables 6-4 to 6-6, pp. 444-446; 6-8 to
 * 6-11, pp. 450-453; 6-15 and 6-16, p. 461), never through the generated accessors whose
 * encoders wrote them.
 */
#define CONTEXTS	(1u + ERX_XHCI_DEVICE_CONTEXTS)

typedef struct image {
	uint32_t	size;			/* the context size */
	uint8_t		bytes[CONTEXTS * 64u];
} image_t;

static uint32_t
le32(const image_t *image, uint32_t context, uint32_t offset)
{
	const uint8_t *const at = image->bytes + context * image->size + offset;

	return ((uint32_t)at[0] | (uint32_t)at[1] << 8 | (uint32_t)at[2] << 16 | (uint32_t)at[3] << 24);
}

static uint64_t
le64(const image_t *image, uint32_t context, uint32_t offset)
{
	return ((uint64_t)le32(image, context, offset) | (uint64_t)le32(image, context, offset + 4u) << 32);
}

/* A form over the small shape at contexts of `size` bytes, nothing bound. */
static void
make_unbound(state_t *state, uint32_t size)
{
	erx_device_trb_controller_t sized = controller;

	sized.context_size = size;
	memset(state, 0, sizeof(*state));
	EXPECT(erx_device_trb_layout(&trb, &small_shape, &sized, BASE, 64, UINT64_C(1) << 20), "the small layout");
	EXPECT(erx_trb_form_make(&state->form, &trb, &no_regions), "a form over the small layout");
	model_idle(&state->model);
	enable_slot(state, SLOT, ERX_XHCI_COMPLETION_SUCCESS);
}

/*
 * The input context `command` publishes, whole: the zeros over its buffer, then its stores, each
 * inside it. False for a command the form refuses.
 */
static bool
publish_contexts(state_t *state, const erx_trb_command_t *command, image_t *image)
{
	const erx_device_trb_region_t *const region = &trb.regions[trb.input_context];
	erx_dma_sequence_t sequence;
	bool zeroed = false;

	if (erx_trb_form_command(&state->form, command, 5, &sequence) != ERX_DEVICE_TRB_ACCEPTED)
		return (false);
	memset(image->bytes, 0xa5, sizeof(image->bytes));
	image->size = trb.context_size;
	for (uint32_t k = 0; k < sequence.zero_count; k++)
		zeroed |= sequence.zeros[k].offset == region->offset && sequence.zeros[k].length >= CONTEXTS * image->size;
	EXPECT(zeroed, "rule 1 zeroes the whole input context");
	memset(image->bytes, 0, CONTEXTS * image->size);
	for (uint32_t k = 0; k < sequence.store_count; k++) {
		const erx_dma_store_t *const store = &sequence.stores[k];

		if (store->offset < region->offset || store->offset >= region->offset + region->length)
			continue;
		EXPECT(store->offset + store->length <= region->offset + CONTEXTS * image->size,
		    "each context's store lies inside the input context");
		memcpy(image->bytes + (store->offset - region->offset), store->bytes, store->length);
	}
	return (true);
}

/* The command in flight's success, consumed. */
static void
complete_command(state_t *state, uint32_t head)
{
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, BASE + command_offset(head),
	    ERX_XHCI_COMPLETION_SUCCESS, 0, 0);
	erx_trb_answer_t answers[ERX_TRB_FORM_ANSWERS_MAX(1)];
	uint32_t answered;

	EXPECT(deliver(state, &event, 1, 1, answers, &answered) == ERX_OK && answered == 1 &&
	    answers[0].kind == ERX_TRB_ANSWER_COMMAND, "the command's success");
}

/* Whether every byte of context `context` from `from` on is 0, the reserved half of a 64-byte one included. */
static bool
zero_from(const image_t *image, uint32_t context, uint32_t from)
{
	for (uint32_t offset = from; offset < image->size; offset++) {
		if (image->bytes[context * image->size + offset] != 0)
			return (false);
	}
	return (true);
}

/* Endpoint context dci: its type, packet, burst, interval, payload and ring, error count 3, no streams. */
static void
expect_endpoint(const image_t *image, uint32_t dci, uint32_t type, uint32_t packet, uint32_t average,
    uint32_t payload, uint32_t block)
{
	const uint32_t info = le32(image, dci + 1u, 0), config = le32(image, dci + 1u, 4);
	const uint64_t dequeue = le64(image, dci + 1u, 8);
	const uint32_t rates = le32(image, dci + 1u, 16);

	EXPECT((info & 0x7u) == 0 && (info >> 8 & 0x3u) == 0 && (info >> 10 & 0x1fu) == 0 && (info >> 15 & 1u) == 0 &&
	    (info >> 16 & 0xffu) == 0 && info >> 24 == 0, "state, Mult, MaxPStreams, LSA and interval 0 (Table 6-8)");
	EXPECT((config & 1u) == 0 && (config >> 1 & 0x3u) == 3 && (config >> 3 & 0x7u) == type && (config >> 7 & 1u) == 0 &&
	    (config >> 8 & 0xffu) == 0 && config >> 16 == packet, "error count 3, the type, HID 0, burst 0, the packet (Table 6-9)");
	EXPECT((dequeue & 1u) == 1 && (dequeue >> 1 & 0x7u) == 0 && (dequeue & ~UINT64_C(0xf)) == BASE + position_offset(block, 0),
	    "the dequeue pointer is its bound ring's first TRB, cycle state 1 (Table 6-10)");
	EXPECT((rates & 0xffffu) == average && rates >> 16 == payload, "the average TRB length and payload (Table 6-11)");
	EXPECT(zero_from(image, dci + 1u, 20), "the rest of the endpoint context is 0");
}

/* Address Device's input context: A0 and A1 alone (4.6.5, p. 112), the slot context's device fields, EP0's. */
static void
check_address_contexts(uint32_t size)
{
	static state_t state;
	static image_t image;
	erx_trb_command_t command = binding(SLOT, 1, CONTROL_BLOCK);
	uint32_t route, ports, tt;

	make_unbound(&state, size);
	command.slot_context = (erx_xhci_slot_context_free_t){ .route_route_string = 0x31, .route_speed = ERX_XHCI_SPEED_FULL,
	    .route_multi_tt = 1, .ports_root_port = 1, .tt_tt_slot = 2, .tt_tt_port = 4 };
	EXPECT(publish_contexts(&state, &command, &image), "an Address Device");
	EXPECT(le32(&image, 0, 0) == 0 && le32(&image, 0, 4) == 0x3u && zero_from(&image, 0, 8),
	    "Address Device adds the slot and EP0 and drops nothing");
	route = le32(&image, 1, 0);
	ports = le32(&image, 1, 4);
	tt = le32(&image, 1, 8);
	EXPECT((route & 0xfffffu) == 0x31 && (route >> 20 & 0xfu) == ERX_XHCI_SPEED_FULL && (route >> 24 & 1u) == 0 &&
	    (route >> 25 & 1u) == 1 && (route >> 26 & 1u) == 0 && route >> 27 == 1,
	    "route string, speed, MTT, not a hub, one context entry (Table 6-4)");
	EXPECT((ports & 0xffffu) == 0 && (ports >> 16 & 0xffu) == 1 && ports >> 24 == 0,
	    "exit latency 0, root port 1, no ports (Table 6-5)");
	EXPECT((tt & 0xffu) == 2 && (tt >> 8 & 0xffu) == 4 && (tt >> 16 & 0x3u) == 0 && tt >> 22 == 0,
	    "TT hub slot and port, think time 0, interrupter 0 (Table 6-6)");
	EXPECT(le32(&image, 1, 12) == 0 && zero_from(&image, 1, 12), "the address and slot state are 0 (Table 6-7)");
	expect_endpoint(&image, 1, ERX_XHCI_ENDPOINT_TYPE_CONTROL, 64, 8, 0, CONTROL_BLOCK);
	for (uint32_t context = 3; context < CONTEXTS; context++)
		EXPECT(zero_from(&image, context, 0), "no other context is written");
}

/*
 * Configure Endpoint adding bulk IN and OUT after an Address Device: A0 and each added index, never
 * A1 (4.6.6, p. 116); the hub fields and Context Entries; a drop's flag; Evaluate Context's EP0.
 */
static void
check_configure_contexts(void)
{
	static state_t state;
	static image_t image;
	const erx_trb_command_t address = binding(SLOT, 1, CONTROL_BLOCK);
	erx_trb_command_t configure = binding(SLOT, 3, IN_BLOCK);
	erx_trb_command_t drop = { .kind = ERX_TRB_COMMAND_CONFIGURE_ENDPOINT, .slot = SLOT, .drops = 1u << 2 };
	erx_trb_command_t evaluate = { .kind = ERX_TRB_COMMAND_EVALUATE_CONTEXT, .slot = SLOT, .ep0_packet = 512 };
	uint32_t route, ports, tt;

	make_unbound(&state, 32);
	EXPECT(publish_contexts(&state, &address, &image), "an Address Device");
	complete_command(&state, 1);
	configure.add_count = 2;
	configure.adds[1] = binding(SLOT, 2, OUT_BLOCK).adds[0];
	configure.slot_context = (erx_xhci_slot_context_free_t){ .route_hub = 1, .route_multi_tt = 1, .ports_port_count = 4,
	    .tt_tt_think_time = 2 };
	EXPECT(publish_contexts(&state, &configure, &image), "a Configure Endpoint adding bulk IN and OUT");
	EXPECT(le32(&image, 0, 0) == 0 && le32(&image, 0, 4) == (1u << 0 | 1u << 2 | 1u << 3),
	    "Configure Endpoint adds the slot and its endpoints, not EP0, and drops nothing");
	route = le32(&image, 1, 0);
	ports = le32(&image, 1, 4);
	tt = le32(&image, 1, 8);
	EXPECT((route & 0xfffffu) == 0 && (route >> 20 & 0xfu) == ERX_XHCI_SPEED_HIGH && (route >> 24 & 1u) == 0 &&
	    (route >> 25 & 1u) == 1 && (route >> 26 & 1u) == 1 && route >> 27 == 3,
	    "the addressed route and high speed, a multi-TT hub whose last valid index is EP1 IN's (Table 6-4; 6.2.2.2)");
	EXPECT(ports == (4u << 24 | 1u << 16) && tt == 2u << 16,
	    "the addressed root port, four ports, think time 2 (Tables 6-5 and 6-6)");
	EXPECT(zero_from(&image, 2, 0), "EP0's context is not written");
	expect_endpoint(&image, 3, ERX_XHCI_ENDPOINT_TYPE_BULK_IN, 64, 64, 64, IN_BLOCK);
	expect_endpoint(&image, 2, ERX_XHCI_ENDPOINT_TYPE_BULK_OUT, 64, 64, 64, OUT_BLOCK);
	complete_command(&state, 2);
	EXPECT(publish_contexts(&state, &drop, &image), "a Configure Endpoint dropping EP1 OUT");
	EXPECT(le32(&image, 0, 0) == 1u << 2 && le32(&image, 0, 4) == 1u << 0 && le32(&image, 1, 0) >> 27 == 3,
	    "a drop's flag, A0, and EP1 IN still the last valid index");
	complete_command(&state, 3);
	EXPECT(publish_contexts(&state, &evaluate, &image), "an Evaluate Context");
	EXPECT(le32(&image, 0, 0) == 0 && le32(&image, 0, 4) == 1u << 1 && zero_from(&image, 1, 0),
	    "Evaluate Context adds EP0 alone, no slot context");
	expect_endpoint(&image, 1, ERX_XHCI_ENDPOINT_TYPE_CONTROL, 512, 8, 0, CONTROL_BLOCK);
}

/*
 * A full-speed hub behind a high-speed hub's TT: Configure Endpoint's slot context keeps the
 * addressed route, speed, root port, TT hub and that hub's multi-TT flag; think time and multi-TT
 * are a high-speed hub's own (6.2.2.2, p. 448), so the stated ones do not reach a full-speed slot.
 */
static void
check_configure_full_speed_hub(void)
{
	static state_t state;
	static image_t image;
	erx_trb_command_t address = binding(SLOT, 1, CONTROL_BLOCK);
	erx_trb_command_t configure = binding(SLOT, 3, IN_BLOCK);
	uint32_t route, ports, tt;

	make_unbound(&state, 64);
	address.slot_context = (erx_xhci_slot_context_free_t){ .route_route_string = 0x2, .route_speed = ERX_XHCI_SPEED_FULL,
	    .route_multi_tt = 1, .ports_root_port = 1, .tt_tt_slot = 2, .tt_tt_port = 4 };
	EXPECT(publish_contexts(&state, &address, &image), "a full-speed Address Device behind a TT");
	complete_command(&state, 1);
	configure.slot_context = (erx_xhci_slot_context_free_t){ .route_hub = 1, .ports_port_count = 3,
	    .tt_tt_think_time = 2 };
	EXPECT(publish_contexts(&state, &configure, &image), "a full-speed hub's Configure Endpoint");
	route = le32(&image, 1, 0);
	ports = le32(&image, 1, 4);
	tt = le32(&image, 1, 8);
	EXPECT((route & 0xfffffu) == 0x2 && (route >> 20 & 0xfu) == ERX_XHCI_SPEED_FULL && (route >> 25 & 1u) == 1 &&
	    (route >> 26 & 1u) == 1 && route >> 27 == 3, "the addressed route, full speed and parent multi-TT, a hub");
	EXPECT(ports == (3u << 24 | 1u << 16) && tt == (4u << 8 | 2u), "root port 1, three ports, the TT hub, no think time");
}

/* Evaluate Context while EP0 has a transfer posted is refused: its reach holds EP0, which must be idle. */
static void
check_evaluate_while_posted(void)
{
	static state_t state;
	static image_t image;
	const erx_trb_command_t address = binding(SLOT, 1, CONTROL_BLOCK);
	const erx_trb_command_t evaluate = { .kind = ERX_TRB_COMMAND_EVALUATE_CONTEXT, .slot = SLOT, .ep0_packet = 512 };
	const erx_device_trb_request_t request = { .control = true, .setup = { 0x00, 0x09, 1, 0, 0, 0, 0, 0 } };
	erx_dma_sequence_t sequence;
	uint32_t live;

	make_unbound(&state, 32);
	EXPECT(publish_contexts(&state, &address, &image), "an Address Device");
	complete_command(&state, 1);
	EXPECT(erx_trb_form_post(&state.form, SLOT, 1, &request, 9, &sequence) == ERX_DEVICE_TRB_ACCEPTED,
	    "a SET_CONFIGURATION on EP0");
	live = erx_dma_ledger_live(&state.form.ledger);
	EXPECT(erx_trb_form_command(&state.form, &evaluate, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_dma_ledger_live(&state.form.ledger) == live, "an Evaluate Context while EP0 has a transfer posted");
}

/*
 * Evaluate Context acts on EP0, which must be idle when it is posted (6.2.3.3, p. 454), and closes
 * it while it runs, so a transfer on EP0 is refused until its completion (design-usb.md's refusal
 * table). Configure Endpoint needs its slot addressed (6.2.2.2's Addressed or Configured
 * precondition), so it is refused on a slot never addressed, after Disable Slot, after a reset and
 * after a failed Address Device.
 */
static void
check_command_preconditions(void)
{
	static state_t state;
	static image_t image;
	const erx_trb_command_t address = binding(SLOT, 1, CONTROL_BLOCK);
	const erx_trb_command_t configure = binding(SLOT, 3, IN_BLOCK);
	const erx_trb_command_t evaluate = { .kind = ERX_TRB_COMMAND_EVALUATE_CONTEXT, .slot = SLOT, .ep0_packet = 512 };
	const erx_trb_command_t disable = { .kind = ERX_TRB_COMMAND_DISABLE_SLOT, .slot = SLOT };
	const erx_device_trb_request_t request = { .control = true, .setup = { 0x00, 0x09, 1, 0, 0, 0, 0, 0 } };
	erx_dma_sequence_t sequence;
	uint32_t live, head;

	make_unbound(&state, 32);
	EXPECT(erx_trb_form_command(&state.form, &configure, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_dma_ledger_live(&state.form.ledger) == 0, "a Configure Endpoint on a slot never addressed");
	EXPECT(erx_trb_form_command(&state.form, &evaluate, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_dma_ledger_live(&state.form.ledger) == 0, "an Evaluate Context on a slot never addressed");
	EXPECT(erx_trb_form_command(&state.form, &(erx_trb_command_t){ .kind = ERX_TRB_COMMAND_DISABLE_SLOT,
	    .slot = state.form.slots + 1 }, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_dma_ledger_live(&state.form.ledger) == 0, "a Disable Slot of a slot outside the layout's");
	head = erx_dma_ledger_position(&state.form.ledger, COMMANDS).index;
	EXPECT(publish_contexts(&state, &address, &image), "an Address Device");
	complete_command(&state, head);
	head = erx_dma_ledger_position(&state.form.ledger, COMMANDS).index;
	EXPECT(erx_trb_form_command(&state.form, &disable, 1, &sequence) == ERX_DEVICE_TRB_ACCEPTED, "a Disable Slot");
	complete_command(&state, head);
	EXPECT(erx_trb_form_command(&state.form, &configure, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "a Configure Endpoint after Disable Slot");
	EXPECT(erx_trb_form_command(&state.form, &address, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_dma_ledger_live(&state.form.ledger) == 0, "an Address Device after Disable Slot, before an Enable Slot");
	enable_slot(&state, SLOT, ERX_XHCI_COMPLETION_SUCCESS);
	head = erx_dma_ledger_position(&state.form.ledger, COMMANDS).index;
	EXPECT(publish_contexts(&state, &address, &image), "the slot addressed again");
	complete_command(&state, head);
	head = erx_dma_ledger_position(&state.form.ledger, COMMANDS).index;
	EXPECT(publish_contexts(&state, &evaluate, &image), "an Evaluate Context on an idle EP0");
	live = erx_dma_ledger_live(&state.form.ledger);
	EXPECT(erx_trb_form_post(&state.form, SLOT, 1, &request, 9, &sequence) == ERX_DEVICE_TRB_REFUSE_HALTED &&
	    erx_dma_ledger_live(&state.form.ledger) == live, "a transfer on EP0 while Evaluate Context runs");
	complete_command(&state, head);
	EXPECT(erx_trb_form_post(&state.form, SLOT, 1, &request, 9, &sequence) == ERX_DEVICE_TRB_ACCEPTED,
	    "a transfer on EP0 after its completion");

	erx_trb_form_reset(&state.form);
	model_idle(&state.model);
	EXPECT(erx_trb_form_command(&state.form, &configure, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "a Configure Endpoint after a reset");
	EXPECT(erx_trb_form_command(&state.form, &address, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "an Address Device after a reset, before an Enable Slot");
	enable_slot(&state, SLOT, ERX_XHCI_COMPLETION_TRB_ERROR);
	enable_slot(&state, state.form.slots + 1u, ERX_XHCI_COMPLETION_SUCCESS);
	enable_slot(&state, 255, ERX_XHCI_COMPLETION_SUCCESS);
	EXPECT(erx_trb_form_command(&state.form, &address, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "an Address Device after a failed Enable Slot, or one naming a slot outside the layout's");
	enable_slot(&state, SLOT, ERX_XHCI_COMPLETION_SUCCESS);
	bind(&state, CONTROL_BLOCK, erx_trb_form_endpoint(SLOT, 1), ERX_XHCI_COMPLETION_TRANSACTION_ERROR);
	EXPECT(erx_trb_form_command(&state.form, &configure, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "a Configure Endpoint after a failed Address Device");
}

/* Each stated parameter out of its range is refused at the form's entry, changing nothing. */
static void
check_parameters_refused(void)
{
	static state_t state;
	erx_dma_sequence_t sequence;
	const erx_trb_command_t address = binding(SLOT, 1, CONTROL_BLOCK);
	erx_trb_command_t bad[16];
	uint32_t count = 0;

	make_unbound(&state, 32);
	for (uint32_t k = 0; k < 9; k++)
		bad[k] = address;
	bad[0].slot_context.route_route_string = 0x101;		/* a port after a tier of none */
	bad[1].slot_context.route_speed = 0;
	bad[2].slot_context.ports_root_port = 2;			/* past the controller's one port */
	bad[3].slot_context.tt_tt_slot = 1;			/* a TT hub's slot without its port */
	bad[4].slot_context.tt_tt_port = ERX_USB_HUB_PORTS_MAX + 1u;
	bad[4].slot_context.tt_tt_slot = 1;
	bad[5].adds[0].context.config_max_packet = 32;		/* not 8, 64 or 512 */
	bad[6].adds[0].block = OUT_BLOCK;			/* EP0 on a bulk block */
	bad[7].slot_context.route_hub = 1;
	bad[8] = (erx_trb_command_t){ .kind = ERX_TRB_COMMAND_EVALUATE_CONTEXT, .slot = SLOT, .ep0_packet = 513 };
	count = 9;
	for (uint32_t k = 0; k < count; k++)
		EXPECT(erx_trb_form_command(&state.form, &bad[k], 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
		    erx_dma_ledger_live(&state.form.ledger) == 0, "an Address Device or Evaluate Context out of range");
	EXPECT(erx_trb_form_command(&state.form, &address, 1, &sequence) == ERX_DEVICE_TRB_ACCEPTED, "the Address Device in range");
	complete_command(&state, 1);
	count = 0;
	bad[count] = binding(SLOT, 3, IN_BLOCK);
	bad[count].adds[0].context.config_max_packet = 2;	/* a burst past 15 alone out of range */
	bad[count].adds[0].context.config_max_burst = 16;
	bad[count++].adds[0].context.payload_max_esit_payload = 34;
	bad[count] = binding(SLOT, 3, IN_BLOCK);
	bad[count++].adds[0].context.info_interval = 1;		/* a bulk endpoint's interval is 0 */
	bad[count] = binding(SLOT, 3, IN_BLOCK);
	bad[count++].adds[0].context.config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_BULK_OUT;	/* against its index */
	bad[count] = binding(SLOT, 3, IN_BLOCK);
	bad[count++].adds[0].context.payload_max_esit_payload = 32;	/* not the packet times the burst plus one */
	bad[count] = binding(SLOT, 3, IN_BLOCK);
	bad[count++].adds[0].dci = 1;				/* EP0 on Configure Endpoint */
	bad[count] = binding(SLOT, 3, IN_BLOCK);
	bad[count++].adds[0].block = BLOCKS;			/* a block the form does not have */
	bad[count] = binding(SLOT, 3, IN_BLOCK);
	bad[count++].slot_context.route_speed = ERX_XHCI_SPEED_HIGH;	/* a device field on Configure */
	bad[count] = binding(SLOT, 3, IN_BLOCK);
	bad[count++].slot_context = (erx_xhci_slot_context_free_t){ .route_hub = 1, .ports_port_count = 16 };
	for (uint32_t k = 0; k < count; k++)
		EXPECT(erx_trb_form_command(&state.form, &bad[k], 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
		    erx_dma_ledger_live(&state.form.ledger) == 0, "a Configure Endpoint out of range");
}

static void
check_input_contexts(void)
{
	check_address_contexts(32);
	check_address_contexts(64);
	check_configure_contexts();
	check_configure_full_speed_hub();
	check_evaluate_while_posted();
	check_command_preconditions();
	check_parameters_refused();
}

/*
 * A controller as xHCI 1.2 has it for the start (4.2, pp. 80-82; 5.4.1-5.4.2, pp. 393-397):
 * clearing run halts it, HCRST resets it, the reset clears run and leaves it halted, and the
 * controller-not-ready bit may clear after HCRST; each change comes after some calls, which the
 * exploration chooses. `installed` is the install of this negotiation, which a reset forgets.
 */
typedef struct controller {
	bool	run;
	bool	halted;
	bool	resetting;
	bool	not_ready;
	bool	installed;
	bool	mastered;	/* the driver mastered its function since the last reset */
} controller_t;

enum { START_DEPTH = 8, START_CALLS_EAGER = 5 };
static uint64_t start_traces;

/* What the controller may have done between two calls: each pending change taken or not, by `choice`'s bits. */
static controller_t
controller_moves(controller_t c, uint32_t choice)
{
	if ((choice & 1u) != 0 && !c.run && !c.halted && !c.resetting)
		c.halted = true;
	if ((choice & 2u) != 0 && c.resetting)
		c = (controller_t){ .halted = true, .not_ready = c.not_ready };
	if ((choice & 4u) != 0 && !c.resetting && c.not_ready)
		c.not_ready = false;
	if ((choice & 8u) != 0 && c.run && c.halted && !c.resetting)
		c.halted = false;
	return (c);
}

/* The steps a negotiation takes, each of which a call may find it at. */
static const erx_trb_start_step_t start_steps[] = { ERX_TRB_START_BEGIN, ERX_TRB_START_RESETTING, ERX_TRB_START_RESET_ENDED,
    ERX_TRB_START_STARTING };

/*
 * One call of negotiate/2 on `c`, beginning a negotiation or continuing it, its effect checked
 * against what the specification allows.
 */
static erx_trb_start_next_t
start_call(controller_t *c, erx_trb_start_step_t step, bool continues)
{
	const erx_trb_start_seen_t seen = { .running = c->run, .halted = c->halted, .resetting = c->resetting,
	    .not_ready = c->not_ready };
	const erx_trb_start_next_t next = erx_trb_form_start_next(step, continues, seen);

	/* No write while HCRST or CNR reads set: a reset under way is waited out (5.4.1, p. 394; 4.2, p. 80). */
	EXPECT(next.effect == ERX_TRB_START_NOTHING || (!c->resetting && !c->not_ready),
	    "a register written while HCRST or CNR reads set");
	switch (next.effect) {
	case ERX_TRB_START_NOTHING:
		break;
	case ERX_TRB_START_CLEAR_RUN:
		c->run = false;
		break;
	case ERX_TRB_START_RESET:
		/* HCRST only once halted (5.4.1, p. 394). */
		EXPECT(c->halted && !c->run, "HCRST written to a controller not halted");
		*c = (controller_t){ .halted = c->halted, .resetting = true, .not_ready = true };
		break;
	case ERX_TRB_START_ROUTE:
		/* The function's table written after the reset (docs/design-pcie.md, "Who programs what, and when"). */
		EXPECT(!c->resetting && !c->not_ready && c->halted && !c->run, "the MSI-X table written before the reset ended");
		break;
	case ERX_TRB_START_INSTALL:
		/* No register but USBCMD before HCRST and CNR clear (5.4.1, p. 394; 4.2, p. 80), and halted. */
		EXPECT(c->mastered, "installed before the driver mastered its function, so the controller cannot reach memory");
		EXPECT(!c->resetting && !c->not_ready, "installed before the reset and CNR cleared");
		EXPECT(c->halted && !c->run, "installed on a controller not halted");
		c->installed = c->run = true;
		break;
	}
	if (next.answer == ERX_TRB_START_RESET_DONE) {
		EXPECT(next.effect == ERX_TRB_START_ROUTE, "`reset` answered without the MSI-X table");
		c->mastered = true;	/* the driver's pci:master before it continues */
	}
	if (next.answer == ERX_TRB_START_STARTED)
		EXPECT(c->installed && c->run && !c->halted, "started before the installed controller left halted");
	return (next);
}

/*
 * Every interleaving of the controller's changes with calls, up to START_DEPTH calls, the first
 * finding the negotiation at `step` and beginning or continuing it, the rest continuing.
 */
static void
explore_start(controller_t c, erx_trb_start_step_t step, bool continues, uint32_t depth)
{
	if (depth == START_DEPTH) {
		start_traces++;
		return;
	}
	controller_t seen[16];
	uint32_t seen_count = 0;

	for (uint32_t choice = 0; choice < 16u; choice++) {
		controller_t moved = controller_moves(c, choice);
		erx_trb_start_next_t next;
		bool again = false;

		/* Choices that change the same things are one interleaving. */
		for (uint32_t k = 0; k < seen_count; k++)
			again = again || memcmp(&seen[k], &moved, sizeof(moved)) == 0;
		if (again)
			continue;
		seen[seen_count++] = moved;
		next = start_call(&moved, step, continues);

		if (next.answer == ERX_TRB_START_STARTED) {
			start_traces++;
			continue;
		}
		explore_start(moved, next.step, true, depth + 1);
	}
}

/*
 * Each call's answer over every step, reading and kind of call: a begin answers as the first
 * step does whatever step the record keeps, and the first step clears run on every call while
 * the controller runs or its run bit reads set, so a controller that missed one write is stopped
 * by the next, and resets only a controller halted with run, HCRST and CNR clear.
 */
static void
test_start_answers(void)
{
	for (uint32_t at = 0; at < sizeof(start_steps) / sizeof(start_steps[0]); at++) {
		for (uint32_t bits = 0; bits < 16u; bits++) {
			const erx_trb_start_seen_t seen = { .halted = (bits & 1u) != 0, .resetting = (bits & 2u) != 0,
			    .not_ready = (bits & 4u) != 0, .running = (bits & 8u) != 0 };
			const erx_trb_start_next_t begun = erx_trb_form_start_next(start_steps[at], false, seen);
			const erx_trb_start_next_t first = erx_trb_form_start_next(ERX_TRB_START_BEGIN, true, seen);
			const erx_trb_start_next_t continued = erx_trb_form_start_next(start_steps[at], true, seen);
			const bool ready = !seen.resetting && !seen.not_ready;

			EXPECT(begun.effect == first.effect && begun.step == first.step && begun.answer == first.answer,
			    "a begin that answers by the step the record keeps");
			EXPECT((first.effect == ERX_TRB_START_NOTHING) == !ready, "the first step idle other than mid-reset");
			EXPECT(first.effect != ERX_TRB_START_RESET || (seen.halted && !seen.running),
			    "the first step resetting a controller not stopped");
			EXPECT(first.effect != ERX_TRB_START_CLEAR_RUN || seen.running || !seen.halted,
			    "the first step clearing run on a stopped controller");
			EXPECT(first.step == (first.effect == ERX_TRB_START_RESET ? ERX_TRB_START_RESETTING : ERX_TRB_START_BEGIN) &&
			    first.answer == ERX_TRB_START_BUSY, "the first step left other than by its reset");
			if (start_steps[at] != ERX_TRB_START_BEGIN)
				EXPECT(continued.effect != ERX_TRB_START_CLEAR_RUN && continued.effect != ERX_TRB_START_RESET,
				    "a later step writing the first step's registers");
			EXPECT(continued.answer != ERX_TRB_START_RESET_DONE || (start_steps[at] == ERX_TRB_START_RESETTING && ready),
			    "`reset` answered other than as the reset ends");
			EXPECT(continued.answer != ERX_TRB_START_STARTED || (start_steps[at] == ERX_TRB_START_STARTING && !seen.halted),
			    "started other than by the installed controller leaving halted");
		}
	}
}

/*
 * The start's core over a controller in every state a negotiation may find it in, begun at
 * every step a negotiation may have been left at, as a restarted controller process begins, every
 * interleaving explored; and a controller that answers each write before the next call is
 * started in START_CALLS_EAGER calls from any of them, the bound the controller core's deadline
 * counts on, one that misses the first write to run in one more. A controller with run and CNR
 * both set, which no controller is (CNR reads set only from a reset or power-on, which leave run
 * clear), takes a call more: nothing is written until CNR clears.
 */
static void
test_start(void)
{
	test_start_answers();
	for (uint32_t at = 0; at < sizeof(start_steps) / sizeof(start_steps[0]); at++) {
		for (uint32_t bits = 0; bits < 32u; bits++) {
			const controller_t initial = { .run = (bits & 1u) != 0, .halted = (bits & 2u) != 0,
			    .resetting = (bits & 4u) != 0, .not_ready = (bits & 8u) != 0, .installed = (bits & 16u) != 0 };

			explore_start(initial, start_steps[at], false, 0);
			for (uint32_t missed = 0; missed < 2u; missed++) {
				controller_t c = initial;
				erx_trb_start_step_t step = start_steps[at];
				uint32_t calls = 0;
				bool started = false;

				while (!started && calls < START_CALLS_EAGER + 2) {
					const bool kept_run = c.run;
					const erx_trb_start_next_t next = start_call(&c, step, calls > 0);

					if (missed == 1u && calls == 0 && next.effect == ERX_TRB_START_CLEAR_RUN)
						c.run = kept_run;	/* the controller missed the write */
					calls++;
					started = next.answer == ERX_TRB_START_STARTED;
					step = next.step;
					c = controller_moves(c, 15u);
					c = controller_moves(c, 15u);
				}
				EXPECT(started && calls <= START_CALLS_EAGER + missed + (initial.run && initial.not_ready),
				    "an answering controller not started in time");
				EXPECT(step == ERX_TRB_START_BEGIN, "a started negotiation not begun again by the next call");
			}
		}
	}
}

int
main(void)
{
	static state_t start;

	test_layout();
	test_install();
	test_start();
	test_endpoints_and_requests();
	test_refusals();
	test_commands();
	check_input_contexts();
	make_small(&start);
	explore(&start, 0);
	explore_commands(&start, 0);
	printf("erx_device_trb_form done (%llu states, %llu start traces)\n", (unsigned long long)states,
	    (unsigned long long)start_traces);
	return (0);
}
