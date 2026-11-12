/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_PROGRAM_H
#define LIBERX_PROGRAM_PROGRAM_H

/*
 * A program's start-up in liberx's program layer (docs/design-programs.md,
 * "The channel" and "Starting a program", step 9).  The backend's task
 * entry hands erx_prog_enter the first thread's argument registers, then
 * has musl's start call liberx_program_main, which maps the channel's two
 * sides, starts the event executor and waits.  The executor copies the
 * startup message out of the inbound lane as it is published, ringing the
 * session's doorbell as it frees room, and checks it whole
 * (erx_prog_startup_plan).  A refused message stops the program's space
 * with ERX_PROG_STATUS_REFUSED before main and without a line; an accepted
 * one wakes the first thread, which maps the data area, copies argv, env
 * and cwd into NUL-terminated strings and calls main.  Any frame after the
 * startup message stops the program the same way
 * (erx_prog_later_frame_status).
 *
 * The layer makes its memory page by page from the program's budget
 * (erx_vm_reserve and erx_vm_commit) and calls neither musl's malloc nor
 * its stdio.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <erx/abi.h>

#include "liberx/program/startup.h"

/* The argument registers a program's first thread starts with. */
#define ERX_PROG_START_REGS	8

/*
 * What liberx keeps of the program's start: the registers' values by
 * program_arg index (every register past the doorbell's is 0), and, once
 * main is called, the startup message's process ids, signal state, file
 * mode creation mask, working directory and data area.  rings counts the
 * deliveries the executor took that carried the channel's label, the
 * program's peer side's value; strays counts those that carried another.
 */
typedef struct erx_prog_self {
	uint64_t		 regs[ERX_PROG_START_REGS];
	uint32_t		 pid;
	uint32_t		 ppid;
	uint32_t		 pgid;
	bool			 spawn;
	uint16_t		 umask;
	erx_prog_sigset_t	 sigmask;
	erx_prog_sigset_t	 sigignore;
	const char		*cwd;
	void			*data_area;
	size_t			 data_bytes;
	_Atomic uint64_t	 rings;
	_Atomic uint64_t	 strays;
} erx_prog_self_t;

/* Stores the first thread's registers; the backend's task entry calls it once, first. */
void	erx_prog_enter(const uint64_t regs[ERX_PROG_START_REGS]);
/* What musl's start calls: the start-up above, then main's return. */
int	liberx_program_main(int argc, char **argv, char **envp);
/* The program's start, as main sees it; rings and strays move while the executor runs. */
const erx_prog_self_t *erx_prog_self(void);

#endif /* !LIBERX_PROGRAM_PROGRAM_H */
