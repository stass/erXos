/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the budget core (kernel/core/budget.c). It plays the
 * core's host: it provides the lock effects, checking that every chain is
 * locked descendant first and released whole, and it stands in for the
 * page core (a free count and a released count, and the memory of the
 * cache pages the core's record cache asks for). Each reserve stands in
 * for an object that holds it: a record of an object header and the
 * reserve, on its budget's real list of charged objects, which a destroy
 * walks through the deletion core's budget-death walk. Every child
 * budget's record comes from its parent's record cache, and its put frees
 * it there. It reads
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
*   race SEED ITERATIONS    four threads race: two charge and release at
*                           random, one carves, charges, resizes and
*                           destroys budgets, one resizes the others
*   arith                   the edges of the checked arithmetic
 */

#include <errno.h>
#include <stdalign.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "budget_impl.h"
#include "erx/attach.h"
#include "erx/delete.h"

#define BUDGETS_MAX	64
#define RESERVES_MAX	256
#define IRQS_MAX	16
#define PART_PAGES	64
#define RACE_THREADS	4
/* The slot the race's carves reuse, one budget at a time. */
#define RACE_SLOT	(BUDGETS_MAX - 1)
#define CACHE_PAGES_MAX	64

struct erx_irq {
	int	id;
};

typedef struct budget_slot {
	erx_budget_t	*budget;	/* in its parent's cache; the root's is
					 * root_record */
	pthread_mutex_t	 lock;
	int		 exists;	/* carved and its record not yet put */
} budget_slot_t;

/* An object holding a reserve: its header area, then the reserve. */
typedef struct reserve_slot {
	alignas(64) unsigned char header[ERX_OBJECT_HEADER_BYTES];
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
static erx_budget_t root_record;
static alignas(64) unsigned char store_record[64];
#define store	(*(erx_object_store_t *)(void *)store_record)
static alignas(ERX_KCACHE_PAGE_BYTES) unsigned char
    cache_pages[CACHE_PAGES_MAX][ERX_KCACHE_PAGE_BYTES];
static bool cache_page_used[CACHE_PAGES_MAX];
static reserve_slot_t reserves[RESERVES_MAX];
static struct erx_irq irqs[IRQS_MAX];
static int nbudgets;
static int nreserves;
static int pending[BUDGETS_MAX];	/* tombstones whose put is due */
static int npending;
static erx_npages_t free_pages;
static erx_npages_t released_pages;
static pthread_mutex_t pages_lock = PTHREAD_MUTEX_INITIALIZER;
/* The budget table: a race's carve and free write a slot others look up. */
static pthread_rwlock_t table_lock = PTHREAD_RWLOCK_INITIALIZER;
/*
 * What each budget may spend at the end of the race: its cap, or, after a
 * resize that left its spending above the cap, that spending, since every
 * rise is refused until the spending falls below the cap.
 */
static erx_npages_t race_bound[BUDGETS_MAX];
/* What the race's carver and resizer did, each written by its one thread. */
static long race_carves;
static long race_resizes;

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
	int i, id = -1;

	pthread_rwlock_rdlock(&table_lock);
	for (i = 0; i < BUDGETS_MAX && id < 0; i++)
		if (budgets[i].exists && budgets[i].budget == budget)
			id = i;
	pthread_rwlock_unlock(&table_lock);
	if (id < 0)
		fail("a budget outside the driver's table");
	return (id);
}

/* Memory for one cache page, as the page allocator would hand it out. */
static void *
cache_page_get(void)
{
	int i;

	for (i = 0; i < CACHE_PAGES_MAX; i++) {
		if (!cache_page_used[i]) {
			cache_page_used[i] = true;
			return (cache_pages[i]);
		}
	}
	fail("out of cache page memory");
	return (NULL);
}

static void
cache_page_put(void *page)
{
	cache_page_used[((unsigned char *)page - cache_pages[0]) /
	    ERX_KCACHE_PAGE_BYTES] = false;
}

/* The driver passes no preemption point: every borrowed reference holds. */
uint32_t
erx_effect_thread_epoch(void)
{
	return (0);
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
	erx_budget_t *parent;
	int i;

	printf("%s free=%" PRIu64 " rel=%" PRIu64, tag, free_pages,
	    released_pages);
	for (i = 0; i < nbudgets; i++) {
		if (!budgets[i].exists)
			continue;
		erx_budget_read(budgets[i].budget, &c);
		parent = erx_budget_parent(budgets[i].budget);
		printf(" b%d:%u,%u,%d,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%"
		    PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64
		    ",%d",
		    i, c.kind, c.depth, c.dead ? 1 : 0, c.guarantee, c.cap,
		    c.used, c.carved, c.lent, c.pinned, c.threshold,
		    budgets[i].budget->caches[ERX_KCACHE_BUDGET].npages,
		    parent == NULL ? -1 : budget_id(parent));
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
new_budget_slot(int id, erx_budget_t *budget)
{
	budget_slot_t *slot;

	pthread_rwlock_wrlock(&table_lock);
	slot = &budgets[id];
	slot->budget = budget;
	slot->exists = 1;
	pthread_rwlock_unlock(&table_lock);
}

/* A page the cache gave back goes to the released pages. */
static void
cache_page_released(void *page)
{
	if (page != NULL) {
		cache_page_put(page);
		release_pages(1);
	}
}

/*
 * Puts obj on its budget's list through the list's insert, under the
 * budget's lock, as a creation does once it has charged the record.
 */
static int
join_budget(erx_object_t *obj, erx_ktype_t type, erx_budget_t *budget)
{
	int error;

	if (erx_object_init(&store, obj, type, budget) != ERX_OK)
		fail("object init refused");
	erx_effect_budget_lock(budget);
	error = erx_attach_budget_charged(obj);
	erx_effect_budget_unlock(budget);
	return (error);
}

/*
 * The carve into slot id: one plan of the record's page and the
 * guarantee, then the child's object header, on the parent's list.
 */
static int
carve(long parent, long kind, erx_npages_t guarantee, erx_npages_t cap,
    int id, report_t *report)
{
	erx_budget_effects_t effects;
	erx_budget_t *child;
	void *page;
	bool taken;
	int error;

	page = cache_page_get();
	error = erx_budget_carve(budgets[parent].budget, page,
	    (erx_budget_kind_t)kind, guarantee, cap, &child, &taken, &effects);
	collect(report, &effects);
	if (taken)
		take_pages(1);
	else
		cache_page_put(page);
	if (error != 0)
		return (error);
	new_budget_slot(id, child);
	if (join_budget(erx_object_of(child), ERX_K_BUDGET,
	    budgets[parent].budget) != ERX_OK)
		fail("a live parent refused its child");
	/* The reference the child's counters hold, which its tombstone puts. */
	(void)erx_object_ref(erx_uref_make(erx_object_of(child)));
	say(report, " id=%d", id);
	return (0);
}

static int
reserve_id(const erx_object_t *obj)
{
	int i;

	for (i = 0; i < nreserves; i++)
		if (reserves[i].exists &&
		    (const void *)reserves[i].header == (const void *)obj)
			return (i);
	fail("an object outside the driver's table");
	return (-1);
}

/*
 * A dead child budget's record is freed at its object's last put, which
 * is the one release event: the object's own reference, the references
 * the walk and the destroyer hold, and the one its counters hold until
 * the tombstone's put each end in it.
 */
static void
put_object(erx_object_t *obj, report_t *report)
{
	erx_budget_effects_t effects;
	void *page;
	int id;

	if (!erx_object_put(obj) || erx_object_type(obj) != ERX_K_BUDGET)
		return;
	id = budget_id(erx_object_body(obj));
	say(report, " freed=%d", id);
	if (erx_budget_free_record(budgets[id].budget, &page, &effects) != 0)
		fail("record free refused");
	pthread_rwlock_wrlock(&table_lock);
	budgets[id].exists = 0;
	pthread_rwlock_unlock(&table_lock);
	collect(report, &effects);
	cache_page_released(page);
}

/*
 * One destroy, as a deletion runs it, with nothing else racing: the close,
 * the drain (the object leaves its budget's list), and the teardown. An
 * object holding a reserve releases its pages at its dead budget; a
 * budget's object holds no capability, so its teardown is empty. The
 * driver frees no record, so the put of the object's own reference is
 * made at once. Returns whether this destroy went on past the close.
 */
static bool
destroy_object(erx_delete_t *destroy, report_t *report)
{
	erx_reserve_counts_t counts;
	erx_reserve_t *reserve;
	erx_object_t *obj = destroy->object;
	int id;

	for (;;) {
		switch (erx_delete_step(destroy).action) {
		case ERX_DELETE_STOP:
			return (false);
		case ERX_DELETE_DRAIN:
			erx_delete_uncharge(obj);
			break;
		case ERX_DELETE_CLEAR:
			fail("a driver object named by a slot");
			break;
		case ERX_DELETE_PUT:
			if (erx_object_type(obj) != ERX_K_BUDGET) {
				id = reserve_id(obj);
				reserve = &reserves[id].reserve;
				erx_reserve_read(reserve, &counts);
				if (release(reserve, counts.backed -
				    counts.pooled, counts.pooled, report) != 0)
					fail("teardown refund refused");
				reserves[id].exists = 0;
			}
			put_object(obj, report);
			return (true);
		}
	}
}

/*
 * The destroy of a budget: its own object's destroy, its close, then the
 * budget-death walk over its tree, printing the state after each object
 * destroyed, each child closed, and each climb from a child.
 */
static int
destroy(long top, report_t *report)
{
	erx_budget_effects_t effects;
	erx_delete_budget_walk_t walk;
	erx_delete_t own;
	erx_object_t *obj;
	bool budget;
	int error;

	if (top == 0)
		return (erx_budget_close(budgets[0].budget, &effects));
	/* The lookup that names the budget refuses a closed object. */
	obj = erx_object_of(budgets[top].budget);
	if (erx_object_state(obj) != ERX_OBJ_LIVE)
		return (ERX_ESTALE);
	obj = erx_object_ref(erx_uref_make(obj));
	erx_delete_begin(&own, obj);
	if (!destroy_object(&own, report)) {
		put_object(obj, report);
		return (ERX_ESTALE);
	}
	error = erx_budget_close(budgets[top].budget, &effects);
	collect(report, &effects);
	if (error != 0)
		fail("the close of a budget whose destroy went on refused");
	erx_delete_budget_walk_begin(&walk, budgets[top].budget);
	for (;;) {
		switch (erx_delete_budget_walk_next(&walk, &effects)) {
		case ERX_DELETE_BUDGET_WALK_DESTROY:
			budget = erx_object_type(walk.destroy.object) ==
			    ERX_K_BUDGET;
			(void)destroy_object(&walk.destroy, report);
			if (budget)
				continue;
			break;
		case ERX_DELETE_BUDGET_WALK_CLOSED:
			collect(report, &effects);
			break;
		case ERX_DELETE_BUDGET_WALK_PUT:
			budget = erx_object_type(walk.put) == ERX_K_BUDGET;
			put_object(walk.put, report);
			if (!budget)
				continue;
			break;
		case ERX_DELETE_BUDGET_WALK_DONE:
			put_object(obj, report);
			return (0);
		}
		print_state("W");
	}
}

/* One round of tombstone puts: each drops the reference of its counters. */
static void
put_round(report_t *report)
{
	int due[BUDGETS_MAX];
	int i, n;

	n = npending;
	memcpy(due, pending, sizeof(due[0]) * (size_t)n);
	npending = 0;
	for (i = 0; i < n; i++)
		put_object(erx_object_of(budgets[due[i]].budget), report);
}

typedef enum race_role {
	RACE_CHARGE,		/* charges and releases at random reserves */
	RACE_CARVE,		/* carves, charges, resizes and destroys */
	RACE_RESIZE		/* resizes the script's budgets */
} race_role_t;

static const race_role_t race_roles[RACE_THREADS] = {
	RACE_CHARGE, RACE_CHARGE, RACE_CARVE, RACE_RESIZE
};

typedef struct race_thread {
	pthread_t	 thread;
	unsigned int	 seed;
	long		 iterations;
	race_role_t	 role;
} race_thread_t;

static unsigned int
next_random(unsigned int *state)
{
	*state = *state * 1103515245u + 12345u;
	return (*state >> 8);
}

/* Charges or releases at a random reserve, under its owner's lock. */
static void
race_charge(unsigned int *seed)
{
	erx_reserve_counts_t counts;
	reserve_slot_t *slot;
	report_t report = { .length = 0, .refused = -1 };

	slot = &reserves[next_random(seed) % (unsigned)nreserves];
	if (!slot->exists)
		return;
	pthread_mutex_lock(&slot->lock);
	if (next_random(seed) % 2 == 0) {
		(void)charge(&slot->reserve, 1 + next_random(seed) % 8, -1,
		    &report);
	} else {
		erx_reserve_read(&slot->reserve, &counts);
		if (counts.backed > 0)
			(void)release(&slot->reserve, 0, counts.pooled,
			    &report);
	}
	pthread_mutex_unlock(&slot->lock);
}

/*
 * One budget's life in the race's slot: carved under a random budget,
 * charged, resized, destroyed, refunded at its dead self, which passes the
 * refund to its parent, and freed by its tombstone's put before the next
 * round. Its chains cross the charging threads' and the resizer's.
 */
static void
race_carve(unsigned int *seed)
{
	erx_budget_effects_t effects;
	erx_budget_t *child;
	erx_npages_t guarantee, pages;
	report_t report = { .length = 0, .refused = -1 };
	bool charged, outlived;

	guarantee = next_random(seed) % 40;
	if (carve(next_random(seed) % (unsigned)nbudgets, ERX_BUDGET_ELASTIC,
	    guarantee, guarantee + next_random(seed) % 80, RACE_SLOT,
	    &report) != 0)
		return;
	child = budgets[RACE_SLOT].budget;
	pages = 1 + next_random(seed) % 16;
	charged = erx_budget_adjust(child, (int64_t)pages, &effects) == 0;
	collect(&report, &effects);
	guarantee = next_random(seed) % 40;
	(void)erx_budget_resize(child, guarantee,
	    guarantee + next_random(seed) % 80, &effects);
	collect(&report, &effects);
	/* The child holds no object, so its walk prints no state. */
	if (destroy(RACE_SLOT, &report) != 0)
		fail("the race's destroy refused");
	if (charged && erx_budget_adjust(child, -(int64_t)pages, &effects) != 0)
		fail("the race's refund at a dead budget refused");
	collect(&report, &effects);
	put_round(&report);
	pthread_rwlock_rdlock(&table_lock);
	outlived = budgets[RACE_SLOT].exists;
	pthread_rwlock_unlock(&table_lock);
	if (outlived)
		fail("a raced budget outlived its round");
	race_carves++;
}

/* Resizes a random budget of the script's, keeping its bound. */
static void
race_resize(unsigned int *seed)
{
	erx_budget_counters_t before, after;
	erx_budget_effects_t effects;
	erx_npages_t guarantee, cap, spent;
	int id;

	if (nbudgets < 2)
		return;
	id = 1 + (int)(next_random(seed) % (unsigned)(nbudgets - 1));
	erx_budget_read(budgets[id].budget, &before);
	guarantee = next_random(seed) % 300;
	cap = before.kind == ERX_BUDGET_WALL ? guarantee :
	    guarantee + next_random(seed) % 800;
	if (erx_budget_resize(budgets[id].budget, guarantee, cap,
	    &effects) != 0)
		return;
	race_resizes++;
	erx_budget_read(budgets[id].budget, &after);
	spent = after.used + after.carved + after.lent;
	race_bound[id] = spent > cap ? spent : cap;
}

static void *
race_body(void *argument)
{
	race_thread_t *self;
	long i;

	self = argument;
	for (i = 0; i < self->iterations; i++) {
		switch (self->role) {
		case RACE_CHARGE:
			race_charge(&self->seed);
			break;
		case RACE_CARVE:
			race_carve(&self->seed);
			break;
		case RACE_RESIZE:
			race_resize(&self->seed);
			break;
		}
		if (nheld != 0)
			fail("a lock held after an operation");
	}
	return (NULL);
}

static void
race(unsigned int seed, long iterations, report_t *report)
{
	erx_budget_counters_t c;
	race_thread_t threads[RACE_THREADS];
	int i;

	/* The race needs every script budget live and no put due. */
	if (npending != 0)
		fail("a race with a tombstone due");
	for (i = 0; i < nbudgets; i++) {
		if (!budgets[i].exists)
			fail("a race over a freed budget");
		erx_budget_read(budgets[i].budget, &c);
		if (c.dead)
			fail("a race over a dead budget");
		race_bound[i] = c.cap;
	}
	race_carves = race_resizes = 0;
	for (i = 0; i < RACE_THREADS; i++) {
		threads[i] = (race_thread_t){ .seed = seed + (unsigned)i,
		    .iterations = iterations, .role = race_roles[i] };
		if (pthread_create(&threads[i].thread, NULL, race_body,
		    &threads[i]) != 0)
			fail("pthread_create");
	}
	for (i = 0; i < RACE_THREADS; i++)
		pthread_join(threads[i].thread, NULL);
	/* Only a resize below the spending leaves a budget above its cap. */
	for (i = 0; i < nbudgets; i++) {
		erx_budget_read(budgets[i].budget, &c);
		if (c.used + c.carved + c.lent > race_bound[i])
			fail("spending above its cap or what a resize left");
	}
	if (npending != 0)
		fail("a tombstone left unput after the race");
	say(report, " carves=%ld resizes=%ld", race_carves, race_resizes);
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
	bool taken;

	root = &root_record;
	say(report, " root=%d", erx_budget_init_root(root,
	    (erx_npages_t)INT64_MAX + 1));
	if (erx_budget_init_root(root, INT64_MAX) != 0)
		fail("the largest root refused");
	memset(cache_page_used, 0, sizeof(cache_page_used));
	new_budget_slot(0, root);
	nbudgets = 1;
	/* The child's record takes one page: the root is full after it. */
	say(report, " carve=%d", erx_budget_carve(root, cache_pages[0],
	    ERX_BUDGET_ELASTIC, (erx_npages_t)INT64_MAX + 1, UINT64_MAX,
	    &child, &taken, &effects));
	say(report, " carve=%d", erx_budget_carve(root, cache_pages[0],
	    ERX_BUDGET_ELASTIC, INT64_MAX - 1, UINT64_MAX, &child, &taken,
	    &effects));
	if (child == NULL || !taken)
		fail("the largest carve refused");
	new_budget_slot(1, child);
	nbudgets = 2;
	erx_budget_read(root, &before);
	say(report, " full=%d", erx_budget_adjust(root, 1, &effects));
	say(report, " min=%d", erx_budget_adjust(child, INT64_MIN, &effects));
	say(report, " below=%d", erx_budget_adjust(child, -1, &effects));
	say(report, " pin=%d", erx_budget_pin(child,
	    (erx_npages_t)INT64_MAX + 1, &effects));
	say(report, " within=%d", erx_budget_adjust(child, INT64_MAX - 1,
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
		for (n = 0; n < BUDGETS_MAX; n++)
			budgets[n].exists = 0;
		nreserves = 0;
		npending = 0;
		released_pages = 0;
		if (erx_budget_init_root(&root_record, (erx_npages_t)a) != 0)
			fail("root refused");
		memset(cache_page_used, 0, sizeof(cache_page_used));
		new_budget_slot(0, &root_record);
		say(report, " per=%u", erx_kcache_capacity(ERX_KCACHE_BUDGET));
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
		race((unsigned int)a, b, report);
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
	if (strcmp(name, "carve") == 0) {
		if (nbudgets == RACE_SLOT)
			fail("too many budgets");
		error = carve(a, b, (erx_npages_t)c, (erx_npages_t)d, nbudgets,
		    report);
		if (error == 0)
			nbudgets++;
		return (error);
	}
	if (strcmp(name, "resize") == 0) {
		error = erx_budget_resize(budgets[a].budget, (erx_npages_t)b,
		    (erx_npages_t)c, &effects);
		collect(report, &effects);
		return (error);
	}
	if (strcmp(name, "destroy") == 0)
		return (destroy(a, report));
	if (strcmp(name, "reserve") == 0) {
		if (nreserves == RESERVES_MAX)
			fail("too many reserves");
		reserves[nreserves].exists = 1;
		reserves[nreserves].budget = (int)a;
		pthread_mutex_init(&reserves[nreserves].lock, NULL);
		erx_reserve_init(&reserves[nreserves].reserve,
		    budgets[a].budget);
		/* The list's insert refuses a dead budget. */
		error = join_budget((erx_object_t *)(void *)
		    reserves[nreserves].header, ERX_K_MEMORY, budgets[a].budget);
		if (error != ERX_OK) {
			reserves[nreserves].exists = 0;
			return (error);
		}
		say(report, " id=%d", nreserves);
		nreserves++;
		return (0);
	}
	if (strcmp(name, "pin") == 0) {
		error = erx_budget_pin(budgets[a].budget, (erx_npages_t)b,
		    &effects);
		collect(report, &effects);
		return (error);
	}
	if (strcmp(name, "adjust") == 0) {
		error = erx_budget_adjust(budgets[a].budget, b, &effects);
		collect(report, &effects);
		return (error);
	}
	if (strcmp(name, "watch") == 0 || strcmp(name, "unwatch") == 0) {
		if (b < 0 || b >= IRQS_MAX)
			fail("no such IRQ object");
		error = erx_budget_watch(budgets[a].budget,
		    name[0] == 'w' ? &irqs[b] : NULL, (erx_npages_t)c, &fire);
		if (fire)
			say(report, " fire=%ld", b);
		return (error);
	}
	if (strcmp(name, "detach") == 0) {
		if (b < 0 || b >= IRQS_MAX)
			fail("no such IRQ object");
		say(report, " detached=%d",
		    erx_budget_watch_detach(budgets[a].budget, &irqs[b]) ? 1 : 0);
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
	if (erx_object_store_size() > sizeof(store_record) ||
	    erx_object_body((erx_object_t *)(void *)reserves[0].header) !=
	    (void *)&reserves[0].reserve)
		fail("a record does not fit the driver's layout");
	erx_object_store_init(&store, &(erx_oid_key_t){ { 1, 2, 3, 4 } });
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
