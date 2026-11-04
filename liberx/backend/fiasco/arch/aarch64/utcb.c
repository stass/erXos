/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Where a thread finds its UTCB on the stopgap: Fiasco keeps its user address
 * in the register user mode can read and only the kernel can write
 * (docs/design-stopgap.md, "Transport").
 */

#include "erx/abi.h"

erx_utcb_t *erx_utcb_self(void);

erx_utcb_t *
erx_utcb_self(void)
{
	erx_utcb_t *utcb;

	__asm__ volatile("mrs %0, tpidrro_el0" : "=r"(utcb));
	return (utcb);
}
