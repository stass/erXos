/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives kernel/core/console_ring.c from a script for
 * test/host/console_ring_test.rb, one command a line, and prints what each
 * call returned and, on "state", what the ring holds. Bytes are printed as
 * a CRC-32 and a length unless "verbose 1" asks for hex, so the exhaustive
 * run's output stays small. The script is the test's own, so a malformed
 * line simply ends the driver. "save N" and "restore N" keep and bring back
 * the ring, so a walk of every sequence of calls runs each call once.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/console_ring.h"

#define DRIVER_LINE_MAX	(2 * 8192 + 64)
#define DRIVER_TEXT_MAX	8192
/* The exhaustive walk's depth: one saved ring per level. */
#define DRIVER_SAVED_MAX	8

static void command_drain(bool);
static void command_reply(char *);
static void command_state(void);
static void command_take(void);
static void command_write(char *);
static uint32_t crc32(const uint8_t *, size_t);
static size_t decode_hex(const char *, uint8_t *, size_t);
static void fail(const char *) __attribute__((__noreturn__));
static char *field(char **);
static void print_bytes(const void *, size_t);
static size_t saved_slot(char **);

static erx_console_ring_t driver_ring;
static erx_console_ring_t driver_saved[DRIVER_SAVED_MAX];
static bool driver_verbose;

static void
fail(const char *why)
{
	fprintf(stderr, "console_ring_driver: %s\n", why);
	exit(2);
}

static char *
field(char **cursor)
{
	char *start;

	start = *cursor;
	if (*start == '\0')
		fail("missing field");
	*cursor = start + strcspn(start, " ");
	if (**cursor == ' ')
		*(*cursor)++ = '\0';
	return (start);
}

static size_t
saved_slot(char **cursor)
{
	unsigned long slot;

	slot = strtoul(field(cursor), NULL, 10);
	if (slot >= DRIVER_SAVED_MAX)
		fail("no such saved ring");
	return ((size_t)slot);
}

static size_t
decode_hex(const char *hex, uint8_t *bytes, size_t capacity)
{
	size_t length;
	unsigned int byte;

	if (strcmp(hex, "-") == 0)
		return (0);
	length = strlen(hex);
	if (length % 2 != 0 || length / 2 > capacity)
		fail("bad hex");
	for (size_t at = 0; at < length / 2; at++) {
		if (sscanf(hex + 2 * at, "%2x", &byte) != 1)
			fail("bad hex");
		bytes[at] = (uint8_t)byte;
	}
	return (length / 2);
}

static uint32_t
crc32(const uint8_t *bytes, size_t length)
{
	uint32_t crc;

	crc = UINT32_MAX;
	for (size_t at = 0; at < length; at++) {
		crc ^= bytes[at];
		for (int bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1)));
	}
	return (~crc);
}

/* " LENGTH CRC", or " HEX" in verbose mode ("-" for none). */
static void
print_bytes(const void *bytes, size_t length)
{
	const uint8_t *in;

	in = bytes;
	if (!driver_verbose) {
		printf(" %zu %08" PRIx32, length, crc32(in, length));
		return;
	}
	printf(" ");
	if (length == 0)
		printf("-");
	for (size_t at = 0; at < length; at++)
		printf("%02x", in[at]);
}

/* write HEX [COUNT]: the bytes, COUNT times over, as one write. */
static void
command_write(char *cursor)
{
	static uint8_t text[DRIVER_TEXT_MAX];
	erx_console_write_t result;
	unsigned long count;
	size_t length, unit;

	unit = decode_hex(field(&cursor), text, sizeof(text));
	count = *cursor == '\0' ? 1 : strtoul(field(&cursor), NULL, 10);
	if (count == 0 || (unit != 0 && count > sizeof(text) / unit))
		fail("write longer than the driver holds");
	for (length = unit; length < unit * count; length += unit)
		memcpy(text + length, text, unit);
	result = erx_console_ring_write(&driver_ring, text, length);
	if (result.uart_from + result.uart_length != length)
		fail("the UART part is not the write's end");
	printf("write %zu\n", result.uart_from);
}

/*
 * The reply's words start as 0xee, so a padding byte the core left unwritten
 * shows; the driver checks the padding and prints the reply's bytes.
 */
static void
command_take(void)
{
	erx_console_reply_words_t reply;
	const uint8_t *bytes;
	size_t length;

	memset(&reply, 0xee, sizeof(reply));
	erx_console_ring_take(&driver_ring, &reply);
	length = (size_t)reply.words[1];
	if (reply.count > ERX_CONSOLE_RING_REPLY_WORDS ||
	    length > (reply.count - ERX_CONSOLE_RING_REPLY_HEADER) * 8 ||
	    reply.count != ERX_CONSOLE_RING_REPLY_HEADER + (length + 7) / 8)
		fail("the reply's count does not match its length");
	bytes = (const uint8_t *)&reply.words[ERX_CONSOLE_RING_REPLY_HEADER];
	for (size_t at = length; at < ERX_CONSOLE_RING_REPLY_BYTES; at++)
		if (bytes[at] != 0)
			fail("a reply byte past its length is not zero");
	printf("take %" PRIu64, reply.words[0]);
	print_bytes(bytes, length);
	printf("\n");
}

/* Every piece up to the first empty one; "drain 1" prints each piece alone. */
static void
command_drain(bool pieces)
{
	static char all[4 * DRIVER_TEXT_MAX];
	erx_console_drain_t piece;
	size_t length, total;

	total = 0;
	for (;;) {
		memset(&piece, 0xee, sizeof(piece));
		length = erx_console_ring_drain(&driver_ring, &piece);
		if (length > sizeof(piece.bytes))
			fail("a piece longer than its buffer");
		if (length == 0)
			break;
		if (pieces) {
			printf("piece");
			print_bytes(piece.bytes, length);
			printf("\n");
		}
		if (length > sizeof(all) - total)
			fail("drain longer than the driver holds");
		memcpy(all + total, piece.bytes, length);
		total += length;
	}
	printf("drain");
	print_bytes(all, total);
	printf("\n");
}

static void
command_state(void)
{
	static const char *const routes[] = { "uart", "ring", "closed" };
	uint8_t held[ERX_CONSOLE_RING_BYTES];
	uint32_t length;

	length = driver_ring.head - driver_ring.tail;
	if (length > ERX_CONSOLE_RING_BYTES ||
	    driver_ring.head - driver_ring.open > length)
		fail("the ring's positions are out of order");
	for (uint32_t at = 0; at < length; at++)
		held[at] = driver_ring.bytes[(driver_ring.tail + at) %
		    ERX_CONSOLE_RING_BYTES];
	printf("state %s %d %d %" PRIu32 " %" PRIu64, routes[driver_ring.route],
	    driver_ring.dropping, driver_ring.uart_line_open,
	    driver_ring.head - driver_ring.open, driver_ring.lost);
	print_bytes(held, length);
	printf("\n");
}

/* reply COUNT HEXWORDS: the words' bytes in memory order, then the lines. */
static void
command_reply(char *cursor)
{
	erx_console_reply_words_t words;
	erx_console_reply_t reply;
	erx_console_line_t line;
	size_t offset;

	memset(&words, 0, sizeof(words));
	words.count = (size_t)strtoull(field(&cursor), NULL, 10);
	(void)decode_hex(field(&cursor), (uint8_t *)words.words,
	    sizeof(words.words));
	if (!erx_console_reply_read(&words, &reply)) {
		printf("reply refused\n");
		return;
	}
	printf("reply %" PRIu64 " %zu\n", reply.lost, reply.length);
	for (offset = 0; erx_console_reply_next_line(&reply, &offset, &line);) {
		if (offset > reply.length)
			fail("the reader's offset passed the reply");
		printf("line");
		print_bytes(line.bytes, line.length);
		printf("\n");
	}
	printf("end\n");
}

int
main(int argc, char **argv)
{
	static char line[DRIVER_LINE_MAX];
	erx_console_loss_text_t loss;
	char *cursor, *name;
	FILE *commands;

	if (argc != 2 || (commands = fopen(argv[1], "r")) == NULL)
		fail("usage: console_ring_driver COMMANDS");
	while (fgets(line, sizeof(line), commands) != NULL) {
		line[strcspn(line, "\n")] = '\0';
		cursor = line;
		name = field(&cursor);
		if (strcmp(name, "reset") == 0) {
			memset(&driver_ring, 0, sizeof(driver_ring));
			if (*cursor != '\0')
				driver_ring.tail = driver_ring.open = driver_ring.head =
				    (uint32_t)strtoul(field(&cursor), NULL, 10);
			printf("reset\n");
		} else if (strcmp(name, "save") == 0)
			driver_saved[saved_slot(&cursor)] = driver_ring;
		else if (strcmp(name, "restore") == 0)
			driver_ring = driver_saved[saved_slot(&cursor)];
		else if (strcmp(name, "verbose") == 0)
			driver_verbose = strcmp(field(&cursor), "1") == 0;
		else if (strcmp(name, "write") == 0)
			command_write(cursor);
		else if (strcmp(name, "take") == 0)
			command_take();
		else if (strcmp(name, "close") == 0)
			printf("close %d\n", erx_console_ring_close(&driver_ring));
		else if (strcmp(name, "drain") == 0)
			command_drain(*cursor == '1');
		else if (strcmp(name, "state") == 0)
			command_state();
		else if (strcmp(name, "reply") == 0)
			command_reply(cursor);
		else if (strcmp(name, "loss") == 0) {
			loss = erx_console_loss_text(strtoull(field(&cursor),
			    NULL, 10));
			printf("loss %.*s\n", (int)loss.length, loss.bytes);
		} else
			fail("unknown command");
	}
	fclose(commands);
	return (0);
}
