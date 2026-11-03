/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs the capability core over commands on standard input and prints
 * every result, so the host test's model can judge it. Two tables, 0 and
 * 1, each with a directory of DRIVER_PAGES pages; T names one. Numbers
 * are hexadecimal.
 *
 *   table T LIMIT              reset T: an empty table of LIMIT slots
 *   grow T N                   add the pages for N free slots
 *   seed T SLOT GEN SEQ        set a free slot's generation and count
 *   install T OBJECT TYPE RIGHTS
 *   clear T VALUE OBJECT
 *   read T VALUE TYPE REQUIRED
 *   reserve T N                T's one reservation takes N slots
 *   release T
 *   empty T
 *   dump T                     every slot, then the free list
 *   rights KIND                erx_rights_create
 *   shrink RIGHTS MASK         erx_rights_shrink
 *   pass FROM TO FROM_OWN TO_CREATED N [RACE], then N lines
 *     item VALUE OP MASK TYPE REQUIRED
 *                              read, plan and apply a pass into TO's
 *                              reservation; RACE 1 clears the first
 *                              source and RACE 2 releases the
 *                              reservation between plan and apply
 *   plan FROM_OWN TO_CREATED ROOM N, then N lines
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
#include "cap_impl.h"
#include "cap_slot_impl.h"

#define DRIVER_PAGES	4
#define DRIVER_LINE	256

typedef struct driver_table {
	erx_cap_table_t		 table;
	_Atomic(erx_cap_slot_t *) dir[DRIVER_PAGES];
	erx_cap_slot_t		*pages[DRIVER_PAGES];
	uint32_t		 npages;
	erx_cap_reservation_t	 reservation;
} driver_table_t;

static driver_table_t	 tables[2];
static driver_table_t	 saved[2];
static erx_cap_slot_t	 saved_slots[2][DRIVER_PAGES][ERX_CAP_PAGE_SLOTS];
static unsigned long	 lineno;

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
}

/*
 * A table's state is its struct, its reservation and its slots; the
 * directory and the page pointers stay, so a restore needs the pages the
 * save saw. Slots are copied as bytes: the driver has no reader running.
 */
static void
driver_save(bool restore)
{
	driver_table_t *from, *to;
	uint32_t t, p;

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
	unsigned fid, tid, own, created, n, i, race = 0;
	erx_status_t status;

	if (sscanf(line, "pass %x %x %x %x %x %x", &fid, &tid, &own, &created,
	    &n, &race) < 5 || n > ERX_MSG_CAPS)
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
		sources[i].status = erx_cap_read(&from->table, items[i].cap,
		    ERX_CAP_ANY_TYPE, 0, &sources[i].view);
	}
	request.items = items;
	request.count = n;
	request.room = to->reservation.count;
	request.from_own = own != 0;
	request.to_created = created != 0;
	status = erx_pass_plan(&request, sources, &plan);
	driver_print_plan(status, &plan);
	if (status != ERX_OK)
		return;
	if (race == 1 && plan.count > 0)
		(void)erx_cap_slot_clear(&from->table, items[0].cap,
		    plan.steps[0].object);
	if (race == 2)
		erx_cap_release_reservation(&to->table, &to->reservation);
	status = erx_pass_take(&plan, &from->table, &to->reservation);
	printf("take %d\n", status);
	if (status != ERX_OK)
		return;
	status = erx_pass_install(&plan, &to->table, &to->reservation,
	    results);
	printf("install %d\n", status);
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
	unsigned own, created, room, n, i;
	int status;

	if (sscanf(line, "plan %x %x %x %x", &own, &created, &room, &n) != 4 ||
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
	request.from_own = own != 0;
	request.to_created = created != 0;
	driver_print_plan(erx_pass_plan(&request, sources, &plan), &plan);
}

static void
driver_command(const char *line)
{
	erx_cap_view_t view;
	erx_cap_t cap;
	erx_rights_t rights;
	uint64_t a, b, c;
	uint32_t x, y;
	unsigned t;
	erx_status_t status;

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
		rights.bits = y;	/* a test's forged value: K2 binds the kernel */
		cap.raw = 0;
		status = erx_cap_install(&driver_table(t)->table, a, x, rights,
		    &cap);
		printf("install %d %" PRIx64 "\n", status, cap.raw);
	} else if (sscanf(line, "clear %x %" SCNx64 " %" SCNx64, &t, &a,
	    &b) == 3) {
		cap.raw = a;
		printf("clear %d\n", erx_cap_slot_clear(&driver_table(t)->table,
		    cap, b));
	} else if (sscanf(line, "read %x %" SCNx64 " %" SCNx32 " %" SCNx64, &t,
	    &a, &x, &c) == 4) {
		cap.raw = a;
		memset(&view, 0, sizeof(view));
		status = erx_cap_read(&driver_table(t)->table, cap, x,
		    (uint32_t)c, &view);
		printf("read %d %" PRIx64 " %" PRIx32 " %" PRIx32 " %" PRIx32
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

	while (driver_line(line))
		driver_command(line);
	return (0);
}
