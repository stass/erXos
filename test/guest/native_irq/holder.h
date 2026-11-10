/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_NATIVE_IRQ_HOLDER_H
#define ERX_NATIVE_IRQ_HOLDER_H

#include <stdint.h>

/*
 * What the interrupt suite's root and its holder task (program.c) agree on. The root
 * passes the holder five handles, and their values in the holder's table travel in its
 * argument, HOLDER_HANDLE_BITS each, in the order of these indices.
 */
#define HOLDER_LINE	0u	/* the UART receive line's IRQ object */
#define HOLDER_WINDOW	1u	/* a physical object over the UART's registers */
#define HOLDER_RUN	2u	/* a contiguous run, its first word the DMA address the root got for it */
#define HOLDER_ROOT_GROUP	3u	/* the root's own group, which the holder does not home */
#define HOLDER_ROOT_SOFT	4u	/* a software object the root bound to its own group */
#define HOLDER_HANDLES	5u
#define HOLDER_HANDLE_BITS	12u
#define HOLDER_HANDLE_MASK	((UINT64_C(1) << HOLDER_HANDLE_BITS) - 1)
_Static_assert(HOLDER_HANDLES * HOLDER_HANDLE_BITS <= 64, "the handles fit the argument");

#define HOLDER_RUN_BYTES	UINT64_C(8192)

/* The first bind's label, and the one a second bind moves the object to. */
#define HOLDER_LABEL_FIRST	UINT64_C(0x55e4)
#define HOLDER_LABEL	UINT64_C(0x55f5)

/* What the holder says once its line is bound, and the harness then types a character. */
#define HOLDER_PROMPT	"erx: irq: the holder waits for a character\n"

#endif /* ERX_NATIVE_IRQ_HOLDER_H */
