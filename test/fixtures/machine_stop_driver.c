/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for kernel/core/machine_stop.c and kernel/core/kip_ram.c, run by
 * test/host/machine_stop_test.rb. It prints one line per check, "NAME: ok" or
 * "NAME: FAIL why".
 *
 * The stop's machine is explored exhaustively for one to four CPUs, under sequential
 * consistency: the barriers the glue owes (machine_stop.h) are what make the hardware
 * behave so for the admission and the claim, which litmus tests check separately. Each
 * CPU has a fixed kind, every assignment of kinds is explored, and every interleaving of
 * the CPUs' steps and the clock's ticks is reached by a depth-first search over the
 * world's states. At most one CPU in a run faults again inside the stop: once it has
 * parked, or just before the store that publishes its slot, so the slot stays zero. One
 * is enough: a CPU that parks again silently writes nothing another CPU reads, and the
 * zero slot it may leave is the one a CPU that never answers leaves too.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/kip_ram.h"
#include "erx/core/machine_stop.h"

#define	MAX_CPUS	4
#define	TICKS		2	/* a census starts at 0, 1 or 2 census bounds, so the clock reads up to 3 */
#define	CENSUS_NS	((uint64_t)ERX_STOP_CENSUS_MS * 1000000u)
#define	DEPTH_CAP	3	/* where a CPU's count of entries stops; one fault again reaches 2 */

/* What each CPU does in an exploration. */
enum kind {
	KIND_STARTER,	/* takes its admission, then runs with interrupts unmasked */
	KIND_UNMASKED,	/* admitted; takes the stop request when one is pending */
	KIND_LOCK_WAIT,	/* admitted; spins in a spinlock's wait with interrupts masked */
	KIND_MASKED,	/* admitted; runs with interrupts masked and never looks */
	KIND_FAILER,	/* admitted; enters the stop, or takes the request first */
	KINDS
};

/* PHASE_FAULTING: it decided to park and faulted before its slot's store. */
enum phase { PHASE_ADMIT, PHASE_RUN, PHASE_PARKED, PHASE_FAULTING, PHASE_LEAD, PHASE_RECORDED };

typedef struct cpu {
	uint8_t			kind;
	uint8_t			phase;
	bool			ran_on;		/* its admission said RUN */
	uint8_t			depth;		/* its entries into a stop path, up to DEPTH_CAP */
	uint32_t		word_seen;	/* what its admission's LOAD_WORD loaded */
	erx_stop_admission_t	admission;
	erx_stop_leader_t	leader;
} cpu_t;

typedef struct world {
	unsigned		ncpus;
	unsigned		ticks;
	uint32_t		word;
	uint64_t		admitted;
	uint32_t		slot[MAX_CPUS];
	bool			pending[MAX_CPUS];
	bool			faulted;	/* a CPU has faulted again inside the stop */
	int			leader;
	cpu_t			cpu[MAX_CPUS];
} world_t;

static const char	*violation;
static char		 detail[256];

static void
fail(const char *why)
{
	if (violation == NULL)
		violation = why;
}

/* The world's state, packed for the visited set; every field that steps can change. */
_Static_assert(ERX_STOP_CPU_STATE_UNANSWERED < 8, "a slot state packs in 3 bits");
_Static_assert(ERX_STOP_STEP_RECORD < 16, "a step packs in 4 bits");
_Static_assert(PHASE_RECORDED < 8 && MAX_CPUS <= 4 && TICKS + 1 < 4 && DEPTH_CAP < 4, "the key's other widths");
typedef struct key {
	uint64_t	w[3];
} key_t;

static key_t
world_key(const world_t *w)
{
	key_t k = { { 0, 0, 0 } };

	if (w->ticks > TICKS + 1)
		fail("the clock passed the last census bound, past the key's width");
	uint64_t a = w->word | (w->admitted << 4) | ((uint64_t)w->ticks << 8) | ((uint64_t)w->faulted << 26);

	for (unsigned i = 0; i < w->ncpus; i++) {
		const cpu_t *c = &w->cpu[i];
		uint64_t s = c->phase | ((uint64_t)c->ran_on << 3) | ((uint64_t)c->word_seen << 4) |
		    ((uint64_t)c->admission.taken << 7) | ((uint64_t)c->admission.step << 9) |
		    ((uint64_t)c->leader.step << 13) | ((uint64_t)(c->leader.asked & 0xf) << 17) |
		    ((uint64_t)(c->leader.since_ns / CENSUS_NS) << 21) | ((uint64_t)c->leader.complete << 23) |
		    ((uint64_t)c->depth << 24);

		a |= ((uint64_t)w->slot[i] << (10 + 3 * i)) | ((uint64_t)w->pending[i] << (22 + i));
		k.w[1 + i / 2] |= s << (32 * (i % 2));
	}
	k.w[0] = a;
	return (k);
}

/* The visited set: open addressing, cleared per exploration by a generation count. */
#define	VISITED_BITS	22
#define	VISITED_SIZE	(1u << VISITED_BITS)

static key_t	*visited_key;
static uint32_t	*visited_gen;
static uint32_t	 generation;

static bool
visit(const world_t *w)
{
	key_t k = world_key(w);
	uint64_t h = (k.w[0] * 0x9e3779b97f4a7c15u) ^ (k.w[1] * 0xc2b2ae3d27d4eb4fu) ^ (k.w[2] * 0x165667b19e3779f9u);

	for (uint32_t i = (uint32_t)(h >> (64 - VISITED_BITS)), n = 0; n < VISITED_SIZE; i = (i + 1) % VISITED_SIZE, n++) {
		if (visited_gen[i] != generation) {
			visited_gen[i] = generation;
			visited_key[i] = k;
			return (true);
		}
		if (memcmp(&visited_key[i], &k, sizeof(k)) == 0)
			return (false);
	}
	fprintf(stderr, "visited set full\n");
	exit(2);
}

static uint64_t
bit(unsigned cpu)
{
	return (UINT64_C(1) << cpu);
}

static void
publish(world_t *w, unsigned cpu, erx_stop_cpu_state_t state)
{
	if (w->slot[cpu] != 0)
		fail("a slot published twice");
	if (!erx_machine_stop_published(state))
		fail("a CPU published a state the census does not count");
	if (w->cpu[cpu].depth >= 2)
		fail("a CPU that faulted again inside the stop published");
	w->slot[cpu] = state;
	w->cpu[cpu].phase = PHASE_PARKED;
}

/* The leader at RECORD: every CPU's final state, against what the slots hold. */
static void
check_record(const world_t *w, const cpu_t *lead)
{
	for (unsigned j = 0; j < w->ncpus; j++) {
		erx_stop_cpu_state_t final = erx_machine_stop_final(&lead->leader, j, w->slot[j]);

		if (final < ERX_STOP_CPU_STATE_OFFLINE || final > ERX_STOP_CPU_STATE_UNANSWERED)
			fail("a final state outside the enum");
		if ((int)j == w->leader) {
			if (final != ERX_STOP_CPU_STATE_LEADER)
				fail("the leader is not `leader` in the record");
			continue;
		}
		if ((lead->leader.asked & bit(j)) == 0) {
			if (final != ERX_STOP_CPU_STATE_OFFLINE)
				fail("a CPU outside the census is not `offline`");
		} else if (erx_machine_stop_published(w->slot[j]) ? final != w->slot[j] : final != ERX_STOP_CPU_STATE_UNANSWERED) {
			fail("an asked CPU's final state is not its published one, or `unanswered`");
		}
		if (lead->leader.complete && (lead->leader.asked & bit(j)) != 0 && !erx_machine_stop_published(final))
			fail("a complete census with a CPU that did not publish");
	}
}

/* What must hold in every state the search reaches. */
static void
check_world(const world_t *w)
{
	for (unsigned i = 0; i < w->ncpus; i++) {
		const cpu_t *c = &w->cpu[i];

		if (c->phase != PHASE_LEAD && c->phase != PHASE_RECORDED)
			continue;
		/* A fault inside the stop never waits, and the leader's own lock waits run on. */
		if (erx_machine_stop_claim(w->word, i, 2) != ERX_STOP_NESTED ||
		    erx_machine_stop_claim(w->word, i, 3) != ERX_STOP_NESTED_SILENT)
			fail("a nested stop does not end the machine");
		if (erx_machine_stop_check(ERX_STOP_AT_LOCK_WAIT, w->word, i) != 0)
			fail("the leader parks at its own lock wait");
		if (c->leader.step == ERX_STOP_STEP_FENCE || c->leader.step == ERX_STOP_STEP_LOAD_ADMITTED)
			continue;
		if ((c->leader.asked & bit(i)) != 0)
			fail("the leader asks itself");
		for (unsigned j = 0; j < w->ncpus; j++)
			if (w->cpu[j].ran_on && (c->leader.asked & bit(j)) == 0)
				fail("a CPU ran on past its admission unasked");
	}
}

/* One more entry into a stop path: a claim, or a park the check decided. */
static void
enter(cpu_t *c)
{
	if (c->depth < DEPTH_CAP)
		c->depth++;
}

/*
 * A CPU parks with `state`: its slot's store, or, when `store` is false, a fault just
 * before that store, so the slot stays zero and the CPU enters the stop again.
 */
static void
park(world_t *w, unsigned i, erx_stop_cpu_state_t state, bool store)
{
	if (store) {
		publish(w, i, state);
		return;
	}
	w->faulted = true;
	w->cpu[i].phase = PHASE_FAULTING;
}

/* A park the check decides, at `point`; nothing when the check says run on. */
static void
check_park(world_t *w, unsigned i, erx_stop_point_t point, bool store)
{
	erx_stop_cpu_state_t state = erx_machine_stop_check(point, w->word, i);

	if (state == 0)
		return;
	enter(&w->cpu[i]);
	park(w, i, state, store);
}

static void
take_request(world_t *w, unsigned i, bool store)
{
	w->pending[i] = false;
	check_park(w, i, ERX_STOP_AT_REQUEST, store);
}

/* An entry into the stop: a CPU's first failure, or a parked CPU's fault again. */
static void
enter_stop(world_t *w, unsigned i, bool store)
{
	cpu_t *c = &w->cpu[i];
	uint32_t observed = w->word;

	if (observed == 0)
		w->word = erx_machine_stop_word(i);
	enter(c);
	switch (erx_machine_stop_claim(observed, i, c->depth)) {
	case ERX_STOP_LEAD:
		if (w->leader >= 0)
			fail("two leaders");
		w->leader = (int)i;
		w->cpu[i].phase = PHASE_LEAD;
		w->cpu[i].leader = erx_machine_stop_leader_begin(i);
		break;
	case ERX_STOP_FOLLOW:
		park(w, i, ERX_STOP_CPU_STATE_CONCURRENT, store);
		break;
	case ERX_STOP_FOLLOW_SILENT:
		if (c->depth < 2)
			fail("a first entry parks without publishing");
		c->phase = PHASE_PARKED;
		break;
	default:
		fail("a CPU that does not lead judged nested");
		c->phase = PHASE_PARKED;
		break;
	}
}

static void
admission_step(world_t *w, unsigned i, bool store)
{
	cpu_t *c = &w->cpu[i];

	switch (c->admission.step) {
	case ERX_STOP_STEP_SET_BIT:
		w->admitted |= bit(i);
		break;
	case ERX_STOP_STEP_LOAD_WORD:
		c->word_seen = w->word;
		break;
	default:
		break;
	}
	c->admission = erx_machine_stop_admission_next(c->admission, c->word_seen);
	if (c->admission.step == ERX_STOP_STEP_RUN) {
		if ((w->admitted & bit(i)) == 0)
			fail("a CPU ran on without its bit");
		c->ran_on = true;
		c->phase = PHASE_RUN;
	} else if (c->admission.step == ERX_STOP_STEP_PARK) {
		enter(c);
		park(w, i, c->admission.state, store);
	}
}

static void
leader_step(world_t *w, unsigned i)
{
	cpu_t *c = &w->cpu[i];
	uint64_t now = (uint64_t)w->ticks * CENSUS_NS, published = 0;
	erx_stop_leader_t before = c->leader;

	switch (c->leader.step) {
	case ERX_STOP_STEP_LOAD_ADMITTED:
		c->leader = erx_machine_stop_leader_next(c->leader, w->admitted, 0);
		return;
	case ERX_STOP_STEP_ASK:
		for (unsigned j = 0; j < w->ncpus; j++)
			if ((c->leader.asked & bit(j)) != 0)
				w->pending[j] = true;
		c->leader = erx_machine_stop_leader_next(c->leader, 0, now);
		return;
	case ERX_STOP_STEP_LOOK:
		for (unsigned j = 0; j < w->ncpus; j++)
			if (erx_machine_stop_published(w->slot[j]))
				published |= bit(j);
		c->leader = erx_machine_stop_leader_next(c->leader, published, now);
		if ((before.asked & ~published) == 0) {
			if (c->leader.step != ERX_STOP_STEP_RECORD || !c->leader.complete)
				fail("a census with every CPU published goes on");
		} else if (now - before.since_ns >= CENSUS_NS) {
			if (c->leader.step != ERX_STOP_STEP_RECORD || c->leader.complete)
				fail("a census past its bound goes on, or calls itself complete");
		} else if (c->leader.step != ERX_STOP_STEP_LOOK) {
			fail("a census ends early");
		}
		if (c->leader.step == ERX_STOP_STEP_RECORD) {
			check_record(w, c);
			c->phase = PHASE_RECORDED;
		}
		return;
	default:
		c->leader = erx_machine_stop_leader_next(c->leader, 0, now);
		return;
	}
}

/*
 * The worlds one step after `w`: each CPU's enabled steps and the clock's tick. Until a
 * CPU has faulted again, each CPU step comes in two ways: a park it makes stores its
 * slot, or the CPU faults just before the store (a step that does not park gives the
 * same world both ways, which the visited set drops); and a parked CPU may fault again.
 * A CPU that faults again passes `store` as true: the claim must park it silently, and
 * a claim that has it follow instead publishes, which publish() catches.
 */
#define	SUCCESSORS_MAX	(4 * MAX_CPUS + 1)

/*
 * A census asked at any clock reading still runs to its bound: past TICKS the clock
 * advances while a leader looks and its bound lies ahead, so every census meets its
 * expiry.
 */
static bool
census_waits(const world_t *w)
{
	for (unsigned i = 0; i < w->ncpus; i++) {
		const cpu_t *c = &w->cpu[i];

		if (c->phase == PHASE_LEAD && c->leader.step == ERX_STOP_STEP_LOOK &&
		    (uint64_t)w->ticks * CENSUS_NS < c->leader.since_ns + CENSUS_NS)
			return (true);
	}
	return (false);
}

static unsigned
successors(const world_t *w, world_t *next)
{
	unsigned n = 0, ways = w->faulted ? 1 : 2;

	for (unsigned i = 0; i < w->ncpus; i++) {
		const cpu_t *c = &w->cpu[i];

		switch (c->phase) {
		case PHASE_ADMIT:
			for (unsigned way = 0; way < ways; way++) {
				next[n] = *w;
				admission_step(&next[n++], i, way == 0);
			}
			break;
		case PHASE_RUN:
			if (c->kind == KIND_LOCK_WAIT) {
				if (erx_machine_stop_check(ERX_STOP_AT_LOCK_WAIT, w->word, i) == 0)
					break;
				for (unsigned way = 0; way < ways; way++) {
					next[n] = *w;
					check_park(&next[n++], i, ERX_STOP_AT_LOCK_WAIT, way == 0);
				}
				break;
			}
			if (c->kind == KIND_MASKED)
				break;
			for (unsigned way = 0; w->pending[i] && way < ways; way++) {
				next[n] = *w;
				take_request(&next[n++], i, way == 0);
			}
			for (unsigned way = 0; c->kind == KIND_FAILER && way < ways; way++) {
				next[n] = *w;
				enter_stop(&next[n++], i, way == 0);
			}
			break;
		case PHASE_PARKED:
			if (!w->faulted) {
				next[n] = *w;
				next[n].faulted = true;
				enter_stop(&next[n++], i, true);
			}
			break;
		case PHASE_FAULTING:
			next[n] = *w;
			enter_stop(&next[n++], i, true);
			break;
		case PHASE_LEAD:
			next[n] = *w;
			leader_step(&next[n++], i);
			break;
		default:
			break;
		}
	}
	if (w->ticks < TICKS || census_waits(w)) {
		next[n] = *w;
		next[n++].ticks++;
	}
	return (n);
}

#define	STACK_MAX	(1u << 20)

static world_t	*stack;

/* Explores every interleaving from one assignment of kinds; returns the states seen. */
static uint64_t
explore(unsigned ncpus, const uint8_t *kinds)
{
	world_t start, next[SUCCESSORS_MAX];
	uint64_t states = 0;
	size_t depth = 0;

	memset(&start, 0, sizeof(start));
	start.ncpus = ncpus;
	start.leader = -1;
	for (unsigned i = 0; i < ncpus; i++) {
		start.cpu[i].kind = kinds[i];
		if (kinds[i] == KIND_STARTER) {
			start.cpu[i].phase = PHASE_ADMIT;
			start.cpu[i].admission = erx_machine_stop_admission_begin(i);
		} else {
			start.cpu[i].phase = PHASE_RUN;
			start.admitted |= bit(i);
		}
	}
	generation++;
	visit(&start);
	stack[depth++] = start;
	while (depth > 0 && violation == NULL) {
		world_t w = stack[--depth];
		unsigned n = successors(&w, next);

		states++;
		for (unsigned s = 0; s < n && violation == NULL; s++) {
			check_world(&next[s]);
			if (visit(&next[s])) {
				if (depth == STACK_MAX) {
					fprintf(stderr, "search stack full\n");
					exit(2);
				}
				stack[depth++] = next[s];
			}
		}
	}
	return (states);
}

static void
check_stop(unsigned ncpus)
{
	uint8_t kinds[MAX_CPUS] = { 0 };
	unsigned assignments = 1;
	uint64_t states = 0;

	for (unsigned i = 0; i < ncpus; i++)
		assignments *= KINDS;
	violation = NULL;
	for (unsigned a = 0; a < assignments && violation == NULL; a++) {
		for (unsigned i = 0, v = a; i < ncpus; i++, v /= KINDS)
			kinds[i] = (uint8_t)(v % KINDS);
		states += explore(ncpus, kinds);
		if (violation != NULL) {
			int at = snprintf(detail, sizeof(detail), "%s, kinds", violation);

			for (unsigned i = 0; i < ncpus && at > 0 && (size_t)at < sizeof(detail); i++)
				at += snprintf(detail + at, sizeof(detail) - (size_t)at, " %u", kinds[i]);
		}
	}
	if (violation != NULL)
		printf("stop %u cpus: FAIL %s\n", ncpus, detail);
	else
		printf("stop %u cpus: ok\n", ncpus);
	fprintf(stderr, "stop %u cpus: %" PRIu64 " states over %u assignments\n", ncpus, states, assignments);
}

/* The claim and the check on their own, over words of every CPU and depths. */
static void
check_claim(void)
{
	const char *why = NULL;

	for (uint32_t cpu = 0; cpu < ERX_CPU_LIMIT; cpu++) {
		uint32_t own = erx_machine_stop_word(cpu), other = erx_machine_stop_word((cpu + 1) % ERX_CPU_LIMIT);

		if (own == 0)
			why = "a leader's word is zero";
		if (erx_machine_stop_claim(0, cpu, 1) != ERX_STOP_LEAD)
			why = "a successful swap does not lead";
		if (erx_machine_stop_claim(other, cpu, 1) != ERX_STOP_FOLLOW)
			why = "another CPU's word does not follow";
		for (uint32_t depth = 2; depth < 8; depth++)
			if (erx_machine_stop_claim(other, cpu, depth) != ERX_STOP_FOLLOW_SILENT)
				why = "a follower that faulted again publishes";
		if (erx_machine_stop_claim(own, cpu, 2) != ERX_STOP_NESTED)
			why = "a second entry of the leader does not print and end";
		for (uint32_t depth = 3; depth < 8; depth++)
			if (erx_machine_stop_claim(own, cpu, depth) != ERX_STOP_NESTED_SILENT)
				why = "a deeper entry of the leader prints";
		if (erx_machine_stop_check(ERX_STOP_AT_REQUEST, other, cpu) != ERX_STOP_CPU_STATE_STOPPED ||
		    erx_machine_stop_check(ERX_STOP_AT_LOCK_WAIT, other, cpu) != ERX_STOP_CPU_STATE_WAITING ||
		    erx_machine_stop_check(ERX_STOP_AT_ADMISSION, other, cpu) != ERX_STOP_CPU_STATE_STARTING)
			why = "a check parks in the wrong state";
		if (erx_machine_stop_check(ERX_STOP_AT_LOCK_WAIT, 0, cpu) != 0 ||
		    erx_machine_stop_check(ERX_STOP_AT_ADMISSION, own, cpu) != 0)
			why = "a check parks with no stop, or on its own stop";
	}
	printf("claim: %s%s\n", why == NULL ? "ok" : "FAIL ", why == NULL ? "" : why);
}

/* The census over the clock alone: the bound, a clock that goes back, and RECORD staying. */
static void
check_census_clock(void)
{
	erx_stop_leader_t l = erx_machine_stop_leader_begin(0), end;
	const char *why = NULL;

	l = erx_machine_stop_leader_next(l, 0, 0);
	l = erx_machine_stop_leader_next(l, 0x6, 0);
	l = erx_machine_stop_leader_next(l, 0, 1000);
	if (l.asked != 0x6 || l.since_ns != 1000)
		why = "the census asks the wrong CPUs";
	if (erx_machine_stop_leader_next(l, 0x2, 1000 + CENSUS_NS - 1).step != ERX_STOP_STEP_LOOK)
		why = "the census ends before its bound";
	end = erx_machine_stop_leader_next(l, 0x2, 1000 + CENSUS_NS);
	if (end.step != ERX_STOP_STEP_RECORD || end.complete)
		why = "the census outlives its bound, or calls itself complete with a CPU missing";
	end = erx_machine_stop_leader_next(l, 0x2, 999);
	if (end.step != ERX_STOP_STEP_RECORD || end.complete)
		why = "a clock read before the request keeps the census waiting, or calls it complete";
	end = erx_machine_stop_leader_next(l, 0x6, 999);
	if (end.step != ERX_STOP_STEP_RECORD || !end.complete)
		why = "a full census read with a clock before the request is not complete";
	end = erx_machine_stop_leader_next(l, 0x6, 1000 + 2 * CENSUS_NS);
	if (end.step != ERX_STOP_STEP_RECORD || !end.complete)
		why = "a full census read past its bound is not complete";
	l = erx_machine_stop_leader_next(l, 0xff, 1000);
	if (l.step != ERX_STOP_STEP_RECORD || !l.complete || erx_machine_stop_leader_next(l, 0, UINT64_MAX).step != ERX_STOP_STEP_RECORD)
		why = "a complete census does not record, or leaves RECORD";
	/* The design's late secondary: outside the census it is `offline`, whatever it published. */
	if (erx_machine_stop_final(&l, 3, ERX_STOP_CPU_STATE_STARTING) != ERX_STOP_CPU_STATE_OFFLINE ||
	    erx_machine_stop_final(&l, 2, ERX_STOP_CPU_STATE_STARTING) != ERX_STOP_CPU_STATE_STARTING ||
	    erx_machine_stop_final(&l, 1, 0) != ERX_STOP_CPU_STATE_UNANSWERED ||
	    erx_machine_stop_final(&l, 1, ERX_STOP_CPU_STATE_LEADER) != ERX_STOP_CPU_STATE_UNANSWERED ||
	    erx_machine_stop_final(&l, 1, 99) != ERX_STOP_CPU_STATE_UNANSWERED ||
	    erx_machine_stop_final(&l, 200, ERX_STOP_CPU_STATE_STOPPED) != ERX_STOP_CPU_STATE_OFFLINE)
		why = "a final state disagrees with the design";
	printf("census clock: %s%s\n", why == NULL ? "ok" : "FAIL ", why == NULL ? "" : why);
}

/* ---- The readable-RAM map ---- */

#define	P	((uint64_t)ERX_PAGE_SIZE)
#define	RAM(b, l)	{ (b), (l), ERX_RAM_CLASS_RAM }
#define	USED(b, l)	{ (b), (l), ERX_RAM_CLASS_USED }
#define	EXCL(b, l)	{ (b), (l), ERX_RAM_CLASS_EXCLUDED }
#define	IGN(b, l)	{ (b), (l), ERX_RAM_CLASS_IGNORED }

typedef struct ram_case {
	const char		*name;
	size_t			 nentries;
	erx_ram_entry_t		 entries[24];
	erx_ram_map_status_t	 status;
	uint32_t		 nranges;
	erx_ram_range_t		 ranges[4];
} ram_case_t;

static const ram_case_t ram_cases[] = {
	{ "two banks", 2, { RAM(0x40000000, 0x10000000), RAM(0x80000000, 0x1000000) }, ERX_RAM_MAP_OK, 2,
	  { { 0x40000000, 0x10000000 }, { 0x80000000, 0x1000000 } } },
	{ "a virtual entry over every bank changes nothing", 3,
	  { IGN(0, UINT64_MAX), RAM(0x40000000, 0x10000000), RAM(0x80000000, 0x1000000) }, ERX_RAM_MAP_OK, 2,
	  { { 0x40000000, 0x10000000 }, { 0x80000000, 0x1000000 } } },
	{ "an interior exclusion splits its bank, rounded outward", 2,
	  { RAM(0x40000000, 0x10000000), EXCL(0x40001800, 0x100) }, ERX_RAM_MAP_OK, 2,
	  { { 0x40000000, 0x1000 }, { 0x40002000, 0x10000000 - 0x2000 } } },
	{ "overlapping and touching banks join", 3,
	  { RAM(0x2000, 0x3000), RAM(0x1000, 0x2000), RAM(0x5000, 0x1000) }, ERX_RAM_MAP_OK, 1, { { 0x1000, 0x5000 } } },
	{ "a bank rounded inward", 1, { RAM(0x1001, 0x2ffe) }, ERX_RAM_MAP_OK, 1, { { 0x2000, 0x1000 } } },
	{ "a bank under one page is no memory", 1, { RAM(0x1001, 0xffe) }, ERX_RAM_MAP_OK, 0, { { 0, 0 } } },
	{ "an exclusion over a whole bank", 2, { RAM(0x1000, 0x1000), EXCL(0x800, 0x1000) }, ERX_RAM_MAP_OK, 0, { { 0, 0 } } },
	{ "used memory inside a bank", 3, { RAM(0x1000, 0x8000), USED(0x2000, 0x10), USED(0x8000, 0x1000) },
	  ERX_RAM_MAP_OK, 1, { { 0x1000, 0x8000 } } },
	{ "used memory past a bank is refused", 2, { RAM(0x1000, 0x8000), USED(0x8800, 0x1000) },
	  ERX_RAM_MAP_USED_OUTSIDE, 0, { { 0, 0 } } },
	{ "used memory across an exclusion is refused", 3, { RAM(0x1000, 0x8000), EXCL(0x4000, 0x1000), USED(0x3000, 0x2000) },
	  ERX_RAM_MAP_USED_OUTSIDE, 0, { { 0, 0 } } },
	{ "used memory with no bank is refused", 1, { USED(0x1000, 0x1000) }, ERX_RAM_MAP_USED_OUTSIDE, 0, { { 0, 0 } } },
	{ "an entry whose end overflows is refused", 2, { RAM(0x1000, 0x1000), EXCL(0x2000, UINT64_MAX - 0x1000) },
	  ERX_RAM_MAP_OVERFLOW, 0, { { 0, 0 } } },
	{ "a bank below the top page of the address space", 2, { RAM(UINT64_MAX - 3 * P + 1, 3 * P), EXCL(UINT64_MAX - P + 1, P) },
	  ERX_RAM_MAP_OK, 1, { { UINT64_MAX - 3 * P + 1, 2 * P } } },
	{ "a range ending at the top of the address space is refused", 1, { RAM(UINT64_MAX - 2 * P + 1, 2 * P) },
	  ERX_RAM_MAP_OVERFLOW, 0, { { 0, 0 } } },
	{ "a class outside the enum excludes", 2, { RAM(0x1000, 0x3000), { 0x2000, 0x1000, 77 } }, ERX_RAM_MAP_OK, 2,
	  { { 0x1000, 0x1000 }, { 0x3000, 0x1000 } } },
	{ "a map of the whole address space is refused", 2, { RAM(0, UINT64_C(1) << 63), RAM(UINT64_C(1) << 63, UINT64_C(1) << 63) },
	  ERX_RAM_MAP_OVERFLOW, 0, { { 0, 0 } } },
	{ "an entry one byte short of the address space", 1, { RAM(0, UINT64_MAX) }, ERX_RAM_MAP_OK, 1, { { 0, UINT64_MAX - P + 1 } } },
};

/* A map of n one-page banks a page apart. */
static size_t
banks(erx_ram_entry_t *entries, size_t n)
{
	for (size_t i = 0; i < n; i++)
		entries[i] = (erx_ram_entry_t)RAM(0x100000 + 2 * P * i, P);
	return (n);
}

static void
check_ram_cases(void)
{
	erx_ram_entry_t entries[24];
	erx_ram_map_t map;

	for (size_t c = 0; c < sizeof(ram_cases) / sizeof(ram_cases[0]); c++) {
		const ram_case_t *rc = &ram_cases[c];
		erx_ram_map_status_t status = erx_machine_stop_ram_map(rc->entries, rc->nentries, &map);
		bool same = status == rc->status && map.nranges == rc->nranges;

		for (uint32_t i = 0; same && i < map.nranges; i++)
			same = map.range[i].base == rc->ranges[i].base && map.range[i].length == rc->ranges[i].length;
		if (same)
			printf("ram %s: ok\n", rc->name);
		else
			printf("ram %s: FAIL status %d, %u ranges\n", rc->name, (int)status, map.nranges);
	}
	if (erx_machine_stop_ram_map(entries, banks(entries, ERX_DEBUG_RAM_RANGES), &map) == ERX_RAM_MAP_OK &&
	    map.nranges == ERX_DEBUG_RAM_RANGES)
		printf("ram 16 ranges: ok\n");
	else
		printf("ram 16 ranges: FAIL\n");
	if (erx_machine_stop_ram_map(entries, banks(entries, ERX_DEBUG_RAM_RANGES + 1), &map) == ERX_RAM_MAP_TOO_MANY &&
	    map.nranges == 0)
		printf("ram 17 ranges are refused: ok\n");
	else
		printf("ram 17 ranges are refused: FAIL\n");
	if (erx_machine_stop_ram_map_reason(ERX_RAM_MAP_OK) == NULL && erx_machine_stop_ram_map_reason(ERX_RAM_MAP_TOO_MANY) != NULL &&
	    erx_machine_stop_ram_map_reason(ERX_RAM_MAP_OVERFLOW) != NULL && erx_machine_stop_ram_map_reason(ERX_RAM_MAP_USED_OUTSIDE) != NULL)
		printf("ram reasons: ok\n");
	else
		printf("ram reasons: FAIL\n");
}

/* Random maps over 160 pages, judged page by page against the entries. */
#define	ORACLE_PAGES	160

static uint64_t	rng_state = 0x243f6a8885a308d3u;

static uint64_t
rng(void)
{
	rng_state ^= rng_state << 13;
	rng_state ^= rng_state >> 7;
	rng_state ^= rng_state << 17;
	return (rng_state);
}

/* Whether byte range [base, base + length) covers page p whole (ram) or touches it (others). */
static bool
oracle_covers(const erx_ram_entry_t *e, uint64_t p, bool whole)
{
	uint64_t lo = p * P, hi = lo + P;

	if (e->length == 0)
		return (false);
	return (whole ? e->base <= lo && hi <= e->base + e->length : e->base < hi && lo < e->base + e->length);
}

static const char *
check_random_map(const erx_ram_entry_t *entries, size_t n)
{
	bool readable[ORACLE_PAGES + 1] = { false }, used_outside = false;
	unsigned runs = 0;
	erx_ram_map_t map;
	erx_ram_map_status_t status;

	for (uint64_t p = 0; p < ORACLE_PAGES; p++) {
		bool ram = false, excluded = false;

		for (size_t i = 0; i < n; i++) {
			if (entries[i].ram_class == ERX_RAM_CLASS_RAM)
				ram = ram || oracle_covers(&entries[i], p, true);
			else if (entries[i].ram_class != ERX_RAM_CLASS_USED && entries[i].ram_class != ERX_RAM_CLASS_IGNORED)
				excluded = excluded || oracle_covers(&entries[i], p, false);
		}
		readable[p] = ram && !excluded;
		runs += readable[p] && (p == 0 || !readable[p - 1]);
	}
	/* A used entry lies in one range when every page it touches is readable: a range is a whole run. */
	for (size_t i = 0; i < n; i++)
		for (uint64_t p = 0; entries[i].ram_class == ERX_RAM_CLASS_USED && p < ORACLE_PAGES; p++)
			used_outside = used_outside || (oracle_covers(&entries[i], p, false) && !readable[p]);
	status = erx_machine_stop_ram_map(entries, n, &map);
	if (runs > ERX_DEBUG_RAM_RANGES)
		return (status == ERX_RAM_MAP_TOO_MANY && map.nranges == 0 ? NULL : "a map past the anchor's ranges was not refused");
	if (used_outside)
		return (status == ERX_RAM_MAP_USED_OUTSIDE && map.nranges == 0 ? NULL : "a used entry outside the map was not refused");
	if (status != ERX_RAM_MAP_OK || map.nranges != runs)
		return ("the map's ranges are not the readable runs");
	for (uint32_t i = 0; i < map.nranges; i++) {
		uint64_t first = map.range[i].base / P, end = first + map.range[i].length / P;

		if (map.range[i].base % P != 0 || map.range[i].length % P != 0 || map.range[i].length == 0)
			return ("a range of partial pages");
		if (i > 0 && map.range[i - 1].base + map.range[i - 1].length >= map.range[i].base)
			return ("ranges unsorted, overlapping or touching");
		for (uint64_t p = first; p < end; p++)
			if (p >= ORACLE_PAGES || !readable[p])
				return ("a page of the map is not readable");
		if (end < ORACLE_PAGES && readable[end])
			return ("a range stops short of its run");
	}
	return (NULL);
}

static void
check_ram_random(void)
{
	erx_ram_entry_t entries[40];
	const char *why = NULL;
	unsigned refused = 0;

	for (unsigned round = 0; round < 20000 && why == NULL; round++) {
		size_t n = 1 + rng() % 40;

		for (size_t i = 0; i < n; i++) {
			uint64_t base = rng() % (ORACLE_PAGES * P), length = rng() % (6 * P);
			static const erx_ram_class_t classes[] = { ERX_RAM_CLASS_RAM, ERX_RAM_CLASS_RAM, ERX_RAM_CLASS_RAM,
				ERX_RAM_CLASS_EXCLUDED, ERX_RAM_CLASS_IGNORED, ERX_RAM_CLASS_USED, 77 };

			if (base + length > ORACLE_PAGES * P)
				length = ORACLE_PAGES * P - base;
			entries[i] = (erx_ram_entry_t){ base, length, classes[rng() % 7] };
		}
		why = check_random_map(entries, n);
		refused += erx_machine_stop_ram_map(entries, n, &(erx_ram_map_t){ 0 }) == ERX_RAM_MAP_TOO_MANY;
	}
	/* The rounds must reach the refusal, or the oracle's branch for it proves nothing. */
	if (why == NULL && refused == 0)
		why = "no random map needed more ranges than the anchor holds";
	printf("ram random maps: %s%s\n", why == NULL ? "ok" : "FAIL ", why == NULL ? "" : why);
}

/* ---- Fiasco's descriptor table ---- */

static uint64_t
kip_lo(uint64_t start, unsigned type, unsigned sub_type, bool virt)
{
	return (start | type | (sub_type << 4) | (virt ? 0x200u : 0));
}

static erx_ram_class_t
kip_expected(unsigned type, unsigned sub_type, bool virt)
{
	if (virt || type == 0x0)
		return (ERX_RAM_CLASS_IGNORED);
	if (type == 0x1)
		return (ERX_RAM_CLASS_RAM);
	if ((type == 0x2 && (sub_type == 0 || sub_type == 1)) || type == 0x3 || type == 0x7 || type == 0xe)
		return (ERX_RAM_CLASS_USED);
	return (ERX_RAM_CLASS_EXCLUDED);
}

/* The entry of a descriptor the conversion must accept; a refusal leaves class 0, which no check expects. */
static erx_ram_entry_t
kip_entry(uint64_t lo, uint64_t hi)
{
	erx_ram_entry_t entry = { .ram_class = 0 };

	(void)erx_kip_ram_entry(lo, hi, &entry);
	return (entry);
}

static void
check_kip(void)
{
	const char *why = NULL;
	erx_ram_entry_t e, entries[3];
	erx_ram_map_t map;

	for (unsigned type = 0; type < 16; type++)
		for (unsigned sub_type = 0; sub_type < 16; sub_type++)
			for (int virt = 0; virt < 2; virt++)
				if (kip_entry(kip_lo(0x40000000, type, sub_type, virt), 0x7fffffff).ram_class !=
				    kip_expected(type, sub_type, virt))
					why = "a descriptor classified against the design's table";
	e = kip_entry(kip_lo(0x40000000, 0x1, 0, false), 0x7ffffc00);
	if (e.base != 0x40000000 || e.length != 0x40000000)
		why = "a descriptor's range misread";
	/* The whole address space has a length no entry holds: refused, never cut by a page. */
	if (erx_kip_ram_entry(kip_lo(0, 0x1, 0, false), UINT64_MAX, &e) != ERX_RAM_MAP_OVERFLOW ||
	    erx_kip_ram_entry(kip_lo(0, 0x2, 2, false), UINT64_MAX, &e) != ERX_RAM_MAP_OVERFLOW)
		why = "the whole address space was not refused";
	if (kip_entry(kip_lo(0, 0x1, 0, true), UINT64_MAX).ram_class != ERX_RAM_CLASS_IGNORED)
		why = "a virtual descriptor over the whole address space was refused";
	if (erx_kip_ram_entry(kip_lo(0x50000000, 0x2, 2, false), 0x40000000, &e) != ERX_RAM_MAP_OVERFLOW)
		why = "a descriptor ending below its start was not refused";
	/* Fiasco's own virtual descriptor over the user address space, beside a bank and the kernel. */
	entries[0] = kip_entry(kip_lo(0, 0x1, 0, true), UINT64_C(0x0000ffffffffffff));
	entries[1] = kip_entry(kip_lo(0x40000000, 0x1, 0, false), 0x7fffffff);
	entries[2] = kip_entry(kip_lo(0x40080000, 0x2, 0, false), 0x4017ffff);
	if (erx_machine_stop_ram_map(entries, 3, &map) != ERX_RAM_MAP_OK || map.nranges != 1 ||
	    map.range[0].base != 0x40000000 || map.range[0].length != 0x40000000)
		why = "a KIP map misread";
	printf("kip table: %s%s\n", why == NULL ? "ok" : "FAIL ", why == NULL ? "" : why);
}

int
main(void)
{
	visited_key = calloc(VISITED_SIZE, sizeof(*visited_key));
	visited_gen = calloc(VISITED_SIZE, sizeof(*visited_gen));
	stack = calloc(STACK_MAX, sizeof(*stack));
	if (visited_key == NULL || visited_gen == NULL || stack == NULL)
		return (2);
	check_claim();
	check_census_clock();
	for (unsigned n = 1; n <= MAX_CPUS; n++)
		check_stop(n);
	check_ram_cases();
	check_ram_random();
	check_kip();
	free(stack);
	free(visited_gen);
	free(visited_key);
	return (0);
}
