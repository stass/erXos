/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The offsets of erx_stop_regs (abi/arch/aarch64.txt) at which ivt.S's
 * stop routines store, for assembly, which cannot take them from the
 * generated layout. ivt.S stores at these macros, and erx_machine_stop.cpp
 * includes this header too and holds each macro to the generated layout
 * with a static_assert, so a layout change fails the kernel's build.
 */

#ifndef ERX_STOP_OFFSETS_H
#define ERX_STOP_OFFSETS_H

#define STOP_GPR(n)	((n) * 8)
#define STOP_SP		248
#define STOP_PC		256
#define STOP_STATE	264
#define STOP_SPACE_ROOT	272
#define STOP_CAUSE	280
#define STOP_ADDR	288

#endif /* ERX_STOP_OFFSETS_H */
