/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The cycle probe (docs/design-bench.md, "The cycle counter"). Before its cells, the root
 * launches test/guest/native_task's program in MODE_CYCLES as a disposable task on the
 * root's CPU, whose records come to a gate bound to the root's thread, as vm's disposable
 * task's do. The task's exit record carries the cycles per tick in thousandths; a fault on
 * its read of the cycle counter is the answer that user mode may not read it, and the
 * root stops the faulted task.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/pack.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/log.h"
#include "test/guest/native_bench/bench_root.h"
#include "test/guest/native_task/modes.h"

#define PROGRAM		"boot/native-task"
#define TASK_CAP_LIMIT	64u
#define PROBE_LABEL	UINT64_C(0x5e000000000c0000)
/* The status the root stops a faulted probe with. */
#define PROBE_STOPPED	79

/* The CLOCK line's count from the probe's first record, 0 for unknown, saying why it is unknown. */
static uint64_t
probe_answer(const erx_fault_t *record)
{
	if (record->kind == ERX_FAULT_UNDEFINED) {
		bench_say("erx: bench: cycle counter: not readable in user mode\n");
		return (0);
	}
	if (record->kind != ERX_FAULT_EXIT || record->status < 0)
		bench_fail("erx: bench: the cycle probe ended without an answer FAILED\n");
	if (record->status == 0)
		bench_say("erx: bench: cycle counter: did not advance\n");
	return ((uint64_t)record->status);
}

uint64_t
bench_cycles_probe(const erx_pack_view_t *pack)
{
	uint64_t gate, space, pc, label;
	uint32_t entry;
	erx_fault_t answer, record;
	int64_t status = INT64_MIN;
	bool ended;

	if (erx_fiasco_launcher_find(pack, PROGRAM, &entry) != ERX_OK)
		bench_fail("erx: bench: no program for the cycle probe FAILED\n");
	if (erx_gate_create(0, &gate) != ERX_OK || erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) != ERX_OK ||
	    erx_space_create(0, ERX_CAP_SELF, gate, PROBE_LABEL, 0, TASK_CAP_LIMIT, &space) != ERX_OK ||
	    erx_image_map(space, 0, entry, &pc) != ERX_OK || erx_fiasco_launch_start(space, pc, MODE_CYCLES) != ERX_OK)
		bench_fail("erx: bench: the cycle probe did not start FAILED\n");
	if (!bench_record_wait(erx_fiasco_clock_ns() + PATIENCE_NS, &answer, &label) || label != PROBE_LABEL)
		bench_fail("erx: bench: the cycle probe sent no record FAILED\n");
	record = answer;
	ended = answer.kind == ERX_FAULT_EXIT || (erx_space_stop(space, PROBE_STOPPED) == ERX_OK &&
	    bench_record_wait(erx_fiasco_clock_ns() + PATIENCE_NS, &record, &label) && label == PROBE_LABEL &&
	    record.kind == ERX_FAULT_EXIT && record.status == PROBE_STOPPED);
	if (!ended || erx_fiasco_task_join_until(space, erx_fiasco_clock_ns() + PATIENCE_NS, &status) != ERX_OK ||
	    status != record.status || erx_object_destroy(gate) != ERX_OK ||
	    erx_cap_close((erx_cap_t){ .raw = gate }) != ERX_OK)
		bench_fail("erx: bench: the cycle probe did not end FAILED\n");
	return (probe_answer(&answer));
}
