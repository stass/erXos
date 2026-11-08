/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the object store (kernel/core/object.c). It plays the
 * core's host: it keeps the thread's count of preemption points that
 * erx_effect_thread_epoch reports, and a table of OBJECTS_MAX records. It
 * reads one command per line from the file named by its argument and
 * prints one line per command, which test/fixtures/object_model.rb
 * predicts independently. A command that breaks the core's contract (a
 * put of a record with no reference, a borrowed reference kept across a
 * preemption point) traps in the core, and the test expects the signal.
 *
 *   key A B C D     a store keyed with the four round keys; counter 0
 *   counter N       set the store's creation counter to N
 *   new I           make record I:          "= STATUS OID NEXT"
 *   add I           erx_object_cap_add:     "= STATUS STATE NCAPS REFS"
 *   remove I        erx_object_cap_remove:  "= RELEASED STATE NCAPS REFS"
 *   close I         erx_object_close:       "= CLOSED STATE NCAPS REFS"
 *   ref I           erx_object_ref of a fresh lookup of I, as remove
 *   put I           erx_object_put:         "= LAST STATE NCAPS REFS"
 *   ncaps I N       set I's slot count to N (to reach the limit)
 *   refs I N        set I's reference count to N
 *   lookup I        keep a borrowed reference to I:  "= EPOCH"
 *   preempt         pass a preemption point:          "= EPOCH"
 *   get             erx_uref_get of the kept one:     "= I"
 *   hold            erx_object_ref of the kept one:   "= I REFS"
 *   store N         the test store holds records 0 .. N-1: "= N"
 *   handle I        erx_object_handle of record I:    "= HANDLE"
 *   from H          erx_object_from_handle(H):        "= I", -1 for NULL
 *   slots I P       set I's slot list head to slot P, or NULL when P
 *                   is -1, and read it back:          "= P"
 *   facts I         the fixed fields: "= TYPE BUDGET OID NAME_EMPTY"
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "object_impl.h"

#define OBJECTS_MAX	8
#define SLOTS_MAX	4

static erx_object_t objects[OBJECTS_MAX];
static erx_object_t *records[OBJECTS_MAX];
/* Stand-ins for the budgets that pay, named only by address. */
static char budgets[OBJECTS_MAX];
static uint8_t slots[SLOTS_MAX][64];
static erx_object_store_t store;
static erx_uref_t kept;
static uint32_t epoch;

uint32_t
erx_effect_thread_epoch(void)
{
	return (epoch);
}

static void
fail(const char *what)
{
	fprintf(stderr, "object_driver: %s\n", what);
	exit(1);
}

static uint64_t
number(const char *text)
{
	char *end;
	uint64_t value;

	if (text == NULL)
		fail("missing operand");
	value = strtoull(text, &end, 0);
	if (*end != '\0')
		fail("malformed number");
	return (value);
}

static erx_object_t *
record(const char *text)
{
	uint64_t index;

	index = number(text);
	if (index >= OBJECTS_MAX)
		fail("record index out of range");
	return (&objects[index]);
}

static int
index_of(const erx_object_t *object)
{
	if (object == NULL)
		return (-1);
	if (object < objects || object >= objects + OBJECTS_MAX)
		fail("an object outside the driver's table");
	return ((int)(object - objects));
}

static void
print_counts(int64_t result, const erx_object_t *object)
{
	printf("= %" PRId64 " %d %" PRIu32 " %" PRIu32 "\n", result,
	    (int)erx_object_state(object), erx_object_ncaps(object),
	    atomic_load(&object->refs));
}

static void
command(char *line)
{
	char *verb, *a, *b, *c, *d;
	erx_object_t *object;
	erx_oid_key_t key;
	erx_status_t status;
	uint64_t value;
	int64_t slot;

	verb = strtok(line, " \t\n");
	if (verb == NULL)
		return;
	a = strtok(NULL, " \t\n");
	b = strtok(NULL, " \t\n");
	c = strtok(NULL, " \t\n");
	d = strtok(NULL, " \t\n");
	if (strcmp(verb, "key") == 0) {
		key.round[0] = number(a);
		key.round[1] = number(b);
		key.round[2] = number(c);
		key.round[3] = number(d);
		erx_object_store_init(&store, &key);
		printf("= 0\n");
	} else if (strcmp(verb, "counter") == 0) {
		atomic_store(&store.next, number(a));
		printf("= 0\n");
	} else if (strcmp(verb, "new") == 0) {
		object = record(a);
		status = erx_object_init(&store, object, ERX_K_GATE,
		    (struct erx_budget *)(void *)&budgets[index_of(object)]);
		printf("= %d %" PRIu64 " %" PRIu64 "\n", (int)status,
		    status == ERX_OK ? erx_object_oid(object) : 0,
		    atomic_load(&store.next));
	} else if (strcmp(verb, "add") == 0) {
		object = record(a);
		print_counts(erx_object_cap_add(object), object);
	} else if (strcmp(verb, "remove") == 0) {
		object = record(a);
		print_counts(erx_object_cap_remove(object), object);
	} else if (strcmp(verb, "close") == 0) {
		object = record(a);
		print_counts(erx_object_close(object), object);
	} else if (strcmp(verb, "ref") == 0) {
		object = erx_object_ref(erx_uref_make(record(a)));
		print_counts(index_of(object), object);
	} else if (strcmp(verb, "put") == 0) {
		object = record(a);
		print_counts(erx_object_put(object), object);
	} else if (strcmp(verb, "ncaps") == 0) {
		object = record(a);
		value = number(b);
		if (value > UINT32_MAX)
			fail("count out of range");
		object->ncaps = (uint32_t)value;
		print_counts(0, object);
	} else if (strcmp(verb, "refs") == 0) {
		object = record(a);
		value = number(b);
		if (value > UINT32_MAX)
			fail("count out of range");
		atomic_store(&object->refs, (uint32_t)value);
		print_counts(0, object);
	} else if (strcmp(verb, "lookup") == 0) {
		kept = erx_uref_make(record(a));
		printf("= %" PRIu32 "\n", epoch);
	} else if (strcmp(verb, "preempt") == 0) {
		epoch++;
		printf("= %" PRIu32 "\n", epoch);
	} else if (strcmp(verb, "get") == 0) {
		printf("= %d\n", index_of(erx_uref_get(kept)));
	} else if (strcmp(verb, "hold") == 0) {
		object = erx_object_ref(kept);
		printf("= %d %" PRIu32 "\n", index_of(object),
		    atomic_load(&object->refs));
	} else if (strcmp(verb, "store") == 0) {
		value = number(a);
		if (value > OBJECTS_MAX)
			fail("store larger than the table");
		erx_object_test_store(records, value);
		printf("= %" PRIu64 "\n", value);
	} else if (strcmp(verb, "handle") == 0) {
		printf("= %" PRIu64 "\n", erx_object_handle(record(a)));
	} else if (strcmp(verb, "from") == 0) {
		printf("= %d\n", index_of(erx_object_from_handle(number(a))));
	} else if (strcmp(verb, "slots") == 0) {
		object = record(a);
		slot = strtoll(b == NULL ? "" : b, NULL, 0);
		if (slot < -1 || slot >= SLOTS_MAX)
			fail("slot out of range");
		erx_object_set_slots(object, slot < 0 ? NULL :
		    (erx_cap_slot_t *)(void *)slots[slot]);
		slot = erx_object_slots(object) == NULL ? -1 :
		    ((uint8_t *)(void *)erx_object_slots(object) -
		    slots[0]) / 64;
		printf("= %" PRId64 "\n", slot);
	} else if (strcmp(verb, "facts") == 0) {
		object = record(a);
		printf("= %" PRIu32 " %d %" PRIu64 " %d\n",
		    erx_object_type(object),
		    erx_object_budget(object) == NULL ? -1 :
		    (int)((char *)(void *)erx_object_budget(object) - budgets),
		    erx_object_oid(object),
		    object->name[0] == '\0' &&
		    memcmp(object->name, (char[16]){ 0 }, 16) == 0);
	} else {
		fail("unknown command");
	}
}

int
main(int argc, char **argv)
{
	char line[256];
	FILE *script;
	int i;

	if (argc != 2)
		fail("usage: object_driver SCRIPT");
	script = fopen(argv[1], "r");
	if (script == NULL)
		fail("cannot open the script");
	for (i = 0; i < OBJECTS_MAX; i++) {
		records[i] = &objects[i];
	}
	setvbuf(stdout, NULL, _IOFBF, 1 << 16);
	while (fgets(line, sizeof(line), script) != NULL) {
		command(line);
		fflush(stdout);
	}
	fclose(script);
	return (0);
}
