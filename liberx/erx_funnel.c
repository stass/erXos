/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The funnel's grammar: a frame's header, its control term and its
 * payload's structural pass.  include/erx/funnel.h states the contracts.
 *
 * The control term is judged in two passes over its bytes.  erx_etf_check
 * first accepts it as a term of the system grammar, with the semantic stage
 * and a depth of ERX_FUNNEL_CTL_DEPTH, so the second pass reads a term
 * known to be well formed and shallow.  The second pass reads it item by
 * item with erx_etf_next and matches the operation's tuple element by
 * element: one table row gives each operation's arity and whether it has a
 * payload, and one reader per operation takes its elements in wire order.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <strings.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/etf.h"
#include "erx/funnel.h"
#include "erx/lane.h"

/* ERTS's small integers on a 64-bit build: 60 bits, signed. */
#define SMALL_MIN		(-((int64_t)1 << 59))
#define SMALL_MAX		(((int64_t)1 << 59) - 1)
/* SPAWN_REPLY's Flags, as ERTS bounds them. */
#define SPAWN_FLAGS_LIMIT	(1u << 27)

/* An operation's control tuple: its arity and whether a payload follows. */
typedef struct ctl_shape {
	uint8_t			 arity;
	bool			 payload;
} ctl_shape_t;

static const ctl_shape_t *ctl_shape(int64_t);
static erx_etf_rules_t payload_rules(const erx_funnel_limits_t *);
static erx_funnel_reason_t ctl_elements(erx_etf_reader_t *,
    erx_funnel_control_t *);
static erx_funnel_reason_t ctl_options(erx_etf_reader_t *);
static erx_funnel_reason_t ctl_option(erx_etf_reader_t *);
static bool next_item(erx_etf_reader_t *, erx_etf_item_t *);
static bool take_atom(erx_etf_reader_t *, const uint8_t **, size_t *);
static bool take_id(erx_etf_reader_t *, uint64_t *);
static bool take_integer(erx_etf_reader_t *, int64_t, int64_t, int64_t *);
static bool take_mfa(erx_etf_reader_t *, erx_funnel_control_t *);
static bool take_pid(erx_etf_reader_t *, erx_etf_pid_t *);
static bool take_ref(erx_etf_reader_t *, erx_etf_ref_t *);

erx_funnel_reason_t
erx_funnel_header(const uint8_t *header, uint32_t frame_len,
    erx_funnel_header_t *result)
{
	erx_frame_header_t h;
	uint64_t total;

	*result = (erx_funnel_header_t){ 0 };
	if (frame_len < ERX_FRAME_HEADER_SIZE || frame_len > ERX_FRAME_MAX ||
	    !erx_frame_header_decode(header, ERX_FRAME_HEADER_SIZE, &h))
		return (ERX_FUNNEL_ERR_HEADER);
	if (h.ctl_len < 2 || h.ctl_len > ERX_CTL_MAX)
		return (ERX_FUNNEL_ERR_CTL_LEN);
	/* Two 32-bit lengths and the header cannot overflow 64 bits. */
	total = (uint64_t)ERX_FRAME_HEADER_SIZE + h.ctl_len + h.payload_len;
	if (total != frame_len)
		return (ERX_FUNNEL_ERR_HEADER);
	*result = (erx_funnel_header_t){
		.ctl_len = h.ctl_len,
		.payload_len = h.payload_len,
	};
	return (ERX_FUNNEL_OK);
}

erx_funnel_reason_t
erx_funnel_control(const uint8_t *term, size_t len, uint32_t payload_len,
    const char *host, size_t host_len, void *scratch, size_t scratch_len,
    erx_funnel_control_t *control, erx_etf_result_t *etf)
{
	const erx_etf_rules_t rules = {
		.host = host,
		.host_len = host_len,
		.max_words = UINT64_MAX,
		.max_depth = ERX_FUNNEL_CTL_DEPTH,
		.grammar = ERX_ETF_SYSTEM,
		.accept = true,
	};
	const ctl_shape_t *shape;
	erx_funnel_control_t c = { 0 };
	erx_funnel_reason_t reason;
	erx_etf_reader_t r;
	erx_etf_item_t item;
	int64_t op;

	*control = (erx_funnel_control_t){ 0 };
	if (len > ERX_CTL_MAX) {
		*etf = (erx_etf_result_t){ .verdict = ERX_ETF_MALFORMED };
		return (ERX_FUNNEL_ERR_CTL_LEN);
	}
	if (erx_etf_check(term, len, &rules, scratch, scratch_len, etf) !=
	    ERX_ETF_ACCEPTED)
		return (ERX_FUNNEL_ERR_TERM);

	(void)erx_etf_reader_init(&r, term, len);
	if (!next_item(&r, &item) || item.kind != ERX_ETF_TUPLE ||
	    item.count == 0)
		return (ERX_FUNNEL_ERR_OP);
	if (!take_integer(&r, INT64_MIN, INT64_MAX, &op) ||
	    (shape = ctl_shape(op)) == NULL)
		return (ERX_FUNNEL_ERR_OP);
	if (item.count != shape->arity)
		return (ERX_FUNNEL_ERR_ARITY);
	c.op = (erx_funnel_op_t)op;
	c.payload = shape->payload;
	reason = ctl_elements(&r, &c);
	if (reason != ERX_FUNNEL_OK)
		return (reason);
	/* erx_etf accepted one term, and the tuple's elements were all read. */
	if (erx_etf_next(&r, &item, &(erx_etf_reason_t){ 0 }) !=
	    ERX_ETF_STEP_END)
		return (ERX_FUNNEL_ERR_FIELD);
	if (c.payload != (payload_len > 0))
		return (ERX_FUNNEL_ERR_PAYLOAD);
	*control = c;
	return (ERX_FUNNEL_OK);
}

erx_etf_verdict_t
erx_funnel_payload(const uint8_t *term, size_t len,
    const erx_funnel_limits_t *limits, void *scratch, size_t scratch_len,
    erx_etf_result_t *result)
{
	const erx_etf_rules_t rules = payload_rules(limits);

	return (erx_etf_check(term, len, &rules, scratch, scratch_len, result));
}

size_t
erx_funnel_payload_scratch_bytes(const erx_funnel_limits_t *limits, size_t len)
{
	const erx_etf_rules_t rules = payload_rules(limits);

	return (erx_etf_scratch_bytes(&rules, len));
}

erx_etf_verdict_t
erx_funnel_channel(const uint8_t *term, size_t len,
    const erx_funnel_limits_t *limits, void *scratch, size_t scratch_len,
    erx_etf_result_t *result)
{
	if (len > ERX_PROG_FRAME_MAX) {
		*result = (erx_etf_result_t){ .offset = 0,
		    .verdict = ERX_ETF_OVER_LIMIT,
		    .reason = ERX_ETF_ERR_TOO_LONG };
		return (result->verdict);
	}
	return (erx_funnel_payload(term, len, limits, scratch, scratch_len,
	    result));
}

/* erx_etf's scratch grows with the input, so the longest record's is enough. */
size_t
erx_funnel_channel_scratch_bytes(const erx_funnel_limits_t *limits)
{
	return (erx_funnel_payload_scratch_bytes(limits, ERX_PROG_FRAME_MAX));
}

/*
 * The payload's pass is erx_etf's structural pass: the semantic stage is
 * the receiving decoder's.
 */
static erx_etf_rules_t
payload_rules(const erx_funnel_limits_t *limits)
{
	return ((erx_etf_rules_t){
		.host = limits->host,
		.host_len = limits->host_len,
		.max_words = limits->max_words,
		.max_depth = limits->depth,
		.grammar = limits->system ? ERX_ETF_SYSTEM : ERX_ETF_DOMAIN,
		.accept = false,
	});
}

/* The operation numbered op, or NULL when the grammar has none. */
static const ctl_shape_t *
ctl_shape(int64_t op)
{
	static const ctl_shape_t shapes[] = {
		[ERX_FUNNEL_LINK] = { 3, false },
		[ERX_FUNNEL_GROUP_LEADER] = { 3, false },
		[ERX_FUNNEL_MONITOR_P] = { 4, false },
		[ERX_FUNNEL_DEMONITOR_P] = { 4, false },
		[ERX_FUNNEL_SEND_SENDER] = { 3, true },
		[ERX_FUNNEL_PAYLOAD_EXIT] = { 3, true },
		[ERX_FUNNEL_PAYLOAD_EXIT2] = { 3, true },
		[ERX_FUNNEL_PAYLOAD_MONITOR_P_EXIT] = { 4, true },
		[ERX_FUNNEL_SPAWN_REQUEST] = { 6, true },
		[ERX_FUNNEL_SPAWN_REPLY] = { 5, false },
		[ERX_FUNNEL_ALIAS_SEND] = { 3, true },
		[ERX_FUNNEL_UNLINK_ID] = { 4, false },
		[ERX_FUNNEL_UNLINK_ID_ACK] = { 4, false },
	};

	if (op < 0 || (uint64_t)op >= sizeof(shapes) / sizeof(shapes[0]) ||
	    shapes[op].arity == 0)
		return (NULL);
	return (&shapes[op]);
}

/* Reads the elements after the operation number, in wire order. */
static erx_funnel_reason_t
ctl_elements(erx_etf_reader_t *r, erx_funnel_control_t *c)
{
	erx_etf_item_t item;
	int64_t flags;

	switch (c->op) {
	case ERX_FUNNEL_LINK:
	case ERX_FUNNEL_GROUP_LEADER:
	case ERX_FUNNEL_SEND_SENDER:
	case ERX_FUNNEL_PAYLOAD_EXIT:
	case ERX_FUNNEL_PAYLOAD_EXIT2:
		c->fields = ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_TO;
		if (!take_pid(r, &c->from) || !take_pid(r, &c->to))
			return (ERX_FUNNEL_ERR_FIELD);
		return (ERX_FUNNEL_OK);
	case ERX_FUNNEL_MONITOR_P:
	case ERX_FUNNEL_DEMONITOR_P:
		c->fields = ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_TO |
		    ERX_FUNNEL_HAS_SENDER_REF;
		if (!take_pid(r, &c->from) || !take_pid(r, &c->to) ||
		    !take_ref(r, &c->sender_ref))
			return (ERX_FUNNEL_ERR_FIELD);
		return (ERX_FUNNEL_OK);
	case ERX_FUNNEL_PAYLOAD_MONITOR_P_EXIT:
		c->fields = ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_TO |
		    ERX_FUNNEL_HAS_RECEIVER_REF;
		if (!take_pid(r, &c->from) || !take_pid(r, &c->to) ||
		    !take_ref(r, &c->receiver_ref))
			return (ERX_FUNNEL_ERR_FIELD);
		return (ERX_FUNNEL_OK);
	case ERX_FUNNEL_ALIAS_SEND:
		c->fields = ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_RECEIVER_REF;
		if (!take_pid(r, &c->from) || !take_ref(r, &c->receiver_ref))
			return (ERX_FUNNEL_ERR_FIELD);
		return (ERX_FUNNEL_OK);
	case ERX_FUNNEL_UNLINK_ID:
	case ERX_FUNNEL_UNLINK_ID_ACK:
		c->fields = ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_TO |
		    ERX_FUNNEL_HAS_ID;
		if (!take_id(r, &c->id) || !take_pid(r, &c->from) ||
		    !take_pid(r, &c->to))
			return (ERX_FUNNEL_ERR_FIELD);
		return (ERX_FUNNEL_OK);
	case ERX_FUNNEL_SPAWN_REQUEST:
		c->fields = ERX_FUNNEL_HAS_SENDER_REF | ERX_FUNNEL_HAS_FROM |
		    ERX_FUNNEL_HAS_GROUP_LEADER | ERX_FUNNEL_HAS_SPAWN;
		if (!take_ref(r, &c->sender_ref) || !take_pid(r, &c->from) ||
		    !take_pid(r, &c->group_leader) || !take_mfa(r, c))
			return (ERX_FUNNEL_ERR_FIELD);
		return (ctl_options(r));
	case ERX_FUNNEL_SPAWN_REPLY:
		c->fields = ERX_FUNNEL_HAS_RECEIVER_REF | ERX_FUNNEL_HAS_TO |
		    ERX_FUNNEL_HAS_SPAWN;
		if (!take_ref(r, &c->receiver_ref) || !take_pid(r, &c->to) ||
		    !take_integer(r, 0, SPAWN_FLAGS_LIMIT - 1, &flags) ||
		    !next_item(r, &item))
			return (ERX_FUNNEL_ERR_FIELD);
		c->spawn.flags = (uint32_t)flags;
		if (item.kind == ERX_ETF_PID) {
			c->fields |= ERX_FUNNEL_HAS_FROM;
			c->from = item.u.pid;
		} else if (item.kind == ERX_ETF_ATOM) {
			c->spawn.error = item.u.data.bytes;
			c->spawn.error_len = item.u.data.len;
		} else
			return (ERX_FUNNEL_ERR_FIELD);
		return (ERX_FUNNEL_OK);
	}
	return (ERX_FUNNEL_ERR_OP);
}

/*
 * SPAWN_REQUEST's option list: a proper list of options, written as one
 * LIST_EXT or as several whose tails continue it, ending in NIL_EXT or an
 * empty STRING_EXT.  A STRING_EXT with bytes holds integers, never options.
 */
static erx_funnel_reason_t
ctl_options(erx_etf_reader_t *r)
{
	erx_etf_item_t item;
	erx_funnel_reason_t reason;
	uint32_t i;

	for (;;) {
		if (!next_item(r, &item))
			return (ERX_FUNNEL_ERR_OPTION);
		if (item.kind == ERX_ETF_NIL ||
		    (item.kind == ERX_ETF_STRING && item.u.data.len == 0))
			return (ERX_FUNNEL_OK);
		if (item.kind != ERX_ETF_LIST)
			return (ERX_FUNNEL_ERR_OPTION);
		for (i = 0; i < item.count; i++) {
			reason = ctl_option(r);
			if (reason != ERX_FUNNEL_OK)
				return (reason);
		}
	}
}

/*
 * One option: an atom, or {Atom, Value} with Value an atom, an integer or
 * a map from atoms to atoms and integers.
 */
static erx_funnel_reason_t
ctl_option(erx_etf_reader_t *r)
{
	erx_etf_item_t item;
	uint32_t i;

	if (!next_item(r, &item))
		return (ERX_FUNNEL_ERR_OPTION);
	if (item.kind == ERX_ETF_ATOM)
		return (ERX_FUNNEL_OK);
	if (item.kind != ERX_ETF_TUPLE || item.count != 2 ||
	    !next_item(r, &item) || item.kind != ERX_ETF_ATOM ||
	    !next_item(r, &item))
		return (ERX_FUNNEL_ERR_OPTION);
	switch (item.kind) {
	case ERX_ETF_ATOM:
	case ERX_ETF_INTEGER:
	case ERX_ETF_BIG:
		return (ERX_FUNNEL_OK);
	case ERX_ETF_MAP:
		for (i = 0; i < item.count; i++) {
			erx_etf_item_t key, value;

			if (!next_item(r, &key) || key.kind != ERX_ETF_ATOM ||
			    !next_item(r, &value) ||
			    (value.kind != ERX_ETF_ATOM &&
			    value.kind != ERX_ETF_INTEGER &&
			    value.kind != ERX_ETF_BIG))
				return (ERX_FUNNEL_ERR_OPTION);
		}
		return (ERX_FUNNEL_OK);
	default:
		return (ERX_FUNNEL_ERR_OPTION);
	}
}

/* The next item of a term erx_etf_check accepted; false at its end. */
static bool
next_item(erx_etf_reader_t *r, erx_etf_item_t *item)
{
	erx_etf_reason_t reason;

	return (erx_etf_next(r, item, &reason) == ERX_ETF_STEP_ITEM);
}

static bool
take_atom(erx_etf_reader_t *r, const uint8_t **bytes, size_t *len)
{
	erx_etf_item_t item;

	if (!next_item(r, &item) || item.kind != ERX_ETF_ATOM)
		return (false);
	*bytes = item.u.data.bytes;
	*len = item.u.data.len;
	return (true);
}

/*
 * An unlink identifier: an integer from 1 to 2^64 - 1, as ERTS's
 * term_to_Uint64 reads it.  An integer past INT64_MAX is a big, whose
 * little-endian magnitude may carry high zero bytes.
 */
static bool
take_id(erx_etf_reader_t *r, uint64_t *id)
{
	erx_etf_item_t item;
	uint64_t value;
	size_t i, len;

	if (!next_item(r, &item))
		return (false);
	if (item.kind == ERX_ETF_INTEGER) {
		if (item.u.integer < 1)
			return (false);
		*id = (uint64_t)item.u.integer;
		return (true);
	}
	if (item.kind != ERX_ETF_BIG || item.u.data.negative)
		return (false);
	len = item.u.data.len;
	while (len > 0 && item.u.data.bytes[len - 1] == 0)
		len--;
	if (len == 0 || len > sizeof(value))
		return (false);
	value = 0;
	for (i = len; i > 0; i--)
		value = value << 8 | item.u.data.bytes[i - 1];
	*id = value;
	return (true);
}

/* An integer from min to max; a big is past every bound used here. */
static bool
take_integer(erx_etf_reader_t *r, int64_t min, int64_t max, int64_t *value)
{
	erx_etf_item_t item;

	if (!next_item(r, &item) || item.kind != ERX_ETF_INTEGER ||
	    item.u.integer < min || item.u.integer > max)
		return (false);
	*value = item.u.integer;
	return (true);
}

/* SPAWN_REQUEST's {Module, Function, Arity}, as ERTS's dist.c checks it. */
static bool
take_mfa(erx_etf_reader_t *r, erx_funnel_control_t *c)
{
	erx_etf_item_t item;

	return (next_item(r, &item) && item.kind == ERX_ETF_TUPLE &&
	    item.count == 3 &&
	    take_atom(r, &c->spawn.module, &c->spawn.module_len) &&
	    take_atom(r, &c->spawn.function, &c->spawn.function_len) &&
	    take_integer(r, SMALL_MIN, SMALL_MAX, &c->spawn.arity));
}

static bool
take_pid(erx_etf_reader_t *r, erx_etf_pid_t *pid)
{
	erx_etf_item_t item;

	if (!next_item(r, &item) || item.kind != ERX_ETF_PID)
		return (false);
	*pid = item.u.pid;
	return (true);
}

static bool
take_ref(erx_etf_reader_t *r, erx_etf_ref_t *ref)
{
	erx_etf_item_t item;

	if (!next_item(r, &item) || item.kind != ERX_ETF_REF)
		return (false);
	*ref = item.u.ref;
	return (true);
}

/*
 * ERTS's internal range of its own pids on a 64-bit build (erl_term.h:
 * _PID_NUM_SIZE), which its decoder holds a pid of its own node and
 * creation to (external.c: dec_pid).  A pid's serial has 32 bits, the wire
 * field's whole range.  Its own references need no bound: edit 17 of
 * design-runtime.md makes all four words a reference's identity.
 */
#define OWN_PID_NUMBER_LIMIT	((uint32_t)1 << 28)

/*
 * The verdict table (design-domains.md, "Frames" and "The funnel", step
 * 7): for each operation, the right the peer must hold and on which of
 * the receiver's names, and the action for each cause short of
 * malformed.  UNREACHABLE marks a cause the operation cannot have: an
 * unauthorised operation that needs no right, a dead spawn request, whose
 * target is the receiving domain itself, and a payload over a limit for an
 * operation without one.  It fails closed, as does an operation with no
 * row, whose actions are all zero, ERX_FUNNEL_MALFORMED.
 */
#define UNREACHABLE	ERX_FUNNEL_MALFORMED

typedef struct verdict_row {
	uint8_t			 right;		/* ERX_RIGHT_*, 0 for none */
	erx_funnel_name_kind_t	 target;	/* where the right is held */
	erx_funnel_action_t	 action[ERX_FUNNEL_CAUSE_MALFORMED];
} verdict_row_t;

#define ROW(right, target, unauthorised, dead, over)			\
	{ (right), ERX_FUNNEL_NAME_##target, {				\
	    [ERX_FUNNEL_CAUSE_ACCEPTED] = ERX_FUNNEL_DELIVER,		\
	    [ERX_FUNNEL_CAUSE_UNAUTHORISED] = (unauthorised),		\
	    [ERX_FUNNEL_CAUSE_DEAD] = (dead),				\
	    [ERX_FUNNEL_CAUSE_OVER_LIMIT] = (over) } }

static const verdict_row_t verdict_rows[] = {
	/* ROW(right, target, unauthorised, dead, over a limit) */
	[ERX_FUNNEL_SEND_SENDER] = ROW(ERX_RIGHT_SEND, PID,
	    ERX_FUNNEL_DROP, ERX_FUNNEL_DROP, ERX_FUNNEL_DROP),
	[ERX_FUNNEL_ALIAS_SEND] = ROW(ERX_RIGHT_SEND, ALIAS,
	    ERX_FUNNEL_DROP, ERX_FUNNEL_DROP, ERX_FUNNEL_DROP),
	[ERX_FUNNEL_LINK] = ROW(ERX_RIGHT_LINK, PID,
	    ERX_FUNNEL_DELIVER_IF_LINKED, ERX_FUNNEL_ANSWER_NOPROC,
	    UNREACHABLE),
	[ERX_FUNNEL_UNLINK_ID] = ROW(0, PID,
	    UNREACHABLE, ERX_FUNNEL_DROP, UNREACHABLE),
	[ERX_FUNNEL_UNLINK_ID_ACK] = ROW(0, PID,
	    UNREACHABLE, ERX_FUNNEL_DROP, UNREACHABLE),
	[ERX_FUNNEL_MONITOR_P] = ROW(ERX_RIGHT_SEND, PID,
	    ERX_FUNNEL_ANSWER_NOPROC, ERX_FUNNEL_ANSWER_NOPROC, UNREACHABLE),
	[ERX_FUNNEL_DEMONITOR_P] = ROW(0, PID,
	    UNREACHABLE, ERX_FUNNEL_DROP, UNREACHABLE),
	[ERX_FUNNEL_PAYLOAD_MONITOR_P_EXIT] = ROW(0, PID,
	    UNREACHABLE, ERX_FUNNEL_DROP, ERX_FUNNEL_TOO_LARGE),
	[ERX_FUNNEL_PAYLOAD_EXIT] = ROW(0, PID,
	    UNREACHABLE, ERX_FUNNEL_DROP, ERX_FUNNEL_TOO_LARGE),
	[ERX_FUNNEL_PAYLOAD_EXIT2] = ROW(ERX_RIGHT_EXIT, PID,
	    ERX_FUNNEL_DROP, ERX_FUNNEL_DROP, ERX_FUNNEL_TOO_LARGE),
	[ERX_FUNNEL_GROUP_LEADER] = ROW(ERX_RIGHT_EXIT, PID,
	    ERX_FUNNEL_DROP, ERX_FUNNEL_DROP, UNREACHABLE),
	[ERX_FUNNEL_SPAWN_REQUEST] = ROW(ERX_RIGHT_SPAWN, DOMAIN,
	    ERX_FUNNEL_ANSWER_SPAWN, UNREACHABLE, ERX_FUNNEL_ANSWER_SPAWN),
	[ERX_FUNNEL_SPAWN_REPLY] = ROW(0, PID,
	    UNREACHABLE, ERX_FUNNEL_DROP, UNREACHABLE),
};
_Static_assert(sizeof(verdict_rows) / sizeof(verdict_rows[0]) ==
    ERX_FUNNEL_UNLINK_ID_ACK + 1, "a verdict row for every operation");

static erx_funnel_reason_t check_frame(const uint8_t *, uint32_t, size_t,
    const erx_funnel_lane_t *, const erx_funnel_limits_t *, void *, size_t,
    erx_funnel_verdict_t *);
static bool names_sender(const uint8_t *, size_t, uint32_t,
    const erx_funnel_lane_t *);
static erx_funnel_reason_t sender_rule(const erx_funnel_control_t *,
    const erx_funnel_lane_t *);
static erx_funnel_reason_t target_rule(const erx_funnel_control_t *,
    const erx_funnel_lane_t *, bool *);
static erx_funnel_reason_t target_name(const uint8_t *, size_t, uint32_t,
    bool, const erx_funnel_lane_t *, bool *);

void
erx_funnel_check(const uint8_t *frame, uint32_t frame_len, size_t held,
    const erx_funnel_lane_t *lane, const erx_funnel_limits_t *limits,
    void *scratch, size_t scratch_len, erx_funnel_verdict_t *verdict)
{
	erx_funnel_reason_t reason;

	*verdict = (erx_funnel_verdict_t){ 0 };
	reason = check_frame(frame, frame_len, held, lane, limits, scratch,
	    scratch_len, verdict);
	if (reason != ERX_FUNNEL_OK) {
		verdict->action = ERX_FUNNEL_MALFORMED;
		verdict->cause = ERX_FUNNEL_CAUSE_MALFORMED;
		verdict->reason = reason;
		return;
	}
	verdict->action =
	    verdict_rows[verdict->control.op].action[verdict->cause];
	if (verdict->action == ERX_FUNNEL_MALFORMED) {
		/* An UNREACHABLE cell: fail closed, and say so. */
		verdict->cause = ERX_FUNNEL_CAUSE_MALFORMED;
		verdict->reason = ERX_FUNNEL_ERR_VERDICT;
	}
}

size_t
erx_funnel_check_scratch_bytes(const erx_funnel_limits_t *limits, size_t held)
{
	size_t payload = erx_funnel_payload_scratch_bytes(limits, held);

	return (payload > ERX_FUNNEL_CTL_SCRATCH ? payload :
	    ERX_FUNNEL_CTL_SCRATCH);
}

/*
 * The steps of erx_funnel_check, numbered as design-domains.md's.  Sets the verdict's
 * header, control record, cause and payload result, and returns why the
 * frame is malformed, or ERX_FUNNEL_OK.
 */
static erx_funnel_reason_t
check_frame(const uint8_t *frame, uint32_t frame_len, size_t held,
    const erx_funnel_lane_t *lane, const erx_funnel_limits_t *limits,
    void *scratch, size_t scratch_len, erx_funnel_verdict_t *v)
{
	const verdict_row_t *row;
	erx_funnel_limits_t payload_limits;
	erx_funnel_name_t name;
	erx_funnel_hold_t hold = { 0 };
	erx_funnel_reason_t reason;
	const uint8_t *payload;
	uint32_t ctl_len, payload_len;
	bool dead;

	/* Steps 2 and 4: the header, the control term, the version byte. */
	if (held > frame_len)
		return (ERX_FUNNEL_ERR_HELD);
	if (held < ERX_FRAME_HEADER_SIZE)
		return (held == frame_len ? ERX_FUNNEL_ERR_HEADER :
		    ERX_FUNNEL_ERR_HELD);
	reason = erx_funnel_header(frame, frame_len, &v->header);
	if (reason != ERX_FUNNEL_OK)
		return (reason);
	ctl_len = v->header.ctl_len;
	payload_len = v->header.payload_len;
	/* The header passed, so these sums are at most frame_len. */
	if (held < frame_len &&
	    held < (size_t)ERX_FRAME_HEADER_SIZE + ctl_len + 1)
		return (ERX_FUNNEL_ERR_HELD);
	reason = erx_funnel_control(frame + ERX_FRAME_HEADER_SIZE, ctl_len,
	    payload_len, limits->host, limits->host_len, scratch, scratch_len,
	    &v->control, &v->etf);
	if (reason != ERX_FUNNEL_OK)
		return (reason);
	v->etf = (erx_etf_result_t){ 0 };
	payload = frame + ERX_FRAME_HEADER_SIZE + ctl_len;
	if (payload_len > 0 && payload[0] != ERX_ETF_VERSION)
		return (ERX_FUNNEL_ERR_VERSION);

	/* Step 4: the sender rule and the target rule. */
	reason = sender_rule(&v->control, lane);
	if (reason != ERX_FUNNEL_OK)
		return (reason);
	reason = target_rule(&v->control, lane, &dead);
	if (reason != ERX_FUNNEL_OK)
		return (reason);
	if (dead) {
		v->cause = ERX_FUNNEL_CAUSE_DEAD;
		return (ERX_FUNNEL_OK);
	}

	/* Step 5: authority, decided before any limit. */
	row = &verdict_rows[v->control.op];
	if (row->right != 0) {
		name = (erx_funnel_name_t){
			.kind = row->target,
			.pid = row->target == ERX_FUNNEL_NAME_PID ?
			    &v->control.to : NULL,
			.alias = row->target == ERX_FUNNEL_NAME_ALIAS ?
			    &v->control.receiver_ref : NULL,
		};
		hold = lane->lookup(lane->connection, &name);
		if ((hold.rights & row->right) == 0) {
			v->cause = ERX_FUNNEL_CAUSE_UNAUTHORISED;
			return (ERX_FUNNEL_OK);
		}
	}

	/* Steps 3 and 6: the payload of an authorised frame. */
	if (held < frame_len) {
		v->cause = ERX_FUNNEL_CAUSE_OVER_LIMIT;
		return (ERX_FUNNEL_OK);
	}
	v->cause = ERX_FUNNEL_CAUSE_ACCEPTED;
	if (payload_len == 0)
		return (ERX_FUNNEL_OK);
	payload_limits = *limits;
	/* A request limit is on messages, the payloads that need send. */
	if (row->right == ERX_RIGHT_SEND && hold.request_words != 0 &&
	    hold.request_words < payload_limits.max_words)
		payload_limits.max_words = hold.request_words;
	switch (erx_funnel_payload(payload, payload_len, &payload_limits,
	    scratch, scratch_len, &v->etf)) {
	case ERX_ETF_ACCEPTED:
		return (ERX_FUNNEL_OK);
	case ERX_ETF_OVER_LIMIT:
		v->cause = ERX_FUNNEL_CAUSE_OVER_LIMIT;
		return (ERX_FUNNEL_OK);
	case ERX_ETF_MALFORMED:
		break;
	}
	return (ERX_FUNNEL_ERR_PAYLOAD_TERM);
}

/* Whether a pid's or reference's node and creation are the lane's sender's. */
static bool
names_sender(const uint8_t *node, size_t node_len, uint32_t creation,
    const erx_funnel_lane_t *lane)
{
	return (node_len == lane->sender_node_len &&
	    bcmp(node, lane->sender_node, node_len) == 0 &&
	    creation == lane->sender_id);
}

/*
 * The sender rule: every pid and reference of the sender's own in the
 * control term (funnel.h's from and sender_ref) carries the lane's node
 * name and domain id.
 */
static erx_funnel_reason_t
sender_rule(const erx_funnel_control_t *c, const erx_funnel_lane_t *lane)
{
	if ((c->fields & ERX_FUNNEL_HAS_FROM) != 0 &&
	    !names_sender(c->from.node, c->from.node_len, c->from.creation,
	    lane))
		return (ERX_FUNNEL_ERR_SENDER);
	if ((c->fields & ERX_FUNNEL_HAS_SENDER_REF) != 0 &&
	    !names_sender(c->sender_ref.node, c->sender_ref.node_len,
	    c->sender_ref.creation, lane))
		return (ERX_FUNNEL_ERR_SENDER);
	return (ERX_FUNNEL_OK);
}

/*
 * The target rule over funnel.h's to and receiver_ref: each carries the
 * receiver's node name, and *dead is set when either names an ended
 * domain of that name; the receiver's own pid lies in ERTS's internal
 * range.  A malformed name outweighs a dead one.
 */
static erx_funnel_reason_t
target_rule(const erx_funnel_control_t *c, const erx_funnel_lane_t *lane,
    bool *dead)
{
	erx_funnel_reason_t reason;

	*dead = false;
	if ((c->fields & ERX_FUNNEL_HAS_TO) != 0) {
		reason = target_name(c->to.node, c->to.node_len, c->to.creation,
		    c->to.id < OWN_PID_NUMBER_LIMIT, lane, dead);
		if (reason != ERX_FUNNEL_OK)
			return (reason);
	}
	if ((c->fields & ERX_FUNNEL_HAS_RECEIVER_REF) != 0) {
		reason = target_name(c->receiver_ref.node,
		    c->receiver_ref.node_len, c->receiver_ref.creation, true,
		    lane, dead);
		if (reason != ERX_FUNNEL_OK)
			return (reason);
	}
	return (ERX_FUNNEL_OK);
}

/*
 * One target name: the receiver's node name, else malformed; of another
 * creation, dead; of the receiver's, within ERTS's internal range
 * (in_range), else malformed.
 */
static erx_funnel_reason_t
target_name(const uint8_t *node, size_t node_len, uint32_t creation,
    bool in_range, const erx_funnel_lane_t *lane, bool *dead)
{
	if (node_len != lane->receiver_node_len ||
	    bcmp(node, lane->receiver_node, node_len) != 0)
		return (ERX_FUNNEL_ERR_TARGET);
	if (creation != lane->receiver_id)
		*dead = true;
	else if (!in_range)
		return (ERX_FUNNEL_ERR_TARGET);
	return (ERX_FUNNEL_OK);
}

/* ------------------------------------------------------- frame assembly */

void
erx_funnel_asm_init(erx_funnel_asm_t *a, uint32_t max_frame)
{
	*a = (erx_funnel_asm_t){ .max_frame = max_frame };
}

void
erx_funnel_asm_next(erx_funnel_asm_t *a)
{
	erx_funnel_asm_init(a, a->max_frame);
}

static uint32_t
min_u32(uint64_t a, uint64_t b)
{
	return ((uint32_t)(a < b ? a : b));
}

/*
 * Before a record opens, a take may copy only what is kept of every
 * record; until its header is read, only the rest of the header.  So the
 * plan never asks for room that the header may later disown.
 */
void
erx_funnel_asm_plan(const erx_funnel_asm_t *a, size_t cap,
    erx_funnel_asm_plan_t *plan)
{
	const uint32_t limit = a->sized ? a->hold :
	    min_u32(a->hold, ERX_FRAME_HEADER_SIZE);

	if (a->frame == 0) {
		*plan = (erx_funnel_asm_plan_t){ .where = ERX_FUNNEL_ASM_COPY,
		    .room = min_u32(cap, ERX_FRAME_HEADER_SIZE) };
	} else if (a->held >= limit) {
		*plan = (erx_funnel_asm_plan_t){ .where = ERX_FUNNEL_ASM_SKIP };
	} else if (a->held >= cap) {
		/* Doubling, never past what the record keeps. */
		*plan = (erx_funnel_asm_plan_t){ .where = ERX_FUNNEL_ASM_GROW,
		    .want = min_u32(limit, (uint64_t)cap * 2) };
	} else {
		*plan = (erx_funnel_asm_plan_t){ .where = ERX_FUNNEL_ASM_COPY,
		    .at = a->held, .room = min_u32(cap, limit) - a->held };
	}
}

void
erx_funnel_asm_ungrown(erx_funnel_asm_t *a)
{
	a->discard = true;
	a->hold = a->held;
}

/* The header's verdict on how much of the record the buffer keeps. */
static void
asm_size(erx_funnel_asm_t *a, const uint8_t *buf)
{
	erx_funnel_header_t header;

	a->sized = true;
	if (a->discard)
		return;
	if (erx_funnel_header(buf, a->frame, &header) != ERX_FUNNEL_OK ||
	    header.payload_len > a->max_frame) {
		a->discard = true;
		a->hold = min_u32(a->frame, ERX_FUNNEL_ASM_KEEP);
	} else {
		a->hold = a->frame;
	}
}

erx_funnel_asm_status_t
erx_funnel_asm_took(erx_funnel_asm_t *a, const erx_funnel_asm_plan_t *plan,
    const erx_lane_part_t *part, const uint8_t *buf)
{
	if (part->opened) {
		if (a->frame != 0 || part->kind != ERX_REC_FRAME ||
		    part->zero != 0 || part->len < ERX_FRAME_HEADER_SIZE)
			return (ERX_FUNNEL_ASM_MALFORMED);
		a->frame = part->len;
		a->held = 0;
		a->hold = min_u32(part->len, ERX_FUNNEL_ASM_KEEP);
	} else if (a->frame == 0) {
		return (ERX_FUNNEL_ASM_MALFORMED);
	}
	if (plan->where == ERX_FUNNEL_ASM_COPY) {
		/* The reader copies at most room bytes of the record's body. */
		if (part->copied > plan->room ||
		    part->copied > (uint64_t)a->frame - a->held)
			return (ERX_FUNNEL_ASM_MALFORMED);
		a->held += (uint32_t)part->copied;
	}
	if (!a->sized && a->held >= ERX_FRAME_HEADER_SIZE)
		asm_size(a, buf);
	return (part->closed ? ERX_FUNNEL_ASM_WHOLE : ERX_FUNNEL_ASM_MORE);
}
