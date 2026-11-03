/*
 * SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
 * Modified by erXos: the portable implementation only, by construction:
 * the x86, NEON and MSVC configuration, the SIMD and TBB declarations,
 * blake3_hash_many, blake3_xof_many, blake3_compress_xof and
 * blake3_simd_degree removed, so the kernel's build reaches no vector
 * instruction and no CPU-feature detection; the one compression function
 * renamed erx_blake3_compress_in_place and called directly, with no
 * dispatch; the constants the interface no longer exposes defined here;
 * freestanding C17 (no <assert.h> or <string.h>); the keyed and
 * key-derivation flags, which nothing sets (so the context's key is
 * always IV and its chunk flags 0), and the helpers nothing
 * calls (highest_one, round_down_to_power_of_2, load_key_words,
 * load_block_words, popcnt's fallback for compilers without
 * __builtin_popcountll) removed; INLINE is plain static inline, without
 * always_inline.
 *
 * BLAKE3 1.8.7, https://github.com/BLAKE3-team/BLAKE3, taken under
 * Apache-2.0 WITH LLVM-exception (LICENSE_A2LLVM beside this file);
 * erXos's changes are under the same licence.
 */
#ifndef BLAKE3_IMPL_H
#define BLAKE3_IMPL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "blake3.h"

#define BLAKE3_KEY_LEN 32
#define BLAKE3_CHUNK_LEN 1024

// internal flags
enum blake3_flags {
  CHUNK_START         = 1 << 0,
  CHUNK_END           = 1 << 1,
  PARENT              = 1 << 2,
  ROOT                = 1 << 3,
};

// Plain static inline, not always_inline: forced inlining at -O0 gives each
// of the 56 inlined G calls its own stack slots, a 5 KiB frame the kernel's
// stack proof refuses; -O2 inlines them all the same.
#define INLINE static inline

static const uint32_t IV[8] = {0x6A09E667UL, 0xBB67AE85UL, 0x3C6EF372UL,
                               0xA54FF53AUL, 0x510E527FUL, 0x9B05688CUL,
                               0x1F83D9ABUL, 0x5BE0CD19UL};

static const uint8_t MSG_SCHEDULE[7][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8},
    {3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1},
    {10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6},
    {12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4},
    {9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7},
    {11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13},
};

// Count the number of 1 bits.
INLINE unsigned int popcnt(uint64_t x) {
  return (unsigned int)__builtin_popcountll(x);
}

INLINE uint32_t counter_low(uint64_t counter) { return (uint32_t)counter; }

INLINE uint32_t counter_high(uint64_t counter) {
  return (uint32_t)(counter >> 32);
}

INLINE uint32_t load32(const void *src) {
  const uint8_t *p = (const uint8_t *)src;
  return ((uint32_t)(p[0]) << 0) | ((uint32_t)(p[1]) << 8) |
         ((uint32_t)(p[2]) << 16) | ((uint32_t)(p[3]) << 24);
}

INLINE void store32(void *dst, uint32_t w) {
  uint8_t *p = (uint8_t *)dst;
  p[0] = (uint8_t)(w >> 0);
  p[1] = (uint8_t)(w >> 8);
  p[2] = (uint8_t)(w >> 16);
  p[3] = (uint8_t)(w >> 24);
}

INLINE void store_cv_words(uint8_t bytes_out[32], uint32_t cv_words[8]) {
  store32(&bytes_out[0 * 4], cv_words[0]);
  store32(&bytes_out[1 * 4], cv_words[1]);
  store32(&bytes_out[2 * 4], cv_words[2]);
  store32(&bytes_out[3 * 4], cv_words[3]);
  store32(&bytes_out[4 * 4], cv_words[4]);
  store32(&bytes_out[5 * 4], cv_words[5]);
  store32(&bytes_out[6 * 4], cv_words[6]);
  store32(&bytes_out[7 * 4], cv_words[7]);
}

// The portable compression function, in blake3_portable.c: compresses one
// block into the chaining value cv in place.
void erx_blake3_compress_in_place(uint32_t cv[8],
                                  const uint8_t block[ERX_BLAKE3_BLOCK_LEN],
                                  uint8_t block_len, uint64_t counter,
                                  uint8_t flags);

#endif /* BLAKE3_IMPL_H */
