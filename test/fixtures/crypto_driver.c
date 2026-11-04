/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs SHA-256, ChaCha20 and the entropy generator over the requests in a
 * text file, one per line, and prints one answer line per request, so the
 * host tests can judge them against their references. Byte strings are
 * hexadecimal, "-" for none; numbers are decimal. Every buffer is
 * allocated at its exact size, so a sanitizer sees any access past it.
 *
 *   sha256 HEX CHUNKS        CHUNKS: comma-separated update sizes, or "-"
 *     -> sha256 DIGEST CONTEXT   (CONTEXT: the context's bytes after final)
 *   sha256-repeat BYTE COUNT CHUNK
 *     -> sha256 DIGEST CONTEXT   (COUNT copies of BYTE, CHUNK at a time)
 *   chacha20 KEY COUNTER NONCE HEX MODE      MODE: "copy" or "inplace"
 *     -> chacha20 ok OUT | chacha20 refused UNTOUCHED
 *   chacha20-bound COUNTER LENGTH   (no buffers: LENGTH must be refused)
 *     -> chacha20 refused | chacha20 ok
 *   rng OP...   OP: "r:N" read N bytes, "m:HEX" mix the bytes' digest,
 *               "i:HEX" init with the bytes' digest, "d:HEX" the bytes'
 *               digest alone, "c" clear; the
 *               generator starts all zeroes, never initialized
 *     -> rng, then per OP " r:ok:OUT:STATE", " r:refused:STATE",
 *        " m:ok:STATE", " m:refused:STATE", " i:STATE", " d:ok:DIGEST:STATE",
 *        " d:refused:STATE" or " c:STATE", where STATE is KEY:READY, READY 1
 *        or 0. A spent or refused digest that is not all zeroes, or that
 *        still counts as hashed, stops the driver; "m" and "i" pass a refused
 *        digest on.
 *   rng-residue KIND HEX HEX   KIND "hash", of two messages of one length,
 *               or "read" or "mix", under two 32-byte keys
 *     -> rng-residue DIFFERING TOUCHED
 *        Makes the call with each secret from one frame over one painted
 *        stretch of the stack below it, and counts the bytes of that
 *        stretch that the call changed (TOUCHED) and the bytes that end
 *        up different between the two secrets (DIFFERING). Only the
 *        secrets differ, so a differing byte is one that depends on them:
 *        a secret the generator left on the stack. Not under a sanitizer,
 *        whose frames are not the ones the burn is sized for.
 */

#define _DEFAULT_SOURCE

#include <sys/types.h>

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/rng.h"

#include "chacha20/chacha.h"
#include "sha2/sha256.h"

/* How much of the stack rng-residue paints: past every hash and burn. */
#define DRIVER_RESIDUE_BYTES	8192
#define DRIVER_PAINT		0xa5

typedef struct driver_bytes driver_bytes_t;

typedef enum driver_residue {
	DRIVER_RESIDUE_HASH,
	DRIVER_RESIDUE_READ,
	DRIVER_RESIDUE_MIX
} driver_residue_t;

struct driver_bytes {
	uint8_t	*bytes;
	size_t	 length;
};

static void driver_answer_chacha20(char *);
static void driver_answer_chacha20_bound(char *);
static void driver_answer_rng(char *);
static void driver_answer_rng_residue(char *);
static void driver_answer_sha256(char *);
static void driver_answer_sha256_repeat(char *);
static void driver_residue_run(driver_residue_t, erx_rng_t *,
    const driver_bytes_t *, uint8_t *);
static bool driver_rng_digest(erx_rng_digest_t *, const char *);
static void driver_rng_spent(const erx_rng_digest_t *);
static uintptr_t driver_stack_edge(void);
static driver_bytes_t driver_hex(const char *);
static void driver_print_hex(const uint8_t *, size_t);
static void driver_print_sha256(erx_sha256_ctx_t *);
static uint64_t driver_number(const char *);
static char *driver_token(char **);
static _Noreturn void driver_usage(const char *);

static _Noreturn void
driver_usage(const char *why)
{
	fprintf(stderr, "crypto_driver: %s\n", why);
	exit(2);
}

static char *
driver_token(char **cursor)
{
	char *token;

	token = strsep(cursor, " ");
	if (token == NULL || *token == '\0')
		driver_usage("missing field");
	return (token);
}

static uint64_t
driver_number(const char *text)
{
	char *end;
	unsigned long long value;

	value = strtoull(text, &end, 10);
	if (*text == '\0' || *end != '\0')
		driver_usage("bad number");
	return ((uint64_t)value);
}

/* An exact-size copy of the bytes; "-" is no bytes and a NULL pointer. */
static driver_bytes_t
driver_hex(const char *text)
{
	driver_bytes_t result = { NULL, 0 };
	size_t digits;

	if (strcmp(text, "-") == 0)
		return (result);
	digits = strlen(text);
	if (digits % 2 != 0)
		driver_usage("odd hex length");
	result.length = digits / 2;
	if ((result.bytes = malloc(result.length)) == NULL)
		driver_usage("out of memory");
	for (size_t index = 0; index < result.length; index++) {
		unsigned int byte;

		if (sscanf(text + 2 * index, "%2x", &byte) != 1)
			driver_usage("bad hex");
		result.bytes[index] = (uint8_t)byte;
	}
	return (result);
}

static void
driver_print_hex(const uint8_t *bytes, size_t length)
{
	if (length == 0)
		fputs("-", stdout);
	for (size_t index = 0; index < length; index++)
		printf("%02x", bytes[index]);
}

static void
driver_print_sha256(erx_sha256_ctx_t *ctx)
{
	uint8_t *digest;

	if ((digest = malloc(ERX_SHA256_DIGEST_LENGTH)) == NULL)
		driver_usage("out of memory");
	erx_sha256_final(digest, ctx);
	fputs("sha256 ", stdout);
	driver_print_hex(digest, ERX_SHA256_DIGEST_LENGTH);
	fputs(" ", stdout);
	driver_print_hex((const uint8_t *)ctx, sizeof(*ctx));
	fputs("\n", stdout);
	free(digest);
}

static void
driver_answer_sha256(char *cursor)
{
	erx_sha256_ctx_t ctx;
	driver_bytes_t message;
	char *chunks, *size;
	size_t offset;

	message = driver_hex(driver_token(&cursor));
	chunks = driver_token(&cursor);
	erx_sha256_init(&ctx);
	offset = 0;
	if (strcmp(chunks, "-") == 0) {
		erx_sha256_update(&ctx, message.bytes, message.length);
		offset = message.length;
	} else {
		while ((size = strsep(&chunks, ",")) != NULL) {
			uint64_t length = driver_number(size);

			if (length > message.length - offset)
				driver_usage("chunks past the message");
			erx_sha256_update(&ctx, length == 0 ? NULL :
			    message.bytes + offset, (size_t)length);
			offset += (size_t)length;
		}
	}
	if (offset != message.length)
		driver_usage("chunks do not cover the message");
	driver_print_sha256(&ctx);
	free(message.bytes);
}

static void
driver_answer_sha256_repeat(char *cursor)
{
	erx_sha256_ctx_t ctx;
	driver_bytes_t byte;
	uint8_t *chunk;
	uint64_t count, size;

	byte = driver_hex(driver_token(&cursor));
	count = driver_number(driver_token(&cursor));
	size = driver_number(driver_token(&cursor));
	if (byte.length != 1 || size == 0 || (chunk = malloc(size)) == NULL)
		driver_usage("bad repeat");
	memset(chunk, byte.bytes[0], size);
	erx_sha256_init(&ctx);
	for (uint64_t done = 0; done < count; done += size)
		erx_sha256_update(&ctx, chunk, (size_t)(count - done < size ?
		    count - done : size));
	driver_print_sha256(&ctx);
	free(chunk);
	free(byte.bytes);
}

static void
driver_answer_chacha20(char *cursor)
{
	driver_bytes_t key, nonce, data;
	uint8_t *out;
	uint64_t counter;
	const char *mode;
	bool accepted;

	key = driver_hex(driver_token(&cursor));
	counter = driver_number(driver_token(&cursor));
	nonce = driver_hex(driver_token(&cursor));
	data = driver_hex(driver_token(&cursor));
	mode = driver_token(&cursor);
	if (key.length != ERX_CHACHA20_KEY_LENGTH ||
	    nonce.length != ERX_CHACHA20_NONCE_LENGTH || counter > UINT32_MAX)
		driver_usage("bad key, nonce or counter");
	if (strcmp(mode, "inplace") == 0) {
		out = data.bytes;
	} else if (strcmp(mode, "copy") == 0) {
		out = data.length == 0 ? NULL : malloc(data.length);
		if (data.length != 0 && out == NULL)
			driver_usage("out of memory");
		if (out != NULL)
			memset(out, 0xa5, data.length);
	} else {
		driver_usage("bad mode");
	}
	accepted = erx_chacha20_xor(key.bytes, (uint32_t)counter, nonce.bytes,
	    data.bytes, out, data.length);
	printf("chacha20 %s ", accepted ? "ok" : "refused");
	driver_print_hex(out, data.length);
	fputs("\n", stdout);
	if (out != data.bytes)
		free(out);
	free(data.bytes);
	free(nonce.bytes);
	free(key.bytes);
}

static void
driver_answer_chacha20_bound(char *cursor)
{
	static const uint8_t key[ERX_CHACHA20_KEY_LENGTH];
	static const uint8_t nonce[ERX_CHACHA20_NONCE_LENGTH];
	uint64_t counter, length;
	bool accepted;

	counter = driver_number(driver_token(&cursor));
	length = driver_number(driver_token(&cursor));
	if (counter > UINT32_MAX || length > SIZE_MAX)
		driver_usage("bad counter or length");
	/* No buffers: an accepted stream faults on its first byte. */
	accepted = erx_chacha20_xor(key, (uint32_t)counter, nonce, NULL, NULL,
	    (size_t)length);
	printf("chacha20 %s\n", accepted ? "ok" : "refused");
}

/* Hashes the op's bytes, "-" or nothing for none. */
static bool
driver_rng_digest(erx_rng_digest_t *digest, const char *text)
{
	driver_bytes_t bytes = driver_hex(*text == '\0' ? "-" : text);
	bool hashed = erx_rng_digest(digest, bytes.bytes, bytes.length);

	free(bytes.bytes);
	return (hashed);
}

static void
driver_rng_spent(const erx_rng_digest_t *digest)
{
	if (digest->hashed)
		driver_usage("a spent digest still counts as hashed");
	for (size_t index = 0; index < sizeof(digest->bytes); index++)
		if (digest->bytes[index] != 0)
			driver_usage("a spent digest was not erased");
}

static void
driver_answer_rng(char *cursor)
{
	erx_rng_digest_t digest;
	erx_rng_t rng;
	char *op;

	memset(&rng, 0, sizeof(rng));
	fputs("rng", stdout);
	while ((op = strsep(&cursor, " ")) != NULL) {
		if (*op == '\0')
			continue;
		if (strncmp(op, "r:", 2) == 0) {
			uint64_t length = driver_number(op + 2);
			uint8_t *out = length == 0 ? NULL : malloc(length);

			if (length != 0 && out == NULL)
				driver_usage("out of memory");
			if (out != NULL)
				memset(out, 0xa5, length);
			if (erx_rng_read(&rng, out, (size_t)length)) {
				fputs(" r:ok:", stdout);
				driver_print_hex(out, (size_t)length);
			} else {
				fputs(" r:refused", stdout);
				for (uint64_t index = 0; index < length; index++)
					if (out[index] != 0xa5)
						driver_usage("refused read wrote");
			}
			free(out);
		} else if (strncmp(op, "m:", 2) == 0) {
			driver_rng_digest(&digest, op + 2);
			fputs(erx_rng_mix(&rng, &digest) ? " m:ok" : " m:refused",
			    stdout);
			driver_rng_spent(&digest);
		} else if (strncmp(op, "i:", 2) == 0) {
			driver_rng_digest(&digest, op + 2);
			erx_rng_init(&rng, &digest);
			fputs(" i", stdout);
			driver_rng_spent(&digest);
		} else if (strncmp(op, "d:", 2) == 0) {
			memset(&digest, DRIVER_PAINT, sizeof(digest));
			if (driver_rng_digest(&digest, op + 2)) {
				fputs(" d:ok:", stdout);
				driver_print_hex(digest.bytes, sizeof(digest.bytes));
			} else {
				fputs(" d:refused", stdout);
				driver_rng_spent(&digest);
			}
		} else if (strcmp(op, "c") == 0) {
			erx_rng_clear(&rng);
			fputs(" c", stdout);
		} else {
			driver_usage("bad rng op");
		}
		fputs(":", stdout);
		driver_print_hex(rng.key, sizeof(rng.key));
		printf(":%d", rng.ready ? 1 : 0);
	}
	fputs("\n", stdout);
}

/*
 * This function's saved frame record, which lies just below its caller's
 * frame, where the frame of the caller's next callee starts too. Only that
 * callee's saved registers lie between here and the caller's frame.
 */
static __attribute__((__noinline__)) uintptr_t
driver_stack_edge(void)
{
	return ((uintptr_t)__builtin_frame_address(0));
}

/*
 * Paints the stretch below this frame, makes the call, and copies out what
 * is left there. Reading the stack below the frame is what the check is;
 * nothing but the loops and the call runs between the painting and the
 * copying, so every change is the call's.
 */
static __attribute__((__noinline__)) void
driver_residue_run(driver_residue_t kind, erx_rng_t *rng,
    const driver_bytes_t *secret, uint8_t *left)
{
	uint8_t out[ERX_RNG_READ_MAX];
	erx_rng_digest_t digest;
	volatile uint8_t *stretch;
	bool served = true;

	memset(&digest, 0, sizeof(digest));
	if (kind != DRIVER_RESIDUE_HASH) {
		memcpy(rng->key, secret->bytes, sizeof(rng->key));
		rng->ready = true;
		digest.hashed = true;
	}
	stretch = (volatile uint8_t *)(driver_stack_edge() - DRIVER_RESIDUE_BYTES);
	for (size_t index = 0; index < DRIVER_RESIDUE_BYTES; index++)
		stretch[index] = DRIVER_PAINT;
	switch (kind) {
	case DRIVER_RESIDUE_HASH:
		served = erx_rng_digest(&digest, secret->bytes, secret->length);
		break;
	case DRIVER_RESIDUE_READ:
		served = erx_rng_read(rng, out, sizeof(out));
		break;
	case DRIVER_RESIDUE_MIX:
		served = erx_rng_mix(rng, &digest);
		break;
	}
	for (size_t index = 0; index < DRIVER_RESIDUE_BYTES; index++)
		left[index] = stretch[index];
	if (!served)
		driver_usage("a residue call was refused");
}

static void
driver_answer_rng_residue(char *cursor)
{
	const char *name = driver_token(&cursor);
	driver_residue_t kind = strcmp(name, "hash") == 0 ? DRIVER_RESIDUE_HASH :
	    strcmp(name, "read") == 0 ? DRIVER_RESIDUE_READ : DRIVER_RESIDUE_MIX;
	driver_bytes_t first = driver_hex(driver_token(&cursor));
	driver_bytes_t second = driver_hex(driver_token(&cursor));
	driver_bytes_t secret;
	erx_rng_t *rng = malloc(sizeof(*rng));
	uint8_t *first_left, *left;
	size_t differing = 0, touched = 0;

	first_left = malloc(DRIVER_RESIDUE_BYTES);
	left = malloc(DRIVER_RESIDUE_BYTES);
	secret.length = first.length;
	secret.bytes = malloc(first.length == 0 ? 1 : first.length);
	if (rng == NULL || first_left == NULL || left == NULL ||
	    secret.bytes == NULL)
		driver_usage("out of memory");
	if (first.length != second.length ||
	    (kind != DRIVER_RESIDUE_HASH && first.length != ERX_RNG_KEY_LENGTH))
		driver_usage("rng-residue compares secrets of one length");

	/*
	 * The same buffers and generator every time: the saved registers in the
	 * call's frames hold their addresses, which must differ in nothing. The
	 * first run is discarded: it may bind the C library's functions, which
	 * runs the dynamic linker on the painted stack.
	 */
	memcpy(secret.bytes, first.bytes, first.length);
	driver_residue_run(kind, rng, &secret, left);
	driver_residue_run(kind, rng, &secret, left);
	memcpy(first_left, left, DRIVER_RESIDUE_BYTES);
	memcpy(secret.bytes, second.bytes, second.length);
	driver_residue_run(kind, rng, &secret, left);
	for (size_t index = 0; index < DRIVER_RESIDUE_BYTES; index++) {
		differing += first_left[index] != left[index];
		touched += first_left[index] != DRIVER_PAINT;
	}
	printf("rng-residue %zu %zu\n", differing, touched);
	free(secret.bytes);
	free(left);
	free(first_left);
	free(rng);
	free(second.bytes);
	free(first.bytes);
}

int
main(int argc, char **argv)
{
	FILE *input;
	char *line = NULL;
	size_t capacity = 0;
	ssize_t length;

	if (argc != 2 || (input = fopen(argv[1], "r")) == NULL)
		driver_usage("usage: crypto_driver REQUESTS");
	while ((length = getline(&line, &capacity, input)) > 0) {
		char *cursor = line;
		char *command;

		if (line[length - 1] == '\n')
			line[length - 1] = '\0';
		command = driver_token(&cursor);
		if (strcmp(command, "sha256") == 0)
			driver_answer_sha256(cursor);
		else if (strcmp(command, "sha256-repeat") == 0)
			driver_answer_sha256_repeat(cursor);
		else if (strcmp(command, "chacha20") == 0)
			driver_answer_chacha20(cursor);
		else if (strcmp(command, "chacha20-bound") == 0)
			driver_answer_chacha20_bound(cursor);
		else if (strcmp(command, "rng") == 0)
			driver_answer_rng(cursor);
		else if (strcmp(command, "rng-residue") == 0)
			driver_answer_rng_residue(cursor);
		else
			driver_usage("unknown request");
	}
	free(line);
	fclose(input);
	return (0);
}
