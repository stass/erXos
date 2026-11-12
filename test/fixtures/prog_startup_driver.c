/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of liberx's start-up core (test/host/prog_startup_test.rb).
 * Each line of the requests file is "plan HEX", HEX a startup message's
 * bytes, planned with all the scratch erx_prog_scratch_bytes promises, or
 * "later", the status of a frame after the startup message.  Each answer is
 * one line:
 *   go KEY=VALUE...		the plan's fields; texts in hex, a list's
 *				elements joined by ':', fds as numbers
 *   refused check REASON KIND OFFSET
 *   refused descriptor FD
 *   refused bound
 *   later STATUS
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "liberx/program/startup.h"

#define LINE_MAX_BYTES	(2 * 300000 + 64)

static void
put_hex(const uint8_t *bytes, size_t len)
{
	size_t i;

	for (i = 0; i < len; i++)
		printf("%02x", bytes[i]);
}

static int
hex_value(int c)
{
	if (c >= '0' && c <= '9')
		return (c - '0');
	if (c >= 'a' && c <= 'f')
		return (c - 'a' + 10);
	return (-1);
}

/* Decodes hex into bytes: the byte count, or SIZE_MAX on a bad digit. */
static size_t
unhex(const char *hex, uint8_t *bytes)
{
	size_t n;
	int hi, lo;

	for (n = 0; hex[2 * n] != '\0' && hex[2 * n] != '\n'; n++) {
		hi = hex_value(hex[2 * n]);
		lo = hi < 0 ? -1 : hex_value(hex[2 * n + 1]);
		if (lo < 0)
			return (SIZE_MAX);
		bytes[n] = (uint8_t)(hi << 4 | lo);
	}
	return (n);
}

static void
put_argv(erx_prog_argv_iter_t it)
{
	erx_profile_text_t text;
	const char *sep = "";

	while (erx_prog_argv_next(&it, &text)) {
		printf("%s", sep);
		put_hex(text.bytes, text.len);
		sep = ":";
	}
}

static void
put_env(erx_prog_env_iter_t it)
{
	erx_profile_text_t text;
	const char *sep = "";

	while (erx_prog_env_next(&it, &text)) {
		printf("%s", sep);
		put_hex(text.bytes, text.len);
		sep = ":";
	}
}

static void
put_fds(erx_prog_fds_iter_t it)
{
	erx_prog_fd_entry_t entry;
	const char *sep = "";

	while (erx_prog_fds_next(&it, &entry)) {
		printf("%s%u", sep, entry.fd);
		sep = ":";
	}
}

static void
plan(const uint8_t *frame, size_t len)
{
	static erx_prog_startup_t out;
	size_t need;
	void *scratch;
	int status, want;

	need = erx_prog_scratch_bytes(len);
	if (need == SIZE_MAX || (scratch = malloc(need == 0 ? 1 : need)) == NULL)
		abort();
	status = erx_prog_startup_plan(frame, len, scratch, need, &out);
	free(scratch);
	/* A plan that runs has status 0, and every refusal status 127. */
	want = out.cause == ERX_PROG_STARTUP_GO ? 0 : ERX_PROG_STATUS_REFUSED;
	if (status != want || out.status != want)
		abort();
	switch (out.cause) {
	case ERX_PROG_STARTUP_CHECK:
		printf("refused check %s %s %zu\n",
		    erx_profile_reason_name(out.refusal.reason),
		    erx_prog_kind_name(out.refusal.kind), out.refusal.offset);
		return;
	case ERX_PROG_STARTUP_DESCRIPTOR:
		printf("refused descriptor %u\n", out.fd);
		return;
	case ERX_PROG_STARTUP_BOUND:
		printf("refused bound\n");
		return;
	case ERX_PROG_STARTUP_GO:
		break;
	}
	if (out.status != 0 || out.cwd[out.cwd_len] != '\0' ||
	    strlen(out.cwd) != out.cwd_len)
		abort();
	printf("go status=%d pid=%u ppid=%u pgid=%u spawn=%d umask=%u",
	    out.status, out.pid, out.ppid, out.pgid, out.spawn, out.umask);
	printf(" sigmask=%016llx%016llx sigignore=%016llx%016llx",
	    (unsigned long long)out.sigmask.bits[1],
	    (unsigned long long)out.sigmask.bits[0],
	    (unsigned long long)out.sigignore.bits[1],
	    (unsigned long long)out.sigignore.bits[0]);
	printf(" data_area=%llu data_slots=%u",
	    (unsigned long long)out.data_area, out.data_slots);
	if (out.has_image)
		printf(" image=%llu", (unsigned long long)out.image);
	printf(" argc=%u argv_bytes=%zu envc=%u env_bytes=%zu cwd=",
	    out.argc, out.argv_bytes, out.envc, out.env_bytes);
	put_hex((const uint8_t *)out.cwd, out.cwd_len);
	printf(" argv=");
	put_argv(out.argv);
	printf(" env=");
	put_env(out.env);
	printf(" fds=");
	put_fds(out.fds);
	printf("\n");
}

int
main(int argc, char **argv)
{
	static char line[LINE_MAX_BYTES];
	static uint8_t frame[LINE_MAX_BYTES / 2];
	FILE *requests;
	size_t len;

	if (argc != 2 || (requests = fopen(argv[1], "r")) == NULL)
		return (2);
	while (fgets(line, sizeof(line), requests) != NULL) {
		if (strcmp(line, "later\n") == 0) {
			printf("later %d\n", erx_prog_later_frame_status());
			continue;
		}
		if (strncmp(line, "plan ", 5) != 0 ||
		    (len = unhex(line + 5, frame)) == SIZE_MAX)
			return (2);
		plan(frame, len);
	}
	fclose(requests);
	return (0);
}
