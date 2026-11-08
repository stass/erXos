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
 *
 * TERM is the accepted control tuple rebuilt from erx_funnel_control_t as
 * Erlang source, so the oracle compares it with binary_to_term/1 of the
 * input: an atom as the binary of its UTF-8 bytes, a pid as
 * {pid, Node, Id, Serial, Creation}, a reference as
 * {ref, Node, Creation, [W1, W2, W3, W4]}, and the option list, which the
 * control record does not keep, as the atom options.  The scratch is
 * allocated for each request at the size the header promises, so ASan
 * sees a write past it.
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
		else
			fputs("bad request\n", out);
	}
	free(bytes);
	free(line);
	fclose(in);
	return (fclose(out) == 0 ? 0 : 1);
}
