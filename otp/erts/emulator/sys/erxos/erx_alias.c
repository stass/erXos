/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The alias registry (erx_alias.h). Entries are spread over stripes by their first identity
 * word, each stripe a hash table under its own lock. Only this domain's own aliases are
 * entries, and identity words are AES output, so entries spread evenly over stripes and
 * buckets. A peer chooses the words it sends and so the stripe its lookups take, but each
 * lookup only walks one bucket of evenly spread entries. An entry is freed only after it
 * has left its table under the stripe lock, and erx_alias_hold returns with that lock held,
 * so no reader of an entry outlives it.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "hash.h"
#include "bif.h"
#include "big.h"

#include "erx_alias.h"
#include "erx_exports.h"

#define STRIPES		64

typedef struct alias_entry {
	HashBucket	 hash;			/* first: hash.h links entries through it */
	uint32_t	 words[ERX_ALIAS_WORDS];
	uint64_t	 owner;			/* an internal pid */
	erx_exports_t	 exports;		/* the peers given the alias */
} alias_entry_t;

typedef struct alias_stripe {
	erts_mtx_t	 lock;
	Hash		 table;
	char		 name[24];
} alias_stripe_t;

typedef union {
	alias_stripe_t	 s;
	char		 align[ERTS_ALC_CACHE_LINE_ALIGN_SIZE(sizeof(alias_stripe_t))];
} aligned_stripe_t;

static aligned_stripe_t *stripes;
static erts_atomic_t active;

_Static_assert(ERX_ALIAS_WORDS == ERTS_REF_NUMBERS, "an alias's words are a reference's");

static HashValue
entry_hash(void *e)
{
	return ((HashValue)((alias_entry_t *)e)->words[1]);
}

static int
entry_cmp(void *a, void *b)
{
	return (sys_memcmp(((alias_entry_t *)a)->words, ((alias_entry_t *)b)->words,
	    sizeof(((alias_entry_t *)a)->words)) != 0);
}

/* hash_put is handed the entry itself, allocated by its caller, and frees nothing. */
static void *
entry_alloc(void *e)
{
	return (e);
}

static void
entry_free(void *e)
{
	(void)e;
}

static void *
buckets_alloc(int i, size_t size)
{
	(void)i;
	return (erts_alloc(ERTS_ALC_T_PREF_TAB_BKTS, size));
}

static void
buckets_free(int i, void *p)
{
	(void)i;
	erts_free(ERTS_ALC_T_PREF_TAB_BKTS, p);
}

void
erx_alias_init(void)
{
	HashFunctions funcs = {
		.hash = entry_hash, .cmp = entry_cmp, .alloc = entry_alloc, .free = entry_free,
		.meta_alloc = buckets_alloc, .meta_free = buckets_free, .meta_print = erts_print,
	};
	size_t i;

	stripes = erts_alloc_permanent_cache_aligned(ERTS_ALC_T_PREF_TAB, sizeof(*stripes) * STRIPES);
	for (i = 0; i < STRIPES; i++) {
		alias_stripe_t *const s = &stripes[i].s;

		erts_snprintf(s->name, sizeof(s->name), "erx_alias_%zu", i);
		hash_init(ERTS_ALC_T_PREF_TAB_BKTS, &s->table, s->name, 16, funcs);
		erts_mtx_init(&s->lock, "erx_alias", NIL,
		    ERTS_LOCK_FLAGS_PROPERTY_STATIC | ERTS_LOCK_FLAGS_CATEGORY_DISTRIBUTION);
	}
	erts_atomic_init_nob(&active, 0);
}

size_t
erx_alias_entry_size(void)
{
	return (sizeof(alias_entry_t));
}

static alias_stripe_t *
stripe_of(const uint32_t words[ERX_ALIAS_WORDS])
{
	return (&stripes[words[0] % STRIPES].s);
}

/* The entry of words in s, or NULL. Under s's lock. */
static alias_entry_t *
entry_find(alias_stripe_t *s, const uint32_t words[ERX_ALIAS_WORDS])
{
	alias_entry_t key;

	sys_memcpy(key.words, words, sizeof(key.words));
	return (hash_get(&s->table, &key));
}

void
erx_alias_insert(const uint32_t words[ERX_ALIAS_WORDS], uint64_t owner)
{
	alias_stripe_t *const s = stripe_of(words);
	alias_entry_t *e = erts_alloc(ERTS_ALC_T_PREF_ENT, sizeof(*e));
	alias_entry_t *found;

	sys_memcpy(e->words, words, sizeof(e->words));
	e->owner = owner;
	e->exports = (erx_exports_t){ 0 };
	erts_mtx_lock(&s->lock);
	found = entry_find(s, words);
	/*
	 * Identities are unique and a monitor is in one tree at a time, so none is found. One
	 * found means two sources made the same identity, which would route one process's
	 * alias to another: the runtime stops, as it does when a source is spent.
	 */
	if (found != NULL)
		erts_exit(ERTS_ABORT_EXIT, "erx: alias registry: an identity made twice\n");
	(void)hash_put(&s->table, e);
	erts_atomic_inc_nob(&active);
	erts_mtx_unlock(&s->lock);
}

void
erx_alias_remove(const uint32_t words[ERX_ALIAS_WORDS])
{
	alias_stripe_t *const s = stripe_of(words);
	alias_entry_t key, *e;

	sys_memcpy(key.words, words, sizeof(key.words));
	erts_mtx_lock(&s->lock);
	e = hash_remove(&s->table, &key);
	erts_mtx_unlock(&s->lock);
	if (e == NULL)
		return;
	erts_atomic_dec_nob(&active);
	/* Out of the table under the lock, so no hold reaches e from here on. */
	erx_exports_close(&e->exports);
	erts_free(ERTS_ALC_T_PREF_ENT, e);
}

uint64_t
erx_alias_owner(const uint32_t words[ERX_ALIAS_WORDS])
{
	alias_stripe_t *const s = stripe_of(words);
	alias_entry_t *e;
	uint64_t owner;

	erts_mtx_lock(&s->lock);
	e = entry_find(s, words);
	owner = e == NULL ? 0 : e->owner;
	erts_mtx_unlock(&s->lock);
	return (owner);
}

erx_exports_t *
erx_alias_hold(const uint32_t words[ERX_ALIAS_WORDS], erx_alias_hold_t *hold)
{
	alias_stripe_t *const s = stripe_of(words);
	alias_entry_t *e;

	erts_mtx_lock(&s->lock);
	e = entry_find(s, words);
	if (e == NULL) {
		erts_mtx_unlock(&s->lock);
		hold->stripe = NULL;
		return (NULL);
	}
	hold->stripe = s;
	return (&e->exports);
}

void
erx_alias_release(erx_alias_hold_t *hold)
{
	erts_mtx_unlock(&((alias_stripe_t *)hold->stripe)->lock);
	hold->stripe = NULL;
}

uint64_t
erx_alias_count(void)
{
	return ((uint64_t)erts_atomic_read_nob(&active));
}

/* erx_dist:aliases(): how many aliases of this domain are active. */
BIF_RETTYPE
erx_dist_aliases_0(BIF_ALIST_0)
{
	const Uint n = (Uint)erx_alias_count();
	Eterm *hp;

	if (IS_USMALL(0, n))
		BIF_RET(make_small(n));
	hp = HAlloc(BIF_P, BIG_UINT_HEAP_SIZE);
	BIF_RET(uint_to_big(n, hp));
}
