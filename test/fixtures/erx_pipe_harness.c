/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The session's pipe NIF (otp/erts/emulator/nifs/erxos/erx_pipe_nif.c)
 * built for the host and loaded into stock's emulator, for
 * test/erlang/erx_pipe_hand_tests.erl (test/host/erx_pipe_hand_test.rb).
 * It is a translation unit of its own, linked with the NIF's source built
 * with ERX_PIPE_NIF_LOADABLE and ERX_PIPE_HARNESS and with liberx's pipe
 * core, and adds two things (test/fixtures/erx_pipe_harness.h is the seam
 * between them):
 *
 * - the backend calls the NIF makes, over the host: a memory object or a
 *   doorbell is a fresh capability number, a reserve maps fresh anonymous
 *   memory and a map there is a no-op, so the server's lock page is real
 *   memory but an end's mapping shares nothing with it; every close is
 *   recorded, so a test can ask whether a capability has closed;
 * - NIF functions standing in for the program driver, the one caller of
 *   the NIF's hand-off entries (erx_pipe.h): take/2, give/1 (the driver's
 *   release after its installs) and holder_release/1, with closed/1 and
 *   obj_cap/1 to see what a hand-off holds.  Taken hand-offs are kept by
 *   number in a small table, used by one test process at a time.
 */

#include <sys/mman.h>

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

#include "liberx/backend/api.h"

#include "erl_nif.h"
#include "erx_event.h"
#include "erx_pipe.h"
#include "erx_pipe_harness.h"

/* Capabilities are numbered from CAP_BASE; the closes of the first CAP_SLOTS are recorded. */
#define CAP_BASE	0x1000u
#define CAP_SLOTS	4096u

static atomic_uint_fast64_t next_cap = CAP_BASE;
static atomic_bool cap_closed[CAP_SLOTS];
static atomic_uint_fast32_t next_label = 1;
/*
 * The hand-offs the stand-in driver has taken and not yet released, each in
 * slot number % HARNESS_SLOTS; a case holds a few at once, and a take into a
 * slot already in use is refused with badarg, never overwritten.
 */
static erx_pipe_hand_t *harness_taken[64];

#define HARNESS_SLOTS (sizeof harness_taken / sizeof harness_taken[0])

static uint64_t
cap_new(void)
{
	return (atomic_fetch_add(&next_cap, 1));
}

int
erx_mem_create(uint64_t budget, uint64_t size, uint32_t flags, uint64_t *mem)
{
	(void)budget;
	(void)size;
	(void)flags;
	*mem = cap_new();
	return (ERX_OK);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq)
{
	(void)budget;
	(void)resource;
	(void)kind;
	(void)selector;
	*irq = cap_new();
	return (ERX_OK);
}

int
erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label)
{
	(void)irq;
	(void)group;
	(void)label;
	return (ERX_OK);
}

int
erx_irq_trigger(uint64_t irq)
{
	(void)irq;
	return (ERX_OK);
}

int
erx_cap_close(uint64_t cap)
{
	if (cap >= CAP_BASE && cap - CAP_BASE < CAP_SLOTS)
		atomic_store(&cap_closed[cap - CAP_BASE], true);
	return (ERX_OK);
}

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	void *base;

	(void)space;
	(void)addr;
	(void)flags;
	base = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
	if (base == MAP_FAILED)
		return (ERX_ENOMEM);
	*reserved = (uint64_t)(uintptr_t)base;
	return (ERX_OK);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	(void)space;
	(void)addr;
	(void)size;
	(void)mem;
	(void)offset;
	(void)prot;
	return (ERX_OK);
}

int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	(void)space;
	(void)munmap((void *)(uintptr_t)addr, size);
	return (ERX_OK);
}

uint64_t
erx_clock_ns(void)
{
	struct timespec ts;

	(void)clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec);
}

int
erx_event_register_process(const ErlNifPid *pid, ERL_NIF_TERM term, uint32_t *label)
{
	(void)pid;
	(void)term;
	*label = (uint32_t)atomic_fetch_add(&next_label, 1);
	return (ERX_OK);
}

void
erx_event_unregister(uint32_t label)
{
	(void)label;
}

/*
 * take(Number, Program, Caller) -> {ok, Program, [{Cap, Rights}],
 * none | {Cap, Label}} | none: the driver's take of hand-off Number of
 * Program for Caller, and what it holds.
 */
ERL_NIF_TERM
erx_pipe_harness_take(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 number, program;
	erx_pipe_hand_t *hand;
	ERL_NIF_TERM copies, bell;
	uint64_t cap, label;
	uint32_t rights;
	unsigned i;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &number) ||
	    !enif_get_uint64(env, argv[1], &program) || !enif_is_pid(env, argv[2]) ||
	    harness_taken[number % HARNESS_SLOTS] != NULL)
		return (enif_make_badarg(env));
	if ((hand = erx_pipe_hand_take(number, program, argv[2])) == NULL)
		return (enif_make_atom(env, "none"));
	harness_taken[number % HARNESS_SLOTS] = hand;
	copies = enif_make_list(env, 0);
	for (i = erx_pipe_hand_count(hand); i > 0; i--) {
		erx_pipe_hand_copy(hand, i - 1, &cap, &rights);
		copies = enif_make_list_cell(env, enif_make_tuple2(env,
		    enif_make_uint64(env, cap), enif_make_uint(env, rights)), copies);
	}
	bell = erx_pipe_hand_bell(hand, &cap, &label) ?
	    enif_make_tuple2(env, enif_make_uint64(env, cap), enif_make_uint64(env, label)) :
	    enif_make_atom(env, "none");
	return (enif_make_tuple4(env, enif_make_atom(env, "ok"),
	    enif_make_uint64(env, erx_pipe_hand_program(hand)), copies, bell));
}

/* give(Number) -> ok: the driver's release of the hand-off it took as Number. */
ERL_NIF_TERM
erx_pipe_harness_give(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 number;
	erx_pipe_hand_t *hand;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &number) || harness_taken[number % HARNESS_SLOTS] == NULL)
		return (enif_make_badarg(env));
	hand = harness_taken[number % HARNESS_SLOTS];
	harness_taken[number % HARNESS_SLOTS] = NULL;
	erx_pipe_hand_release(hand);
	return (enif_make_atom(env, "ok"));
}

/* holder_release(Program) -> ok: the driver lets the port's hold go, its anchor released. */
ERL_NIF_TERM
erx_pipe_harness_holder_release(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 program;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &program))
		return (enif_make_badarg(env));
	erx_pipe_holder_release(program);
	return (enif_make_atom(env, "ok"));
}

/* closed(Cap) -> boolean(): whether capability Cap has been closed. */
ERL_NIF_TERM
erx_pipe_harness_closed(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 cap;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &cap) || cap < CAP_BASE || cap - CAP_BASE >= CAP_SLOTS)
		return (enif_make_badarg(env));
	return (enif_make_atom(env, atomic_load(&cap_closed[cap - CAP_BASE]) ? "true" : "false"));
}

/* obj_cap(Object) -> Cap: the capability of one of the pipe server's objects. */
ERL_NIF_TERM
erx_pipe_harness_obj_cap_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	uint64_t cap;

	(void)argc;
	if (!erx_pipe_harness_obj_cap(env, argv[0], &cap))
		return (enif_make_badarg(env));
	return (enif_make_uint64(env, cap));
}
