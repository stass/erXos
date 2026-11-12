/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Host driver of the erx_program core's credit and shape reader
 * (otp/erts/emulator/sys/erxos/erx_program_core.h), for
 * test/host/erx_program_credit_test.rb. It reads requests on standard input,
 * one per line, and answers each on standard output:
 *
 *   shape HEX		"request S" or "other": erx_program_frame_shape of the bytes
 *   step BUSY INPUT	one step of the credit from the busy mask BUSY (decimal):
 *			INPUT is "request S", "other" or "reply S"; the answer is
 *			"deliver", "refuse", "replied" or "unreplied", then the
 *			busy mask after the step
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_program_core.h"

#define LINE_MAX_BYTES	4096

static size_t
unhex(const char *text, uint8_t *out, size_t cap)
{
	size_t n;
	unsigned byte;

	for (n = 0; n < cap && sscanf(text + 2 * n, "%2x", &byte) == 1; n++)
		out[n] = (uint8_t)byte;
	return (n);
}

static void
shape(const char *hex)
{
	uint8_t bytes[LINE_MAX_BYTES / 2];
	erx_program_frame_t frame;
	size_t len;

	len = unhex(hex, bytes, sizeof(bytes));
	frame = erx_program_frame_shape(bytes, len);
	if (frame.kind == ERX_PROGRAM_FRAME_REQUEST)
		printf("request %u\n", (unsigned)frame.slot);
	else
		printf("other\n");
}

static void
step(const char *args)
{
	erx_program_credit_t credit;
	erx_program_frame_t frame = { .kind = ERX_PROGRAM_FRAME_OTHER };
	unsigned busy, slot;
	const char *answer;

	if (sscanf(args, "%u", &busy) != 1 || busy > UINT16_MAX) {
		printf("bad request\n");
		return;
	}
	credit.busy = (uint16_t)busy;
	if (sscanf(args, "%*u request %u", &slot) == 1) {
		frame = (erx_program_frame_t){ .kind = ERX_PROGRAM_FRAME_REQUEST,
		    .slot = (uint8_t)slot };
		answer = erx_program_credit_take(&credit, frame) ==
		    ERX_PROGRAM_DELIVER ? "deliver" : "refuse";
	} else if (sscanf(args, "%*u reply %u", &slot) == 1) {
		answer = erx_program_credit_reply(&credit, slot) ? "replied" :
		    "unreplied";
	} else if (strstr(args, " other") != NULL) {
		answer = erx_program_credit_take(&credit, frame) ==
		    ERX_PROGRAM_DELIVER ? "deliver" : "refuse";
	} else {
		printf("bad request\n");
		return;
	}
	printf("%s %u\n", answer, (unsigned)credit.busy);
}

int
main(void)
{
	char line[LINE_MAX_BYTES + 16];

	while (fgets(line, sizeof(line), stdin) != NULL) {
		line[strcspn(line, "\n")] = '\0';
		if (strncmp(line, "shape ", 6) == 0)
			shape(line + 6);
		else if (strncmp(line, "step ", 5) == 0)
			step(line + 5);
		else
			printf("bad request\n");
	}
	return (fflush(stdout) == 0 ? EXIT_SUCCESS : EXIT_FAILURE);
}
