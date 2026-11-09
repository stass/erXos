/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Drives otp/erts/emulator/sys/erxos/erx_ref.c for test/host/erx_ref_test.rb. Each line of
 * standard input is one request, and each request prints its answer lines:
 *
 *   permute KEY IN                 -> "permute OUT", OUT = AES-128(KEY, IN)
 *   make KEY ORDINAL HIGH LOW N    -> N lines "ref W0 W1 W2 W3" or "ref limit", made from a
 *                                     source at that ordinal whose next counter value is
 *                                     HIGH:LOW, then "state HIGH LOW", its next value left;
 *                                     the counter's last value is a spent source
 *   fresh KEY                      -> "ref limit" if a zero-initialised source makes nothing
 *   sources TAKEN N                -> N lines "source ORDINAL" or "source limit", opened from
 *                                     a runtime that has handed out TAKEN ordinals
 *   threads KEY N                  -> N threads each open a source and make references until
 *                                     refused; "threads OPENED REFUSED", then every identity
 *                                     made as "id ORDINAL W0 W1 W2 W3"
 *
 * KEY, IN and OUT are 32 hex digits, the words 8 hex digits, the numbers decimal. A malformed
 * request, or a result the core must never give, ends the driver with status 2.
 */

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_ref.h"

#define LINE_MAX_BYTES	256
#define THREADS_MAX	64
/* The most references one thread of a narrowed build makes; a wider counter is refused. */
#define THREAD_REFS_MAX	4096
/* What a refused call must leave in its result. */
#define UNTOUCHED	UINT32_C(0xdeadbeef)

/* The ABI's little-endian u32 fields. */
static void
store32(uint8_t *bytes, uint32_t value)
{

	for (int i = 0; i < 4; i++)
		bytes[i] = (uint8_t)(value >> (8 * i));
}

static uint32_t
load32(const uint8_t *bytes)
{

	return ((uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 |
	    (uint32_t)bytes[3] << 24);
}

static void
fail(const char *what)
{

	fprintf(stderr, "erx_ref_driver: %s\n", what);
	exit(2);
}

static void
parse_hex16(const char *text, uint8_t out[16])
{

	if (text == NULL || strlen(text) != 32)
		fail("a block is 32 hex digits");
	for (int i = 0; i < 32; i++)
		if (!isxdigit((unsigned char)text[i]))
			fail("bad hex");
	for (int i = 0; i < 16; i++) {
		const char pair[3] = { text[2 * i], text[2 * i + 1], '\0' };

		out[i] = (uint8_t)strtoul(pair, NULL, 16);
	}
}

static uint64_t
parse_number(const char *text, uint64_t max)
{
	char *end;
	unsigned long long value;

	if (text == NULL || *text < '0' || *text > '9')
		fail("bad number");
	errno = 0;
	value = strtoull(text, &end, 10);
	if (errno != 0 || *end != '\0' || value > max)
		fail("bad number");
	return ((uint64_t)value);
}

/* A runtime under the key the next field of the request names. */
static void
runtime_from_request(erx_ref_runtime_t *runtime, char **save)
{
	uint8_t key[ERX_REF_KEY_BYTES];

	parse_hex16(strtok_r(NULL, " ", save), key);
	erx_ref_runtime_init(runtime, key);
	for (size_t i = 0; i < sizeof(key); i++)
		if (key[i] != 0)
			fail("erx_ref_runtime_init left key bytes behind");
}

static void
print_words(const char *tag, const uint32_t words[ERX_REF_WORDS])
{

	printf("%s %08" PRIx32 " %08" PRIx32 " %08" PRIx32 " %08" PRIx32 "\n", tag, words[0], words[1],
	    words[2], words[3]);
}

/* Makes count references from source, printing each, or "ref limit" for each refusal. */
static void
make_and_print(const erx_ref_runtime_t *runtime, erx_ref_source_t *source, uint64_t count)
{

	for (uint64_t i = 0; i < count; i++) {
		uint32_t words[ERX_REF_WORDS] = { UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED };
		const erx_ref_source_t before = *source;
		const int status = erx_ref_make(runtime, source, words);

		if (status == ERX_OK)
			print_words("ref", words);
		else if (status == ERX_ELIMIT && words[0] == UNTOUCHED && words[3] == UNTOUCHED &&
		    memcmp(&before, source, sizeof(before)) == 0)
			printf("ref limit\n");
		else
			fail("erx_ref_make: an unexpected status or a write on refusal");
	}
}

static void
do_permute(char **save)
{
	erx_ref_runtime_t runtime;
	uint8_t in[16], out[16];

	runtime_from_request(&runtime, save);
	parse_hex16(strtok_r(NULL, " ", save), in);
	erx_ref_permute(&runtime, in, out);
	printf("permute ");
	for (int i = 0; i < 16; i++)
		printf("%02x", out[i]);
	printf("\n");
}

/* The source's next counter value is the last value less what remains, as the core counts. */
static void
do_make(char **save)
{
	erx_ref_runtime_t runtime;
	erx_ref_source_t source = { 0 };
	uint64_t high, low;

	runtime_from_request(&runtime, save);
	source.ordinal = (uint32_t)parse_number(strtok_r(NULL, " ", save), UINT32_MAX);
	high = parse_number(strtok_r(NULL, " ", save), ERX_REF_COUNTER_LAST_HIGH);
	low = parse_number(strtok_r(NULL, " ", save), high == ERX_REF_COUNTER_LAST_HIGH ?
	    ERX_REF_COUNTER_LAST_LOW : UINT64_MAX);
	source.remaining_high = ERX_REF_COUNTER_LAST_HIGH - (uint32_t)high;
	source.remaining_low = ERX_REF_COUNTER_LAST_LOW - low;
	make_and_print(&runtime, &source, parse_number(strtok_r(NULL, " ", save), 1u << 20));
	printf("state %" PRIu32 " %" PRIu64 "\n", ERX_REF_COUNTER_LAST_HIGH - source.remaining_high,
	    ERX_REF_COUNTER_LAST_LOW - source.remaining_low);
}

static void
do_fresh(char **save)
{
	erx_ref_runtime_t runtime;
	erx_ref_source_t source = { 0 };

	runtime_from_request(&runtime, save);
	make_and_print(&runtime, &source, 1);
}

/*
 * "source_of KEY TAKEN ORDINAL HIGH LOW": with TAKEN ordinals handed out, the source that
 * erx_ref_source_of names for the identity of the block ORDINAL, HIGH:LOW, enciphered.
 */
static void
do_source_of(char **save)
{
	erx_ref_runtime_t runtime;
	uint8_t block[ERX_REF_BLOCK_SIZE], identity[ERX_REF_IDENTITY_SIZE];
	uint32_t words[ERX_REF_WORDS], ordinal = UNTOUCHED;
	uint64_t low;
	uint32_t high;

	runtime_from_request(&runtime, save);
	atomic_store(&runtime.taken, parse_number(strtok_r(NULL, " ", save), UINT64_C(1) << 32));
	store32(block + ERX_REF_BLOCK_OFF_SOURCE,
	    (uint32_t)parse_number(strtok_r(NULL, " ", save), UINT32_MAX));
	high = (uint32_t)parse_number(strtok_r(NULL, " ", save), UINT32_MAX);
	low = parse_number(strtok_r(NULL, " ", save), UINT64_MAX);
	store32(block + ERX_REF_BLOCK_OFF_COUNTER, (uint32_t)low);
	store32(block + ERX_REF_BLOCK_OFF_COUNTER + 4, (uint32_t)(low >> 32));
	store32(block + ERX_REF_BLOCK_OFF_COUNTER + 8, high);
	erx_ref_permute(&runtime, block, identity);
	for (uint32_t i = 0; i < ERX_REF_WORDS; i++)
		words[i] = load32(identity + ERX_REF_IDENTITY_OFF_ID + 4 * i);
	if (erx_ref_source_of(&runtime, words, &ordinal) == ERX_OK)
		printf("source_of %" PRIu32 "\n", ordinal);
	else if (ordinal == UNTOUCHED)
		printf("source_of refused\n");
	else
		printf("source_of refused but wrote\n");
}

static void
do_sources(char **save)
{
	uint8_t key[ERX_REF_KEY_BYTES] = { 0 };
	erx_ref_runtime_t runtime;
	uint64_t count;

	erx_ref_runtime_init(&runtime, key);
	atomic_store(&runtime.taken, parse_number(strtok_r(NULL, " ", save), UINT64_C(1) << 32));
	count = parse_number(strtok_r(NULL, " ", save), 1024);
	for (uint64_t i = 0; i < count; i++) {
		erx_ref_source_t source = { .ordinal = UNTOUCHED };

		if (erx_ref_source_open(&runtime, &source) == ERX_OK)
			printf("source %" PRIu32 "\n", source.ordinal);
		else if (source.ordinal == UNTOUCHED)
			printf("source limit\n");
		else
			fail("erx_ref_source_open wrote its source on refusal");
	}
}

/* One thread of a threads request: its source and the identities it made. */
typedef struct worker {
	erx_ref_runtime_t	*runtime;
	atomic_int		*start;
	int			 opened;
	erx_ref_source_t	 source;
	size_t			 made;
	uint32_t		 words[THREAD_REFS_MAX][ERX_REF_WORDS];
} worker_t;

static void *
work(void *argument)
{
	worker_t *worker = argument;

	while (atomic_load(worker->start) == 0)
		;
	worker->opened = erx_ref_source_open(worker->runtime, &worker->source) == ERX_OK;
	if (!worker->opened)
		return (NULL);
	while (worker->made < THREAD_REFS_MAX &&
	    erx_ref_make(worker->runtime, &worker->source, worker->words[worker->made]) == ERX_OK)
		worker->made++;
	if (worker->made == THREAD_REFS_MAX)
		fail("a counter outlasted THREAD_REFS_MAX references; narrow ERX_REF_COUNTER_BITS");
	return (NULL);
}

/*
 * The threads start together on an atomic flag (macOS has no pthread barriers) so their
 * source opens race. The workers' results, about 4 MiB, are static rather than on a stack.
 */
static void
do_threads(char **save)
{
	static worker_t workers[THREADS_MAX];
	pthread_t threads[THREADS_MAX];
	erx_ref_runtime_t runtime;
	atomic_int start;
	uint64_t count;
	int opened = 0;

	runtime_from_request(&runtime, save);
	count = parse_number(strtok_r(NULL, " ", save), THREADS_MAX);
	atomic_init(&start, 0);
	for (uint64_t i = 0; i < count; i++) {
		workers[i] = (worker_t){ .runtime = &runtime, .start = &start };
		if (pthread_create(&threads[i], NULL, work, &workers[i]) != 0)
			fail("pthread_create");
	}
	atomic_store(&start, 1);
	for (uint64_t i = 0; i < count; i++) {
		if (pthread_join(threads[i], NULL) != 0)
			fail("pthread_join");
		opened += workers[i].opened;
	}
	printf("threads %d %d\n", opened, (int)count - opened);
	for (uint64_t i = 0; i < count; i++) {
		char tag[32];

		snprintf(tag, sizeof(tag), "id %" PRIu32, workers[i].source.ordinal);
		for (size_t j = 0; j < workers[i].made; j++)
			print_words(tag, workers[i].words[j]);
	}
}

int
main(void)
{
	char line[LINE_MAX_BYTES];

	while (fgets(line, sizeof(line), stdin) != NULL) {
		char *save, *verb;

		line[strcspn(line, "\n")] = '\0';
		verb = strtok_r(line, " ", &save);
		if (verb == NULL)
			fail("an empty request");
		if (strcmp(verb, "permute") == 0)
			do_permute(&save);
		else if (strcmp(verb, "make") == 0)
			do_make(&save);
		else if (strcmp(verb, "fresh") == 0)
			do_fresh(&save);
		else if (strcmp(verb, "source_of") == 0)
			do_source_of(&save);
		else if (strcmp(verb, "sources") == 0)
			do_sources(&save);
		else if (strcmp(verb, "threads") == 0)
			do_threads(&save);
		else
			fail("an unknown request");
	}
	return (0);
}
