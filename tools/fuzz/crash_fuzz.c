/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/crash.h"
#include "erx/log.h"

/*
 * The first byte picks the target; the writer and the reader share it over
 * both forms, as the design asks:
 *   0: erx_crash_check and erx_crash_previous_length over any bytes
 *   1: the same over any bytes with the magic, version and CRC made right, so
 *      that the fields past the CRC are reached
 *   2: erx_crash_frame_read over any log
 *   3: erx_crash_record_write from any input, the log's counters and ring
 *      scribbled on when the input asks, through the frame and back
 */

#define FUZZ_FRAME_MAX	(2 * ERX_CRASH_SIZE)

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void fuzz_check(const uint8_t *, size_t);
static void fuzz_fixed(const uint8_t *, size_t);
static void fuzz_read(const uint8_t *, size_t);
static void fuzz_scribble(const uint8_t *, size_t);
static void fuzz_write(const uint8_t *, size_t);
static bool fuzz_expected(const uint8_t *);
static void fuzz_plans(const uint8_t *, size_t);

static _Alignas(8) uint8_t fuzz_record[ERX_CRASH_SIZE];
static _Alignas(8) uint8_t fuzz_copy[ERX_CRASH_SIZE];
static _Alignas(8) uint8_t fuzz_scratch[ERX_CRASH_SCRATCH_BYTES];
static uint8_t fuzz_frame[FUZZ_FRAME_MAX];
static size_t fuzz_frame_used;
static erx_log_t fuzz_log;

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
 * An independent reading of the design's list, for a record whose framing and
 * CRC erx_crash_check has already accepted: the fields only.
 */
static bool
fuzz_expected(const uint8_t *bytes)
{
	uint32_t cause, form, kind, length, nframes, value, slot;
	static const uint8_t none[ERX_REGS_SIZE];

	form = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_FORM);
	length = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_LENGTH);
	cause = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_CAUSE);
	value = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_BOOT_VALUE);
	slot = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_BOOT_SLOT);
	nframes = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_NFRAMES);
	kind = fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_FAULT);

	if (cause < 1 || cause > 4 || fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_CPU) >= 64)
		return (false);
	if (value < 1 || value > 3 || slot > 2 || (value == 1) != (slot == 0))
		return (false);
	if (fuzz_u32(bytes, ERX_CRASH_BRIEF_OFF_NFRAMES + 4) != 0)
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
	    index < ERX_CRASH_RECORD_SIZE; index++) {
		if (bytes[index] != 0)
			return (false);
	}
	for (size_t index = ERX_CRASH_RECORD_SIZE; index < length; index++) {
		if (bytes[index] != '\n' && (bytes[index] < 0x20 || bytes[index] > 0x7e))
			return (false);
	}
	return (true);
}

/* A record is handed on only in its own form, and only when it checks. */
static void
fuzz_plans(const uint8_t *bytes, size_t length)
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
	fuzz_plans(bytes, length);
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
	fuzz_plans(fuzz_copy, used);
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
 * What a wild store or a CPU stopped mid-append leaves: the input over the
 * log's counters at its start and over the ring at its end.
 */
static void
fuzz_scribble(const uint8_t *bytes, size_t length)
{
	size_t counters, ring;

	counters = length < 4 * sizeof(uint64_t) ? length : 4 * sizeof(uint64_t);
	ring = length < sizeof(fuzz_log) / 2 ? length : sizeof(fuzz_log) / 2;
	memcpy(&fuzz_log, bytes, counters);
	memcpy((uint8_t *)&fuzz_log + sizeof(fuzz_log) - ring, bytes, ring);
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
	static _Alignas(8) uint8_t back[ERX_CRASH_SIZE];
	erx_crash_input_t input;
	erx_crash_read_t result;
	size_t used, split;

	memset(&input, 0, sizeof(input));
	used = length < sizeof(input) ? length : sizeof(input);
	memcpy(&input, bytes, used);
	split = used;
	input.regs = (split > 0 && (bytes[0] & 1) != 0) ? regs : NULL;
	input.frames = (split > 0 && (bytes[0] & 2) != 0) ? frames : NULL;
	input.message = (const char *)bytes + split;
	input.message_length = length - split;
	memset(&fuzz_log, 0, sizeof(fuzz_log));
	input.log = NULL;
	if (split > 0 && (bytes[0] & 4) != 0) {
		for (size_t index = 0; index < (size_t)(bytes[0] >> 3) * 8; index++) {
			if (ERX_LOG_FORMAT(&fuzz_log, ERX_LOG_LEVEL_INFO, index,
			    "a line of the log %zu", index) != ERX_OK)
				abort();
		}
		if ((bytes[0] & 0x80) != 0)
			fuzz_scribble(bytes, length);
		input.log = &fuzz_log;
	}

	used = erx_crash_record_write(&input, fuzz_record, fuzz_scratch);
	if (used > ERX_CRASH_SIZE || erx_crash_check(fuzz_record, used) != ERX_CRASH_CHECK_OK)
		abort();
	if (input.form != ERX_CRASH_FORM_FULL && used != ERX_CRASH_BRIEF_SIZE)
		abort();

	fuzz_frame_used = 0;
	erx_crash_frame_write(fuzz_record);
	result = erx_crash_frame_read(fuzz_frame, fuzz_frame_used, back);
	if (result.status != ERX_CRASH_READ_VALID || result.length != used ||
	    memcmp(back, fuzz_record, used) != 0)
		abort();
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
