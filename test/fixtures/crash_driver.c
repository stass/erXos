/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the crash core (kernel/core/crash.c, crash_frame.c and
 * crash_read.c). It reads one command per line from the file named by its
 * argument and prints what the core did, for test/host/crash_test.rb and
 * tools/lib/erx/crash_frame.rb to judge. Bytes are hex; "-" is no bytes.
 *
 *   crc HEX                 -> crc VALUE
 *   check HEX               -> check NAME
 *   previous FORM HEX       -> previous LENGTH
 *   read HEX                -> read STATUS REASON CHECK LENGTH START END RECORD-HEX
 *   write FORM CAUSE CPU VALUE SLOT NFRAMES FRAMES REGS KIND MESSAGE-HEX LOG-LINES END
 *                           -> record LENGTH CHECK HEX
 *                              frame HEX
 *
 * FRAMES and REGS are 0 for a NULL pointer and 1 for a filled array. The fault
 * record is zero when KIND is 0 and otherwise filled. MESSAGE-HEX "-" is NULL.
 * LOG-LINES is how many lines the log holds, -1 for a NULL log and -2 for a log
 * whose counters a wild store has corrupted. END is "machine" for a frame
 * written as the machine goes down and "task" for one written for a task's
 * fault while the machine runs on.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/crash.h"
#include "erx/log.h"

#define DRIVER_HEX_MAX	(4 * ERX_CRASH_SIZE + 16)
#define DRIVER_LINE_MAX	(2 * DRIVER_HEX_MAX + 256)
#define DRIVER_FRAME_MAX (2 * ERX_CRASH_SIZE)
#define DRIVER_LOG_CORRUPT (-2)

static _Alignas(8) uint8_t driver_record[ERX_CRASH_SIZE];
static _Alignas(8) uint8_t driver_scratch[ERX_CRASH_SCRATCH_BYTES];
static char driver_line[DRIVER_LINE_MAX];
static uint8_t driver_bytes[DRIVER_HEX_MAX];
static uint8_t driver_frame[DRIVER_FRAME_MAX];
static size_t driver_frame_used;
static erx_log_t driver_log;

static void driver_command(char *);
static void driver_fail(const char *);
static void driver_print_hex(const uint8_t *, size_t);
static size_t driver_unhex(const char *);
static void driver_write(char *);

static const char *const driver_checks[] = {
	"ok", "short", "magic", "version", "form", "length", "crc", "cause", "cpu",
	"boot", "padding", "nframes", "fault", "regs", "frames", "text", "not_run",
};
static const char *const driver_statuses[] = {
	"none", "absent", "valid", "truncated", "corrupt",
};
static const char *const driver_reasons[] = {
	"none", "cut", "early_end", "header", "second_header", "line_length",
	"base64", "no_end", "record",
};

/* The core's one effect: this file keeps what a console would show. */
void
erx_effect_console_write(const char *line, size_t length)
{
	if (length > sizeof(driver_frame) - driver_frame_used)
		driver_fail("the frame does not fit");
	memcpy(driver_frame + driver_frame_used, line, length);
	driver_frame_used += length;
}

static void
driver_fail(const char *reason)
{
	fprintf(stderr, "crash_driver: %s\n", reason);
	exit(2);
}

static size_t
driver_unhex(const char *text)
{
	size_t length;
	unsigned int byte;

	if (strcmp(text, "-") == 0)
		return (0);
	length = strlen(text);
	if (length % 2 != 0 || length / 2 > sizeof(driver_bytes))
		driver_fail("bad hex");
	for (size_t index = 0; index < length / 2; index++) {
		if (sscanf(text + 2 * index, "%2x", &byte) != 1)
			driver_fail("bad hex");
		driver_bytes[index] = (uint8_t)byte;
	}
	return (length / 2);
}

static void
driver_print_hex(const uint8_t *bytes, size_t length)
{
	if (length == 0)
		fputc('-', stdout);
	for (size_t index = 0; index < length; index++)
		printf("%02x", bytes[index]);
}

static void
driver_write(char *arguments)
{
	static uint64_t frames[128];
	static uint8_t regs[ERX_CRASH_REGS_BYTES];
	static char message[DRIVER_HEX_MAX];
	erx_crash_input_t input;
	char message_hex[DRIVER_LINE_MAX], end[16];
	unsigned int form, cause, cpu, value, slot, nframes, has_frames, has_regs, kind;
	size_t length, message_length;
	int lines;

	if (sscanf(arguments, "%u %u %u %u %u %u %u %u %u %s %d %15s", &form, &cause,
	    &cpu, &value, &slot, &nframes, &has_frames, &has_regs, &kind, message_hex,
	    &lines, end) != 12)
		driver_fail("bad write");
	if (strcmp(end, "machine") != 0 && strcmp(end, "task") != 0)
		driver_fail("bad write: END is machine or task");
	for (size_t index = 0; index < 128; index++)
		frames[index] = 0x1000 + index;
	memset(regs, 0x5a, sizeof(regs));
	message_length = driver_unhex(message_hex);
	memcpy(message, driver_bytes, message_length);

	memset(&input, 0, sizeof(input));
	input.form = form;
	input.cause = cause;
	input.cpu = cpu;
	input.boot_value = value;
	input.boot_slot = slot;
	input.nframes = nframes;
	input.uptime_ns = UINT64_C(0x1122334455667788);
	input.since_pet_ns = UINT64_C(5000000000);
	memcpy(input.build_id, "BUILDID8", sizeof(input.build_id));
	if (kind != 0) {
		input.fault = (erx_crash_fault_t){ .kind = kind, .cause = 7,
		    .addr = 0xdead, .pc = 0xbeef, .thread = 3, .space = 4, .status = -1 };
	}
	input.regs = has_regs != 0 ? regs : NULL;
	input.frames = has_frames != 0 ? frames : NULL;
	input.message = strcmp(message_hex, "-") == 0 ? NULL : message;
	input.message_length = message_length;

	memset(&driver_log, 0, sizeof(driver_log));
	for (int index = 0; index < lines; index++) {
		if (ERX_LOG_FORMAT(&driver_log, ERX_LOG_LEVEL_INFO, (uint64_t)index,
		    "line %d of the log, with padding to make it longer", index) != ERX_OK)
			driver_fail("the log refused a line");
	}
	if (lines == DRIVER_LOG_CORRUPT)
		driver_log.next_seq = UINT64_C(0x7fffffffffffffff);
	input.log = lines >= 0 || lines == DRIVER_LOG_CORRUPT ? &driver_log : NULL;

	/* A stale buffer must not reach the record. */
	memset(driver_record, 0xa5, sizeof(driver_record));
	length = erx_crash_record_write(&input, driver_record, driver_scratch);
	printf("record %zu %s ", length,
	    driver_checks[erx_crash_check(driver_record, length)]);
	driver_print_hex(driver_record, length);
	fputc('\n', stdout);
	for (size_t index = length; index < sizeof(driver_record); index++) {
		if (driver_record[index] != 0)
			driver_fail("a byte past the record's length is not zero");
	}

	driver_frame_used = 0;
	erx_crash_frame_write(driver_record, strcmp(end, "task") == 0 ?
	    ERX_CRASH_END_TASK : ERX_CRASH_END_MACHINE);
	fputs("frame ", stdout);
	driver_print_hex(driver_frame, driver_frame_used);
	fputc('\n', stdout);
}

static void
driver_command(char *line)
{
	erx_crash_read_t read;
	char *name, *rest, *hex;
	size_t length;
	unsigned int form;

	name = strtok_r(line, " \n", &rest);
	if (name == NULL)
		return;
	if (strcmp(name, "write") == 0) {
		driver_write(rest);
	} else if (strcmp(name, "previous") == 0) {
		form = (unsigned int)strtoul(strtok_r(NULL, " \n", &rest), NULL, 10);
		hex = strtok_r(NULL, " \n", &rest);
		length = driver_unhex(hex);
		printf("previous %u\n", erx_crash_previous_length(driver_bytes, length, form));
	} else {
		hex = strtok_r(NULL, " \n", &rest);
		if (hex == NULL)
			driver_fail("no bytes");
		length = driver_unhex(hex);
		if (strcmp(name, "crc") == 0) {
			printf("crc %u\n", erx_crash_crc32c(driver_bytes, length));
		} else if (strcmp(name, "check") == 0) {
			printf("check %s\n",
			    driver_checks[erx_crash_check(driver_bytes, length)]);
		} else if (strcmp(name, "read") == 0) {
			read = erx_crash_frame_read(driver_bytes, length, driver_record);
			printf("read %s %s %s %u %zu %zu ", driver_statuses[read.status],
			    driver_reasons[read.reason], driver_checks[read.check],
			    read.length, read.frame_start, read.frame_end);
			driver_print_hex(driver_record,
			    read.status == ERX_CRASH_READ_VALID ? read.length : 0);
			fputc('\n', stdout);
		} else {
			driver_fail("unknown command");
		}
	}
}

int
main(int argc, char **argv)
{
	FILE *input;

	if (argc != 2)
		driver_fail("usage: crash_driver FILE");
	input = fopen(argv[1], "r");
	if (input == NULL)
		driver_fail("cannot open the command file");
	while (fgets(driver_line, sizeof(driver_line), input) != NULL)
		driver_command(driver_line);
	fclose(input);
	return (0);
}
