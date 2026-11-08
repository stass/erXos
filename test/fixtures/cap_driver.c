/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs the capability core over commands on standard input and prints
 * every result, so the host test's model can judge it. Two tables, 0 and
 * 1, each with a directory of DRIVER_PAGES pages; T names one. Objects 1
 * to DRIVER_OBJECTS are the test store's records, LIVE with no capability
 * at the start: a memory object, a gate and a space. Numbers are
 * hexadecimal.
 *
 *   table T LIMIT              reset T: an empty table of LIMIT slots
 *   grow T N                   add the pages for N free slots
 *   seed T SLOT GEN SEQ        set a free slot's generation and count
 *   install T OBJECT KIND MASK erx_cap_install_kind
 *   copy TO FROM VALUE OBJECT MASK
 *                              erx_cap_install_copy
 *   revive OBJECT              a fresh header for a released object
 *   objects                    fresh headers for every object, as at
 *                              the start; for a test that resets its
 *                              tables, whose slots the lists name
 *   clear T VALUE OBJECT       prints the status and the release
 *   read T VALUE TYPE REQUIRED
 *   lookup T VALUE TYPE REQUIRED
 *                              prints the status and the object
 *   self T VALUE TYPE REQUIRED read as a call of a thread of T's space,
 *                              whose space is object 5a and thread 7b
 *   reserve T N                T's one reservation takes N slots
 *   release T
 *   empty T
 *   dump T                     every slot, the free list, the reservation,
 *                              then each object and its slot list
 *   rights KIND                erx_rights_create
 *   shrink RIGHTS MASK         erx_rights_shrink
 *   pass FROM TO ROUTE N [RACE], then N lines
 *     item VALUE OP MASK TYPE REQUIRED
 *                              read, plan and apply a pass into TO's
 *                              reservation; RACE 1 clears the first
 *                              source and RACE 2 releases the
 *                              reservation between plan and apply; an
 *                              install that drops the pass prints each
 *                              released step
 *   plan ROUTE ROOM N, then N lines
 *     source STATUS OBJECT TYPE RIGHTS SLOT GEN OP MASK ITYPE REQUIRED
 *                              erx_pass_plan alone
 *   save                       remember both tables, pages included
 *   restore                    return to them; no page added between
 *   end                        prints "end", flushes
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/cap.h"
#include "erx/object.h"
#include "cap_impl.h"
#include "cap_slot_impl.h"

#define DRIVER_PAGES	4
#define DRIVER_LINE	256
#define DRIVER_OBJECTS	3

typedef struct driver_table {
	erx_cap_table_t		 table;
	_Atomic(erx_cap_slot_t *) dir[DRIVER_PAGES];
	erx_cap_slot_t		*pages[DRIVER_PAGES];
	uint32_t		 npages;
	erx_cap_reservation_t	 reservation;
} driver_table_t;

static driver_table_t	 tables[2];
static driver_table_t	 saved[2];
static const erx_cap_self_t driver_self = { 0x5a, 0x7b };
static erx_cap_slot_t	 saved_slots[2][DRIVER_PAGES][ERX_CAP_PAGE_SLOTS];
static unsigned long	 lineno;
static erx_object_store_t *store;
static erx_object_t	*objects[DRIVER_OBJECTS];
static void		*saved_objects[DRIVER_OBJECTS];
static const erx_ktype_t object_types[DRIVER_OBJECTS] = {
	ERX_K_MEMORY, ERX_K_GATE, ERX_K_SPACE
};

static void
driver_fail(const char *reason)
{
	fprintf(stderr, "cap_driver: line %lu: %s\n", lineno, reason);
	exit(2);
}

static bool
driver_line(char *line)
{
	lineno++;
	if (fgets(line, DRIVER_LINE, stdin) == NULL)
		return (false);
	line[strcspn(line, "\n")] = '\0';
	return (true);
}

static erx_object_t *
driver_object(uint64_t id)
{
	if (id == 0 || id > DRIVER_OBJECTS)
		driver_fail("no such object");
	return (objects[id - 1]);
}

/* The id of a table the driver holds, from a slot's table field. */
static unsigned
driver_table_id(uint64_t address)
{
	unsigned t;

	for (t = 0; t < 2; t++)
		if (address == (uint64_t)(uintptr_t)&tables[t].table)
			return (t);
	driver_fail("a slot names no table");
	return (0);
}

static void
driver_revive(uint64_t id)
{
	printf("revive %d\n", erx_object_init(store, driver_object(id),
	    object_types[id - 1], NULL));
}

static void
driver_setup(void)
{
	erx_oid_key_t key = { { 1, 2, 3, 4 } };
	uint64_t i;

	store = calloc(1, erx_object_store_size());
	if (store == NULL)
		driver_fail("out of memory");
	erx_object_store_init(store, &key);
	for (i = 0; i < DRIVER_OBJECTS; i++) {
		objects[i] = aligned_alloc(erx_object_record_align(),
		    erx_object_record_size());
		saved_objects[i] = malloc(erx_object_record_size());
		if (objects[i] == NULL || saved_objects[i] == NULL ||
		    erx_object_init(store, objects[i], object_types[i],
		    NULL) != ERX_OK)
			driver_fail("cannot make the objects");
	}
	erx_object_test_store(objects, DRIVER_OBJECTS);
}

static driver_table_t *
driver_table(unsigned id)
{
	if (id > 1)
		driver_fail("no such table");
	return (&tables[id]);
}

static void
driver_reset(driver_table_t *t, uint32_t limit)
{
	uint32_t i;

	for (i = 0; i < t->npages; i++)
		free(t->pages[i]);
	memset(t, 0, sizeof(*t));
	printf("table %d\n", erx_cap_table_init(&t->table, t->dir, sizeof(t->dir),
	    limit));
}

static void
driver_grow(driver_table_t *t, uint32_t n)
{
	uint32_t npages = 0, i;
	erx_status_t status;

	status = erx_cap_table_pages_needed(&t->table, n, &npages);
	for (i = 0; status == ERX_OK && i < npages; i++) {
		if (t->npages == DRIVER_PAGES)
			driver_fail("directory full");
		t->pages[t->npages] = calloc(ERX_CAP_PAGE_SLOTS,
		    sizeof(erx_cap_slot_t));
		if (t->pages[t->npages] == NULL)
			driver_fail("out of memory");
		status = erx_cap_table_add_page(&t->table, t->pages[t->npages],
		    ERX_CAP_PAGE_SLOTS * sizeof(erx_cap_slot_t));
		t->npages++;
	}
	printf("grow %d %" PRIx32 "\n", status, npages);
}

static erx_cap_slot_t *
driver_slot(driver_table_t *t, uint32_t index)
{
	if (index / ERX_CAP_PAGE_SLOTS >= t->npages)
		driver_fail("slot outside the pages");
	return (&t->pages[index / ERX_CAP_PAGE_SLOTS][index %
	    ERX_CAP_PAGE_SLOTS]);
}

/* The index of slot in table t, from the pages the driver gave it. */
static uint32_t
driver_index(unsigned t, const erx_cap_slot_t *slot)
{
	uint32_t p;

	for (p = 0; p < tables[t].npages; p++)
		if (slot >= tables[t].pages[p] &&
		    slot < tables[t].pages[p] + ERX_CAP_PAGE_SLOTS)
			return (p * ERX_CAP_PAGE_SLOTS +
			    (uint32_t)(slot - tables[t].pages[p]));
	driver_fail("a listed slot is in no page of its table");
	return (0);
}

/*
 * Each object's state, count and slot list, head first, as table:index
 * from each slot's own table field; every back link must match.
 */
static void
driver_dump_objects(void)
{
	const erx_cap_slot_t *slot, *prev;
	uint64_t address, back;
	unsigned id, t;

	for (id = 1; id <= DRIVER_OBJECTS; id++) {
		printf("object %x %x %" PRIx32, id,
		    erx_object_state(driver_object(id)),
		    erx_object_ncaps(driver_object(id)));
		prev = NULL;
		for (slot = erx_object_slots(driver_object(id)); slot != NULL;
		    slot = (const erx_cap_slot_t *)(uintptr_t)address) {
			(void)erx_cap_slot_obj_prev_load(slot, &back);
			if (back != (uint64_t)(uintptr_t)prev)
				driver_fail("a slot's back link is wrong");
			(void)erx_cap_slot_table_load(slot, &address);
			t = driver_table_id(address);
			printf(" %x:%" PRIx32, t, driver_index(t, slot));
			prev = slot;
			(void)erx_cap_slot_obj_next_load(slot, &address);
		}
		printf("\n");
	}
}

static void
driver_dump(driver_table_t *t)
{
	uint32_t capacity = atomic_load(&t->table.capacity);
	uint64_t object, generation, seq;
	uint32_t rights, type, state, next, i;
	erx_cap_slot_t *slot;

	for (i = 0; i < capacity; i++) {
		slot = driver_slot(t, i);
		(void)erx_cap_slot_object_load(slot, &object);
		(void)erx_cap_slot_generation_load(slot, &generation);
		(void)erx_cap_slot_seq_load(slot, &seq);
		(void)erx_cap_slot_rights_load(slot, &rights);
		(void)erx_cap_slot_type_load(slot, &type);
		(void)erx_cap_slot_state_load(slot, &state);
		printf("slot %" PRIx32 " %" PRIx32 " %" PRIx64 " %" PRIx64
		    " %" PRIx64 " %" PRIx32 " %" PRIx32 "\n", i, state,
		    generation, seq, object, type, rights);
	}
	printf("free %" PRIx32, t->table.nfree);
	for (i = t->table.free_head; i != 0; i = next) {
		printf(" %" PRIx32, i);
		(void)erx_cap_slot_next_load(driver_slot(t, i), &next);
	}
	printf("\nheld %" PRIx32, t->reservation.count);
	for (i = 0; i < t->reservation.count; i++)
		printf(" %" PRIx32, t->reservation.slots[i]);
	printf("\n");
	driver_dump_objects();
}

/*
 * A table's state is its struct, its reservation and its slots; the
 * directory and the page pointers stay, so a restore needs the pages the
 * save saw. Slots and object records are copied as bytes, slot list links
 * included, since nothing moves: the driver has no reader running.
 */
static void
driver_save(bool restore)
{
	driver_table_t *from, *to;
	uint32_t t, p;

	for (t = 0; t < DRIVER_OBJECTS; t++)
		if (restore)
			memcpy(objects[t], saved_objects[t],
			    erx_object_record_size());
		else
			memcpy(saved_objects[t], objects[t],
			    erx_object_record_size());
	for (t = 0; t < 2; t++) {
		from = restore ? &saved[t] : &tables[t];
		to = restore ? &tables[t] : &saved[t];
		if (restore && from->npages != to->npages)
			driver_fail("pages added since the save");
		for (p = 0; p < tables[t].npages; p++)
			if (restore)
				memcpy(tables[t].pages[p], saved_slots[t][p],
				    sizeof(saved_slots[t][p]));
			else
				memcpy(saved_slots[t][p], tables[t].pages[p],
				    sizeof(saved_slots[t][p]));
		atomic_store(&to->table.capacity,
		    atomic_load(&from->table.capacity));
		to->table.free_head = from->table.free_head;
		to->table.free_tail = from->table.free_tail;
		to->table.nfree = from->table.nfree;
		to->table.emptied = from->table.emptied;
		to->reservation = from->reservation;
		to->npages = from->npages;
	}
}

static void
driver_print_plan(erx_status_t status, const erx_pass_plan_t *plan)
{
	uint32_t i;

	printf("plan %d %" PRIx32 " %" PRIx32 "\n", status, plan->failed,
	    plan->count);
	for (i = 0; i < plan->count; i++)
		printf("step %d %" PRIx32 " %" PRIx64 " %" PRIx64 " %" PRIx32
		    " %" PRIx32 "\n", plan->steps[i].op, plan->steps[i].slot,
		    plan->steps[i].generation, plan->steps[i].object,
		    plan->steps[i].type, plan->steps[i].rights.bits);
}

static void
driver_pass(const char *line)
{
	erx_pass_item_t items[ERX_MSG_CAPS];
	erx_pass_source_t sources[ERX_MSG_CAPS];
	erx_pass_result_t results[ERX_MSG_CAPS];
	erx_pass_request_t request;
	erx_pass_plan_t plan;
	driver_table_t *from, *to;
	char buf[DRIVER_LINE];
	unsigned fid, tid, route, n, i, race = 0;
	erx_status_t status;
	bool released;

	if (sscanf(line, "pass %x %x %x %x %x", &fid, &tid, &route, &n,
	    &race) < 4 || n > ERX_MSG_CAPS)
		driver_fail("bad pass");
	from = driver_table(fid);
	to = driver_table(tid);
	for (i = 0; i < n; i++) {
		if (!driver_line(buf) || sscanf(buf, "item %" SCNx64 " %" SCNx32
		    " %" SCNx32 " %" SCNx32 " %" SCNx32, &items[i].cap.raw,
		    &items[i].op, &items[i].mask, &items[i].type,
		    &items[i].required) != 5)
			driver_fail("bad item");
		memset(&sources[i], 0, sizeof(sources[i]));
		sources[i].status = erx_cap_read(&from->table,
		    route == ERX_PASS_RENDEZVOUS ||
		    route == ERX_PASS_OWN_TO_CREATED ? &driver_self : NULL,
		    items[i].cap,
		    ERX_CAP_ANY_TYPE, 0, &sources[i].view);
	}
	request.items = items;
	request.count = n;
	request.room = to->reservation.count;
	request.route = route;
	request.from = &from->table;
	request.to = &to->table;
	status = erx_pass_plan(&request, sources, &plan);
	driver_print_plan(status, &plan);
	if (status != ERX_OK)
		return;
	if (race == 1 && plan.count > 0)
		(void)erx_cap_slot_clear(&from->table, items[0].cap,
		    erx_object_from_handle(plan.steps[0].object), &released);
	if (race == 2)
		erx_cap_release_reservation(&to->table, &to->reservation);
	status = erx_pass_take(&plan, &from->table, &to->reservation);
	printf("take %d\n", status);
	if (status != ERX_OK)
		return;
	status = erx_pass_install(&plan, &to->table, &to->reservation,
	    results);
	printf("install %d\n", status);
	for (i = 0; i < plan.count; i++)
		if (plan.steps[i].released)
			printf("released %" PRIx32 "\n", i);
	for (i = 0; status == ERX_OK && i < plan.count; i++)
		printf("result %" PRIx64 " %" PRIx32 " %" PRIx32 "\n",
		    results[i].cap.raw, results[i].type, results[i].rights.bits);
}

static void
driver_plan(const char *line)
{
	erx_pass_item_t items[ERX_MSG_CAPS];
	erx_pass_source_t sources[ERX_MSG_CAPS];
	erx_pass_request_t request;
	erx_pass_plan_t plan;
	char buf[DRIVER_LINE];
	unsigned route, room, n, i;
	int status;

	if (sscanf(line, "plan %x %x %x", &route, &room, &n) != 3 ||
	    n > ERX_MSG_CAPS + 1)
		driver_fail("bad plan");
	for (i = 0; i < n && i < ERX_MSG_CAPS; i++) {
		memset(&sources[i], 0, sizeof(sources[i]));
		if (!driver_line(buf) || sscanf(buf, "source %d %" SCNx64
		    " %" SCNx32 " %" SCNx32 " %" SCNx32 " %" SCNx64 " %" SCNx32
		    " %" SCNx32 " %" SCNx32 " %" SCNx32, &status,
		    &sources[i].view.object, &sources[i].view.type,
		    &sources[i].view.rights.bits, &sources[i].view.slot,
		    &sources[i].view.generation, &items[i].op, &items[i].mask,
		    &items[i].type, &items[i].required) != 10)
			driver_fail("bad source");
		sources[i].status = status;
	}
	request.items = items;
	request.count = n;
	request.room = room;
	request.route = route;
	request.from = &tables[0].table;
	request.to = &tables[1].table;
	driver_print_plan(erx_pass_plan(&request, sources, &plan), &plan);
}

static void
driver_command(const char *line)
{
	erx_cap_view_t view;
	erx_uref_t ref;
	erx_cap_t cap;
	erx_rights_t rights;
	uint64_t a, b, c;
	uint32_t x, y;
	unsigned t, u;
	erx_status_t status;
	bool released;

	if (sscanf(line, "table %x %" SCNx32, &t, &x) == 2)
		driver_reset(driver_table(t), x);
	else if (sscanf(line, "grow %x %" SCNx32, &t, &x) == 2)
		driver_grow(driver_table(t), x);
	else if (sscanf(line, "seed %x %" SCNx32 " %" SCNx64 " %" SCNx64, &t,
	    &x, &a, &b) == 4) {
		(void)erx_cap_slot_generation_store(driver_slot(driver_table(t),
		    x), a);
		(void)erx_cap_slot_seq_store(driver_slot(driver_table(t), x), b);
		printf("seed\n");
	} else if (sscanf(line, "install %x %" SCNx64 " %" SCNx32 " %" SCNx32,
	    &t, &a, &x, &y) == 4) {
		cap.raw = 0;
		status = erx_cap_install_kind(&driver_table(t)->table,
		    driver_object(a), x, y, &cap);
		printf("install %d %" PRIx64 "\n", status, cap.raw);
	} else if (sscanf(line, "copy %x %x %" SCNx64 " %" SCNx64 " %" SCNx32,
	    &t, &u, &a, &b, &x) == 5) {
		cap.raw = a;
		status = erx_cap_install_copy(&driver_table(t)->table,
		    &driver_table(u)->table, cap, driver_object(b), x, &cap);
		printf("copy %d %" PRIx64 "\n", status, status == ERX_OK ?
		    cap.raw : 0);
	} else if (sscanf(line, "revive %" SCNx64, &a) == 1)
		driver_revive(a);
	else if (strcmp(line, "objects") == 0) {
		for (a = 1; a <= DRIVER_OBJECTS; a++)
			if (erx_object_init(store, driver_object(a),
			    object_types[a - 1], NULL) != ERX_OK)
				driver_fail("cannot make the objects");
		printf("objects\n");
	}
	else if (sscanf(line, "clear %x %" SCNx64 " %" SCNx64, &t, &a,
	    &b) == 3) {
		/* A handle outside the store names no record, and no slot. */
		cap.raw = a;
		status = erx_cap_slot_clear(&driver_table(t)->table, cap,
		    erx_object_from_handle(b), &released);
		printf("clear %d %d\n", status, released);
	} else if (sscanf(line, "lookup %x %" SCNx64 " %" SCNx32 " %" SCNx64,
	    &t, &a, &x, &c) == 4) {
		cap.raw = a;
		status = erx_cap_lookup(&driver_table(t)->table, NULL, cap, x,
		    (uint32_t)c, &ref);
		printf("lookup %d %" PRIx64 "\n", status, status == ERX_OK ?
		    erx_object_handle(erx_uref_get(ref)) : 0);
	} else if (sscanf(line, "read %x %" SCNx64 " %" SCNx32 " %" SCNx64, &t,
	    &a, &x, &c) == 4) {
		cap.raw = a;
		memset(&view, 0, sizeof(view));
		status = erx_cap_read(&driver_table(t)->table, NULL, cap, x,
		    (uint32_t)c, &view);
		printf("read %d %" PRIx64 " %" PRIx32 " %" PRIx32 " %" PRIx32
		    " %" PRIx64 "\n", status, view.object, view.type,
		    view.rights.bits, view.slot, view.generation);
	} else if (sscanf(line, "self %x %" SCNx64 " %" SCNx32 " %" SCNx64, &t,
	    &a, &x, &c) == 4) {
		cap.raw = a;
		memset(&view, 0, sizeof(view));
		status = erx_cap_read(&driver_table(t)->table, &driver_self, cap,
		    x, (uint32_t)c, &view);
		printf("self %d %" PRIx64 " %" PRIx32 " %" PRIx32 " %" PRIx32
		    " %" PRIx64 "\n", status, view.object, view.type,
		    view.rights.bits, view.slot, view.generation);
	} else if (sscanf(line, "reserve %x %" SCNx32, &t, &x) == 2) {
		status = erx_cap_reserve(&driver_table(t)->table, x,
		    &driver_table(t)->reservation);
		printf("reserve %d\n", status);
	} else if (sscanf(line, "release %x", &t) == 1) {
		erx_cap_release_reservation(&driver_table(t)->table,
		    &driver_table(t)->reservation);
		printf("release\n");
	} else if (sscanf(line, "empty %x", &t) == 1) {
		erx_cap_table_set_emptied(&driver_table(t)->table);
		printf("empty\n");
	} else if (sscanf(line, "dump %x", &t) == 1)
		driver_dump(driver_table(t));
	else if (sscanf(line, "rights %" SCNx32, &x) == 1)
		printf("rights %" PRIx32 "\n", erx_rights_create(x).bits);
	else if (sscanf(line, "shrink %" SCNx32 " %" SCNx32, &x, &y) == 2) {
		rights.bits = x;
		printf("shrink %" PRIx32 "\n", erx_rights_shrink(rights, y).bits);
	} else if (strncmp(line, "pass ", 5) == 0)
		driver_pass(line);
	else if (strncmp(line, "plan ", 5) == 0)
		driver_plan(line);
	else if (strcmp(line, "save") == 0)
		driver_save(false);
	else if (strcmp(line, "restore") == 0)
		driver_save(true);
	else if (strcmp(line, "end") == 0) {
		printf("end\n");
		fflush(stdout);
	} else
		driver_fail("unknown command");
}

int
main(void)
{
	char line[DRIVER_LINE];

	driver_setup();
	while (driver_line(line))
		driver_command(line);
	return (0);
}
