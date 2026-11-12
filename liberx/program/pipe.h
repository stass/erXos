/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_PIPE_H
#define LIBERX_PROGRAM_PIPE_H

/*
 * A program's pipe ends (docs/design-pipes.md, "Ends in liberx" and "Ends
 * and their holders"): the end object a descriptor of the table (fd.h)
 * refers to, its set-up from a startup message's descriptor, the handler's
 * reports applied to it, and its release.
 *
 * An end's tables (its core state, its mappings, its capabilities and its
 * peers' doorbells) are guarded by the end's lock, which a call holds
 * while it uses them and the event executor holds while it applies a
 * report, never across a wait.  pipe, end and kind never change after
 * the set-up.  Every capability the end holds is closed exactly once: a
 * slot that held one is ERX_CAP_NULL from the moment it is closed.
 */

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <erx/abi.h>
#include <erx/pipe.h>
#include <erx/pipe_run.h>
#include <erx/prog_profile.h>

#include "liberx/program/fd.h"

typedef enum erx_pipe_kind {
	ERX_PIPE_READ,
	ERX_PIPE_WRITE
} erx_pipe_kind_t;

/* A write end: its core state, its lane mapped, and its capabilities to the lane. */
typedef struct erx_pipe_wend {
	erx_pipe_wstate_t	 st;		/* readers and lost the reports keep */
	erx_pipe_wmap_t		 map;		/* the ring read-write, its reader page read-only */
	uint64_t		 ring;
	uint64_t		 rpage;
} erx_pipe_wend_t;

/*
 * What a read end keeps of one lane beside the core's erx_pipe_rlane_t and
 * the run's erx_pipe_rmap_t of the same index: its capabilities, and owed,
 * set when the end let go of a lane it found drained and has not yet sent
 * the handler its {drained}.
 */
typedef struct erx_pipe_lane {
	uint64_t		 ring;
	uint64_t		 rpage;
	uint64_t		 bell;		/* the writer's doorbell while it is open */
	bool			 owed;
} erx_pipe_lane_t;

/*
 * A read end: its core state, the pipe's lock page, and its lanes, three
 * arrays of room entries in one run of pages, of which st.nlanes are used:
 * st.lanes (the core's), maps (the run's) and lanes (the end's).
 */
typedef struct erx_pipe_rend {
	erx_pipe_rstate_t	 st;
	erx_pipe_lock_t		*lockpage;
	uint64_t		 lock;
	erx_pipe_rmap_t		*maps;
	erx_pipe_lane_t		*lanes;
	uint32_t		 room;
	void			*run;
} erx_pipe_rend_t;

/*
 * A pipe end.  obj is the table's head; peers holds the trigger right on
 * each other read end's doorbell, by index: every read end's for a write
 * end, the others' for a read end.  kind selects the member of u, which
 * only code that checks it touches.
 */
typedef struct erx_pipe_end {
	erx_prog_obj_t		 obj;
	pthread_mutex_t		 lock;
	erx_pipe_kind_t		 kind;
	uint32_t		 pipe;
	uint32_t		 end;
	uint64_t		 peers[ERX_PIPE_READERS_MAX];
	union {
		erx_pipe_wend_t	 w;
		erx_pipe_rend_t	 r;
	} u;
} erx_pipe_end_t;

_Static_assert(offsetof(erx_pipe_end_t, obj) == 0, "an end's table head is its first member");

/* The end an object of kind ERX_PROG_OBJ_PIPE heads. */
static inline erx_pipe_end_t *
erx_pipe_end_of(erx_prog_obj_t *obj)
{
	return ((erx_pipe_end_t *)obj);
}

/*
 * Sets up the end a startup message's descriptor gives, a pipe's read or
 * write end, mapping its pages and keeping its capabilities; a read end
 * takes its index last, with erx_pipe_rtake.  ERX_OK, or ERX_ENOMEM or
 * ERX_EINVAL after which the caller stops the program: what the set-up
 * made is let go and the capabilities it kept are closed, and the
 * descriptor's others go with the program's space.
 */
int	erx_pipe_open(const erx_prog_descriptor_t *descriptor, erx_pipe_end_t **out);

/*
 * The event executor's: applies a report the handler sent, read and
 * checked (inbound.h), to the end it names, under the end's lock, or to
 * every end for pipe_server_lost.  A report for an end the program does not
 * hold closes the capabilities it installed.
 */
void	erx_pipe_report(const erx_prog_report_t *report);

/*
 * The end's last reference went and the table let go of it: ends a wait
 * its last read left, lets go of every mapping and capability, sends each
 * {drained} it owes and then {closed}, and frees the end.
 */
void	erx_pipe_release(erx_pipe_end_t *e);

#endif /* !LIBERX_PROGRAM_PIPE_H */
