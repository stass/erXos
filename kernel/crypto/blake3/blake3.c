/*
 * SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
 * Modified by erXos: the portable implementation only, one chunk at a
 * time: update hashes each whole chunk through the context's own chunk
 * state and pushes its chaining value, so the SIMD subtree code
 * (compress_chunks_parallel, compress_parents_parallel,
 * blake3_compress_subtree_wide, which recursed, and
 * compress_subtree_to_parent_node) and left_subtree_len are removed; the
 * digest is the same, from the same compressions, and nothing recurses.
 * Because update always leaves at least one byte in the chunk state,
 * final's branch for an empty chunk state above a non-empty stack, which
 * only the subtree code reached, is removed. Final writes the 32-byte
 * root digest through the in-place compression (output_root_bytes, seek
 * and extended output removed) and erases the context with
 * erx_explicit_bzero. The keyed and key-derivation modes, reset, the
 * version string and the TBB entry point removed; erXos names for the
 * interface; freestanding C17 (compiler builtins for memcpy and memset,
 * no <assert.h> or <string.h>); the context's size bounded at build time.
 *
 * BLAKE3 1.8.7, https://github.com/BLAKE3-team/BLAKE3, taken under
 * Apache-2.0 WITH LLVM-exception (LICENSE_A2LLVM beside this file);
 * erXos's changes are under the same licence.
 */
#include <stdbool.h>
#include <stdint.h>

#include "erx/explicit_bzero.h"

#include "blake3.h"
#include "blake3_impl.h"

// The context lives in memory its caller provides (a page charged to the
// caller in the kernel), so its size is part of the interface.
_Static_assert(sizeof(erx_blake3_ctx_t) <= 2048,
               "the BLAKE3 context outgrew its stated bound");

INLINE void chunk_state_init(erx_blake3_chunk_t *self, const uint32_t key[8],
                             uint8_t flags) {
  __builtin_memcpy(self->cv, key, BLAKE3_KEY_LEN);
  self->chunk_counter = 0;
  __builtin_memset(self->buf, 0, ERX_BLAKE3_BLOCK_LEN);
  self->buf_len = 0;
  self->blocks_compressed = 0;
  self->flags = flags;
}

INLINE void chunk_state_reset(erx_blake3_chunk_t *self, const uint32_t key[8],
                              uint64_t chunk_counter) {
  __builtin_memcpy(self->cv, key, BLAKE3_KEY_LEN);
  self->chunk_counter = chunk_counter;
  self->blocks_compressed = 0;
  __builtin_memset(self->buf, 0, ERX_BLAKE3_BLOCK_LEN);
  self->buf_len = 0;
}

INLINE size_t chunk_state_len(const erx_blake3_chunk_t *self) {
  return (ERX_BLAKE3_BLOCK_LEN * (size_t)self->blocks_compressed) +
         ((size_t)self->buf_len);
}

INLINE size_t chunk_state_fill_buf(erx_blake3_chunk_t *self,
                                   const uint8_t *input, size_t input_len) {
  size_t take = ERX_BLAKE3_BLOCK_LEN - ((size_t)self->buf_len);
  if (take > input_len) {
    take = input_len;
  }
  uint8_t *dest = self->buf + ((size_t)self->buf_len);
  __builtin_memcpy(dest, input, take);
  self->buf_len += (uint8_t)take;
  return take;
}

INLINE uint8_t chunk_state_maybe_start_flag(const erx_blake3_chunk_t *self) {
  if (self->blocks_compressed == 0) {
    return CHUNK_START;
  } else {
    return 0;
  }
}

typedef struct {
  uint32_t input_cv[8];
  uint64_t counter;
  uint8_t block[ERX_BLAKE3_BLOCK_LEN];
  uint8_t block_len;
  uint8_t flags;
} output_t;

INLINE output_t make_output(const uint32_t input_cv[8],
                            const uint8_t block[ERX_BLAKE3_BLOCK_LEN],
                            uint8_t block_len, uint64_t counter,
                            uint8_t flags) {
  output_t ret;
  __builtin_memcpy(ret.input_cv, input_cv, 32);
  __builtin_memcpy(ret.block, block, ERX_BLAKE3_BLOCK_LEN);
  ret.block_len = block_len;
  ret.counter = counter;
  ret.flags = flags;
  return ret;
}

// Chaining values within a given chunk (specifically the compress_in_place
// interface) are represented as words. This avoids unnecessary bytes<->words
// conversion overhead in the portable implementation. Chaining values in the
// CV stack are represented as bytes, since a parent node's block is the
// concatenation of its children's.
INLINE void output_chaining_value(const output_t *self, uint8_t cv[32]) {
  uint32_t cv_words[8];
  __builtin_memcpy(cv_words, self->input_cv, 32);
  erx_blake3_compress_in_place(cv_words, self->block, self->block_len,
                               self->counter, self->flags);
  store_cv_words(cv, cv_words);
}

// The root node's first 32 output bytes, the digest: the first output block
// (counter 0) under the ROOT flag, whose first eight words are what the
// in-place compression leaves in the chaining value.
INLINE void output_root_hash(const output_t *self,
                             uint8_t out[ERX_BLAKE3_OUT_LEN]) {
  uint32_t cv_words[8];
  __builtin_memcpy(cv_words, self->input_cv, 32);
  erx_blake3_compress_in_place(cv_words, self->block, self->block_len, 0,
                               self->flags | ROOT);
  store_cv_words(out, cv_words);
}

INLINE void chunk_state_update(erx_blake3_chunk_t *self, const uint8_t *input,
                               size_t input_len) {
  if (self->buf_len > 0) {
    size_t take = chunk_state_fill_buf(self, input, input_len);
    input += take;
    input_len -= take;
    if (input_len > 0) {
      erx_blake3_compress_in_place(
          self->cv, self->buf, ERX_BLAKE3_BLOCK_LEN, self->chunk_counter,
          self->flags | chunk_state_maybe_start_flag(self));
      self->blocks_compressed += 1;
      self->buf_len = 0;
      __builtin_memset(self->buf, 0, ERX_BLAKE3_BLOCK_LEN);
    }
  }

  while (input_len > ERX_BLAKE3_BLOCK_LEN) {
    erx_blake3_compress_in_place(self->cv, input, ERX_BLAKE3_BLOCK_LEN,
                                 self->chunk_counter,
                                 self->flags | chunk_state_maybe_start_flag(self));
    self->blocks_compressed += 1;
    input += ERX_BLAKE3_BLOCK_LEN;
    input_len -= ERX_BLAKE3_BLOCK_LEN;
  }

  chunk_state_fill_buf(self, input, input_len);
}

INLINE output_t chunk_state_output(const erx_blake3_chunk_t *self) {
  uint8_t block_flags =
      self->flags | chunk_state_maybe_start_flag(self) | CHUNK_END;
  return make_output(self->cv, self->buf, self->buf_len, self->chunk_counter,
                     block_flags);
}

INLINE output_t parent_output(const uint8_t block[ERX_BLAKE3_BLOCK_LEN],
                              const uint32_t key[8], uint8_t flags) {
  return make_output(key, block, ERX_BLAKE3_BLOCK_LEN, 0, flags | PARENT);
}

INLINE void hasher_init_base(erx_blake3_ctx_t *self, const uint32_t key[8],
                             uint8_t flags) {
  __builtin_memcpy(self->key, key, BLAKE3_KEY_LEN);
  chunk_state_init(&self->chunk, key, flags);
  self->cv_stack_len = 0;
}

void erx_blake3_init(erx_blake3_ctx_t *ctx) { hasher_init_base(ctx, IV, 0); }

// As described in hasher_push_cv() below, we do "lazy merging", delaying
// merges until right before the next CV is about to be added. This is
// different from the reference implementation. Instead of the "count the
// trailing 0-bits" algorithm described in the spec, we use a "count the total
// number of 1-bits" variant that doesn't require us to retain the subtree
// size of the CV on top of the stack. The principle is the same: each CV that
// should remain in the stack is represented by a 1-bit in the total number of
// chunks so far. A total below 2^54 chunks (2^64 bytes) has at most 54 such
// bits, so the stack, with room for one more, never overflows.
INLINE void hasher_merge_cv_stack(erx_blake3_ctx_t *self, uint64_t total_len) {
  size_t post_merge_stack_len = (size_t)popcnt(total_len);
  while (self->cv_stack_len > post_merge_stack_len) {
    uint8_t *parent_node =
        &self->cv_stack[(self->cv_stack_len - 2) * ERX_BLAKE3_OUT_LEN];
    output_t output = parent_output(parent_node, self->key, self->chunk.flags);
    output_chaining_value(&output, parent_node);
    self->cv_stack_len -= 1;
  }
}

// In reference_impl.rs, we merge the new CV with existing CVs from the stack
// before pushing it. We can do that because we know more input is coming, so
// we know none of the merges are root.
//
// Here, when we're about to add a CV to the stack, we don't merge it with
// anything first, as the reference impl does. Instead we do merges using the
// *previous* CV that was added, which is sitting on top of the stack, and we
// put the new CV (unmerged) on top of the stack afterwards. This guarantees
// that we never merge the root node until erx_blake3_final().
INLINE void hasher_push_cv(erx_blake3_ctx_t *self,
                           uint8_t new_cv[ERX_BLAKE3_OUT_LEN],
                           uint64_t chunk_counter) {
  hasher_merge_cv_stack(self, chunk_counter);
  __builtin_memcpy(&self->cv_stack[self->cv_stack_len * ERX_BLAKE3_OUT_LEN],
                   new_cv, ERX_BLAKE3_OUT_LEN);
  self->cv_stack_len += 1;
}

// Finishes the whole chunk in the chunk state, which is not the root because
// more input follows, pushes its chaining value and starts the next chunk.
INLINE void hasher_finish_chunk(erx_blake3_ctx_t *self) {
  output_t output = chunk_state_output(&self->chunk);
  uint8_t chunk_cv[32];
  output_chaining_value(&output, chunk_cv);
  hasher_push_cv(self, chunk_cv, self->chunk.chunk_counter);
  chunk_state_reset(&self->chunk, self->key, self->chunk.chunk_counter + 1);
}

void erx_blake3_update(erx_blake3_ctx_t *ctx, const void *input,
                       size_t length) {
  // Explicitly checking for zero avoids causing UB by passing a null pointer
  // to memcpy.
  if (length == 0) {
    return;
  }

  const uint8_t *input_bytes = (const uint8_t *)input;
  size_t input_len = length;

  // If we have some partial chunk bytes in the internal chunk_state, we need
  // to finish that chunk first.
  if (chunk_state_len(&ctx->chunk) > 0) {
    size_t take = BLAKE3_CHUNK_LEN - chunk_state_len(&ctx->chunk);
    if (take > input_len) {
      take = input_len;
    }
    chunk_state_update(&ctx->chunk, input_bytes, take);
    input_bytes += take;
    input_len -= take;
    // If we've filled the current chunk and there's more coming, finalize this
    // chunk and proceed. In this case we know it's not the root.
    if (input_len > 0) {
      hasher_finish_chunk(ctx);
    } else {
      return;
    }
  }

  // Now the chunk_state is clear, and we have more input. Each whole chunk
  // with more input after it is definitely not the root: hash it and push its
  // chaining value. The last 1 to BLAKE3_CHUNK_LEN bytes stay in the chunk
  // state, since they may be the root chunk, so the chunk state is never empty
  // when this returns.
  while (input_len > BLAKE3_CHUNK_LEN) {
    chunk_state_update(&ctx->chunk, input_bytes, BLAKE3_CHUNK_LEN);
    hasher_finish_chunk(ctx);
    input_bytes += BLAKE3_CHUNK_LEN;
    input_len -= BLAKE3_CHUNK_LEN;
  }

  // Add the remaining input to the chunk state, and do a final merge loop to
  // make sure the subtree stack doesn't contain any unmerged pairs. The
  // remaining input means we know these merges are non-root. This simplifies
  // erx_blake3_final below.
  chunk_state_update(&ctx->chunk, input_bytes, input_len);
  hasher_merge_cv_stack(ctx, ctx->chunk.chunk_counter);
}

void erx_blake3_final(erx_blake3_ctx_t *ctx,
                      uint8_t digest[ERX_BLAKE3_OUT_LEN]) {
  output_t output = chunk_state_output(&ctx->chunk);
  // If the subtree stack is empty, then the current chunk is the root.
  // Otherwise the chunk state holds at least one byte (erx_blake3_update
  // never leaves it empty above a chaining value), so finalize that chunk
  // and do a roll-up merge between that chunk hash and every subtree in the
  // stack. The extra merge loop at the end of erx_blake3_update guarantees
  // that none of the subtrees in the stack need to be merged with each other
  // first.
  // Each parent's block is its left child, the stack entry, followed by its
  // right child, the chaining value of the output built so far.
  size_t cvs_remaining = ctx->cv_stack_len;
  while (cvs_remaining > 0) {
    cvs_remaining -= 1;
    uint8_t parent_block[ERX_BLAKE3_BLOCK_LEN];
    __builtin_memcpy(parent_block,
                     &ctx->cv_stack[cvs_remaining * ERX_BLAKE3_OUT_LEN],
                     ERX_BLAKE3_OUT_LEN);
    output_chaining_value(&output, &parent_block[ERX_BLAKE3_OUT_LEN]);
    output = parent_output(parent_block, ctx->key, ctx->chunk.flags);
  }
  output_root_hash(&output, digest);
  erx_explicit_bzero(ctx, sizeof(*ctx));
}
