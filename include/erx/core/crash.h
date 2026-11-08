/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_CRASH_H
#define ERX_CORE_CRASH_H

/*
 * The crash record as a kernel's end path sees it (docs/design-kernel.md,
 * "The root task"). A header of include/erx/core/ is the seam between the
 * C17 cores and Fiasco: it compiles as C17 and as C++ and includes only the
 * freestanding headers and this directory. The record's checker and the
 * frame's reader, which no end path calls, are in erx/crash.h.
 *
 * The end path calls erx_crash_record_write once, then
 * erx_crash_frame_write, after every other CPU has stopped. Boot step 4
 * calls erx_crash_previous_length on the crash buffer's region before it
 * carves the buffer.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/core/abi_crash.h"

/* The alignment of the record buffer and of the writer's scratch. */
#define ERX_CRASH_BUFFER_ALIGN 8
/* The writer's working memory: one log record, its text and its line. */
#define ERX_CRASH_SCRATCH_BYTES 8192

#ifdef __cplusplus
extern "C" {
#endif

/* The fields of the ABI's erx_fault_t; kernel/core/crash.c pins each one. */
typedef struct erx_crash_fault {
	uint32_t	kind;
	uint32_t	cause;
	uint64_t	addr;
	uint64_t	pc;
	uint64_t	thread;
	uint64_t	space;
	int64_t		status;
} erx_crash_fault_t;

/*
 * What an end knows. The writer reads regs, frames, message and log only for
 * the full form, so the brief form cannot carry them whatever the caller
 * holds. regs is ERX_CRASH_REGS_BYTES laid out as the ABI's erx_regs_t, or
 * NULL for zeros. log is the kernel's erx_log_t, or NULL for no log lines.
 */
typedef struct erx_crash_input {
	uint32_t	 form;		/* ERX_CRASH_FORM_*, from the boot image */
	uint32_t	 cause;		/* ERX_CRASH_CAUSE_* */
	uint32_t	 cpu;
	uint32_t	 boot_value;
	uint32_t	 boot_slot;
	uint32_t	 nframes;
	uint64_t	 uptime_ns;
	uint64_t	 since_pet_ns;
	uint8_t		 build_id[ERX_CRASH_BUILD_ID_BYTES];
	erx_crash_fault_t fault;
	const void	*regs;
	const uint64_t	*frames;
	const char	*message;	/* escaped by the writer; need not end in NUL */
	size_t		 message_length;
	const void	*log;
} erx_crash_input_t;

/*
 * What a crash frame is written for, which every writer of one states: the
 * machine going down, or a task's fault that the machine survives.
 */
typedef enum erx_crash_end {
	ERX_CRASH_END_MACHINE = 1,
	ERX_CRASH_END_TASK
} erx_crash_end_t;

/*
 * The one writer of a crash record. Zeroes the ERX_CRASH_SIZE bytes of buffer
 * and writes a record that erx_crash_check accepts, whatever input holds: it
 * cannot refuse, since nothing can report a refusal at the machine's end, so
 * an input that contradicts itself is written as what it is, a kernel bug
 * (see kernel/core/crash.c, erx_crash_settle). Returns the record's length.
 * buffer and scratch are ERX_CRASH_BUFFER_ALIGN aligned. No lock is taken:
 * a log whose counters could not be the ring's gives no lines, and each of its
 * records is read through the log's own check.
 */
size_t erx_crash_record_write(const erx_crash_input_t *input, void *buffer,
    void *scratch);

/*
 * Prints the record in buffer as the crash frame through the console effect,
 * after a newline that ends whatever line the report left open. When end is
 * ERX_CRASH_END_MACHINE a flatline for the person at the console goes
 * between the two; a task's fault gets the frame alone. A buffer whose form
 * and length break the frame's rules prints nothing; the writer's never do.
 */
void erx_crash_frame_write(const void *buffer, erx_crash_end_t end);

/*
 * Boot step 4's decision on region_size bytes that firmware and the previous
 * boot wrote; build_form is the form this build writes. Returns how many bytes
 * to copy into fresh pages for the root task, or 0 when no record is to be
 * handed on. The caller then zeroes the whole region in every case, so a record
 * is reported once and no record, of either form, stays there. Reads at most
 * ERX_CRASH_SIZE bytes. No other party writes the region at that step, so the
 * check holds for the copy made right after it.
 */
uint32_t erx_crash_previous_length(const void *region, size_t region_size,
    uint32_t build_form);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_CRASH_H */
