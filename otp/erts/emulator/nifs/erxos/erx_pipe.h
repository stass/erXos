/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The pipe NIF's entries for the program driver (docs/design-pipes.md,
 * "Hand-offs"): the take of a hand-off, its contents, its release, and the
 * port's hold on a program's holder entry.
 *
 * A hand-off holds the copies one pipe descriptor or one report needs for
 * a program, in erx_pipe:copies/1's order, each a capability of the pipe
 * server's with the handle rights its copy carries, and, for an end the
 * program gains, that end's doorbell, made unbound, with the end's label.
 * The pipe server makes it with erx_pipe_nif:hand_make/2 for the program's
 * handler, its owner, and names it to the handler by its number alone.
 *
 * The program driver, erx_program_drv.c, alone calls these functions
 * (the chokepoint pipe-hand-take).  A take, a give-back with
 * erx_pipe_nif:hand_drop/1, the owner's exit and holder_drop/1 serialize on
 * the NIF's one hand-off lock, so exactly one of them has each hand-off.
 * Nothing here runs a destructor under the lock, and no caller holds a lock
 * of the NIF when it calls in, so the driver may call with its port locked.
 */

#ifndef ERX_PIPE_NIF_H
#define ERX_PIPE_NIF_H

#include <stdbool.h>
#include <stdint.h>

#include "erl_nif.h"

typedef struct erx_pipe_hand erx_pipe_hand_t;

/*
 * Takes the held hand-off number of program, the n of {program, n} whose
 * port the driver runs, for caller, the process that made the call: at a
 * start, the process opening the port (driver_connected); for
 * erx_program:install/2, the process calling port_control
 * (driver_caller), which the driver has checked is also the port's owner.
 * Answers the hand-off, now the caller's driver's alone, only when it is
 * for program, caller is its owner, and the program's holder entry is held
 * by that owner with the port's hold not yet released; the take also takes
 * the port's hold on that entry, if the port does not hold it yet.  NULL,
 * changing nothing, for a number with no held hand-off (never made, taken,
 * or let go), one for another program, one of another owner, a program
 * whose port's hold erx_pipe_holder_release has let go, and any take
 * before the NIF has loaded.
 */
erx_pipe_hand_t	*erx_pipe_hand_take(uint64_t number, uint64_t program,
		    ERL_NIF_TERM caller);

/* The program the hand-off is for: the n of {program, n}. */
uint64_t	 erx_pipe_hand_program(const erx_pipe_hand_t *hand);

/*
 * The count of copies, 0 to ERX_PIPE_HAND_COPIES_MAX (erx/abi.h): the
 * driver answers one value for each, so it may size its answer by that
 * limit.
 */
unsigned	 erx_pipe_hand_count(const erx_pipe_hand_t *hand);

/*
 * Copy i, 0 <= i < erx_pipe_hand_count: the pipe server's capability, to
 * pass into the image, and the handle rights the copy carries
 * (ERX_HR_*): READ, WRITE and MAP for memory, TRIGGER for a doorbell,
 * never DUP, GIVE or DESTROY.  It is the value of {hand, i + 1}.
 */
void		 erx_pipe_hand_copy(const erx_pipe_hand_t *hand, unsigned i,
		    uint64_t *cap, uint32_t *rights);

/*
 * The doorbell of the end the hand-off gives, if it gives one: true with
 * the pipe server's capability to it, unbound, and the label to bind it
 * with in the program's group.  False for a report's hand-off.
 */
bool		 erx_pipe_hand_bell(const erx_pipe_hand_t *hand, uint64_t *cap,
		    uint64_t *label);

/*
 * Lets a taken hand-off go, once, whatever the installs answered: each
 * capability it kept closes if the pipe server has closed it too.  The
 * driver does not use hand or the capabilities it answered afterwards.
 */
void		 erx_pipe_hand_release(erx_pipe_hand_t *hand);

/*
 * Lets go the port's hold on program's holder entry: called once the
 * driver has released the program's anchor, so no image of the program
 * and no sub-space under it runs, or as an undo of a start that failed
 * after a take, just before the lease's return; the driver calls it only
 * when one of its takes took the hold.  When the owner's hold is gone too,
 * the NIF sends the running pipe server the program's gone and forgets the
 * entry.  The release is final: a release before any take also refuses
 * every later take for the program, and a second release, or one for a
 * program with no entry, does nothing.
 */
void		 erx_pipe_holder_release(uint64_t program);

#endif /* ERX_PIPE_NIF_H */
