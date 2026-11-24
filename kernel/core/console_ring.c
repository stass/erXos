/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The ring console's core (docs/design-fiasco.md, "The kernel's lines").
 *
 * Bytes enter the ring only through console_ring_append, which only takes
 * a segment that leaves the ring within its size and the open line within
 * ERX_CONSOLE_RING_LINE_MAX; anything else goes through console_ring_lose,
 * the one place a line is taken back and counted. So tail..open is always
 * whole lines of at most ERX_CONSOLE_RING_LINE_MAX bytes each, which is what
 * the take and the drain rely on when they walk it. A drop is armed only
 * on the ring route and the close disarms it, so a write on any other route
 * goes to the UART whole.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/console_ring.h"
#include "erx/log.h"
#include "erx/terminal_ascii.h"

#define CONSOLE_RING_MASK	((uint32_t)ERX_CONSOLE_RING_BYTES - 1)
#define CONSOLE_LITERAL_BYTES(literal)	(sizeof(literal) - 1)
#define CONSOLE_LABEL_BYTES	CONSOLE_LITERAL_BYTES(ERX_CONSOLE_RING_LABEL)
#define CONSOLE_LOSS_TAIL	" kernel lines lost"
#define CONSOLE_LINE_END	"\r\n"
/* What erx_log_escape writes for a byte that is not printable ASCII. */
#define CONSOLE_TOKEN_BYTES	(CONSOLE_LITERAL_BYTES(ERX_TERMINAL_KERNEL_TOKEN_PREFIX) + \
				    ERX_TERMINAL_KERNEL_TOKEN_DIGITS)
/* The decimal digits of a 64-bit value. */
#define CONSOLE_NUMBER_MAX	20

/* Reply bytes lie in the message words in memory order, read the same way. */
_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
    "reply bytes are read as they lie in the message words");
_Static_assert((ERX_CONSOLE_RING_BYTES & (ERX_CONSOLE_RING_BYTES - 1)) == 0,
    "a ring offset is a position's low bits");
_Static_assert(ERX_CONSOLE_RING_LINE_MAX <= ERX_CONSOLE_RING_BYTES,
    "the ring holds the longest line");
/* So a whole line, escaped at a token a byte, is never cut in the log. */
_Static_assert(CONSOLE_LABEL_BYTES + CONSOLE_TOKEN_BYTES *
    ERX_CONSOLE_RING_LINE_MAX <= ERX_LOG_TEXT_MAX,
    "a kernel line's record fits a record's text");
_Static_assert(CONSOLE_NUMBER_MAX + CONSOLE_LITERAL_BYTES(CONSOLE_LOSS_TAIL) <=
    ERX_CONSOLE_LOSS_TEXT_MAX, "the loss text holds any count");
/* So a piece always holds the whole loss line, or a label, or a token. */
_Static_assert(CONSOLE_LABEL_BYTES + ERX_CONSOLE_LOSS_TEXT_MAX +
    CONSOLE_LITERAL_BYTES(CONSOLE_LINE_END) <= ERX_CONSOLE_DRAIN_BYTES,
    "a drain piece holds the loss line");

static void console_ring_append(erx_console_ring_t *, const uint8_t *,
    uint32_t);
static uint8_t console_ring_byte(const erx_console_ring_t *, uint32_t);
static size_t console_ring_drop(erx_console_ring_t *, const uint8_t *, size_t);
static uint32_t console_ring_line_end(const erx_console_ring_t *, uint32_t);
static void console_ring_lose(erx_console_ring_t *);
static void console_ring_take_back(erx_console_ring_t *);
static size_t console_segment(const uint8_t *, size_t);
static bool console_piece_add(erx_console_drain_t *, size_t *, const void *,
    size_t);

static uint8_t
console_ring_byte(const erx_console_ring_t *ring, uint32_t position)
{
	return (ring->bytes[position & CONSOLE_RING_MASK]);
}

/* The open line's bytes come back off the tail, and the loss is counted once. */
static void
console_ring_take_back(erx_console_ring_t *ring)
{
	ring->head = ring->open;
	if (ring->lost != UINT64_MAX)
		ring->lost++;
}

/*
 * The ring route's one way a line is lost: the open line is taken back and
 * the rest of the line, through its newline, is dropped. Only a write and a
 * take on the ring route call it, so a drop is only ever armed there.
 */
static void
console_ring_lose(erx_console_ring_t *ring)
{
	console_ring_take_back(ring);
	ring->dropping = true;
}

/*
 * Drops a dropped line's rest from text, through its newline. Returns how
 * many bytes it dropped, and ends the drop at the newline.
 */
static size_t
console_ring_drop(erx_console_ring_t *ring, const uint8_t *text, size_t length)
{
	size_t at;

	if (!ring->dropping)
		return (0);
	for (at = 0; at < length; at++) {
		if (text[at] == '\n') {
			ring->dropping = false;
			return (at + 1);
		}
	}
	return (length);
}

/* Appends a segment the caller checked fits; a newline at its end closes the line. */
static void
console_ring_append(erx_console_ring_t *ring, const uint8_t *text,
    uint32_t length)
{
	uint32_t at;

	for (at = 0; at < length; at++)
		ring->bytes[(ring->head + at) & CONSOLE_RING_MASK] = text[at];
	ring->head += length;
	if (length > 0 && text[length - 1] == '\n')
		ring->open = ring->head;
}

/* The bytes of text through its first newline, or all of them. */
static size_t
console_segment(const uint8_t *text, size_t length)
{
	size_t at;

	for (at = 0; at < length; at++)
		if (text[at] == '\n')
			return (at + 1);
	return (length);
}

bool
erx_console_ring_write(erx_console_ring_t *ring, const void *text,
    size_t length)
{
	const uint8_t *in;
	size_t at, segment;

	in = text;
	if (ring->route != ERX_CONSOLE_ROUTE_RING) {
		if (length > 0)
			ring->uart_line_open = in[length - 1] != '\n';
		return (true);
	}

	at = console_ring_drop(ring, in, length);
	while (at < length) {
		segment = console_segment(in + at, length - at);
		/* Both sides stay within the ring, so neither sum can wrap. */
		if (segment > ERX_CONSOLE_RING_BYTES - (ring->head - ring->tail) ||
		    segment > ERX_CONSOLE_RING_LINE_MAX - (ring->head - ring->open)) {
			console_ring_lose(ring);
			at += console_ring_drop(ring, in + at, length - at);
			continue;
		}
		console_ring_append(ring, in + at, (uint32_t)segment);
		at += segment;
	}
	return (false);
}

/*
 * The position just past the newline of the whole line that starts at
 * start, which must be before ring->open.
 */
static uint32_t
console_ring_line_end(const erx_console_ring_t *ring, uint32_t start)
{
	uint32_t at;

	for (at = start; console_ring_byte(ring, at) != '\n'; at++)
		;
	return (at + 1);
}

void
erx_console_ring_take(erx_console_ring_t *ring,
    erx_console_reply_words_t *reply)
{
	uint8_t *out;
	uint32_t at, end, length, next;

	/* Every word, so no word the reply leaves unused holds stale bytes. */
	for (at = 0; at < ERX_CONSOLE_RING_REPLY_WORDS; at++)
		reply->words[at] = 0;
	reply->count = ERX_CONSOLE_RING_REPLY_HEADER;
	/* After the close its drain alone hands out what the ring holds. */
	if (ring->route == ERX_CONSOLE_ROUTE_CLOSED)
		return;
	if (ring->route == ERX_CONSOLE_ROUTE_UART) {
		ring->route = ERX_CONSOLE_ROUTE_RING;
		if (ring->uart_line_open)
			console_ring_lose(ring);
		ring->uart_line_open = false;
	}

	for (end = ring->tail; end != ring->open; end = next) {
		next = console_ring_line_end(ring, end);
		if (next - ring->tail > ERX_CONSOLE_RING_REPLY_BYTES)
			break;
	}
	length = end - ring->tail;

	out = (uint8_t *)&reply->words[ERX_CONSOLE_RING_REPLY_HEADER];
	reply->words[0] = ring->lost;
	reply->words[1] = length;
	reply->count += (length + 7) / 8;
	for (at = 0; at < length; at++)
		out[at] = console_ring_byte(ring, ring->tail + at);
	ring->tail = end;
	ring->lost = 0;
}

bool
erx_console_ring_close(erx_console_ring_t *ring)
{
	if (ring->route == ERX_CONSOLE_ROUTE_CLOSED)
		return (false);
	if (ring->route == ERX_CONSOLE_ROUTE_RING && ring->head != ring->open)
		console_ring_take_back(ring);
	/* A drop an earlier loss armed ends: the report reaches the UART whole. */
	ring->dropping = false;
	ring->route = ERX_CONSOLE_ROUTE_CLOSED;
	return (true);
}

/* Adds bytes to a piece only whole; false, with nothing added, if they do not fit. */
static bool
console_piece_add(erx_console_drain_t *piece, size_t *used, const void *bytes,
    size_t length)
{
	if (length > sizeof(piece->bytes) - *used)
		return (false);
	__builtin_memcpy(piece->bytes + *used, bytes, length);
	*used += length;
	return (true);
}

/*
 * The drain walks the ring's whole lines from the tail, which moves past
 * each byte once its token is in the piece, so a piece cut short resumes
 * where it stopped. drain_in_line says the line's label is out already.
 * An empty piece always holds the loss line, a label and a token, so only
 * the end of the ring ends a drain.
 */
size_t
erx_console_ring_drain(erx_console_ring_t *ring, erx_console_drain_t *piece)
{
	erx_console_loss_text_t loss;
	erx_log_escape_result_t escaped;
	uint32_t body_end, end;
	size_t used;
	uint8_t byte;

	if (ring->route != ERX_CONSOLE_ROUTE_CLOSED)
		return (0);
	used = 0;
	if (ring->lost > 0) {
		loss = erx_console_loss_text(ring->lost);
		(void)console_piece_add(piece, &used, ERX_CONSOLE_RING_LABEL,
		    CONSOLE_LABEL_BYTES);
		(void)console_piece_add(piece, &used, loss.bytes, loss.length);
		(void)console_piece_add(piece, &used, CONSOLE_LINE_END,
		    CONSOLE_LITERAL_BYTES(CONSOLE_LINE_END));
		ring->lost = 0;
	}

	while (ring->tail != ring->open) {
		end = console_ring_line_end(ring, ring->tail);
		body_end = end - 1;
		if (body_end != ring->tail &&
		    console_ring_byte(ring, body_end - 1) == '\r')
			body_end--;
		if (!ring->drain_in_line) {
			if (body_end == ring->tail) {
				ring->tail = end;	/* an empty line */
				continue;
			}
			if (!console_piece_add(piece, &used,
			    ERX_CONSOLE_RING_LABEL, CONSOLE_LABEL_BYTES))
				break;
			ring->drain_in_line = true;
		}
		for (; ring->tail != body_end; ring->tail++) {
			byte = console_ring_byte(ring, ring->tail);
			escaped = erx_log_escape(&byte, 1, piece->bytes + used,
			    sizeof(piece->bytes) - used);
			if (escaped.consumed == 0)
				return (used);
			used += escaped.written;
		}
		if (!console_piece_add(piece, &used, CONSOLE_LINE_END,
		    CONSOLE_LITERAL_BYTES(CONSOLE_LINE_END)))
			break;
		ring->tail = end;
		ring->drain_in_line = false;
	}
	return (used);
}

erx_console_loss_text_t
erx_console_loss_text(uint64_t lost)
{
	erx_console_loss_text_t text;
	char digits[CONSOLE_NUMBER_MAX];
	size_t at;

	at = sizeof(digits);
	do {
		digits[--at] = (char)('0' + lost % 10);
		lost /= 10;
	} while (lost != 0);
	text.length = sizeof(digits) - at;
	__builtin_memcpy(text.bytes, digits + at, text.length);
	__builtin_memcpy(text.bytes + text.length, CONSOLE_LOSS_TAIL,
	    CONSOLE_LITERAL_BYTES(CONSOLE_LOSS_TAIL));
	text.length += CONSOLE_LITERAL_BYTES(CONSOLE_LOSS_TAIL);
	return (text);
}

/*
 * The words came from the kernel, but they are checked once here, so a
 * count or a length they cannot hold never reaches the copy.
 */
bool
erx_console_reply_read(const erx_console_reply_words_t *words,
    erx_console_reply_t *reply)
{
	uint64_t length;

	if (words->count < ERX_CONSOLE_RING_REPLY_HEADER ||
	    words->count > ERX_CONSOLE_RING_REPLY_WORDS)
		return (false);
	length = words->words[1];
	if (length > (words->count - ERX_CONSOLE_RING_REPLY_HEADER) * 8)
		return (false);
	reply->lost = words->words[0];
	reply->length = (size_t)length;
	__builtin_memcpy(reply->bytes,
	    &words->words[ERX_CONSOLE_RING_REPLY_HEADER], reply->length);
	return (true);
}

bool
erx_console_reply_next_line(const erx_console_reply_t *reply, size_t *offset,
    erx_console_line_t *line)
{
	size_t at, body, start;

	for (start = *offset; start < reply->length; start = at) {
		for (at = start; at < reply->length && reply->bytes[at] != '\n';
		    at++)
			;
		body = at - start;
		if (at < reply->length)
			at++;	/* past the newline */
		if (body > 0 && reply->bytes[start + body - 1] == '\r')
			body--;
		if (body > 0) {
			*offset = at;
			*line = (erx_console_line_t){
				.bytes = reply->bytes + start,
				.length = body,
			};
			return (true);
		}
	}
	*offset = reply->length;
	return (false);
}
