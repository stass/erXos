/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Reference identities (docs/design-runtime.md, "Unguessable references"). The permutation is
 * bitcoin-core's ctaes as erXos imported it (ctaes/ in the tree), a bit-sliced AES-128 whose
 * time and memory accesses do not depend on the key or the data. The block's fields and the
 * identity words are little-endian, as the ABI lays out erx_ref_block and erx_ref_identity.
 * It builds for the host, where its unit tests run.
 */

#include "erx_ref.h"

#include <stdbool.h>

#include "erx/explicit_bzero.h"

/* How many ordinals there are. */
#define SOURCE_ORDINALS		(UINT64_C(1) << ERX_REF_SOURCE_BITS)

static void
store32(uint8_t *bytes, uint32_t value)
{

	bytes[0] = (uint8_t)value;
	bytes[1] = (uint8_t)(value >> 8);
	bytes[2] = (uint8_t)(value >> 16);
	bytes[3] = (uint8_t)(value >> 24);
}

static uint32_t
load32(const uint8_t *bytes)
{

	return ((uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 |
	    (uint32_t)bytes[3] << 24);
}

static bool
source_spent(const erx_ref_source_t *source)
{

	return (source->remaining_low == 0 && source->remaining_high == 0);
}

/*
 * The block of source's next counter value, the last value less what remains. The
 * subtraction never borrows: below 64 bits remaining_high is 0 and remaining_low at most
 * the last value, and from 64 bits the last value's low word is all ones.
 */
_Static_assert(sizeof(((erx_ref_block_t *)0)->counter) == 3 * sizeof(uint32_t),
    "block_encode writes the ABI counter as three u32");

static void
block_encode(const erx_ref_source_t *source, uint8_t block[ERX_REF_BLOCK_SIZE])
{
	const uint64_t low = ERX_REF_COUNTER_LAST_LOW - source->remaining_low;
	const uint32_t counter[3] = { (uint32_t)low, (uint32_t)(low >> 32),
	    ERX_REF_COUNTER_LAST_HIGH - source->remaining_high };

	store32(block + ERX_REF_BLOCK_OFF_SOURCE, source->ordinal);
	for (uint32_t i = 0; i < 3; i++)
		store32(block + ERX_REF_BLOCK_OFF_COUNTER + i * sizeof(uint32_t), counter[i]);
}

/* One counter value of an unspent source used up. */
static void
counter_take(erx_ref_source_t *source)
{

	if (source->remaining_low == 0) {
		source->remaining_low = UINT64_MAX;
		source->remaining_high--;
	} else
		source->remaining_low--;
}

void
erx_ref_runtime_init(erx_ref_runtime_t *runtime, uint8_t bytes[ERX_REF_KEY_BYTES])
{

	AES128_init(&runtime->aes, bytes);
	erx_explicit_bzero(bytes, ERX_REF_KEY_BYTES);
	atomic_init(&runtime->taken, 0);
}

void
erx_ref_permute(const erx_ref_runtime_t *runtime, const uint8_t in[ERX_REF_BLOCK_SIZE],
    uint8_t out[ERX_REF_IDENTITY_SIZE])
{

	AES128_encrypt(&runtime->aes, 1, out, in);
}

/*
 * The compare-and-swap takes an ordinal only while one is left, so the count never passes
 * the number of ordinals however many threads ask.
 */
int
erx_ref_source_open(erx_ref_runtime_t *runtime, erx_ref_source_t *source)
{
	uint64_t taken = atomic_load_explicit(&runtime->taken, memory_order_relaxed);

	do {
		if (taken >= SOURCE_ORDINALS)
			return (ERX_ELIMIT);
	} while (!atomic_compare_exchange_weak_explicit(&runtime->taken, &taken, taken + 1,
	    memory_order_relaxed, memory_order_relaxed));
	source->ordinal = (uint32_t)taken;
	source->remaining_high = ERX_REF_COUNTER_LAST_HIGH;
	source->remaining_low = ERX_REF_COUNTER_LAST_LOW;
	return (ERX_OK);
}

int
erx_ref_make(const erx_ref_runtime_t *runtime, erx_ref_source_t *source,
    uint32_t words[ERX_REF_WORDS])
{
	uint8_t block[ERX_REF_BLOCK_SIZE], identity[ERX_REF_IDENTITY_SIZE];

	if (source_spent(source))
		return (ERX_ELIMIT);
	block_encode(source, block);
	erx_ref_permute(runtime, block, identity);
	counter_take(source);
	for (uint32_t i = 0; i < ERX_REF_WORDS; i++)
		words[i] = load32(identity + ERX_REF_IDENTITY_OFF_ID + i * sizeof(uint32_t));
	return (ERX_OK);
}

/*
 * The block's fields are checked against what erx_ref_make enciphers: an ordinal the
 * runtime has handed out, and a counter value below the last, which no reference takes.
 */
int
erx_ref_source_of(const erx_ref_runtime_t *runtime, const uint32_t words[ERX_REF_WORDS],
    uint32_t *ordinal)
{
	uint8_t identity[ERX_REF_IDENTITY_SIZE], block[ERX_REF_BLOCK_SIZE];
	uint64_t low;
	uint32_t source, high;

	for (uint32_t i = 0; i < ERX_REF_WORDS; i++)
		store32(identity + ERX_REF_IDENTITY_OFF_ID + i * sizeof(uint32_t), words[i]);
	AES128_decrypt(&runtime->aes, 1, block, identity);
	source = load32(block + ERX_REF_BLOCK_OFF_SOURCE);
	low = (uint64_t)load32(block + ERX_REF_BLOCK_OFF_COUNTER) |
	    (uint64_t)load32(block + ERX_REF_BLOCK_OFF_COUNTER + sizeof(uint32_t)) << 32;
	high = load32(block + ERX_REF_BLOCK_OFF_COUNTER + 2 * sizeof(uint32_t));
	if (source >= atomic_load_explicit(&runtime->taken, memory_order_relaxed))
		return (ERX_EINVAL);
	if (high > ERX_REF_COUNTER_LAST_HIGH ||
	    (high == ERX_REF_COUNTER_LAST_HIGH && low >= ERX_REF_COUNTER_LAST_LOW))
		return (ERX_EINVAL);
	*ordinal = source;
	return (ERX_OK);
}
