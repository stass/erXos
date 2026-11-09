/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_bytes's network primitives as NIF functions (erx_net_bytes.h): the argument checks and
 * the walk over iodata, around the Internet checksum and SipHash-2-4 cores beside this file.
 * Each call works on at most ERX_NET_BYTES_CALL_MAX bytes, so it ends within a reduction slice
 * on a normal scheduler and never waits; the Erlang wrappers check that size before the call
 * and leave longer inputs to their caller.
 */

#include "erx_net_bytes.h"

#include <stddef.h>
#include <stdint.h>

#include "erx_inet_csum.h"
#include "erx_siphash.h"

/*
 * The most pieces of an iodata argument one call walks. erlang:iolist_to_iovec/1 joins
 * binaries of up to 512 bytes and drops empty ones, so ERX_NET_BYTES_CALL_MAX bytes come as at
 * most about 257 pieces; the cap bounds the walk whatever list reaches the NIF.
 */
#define PIECES_MAX	1024u

/*
 * The percent of a reduction slice, about a millisecond, that a call of ERX_NET_BYTES_CALL_MAX
 * bytes is charged: the Internet checksum takes about 16 microseconds over 64 KiB and SipHash-2-4
 * about 110 on the development host (Apple M3 Max, native, clang 23.1.3 -O2). Slower targets
 * are a watch-list item (docs/todo-performance.md).
 */
#define INET_CSUM_PERCENT_AT_MAX	2
#define SIPHASH_PERCENT_AT_MAX	11

/*
 * Charges the calling process for a call over size bytes, in proportion to the bytes, so a loop
 * of calls is preempted like any other.
 */
static void
charge(ErlNifEnv *env, size_t size, int percent_at_max)
{

	(void)enif_consume_timeslice(env,
	    1 + (int)(size * (size_t)percent_at_max / ERX_NET_BYTES_CALL_MAX));
}

/*
 * True when term is a binary of at most ERX_NET_BYTES_CALL_MAX bytes, which data then
 * describes. enif_inspect_binary refuses a bitstring, but copies a binary that starts at a bit
 * offset before the size is known here; the Erlang wrappers check the size first, so that copy
 * is at most ERX_NET_BYTES_CALL_MAX bytes.
 */
static int
get_call_binary(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *data)
{

	return (enif_inspect_binary(env, term, data) && data->size <= ERX_NET_BYTES_CALL_MAX);
}

/* What each_piece calls on each piece, with the count of bytes before the piece. */
typedef void piece_visit_t(void *context, const uint8_t *data, size_t length, size_t before);

/*
 * Walks an iodata argument, which the Erlang wrappers pass as a binary or as the list of
 * binaries erlang:iolist_to_iovec/1 makes, after checking that it holds at most
 * ERX_NET_BYTES_CALL_MAX bytes. visit is called on each piece in order, with the count of bytes
 * before it, and *total is the count of bytes visited. True when term is a binary or a proper
 * list of at most PIECES_MAX binaries of at most ERX_NET_BYTES_CALL_MAX bytes in all. On false
 * the walk has stopped at the first piece that breaks this, and visit may already have run on
 * the pieces before it, so the caller discards what visit built.
 *
 * As in get_call_binary, enif_inspect_binary copies a piece that starts at a bit offset before
 * its size is known here, which the wrapper's size check bounds.
 */
static int
each_piece(ErlNifEnv *env, ERL_NIF_TERM term, piece_visit_t *visit, void *context, size_t *total)
{
	ERL_NIF_TERM head, tail;
	ErlNifBinary piece;
	size_t pieces = 0;

	*total = 0;
	if (enif_is_binary(env, term)) {
		if (!get_call_binary(env, term, &piece))
			return (0);
		visit(context, piece.data, piece.size, 0);
		*total = piece.size;
		return (1);
	}
	while (enif_get_list_cell(env, term, &head, &tail)) {
		if (++pieces > PIECES_MAX)
			return (0);
		if (!enif_inspect_binary(env, head, &piece) ||
		    piece.size > ERX_NET_BYTES_CALL_MAX - *total)
			return (0);
		visit(context, piece.data, piece.size, *total);
		*total += piece.size;
		term = tail;
	}
	return (enif_is_empty_list(env, term));
}

/* Adds a piece to the running Internet checksum sum at context. */
static void
sum_piece(void *context, const uint8_t *data, size_t length, size_t before)
{
	uint16_t *sum = context;

	*sum = erx_inet_sum(*sum, data, length, before);
}

/*
 * inet_csum_nif(Sum, Data): the Internet checksum sum of Data's bytes, continuing from Sum,
 * the sum of bytes before them of even length. badarg unless Sum is an integer in 0..16#FFFF
 * and Data a binary or a list of binaries of at most ERX_NET_BYTES_CALL_MAX bytes in all.
 */
ERL_NIF_TERM
erx_net_bytes_inet_csum(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	unsigned int start;
	uint16_t sum;
	size_t total;

	if (argc != 2 || !enif_get_uint(env, argv[0], &start) || start > 0xffffu)
		return (enif_make_badarg(env));
	sum = (uint16_t)start;
	if (!each_piece(env, argv[1], sum_piece, &sum, &total))
		return (enif_make_badarg(env));
	charge(env, total, INET_CSUM_PERCENT_AT_MAX);
	return (enif_make_uint(env, sum));
}

/*
 * inet_csum_update_nif(Checksum, Before, After): the checksum field that replaces Checksum
 * when the bytes Before, at an even offset of what it covers, become the bytes After. badarg
 * unless Checksum is an integer in 0..16#FFFF and Before and After are binaries of one even
 * size of at most ERX_NET_BYTES_CALL_MAX bytes.
 */
ERL_NIF_TERM
erx_net_bytes_inet_csum_update(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary before, after;
	unsigned int checksum;

	if (argc != 3 || !enif_get_uint(env, argv[0], &checksum) || checksum > 0xffffu)
		return (enif_make_badarg(env));
	if (!get_call_binary(env, argv[1], &before) || !get_call_binary(env, argv[2], &after))
		return (enif_make_badarg(env));
	if (before.size != after.size || before.size % 2 != 0)
		return (enif_make_badarg(env));
	charge(env, 2 * before.size, INET_CSUM_PERCENT_AT_MAX);
	return (enif_make_uint(env, erx_inet_csum_update((uint16_t)checksum, before.data, after.data,
	    before.size)));
}

/* Gives a piece to the SipHash state at context. */
static void
hash_piece(void *context, const uint8_t *data, size_t length, size_t before)
{

	(void)before;
	erx_siphash24_update(context, data, length);
}

/*
 * siphash24_nif(Key, Data): SipHash-2-4 of Data's bytes under the 16-byte binary Key, as an
 * integer in 0..2^64-1. badarg unless Key is a 16-byte binary and Data a binary or a list of
 * binaries of at most ERX_NET_BYTES_CALL_MAX bytes in all. The state, which holds values
 * derived from the key, is erased before the call returns.
 */
ERL_NIF_TERM
erx_net_bytes_siphash24(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_siphash_t state;
	ErlNifBinary key;
	uint64_t hash;
	size_t total;
	int ok;

	if (argc != 2 || !enif_inspect_binary(env, argv[0], &key) || key.size != ERX_SIPHASH_KEY_LENGTH)
		return (enif_make_badarg(env));
	erx_siphash24_init(&state, key.data);
	ok = each_piece(env, argv[1], hash_piece, &state, &total);
	hash = erx_siphash24_final(&state);
	erx_siphash24_erase(&state);
	if (!ok)
		return (enif_make_badarg(env));
	charge(env, total, SIPHASH_PERCENT_AT_MAX);
	return (enif_make_uint64(env, hash));
}
