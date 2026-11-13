/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A stand-in for erx_area (otp/erts/emulator/nifs/erxos/erx_area_nif.c)
 * in the erx_memdraw bundle that stock's emulator loads
 * (tools/lib/erx/memdraw_build.rb), so test/erlang/erx_memdraw_tests.erl
 * can wrap images over an area. test_area(Bytes, Mode) maps Bytes of
 * fresh anonymous memory followed by one page that may not be touched, so
 * an image that reads or writes past the area faults; the destructor
 * unmaps it, so an image used after the area is gone faults too, and then
 * tells the creator erx_area_unmapped, as erx_area tells the agent.
 *
 * Built alone with ERX_AREA_LOADABLE it is erx_area's own NIF in stock's
 * emulator (test/host/erx_connections_test.rb): map(Slot, Bytes, Mode,
 * Tag) maps the same memory, ignoring Slot, which names no object on the
 * host, and its destructor tells the caller {erx_area_unmapped, Tag}, so
 * the connection agent's tests hold a real resource whose unmap waits on
 * every process that refers to it collecting.
 */
#include "erl_nif.h"

#include <sys/mman.h>
#include <unistd.h>

#include "erx_area.h"

bool erx_area_stand_in_load(ErlNifEnv *env);
ERL_NIF_TERM erx_area_stand_in_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

typedef struct stand_in {
	uint8_t *base;
	size_t bytes;
	bool writable;
	ErlNifPid owner;
	ErlNifEnv *tag_env;	/* holds tag; NULL for test_area, which sends no tag */
	ERL_NIF_TERM tag;
} stand_in_t;

static ErlNifResourceType *stand_in_type;

static size_t
page(void)
{
	return (size_t)sysconf(_SC_PAGESIZE);
}

static void
stand_in_dtor(ErlNifEnv *env, void *object)
{
	stand_in_t *area = object;
	ErlNifEnv *msg = enif_alloc_env();

	(void)munmap(area->base, area->bytes + page());
	if (msg != NULL) {
		ERL_NIF_TERM unmapped = enif_make_atom(msg, "erx_area_unmapped");

		if (area->tag_env != NULL)
			unmapped = enif_make_tuple2(msg, unmapped, enif_make_copy(msg, area->tag));
		(void)enif_send(env, &area->owner, msg, unmapped);
		enif_free_env(msg);
	}
	if (area->tag_env != NULL)
		enif_free_env(area->tag_env);
}

bool
erx_area_stand_in_load(ErlNifEnv *env)
{
	stand_in_type = enif_open_resource_type(env, NULL, "erx_area_stand_in", stand_in_dtor, ERL_NIF_RT_CREATE, NULL);
	return stand_in_type != NULL;
}

bool
erx_area_view(ErlNifEnv *env, ERL_NIF_TERM term, erx_area_view_t *out)
{
	stand_in_t *area;

	if (!enif_get_resource(env, term, stand_in_type, (void **)&area))
		return false;
	*out = (erx_area_view_t){ .resource = area, .base = area->base, .bytes = area->bytes, .page = page(),
		.writable = area->writable };
	return true;
}

/*
 * The area of Bytes, whole pages, writable or not, as a new resource term
 * whose destructor tells the caller of its unmap, with a copy of *tag when
 * tag is not NULL; false for bad arguments or memory the host refuses.
 */
static bool
stand_in_map(ErlNifEnv *env, ERL_NIF_TERM bytes_term, ERL_NIF_TERM mode, const ERL_NIF_TERM *tag, ERL_NIF_TERM *out)
{
	ErlNifUInt64 bytes;
	bool writable = enif_is_identical(mode, enif_make_atom(env, "write"));

	if (!enif_get_uint64(env, bytes_term, &bytes) || bytes == 0 || bytes % page() != 0 || bytes > SIZE_MAX / 2 ||
	    !(writable || enif_is_identical(mode, enif_make_atom(env, "read"))))
		return false;
	uint8_t *base = mmap(NULL, (size_t)bytes + page(), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	if (base == MAP_FAILED)
		return false;
	/* The guard page past the area, and the reader's mapping read-only, as erx_area maps it. */
	if (mprotect(base + bytes, page(), PROT_NONE) != 0 ||
	    (!writable && mprotect(base, (size_t)bytes, PROT_READ) != 0)) {
		(void)munmap(base, (size_t)bytes + page());
		return false;
	}
	/* The tag's env first, so a failure leaves no resource whose destructor would send. */
	ErlNifEnv *tag_env = NULL;
	if (tag != NULL) {
		tag_env = enif_alloc_env();
		if (tag_env == NULL) {
			(void)munmap(base, (size_t)bytes + page());
			return false;
		}
	}
	stand_in_t *area = enif_alloc_resource(stand_in_type, sizeof *area);
	if (area == NULL) {
		if (tag_env != NULL)
			enif_free_env(tag_env);
		(void)munmap(base, (size_t)bytes + page());
		return false;
	}
	*area = (stand_in_t){ .base = base, .bytes = (size_t)bytes, .writable = writable, .tag_env = tag_env };
	if (tag_env != NULL)
		area->tag = enif_make_copy(tag_env, *tag);
	(void)enif_self(env, &area->owner);
	*out = enif_make_resource(env, area);
	enif_release_resource(area);
	return true;
}

/* test_area(Bytes, write | read) -> {ok, Area, PageBytes}; Bytes whole pages. */
ERL_NIF_TERM
erx_area_stand_in_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ERL_NIF_TERM term;

	(void)argc;
	if (!stand_in_map(env, argv[0], argv[1], NULL, &term))
		return enif_make_badarg(env);
	return enif_make_tuple3(env, enif_make_atom(env, "ok"), term, enif_make_uint64(env, page()));
}

#ifdef ERX_AREA_LOADABLE
/*
 * map(Slot, Bytes, write | read, Tag) -> {ok, Area} | {error, einval | enomem},
 * as erx_area's: badarg for arguments of the wrong type, einval for a length
 * that is not whole host pages, enomem for memory the host refuses.
 */
static ERL_NIF_TERM
map_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 slot, bytes;
	ERL_NIF_TERM term;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &slot) || !enif_get_uint64(env, argv[1], &bytes) ||
	    !(enif_is_identical(argv[2], enif_make_atom(env, "write")) ||
	      enif_is_identical(argv[2], enif_make_atom(env, "read"))))
		return enif_make_badarg(env);
	if (bytes == 0 || bytes % page() != 0 || bytes > SIZE_MAX / 2)
		return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "einval"));
	if (!stand_in_map(env, argv[1], argv[2], &argv[3], &term))
		return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "enomem"));
	return enif_make_tuple2(env, enif_make_atom(env, "ok"), term);
}

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	(void)priv;
	(void)info;
	return erx_area_stand_in_load(env) ? 0 : 1;
}

static ErlNifFunc functions[] = {
	{ "map", 4, map_nif, 0 },
};

ERL_NIF_INIT(erx_area, functions, load, NULL, NULL, NULL)
#endif
