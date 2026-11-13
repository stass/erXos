/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The NIF of erx_area (erlang/apps/erx/src/erx_area.erl): a connection's
 * pixel area mapped into the runtime (docs/design-display.md, "The pixel
 * area"). The connection agent maps the area the system domain gave the
 * domain when it maps the connection's sides, read-write for the writer
 * and read-only for the reader, and holds the mapping as a resource.
 * Every term that refers to the area, every image erx_memdraw built over
 * it (erx_area.h) and every lease of it keeps the resource alive; the
 * destructor, which runs only once the last of them is gone, unmaps the
 * area and only then tells the agent {erx_area_unmapped, Tag}, so the
 * agent answers that the connection is unmapped only when nothing in the
 * runtime or in a program can reach the area's memory any more. The
 * capability stays in its slot, as the sides' do; the system domain
 * deletes the object with the connection.
 *
 * A lease (erx_area.h) lends one whole range of a writable area to one
 * program. Its decisions are erx_area_lease_core.c's; this file holds
 * their effects. Every lease lent and not yet returned is in one table,
 * a list under table_lock, and the table holds the lease's one reference
 * from the lend to the return. Each state change is decided under the
 * lock; what follows a return, the message to the lender and the release
 * of the lease, which may run the destructors of the lease and the area,
 * runs after the lock is let go, so no destructor runs under it. The lock
 * order is the driver's port lock, then table_lock; the lease's down
 * callback and unlend take table_lock alone.
 *
 * zero/3, erx_pixels's one per-byte primitive, stores zero over a checked
 * range of whole pages of a writable area through the agent's mapping, so
 * a range rejoins erx_pixels's free list holding nothing of its last owner.
 */

#ifndef ERX_AREA_NIF_LOADABLE
#define STATIC_ERLANG_NIF 1
#endif

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdatomic.h>
#include <strings.h>

#include "erl_nif.h"
#include "erx_area.h"
#include "erx_area_lease_core.h"

#include "liberx/backend/api.h"

#ifdef ERX_AREA_HARNESS
#include "erx_area_harness.h"
#endif

typedef struct area {
	uint64_t addr;		/* the mapping, ERX_PAGE_SIZE-aligned */
	uint64_t bytes;
	uint64_t slot;		/* the area's object, which a lease maps into a program */
	bool writable;
	ErlNifPid owner;	/* the agent, told of the unmap */
	ErlNifEnv *tag_env;	/* holds tag */
	ERL_NIF_TERM tag;	/* the agent's name for this mapping */
} area_t;

struct erx_area_lease {
	erx_area_lease_t *next;	/* the table's list, under table_lock */
	erx_lease_state_t state; /* under table_lock */
	bool listed;		/* in the table; under table_lock */
	uint64_t number;	/* from 1, given when listed and never again; 0 before */
	area_t *area;		/* kept from the lend until the lease's destructor */
	uint64_t offset;	/* the range, checked against the area by the lend */
	uint64_t pages;
	ErlNifPid holder;	/* the range's owner, whose port alone takes the lease */
	ErlNifPid lender;	/* erx_pixels, sent {erx_area_returned, Tag, Number} */
	ErlNifEnv *tag_env;	/* keeps tag for the lease's life; freed by lease_dtor */
	ERL_NIF_TERM tag;	/* the lender's reference for this lease, set by the lend */
	ErlNifMonitor monitor;	/* of the holder */
};

static ErlNifResourceType *area_type, *lease_type;
static ERL_NIF_TERM atom_ok, atom_error, atom_einval, atom_enomem, atom_noproc, atom_read, atom_write,
    atom_unmapped, atom_returned;

/*
 * The table of leases. table_lock is made at load and published last, so a
 * take that finds it NULL runs before any lease can exist and answers none.
 */
static _Atomic(ErlNifMutex *) table_lock;
static erx_area_lease_t *table;
static uint64_t last_number;	/* under table_lock */

/* Runs once the last reference is gone: no image, term or lease reaches addr after it. */
static void
area_dtor(ErlNifEnv *env, void *object)
{
	area_t *area = object;

	(void)erx_vm_release(ERX_CAP_SELF, area->addr, area->bytes);
	(void)enif_send(env, &area->owner, area->tag_env,
	    enif_make_tuple2(area->tag_env, atom_unmapped, area->tag));
	enif_free_env(area->tag_env);
}

/* Runs once the lease is out of the table, or was never in it: lets go of the area. */
static void
lease_dtor(ErlNifEnv *env, void *object)
{
	erx_area_lease_t *lease = object;

	(void)env;
	enif_free_env(lease->tag_env);
	enif_release_resource(lease->area);
}

/* Under table_lock: the listed lease number, or NULL. */
static erx_area_lease_t *
table_find(uint64_t number)
{
	erx_area_lease_t *lease;

	for (lease = table; lease != NULL; lease = lease->next)
		if (lease->number == number)
			return (lease);
	return (NULL);
}

/* Under table_lock: takes a listed lease out of the list. */
static void
table_remove(erx_area_lease_t *lease)
{
	erx_area_lease_t **link;

	for (link = &table; *link != lease; link = &(*link)->next)
		;
	*link = lease->next;
	lease->next = NULL;
	lease->listed = false;
}

/*
 * Under table_lock: applies event to lease. True when the step is the
 * lease's return from the table, after which the caller, with the lock let
 * go, owes finish_return. A lease not yet listed is marked returned by its
 * holder's exit and nothing more, since the lend that lists it holds its
 * reference and answers noproc on seeing the mark.
 */
static bool
lease_apply(erx_area_lease_t *lease, erx_lease_event_t event, bool eligible, bool *taken)
{
	erx_lease_step_t step = erx_lease_step(lease->state, event, eligible);

	lease->state = step.next;
	if (taken != NULL)
		*taken = step.taken;
	if (!step.returned || !lease->listed)
		return (false);
	table_remove(lease);
	return (true);
}

/*
 * After a return, with table_lock let go: tells the lender and drops the
 * table's reference. enif_alloc_env aborts the runtime rather than answer
 * NULL in ERTS, so the message is always sent; the check guards the host
 * build only.
 */
static void
finish_return(ErlNifEnv *env, erx_area_lease_t *lease)
{
	ErlNifEnv *msg = enif_alloc_env();

	if (msg != NULL) {
		(void)enif_send(env, &lease->lender, msg,
		    enif_make_tuple3(msg, atom_returned, enif_make_copy(msg, lease->tag),
		    enif_make_uint64(msg, lease->number)));
		enif_free_env(msg);
	}
	enif_release_resource(lease);
}

/* The holder has exited: a held lease is returned, a taken one waits for its driver. */
static void
lease_down(ErlNifEnv *env, void *object, ErlNifPid *pid, ErlNifMonitor *monitor)
{
	erx_area_lease_t *lease = object;
	ErlNifMutex *lock = atomic_load_explicit(&table_lock, memory_order_acquire);
	bool returned;

	(void)pid;
	(void)monitor;
	enif_mutex_lock(lock);
	returned = lease_apply(lease, ERX_LEASE_HOLDER_EXIT, false, NULL);
	enif_mutex_unlock(lock);
	if (returned)
		finish_return(env, lease);
}

bool
erx_area_view(ErlNifEnv *env, ERL_NIF_TERM term, erx_area_view_t *out)
{
	area_t *area;

	if (!enif_get_resource(env, term, area_type, (void **)&area))
		return (false);
	out->resource = area;
	out->base = (uint8_t *)(uintptr_t)area->addr;
	out->bytes = (size_t)area->bytes;
	out->page = ERX_PAGE_SIZE;
	out->writable = area->writable;
	return (true);
}

/*
 * map(Slot, Bytes, Mode, Tag) -> {ok, Area} | {error, einval | enomem}:
 * maps the Bytes of the memory object in Slot, read-write for write and
 * read-only for read; the caller is told {erx_area_unmapped, Tag} once
 * the mapping is gone. einval for a length that is not whole pages, or
 * for an object the kernel refuses to map so.
 */
static ERL_NIF_TERM
map_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 slot, bytes;
	ErlNifEnv *tag_env;
	ERL_NIF_TERM term;
	area_t *area;
	uint64_t addr;
	bool writable;
	int status;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &slot) || !enif_get_uint64(env, argv[1], &bytes) ||
	    !(enif_is_identical(argv[2], atom_write) || enif_is_identical(argv[2], atom_read)))
		return (enif_make_badarg(env));
	writable = enif_is_identical(argv[2], atom_write);
	if (bytes == 0 || bytes % ERX_PAGE_SIZE != 0 || bytes > SIZE_MAX)
		return (enif_make_tuple2(env, atom_error, atom_einval));
	status = erx_vm_reserve(ERX_CAP_SELF, 0, bytes, 0, &addr);
	if (status == ERX_OK) {
		status = erx_vm_map(ERX_CAP_SELF, addr, bytes, slot, 0, writable ? ERX_PROT_RW : ERX_PROT_R);
		if (status != ERX_OK)
			(void)erx_vm_release(ERX_CAP_SELF, addr, bytes);
	}
	if (status != ERX_OK)
		return (enif_make_tuple2(env, atom_error, status == ERX_ENOMEM ? atom_enomem : atom_einval));
	/* The area is mapped: from here every failure releases it before answering. */
	tag_env = enif_alloc_env();
	area = tag_env == NULL ? NULL : enif_alloc_resource(area_type, sizeof *area);
	if (area == NULL) {
		if (tag_env != NULL)
			enif_free_env(tag_env);
		(void)erx_vm_release(ERX_CAP_SELF, addr, bytes);
		return (enif_make_tuple2(env, atom_error, atom_enomem));
	}
	area->addr = addr;
	area->bytes = bytes;
	area->slot = slot;
	area->writable = writable;
	(void)enif_self(env, &area->owner);
	area->tag_env = tag_env;
	area->tag = enif_make_copy(tag_env, argv[3]);
	term = enif_make_resource(env, area);
	enif_release_resource(area);
	return (enif_make_tuple2(env, atom_ok, term));
}

/*
 * lend(Area, Offset, Pages, Holder, Tag) -> {ok, Lease} | {error, einval |
 * noproc | enomem}: makes a held lease of Area's Pages pages from Offset
 * for the pid Holder, lent by the caller, and answers its number. Its
 * return sends the caller {erx_area_returned, Tag, Lease}: the number
 * counts up from 1 and is guessable, so the caller acts only on a return
 * that carries its own reference Tag. einval for a
 * range erx_lease_range_ok refuses; noproc, making no lease, for a holder
 * that has exited before its monitor is set or before the lease is listed.
 * Offset and Pages are integers from 0 to 2^64 - 1, Holder a local pid and
 * Tag a reference: anything else, or an Area that is no area, is badarg.
 *
 * The monitor is set before the lease is listed and outside table_lock,
 * since a down callback may wait for table_lock; a holder that exits in
 * between marks the unlisted lease returned, which the listing step sees.
 */
static ERL_NIF_TERM
lend_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifMutex *lock = atomic_load_explicit(&table_lock, memory_order_acquire);
	ErlNifUInt64 offset, pages;
	erx_area_lease_t *lease;
	ErlNifEnv *tag_env;
	ErlNifPid holder;
	area_t *area;
	uint64_t number;

	(void)argc;
	if (!enif_get_resource(env, argv[0], area_type, (void **)&area) || !enif_get_uint64(env, argv[1], &offset) ||
	    !enif_get_uint64(env, argv[2], &pages) || !enif_get_local_pid(env, argv[3], &holder) ||
	    !enif_is_ref(env, argv[4]))
		return (enif_make_badarg(env));
	if (!erx_lease_range_ok(offset, pages, ERX_PAGE_SIZE, area->bytes, area->writable))
		return (enif_make_tuple2(env, atom_error, atom_einval));
	tag_env = enif_alloc_env();
	lease = tag_env == NULL ? NULL : enif_alloc_resource(lease_type, sizeof *lease);
	if (lease == NULL) {
		if (tag_env != NULL)
			enif_free_env(tag_env);
		return (enif_make_tuple2(env, atom_error, atom_enomem));
	}
	*lease = (erx_area_lease_t){ .state = ERX_LEASE_HELD, .area = area, .offset = offset, .pages = pages,
	    .holder = holder, .tag_env = tag_env, .tag = enif_make_copy(tag_env, argv[4]) };
	enif_keep_resource(area);
	(void)enif_self(env, &lease->lender);
	if (enif_monitor_process(env, lease, &holder, &lease->monitor) != 0) {
		enif_release_resource(lease);
		return (enif_make_tuple2(env, atom_error, atom_noproc));
	}
	enif_mutex_lock(lock);
	if (lease->state != ERX_LEASE_HELD) {
		enif_mutex_unlock(lock);
		enif_release_resource(lease);
		return (enif_make_tuple2(env, atom_error, atom_noproc));
	}
	/* 2^64 - 1 lends would take centuries: the counter does not wrap. */
	number = ++last_number;
	lease->number = number;
	lease->listed = true;
	lease->next = table;
	table = lease;
	enif_mutex_unlock(lock);
	/* The table now holds the allocation's reference, until the return. */
	return (enif_make_tuple2(env, atom_ok, enif_make_uint64(env, number)));
}

/*
 * unlend(Lease) -> ok: returns the lease numbered Lease if it is held, and
 * does nothing to one taken, returned or never made. badarg for a term that
 * is no integer from 1 to 2^64 - 1.
 */
static ERL_NIF_TERM
unlend_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifMutex *lock = atomic_load_explicit(&table_lock, memory_order_acquire);
	erx_area_lease_t *lease;
	ErlNifUInt64 number;
	bool returned = false;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &number) || number == 0)
		return (enif_make_badarg(env));
	enif_mutex_lock(lock);
	lease = table_find(number);
	if (lease != NULL)
		returned = lease_apply(lease, ERX_LEASE_GIVE_BACK, false, NULL);
	enif_mutex_unlock(lock);
	if (returned)
		finish_return(env, lease);
	return (atom_ok);
}

/*
 * zero(Area, Offset, Pages) -> ok | {error, einval}: stores zero over Area's
 * Pages pages from Offset, through the connection agent's mapping, on a
 * dirty CPU scheduler. einval for a range erx_area_range_ok refuses, the
 * read-only area among them. Offset and Pages are integers from 0 to
 * 2^64 - 1: anything else, or an Area that is no area, is badarg. Only
 * erx_pixels calls it, on a range nothing else holds (area-mappers).
 */
static ERL_NIF_TERM
zero_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 offset, pages;
	area_t *area;

	(void)argc;
	if (!enif_get_resource(env, argv[0], area_type, (void **)&area) || !enif_get_uint64(env, argv[1], &offset) ||
	    !enif_get_uint64(env, argv[2], &pages))
		return (enif_make_badarg(env));
	if (!erx_area_range_ok(offset, pages, ERX_PAGE_SIZE, area->bytes, area->writable))
		return (enif_make_tuple2(env, atom_error, atom_einval));
	/* The range lies inside the mapping, whose bytes map/4 bounded by SIZE_MAX. */
	bzero((void *)(uintptr_t)(area->addr + offset), (size_t)(pages * ERX_PAGE_SIZE));
	return (atom_ok);
}

erx_area_lease_t *
erx_area_lease_take(uint64_t number, ERL_NIF_TERM owner, uint64_t pages)
{
	ErlNifMutex *lock = atomic_load_explicit(&table_lock, memory_order_acquire);
	erx_area_lease_t *lease;
	bool taken = false;

	if (lock == NULL)
		return (NULL);
	enif_mutex_lock(lock);
	lease = table_find(number);
	if (lease != NULL)
		(void)lease_apply(lease, ERX_LEASE_TAKE,
		    enif_is_identical(lease->holder.pid, owner) && lease->pages == pages, &taken);
	enif_mutex_unlock(lock);
	return (taken ? lease : NULL);
}

int
erx_area_lease_map(const erx_area_lease_t *lease, uint64_t space)
{
	uint64_t bytes = lease->pages * ERX_PAGE_SIZE, addr;
	int status;

	/* The lend bounded pages by ERX_PROG_MEM_BYTES, so bytes did not overflow. */
	status = erx_vm_reserve(space, ERX_PROG_MEM_BASE, bytes, ERX_VM_FIXED | ERX_VM_NOREPLACE, &addr);
	if (status != ERX_OK)
		return (status);
	status = erx_vm_map(space, addr, bytes, lease->area->slot, lease->offset, ERX_PROT_RW);
	if (status != ERX_OK)
		(void)erx_vm_release(space, addr, bytes);
	return (status);
}

void
erx_area_lease_return(erx_area_lease_t *lease)
{
	ErlNifMutex *lock = atomic_load_explicit(&table_lock, memory_order_acquire);
	bool returned;

	enif_mutex_lock(lock);
	returned = lease_apply(lease, ERX_LEASE_DRIVER_RETURN, false, NULL);
	enif_mutex_unlock(lock);
	if (returned)
		finish_return(NULL, lease);
}

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	ErlNifResourceTypeInit lease_init = { .dtor = lease_dtor, .down = lease_down };
	ErlNifMutex *lock;

	(void)priv;
	(void)info;
	area_type = enif_open_resource_type(env, NULL, "erx_area", area_dtor, ERL_NIF_RT_CREATE, NULL);
	lease_type = enif_open_resource_type_x(env, "erx_area_lease", &lease_init, ERL_NIF_RT_CREATE, NULL);
	if (area_type == NULL || lease_type == NULL)
		return (1);
	atom_ok = enif_make_atom(env, "ok");
	atom_error = enif_make_atom(env, "error");
	atom_einval = enif_make_atom(env, "einval");
	atom_enomem = enif_make_atom(env, "enomem");
	atom_noproc = enif_make_atom(env, "noproc");
	atom_read = enif_make_atom(env, "read");
	atom_write = enif_make_atom(env, "write");
	atom_unmapped = enif_make_atom(env, "erx_area_unmapped");
	atom_returned = enif_make_atom(env, "erx_area_returned");
	lock = enif_mutex_create("erx_area_leases");
	if (lock == NULL)
		return (1);
	atomic_store_explicit(&table_lock, lock, memory_order_release);
	return (0);
}

#ifdef ERX_AREA_HARNESS
/*
 * The host harness's one view into the table
 * (test/display/erx_area_harness.h): the count of leases listed, read
 * under the lock. Built only with ERX_AREA_HARNESS.
 */
unsigned
erx_area_harness_lease_count(void)
{
	ErlNifMutex *lock = atomic_load_explicit(&table_lock, memory_order_acquire);
	unsigned count = 0;

	enif_mutex_lock(lock);
	for (erx_area_lease_t *lease = table; lease != NULL; lease = lease->next)
		count++;
	enif_mutex_unlock(lock);
	return (count);
}
#endif

static ErlNifFunc functions[] = {
	{ "map", 4, map_nif, 0 },
	{ "lend", 5, lend_nif, 0 },
	{ "unlend", 1, unlend_nif, 0 },
	{ "zero", 3, zero_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
#ifdef ERX_AREA_HARNESS
	/* test/display/erx_area_harness.c: the driver's calls, for the host tests. */
	ERX_AREA_HARNESS_FUNCTIONS
#endif
};

ERL_NIF_INIT(erx_area, functions, load, NULL, NULL, NULL)
