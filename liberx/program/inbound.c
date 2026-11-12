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
	return (len <= ERX_PROG_REPORT_BYTES ? ERX_PROG_INBOUND_REPORT :
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

size_t
erx_prog_report_caps(const erx_prog_report_t *report,
    uint64_t caps[ERX_PROG_REPORT_CAPS])
{
	switch (report->which) {
	case ERX_PROG_REPORT_PIPE_WRITER:
		caps[0] = report->u.pipe_writer.cap_1;
		caps[1] = report->u.pipe_writer.cap_2;
		caps[2] = report->u.pipe_writer.cap_3;
		return (3);
	case ERX_PROG_REPORT_PIPE_READER:
		caps[0] = report->u.pipe_reader.cap;
		return (1);
	case ERX_PROG_REPORT_PIPE_WRITER_GONE:
	case ERX_PROG_REPORT_PIPE_READER_GONE:
	case ERX_PROG_REPORT_PIPE_LOST:
	case ERX_PROG_REPORT_PIPE_SERVER_LOST:
		return (0);
	}
	return (0);
}
