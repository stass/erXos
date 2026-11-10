/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for liberx/erx_funnel.c, run as funnel_driver REQUESTS
 * ANSWERS.  Each line of REQUESTS is one request, and each gets one line
 * of ANSWERS; the machine's host name is "erxos".
 *
 *   header FRAME_LEN HEX       the frame header's 8 bytes
 *     -> ok CTL_LEN PAYLOAD_LEN | REASON
 *   control PAYLOAD_LEN HEX    a control term
 *     -> ok TERM | REASON ETF_REASON
 *   payload SYSTEM DEPTH WORDS HEX
 *     -> accepted WORDS | malformed ETF_REASON | over ETF_REASON
 *   check RIGHTS REQUEST_WORDS HELD WORDS HEX
 *     -> ACTION CAUSE REASON ASKED WORDS
 *
 * TERM is the accepted control tuple rebuilt from erx_funnel_control_t as
 * Erlang source, so the oracle compares it with binary_to_term/1 of the
 * input: an atom as the binary of its UTF-8 bytes, a pid as
 * {pid, Node, Id, Serial, Creation}, a reference as
 * {ref, Node, Creation, [W1, W2, W3, W4]}, and the option list, which the
 * control record does not keep, as the atom options.  The scratch is
 * allocated for each request at the size the header promises, so ASan
 * sees a write past it.
 *
 * check is erx_funnel_check of one frame (HEX, its header included) on a
 * lane from web@erxos, domain 3, to system@erxos, domain 1, the system
 * domain, with funnel_depth 16 and max_message_heap WORDS.  Its export
 * table gives RIGHTS (ERX_RIGHT_* bits) and REQUEST_WORDS on every name.
 * HELD is the bytes the caller copied, or - for the whole frame.  ASKED
 * is the name the table was asked about (pid:ID, alias:FIRST_WORD,
 * domain), or - when it was not; WORDS is an accepted payload's.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/funnel.h"

#define LINE_MAX_BYTES	(40u * 1024 * 1024)

static const char *const funnel_reasons[] = {
	[ERX_FUNNEL_OK] = "ok",
	[ERX_FUNNEL_ERR_HEADER] = "header",
	[ERX_FUNNEL_ERR_CTL_LEN] = "ctl_len",
	[ERX_FUNNEL_ERR_TERM] = "term",
	[ERX_FUNNEL_ERR_OP] = "op",
	[ERX_FUNNEL_ERR_ARITY] = "arity",
	[ERX_FUNNEL_ERR_FIELD] = "field",
	[ERX_FUNNEL_ERR_OPTION] = "option",
	[ERX_FUNNEL_ERR_PAYLOAD] = "payload",
	[ERX_FUNNEL_ERR_SENDER] = "sender",
	[ERX_FUNNEL_ERR_TARGET] = "target",
	[ERX_FUNNEL_ERR_VERSION] = "version",
	[ERX_FUNNEL_ERR_PAYLOAD_TERM] = "payload_term",
	[ERX_FUNNEL_ERR_HELD] = "held",
	[ERX_FUNNEL_ERR_VERDICT] = "verdict",
};

static const char *const etf_reasons[] = {
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

static const char host[] = "erxos";

static size_t
unhex(const char *hex, uint8_t *out)
{
	size_t n = 0;
	unsigned byte;

	while (hex[0] != '\0' && hex[0] != '\n' &&
	    sscanf(hex, "%2x", &byte) == 1) {
		out[n++] = (uint8_t)byte;
		hex += 2;
	}
	return (n);
}

/* An atom as the Erlang binary of its UTF-8 bytes. */
static void
put_atom(FILE *out, const uint8_t *bytes, size_t len)
{
	size_t i;

	fputs("<<", out);
	for (i = 0; i < len; i++)
		fprintf(out, "%s%u", i > 0 ? "," : "", bytes[i]);
	fputs(">>", out);
}

static void
put_pid(FILE *out, const erx_etf_pid_t *pid)
{
	fputs("{pid,", out);
	put_atom(out, pid->node, pid->node_len);
	fprintf(out, ",%u,%u,%u}", pid->id, pid->serial, pid->creation);
}

static void
put_ref(FILE *out, const erx_etf_ref_t *ref)
{
	fputs("{ref,", out);
	put_atom(out, ref->node, ref->node_len);
	fprintf(out, ",%u,[%u,%u,%u,%u]}", ref->creation, ref->words[0],
	    ref->words[1], ref->words[2], ref->words[3]);
}

/* The control tuple, element by element in the order of funnel.h. */
static void
put_control(FILE *out, const erx_funnel_control_t *c)
{
	fprintf(out, "{%d", (int)c->op);
	switch (c->op) {
	case ERX_FUNNEL_UNLINK_ID:
	case ERX_FUNNEL_UNLINK_ID_ACK:
		fprintf(out, ",%llu,", (unsigned long long)c->id);
		put_pid(out, &c->from);
		fputc(',', out);
		put_pid(out, &c->to);
		break;
	case ERX_FUNNEL_SPAWN_REQUEST:
		fputc(',', out);
		put_ref(out, &c->sender_ref);
		fputc(',', out);
		put_pid(out, &c->from);
		fputc(',', out);
		put_pid(out, &c->group_leader);
		fputs(",{", out);
		put_atom(out, c->spawn.module, c->spawn.module_len);
		fputc(',', out);
		put_atom(out, c->spawn.function, c->spawn.function_len);
		fprintf(out, ",%lld},options", (long long)c->spawn.arity);
		break;
	case ERX_FUNNEL_SPAWN_REPLY:
		fputc(',', out);
		put_ref(out, &c->receiver_ref);
		fputc(',', out);
		put_pid(out, &c->to);
		fprintf(out, ",%u,", c->spawn.flags);
		if (c->fields & ERX_FUNNEL_HAS_FROM)
			put_pid(out, &c->from);
		else
			put_atom(out, c->spawn.error, c->spawn.error_len);
		break;
	default:
		fputc(',', out);
		put_pid(out, &c->from);
		if (c->fields & ERX_FUNNEL_HAS_TO) {
			fputc(',', out);
			put_pid(out, &c->to);
		}
		if (c->fields & ERX_FUNNEL_HAS_SENDER_REF) {
			fputc(',', out);
			put_ref(out, &c->sender_ref);
		}
		if (c->fields & ERX_FUNNEL_HAS_RECEIVER_REF) {
			fputc(',', out);
			put_ref(out, &c->receiver_ref);
		}
		break;
	}
	fputc('}', out);
}

static void
header_request(FILE *out, const char *args, uint8_t *bytes)
{
	erx_funnel_header_t h;
	erx_funnel_reason_t reason;
	unsigned long frame_len;
	char hex[64];

	if (sscanf(args, "%lu %63s", &frame_len, hex) != 2 ||
	    unhex(hex, bytes) != ERX_FRAME_HEADER_SIZE) {
		fputs("bad request\n", out);
		return;
	}
	reason = erx_funnel_header(bytes, (uint32_t)frame_len, &h);
	if (reason == ERX_FUNNEL_OK)
		fprintf(out, "ok %u %u\n", h.ctl_len, h.payload_len);
	else
		fprintf(out, "%s\n", funnel_reasons[reason]);
}

static void
control_request(FILE *out, const char *args, uint8_t *bytes)
{
	erx_funnel_control_t c;
	erx_funnel_reason_t reason;
	erx_etf_result_t etf;
	unsigned long payload_len;
	void *scratch;
	size_t len;
	int skip;

	if (sscanf(args, "%lu %n", &payload_len, &skip) != 1) {
		fputs("bad request\n", out);
		return;
	}
	len = unhex(args + skip, bytes);
	if ((scratch = malloc(ERX_FUNNEL_CTL_SCRATCH)) == NULL)
		abort();
	reason = erx_funnel_control(bytes, len, (uint32_t)payload_len, host,
	    sizeof(host) - 1, scratch, ERX_FUNNEL_CTL_SCRATCH, &c, &etf);
	free(scratch);
	if (reason == ERX_FUNNEL_OK) {
		fputs("ok ", out);
		put_control(out, &c);
		fputc('\n', out);
	} else
		fprintf(out, "%s %s\n", funnel_reasons[reason],
		    etf_reasons[etf.reason]);
}

static void
payload_request(FILE *out, const char *args, uint8_t *bytes)
{
	erx_funnel_limits_t limits = { .host = host,
	    .host_len = sizeof(host) - 1 };
	erx_etf_result_t result;
	erx_etf_verdict_t verdict;
	unsigned long long words;
	unsigned system, depth;
	void *scratch;
	size_t len, scratch_len;
	int skip;

	if (sscanf(args, "%u %u %llu %n", &system, &depth, &words,
	    &skip) != 3) {
		fputs("bad request\n", out);
		return;
	}
	limits.system = system != 0;
	limits.depth = depth;
	limits.max_words = words;
	len = unhex(args + skip, bytes);
	scratch_len = erx_funnel_payload_scratch_bytes(&limits);
	if ((scratch = malloc(scratch_len)) == NULL)
		abort();
	verdict = erx_funnel_payload(bytes, len, &limits, scratch,
	    scratch_len, &result);
	free(scratch);
	if (verdict == ERX_ETF_ACCEPTED)
		fprintf(out, "accepted %llu\n",
		    (unsigned long long)result.words);
	else
		fprintf(out, "%s %s\n",
		    verdict == ERX_ETF_MALFORMED ? "malformed" : "over",
		    etf_reasons[result.reason]);
}

static const char *const actions[] = {
	[ERX_FUNNEL_DELIVER] = "deliver",
	[ERX_FUNNEL_DELIVER_IF_LINKED] = "deliver_if_linked",
	[ERX_FUNNEL_DROP] = "drop",
	[ERX_FUNNEL_ANSWER_NOPROC] = "answer_noproc",
	[ERX_FUNNEL_ANSWER_SPAWN] = "answer_spawn",
	[ERX_FUNNEL_TOO_LARGE] = "too_large",
	[ERX_FUNNEL_MALFORMED] = "malformed",
};

static const char *const causes[] = {
	[ERX_FUNNEL_CAUSE_ACCEPTED] = "accepted",
	[ERX_FUNNEL_CAUSE_UNAUTHORISED] = "unauthorised",
	[ERX_FUNNEL_CAUSE_DEAD] = "dead",
	[ERX_FUNNEL_CAUSE_OVER_LIMIT] = "over_limit",
	[ERX_FUNNEL_CAUSE_MALFORMED] = "malformed",
};

/*
 * The check request's export table: the same hold on every name, and a
 * record of the questions asked, which the lookup writes through a pointer
 * so the table itself stays as the funnel sees it.
 */
typedef struct asked {
	char			 name[32];
	unsigned		 count;
} asked_t;

typedef struct exports {
	erx_funnel_hold_t	 hold;
	asked_t			*asked;
} exports_t;

static erx_funnel_hold_t
lookup(const void *table, const erx_funnel_name_t *name)
{
	const exports_t *exports = table;
	asked_t *asked = exports->asked;

	asked->count++;
	switch (name->kind) {
	case ERX_FUNNEL_NAME_PID:
		snprintf(asked->name, sizeof(asked->name), "pid:%u",
		    name->pid->id);
		break;
	case ERX_FUNNEL_NAME_ALIAS:
		snprintf(asked->name, sizeof(asked->name), "alias:%u",
		    name->alias->words[0]);
		break;
	case ERX_FUNNEL_NAME_DOMAIN:
		snprintf(asked->name, sizeof(asked->name), "domain");
		break;
	}
	return (exports->hold);
}

static void
check_request(FILE *out, const char *args, uint8_t *bytes)
{
	static const char sender[] = "web@erxos", receiver[] = "system@erxos";
	erx_funnel_limits_t limits = { .host = host,
	    .host_len = sizeof(host) - 1, .depth = 16, .system = true };
	asked_t asked = { .name = "-" };
	exports_t exports = { .asked = &asked };
	const erx_funnel_lane_t lane = {
		.sender_node = sender,
		.sender_node_len = sizeof(sender) - 1,
		.sender_id = 3,
		.receiver_node = receiver,
		.receiver_node_len = sizeof(receiver) - 1,
		.receiver_id = 1,
		.lookup = lookup,
		.connection = &exports,
	};
	erx_funnel_verdict_t v;
	unsigned long long request_words, words;
	unsigned rights;
	char held_text[24];
	size_t copied, len, held, scratch_len;
	uint8_t *frame;
	void *scratch;
	int skip;

	if (sscanf(args, "%u %llu %23s %llu %n", &rights, &request_words,
	    held_text, &words, &skip) != 4) {
		fputs("bad request\n", out);
		return;
	}
	exports.hold = (erx_funnel_hold_t){ .rights = (uint8_t)rights,
	    .request_words = request_words };
	limits.max_words = words;
	len = unhex(args + skip, bytes);
	held = strcmp(held_text, "-") == 0 ? len :
	    (size_t)strtoull(held_text, NULL, 10);
	/*
	 * The frame alone in an allocation of the bytes held, so ASan sees a
	 * read past them.
	 */
	copied = held < len ? held : len;
	scratch_len = erx_funnel_check_scratch_bytes(&limits);
	if ((frame = malloc(copied == 0 ? 1 : copied)) == NULL ||
	    (scratch = malloc(scratch_len)) == NULL)
		abort();
	memcpy(frame, bytes, copied);
	erx_funnel_check(frame, (uint32_t)len, held, &lane, &limits, scratch,
	    scratch_len, &v);
	free(scratch);
	free(frame);
	if (asked.count > 1)
		abort();
	fprintf(out, "%s %s %s %s %llu\n", actions[v.action], causes[v.cause],
	    funnel_reasons[v.reason], asked.name,
	    (unsigned long long)(v.cause == ERX_FUNNEL_CAUSE_ACCEPTED ?
	    v.etf.words : 0));
}

int
main(int argc, char **argv)
{
	FILE *in, *out;
	uint8_t *bytes;
	char *line;

	if (argc != 3 || (in = fopen(argv[1], "r")) == NULL ||
	    (out = fopen(argv[2], "w")) == NULL)
		return (2);
	if ((line = malloc(LINE_MAX_BYTES)) == NULL ||
	    (bytes = malloc(LINE_MAX_BYTES / 2)) == NULL)
		return (2);
	while (fgets(line, LINE_MAX_BYTES, in) != NULL) {
		if (strncmp(line, "header ", 7) == 0)
			header_request(out, line + 7, bytes);
		else if (strncmp(line, "control ", 8) == 0)
			control_request(out, line + 8, bytes);
		else if (strncmp(line, "payload ", 8) == 0)
			payload_request(out, line + 8, bytes);
		else if (strncmp(line, "check ", 6) == 0)
			check_request(out, line + 6, bytes);
		else
			fputs("bad request\n", out);
	}
	free(bytes);
	free(line);
	fclose(in);
	return (fclose(out) == 0 ? 0 : 1);
}
