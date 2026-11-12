/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_PIPE_RUN_H
#define ERX_PIPE_RUN_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/pipe.h"

/*
 * The effects of the pipe core's steps (docs/design-pipes.md, "The pipe
 * core"): a run performs a write end's or a read end's actions on the
 * pages the end has mapped, one action at a time, and hands each copy back
 * to the next step, until a step returns ERX_PIPE_OP_WAIT or
 * ERX_PIPE_OP_DONE, which the run returns to its caller.  The run never
 * waits, and a wait ends the call: a program's worker lets go of the end,
 * waits for its doorbell and starts a fresh call with the bytes it has
 * not yet written or read, and the session's pipe NIF returns would_block
 * and starts its next call afresh (a step that waits holds neither the
 * reader lock nor an unpublished record).  A call whose wake_local is set
 * when the run returns, DONE or WAIT, changed what other calls of the end
 * may wait on, and its caller wakes them before it lets go of the end
 * (docs/design-pipes.md, "Ends in liberx"); a caller that steps past a
 * wait instead of returning reads it first, since the call after a wait
 * starts afresh.
 *
 * Every load of a page another party writes goes through erx_shm_copy, but
 * the published positions' acquire loads; stores go through the generated
 * accessors, and the bits and the reader lock through one atomic
 * read-modify-write each.  The run checks every action the step returns
 * against the end's own mappings and the call's buffer, and ends the call
 * with EIO on one that falls outside them, so no step can make it touch
 * memory it does not own.
 */

/* A write end's mappings: its ring, read-write, and its reader page, read-only. */
typedef struct erx_pipe_wmap {
	erx_lane_hdr_t	*hdr;		/* the ring's header page */
	unsigned char	*area;		/* the data area, the end's size bytes */
	const erx_pipe_rpage_t *rpage;
} erx_pipe_wmap_t;

/* A read end's lane, as mapped: the ring read-only, its reader page read-write. */
typedef struct erx_pipe_rmap {
	const erx_lane_hdr_t *hdr;
	const unsigned char *area;	/* the lane's size bytes */
	erx_pipe_rpage_t *rpage;
} erx_pipe_rmap_t;

/*
 * What a run asks of its caller: the clock, the doorbells, and the notices
 * of a lane drained or broken.  A read end names its lanes by their index
 * in its state's lanes, and its peers' doorbells by read end index; a write
 * end rings read ends only.  The read end's callbacks run while the call
 * is in progress, so drained may unmap the lane it names: no later action
 * of the call touches a lane the step has counted drained or broken.
 */
typedef struct erx_pipe_fx {
	void		*ctx;
	uint64_t	(*clock)(void *ctx);
	void		(*ring_reader)(void *ctx, uint32_t rix);
	void		(*ring_writer)(void *ctx, uint32_t lane);
	void		(*drained)(void *ctx, uint32_t lane);
	void		(*broken)(void *ctx, uint32_t lane, uint64_t fault);
} erx_pipe_fx_t;

/*
 * Runs a write end's steps over buf, the call's len bytes, from where its
 * state stands; returns the WAIT or DONE action that ended the run.
 */
erx_pipe_act_t	erx_pipe_wrun(erx_pipe_wstate_t *w, const erx_pipe_wmap_t *map,
		    const void *buf, const erx_pipe_fx_t *fx);

/*
 * Gives a read end its index rix, the only way a read state gets one, once
 * its lanes are in r and mapped in maps: clears the index's bit in lock's
 * waiters and in every mapped lane's sleepers, which an end that held the
 * index before may have left set by dying mid-wait (docs/design-pipes.md,
 * "Waiting and doorbells"), and marks the state taken.  False, touching
 * nothing, when rix is not below ERX_PIPE_READERS_MAX.
 */
bool		erx_pipe_rtake(erx_pipe_rstate_t *r, uint32_t rix,
		    const erx_pipe_rmap_t *maps, erx_pipe_lock_t *lock);

/*
 * Runs a read end's steps into buf, the call's len bytes; maps holds one
 * mapping for each of the state's nlanes lanes, and lock is the pipe's
 * lock page.  A lane the end found drained or broken may have NULL pages.
 * A state erx_pipe_rtake has not given an index ends the call with EIO.
 */
erx_pipe_act_t	erx_pipe_rrun(erx_pipe_rstate_t *r, const erx_pipe_rmap_t *maps,
		    erx_pipe_lock_t *lock, void *buf, const erx_pipe_fx_t *fx);

#endif /* !ERX_PIPE_RUN_H */
