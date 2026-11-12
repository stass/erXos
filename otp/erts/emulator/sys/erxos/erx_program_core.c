/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The erx_program port's core: the spec check, the start's run and the end's decisions
 * (erx_program_core.h). Pure: it reads and writes only what it is given.
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>

#include "erx/etf.h"
#include "erx_program_core.h"

/* A step that made nothing of its own: a map and an install die with their space. */
#define NO_UNDO	ERX_PROGRAM_DONE

/*
 * The start's one order, and what undoes each step. A release is this table read
 * backwards, so a failed start and a program's end free the same things the same way.
 * What the session keeps and maps of the program's channel comes before the program's
 * budget, so every release deletes it only after that budget is destroyed, by this order
 * alone (docs/design-programs.md, "The channel").
 */
static const struct {
	erx_program_act_t	step;
	erx_program_act_t	undo;
} plan[] = {
	{ ERX_PROGRAM_CHANNEL_CREATE, ERX_PROGRAM_CHANNEL_DESTROY },
	{ ERX_PROGRAM_CHANNEL_MAP, ERX_PROGRAM_CHANNEL_UNMAP },
	{ ERX_PROGRAM_BELL_CREATE, ERX_PROGRAM_BELL_DESTROY },
	{ ERX_PROGRAM_DATA_CREATE, ERX_PROGRAM_DATA_DESTROY },
	{ ERX_PROGRAM_IRQ_CREATE, ERX_PROGRAM_IRQ_CLOSE },
	{ ERX_PROGRAM_SINK_REGISTER, ERX_PROGRAM_SINK_UNREGISTER },
	{ ERX_PROGRAM_IRQ_BIND, ERX_PROGRAM_IRQ_UNBIND },
	{ ERX_PROGRAM_BUDGET_CREATE, ERX_PROGRAM_BUDGET_DESTROY },
	{ ERX_PROGRAM_GROUP_CREATE, ERX_PROGRAM_GROUP_CLOSE },
	{ ERX_PROGRAM_GATE_REGISTER_ANCHOR, ERX_PROGRAM_GATE_UNREGISTER_ANCHOR },
	{ ERX_PROGRAM_GATE_REGISTER_IMAGE, ERX_PROGRAM_GATE_UNREGISTER_IMAGE },
	{ ERX_PROGRAM_ANCHOR_CREATE, ERX_PROGRAM_ANCHOR_DESTROY },
	{ ERX_PROGRAM_IMAGE_CREATE, ERX_PROGRAM_IMAGE_CLOSE },
	{ ERX_PROGRAM_IMAGE_MAP, NO_UNDO },
	{ ERX_PROGRAM_INSTALL, NO_UNDO },
	{ ERX_PROGRAM_BELL_BIND, ERX_PROGRAM_BELL_UNBIND },
	{ ERX_PROGRAM_THREAD_CREATE, ERX_PROGRAM_THREAD_CLOSE },
};
#define PLAN_STEPS	((uint32_t)(sizeof(plan) / sizeof(plan[0])))
_Static_assert(PLAN_STEPS + 3 <= ERX_PROGRAM_ACTIONS_MAX, "an end's report, stop, release and close fit its actions");

/* No control byte, and every component, the bytes between slashes, is neither empty, "." nor "..". */
static bool
image_path_valid(const uint8_t *path, size_t len)
{
	size_t start = 0;

	if (len == 0 || len > ERX_PACK_PATH_MAX)
		return (false);
	for (size_t at = 0; at <= len; at++) {
		size_t component;

		if (at < len && path[at] != '/') {
			if (path[at] < 0x20 || path[at] == 0x7f)
				return (false);
			continue;
		}
		component = at - start;
		if (component == 0 || (path[start] == '.' && (component == 1 ||
		    (component == 2 && path[start + 1] == '.'))))
			return (false);
		start = at + 1;
	}
	return (true);
}

int
erx_program_spec_check(const erx_program_spec_t *spec, uint64_t pool)
{
	if (!image_path_valid(spec->image, spec->image_len))
		return (ERX_EINVAL);
	if (spec->pid < ERX_PROGRAM_PID_MIN || spec->pid > ERX_PROGRAM_PID_MAX)
		return (ERX_ERANGE);
	if (spec->guarantee > spec->cap || spec->slots < 1 || spec->slots > ERX_PROG_DATA_SLOTS_MAX)
		return (ERX_EINVAL);
	if (spec->cap > pool)
		return (ERX_ELIMIT);
	return (ERX_OK);
}

void
erx_program_start_begin(erx_program_start_t *run, const erx_program_spec_t *spec, uint64_t pool)
{
	run->applied = 0;
	run->undoing = 0;
	run->error = erx_program_spec_check(spec, pool);
	/* A refused spec ends the run before any step. */
	run->over = run->error != ERX_OK;
}

erx_program_act_t
erx_program_start_next(erx_program_start_t *run, int result)
{
	if (run->over)
		return (ERX_PROGRAM_DONE);
	if (!run->undoing && result == ERX_OK && run->applied < PLAN_STEPS)
		return (plan[run->applied++].step);
	if (!run->undoing && result != ERX_OK) {
		/* The step last returned, if any, failed and made nothing: undo the ones before it. */
		run->error = result;
		run->undoing = 1;
		if (run->applied > 0)
			run->applied--;
	}
	while (run->undoing && run->applied > 0) {
		const erx_program_act_t undo = plan[--run->applied].undo;

		if (undo != NO_UNDO)
			return (undo);
	}
	run->over = 1;
	return (ERX_PROGRAM_DONE);
}

/*
 * Each copy's rights, from docs/design-programs.md's tables: the budget to allocate from;
 * the group to create threads in and bind IRQ objects to; the program's own side of the
 * channel to read, write and map, and the session's side, its peer side, to read and map
 * alone, so each side has one writer; the session's doorbell to trigger alone; the data
 * area to read, write and map.
 */
static const uint32_t install_rights[ERX_PROGRAM_INSTALLS] = {
	[ERX_PROGRAM_ARG_BUDGET] = ERX_HR_ALLOC,
	[ERX_PROGRAM_ARG_GROUP] = ERX_HR_ATTACH | ERX_HR_SIGNAL,
	[ERX_PROGRAM_ARG_OWN_SIDE] = ERX_HR_READ | ERX_HR_WRITE | ERX_HR_MAP,
	[ERX_PROGRAM_ARG_PEER_SIDE] = ERX_HR_READ | ERX_HR_MAP,
	[ERX_PROGRAM_ARG_DOORBELL] = ERX_HR_TRIGGER,
	[ERX_PROGRAM_INSTALL_DATA] = ERX_HR_READ | ERX_HR_WRITE | ERX_HR_MAP,
};

uint32_t
erx_program_install_rights(uint32_t index)
{
	return (index < ERX_PROGRAM_INSTALLS ? install_rights[index] : 0);
}

uint32_t
erx_program_session_prot(uint32_t index)
{
	if (index != ERX_PROGRAM_ARG_OWN_SIDE && index != ERX_PROGRAM_ARG_PEER_SIDE)
		return (0);
	return ((install_rights[index] & ERX_HR_WRITE) != 0 ? ERX_PROT_R : ERX_PROT_RW);
}

uint32_t
erx_program_install_batch(uint32_t first)
{
	if (first >= ERX_PROGRAM_INSTALLS)
		return (0);
	return (ERX_PROGRAM_INSTALLS - first < ERX_MSG_CAPS ? ERX_PROGRAM_INSTALLS - first : ERX_MSG_CAPS);
}

erx_program_end_t
erx_program_end_begin(void)
{
	return ((erx_program_end_t){ .phase = ERX_PROGRAM_RUNNING });
}

erx_program_input_t
erx_program_input_of(const erx_fault_t *record, erx_program_space_t space)
{
	if (record->kind != ERX_FAULT_EXIT)
		return ((erx_program_input_t){ .kind = ERX_PROGRAM_FAULT, .fault = (uint32_t)record->kind });
	return ((erx_program_input_t){ .kind = space == ERX_PROGRAM_SPACE_ANCHOR ? ERX_PROGRAM_ANCHOR_EXIT :
	    ERX_PROGRAM_IMAGE_EXIT, .status = record->status });
}

/*
 * The status a fault ends the program with: its kind's signal from the fault table, and
 * SIGKILL's for a kind the table does not hold, so a fault always ends the program.
 */
static int64_t
fault_status(uint32_t kind)
{
	const int signal = erx_fault_signal(kind);

	return (ERX_EXIT_SIGNAL + (signal != 0 ? signal : ERX_SIGKILL));
}

/*
 * What the anchor is stopped with after the image ended with status: the same status, as
 * the design says, unless it is one of the kernel's own, which erx_space_stop refuses.
 */
static int64_t
anchor_status(int64_t status)
{
	if (status == ERX_EXIT_PARENT || status == ERX_EXIT_RELEASED || status == ERX_EXIT_NOTHREAD)
		return (ERX_PROGRAM_KILLED);
	return (status);
}

/*
 * The status a decisive input ends the program with: a fault's, SIGSYS for a channel the
 * program broke or a frame of it the driver refused, and the owner's for a STOP.
 */
static int64_t
stop_status(erx_program_input_t input)
{
	switch (input.kind) {
	case ERX_PROGRAM_FAULT:
		return (fault_status(input.fault));
	case ERX_PROGRAM_STOP:
		return (input.status);
	default:
		return (ERX_EXIT_SIGNAL + ERX_SIGSYS);
	}
}

/*
 * Whether the owner may still act on the program: it read the start's answer, and the image
 * runs with its anchor, so a thread started or a frame written now reaches a live program.
 */
static bool
alive(const erx_program_end_t *end)
{
	return (end->answered && end->phase == ERX_PROGRAM_RUNNING && !end->anchor_ended);
}

static size_t
put(erx_program_action_t actions[], size_t at, erx_program_act_t act, int64_t status)
{
	actions[at] = (erx_program_action_t){ .act = act, .status = status };
	return (at + 1);
}

/*
 * Ends the program's hold on everything the start made, after the actions already in
 * actions[0..at): every undo, last step first, then, unless the port is closing already,
 * its close, or the close held when the start's answer is not read yet.
 */
static size_t
release(erx_program_end_t *end, erx_program_action_t actions[], size_t at, bool closing)
{
	for (uint32_t step = PLAN_STEPS; step > 0; step--) {
		if (plan[step - 1].undo != NO_UNDO)
			at = put(actions, at, plan[step - 1].undo, 0);
	}
	if (!closing && end->answered)
		at = put(actions, at, ERX_PROGRAM_CLOSE_PORT, 0);
	*end = (erx_program_end_t){ .phase = ERX_PROGRAM_RELEASED, .answered = end->answered,
	    .close_held = !closing && !end->answered };
	return (at);
}

size_t
erx_program_end_next(erx_program_end_t *end, erx_program_input_t input,
    erx_program_action_t actions[ERX_PROGRAM_ACTIONS_MAX])
{
	size_t at = 0;

	/* The answer is the port's, not the program's: it counts in every phase. */
	if (input.kind == ERX_PROGRAM_ANSWERED) {
		const bool held = end->close_held;

		end->answered = true;
		end->close_held = false;
		return (held ? put(actions, 0, ERX_PROGRAM_CLOSE_PORT, 0) : 0);
	}
	if (end->phase == ERX_PROGRAM_RELEASED) {
		/* A port that is closing owes no close. */
		if (input.kind == ERX_PROGRAM_CLOSE)
			end->close_held = false;
		return (0);
	}
	switch (input.kind) {
	case ERX_PROGRAM_IMAGE_EXIT:
		if (end->phase == ERX_PROGRAM_ENDED)
			return (0);
		if (end->phase == ERX_PROGRAM_FAULTED) {
			/*
			 * The fault stopped the anchor already. An image ended by that stop reports
			 * the fault's status; one that halted on its own first reports its own.
			 */
			at = put(actions, at, ERX_PROGRAM_REPORT,
			    input.status == ERX_EXIT_PARENT ? end->status : input.status);
		} else {
			at = put(actions, at, ERX_PROGRAM_REPORT, input.status);
			if (!end->anchor_ended)
				at = put(actions, at, ERX_PROGRAM_STOP_ANCHOR, anchor_status(input.status));
		}
		end->phase = ERX_PROGRAM_ENDED;
		end->status = 0;
		return (end->anchor_ended ? release(end, actions, at, false) : at);
	case ERX_PROGRAM_ANCHOR_EXIT:
		/* The image's record reports; an anchor that ended first waits for it. */
		end->anchor_ended = true;
		return (end->phase == ERX_PROGRAM_ENDED ? release(end, actions, 0, false) : 0);
	case ERX_PROGRAM_FAULT:
	case ERX_PROGRAM_BROKEN:
	case ERX_PROGRAM_REFUSED:
	case ERX_PROGRAM_STOP:
		/* An ending program takes no frame more: none is being written for it, nor room owed. */
		end->writing = end->room_owed = false;
		/* Only the first fault decides; the image's exit record reports it. */
		if (end->phase != ERX_PROGRAM_RUNNING)
			return (0);
		end->phase = ERX_PROGRAM_FAULTED;
		end->status = stop_status(input);
		return (end->anchor_ended ? 0 : put(actions, 0, ERX_PROGRAM_STOP_ANCHOR, end->status));
	case ERX_PROGRAM_CLOSE:
	case ERX_PROGRAM_LOST:
		/* No status is reported: the port is closing, or a record of the end may be lost. */
		if (end->phase == ERX_PROGRAM_RUNNING && !end->anchor_ended)
			at = put(actions, 0, ERX_PROGRAM_STOP_ANCHOR, ERX_PROGRAM_KILLED);
		return (release(end, actions, at, input.kind == ERX_PROGRAM_CLOSE));
	case ERX_PROGRAM_RUN:
		if (!alive(end) || end->ran)
			return (0);
		end->ran = true;
		return (put(actions, 0, ERX_PROGRAM_THREAD_START, 0));
	case ERX_PROGRAM_SEND:
		if (!alive(end))
			return (0);
		if (end->writing) {
			end->room_owed = true;
			return (put(actions, 0, ERX_PROGRAM_BUSY, 0));
		}
		end->writing = true;
		return (put(actions, 0, ERX_PROGRAM_WRITE, 0));
	case ERX_PROGRAM_WRITTEN:
		if (!end->writing)
			return (0);
		end->writing = false;
		if (!end->room_owed)
			return (0);
		end->room_owed = false;
		return (put(actions, 0, ERX_PROGRAM_ROOM, 0));
	case ERX_PROGRAM_ANSWERED:
		break;
	}
	return (0);
}

/*
 * The next term's first item. A LIST_EXT of no element is its tail, as ERTS decodes it, so the
 * loop takes the item after it in its place; each pass reads at least one byte.
 */
static bool
shape_term(erx_etf_reader_t *r, erx_etf_item_t *item)
{
	erx_etf_reason_t reason;

	do {
		if (erx_etf_next(r, item, &reason) != ERX_ETF_STEP_ITEM)
			return (false);
	} while (item->kind == ERX_ETF_LIST && item->count == 0);
	return (true);
}

/* The next term, which must be an integer from min to max. */
static bool
shape_integer(erx_etf_reader_t *r, int64_t min, int64_t max, int64_t *value)
{
	erx_etf_item_t item;

	if (!shape_term(r, &item) || item.kind != ERX_ETF_INTEGER || item.u.integer < min ||
	    item.u.integer > max)
		return (false);
	*value = item.u.integer;
	return (true);
}

/* The next term, which must be the atom name. */
static bool
shape_atom(erx_etf_reader_t *r, const char *name)
{
	const size_t len = strlen(name);
	erx_etf_item_t item;

	return (shape_term(r, &item) && item.kind == ERX_ETF_ATOM && item.u.data.len == len &&
	    bcmp(item.u.data.bytes, name, len) == 0);
}

/* The next term, which must be a notice key's number, from 1 to 2^32 - 1. */
static bool
shape_number(erx_etf_reader_t *r, uint32_t *value)
{
	int64_t v;

	if (!shape_integer(r, 1, UINT32_MAX, &v))
		return (false);
	*value = (uint32_t)v;
	return (true);
}

/* The notice key that is the next term: {closed, Pipe, End} or {drained, Pipe, End, Writer}. */
static bool
shape_notice(erx_etf_reader_t *r, erx_program_notice_t *notice)
{
	erx_etf_item_t item;

	if (!shape_term(r, &item) || item.kind != ERX_ETF_TUPLE)
		return (false);
	*notice = (erx_program_notice_t){ 0 };
	if (item.count == 3 && shape_atom(r, "closed"))
		notice->kind = ERX_PROGRAM_NOTICE_CLOSED;
	else if (item.count == 4 && shape_atom(r, "drained"))
		notice->kind = ERX_PROGRAM_NOTICE_DRAINED;
	else
		return (false);
	return (shape_number(r, &notice->pipe) && shape_number(r, &notice->end) &&
	    (notice->kind == ERX_PROGRAM_NOTICE_CLOSED || shape_number(r, &notice->writer)));
}

erx_program_frame_t
erx_program_frame_shape(const uint8_t *record, size_t len)
{
	const erx_program_frame_t other = { .kind = ERX_PROGRAM_FRAME_OTHER };
	erx_program_frame_t frame = other;
	erx_etf_reader_t r;
	erx_etf_item_t item;
	int64_t version, slot;

	/* The version is an integer, one item, so what follows is the term after it, not inside it. */
	if (!erx_etf_reader_init(&r, record, len) || !shape_term(&r, &item) ||
	    item.kind != ERX_ETF_TUPLE || (item.count != 3 && item.count != 4) ||
	    !shape_atom(&r, "erx_prog") || !shape_integer(&r, INT64_MIN, INT64_MAX, &version))
		return (other);
	if (item.count == 4) {
		if (!shape_integer(&r, 0, ERX_PROGRAM_SLOTS - 1, &slot))
			return (other);
		return ((erx_program_frame_t){ .kind = ERX_PROGRAM_FRAME_REQUEST, .slot = (uint8_t)slot });
	}
	if (!shape_notice(&r, &frame.notice))
		return (other);
	frame.kind = ERX_PROGRAM_FRAME_NOTICE;
	return (frame);
}

void
erx_program_credit_init(erx_program_credit_t *credit, erx_program_notice_t *due,
    uint32_t closed_max, uint32_t drained_max)
{
	*credit = (erx_program_credit_t){ .due = due, .closed_max = closed_max,
	    .drained_max = drained_max };
}

static bool
notice_equal(erx_program_notice_t a, erx_program_notice_t b)
{
	return (a.kind == b.kind && a.pipe == b.pipe && a.end == b.end && a.writer == b.writer);
}

/* Spends one grant of notice: false, credit unchanged, when none is due. */
static bool
due_spend(erx_program_credit_t *credit, erx_program_notice_t notice)
{
	const uint32_t count = credit->closed + credit->drained;

	for (uint32_t at = 0; at < count; at++) {
		if (!notice_equal(credit->due[at], notice))
			continue;
		/* The set has no order: the last key takes the spent one's place. */
		credit->due[at] = credit->due[count - 1];
		if (notice.kind == ERX_PROGRAM_NOTICE_CLOSED)
			credit->closed--;
		else
			credit->drained--;
		return (true);
	}
	return (false);
}

erx_program_credit_verdict_t
erx_program_credit_take(erx_program_credit_t *credit, erx_program_frame_t frame)
{
	uint16_t bit;

	switch (frame.kind) {
	case ERX_PROGRAM_FRAME_NOTICE:
		return (due_spend(credit, frame.notice) ? ERX_PROGRAM_DELIVER : ERX_PROGRAM_REFUSE);
	case ERX_PROGRAM_FRAME_REQUEST:
		if (frame.slot >= ERX_PROGRAM_SLOTS)
			return (ERX_PROGRAM_REFUSE);
		bit = (uint16_t)(1u << frame.slot);
		if ((credit->busy & bit) != 0)
			return (ERX_PROGRAM_REFUSE);
		credit->busy |= bit;
		return (ERX_PROGRAM_DELIVER);
	case ERX_PROGRAM_FRAME_OTHER:
		break;
	}
	return (ERX_PROGRAM_REFUSE);
}

/* A grant the driver can keep: a key of a known kind with every number it carries nonzero. */
static bool
grant_valid(erx_program_notice_t grant)
{
	if (grant.pipe == 0 || grant.end == 0)
		return (false);
	switch (grant.kind) {
	case ERX_PROGRAM_NOTICE_CLOSED:
		return (grant.writer == 0);
	case ERX_PROGRAM_NOTICE_DRAINED:
		return (grant.writer != 0);
	}
	return (false);
}

bool
erx_program_credit_admits(const erx_program_credit_t *credit, const erx_program_send_t *send)
{
	uint32_t closed = 0, drained = 0;

	if (send->reply != ERX_PROGRAM_NO_REPLY &&
	    (send->reply >= ERX_PROGRAM_SLOTS || (credit->busy & (1u << send->reply)) == 0))
		return (false);
	for (uint32_t at = 0; at < send->count; at++) {
		if (!grant_valid(send->grants[at]))
			return (false);
		if (send->grants[at].kind == ERX_PROGRAM_NOTICE_CLOSED)
			closed++;
		else
			drained++;
	}
	/* Each count is at most its bound, so neither subtraction wraps. */
	return (closed <= credit->closed_max - credit->closed &&
	    drained <= credit->drained_max - credit->drained);
}

void
erx_program_credit_sent(erx_program_credit_t *credit, const erx_program_send_t *send)
{
	if (send->reply != ERX_PROGRAM_NO_REPLY)
		credit->busy &= (uint16_t)~(1u << send->reply);
	for (uint32_t at = 0; at < send->count; at++) {
		credit->due[credit->closed + credit->drained] = send->grants[at];
		if (send->grants[at].kind == ERX_PROGRAM_NOTICE_CLOSED)
			credit->closed++;
		else
			credit->drained++;
	}
}
