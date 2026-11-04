/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Text is built in an erx_log_text_t, which only erx_log_escape writes, and
 * enters the ring only through erx_log_raw_append, which only this file can
 * reach. So a record cannot hold a byte erx_log_escape would not pass,
 * however its text was assembled.
 *
 * The ring holds records in the form a reader receives them: an
 * erx_log_record_t, the text, and zero padding to 8 bytes, each record
 * running on across the ring's end. Its bytes come only from this file, so
 * the walks below trust the lengths they read from it.
 */

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/log.h"
#include "erx/terminal_ascii.h"

#define ERX_LOG_NS_PER_S	UINT64_C(1000000000)
#define ERX_LOG_NS_PER_US	UINT64_C(1000)
#define ERX_LOG_RING_MASK	((uint64_t)ERX_LOG_RING_BYTES - 1)
#define ERX_LOG_PAD_MASK	(ERX_LOG_RECORD_ALIGN - 1)
#define ERX_LOG_LITERAL_BYTES(literal)	(sizeof(literal) - 1)
#define ERX_LOG_TOKEN_BYTES	(ERX_LOG_LITERAL_BYTES(ERX_TERMINAL_KERNEL_TOKEN_PREFIX) + \
				    ERX_TERMINAL_KERNEL_TOKEN_DIGITS)
/* The decimal digits of a 64-bit value. */
#define ERX_LOG_NUMBER_MAX	20
/* The parts of a debug line's prefix: "space N dropped N: ". */
#define ERX_LOG_SPACE		"space "
#define ERX_LOG_DROPPED		" dropped "
#define ERX_LOG_PREFIX_END	": "
#define ERX_LOG_DEBUG_PREFIX_MAX (ERX_LOG_LITERAL_BYTES(ERX_LOG_SPACE) + \
				    ERX_LOG_NUMBER_MAX + \
				    ERX_LOG_LITERAL_BYTES(ERX_LOG_DROPPED) + \
				    ERX_LOG_NUMBER_MAX + \
				    ERX_LOG_LITERAL_BYTES(ERX_LOG_PREFIX_END))
/* The parts of a rendered line around its text. */
#define ERX_LOG_MICRO_DIGITS	6
#define ERX_LOG_TRUNCATED_MARK	" [truncated]"
#define ERX_LOG_LINE_OVERHEAD	(ERX_LOG_LITERAL_BYTES("#") + \
				    ERX_LOG_NUMBER_MAX + \
				    ERX_LOG_LITERAL_BYTES(" ") + \
				    ERX_LOG_NUMBER_MAX + \
				    ERX_LOG_LITERAL_BYTES(".") + \
				    ERX_LOG_MICRO_DIGITS + \
				    ERX_LOG_LITERAL_BYTES(" ") + \
				    ERX_LOG_LITERAL_BYTES("warning") + \
				    ERX_LOG_LITERAL_BYTES(" ") + \
				    ERX_LOG_LITERAL_BYTES(ERX_LOG_TRUNCATED_MARK) + \
				    ERX_LOG_LITERAL_BYTES("\n"))
#define ERX_LOG_BAD_FORMAT	"<bad format>"

/*
 * A window and the ring hold wire records as they lie in memory, and a UTCB
 * word's bytes in memory are the bytes in the order the caller put them.
 */
_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
    "wire records and UTCB words are read as they lie in memory");
_Static_assert((ERX_LOG_RING_BYTES & (ERX_LOG_RING_BYTES - 1)) == 0,
    "a ring offset is a position's low bits");
_Static_assert((ERX_LOG_TEXT_MAX & ERX_LOG_PAD_MASK) == 0,
    "the longest text needs no padding");
/* So a line from erx_debug_log is never truncated. */
_Static_assert(ERX_LOG_DEBUG_PREFIX_MAX + ERX_LOG_TOKEN_BYTES *
    ERX_UTCB_BYTES_MAX <= ERX_LOG_TEXT_MAX, "a whole debug line fits a record");
/* So every length erx_log_debug accepts is within the message words. */
_Static_assert(ERX_UTCB_BYTES_MAX == ERX_MSG_WORDS * sizeof(uint64_t),
    "the UTCB's text is its message words");
/* So the longest record fits an empty rate window, and no line starves. */
_Static_assert(ERX_LOG_RECORD_MAX <= ERX_LOG_RATE_BYTES,
    "the rate window holds the longest record");
_Static_assert(ERX_LOG_RECORD_MAX <= ERX_LOG_RING_BYTES,
    "the ring holds the longest record");
_Static_assert(ERX_LOG_LINE_MAX >= ERX_LOG_TEXT_MAX + ERX_LOG_LINE_OVERHEAD,
    "a checked record's line fits");
_Static_assert(sizeof(int) == 4, "the %d and %x width");
_Static_assert(sizeof(long) == 8 && sizeof(long long) == 8 &&
    sizeof(size_t) == 8, "the wide conversions' width");

/* Text under construction: only erx_log_escape fills bytes. */
typedef struct erx_log_text {
	char	*bytes;
	size_t	capacity;
	size_t	length;
	bool	truncated;
} erx_log_text_t;

/* An integer conversion's size modifier: none, l, ll or z. */
typedef enum erx_log_size {
	ERX_LOG_SIZE_INT,
	ERX_LOG_SIZE_LONG,
	ERX_LOG_SIZE_LONG_LONG,
	ERX_LOG_SIZE_SIZE_T
} erx_log_size_t;

/* One conversion of a format string, as read past its '%'. */
typedef struct erx_log_spec {
	erx_log_size_t	size;
	size_t		consumed;	/* format bytes it takes up */
	char		conversion;
	bool		star_precision;	/* it said .* */
} erx_log_spec_t;

static void erx_log_arg_string(erx_log_text_t *, const char *, int);
static int64_t erx_log_arg_signed(va_list *, erx_log_size_t);
static uint64_t erx_log_arg_unsigned(va_list *, erx_log_size_t);
static bool erx_log_conversion(erx_log_text_t *, erx_log_spec_t, va_list *);
static void erx_log_debug_prefix(erx_log_text_t *, uint64_t, uint64_t);
static void erx_log_debug_utcb(erx_log_text_t *, const erx_utcb_t *, size_t);
static bool erx_log_level_known(erx_log_level_t);
static const char *erx_log_level_name(erx_log_level_t);
static void erx_log_raw_append(erx_log_t *, const erx_log_text_t *,
    erx_log_level_t, uint64_t);
static void erx_log_raw_header(const erx_log_t *, uint64_t, erx_log_record_t *);
static void erx_log_raw_load(const erx_log_t *, uint64_t, void *, size_t);
static void erx_log_raw_store(erx_log_t *, uint64_t, const void *, size_t);
static size_t erx_log_record_bytes(size_t);
static erx_log_spec_t erx_log_spec_read(const char *);
static void erx_log_text_add(erx_log_text_t *, const void *, size_t);
static void erx_log_text_mark_bad(erx_log_text_t *);
static void erx_log_text_number(erx_log_text_t *, uint64_t, uint32_t, uint32_t);
static bool erx_log_text_open(erx_log_t *, erx_log_text_t *);
static erx_log_text_t erx_log_text_over(char *, size_t);
static void erx_log_text_string(erx_log_text_t *, const char *);

erx_log_escape_result_t
erx_log_escape(const void *text, size_t length, char *dst, size_t capacity)
{
	static const char prefix[] = ERX_TERMINAL_KERNEL_TOKEN_PREFIX;
	static const char hex[] = "0123456789ABCDEF";
	const uint8_t *in;
	size_t written, consumed;
	uint32_t digit;
	uint8_t byte;

	in = text;
	written = 0;
	for (consumed = 0; consumed < length; consumed++) {
		byte = in[consumed];
		if (erx_terminal_ascii_safe[byte] != 0) {
			if (written == capacity)
				break;
			dst[written++] = (char)byte;
			continue;
		}
		if (capacity - written < ERX_LOG_TOKEN_BYTES)
			break;
		__builtin_memcpy(dst + written, prefix, sizeof(prefix) - 1);
		written += sizeof(prefix) - 1;
		for (digit = ERX_TERMINAL_KERNEL_TOKEN_DIGITS; digit > 0; digit--)
			dst[written++] = hex[(byte >> ((digit - 1) * 4)) & 0xf];
	}
	return ((erx_log_escape_result_t){
		.consumed = consumed,
		.written = written,
	});
}

static erx_log_text_t
erx_log_text_over(char *bytes, size_t capacity)
{
	return ((erx_log_text_t){ .bytes = bytes, .capacity = capacity });
}

/*
 * Opens a new record's text, or refuses when no sequence number is left. A
 * text for the ring comes only from here, so whatever reaches
 * erx_log_raw_append has a number to take.
 */
static bool
erx_log_text_open(erx_log_t *log, erx_log_text_t *text)
{
	if (log->next_seq == UINT64_MAX)
		return (false);
	*text = erx_log_text_over(log->raw_text, sizeof(log->raw_text));
	return (true);
}

/*
 * Adds escaped bytes. After the first bytes that do not fit it adds nothing
 * more, so a truncated text is a prefix of the whole one.
 */
static void
erx_log_text_add(erx_log_text_t *text, const void *bytes, size_t length)
{
	erx_log_escape_result_t result;

	if (text->truncated)
		return;
	result = erx_log_escape(bytes, length, text->bytes + text->length,
	    text->capacity - text->length);
	text->length += result.written;
	text->truncated = result.consumed < length;
}

static void
erx_log_text_string(erx_log_text_t *text, const char *string)
{
	for (; *string != '\0' && !text->truncated; string++)
		erx_log_text_add(text, string, 1);
}

/* Adds a value in base 10 or 16, in at least min_digits digits. */
static void
erx_log_text_number(erx_log_text_t *text, uint64_t value, uint32_t base,
    uint32_t min_digits)
{
	char digits[ERX_LOG_NUMBER_MAX];
	size_t at;

	at = sizeof(digits);
	do {
		digits[--at] = "0123456789abcdef"[value % base];
		value /= base;
	} while (value != 0);
	while (sizeof(digits) - at < min_digits && at > 0)
		digits[--at] = '0';
	erx_log_text_add(text, digits + at, sizeof(digits) - at);
}

/* A record's bytes in the ring and in a window, its padding included. */
static size_t
erx_log_record_bytes(size_t text_length)
{
	return (ERX_LOG_RECORD_SIZE + ((text_length + ERX_LOG_PAD_MASK) &
	    ~(size_t)ERX_LOG_PAD_MASK));
}

static void
erx_log_raw_store(erx_log_t *log, uint64_t position, const void *bytes,
    size_t length)
{
	size_t offset, first;

	offset = (size_t)(position & ERX_LOG_RING_MASK);
	first = sizeof(log->raw_ring) - offset;
	if (first > length)
		first = length;
	__builtin_memcpy(log->raw_ring + offset, bytes, first);
	__builtin_memcpy(log->raw_ring, (const uint8_t *)bytes + first,
	    length - first);
}

static void
erx_log_raw_load(const erx_log_t *log, uint64_t position, void *bytes,
    size_t length)
{
	size_t offset, first;

	offset = (size_t)(position & ERX_LOG_RING_MASK);
	first = sizeof(log->raw_ring) - offset;
	if (first > length)
		first = length;
	__builtin_memcpy(bytes, log->raw_ring + offset, first);
	__builtin_memcpy((uint8_t *)bytes + first, log->raw_ring, length - first);
}

static void
erx_log_raw_header(const erx_log_t *log, uint64_t position,
    erx_log_record_t *record)
{
	erx_log_raw_load(log, position, record, ERX_LOG_RECORD_SIZE);
}

/*
 * The one way into the ring: drops the oldest records until the new one
 * fits, then writes it. text came from erx_log_text_open, so it was filled
 * through erx_log_text_add and a sequence number is left for it.
 */
static void
erx_log_raw_append(erx_log_t *log, const erx_log_text_t *text,
    erx_log_level_t level, uint64_t now_ns)
{
	static const uint8_t padding[ERX_LOG_RECORD_ALIGN] = { 0 };
	erx_log_record_t oldest, record;
	size_t total;

	total = erx_log_record_bytes(text->length);
	while (sizeof(log->raw_ring) - (log->head - log->tail) < total) {
		erx_log_raw_header(log, log->tail, &oldest);
		log->tail += erx_log_record_bytes(oldest.length);
		log->oldest_seq++;
	}

	record = (erx_log_record_t){
		.seq = log->next_seq,
		.time_ns = now_ns,
		.level = level,
		.flags = text->truncated ? ERX_LOG_RECORD_TRUNCATED : 0,
		.length = (uint32_t)text->length,
	};
	erx_log_raw_store(log, log->head, &record, ERX_LOG_RECORD_SIZE);
	erx_log_raw_store(log, log->head + ERX_LOG_RECORD_SIZE, text->bytes,
	    text->length);
	erx_log_raw_store(log, log->head + ERX_LOG_RECORD_SIZE + text->length,
	    padding, total - ERX_LOG_RECORD_SIZE - text->length);
	log->head += total;
	log->next_seq++;
}

/*
 * A window of one second opens at the first line after the last one ended.
 * A clock reading before the window's start stays in the window, so nothing
 * but time passing opens a new one.
 */
erx_log_rate_step_t
erx_log_rate_admit(const erx_log_rate_t *rate, uint64_t now_ns, uint32_t cost)
{
	erx_log_rate_step_t step;

	step.next = *rate;
	if (now_ns >= rate->window_start_ns &&
	    now_ns - rate->window_start_ns >= ERX_LOG_NS_PER_S) {
		step.next.window_start_ns = now_ns;
		step.next.window_bytes = 0;
	}

	step.admit = cost <= ERX_LOG_RATE_BYTES - step.next.window_bytes;
	if (step.admit) {
		step.next.window_bytes += cost;
		step.next.dropped = 0;
	} else if (step.next.dropped != UINT64_MAX) {
		step.next.dropped++;
	}
	return (step);
}

/* What opens a debug line: the kernel's, ahead of anything the space wrote. */
static void
erx_log_debug_prefix(erx_log_text_t *text, uint64_t space, uint64_t dropped)
{
	erx_log_text_string(text, ERX_LOG_SPACE);
	erx_log_text_number(text, space, 10, 1);
	if (dropped != 0) {
		erx_log_text_string(text, ERX_LOG_DROPPED);
		erx_log_text_number(text, dropped, 10, 1);
	}
	erx_log_text_string(text, ERX_LOG_PREFIX_END);
}

/*
 * Adds length bytes of the message words, which user mode can rewrite while
 * this runs: each word is loaded once, into kernel memory, before any byte
 * of it is looked at. length is at most ERX_UTCB_BYTES_MAX, which keeps every
 * index in range, so the load cannot fail.
 */
static void
erx_log_debug_utcb(erx_log_text_t *text, const erx_utcb_t *utcb, size_t length)
{
	uint64_t word;
	size_t index, part;

	for (index = 0; length > 0; index++) {
		word = 0;
		(void)erx_utcb_mr_load(utcb, index, &word);
		part = length < sizeof(word) ? length : sizeof(word);
		erx_log_text_add(text, &word, part);
		length -= part;
	}
}

/*
 * The text is built before the rate decision because a line costs what it
 * takes up once escaped, which only the words loaded here decide: charging
 * the raw length would let a line of control bytes fill the ring four times
 * as fast, and an empty line would cost nothing.
 */
erx_status_t
erx_log_debug(erx_log_t *log, erx_log_rate_t *rate, uint64_t space,
    uint64_t now_ns, const erx_utcb_t *utcb, erx_utcb_length_t len)
{
	erx_log_rate_step_t step;
	erx_log_text_t text;

	if (utcb == NULL || len.raw > ERX_UTCB_BYTES_MAX)
		return (ERX_EINVAL);
	if (!erx_log_text_open(log, &text))
		return (ERX_ELIMIT);

	erx_log_debug_prefix(&text, space, rate->dropped);
	erx_log_debug_utcb(&text, utcb, len.raw);

	step = erx_log_rate_admit(rate, now_ns,
	    (uint32_t)erx_log_record_bytes(text.length));
	*rate = step.next;
	if (step.admit)
		erx_log_raw_append(log, &text, ERX_LOG_LEVEL_DEBUG, now_ns);
	return (ERX_OK);
}

static bool
erx_log_level_known(erx_log_level_t level)
{
	switch (level) {
	case ERX_LOG_LEVEL_ERROR:
	case ERX_LOG_LEVEL_WARNING:
	case ERX_LOG_LEVEL_INFO:
	case ERX_LOG_LEVEL_DEBUG:
		return (true);
	default:
		return (false);
	}
}

/*
 * Reads [.*][l|ll|z]C from a format, past its '%'. Whether the combination
 * means anything is for erx_log_conversion to decide; a format ending inside
 * a conversion reads as conversion '\0'.
 */
static erx_log_spec_t
erx_log_spec_read(const char *format)
{
	erx_log_spec_t spec;
	const char *cursor;

	cursor = format;
	spec = (erx_log_spec_t){ .size = ERX_LOG_SIZE_INT };
	if (cursor[0] == '.' && cursor[1] == '*') {
		spec.star_precision = true;
		cursor += 2;
	}
	if (cursor[0] == 'l' && cursor[1] == 'l') {
		spec.size = ERX_LOG_SIZE_LONG_LONG;
		cursor += 2;
	} else if (cursor[0] == 'l') {
		spec.size = ERX_LOG_SIZE_LONG;
		cursor++;
	} else if (cursor[0] == 'z') {
		spec.size = ERX_LOG_SIZE_SIZE_T;
		cursor++;
	}
	spec.conversion = *cursor;
	if (*cursor != '\0')
		cursor++;
	spec.consumed = (size_t)(cursor - format);
	return (spec);
}

static uint64_t
erx_log_arg_unsigned(va_list *args, erx_log_size_t size)
{
	switch (size) {
	case ERX_LOG_SIZE_LONG:
		return (va_arg(*args, unsigned long));
	case ERX_LOG_SIZE_LONG_LONG:
		return (va_arg(*args, unsigned long long));
	case ERX_LOG_SIZE_SIZE_T:
		return (va_arg(*args, size_t));
	case ERX_LOG_SIZE_INT:
	default:
		return (va_arg(*args, unsigned int));
	}
}

static int64_t
erx_log_arg_signed(va_list *args, erx_log_size_t size)
{
	switch (size) {
	case ERX_LOG_SIZE_LONG:
		return (va_arg(*args, long));
	case ERX_LOG_SIZE_LONG_LONG:
		return (va_arg(*args, long long));
	case ERX_LOG_SIZE_SIZE_T:
		return ((int64_t)va_arg(*args, size_t));
	case ERX_LOG_SIZE_INT:
	default:
		return (va_arg(*args, int));
	}
}

/*
 * Adds a string argument, at most limit bytes when limit is not negative,
 * and stops at its end or once the text is full. It never reads the string
 * further than it needs.
 */
static void
erx_log_arg_string(erx_log_text_t *text, const char *string, int limit)
{
	int taken;

	if (string == NULL)
		string = "(null)";
	for (taken = 0; (limit < 0 || taken < limit) && string[taken] != '\0' &&
	    !text->truncated; taken++)
		erx_log_text_add(text, string + taken, 1);
}

/*
 * Formats one conversion from its argument. False means the conversion is
 * not one this log understands; the caller cannot tell how to step past its
 * argument, so nothing further can be read.
 */
static bool
erx_log_conversion(erx_log_text_t *text, erx_log_spec_t spec, va_list *args)
{
	const char *string;
	uint64_t magnitude;
	int64_t value;
	int limit;
	char byte;

	if (spec.star_precision && spec.conversion != 's')
		return (false);
	if (spec.size != ERX_LOG_SIZE_INT && spec.conversion != 'd' &&
	    spec.conversion != 'u' && spec.conversion != 'x')
		return (false);

	switch (spec.conversion) {
	case '%':
		erx_log_text_add(text, "%", 1);
		return (true);
	case 'c':
		byte = (char)va_arg(*args, int);
		erx_log_text_add(text, &byte, 1);
		return (true);
	case 's':
		limit = spec.star_precision ? va_arg(*args, int) : -1;
		string = va_arg(*args, const char *);
		if (spec.star_precision && limit < 0)
			return (false);
		erx_log_arg_string(text, string, limit);
		return (true);
	case 'u':
		erx_log_text_number(text, erx_log_arg_unsigned(args, spec.size),
		    10, 1);
		return (true);
	case 'x':
		erx_log_text_number(text, erx_log_arg_unsigned(args, spec.size),
		    16, 1);
		return (true);
	case 'd':
		value = erx_log_arg_signed(args, spec.size);
		magnitude = value < 0 ? UINT64_C(0) - (uint64_t)value :
		    (uint64_t)value;
		if (value < 0)
			erx_log_text_add(text, "-", 1);
		erx_log_text_number(text, magnitude, 10, 1);
		return (true);
	default:
		return (false);
	}
}

static void
erx_log_text_mark_bad(erx_log_text_t *text)
{
	erx_log_text_string(text, ERX_LOG_BAD_FORMAT);
	text->truncated = true;
}

erx_status_t
erx_log_format(erx_log_t *log, erx_log_level_t level, uint64_t now_ns,
    const char *format, ...)
{
	erx_log_spec_t spec;
	erx_log_text_t text;
	const char *cursor;
	size_t run;
	va_list args;

	if (!erx_log_level_known(level))
		return (ERX_EINVAL);
	if (!erx_log_text_open(log, &text))
		return (ERX_ELIMIT);

	va_start(args, format);
	for (cursor = format; *cursor != '\0' && !text.truncated;) {
		for (run = 0; cursor[run] != '\0' && cursor[run] != '%'; run++)
			;
		erx_log_text_add(&text, cursor, run);
		cursor += run;
		if (*cursor == '\0')
			break;

		spec = erx_log_spec_read(cursor + 1);
		cursor += 1 + spec.consumed;
		if (!erx_log_conversion(&text, spec, &args)) {
			erx_log_text_mark_bad(&text);
			break;
		}
	}
	va_end(args);

	erx_log_raw_append(log, &text, level, now_ns);
	return (ERX_OK);
}

erx_log_copy_result_t
erx_log_copy(const erx_log_t *log, uint64_t cursor, uint8_t *window,
    size_t window_size)
{
	erx_log_copy_result_t result;
	erx_log_record_t record;
	uint64_t seq, position;
	size_t total;

	result = (erx_log_copy_result_t){
		.status = ERX_EINVAL,
		.next_cursor = cursor,
	};
	if (window == NULL || window_size < ERX_LOG_RECORD_MAX ||
	    cursor > log->next_seq)
		return (result);

	/*
	 * A cursor older than the ring has lost what lay between it and the
	 * oldest record. Records differ in length, so finding the cursor's
	 * record walks the ring's headers from its oldest; a reader with
	 * nothing new has nothing to find.
	 */
	seq = cursor;
	if (seq < log->oldest_seq) {
		result.lost = log->oldest_seq - seq;
		seq = log->oldest_seq;
	}
	position = log->tail;
	for (uint64_t at = log->oldest_seq; at < seq && seq < log->next_seq;
	    at++) {
		erx_log_raw_header(log, position, &record);
		position += erx_log_record_bytes(record.length);
	}

	while (seq < log->next_seq) {
		erx_log_raw_header(log, position, &record);
		total = erx_log_record_bytes(record.length);
		if (window_size - result.written < total)
			break;
		erx_log_raw_load(log, position, window + result.written, total);
		result.written += total;
		result.records++;
		position += total;
		seq++;
	}

	result.status = ERX_OK;
	result.next_cursor = seq;
	return (result);
}

erx_log_next_t
erx_log_next_record(const uint8_t *window, size_t window_size, size_t *offset,
    char *text, erx_log_view_t *view)
{
	erx_log_record_t record;
	const uint8_t *padding;
	size_t at, padding_bytes, total;

	at = *offset;
	if (at > window_size || (at & ERX_LOG_PAD_MASK) != 0)
		return (ERX_LOG_NEXT_CORRUPT);
	if (at == window_size)
		return (ERX_LOG_NEXT_END);
	if (window_size - at < ERX_LOG_RECORD_SIZE)
		return (ERX_LOG_NEXT_CORRUPT);

	__builtin_memcpy(&record, window + at, ERX_LOG_RECORD_SIZE);
	if (!erx_log_level_known(record.level) ||
	    (record.flags & ~(uint32_t)ERX_LOG_RECORD_TRUNCATED) != 0 ||
	    record.reserved != 0 || record.length > ERX_LOG_TEXT_MAX)
		return (ERX_LOG_NEXT_CORRUPT);
	total = erx_log_record_bytes(record.length);
	if (window_size - at < total)
		return (ERX_LOG_NEXT_CORRUPT);

	/* What is checked is the copy, which only the caller can reach. */
	__builtin_memcpy(text, window + at + ERX_LOG_RECORD_SIZE, record.length);
	for (size_t index = 0; index < record.length; index++) {
		if (erx_terminal_ascii_safe[(uint8_t)text[index]] == 0)
			return (ERX_LOG_NEXT_CORRUPT);
	}
	padding = window + at + ERX_LOG_RECORD_SIZE + record.length;
	padding_bytes = total - ERX_LOG_RECORD_SIZE - record.length;
	for (size_t index = 0; index < padding_bytes; index++) {
		if (padding[index] != 0)
			return (ERX_LOG_NEXT_CORRUPT);
	}

	*view = (erx_log_view_t){
		.seq = record.seq,
		.time_ns = record.time_ns,
		.level = record.level,
		.flags = record.flags,
		.text = text,
		.length = record.length,
	};
	*offset = at + total;
	return (ERX_LOG_NEXT_RECORD);
}

static const char *
erx_log_level_name(erx_log_level_t level)
{
	switch (level) {
	case ERX_LOG_LEVEL_ERROR:
		return ("error");
	case ERX_LOG_LEVEL_WARNING:
		return ("warning");
	case ERX_LOG_LEVEL_INFO:
		return ("info");
	case ERX_LOG_LEVEL_DEBUG:
		return ("debug");
	default:
		return ("unknown");
	}
}

size_t
erx_log_render(const erx_log_view_t *view, char *dst, size_t capacity)
{
	erx_log_text_t line;

	/* Keeps room for the newline, which is the line's one raw byte. */
	if (capacity == 0)
		return (0);
	line = erx_log_text_over(dst, capacity - 1);

	erx_log_text_string(&line, "#");
	erx_log_text_number(&line, view->seq, 10, 1);
	erx_log_text_string(&line, " ");
	erx_log_text_number(&line, view->time_ns / ERX_LOG_NS_PER_S, 10, 1);
	erx_log_text_string(&line, ".");
	erx_log_text_number(&line,
	    view->time_ns % ERX_LOG_NS_PER_S / ERX_LOG_NS_PER_US, 10,
	    ERX_LOG_MICRO_DIGITS);
	erx_log_text_string(&line, " ");
	erx_log_text_string(&line, erx_log_level_name(view->level));
	erx_log_text_string(&line, " ");
	erx_log_text_add(&line, view->text, view->length);
	if ((view->flags & ERX_LOG_RECORD_TRUNCATED) != 0)
		erx_log_text_string(&line, ERX_LOG_TRUNCATED_MARK);
	if (line.truncated)
		return (0);

	dst[line.length] = '\n';
	return (line.length + 1);
}
