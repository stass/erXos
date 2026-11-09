/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_NET_BYTES_H
#define ERX_NET_BYTES_H

#include "erl_nif.h"

/*
 * erx_bytes's network primitives, inet_csum/2, inet_csum_update/3 and siphash24/2, as NIF
 * functions over the cores beside this file. Each build of erx_bytes puts them in its NIF
 * table with ERX_NET_BYTES_NIFS, so both builds take the same names, arities and argument
 * checks from here: erXos's ERTS links them statically beside its other primitives
 * (otp/erts/emulator/nifs/erxos/erx_bytes_nif.c), and outside erXos they are the library
 * that erx_net's portable erx_bytes loads (erx_bytes_nif.c beside this file).
 */

/* The most bytes one call works on, so a call stays within a reduction slice. */
#define ERX_NET_BYTES_CALL_MAX	65536u

ERL_NIF_TERM erx_net_bytes_inet_csum(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM erx_net_bytes_inet_csum_update(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM erx_net_bytes_siphash24(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

/* The entries of a NIF table, each on a normal scheduler. */
#define ERX_NET_BYTES_NIFS \
	{ "inet_csum_nif", 2, erx_net_bytes_inet_csum, 0 }, \
	{ "inet_csum_update_nif", 3, erx_net_bytes_inet_csum_update, 0 }, \
	{ "siphash24_nif", 2, erx_net_bytes_siphash24, 0 }

#endif
