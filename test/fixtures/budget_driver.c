/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the budget core (kernel/core/budget.c). It plays the
 * core's host: it provides the lock effects, checking that every chain is
 * locked descendant first and released whole, and it stands in for the
 * page core (a free count and a released count), the record cache (one
 * cache page per child budget's record, charged to the parent's cache
 * reserve) and the lists of charged objects that a destroy walks. It reads
 * one command per line from the file named by its argument and prints,
 * for each, the status and effects and then the whole state, which
 * test/fixtures/budget_model.rb predicts independently:
 *
*   root N                  the root budget of N pages: a new machine
*   carve P K G C           carve a child of P, kind K (1 wall, 2 elastic)
*   resize B G C            set B's guarantee and cap
*   destroy B               close B, then walk its tree
*   reserve B               a reserve on B's list
*   charge R N [CLOSE]      admit N and back them; the owner closes
*                           before part CLOSE when it is given
*   take R                  one pooled page into use
*   release R USED POOLED   release pages in use and pooled
*   adjust B N              charge (or refund, N < 0) B directly
*   pin B N                 pin N pages held in B's tree
*   watch B I T             arm B's watch on IRQ object I at T
*   unwatch B               disarm B's watch
*   detach B I              detach IRQ object I from B's watch
*   reap                    free every released page
*   put                     one round of tombstone puts
*   state                   print the state alone
*   race SEED ITERATIONS    four threads charge and release at random
*   arith                   the edges of the checked arithmetic
 */

#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "budget_impl.h"

#define BUDGETS_MAX	64
#define RESERVES_MAX	256
#define ENTRIES_MAX	64
#define IRQS_MAX	16
#define PART_PAGES	64
#define RACE_THREADS	4

struct erx_irq {
	int	id;
};

typedef struct entry {
	int	is_budget;
	int	id;
} entry_t;

typedef struct budget_slot {
	erx_budget_t	 budget;
	erx_reserve_t	 cache;		/* the budget's cache pages */
	pthread_mutex_t	 lock;
	int		 exists;	/* carved and its record not yet put */
	int		 nentries;	/* its list of charged objects */
	entry_t		 entries[ENTRIES_MAX];
} budget_slot_t;

typedef struct reserve_slot {
	erx_reserve_t	 reserve;
	pthread_mutex_t	 lock;		/* the owner's lock */
	int		 exists;
	int		 budget;
} reserve_slot_t;

typedef struct report {
	char	text[2048];
	size_t	length;
	int	refused;
} report_t;

static budget_slot_t budgets[BUDGETS_MAX];
static reserve_slot_t reserves[RESERVES_MAX];
static struct erx_irq irqs[IRQS_MAX];
static int nbudgets;
static int nreserves;
static int pending[BUDGETS_MAX];	/* tombstones whose put is due */
static int npending;
static erx_npages_t free_pages;
static erx_npages_t released_pages;
static pthread_mutex_t pages_lock = PTHREAD_MUTEX_INITIALIZER;

/* The locks this thread holds, innermost last. */
static _Thread_local erx_budget_t *held[ERX_BUDGET_DEPTH_MAX + 1];
static _Thread_local int nheld;

static void
fail(const char *what)
{
	fprintf(stderr, "budget_driver: %s\n", what);
	exit(1);
}

static int
budget_id(const erx_budget_t *budget)
{
	const budget_slot_t *slot;

	slot = (const budget_slot_t *)(const void *)budget;
	if (slot < budgets || slot >= budgets + BUDGETS_MAX)
		fail("a budget outside the driver's table");
	return ((int)(slot - budgets));
}

void
erx_effect_budget_lock(erx_budget_t *budget)
{
	int i;

	for (i = 0; i < nheld; i++)
		if (held[i] == budget)
			fail("lock order: a budget locked twice");
	if (nheld > 0 && erx_budget_parent(held[nheld - 1]) != budget)
		fail("lock order: a lock that is not the parent of the last");
	if (nheld == ERX_BUDGET_DEPTH_MAX + 1)
		fail("lock order: more locks than a chain has budgets");
	if (pthread_mutex_lock(&budgets[budget_id(budget)].lock) != 0)
		fail("mutex");
	held[nheld++] = budget;
}

void
erx_effect_budget_unlock(erx_budget_t *budget)
{
	int i;

	for (i = 0; i < nheld && held[i] != budget; i++)
		continue;
	if (i == nheld)
		fail("unlock of a budget not locked");
	for (; i + 1 < nheld; i++)
		held[i] = held[i + 1];
	nheld--;
	if (pthread_mutex_unlock(&budgets[budget_id(budget)].lock) != 0)
		fail("mutex");
}

static void
say(report_t *report, const char *format, ...)
    __attribute__((__format__(__printf__, 2, 3)));

static void
say(report_t *report, const char *format, ...)
{
	va_list arguments;
	int n;

	va_start(arguments, format);
	n = vsnprintf(report->text + report->length,
	    sizeof(report->text) - report->length, format, arguments);
	va_end(arguments);
	if (n < 0 || (size_t)n >= sizeof(report->text) - report->length)
		fail("report overflow");
	report->length += (size_t)n;
}

/* Records an operation's effects; tombstones join the put queue. */
static void
collect(report_t *report, const erx_budget_effects_t *effects)
{
	uint32_t i;

	for (i = 0; i < effects->nfire; i++)
		say(report, " fire=%d", effects->fire[i]->id);
	for (i = 0; i < effects->nfirst_pin; i++)
		say(report, " pin=%d", budget_id(effects->first_pin[i]));
	for (i = 0; i < effects->ntombstone; i++) {
		say(report, " tomb=%d", budget_id(effects->tombstone[i]));
		if (npending == BUDGETS_MAX)
			fail("a tombstone reported twice");
		pending[npending++] = budget_id(effects->tombstone[i]);
	}
	if (effects->refused != NULL)
		report->refused = budget_id(effects->refused);
}

static void
print_state(const char *tag)
{
	erx_budget_counters_t c;
	erx_reserve_counts_t r;
	int i;

	printf("%s free=%" PRIu64 " rel=%" PRIu64, tag, free_pages,
	    released_pages);
	for (i = 0; i < nbudgets; i++) {
		if (!budgets[i].exists)
			continue;
		erx_budget_read(&budgets[i].budget, &c);
		erx_reserve_read(&budgets[i].cache, &r);
		printf(" b%d:%u,%u,%d,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%"
		    PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64,
		    i, c.kind, c.depth, c.dead ? 1 : 0, c.guarantee, c.cap,
		    c.used, c.carved, c.lent, c.pinned, c.threshold,
		    r.charged);
	}
	for (i = 0; i < nreserves; i++) {
		if (!reserves[i].exists)
			continue;
		erx_reserve_read(&reserves[i].reserve, &r);
		printf(" r%d:%d,%" PRIu64 ",%" PRIu64 ",%" PRIu64, i,
		    reserves[i].budget, r.charged, r.backed, r.pooled);
	}
	printf("\n");
}

/* The page core's stand-in: take free pages first, then released ones. */
static void
take_pages(erx_npages_t pages)
{
	erx_npages_t from_free;

	pthread_mutex_lock(&pages_lock);
	if (pages > free_pages + released_pages)
		fail("identity: a backing found neither a free nor a released page");
	from_free = pages < free_pages ? pages : free_pages;
	free_pages -= from_free;
	released_pages -= pages - from_free;
	pthread_mutex_unlock(&pages_lock);
}

static void
release_pages(erx_npages_t pages)
{
	pthread_mutex_lock(&pages_lock);
	released_pages += pages;
	pthread_mutex_unlock(&pages_lock);
}

/*
 * erx_reserve_charge's composition: admit, then back in parts of 64; an
 * owner closed before part close_at cancels what is still unbacked.
 */
static int
charge(erx_reserve_t *reserve, erx_npages_t pages, long close_at,
    report_t *report)
{
	erx_budget_effects_t effects;
	erx_npages_t done, part;
	long index;
	int error;

	error = erx_reserve_admit(reserve, pages, &effects);
	collect(report, &effects);
	if (error != 0)
		return (error);
	for (done = 0, index = 0; done < pages; done += part, index++) {
		if (index == close_at) {
			error = erx_reserve_cancel(reserve, pages - done,
			    &effects);
			collect(report, &effects);
			if (error != 0)
				fail("cancel refused");
			return (ERX_ESTALE);
		}
		part = pages - done < PART_PAGES ? pages - done : PART_PAGES;
		take_pages(part);
		if (erx_reserve_fill(reserve, part) != 0)
			fail("fill refused");
	}
	return (0);
}

static int
release(erx_reserve_t *reserve, erx_npages_t in_use, erx_npages_t pooled,
    report_t *report)
{
	erx_budget_effects_t effects;
	int error;

	error = erx_reserve_refund(reserve, in_use, pooled, &effects);
	collect(report, &effects);
	if (error == 0)
		release_pages(in_use + pooled);
	return (error);
}

static int
valid_budget(long id)
{
	return (id >= 0 && id < nbudgets && budgets[id].exists);
}

static int
valid_reserve(long id)
{
	return (id >= 0 && id < nreserves && reserves[id].exists);
}

static void
list_append(int budget, int is_budget, int id)
{
	budget_slot_t *slot;

	slot = &budgets[budget];
	if (slot->nentries == ENTRIES_MAX)
		fail("list full");
	slot->entries[slot->nentries++] = (entry_t){ is_budget, id };
}

static void
list_remove_head(int budget)
{
	budget_slot_t *slot;

	slot = &budgets[budget];
	memmove(&slot->entries[0], &slot->entries[1],
	    (size_t)(slot->nentries - 1) * sizeof(slot->entries[0]));
	slot->nentries--;
}

/* A destroyed budget leaves its parent's list as its deletion ends. */
static void
list_remove_budget(int budget, int id)
{
	budget_slot_t *slot;
	int i;

	slot = &budgets[budget];
	for (i = 0; i < slot->nentries; i++) {
		if (slot->entries[i].is_budget && slot->entries[i].id == id) {
			memmove(&slot->entries[i], &slot->entries[i + 1],
			    (size_t)(slot->nentries - i - 1) *
			    sizeof(slot->entries[0]));
			slot->nentries--;
			return;
		}
	}
	fail("a destroyed budget on no list");
}

static void
new_budget_slot(int id)
{
	budget_slot_t *slot;

	slot = &budgets[id];
	slot->exists = 1;
	slot->nentries = 0;
	erx_reserve_init(&slot->cache, &slot->budget);
}

/* The carve's composition: the record's cache page, then the guarantee. */
static int
carve(long parent, long kind, erx_npages_t guarantee, erx_npages_t cap,
    report_t *report)
{
	erx_budget_effects_t effects;
	erx_reserve_t *cache;
	int error, id;

	if (nbudgets == BUDGETS_MAX)
		fail("too many budgets");
	cache = &budgets[parent].cache;
	error = charge(cache, 1, -1, report);
	if (error != 0)
		return (error);
	if (erx_reserve_use(cache) != 0)
		fail("cache use refused");
	id = nbudgets;
	error = erx_budget_carve(&budgets[parent].budget, &budgets[id].budget,
	    (erx_budget_kind_t)kind, guarantee, cap, &effects);
	collect(report, &effects);
	if (error != 0) {
		if (release(cache, 1, 0, report) != 0)
			fail("cache refund refused");
		return (error);
	}
	nbudgets++;
	new_budget_slot(id);
	list_append((int)parent, 1, id);
	say(report, " id=%d", id);
	return (0);
}

static void
destroy_head_reserve(int budget, int id, report_t *report)
{
	erx_reserve_counts_t counts;
	erx_reserve_t *reserve;

	reserve = &reserves[id].reserve;
	erx_reserve_read(reserve, &counts);
	if (release(reserve, counts.backed - counts.pooled, counts.pooled,
	    report) != 0)
		fail("teardown refund refused");
	reserves[id].exists = 0;
	list_remove_head(budget);
}

/* The destroy: close, then the iterative walk, printing each step. */
static int
destroy(long top, report_t *report)
{
	erx_budget_effects_t effects;
	erx_budget_walk_t walk;
	erx_budget_head_t head;
	budget_slot_t *slot;
	int cursor, error;

	error = erx_budget_close(&budgets[top].budget, &effects);
	collect(report, &effects);
	if (error != 0)
		return (error);
	erx_budget_walk_begin(&walk, &budgets[top].budget);
	for (;;) {
		cursor = budget_id(walk.cursor);
		slot = &budgets[cursor];
		head = slot->nentries == 0 ? ERX_BUDGET_HEAD_EMPTY :
		    slot->entries[0].is_budget ? ERX_BUDGET_HEAD_BUDGET :
		    ERX_BUDGET_HEAD_OBJECT;
		switch (erx_budget_walk_next(&walk, head, head ==
		    ERX_BUDGET_HEAD_BUDGET ?
		    &budgets[slot->entries[0].id].budget : NULL)) {
		case ERX_BUDGET_WALK_DESTROY:
			destroy_head_reserve(cursor, slot->entries[0].id,
			    report);
			break;
		case ERX_BUDGET_WALK_ENTER:
			if (erx_budget_close(walk.subject, &effects) != 0)
				fail("close of a doomed budget refused");
			collect(report, &effects);
			break;
		case ERX_BUDGET_WALK_LEAVE:
			if (budget_id(walk.cursor) !=
			    budget_id(erx_budget_parent(walk.subject)))
				fail("walk left to a budget other than the parent");
			list_remove_head(budget_id(walk.cursor));
			break;
		case ERX_BUDGET_WALK_INVALID:
			fail("the walk refused its list");
			break;
		case ERX_BUDGET_WALK_DONE:
			list_remove_budget(budget_id(erx_budget_parent(
			    walk.top)), (int)top);
			return (0);
		}
		print_state("W");
	}
}

/* One round of puts: each due record frees its page in its parent's cache. */
static void
put_round(report_t *report)
{
	int due[BUDGETS_MAX];
	int i, n, parent;

	n = npending;
	memcpy(due, pending, sizeof(due[0]) * (size_t)n);
	npending = 0;
	for (i = 0; i < n; i++) {
		parent = budget_id(erx_budget_parent(&budgets[due[i]].budget));
		budgets[due[i]].exists = 0;
		say(report, " freed=%d", due[i]);
		if (release(&budgets[parent].cache, 1, 0, report) != 0)
			fail("record cache refund refused");
	}
}

typedef struct race_thread {
	pthread_t	 thread;
	unsigned int	 seed;
	long		 iterations;
} race_thread_t;

static unsigned int
next_random(unsigned int *state)
{
	*state = *state * 1103515245u + 12345u;
	return (*state >> 8);
}

/* Charges and releases at random reserves, under each owner's lock. */
static void *
race_body(void *argument)
{
	erx_reserve_counts_t counts;
	race_thread_t *self;
	reserve_slot_t *slot;
	report_t report;
	long i;

	self = argument;
	for (i = 0; i < self->iterations; i++) {
		slot = &reserves[next_random(&self->seed) % (unsigned)nreserves];
		if (!slot->exists)
			continue;
		report.length = 0;
		pthread_mutex_lock(&slot->lock);
		if (next_random(&self->seed) % 2 == 0) {
			(void)charge(&slot->reserve,
			    1 + next_random(&self->seed) % 8, -1, &report);
		} else {
			erx_reserve_read(&slot->reserve, &counts);
			if (counts.backed > 0)
				(void)release(&slot->reserve, 0, counts.pooled,
				    &report);
		}
		pthread_mutex_unlock(&slot->lock);
		if (nheld != 0)
			fail("a lock held after an operation");
	}
	return (NULL);
}

static void
race(unsigned int seed, long iterations)
{
	race_thread_t threads[RACE_THREADS];
	int i;

	for (i = 0; i < RACE_THREADS; i++) {
		threads[i] = (race_thread_t){ .seed = seed + (unsigned)i,
		    .iterations = iterations };
		if (pthread_create(&threads[i].thread, NULL, race_body,
		    &threads[i]) != 0)
			fail("pthread_create");
	}
	for (i = 0; i < RACE_THREADS; i++)
		pthread_join(threads[i].thread, NULL);
}

/*
 * The checked arithmetic at its edges, on a root of every page a 64-bit
 * count can name: each status is printed, and every counter must be
 * unchanged by a refusal.
 */
static void
arith(report_t *report)
{
	erx_budget_effects_t effects;
	erx_budget_counters_t before, after;
	erx_budget_t *root, *child;

	root = &budgets[0].budget;
	child = &budgets[1].budget;
	say(report, " root=%d", erx_budget_init_root(root,
	    (erx_npages_t)INT64_MAX + 1));
	if (erx_budget_init_root(root, INT64_MAX) != 0)
		fail("the largest root refused");
	say(report, " carve=%d", erx_budget_carve(root, child,
	    ERX_BUDGET_ELASTIC, (erx_npages_t)INT64_MAX + 1, UINT64_MAX,
	    &effects));
	say(report, " carve=%d", erx_budget_carve(root, child,
	    ERX_BUDGET_ELASTIC, INT64_MAX, UINT64_MAX, &effects));
	erx_budget_read(root, &before);
	say(report, " full=%d", erx_budget_adjust(root, 1, &effects));
	say(report, " min=%d", erx_budget_adjust(child, INT64_MIN, &effects));
	say(report, " below=%d", erx_budget_adjust(child, -1, &effects));
	say(report, " pin=%d", erx_budget_pin(child,
	    (erx_npages_t)INT64_MAX + 1, &effects));
	say(report, " within=%d", erx_budget_adjust(child, INT64_MAX,
	    &effects));
	say(report, " borrow=%d", erx_budget_adjust(child, 1, &effects));
	erx_budget_read(root, &after);
	say(report, " unchanged=%d", before.used == after.used &&
	    before.carved == after.carved && before.lent == after.lent &&
	    before.pinned == after.pinned ? 1 : 0);
	say(report, " grow=%d", erx_budget_resize(child, UINT64_MAX,
	    UINT64_MAX, &effects));
	nbudgets = 0;
}

static int
command(char *line, report_t *report)
{
	erx_budget_effects_t effects;
	char name[16];
	long a, b, c, d;
	bool fire;
	int n, error;

	a = b = c = 0;
	d = -1;
	n = sscanf(line, "%15s %ld %ld %ld %ld", name, &a, &b, &c, &d);
	if (n < 1)
		fail("empty command");
	if (strcmp(name, "arith") == 0) {
		arith(report);
		return (0);
	}
	if (strcmp(name, "root") == 0) {
		/* A new root starts a new machine. */
		for (n = 0; n < nbudgets; n++)
			budgets[n].exists = 0;
		nreserves = 0;
		npending = 0;
		released_pages = 0;
		if (erx_budget_init_root(&budgets[0].budget,
		    (erx_npages_t)a) != 0)
			fail("root refused");
		new_budget_slot(0);
		nbudgets = 1;
		free_pages = (erx_npages_t)a;
		return (0);
	}
	if (strcmp(name, "reap") == 0) {
		free_pages += released_pages;
		released_pages = 0;
		return (0);
	}
	if (strcmp(name, "put") == 0) {
		put_round(report);
		return (0);
	}
	if (strcmp(name, "state") == 0)
		return (0);
	if (strcmp(name, "race") == 0) {
		race((unsigned int)a, b);
		return (0);
	}
	if (strcmp(name, "take") == 0 || strcmp(name, "release") == 0 ||
	    strcmp(name, "charge") == 0) {
		if (!valid_reserve(a))
			fail("no such reserve");
		if (name[0] == 't')
			return (erx_reserve_use(&reserves[a].reserve));
		if (name[0] == 'r')
			return (release(&reserves[a].reserve, (erx_npages_t)b,
			    (erx_npages_t)c, report));
		return (charge(&reserves[a].reserve, (erx_npages_t)b,
		    n == 4 ? c : -1, report));
	}
	if (!valid_budget(a))
		fail("no such budget");
	if (strcmp(name, "carve") == 0)
		return (carve(a, b, (erx_npages_t)c, (erx_npages_t)d, report));
	if (strcmp(name, "resize") == 0) {
		error = erx_budget_resize(&budgets[a].budget, (erx_npages_t)b,
		    (erx_npages_t)c, &effects);
		collect(report, &effects);
		return (error);
	}
	if (strcmp(name, "destroy") == 0)
		return (destroy(a, report));
	if (strcmp(name, "reserve") == 0) {
		erx_budget_counters_t counters;

		/* The list's insert function refuses a dead budget. */
		erx_budget_read(&budgets[a].budget, &counters);
		if (counters.dead)
			return (ERX_ESTALE);
		if (nreserves == RESERVES_MAX)
			fail("too many reserves");
		reserves[nreserves].exists = 1;
		reserves[nreserves].budget = (int)a;
		pthread_mutex_init(&reserves[nreserves].lock, NULL);
		erx_reserve_init(&reserves[nreserves].reserve,
		    &budgets[a].budget);
		list_append((int)a, 0, nreserves);
		say(report, " id=%d", nreserves);
		nreserves++;
		return (0);
	}
	if (strcmp(name, "pin") == 0) {
		error = erx_budget_pin(&budgets[a].budget, (erx_npages_t)b,
		    &effects);
		collect(report, &effects);
		return (error);
	}
	if (strcmp(name, "adjust") == 0) {
		error = erx_budget_adjust(&budgets[a].budget, b, &effects);
		collect(report, &effects);
		return (error);
	}
	if (strcmp(name, "watch") == 0 || strcmp(name, "unwatch") == 0) {
		if (b < 0 || b >= IRQS_MAX)
			fail("no such IRQ object");
		error = erx_budget_watch(&budgets[a].budget,
		    name[0] == 'w' ? &irqs[b] : NULL, (erx_npages_t)c, &fire);
		if (fire)
			say(report, " fire=%ld", b);
		return (error);
	}
	if (strcmp(name, "detach") == 0) {
		if (b < 0 || b >= IRQS_MAX)
			fail("no such IRQ object");
		say(report, " detached=%d",
		    erx_budget_watch_detach(&budgets[a].budget, &irqs[b]) ? 1 : 0);
		return (0);
	}
	fail("unknown command");
	return (0);
}

int
main(int argc, char **argv)
{
	char line[256];
	report_t report;
	FILE *input;
	int i, status;

	if (argc != 2)
		fail("usage: budget_driver COMMANDS");
	input = fopen(argv[1], "r");
	if (input == NULL)
		fail(strerror(errno));
	for (i = 0; i < BUDGETS_MAX; i++)
		pthread_mutex_init(&budgets[i].lock, NULL);
	for (i = 0; i < IRQS_MAX; i++)
		irqs[i].id = i;
	while (fgets(line, sizeof(line), input) != NULL) {
		report.length = 0;
		report.text[0] = '\0';
		report.refused = -1;
		status = command(line, &report);
		if (nheld != 0)
			fail("a lock held after a command");
		printf("= %d%s", status, report.text);
		if (report.refused >= 0 && status == ERX_ENOMEM)
			printf(" refused=%d", report.refused);
		printf("\n");
		print_state("S");
	}
	fclose(input);
	return (0);
}
