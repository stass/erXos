/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the log core (kernel/core/log.c). It reads one command
 * per line from the file named by its argument and prints what the core did,
 * which test/fixtures/log_model.rb predicts independently. Bytes are hex; "-"
 * is no bytes.
 *
 *   escape HEX CAPACITY          erx_log_escape into CAPACITY bytes
 *   rate NOW COST                erx_log_rate_admit on the driver's own state
 *   debug SPACE NOW LEN HEX      fill the UTCB with HEX and erx_log_debug
 *   format LEVEL NOW HEX         erx_log_format with "%s" and HEX as a string
 *   numbers NOW                  a line of every integer conversion's extremes
 *   oddity NAME                  a format the core refuses, by name
 *   cut KIND PAD                 a line of PAD bytes and text a record end cuts
 *   cursor SEQ                   set next_seq and oldest_seq (an empty log)
 *   read CURSOR WINDOW           erx_log_copy, then read and render each record
 *   parse HEX                    erx_log_next_record over HEX until it stops
 *   render SEQ NOW LEVEL FLAGS CAPACITY HEX
 *                                erx_log_render of a view with text HEX
 *   state                        the ring's four counters
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/log.h"

#define DRIVER_LINE_MAX		(16 * 1024)
#define DRIVER_WINDOW_MAX	(128 * 1024)
#define DRIVER_TEXT_MAX		(4 * 1024)

int main(int, char **);

static void command_cut(char *);
static void command_escape(char *);
static void command_debug(char *);
static void command_format(char *);
static void command_numbers(char *);
static void command_oddity(char *);
static void command_parse(char *);
static void command_rate(char *);
static void command_read(char *);
static void command_render(char *);
static size_t decode_hex(const char *, uint8_t *, size_t);
static void fail(const char *) __attribute__((__noreturn__));
static char *field(char **);
static void print_hex(const void *, size_t);
static void print_records(const uint8_t *, size_t);
static uint64_t unsigned_field(char **);

static erx_log_t driver_log;
static erx_log_rate_t driver_rate;
static erx_log_rate_t driver_debug_rate;

static void
fail(const char *why)
{
	fprintf(stderr, "log driver: %s\n", why);
	exit(2);
}

static char *
field(char **cursor)
{
	char *end, *value;

	value = *cursor;
	if (value == NULL || *value == '\0')
		fail("missing field");
	end = strchr(value, ' ');
	if (end != NULL)
		*end = '\0';
	*cursor = end != NULL ? end + 1 : NULL;
	return (value);
}

static uint64_t
unsigned_field(char **cursor)
{
	return (strtoull(field(cursor), NULL, 0));
}

static size_t
decode_hex(const char *hex, uint8_t *bytes, size_t capacity)
{
	size_t length;
	unsigned int byte;

	if (strcmp(hex, "-") == 0)
		return (0);
	length = strlen(hex) / 2;
	if (length > capacity)
		fail("hex field too long");
	for (size_t index = 0; index < length; index++) {
		if (sscanf(hex + index * 2, "%2x", &byte) != 1)
			fail("bad hex");
		bytes[index] = (uint8_t)byte;
	}
	return (length);
}

static void
print_hex(const void *bytes, size_t length)
{
	const uint8_t *in;

	in = bytes;
	if (length == 0)
		printf("-");
	for (size_t index = 0; index < length; index++)
		printf("%02x", in[index]);
}

static void
command_escape(char *cursor)
{
	static uint8_t input[DRIVER_TEXT_MAX];
	static char output[4 * DRIVER_TEXT_MAX];
	erx_log_escape_result_t result;
	const char *hex;
	size_t capacity, length;

	hex = field(&cursor);
	capacity = (size_t)unsigned_field(&cursor);
	if (capacity > sizeof(output))
		fail("escape capacity too large");
	length = decode_hex(hex, input, sizeof(input));
	result = erx_log_escape(input, length, output, capacity);
	printf("escape %zu %zu ", result.consumed, result.written);
	print_hex(output, result.written);
	printf("\n");
}

static void
command_rate(char *cursor)
{
	erx_log_rate_step_t step;
	uint64_t now_ns;
	uint32_t cost;

	now_ns = unsigned_field(&cursor);
	cost = (uint32_t)unsigned_field(&cursor);
	step = erx_log_rate_admit(&driver_rate, now_ns, cost);
	driver_rate = step.next;
	printf("rate %d %" PRIu64 " %u %" PRIu64 "\n", step.admit,
	    step.next.window_start_ns, step.next.window_bytes,
	    step.next.dropped);
}

static void
command_debug(char *cursor)
{
	static erx_utcb_t utcb;
	uint8_t bytes[sizeof(uint64_t) * ERX_MSG_WORDS];
	uint64_t space, now_ns, word;
	erx_utcb_length_t len;
	size_t length;

	space = unsigned_field(&cursor);
	now_ns = unsigned_field(&cursor);
	len.raw = (uint32_t)unsigned_field(&cursor);
	memset(bytes, 0xee, sizeof(bytes));
	length = decode_hex(field(&cursor), bytes, sizeof(bytes));
	(void)length;
	for (size_t index = 0; index < ERX_MSG_WORDS; index++) {
		memcpy(&word, bytes + index * sizeof(word), sizeof(word));
		if (!erx_utcb_mr_store(&utcb, index, word))
			fail("UTCB store");
	}
	printf("debug %d\n", (int)erx_log_debug(&driver_log, &driver_debug_rate,
	    space, now_ns, &utcb, len));
}

static void
command_format(char *cursor)
{
	static uint8_t string[DRIVER_TEXT_MAX + 1];
	erx_log_level_t level;
	uint64_t now_ns;
	size_t length;

	level = (erx_log_level_t)unsigned_field(&cursor);
	now_ns = unsigned_field(&cursor);
	length = decode_hex(field(&cursor), string, DRIVER_TEXT_MAX);
	string[length] = '\0';
	printf("format %d\n", (int)ERX_LOG_FORMAT(&driver_log, level, now_ns,
	    "s=%s", (const char *)string));
}

/*
 * A pad, then conversions and format text that a record's end can cut: at a
 * digit, across a token, and with shorter text after it that must not slip
 * in behind the cut. %f is not understood: the mark must be cut the same way.
 */
static void
command_cut(char *cursor)
{
	static char pad[DRIVER_TEXT_MAX];
	const char *kind;
	erx_status_t status;
	size_t length;

	kind = field(&cursor);
	length = (size_t)unsigned_field(&cursor);
	if (length > sizeof(pad))
		fail("pad too long");
	memset(pad, 'p', length);
	if (strcmp(kind, "conversions") == 0)
		status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, 0,
		    "%.*s%d%x%c%s\nend", (int)length, pad, -12345, 0xabcu, '\n', "tail");
	else
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat"
#pragma clang diagnostic ignored "-Wformat-pedantic"
		status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, 0,
		    "%.*s%f", (int)length, pad, 1.5);
#pragma clang diagnostic pop
	printf("cut %d\n", (int)status);
}

static void
command_numbers(char *cursor)
{
	erx_status_t status;

	status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO,
	    unsigned_field(&cursor),
	    "%d %d %u %x %ld %lu %lx %lld %llu %llx %zu %zx %c %.*s %.*s%%",
	    INT32_MIN, 7, UINT32_MAX, 0xabcu, (long)INT64_MIN, (unsigned long)UINT64_MAX,
	    (unsigned long)0xdefUL, (long long)-1, (unsigned long long)UINT64_MAX,
	    (unsigned long long)UINT64_MAX, (size_t)SIZE_MAX, (size_t)0x12,
	    '\n', 3, "abcdef", 8, "short");
	printf("numbers %d\n", (int)status);
}

/*
 * The formats a compiler's check lets through or that only a suppressed
 * warning allows; the core must stop at each, reading no further argument.
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat"
#pragma clang diagnostic ignored "-Wformat-invalid-specifier"
#pragma clang diagnostic ignored "-Wformat-extra-args"
#pragma clang diagnostic ignored "-Wformat-pedantic"
static void
command_oddity(char *cursor)
{
	const char *name;
	erx_status_t status;
	int stored;

	name = field(&cursor);
	stored = 0x5a;
	if (strcmp(name, "float") == 0)
		status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, 1,
		    "a %f b %s", 1.5, "after");
	else if (strcmp(name, "store") == 0)
		status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, 1,
		    "a %n b", &stored);
	else if (strcmp(name, "end") == 0)
		status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, 1,
		    "a %");
	else if (strcmp(name, "negative") == 0)
		status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, 1,
		    "a %.*s b", -1, "unbounded");
	else if (strcmp(name, "precise-number") == 0)
		status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, 1,
		    "a %.*d b", 2, 5);
	else if (strcmp(name, "wide-string") == 0)
		status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, 1,
		    "a %ls b", (const wchar_t *)NULL);
	else if (strcmp(name, "null") == 0)
		status = ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, 1,
		    "a %s b", (const char *)NULL);
	else
		fail("unknown oddity");
	if (stored != 0x5a)
		fail("the core stored through a conversion");
	printf("oddity %d\n", (int)status);
}
#pragma clang diagnostic pop

/* Reads a window of records, printing each one and its rendered line. */
static void
print_records(const uint8_t *window, size_t length)
{
	static char line[ERX_LOG_LINE_MAX];
	static char text[ERX_LOG_TEXT_MAX];
	erx_log_next_t next;
	erx_log_view_t view;
	size_t offset, rendered;

	offset = 0;
	while ((next = erx_log_next_record(window, length, &offset, text,
	    &view)) == ERX_LOG_NEXT_RECORD) {
		printf("record %" PRIu64 " %" PRIu64 " %u %u %zu ", view.seq,
		    view.time_ns, view.level, view.flags, offset);
		print_hex(view.text, view.length);
		rendered = erx_log_render(&view, line, sizeof(line));
		printf(" ");
		print_hex(line, rendered);
		printf("\n");
	}
	printf("%s %zu\n", next == ERX_LOG_NEXT_END ? "end" : "corrupt", offset);
}

static void
command_read(char *cursor)
{
	static uint8_t window[DRIVER_WINDOW_MAX];
	erx_log_copy_result_t result;
	uint64_t position;
	size_t size;

	position = unsigned_field(&cursor);
	size = (size_t)unsigned_field(&cursor);
	if (size > sizeof(window))
		fail("window too large");
	memset(window, 0xcc, sizeof(window));
	result = erx_log_copy(&driver_log, position, window, size);
	for (size_t index = result.written; index < sizeof(window); index++) {
		if (window[index] != 0xcc)
			fail("the core wrote past what it reported");
	}
	printf("read %d %" PRIu64 " %" PRIu64 " %zu %u\n", (int)result.status,
	    result.next_cursor, result.lost, result.written, result.records);
	print_records(window, result.written);
}

static void
command_parse(char *cursor)
{
	static uint8_t window[DRIVER_WINDOW_MAX];
	size_t length;

	length = decode_hex(field(&cursor), window, sizeof(window));
	print_records(window, length);
}

static void
command_render(char *cursor)
{
	static uint8_t text[DRIVER_TEXT_MAX];
	static char line[2 * DRIVER_LINE_MAX];
	erx_log_view_t view;
	size_t capacity, rendered;

	view.seq = unsigned_field(&cursor);
	view.time_ns = unsigned_field(&cursor);
	view.level = (erx_log_level_t)unsigned_field(&cursor);
	view.flags = (erx_log_record_flags_t)unsigned_field(&cursor);
	capacity = (size_t)unsigned_field(&cursor);
	if (capacity > sizeof(line))
		fail("render capacity too large");
	view.length = decode_hex(field(&cursor), text, sizeof(text));
	view.text = (const char *)text;
	rendered = erx_log_render(&view, line, capacity);
	printf("render %zu ", rendered);
	print_hex(line, rendered);
	printf("\n");
}

int
main(int argc, char **argv)
{
	static char line[DRIVER_LINE_MAX];
	char *cursor, *name;
	FILE *commands;

	if (argc != 2 || (commands = fopen(argv[1], "r")) == NULL)
		fail("usage: log_driver COMMANDS");
	while (fgets(line, sizeof(line), commands) != NULL) {
		line[strcspn(line, "\n")] = '\0';
		cursor = line;
		name = field(&cursor);
		if (strcmp(name, "escape") == 0)
			command_escape(cursor);
		else if (strcmp(name, "rate") == 0)
			command_rate(cursor);
		else if (strcmp(name, "debug") == 0)
			command_debug(cursor);
		else if (strcmp(name, "format") == 0)
			command_format(cursor);
		else if (strcmp(name, "numbers") == 0)
			command_numbers(cursor);
		else if (strcmp(name, "cut") == 0)
			command_cut(cursor);
		else if (strcmp(name, "oddity") == 0)
			command_oddity(cursor);
		else if (strcmp(name, "cursor") == 0) {
			driver_log.next_seq = unsigned_field(&cursor);
			driver_log.oldest_seq = driver_log.next_seq;
		} else if (strcmp(name, "read") == 0)
			command_read(cursor);
		else if (strcmp(name, "parse") == 0)
			command_parse(cursor);
		else if (strcmp(name, "render") == 0)
			command_render(cursor);
		else if (strcmp(name, "state") == 0)
			printf("state %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 "\n",
			    driver_log.next_seq, driver_log.oldest_seq,
			    driver_log.head, driver_log.tail);
		else
			fail("unknown command");
	}
	fclose(commands);
	return (0);
}
