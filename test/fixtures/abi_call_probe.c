/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdio.h>

#include "kernel/generated/abi_calls.h"

int
main(void)
{
	erx_sys_shape_t shape = { .number = 999 };
	uint64_t registers[6] = {0};

	registers[0] = ERX_UTCB_BYTES_MAX;
	if (erx_sys_decode_shape(ERX_CALL_DEBUG_LOG, registers, false, &shape) != ERX_OK ||
	    shape.arguments.debug_log.len.raw != ERX_UTCB_BYTES_MAX)
		return (1);
	shape.number = 999;
	registers[0] = ERX_UTCB_BYTES_MAX + UINT64_C(1);
	if (erx_sys_decode_shape(ERX_CALL_DEBUG_LOG, registers, false, &shape) != ERX_EINVAL ||
	    shape.number != 999)
		return (1);
	registers[0] = UINT64_MAX;
	if (erx_sys_decode_shape(ERX_CALL_DEBUG_LOG, registers, false, &shape) != ERX_EINVAL)
		return (1);
	if (erx_sys_decode_shape(UINT64_MAX, registers, false, &shape) != ERX_ENOTSUP)
		return (1);
	if (erx_sys_decode_shape(ERX_CALL_DEBUG_LOG, NULL, false, &shape) != ERX_EINVAL)
		return (1);
	registers[0] = 0;
	if (erx_sys_decode_shape(ERX_CALL_DEBUG_LOG, registers, true, &shape) != ERX_OK)
		return (1);
	puts("call shape checks passed");
	return (0);
}
