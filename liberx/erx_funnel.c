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

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/etf.h"
#include "erx/funnel.h"

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
erx_funnel_payload_scratch_bytes(const erx_funnel_limits_t *limits)
{
	const erx_etf_rules_t rules = payload_rules(limits);

	return (erx_etf_scratch_bytes(&rules));
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
