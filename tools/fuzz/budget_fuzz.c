/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the budget core, with the object store and the deletion core's
 * budget-death walk, through every sequence of calls its contract allows,
 * decoded from the input: carves of child budgets (each record from its
 * parent's record cache), objects that hold a charge on a budget's list,
 * charges and refunds (of a holding, or of any budget directly, dead
 * ones included), resizes, pins, destroys (the close, then the walk
 * over the budget's tree) and rounds of tombstone puts, whose last put
 * frees a dead budget's record. Operands reach the edges of the checked
 * arithmetic: guarantees, caps and charges near INT64_MAX and UINT64_MAX.
 *
 * Beside the core it keeps only the facts test/fixtures/budget_model.rb
 * keeps: each budget's parent, kind, guarantee, cap, pins and whether it is
 * dead, what each object holds and which budget's cache each cache page
 * is in. From them it derives every counter by the design's definitions
 * (docs/design-kernel.md, "Budgets"):
 *
 *   used(b)   = what b's objects hold + b's cache pages + the spending of
 *               b's dead children
 *   carved(b) = the guarantees of b's live children
 *   lent(b)   = the borrowing, max(0, spending - guarantee), of b's live
 *               children
 *   pinned(b) = b's pins + b's cache pages holding a pinned child's record
 *               + the pinned of every child
 *
 * and predicts each call as the model does: applied to the facts, the
 * call is refused with ERX_ENOMEM when it raises a live level of its chain
 * above that level's cap, naming the nearest, and with ERX_ESTALE when it
 * raises a dead budget it charges directly. It aborts when an invariant
 * breaks:
 *   a call's status is the predicted one (an operand above INT64_MAX, or
 *   a change of some level's spending by more than INT64_MAX, may instead
 *   be refused with ERX_EINVAL), a refusal names the predicted
 *   level and changes nothing, and after every call and every step of a
 *   walk each budget's counters are their definitions;
 *   K32: what is charged to the machine, the used of every live budget
 *   whose ancestors all live, is at most the root's pages, and no tree is
 *   doomed (a live budget under a dead one) but while a walk is in
 *   progress; that sum's agreement with what the budgets hold follows
 *   from the definitions, so test/host/budget_test.rb checks it against
 *   the pages the driver's reserves and caches hold instead;
 *   a tombstone is reported exactly once for each dead budget whose
 *   spending and pinned reach zero, and a record is freed only after its
 *   tombstone, at its object's last put;
 *   a walk closes only budgets below a dead one, and leaves its whole tree
 *   dead and every object on it destroyed;
 *   every chain is locked descendant first and released whole.
 *
 * Each operation is one byte, its low three bits the operation and the
 * rest the budget or object it names, followed by its operand bytes.
 */

#include <stdalign.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/attach.h"
#include "erx/budget.h"
#include "erx/delete.h"
#include "erx/object.h"

#define FUZZ_PAGES	200
#define FUZZ_BUDGETS	16
#define FUZZ_HOLDERS	16
#define FUZZ_CACHE_PAGES FUZZ_BUDGETS	/* a carve takes at most one */
#define NO_BUDGET	(-1)

typedef struct fuzz_input {
	const uint8_t	*data;
	size_t		 size;
} fuzz_input_t;

/* What a budget's counters are derived from. */
typedef struct fuzz_budget {
	bool		 exists;	/* carved, its record not yet freed */
	bool		 dead;
	bool		 tombstoned;	/* its tombstone has been reported */
	int		 parent;	/* NO_BUDGET for the root */
	int		 page;		/* its record's cache page; NO_BUDGET
					 * for the root */
	uint32_t	 depth;
	erx_budget_kind_t kind;
	erx_npages_t	 guarantee;
	erx_npages_t	 cap;
	erx_npages_t	 pins;
	erx_npages_t	 adjusted;	/* charged to it directly */
} fuzz_budget_t;

/* An object on a budget's list that holds a charge there. */
typedef struct fuzz_holding {
	bool		 exists;
	int		 budget;
	erx_npages_t	 pages;
} fuzz_holding_t;

/* Every fact, copied whole before a call so a refusal restores it. */
typedef struct fuzz_facts {
	fuzz_budget_t	 budgets[FUZZ_BUDGETS];
	fuzz_holding_t	 holdings[FUZZ_HOLDERS];
	int		 page_owner[FUZZ_CACHE_PAGES]; /* NO_BUDGET: none */
} fuzz_facts_t;

typedef struct fuzz_counters {
	erx_npages_t	used;
	erx_npages_t	carved;
	erx_npages_t	lent;
	erx_npages_t	pinned;
	erx_npages_t	spending;
} fuzz_counters_t;

/* The model's rule for the budget a call charges directly, when dead. */
typedef enum fuzz_dead_rule {
	FUZZ_DEAD_PASSES,
	FUZZ_DEAD_NO_RISE,
	FUZZ_DEAD_REFUSED
} fuzz_dead_rule_t;

/*
 * A prediction: the status, the level an ERX_ENOMEM names, and whether
 * some level's spending changes by more than INT64_MAX, a change the core
 * cannot express and may refuse with ERX_EINVAL first.
 */
typedef struct fuzz_verdict {
	int		 status;
	int		 refused;
	bool		 inexpressible;
} fuzz_verdict_t;

/* Where a budget stands for the machine's charge (K32). */
typedef enum fuzz_region {
	REGION_MACHINE,		/* live, and its ancestors all live */
	REGION_DEAD,		/* dead, under the machine's budgets */
	REGION_DOOMED_TOP,	/* live under a dead budget */
	REGION_DOOMED		/* below a doomed top */
} fuzz_region_t;

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static fuzz_facts_t facts;
static erx_budget_t *records[FUZZ_BUDGETS];
static int nbudgets;
static int nholdings;
static int nextpage;
/* A holding's object: its header, then a body the object store may use. */
typedef struct fuzz_holder {
	alignas(64) unsigned char header[ERX_OBJECT_HEADER_BYTES];
	alignas(64) unsigned char body[64];
} fuzz_holder_t;

static fuzz_holder_t holders[FUZZ_HOLDERS];
static alignas(64) unsigned char root_record[256];
static alignas(64) unsigned char store_record[64];
#define store	(*(erx_object_store_t *)(void *)store_record)
static alignas(ERX_KCACHE_PAGE_BYTES) unsigned char
    cache_pages[FUZZ_CACHE_PAGES][ERX_KCACHE_PAGE_BYTES];
static int pending[FUZZ_BUDGETS];	/* tombstones whose put is due */
static int npending;
static erx_budget_t *held[ERX_BUDGET_DEPTH_MAX + 1];
static int nheld;

/* The fuzzer passes no preemption point: every borrowed reference holds. */
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
			abort();
	if (nheld == ERX_BUDGET_DEPTH_MAX + 1 ||
	    (nheld > 0 && erx_budget_parent(held[nheld - 1]) != budget))
		abort();
	held[nheld++] = budget;
}

void
erx_effect_budget_unlock(erx_budget_t *budget)
{
	int i;

	for (i = 0; i < nheld && held[i] != budget; i++)
		continue;
	if (i == nheld)
		abort();
	for (; i + 1 < nheld; i++)
		held[i] = held[i + 1];
	nheld--;
}

static bool
next_byte(fuzz_input_t *in, uint8_t *byte)
{
	if (in->size == 0)
		return (false);
	*byte = *in->data++;
	in->size--;
	return (true);
}

/* An operand: a small count, or an edge of the checked arithmetic. */
static erx_npages_t
amount(uint8_t byte)
{
	static const erx_npages_t edges[] = {
		(erx_npages_t)INT64_MAX, (erx_npages_t)INT64_MAX + 1,
		UINT64_MAX, UINT64_MAX - 1, FUZZ_PAGES, FUZZ_PAGES + 1
	};
	size_t nedges = sizeof(edges) / sizeof(edges[0]);

	if (byte >= 256 - nedges)
		return (edges[255 - byte]);
	return (byte % 80);
}

static erx_npages_t
sum(erx_npages_t a, erx_npages_t b)
{
	erx_npages_t out;

	return (__builtin_add_overflow(a, b, &out) ? UINT64_MAX : out);
}

static erx_npages_t
borrowing(const fuzz_counters_t *c, const fuzz_budget_t *b)
{
	return (c->spending > b->guarantee ? c->spending - b->guarantee : 0);
}

static int
budget_index(const erx_budget_t *budget)
{
	int i;

	for (i = 0; i < nbudgets; i++)
		if (facts.budgets[i].exists && records[i] == budget)
			return (i);
	abort();
}

static int
cache_page_index(const void *record)
{
	uintptr_t at = (uintptr_t)record, base = (uintptr_t)cache_pages[0];

	if (at < base || at - base >= sizeof(cache_pages))
		abort();
	return ((int)((at - base) / ERX_KCACHE_PAGE_BYTES));
}

/* The records on a cache page: the budgets that still have one there. */
static uint32_t
records_on(int page)
{
	uint32_t n = 0;
	int i;

	for (i = 1; i < nbudgets; i++)
		if (facts.budgets[i].exists && facts.budgets[i].page == page)
			n++;
	return (n);
}

/* What a budget's objects and cache pages hold: its direct charge. */
static erx_npages_t
direct(int id)
{
	erx_npages_t pages = facts.budgets[id].adjusted;
	int i;

	for (i = 0; i < nholdings; i++)
		if (facts.holdings[i].exists && facts.holdings[i].budget == id)
			pages = sum(pages, facts.holdings[i].pages);
	for (i = 0; i < FUZZ_CACHE_PAGES; i++)
		if (facts.page_owner[i] == id)
			pages = sum(pages, 1);
	return (pages);
}

/* Every counter from its definition, children before parents. */
static void
derive(fuzz_counters_t out[FUZZ_BUDGETS])
{
	const fuzz_budget_t *b, *kid;
	fuzz_counters_t *c;
	bool kept[FUZZ_CACHE_PAGES];
	int depth, i, k;

	memset(out, 0, sizeof(fuzz_counters_t) * FUZZ_BUDGETS);
	for (depth = (int)ERX_BUDGET_DEPTH_MAX - 1; depth >= 0; depth--) {
		for (i = 0; i < nbudgets; i++) {
			b = &facts.budgets[i];
			if (!b->exists || b->depth != (uint32_t)depth)
				continue;
			c = &out[i];
			c->used = direct(i);
			c->pinned = b->pins;
			memset(kept, 0, sizeof(kept));
			for (k = 1; k < nbudgets; k++) {
				kid = &facts.budgets[k];
				if (!kid->exists || kid->parent != i)
					continue;
				c->pinned = sum(c->pinned, out[k].pinned);
				if (out[k].pinned != 0 && kid->page >= 0)
					kept[kid->page] = true;
				if (kid->dead) {
					c->used = sum(c->used, out[k].spending);
				} else {
					c->carved = sum(c->carved,
					    kid->guarantee);
					c->lent = sum(c->lent,
					    borrowing(&out[k], kid));
				}
			}
			for (k = 0; k < FUZZ_CACHE_PAGES; k++)
				if (kept[k])
					c->pinned = sum(c->pinned, 1);
			c->spending = sum(sum(c->used, c->carved), c->lent);
		}
	}
}

/*
 * The model's judgement of a change already applied to the facts: before
 * holds the counters derived without it.
 */
static fuzz_verdict_t
judge(int origin, fuzz_dead_rule_t rule, const fuzz_counters_t *before)
{
	fuzz_counters_t after[FUZZ_BUDGETS];
	fuzz_verdict_t verdict = { 0, NO_BUDGET, false };
	const fuzz_budget_t *b;
	erx_npages_t change;
	bool rose;
	int id;

	derive(after);
	for (id = 0; id < nbudgets; id++) {
		change = after[id].spending > before[id].spending ?
		    after[id].spending - before[id].spending :
		    before[id].spending - after[id].spending;
		if (facts.budgets[id].exists && change > INT64_MAX)
			verdict.inexpressible = true;
	}
	if (facts.budgets[origin].dead) {
		rose = after[origin].spending > before[origin].spending;
		if (rule == FUZZ_DEAD_REFUSED ||
		    (rule == FUZZ_DEAD_NO_RISE && rose)) {
			verdict.status = ERX_ESTALE;
			return (verdict);
		}
	}
	for (id = origin; id != NO_BUDGET; id = b->parent) {
		b = &facts.budgets[id];
		if (!b->dead && after[id].spending > before[id].spending &&
		    after[id].spending > b->cap) {
			verdict.status = ERX_ENOMEM;
			verdict.refused = id;
			break;
		}
	}
	return (verdict);
}

/* Each tombstone reported must be due: dead, nothing spent, nothing pinned. */
static void
collect(const erx_budget_effects_t *effects)
{
	erx_budget_counters_t c;
	uint32_t i;
	int id;

	for (i = 0; i < effects->ntombstone; i++) {
		id = budget_index(effects->tombstone[i]);
		erx_budget_read(records[id], &c);
		if (!c.dead || facts.budgets[id].tombstoned ||
		    sum(sum(c.used, c.carved), c.lent) != 0 || c.pinned != 0 ||
		    npending == FUZZ_BUDGETS)
			abort();
		facts.budgets[id].tombstoned = true;
		pending[npending++] = id;
	}
}

/*
 * A call's status against its verdict. An operand above INT64_MAX, like
 * a level's change beyond it, is a change the core cannot express, which
 * it may refuse with ERX_EINVAL before the check the model makes. On a
 * refusal the call's facts are undone (back to saved) and the core must
 * have changed nothing.
 */
static void
expect(int status, fuzz_verdict_t verdict, bool huge,
    const erx_budget_effects_t *effects, const fuzz_facts_t *saved)
{
	if (status != verdict.status &&
	    !((huge || verdict.inexpressible) && verdict.status != 0 &&
	    status == ERX_EINVAL))
		abort();
	if (status == ERX_ENOMEM &&
	    (effects->refused == NULL ||
	    budget_index(effects->refused) != verdict.refused))
		abort();
	if (status != 0) {
		if (effects->ntombstone != 0 || effects->nfire != 0)
			abort();
		facts = *saved;
	}
}

/*
 * K32: what is charged to the machine, the used of the budgets whose tree
 * lives, is at most the root's pages. Returns whether any tree is doomed.
 */
static bool
check_machine(const fuzz_counters_t *derived)
{
	fuzz_region_t region[FUZZ_BUDGETS], above;
	const fuzz_budget_t *b;
	erx_npages_t charged = 0;
	bool doomed = false;
	int depth, i;

	for (i = 0; i < FUZZ_BUDGETS; i++)
		region[i] = REGION_DOOMED;
	for (depth = 0; depth < (int)ERX_BUDGET_DEPTH_MAX; depth++) {
		for (i = 0; i < nbudgets; i++) {
			b = &facts.budgets[i];
			if (!b->exists || b->depth != (uint32_t)depth)
				continue;
			above = b->parent == NO_BUDGET ? REGION_MACHINE :
			    region[b->parent];
			if (above == REGION_DOOMED_TOP ||
			    above == REGION_DOOMED)
				region[i] = REGION_DOOMED;
			else if (b->dead)
				region[i] = REGION_DEAD;
			else if (above == REGION_DEAD)
				region[i] = REGION_DOOMED_TOP;
			else
				region[i] = REGION_MACHINE;
			if (region[i] == REGION_MACHINE)
				charged = sum(charged, derived[i].used);
			if (region[i] == REGION_DOOMED_TOP)
				doomed = true;
		}
	}
	if (charged > FUZZ_PAGES)
		abort();
	return (doomed);
}

/*
 * Every budget's counters against their definitions, the machine's charge
 * against what is held, and every tombstone that is due reported. between
 * says no walk is in progress, so no tree may be doomed.
 */
static void
check(bool between)
{
	fuzz_counters_t derived[FUZZ_BUDGETS];
	erx_budget_counters_t c;
	const fuzz_budget_t *b;
	int i;

	if (nheld != 0)
		abort();
	derive(derived);
	for (i = 0; i < nbudgets; i++) {
		b = &facts.budgets[i];
		if (!b->exists)
			continue;
		erx_budget_read(records[i], &c);
		if (c.used != derived[i].used ||
		    c.carved != derived[i].carved ||
		    c.lent != derived[i].lent ||
		    c.pinned != derived[i].pinned || c.dead != b->dead ||
		    c.guarantee != b->guarantee || c.cap != b->cap ||
		    c.depth != b->depth || c.kind != b->kind)
			abort();
		if (b->dead && !b->tombstoned && derived[i].spending == 0 &&
		    derived[i].pinned == 0)
			abort();
	}
	if (check_machine(derived) && between)
		abort();
}

/*
 * The put of one counted reference to obj. A budget's object's last put is
 * its record's one release: the record is freed in its parent's cache,
 * which refunds a cache page left empty.
 */
static void
put_object(erx_object_t *obj)
{
	erx_budget_effects_t effects;
	void *page;
	int id, owner;

	if (!erx_object_put(obj) || erx_object_type(obj) != ERX_K_BUDGET)
		return;
	id = budget_index(erx_object_body(obj));
	if (!facts.budgets[id].tombstoned ||
	    erx_budget_free_record(records[id], &page, &effects) != 0)
		abort();
	owner = facts.budgets[id].parent;
	facts.budgets[id].exists = false;
	if (page != NULL) {
		if (cache_page_index(page) != facts.budgets[id].page ||
		    records_on(facts.budgets[id].page) != 0)
			abort();
		facts.page_owner[facts.budgets[id].page] = NO_BUDGET;
	} else if (records_on(facts.budgets[id].page) == 0 ||
	    facts.page_owner[facts.budgets[id].page] != owner) {
		abort();
	}
	collect(&effects);
}

/* Puts obj on budget's list through the list's insert, under its lock. */
static int
join(erx_object_t *obj, erx_ktype_t type, int id)
{
	int error;

	if (erx_object_init(&store, obj, type, records[id]) != ERX_OK)
		abort();
	erx_effect_budget_lock(records[id]);
	error = erx_attach_budget_charged(obj);
	erx_effect_budget_unlock(records[id]);
	return (error);
}

static void
carve(int parent, uint8_t kind_byte, uint8_t guarantee_byte,
    uint8_t cap_byte)
{
	fuzz_counters_t before[FUZZ_BUDGETS];
	erx_budget_effects_t effects = { 0 };
	erx_budget_kind_t kind = (erx_budget_kind_t)(kind_byte & 3);
	erx_npages_t guarantee = amount(guarantee_byte), cap;
	fuzz_facts_t saved = facts;
	fuzz_budget_t *p = &facts.budgets[parent];
	fuzz_verdict_t verdict = { 0, NO_BUDGET, false };
	erx_budget_t *child;
	bool fresh = true, taken;
	int id = nbudgets, i, status;

	cap = (kind_byte & 4) != 0 ? amount(cap_byte) :
	    sum(guarantee, amount(cap_byte));
	if (nbudgets == FUZZ_BUDGETS || nextpage == FUZZ_CACHE_PAGES)
		return;
	for (i = 0; i < FUZZ_CACHE_PAGES; i++)
		if (facts.page_owner[i] == parent &&
		    records_on(i) < erx_kcache_capacity(ERX_KCACHE_BUDGET))
			fresh = false;
	derive(before);
	if (kind != ERX_BUDGET_WALL && kind != ERX_BUDGET_ELASTIC)
		verdict.status = ERX_EINVAL;
	else if (cap < guarantee ||
	    (kind == ERX_BUDGET_WALL && cap != guarantee))
		verdict.status = ERX_EINVAL;
	else if (p->depth >= ERX_BUDGET_DEPTH_MAX - 1)
		verdict.status = ERX_ELIMIT;
	else if (p->dead)
		verdict.status = ERX_ESTALE;
	else {
		if (fresh)
			facts.page_owner[nextpage] = parent;
		facts.budgets[id] = (fuzz_budget_t){ .exists = true,
		    .parent = parent, .page = NO_BUDGET, .depth = p->depth + 1,
		    .kind = kind, .guarantee = guarantee, .cap = cap };
		nbudgets++;
		verdict = judge(parent, FUZZ_DEAD_REFUSED, before);
		nbudgets = id;
	}
	status = erx_budget_carve(records[parent], cache_pages[nextpage], kind,
	    guarantee, cap, &child, &taken, &effects);
	expect(status, verdict, guarantee > INT64_MAX, &effects, &saved);
	if (taken != (status == 0 && fresh))
		abort();
	collect(&effects);
	if (status != 0)
		return;
	nbudgets++;
	if (taken)
		nextpage++;
	records[id] = child;
	facts.budgets[id].page = cache_page_index(erx_object_of(child));
	if (facts.page_owner[facts.budgets[id].page] != parent ||
	    join(erx_object_of(child), ERX_K_BUDGET, parent) != ERX_OK)
		abort();
	/* The reference the child's counters hold, which its tombstone puts. */
	(void)erx_object_ref(erx_uref_make(erx_object_of(child)));
}

static void
new_holding(int id)
{
	int h = nholdings;

	if (nholdings == FUZZ_HOLDERS)
		return;
	nholdings++;
	facts.holdings[h] = (fuzz_holding_t){ .exists = true, .budget = id };
	if (join((erx_object_t *)(void *)holders[h].header, ERX_K_MEMORY,
	    id) != ERX_OK) {
		/* The list's insert refuses only a dead budget. */
		if (!facts.budgets[id].dead)
			abort();
		facts.holdings[h].exists = false;
	} else if (facts.budgets[id].dead) {
		abort();
	}
}

/* A charge (pages > 0) or a refund of what holding h holds. */
static void
adjust(int h, erx_npages_t pages, bool refund)
{
	fuzz_counters_t before[FUZZ_BUDGETS];
	erx_budget_effects_t effects;
	fuzz_holding_t *holding = &facts.holdings[h];
	fuzz_facts_t saved = facts;
	fuzz_verdict_t verdict;
	int id = holding->budget, status;

	if (pages > INT64_MAX)
		pages = INT64_MAX;
	if (refund && pages > holding->pages)
		pages = holding->pages;
	derive(before);
	holding->pages = refund ? holding->pages - pages :
	    sum(holding->pages, pages);
	verdict = judge(id, FUZZ_DEAD_NO_RISE, before);
	status = erx_budget_adjust(records[id],
	    refund ? -(int64_t)pages : (int64_t)pages, &effects);
	expect(status, verdict, false, &effects, &saved);
	collect(&effects);
}

/*
 * A charge, or a refund (bit 6), of byte's low six bits at budget id
 * directly, dead or not, as the driver's adjust makes one. A refund beyond
 * the budget's used is an accounting error, refused with ERX_EINVAL; one
 * within its used but beyond what it was charged directly is not made.
 */
static void
adjust_budget(int id, uint8_t byte)
{
	fuzz_counters_t before[FUZZ_BUDGETS];
	erx_budget_effects_t effects;
	fuzz_budget_t *b = &facts.budgets[id];
	fuzz_facts_t saved = facts;
	fuzz_verdict_t verdict = { 0, NO_BUDGET, false };
	erx_npages_t pages = byte & 0x3f;
	bool refund = (byte & 0x40) != 0;
	int status;

	derive(before);
	if (refund && pages > before[id].used) {
		verdict.status = ERX_EINVAL;
	} else if (refund && pages > b->adjusted) {
		return;
	} else {
		b->adjusted = refund ? b->adjusted - pages :
		    b->adjusted + pages;
		verdict = judge(id, FUZZ_DEAD_NO_RISE, before);
	}
	status = erx_budget_adjust(records[id],
	    refund ? -(int64_t)pages : (int64_t)pages, &effects);
	expect(status, verdict, false, &effects, &saved);
	collect(&effects);
}

static void
resize(int id, uint8_t guarantee_byte, uint8_t cap_byte)
{
	fuzz_counters_t before[FUZZ_BUDGETS];
	erx_budget_effects_t effects = { 0 };
	fuzz_budget_t *b = &facts.budgets[id];
	erx_npages_t guarantee = amount(guarantee_byte), cap;
	fuzz_facts_t saved = facts;
	fuzz_verdict_t verdict = { 0, NO_BUDGET, false };
	int status;

	cap = cap_byte >= 128 ? amount(cap_byte) :
	    sum(guarantee, amount(cap_byte));
	if (b->kind == ERX_BUDGET_WALL && (cap_byte & 1) != 0)
		cap = guarantee;
	derive(before);
	if (b->parent == NO_BUDGET || cap < guarantee ||
	    (b->kind == ERX_BUDGET_WALL && cap != guarantee))
		verdict.status = ERX_EINVAL;
	else if (b->dead)
		verdict.status = ERX_ESTALE;
	else {
		b->guarantee = guarantee;
		b->cap = cap;
		verdict = judge(b->parent, FUZZ_DEAD_NO_RISE, before);
	}
	status = erx_budget_resize(records[id], guarantee, cap, &effects);
	expect(status, verdict, guarantee > INT64_MAX, &effects, &saved);
	collect(&effects);
}

/* A pin names pages the budget holds, so it stays within its used. */
static void
pin(int id, uint8_t byte)
{
	fuzz_counters_t before[FUZZ_BUDGETS];
	erx_budget_effects_t effects;
	erx_npages_t pages = 1 + byte % 2;

	derive(before);
	if (before[id].used < sum(facts.budgets[id].pins, pages))
		return;
	facts.budgets[id].pins += pages;
	if (erx_budget_pin(records[id], pages, &effects) != 0)
		abort();
	collect(&effects);
}

static int
holder_index(const erx_object_t *obj)
{
	int i;

	for (i = 0; i < nholdings; i++)
		if ((const void *)holders[i].header == (const void *)obj)
			return (i);
	abort();
}

/*
 * One destroy as a deletion runs it, with nothing racing: the close, the
 * drain and the teardown, whose put of a holding refunds what it holds at
 * its budget, dead or not. Returns whether it went on past the close.
 */
static bool
destroy_object(erx_delete_t *destroy)
{
	erx_budget_effects_t effects;
	erx_object_t *obj = destroy->object;
	fuzz_holding_t *holding;

	for (;;) {
		switch (erx_delete_step(destroy).action) {
		case ERX_DELETE_STOP:
			return (false);
		case ERX_DELETE_DRAIN:
			erx_delete_uncharge(obj);
			break;
		case ERX_DELETE_CLEAR:
			abort();
		case ERX_DELETE_PUT:
			if (erx_object_type(obj) != ERX_K_BUDGET) {
				holding = &facts.holdings[holder_index(obj)];
				if (erx_budget_adjust(records[holding->budget],
				    -(int64_t)holding->pages, &effects) != 0)
					abort();
				holding->exists = false;
				collect(&effects);
			}
			put_object(obj);
			return (true);
		}
	}
}

/* Marks dead the budget a walk's step closed: one doomed top. */
static void
note_closed(void)
{
	int closed = NO_BUDGET, i;

	for (i = 0; i < nbudgets; i++) {
		if (!facts.budgets[i].exists || facts.budgets[i].dead ||
		    !erx_budget_dead(records[i]))
			continue;
		if (closed != NO_BUDGET ||
		    !facts.budgets[facts.budgets[i].parent].dead)
			abort();
		closed = i;
	}
	if (closed == NO_BUDGET)
		abort();
	facts.budgets[closed].dead = true;
}

static bool
below(int id, int top)
{
	for (; id != NO_BUDGET; id = facts.budgets[id].parent)
		if (id == top)
			return (true);
	return (false);
}

static void
destroy(int top)
{
	erx_budget_effects_t effects;
	erx_delete_budget_walk_t walk;
	erx_delete_t own;
	erx_object_t *obj;
	bool budget;
	int i;

	if (top == 0) {
		if (erx_budget_close(records[0], &effects) != ERX_EINVAL)
			abort();
		return;
	}
	obj = erx_object_of(records[top]);
	if (erx_object_state(obj) != ERX_OBJ_LIVE) {
		/* A dead budget never closes again. */
		if (!facts.budgets[top].dead ||
		    erx_budget_close(records[top], &effects) != ERX_ESTALE)
			abort();
		return;
	}
	obj = erx_object_ref(erx_uref_make(obj));
	erx_delete_begin(&own, obj);
	if (!destroy_object(&own) ||
	    erx_budget_close(records[top], &effects) != 0)
		abort();
	facts.budgets[top].dead = true;
	collect(&effects);
	check(false);
	erx_delete_budget_walk_begin(&walk, records[top]);
	for (;;) {
		switch (erx_delete_budget_walk_next(&walk, &effects)) {
		case ERX_DELETE_BUDGET_WALK_DESTROY:
			budget = erx_object_type(walk.destroy.object) ==
			    ERX_K_BUDGET;
			(void)destroy_object(&walk.destroy);
			if (budget)
				continue;
			break;
		case ERX_DELETE_BUDGET_WALK_CLOSED:
			note_closed();
			collect(&effects);
			break;
		case ERX_DELETE_BUDGET_WALK_PUT:
			budget = erx_object_type(walk.put) == ERX_K_BUDGET;
			put_object(walk.put);
			if (!budget)
				continue;
			break;
		case ERX_DELETE_BUDGET_WALK_DONE:
			put_object(obj);
			for (i = 0; i < nbudgets; i++)
				if (facts.budgets[i].exists &&
				    !facts.budgets[i].dead && below(i, top))
					abort();
			for (i = 0; i < nholdings; i++)
				if (facts.holdings[i].exists &&
				    below(facts.holdings[i].budget, top))
					abort();
			return;
		}
		check(false);
	}
}

/* One round of tombstone puts: each drops the reference of its counters. */
static void
put_round(void)
{
	int due[FUZZ_BUDGETS];
	int i, n = npending;

	memcpy(due, pending, sizeof(due[0]) * (size_t)n);
	npending = 0;
	for (i = 0; i < n; i++)
		put_object(erx_object_of(records[due[i]]));
}

static void
reset(void)
{
	int i;

	if (erx_budget_record_size() > sizeof(root_record) ||
	    erx_object_store_size() > sizeof(store_record))
		abort();
	memset(&facts, 0, sizeof(facts));
	memset(records, 0, sizeof(records));
	memset(holders, 0, sizeof(holders));
	memset(root_record, 0, sizeof(root_record));
	for (i = 0; i < FUZZ_CACHE_PAGES; i++)
		facts.page_owner[i] = NO_BUDGET;
	erx_object_store_init(&store, &(erx_oid_key_t){ { 1, 2, 3, 4 } });
	records[0] = (erx_budget_t *)(void *)root_record;
	if (erx_budget_init_root(records[0], FUZZ_PAGES) != 0)
		abort();
	facts.budgets[0] = (fuzz_budget_t){ .exists = true,
	    .parent = NO_BUDGET, .page = NO_BUDGET, .kind = ERX_BUDGET_WALL,
	    .guarantee = FUZZ_PAGES, .cap = FUZZ_PAGES };
	nbudgets = 1;
	nholdings = 0;
	nextpage = 0;
	npending = 0;
	nheld = 0;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	fuzz_input_t in = { data, size };
	uint8_t op, b1, b2, b3;
	int target, h;

	reset();
	while (next_byte(&in, &op)) {
		target = (op >> 3) % nbudgets;
		h = nholdings == 0 ? -1 : (op >> 3) % nholdings;
		b1 = b2 = b3 = 0;
		switch (op & 7) {
		case 0:
			if (next_byte(&in, &b1) && next_byte(&in, &b2) &&
			    next_byte(&in, &b3) &&
			    facts.budgets[target].exists)
				carve(target, b1, b2, b3);
			break;
		case 1:
			if (facts.budgets[target].exists)
				new_holding(target);
			break;
		case 2:
		case 3:
			if (!next_byte(&in, &b1))
				break;
			if ((op & 7) == 3 && (b1 & 0x80) != 0) {
				if (facts.budgets[target].exists)
					adjust_budget(target, b1);
			} else if (h >= 0 && facts.holdings[h].exists) {
				adjust(h, amount(b1), (op & 7) == 3);
			}
			break;
		case 4:
			if (next_byte(&in, &b1) && next_byte(&in, &b2) &&
			    facts.budgets[target].exists)
				resize(target, b1, b2);
			break;
		case 5:
			if (next_byte(&in, &b1) && facts.budgets[target].exists)
				pin(target, b1);
			break;
		case 6:
			if (facts.budgets[target].exists)
				destroy(target);
			break;
		default:
			put_round();
			break;
		}
		check(true);
	}
	return (0);
}
