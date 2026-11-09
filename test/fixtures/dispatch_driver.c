/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Plays a kernel's trap handler over kernel/core/dispatch.c: takes register
 * snapshots, provides the effects, and prints what came back for
 * test/host/dispatch_test.rb to judge.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/debug_log.h"
#include "erx/core/dispatch.h"
#include "erx/core/effects.h"
#include "erx/log.h"

#define CONSOLE_LINES	512

static uint64_t driver_clock;
static int driver_lock_depth;
static uint64_t driver_locks;
static char driver_console[CONSOLE_LINES][ERX_LOG_LINE_MAX + 1];
static size_t driver_console_lines;

void
erx_effect_log_lock(void)
{
	if (driver_lock_depth++ != 0)
		abort();
	driver_locks++;
}

void
erx_effect_log_unlock(void)
{
	if (--driver_lock_depth != 0)
		abort();
}

uint64_t
erx_effect_clock_ns(void)
{
	return (driver_clock);
}

void
erx_effect_console_write(const char *line, size_t length)
{
	if (driver_lock_depth != 1 || driver_console_lines == CONSOLE_LINES ||
	    length > ERX_LOG_LINE_MAX)
		abort();
	memcpy(driver_console[driver_console_lines], line, length);
	driver_console[driver_console_lines++][length] = '\0';
}

static erx_utcb_t driver_utcb;
static erx_log_rate_t driver_rate;

static void
driver_text(const void *text, size_t length)
{
	const uint8_t *bytes = text;

	for (size_t index = 0; index < length; index += 8) {
		uint64_t word = 0;

		for (size_t byte = 0; byte < 8 && index + byte < length; byte++)
			word |= (uint64_t)bytes[index + byte] << (8 * byte);
		if (!erx_utcb_mr_store(&driver_utcb, index / 8, word))
			abort();
	}
}

static void
driver_call(uint64_t space, erx_log_rate_t *rate, uint64_t number,
    const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT])
{
	erx_sys_caller_t caller = { .utcb = &driver_utcb, .log_rate = rate,
	    .space = space, .executor = false };

	for (size_t index = 0; index < ERX_TRAP_RESULT_COUNT; index++)
		results[index] = UINT64_C(0xE5E5E5E5E5E5E5E5);
	erx_dispatch(&caller, number, args, results);
}

static int
driver_report(uint64_t number, uint64_t first, bool garbage)
{
	uint64_t args[ERX_TRAP_ARG_COUNT] = { first };
	uint64_t results[ERX_TRAP_RESULT_COUNT];

	for (size_t index = 1; garbage && index < ERX_TRAP_ARG_COUNT; index++)
		args[index] = UINT64_C(0xE5E5E5E5E5E5E5E5) + index;
	driver_call(7, &driver_rate, number, args, results);
	printf("status %" PRId32 " r1 %" PRIu64 " r2 %" PRIu64 " locks %" PRIu64 "\n",
	    (int32_t)(uint32_t)results[0], results[1], results[2], driver_locks);
	for (size_t index = 0; index < driver_console_lines; index++)
		fputs(driver_console[index], stdout);
	return (0);
}

/* One line of space 7, a second of the clock after the last, so no rate limit bites. */
static void
driver_log(const char *text)
{
	uint64_t args[ERX_TRAP_ARG_COUNT] = { strlen(text) };
	uint64_t results[ERX_TRAP_RESULT_COUNT];

	driver_clock += UINT64_C(1000000000);
	driver_text(text, strlen(text));
	driver_call(7, &driver_rate, ERX_CALL_DEBUG_LOG, args, results);
	if (results[0] != 0)
		abort();
}

/*
 * Prints one window of records as "who OP STATUS lost N", then "who LINE" for each record.
 */
static void
driver_print_window(const char *who, const char *op, const erx_log_copy_result_t *copied,
    const uint8_t *window)
{
	static char text[ERX_LOG_TEXT_MAX], line[ERX_LOG_LINE_MAX + 1];
	erx_log_view_t view;
	size_t offset = 0;

	printf("%s %s %d lost %" PRIu64 "\n", who, op, (int)copied->status, copied->lost);
	if (copied->status != ERX_OK)
		return;
	while (erx_log_next_record(window, copied->written, &offset, text, &view) ==
	    ERX_LOG_NEXT_RECORD) {
		line[erx_log_render(&view, line, ERX_LOG_LINE_MAX)] = '\0';
		printf("%s %s", who, line);
	}
}

/* One read from the cursor of the reader called who, into a window of size bytes. */
static void
driver_read_as(const char *who, uint64_t *cursor, size_t size)
{
	static uint8_t window[2 * ERX_LOG_RECORD_MAX];
	const erx_log_copy_result_t copied = erx_debug_log_read(*cursor, window, size);

	driver_print_window(who, "read", &copied, window);
	if (copied.status == ERX_OK)
		*cursor = copied.next_cursor;
}

/* One take by the console, erx_console's read, which moves the log's one shared position. */
static void
driver_take(void)
{
	static uint8_t window[2 * ERX_LOG_RECORD_MAX];
	const erx_log_copy_result_t copied = erx_debug_log_take(window, sizeof(window));

	driver_print_window("erx_console", "take", &copied, window);
}

static void
driver_console_dump(void)
{
	for (size_t index = 0; index < driver_console_lines; index++)
		printf("console %s", driver_console[index]);
	driver_console_lines = 0;
}

/*
 * The handoff (docs/design-stopgap.md, "The console"): a line before it reaches the early
 * console, lines after it reach only the console's take, a reader from the start sees every
 * line and a cursor past the newest record is refused, taking the log back writes only what
 * the console had not taken, and from then on a take finds nothing. Each step prints in
 * order.
 */
static int
driver_handoff(void)
{
	uint64_t cursor = 0;

	driver_log("before");
	driver_console_dump();
	erx_debug_log_hand_to_console();
	driver_log("after-one");
	driver_log("after-two");
	driver_console_dump();
	driver_take();
	driver_take();
	driver_log("parked");
	driver_read_as("reader", &cursor, 2 * ERX_LOG_RECORD_MAX);
	cursor += 1;
	driver_read_as("reader", &cursor, 2 * ERX_LOG_RECORD_MAX);
	erx_debug_log_take_back();
	driver_console_dump();
	printf("taken back\n");
	driver_log("taken-back");
	driver_console_dump();
	driver_take();
	return (0);
}

/*
 * Two readers on one log (docs/design-stopgap.md, "The console"): the console's take starts
 * where the early console stopped, however often the UART is mapped, and loses no line and
 * shows none twice, while another reader from the start sees every line, also when it reads
 * ahead of the console. Neither that reader nor one whose window stops short of the newest
 * record moves the shared position, so taking the log back writes only "parked".
 */
static int
driver_readers(void)
{
	uint64_t other = 0, short_window = 0;
	char text[501];

	memset(text, 'l', sizeof(text) - 1);
	text[sizeof(text) - 1] = '\0';
	driver_log("boot-one");
	driver_log("boot-two");
	driver_console_dump();
	erx_debug_log_hand_to_console();
	driver_log("after-one");
	driver_read_as("other", &other, 2 * ERX_LOG_RECORD_MAX);
	erx_debug_log_hand_to_console();
	driver_log("after-two");
	driver_read_as("other", &other, 2 * ERX_LOG_RECORD_MAX);
	driver_take();
	for (int index = 0; index < 4; index++)
		driver_log(text);
	driver_read_as("short", &short_window, ERX_LOG_RECORD_MAX);
	driver_take();
	driver_log("parked");
	driver_read_as("other", &other, 2 * ERX_LOG_RECORD_MAX);
	driver_console_dump();
	printf("taken back\n");
	erx_debug_log_take_back();
	driver_console_dump();
	return (0);
}

/*
 * A parked ring that wraps: taking it back says how many records were lost, then the rest,
 * and a reader from the start is told the same loss.
 */
static int
driver_wrap(void)
{
	uint64_t cursor = 0;
	char text[401];

	memset(text, 'w', sizeof(text) - 1);
	text[sizeof(text) - 1] = '\0';
	erx_debug_log_hand_to_console();
	for (int index = 0; index < 400; index++)
		driver_log(text);
	erx_debug_log_take_back();
	driver_console_dump();
	driver_read_as("reader", &cursor, ERX_LOG_RECORD_MAX);
	return (0);
}

/* A flooding space and a quiet one on one log: the limit is the space's. */
static int
driver_two_spaces(void)
{
	static erx_log_rate_t flooder, other;
	uint64_t args[ERX_TRAP_ARG_COUNT] = { 504 };
	uint64_t results[ERX_TRAP_RESULT_COUNT];
	char controls[504];
	char expected[64];
	size_t flood_lines = 0;

	memset(controls, 1, sizeof(controls));
	driver_text(controls, sizeof(controls));
	driver_clock = UINT64_C(1000000000);
	for (int index = 0; index < 64; index++)
		driver_call(1, &flooder, ERX_CALL_DEBUG_LOG, args, results);
	flood_lines = driver_console_lines;
	if (flood_lines == 0 || flood_lines >= 64)
		return (1);

	driver_text("other passes", 12);
	args[0] = 12;
	driver_call(2, &other, ERX_CALL_DEBUG_LOG, args, results);
	if (driver_console_lines != flood_lines + 1 ||
	    strstr(driver_console[flood_lines], "space 2: other passes") == NULL)
		return (1);
	puts("other passes");

	driver_clock += UINT64_C(2000000000);
	driver_call(1, &flooder, ERX_CALL_DEBUG_LOG, args, results);
	snprintf(expected, sizeof(expected), "space 1 dropped %zu: ", 64 - flood_lines);
	if (strstr(driver_console[driver_console_lines - 1], expected) == NULL)
		return (1);
	puts("flooder counted");
	return (0);
}

int
main(int argc, char **argv)
{
	const char *name = argc > 1 ? argv[1] : "";
	char controls[504];

	driver_clock = UINT64_C(1000000000);
	if (strcmp(name, "good") == 0 || strcmp(name, "garbage") == 0) {
		driver_text("hello", 5);
		return (driver_report(ERX_CALL_DEBUG_LOG, 5,
		    strcmp(name, "garbage") == 0));
	}
	if (strcmp(name, "empty") == 0)
		return (driver_report(ERX_CALL_DEBUG_LOG, 0, false));
	if (strcmp(name, "over") == 0)
		return (driver_report(ERX_CALL_DEBUG_LOG, 505, false));
	if (strcmp(name, "high-bits") == 0)
		return (driver_report(ERX_CALL_DEBUG_LOG,
		    UINT64_C(0x100000005), false));
	if (strcmp(name, "u32-max") == 0)
		return (driver_report(ERX_CALL_DEBUG_LOG, UINT32_MAX, false));
	if (strcmp(name, "u64-max") == 0)
		return (driver_report(ERX_CALL_DEBUG_LOG, UINT64_MAX, false));
	if (strcmp(name, "number-zero") == 0)
		return (driver_report(0, 0, false));
	if (strcmp(name, "number-next") == 0)
		return (driver_report(ERX_CALL_DEBUG_LOG + 1, 0, false));
	if (strcmp(name, "number-max") == 0)
		return (driver_report(UINT64_MAX, 0, false));
	if (strcmp(name, "full-controls") == 0) {
		memset(controls, 1, sizeof(controls));
		driver_text(controls, sizeof(controls));
		return (driver_report(ERX_CALL_DEBUG_LOG, 504, false));
	}
	if (strcmp(name, "forged") == 0) {
		static const char forged[] = "x\nerx: panic: forged";

		driver_text(forged, sizeof(forged) - 1);
		return (driver_report(ERX_CALL_DEBUG_LOG, sizeof(forged) - 1,
		    false));
	}
	if (strcmp(name, "status-word") == 0) {
		uint64_t args[ERX_TRAP_ARG_COUNT] = { 505 };
		uint64_t results[ERX_TRAP_RESULT_COUNT];

		driver_call(7, &driver_rate, ERX_CALL_DEBUG_LOG, args, results);
		printf("%016" PRIx64 "\n", results[0]);
		return (0);
	}
	if (strcmp(name, "two-spaces") == 0)
		return (driver_two_spaces());
	if (strcmp(name, "handoff") == 0)
		return (driver_handoff());
	if (strcmp(name, "wrap") == 0)
		return (driver_wrap());
	if (strcmp(name, "readers") == 0)
		return (driver_readers());
	return (2);
}
