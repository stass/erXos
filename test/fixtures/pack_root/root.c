/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "erx/abi.h"

ERX_DECLARE_ABI_NOTE(erx_fixture_abi_note);

_Noreturn void erx_fixture_start(void);

_Noreturn void
erx_fixture_start(void)
{

	for (;;)
		;
}
