/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "atomic.h"
#include "ksigaction.h"

/* sigaction names these as its restorers. No signal is delivered, so neither runs. */
void
__restore(void)
{
	a_crash();
}

void
__restore_rt(void)
{
	a_crash();
}
