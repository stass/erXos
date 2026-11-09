/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the hosted backend's erx_debug_log as a program would: bytes in the
 * calling thread's UTCB, then the generated call. Each argument is one step:
 *
 *   line:HEX        log HEX, printing the status on standard output
 *   length:N        log N bytes of whatever the UTCB holds
 *   flood:THREADS:LINES  LINES full lines on each of THREADS threads, each
 *                   printing its statuses' sum at the end
 *   sleep:MS        sleep
 *   read:CURSOR     erx_log_read from CURSOR: "read STATUS lost N", then "read LINE"
 *                   for each record
 *   take            erx_log_take: "take STATUS lost N", then "take LINE" for each
 *
 * The log's lines go to standard error, which the test reads.
 */

#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "erx/abi.h"
#include "erx/log.h"
#include "liberx/backend/api.h"
#include "liberx/backend/hosted/log.h"
#include "liberx/generated/calls.h"

#define FLOOD_THREADS_MAX	8

int main(int, char **);

static void *flood_thread(void *);
static void flood(const char *);
static void log_bytes(const char *);
static erx_status_t put_and_log(const uint8_t *, size_t);
static void read_log(const char *, const char *);

static long flood_lines;

/* Writes the bytes to this thread's UTCB, word by word, and logs them. */
static erx_status_t
put_and_log(const uint8_t *bytes, size_t length)
{
	erx_utcb_t *utcb;
	erx_utcb_length_t len;
	uint64_t word;

	utcb = erx_utcb_self();
	for (size_t index = 0; index * sizeof(word) < length; index++) {
		word = 0;
		memcpy(&word, bytes + index * sizeof(word),
		    length - index * sizeof(word) < sizeof(word) ?
		    length - index * sizeof(word) : sizeof(word));
		if (!erx_utcb_mr_store(utcb, index, word))
			exit(2);
	}
	len.raw = (uint32_t)length;
	return (erx_debug_log(len));
}

static void
log_bytes(const char *hex)
{
	uint8_t bytes[ERX_UTCB_BYTES_MAX];
	size_t length;
	unsigned int byte;

	length = strlen(hex) / 2;
	if (length > sizeof(bytes))
		exit(2);
	for (size_t index = 0; index < length; index++) {
		if (sscanf(hex + index * 2, "%2x", &byte) != 1)
			exit(2);
		bytes[index] = (uint8_t)byte;
	}
	printf("status %d\n", (int)put_and_log(bytes, length));
}

static void *
flood_thread(void *unused)
{
	uint8_t bytes[ERX_UTCB_BYTES_MAX];
	erx_status_t status;
	long failures;

	(void)unused;
	memset(bytes, 'f', sizeof(bytes));
	failures = 0;
	for (long line = 0; line < flood_lines; line++) {
		status = put_and_log(bytes, sizeof(bytes));
		if (status != ERX_OK)
			failures++;
	}
	return ((void *)failures);
}

static void
flood(const char *spec)
{
	pthread_t threads[FLOOD_THREADS_MAX];
	void *failures;
	long count, total;
	char *end;

	count = strtol(spec, &end, 10);
	if (*end != ':' || count < 1 || count > FLOOD_THREADS_MAX)
		exit(2);
	flood_lines = strtol(end + 1, NULL, 10);
	for (long index = 0; index < count; index++) {
		if (pthread_create(&threads[index], NULL, flood_thread, NULL) != 0)
			exit(2);
	}
	total = 0;
	for (long index = 0; index < count; index++) {
		if (pthread_join(threads[index], &failures) != 0)
			exit(2);
		total += (long)failures;
	}
	printf("flood failures %ld\n", total);
}

/* One erx_log_read from cursor, or an erx_log_take when cursor is NULL, printed as op's lines. */
static void
read_log(const char *op, const char *cursor)
{
	static uint8_t window[2 * ERX_LOG_RECORD_MAX];
	static char text[ERX_LOG_TEXT_MAX], line[ERX_LOG_LINE_MAX + 1];
	erx_log_read_result_t result = { 0 };
	erx_log_view_t view;
	size_t offset = 0;
	int status;

	if (cursor == NULL)
		status = erx_log_take(0, window, sizeof(window), &result);
	else
		status = erx_log_read(0, strtoull(cursor, NULL, 10), window, sizeof(window), &result);
	printf("%s %d lost %" PRIu64 "\n", op, status, result.lost);
	if (status != ERX_OK || result.written > sizeof(window))
		return;
	while (erx_log_next_record(window, (size_t)result.written, &offset, text, &view) ==
	    ERX_LOG_NEXT_RECORD) {
		line[erx_log_render(&view, line, ERX_LOG_LINE_MAX)] = '\0';
		printf("%s %s", op, line);
	}
}

int
main(int argc, char **argv)
{
	erx_utcb_length_t len;
	struct timespec pause;
	long milliseconds;

	for (int index = 1; index < argc; index++) {
		if (strncmp(argv[index], "line:", 5) == 0) {
			log_bytes(argv[index] + 5);
		} else if (strncmp(argv[index], "length:", 7) == 0) {
			len.raw = (uint32_t)strtoul(argv[index] + 7, NULL, 10);
			printf("status %d\n", (int)erx_debug_log(len));
		} else if (strncmp(argv[index], "flood:", 6) == 0) {
			flood(argv[index] + 6);
		} else if (strncmp(argv[index], "sleep:", 6) == 0) {
			milliseconds = strtol(argv[index] + 6, NULL, 10);
			pause.tv_sec = milliseconds / 1000;
			pause.tv_nsec = (milliseconds % 1000) * 1000000;
			nanosleep(&pause, NULL);
		} else if (strncmp(argv[index], "read:", 5) == 0) {
			read_log("read", argv[index] + 5);
		} else if (strcmp(argv[index], "take") == 0) {
			read_log("take", NULL);
		} else {
			return (2);
		}
	}
	return (0);
}
