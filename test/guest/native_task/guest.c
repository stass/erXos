/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root of the second-task suite: it loads test/guest/native_task/program.c from the
 * boot image and runs one task per case, in order. Each case says one line, and
 * tools/lib/erx/native_task.rb holds the transcript to them. A fault's crash frame comes
 * between the line that says where it will land and the line that says the machine went on.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/service.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_task/modes.h"

#define PROGRAM		"boot/native-task"
#define RACE_ROUNDS	1000u

void erx_fiasco_root_main(void);

static void
say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

static void
say_number(uint64_t value)
{
	char digits[24];
	int used = 0;

	do {
		digits[used++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	while (used > 0) {
		const char one[2] = { digits[--used], '\0' };

		say(one);
	}
}

static void
say_case(const char *name, bool passed)
{
	say("erx: task: ");
	say(name);
	say(passed ? " ok\n" : " FAILED\n");
}

static void
say_status(int64_t status)
{
	say("erx: task: status ");
	if (status < 0) {
		say("-");
		say_number((uint64_t)0 - (uint64_t)status);
	} else {
		say_number((uint64_t)status);
	}
	say("\n");
}

static void
say_address(uint64_t addr)
{
	static const char digits[] = "0123456789abcdef";
	char line[] = "erx: task: address 0000000000000000\n";

	for (int digit = 0; digit < 16; digit++)
		line[19 + digit] = digits[(addr >> (60 - 4 * digit)) & 0xf];
	say(line);
}

static uint32_t program_entry;

/* One task, from launch to join; its index and its pages are free again when this returns. */
static int64_t
task_run(uint32_t flags, uint64_t mode, uint64_t *space)
{
	int64_t status = INT64_MIN;
	int result = erx_fiasco_launch(program_entry, flags, mode, space);

	if (result == ERX_OK)
		result = erx_fiasco_task_join(*space, &status);
	return (result == ERX_OK ? status : INT64_MIN);
}

/* A case that ends by itself: its status, its capabilities gone, and the pool's count back. */
static void
case_ends(const char *name, uint32_t flags, uint64_t mode, int64_t expected)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t space = 0;
	const int64_t status = task_run(flags, mode, &space);

	say_status(status);
	say_case(name, status == expected && erx_fiasco_test_task_caps_gone() &&
	    erx_fiasco_vm_free_pages() == before);
}

/*
 * A task cannot make an IRQ object, and reaches none through a handle it was not given: the
 * root holds an object, within the handles the task probes, while the task runs, and still
 * holds it afterwards.
 */
static void
case_irq_refused(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t bell = 0, space = 0;
	const bool made = erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &bell) == ERX_OK && bell >= 1 && bell <= IRQ_SCAN;
	const int64_t status = made ? task_run(0, MODE_IRQ_REFUSED, &space) : INT64_MIN;
	const bool kept = made && erx_object_destroy(bell) == ERX_OK;

	say_status(status);
	say_case("irq_refused", made && status == 0 && kept && erx_fiasco_test_task_caps_gone() &&
	    erx_fiasco_vm_free_pages() == before);
}

/* The root stops a task that has not stopped itself, with the root's own status. */
static void
case_root_stops(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t space;
	int64_t status = 0;
	bool passed = erx_fiasco_launch(program_entry, 0, MODE_WAIT, &space) == ERX_OK &&
	    erx_space_stop(space, 33) == ERX_OK && erx_fiasco_task_join(space, &status) == ERX_OK && status == 33;

	say_case("root_stops", passed && erx_fiasco_vm_free_pages() == before);
}

/* A thread requesting while another faults, and the label reused at once each time. */
static void
case_race(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	bool passed = true;

	for (uint32_t round = 0; round < RACE_ROUNDS && passed; round++) {
		uint64_t space;

		passed = task_run(0, MODE_RACE, &space) == ERX_FIASCO_TASK_STATUS_FAULT;
	}
	say_case("request_against_exit", passed && erx_fiasco_test_dropped() == 0 &&
	    erx_fiasco_vm_free_pages() == before);
}

void
erx_fiasco_root_main(void)
{
	erx_boot_handoff_view_t handoff;
	static erx_pack_view_t pack;
	const char *reason = erx_fiasco_root_open(&handoff, &pack);

	if (reason == NULL)
		reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff.image.start, (size_t)handoff.image.size);
	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	erx_fiasco_task_set_archive(&pack);
	say_case("program_found", erx_fiasco_launcher_find(&pack, PROGRAM, &program_entry) == ERX_OK);
	say("erx: task: cpus ");
	say_number(erx_fiasco_test_cpu_count());
	say("\n");

	case_ends("yield", 0, MODE_YIELD, 0);
	case_ends("service", ERX_SPACE_JIT, MODE_SERVICE, 0);
	say_address(ALIAS_RX);
	case_ends("write_rx", ERX_SPACE_JIT, MODE_WRITE_RX, ERX_FIASCO_TASK_STATUS_FAULT);
	say_address(ALIAS_RW);
	case_ends("run_rw", ERX_SPACE_JIT, MODE_RUN_RW, ERX_FIASCO_TASK_STATUS_FAULT);
	case_ends("no_jit", 0, MODE_NO_JIT, 0);
	case_irq_refused();
	case_ends("device_refused", 0, MODE_DEVICE_REFUSED, 0);
	case_ends("log", 0, MODE_LOG, 0);
	case_ends("write", 0, MODE_WRITE, 0);
	case_ends("spin_stop", 0, MODE_SPIN_STOP, STATUS_SPIN_STOP);
	case_root_stops();
	case_race();
	say("erx: task: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	erx_fiasco_sleep_forever();
}
