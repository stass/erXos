/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_CONSOLE_RING_H
#define ERX_CORE_CONSOLE_RING_H

/*
 * The kernel's ring console on Fiasco (docs/design-fiasco.md, "The kernel's
 * lines"): the route every line the kernel prints takes, the ring that holds
 * those lines once the log service has taken the log, the reply a take
 * hands the root, and the root's reader of that reply. Fiasco's glue holds
 * one erx_console_ring_t and calls the core under the printf lock, which
 * serializes every call; the root links the reader. The core reads no
 * hardware and holds no state of its own.
 *
 * Two rules give the rest. A line leaves the ring only whole: a line that
 * does not fit is taken back and counted, and what follows it is dropped
 * through its newline, so a loss is always one whole line, counted once.
 * And the route closes before a stop prints: closed is final, and the close
 * is the one way the ring's lines reach the UART.
 *
 * This header is C and C++: the glue in fiasco/kernel/src/erx includes it.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* What the ring holds; it never overwrites a byte it holds. */
#define ERX_CONSOLE_RING_BYTES		4096
/*
 * A take's reply is Fiasco's message words, L4_UTCB_GENERIC_DATA_SIZE of
 * them, which the glue asserts: the lines lost, the bytes that follow, then
 * the bytes in memory order.
 */
#define ERX_CONSOLE_RING_REPLY_WORDS	63
#define ERX_CONSOLE_RING_REPLY_HEADER	2
#define ERX_CONSOLE_RING_REPLY_BYTES \
	((ERX_CONSOLE_RING_REPLY_WORDS - ERX_CONSOLE_RING_REPLY_HEADER) * 8)
/* The longest line, its carriage return and newline included: one reply. */
#define ERX_CONSOLE_RING_LINE_MAX	ERX_CONSOLE_RING_REPLY_BYTES
/* What opens every kernel line the log or the close writes. */
#define ERX_CONSOLE_RING_LABEL		"fiasco: "
/* "N kernel lines lost" for any 64-bit N. */
#define ERX_CONSOLE_LOSS_TEXT_MAX	40
/* One piece of the close's output; a piece holds the whole loss line. */
#define ERX_CONSOLE_DRAIN_BYTES		128

/* Where the kernel's lines go. All zeros is uart, a ring console at boot. */
typedef enum erx_console_route {
	ERX_CONSOLE_ROUTE_UART = 0,	/* straight to the UART, as upstream */
	ERX_CONSOLE_ROUTE_RING,		/* into the ring, for the root's takes */
	ERX_CONSOLE_ROUTE_CLOSED	/* straight to the UART, for good */
} erx_console_route_t;

/*
 * The ring console. All zeros is the route uart and an empty ring, so a
 * zeroed static one needs no initialization. Only kernel/core/console_ring.c
 * changes the members. tail, open and head are byte positions that
 * only grow, modulo 2^32; a position's offset in bytes is its low bits.
 * tail..open holds whole lines, each ending in a newline, and open..head the
 * line still open.
 */
typedef struct erx_console_ring {
	uint32_t		tail;		/* the oldest byte held */
	uint32_t		open;		/* where the open line starts */
	uint32_t		head;		/* where the next byte goes */
	uint64_t		lost;		/* lines lost, not yet reported */
	erx_console_route_t	route;
	bool			dropping;	/* dropping through the next newline */
	bool			uart_line_open;	/* the UART has a line's start */
	bool			drain_in_line;	/* the close wrote a line's label */
	uint8_t			bytes[ERX_CONSOLE_RING_BYTES];
} erx_console_ring_t;

/*
 * A take's reply as it lies in the caller's message words. count is how
 * many of the words the reply uses, the message tag's word count.
 */
typedef struct erx_console_reply_words {
	uint64_t	words[ERX_CONSOLE_RING_REPLY_WORDS];
	size_t		count;
} erx_console_reply_words_t;

/* A reply the root has checked, in its own memory. */
typedef struct erx_console_reply {
	uint64_t	lost;
	size_t		length;
	uint8_t		bytes[ERX_CONSOLE_RING_REPLY_BYTES];
} erx_console_reply_t;

/* One line of a reply, without its carriage return and newline. */
typedef struct erx_console_line {
	const uint8_t	*bytes;
	size_t		length;
} erx_console_line_t;

/* One piece of the close's output. */
typedef struct erx_console_drain {
	char	bytes[ERX_CONSOLE_DRAIN_BYTES];
} erx_console_drain_t;

/* "N kernel lines lost", the loss line's text after its label. */
typedef struct erx_console_loss_text {
	char	bytes[ERX_CONSOLE_LOSS_TEXT_MAX];
	size_t	length;
} erx_console_loss_text_t;

/*
 * The ring console's write, every byte the kernel prints. Returns true
 * under uart and closed, where the caller writes the whole text to the
 * UART, and false under ring, where the bytes join the ring, all but the
 * rest of a dropped line through its newline, and nothing goes to the UART.
 */
bool erx_console_ring_write(erx_console_ring_t *ring, const void *text,
    size_t length);

/*
 * Vlog operation 4. Under closed fills an empty reply and changes nothing,
 * so the close's drain alone hands out what the ring holds. Otherwise moves
 * uart to ring, dropping the rest of a line the UART had started, then
 * fills the reply with the lines lost since the last take and as many of
 * the ring's whole lines as fit, which leave the ring; the open line stays.
 */
void erx_console_ring_take(erx_console_ring_t *ring,
    erx_console_reply_words_t *reply);

/*
 * Vlog operation 5, and the head of every stop's report. Moves any route to
 * closed, keeping a line open in the ring as the ring's last line, which the
 * drain writes out with the others, and ends any drop, so the stop's report
 * that follows reaches the UART whole; the rest of the open line, if it
 * arrives after the close, goes to the UART raw. Returns whether this call
 * closed it: only then does the caller
 * write the ring out, through erx_console_ring_drain, so a stop inside that
 * write finds the route closed and its close does nothing.
 */
bool erx_console_ring_close(erx_console_ring_t *ring);

/*
 * The close's output, one piece at a time: the loss line if lines were
 * lost, then each non-empty line of the ring, oldest first, the line the
 * close kept open last, as
 * "fiasco: ", the line without its carriage return and newline through
 * erx_log_escape, and a carriage return and newline. A piece ends on a whole
 * token. Returns the piece's length, 0 once everything is written or while
 * the route is not closed.
 */
size_t erx_console_ring_drain(erx_console_ring_t *ring,
    erx_console_drain_t *piece);

/*
 * The root's reader of a take's reply, copied out of its message words:
 * refuses a reply whose count or byte length the words cannot hold.
 */
bool erx_console_reply_read(const erx_console_reply_words_t *words,
    erx_console_reply_t *reply);

/*
 * The next non-empty line of a reply at *offset, which moves past it: the
 * bytes up to the next newline or the reply's end, without the newline or
 * one carriage return before it. Returns false at the reply's end.
 */
bool erx_console_reply_next_line(const erx_console_reply_t *reply,
    size_t *offset, erx_console_line_t *line);

/* The loss line's text, which the close and the root's record share. */
erx_console_loss_text_t erx_console_loss_text(uint64_t lost);

#endif /* ERX_CORE_CONSOLE_RING_H */
