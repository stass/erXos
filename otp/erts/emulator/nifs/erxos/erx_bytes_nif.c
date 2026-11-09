/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The per-byte primitives of erx_bytes (docs/design-runtime.md, "Per-byte primitives"),
 * statically linked NIFs on binaries. Each works on at most ERX_BYTES_CALL_MAX bytes, so a call
 * ends within a reduction slice on a normal scheduler and never waits; the Erlang wrappers
 * stream longer inputs. The work is in the cores beside this file and in kernel/crypto/sha2,
 * which build for the host. The network primitives, inet_csum/2, inet_csum_update/3 and
 * siphash24/2, are erx_net's NIF functions (erlang/apps/erx_net/c_src/erx_net_bytes.c), which
 * this table lists as erx_net's portable library does, so both builds run the same C. Beside
 * them, entropy_nif is Erlang's entry to the kernel's generator.
 */

#define STATIC_ERLANG_NIF 1

#include <string.h>

#include "erl_nif.h"

#include "erlang/apps/erx_net/c_src/erx_net_bytes.h"
#include "erx/explicit_bzero.h"
#include "kernel/crypto/sha2/sha256.h"
#include "liberx/backend/api.h"

#include "erx_crc32c.h"

/* The most bytes one call works on, so a call stays within a reduction slice. */
#define ERX_BYTES_CALL_MAX	65536u
_Static_assert(ERX_BYTES_CALL_MAX == ERX_NET_BYTES_CALL_MAX,
    "erx_bytes.erl checks one bound for every primitive");

/*
 * The percent of a reduction slice, about a millisecond, that a call of ERX_BYTES_CALL_MAX bytes
 * is charged: CRC-32C's two table steps a byte and the portable SHA-256 each take about a quarter
 * of a slice over 64 KiB on the development host (Apple M-series, native, clang -O2; SHA-256
 * about 240 microseconds). Slower targets are a watch-list item (docs/todo-performance.md).
 */
#define CRC32C_PERCENT_AT_MAX	24
#define SHA256_PERCENT_AT_MAX	25

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
	ERX_NET_BYTES_NIFS,
	{ "entropy_nif", 1, entropy_nif, 0 },
	{ "sha256_nif", 1, sha256_nif, 0 },
	{ "sha256_init_nif", 0, sha256_init_nif, 0 },
	{ "sha256_update_nif", 2, sha256_update_nif, 0 },
	{ "sha256_final_nif", 1, sha256_final_nif, 0 },
};

ERL_NIF_INIT(erx_bytes, nif_funcs, load, NULL, NULL, NULL)
