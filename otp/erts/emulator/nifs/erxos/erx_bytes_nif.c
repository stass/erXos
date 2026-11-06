/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The per-byte primitives of erx_bytes (docs/design-runtime.md, "Per-byte primitives"),
 * statically linked NIFs on binaries. Each works on at most ERX_BYTES_CALL_MAX bytes, so a call
 * ends within a reduction slice on a normal scheduler and never waits; the caller streams longer
 * inputs. The work is in the cores beside this file, which build for the host.
 */

#define STATIC_ERLANG_NIF 1

#include "erl_nif.h"

#include "erx_crc32c.h"

/*
 * The most bytes one call works on: a call stays within a reduction slice, and the caller
 * streams longer inputs.
 */
#define ERX_BYTES_CALL_MAX	65536u

/* The percent of a reduction slice a call of ERX_BYTES_CALL_MAX bytes is charged. */
#define SLICE_PERCENT_AT_MAX	24

/*
 * crc32c_nif(Crc, Data): CRC-32C of the binary Data after the bytes whose value is Crc, 0 for
 * none. The call is charged reductions in proportion to its bytes, so a loop of calls is
 * preempted like any other. badarg unless Crc is an integer in 0..16#FFFFFFFF and Data a binary of at most
 * ERX_BYTES_CALL_MAX bytes.
 */
static ERL_NIF_TERM
crc32c_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary data;
	unsigned int crc;

	if (argc != 2 || !enif_get_uint(env, argv[0], &crc) || !enif_inspect_binary(env, argv[1], &data))
		return (enif_make_badarg(env));
	if (data.size > ERX_BYTES_CALL_MAX)
		return (enif_make_badarg(env));
	(void)enif_consume_timeslice(env, 1 + (int)(data.size * SLICE_PERCENT_AT_MAX / ERX_BYTES_CALL_MAX));
	return (enif_make_uint(env, erx_crc32c(crc, data.data, data.size)));
}

static ErlNifFunc nif_funcs[] = {
	{ "crc32c_nif", 2, crc32c_nif, 0 },
};

ERL_NIF_INIT(erx_bytes, nif_funcs, NULL, NULL, NULL, NULL)
