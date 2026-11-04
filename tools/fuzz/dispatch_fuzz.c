/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * System-call argument decoding through erx_dispatch. An input is a call
 * number and six argument registers, then message-word bytes. Whatever it
 * holds: the call ends with a status its contract allows, the other result
 * words are zero, a line reaches the console only for a call that returned
 * ERX_OK and carries no raw control byte, and the lock is balanced.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/dispatch.h"
#include "erx/core/effects.h"
#include "erx/log.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static uint64_t fuzz_clock;
static int fuzz_lock_depth;
static size_t fuzz_console_lines;

void
erx_effect_log_lock(void)
{
	if (fuzz_lock_depth++ != 0)
		abort();
}

void
erx_effect_log_unlock(void)
{
	if (--fuzz_lock_depth != 0)
		abort();
}

uint64_t
erx_effect_clock_ns(void)
{
	return (fuzz_clock);
}

void
erx_effect_console_write(const char *line, size_t length)
{
	if (fuzz_lock_depth != 1 || length == 0 || line[length - 1] != '\n')
		abort();
	for (size_t index = 0; index + 1 < length; index++) {
		unsigned char byte = (unsigned char)line[index];

		if (byte < 0x20 || byte >= 0x7f)
			abort();
	}
	fuzz_console_lines++;
}

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	static erx_utcb_t utcb;
	static erx_log_rate_t rate;
	uint64_t frame[1 + ERX_TRAP_ARG_COUNT];
	uint64_t results[ERX_TRAP_RESULT_COUNT];
	erx_sys_caller_t caller = { .utcb = &utcb, .log_rate = &rate, .space = 7,
	    .executor = false };
	size_t lines = fuzz_console_lines;
	int32_t status;

	if (length < sizeof(frame))
		return (0);
	memcpy(frame, bytes, sizeof(frame));
	bytes += sizeof(frame);
	length -= sizeof(frame);
	for (size_t word = 0; word * 8 < length && word < 63; word++) {
		uint8_t raw[8] = { 0 };
		uint64_t value = 0;
		size_t count = length - word * 8 < 8 ? length - word * 8 : 8;

		memcpy(raw, bytes + word * 8, count);
		for (size_t byte = 0; byte < 8; byte++)
			value |= (uint64_t)raw[byte] << (8 * byte);
		if (!erx_utcb_mr_store(&utcb, word, value))
			abort();
	}

	/* The call ignores its last register; here it moves the clock. */
	fuzz_clock += frame[ERX_TRAP_ARG_COUNT] & UINT64_C(0xFFFFFFFFFF);
	erx_dispatch(&caller, frame[0], &frame[1], results);

	status = (int32_t)(uint32_t)results[0];
	if ((results[0] >> 32) != 0 || results[1] != 0 || results[2] != 0)
		abort();
	if (status != ERX_OK && status != ERX_EINVAL && status != ERX_ENOTSUP &&
	    status != ERX_ELIMIT)
		abort();
	if (frame[0] != ERX_CALL_DEBUG_LOG && status != ERX_ENOTSUP)
		abort();
	if (status != ERX_OK && fuzz_console_lines != lines)
		abort();
	return (0);
}
