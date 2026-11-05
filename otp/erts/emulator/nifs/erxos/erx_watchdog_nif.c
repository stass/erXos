/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The call under erx_watchdog (docs/design-stopgap.md, "The watchdog"). It runs on a
 * normal scheduler, so a pet says that schedulers run and timers fire.
 */

#define STATIC_ERLANG_NIF 1

#include "erl_nif.h"

#include "liberx/backend/api.h"

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

static ErlNifFunc nif_funcs[] = {
	{ "pet_nif", 0, pet_nif, 0 },
};

ERL_NIF_INIT(erx_watchdog, nif_funcs, NULL, NULL, NULL, NULL)
