/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_REF_H
#define ERX_REF_H

#include <stdatomic.h>
#include <stdint.h>

#include "erx/abi.h"
#include "ctaes/ctaes.h"

/*
 * A reference's identity (docs/design-runtime.md, "Unguessable references"): the four words
 * of AES-128(key, source || counter), the block laid out as the ABI's erx_ref_block and the
 * result read as its erx_ref_identity. A domain's runtime holds one erx_ref_runtime_t: its
 * secret key and the count of source ordinals it has handed out. Each thread that makes
 * references opens a source from it, with an ordinal no other source has had; each reference
 * the thread makes takes the source's next counter value. AES is a permutation, so no two
 * references of one runtime share their identity, and the key is secret, so a party that has
 * seen some identities can name another only by guessing.
 *
 * The widths of an ordinal and of a counter. ERTS builds use the full widths, which fill the
 * block; a host test narrows them to reach exhaustion.
 */
#ifndef ERX_REF_SOURCE_BITS
#define ERX_REF_SOURCE_BITS	32
#endif
#ifndef ERX_REF_COUNTER_BITS
#define ERX_REF_COUNTER_BITS	96
#endif

_Static_assert(ERX_REF_SOURCE_BITS >= 1 && ERX_REF_SOURCE_BITS <= 32, "a source ordinal fills one u32");
_Static_assert(ERX_REF_COUNTER_BITS >= 2 && ERX_REF_COUNTER_BITS <= 96, "a counter fills three u32");
_Static_assert(ERX_REF_BLOCK_SIZE == 16 && ERX_REF_IDENTITY_SIZE == 16, "an AES-128 block");
_Static_assert(ERX_REF_WORDS * sizeof(uint32_t) == ERX_REF_IDENTITY_SIZE, "four identity words");

/*
 * A counter's last value, 2^ERX_REF_COUNTER_BITS - 1, as high:low. No reference takes it, so
 * a source has exactly that many values, 0 to the last value less one.
 */
#if ERX_REF_COUNTER_BITS >= 64
#define ERX_REF_COUNTER_LAST_LOW	UINT64_MAX
#if ERX_REF_COUNTER_BITS == 96
#define ERX_REF_COUNTER_LAST_HIGH	UINT32_MAX
#else
#define ERX_REF_COUNTER_LAST_HIGH	((UINT32_C(1) << (ERX_REF_COUNTER_BITS - 64)) - 1)
#endif
#else
#define ERX_REF_COUNTER_LAST_LOW	((UINT64_C(1) << ERX_REF_COUNTER_BITS) - 1)
#define ERX_REF_COUNTER_LAST_HIGH	UINT32_C(0)
#endif

/*
 * A domain's runtime's references: the AES-128 round keys of its key, read-only once set, and
 * how many ordinals its sources have taken, never more than 2^ERX_REF_SOURCE_BITS. Threads
 * open sources concurrently. A runtime has one, so no two sources share an ordinal.
 */
typedef struct erx_ref_runtime {
	AES128_ctx		aes;
	_Atomic uint64_t	taken;
} erx_ref_runtime_t;

/*
 * One thread's source: its ordinal and how many counter values it has left, as the 96-bit
 * number remaining_high:remaining_low; the counter value its next reference takes is the
 * last value less that. Only its thread uses it, and nothing copies it. A source with none
 * left is spent, a zero-initialised one included, so a source that was never opened makes
 * no reference rather than repeat another's.
 */
typedef struct erx_ref_source {
	uint32_t	ordinal;
	uint32_t	remaining_high;
	uint64_t	remaining_low;
} erx_ref_source_t;

/*
 * Sets runtime's key from bytes, which it then erases, and its sources to none taken. A
 * runtime is set up once: setting it again would hand out its ordinals again.
 */
void	erx_ref_runtime_init(erx_ref_runtime_t *runtime, uint8_t bytes[ERX_REF_KEY_BYTES]);

/* The AES-128 block primitive (FIPS 197): out is in enciphered under runtime's key. */
void	erx_ref_permute(const erx_ref_runtime_t *runtime, const uint8_t in[ERX_REF_BLOCK_SIZE],
	    uint8_t out[ERX_REF_IDENTITY_SIZE]);

/*
 * Opens source with the next ordinal of runtime and every counter value left. ERX_ELIMIT,
 * leaving source untouched, once every ordinal has been taken; ordinals are never reused.
 */
int	erx_ref_source_open(erx_ref_runtime_t *runtime, erx_ref_source_t *source);

/*
 * The identity of the next reference of source, in words, and the counter value used up.
 * ERX_ELIMIT, leaving words and source untouched, once source is spent.
 */
int	erx_ref_make(const erx_ref_runtime_t *runtime, erx_ref_source_t *source,
	    uint32_t words[ERX_REF_WORDS]);

/*
 * The ordinal of the source whose reference has the identity words, deciphered, so ERTS can
 * route a request to the thread that owns what the reference names (a timer). words is
 * untrusted input: ERX_EINVAL, leaving ordinal untouched, unless the block names an ordinal
 * runtime has handed out and a counter value below the last, as every block erx_ref_make
 * enciphers does. A forged identity passes with probability about taken / 2^32, and then
 * names a source that exists, so a caller indexing by the ordinal stays in bounds.
 */
int	erx_ref_source_of(const erx_ref_runtime_t *runtime, const uint32_t words[ERX_REF_WORDS],
	    uint32_t *ordinal);

#endif
