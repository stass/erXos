/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The NIF library of the portable erx_bytes (portable/erx_bytes.erl), erx_net's per-byte
 * primitives outside erXos: c_src/Makefile builds it with this file into priv/erx_bytes_nif.so,
 * which the module loads as it is loaded. Its table is erx_net_bytes.h's network primitives
 * alone, the same NIF functions erXos's ERTS links statically
 * (otp/erts/emulator/nifs/erxos/erx_bytes_nif.c, the table of the other build); entropy/1 is
 * Erlang over the host's generator and needs none.
 */

#include "erl_nif.h"

#include "erx_net_bytes.h"

static ErlNifFunc nif_funcs[] = {
	ERX_NET_BYTES_NIFS,
};

/* The library keeps no state, so a new instance of the module takes it over as it is. */
static int
upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info)
{

	(void)env;
	(void)priv;
	(void)old_priv;
	(void)info;
	return (0);
}

ERL_NIF_INIT(erx_bytes, nif_funcs, NULL, NULL, upgrade, NULL)
