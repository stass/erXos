/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The event executor's pure decisions on the inbound lane
 * (liberx/program/inbound.h).
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/program/inbound.h"

erx_prog_inbound_t
erx_prog_inbound_open(bool started, uint32_t kind, uint64_t zero, uint32_t len)
{
	if (kind != ERX_REC_FRAME || zero != 0 || len == 0)
		return (ERX_PROG_INBOUND_REFUSE);
	if (!started)
		return (len <= ERX_PROG_FRAME_MAX ? ERX_PROG_INBOUND_START :
		    ERX_PROG_INBOUND_REFUSE);
	return (len <= ERX_PROG_REPORT_MAX ? ERX_PROG_INBOUND_REPORT :
	    ERX_PROG_INBOUND_REFUSE);
}

bool
erx_prog_report_read(const uint8_t *frame, size_t len, void *scratch,
    size_t scratch_len, erx_prog_report_t *report)
{
	erx_profile_refusal_t refusal;

	return (erx_prog_check_report(frame, len, scratch, scratch_len, report,
	    &refusal));
}

