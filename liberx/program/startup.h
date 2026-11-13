/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_STARTUP_H
#define LIBERX_PROGRAM_STARTUP_H

/*
 * The pure core of a program's start-up in liberx's program layer
 * (docs/design-programs.md#the-startup-message,
 * docs/design-abi.md#program-protocol).  The event executor hands it the
 * startup message, copied whole out of the inbound lane, and it decides
 * whether the program reaches main: it runs the generated check
 * erx_prog_check_start, then walks the check's typed views into a plan the
 * first thread applies.  A refusal ends the program with status 127 before
 * main and without a line, since a program's descriptors come only from a
 * startup message liberx has accepted.
 *
 * The core is pure: it reads only its arguments and writes only the scratch
 * and its plan, so it builds and is tested on the host.  It makes no kernel
 * call and names no backend symbol; the effects (the lane, the mapping of
 * the data area, the copies of argv and env into NUL-terminated strings and
 * the call of main) are the program layer's, around it.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <erx/abi.h>
#include <erx/prog_profile.h>

/* The status of a program whose frame from its handler liberx refuses. */
#define ERX_PROG_STATUS_REFUSED	127

/* A set of the ABI's signal numbers 1 to ERX_SIGRTMAX: bit N - 1 is signal N. */
typedef struct erx_prog_sigset {
	uint64_t	bits[2];
} erx_prog_sigset_t;

/* Why a plan ends the program with ERX_PROG_STATUS_REFUSED. */
typedef enum erx_prog_startup_cause {
	ERX_PROG_STARTUP_GO,		/* none: the program runs */
	ERX_PROG_STARTUP_CHECK,		/* the check refused; refusal says why */
	ERX_PROG_STARTUP_DESCRIPTOR,	/* a descriptor liberx cannot set up, at fd */
	ERX_PROG_STARTUP_BOUND,		/* past the plan's bounds; the check's exclude it */
} erx_prog_startup_cause_t;

/*
 * The plan of a start-up.  status is 0 when the program runs, and
 * ERX_PROG_STATUS_REFUSED when it ends before main; cause says which, and
 * refusal is the check's when cause is ERX_PROG_STARTUP_CHECK.  Nothing
 * else of a refused plan is meaningful.
 *
 * argv, env and fds are the check's iterators, fresh: the first thread
 * walks argv and env to copy each string, and the event executor fds to
 * build the descriptor table (fd.h); they borrow the frame, which the
 * caller keeps unchanged while it uses them.  Walk a copy: next advances
 * the iterator it is handed.  Every descriptor fds holds is null, a
 * pipe's read or write end, or a mem range the session mapped (fd.h).
 * argc and envc count their strings, and argv_bytes and env_bytes their lengths with one NUL each, which size the
 * copies; the check's args total bounds the two sums together by
 * ERX_PROG_ARGS_MAX.  cwd is the working directory's copy, NUL-terminated,
 * cwd_len bytes before the NUL.
 */
typedef struct erx_prog_startup {
	int			 status;
	erx_prog_startup_cause_t cause;
	erx_profile_refusal_t	 refusal;
	uint16_t		 fd;		/* ERX_PROG_STARTUP_DESCRIPTOR's */

	uint32_t		 argc;
	size_t			 argv_bytes;
	erx_prog_argv_iter_t	 argv;
	uint32_t		 envc;
	size_t			 env_bytes;
	erx_prog_env_iter_t	 env;
	size_t			 cwd_len;
	char			 cwd[ERX_PROG_PATH_MAX + 1];
	erx_prog_fds_iter_t	 fds;

	uint32_t		 pid;
	uint32_t		 ppid;
	uint32_t		 pgid;
	bool			 spawn;
	uint16_t		 umask;
	erx_prog_sigset_t	 sigmask;
	erx_prog_sigset_t	 sigignore;
	uint64_t		 data_area;	/* the data area's capability value */
	uint8_t			 data_slots;	/* its 64 KiB slots */
	bool			 has_image;
	uint64_t		 image;		/* the image object's capability value */
} erx_prog_startup_t;

/*
 * Plans a start-up from the startup message frame[0, len), with scratch_len
 * bytes of scratch; with erx_prog_scratch_bytes(len) bytes the check never
 * refuses for scratch.  Returns out->status.  The check bounds every view
 * it fills to the frame, and the plan keeps those views.  Every descriptor
 * must be null, a pipe's read or write end or a mem range: liberx refuses a descriptor it
 * cannot set up rather than start the program without it.
 */
int	erx_prog_startup_plan(const uint8_t *frame, size_t len, void *scratch,
	    size_t scratch_len, erx_prog_startup_t *out);

#endif /* !LIBERX_PROGRAM_STARTUP_H */
