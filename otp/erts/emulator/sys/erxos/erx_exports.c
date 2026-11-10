/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The export table (docs/design-domains.md, "Exports"; docs/design-runtime.md, "The
 * export table's three writers"): a name's holders live on the name's own record, and
 * holders_put, the one insert, has exactly three callers, one per writer (R7,
 * tools/lib/erx/chokepoint_rules/exports.rb). The funnel asks erx_exports_lookup from
 * the lane's input task; encoders, spawns and the owner's own export write from their
 * own schedulers. Every read and write of a set is under the stripe lock its address
 * picks, so a reader sees a set whole and a set closed at its name's end stays empty.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "erl_process.h"
#include "dist.h"
#include "bif.h"
#include "big.h"

#include "erx/abi.h"
#include "erx_alias.h"
#include "erx_exports.h"

/* The table's bound, the design's default for `exports` (design-domains.md, "Exports"). */
#define EXPORTS_MAX		16384
/* Stripe locks: a set's address picks one, so unrelated names rarely share a lock. */
#define STRIPES			64
/* The rights a pid and the domain's own name may hold. */
#define PID_RIGHTS		(ERX_RIGHT_SEND | ERX_RIGHT_LINK | ERX_RIGHT_EXIT | ERX_RIGHT_INTRODUCE)
#define DOMAIN_RIGHTS		ERX_RIGHT_SPAWN
/* What a spawner holds on its child. */
#define CHILD_RIGHTS		(ERX_RIGHT_SEND | ERX_RIGHT_LINK | ERX_RIGHT_EXIT)

static erts_mtx_t stripes[STRIPES];
/* Live entries across every set, against EXPORTS_MAX. */
static erts_atomic_t live;
/*
 * The holders a hand-out or a spawn could not write (PUT_FULL: the table full, or memory
 * short): each such name behaves at its peer as a dead process (erx_dist:exports_refused/0).
 */
static erts_atomic64_t refused;
/* The domain's own name's holders: spawn into the domain. */
static erx_exports_t domain_exports;

/* How holders_put treats what the peer already holds. */
typedef enum {
	PUT_IF_NONE,	/* handing out a name: only where the peer holds nothing */
	PUT_WIDEN,	/* a spawn: add the rights to what the peer holds */
	PUT_EXACT	/* an explicit export: exactly these, none removing the holder */
} put_mode_t;

/* What holders_put did. */
typedef enum {
	PUT_DONE,
	PUT_FULL	/* the table is at EXPORTS_MAX, or no memory: nothing written */
} put_t;

void
erx_exports_init(void)
{
	size_t i;

	for (i = 0; i < STRIPES; i++)
		erts_mtx_init(&stripes[i], "erx_exports", NIL,
		    ERTS_LOCK_FLAGS_PROPERTY_STATIC | ERTS_LOCK_FLAGS_CATEGORY_DISTRIBUTION);
	erts_atomic_init_nob(&live, 0);
	erts_atomic64_init_nob(&refused, 0);
}

static erts_mtx_t *
stripe_of(const erx_exports_t *set)
{
	return (&stripes[((uintptr_t)set >> 4) % STRIPES]);
}

/* The holder of peer in set, or NULL. Under set's stripe lock. */
static erx_export_holder_t *
holder_find(const erx_exports_t *set, uint32_t peer)
{
	uint16_t i;

	for (i = 0; i < set->nholders; i++)
		if (set->holders[i].peer == peer)
			return (&set->holders[i]);
	return (NULL);
}

/* Removes the holder h of set. Under set's stripe lock. */
static void
holder_remove(erx_exports_t *set, erx_export_holder_t *h)
{
	*h = set->holders[--set->nholders];
	erts_atomic_dec_nob(&live);
}

/* A new holder of peer with rights in set, within the table's bound. Under the lock. */
static put_t
holder_add(erx_exports_t *set, uint32_t peer, uint8_t rights)
{
	erx_export_holder_t *grown;
	uint16_t cap;

	if (erts_atomic_inc_read_nob(&live) > EXPORTS_MAX) {
		erts_atomic_dec_nob(&live);
		return (PUT_FULL);
	}
	if (set->nholders == set->cap) {
		cap = set->cap == 0 ? 2 : (uint16_t)(set->cap * 2);
		if (cap <= set->cap)
			goto full;	/* UINT16_MAX peers on one name */
		grown = erts_realloc_fnf(ERTS_ALC_T_DRV, set->holders, cap * sizeof(*grown));
		if (grown == NULL)
			goto full;
		set->holders = grown;
		set->cap = cap;
	}
	set->holders[set->nholders++] = (erx_export_holder_t){ .peer = peer, .rights = rights };
	return (PUT_DONE);
full:
	erts_atomic_dec_nob(&live);
	return (PUT_FULL);
}

/*
 * The one insert: what peer holds on set's name after mode applies rights. A closed set
 * takes nothing, so a writer that raced the name's end writes nothing.
 */
static put_t
holders_put(erx_exports_t *set, uint32_t peer, uint8_t rights, put_mode_t mode)
{
	erts_mtx_t *const lock = stripe_of(set);
	erx_export_holder_t *h;
	put_t put = PUT_DONE;

	erts_mtx_lock(lock);
	h = holder_find(set, peer);	/* a closed set has none */
	if (set->closed)
		put = PUT_DONE;
	else if (h == NULL && rights != 0)
		put = holder_add(set, peer, rights);
	else if (h != NULL && mode == PUT_WIDEN)
		h->rights |= rights;
	else if (h != NULL && mode == PUT_EXACT && rights != 0)
		h->rights = rights;
	else if (h != NULL && mode == PUT_EXACT)
		holder_remove(set, h);
	erts_mtx_unlock(lock);
	return (put);
}

/* What peer holds on set's name, read whole under its lock. */
static uint8_t
holders_rights(const erx_exports_t *set, uint32_t peer)
{
	erts_mtx_t *const lock = stripe_of(set);
	const erx_export_holder_t *h;
	uint8_t rights;

	erts_mtx_lock(lock);
	h = holder_find(set, peer);
	rights = h == NULL ? 0 : h->rights;
	erts_mtx_unlock(lock);
	return (rights);
}

void
erx_exports_close(erx_exports_t *set)
{
	erts_mtx_t *const lock = stripe_of(set);
	erx_export_holder_t *holders;
	uint16_t n;

	erts_mtx_lock(lock);
	holders = set->holders;
	n = set->nholders;
	*set = (erx_exports_t){ .closed = 1 };
	erts_mtx_unlock(lock);
	erts_atomic_add_nob(&live, -(erts_aint_t)n);
	if (holders != NULL)
		erts_free(ERTS_ALC_T_DRV, holders);
}

/* The live process of an internal pid, or NULL; on a managed thread. */
static Process *
live_process(Eterm pid)
{
	return (is_internal_pid(pid) ? erts_proc_lookup(pid) : NULL);
}

/*
 * Writer 1: handing out a name, a pid (edit 8) or an alias (edit 14), each a name of a live
 * record: a live process, or an active alias, whose registry entry stays held, and so alive,
 * until the write is done. With the table full it writes nothing and counts the refusal, so
 * the peer holds nothing on the name and what it sends there reaches no one, as a send to a
 * dead process (design-domains.md, "Exports").
 */
void
erx_exports_hand_out(Eterm name, uint32_t peer)
{
	erx_alias_hold_t hold = { NULL };
	erx_exports_t *set = NULL;
	Process *p;
	put_t put = PUT_DONE;

	if (peer == 0)
		return;
	if (is_internal_pid_ref(name))
		set = erx_alias_hold(internal_ref_numbers(name), &hold);
	else if ((p = live_process(name)) != NULL)
		set = &p->erx_exports;
	if (set != NULL)
		put = holders_put(set, peer, ERX_RIGHT_SEND, PUT_IF_NONE);
	if (put == PUT_FULL)
		erts_atomic64_inc_nob(&refused);
	if (hold.stripe != NULL)
		erx_alias_release(&hold);
}

/* What peer holds on the active alias words; nothing once the alias has ended. */
static uint8_t
alias_rights(const uint32_t words[ERX_ALIAS_WORDS], uint32_t peer)
{
	erx_alias_hold_t hold;
	erx_exports_t *const set = erx_alias_hold(words, &hold);
	uint8_t rights;

	if (set == NULL)
		return (0);
	rights = holders_rights(set, peer);
	erx_alias_release(&hold);
	return (rights);
}

/* Writer 2: a spawn into the domain, before the child runs; a full table's refusal is counted. */
void
erx_exports_spawned(Process *child, DistEntry *dep)
{
	const uint32_t peer = erx_exports_peer_of(dep);
	put_t put = PUT_DONE;

	if (peer != 0)
		put = holders_put(&child->erx_exports, peer, CHILD_RIGHTS, PUT_WIDEN);
	if (put == PUT_FULL)
		erts_atomic64_inc_nob(&refused);
}

/* Writer 3: an explicit export by the name's owner, of exactly rights. */
static put_t
exports_set(erx_exports_t *set, uint32_t peer, uint8_t rights)
{
	return (holders_put(set, peer, rights, PUT_EXACT));
}

void
erx_exports_boot(uint32_t system)
{
	Process *const init = live_process(erts_init_process_id);

	if (init != NULL)
		(void)exports_set(&init->erx_exports, system, ERX_RIGHT_SEND);
	(void)exports_set(&domain_exports, system, ERX_RIGHT_SPAWN);
}

uint32_t
erx_exports_peer_of(DistEntry *dep)
{
	return (dep != NULL && dep != erts_this_dist_entry && erts_dist_peer_is_domain(dep) ?
	    (uint32_t)dep->creation : 0);
}

/* The process a target pid of this node names; the funnel's target rule checked the node. */
static Process *
target_process(const erx_etf_pid_t *pid)
{
	if (pid->id > ERTS_MAX_INTERNAL_PID_NUMBER || pid->serial > ERTS_MAX_INTERNAL_PID_SERIAL)
		return (NULL);
	return (erts_proc_lookup(make_internal_pid(make_pid_data((Uint)pid->serial, (Uint)pid->id))));
}

erx_funnel_hold_t
erx_exports_lookup(const void *peerp, const erx_funnel_name_t *name)
{
	const uint32_t peer = *(const uint32_t *)peerp;
	Process *p;

	switch (name->kind) {
	case ERX_FUNNEL_NAME_PID:
		p = target_process(name->pid);
		return ((erx_funnel_hold_t){ .rights = p == NULL ? 0 : holders_rights(&p->erx_exports, peer) });
	case ERX_FUNNEL_NAME_DOMAIN:
		return ((erx_funnel_hold_t){ .rights = holders_rights(&domain_exports, peer) });
	case ERX_FUNNEL_NAME_ALIAS:
		return ((erx_funnel_hold_t){ .rights = alias_rights(name->alias->words, peer) });
	}
	return ((erx_funnel_hold_t){ 0 });
}

/* ------------------------------------------------------------------ BIFs */

/* The atoms of the rights, in bit order. */
static const struct {
	uint8_t	 bit;
	Eterm	 atom;
} right_atoms[] = {
	{ ERX_RIGHT_SEND, am_send }, { ERX_RIGHT_LINK, am_link }, { ERX_RIGHT_EXIT, am_exit },
	{ ERX_RIGHT_SPAWN, am_spawn }, { ERX_RIGHT_INTRODUCE, am_introduce },
};
#define NRIGHTS	(sizeof(right_atoms) / sizeof(right_atoms[0]))

/* A proper list of right atoms as bits; false for anything else. */
static bool
rights_of(Eterm list, uint8_t *rights)
{
	Eterm *cell;
	size_t i, n = 0;

	*rights = 0;
	for (; is_list(list) && n < 64; list = CDR(cell), n++) {
		cell = list_val(list);
		for (i = 0; i < NRIGHTS && right_atoms[i].atom != CAR(cell); i++)
			;
		if (i == NRIGHTS)
			return (false);
		*rights |= right_atoms[i].bit;
	}
	return (is_nil(list));
}

/* A domain id: a positive integer of 32 bits. */
static bool
peer_of(Eterm term, uint32_t *peer)
{
	Uint value;

	if (!term_to_Uint(term, &value) || value == 0 || value > UINT32_MAX)
		return (false);
	*peer = (uint32_t)value;
	return (true);
}

/*
 * The holder set of one of this domain's own names, and the rights it may hold: a live
 * process of this runtime, or the domain's name {domain, Id} with this domain's own id.
 * NULL for any other term, another domain's name or a process that has exited included.
 * Any process of the domain may name any of them: the domain is one party (D4).
 */
static erx_exports_t *
own_name(Eterm name, uint8_t *allowed)
{
	Process *p;
	Eterm *tuple;
	Uint id;

	if (is_internal_pid(name)) {
		p = erts_proc_lookup(name);
		*allowed = PID_RIGHTS;
		return (p == NULL ? NULL : &p->erx_exports);
	}
	if (!is_tuple_arity(name, 2))
		return (NULL);
	tuple = tuple_val(name);
	if (tuple[1] != am_domain || !term_to_Uint(tuple[2], &id) || id != erts_this_node->creation)
		return (NULL);
	*allowed = DOMAIN_RIGHTS;
	return (&domain_exports);
}

/*
 * erx_dist:export(Name, Rights, Peer): sets what the domain Peer holds on Name, one of
 * this domain's own names, to exactly Rights, a list of send, link, exit and introduce
 * for a pid and spawn for the domain's name; [] ends Peer's hold. ok, {error, badarg}
 * for any other name or a malformed argument, {error, system_limit} when the table is
 * full.
 */
BIF_RETTYPE
erx_dist_export_3(BIF_ALIST_3)
{
	erx_exports_t *set;
	uint8_t rights, allowed;
	uint32_t peer;
	Eterm *hp;

	set = own_name(BIF_ARG_1, &allowed);
	if (set == NULL || !rights_of(BIF_ARG_2, &rights) || (rights & ~allowed) != 0 ||
	    !peer_of(BIF_ARG_3, &peer) || peer == erts_this_node->creation) {
		hp = HAlloc(BIF_P, 3);
		BIF_RET(TUPLE2(hp, am_error, am_badarg));
	}
	if (exports_set(set, peer, rights) == PUT_FULL) {
		hp = HAlloc(BIF_P, 3);
		BIF_RET(TUPLE2(hp, am_error, am_system_limit));
	}
	BIF_RET(am_ok);
}

/* erx_dist:exports(Name): [{Peer, Rights}] for one of this domain's own names. */
BIF_RETTYPE
erx_dist_exports_1(BIF_ALIST_1)
{
	erx_export_holder_t *copy = NULL;
	erx_exports_t *set;
	erts_mtx_t *lock;
	Eterm result = NIL, rights, *hp;
	uint8_t allowed;
	uint16_t n, i;
	size_t r;
	Uint need;

	set = own_name(BIF_ARG_1, &allowed);
	if (set == NULL)
		BIF_ERROR(BIF_P, BADARG);
	lock = stripe_of(set);
	erts_mtx_lock(lock);
	n = set->nholders;
	if (n != 0) {
		copy = erts_alloc(ERTS_ALC_T_TMP, n * sizeof(*copy));
		sys_memcpy(copy, set->holders, n * sizeof(*copy));
	}
	erts_mtx_unlock(lock);
	/* Each holder: a 2-tuple, its cons and a cons per right; a peer id is a small. */
	need = (Uint)n * 5;
	for (i = 0; i < n; i++)
		for (r = 0; r < NRIGHTS; r++)
			need += (copy[i].rights & right_atoms[r].bit) ? 2 : 0;
	hp = need == 0 ? NULL : HAlloc(BIF_P, need);
	for (i = 0; i < n; i++) {
		rights = NIL;
		for (r = NRIGHTS; r-- > 0;)
			if (copy[i].rights & right_atoms[r].bit) {
				rights = CONS(hp, right_atoms[r].atom, rights);
				hp += 2;
			}
		result = CONS(hp + 3, TUPLE2(hp, make_small(copy[i].peer), rights), result);
		hp += 5;
	}
	if (copy != NULL)
		erts_free(ERTS_ALC_T_TMP, copy);
	BIF_RET(result);
}

/* erx_dist:exports_refused(): how many holders a hand-out or a spawn could not write. */
BIF_RETTYPE
erx_dist_exports_refused_0(BIF_ALIST_0)
{
	const Uint64 n = (Uint64)erts_atomic64_read_nob(&refused);
	Uint size = 0;
	Eterm *hp;

	(void)erts_bld_uint64(NULL, &size, n);
	hp = HAlloc(BIF_P, size);
	BIF_RET(erts_bld_uint64(&hp, NULL, n));
}

/*
 * erx_dist:owner(Name): edit 16. The domain id a pid, reference or port claims, the
 * creation of its node: this domain's own for a local name, and for a name from another
 * domain the creation its sender encoded, which nothing checks. A process compares it
 * with the D of {erx_origin, D, Msg}, which the connection sets, to tell whether a
 * message came from the domain a name it holds claims. badarg for any other term.
 */
BIF_RETTYPE
erx_dist_owner_1(BIF_ALIST_1)
{
	const Eterm name = BIF_ARG_1;

	if (!is_pid(name) && !is_ref(name) && !is_port(name))
		BIF_ERROR(BIF_P, BADARG);
	BIF_RET(erts_make_integer(node_container_channel_no(name), BIF_P));
}
