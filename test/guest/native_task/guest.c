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
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/service.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/vm.h"
#include "liberx/backend/fiasco/thread.h"
#include "test/guest/native_task/modes.h"

#define PROGRAM		"boot/native-task"
#define RACE_ROUNDS	1000u
/*
 * How many milliseconds the root waits, blocked, for a task's threads to be live (task_live).
 * The root runs at the base level, above the app level of its tasks, so a yield would give
 * the CPU only to the root's own threads and the task would never run on one CPU.
 */
#define LIVE_WAITS	10000u
#define LIVE_WAIT_US	UINT64_C(1000)
/* The band case's window, in which the root counts its work, and how many windows it takes the best of. */
#define BAND_WINDOW_NS		UINT64_C(50000000)
#define BAND_WINDOWS		3u
/*
 * The quantum case's bounds on the median turn, in us, around the root's 1000 us slice. With
 * config/fiasco/kernel.defconfig choosing no one-shot timer, Fiasco ticks every 1 ms (its Kconfig's
 * SCHED_GRANULARITY), so a turn is one to two ticks; one-shot would give 1 ms. The bounds leave
 * room for HVF and still refuse Fiasco's own 10 ms quantum, which a task takes whose threads read
 * the slice from their own row rather than their domain's.
 */
#define QUANTUM_MIN_US		250
#define QUANTUM_MAX_US		4000
/*
 * The share case: the sched benchmark's landing cell of share-equal, four spinners for three
 * 1 s windows (docs/design-bench.md, "The gates").
 */
#if !defined(ERX_SHARE_SPINNERS) || !defined(ERX_SHARE_WINDOWS)
#error "the build passes the share case's sizes, which tools/lib/erx/native_task.rb holds its lines to"
#endif
#define SHARE_SPINNERS		ERX_SHARE_SPINNERS
#define SHARE_WINDOWS		ERX_SHARE_WINDOWS
#define SHARE_WINDOW_MS		1000u

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

/* A case that ends by itself: its status, its capabilities gone, and both pools' counts back. */
static void
case_ends(const char *name, uint32_t flags, uint64_t mode, int64_t expected)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	const uint32_t pairs = erx_fiasco_test_pool_free();
	uint64_t space = 0;
	const int64_t status = task_run(flags, mode, &space);

	say_status(status);
	say_case(name, status == expected && erx_fiasco_test_pool_slots_gone() &&
	    erx_fiasco_vm_free_pages() == before && erx_fiasco_test_pool_free() == pairs);
}

/*
 * A task the root makes with erx_space_create, as the domain library makes a domain's,
 * not through the launcher: it is no test task, so its raw write is refused. Its fault
 * gate, which every such create names, is made before the counts are read and goes
 * after they are compared, so the counts see only the task.
 */
static void
case_write_refused(void)
{
	uint64_t gate = ERX_CAP_NULL, space = 0, pc;
	int result = erx_gate_create(0, &gate);
	const uint64_t before = erx_fiasco_vm_free_pages();
	const uint32_t pairs = erx_fiasco_test_pool_free();
	int64_t status = INT64_MIN;
	bool counted;

	if (result == ERX_OK)
		result = erx_space_create(0, ERX_CAP_SELF, gate, 0, 0, erx_space_cap_limit_max(), &space);
	if (result == ERX_OK && erx_image_map(space, 0, program_entry, &pc) != ERX_OK) {
		(void)erx_space_stop(space, ERX_EINVAL);
		(void)erx_fiasco_task_join(space, &status);
		result = ERX_EINVAL;
	}
	/* A refused start stops and joins the task itself. */
	if (result == ERX_OK)
		result = erx_fiasco_launch_start(space, pc, MODE_WRITE_REFUSED);
	if (result == ERX_OK)
		result = erx_fiasco_task_join(space, &status);
	counted = erx_fiasco_test_pool_slots_gone() && erx_fiasco_vm_free_pages() == before &&
	    erx_fiasco_test_pool_free() == pairs;
	if (gate != ERX_CAP_NULL && (erx_object_destroy(gate) != ERX_OK ||
	    erx_cap_close((erx_cap_t){ .raw = gate }) != ERX_OK))
		result = ERX_EINVAL;
	say_status(status);
	say_case("write_refused", result == ERX_OK && status == 0 && counted);
}

/*
 * A task cannot make a line, and reaches no IRQ object through a handle it was not given:
 * the root holds an object while the task runs, the task's probes of its own handles 1 to
 * IRQ_SCAN reach nothing, and the root still holds the object afterwards. The doorbell the
 * task makes last goes with the task.
 */
static void
case_irq_refused(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t bell = 0, space = 0;
	const bool made = erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &bell, NULL) == ERX_OK;
	const int64_t status = made ? task_run(0, MODE_IRQ_REFUSED, &space) : INT64_MIN;
	const bool kept = made && erx_object_destroy(bell) == ERX_OK;

	say_status(status);
	say_case("irq_refused", made && status == 0 && kept && erx_fiasco_test_pool_slots_gone() &&
	    erx_fiasco_vm_free_pages() == before);
}

/*
 * Whether a launched task's threads came up within LIVE_WAITS: the slot pool is down to live
 * free pairs, the task's two and one for each of its threads taken.
 */
static bool
task_live(uint32_t live)
{
	for (uint32_t wait = 0; wait < LIVE_WAITS && erx_fiasco_test_pool_free() != live; wait++)
		erx_fiasco_test_ipc_sleep_us(LIVE_WAIT_US);
	return (erx_fiasco_test_pool_free() == live);
}

/*
 * The root stops a task that has not stopped itself, with the root's own status, once its
 * threads are live: the task's two pairs of the slot pool and one for each thread are
 * taken, and all of them are free again after the join.
 */
static void
case_root_stops(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	const uint32_t pairs = erx_fiasco_test_pool_free();
	const uint32_t live = pairs - 2 - (TASK_OWN_THREADS + WAIT_THREADS);
	uint64_t space;
	int64_t status = 0;
	const bool launched = erx_fiasco_launch(program_entry, 0, MODE_WAIT, &space) == ERX_OK;
	bool live_seen, passed;

	live_seen = launched && task_live(live);
	/* Stopped and joined even when its threads never came up, so a failure leaves nothing running. */
	passed = launched && erx_space_stop(space, 33) == ERX_OK &&
	    erx_fiasco_task_join(space, &status) == ERX_OK && status == 33 && live_seen;
	say_case("root_stops", passed && erx_fiasco_vm_free_pages() == before && erx_fiasco_test_pool_free() == pairs);
}

/* The most work the root's thread does in one window of BAND_WINDOWS. */
static uint64_t
band_work(void)
{
	uint64_t best = 0;

	for (uint32_t window = 0; window < BAND_WINDOWS; window++) {
		const uint64_t deadline = erx_fiasco_clock_ns() + BAND_WINDOW_NS;
		uint64_t done = 0;

		while (erx_fiasco_clock_ns() < deadline)
			done++;
		if (done > best)
			best = done;
	}
	return (best);
}

/*
 * The band case (docs/design-fiasco.md, "Verification", band): the root's thread, at the base
 * level, does no less work, within a tenth, while a launched task, at the app level, spins
 * SPIN_THREADS threads on the root's CPU. Were the task at the base level, the spinners would
 * share that CPU with the root's thread, a quantum each in turn.
 */
static void
case_band(void)
{
	const uint32_t pairs = erx_fiasco_test_pool_free();
	const uint32_t live = pairs - 2 - (TASK_OWN_THREADS + SPIN_THREADS);
	const uint64_t alone = band_work();
	uint64_t beside = 0, space;
	int64_t status = 0;
	const bool launched = erx_fiasco_launch(program_entry, 0, MODE_SPIN, &space) == ERX_OK;
	bool live_seen, passed;

	live_seen = launched && task_live(live);
	if (live_seen)
		beside = band_work();
	/* Stopped and joined even when its threads never came up, so a failure leaves nothing running. */
	passed = launched && erx_space_stop(space, 33) == ERX_OK &&
	    erx_fiasco_task_join(space, &status) == ERX_OK && status == 33 && live_seen;
	say_case("band", passed && beside >= alone - alone / 10 && erx_fiasco_test_pool_free() == pairs);
}

/*
 * The quantum case (docs/design-fiasco.md, "Bands"): a launched task's threads take their
 * domain row's slice as their quantum, here the root's ERX_FIASCO_ROOT_SLICE_US. The task's own
 * row is not a domain row and holds no slice, so a thread that read the slice there would
 * take Fiasco's 10 ms default.
 */
_Static_assert(ERX_FIASCO_ROOT_SLICE_US == 1000, "the quantum case's bounds are around a 1000 us slice");

static void
case_quantum(void)
{
	uint64_t space;
	const int64_t turn = task_run(0, MODE_TURNS, &space);

	say_status(turn);
	say_case("quantum", turn >= QUANTUM_MIN_US && turn <= QUANTUM_MAX_US);
}

/*
 * The share case (docs/design-bench.md, "2. `sched`: how a CPU is shared"): SHARE_SPINNERS
 * recording spinners of one task on the last CPU, off the root's unless the machine has one,
 * while the root waits in its join. The task writes its windows, which
 * tools/lib/erx/native_task.rb reads back; here the task's status and its pools are judged.
 */
static void
case_share(void)
{
	const uint32_t cpus = erx_fiasco_test_cpu_count();

	case_ends("share", 0, SHARE_ARGUMENT(SHARE_SPINNERS, cpus - 1, SHARE_WINDOWS, SHARE_WINDOW_MS), 0);
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
		reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff.image.start, (size_t)handoff.image.size, 0, NULL, ERX_FIASCO_ROOT_SLICE_US);
	if (reason != NULL) {
		say(reason);
		erx_fiasco_end(ERX_FIASCO_END_ASKED_OFF, NULL);
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
	case_ends("machine_end_refused", 0, MODE_MACHINE_END, 0);
	case_ends("pool_rounds", 0, MODE_POOL_ROUNDS, 0);
	case_ends("log", 0, MODE_LOG, 0);
	case_ends("write", 0, MODE_WRITE, 0);
	case_write_refused();
	case_ends("spin_stop", 0, MODE_SPIN_STOP, STATUS_SPIN_STOP);
	case_band();
	case_share();
	case_quantum();
	case_root_stops();
	case_race();
	say("erx: task: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	erx_fiasco_sleep_forever();
}
