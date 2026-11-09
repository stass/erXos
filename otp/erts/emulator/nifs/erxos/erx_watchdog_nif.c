/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The calls under erx_watchdog (docs/design-stopgap.md, "The watchdog"). A pet runs on a
 * normal scheduler, so it says that schedulers run and timers fire. Only the system
 * domain, whose boot page has ERX_BOOT_ROOT, holds the machine's watchdog.
 */

#define STATIC_ERLANG_NIF 1

#include "erl_nif.h"

#include "liberx/backend/api.h"
#include "liberx/backend/runtime_entry.h"

static ERL_NIF_TERM
pet_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int status;

	(void)argc;
	(void)argv;
	status = erx_watchdog_pet();
	if (status != ERX_OK)
		return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_int(env, status)));
	return (enif_make_atom(env, "ok"));
}

/* The page is the runtime's own memory, written and checked once before ERTS started. */
static ERL_NIF_TERM
held_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	(void)argc;
	(void)argv;
	return (enif_make_atom(env, (erx_boot_info()->flags & ERX_BOOT_ROOT) != 0 ? "true" : "false"));
}

static ErlNifFunc nif_funcs[] = {
	{ "held_nif", 0, held_nif, 0 },
	{ "pet_nif", 0, pet_nif, 0 },
};

ERL_NIF_INIT(erx_watchdog, nif_funcs, NULL, NULL, NULL, NULL)
