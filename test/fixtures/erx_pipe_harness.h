/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The seam between the session's pipe NIF (otp/erts/emulator/nifs/erxos/
 * erx_pipe_nif.c) and its host harness (test/fixtures/erx_pipe_harness.c),
 * two translation units linked into one host NIF by
 * test/host/erx_pipe_hand_test.rb. The NIF includes this header only when
 * built with ERX_PIPE_HARNESS: it adds the harness's NIF functions, the
 * stand-ins for the program driver, to its function table, and defines
 * erx_pipe_harness_obj_cap, the one view into its objects the harness
 * needs.
 */

#ifndef ERX_PIPE_HARNESS_H
#define ERX_PIPE_HARNESS_H

#include <stdbool.h>
#include <stdint.h>

#include "erl_nif.h"

/*
 * The harness's NIF functions, defined in test/fixtures/erx_pipe_harness.c,
 * and their entries in the NIF's function table.
 */
ERL_NIF_TERM erx_pipe_harness_take(ErlNifEnv *env, int argc,
    const ERL_NIF_TERM argv[]);
ERL_NIF_TERM erx_pipe_harness_give(ErlNifEnv *env, int argc,
    const ERL_NIF_TERM argv[]);
ERL_NIF_TERM erx_pipe_harness_holder_release(ErlNifEnv *env, int argc,
    const ERL_NIF_TERM argv[]);
ERL_NIF_TERM erx_pipe_harness_closed(ErlNifEnv *env, int argc,
    const ERL_NIF_TERM argv[]);
ERL_NIF_TERM erx_pipe_harness_obj_cap_nif(ErlNifEnv *env, int argc,
    const ERL_NIF_TERM argv[]);

#define ERX_PIPE_HARNESS_FUNCTIONS						\
	{ "take", 3, erx_pipe_harness_take, 0 },				\
	{ "give", 1, erx_pipe_harness_give, 0 },				\
	{ "holder_release", 1, erx_pipe_harness_holder_release, 0 },		\
	{ "closed", 1, erx_pipe_harness_closed, 0 },				\
	{ "obj_cap", 1, erx_pipe_harness_obj_cap_nif, 0 },

/* The capability of an object term; erx_pipe_nif.c defines it. */
bool erx_pipe_harness_obj_cap(ErlNifEnv *env, ERL_NIF_TERM term,
    uint64_t *cap);

#endif /* ERX_PIPE_HARNESS_H */
