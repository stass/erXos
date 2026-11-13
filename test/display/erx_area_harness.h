/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The seam between erx_area's own NIF (otp/erts/emulator/nifs/erxos/
 * erx_area_nif.c) and its host harness (test/display/erx_area_harness.c),
 * two translation units linked into one host NIF by
 * test/host/erx_area_lease_test.rb. The NIF includes this header only
 * when built with ERX_AREA_HARNESS: it adds the harness's NIF functions,
 * the stand-ins for the program driver, to its function table, and
 * defines erx_area_harness_lease_count, the one view into its internals
 * the harness needs.
 */

#ifndef ERX_AREA_HARNESS_H
#define ERX_AREA_HARNESS_H

#include "erl_nif.h"

/*
 * The harness's NIF functions, defined in test/display/erx_area_harness.c,
 * and their entries in the NIF's function table.
 */
ERL_NIF_TERM erx_area_harness_take(ErlNifEnv *env, int argc,
    const ERL_NIF_TERM argv[]);
ERL_NIF_TERM erx_area_harness_give(ErlNifEnv *env, int argc,
    const ERL_NIF_TERM argv[]);
ERL_NIF_TERM erx_area_harness_map_lease(ErlNifEnv *env, int argc,
    const ERL_NIF_TERM argv[]);
ERL_NIF_TERM erx_area_harness_leases(ErlNifEnv *env, int argc,
    const ERL_NIF_TERM argv[]);

#define ERX_AREA_HARNESS_FUNCTIONS						\
	{ "take", 3, erx_area_harness_take, 0 },				\
	{ "give", 1, erx_area_harness_give, 0 },				\
	{ "map_lease", 2, erx_area_harness_map_lease, 0 },			\
	{ "leases", 0, erx_area_harness_leases, 0 },

/*
 * The count of leases listed in the NIF's table, read under its lock;
 * erx_area_nif.c defines it.
 */
unsigned erx_area_harness_lease_count(void);

#endif /* ERX_AREA_HARNESS_H */
