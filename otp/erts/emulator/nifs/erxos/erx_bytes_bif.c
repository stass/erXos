/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_bytes's BIFs, the per-byte primitives of docs/design-runtime.md ("Per-byte primitives")
 * and the entropy entry beside them. They are BIFs rather than NIFs because the network stack
 * calls them several times a segment, where a NIF's call path and its Erlang wrapper's
 * flattening of iodata cost more than a small call's work. Each BIF checks its own
 * arguments; erx_bytes.erl holds only their documentation.
 *
 * Every call works on at most ERX_BYTES_CALL_MAX bytes, so it ends within a reduction slice on
 * a normal scheduler and never waits, and is charged reductions for its work
 * (erx_bytes_reductions). inet_csum/2 and siphash24/2 walk their iodata with erx_net's
 * erx_iodata_walk, as the portable NIF library does outside erXos, through classify below;
 * crc32c/2 leaves longer inputs to its caller, and sha256_update/2 takes a binary of any size
 * and traps to itself between pieces of ERX_BYTES_CALL_MAX bytes, as ERTS's own md5_update/2
 * does. The work is in erx_net's cores (erlang/apps/erx_net/c_src), erx_crc32c.c beside this
 * file and kernel/crypto/sha2, all of which build for the host.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <string.h>

#include "sys.h"
#include "global.h"
#include "bif.h"
#include "big.h"
#include "erl_binary.h"
#include "erl_bits.h"
#include "erl_process.h"
#include "error.h"

#include "erlang/apps/erx_net/c_src/erx_inet_csum.h"
#include "erlang/apps/erx_net/c_src/erx_iodata.h"
#include "erlang/apps/erx_net/c_src/erx_siphash.h"
#include "erlang/apps/erx_net/c_src/erx_tcp_merge.h"
#include "erx/explicit_bzero.h"
#include "kernel/crypto/sha2/sha256.h"
#include "liberx/backend/api.h"

#include "erx_crc32c.h"

_Static_assert(sizeof(Eterm) == sizeof(erx_iodata_term_t), "a term is a word");
_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "entropy/1: a word's first byte is its low byte");

/*
 * The reductions a call over ERX_BYTES_CALL_MAX bytes is charged: CRC-32C's two table steps a
 * byte and the portable SHA-256 each take about a quarter of a slice over 64 KiB on the
 * development host (Apple M-series, native, clang -O2; SHA-256 about 240 microseconds). Slower
 * targets are a watch-list item (docs/todo-performance.md).
 */
#define CRC32C_REDS_AT_MAX	960u
#define SHA256_REDS_AT_MAX	1000u

_Static_assert(ERX_BYTES_SLICE_REDS == CONTEXT_REDS, "erx_iodata.h's slice is ERTS's");
_Static_assert(sizeof(Uint) >= sizeof(uint64_t), "siphash24/2's result is a Uint");

/*
 * True when term is a binary of whole bytes, whose size *size then is. Nothing is copied, so
 * a size can be checked before any copy is made.
 */
static bool
binary_size(Eterm term, Uint *size)
{
	const byte *base;
	Uint offset, bits;

	if (!is_bitstring(term))
		return (false);
	ERTS_GET_BITSTRING(term, base, offset, bits);
	(void)base;
	(void)offset;
	if (TAIL_BITS(bits) != 0)
		return (false);
	*size = BYTE_SIZE(bits);
	return (true);
}

/*
 * The first length bytes of the binary term, whose size binary_size has checked: in place, or
 * when the binary starts at a bit offset, copied into a block of ERTS_ALC_T_TMP that *copy
 * then is, for the caller to free with erts_free once it is done; *copy is NULL otherwise.
 */
static const byte *
binary_prefix(Eterm term, Uint length, byte **copy)
{
	const byte *base;
	Uint offset, bits;

	ERTS_GET_BITSTRING(term, base, offset, bits);
	(void)bits;
	*copy = NULL;
	if (BIT_OFFSET(offset) == 0)
		return (&base[BYTE_OFFSET(offset)]);
	*copy = erts_alloc(ERTS_ALC_T_TMP, length > 0 ? length : 1);
	erts_copy_bits_fwd(base, offset, *copy, 0, length * 8);
	return (*copy);
}

/* Says what one term is, for erx_iodata_walk; a binary over room is refused before a copy. */
static void
classify(void *env, erx_iodata_term_t word, size_t room, erx_iodata_item_t *item)
{
	Eterm term = (Eterm)word;
	Eterm *cell;
	Uint size;
	byte *copy;

	(void)env;
	item->copy = NULL;
	if (is_list(term)) {
		cell = list_val(term);
		item->kind = ERX_IODATA_CELL;
		item->head = (erx_iodata_term_t)CAR(cell);
		item->tail = (erx_iodata_term_t)CDR(cell);
	} else if (is_byte(term)) {
		item->kind = ERX_IODATA_BYTE;
		item->value = (uint8_t)unsigned_val(term);
	} else if (is_nil(term)) {
		item->kind = ERX_IODATA_NIL;
	} else if (binary_size(term, &size) && size <= room) {
		item->kind = ERX_IODATA_BINARY;
		item->data = binary_prefix(term, size, &copy);
		item->size = size;
		item->copy = copy;
	} else {
		item->kind = ERX_IODATA_OTHER;
	}
}

static void *
resize(void *env, void *block, size_t bytes)
{

	(void)env;
	return (block == NULL ? erts_alloc_fnf(ERTS_ALC_T_TMP, bytes) :
	    erts_realloc_fnf(ERTS_ALC_T_TMP, block, bytes));
}

static void
release(void *env, void *block)
{

	(void)env;
	erts_free(ERTS_ALC_T_TMP, block);
}

static const erx_iodata_layer_t layer = {
	.classify = classify, .resize = resize, .release = release, .env = NULL
};

/* Fails the BIF for a refused walk: badarg, or system_limit when its stack could not grow. */
#define WALK_ERROR(p, status) \
	BIF_ERROR((p), (status) == ERX_IODATA_NOMEM ? SYSTEM_LIMIT : BADARG)

/* Adds a run to the running Internet checksum sum at context. */
static void
sum_run(void *context, const uint8_t *data, size_t length, size_t before)
{
	uint16_t *sum = context;

	*sum = erx_inet_sum(*sum, data, length, before);
}

/* Gives a run to the SipHash state at context. */
static void
hash_run(void *context, const uint8_t *data, size_t length, size_t before)
{

	(void)before;
	erx_siphash24_update(context, data, length);
}

/* True when term is a small integer in 0..max, which *value then is. */
static bool
get_small_upto(Eterm term, Uint max, Uint *value)
{

	if (!is_small(term) || signed_val(term) < 0 || (Uint)signed_val(term) > max)
		return (false);
	*value = (Uint)signed_val(term);
	return (true);
}

/*
 * crc32c(Crc, Data): CRC-32C of the binary Data after the bytes whose value is Crc, 0 for
 * none. badarg unless Crc is an integer in 0..16#FFFFFFFF and Data a binary of at most
 * ERX_BYTES_CALL_MAX bytes.
 */
BIF_RETTYPE
erx_bytes_crc32c_2(BIF_ALIST_2)
{
	const byte *data;
	Uint crc, size;
	uint32_t result;
	byte *copy;

	if (!term_to_UWord(BIF_ARG_1, &crc) || crc > UINT32_MAX)
		BIF_ERROR(BIF_P, BADARG);
	if (!binary_size(BIF_ARG_2, &size) || size > ERX_BYTES_CALL_MAX)
		BIF_ERROR(BIF_P, BADARG);
	data = binary_prefix(BIF_ARG_2, size, &copy);
	result = erx_crc32c((uint32_t)crc, data, size);
	if (copy != NULL)
		erts_free(ERTS_ALC_T_TMP, copy);
	BUMP_REDS(BIF_P, erx_bytes_reductions(size, 0, CRC32C_REDS_AT_MAX));
	BIF_RET(erts_make_integer(result, BIF_P));
}

/*
 * inet_csum(Sum, Data): the Internet checksum sum of Data's bytes, continuing from Sum, the
 * sum of bytes before them of even length. badarg unless Sum is an integer in 0..16#FFFF and
 * Data iodata within erx_iodata.h's limits.
 */
BIF_RETTYPE
erx_bytes_inet_csum_2(BIF_ALIST_2)
{
	erx_iodata_status_t status;
	erx_iodata_walked_t walked;
	uint16_t sum;
	Uint start;

	if (!get_small_upto(BIF_ARG_1, 0xffffu, &start))
		BIF_ERROR(BIF_P, BADARG);
	sum = (uint16_t)start;
	status = erx_iodata_walk(&layer, (erx_iodata_term_t)BIF_ARG_2, sum_run, &sum, &walked);
	BUMP_REDS(BIF_P, erx_bytes_reductions(walked.bytes, walked.cells, ERX_INET_CSUM_REDS_AT_MAX));
	if (status != ERX_IODATA_OK)
		WALK_ERROR(BIF_P, status);
	BIF_RET(make_small(sum));
}

/*
 * inet_csum_update(Checksum, Before, After): the checksum field that replaces Checksum when
 * the bytes Before, at an even offset of what it covers, become the bytes After. badarg unless
 * Checksum is an integer in 0..16#FFFF and Before and After are binaries of one even size of
 * at most ERX_BYTES_CALL_MAX bytes.
 */
BIF_RETTYPE
erx_bytes_inet_csum_update_3(BIF_ALIST_3)
{
	const byte *before, *after;
	byte *before_copy, *after_copy;
	Uint checksum, size, after_size;
	uint16_t result;

	if (!get_small_upto(BIF_ARG_1, 0xffffu, &checksum) || !binary_size(BIF_ARG_2, &size) ||
	    !binary_size(BIF_ARG_3, &after_size) || size != after_size || size % 2 != 0 ||
	    size > ERX_BYTES_CALL_MAX)
		BIF_ERROR(BIF_P, BADARG);
	before = binary_prefix(BIF_ARG_2, size, &before_copy);
	after = binary_prefix(BIF_ARG_3, size, &after_copy);
	result = erx_inet_csum_update((uint16_t)checksum, before, after, size);
	if (before_copy != NULL)
		erts_free(ERTS_ALC_T_TMP, before_copy);
	if (after_copy != NULL)
		erts_free(ERTS_ALC_T_TMP, after_copy);
	BUMP_REDS(BIF_P, erx_bytes_reductions(2 * size, 0, ERX_INET_CSUM_REDS_AT_MAX));
	BIF_RET(make_small(result));
}

/*
 * siphash24(Key, Data): SipHash-2-4 of Data's bytes under the 16-byte binary Key, as an
 * integer in 0..2^64-1. badarg unless Key is a 16-byte binary and Data iodata within
 * erx_iodata.h's limits. The state, which holds values derived from the key, and any copy of
 * the key are erased before the call returns.
 */
BIF_RETTYPE
erx_bytes_siphash24_2(BIF_ALIST_2)
{
	erx_iodata_status_t status;
	erx_iodata_walked_t walked;
	erx_siphash_t state;
	const byte *key;
	byte *key_copy;
	uint64_t hash;
	Uint size;

	if (!binary_size(BIF_ARG_1, &size) || size != ERX_SIPHASH_KEY_LENGTH)
		BIF_ERROR(BIF_P, BADARG);
	key = binary_prefix(BIF_ARG_1, size, &key_copy);
	erx_siphash24_init(&state, key);
	if (key_copy != NULL) {
		erx_explicit_bzero(key_copy, size);
		erts_free(ERTS_ALC_T_TMP, key_copy);
	}
	status = erx_iodata_walk(&layer, (erx_iodata_term_t)BIF_ARG_2, hash_run, &state, &walked);
	hash = erx_siphash24_final(&state);
	erx_siphash24_erase(&state);
	BUMP_REDS(BIF_P, erx_bytes_reductions(walked.bytes, walked.cells, ERX_SIPHASH_REDS_AT_MAX));
	if (status != ERX_IODATA_OK)
		WALK_ERROR(BIF_P, status);
	BIF_RET(erts_make_integer((Uint)hash, BIF_P));
}

/*
 * One frame of a tcp_merge/1 batch: a binary of whole bytes, or {sum, Sum, Binary} with Sum its
 * network sum. *binary is the frame's binary term; its bytes are not reached yet, so a batch
 * past the merge's limit is refused before anything is copied.
 */
static bool
get_merge_frame(Eterm term, erx_tcp_merge_in_t *frame, Eterm *binary)
{
	Eterm *tuple;
	Uint size, sum;

	*frame = (erx_tcp_merge_in_t){ .has_sum = false };
	*binary = term;
	if (is_tuple(term)) {
		tuple = tuple_val(term);
		if (arityval(tuple[0]) != 3 || tuple[1] != am_sum || !get_small_upto(tuple[2], 0xffffu, &sum))
			return (false);
		frame->has_sum = true;
		frame->sum = (uint16_t)sum;
		*binary = tuple[3];
	}
	if (!binary_size(*binary, &size))
		return (false);
	frame->length = size;
	return (true);
}

/*
 * What one call of tcp_merge/1 keeps per frame, about 20 KiB, allocated for the call from the
 * scheduler's temporary allocator instead of on its stack.
 */
typedef struct merge_scratch {
	erx_tcp_merge_in_t in[ERX_TCP_MERGE_FRAMES_MAX];
	erx_tcp_merge_out_t out[ERX_TCP_MERGE_FRAMES_MAX];
	Eterm given[ERX_TCP_MERGE_FRAMES_MAX], binaries[ERX_TCP_MERGE_FRAMES_MAX];
	Eterm summed[ERX_TCP_MERGE_FRAMES_MAX], payloads[ERX_TCP_MERGE_FRAMES_MAX];
	byte *copies[ERX_TCP_MERGE_FRAMES_MAX];
} merge_scratch_t;

static Eterm tcp_merge_with(Process *, Eterm, merge_scratch_t *);

/*
 * tcp_merge(Frames): the units of erx_tcp_merge over one batch, in order of their first frames
 * (erlang/apps/erx_net/c_src/erx_tcp_merge.h), as the portable NIF answers them: a frame on its
 * own is {sum, Sum, Frame}, the very term it came as when it came with its sum; a unit of
 * several is {merged, N, First, Last, Payload}, its first and last frames so and each member's
 * payload, a sub-binary of its frame, in order, the empty ones left out. badarg unless Frames is
 * a proper list of frames within the merge's limit. A frame at a bit offset is copied before
 * the merge reads it, at most twice ERX_TCP_MERGE_BYTES_MAX bytes in all.
 */
BIF_RETTYPE
erx_bytes_tcp_merge_1(BIF_ALIST_1)
{
	merge_scratch_t *scratch;
	Eterm units;

	scratch = erts_alloc(ERTS_ALC_T_TMP, sizeof(*scratch));
	units = tcp_merge_with(BIF_P, BIF_ARG_1, scratch);
	erts_free(ERTS_ALC_T_TMP, scratch);
	if (is_non_value(units))
		BIF_ERROR(BIF_P, BADARG);
	BIF_RET(units);
}

/* tcp_merge/1 over frames with its per-frame arrays in scratch; THE_NON_VALUE for badarg. */
static Eterm
tcp_merge_with(Process *p, Eterm frames, merge_scratch_t *scratch)
{
	erx_tcp_merge_in_t *in = scratch->in;
	erx_tcp_merge_out_t *out = scratch->out;
	Eterm *given = scratch->given, *binaries = scratch->binaries;
	Eterm *summed = scratch->summed, *payloads = scratch->payloads;
	byte **copies = scratch->copies;
	size_t count, i;
	erx_tcp_merge_status_t status;
	Eterm list, unit, units, *hp;

	count = 0;
	for (list = frames; is_list(list); list = CDR(list_val(list)), count++) {
		if (count == ERX_TCP_MERGE_FRAMES_MAX ||
		    !get_merge_frame(CAR(list_val(list)), &in[count], &binaries[count]))
			return (THE_NON_VALUE);
		given[count] = CAR(list_val(list));
	}
	if (is_not_nil(list) || !erx_tcp_merge_within_limit(in, count))
		return (THE_NON_VALUE);
	for (i = 0; i < count; i++)
		in[i].data = binary_prefix(binaries[i], in[i].length, &copies[i]);
	status = erx_tcp_merge(in, count, out);
	BUMP_REDS(p, erx_bytes_reductions(erx_tcp_merge_bytes_read(in, count), 0,
	    ERX_INET_CSUM_REDS_AT_MAX));
	for (i = 0; i < count; i++)
		if (copies[i] != NULL)
			erts_free(ERTS_ALC_T_TMP, copies[i]);
	if (status != ERX_TCP_MERGE_OK)
		return (THE_NON_VALUE);
	/*
	 * summed[i] is frame i as {sum, Sum, Frame}; payloads[i] is the list of payloads of the unit
	 * that frame i starts, built from the back so each piece is consed in front of the later
	 * ones, as the units' list is.
	 */
	for (i = 0; i < count; i++) {
		summed[i] = given[i];
		if (!in[i].has_sum) {
			hp = HAlloc(p, 4);
			summed[i] = TUPLE3(hp, am_sum, make_small(out[i].sum), binaries[i]);
		}
		payloads[i] = NIL;
	}
	for (i = count; i-- > 0;) {
		if (out[i].payload_length > 0) {
			unit = erts_make_sub_binary(p, binaries[i], out[i].payload, out[i].payload_length);
			hp = HAlloc(p, 2);
			payloads[out[i].unit] = CONS(hp, unit, payloads[out[i].unit]);
		}
	}
	units = NIL;
	for (i = count; i-- > 0;) {
		if (out[i].members == 0)
			continue;
		unit = summed[i];
		if (out[i].members > 1) {
			hp = HAlloc(p, 6);
			unit = TUPLE5(hp, am_merged, make_small(out[i].members), summed[i],
			    summed[out[i].last], payloads[i]);
		}
		hp = HAlloc(p, 2);
		units = CONS(hp, unit, units);
	}
	return (units);
}

/* tcp_merge_limit(): {ERX_TCP_MERGE_FRAMES_MAX, ERX_TCP_MERGE_BYTES_MAX}, the merge's limit. */
BIF_RETTYPE
erx_bytes_tcp_merge_limit_0(BIF_ALIST_0)
{
	Eterm *hp = HAlloc(BIF_P, 3);

	BIF_RET(TUPLE2(hp, make_small(ERX_TCP_MERGE_FRAMES_MAX), make_small(ERX_TCP_MERGE_BYTES_MAX)));
}

/*
 * A SHA-256 state of sha256_init/0 and sha256_update/2: a magic reference to the context of
 * the bytes given so far, as ERTS's atomics and counters are. A state is never changed once
 * made: an update makes a new state from a copy of the old one, so a state is an Erlang value
 * that any process of this runtime may hold, reuse or send, and needs no lock. The destructor
 * erases the context, which holds a copy of the input's last partial block.
 */
static int
sha256_state_destructor(Binary *state)
{

	erx_explicit_bzero(ERTS_MAGIC_BIN_DATA(state), sizeof(erx_sha256_ctx_t));
	return (1);
}

/* The context of the state term, or NULL unless term is a state. */
static const erx_sha256_ctx_t *
sha256_state(Eterm term)
{
	Binary *state;

	if (!is_internal_magic_ref(term))
		return (NULL);
	state = erts_magic_ref2bin(term);
	if (ERTS_MAGIC_BIN_DESTRUCTOR(state) != sha256_state_destructor)
		return (NULL);
	return (ERTS_MAGIC_BIN_DATA(state));
}

/* A new state holding ctx, as a term. ctx is erased, so no copy of its partial block stays. */
static Eterm
make_sha256_state(Process *p, erx_sha256_ctx_t *ctx)
{
	Binary *state;
	Eterm *hp;

	state = erts_create_magic_binary(sizeof(*ctx), sha256_state_destructor);
	memcpy(ERTS_MAGIC_BIN_DATA(state), ctx, sizeof(*ctx));
	erx_explicit_bzero(ctx, sizeof(*ctx));
	hp = HAlloc(p, ERTS_MAGIC_REF_THING_SIZE);
	return (erts_mk_magic_ref(&hp, &MSO(p), state));
}

/* The digest of ctx as a new 32-byte binary. erx_sha256_final erases ctx. */
static Eterm
make_digest(Process *p, erx_sha256_ctx_t *ctx)
{
	byte *bytes;
	Eterm digest;

	digest = erts_new_binary(p, ERX_SHA256_DIGEST_LENGTH, &bytes);
	erx_sha256_final(bytes, ctx);
	return (digest);
}

/*
 * Adds the first piece of the binary data, at most ERX_BYTES_CALL_MAX of its size bytes, to
 * ctx and charges it; the count of bytes it took.
 */
static Uint
sha256_piece(Process *p, erx_sha256_ctx_t *ctx, Eterm data, Uint size)
{
	const byte *bytes;
	Uint length;
	byte *copy;

	length = size < ERX_BYTES_CALL_MAX ? size : ERX_BYTES_CALL_MAX;
	bytes = binary_prefix(data, length, &copy);
	erx_sha256_update(ctx, bytes, length);
	if (copy != NULL) {
		erx_explicit_bzero(copy, length);
		erts_free(ERTS_ALC_T_TMP, copy);
	}
	BUMP_REDS(p, erx_bytes_reductions(length, 0, SHA256_REDS_AT_MAX));
	return (length);
}

/* sha256_init(): the state of no bytes. */
BIF_RETTYPE
erx_bytes_sha256_init_0(BIF_ALIST_0)
{
	erx_sha256_ctx_t ctx;

	erx_sha256_init(&ctx);
	BIF_RET(make_sha256_state(BIF_P, &ctx));
}

/*
 * sha256_update(State, Data): a new state, of State's bytes followed by the binary Data of any
 * size. State is left as it was. A Data longer than ERX_BYTES_CALL_MAX bytes is taken a piece
 * at a time: each call takes one piece and traps back to this BIF with the state so far and
 * the rest, so a long binary is preempted like a loop of calls. badarg unless State is a state and
 * Data a binary.
 */
BIF_RETTYPE
erx_bytes_sha256_update_2(BIF_ALIST_2)
{
	const erx_sha256_ctx_t *state;
	erx_sha256_ctx_t ctx;
	Eterm next;
	Uint size, taken;

	state = sha256_state(BIF_ARG_1);
	if (state == NULL || !binary_size(BIF_ARG_2, &size))
		BIF_ERROR(BIF_P, BADARG);
	ctx = *state;
	taken = sha256_piece(BIF_P, &ctx, BIF_ARG_2, size);
	next = make_sha256_state(BIF_P, &ctx);
	if (taken == size)
		BIF_RET(next);
	BIF_TRAP2(BIF_TRAP_EXPORT(BIF_erx_bytes_sha256_update_2), BIF_P, next,
	    erts_make_sub_binary(BIF_P, BIF_ARG_2, taken, size - taken));
}

/*
 * sha256_final(State): the digest of State's bytes. State is left as it was, so it may be
 * finished again or updated further. badarg unless State is a state.
 */
BIF_RETTYPE
erx_bytes_sha256_final_1(BIF_ALIST_1)
{
	const erx_sha256_ctx_t *state;
	erx_sha256_ctx_t ctx;

	state = sha256_state(BIF_ARG_1);
	if (state == NULL)
		BIF_ERROR(BIF_P, BADARG);
	ctx = *state;
	BIF_RET(make_digest(BIF_P, &ctx));
}

/*
 * entropy(N): N bytes, 1 to ERX_ENTROPY_BYTES_MAX, from one erx_entropy_take straight into the
 * new binary, so no copy of them stays behind in this thread's mr or on the stack. A failed read raises
 * {entropy, Status}, Status the ABI file's name of the status, or its integer for a value no
 * status names; nothing stands in for the bytes, and the binary, never filled, is garbage.
 */
BIF_RETTYPE
erx_bytes_entropy_1(BIF_ALIST_1)
{
	const char *name;
	Eterm bytes, status_term, *hp;
	byte *data;
	Uint len;
	int status;

	if (!get_small_upto(BIF_ARG_1, ERX_ENTROPY_BYTES_MAX, &len) || len < 1)
		BIF_ERROR(BIF_P, BADARG);
	bytes = erts_new_binary(BIF_P, len, &data);
	status = erx_entropy_take(data, (uint32_t)len);
	if (status != ERX_OK) {
		name = erx_status_name(status);
		status_term = name != NULL ?
		    erts_atom_put((const byte *)name, (Sint)strlen(name), ERTS_ATOM_ENC_7BIT_ASCII, 1) :
		    make_small(status);
		hp = HAlloc(BIF_P, 3);
		BIF_P->fvalue = TUPLE2(hp, am_entropy, status_term);
		BIF_ERROR(BIF_P, EXC_ERROR);
	}
	BIF_RET(bytes);
}
