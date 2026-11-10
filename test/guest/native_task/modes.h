/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_NATIVE_TASK_MODES_H
#define ERX_NATIVE_TASK_MODES_H

#include <stdint.h>

/* What the program does: the root's argument to it. */
#define MODE_SERVICE	1	/* memory, a thread, the JIT alias, a rewrite across CPUs: ends with 0 */
#define MODE_WRITE_RX	2	/* a write through the read-execute alias */
#define MODE_RUN_RW	3	/* a jump into the read-write alias */
#define MODE_NO_JIT	4	/* in a space without ERX_SPACE_JIT: a JIT object is refused */
#define MODE_SPIN_STOP	5	/* a thread spinning on each CPU while the first stops the task */
#define MODE_RACE	6	/* a thread looping on commit while the first faults */
#define MODE_WAIT	7	/* sleeps until the root stops the task */
#define MODE_IRQ_REFUSED	8	/* IRQ calls from a task: make refused, no handle reaches an object */
#define MODE_LOG	9	/* forges the root's lines with erx_debug_log: ends with 0 */
#define MODE_WRITE	10	/* writes every byte value through a task's standard output: ends with 0 */
#define MODE_DEVICE_REFUSED	11	/* device memory from a task: a physical or contiguous create refused */
#define MODE_YIELD	12	/* two threads on one CPU hand a count back and forth by yielding: ends with 0 */

/* The line the log case tries to forge, which must appear only inside a record. */
#define LOG_FORGED_LINE	"erx: task: forged ok"

/*
 * What the write case writes, and tools/lib/erx/native_task.rb reads back: this head, then
 * this many bytes counting up from 0 and wrapping, past two splits of the UTCB, then a newline.
 * The last piece ends part of the way through a word.
 */
#define WRITE_HEAD	"write case:\t\n\033[2J\xff\n"
#define WRITE_RUN_BYTES	1103

/* How many handles the IRQ case probes, from 1: the root's object is among them. */
#define IRQ_SCAN	16u

/* The status a spinning task stops with. */
#define STATUS_SPIN_STOP	7

/* The aliases' fixed addresses, which the root says before each fault. */
#define ALIAS_RW	UINT64_C(0x4000400000)
#define ALIAS_RX	UINT64_C(0x4000500000)

#endif /* ERX_NATIVE_TASK_MODES_H */
