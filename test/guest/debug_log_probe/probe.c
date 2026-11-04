/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The cases of the debug-log probe. Every case reports one line through
 * erx_debug_log: its name, what the call returned and what the contract says
 * (docs/design-kernel.md, "Console, log and panic"), so the transcript holds
 * the results a backend gave and any disagreement between backends shows in
 * it. Nothing here depends on a backend; test/guest/debug_log_probe/guest.c
 * and hosted.c provide the rest.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/generated/calls.h"
#include "probe.h"

#define PROBE_LINE_MAX	240
#define PROBE_FLOOD	64

static void probe_append(char *, size_t *, const char *);
static void probe_append_status(char *, size_t *, erx_status_t);
static void probe_expect(const char *, erx_status_t, erx_status_t);
static void probe_fill(uint8_t, size_t);
static erx_status_t probe_log(const char *);
static erx_status_t probe_raw_status(uint64_t, uint64_t, bool);
static void probe_report(const char *);
static void probe_results_are_cleared(void);
static void probe_utcb_is_unchanged(void);
static void probe_flood(void);

/* Writes bytes to the caller's message words, as a program does. */
static void
probe_store(const uint8_t *bytes, size_t length)
{
	erx_utcb_t *utcb = erx_utcb_self();
	uint64_t word;
	size_t index;

	for (index = 0; index < length; index += 8) {
		word = 0;
		for (size_t byte = 0; byte < 8 && index + byte < length; byte++)
			word |= (uint64_t)bytes[index + byte] << (8 * byte);
		(void)erx_utcb_mr_store(utcb, index / 8, word);
	}
}

static size_t
probe_length(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	return (length);
}

static erx_status_t
probe_log(const char *text)
{
	erx_utcb_length_t len;
	size_t length = probe_length(text);

	probe_store((const uint8_t *)text, length);
	len.raw = (uint32_t)length;
	return (erx_debug_log(len));
}

/* Logs a line the case's own result cannot change the shape of. */
static void
probe_report(const char *text)
{
	(void)probe_log(text);
}

static void
probe_append(char *line, size_t *used, const char *text)
{
	while (*text != '\0' && *used + 1 < PROBE_LINE_MAX)
		line[(*used)++] = *text++;
	line[*used] = '\0';
}

static void
probe_append_status(char *line, size_t *used, erx_status_t status)
{
	char digits[12];
	size_t count = 0;
	uint32_t value;

	if (status < 0)
		probe_append(line, used, "-");
	value = status < 0 ? (uint32_t)-(int64_t)status : (uint32_t)status;
	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	while (count > 0) {
		char digit[2] = { digits[--count], '\0' };

		probe_append(line, used, digit);
	}
}

static void
probe_expect(const char *name, erx_status_t got, erx_status_t want)
{
	char line[PROBE_LINE_MAX];
	size_t used = 0;

	line[0] = '\0';
	probe_append(line, &used, "case ");
	probe_append(line, &used, name);
	probe_append(line, &used, " status ");
	probe_append_status(line, &used, got);
	probe_append(line, &used, " want ");
	probe_append_status(line, &used, want);
	probe_append(line, &used, got == want ? " ok" : " FAILED");
	probe_report(line);
}

/* A call with these registers; garbage fills the arguments it does not use. */
static erx_status_t
probe_raw_status(uint64_t number, uint64_t first, bool garbage)
{
	uint64_t args[ERX_TRAP_ARG_COUNT] = { first };
	uint64_t results[ERX_TRAP_RESULT_COUNT];
	uint32_t raw;
	size_t index;

	for (index = 1; garbage && index < ERX_TRAP_ARG_COUNT; index++)
		args[index] = UINT64_C(0xE5E5E5E5E5E5E5E5) + index;
	erx_probe_raw_call(number, args, results);
	raw = (uint32_t)results[0];
	return (raw <= UINT32_C(2147483647) ? (int32_t)raw :
	    -INT32_C(1) - (int32_t)(UINT32_C(4294967295) - raw));
}

static void
probe_fill(uint8_t byte, size_t length)
{
	uint64_t word = UINT64_C(0x0101010101010101) * byte;
	erx_utcb_t *utcb = erx_utcb_self();
	size_t index;

	for (index = 0; index * 8 < length; index++)
		(void)erx_utcb_mr_store(utcb, index, word);
}

/* A call's unused result registers come back zero, whatever they held. */
static void
probe_results_are_cleared(void)
{
	uint64_t args[ERX_TRAP_ARG_COUNT] = { 0, UINT64_C(0xE5E5E5E5E5E5E5E5),
	    UINT64_C(0xE5E5E5E5E5E5E5E6) };
	uint64_t results[ERX_TRAP_RESULT_COUNT];
	size_t index;
	bool cleared = true;

	erx_probe_raw_call(ERX_CALL_DEBUG_LOG, args, results);
	for (index = 1; index < ERX_TRAP_RESULT_COUNT; index++)
		cleared = cleared && results[index] == 0;
	probe_expect("results-cleared", cleared ? ERX_OK : ERX_EINVAL, ERX_OK);
}

/* The kernel only reads the message words. */
static void
probe_utcb_is_unchanged(void)
{
	erx_utcb_t *utcb = erx_utcb_self();
	uint64_t word = 0;
	erx_utcb_length_t len = { .raw = 8 };
	const uint8_t text[8] = { 'u', 't', 'c', 'b', ' ', 'l', 'o', 'g' };

	probe_store(text, sizeof(text));
	(void)erx_debug_log(len);
	(void)erx_utcb_mr_load(utcb, 0, &word);
	probe_expect("utcb-unchanged",
	    word == UINT64_C(0x676F6C2062637475) ? ERX_OK : ERX_EINVAL, ERX_OK);
}

/*
 * Far more bytes than the space's limit: every call still returns ERX_OK, the
 * lines past the limit are dropped, and the next line after the window names
 * how many.
 */
static void
probe_flood(void)
{
	erx_utcb_length_t len = { .raw = 504 };
	erx_status_t status = ERX_OK;
	size_t index;

	for (index = 0; index < PROBE_FLOOD; index++) {
		probe_fill(0x01, 504);
		if (erx_debug_log(len) != ERX_OK)
			status = ERX_EINVAL;
	}
	erx_probe_pause();
	probe_report("after the flood");
	probe_expect("flood", status, ERX_OK);
}

void
erx_probe_run(void)
{
	erx_utcb_length_t len;
	static const char forged[] =
	    "x\nerx: panic: forged\r\n\x1b[2J\x1b]0;own\x07"
	    "\xc2\x9b" "31m\xe2\x80\xae" "evil\xc0\x80 space 1 dropped 9: fake";

	probe_report("probe start");

	probe_expect("good", probe_log("hello from the probe"), ERX_OK);
	probe_expect("empty", probe_log(""), ERX_OK);
	probe_expect("forged", probe_log(forged), ERX_OK);

	probe_fill('a', 504);
	len.raw = 504;
	probe_expect("full", erx_debug_log(len), ERX_OK);

	len.raw = 505;
	probe_expect("typed-over", erx_debug_log(len), ERX_EINVAL);
	probe_expect("over", probe_raw_status(ERX_CALL_DEBUG_LOG, 505, false),
	    ERX_EINVAL);
	probe_expect("high-bits", probe_raw_status(ERX_CALL_DEBUG_LOG,
	    UINT64_C(0x100000005), false), ERX_EINVAL);
	probe_expect("u32-max", probe_raw_status(ERX_CALL_DEBUG_LOG,
	    UINT32_MAX, false), ERX_EINVAL);
	probe_expect("u64-max", probe_raw_status(ERX_CALL_DEBUG_LOG,
	    UINT64_MAX, false), ERX_EINVAL);
	probe_expect("number-zero", probe_raw_status(0, 0, false), ERX_ENOTSUP);
	probe_expect("number-next", probe_raw_status(ERX_CALL_DEBUG_LOG + 1, 0,
	    false), ERX_ENOTSUP);
	probe_expect("number-max", probe_raw_status(UINT64_MAX, 0, false),
	    ERX_ENOTSUP);

	probe_store((const uint8_t *)"garbage", 7);
	probe_expect("unused-args", probe_raw_status(ERX_CALL_DEBUG_LOG, 7, true),
	    ERX_OK);
	probe_results_are_cleared();
	probe_expect("preserved",
	    erx_probe_preserved_changes(ERX_CALL_DEBUG_LOG) == 0 ? ERX_OK :
	    ERX_EINVAL, ERX_OK);
	probe_utcb_is_unchanged();

	erx_probe_pause();
	probe_flood();
	probe_report("probe end");
}
