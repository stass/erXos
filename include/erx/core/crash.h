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
 * calls erx_crash_previous_plan on the crash buffer's region before it
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
 * Boot step 4's decision on the region. HAND_ON: copy the first length bytes
 * into fresh pages for the root task and clear the region's magic. ZERO: the
 * region holds a record it must not keep; zero all of it and report none.
 * NONE: no magic, nothing to do and nothing to report.
 */
typedef enum erx_crash_previous_action {
	ERX_CRASH_PREVIOUS_NONE = 1,
	ERX_CRASH_PREVIOUS_HAND_ON,
	ERX_CRASH_PREVIOUS_ZERO
} erx_crash_previous_action_t;

typedef struct erx_crash_previous {
	erx_crash_previous_action_t action;
	uint32_t	length;		/* HAND_ON only, else zero */
} erx_crash_previous_t;

/*
 * The one writer of a crash record. Zeroes the ERX_CRASH_SIZE bytes of buffer
 * and writes a record that erx_crash_check accepts, whatever input holds: it
 * cannot refuse, since nothing can report a refusal at the machine's end, so
 * an input that contradicts itself is written as what it is, a kernel bug
 * (see kernel/core/crash.c, erx_crash_settle). Returns the record's length.
 * buffer and scratch are ERX_CRASH_BUFFER_ALIGN aligned. No lock is taken:
 * the log is read trusting none of its records.
 */
size_t erx_crash_record_write(const erx_crash_input_t *input, void *buffer,
    void *scratch);

/*
 * Prints the record in buffer as the crash frame through the console effect,
 * after a newline that ends whatever line the report left open. A buffer
 * that holds no record the writer could have made prints nothing.
 */
void erx_crash_frame_write(const void *buffer);

/*
 * Decides what boot step 4 does with region_size bytes that firmware and the
 * previous boot wrote; build_form is the form this build writes. Reads at
 * most ERX_CRASH_SIZE bytes. No other party writes the region at that step,
 * so the check holds for the copy made right after it.
 */
erx_crash_previous_t erx_crash_previous_plan(const void *region,
    size_t region_size, uint32_t build_form);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_CRASH_H */
