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
#define MODE_IRQ_REFUSED	8	/* IRQ calls from a task: a line refused, no handle reaches an object, a doorbell made */
#define MODE_LOG	9	/* forges the root's lines with erx_debug_log: ends with 0 */
#define MODE_WRITE	10	/* writes every byte value through a task's standard output: ends with 0 */
#define MODE_DEVICE_REFUSED	11	/* device memory from a task: a physical or contiguous create refused */
#define MODE_YIELD	12	/* two threads on one CPU hand a count back and forth by yielding: ends with 0 */
#define MODE_MACHINE_END	13	/* erx_machine_end from a task, refused with ERX_ENOTSUP: ends with 0 */
#define MODE_POOL_ROUNDS	14	/* more thread creates, starts and exits than the root's slot pool holds pairs: ends with 0 */
#define MODE_WRITE_REFUSED	15	/* from a task the launcher did not make: the launcher's create and a raw write refused: ends with 0 */
#define MODE_SPIN	16	/* SPIN_THREADS threads spinning on CPU 0 until the root stops the task */
#define MODE_TURNS	17	/* two threads spin on CPU 0: ends with the median turn of one, in us, or a negative status */
#define MODE_SHARE	18	/* recording spinners on one CPU write each window through the task's write: ends with 0 */

/*
 * The argument names its mode in its low byte; only MODE_SHARE reads the rest, which
 * SHARE_ARGUMENT packs: its spinners, the one CPU they are pinned to, its windows, and each
 * window's length in milliseconds (docs/design-bench.md, "2. `sched`: how a CPU is shared").
 */
#define MODE_BITS	UINT64_C(0xff)
#define SHARE_ARGUMENT(spinners, cpu, windows, window_ms)						\
	((uint64_t)MODE_SHARE | (uint64_t)(spinners) << 8 | (uint64_t)(cpu) << 16 | (uint64_t)(windows) << 24 |	\
	    (uint64_t)(window_ms) << 32)
#define SHARE_SPINNERS_MAX	8u
#define SHARE_WINDOWS_MAX	10u
#define SHARE_WINDOW_MS_MAX	60000u
/* The sustained profile's warm-up, in both its forms, before the first window starts. */
#define SHARE_WARMUP_MS		2000u
/* A gap longer than this many loop periods is a turn the spinner lost. */
#define SHARE_LOST_LOOPS	20u
/*
 * MODE_SHARE's statuses when it ends early: an argument out of the bounds above, its first
 * thread not moved to CPU 0, a spinner that published no window within SHARE_PATIENCE_MS of its
 * end, and a spinner it could not start, its status added to SHARE_SPAWN.
 */
#define SHARE_ARGUMENT_BAD	100
#define SHARE_PINNED		101
#define SHARE_STARVED		102
#define SHARE_SPAWN		110
#define SHARE_PATIENCE_MS	5000u

/* The threads MODE_WAIT starts before it sleeps, each asleep for good. */
#define WAIT_THREADS	2u
#define SPIN_THREADS	4u
/*
 * MODE_TURNS's statuses when it measures nothing, negative so that none reads as a turn: its
 * thread not moved to CPU 0, too few turns before its deadline, and the negated status of a
 * spinner it could not start.
 */
#define TURNS_PINNED	(-80)
#define TURNS_NONE	(-90)
/* The threads every task runs before its main: its first, its reaper and its dispatcher (task_start.c). */
#define TASK_OWN_THREADS	3u

/* The line the log case tries to forge, which must appear only inside a record. */
#define LOG_FORGED_LINE	"erx: task: forged ok"

/*
 * What the write case writes, and tools/lib/erx/native_task.rb reads back: this head, then
 * this many bytes counting up from 0 and wrapping, past two splits of the UTCB, then a newline.
 * The last piece ends part of the way through a word.
 */
#define WRITE_HEAD	"write case:\t\n\033[2J\xff\n"
#define WRITE_RUN_BYTES	1103

/* What the refused write tries to put on the console; tools/lib/erx/native_task.rb finds none of it. */
#define WRITE_REFUSED_TEXT	"refused write\033]0;forged\007\n"

/* How many handles the IRQ case probes, from 1: the root's object is among them. */
#define IRQ_SCAN	16u

/* The status a spinning task stops with. */
#define STATUS_SPIN_STOP	7

/* The aliases' fixed addresses, which the root says before each fault. */
#define ALIAS_RW	UINT64_C(0x4000400000)
#define ALIAS_RX	UINT64_C(0x4000500000)

#endif /* ERX_NATIVE_TASK_MODES_H */
