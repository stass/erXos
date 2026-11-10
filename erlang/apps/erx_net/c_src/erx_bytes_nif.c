/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The NIF library of the portable erx_bytes (portable/erx_bytes.erl), erx_net's per-byte
 * primitives outside erXos: the NIFs inet_csum_nif/2, inet_csum_update_nif/3 and
 * siphash24_nif/2, which the module's inet_csum/2, inet_csum_update/3 and siphash24/2 call
 * once their arguments fit. c_src/Makefile builds it into
 * priv/erx_bytes_nif.so, which the module loads as it is loaded. On erXos the same functions are
 * BIFs of ERTS (otp/erts/emulator/nifs/erxos/erx_bytes_bif.c) over the same cores and the same
 * iodata walk (erx_iodata.c), so the two builds differ only in how a term is read. entropy/1
 * is Erlang over the host's generator and needs none.
 *
 * Each call works on at most ERX_BYTES_CALL_MAX bytes, so it ends within a reduction slice on
 * a normal scheduler and never waits. enif_inspect_binary copies a binary that starts at a
 * bit offset whole, into a block ERTS frees without erasing, before its size is known here;
 * the module refuses every argument of more than twice ERX_BYTES_CALL_MAX bytes before it
 * calls a NIF, so no copy is larger. erXos's BIFs check the size before they copy.
 */

#include <stddef.h>
#include <stdint.h>

#include "erl_nif.h"

#include "erx_inet_csum.h"
#include "erx_iodata.h"
#include "erx_siphash.h"

_Static_assert(sizeof(ERL_NIF_TERM) == sizeof(erx_iodata_term_t), "a term is a word");

/* Says what one term is, for erx_iodata_walk. */
static void
classify(void *env, erx_iodata_term_t term, size_t room, erx_iodata_item_t *item)
{
	ERL_NIF_TERM head, tail;
	ErlNifBinary binary;
	unsigned int byte;

	item->copy = NULL;
	if (enif_get_list_cell(env, (ERL_NIF_TERM)term, &head, &tail)) {
		item->kind = ERX_IODATA_CELL;
		item->head = (erx_iodata_term_t)head;
		item->tail = (erx_iodata_term_t)tail;
	} else if (enif_is_binary(env, (ERL_NIF_TERM)term)) {
		item->kind = ERX_IODATA_OTHER;
		if (enif_inspect_binary(env, (ERL_NIF_TERM)term, &binary) && binary.size <= room) {
			item->kind = ERX_IODATA_BINARY;
			item->data = binary.data;
			item->size = binary.size;
		}
	} else if (enif_get_uint(env, (ERL_NIF_TERM)term, &byte) && byte <= UINT8_MAX) {
		item->kind = ERX_IODATA_BYTE;
		item->value = (uint8_t)byte;
	} else if (enif_is_empty_list(env, (ERL_NIF_TERM)term)) {
		item->kind = ERX_IODATA_NIL;
	} else {
		item->kind = ERX_IODATA_OTHER;
	}
}

static void *
resize(void *env, void *block, size_t bytes)
{

	(void)env;
	return (block == NULL ? enif_alloc(bytes) : enif_realloc(block, bytes));
}

static void
release(void *env, void *block)
{

	(void)env;
	enif_free(block);
}

/* The term layer of a call's environment. */
static erx_iodata_layer_t
layer_of(ErlNifEnv *env)
{

	return ((erx_iodata_layer_t){ .classify = classify, .resize = resize, .release = release, .env = env });
}

/* The exception of a refused walk: badarg, or system_limit when its stack could not grow. */
static ERL_NIF_TERM
refusal(ErlNifEnv *env, erx_iodata_status_t status)
{

	if (status == ERX_IODATA_NOMEM)
		return (enif_raise_exception(env, enif_make_atom(env, "system_limit")));
	return (enif_make_badarg(env));
}

/* Charges the calling process the reductions of a call, as a percent of a slice. */
static void
charge(ErlNifEnv *env, size_t reductions)
{
	size_t percent;

	percent = reductions * 100 / ERX_BYTES_SLICE_REDS;
	(void)enif_consume_timeslice(env, percent < 1 ? 1 : percent > 100 ? 100 : (int)percent);
}

/* True when term is a binary of at most ERX_BYTES_CALL_MAX bytes, which data then describes. */
static int
get_call_binary(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *data)
{

	return (enif_inspect_binary(env, term, data) && data->size <= ERX_BYTES_CALL_MAX);
}

/* Adds a run to the running Internet checksum sum at context. */
static void
sum_run(void *context, const uint8_t *data, size_t length, size_t before)
{
	uint16_t *sum = context;

	*sum = erx_inet_sum(*sum, data, length, before);
}

/*
 * inet_csum(Sum, Data): the Internet checksum sum of Data's bytes, continuing from Sum, the
 * sum of bytes before them of even length. badarg unless Sum is an integer in 0..16#FFFF and
 * Data iodata within erx_iodata.h's limits.
 */
static ERL_NIF_TERM
inet_csum(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_iodata_layer_t layer = layer_of(env);
	erx_iodata_status_t status;
	erx_iodata_walked_t walked;
	unsigned int start;
	uint16_t sum;

	if (argc != 2 || !enif_get_uint(env, argv[0], &start) || start > 0xffffu)
		return (enif_make_badarg(env));
	sum = (uint16_t)start;
	status = erx_iodata_walk(&layer, (erx_iodata_term_t)argv[1], sum_run, &sum, &walked);
	charge(env, erx_bytes_reductions(walked.bytes, walked.cells, ERX_INET_CSUM_REDS_AT_MAX));
	if (status != ERX_IODATA_OK)
		return (refusal(env, status));
	return (enif_make_uint(env, sum));
}

/*
 * inet_csum_update(Checksum, Before, After): the checksum field that replaces Checksum when
 * the bytes Before, at an even offset of what it covers, become the bytes After. badarg unless
 * Checksum is an integer in 0..16#FFFF and Before and After are binaries of one even size of
 * at most ERX_BYTES_CALL_MAX bytes.
 */
static ERL_NIF_TERM
inet_csum_update(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary before, after;
	unsigned int checksum;

	if (argc != 3 || !enif_get_uint(env, argv[0], &checksum) || checksum > 0xffffu)
		return (enif_make_badarg(env));
	if (!get_call_binary(env, argv[1], &before) || !get_call_binary(env, argv[2], &after))
		return (enif_make_badarg(env));
	if (before.size != after.size || before.size % 2 != 0)
		return (enif_make_badarg(env));
	charge(env, erx_bytes_reductions(2 * before.size, 0, ERX_INET_CSUM_REDS_AT_MAX));
	return (enif_make_uint(env, erx_inet_csum_update((uint16_t)checksum, before.data, after.data,
	    before.size)));
}

/* Gives a run to the SipHash state at context. */
static void
hash_run(void *context, const uint8_t *data, size_t length, size_t before)
{

	(void)before;
	erx_siphash24_update(context, data, length);
}

/*
 * siphash24(Key, Data): SipHash-2-4 of Data's bytes under the 16-byte binary Key, as an
 * integer in 0..2^64-1. badarg unless Key is a 16-byte binary and Data iodata within
 * erx_iodata.h's limits. The state, which holds values derived from the key, is erased before
 * the call returns.
 */
static ERL_NIF_TERM
siphash24(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_iodata_layer_t layer = layer_of(env);
	erx_iodata_status_t status;
	erx_iodata_walked_t walked;
	erx_siphash_t state;
	ErlNifBinary key;
	uint64_t hash;

	if (argc != 2 || !enif_inspect_binary(env, argv[0], &key) || key.size != ERX_SIPHASH_KEY_LENGTH)
		return (enif_make_badarg(env));
	erx_siphash24_init(&state, key.data);
	status = erx_iodata_walk(&layer, (erx_iodata_term_t)argv[1], hash_run, &state, &walked);
	hash = erx_siphash24_final(&state);
	erx_siphash24_erase(&state);
	charge(env, erx_bytes_reductions(walked.bytes, walked.cells, ERX_SIPHASH_REDS_AT_MAX));
	if (status != ERX_IODATA_OK)
		return (refusal(env, status));
	return (enif_make_uint64(env, hash));
}

static ErlNifFunc nif_funcs[] = {
	{ "inet_csum_nif", 2, inet_csum, 0 },
	{ "inet_csum_update_nif", 3, inet_csum_update, 0 },
	{ "siphash24_nif", 2, siphash24, 0 },
};

/*
 * 0 when info, the module's {CALL_MAX, CELLS_MAX}, holds this library's limits, which the
 * module's checks before each NIF assume; any other answer refuses the load.
 */
static int
limits_agree(ErlNifEnv *env, ERL_NIF_TERM info)
{
	const ERL_NIF_TERM *limits;
	unsigned int bytes, cells;
	int arity;

	if (!enif_get_tuple(env, info, &arity, &limits) || arity != 2 ||
	    !enif_get_uint(env, limits[0], &bytes) || !enif_get_uint(env, limits[1], &cells))
		return (1);
	return (bytes == ERX_BYTES_CALL_MAX && cells == ERX_IODATA_CELLS_MAX ? 0 : 1);
}

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{

	(void)priv;
	return (limits_agree(env, info));
}

/* The library keeps no state, so a new instance of the module takes it over as it is. */
static int
upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info)
{

	(void)priv;
	(void)old_priv;
	return (limits_agree(env, info));
}

ERL_NIF_INIT(erx_bytes, nif_funcs, load, NULL, upgrade, NULL)
