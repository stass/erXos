/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of the event executor's inbound decisions
 * (liberx/program/inbound.h, test/host/prog_inbound_test.rb).  Each line of
 * the requests file is one request, each answered by one line:
 *   open STARTED KIND ZERO LEN	-> open start | report | refuse
 *   report HEX			-> report refused, or
 *				   report WHICH PIPE END CAP... (the
 *				   capabilities erx_prog_report_caps names)
 * A report is read with all the scratch erx_prog_scratch_bytes promises.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "liberx/program/inbound.h"

#define LINE_MAX_BYTES	4096

static const char *const decisions[] = {
	[ERX_PROG_INBOUND_START] = "start",
	[ERX_PROG_INBOUND_REPORT] = "report",
	[ERX_PROG_INBOUND_REFUSE] = "refuse",
};

/* hex's bytes into out; SIZE_MAX on a malformed line. */
static size_t
unhex(const char *hex, uint8_t *out, size_t room)
{
	size_t n = 0;
	unsigned byte;

	while (hex[0] != '\n' && hex[0] != '\0') {
		if (n == room || sscanf(hex, "%2x", &byte) != 1)
			return (SIZE_MAX);
		out[n++] = (uint8_t)byte;
		hex += 2;
	}
	return (n);
}

/* The report's pipe and end, which every report but pipe_server_lost names. */
static void
names(const erx_prog_report_t *r, uint32_t *pipe, uint32_t *end)
{
	*pipe = *end = 0;
	switch (r->which) {
	case ERX_PROG_REPORT_PIPE_WRITER:
		*pipe = r->u.pipe_writer.pipe_id;
		*end = r->u.pipe_writer.end_id;
		break;
	case ERX_PROG_REPORT_PIPE_WRITER_GONE:
		*pipe = r->u.pipe_writer_gone.pipe_id;
		*end = r->u.pipe_writer_gone.end_id;
		break;
	case ERX_PROG_REPORT_PIPE_READER:
		*pipe = r->u.pipe_reader.pipe_id;
		*end = r->u.pipe_reader.end_id;
		break;
	case ERX_PROG_REPORT_PIPE_READER_GONE:
		*pipe = r->u.pipe_reader_gone.pipe_id;
		*end = r->u.pipe_reader_gone.end_id;
		break;
	case ERX_PROG_REPORT_PIPE_LOST:
		*pipe = r->u.pipe_lost.pipe_id;
		*end = r->u.pipe_lost.end_id;
		break;
	default:
		break;
	}
}

static void
report(const uint8_t *frame, size_t len)
{
	uint64_t caps[ERX_PROG_REPORT_CAPS];
	const size_t scratch_len = erx_prog_scratch_bytes(len);
	void *scratch = malloc(scratch_len == 0 ? 1 : scratch_len);
	erx_prog_report_t r;
	uint32_t pipe, end;
	size_t n;

	if (scratch == NULL || !erx_prog_report_read(frame, len, scratch, scratch_len, &r)) {
		printf("report refused\n");
		free(scratch);
		return;
	}
	names(&r, &pipe, &end);
	printf("report %u %" PRIu32 " %" PRIu32, r.which, pipe, end);
	n = erx_prog_report_caps(&r, caps);
	for (size_t at = 0; at < n; at++)
		printf(" %" PRIu64, caps[at]);
	printf("\n");
	free(scratch);
}

int
main(int argc, char **argv)
{
	static char line[LINE_MAX_BYTES];
	static uint8_t frame[LINE_MAX_BYTES / 2];
	unsigned started;
	uint32_t kind, len;
	uint64_t zero;
	FILE *requests;
	size_t n;

	if (argc != 2 || (requests = fopen(argv[1], "r")) == NULL)
		return (2);
	while (fgets(line, sizeof(line), requests) != NULL) {
		if (sscanf(line, "open %u %" SCNu32 " %" SCNu64 " %" SCNu32,
		    &started, &kind, &zero, &len) == 4) {
			printf("open %s\n", decisions[erx_prog_inbound_open(started != 0, kind, zero, len)]);
			continue;
		}
		if (strncmp(line, "report ", 7) != 0 ||
		    (n = unhex(line + 7, frame, sizeof(frame))) == SIZE_MAX)
			return (2);
		report(frame, n);
	}
	fclose(requests);
	return (0);
}
