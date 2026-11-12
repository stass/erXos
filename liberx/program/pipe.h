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
 * An end's tables (its core state, its mappings, its capabilities, its
 * peers' doorbells and its waiters) are guarded by the end's lock, which a
 * call holds while it uses them and the event executor holds while it
 * applies a report or a ring of the end's doorbell, never across a wait.
 * pipe, end and kind never change after the set-up.  The lock order is
 * the descriptor table's lock, then an end's (fd.h): a thread that holds
 * an end's lock never takes the table's, which fd.c checks, nor a second
 * end's, which erx_pipe_end_lock checks.  Every capability the end holds
 * is closed exactly once: a slot that held one is ERX_CAP_NULL from the
 * moment it is closed.
 */

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include <erx/abi.h>
#include <erx/pipe.h>
#include <erx/pipe_run.h>
#include <erx/prog_profile.h>

#include "liberx/program/fd.h"
#include "liberx/program/wake.h"

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
 * the handler its {drained}; the read end counts its owed lanes in owing.
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
	uint32_t		 owing;		/* lanes whose {drained} is owed */
	void			*run;
} erx_pipe_rend_t;

/*
 * A pipe end.  obj is the table's head; peers holds the trigger right on
 * each other read end's doorbell, by index: every read end's for a write
 * end, the others' for a read end.  waiters lists the threads waiting on
 * the end: calls that wait for its doorbell and polls that watch it.  kind
 * selects the member of u, which only code that checks it touches.
 */
typedef struct erx_pipe_end {
	erx_prog_obj_t		 obj;
	pthread_mutex_t		 lock;
	erx_pipe_kind_t		 kind;
	uint32_t		 pipe;
	uint32_t		 end;
	uint64_t		 peers[ERX_PIPE_READERS_MAX];
	erx_prog_waitq_t	 waiters;
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
 * Reads at most len bytes into buf, from a read end the caller holds a
 * counted reference to: the count, 0 at the end of the stream, or a
 * negative errno, -EBADF for a write end.  A call that waits lets go of
 * the end and sleeps until its doorbell or a report wakes it, then starts
 * afresh; whatever the call cleared that other calls of the end were
 * waiting on, it wakes them for (docs/design-pipes.md, "Ends in liberx").
 * Each {drained} the read owes is sent after it lets go of the end.
 */
ssize_t	erx_pipe_read(erx_pipe_end_t *e, void *buf, size_t len);

/*
 * Writes len bytes from buf to a write end the caller holds a counted
 * reference to, waiting for room as a read waits for data: the count
 * written, which is short only when an error ends the write after some
 * bytes went, or a negative errno, -EBADF for a read end.
 */
ssize_t	erx_pipe_write(erx_pipe_end_t *e, const void *buf, size_t len);

/*
 * A poll's registration on an end it watches, and its removal (wake.h): a
 * poll watches every end it waits on before it checks any of them, and
 * unwatches them all before it returns.
 */
void	erx_pipe_watch(erx_pipe_end_t *e, erx_prog_waiter_t *w);
void	erx_pipe_unwatch(erx_pipe_end_t *e, erx_prog_waiter_t *w);

/*
 * One poll of an end the caller holds a counted reference to and watches
 * (docs/design-pipes.md, "Readiness"): its POLL* bits, or 0 when nothing is
 * ready.  It never waits for the pipe and never copies; a 0 leaves
 * published what makes the end's doorbell ring once the answer may change,
 * which wakes the watching thread, and the poll that follows answers
 * afresh.  The caller reads its wake word after erx_pipe_watch and before
 * the first poll, as a waiting call does, so no such ring is lost.  Each
 * {drained} the poll owes is sent after it lets go of the end, and that
 * send may wait for room on the session channel.
 */
short	erx_pipe_poll(erx_pipe_end_t *e);

/*
 * The event executor's: a label came up in the group's ready list.  For a
 * pipe end's label, wakes the threads waiting on the end, if the program
 * holds it, and returns true; false for any other label.
 */
bool	erx_pipe_doorbell(uint64_t label);

/* An end's lock, taken and let go only through these, which count the end locks a thread holds. */
void	erx_pipe_end_lock(erx_pipe_end_t *e);
void	erx_pipe_end_unlock(erx_pipe_end_t *e);
/* Whether the calling thread holds an end's lock. */
bool	erx_pipe_end_held(void);

/*
 * The end's last reference went and the table let go of it: ends a wait
 * its last read left, lets go of every mapping and capability, sends each
 * {drained} it owes and then {closed}, and frees the end.
 */
void	erx_pipe_release(erx_pipe_end_t *e);

#endif /* !LIBERX_PROGRAM_PIPE_H */
