/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * liberx's funnel grammar over hostile frames.  The first input byte
 * chooses the mode and limits; the rest is a frame body (8-byte header,
 * control term, payload) of the input's length.  The harness runs the
 * funnel's three checks in order, as the funnel does, cutting the body
 * short at a point the second byte chooses as well as whole, and checks:
 * an accepted header's lengths add up to the frame; a control term is
 * accepted exactly with reason OK, and erx_etf's reason is OK exactly
 * when the refusal is not erx_etf's; an accepted control record names
 * only memory inside the input, sets the members its operation's row of
 * funnel.h lists and no others, and agrees with the payload length; a
 * refused one is all zero; every proper prefix of an accepted control
 * term is refused; and the payload's verdict and reason agree and an
 * accepted payload's words stay within the limit.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/funnel.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static const uint32_t depths[] = { 0, 2, 16, 1024 };
static const uint64_t words[] = { 0, 64, 4096, 65536 };
static const char host[] = "erxos";

static bool
inside(const uint8_t *p, size_t n, const uint8_t *base, size_t len)
{
	return (p == NULL ? n == 0 :
	    p >= base && n <= len && (size_t)(p - base) <= len - n);
}

/* The members each operation sets, from funnel.h's table. */
static uint32_t
expected_fields(const erx_funnel_control_t *c)
{
	switch (c->op) {
	case ERX_FUNNEL_LINK:
	case ERX_FUNNEL_GROUP_LEADER:
	case ERX_FUNNEL_SEND_SENDER:
	case ERX_FUNNEL_PAYLOAD_EXIT:
	case ERX_FUNNEL_PAYLOAD_EXIT2:
		return (ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_TO);
	case ERX_FUNNEL_MONITOR_P:
	case ERX_FUNNEL_DEMONITOR_P:
		return (ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_TO |
		    ERX_FUNNEL_HAS_SENDER_REF);
	case ERX_FUNNEL_PAYLOAD_MONITOR_P_EXIT:
		return (ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_TO |
		    ERX_FUNNEL_HAS_RECEIVER_REF);
	case ERX_FUNNEL_ALIAS_SEND:
		return (ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_RECEIVER_REF);
	case ERX_FUNNEL_UNLINK_ID:
	case ERX_FUNNEL_UNLINK_ID_ACK:
		return (ERX_FUNNEL_HAS_FROM | ERX_FUNNEL_HAS_TO |
		    ERX_FUNNEL_HAS_ID);
	case ERX_FUNNEL_SPAWN_REQUEST:
		return (ERX_FUNNEL_HAS_SENDER_REF | ERX_FUNNEL_HAS_FROM |
		    ERX_FUNNEL_HAS_GROUP_LEADER | ERX_FUNNEL_HAS_SPAWN);
	case ERX_FUNNEL_SPAWN_REPLY:
		return (ERX_FUNNEL_HAS_RECEIVER_REF | ERX_FUNNEL_HAS_TO |
		    ERX_FUNNEL_HAS_SPAWN | (c->fields & ERX_FUNNEL_HAS_FROM));
	}
	abort();
}

static void
check_control(const erx_funnel_control_t *c, const uint8_t *term,
    size_t len, uint32_t payload_len)
{
	const erx_funnel_control_t zero = { 0 };

	if (c->fields != expected_fields(c) ||
	    c->payload != (payload_len > 0) ||
	    !inside(c->from.node, c->from.node_len, term, len) ||
	    !inside(c->to.node, c->to.node_len, term, len) ||
	    !inside(c->group_leader.node, c->group_leader.node_len, term,
	    len) ||
	    !inside(c->sender_ref.node, c->sender_ref.node_len, term, len) ||
	    !inside(c->receiver_ref.node, c->receiver_ref.node_len, term,
	    len) ||
	    !inside(c->spawn.module, c->spawn.module_len, term, len) ||
	    !inside(c->spawn.function, c->spawn.function_len, term, len) ||
	    !inside(c->spawn.error, c->spawn.error_len, term, len))
		abort();
	if (!(c->fields & ERX_FUNNEL_HAS_FROM) &&
	    memcmp(&c->from, &zero.from, sizeof(zero.from)) != 0)
		abort();
	if (!(c->fields & ERX_FUNNEL_HAS_TO) &&
	    memcmp(&c->to, &zero.to, sizeof(zero.to)) != 0)
		abort();
	if (!(c->fields & ERX_FUNNEL_HAS_SENDER_REF) &&
	    memcmp(&c->sender_ref, &zero.sender_ref, sizeof(zero.sender_ref)) != 0)
		abort();
	if (!(c->fields & ERX_FUNNEL_HAS_RECEIVER_REF) &&
	    memcmp(&c->receiver_ref, &zero.receiver_ref,
	    sizeof(zero.receiver_ref)) != 0)
		abort();
	if (!(c->fields & ERX_FUNNEL_HAS_GROUP_LEADER) &&
	    memcmp(&c->group_leader, &zero.group_leader,
	    sizeof(zero.group_leader)) != 0)
		abort();
	if (!(c->fields & ERX_FUNNEL_HAS_SPAWN) &&
	    memcmp(&c->spawn, &zero.spawn, sizeof(zero.spawn)) != 0)
		abort();
	/* A spawn reply's Result is the child or the error, never both. */
	if (c->op == ERX_FUNNEL_SPAWN_REPLY &&
	    ((c->fields & ERX_FUNNEL_HAS_FROM) != 0) == (c->spawn.error != NULL))
		abort();
	if ((c->fields & ERX_FUNNEL_HAS_ID) ? c->id == 0 : c->id != 0)
		abort();
}

static erx_funnel_reason_t
control(const uint8_t *term, size_t len, uint32_t payload_len,
    erx_funnel_control_t *c)
{
	const erx_funnel_control_t zero = { 0 };
	erx_funnel_reason_t reason;
	erx_etf_result_t etf;
	void *scratch;

	if ((scratch = malloc(ERX_FUNNEL_CTL_SCRATCH)) == NULL)
		abort();
	reason = erx_funnel_control(term, len, payload_len, host,
	    sizeof(host) - 1, scratch, ERX_FUNNEL_CTL_SCRATCH, c, &etf);
	free(scratch);
	if ((reason == ERX_FUNNEL_ERR_TERM) != (etf.reason != ERX_ETF_OK))
		abort();
	/* With ERX_FUNNEL_CTL_SCRATCH, erx_etf never runs out of scratch. */
	if (etf.reason == ERX_ETF_ERR_SCRATCH)
		abort();
	if (reason == ERX_FUNNEL_OK)
		check_control(c, term, len, payload_len);
	else if (memcmp(c, &zero, sizeof(zero)) != 0)
		abort();
	return (reason);
}

static void
payload(const uint8_t *term, size_t len, uint8_t mode)
{
	erx_funnel_limits_t limits = {
		.host = host,
		.host_len = sizeof(host) - 1,
		.max_words = words[(mode >> 2) & 3],
		.depth = depths[(mode >> 4) & 3],
		.system = (mode & 0x40) != 0,
	};
	erx_etf_result_t result;
	erx_etf_verdict_t verdict;
	size_t scratch_len;
	void *scratch;

	scratch_len = erx_funnel_payload_scratch_bytes(&limits);
	if ((scratch = malloc(scratch_len == 0 ? 1 : scratch_len)) == NULL)
		abort();
	verdict = erx_funnel_payload(term, len, &limits, scratch, scratch_len,
	    &result);
	free(scratch);
	if ((verdict == ERX_ETF_ACCEPTED) != (result.reason == ERX_ETF_OK) ||
	    result.verdict != verdict || result.reason == ERX_ETF_ERR_SCRATCH ||
	    (verdict == ERX_ETF_ACCEPTED && result.words > limits.max_words))
		abort();
}

static void
frame(const uint8_t *body, size_t len, uint8_t mode)
{
	erx_funnel_control_t c;
	erx_funnel_header_t h;
	size_t cut;

	if (len > ERX_FRAME_MAX || erx_funnel_header(body, (uint32_t)len,
	    &h) != ERX_FUNNEL_OK)
		return;
	if ((uint64_t)ERX_FRAME_HEADER_SIZE + h.ctl_len + h.payload_len != len ||
	    h.ctl_len < 2 || h.ctl_len > ERX_CTL_MAX)
		abort();
	body += ERX_FRAME_HEADER_SIZE;
	if (control(body, h.ctl_len, h.payload_len, &c) != ERX_FUNNEL_OK)
		return;
	for (cut = 0; cut < h.ctl_len; cut++)
		if (control(body, cut, h.payload_len, &c) == ERX_FUNNEL_OK)
			abort();
	if (h.payload_len > 0)
		payload(body + h.ctl_len, h.payload_len, mode);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_funnel_control_t c;
	uint8_t mode, cut;

	if (size < 2)
		return (0);
	mode = data[0];
	cut = data[1];
	data += 2;
	size -= 2;
	switch (mode & 3) {
	case 0:
		frame(data, size, mode);
		/* The same frame with its record cut short. */
		if (size > 0)
			frame(data, cut % size, mode);
		break;
	case 1:
		(void)control(data, size, (mode & 4) ? 9 : 0, &c);
		break;
	default:
		payload(data, size, mode);
		break;
	}
	return (0);
}
