/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A program's channel as the erx_program driver reads it: arbitrary records
 * through the funnel's channel mode (erx_funnel_channel), each record it
 * accepts through the shape reader (erx_program_frame_shape), and the shape
 * into the program's credit (erx_program_credit_take), with the handler's
 * replies between them. Input: a mode byte choosing the receiver's limits
 * (its word limit, depth, whether it is the system domain, and its host or
 * none, the last two of which channel mode ignores), then a sequence of
 * steps: a byte with the top bit set is a reply on the slot its low five
 * bits name; any other byte is followed by a 16-bit
 * little-endian length and that many record bytes (fewer at the end of the
 * input). Properties: no crash, an accepted record within ERX_PROG_FRAME_MAX
 * and the receiver's word limit and holding no fun, export, pid or reference
 * (the host grammar), a request's slot within the sixteen, and at
 * most one delivery per credit: never two requests delivered on a slot
 * without a reply taken between them, and a request on a free slot never
 * refused. The shape reader also reads every record, accepted or not.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "erx/funnel.h"
#include "erx_program_core.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static const uint32_t depths[] = { 0, 2, 16, 64 };
static const uint64_t words[] = { 0, 64, 4096, UINT64_MAX };
static const char host[] = "erxos";

/*
 * Whether an accepted record holds a fun, an export, a pid or a reference,
 * the kinds only the domain and system grammars admit.  The record is one
 * whole term, so the walk ends at its end.  The walk reads tags with the
 * tokenizer the check uses, so it catches a grammar rule that admits one
 * of these kinds, not a tokenizer that misnames a tag; the funnel's
 * stock-OTP oracle test covers that.
 */
static bool
holds_domain_only(const uint8_t *bytes, size_t len)
{
	erx_etf_reader_t r;
	erx_etf_item_t item;
	erx_etf_reason_t reason;

	if (!erx_etf_reader_init(&r, bytes, len))
		abort();
	for (;;) {
		switch (erx_etf_next(&r, &item, &reason)) {
		case ERX_ETF_STEP_END:
			return (false);
		case ERX_ETF_STEP_ERROR:
			abort();
		case ERX_ETF_STEP_ITEM:
			break;
		}
		if (item.kind == ERX_ETF_FUN || item.kind == ERX_ETF_EXPORT ||
		    item.kind == ERX_ETF_PID || item.kind == ERX_ETF_REF)
			return (true);
	}
}

/* One record: channel mode, then the shape and the credit for one it accepts. */
static void
record(const uint8_t *bytes, size_t len, const erx_funnel_limits_t *limits,
    void *scratch, size_t scratch_len, erx_program_credit_t *credit,
    unsigned outstanding[ERX_PROGRAM_SLOTS])
{
	erx_program_frame_t frame;
	erx_etf_result_t result;
	erx_etf_verdict_t verdict;

	(void)erx_program_frame_shape(bytes, len);
	verdict = erx_funnel_channel(bytes, len, limits, scratch, scratch_len,
	    &result);
	if (result.verdict != verdict ||
	    (verdict == ERX_ETF_ACCEPTED) != (result.reason == ERX_ETF_OK) ||
	    result.reason == ERX_ETF_ERR_SCRATCH)
		abort();
	if (verdict != ERX_ETF_ACCEPTED)
		return;	/* the driver ends the program with SIGSYS */
	if (len > ERX_PROG_FRAME_MAX || result.words > limits->max_words ||
	    holds_domain_only(bytes, len))
		abort();
	frame = erx_program_frame_shape(bytes, len);
	if (frame.kind == ERX_PROGRAM_FRAME_REQUEST &&
	    frame.slot >= ERX_PROGRAM_SLOTS)
		abort();
	if (erx_program_credit_take(credit, frame) != ERX_PROGRAM_DELIVER) {
		if (frame.kind == ERX_PROGRAM_FRAME_REQUEST &&
		    outstanding[frame.slot] == 0)
			abort();
		return;
	}
	if (frame.kind != ERX_PROGRAM_FRAME_REQUEST ||
	    ++outstanding[frame.slot] > 1)
		abort();
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	unsigned outstanding[ERX_PROGRAM_SLOTS] = { 0 };
	erx_program_credit_t credit = { 0 };
	erx_funnel_limits_t limits;
	size_t at, len, scratch_len;
	void *scratch;
	uint8_t op;

	if (size < 1)
		return (0);
	limits = (erx_funnel_limits_t){ .host = host,
	    .host_len = (data[0] & 0x20) != 0 ? 0 : sizeof(host) - 1,
	    .max_words = words[data[0] & 3],
	    .depth = depths[(data[0] >> 2) & 3],
	    .system = (data[0] & 0x10) != 0 };
	scratch_len = erx_funnel_channel_scratch_bytes(&limits);
	if ((scratch = malloc(scratch_len == 0 ? 1 : scratch_len)) == NULL)
		abort();
	for (at = 1; at < size;) {
		op = data[at++];
		if ((op & 0x80) != 0) {
			bool busy = (op & 0x1f) < ERX_PROGRAM_SLOTS &&
			    outstanding[op & 0x1f] != 0;

			if (erx_program_credit_reply(&credit, op & 0x1f) != busy)
				abort();
			if (busy)
				outstanding[op & 0x1f]--;
			continue;
		}
		len = 0;
		if (size - at >= 2) {
			len = (size_t)data[at] | (size_t)data[at + 1] << 8;
			at += 2;
		}
		if (len > size - at)
			len = size - at;
		record(data + at, len, &limits, scratch, scratch_len, &credit,
		    outstanding);
		at += len;
	}
	free(scratch);
	return (0);
}
