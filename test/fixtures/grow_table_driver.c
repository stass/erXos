/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host checks of the growable table's core, liberx/backend/core/grow_table.c,
 * against a page source that counts what it hands out and can be told to run dry
 * after a given number of pages:
 *
 *   grow     A table of each record size grows a page at a time to its limit; every
 *            record it adds reads zero, keeps its address and its contents as the
 *            table grows, and no record past the capacity exists.
 *   refusal  The source runs dry at every point of a grow, the directory's included:
 *            the refusal is ERX_ENOMEM, the records before keep their contents, and
 *            clearing gives back every page the table took.
 *   move     Moves in both directions, overlapping and across pages, agree with a
 *            plain array moved by memmove.
 *
 * Prints what it covered and exits 0, or names the first disagreement and exits 1.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

#include "erx/abi.h"
#include "liberx/backend/core/grow_table.h"

#define PAGE	((size_t)ERX_PAGE_SIZE)
/* Room enough for one full table of the smallest records the checks use. */
#define MODEL_RECORDS	(4u * 1024u * 1024u)

static uint32_t		 pages_left;	/* what the source may still hand out */
static uint32_t		 pages_held;
static const char	*current_case = "setup";
static unsigned long	 checks;

static _Noreturn void
fail(const char *what, uint64_t detail)
{
	fprintf(stderr, "%s: %s (0x%llx)\n", current_case, what, (unsigned long long)detail);
	exit(1);
}

/* A page full of garbage, so a record the core does not zero shows. */
static uintptr_t
source_take(void)
{
	void *page = NULL;

	if (pages_left == 0)
		return (0);
	if (posix_memalign(&page, PAGE, PAGE) != 0)
		fail("the host gave no page", 0);
	pages_left--;
	pages_held++;
	memset(page, 0xa5, PAGE);
	return ((uintptr_t)page);
}

static void
source_give(uintptr_t page)
{
	if (page == 0 || page % PAGE != 0)
		fail("a page given back that is no page", page);
	if (pages_held == 0)
		fail("more pages given back than taken", page);
	pages_held--;
	free((void *)page);
}

static const erx_backend_grow_pages_t source = { .take = source_take, .give = source_give };

/* A record's expected contents: its index and a stamp, repeated over its bytes. */
static void
stamp(uint8_t *record, size_t bytes, uint32_t index, uint8_t salt)
{
	for (size_t byte = 0; byte < bytes; byte++)
		record[byte] = (uint8_t)(index * 31u + byte + salt);
}

static bool
stamped(const uint8_t *record, size_t bytes, uint32_t index, uint8_t salt)
{
	for (size_t byte = 0; byte < bytes; byte++)
		if (record[byte] != (uint8_t)(index * 31u + byte + salt))
			return (false);
	return (true);
}

static bool
zero(const uint8_t *record, size_t bytes)
{
	for (size_t byte = 0; byte < bytes; byte++)
		if (record[byte] != 0)
			return (false);
	return (true);
}

/* Every record below count holds its stamp and sits where it was; none exists past the capacity. */
static void
check_records(const erx_backend_grow_table_t *table, uint8_t *const *where, uint32_t count, uint8_t salt)
{
	const uint32_t capacity = erx_backend_grow_table_capacity(table);

	for (uint32_t index = 0; index < count; index++) {
		uint8_t *const record = erx_backend_grow_table_at(table, index);

		if (record != where[index])
			fail("a record moved", index);
		if (!stamped(record, table->record_bytes, index, salt))
			fail("a record lost its contents", index);
	}
	if (erx_backend_grow_table_at(table, capacity) != NULL || erx_backend_grow_table_at(table, UINT32_MAX) != NULL)
		fail("a record past the capacity exists", capacity);
	checks++;
}

/* Grows a table of this record size to its limit, one record more at a time. */
static void
check_grow(size_t record_bytes, uint8_t **where)
{
	erx_backend_grow_table_t table;
	uint32_t limit;

	current_case = "grow";
	pages_left = UINT32_MAX;
	erx_backend_grow_table_init(&table, record_bytes, &source);
	limit = erx_backend_grow_table_limit(&table);
	if (limit != ERX_BACKEND_GROW_PAGES_MAX * (uint32_t)(PAGE / record_bytes))
		fail("the limit is not a full directory's", limit);
	if (erx_backend_grow_table_capacity(&table) != 0 || erx_backend_grow_table_at(&table, 0) != NULL || pages_held != 0)
		fail("a new table holds something", pages_held);
	if (erx_backend_grow_table_room(&table, 0) != ERX_OK || pages_held != 0)
		fail("room for nothing took a page", pages_held);

	for (uint32_t count = 1; count <= limit; count++) {
		uint8_t *record;

		if (erx_backend_grow_table_room(&table, count) != ERX_OK)
			fail("a grow below the limit failed", count);
		if (erx_backend_grow_table_capacity(&table) < count ||
		    erx_backend_grow_table_capacity(&table) - count >= table.per_page)
			fail("a grow took more than it needed", erx_backend_grow_table_capacity(&table));
		if (pages_held != 1 + (count + table.per_page - 1) / table.per_page)
			fail("the pages held are not the directory and the record pages", pages_held);
		record = erx_backend_grow_table_at(&table, count - 1);
		if (record == NULL || !zero(record, record_bytes))
			fail("a new record does not read zero", count - 1);
		if ((uintptr_t)record % PAGE + record_bytes > PAGE)
			fail("a record crosses its page", count - 1);
		stamp(record, record_bytes, count - 1, 0);
		where[count - 1] = record;
		if ((count % table.per_page == 1 && count / table.per_page < 4) || count == limit)
			check_records(&table, where, count, 0);
	}
	if (erx_backend_grow_table_room(&table, limit + 1) != ERX_ENOMEM)
		fail("room past the limit was given", limit + 1);
	check_records(&table, where, limit, 0);
	erx_backend_grow_table_clear(&table);
	if (pages_held != 0 || erx_backend_grow_table_capacity(&table) != 0 || erx_backend_grow_table_at(&table, 0) != NULL)
		fail("clearing left pages", pages_held);
	/* A cleared table grows again from nothing. */
	if (erx_backend_grow_table_room(&table, 1) != ERX_OK || pages_held != 2)
		fail("a cleared table did not grow again", pages_held);
	erx_backend_grow_table_clear(&table);
	checks++;
}

/*
 * The source runs dry after `given` pages, for every count of pages a room for
 * `records` takes, the directory first: each refusal keeps what was there.
 */
static void
check_refusal(size_t record_bytes, uint8_t **where)
{
	erx_backend_grow_table_t table;

	current_case = "refusal";
	erx_backend_grow_table_init(&table, record_bytes, &source);
	const uint32_t records = 3 * table.per_page + 1;
	const uint32_t pages_needed = 1 + 4;

	for (uint32_t given = 0; given < pages_needed; given++) {
		uint32_t kept;

		pages_left = given;
		erx_backend_grow_table_init(&table, record_bytes, &source);
		if (erx_backend_grow_table_room(&table, records) != ERX_ENOMEM)
			fail("a grow past the source passed", given);
		/* With no record page, the directory goes back too, so an empty table holds nothing. */
		if (given <= 1 && (pages_held != 0 || table.directory != NULL))
			fail("a refused first grow kept a page", pages_held);
		if (given > 1 && pages_held != given)
			fail("a refused grow gave back pages it had added", pages_held);
		kept = erx_backend_grow_table_capacity(&table);
		for (uint32_t index = 0; index < kept; index++) {
			where[index] = erx_backend_grow_table_at(&table, index);
			stamp(where[index], record_bytes, index, 7);
		}
		pages_left = 0;
		if (erx_backend_grow_table_room(&table, kept + 1) != ERX_ENOMEM)
			fail("a grow from a dry source passed", kept);
		check_records(&table, where, kept, 7);
		pages_left = UINT32_MAX;
		if (erx_backend_grow_table_room(&table, records) != ERX_OK)
			fail("a grow after the refusal failed", given);
		check_records(&table, where, kept, 7);
		erx_backend_grow_table_clear(&table);
		if (pages_held != 0)
			fail("clearing after a refusal left pages", pages_held);
	}
	checks++;
}

/* Moves of every shape over a table of three pages, against memmove over an array. */
static void
check_move(size_t record_bytes)
{
	erx_backend_grow_table_t table;
	uint8_t *model;
	uint32_t count;

	current_case = "move";
	pages_left = UINT32_MAX;
	erx_backend_grow_table_init(&table, record_bytes, &source);
	count = 3 * table.per_page;
	if (erx_backend_grow_table_room(&table, count) != ERX_OK)
		fail("the table did not grow", count);
	model = malloc(count * record_bytes);
	if (model == NULL)
		fail("the host gave no memory", 0);
	for (uint32_t index = 0; index < count; index++) {
		stamp(erx_backend_grow_table_at(&table, index), record_bytes, index, 3);
		stamp(model + index * record_bytes, record_bytes, index, 3);
	}
	srand(20261107u);
	for (unsigned round = 0; round < 2000; round++) {
		const uint32_t from = (uint32_t)rand() % count;
		const uint32_t to = (uint32_t)rand() % count;
		const uint32_t room = count - (from > to ? from : to);
		const uint32_t moved = (uint32_t)rand() % (room + 1);

		erx_backend_grow_table_move(&table, to, from, moved);
		memmove(model + (size_t)to * record_bytes, model + (size_t)from * record_bytes, (size_t)moved * record_bytes);
		for (uint32_t index = 0; index < count; index++)
			if (memcmp(erx_backend_grow_table_at(&table, index), model + index * record_bytes, record_bytes) != 0)
				fail("a move disagrees with memmove", index);
		checks++;
	}
	free(model);
	erx_backend_grow_table_clear(&table);
}

/* A lookup past the pages the table holds reads no page of it. Name it, since a fault prints nothing. */
static void
stray_read(int signal_number)
{
	static const char line[] = "a record read outside the table\n";

	(void)signal_number;
	(void)write(2, line, sizeof(line) - 1);
	_exit(1);
}

int
main(void)
{
	/* Records that fill a page exactly, that leave a tail, and the two extremes. */
	static const size_t sizes[] = { 1, 16, 24, 1000, 2048, 2049, PAGE };
	uint8_t **where = malloc(MODEL_RECORDS * sizeof(*where));

	if (where == NULL)
		return (1);
	signal(SIGSEGV, stray_read);
	signal(SIGBUS, stray_read);
	for (size_t size = 0; size < sizeof(sizes) / sizeof(sizes[0]); size++) {
		check_grow(sizes[size], where);
		check_refusal(sizes[size], where);
		check_move(sizes[size]);
	}
	if (pages_held != 0)
		fail("pages left after every table was cleared", pages_held);
	free(where);
	printf("ok: %lu checks\n", checks);
	return (0);
}
