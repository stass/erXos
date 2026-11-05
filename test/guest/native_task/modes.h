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
#define MODE_IRQ_REFUSED	8	/* every IRQ call through the service: each refused */

/* The status a spinning task stops with. */
#define STATUS_SPIN_STOP	7

/* The aliases' fixed addresses, which the root says before each fault. */
#define ALIAS_RW	UINT64_C(0x4000400000)
#define ALIAS_RX	UINT64_C(0x4000500000)

#endif /* ERX_NATIVE_TASK_MODES_H */
