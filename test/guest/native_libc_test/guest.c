/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root that runs musl's libc-test: every program under boot/libc-test/ in the
 * boot image runs as a task of its own, one after another, in one boot, since a task's
 * fault leaves the machine running. It reports what it saw and judges nothing:
 * tools/lib/erx/libc_test.rb reads these lines. A task's output lies between them as it
 * wrote it, so each end line opens with a newline: output with no final newline stays
 * on a line of its own, and the line after it is still a whole one of the root's.
 *
 *   erx: libc-test: run NAME          the task is about to start
 *   erx: libc-test: end NAME status N the program exited with N
 *   erx: libc-test: end NAME fault    the task faulted, and its crash frame came before this line
 *   erx: libc-test: end NAME timeout  it was still running at its deadline, and was stopped
 *   erx: libc-test: end NAME no-program the task came up without running the program
 *   erx: libc-test: end NAME other N  the task said N, which no exit can: musl's start came back
 *   erx: libc-test: end NAME launch-refused N  the launch said N, and nothing ran
 *   erx: libc-test: end NAME join-refused N    the join said N, and no status exists
 *   erx: libc-test: pool B A          the pool's free pages before the first task and after the last
 *   erx: libc-test: done              the last line
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/service.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/vm.h"

#define PREFIX		"boot/libc-test/"
#define PREFIX_BYTES	(sizeof(PREFIX) - 1)
#define NS_PER_SECOND	UINT64_C(1000000000)
/* The status the root gives a task it stops at its deadline, which no one reads as the task's. */
#define STATUS_STOPPED	INT64_C(-100)

#ifndef LIBC_TEST_SECONDS
#error "the build names each task's deadline"
#endif

void	erx_fiasco_root_main(void);

static void
say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

static void
say_number(int64_t value)
{
	uint64_t rest = value < 0 ? -(uint64_t)value : (uint64_t)value;
	char digits[24];
	int used = 0;

	if (value < 0)
		say("-");
	do {
		digits[used++] = (char)('0' + rest % 10);
		rest /= 10;
	} while (rest != 0);
	while (used > 0) {
		const char one[2] = { digits[--used], '\0' };

		say(one);
	}
}

static void
say_line_start(const char *what, const uint8_t *name, size_t length)
{
	say("erx: libc-test: ");
	say(what);
	say(" ");
	erx_fiasco_console_write((const char *)name, length);
}

static bool
is_test(const uint8_t *path, size_t length)
{
	if (length <= PREFIX_BYTES)
		return (false);
	for (size_t index = 0; index < PREFIX_BYTES; index++)
		if (path[index] != (uint8_t)PREFIX[index])
			return (false);
	return (true);
}

/* Starts one task and waits for its end, stopping it at its deadline. */
static void
test_run(uint32_t entry, const uint8_t *name, size_t length)
{
	const uint64_t deadline = erx_fiasco_clock_ns() + LIBC_TEST_SECONDS * NS_PER_SECOND;
	uint64_t space = 0;
	int64_t status = 0;
	bool stopped = false;
	bool launched;
	int result;

	say_line_start("run", name, length);
	say("\n");
	result = erx_fiasco_launch(entry, 0, 0, &space);
	launched = result == ERX_OK;
	if (launched) {
		result = erx_fiasco_task_join_until(space, deadline, &status);
		if (result == ERX_ETIMEDOUT) {
			/* A task that ended by itself just now keeps its own status: a stop of a stopped space changes nothing. */
			(void)erx_space_stop(space, STATUS_STOPPED);
			result = erx_fiasco_task_join(space, &status);
			stopped = result == ERX_OK && status == STATUS_STOPPED;
		}
	}
	say("\n");
	say_line_start("end", name, length);
	if (result != ERX_OK) {
		say(launched ? " join-refused " : " launch-refused ");
		say_number(result);
	} else if (stopped) {
		say(" timeout");
	} else if (status == ERX_FIASCO_TASK_STATUS_FAULT) {
		say(" fault");
	} else if (status == ERX_FIASCO_TASK_STATUS_UP) {
		say(" no-program");
	} else {
		say(status < 0 ? " other " : " status ");
		say_number(status);
	}
	say("\n");
}

void
erx_fiasco_root_main(void)
{
	erx_boot_handoff_view_t handoff;
	static erx_pack_view_t pack;
	const char *reason = erx_fiasco_root_open(&handoff, &pack);
	uint64_t before;

	if (reason == NULL)
		reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff.image.start, (size_t)handoff.image.size);
	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	erx_fiasco_task_set_archive(&pack);
	before = erx_fiasco_vm_free_pages();
	for (uint32_t index = 0; index < pack.header.nentries; index++) {
		const uint8_t *path;
		size_t length;

		if (erx_pack_path_at(&pack, index, &path, &length) && is_test(path, length))
			test_run(index, path + PREFIX_BYTES, length - PREFIX_BYTES);
	}
	say("erx: libc-test: pool ");
	say_number((int64_t)before);
	say(" ");
	say_number((int64_t)erx_fiasco_vm_free_pages());
	say("\n");
	say("erx: libc-test: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	erx_fiasco_sleep_forever();
}
