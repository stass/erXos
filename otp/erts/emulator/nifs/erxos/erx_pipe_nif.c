/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The session's pipe NIF, module erx_pipe_nif (docs/design-pipes.md, "The
 * session's pipe NIF"): the pipe server's objects and the session
 * processes' ends.
 *
 * Objects.  make_lock/0, make_lane/1 and make_bell/3 create a pipe's
 * lock page, a lane's ring and reader page, and a doorbell bound to the
 * session's group with the label the event table registers for the end's
 * process, all charged to the session's budget.  Each is a resource whose
 * capability the server holds; an end that uses it keeps it too.  close/1
 * drops the server's hold, and the capability closes when no end holds it
 * either, or when the resource is collected, whichever comes first.  The
 * NIF never deletes memory: a mapping keeps its object, so no holder of a
 * pipe's memory can make another fault.
 *
 * Ends.  open_end/3 makes an end owned by one process from a descriptor
 * whose objects are resources: it maps the pages the end uses (a write
 * end its ring read-write and its reader page read-only; a read end every
 * lane's ring read-only, their reader pages and the lock page read-write)
 * and keeps the doorbells it rings.  It monitors the owner and the server:
 * the owner's exit closes the end and tells the server {closed, Holder,
 * Pipe, End}; the server's makes the end lost and tells the owner
 * {pipe_server_lost, End}.  read/2 and write/2 run the pipe core
 * (liberx/erx_pipe_run.c) and return would_block where a program's call
 * would wait, with the same position or bit published, so the owner waits
 * for its doorbell's message {erx_pipe_ready, Pipe, End}.  apply/2 takes
 * the server's report for the end.
 */

#define STATIC_ERLANG_NIF 1

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <errno.h>
#include <stdatomic.h>
#include <string.h>

#include "erl_nif.h"
#include "erx_event.h"

#include "erx/pipe_run.h"
#include "liberx/backend/api.h"

/* Every page of a pipe but a ring's data area is one page. */
#define PIPE_PAGE	4096u
/* The most bytes one read/2 returns, and one write/2 takes, so a call's work is bounded. */
#define PIPE_READ_MAX	(16u * ERX_PIPE_BUF)
#define PIPE_WRITE_MAX	(16u * ERX_PIPE_BUF)

typedef enum pipe_obj_kind {
	OBJ_LOCK,
	OBJ_RING,
	OBJ_RPAGE,
	OBJ_BELL
} pipe_obj_kind_t;

/*
 * The server's capability to one object.  holds counts the server's hold
 * and each end's; the capability closes at zero or in the destructor.
 * Only the lock page has a mapping of the server's own.
 */
typedef struct pipe_obj {
	pipe_obj_kind_t	 kind;
	uint64_t	 cap;
	uint64_t	 size;
	uint64_t	 map;		/* the server's mapping of the lock page */
	uint32_t	 label;		/* a doorbell's registered label */
	unsigned	 holds;
	bool		 server;	/* the server still holds it */
	bool		 closed;
} pipe_obj_t;

/* A read end's lane: the objects it keeps and their mappings. */
typedef struct pipe_lane {
	pipe_obj_t	*ring;
	pipe_obj_t	*rpage;
	pipe_obj_t	*bell;		/* its writer's doorbell while open */
	uint64_t	 ring_map;
	uint64_t	 rpage_map;
} pipe_lane_t;

typedef struct pipe_end {
	ErlNifMutex	*mutex;
	bool		 write;
	bool		 closed;
	uint32_t	 pipe;
	uint32_t	 end;
	ErlNifPid	 owner;
	ErlNifPid	 server;
	ErlNifMonitor	 owner_mon;
	ErlNifMonitor	 server_mon;
	pipe_obj_t	*peers[ERX_PIPE_READERS_MAX];	/* read ends' doorbells */
	/* A write end. */
	erx_pipe_wstate_t w;
	pipe_obj_t	*ring;
	pipe_obj_t	*rpage;
	uint64_t	 ring_map;
	uint64_t	 rpage_map;
	/* A read end. */
	erx_pipe_rstate_t r;
	pipe_obj_t	*lock;
	uint64_t	 lock_map;
	pipe_lane_t	*lanes;
	erx_pipe_rlane_t *rlanes;
	erx_pipe_rmap_t	*maps;
	uint32_t	 room;		/* lanes allocated */
	/* The drained lanes found by the call in progress, sent after it. */
	uint32_t	 ndrained;
	uint32_t	*drained;
} pipe_end_t;

static ErlNifResourceType *obj_type;
static ErlNifResourceType *end_type;
static ErlNifMutex *obj_mutex;

static ERL_NIF_TERM atom_ok, atom_error, atom_enomem, atom_eof, atom_eio,
    atom_epipe, atom_would_block, atom_closed, atom_drained, atom_process,
    atom_lost, atom_ready, atom_write, atom_read, atom_open, atom_gone;

static ERL_NIF_TERM
error_term(ErlNifEnv *env, ERL_NIF_TERM reason)
{
	return (enif_make_tuple2(env, atom_error, reason));
}

/* ---------------------------------------------------------------------
 * Objects */

static int
map_object(uint64_t cap, uint64_t size, uint32_t prot, uint64_t *addr)
{
	int status;

	status = erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, addr);
	if (status == ERX_OK) {
		status = erx_vm_map(ERX_CAP_SELF, *addr, size, cap, 0, prot);
		if (status != ERX_OK)
			(void)erx_vm_release(ERX_CAP_SELF, *addr, size);
	}
	return (status);
}

static void
unmap_object(uint64_t *addr, uint64_t size)
{
	if (*addr != 0)
		(void)erx_vm_release(ERX_CAP_SELF, *addr, size);
	*addr = 0;
}

/* Closes an object's capability once; the caller holds obj_mutex. */
static void
obj_close_locked(pipe_obj_t *obj)
{
	if (obj->closed)
		return;
	obj->closed = true;
	if (obj->kind == OBJ_BELL) {
		(void)erx_irq_bind(obj->cap, ERX_CAP_NULL, 0);
		erx_event_unregister(obj->label);
	}
	unmap_object(&obj->map, obj->size);
	(void)erx_cap_close(obj->cap);
}

static void
obj_keep(pipe_obj_t *obj)
{
	enif_mutex_lock(obj_mutex);
	obj->holds++;
	enif_mutex_unlock(obj_mutex);
	enif_keep_resource(obj);
}

static void
obj_drop(pipe_obj_t **slot)
{
	pipe_obj_t *obj = *slot;

	if (obj == NULL)
		return;
	*slot = NULL;
	enif_mutex_lock(obj_mutex);
	if (--obj->holds == 0)
		obj_close_locked(obj);
	enif_mutex_unlock(obj_mutex);
	enif_release_resource(obj);
}

static void
obj_dtor(ErlNifEnv *env, void *data)
{
	(void)env;
	enif_mutex_lock(obj_mutex);
	obj_close_locked(data);
	enif_mutex_unlock(obj_mutex);
}

static pipe_obj_t *
obj_new(pipe_obj_kind_t kind, uint64_t cap, uint64_t size)
{
	pipe_obj_t *obj;

	obj = enif_alloc_resource(obj_type, sizeof(*obj));
	if (obj == NULL)
		return (NULL);
	memset(obj, 0, sizeof(*obj));
	obj->kind = kind;
	obj->cap = cap;
	obj->size = size;
	obj->holds = 1;
	obj->server = true;
	return (obj);
}

static ERL_NIF_TERM
obj_term(ErlNifEnv *env, pipe_obj_t *obj)
{
	ERL_NIF_TERM term = enif_make_resource(env, obj);

	enif_release_resource(obj);
	return (term);
}

static bool
get_obj(ErlNifEnv *env, ERL_NIF_TERM term, pipe_obj_kind_t kind,
    pipe_obj_t **obj)
{
	if (!enif_get_resource(env, term, obj_type, (void **)obj))
		return (false);
	return ((*obj)->kind == kind && !(*obj)->closed);
}

static bool
mem_new(pipe_obj_kind_t kind, uint64_t size, pipe_obj_t **obj)
{
	uint64_t cap;

	if (erx_mem_create(ERX_CAP_NULL, size, 0, &cap) != ERX_OK)
		return (false);
	if ((*obj = obj_new(kind, cap, size)) == NULL) {
		(void)erx_cap_close(cap);
		return (false);
	}
	return (true);
}

static ERL_NIF_TERM
make_lock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	pipe_obj_t *lock;

	(void)argc;
	(void)argv;
	if (!mem_new(OBJ_LOCK, PIPE_PAGE, &lock))
		return (error_term(env, atom_enomem));
	/* The server stores wends and frees the lock through its own mapping. */
	if (map_object(lock->cap, PIPE_PAGE, ERX_PROT_RW, &lock->map) != ERX_OK) {
		lock->map = 0;
		enif_release_resource(lock);
		return (error_term(env, atom_enomem));
	}
	return (enif_make_tuple2(env, atom_ok, obj_term(env, lock)));
}

static ERL_NIF_TERM
make_lane(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	pipe_obj_t *ring, *rpage;
	unsigned size;

	(void)argc;
	if (!enif_get_uint(env, argv[0], &size) ||
	    (size != ERX_PIPE_RING_FIRST && size != ERX_PIPE_RING_NEXT))
		return (enif_make_badarg(env));
	if (!mem_new(OBJ_RING, ERX_PIPE_RING_DATA + (uint64_t)size, &ring))
		return (error_term(env, atom_enomem));
	if (!mem_new(OBJ_RPAGE, PIPE_PAGE, &rpage)) {
		enif_release_resource(ring);
		return (error_term(env, atom_enomem));
	}
	return (enif_make_tuple3(env, atom_ok, obj_term(env, ring),
	    obj_term(env, rpage)));
}

/* A doorbell bound to the session's group, delivered to Pid as {erx_pipe_ready, Pipe, End}. */
static ERL_NIF_TERM
make_bell(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifPid pid;
	pipe_obj_t *bell;
	uint64_t cap;
	unsigned pipe, end;
	ERL_NIF_TERM message;

	(void)argc;
	if (!enif_get_local_pid(env, argv[0], &pid) ||
	    !enif_get_uint(env, argv[1], &pipe) ||
	    !enif_get_uint(env, argv[2], &end))
		return (enif_make_badarg(env));
	if (erx_irq_create(ERX_CAP_NULL, 0, ERX_IRQ_SOFT, 0, &cap) != ERX_OK)
		return (error_term(env, atom_enomem));
	if ((bell = obj_new(OBJ_BELL, cap, 0)) == NULL) {
		(void)erx_cap_close(cap);
		return (error_term(env, atom_enomem));
	}
	message = enif_make_tuple3(env, atom_ready, argv[1], argv[2]);
	if (erx_event_register_process(&pid, message, &bell->label) != ERX_OK) {
		bell->closed = true;
		(void)erx_cap_close(cap);
		enif_release_resource(bell);
		return (error_term(env, atom_enomem));
	}
	if (erx_irq_bind(cap, ERX_CAP_SELF, bell->label) != ERX_OK) {
		enif_release_resource(bell);	/* the destructor unregisters */
		return (error_term(env, atom_enomem));
	}
	return (enif_make_tuple2(env, atom_ok, obj_term(env, bell)));
}

/* Stores a write end's number in wends with release order, before any install of it. */
static ERL_NIF_TERM
store_wends(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	pipe_obj_t *lock;
	unsigned wends;

	(void)argc;
	if (!enif_get_resource(env, argv[0], obj_type, (void **)&lock) ||
	    lock->kind != OBJ_LOCK || !enif_get_uint(env, argv[1], &wends))
		return (enif_make_badarg(env));
	/* Under obj_mutex, so the mapping cannot be released under the store. */
	enif_mutex_lock(obj_mutex);
	if (lock->closed || lock->map == 0) {
		enif_mutex_unlock(obj_mutex);
		return (enif_make_badarg(env));
	}
	(void)erx_pipe_lock_wends_store((erx_pipe_lock_t *)(uintptr_t)lock->map,
	    wends);
	enif_mutex_unlock(obj_mutex);
	return (atom_ok);
}

/* Frees the reader lock a gone read end held: one CAS of owner from 1 + rix to 0. */
static ERL_NIF_TERM
free_lock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_pipe_lock_t *page;
	pipe_obj_t *lock;
	uint32_t expected;
	unsigned rix;

	(void)argc;
	if (!enif_get_resource(env, argv[0], obj_type, (void **)&lock) ||
	    lock->kind != OBJ_LOCK || !enif_get_uint(env, argv[1], &rix) ||
	    rix >= ERX_PIPE_READERS_MAX)
		return (enif_make_badarg(env));
	/* Under obj_mutex, so the mapping cannot be released under the CAS. */
	enif_mutex_lock(obj_mutex);
	if (lock->closed || lock->map == 0) {
		enif_mutex_unlock(obj_mutex);
		return (enif_make_badarg(env));
	}
	page = (erx_pipe_lock_t *)(uintptr_t)lock->map;
	expected = 1 + rix;
	(void)atomic_compare_exchange_strong_explicit(&page->owner, &expected,
	    0, memory_order_acq_rel, memory_order_relaxed);
	enif_mutex_unlock(obj_mutex);
	return (atom_ok);
}

/* ---------------------------------------------------------------------
 * Ends */

/*
 * A record's stamp is the time page's monotonic clock, as a program's ends stamp
 * theirs: a reader merges records from both by stamp, so both must read the one
 * clock.  ERTS's monotonic time may carry a per-runtime offset and is not that clock.
 */
static uint64_t
end_clock(void *ctx)
{
	(void)ctx;
	return (erx_clock_ns());
}

static void
ring_bell(pipe_obj_t *bell)
{
	/* A ring of a doorbell whose end has gone fails, which is harmless. */
	if (bell != NULL)
		(void)erx_irq_trigger(bell->cap);
}

static void
end_ring_reader(void *ctx, uint32_t rix)
{
	pipe_end_t *e = ctx;

	if (rix < ERX_PIPE_READERS_MAX)
		ring_bell(e->peers[rix]);
}

static void
end_ring_writer(void *ctx, uint32_t lane)
{
	pipe_end_t *e = ctx;

	if (lane < e->r.nlanes)
		ring_bell(e->lanes[lane].bell);
}

static void
lane_release(pipe_end_t *e, uint32_t i)
{
	pipe_lane_t *l = &e->lanes[i];

	if (l->ring != NULL)
		unmap_object(&l->ring_map, l->ring->size);
	if (l->rpage != NULL)
		unmap_object(&l->rpage_map, PIPE_PAGE);
	obj_drop(&l->ring);
	obj_drop(&l->rpage);
	obj_drop(&l->bell);
	memset(&e->maps[i], 0, sizeof(e->maps[i]));
}

/* A drained lane is let go at once and reported after the call. */
static void
end_drained(void *ctx, uint32_t lane)
{
	pipe_end_t *e = ctx;

	lane_release(e, lane);
	e->drained[e->ndrained++] = e->rlanes[lane].wend;
}

static void
end_broken(void *ctx, uint32_t lane, uint64_t fault)
{
	pipe_end_t *e = ctx;

	enif_fprintf(stderr, "erx_pipe: pipe %u write end %u broken: fault %u\r\n",
	    e->pipe, e->rlanes[lane].wend, (unsigned)fault);
}

static const erx_pipe_fx_t *
end_fx(pipe_end_t *e, erx_pipe_fx_t *fx)
{
	*fx = (erx_pipe_fx_t){ e, end_clock, end_ring_reader, end_ring_writer,
	    end_drained, end_broken };
	return (fx);
}

/*
 * Makes room for one more lane.  Each array is grown on its own and kept on
 * success, so a failure leaves every array valid for at least nlanes lanes,
 * which is all end_release reads.
 */
static bool
grow(void **array, size_t size)
{
	void *p;

	if ((p = enif_realloc(*array, size)) == NULL)
		return (false);
	*array = p;
	return (true);
}

static bool
lanes_grow(pipe_end_t *e)
{
	uint32_t room;
	bool ok;

	if (e->r.nlanes < e->room)
		return (true);
	if (e->room > UINT32_MAX / 2)
		return (false);
	room = e->room == 0 ? 4 : 2 * e->room;
	ok = grow((void **)&e->lanes, room * sizeof(*e->lanes)) &&
	    grow((void **)&e->rlanes, room * sizeof(*e->rlanes)) &&
	    grow((void **)&e->maps, room * sizeof(*e->maps)) &&
	    grow((void **)&e->drained, room * sizeof(*e->drained));
	e->r.lanes = e->rlanes;
	if (ok)
		e->room = room;
	return (ok);
}

/* Adds a lane to a read end: {Wend, Ring, RPage, Size, {open, Bell} | gone}. */
static bool
lane_add(ErlNifEnv *env, pipe_end_t *e, ERL_NIF_TERM term)
{
	const ERL_NIF_TERM *t, *st;
	pipe_obj_t *ring, *rpage, *bell = NULL;
	unsigned wend, size;
	int arity, sarity;
	pipe_lane_t *l;
	uint32_t i;

	if (!enif_get_tuple(env, term, &arity, &t) || arity != 5 ||
	    !enif_get_uint(env, t[0], &wend) || wend == 0 ||
	    !get_obj(env, t[1], OBJ_RING, &ring) ||
	    !get_obj(env, t[2], OBJ_RPAGE, &rpage) ||
	    !enif_get_uint(env, t[3], &size) ||
	    ring->size != ERX_PIPE_RING_DATA + (uint64_t)size)
		return (false);
	if (enif_get_tuple(env, t[4], &sarity, &st)) {
		if (sarity != 2 || enif_compare(st[0], atom_open) != 0 ||
		    !get_obj(env, st[1], OBJ_BELL, &bell))
			return (false);
	} else if (enif_compare(t[4], atom_gone) != 0)
		return (false);
	for (i = 0; i < e->r.nlanes; i++)
		if (e->rlanes[i].wend == wend)
			return (false);
	if (!lanes_grow(e))
		return (false);
	i = e->r.nlanes;
	l = &e->lanes[i];
	memset(l, 0, sizeof(*l));
	memset(&e->rlanes[i], 0, sizeof(e->rlanes[i]));
	memset(&e->maps[i], 0, sizeof(e->maps[i]));
	if (map_object(ring->cap, ring->size, ERX_PROT_R, &l->ring_map) != ERX_OK)
		return (false);
	if (map_object(rpage->cap, PIPE_PAGE, ERX_PROT_RW, &l->rpage_map) !=
	    ERX_OK) {
		unmap_object(&l->ring_map, ring->size);
		return (false);
	}
	obj_keep(ring);
	obj_keep(rpage);
	l->ring = ring;
	l->rpage = rpage;
	if (bell != NULL) {
		obj_keep(bell);
		l->bell = bell;
	}
	e->rlanes[i].wend = wend;
	e->rlanes[i].size = size;
	e->rlanes[i].writer = bell != NULL ? ERX_PIPE_WRITER_OPEN :
	    ERX_PIPE_WRITER_GONE;
	e->maps[i] = (erx_pipe_rmap_t){
	    (const erx_lane_hdr_t *)(uintptr_t)l->ring_map,
	    (const unsigned char *)(uintptr_t)(l->ring_map + ERX_PIPE_RING_DATA),
	    (erx_pipe_rpage_t *)(uintptr_t)l->rpage_map };
	e->r.nlanes++;
	return (true);
}

/* Keeps a peer read end's doorbell: {Rix, Bell}. */
static bool
peer_add(ErlNifEnv *env, pipe_end_t *e, ERL_NIF_TERM term)
{
	const ERL_NIF_TERM *t;
	pipe_obj_t *bell;
	unsigned rix;
	int arity;

	if (!enif_get_tuple(env, term, &arity, &t) || arity != 2 ||
	    !enif_get_uint(env, t[0], &rix) || rix >= ERX_PIPE_READERS_MAX ||
	    !get_obj(env, t[1], OBJ_BELL, &bell))
		return (false);
	obj_drop(&e->peers[rix]);
	obj_keep(bell);
	e->peers[rix] = bell;
	return (true);
}

static bool
map_get(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, ERL_NIF_TERM *value)
{
	return (enif_get_map_value(env, map, enif_make_atom(env, key), value));
}

static bool
list_each(ErlNifEnv *env, pipe_end_t *e, ERL_NIF_TERM list,
    bool (*add)(ErlNifEnv *, pipe_end_t *, ERL_NIF_TERM))
{
	ERL_NIF_TERM head;

	while (enif_get_list_cell(env, list, &head, &list))
		if (!add(env, e, head))
			return (false);
	return (enif_is_empty_list(env, list));
}

/* {pipe, write, _, #{ring, rpage, size, readers}} */
static bool
open_write(ErlNifEnv *env, pipe_end_t *e, ERL_NIF_TERM m)
{
	ERL_NIF_TERM ring_t, rpage_t, size_t_, readers;
	unsigned size, n;

	if (!map_get(env, m, "ring", &ring_t) ||
	    !map_get(env, m, "rpage", &rpage_t) ||
	    !map_get(env, m, "size", &size_t_) ||
	    !map_get(env, m, "readers", &readers) ||
	    !get_obj(env, ring_t, OBJ_RING, &e->ring) ||
	    !get_obj(env, rpage_t, OBJ_RPAGE, &e->rpage) ||
	    !enif_get_uint(env, size_t_, &size) ||
	    e->ring->size != ERX_PIPE_RING_DATA + (uint64_t)size ||
	    !enif_get_list_length(env, readers, &n)) {
		e->ring = e->rpage = NULL;
		return (false);
	}
	if (map_object(e->ring->cap, e->ring->size, ERX_PROT_RW, &e->ring_map) !=
	    ERX_OK) {
		e->ring = e->rpage = NULL;
		return (false);
	}
	if (map_object(e->rpage->cap, PIPE_PAGE, ERX_PROT_R, &e->rpage_map) !=
	    ERX_OK) {
		unmap_object(&e->ring_map, e->ring->size);
		e->ring = e->rpage = NULL;
		return (false);
	}
	obj_keep(e->ring);
	obj_keep(e->rpage);
	e->w.size = size;
	e->w.chunk = ERX_PIPE_BUF;
	e->w.readers = n;
	return (list_each(env, e, readers, peer_add));
}

/* {pipe, read, _, #{rix, lock, wends, writers, readers}} */
static bool
open_read(ErlNifEnv *env, pipe_end_t *e, ERL_NIF_TERM m)
{
	ERL_NIF_TERM rix_t, lock_t, wends_t, writers, readers;
	unsigned rix, wends;

	if (!map_get(env, m, "rix", &rix_t) || !map_get(env, m, "lock", &lock_t) ||
	    !map_get(env, m, "wends", &wends_t) ||
	    !map_get(env, m, "writers", &writers) ||
	    !map_get(env, m, "readers", &readers) ||
	    !enif_get_uint(env, rix_t, &rix) || rix >= ERX_PIPE_READERS_MAX ||
	    !enif_get_uint(env, wends_t, &wends) ||
	    !get_obj(env, lock_t, OBJ_LOCK, &e->lock)) {
		e->lock = NULL;
		return (false);
	}
	if (map_object(e->lock->cap, PIPE_PAGE, ERX_PROT_RW, &e->lock_map) !=
	    ERX_OK) {
		e->lock = NULL;
		return (false);
	}
	obj_keep(e->lock);
	e->r.rix = rix;
	e->r.known = wends;
	e->r.batches = ERX_PIPE_BATCHES;
	return (list_each(env, e, writers, lane_add) &&
	    list_each(env, e, readers, peer_add));
}

/*
 * Lets go of every mapping and object of an end; the caller holds its mutex.
 * A read end first ends the wait its last read left in progress, by a read
 * of 0 bytes, so no bit of its index stays set for the next holder.
 */
static void
end_release(pipe_end_t *e)
{
	erx_pipe_fx_t fx;
	uint32_t i;

	if (!e->write && e->lock != NULL) {
		erx_pipe_rstart(&e->r, 0);
		(void)erx_pipe_rrun(&e->r, e->maps,
		    (erx_pipe_lock_t *)(uintptr_t)e->lock_map, NULL, end_fx(e, &fx));
	}
	if (e->write) {
		if (e->ring != NULL)
			unmap_object(&e->ring_map, e->ring->size);
		if (e->rpage != NULL)
			unmap_object(&e->rpage_map, PIPE_PAGE);
		obj_drop(&e->ring);
		obj_drop(&e->rpage);
	} else {
		for (i = 0; i < e->r.nlanes; i++)
			lane_release(e, i);
		if (e->lock != NULL)
			unmap_object(&e->lock_map, PIPE_PAGE);
		obj_drop(&e->lock);
	}
	for (i = 0; i < ERX_PIPE_READERS_MAX; i++)
		obj_drop(&e->peers[i]);
	e->closed = true;
}

/* Tells the server the end is closed: {closed, {process, Owner}, Pipe, End}. */
static void
send_closed(ErlNifEnv *env, pipe_end_t *e)
{
	ErlNifEnv *msg;

	if ((msg = enif_alloc_env()) == NULL)
		return;
	(void)enif_send(env, &e->server, msg, enif_make_tuple4(msg, atom_closed,
	    enif_make_tuple2(msg, atom_process, enif_make_pid(msg, &e->owner)),
	    enif_make_uint(msg, e->pipe), enif_make_uint(msg, e->end)));
	enif_free_env(msg);
}

/* Closes the end once and tells the server; the caller holds its mutex. */
static void
end_close_locked(ErlNifEnv *env, pipe_end_t *e)
{
	if (e->closed)
		return;
	end_release(e);
	(void)enif_demonitor_process(env, e, &e->owner_mon);
	(void)enif_demonitor_process(env, e, &e->server_mon);
	send_closed(env, e);
}

static void
end_down(ErlNifEnv *env, void *data, ErlNifPid *pid, ErlNifMonitor *mon)
{
	pipe_end_t *e = data;
	ErlNifEnv *msg;

	(void)pid;
	enif_mutex_lock(e->mutex);
	if (enif_compare_monitors(mon, &e->owner_mon) == 0) {
		end_close_locked(env, e);
	} else if (!e->closed) {
		/* The server is gone: the pipe is lost, never a false end of stream. */
		e->w.lost = true;
		e->r.lost = true;
		if ((msg = enif_alloc_env()) != NULL) {
			(void)enif_send(env, &e->owner, msg, enif_make_tuple2(msg,
			    atom_lost, enif_make_resource(msg, e)));
			enif_free_env(msg);
		}
	}
	enif_mutex_unlock(e->mutex);
}

static void
end_dtor(ErlNifEnv *env, void *data)
{
	pipe_end_t *e = data;

	/*
	 * The server keeps every end it opened, so an end is collected only
	 * once the server has gone: no one is left to tell.
	 */
	(void)env;
	if (!e->closed)
		end_release(e);
	enif_free(e->lanes);
	enif_free(e->rlanes);
	enif_free(e->maps);
	enif_free(e->drained);
	if (e->mutex != NULL)
		enif_mutex_destroy(e->mutex);
}

/* open_end(Owner, Server, Descriptor) -> {ok, End} | {error, enomem} */
static ERL_NIF_TERM
open_end(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const ERL_NIF_TERM *d, *ids;
	unsigned pipe, end;
	int arity, idarity;
	pipe_end_t *e;
	ERL_NIF_TERM term;
	bool ok;

	(void)argc;
	if (!enif_get_tuple(env, argv[2], &arity, &d) || arity != 4 ||
	    !enif_get_tuple(env, d[2], &idarity, &ids) || idarity != 2 ||
	    !enif_get_uint(env, ids[0], &pipe) || !enif_get_uint(env, ids[1], &end) ||
	    !enif_is_map(env, d[3]) ||
	    (enif_compare(d[1], atom_write) != 0 && enif_compare(d[1], atom_read) != 0))
		return (enif_make_badarg(env));
	if ((e = enif_alloc_resource(end_type, sizeof(*e))) == NULL)
		return (error_term(env, atom_enomem));
	memset(e, 0, sizeof(*e));
	e->write = enif_compare(d[1], atom_write) == 0;
	e->pipe = pipe;
	e->end = end;
	if (!enif_get_local_pid(env, argv[0], &e->owner) ||
	    !enif_get_local_pid(env, argv[1], &e->server)) {
		e->closed = true;
		enif_release_resource(e);
		return (enif_make_badarg(env));
	}
	e->mutex = enif_mutex_create("erx_pipe_end");
	ok = e->mutex != NULL &&
	    (e->write ? open_write(env, e, d[3]) : open_read(env, e, d[3])) &&
	    enif_monitor_process(env, e, &e->owner, &e->owner_mon) == 0;
	if (ok && enif_monitor_process(env, e, &e->server, &e->server_mon) != 0) {
		(void)enif_demonitor_process(env, e, &e->owner_mon);
		ok = false;
	}
	if (!ok) {
		end_release(e);
		enif_release_resource(e);
		return (error_term(env, atom_enomem));
	}
	term = enif_make_resource(env, e);
	enif_release_resource(e);
	return (enif_make_tuple2(env, atom_ok, term));
}

static bool
get_owned_end(ErlNifEnv *env, ERL_NIF_TERM term, pipe_end_t **e)
{
	ErlNifPid self;

	if (!enif_get_resource(env, term, end_type, (void **)e) ||
	    enif_self(env, &self) == NULL)
		return (false);
	return (enif_compare_pids(&self, &(*e)->owner) == 0);
}

/*
 * An end the caller may close: its owner's, or the server's, which closes
 * the ends of a reply it could not open whole before their owner has them.
 */
static bool
get_closable_end(ErlNifEnv *env, ERL_NIF_TERM term, pipe_end_t **e)
{
	ErlNifPid self;

	if (!enif_get_resource(env, term, end_type, (void **)e) ||
	    enif_self(env, &self) == NULL)
		return (false);
	return (enif_compare_pids(&self, &(*e)->owner) == 0 ||
	    enif_compare_pids(&self, &(*e)->server) == 0);
}

/* An end whose server is the caller: only the server applies reports to it. */
static bool
get_served_end(ErlNifEnv *env, ERL_NIF_TERM term, pipe_end_t **e)
{
	ErlNifPid self;

	if (!enif_get_resource(env, term, end_type, (void **)e) ||
	    enif_self(env, &self) == NULL)
		return (false);
	return (enif_compare_pids(&self, &(*e)->server) == 0);
}

static ERL_NIF_TERM
result_term(ErlNifEnv *env, int64_t result)
{
	switch (result) {
	case -EPIPE:
		return (error_term(env, atom_epipe));
	default:
		return (error_term(env, atom_eio));
	}
}

/* write(End, Bin) -> Written | would_block | {error, epipe | eio}, at most PIPE_WRITE_MAX bytes a call */
static ERL_NIF_TERM
nif_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary bin;
	erx_pipe_act_t act;
	erx_pipe_fx_t fx;
	erx_pipe_wmap_t map;
	pipe_end_t *e;
	ERL_NIF_TERM out;

	(void)argc;
	if (!get_owned_end(env, argv[0], &e) || !e->write ||
	    !enif_inspect_binary(env, argv[1], &bin) || bin.size == 0)
		return (enif_make_badarg(env));
	enif_mutex_lock(e->mutex);
	if (e->closed) {
		enif_mutex_unlock(e->mutex);
		return (enif_make_badarg(env));
	}
	map = (erx_pipe_wmap_t){ (erx_lane_hdr_t *)(uintptr_t)e->ring_map,
	    (unsigned char *)(uintptr_t)(e->ring_map + ERX_PIPE_RING_DATA),
	    (const erx_pipe_rpage_t *)(uintptr_t)e->rpage_map };
	erx_pipe_wstart(&e->w, bin.size < PIPE_WRITE_MAX ? bin.size :
	    PIPE_WRITE_MAX);
	act = erx_pipe_wrun(&e->w, &map, bin.data, end_fx(e, &fx));
	if (act.op == ERX_PIPE_OP_WAIT)
		out = e->w.done > 0 ? enif_make_uint64(env, e->w.done) :
		    atom_would_block;
	else if (act.result >= 0)
		out = enif_make_uint64(env, (uint64_t)act.result);
	else
		out = result_term(env, act.result);
	enif_mutex_unlock(e->mutex);
	return (out);
}

/* Tells the server of the lanes the call drained. */
static void
send_drained(ErlNifEnv *env, pipe_end_t *e)
{
	ErlNifEnv *msg;
	uint32_t i;

	for (i = 0; i < e->ndrained; i++) {
		if ((msg = enif_alloc_env()) == NULL)
			break;
		(void)enif_send(env, &e->server, msg, enif_make_tuple5(msg,
		    atom_drained, enif_make_tuple2(msg, atom_process,
		    enif_make_pid(msg, &e->owner)), enif_make_uint(msg, e->pipe),
		    enif_make_uint(msg, e->end), enif_make_uint(msg, e->drained[i])));
		enif_free_env(msg);
	}
	e->ndrained = 0;
}

/*
 * read(End, Max) -> Bin | eof | would_block | {error, eio}.  A read that
 * returned would_block left its wait in progress, with its bits set so its
 * peers ring it; the next read ends that wait first (erx_pipe_rstart), and a
 * read of 0 bytes, which an owner makes when it stops waiting, does only
 * that and returns <<>>, on a closed end too.
 */
static ERL_NIF_TERM
nif_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_pipe_act_t act;
	erx_pipe_fx_t fx;
	ErlNifBinary bin;
	pipe_end_t *e;
	ERL_NIF_TERM out;
	unsigned max;

	(void)argc;
	if (!get_owned_end(env, argv[0], &e) || e->write ||
	    !enif_get_uint(env, argv[1], &max))
		return (enif_make_badarg(env));
	if (max > PIPE_READ_MAX)
		max = PIPE_READ_MAX;
	if (!enif_alloc_binary(max, &bin))
		return (error_term(env, atom_enomem));
	enif_mutex_lock(e->mutex);
	if (e->closed) {
		enif_mutex_unlock(e->mutex);
		if (max == 0)
			return (enif_make_binary(env, &bin));
		enif_release_binary(&bin);
		return (enif_make_badarg(env));
	}
	e->ndrained = 0;
	erx_pipe_rstart(&e->r, max);
	act = erx_pipe_rrun(&e->r, e->maps, (erx_pipe_lock_t *)(uintptr_t)e->lock_map,
	    bin.data, end_fx(e, &fx));
	send_drained(env, e);
	enif_mutex_unlock(e->mutex);
	if (act.op == ERX_PIPE_OP_WAIT) {
		enif_release_binary(&bin);
		return (atom_would_block);
	}
	if (max == 0 && act.result == 0)
		return (enif_make_binary(env, &bin));
	if (act.result == 0) {
		enif_release_binary(&bin);
		return (atom_eof);
	}
	if (act.result < 0) {
		enif_release_binary(&bin);
		return (result_term(env, act.result));
	}
	if (enif_realloc_binary(&bin, (size_t)act.result))
		return (enif_make_binary(env, &bin));
	out = enif_make_binary(env, &bin);
	return (enif_make_sub_binary(env, out, 0, (size_t)act.result));
}

/* close(Object | End) -> ok, for the server's object or an end its owner or server closes */
static ERL_NIF_TERM
nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	pipe_obj_t *obj;
	pipe_end_t *e;

	(void)argc;
	if (enif_get_resource(env, argv[0], obj_type, (void **)&obj)) {
		enif_mutex_lock(obj_mutex);
		if (obj->server) {
			obj->server = false;
			if (--obj->holds == 0)
				obj_close_locked(obj);
		}
		enif_mutex_unlock(obj_mutex);
		return (atom_ok);
	}
	if (!get_closable_end(env, argv[0], &e))
		return (enif_make_badarg(env));
	enif_mutex_lock(e->mutex);
	end_close_locked(env, e);
	enif_mutex_unlock(e->mutex);
	return (atom_ok);
}

/* The read end's lane of write end wend, or nlanes. */
static uint32_t
lane_of(const pipe_end_t *e, unsigned wend)
{
	uint32_t i;

	for (i = 0; i < e->r.nlanes; i++)
		if (e->rlanes[i].wend == wend)
			break;
	return (i);
}

/*
 * apply(End, Report) -> ok | {error, enomem}, the server's report for the
 * end: a new end's objects kept and its doorbell rung once (PI7), a gone
 * end's doorbell let go, or the pipe lost.
 */
static ERL_NIF_TERM
nif_apply(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const ERL_NIF_TERM *t;
	char kind[32];
	pipe_end_t *e;
	unsigned n;
	uint32_t i;
	int arity;
	bool ok, known;

	(void)argc;
	if (!get_served_end(env, argv[0], &e) ||
	    !enif_get_tuple(env, argv[1], &arity, &t) || arity < 3 ||
	    !enif_get_atom(env, t[0], kind, sizeof(kind), ERL_NIF_LATIN1))
		return (enif_make_badarg(env));
	enif_mutex_lock(e->mutex);
	ok = !e->closed;
	if (!ok) {
		/* Its owner let go; the server learns of it from the notice. */
		ok = true;
	} else if (strcmp(kind, "pipe_writer") == 0 && arity == 9 && !e->write) {
		/* {pipe_writer, Pipe, End, Wend, Ring, RPage, Size, Bell, open} */
		ok = enif_get_uint(env, t[3], &n) &&
		    lane_add(env, e, enif_make_tuple5(env, t[3], t[4], t[5], t[6],
		    enif_make_tuple2(env, atom_open, t[7])));
		if (ok) {
			if (n > e->r.known)
				e->r.known = n;
			ring_bell(e->lanes[e->r.nlanes - 1].bell);
		}
	} else if (strcmp(kind, "pipe_writer_gone") == 0 && arity == 4 &&
	    !e->write) {
		ok = enif_get_uint(env, t[3], &n);
		if (ok && (i = lane_of(e, n)) < e->r.nlanes) {
			e->rlanes[i].writer = ERX_PIPE_WRITER_GONE;
			obj_drop(&e->lanes[i].bell);
		}
	} else if (strcmp(kind, "pipe_reader") == 0 && arity == 6) {
		/* {pipe_reader, Pipe, End, Rix, Bell, open} */
		known = enif_get_uint(env, t[3], &n) && n < ERX_PIPE_READERS_MAX &&
		    e->peers[n] != NULL;
		ok = peer_add(env, e, enif_make_tuple2(env, t[3], t[4])) &&
		    enif_get_uint(env, t[3], &n);
		if (ok) {
			if (e->write && !known)
				e->w.readers++;
			ring_bell(e->peers[n]);
		}
	} else if (strcmp(kind, "pipe_reader_gone") == 0 && arity == 4) {
		ok = enif_get_uint(env, t[3], &n) && n < ERX_PIPE_READERS_MAX;
		if (ok) {
			if (e->write && e->peers[n] != NULL && e->w.readers > 0)
				e->w.readers--;
			obj_drop(&e->peers[n]);
		}
	} else if (strcmp(kind, "pipe_lost") == 0 && arity == 3) {
		e->w.lost = true;
		e->r.lost = true;
	} else {
		ok = false;
	}
	enif_mutex_unlock(e->mutex);
	return (ok ? atom_ok : error_term(env, atom_enomem));
}

static ErlNifFunc nif_funcs[] = {
	{"make_lock", 0, make_lock, 0},
	{"make_lane", 1, make_lane, 0},
	{"make_bell", 3, make_bell, 0},
	{"store_wends", 2, store_wends, 0},
	{"free_lock", 2, free_lock, 0},
	{"close", 1, nif_close, 0},
	{"open_end", 3, open_end, 0},
	{"apply", 2, nif_apply, 0},
	{"read", 2, nif_read, 0},
	{"write", 2, nif_write, 0}
};

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	static const ErlNifResourceTypeInit end_init = {
		.dtor = end_dtor, .down = end_down, .members = 3 };

	(void)priv;
	(void)info;
	obj_mutex = enif_mutex_create("erx_pipe_obj");
	obj_type = enif_open_resource_type(env, NULL, "erx_pipe_obj", obj_dtor,
	    ERL_NIF_RT_CREATE, NULL);
	end_type = enif_init_resource_type(env, "erx_pipe_end", &end_init,
	    ERL_NIF_RT_CREATE, NULL);
	atom_ok = enif_make_atom(env, "ok");
	atom_error = enif_make_atom(env, "error");
	atom_enomem = enif_make_atom(env, "enomem");
	atom_eof = enif_make_atom(env, "eof");
	atom_eio = enif_make_atom(env, "eio");
	atom_epipe = enif_make_atom(env, "epipe");
	atom_would_block = enif_make_atom(env, "would_block");
	atom_closed = enif_make_atom(env, "closed");
	atom_drained = enif_make_atom(env, "drained");
	atom_process = enif_make_atom(env, "process");
	atom_lost = enif_make_atom(env, "pipe_server_lost");
	atom_ready = enif_make_atom(env, "erx_pipe_ready");
	atom_write = enif_make_atom(env, "write");
	atom_read = enif_make_atom(env, "read");
	atom_open = enif_make_atom(env, "open");
	atom_gone = enif_make_atom(env, "gone");
	return (obj_mutex == NULL || obj_type == NULL || end_type == NULL);
}

ERL_NIF_INIT(erx_pipe_nif, nif_funcs, load, NULL, NULL, NULL)
