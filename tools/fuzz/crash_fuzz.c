/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/crash.h"
#include "erx/log.h"
#include "erx/core/trace_ring.h"

/*
 * The first byte picks the target; the writer and the reader share it over
 * both forms, as the design asks:
 *   0: erx_crash_check and erx_crash_previous_length over any bytes
 *   1: the same over any bytes with the magic, version and CRC made right, so
 *      that the fields past the CRC are reached
 *   2: erx_crash_frame_read over any log
 *   3: erx_crash_record_write from any input, through the frame and back. The
 *      next byte selects: 1 registers, CPU entries and trace rings whose heads
 *      and first records are the input's bytes, 2 frames, 4 a log, 8 the
 *      full form, 0x40
 *      the form as the input has it, 0x80 scribble on the log's counters and
 *      ring; 0x30 scales the log's lines. trace_none is its input byte's low
 *      bit. The frame is written and read back
 *      for both kinds of end
 */

#define FUZZ_FRAME_MAX	(2 * ERX_CRASH_SIZE)

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void fuzz_check(const uint8_t *, size_t);
static bool fuzz_entries_expected(const uint8_t *, uint32_t);
static bool fuzz_tail_expected(const uint8_t *, bool);
static bool fuzz_expected(const uint8_t *);
static void fuzz_fixed(const uint8_t *, size_t);
static void fuzz_handed_on(const uint8_t *, size_t);
static void fuzz_read(const uint8_t *, size_t);
static void fuzz_scribble(const uint8_t *, size_t);
static void fuzz_write(const uint8_t *, size_t);

static _Alignas(8) uint8_t fuzz_record[ERX_CRASH_SIZE];
static _Alignas(8) uint8_t fuzz_copy[ERX_CRASH_SIZE];
static _Alignas(8) uint8_t fuzz_scratch[ERX_CRASH_SCRATCH_BYTES];
static uint8_t fuzz_frame[FUZZ_FRAME_MAX];
static size_t fuzz_frame_used;
static erx_log_t fuzz_log;
/* The rings the writer is handed; the input fills the first FUZZ_RING_BYTES of each. */
#define FUZZ_RINGS	3
#define FUZZ_RING_BYTES	(64 * ERX_TRACE_RECORD_SIZE)
static erx_trace_ring_t fuzz_rings[FUZZ_RINGS];

void
erx_effect_console_write(const char *line, size_t length)
{
	if (length > sizeof(fuzz_frame) - fuzz_frame_used)
		abort();
	memcpy(fuzz_frame + fuzz_frame_used, line, length);
	fuzz_frame_used += length;
}

static uint32_t
fuzz_u32(const uint8_t *bytes, size_t offset)
{
	uint32_t value;

	memcpy(&value, bytes + offset, sizeof(value));
	return (value);
}

/*
 * The CPU entries: entry N is CPU N in a state 1 to 7 for N below the count,
 * with nothing past its state unless the state carries registers, a fact of
 * the ABI file read from its generated predicate; every entry past the count
 * is zero.
 */
static bool
fuzz_entries_expected(const uint8_t *bytes, uint32_t ncpus)
{
	const uint8_t *entry;
	uint32_t state;
	size_t from;

	for (uint32_t cpu = 0; cpu < ERX_CRASH_CPUS; cpu++) {
		entry = bytes + ERX_CRASH_RECORD_OFF_CPUS + cpu * ERX_CRASH_CPU_SIZE;
		from = 0;
		if (cpu < ncpus) {
			state = fuzz_u32(entry, 4);
			if (fuzz_u32(entry, 0) != cpu || state < 1 || state > 7)
				return (false);
			from = erx_stop_cpu_state_registers(state) ? ERX_CRASH_CPU_SIZE : 8;
		}
		for (size_t index = from; index < ERX_CRASH_CPU_SIZE; index++) {
			if (entry[index] != 0)
				return (false);
		}
	}
	return (true);
}

/*
 * An independent reading of the design's list, for a record whose framing and
 * CRC erx_crash_check has already accepted: the fields only.
 */
static bool
fuzz_expected(const uint8_t *bytes)
{
	uint32_t cause, form, kind, length, ncpus, nframes, value, slot;
	static const uint8_t none[ERX_REGS_SIZE];

	form = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_FORM);
	length = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_LENGTH);
	cause = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_CAUSE);
	value = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_BOOT_VALUE);
	slot = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_BOOT_SLOT);
	nframes = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_NFRAMES);
	ncpus = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_NCPUS);
	kind = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_FAULT);

	if (fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_FLAGS) > 1)
		return (false);
	if (cause < 1 || cause > 4 || fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_CPU) >= 64)
		return (false);
	if (value < 1 || value > 3 || slot > 2 || (value == 1) != (slot == 0))
		return (false);
	if (ncpus > 64 || (ncpus != 0 && form != 2))
		return (false);
	if (nframes > 64 || (nframes != 0 && (form != 2 || cause != 4)))
		return (false);
	if ((cause == 1 && (kind < 1 || kind > 9)) || (cause == 2 && kind != 9))
		return (false);
	if (cause == 3) {
		for (size_t index = 0; index < ERX_FAULT_SIZE; index++) {
			if (bytes[ERX_CRASH_BRIEF_OFF_FAULT + index] != 0)
				return (false);
		}
	}
	if (form != 2)
		return (true);
	if (cause != 1 && cause != 4 &&
	    memcmp(bytes + ERX_CRASH_RECORD_OFF_REGS, none, sizeof(none)) != 0)
		return (false);
	for (size_t index = ERX_CRASH_RECORD_OFF_FRAMES + nframes * 8;
	    index < ERX_CRASH_RECORD_OFF_CPUS; index++) {
		if (bytes[index] != 0)
			return (false);
	}
	if (!fuzz_entries_expected(bytes, ncpus) ||
	    !fuzz_tail_expected(bytes, fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_FLAGS) == 1))
		return (false);
	for (size_t index = ERX_CRASH_RECORD_SIZE; index < length; index++) {
		if (bytes[index] != '\n' && (bytes[index] < 0x20 || bytes[index] > 0x7e))
			return (false);
	}
	return (true);
}

/*
 * The trace tail's rules, read on their own: no record after an empty slot;
 * each with an even, nonzero seq and a CPU below 64; and each after the one
 * before in CPU order and, within one CPU, by seq; and no record at all in a
 * boot whose rings did not record (trace_none, the flags' bit 0).
 */
static bool
fuzz_tail_expected(const uint8_t *bytes, bool trace_none)
{
	static const uint8_t none[ERX_TRACE_RECORD_WIRE_SIZE];
	const uint8_t *slot;
	uint64_t seq, last_seq = 0;
	uint32_t cpu, last_cpu = 0;
	bool ended = false, any = false;

	for (uint32_t index = 0; index < ERX_CRASH_TRACE_RECORDS; index++) {
		slot = bytes + ERX_CRASH_RECORD_OFF_TRACE + index * sizeof(none);
		if (memcmp(slot, none, sizeof(none)) == 0) {
			ended = true;
			continue;
		}
		memcpy(&seq, slot + ERX_TRACE_RECORD_WIRE_OFF_SEQ, sizeof(seq));
		cpu = (uint32_t)slot[ERX_TRACE_RECORD_WIRE_OFF_CPU] |
		    (uint32_t)slot[ERX_TRACE_RECORD_WIRE_OFF_CPU + 1] << 8;
		if (trace_none || ended || seq == 0 || seq % 2 != 0 || cpu >= 64)
			return (false);
		if (any && (cpu < last_cpu || (cpu == last_cpu && seq <= last_seq)))
			return (false);
		any = true;
		last_cpu = cpu;
		last_seq = seq;
	}
	return (true);
}

/* A record is handed on only in its own form, and only when it checks. */
static void
fuzz_handed_on(const uint8_t *bytes, size_t length)
{
	uint32_t brief, full, form, used;
	erx_crash_check_t status;

	status = erx_crash_check(bytes, length);
	brief = erx_crash_previous_length(bytes, length, ERX_CRASH_FORM_BRIEF);
	full = erx_crash_previous_length(bytes, length, ERX_CRASH_FORM_FULL);
	if (status != ERX_CRASH_CHECK_OK) {
		if (brief != 0 || full != 0)
			abort();
		return;
	}
	form = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_FORM);
	used = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_LENGTH);
	if (brief != (form == ERX_CRASH_FORM_BRIEF ? used : 0) ||
	    full != (form == ERX_CRASH_FORM_FULL ? used : 0))
		abort();
}

static void
fuzz_check(const uint8_t *bytes, size_t length)
{
	erx_crash_check_t status;

	status = erx_crash_check(bytes, length);
	if (erx_crash_check_reason(status) == NULL)
		abort();
	fuzz_handed_on(bytes, length);
	if (status == ERX_CRASH_CHECK_OK && !fuzz_expected(bytes))
		abort();
}

/* Makes the framing right so that every field check is reached. */
static void
fuzz_fixed(const uint8_t *bytes, size_t length)
{
	uint64_t magic;
	uint32_t form, version, used, crc;
	size_t crc_start;

	memset(fuzz_copy, 0, sizeof(fuzz_copy));
	memcpy(fuzz_copy, bytes, length > ERX_CRASH_SIZE ? ERX_CRASH_SIZE : length);
	form = (length > 0 && (bytes[0] & 1) != 0) ? ERX_CRASH_FORM_FULL : ERX_CRASH_FORM_BRIEF;
	used = ERX_CRASH_BRIEF_SIZE;
	if (form == ERX_CRASH_FORM_FULL) {
		used = ERX_CRASH_RECORD_SIZE;
		if (length > ERX_CRASH_RECORD_SIZE)
			used = length > ERX_CRASH_SIZE ? ERX_CRASH_SIZE : (uint32_t)length;
	}
	magic = ERX_CRASH_MAGIC;
	version = ERX_CRASH_VERSION;
	memcpy(fuzz_copy + ERX_CRASH_BRIEF_OFF_MAGIC, &magic, sizeof(magic));
	memcpy(fuzz_copy + ERX_CRASH_BRIEF_OFF_VERSION, &version, sizeof(version));
	memcpy(fuzz_copy + ERX_CRASH_BRIEF_OFF_LENGTH, &used, sizeof(used));
	memcpy(fuzz_copy + ERX_CRASH_BRIEF_OFF_FORM, &form, sizeof(form));
	crc_start = ERX_CRASH_BRIEF_OFF_CRC + sizeof(crc);
	crc = erx_crash_crc32c(fuzz_copy + crc_start, used - crc_start);
	memcpy(fuzz_copy + ERX_CRASH_BRIEF_OFF_CRC, &crc, sizeof(crc));

	if ((erx_crash_check(fuzz_copy, used) == ERX_CRASH_CHECK_OK) !=
	    fuzz_expected(fuzz_copy))
		abort();
	fuzz_handed_on(fuzz_copy, used);
}

static void
fuzz_read(const uint8_t *bytes, size_t length)
{
	erx_crash_read_t result;
	char line[ERX_CRASH_FRAME_LINE_BYTES];
	uint32_t form;
	size_t used, cursor;

	result = erx_crash_frame_read(bytes, length, fuzz_record);
	if (result.frame_start > result.frame_end || result.frame_end > length)
		abort();
	if (result.status != ERX_CRASH_READ_VALID) {
		for (size_t index = 0; index < ERX_CRASH_SIZE; index++) {
			if (fuzz_record[index] != 0)
				abort();
		}
		return;
	}
	if (erx_crash_check(fuzz_record, result.length) != ERX_CRASH_CHECK_OK)
		abort();
	/* One record has one spelling: writing it back gives the frame's lines. */
	form = fuzz_u32(fuzz_record, ERX_CRASH_BRIEF_OFF_FORM);
	cursor = result.frame_start;
	for (uint32_t index = 0; index < erx_crash_frame_line_count(result.length); index++) {
		used = erx_crash_frame_line(fuzz_record, form, result.length, index, line);
		if (used == 0 || used - 1 > result.frame_end - cursor ||
		    memcmp(bytes + cursor, line, used - 1) != 0)
			abort();
		cursor += used - 1;
		if (cursor < result.frame_end && bytes[cursor] == '\r')
			cursor++;
		cursor++;
	}
	if (cursor != result.frame_end)
		abort();
}

/*
 * What a wild store or a CPU stopped mid-append leaves: the first bytes over
 * the log's counters, the next two as an offset into the ring, and the rest
 * over the ring there. The ring is the log's last member.
 */
static void
fuzz_scribble(const uint8_t *bytes, size_t length)
{
	uint8_t *ring;
	size_t counters, offset;

	counters = length < 4 * sizeof(uint64_t) ? length : 4 * sizeof(uint64_t);
	memcpy(&fuzz_log, bytes, counters);
	if (length < counters + 2)
		return;
	offset = (bytes[counters] | (size_t)bytes[counters + 1] << 8) % ERX_LOG_RING_BYTES;
	bytes += counters + 2;
	length -= counters + 2;
	if (length > ERX_LOG_RING_BYTES - offset)
		length = ERX_LOG_RING_BYTES - offset;
	ring = (uint8_t *)&fuzz_log + sizeof(fuzz_log) - ERX_LOG_RING_BYTES;
	memcpy(ring + offset, bytes, length);
}

/*
 * Any input, garbage fields included, must write a record the check accepts,
 * whose frame reads back as the same bytes.
 */
static void
fuzz_write(const uint8_t *bytes, size_t length)
{
	static const uint8_t regs[ERX_CRASH_REGS_BYTES] = { 1 };
	static uint64_t frames[64] = { 0x1000, 0x1001 };
	static erx_crash_cpu_t cpus[ERX_CRASH_CPUS];
	static _Alignas(8) uint8_t back[ERX_CRASH_SIZE];
	static const erx_crash_end_t ends[] = { ERX_CRASH_END_FAULT,
	    ERX_CRASH_END_WATCHDOG, ERX_CRASH_END_TASK };
	erx_crash_input_t input;
	erx_crash_read_t result;
	size_t used;
	uint8_t selector;

	if (length == 0)
		return;
	selector = bytes[0];
	bytes++;
	length--;
	memset(&input, 0, sizeof(input));
	used = length < sizeof(input) ? length : sizeof(input);
	memcpy(&input, bytes, used);
	/* A bool holds only 0 or 1: its byte's low bit, so some inputs set the bit. */
	input.trace_none = used > offsetof(erx_crash_input_t, trace_none) &&
	    (bytes[offsetof(erx_crash_input_t, trace_none)] & 1) != 0;
	bytes += used;
	length -= used;
	if ((selector & 0x40) == 0) {
		input.form = (selector & 8) != 0 ? ERX_CRASH_FORM_FULL :
		    ERX_CRASH_FORM_BRIEF;
	}
	input.regs = (selector & 1) != 0 ? regs : NULL;
	input.frames = (selector & 2) != 0 ? frames : NULL;
	/* The entries are the message's bytes: any state, any words. */
	memset(cpus, 0, sizeof(cpus));
	memcpy(cpus, bytes, length < sizeof(cpus) ? length : sizeof(cpus));
	input.cpus = (selector & 1) != 0 ? cpus : NULL;
	/* Ring n's head is the message's byte n and its first records the message. */
	for (size_t ring = 0; ring < FUZZ_RINGS; ring++) {
		memset(fuzz_rings[ring].records, 0, FUZZ_RING_BYTES);
		memcpy(fuzz_rings[ring].records, bytes,
		    length < FUZZ_RING_BYTES ? length : FUZZ_RING_BYTES);
		atomic_store_explicit(&fuzz_rings[ring].head, length > ring ? bytes[ring] : 0,
		    memory_order_relaxed);
	}
	input.trace = (selector & 1) != 0 ? fuzz_rings : NULL;
	input.ntrace = (selector & 1) != 0 ? FUZZ_RINGS : 0;
	input.message = (const char *)bytes;
	input.message_length = length;
	input.log = NULL;
	if ((selector & 4) != 0) {
		memset(&fuzz_log, 0, sizeof(fuzz_log));
		for (size_t index = 0; index < (size_t)((selector >> 4) & 3) * 700;
		    index++) {
			if (ERX_LOG_FORMAT(&fuzz_log, ERX_LOG_LEVEL_INFO, index,
			    "a line of the log %zu", index) != ERX_OK)
				abort();
		}
		if ((selector & 0x80) != 0)
			fuzz_scribble(bytes, length);
		input.log = &fuzz_log;
	}

	used = erx_crash_record_write(&input, fuzz_record, fuzz_scratch);
	if (used > ERX_CRASH_SIZE || erx_crash_check(fuzz_record, used) != ERX_CRASH_CHECK_OK)
		abort();
	if (fuzz_u32(fuzz_record, ERX_CRASH_BRIEF_OFF_FLAGS) != (input.trace_none ? 1u : 0u))
		abort();
	if (input.form != ERX_CRASH_FORM_FULL && used != ERX_CRASH_BRIEF_SIZE)
		abort();

	for (size_t index = 0; index < sizeof(ends) / sizeof(ends[0]); index++) {
		fuzz_frame_used = 0;
		erx_crash_frame_write(fuzz_record, ends[index]);
		result = erx_crash_frame_read(fuzz_frame, fuzz_frame_used, back);
		if (result.status != ERX_CRASH_READ_VALID || result.length != used ||
		    memcmp(back, fuzz_record, used) != 0)
			abort();
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	if (length == 0)
		return (0);
	switch (bytes[0] & 3) {
	case 0:
		fuzz_check(bytes + 1, length - 1);
		break;
	case 1:
		fuzz_fixed(bytes + 1, length - 1);
		break;
	case 2:
		fuzz_read(bytes + 1, length - 1);
		break;
	default:
		fuzz_write(bytes + 1, length - 1);
		break;
	}
	return (0);
}
