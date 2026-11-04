/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "liberx/backend/fiasco/thread_claim.h"

uint32_t
erx_fiasco_thread_claim_pick(const erx_fiasco_claim_view_t *view, void *context, uint32_t first, uint32_t limit)
{
	uint32_t index;

	for (index = first; index < limit; index++)
		if (!view->used(context, index) && view->marker(context, index) == 0)
			break;
	return (index);
}
