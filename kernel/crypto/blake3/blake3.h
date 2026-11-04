/*
 * SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
 * Modified by erXos: erXos names for the interface (erx_blake3_ctx_t,
 * erx_blake3_init, erx_blake3_update, erx_blake3_final) and its
 * constants; only the plain hash with its 32-byte digest is offered (the
 * keyed and key-derivation modes, extended output, seek, reset, the
 * version string and the TBB entry point removed); final takes the
 * context mutably, since it erases it, and the digest as a plain array
 * parameter, so the header compiles as C++ as well (bootstrap and the
 * stopgap kernel's glue are C++); the visibility macros removed; the
 * context's size stated; ERX_BLAKE3_CHUNK_LEN and erx_blake3_hash_chunk
 * added.
 *
 * BLAKE3 1.8.7, https://github.com/BLAKE3-team/BLAKE3, is offered by its
 * authors under CC0-1.0, Apache-2.0 or Apache-2.0 WITH LLVM-exception.
 * erXos takes it under Apache-2.0 WITH LLVM-exception (LICENSE_A2LLVM
 * beside this file), and erXos's changes are under the same licence.
 * ORIGIN.md records what was imported.
 */
#ifndef ERX_CRYPTO_BLAKE3_H
#define ERX_CRYPTO_BLAKE3_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ERX_BLAKE3_OUT_LEN 32
#define ERX_BLAKE3_BLOCK_LEN 64
#define ERX_BLAKE3_CHUNK_LEN 1024
#define ERX_BLAKE3_MAX_DEPTH 54

// This struct is a private implementation detail. It has to be here because
// it's part of the erx_blake3_ctx_t structure defined below.
typedef struct erx_blake3_chunk {
  uint32_t cv[8];
  uint64_t chunk_counter;
  uint8_t buf[ERX_BLAKE3_BLOCK_LEN];
  uint8_t buf_len;
  uint8_t blocks_compressed;
  uint8_t flags;
} erx_blake3_chunk_t;

/*
 * One hash in progress. The caller owns it and keeps it wherever its
 * size suits: 1912 bytes on the 64-bit targets and hosts erXos builds
 * for (blake3.c holds it to at most 2048), most of it the stack of
 * chaining values below. Kernel code keeps it in memory charged to its
 * caller, never on the kernel stack, and never in memory that user mode
 * can write: the code trusts every field (buf_len and cv_stack_len index
 * the buffers), so only the kernel may hold it. Its fields are private.
 */
typedef struct erx_blake3_ctx {
  uint32_t key[8];
  erx_blake3_chunk_t chunk;
  uint8_t cv_stack_len;
  // The stack size is MAX_DEPTH + 1 because we do lazy merging. For example,
  // with 7 chunks, we have 3 entries in the stack. Adding an 8th chunk
  // requires a 4th entry, rather than merging everything down to 1, because we
  // don't know whether more input is coming. This is different from how the
  // reference implementation does things.
  uint8_t cv_stack[(ERX_BLAKE3_MAX_DEPTH + 1) * ERX_BLAKE3_OUT_LEN];
} erx_blake3_ctx_t;

/*
 * The plain BLAKE3 hash: init starts a hash, update adds length bytes at
 * input (none when length is 0, when input may be null), and final
 * writes the 32-byte digest and erases the context, which init must
 * start again before any further use; digest must not lie inside the
 * context, which final erases after writing it, and a context abandoned
 * without final is not erased. A message of any length and any
 * split into updates gives the same digest. The functions keep no state
 * of their own and allocate nothing; they erase only the context, so a
 * caller hashing a secret erases its own stack below it afterwards.
 */
void erx_blake3_init(erx_blake3_ctx_t *ctx);
void erx_blake3_update(erx_blake3_ctx_t *ctx, const void *input,
                       size_t length);
void erx_blake3_final(erx_blake3_ctx_t *ctx,
                      uint8_t digest[ERX_BLAKE3_OUT_LEN]);

/*
 * The same hash of at most ERX_BLAKE3_CHUNK_LEN bytes, none when length is
 * 0, when input may be null. One chunk has no chaining values to keep, so
 * its state fits on this call's stack, and the call erases it. A longer
 * input is refused: it returns false with digest untouched. As with final,
 * a caller hashing a secret erases its own stack below it afterwards.
 */
bool erx_blake3_hash_chunk(const void *input, size_t length,
                           uint8_t digest[ERX_BLAKE3_OUT_LEN]);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CRYPTO_BLAKE3_H */
