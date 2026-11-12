/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Host driver of the erx_program core's credit and shape reader
 * (otp/erts/emulator/sys/erxos/erx_program_core.h), for
 * test/host/erx_program_credit_test.rb. It reads requests on standard input,
 * one per line, and answers each on standard output. A key is "cP.E", a
 * {closed, P, E}, or "dP.E.W", a {drained, P, E, W}; a list of keys is the
 * keys joined by commas, or "-" for none. The credit's bounds are CLOSED_MAX
 * {closed} and DRAINED_MAX {drained} keys.
 *
 *   shape HEX			"request S", "notice KEY" or "other":
 *				erx_program_frame_shape of the bytes
 *   step BUSY DUE INPUT	one step of the credit whose busy mask is BUSY
 *				(decimal) and whose due keys are DUE: INPUT is
 *				"request S", "other", "notice KEY" or "send R KEYS",
 *				R a slot or "none"; the answer is "deliver" or
 *				"refuse" for a frame, "admitted" or "refused" for a
 *				send, then the busy mask and the due keys, sorted,
 *				after the step
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_program_core.h"

#define LINE_MAX_BYTES	4096
#define CLOSED_MAX	2
#define DRAINED_MAX	1
#define KEYS_MAX	16

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
key_print(char *out, size_t cap, erx_program_notice_t key)
{
	if (key.kind == ERX_PROGRAM_NOTICE_CLOSED)
		(void)snprintf(out, cap, "c%u.%u", (unsigned)key.pipe, (unsigned)key.end);
	else
		(void)snprintf(out, cap, "d%u.%u.%u", (unsigned)key.pipe, (unsigned)key.end,
		    (unsigned)key.writer);
}

/* One key from text: false on anything else. */
static bool
key_parse(const char *text, erx_program_notice_t *key)
{
	unsigned pipe, end, writer;
	int used = 0;

	*key = (erx_program_notice_t){ 0 };
	if (sscanf(text, "d%u.%u.%u%n", &pipe, &end, &writer, &used) == 3 && text[used] == '\0') {
		*key = (erx_program_notice_t){ .kind = ERX_PROGRAM_NOTICE_DRAINED, .pipe = pipe,
		    .end = end, .writer = writer };
		return (true);
	}
	if (sscanf(text, "c%u.%u%n", &pipe, &end, &used) == 2 && text[used] == '\0') {
		*key = (erx_program_notice_t){ .kind = ERX_PROGRAM_NOTICE_CLOSED, .pipe = pipe,
		    .end = end };
		return (true);
	}
	return (false);
}

/* A list of keys, "-" for none, into keys: their count, or -1 on anything else. */
static int
keys_parse(char *text, erx_program_notice_t keys[KEYS_MAX])
{
	int count = 0;

	if (strcmp(text, "-") == 0)
		return (0);
	for (char *at = strtok(text, ","); at != NULL; at = strtok(NULL, ",")) {
		if (count == KEYS_MAX || !key_parse(at, &keys[count]))
			return (-1);
		count++;
	}
	return (count);
}

static int
key_order(const void *a, const void *b)
{
	char x[64], y[64];

	key_print(x, sizeof(x), *(const erx_program_notice_t *)a);
	key_print(y, sizeof(y), *(const erx_program_notice_t *)b);
	return (strcmp(x, y));
}

static void
shape(const char *hex)
{
	uint8_t bytes[LINE_MAX_BYTES / 2];
	erx_program_frame_t frame;
	char key[64];
	size_t len;

	len = unhex(hex, bytes, sizeof(bytes));
	frame = erx_program_frame_shape(bytes, len);
	switch (frame.kind) {
	case ERX_PROGRAM_FRAME_REQUEST:
		printf("request %u\n", (unsigned)frame.slot);
		break;
	case ERX_PROGRAM_FRAME_NOTICE:
		key_print(key, sizeof(key), frame.notice);
		printf("notice %s\n", key);
		break;
	case ERX_PROGRAM_FRAME_OTHER:
		printf("other\n");
		break;
	}
}

static void
step(char *args)
{
	erx_program_notice_t storage[CLOSED_MAX + DRAINED_MAX], due[KEYS_MAX], grants[KEYS_MAX];
	erx_program_credit_t credit;
	erx_program_frame_t frame = { .kind = ERX_PROGRAM_FRAME_OTHER };
	char *busy_text = strtok(args, " "), *due_text = strtok(NULL, " ");
	char *input = strtok(NULL, " "), *arg = strtok(NULL, " "), *arg2 = strtok(NULL, " ");
	const char *answer = NULL;
	unsigned long busy;
	int dues, count;

	if (busy_text == NULL || due_text == NULL || input == NULL ||
	    (busy = strtoul(busy_text, NULL, 10)) > UINT16_MAX || (dues = keys_parse(due_text, due)) < 0) {
		printf("bad request\n");
		return;
	}
	erx_program_credit_init(&credit, storage, CLOSED_MAX, DRAINED_MAX);
	credit.busy = (uint16_t)busy;
	for (int at = 0; at < dues; at++) {
		const erx_program_send_t one = { .reply = ERX_PROGRAM_NO_REPLY, .grants = &due[at], .count = 1 };

		if (!erx_program_credit_admits(&credit, &one)) {
			printf("bad request\n");
			return;
		}
		erx_program_credit_sent(&credit, &one);
	}
	if (strcmp(input, "request") == 0 && arg != NULL) {
		frame = (erx_program_frame_t){ .kind = ERX_PROGRAM_FRAME_REQUEST,
		    .slot = (uint8_t)strtoul(arg, NULL, 10) };
	} else if (strcmp(input, "notice") == 0 && arg != NULL && key_parse(arg, &frame.notice)) {
		frame.kind = ERX_PROGRAM_FRAME_NOTICE;
	} else if (strcmp(input, "send") == 0 && arg != NULL && arg2 != NULL &&
	    (count = keys_parse(arg2, grants)) >= 0) {
		const erx_program_send_t send = { .grants = grants, .count = (uint32_t)count,
		    .reply = strcmp(arg, "none") == 0 ? ERX_PROGRAM_NO_REPLY : (uint32_t)strtoul(arg, NULL, 10) };

		answer = "refused";
		if (erx_program_credit_admits(&credit, &send)) {
			erx_program_credit_sent(&credit, &send);
			answer = "admitted";
		}
	} else if (strcmp(input, "other") != 0) {
		printf("bad request\n");
		return;
	}
	if (answer == NULL)
		answer = erx_program_credit_take(&credit, frame) == ERX_PROGRAM_DELIVER ? "deliver" : "refuse";
	printf("%s %u ", answer, (unsigned)credit.busy);
	qsort(credit.due, credit.closed + credit.drained, sizeof(credit.due[0]), key_order);
	if (credit.closed + credit.drained == 0)
		printf("-");
	for (uint32_t at = 0; at < credit.closed + credit.drained; at++) {
		char key[64];

		key_print(key, sizeof(key), credit.due[at]);
		printf("%s%s", at == 0 ? "" : ",", key);
	}
	printf("\n");
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
