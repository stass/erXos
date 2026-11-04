/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The end path (docs/design-stopgap.md, "The end path"), and the effects the crash
 * codec asks of it. Best effort, with no lock. No thread is stopped first, and this
 * root holds no log ring, so there is nothing to drain.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/crash.h"
#include "erx/core/effects.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service.h"

static _Atomic uint32_t end_taken;
static _Alignas(ERX_CRASH_BUFFER_ALIGN) uint8_t end_record[ERX_CRASH_SIZE];
static _Alignas(ERX_CRASH_BUFFER_ALIGN) uint8_t end_scratch[ERX_CRASH_SCRATCH_BYTES];

/* The first caller goes on; every other sleeps. */
static void
end_take(void)
{
	if (atomic_exchange_explicit(&end_taken, 1, memory_order_acq_rel) != 0)
		erx_fiasco_sleep_forever();
}

_Noreturn void
erx_fiasco_end_watchdog(const erx_watchdog_end_t *end)
{
	static const char message[] = "the watchdog's pet was missed";

	end_take();
	const erx_crash_input_t input = { .form = ERX_CRASH_FORM_FULL, .cause = end->cause,
	    .boot_value = ERX_BOOT_VALUE_UNKNOWN, .boot_slot = ERX_BOOT_SLOT_NONE,
	    .uptime_ns = end->uptime_ns, .since_pet_ns = end->since_pet_ns, .message = message,
	    .message_length = sizeof(message) - 1 };

	(void)erx_crash_record_write(&input, end_record, end_scratch);
	erx_crash_frame_write(end_record);
	erx_fiasco_machine_end(false);
}

_Noreturn void
erx_fiasco_end(const erx_crash_fault_t *fault, uint32_t how)
{
	static const char message[] = "root task fault";

	end_take();
	if (fault != NULL) {
		const erx_crash_input_t input = { .form = ERX_CRASH_FORM_FULL, .cause = ERX_CRASH_CAUSE_FAULT,
		    .boot_value = ERX_BOOT_VALUE_UNKNOWN, .boot_slot = ERX_BOOT_SLOT_NONE,
		    .uptime_ns = erx_fiasco_clock_ns(), .fault = *fault, .message = message,
		    .message_length = sizeof(message) - 1 };

		(void)erx_crash_record_write(&input, end_record, end_scratch);
		erx_crash_frame_write(end_record);
	}
	erx_fiasco_machine_end(how != ERX_END_OFF);
}

/* No log ring is passed to the writer, so these guard nothing. */
void
erx_effect_log_lock(void)
{
}

void
erx_effect_log_unlock(void)
{
}

uint64_t
erx_effect_clock_ns(void)
{
	return (erx_fiasco_clock_ns());
}

void
erx_effect_console_write(const char *line, size_t length)
{
	erx_fiasco_console_write(line, length);
}
