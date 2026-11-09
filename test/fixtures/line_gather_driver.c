/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives liberx/backend/core/line_gather.c on the host: ERTS's way of writing standard
 * error, a byte at a time from two threads, must come out as one record per line, and a
 * line longer than the buffer as whole buffers and its rest. Prints "line_gather: N" with
 * the count of checks, or names the first that failed and exits 1.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "liberx/backend/core/line_gather.h"

#define RECORDS_MAX	8

typedef struct records {
	size_t	count;
	size_t	length[RECORDS_MAX];
	char	text[RECORDS_MAX][ERX_LINE_GATHER_BYTES + 1];
} records_t;

static int checks;

static void
record(void *context, const char *line, size_t length)
{
	records_t *const records = context;

	if (length > ERX_LINE_GATHER_BYTES) {
		printf("line_gather: a record too long (%zu bytes)\n", length);
		exit(1);
	}
	/* Records past the first RECORDS_MAX are only counted, for expect_count to name. */
	if (records->count < RECORDS_MAX) {
		memcpy(records->text[records->count], line, length);
		records->length[records->count] = length;
	}
	records->count++;
}

static void
expect(const char *what, const records_t *records, size_t index, const char *text, size_t length)
{
	checks++;
	if (index >= records->count || index >= RECORDS_MAX || records->length[index] != length ||
	    memcmp(records->text[index], text, length) != 0) {
		printf("line_gather: %s: record %zu is not the %zu bytes expected (%zu records)\n",
		    what, index, length, records->count);
		exit(1);
	}
}

static void
expect_count(const char *what, const records_t *records, size_t count)
{
	checks++;
	if (records->count != count) {
		printf("line_gather: %s: %zu records, not %zu\n", what, records->count, count);
		exit(1);
	}
}

/* Two threads' lines, each written a byte at a time and the bytes alternating. */
static void
check_bytewise_lines(void)
{
	static const char first[] = "erx: erts: 4 schedulers and 4 dirty CPU schedulers hold executor slots\r\n";
	static const char second[] = "erx: erts: erl_start runs, 5 arguments\r\n";
	static erx_line_gather_t a, b;
	static records_t ra, rb;

	for (size_t at = 0; at < sizeof(first) - 1 || at < sizeof(second) - 1; at++) {
		if (at < sizeof(first) - 1)
			erx_line_gather_write(&a, &first[at], 1, record, &ra);
		if (at < sizeof(second) - 1)
			erx_line_gather_write(&b, &second[at], 1, record, &rb);
	}
	expect_count("bytewise lines", &ra, 1);
	expect("bytewise lines", &ra, 0, first, sizeof(first) - 3);
	expect_count("bytewise lines", &rb, 1);
	expect("bytewise lines", &rb, 0, second, sizeof(second) - 3);
}

/* One write of two lines and the start of a third, then an empty line ending the third. */
static void
check_lines_in_one_write(void)
{
	static erx_line_gather_t gather;
	static records_t records;

	erx_line_gather_write(&gather, "one\ntwo\r\nthr", 12, record, &records);
	expect_count("lines in one write", &records, 2);
	expect("lines in one write", &records, 0, "one", 3);
	expect("lines in one write", &records, 1, "two", 3);
	erx_line_gather_write(&gather, "\r\n\n", 3, record, &records);
	expect("lines in one write", &records, 2, "thr", 3);
	expect("lines in one write", &records, 3, "", 0);
	expect_count("lines in one write", &records, 4);
	erx_line_gather_write(&gather, "a\rb\n", 4, record, &records);
	expect("lines in one write", &records, 4, "a\rb", 3);
}

/* A line two buffers and seven bytes long goes out as two full buffers and its rest. */
static void
check_long_line(void)
{
	static erx_line_gather_t gather;
	static records_t records;
	static char line[2 * ERX_LINE_GATHER_BYTES + 7];

	for (size_t at = 0; at < sizeof(line); at++)
		line[at] = (char)('a' + at % 26);
	erx_line_gather_write(&gather, line, sizeof(line), record, &records);
	expect_count("long line", &records, 2);
	expect("long line", &records, 0, line, ERX_LINE_GATHER_BYTES);
	expect("long line", &records, 1, line + ERX_LINE_GATHER_BYTES, ERX_LINE_GATHER_BYTES);
	erx_line_gather_write(&gather, "\n", 1, record, &records);
	expect("long line", &records, 2, line + 2 * ERX_LINE_GATHER_BYTES, 7);
	expect_count("long line", &records, 3);
}

/*
 * A line exactly as long as the buffer is one record, with LF or with ERTS's CR-LF, and a
 * carriage return inside a line that fills the buffer stays with that line.
 */
static void
check_full_line(void)
{
	static erx_line_gather_t gather;
	static records_t records;
	static char line[ERX_LINE_GATHER_BYTES];

	memset(line, 'x', sizeof(line));
	erx_line_gather_write(&gather, line, sizeof(line), record, &records);
	erx_line_gather_write(&gather, "\n", 1, record, &records);
	expect("full line", &records, 0, line, sizeof(line));
	expect_count("full line", &records, 1);
	erx_line_gather_write(&gather, line, sizeof(line), record, &records);
	erx_line_gather_write(&gather, "\r\n", 2, record, &records);
	expect("full line", &records, 1, line, sizeof(line));
	expect_count("full line", &records, 2);
	line[sizeof(line) - 1] = '\r';
	erx_line_gather_write(&gather, line, sizeof(line), record, &records);
	erx_line_gather_write(&gather, "y\n", 2, record, &records);
	expect("full line", &records, 2, line, sizeof(line));
	expect("full line", &records, 3, "y", 1);
	expect_count("full line", &records, 4);
}

int
main(void)
{
	check_bytewise_lines();
	check_lines_in_one_write();
	check_long_line();
	check_full_line();
	printf("line_gather: %d\n", checks);
	return (0);
}
