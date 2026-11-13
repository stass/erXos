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
 * Every term that refers to the area, and every image erx_memdraw built
 * over it (erx_area.h), keeps the resource alive; the destructor, which
 * runs only once the last of them is gone, unmaps the area and only then
 * tells the agent {erx_area_unmapped, Tag}, so the agent answers that the
 * connection is unmapped only when nothing in the runtime can reach the
 * area's memory any more. The capability stays in its slot, as the
 * sides' do; the system domain deletes the object with the connection.
 */

#define STATIC_ERLANG_NIF 1

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "erl_nif.h"
#include "erx_area.h"

#include "liberx/backend/api.h"

typedef struct area {
	uint64_t addr;		/* the mapping, ERX_PAGE_SIZE-aligned */
	uint64_t bytes;
	bool writable;
	ErlNifPid owner;	/* the agent, told of the unmap */
	ErlNifEnv *tag_env;	/* holds tag */
	ERL_NIF_TERM tag;	/* the agent's name for this mapping */
} area_t;

static ErlNifResourceType *area_type;
static ERL_NIF_TERM atom_ok, atom_error, atom_einval, atom_enomem, atom_read, atom_write, atom_unmapped;

/* Runs once the last reference is gone: no image or term reaches addr after it. */
static void
area_dtor(ErlNifEnv *env, void *object)
{
	area_t *area = object;

	(void)erx_vm_release(ERX_CAP_SELF, area->addr, area->bytes);
	(void)enif_send(env, &area->owner, area->tag_env,
	    enif_make_tuple2(area->tag_env, atom_unmapped, area->tag));
	enif_free_env(area->tag_env);
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
	area->writable = writable;
	(void)enif_self(env, &area->owner);
	area->tag_env = tag_env;
	area->tag = enif_make_copy(tag_env, argv[3]);
	term = enif_make_resource(env, area);
	enif_release_resource(area);
	return (enif_make_tuple2(env, atom_ok, term));
}

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	(void)priv;
	(void)info;
	area_type = enif_open_resource_type(env, NULL, "erx_area", area_dtor, ERL_NIF_RT_CREATE, NULL);
	if (area_type == NULL)
		return (1);
	atom_ok = enif_make_atom(env, "ok");
	atom_error = enif_make_atom(env, "error");
	atom_einval = enif_make_atom(env, "einval");
	atom_enomem = enif_make_atom(env, "enomem");
	atom_read = enif_make_atom(env, "read");
	atom_write = enif_make_atom(env, "write");
	atom_unmapped = enif_make_atom(env, "erx_area_unmapped");
	return (0);
}

static ErlNifFunc functions[] = {
	{ "map", 4, map_nif, 0 },
};

ERL_NIF_INIT(erx_area, functions, load, NULL, NULL, NULL)
