/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The crash record: the one writer, the one check over its bytes, and boot
 * step 4's decision on a region that may hold one. Every decision here is a
 * pure function of its arguments.
 *
 * The writer and the check are two readings of one rule set. erx_crash_settle
 * turns whatever an end path holds into fields the check accepts, so a record
 * is valid by construction even when the path that reached the end is broken;
 * the check trusts nothing, since what it reads went through a reset.
 *
 * Nothing here puts more than the header's copy on the stack: this runs on a
 * panic stack, so the log's working memory is the caller's scratch.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/crash.h"
#include "erx/log.h"

_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
    "the record's wire layout is the struct's own");

/* The seam's constants and the ABI's. */
_Static_assert(ERX_REGS_SIZE == ERX_CRASH_REGS_BYTES, "regs bytes");
_Static_assert(ERX_CRASH_RECORD_ALIGN == ERX_CRASH_BUFFER_ALIGN, "alignment");
_Static_assert(ERX_FAULT_SIZE == sizeof(erx_crash_fault_t), "fault size");
_Static_assert(ERX_FAULT_OFF_KIND == offsetof(erx_crash_fault_t, kind), "kind");
_Static_assert(ERX_FAULT_OFF_CAUSE == offsetof(erx_crash_fault_t, cause), "cause");
_Static_assert(ERX_FAULT_OFF_ADDR == offsetof(erx_crash_fault_t, addr), "addr");
_Static_assert(ERX_FAULT_OFF_PC == offsetof(erx_crash_fault_t, pc), "pc");
_Static_assert(ERX_FAULT_OFF_THREAD == offsetof(erx_crash_fault_t, thread), "thread");
_Static_assert(ERX_FAULT_OFF_SPACE == offsetof(erx_crash_fault_t, space), "space");
_Static_assert(ERX_FAULT_OFF_STATUS == offsetof(erx_crash_fault_t, status), "status");

/* The padding between nframes and the fault record. */
#define ERX_CRASH_PADDING_OFF	(ERX_CRASH_BRIEF_OFF_NFRAMES + sizeof(uint32_t))
#define ERX_CRASH_PADDING_BYTES	(ERX_CRASH_BRIEF_OFF_FAULT - ERX_CRASH_PADDING_OFF)
/* Bytes after the crc field, where the CRC starts. */
#define ERX_CRASH_CRC_START	(ERX_CRASH_BRIEF_OFF_CRC + sizeof(uint32_t))
#define ERX_CRASH_FRAMES_MAX	\
	((ERX_CRASH_RECORD_SIZE - ERX_CRASH_RECORD_OFF_FRAMES) / sizeof(uint64_t))
#define ERX_CRASH_TEXT_ROOM	(ERX_CRASH_SIZE - ERX_CRASH_RECORD_SIZE)
/* A panic message gets one log record's text, so it never crowds out the log. */
#define ERX_CRASH_MESSAGE_MAX	ERX_LOG_TEXT_MAX
#define ERX_CRASH_CRC_POLY	UINT32_C(0x82f63b78)

typedef struct erx_crash_scratch {
	uint8_t		window[ERX_LOG_RECORD_MAX];
	char		text[ERX_LOG_TEXT_MAX];
	char		line[ERX_LOG_LINE_MAX];
} erx_crash_scratch_t;

_Static_assert(sizeof(erx_crash_scratch_t) <= ERX_CRASH_SCRATCH_BYTES,
    "the seam's scratch holds the writer's");
_Static_assert(_Alignof(erx_crash_scratch_t) <= ERX_CRASH_BUFFER_ALIGN,
    "the seam's alignment holds the scratch");

typedef struct erx_crash_log_walk {
	const erx_log_t	*log;
	erx_crash_scratch_t *scratch;
	uint64_t	cursor;
	size_t		offset;
	size_t		filled;
} erx_crash_log_walk_t;

static bool erx_crash_all_zero(const uint8_t *, size_t);
static bool erx_crash_boot_pair(uint32_t, uint32_t);
static bool erx_crash_cause_known(uint32_t);
static erx_crash_check_t erx_crash_check_body(const uint8_t *, uint32_t, uint32_t,
    uint32_t);
static bool erx_crash_fault_fits(uint32_t, const erx_crash_fault_t *);
static bool erx_crash_kind_known(uint32_t);
static bool erx_crash_log_next(erx_crash_log_walk_t *, size_t *);
static erx_crash_log_walk_t erx_crash_log_start(const erx_log_t *,
    erx_crash_scratch_t *);
static size_t erx_crash_log_tail(const erx_log_t *, erx_crash_scratch_t *, char *,
    size_t);
static void erx_crash_settle(const erx_crash_input_t *, erx_crash_brief_t *);
static uint32_t erx_crash_write_body(const erx_crash_input_t *, erx_crash_record_t *,
    erx_crash_scratch_t *);

static bool
erx_crash_all_zero(const uint8_t *bytes, size_t length)
{
	uint8_t seen;

	seen = 0;
	for (size_t index = 0; index < length; index++)
		seen |= bytes[index];
	return (seen == 0);
}

/* The machine page's pairs: slot none exactly when the value is unknown. */
static bool
erx_crash_boot_pair(uint32_t value, uint32_t slot)
{
	switch (value) {
	case ERX_BOOT_VALUE_UNKNOWN:
		return (slot == ERX_BOOT_SLOT_NONE);
	case ERX_BOOT_VALUE_NORMAL:
	case ERX_BOOT_VALUE_TRIAL:
		return (slot == ERX_BOOT_SLOT_A || slot == ERX_BOOT_SLOT_B);
	default:
		return (false);
	}
}

static bool
erx_crash_cause_known(uint32_t cause)
{
	switch (cause) {
	case ERX_CRASH_CAUSE_FAULT:
	case ERX_CRASH_CAUSE_HALT:
	case ERX_CRASH_CAUSE_WATCHDOG:
	case ERX_CRASH_CAUSE_PANIC:
		return (true);
	default:
		return (false);
	}
}

static bool
erx_crash_kind_known(uint32_t kind)
{
	return (kind < 32 && ((ERX_CRASH_FAULT_KINDS >> kind) & 1) != 0);
}

/*
 * What each cause says of the fault record: a declared kind for FAULT, exit
 * for HALT, all zero for WATCHDOG. PANIC holds whatever the exception's
 * report names, or nothing, so it fits any record.
 */
static bool
erx_crash_fault_fits(uint32_t cause, const erx_crash_fault_t *fault)
{
	switch (cause) {
	case ERX_CRASH_CAUSE_FAULT:
		return (erx_crash_kind_known(fault->kind));
	case ERX_CRASH_CAUSE_HALT:
		return (fault->kind == ERX_FAULT_EXIT);
	case ERX_CRASH_CAUSE_WATCHDOG:
		return (erx_crash_all_zero((const uint8_t *)fault, sizeof(*fault)));
	case ERX_CRASH_CAUSE_PANIC:
		return (true);
	default:
		return (false);
	}
}

uint32_t
erx_crash_crc32c(const void *bytes, size_t length)
{
	const uint8_t *in;
	uint32_t crc;

	in = bytes;
	crc = UINT32_MAX;
	for (size_t index = 0; index < length; index++) {
		crc ^= in[index];
		for (int bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (ERX_CRASH_CRC_POLY & (0 - (crc & 1)));
	}
	return (crc ^ UINT32_MAX);
}

/*
 * Turns an end path's input into header fields the check accepts. An input
 * that contradicts itself means the kernel is broken, so its record says
 * PANIC rather than blame the root task: an unknown cause, a CPU past the
 * limit, a fault record the cause does not allow. A form outside the enum is
 * BRIEF, the form that holds nothing the root task held. A boot pair outside
 * the machine page's is unknown, which is what a record with no pair says.
 */
static void
erx_crash_settle(const erx_crash_input_t *input, erx_crash_brief_t *header)
{
	bool sane, pair;

	sane = input->cpu < ERX_CPU_LIMIT &&
	    erx_crash_fault_fits(input->cause, &input->fault);
	pair = erx_crash_boot_pair(input->boot_value, input->boot_slot);

	header->magic = ERX_CRASH_MAGIC;
	header->version = ERX_CRASH_VERSION;
	header->form = input->form == ERX_CRASH_FORM_FULL ? ERX_CRASH_FORM_FULL :
	    ERX_CRASH_FORM_BRIEF;
	header->cause = sane ? input->cause : ERX_CRASH_CAUSE_PANIC;
	header->cpu = input->cpu < ERX_CPU_LIMIT ? input->cpu : 0;
	header->uptime_ns = input->uptime_ns;
	header->since_pet_ns = input->since_pet_ns;
	__builtin_memcpy(header->build_id, input->build_id,
	    sizeof(header->build_id));
	header->boot_value = pair ? input->boot_value : ERX_BOOT_VALUE_UNKNOWN;
	header->boot_slot = pair ? input->boot_slot : ERX_BOOT_SLOT_NONE;
	header->fault.kind = input->fault.kind;
	header->fault.cause = input->fault.cause;
	header->fault.addr = input->fault.addr;
	header->fault.pc = input->fault.pc;
	header->fault.thread = input->fault.thread;
	header->fault.space = input->fault.space;
	header->fault.status = input->fault.status;
}

/*
 * The next rendered line of the log, in the scratch, and its length; false at
 * the log's end. A window that holds a record the log's check refuses is left
 * for the next: a panic may have stopped a CPU halfway through an append. Each
 * copy moves the cursor forward and the cursor ends at next_seq, which
 * erx_crash_log_tail has checked is within a ring's worth of records, so the
 * walk is bounded however wrong the ring's bytes are.
 */
static bool
erx_crash_log_next(erx_crash_log_walk_t *walk, size_t *length)
{
	erx_crash_scratch_t *scratch;
	erx_log_copy_result_t copied;
	erx_log_view_t view;

	scratch = walk->scratch;
	for (;;) {
		if (walk->offset < walk->filled &&
		    erx_log_next_record(scratch->window, walk->filled, &walk->offset,
		    scratch->text, &view) == ERX_LOG_NEXT_RECORD) {
			*length = erx_log_render(&view, scratch->line,
			    sizeof(scratch->line));
			return (true);
		}
		copied = erx_log_copy(walk->log, walk->cursor, scratch->window,
		    sizeof(scratch->window));
		if (copied.status != ERX_OK || copied.written == 0)
			return (false);
		walk->cursor = copied.next_cursor;
		walk->offset = 0;
		walk->filled = copied.written;
	}
}

static erx_crash_log_walk_t
erx_crash_log_start(const erx_log_t *log, erx_crash_scratch_t *scratch)
{
	return ((erx_crash_log_walk_t){
		.log = log,
		.scratch = scratch,
	});
}

/*
 * The newest whole lines that fit in room, newest last; none when a wild store
 * has reached the log's counters. One walk measures the
 * log and a second copies the lines past the part that does not fit; the other
 * CPUs have stopped, and a log that differs between the walks only ends the
 * copy early.
 */
static size_t
erx_crash_log_tail(const erx_log_t *log, erx_crash_scratch_t *scratch, char *dst,
    size_t room)
{
	erx_crash_log_walk_t walk;
	size_t all, line, seen, skip, used;

	if (!erx_log_counters_plausible(log))
		return (0);
	all = 0;
	walk = erx_crash_log_start(log, scratch);
	while (erx_crash_log_next(&walk, &line))
		all += line;
	skip = all > room ? all - room : 0;

	seen = 0;
	used = 0;
	walk = erx_crash_log_start(log, scratch);
	while (erx_crash_log_next(&walk, &line)) {
		seen += line;
		if (seen - line < skip)
			continue;
		if (line > room - used)
			break;
		__builtin_memcpy(dst + used, scratch->line, line);
		used += line;
	}
	return (used);
}

/* The full form's fields past the brief form's end; returns the record's length. */
static uint32_t
erx_crash_write_body(const erx_crash_input_t *input, erx_crash_record_t *record,
    erx_crash_scratch_t *scratch)
{
	erx_log_escape_result_t escaped;
	char *text;
	size_t room, used;
	uint32_t cause, nframes;

	cause = record->header.cause;
	if (input->regs != NULL && (cause == ERX_CRASH_CAUSE_FAULT ||
	    cause == ERX_CRASH_CAUSE_PANIC))
		__builtin_memcpy(&record->regs, input->regs, sizeof(record->regs));
	if (input->frames != NULL && cause == ERX_CRASH_CAUSE_PANIC) {
		nframes = input->nframes;
		if (nframes > ERX_CRASH_FRAMES_MAX)
			nframes = (uint32_t)ERX_CRASH_FRAMES_MAX;
		__builtin_memcpy(record->frames, input->frames,
		    nframes * sizeof(uint64_t));
		record->header.nframes = nframes;
	}

	text = (char *)record + ERX_CRASH_RECORD_SIZE;
	room = ERX_CRASH_TEXT_ROOM;
	used = 0;
	if (input->message != NULL) {
		escaped = erx_log_escape(input->message, input->message_length,
		    text, ERX_CRASH_MESSAGE_MAX);
		used = escaped.written;
		text[used++] = '\n';
	}
	if (input->log != NULL)
		used += erx_crash_log_tail(input->log, scratch, text + used,
		    room - used);
	return ((uint32_t)(ERX_CRASH_RECORD_SIZE + used));
}

_Static_assert(ERX_CRASH_MESSAGE_MAX < ERX_CRASH_TEXT_ROOM,
    "the message and its newline fit in the record's text");

size_t
erx_crash_record_write(const erx_crash_input_t *input, void *buffer, void *scratch)
{
	erx_crash_record_t *record;
	uint8_t *bytes;
	uint32_t length;

	bytes = buffer;
	record = buffer;
	__builtin_memset(buffer, 0, ERX_CRASH_SIZE);
	erx_crash_settle(input, &record->header);
	length = record->header.form == ERX_CRASH_FORM_FULL ?
	    erx_crash_write_body(input, record, scratch) : ERX_CRASH_BRIEF_SIZE;
	record->header.length = length;
	record->header.crc = erx_crash_crc32c(bytes + ERX_CRASH_CRC_START,
	    length - ERX_CRASH_CRC_START);
	return (length);
}

/* The full form's fields past the brief form's end. */
static erx_crash_check_t
erx_crash_check_body(const uint8_t *bytes, uint32_t length, uint32_t cause,
    uint32_t nframes)
{
	const uint8_t *frames;
	uint8_t byte;

	if (cause != ERX_CRASH_CAUSE_FAULT && cause != ERX_CRASH_CAUSE_PANIC &&
	    !erx_crash_all_zero(bytes + ERX_CRASH_RECORD_OFF_REGS, ERX_REGS_SIZE))
		return (ERX_CRASH_CHECK_REGS);
	frames = bytes + ERX_CRASH_RECORD_OFF_FRAMES + nframes * sizeof(uint64_t);
	if (!erx_crash_all_zero(frames, (size_t)(bytes + ERX_CRASH_RECORD_SIZE - frames)))
		return (ERX_CRASH_CHECK_FRAMES);
	for (uint32_t index = ERX_CRASH_RECORD_SIZE; index < length; index++) {
		byte = bytes[index];
		if (byte != '\n' && (byte < 0x20 || byte > 0x7e))
			return (ERX_CRASH_CHECK_TEXT);
	}
	return (ERX_CRASH_CHECK_OK);
}

erx_crash_check_t
erx_crash_check(const void *bytes, size_t available)
{
	const uint8_t *in;
	erx_crash_brief_t header;
	erx_crash_fault_t fault;

	in = bytes;
	if (in == NULL || available < ERX_CRASH_BRIEF_SIZE)
		return (ERX_CRASH_CHECK_SHORT);
	__builtin_memcpy(&header, in, sizeof(header));

	if (header.magic != ERX_CRASH_MAGIC)
		return (ERX_CRASH_CHECK_MAGIC);
	if (header.version != ERX_CRASH_VERSION)
		return (ERX_CRASH_CHECK_VERSION);
	switch (header.form) {
	case ERX_CRASH_FORM_BRIEF:
		if (header.length != ERX_CRASH_BRIEF_SIZE)
			return (ERX_CRASH_CHECK_LENGTH);
		break;
	case ERX_CRASH_FORM_FULL:
		if (header.length < ERX_CRASH_RECORD_SIZE ||
		    header.length > ERX_CRASH_SIZE)
			return (ERX_CRASH_CHECK_LENGTH);
		break;
	default:
		return (ERX_CRASH_CHECK_FORM);
	}
	if (header.length > available)
		return (ERX_CRASH_CHECK_SHORT);
	if (erx_crash_crc32c(in + ERX_CRASH_CRC_START,
	    header.length - ERX_CRASH_CRC_START) != header.crc)
		return (ERX_CRASH_CHECK_CRC);
	if (!erx_crash_cause_known(header.cause))
		return (ERX_CRASH_CHECK_CAUSE);
	if (header.cpu >= ERX_CPU_LIMIT)
		return (ERX_CRASH_CHECK_CPU);
	if (!erx_crash_boot_pair(header.boot_value, header.boot_slot))
		return (ERX_CRASH_CHECK_BOOT);
	if (!erx_crash_all_zero(in + ERX_CRASH_PADDING_OFF, ERX_CRASH_PADDING_BYTES))
		return (ERX_CRASH_CHECK_PADDING);
	if (header.nframes > ERX_CRASH_FRAMES_MAX || (header.nframes != 0 &&
	    (header.form != ERX_CRASH_FORM_FULL ||
	    header.cause != ERX_CRASH_CAUSE_PANIC)))
		return (ERX_CRASH_CHECK_NFRAMES);
	__builtin_memcpy(&fault, in + ERX_CRASH_BRIEF_OFF_FAULT, sizeof(fault));
	if (!erx_crash_fault_fits(header.cause, &fault))
		return (ERX_CRASH_CHECK_FAULT);
	if (header.form == ERX_CRASH_FORM_BRIEF)
		return (ERX_CRASH_CHECK_OK);
	return (erx_crash_check_body(in, header.length, header.cause,
	    header.nframes));
}

const char *
erx_crash_check_reason(erx_crash_check_t status)
{
	/* A table: a long switch compiles to a jump the stack proof refuses. */
	static const char *const reasons[] = {
		[ERX_CRASH_CHECK_OK] = "valid",
		[ERX_CRASH_CHECK_SHORT] = "fewer bytes than the record's length",
		[ERX_CRASH_CHECK_MAGIC] = "the magic is wrong",
		[ERX_CRASH_CHECK_VERSION] = "the version is not this build's",
		[ERX_CRASH_CHECK_FORM] = "the form is neither brief nor full",
		[ERX_CRASH_CHECK_LENGTH] = "the length is outside what the form admits",
		[ERX_CRASH_CHECK_CRC] = "the CRC does not match",
		[ERX_CRASH_CHECK_CAUSE] = "the cause is not one of the four",
		[ERX_CRASH_CHECK_CPU] = "the CPU is past the limit",
		[ERX_CRASH_CHECK_BOOT] = "the boot value and slot are no allowed pair",
		[ERX_CRASH_CHECK_PADDING] = "the padding is not zero",
		[ERX_CRASH_CHECK_NFRAMES] = "the frame count is wrong for the form and cause",
		[ERX_CRASH_CHECK_FAULT] = "the fault record contradicts the cause",
		[ERX_CRASH_CHECK_REGS] = "registers are set where the cause has none",
		[ERX_CRASH_CHECK_FRAMES] = "frames are set past the frame count",
		[ERX_CRASH_CHECK_TEXT] = "the text holds a byte neither printable nor a newline",
		[ERX_CRASH_CHECK_NOT_RUN] = "the frame stopped before the record",
	};

	if ((size_t)status >= sizeof(reasons) / sizeof(reasons[0]))
		return ("unknown status");
	return (reasons[status]);
}

uint32_t
erx_crash_previous_length(const void *region, size_t region_size,
    uint32_t build_form)
{
	uint32_t form, length;
	size_t available;

	available = region_size < ERX_CRASH_SIZE ? region_size : ERX_CRASH_SIZE;
	if (erx_crash_check(region, available) != ERX_CRASH_CHECK_OK)
		return (0);
	__builtin_memcpy(&form, (const uint8_t *)region + ERX_CRASH_BRIEF_OFF_FORM,
	    sizeof(form));
	__builtin_memcpy(&length, (const uint8_t *)region + ERX_CRASH_BRIEF_OFF_LENGTH,
	    sizeof(length));
	return (form == build_form ? length : 0);
}
