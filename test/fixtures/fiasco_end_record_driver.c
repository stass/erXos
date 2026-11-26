/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root's crash records on the host (liberx/backend/fiasco/end_record.c): each
 * line names one end and the record it wrote, its form, its length, how many
 * trace slots it filled and its header's flags. The input names the full form every time; the boot image
 * decides, whatever the input names. Its last end is a root that only reads its handoff, as the
 * musl test root and the native bench root do: the handoff alone (root_handoff.c, built here
 * over test/fixtures/l4_stub, with the handoff's reader below) must give its records the image's form.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "erx/abi.h"
#include "erx/core/boot_args.h"
#include "erx/core/crash.h"
#include "erx/core/trace_ring.h"
#include "liberx/backend/fiasco/end_record.h"
#include "liberx/backend/fiasco/root_handoff.h"
#include "liberx/backend/fiasco/trace.h"

#define DRIVER_RINGS	4u

static erx_trace_ring_t driver_rings[DRIVER_RINGS];
static _Alignas(ERX_CRASH_BUFFER_ALIGN) uint8_t driver_record[ERX_CRASH_SIZE];
static _Alignas(ERX_CRASH_BUFFER_ALIGN) uint8_t driver_scratch[ERX_CRASH_SCRATCH_BYTES];

/* A development image's handoff with an empty boot line. */
const char *
erx_boot_handoff_accept(const uint8_t *record, size_t length, erx_boot_handoff_view_t *handoff)
{
	(void)record, (void)length;
	*handoff = (erx_boot_handoff_view_t){ .development = true, .bootargs = "", .bootargs_len = 0 };
	return (NULL);
}

/* The trace layer's part of the decision (trace.c) is the record's trace_none bit. */
void
erx_fiasco_trace_boot(bool on)
{
	erx_fiasco_end_trace(on);
}

/* One end of the root: its record's form, length and filled trace slots. */
static void
driver_end(const char *name, bool trace)
{
	static const char message[] = "root task fault";
	const erx_crash_input_t input = { .form = ERX_CRASH_FORM_FULL, .cause = ERX_CRASH_CAUSE_FAULT,
	    .boot_value = ERX_BOOT_VALUE_UNKNOWN, .boot_slot = ERX_BOOT_SLOT_NONE, .uptime_ns = 1000,
	    .message = message, .message_length = sizeof(message) - 1 };
	const erx_crash_record_t *record = (const erx_crash_record_t *)driver_record;
	uint32_t length, slots = 0;

	length = erx_fiasco_end_record_write(input, trace, driver_record, driver_scratch);
	if (record->header.form == ERX_CRASH_FORM_FULL) {
		for (size_t slot = 0; slot < ERX_CRASH_TRACE_RECORDS; slot++)
			slots += record->trace[slot].seq != 0;
	}
	printf("%s: %s %u trace %u flags %u\n", name, record->header.form == ERX_CRASH_FORM_FULL ? "full" :
	    record->header.form == ERX_CRASH_FORM_BRIEF ? "brief" : "neither", length, slots,
	    record->header.flags);
}

int
main(void)
{
	for (uint32_t cpu = 0; cpu < DRIVER_RINGS; cpu++) {
		for (uint64_t at = 0; at < 3; at++)
			(void)erx_trace_ring_put(&driver_rings[cpu],
			    &(erx_trace_entry_t){ .time_ns = at + 1, .event = 1, .cpu = (uint16_t)cpu });
	}
	erx_fiasco_end_trace_rings(driver_rings, DRIVER_RINGS);
	driver_end("before the handoff", true);
	/* A release image's line without erx.trace: the rings are off from the root's start. */
	erx_fiasco_end_boot(false);
	erx_fiasco_end_trace(erx_boot_line_trace("", 0, false));
	driver_end("a release image", true);
	erx_fiasco_end_boot(true);
	erx_fiasco_end_trace(erx_boot_line_trace("", 0, true));
	driver_end("a development image", true);
	driver_end("a task's fault", false);
	/* The rings stay in memory; the bit alone keeps them out of the record. */
	erx_fiasco_end_trace(erx_boot_line_trace("erx.trace=0", 11, true));
	driver_end("rings that did not record", true);
	erx_fiasco_end_boot(false);
	erx_fiasco_end_trace(erx_boot_line_trace("erx.trace=1", 11, false));
	driver_end("a release image with erx.trace=1", true);
	/* As a fresh root's, the form is brief here: only the handoff can make it full. */
	erx_fiasco_end_boot(false);
	if (erx_fiasco_root_handoff(&(erx_boot_handoff_view_t){ 0 }) != NULL) {
		puts("the stand-in handoff was refused");
		return (1);
	}
	driver_end("a root that only reads its handoff", true);
	return (0);
}
