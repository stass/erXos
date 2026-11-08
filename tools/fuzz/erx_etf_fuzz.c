/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * liberx's erx_etf over hostile terms.  The first input byte chooses the
 * rules: bits 0-1 the grammar (3 is the domain grammar again), bits 2-3 the
 * depth limit, bits 4-5 the word limit, bit 6 accept, bit 7 half the
 * scratch the rules need instead of all of it.  The rest is the term.
 *
 * For every input the harness checks that the verdict, the reason and the
 * offset agree; that with the scratch erx_etf_scratch_bytes promises the
 * check never runs out of it; that checking without accept refuses
 * nothing accept accepts, and that accept refuses only for map keys or
 * scratch beyond what the structural pass refuses; and that an accepted
 * term reads item by item to its end, writes again to a term the check
 * accepts with no more words, whose own copy is the same bytes.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/etf.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static const uint32_t depths[] = { 0, 2, 16, 1024 };
static const uint64_t words[] = { 0, 64, 4096, 65536 };

static erx_etf_verdict_t
check(const uint8_t *term, size_t len, const erx_etf_rules_t *rules,
    bool halve, erx_etf_result_t *result)
{
	erx_etf_verdict_t verdict;
	size_t scratch_len;
	void *scratch;

	scratch_len = erx_etf_scratch_bytes(rules);
	if (halve)
		scratch_len /= 2;
	scratch = malloc(scratch_len == 0 ? 1 : scratch_len);
	if (scratch == NULL)
		abort();
	verdict = erx_etf_check(term, len, rules, scratch, scratch_len,
	    result);
	free(scratch);
	if ((verdict == ERX_ETF_ACCEPTED) != (result->reason == ERX_ETF_OK) ||
	    result->verdict != verdict || result->offset > len ||
	    (verdict == ERX_ETF_ACCEPTED && result->words > rules->max_words))
		abort();
	if (!halve && result->reason == ERX_ETF_ERR_SCRATCH)
		abort();
	return (verdict);
}

/* The accepted term read item by item and written again, into out. */
static size_t
copy(const uint8_t *term, size_t len, uint8_t *out, size_t cap)
{
	erx_etf_reader_t reader;
	erx_etf_writer_t w;
	erx_etf_item_t it;
	erx_etf_reason_t reason;
	erx_etf_step_t step;
	size_t n;

	if (!erx_etf_reader_init(&reader, term, len))
		abort();
	erx_etf_writer_init(&w, out, cap);
	while ((step = erx_etf_next(&reader, &it, &reason)) ==
	    ERX_ETF_STEP_ITEM) {
		switch (it.kind) {
		case ERX_ETF_INTEGER:
			erx_etf_put_integer(&w, it.u.integer);
			break;
		case ERX_ETF_BIG:
			erx_etf_put_big(&w, it.u.data.negative,
			    it.u.data.bytes, it.u.data.len);
			break;
		case ERX_ETF_FLOAT:
			erx_etf_put_float(&w, it.u.real);
			break;
		case ERX_ETF_ATOM:
			erx_etf_put_atom(&w, (const char *)it.u.data.bytes,
			    it.u.data.len);
			break;
		case ERX_ETF_BINARY:
			if (it.u.data.trailing_bits == 8)
				erx_etf_put_binary(&w, it.u.data.bytes,
				    it.u.data.len);
			else
				erx_etf_put_bits(&w, it.u.data.bytes,
				    it.u.data.len, it.u.data.trailing_bits);
			break;
		case ERX_ETF_TUPLE:
			erx_etf_put_tuple(&w, it.count);
			break;
		case ERX_ETF_NIL:
			erx_etf_put_nil(&w);
			break;
		case ERX_ETF_LIST:
			erx_etf_put_list(&w, it.count);
			break;
		case ERX_ETF_STRING:
			erx_etf_put_string(&w, it.u.data.bytes, it.u.data.len);
			break;
		case ERX_ETF_MAP:
			erx_etf_put_map(&w, it.count);
			break;
		case ERX_ETF_RECORD:
			erx_etf_put_record(&w, it.count, it.u.exported);
			break;
		case ERX_ETF_PID:
			erx_etf_put_pid(&w, &it.u.pid);
			break;
		case ERX_ETF_REF:
			erx_etf_put_ref(&w, &it.u.ref);
			break;
		case ERX_ETF_FUN:
			erx_etf_put_fun(&w, &it.u.fun, it.count);
			break;
		case ERX_ETF_EXPORT:
			erx_etf_put_export(&w);
			break;
		}
	}
	if (step != ERX_ETF_STEP_END || !erx_etf_writer_done(&w, &n))
		abort();
	return (n);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_etf_result_t loose, result, again;
	erx_etf_rules_t rules;
	uint8_t *first, *second;
	size_t cap, first_len, second_len;
	bool halve;

	if (size < 1)
		return (0);
	rules = (erx_etf_rules_t){
		.host = "erxos",
		.host_len = 5,
		.grammar = (data[0] & 3) == 1 ? ERX_ETF_SYSTEM :
		    (data[0] & 3) == 2 ? ERX_ETF_HOST : ERX_ETF_DOMAIN,
		.max_depth = depths[data[0] >> 2 & 3],
		.max_words = words[data[0] >> 4 & 3],
		.accept = (data[0] & 0x40) != 0,
	};
	halve = (data[0] & 0x80) != 0;
	data++;
	size--;

	check(data, size, &rules, halve, &result);
	rules.accept = !rules.accept;
	check(data, size, &rules, halve, &loose);
	rules.accept = !rules.accept;
	if (rules.accept && result.verdict != loose.verdict) {
		/* Only accept's own checks may refuse beyond the structure. */
		if (result.verdict == ERX_ETF_ACCEPTED ||
		    (result.reason != ERX_ETF_ERR_MAP_KEY &&
		    result.reason != ERX_ETF_ERR_SCRATCH))
			abort();
	}
	if (result.verdict != ERX_ETF_ACCEPTED)
		return (0);

	/*
	 * Items are written in their shortest forms, so a copy grows only
	 * where a one-byte SMALL_BIG_EXT becomes a four-byte INTEGER_EXT.
	 */
	cap = 2 * size + 16;
	first = malloc(cap);
	second = malloc(cap);
	if (first == NULL || second == NULL)
		abort();
	first_len = copy(data, size, first, cap);
	if (check(first, first_len, &rules, false, &again) !=
	    ERX_ETF_ACCEPTED || again.words > result.words)
		abort();
	second_len = copy(first, first_len, second, cap);
	if (second_len != first_len || memcmp(first, second, first_len) != 0)
		abort();
	free(second);
	free(first);
	return (0);
}
