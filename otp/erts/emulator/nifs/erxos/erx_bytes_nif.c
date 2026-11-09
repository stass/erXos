/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The per-byte primitives of erx_bytes (docs/design-runtime.md, "Per-byte primitives"),
 * statically linked NIFs on binaries. Each works on at most ERX_BYTES_CALL_MAX bytes, so a call
 * ends within a reduction slice on a normal scheduler and never waits; the Erlang wrappers
 * stream longer inputs. The work is in the cores beside this file and in kernel/crypto/sha2,
 * which build for the host. Beside them, entropy_nif is Erlang's entry to the kernel's generator.
 */

#define STATIC_ERLANG_NIF 1

#include <string.h>

#include "erl_nif.h"

#include "erx/explicit_bzero.h"
#include "kernel/crypto/sha2/sha256.h"
#include "liberx/backend/api.h"

#include "erx_crc32c.h"
#include "erx_inet_csum.h"
#include "erx_siphash.h"

/* The most bytes one call works on, so a call stays within a reduction slice. */
#define ERX_BYTES_CALL_MAX	65536u

/*
 * The most pieces of an iodata argument one call walks. erlang:iolist_to_iovec/1 joins
 * binaries of up to 512 bytes and drops empty ones, so ERX_BYTES_CALL_MAX bytes come as at
 * most about 257 pieces; the cap bounds the walk whatever list reaches the NIF.
 */
#define ERX_BYTES_PIECES_MAX	1024u

/*
 * The percent of a reduction slice, about a millisecond, that a call of ERX_BYTES_CALL_MAX bytes
 * is charged: CRC-32C's two table steps a byte and the portable SHA-256 each take about a quarter
 * of a slice over 64 KiB on the development host (Apple M-series, native, clang -O2; SHA-256
 * about 240 microseconds). The Internet checksum takes about 16 microseconds over 64 KiB and
 * SipHash-2-4 about 110 there (Apple M3 Max, native, clang 23.1.3 -O2). Slower targets are a
 * watch-list item (docs/todo-performance.md).
 */
#define CRC32C_PERCENT_AT_MAX	24
#define SHA256_PERCENT_AT_MAX	25
#define INET_CSUM_PERCENT_AT_MAX	2
#define SIPHASH_PERCENT_AT_MAX	11

/*
 * A SHA-256 state of sha256_init/0 and sha256_update/2: the context of the bytes given so far.
 * A state is never changed once made: an update makes a new state from a copy of the old one,
 * so a state is an Erlang value that any process of this runtime may hold, reuse or send, and
 * needs no lock.
 * The destructor erases the context, which holds a copy of the input's last partial block.
 */
static ErlNifResourceType *sha256_state_type;

/*
 * Charges the calling process for a call over size bytes, in proportion to the bytes, so a loop
 * of calls is preempted like any other.
 */
static void
charge(ErlNifEnv *env, size_t size, int percent_at_max)
{

	(void)enif_consume_timeslice(env, 1 + (int)(size * (size_t)percent_at_max / ERX_BYTES_CALL_MAX));
}

/*
 * True when term is a binary of at most ERX_BYTES_CALL_MAX bytes, which data then describes.
 * enif_inspect_binary refuses a bitstring, but copies a binary that starts at a bit offset
 * before the size is known here; the Erlang wrappers check the size first, so that copy is at
 * most ERX_BYTES_CALL_MAX bytes.
 */
static int
get_call_binary(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *data)
{

	return (enif_inspect_binary(env, term, data) && data->size <= ERX_BYTES_CALL_MAX);
}

/*
 * crc32c_nif(Crc, Data): CRC-32C of the binary Data after the bytes whose value is Crc, 0 for
 * none. badarg unless Crc is an integer in 0..16#FFFFFFFF and Data a binary of at most
 * ERX_BYTES_CALL_MAX bytes.
 */
static ERL_NIF_TERM
crc32c_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary data;
	unsigned int crc;

	if (argc != 2 || !enif_get_uint(env, argv[0], &crc) || !get_call_binary(env, argv[1], &data))
		return (enif_make_badarg(env));
	charge(env, data.size, CRC32C_PERCENT_AT_MAX);
	return (enif_make_uint(env, erx_crc32c(crc, data.data, data.size)));
}

/*
 * Walks an iodata argument, which the Erlang wrappers pass as a binary or as the list of
 * binaries erlang:iolist_to_iovec/1 makes, after checking that it holds at most
 * ERX_BYTES_CALL_MAX bytes. visit is called on each piece in order, with the count of bytes
 * before it, and *total is the count of bytes visited. True when term is a binary or a proper
 * list of at most ERX_BYTES_PIECES_MAX binaries of at most ERX_BYTES_CALL_MAX bytes in all.
 * On false the walk has stopped at the first piece that breaks this, and visit may already
 * have run on the pieces before it, so the caller discards what visit built.
 *
 * As in get_call_binary, enif_inspect_binary copies a piece that starts at a bit offset
 * before its size is known here, which the wrapper's size check bounds.
 */
typedef void piece_visit_t(void *context, const uint8_t *data, size_t length, size_t before);

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
		if (++pieces > ERX_BYTES_PIECES_MAX)
			return (0);
		if (!enif_inspect_binary(env, head, &piece) || piece.size > ERX_BYTES_CALL_MAX - *total)
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
 * and Data a binary or a list of binaries of at most ERX_BYTES_CALL_MAX bytes in all.
 */
static ERL_NIF_TERM
inet_csum_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
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
 * size of at most ERX_BYTES_CALL_MAX bytes.
 */
static ERL_NIF_TERM
inet_csum_update_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
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
 * binaries of at most ERX_BYTES_CALL_MAX bytes in all. The state, which holds values derived
 * from the key, is erased before the call returns.
 */
static ERL_NIF_TERM
siphash24_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
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
	erx_explicit_bzero(&state, sizeof(state));
	if (!ok)
		return (enif_make_badarg(env));
	charge(env, total, SIPHASH_PERCENT_AT_MAX);
	return (enif_make_uint64(env, hash));
}

/*
 * The digest of ctx as a new 32-byte binary. erx_sha256_final erases ctx, so callers pass a
 * context of their own, never a state's.
 */
static ERL_NIF_TERM
make_digest(ErlNifEnv *env, erx_sha256_ctx_t *ctx)
{
	ERL_NIF_TERM digest;
	unsigned char *bytes;

	bytes = enif_make_new_binary(env, ERX_SHA256_DIGEST_LENGTH, &digest);
	erx_sha256_final(bytes, ctx);
	return (digest);
}

/*
 * A new state holding ctx, as a term. ctx is erased here, so no copy of the input's partial
 * block stays on a caller's stack. The NULL check is a guard only: ERTS ends the runtime rather
 * than fail an allocation.
 */
static ERL_NIF_TERM
make_state(ErlNifEnv *env, erx_sha256_ctx_t *ctx)
{
	erx_sha256_ctx_t *state;
	ERL_NIF_TERM term;

	state = enif_alloc_resource(sha256_state_type, sizeof(*state));
	if (state == NULL) {
		erx_explicit_bzero(ctx, sizeof(*ctx));
		return (enif_raise_exception(env, enif_make_atom(env, "system_limit")));
	}
	*state = *ctx;
	erx_explicit_bzero(ctx, sizeof(*ctx));
	term = enif_make_resource(env, state);
	enif_release_resource(state);
	return (term);
}

/* sha256_nif(Data): the SHA-256 digest of the binary Data of at most ERX_BYTES_CALL_MAX bytes. */
static ERL_NIF_TERM
sha256_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_sha256_ctx_t ctx;
	ErlNifBinary data;

	if (argc != 1 || !get_call_binary(env, argv[0], &data))
		return (enif_make_badarg(env));
	charge(env, data.size, SHA256_PERCENT_AT_MAX);
	erx_sha256_init(&ctx);
	erx_sha256_update(&ctx, data.data, data.size);
	return (make_digest(env, &ctx));
}

/* sha256_init_nif(): the state of no bytes. */
static ERL_NIF_TERM
sha256_init_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_sha256_ctx_t ctx;

	(void)argc;
	(void)argv;
	erx_sha256_init(&ctx);
	return (make_state(env, &ctx));
}

/*
 * sha256_update_nif(State, Data): a new state, of State's bytes followed by the binary Data of
 * at most ERX_BYTES_CALL_MAX bytes. State is left as it was. badarg unless State is a state.
 */
static ERL_NIF_TERM
sha256_update_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_sha256_ctx_t ctx, *state;
	ErlNifBinary data;

	if (argc != 2 || !enif_get_resource(env, argv[0], sha256_state_type, (void **)&state) ||
	    !get_call_binary(env, argv[1], &data))
		return (enif_make_badarg(env));
	charge(env, data.size, SHA256_PERCENT_AT_MAX);
	ctx = *state;
	erx_sha256_update(&ctx, data.data, data.size);
	return (make_state(env, &ctx));
}

/*
 * sha256_final_nif(State): the digest of State's bytes. State is left as it was, so it may be
 * finished again or updated further. badarg unless State is a state.
 */
static ERL_NIF_TERM
sha256_final_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_sha256_ctx_t ctx, *state;

	if (argc != 1 || !enif_get_resource(env, argv[0], sha256_state_type, (void **)&state))
		return (enif_make_badarg(env));
	ctx = *state;
	return (make_digest(env, &ctx));
}

/* Erases a state's context when its last reference goes. */
static void
sha256_state_dtor(ErlNifEnv *env, void *object)
{

	(void)env;
	erx_explicit_bzero(object, sizeof(erx_sha256_ctx_t));
}

/*
 * entropy_nif(N): N bytes, 1 to ERX_ENTROPY_BYTES_MAX, from one erx_entropy_read, which leaves
 * them at the head of this thread's UTCB mr, each word's bytes from its low byte. A failed read
 * raises {entropy, Status}, Status the ABI file's name of the status, or its integer for a value
 * no status names; nothing stands in for the bytes. The wrapper checks N, and so does this, since
 * a larger N would read past the result. The words are taken and zeroed right after the read,
 * before anything else can run on this thread (the binary's allocation included), so no later
 * store to mr can pass for entropy and no key stays behind in the UTCB or on the stack.
 */
static ERL_NIF_TERM
entropy_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	uint64_t words[ERX_ENTROPY_BYTES_MAX / sizeof(uint64_t)] = { 0 };
	erx_utcb_t *utcb;
	const char *name;
	ERL_NIF_TERM bytes, status_term;
	unsigned int len, count;
	int status;

	(void)argc;
	if (!enif_get_uint(env, argv[0], &len) || len < 1 || len > ERX_ENTROPY_BYTES_MAX)
		return (enif_make_badarg(env));
	status = erx_entropy_read(len);
	if (status != ERX_OK) {
		name = erx_status_name(status);
		status_term = name != NULL ? enif_make_atom(env, name) : enif_make_int(env, status);
		return (enif_raise_exception(env, enif_make_tuple2(env, enif_make_atom(env, "entropy"), status_term)));
	}
	utcb = erx_utcb_self();
	count = (len + sizeof(uint64_t) - 1) / sizeof(uint64_t);
	for (unsigned int i = 0; i < count; i++) {
		(void)erx_utcb_mr_load(utcb, i, &words[i]);
		(void)erx_utcb_mr_store(utcb, i, 0);
	}
	_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "a word's first byte is its low byte");
	memcpy(enif_make_new_binary(env, len, &bytes), words, len);
	erx_explicit_bzero(words, sizeof(words));
	return (bytes);
}

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{

	(void)priv;
	(void)info;
	sha256_state_type = enif_open_resource_type(env, NULL, "erx_bytes_sha256_state", sha256_state_dtor,
	    ERL_NIF_RT_CREATE, NULL);
	return (sha256_state_type == NULL ? 1 : 0);
}

static ErlNifFunc nif_funcs[] = {
	{ "crc32c_nif", 2, crc32c_nif, 0 },
	{ "inet_csum_nif", 2, inet_csum_nif, 0 },
	{ "inet_csum_update_nif", 3, inet_csum_update_nif, 0 },
	{ "siphash24_nif", 2, siphash24_nif, 0 },
	{ "entropy_nif", 1, entropy_nif, 0 },
	{ "sha256_nif", 1, sha256_nif, 0 },
	{ "sha256_init_nif", 0, sha256_init_nif, 0 },
	{ "sha256_update_nif", 2, sha256_update_nif, 0 },
	{ "sha256_final_nif", 1, sha256_final_nif, 0 },
};

ERL_NIF_INIT(erx_bytes, nif_funcs, load, NULL, NULL, NULL)
