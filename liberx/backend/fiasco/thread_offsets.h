/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_THREAD_OFFSETS_H
#define ERX_FIASCO_THREAD_OFFSETS_H

/*
 * What the start trampoline reads, for an assembler that cannot see a structure.
 * thread.c pins each one to the structure it names, so a drift fails the build.
 */
#define ERX_FIASCO_RECORD_OFF_ARGS	1024	/* start.regs.gpr[0], the first of the argument registers */
#define ERX_FIASCO_START_ARGS		8	/* the trampoline loads gpr[0] to gpr[7] */
#define ERX_FIASCO_RECORD_OFF_SP	1272	/* start.regs.sp */
#define ERX_FIASCO_RECORD_OFF_PC	1280	/* start.regs.pc */
#define ERX_FIASCO_RECORD_OFF_TLS	1296	/* start.tls */
#define ERX_FIASCO_NATIVE_OFF_MARKER	992	/* the native UTCB's free_marker */
#define ERX_FIASCO_NATIVE_OFF_RECORD	1000	/* the native UTCB's first user word */

#endif /* ERX_FIASCO_THREAD_OFFSETS_H */
