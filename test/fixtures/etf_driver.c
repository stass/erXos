/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for liberx/erx_etf.c, run as etf_driver REQUESTS ANSWERS.
 * Each line of the file REQUESTS is one request:
 *
 *   GRAMMAR ACCEPT DEPTH WORDS HEX
 *
 * GRAMMAR is d, s or h (domain, system, host), ACCEPT 0 or 1, DEPTH and
 * WORDS the limits, HEX the term's bytes; the host name is "erxos".  Each
 * answer is one line of the file ANSWERS:
 *
 *   accepted WORDS COPY     the check accepted the term; COPY is the term
 *                           read back item by item with erx_etf_next and
 *                           written again with the writer, in hex
 *   malformed REASON OFFSET
 *   over REASON OFFSET
 *
 * so the caller can compare COPY with the input under binary_to_term.
 * The scratch is exactly erx_etf_scratch_bytes(rules), allocated for each
 * request, so ASan sees any write past it.  A line "scratch N ..." instead
 * checks with N bytes of scratch.
 */

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/etf.h"

#define LINE_MAX_BYTES	(40u * 1024 * 1024)

static const char *const reasons[] = {
	[ERX_ETF_OK] = "ok",
	[ERX_ETF_ERR_VERSION_BYTE] = "version",
	[ERX_ETF_ERR_TRUNCATED] = "truncated",
	[ERX_ETF_ERR_TRAILING] = "trailing",
	[ERX_ETF_ERR_TAG] = "tag",
	[ERX_ETF_ERR_ATOM] = "atom",
	[ERX_ETF_ERR_FLOAT] = "float",
	[ERX_ETF_ERR_BITS] = "bits",
	[ERX_ETF_ERR_BIG] = "big",
	[ERX_ETF_ERR_ARITY] = "arity",
	[ERX_ETF_ERR_NODE] = "node",
	[ERX_ETF_ERR_REF_LEN] = "ref_len",
	[ERX_ETF_ERR_FUN] = "fun",
	[ERX_ETF_ERR_RECORD] = "record",
	[ERX_ETF_ERR_MAP_KEY] = "map_key",
	[ERX_ETF_ERR_DEPTH] = "depth",
	[ERX_ETF_ERR_WORDS] = "words",
	[ERX_ETF_ERR_SCRATCH] = "scratch",
	[ERX_ETF_ERR_TOO_LONG] = "too_long",
};

static void
fail(const char *what)
{
	fprintf(stderr, "etf_driver: %s\n", what);
	exit(2);
}

static int
hex_digit(int c)
{
	if (c >= '0' && c <= '9')
		return (c - '0');
	if (c >= 'a' && c <= 'f')
		return (c - 'a' + 10);
	if (c >= 'A' && c <= 'F')
		return (c - 'A' + 10);
	return (-1);
}

static size_t
unhex(const char *hex, uint8_t *out)
{
	size_t n;
	int hi, lo;

	for (n = 0; hex[0] != '\0' && hex[0] != '\n'; hex += 2, n++) {
		hi = hex_digit(hex[0]);
		lo = hex[1] == '\0' ? -1 : hex_digit(hex[1]);
		if (hi < 0 || lo < 0)
			fail("bad hex");
		out[n] = (uint8_t)(hi << 4 | lo);
	}
	return (n);
}

/*
 * Reads the accepted term item by item and writes each item again.  The
 * reader yields items in wire order, so writing them in that order makes
 * an encoding of the same term, though not always the same bytes: integers
 * take their shortest form and bitstrings of whole bytes become binaries.
 */
static bool
copy_term(const uint8_t *term, size_t len, uint8_t *out, size_t cap,
    size_t *out_len)
{
	erx_etf_reader_t reader;
	erx_etf_writer_t writer;
	erx_etf_item_t item;
	erx_etf_reason_t reason;
	erx_etf_step_t step;

	if (!erx_etf_reader_init(&reader, term, len))
		return (false);
	erx_etf_writer_init(&writer, out, cap);
	while ((step = erx_etf_next(&reader, &item, &reason)) ==
	    ERX_ETF_STEP_ITEM) {
		switch (item.kind) {
		case ERX_ETF_INTEGER:
			erx_etf_put_integer(&writer, item.u.integer);
			break;
		case ERX_ETF_BIG:
			erx_etf_put_big(&writer, item.u.data.negative,
			    item.u.data.bytes, item.u.data.len);
			break;
		case ERX_ETF_FLOAT:
			erx_etf_put_float(&writer, item.u.real);
			break;
		case ERX_ETF_ATOM:
			erx_etf_put_atom(&writer,
			    (const char *)item.u.data.bytes, item.u.data.len);
			break;
		case ERX_ETF_BINARY:
			if (item.u.data.trailing_bits == 8)
				erx_etf_put_binary(&writer, item.u.data.bytes,
				    item.u.data.len);
			else
				erx_etf_put_bits(&writer, item.u.data.bytes,
				    item.u.data.len,
				    item.u.data.trailing_bits);
			break;
		case ERX_ETF_TUPLE:
			erx_etf_put_tuple(&writer, item.count);
			break;
		case ERX_ETF_NIL:
			erx_etf_put_nil(&writer);
			break;
		case ERX_ETF_LIST:
			erx_etf_put_list(&writer, item.count);
			break;
		case ERX_ETF_STRING:
			erx_etf_put_string(&writer, item.u.data.bytes,
			    item.u.data.len);
			break;
		case ERX_ETF_MAP:
			erx_etf_put_map(&writer, item.count);
			break;
		case ERX_ETF_RECORD:
			erx_etf_put_record(&writer, item.count,
			    item.u.exported);
			break;
		case ERX_ETF_PID:
			erx_etf_put_pid(&writer, &item.u.pid);
			break;
		case ERX_ETF_REF:
			erx_etf_put_ref(&writer, &item.u.ref);
			break;
		case ERX_ETF_FUN:
			erx_etf_put_fun(&writer, &item.u.fun, item.count);
			break;
		case ERX_ETF_EXPORT:
			erx_etf_put_export(&writer);
			break;
		}
	}
	return (step == ERX_ETF_STEP_END &&
	    erx_etf_writer_done(&writer, out_len));
}

/*
 * The writer's refusals: each call below has arguments no term can hold,
 * or no room, and must leave the writer failed.  Then the integers at the
 * ends of int64_t, which take a big encoding, must read back unchanged.
 */
static void
writer_cases(FILE *out, uint8_t *buf)
{
	static const uint8_t uniq[ERX_ETF_UNIQ_BYTES];
	const erx_etf_fun_t fun = { .uniq = uniq };
	const int64_t ends[] = { INT64_MIN, INT64_MAX };
	erx_etf_writer_t w;
	erx_etf_reader_t reader;
	erx_etf_item_t item;
	erx_etf_reason_t reason;
	size_t len;
	int cases;

#define REFUSED(cap, call)						\
	do {								\
		erx_etf_writer_init(&w, buf, (cap));			\
		call;							\
		erx_etf_put_nil(&w);					\
		if (erx_etf_writer_done(&w, &len))			\
			fail("writer accepted " #call);			\
		cases++;						\
	} while (0)

	cases = 0;
	memset(buf + 1024, 'a', 256);
	REFUSED(64, erx_etf_put_atom(&w, "\xc0\x80", 2));
	REFUSED(1024, erx_etf_put_atom(&w, (const char *)buf + 1024, 256));
	REFUSED(1, erx_etf_put_nil(&w));
	REFUSED(64, erx_etf_put_bits(&w, "x", 1, 0));
	REFUSED(64, erx_etf_put_bits(&w, "x", 1, 9));
	REFUSED(64, erx_etf_put_bits(&w, "x", 0, 8));
	REFUSED(64, erx_etf_put_float(&w, HUGE_VAL));
	REFUSED(64, erx_etf_put_float(&w, NAN));
	REFUSED(64, erx_etf_put_fun(&w, &fun, ERX_ETF_FUN_FREE_MAX + 1));
	REFUSED(64, erx_etf_put_record(&w, ERX_ETF_RECORD_FIELDS_MAX + 1,
	    false));
	REFUSED(64, erx_etf_put_tuple(&w, ERX_ETF_TUPLE_ARITY_MAX + 1));
	REFUSED(64, erx_etf_put_map(&w, UINT32_C(1) << 31));
	REFUSED(64, erx_etf_put_string(&w, buf, UINT16_MAX + 1));
	REFUSED(64, erx_etf_put_big(&w, false, buf,
	    ERX_ETF_BIG_BYTES_MAX + 1));
#undef REFUSED

	for (size_t i = 0; i < sizeof(ends) / sizeof(ends[0]); i++) {
		erx_etf_writer_init(&w, buf, 64);
		erx_etf_put_integer(&w, ends[i]);
		if (!erx_etf_writer_done(&w, &len) ||
		    !erx_etf_reader_init(&reader, buf, len) ||
		    erx_etf_next(&reader, &item, &reason) !=
		    ERX_ETF_STEP_ITEM || item.kind != ERX_ETF_INTEGER ||
		    item.u.integer != ends[i] ||
		    erx_etf_next(&reader, &item, &reason) != ERX_ETF_STEP_END)
			fail("an int64_t end does not read back");
	}
	fprintf(out, "writer %d\n", cases);
}

static void
answer(FILE *out, const char *line, uint8_t *term, uint8_t *copy)
{
	erx_etf_result_t result;
	erx_etf_rules_t rules;
	unsigned long long words;
	unsigned depth, accept;
	size_t len, copy_len, scratch_len;
	void *scratch;
	char grammar;
	int used;
	bool sized;

	if (strncmp(line, "writer", 6) == 0) {
		writer_cases(out, copy);
		return;
	}
	sized = strncmp(line, "scratch ", 8) == 0;
	scratch_len = 0;
	if (sized) {
		if (sscanf(line + 8, "%zu %n", &scratch_len, &used) != 1)
			fail("bad scratch request");
		line += 8 + used;
	}
	if (sscanf(line, "%c %u %u %llu %n", &grammar, &accept, &depth, &words,
	    &used) != 4)
		fail("bad request");
	rules = (erx_etf_rules_t){
		.host = "erxos",
		.host_len = 5,
		.max_words = words,
		.max_depth = depth,
		.grammar = grammar == 'd' ? ERX_ETF_DOMAIN :
		    grammar == 's' ? ERX_ETF_SYSTEM : ERX_ETF_HOST,
		.accept = accept != 0,
	};
	len = unhex(line + used, term);
	if (!sized)
		scratch_len = erx_etf_scratch_bytes(&rules);
	scratch = malloc(scratch_len == 0 ? 1 : scratch_len);
	if (scratch == NULL)
		fail("out of memory");
	erx_etf_check(term, len, &rules, scratch, scratch_len, &result);
	free(scratch);
	if (result.verdict != ERX_ETF_ACCEPTED) {
		fprintf(out, "%s %s %zu\n", result.verdict == ERX_ETF_MALFORMED ?
		    "malformed" : "over", reasons[result.reason], result.offset);
		return;
	}
	if (!copy_term(term, len, copy, LINE_MAX_BYTES, &copy_len))
		fail("an accepted term does not read back");
	fprintf(out, "accepted %llu ", (unsigned long long)result.words);
	for (size_t i = 0; i < copy_len; i++)
		fprintf(out, "%02x", copy[i]);
	fprintf(out, "\n");
}

int
main(int argc, char **argv)
{
	uint8_t *copy, *term;
	FILE *in, *out;
	char *line;

	if (argc != 3)
		fail("usage: etf_driver REQUESTS ANSWERS");
	in = fopen(argv[1], "r");
	out = fopen(argv[2], "w");
	if (in == NULL || out == NULL)
		fail("cannot open the request or answer file");
	line = malloc(LINE_MAX_BYTES);
	term = malloc(LINE_MAX_BYTES / 2);
	copy = malloc(LINE_MAX_BYTES);
	if (line == NULL || term == NULL || copy == NULL)
		fail("out of memory");
	while (fgets(line, LINE_MAX_BYTES, in) != NULL)
		answer(out, line, term, copy);
	if (fclose(out) != 0)
		fail("cannot write the answers");
	fclose(in);
	free(copy);
	free(term);
	free(line);
	return (0);
}
