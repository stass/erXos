/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_INBOUND_H
#define LIBERX_PROGRAM_INBOUND_H

/*
 * The event executor's decisions on the inbound lane of a program's channel
 * (docs/design-programs.md, "The program protocol" and "The event
 * executor"), as pure functions the host tests exhaustively.  The handler
 * writes one startup message and then reports, each a frame record: the
 * executor asks erx_prog_inbound_open what a record's header admits, copies
 * the record whole, and then plans the start-up (startup.h) or reads the
 * report with erx_prog_report_read.  Anything else, a record of another
 * kind, a header with a nonzero zero word, an empty record, a startup
 * message past ERX_PROG_FRAME_MAX, a report past ERX_PROG_REPORT_BYTES or a
 * report the profile refuses, ends the program with ERX_PROG_STATUS_REFUSED.
 *
 * Like startup.c, this reads only its arguments: no kernel call, no page.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <erx/abi.h>
#include <erx/prog_profile.h>

/*
 * The bytes the executor keeps for one report.  The profile's largest
 * report, {erx_prog, 1, {pipe_writer, ...}} with three capabilities as
 * 64-bit integers, takes about 120 bytes of ETF; a report past this bound
 * is not one the handler writes.
 */
#define ERX_PROG_REPORT_BYTES	512

/* What the executor does with a record whose header the inbound lane opened. */
typedef enum erx_prog_inbound {
	ERX_PROG_INBOUND_START,		/* the startup message: copy it, then plan */
	ERX_PROG_INBOUND_REPORT,	/* a report: copy it, then read it */
	ERX_PROG_INBOUND_REFUSE		/* stop with ERX_PROG_STATUS_REFUSED */
} erx_prog_inbound_t;

/*
 * The decision on a record's header: kind, zero word and body length.
 * started says the startup message's record was opened before: the first
 * record is the startup message, and every later one a report.
 */
erx_prog_inbound_t erx_prog_inbound_open(bool started, uint32_t kind,
	    uint64_t zero, uint32_t len);

/*
 * Reads the report frame[0, len), copied whole, with scratch_len bytes of
 * scratch; false refuses it.  With erx_prog_scratch_bytes(len) bytes of
 * scratch the profile's check never refuses for scratch.
 */
bool	erx_prog_report_read(const uint8_t *frame, size_t len, void *scratch,
	    size_t scratch_len, erx_prog_report_t *report);

/* The most capabilities one report carries: pipe_writer's ring, reader page and doorbell. */
#define ERX_PROG_REPORT_CAPS	3

/*
 * The capability values a report installed in the program's table, into
 * caps[0, n); returns n.  A report for an end the program no longer holds
 * closes each of them, so a report that comes after the end's close leaks
 * nothing.
 */
size_t	erx_prog_report_caps(const erx_prog_report_t *report,
	    uint64_t caps[ERX_PROG_REPORT_CAPS]);

#endif /* !LIBERX_PROGRAM_INBOUND_H */
