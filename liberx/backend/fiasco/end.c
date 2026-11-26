/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The end path (docs/design-fiasco.md, "The end path"), and the effects the crash
 * codec asks of it. Best effort, with no lock. No thread is stopped first. An end on the
 * thread that owns the debug log (erx_fiasco_log_owned) first writes the records that
 * wait for a reader to the console, so none is lost; on any other thread a write to the
 * ring may be under way, so the ring is skipped, and the watchdog's end writes only its
 * frame. Every end names its cause, which alone decides how it ends (end_how.c): it
 * writes its last line, erx: end off or erx: end reset, and only a requested power-off
 * turns the machine off. machine_end is static, so nothing ends the machine without a
 * cause.
 */

#include <l4/sys/platform_control.h>

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/crash.h"
#include "erx/core/debug_log.h"
#include "erx/core/effects.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/end_how.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/trace_window.h"

/* A refused boot's line, as long as the root's other lines (root.c). */
#define END_LINE_MAX	640u

static _Atomic uint32_t end_taken;
static _Alignas(ERX_CRASH_BUFFER_ALIGN) uint8_t end_record[ERX_CRASH_SIZE];
static _Alignas(ERX_CRASH_BUFFER_ALIGN) uint8_t end_scratch[ERX_CRASH_SCRATCH_BYTES];
/* How many of the kernel's rings the trace window holds; 0 until it maps, and for good if it does not. */
static _Atomic uint32_t end_trace_count;

void
erx_fiasco_end_trace_rings(uint32_t rings)
{
	atomic_store_explicit(&end_trace_count, rings, memory_order_release);
}

/* The kernel's rings as the window holds them, for a machine end's record: NULL, *rings 0, before it maps. */
static const void *
end_trace(uint32_t *rings)
{
	*rings = atomic_load_explicit(&end_trace_count, memory_order_acquire);
	return (*rings != 0 ? (const void *)(uintptr_t)ERX_FIASCO_TRACE_WINDOW : NULL);
}

/*
 * The first caller goes on; every other sleeps. The winner closes the kernel's route at
 * once, so the ring's lines reach the UART ahead of the end's own first line, and
 * every line the kernel prints from here on goes there (docs/design-fiasco.md,
 * "The kernel's lines").
 */
static void
end_take(void)
{
	if (atomic_exchange_explicit(&end_taken, 1, memory_order_acq_rel) != 0)
		erx_fiasco_sleep_forever();
	erx_fiasco_console_close();
}

bool
erx_fiasco_end_taken(void)
{
	return (atomic_load_explicit(&end_taken, memory_order_acquire) != 0);
}

/*
 * The machine's end, which under -no-reboot QEMU turns into its own exit,
 * whichever is asked, so its last line, erx: end off or erx: end reset, is what
 * tells a test which end it took, as erXos's kernel's last line does
 * (docs/design-kernel.md, "Ending the machine"). A kernel that returns from the
 * call has no way to do it, so the thread sleeps and the harness's deadline
 * reports the boot as hung.
 */
static _Noreturn void
machine_end(erx_fiasco_end_cause_t cause)
{
	static const char off[] = "erx: end off\n";
	static const char reset[] = "erx: end reset\n";
	const bool reboot = erx_fiasco_end_how(cause) == ERX_END_RESET;

	if (reboot)
		erx_fiasco_console_write(reset, sizeof(reset) - 1);
	else
		erx_fiasco_console_write(off, sizeof(off) - 1);
	(void)l4_platform_ctl_system_shutdown(L4_BASE_ICU_CAP, reboot ? 1 : 0);
	erx_fiasco_sleep_forever();
}

_Noreturn void
erx_fiasco_end_watchdog(const erx_watchdog_end_t *end)
{
	static const char message[] = "the watchdog's pet was missed";

	uint32_t rings;

	end_take();
	const erx_crash_input_t input = { .form = ERX_CRASH_FORM_FULL, .cause = end->cause,
	    .boot_value = ERX_BOOT_VALUE_UNKNOWN, .boot_slot = ERX_BOOT_SLOT_NONE,
	    .uptime_ns = end->uptime_ns, .since_pet_ns = end->since_pet_ns, .message = message,
	    .message_length = sizeof(message) - 1, .trace = end_trace(&rings), .ntrace = rings };

	(void)erx_crash_record_write(&input, end_record, end_scratch);
	erx_crash_frame_write(end_record, ERX_CRASH_END_WATCHDOG);
	machine_end(ERX_FIASCO_END_PET);
}

/* Takes the end, and on the log's owning thread gives the UART back to the early console. */
static void
end_begin(void)
{
	end_take();
	if (erx_fiasco_log_owned())
		erx_debug_log_take_back();
}

_Noreturn void
erx_fiasco_end(erx_fiasco_end_cause_t cause, const erx_fault_t *fault)
{
	static const char message[] = "root task fault";

	uint32_t rings;

	end_begin();
	if (fault != NULL) {
		const erx_crash_input_t input = { .form = ERX_CRASH_FORM_FULL, .cause = ERX_CRASH_CAUSE_FAULT,
		    .boot_value = ERX_BOOT_VALUE_UNKNOWN, .boot_slot = ERX_BOOT_SLOT_NONE,
		    .uptime_ns = erx_fiasco_clock_ns(), .fault = *fault, .message = message,
		    .message_length = sizeof(message) - 1, .trace = end_trace(&rings), .ntrace = rings };

		(void)erx_crash_record_write(&input, end_record, end_scratch);
		erx_crash_frame_write(end_record, ERX_CRASH_END_FAULT);
	}
	machine_end(cause);
}

/* TEXT, a NUL-terminated fixed string of the root's own, to the console. */
static void
end_say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

_Noreturn void
erx_fiasco_end_refused(const char *line)
{
	end_begin();
	end_say(line);
	machine_end(ERX_FIASCO_END_REFUSED);
}

/* TEXT after the USED bytes of LINE, cut at END_LINE_MAX. */
static void
end_append(char *line, size_t *used, const char *text)
{
	while (*text != '\0' && *used < END_LINE_MAX)
		line[(*used)++] = *text++;
}

/* The line is whole before it is written, so nothing else on the console falls inside it. */
_Noreturn void
erx_fiasco_end_boot_refused(const char *reason)
{
	char line[END_LINE_MAX];
	size_t used = 0;

	end_begin();
	end_append(line, &used, "erx: root task refused the boot: ");
	end_append(line, &used, reason);
	end_append(line, &used, "\n");
	erx_fiasco_console_write(line, used);
	machine_end(ERX_FIASCO_END_REFUSED);
}

/* Buffers of its own: the watchdog's end may run at the same time and takes the others. */
void
erx_fiasco_task_crash_write(const erx_fault_t *fault)
{
	static const char message[] = "task fault";
	static _Alignas(ERX_CRASH_BUFFER_ALIGN) uint8_t record[ERX_CRASH_SIZE];
	static _Alignas(ERX_CRASH_BUFFER_ALIGN) uint8_t scratch[ERX_CRASH_SCRATCH_BYTES];
	const erx_crash_input_t input = { .form = ERX_CRASH_FORM_FULL, .cause = ERX_CRASH_CAUSE_FAULT,
	    .boot_value = ERX_BOOT_VALUE_UNKNOWN, .boot_slot = ERX_BOOT_SLOT_NONE,
	    .uptime_ns = erx_fiasco_clock_ns(), .fault = *fault, .message = message,
	    .message_length = sizeof(message) - 1 };

	(void)erx_crash_record_write(&input, record, scratch);
	erx_crash_frame_write(record, ERX_CRASH_END_TASK);
}

/*
 * The cores' one caller in a root is one thread, the service, or a probe's one thread
 * with no service (log.c), so the debug log's lock is empty, and an end drains the ring
 * only on that thread.
 */
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
