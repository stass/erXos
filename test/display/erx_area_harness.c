/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_area's own NIF (otp/erts/emulator/nifs/erxos/erx_area_nif.c) built
 * for the host and loaded into stock's emulator, for
 * test/erlang/erx_area_lease_tests.erl (test/host/erx_area_lease_test.rb).
 * It is a translation unit of its own, linked with the NIF's source built
 * with ERX_AREA_NIF_LOADABLE and ERX_AREA_HARNESS, and adds two things
 * (test/display/erx_area_harness.h is the seam between them):
 *
 * - the memory calls the NIF makes, over the host: a reserve in
 *   ERX_CAP_SELF maps fresh anonymous memory and a map there is a no-op,
 *   so map/4 makes a real area whose Slot names nothing; in any other
 *   space a reserve and a map are recorded, not made, as a program's
 *   sub-space has no host counterpart;
 * - NIF functions standing in for the program driver, the one caller of
 *   the lease's driver functions: take/3, give/1 (the driver's return),
 *   map_lease/2 and leases/0, the count of listed leases. The taken leases
 *   are kept by number in a small table, used by one test process at a
 *   time.
 */

#include <sys/mman.h>

#include <stddef.h>
#include <stdint.h>
#include <strings.h>

static struct erx_area_lease *harness_taken[64];
static struct {
	uint64_t space, addr, bytes, mem, offset;
	uint32_t prot, flags;
} harness_recorded;

#include "liberx/backend/api.h"

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	void *base;

	if (space != ERX_CAP_SELF) {
		harness_recorded.space = space;
		harness_recorded.addr = addr;
		harness_recorded.flags = flags;
		*reserved = addr;
		return (ERX_OK);
	}
	base = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
	if (base == MAP_FAILED)
		return (ERX_ENOMEM);
	*reserved = (uint64_t)(uintptr_t)base;
	return (ERX_OK);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	if (space != ERX_CAP_SELF) {
		harness_recorded.bytes = size;
		harness_recorded.mem = mem;
		harness_recorded.offset = offset;
		harness_recorded.prot = prot;
	}
	(void)addr;
	return (ERX_OK);
}

int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	if (space == ERX_CAP_SELF)
		(void)munmap((void *)(uintptr_t)addr, size);
	return (ERX_OK);
}

#include "erl_nif.h"
#include "erx_area.h"
#include "erx_area_harness.h"

#define HARNESS_SLOTS (sizeof harness_taken / sizeof harness_taken[0])

/* take(Number, Owner, Pages) -> ok | none: the driver's take for a port Owner owns. */
ERL_NIF_TERM
erx_area_harness_take(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 number, pages;
	erx_area_lease_t *lease;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &number) || !enif_get_uint64(env, argv[2], &pages))
		return (enif_make_badarg(env));
	lease = erx_area_lease_take(number, argv[1], pages);
	if (lease == NULL)
		return (enif_make_atom(env, "none"));
	harness_taken[number % HARNESS_SLOTS] = lease;
	return (enif_make_atom(env, "ok"));
}

/* give(Number) -> ok: the driver's return of the lease it took as Number. */
ERL_NIF_TERM
erx_area_harness_give(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 number;
	erx_area_lease_t *lease;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &number) || harness_taken[number % HARNESS_SLOTS] == NULL)
		return (enif_make_badarg(env));
	lease = harness_taken[number % HARNESS_SLOTS];
	harness_taken[number % HARNESS_SLOTS] = NULL;
	erx_area_lease_return(lease);
	return (enif_make_atom(env, "ok"));
}

/* map_lease(Number, Space) -> {Status, {Space, Addr, Bytes, Mem, Offset, Prot, Flags}}. */
ERL_NIF_TERM
erx_area_harness_map_lease(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 number, space;
	int status;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &number) || !enif_get_uint64(env, argv[1], &space) ||
	    harness_taken[number % HARNESS_SLOTS] == NULL)
		return (enif_make_badarg(env));
	status = erx_area_lease_map(harness_taken[number % HARNESS_SLOTS], space);
	return (enif_make_tuple2(env, enif_make_int(env, status),
	    enif_make_tuple7(env, enif_make_uint64(env, harness_recorded.space),
	    enif_make_uint64(env, harness_recorded.addr), enif_make_uint64(env, harness_recorded.bytes),
	    enif_make_uint64(env, harness_recorded.mem), enif_make_uint64(env, harness_recorded.offset),
	    enif_make_uint(env, harness_recorded.prot), enif_make_uint(env, harness_recorded.flags))));
}

/* leases() -> Count: the leases listed in the table. */
ERL_NIF_TERM
erx_area_harness_leases(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	(void)argc;
	return (enif_make_uint(env, erx_area_harness_lease_count()));
}

/*
 * peek(Area, Offset, Length) -> Binary and poke(Area, Offset, Binary) -> ok:
 * read and write an area's bytes through its mapping, for zero/3's cases.
 * badarg for a range that passes the area's end, and poke's for a read-only area.
 */
ERL_NIF_TERM
erx_area_harness_peek(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 offset, length;
	erx_area_view_t view;
	ERL_NIF_TERM term;
	unsigned char *bytes;

	(void)argc;
	if (!erx_area_view(env, argv[0], &view) || !enif_get_uint64(env, argv[1], &offset) ||
	    !enif_get_uint64(env, argv[2], &length) || offset > view.bytes || length > view.bytes - offset)
		return (enif_make_badarg(env));
	bytes = enif_make_new_binary(env, (size_t)length, &term);
	bcopy(view.base + offset, bytes, (size_t)length);
	return (term);
}

ERL_NIF_TERM
erx_area_harness_poke(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 offset;
	erx_area_view_t view;
	ErlNifBinary data;

	(void)argc;
	if (!erx_area_view(env, argv[0], &view) || !enif_get_uint64(env, argv[1], &offset) ||
	    !enif_inspect_binary(env, argv[2], &data) || !view.writable || offset > view.bytes ||
	    data.size > view.bytes - offset)
		return (enif_make_badarg(env));
	bcopy(data.data, view.base + offset, data.size);
	return (enif_make_atom(env, "ok"));
}
