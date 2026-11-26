/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_MACHINE_STOP_H
#define ERX_CORE_MACHINE_STOP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/abi_stop.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The decisions of the stop of the machine (docs/design-debugger.md, "The stop"), as
 * pure functions and two small machines that return the next step. Each kernel's glue
 * does the effects: the compare-and-swap of the stop word, the barriers, the stop
 * request, the stop slots, the clock, the record and the end. Nothing here reads
 * hardware or global state.
 *
 * The stop word lives in the debug anchor: zero, or the leader's CPU number plus one,
 * and never cleared. The admitted set is one word with a bit per CPU, set at each
 * CPU's admission and never cleared. A stop slot holds a CPU's registers and its
 * state, stored last with release ordering; zero is a slot nothing has published.
 *
 * Memory ordering the glue owes the decisions here:
 *   - the claim is one compare-and-swap of the stop word from zero to
 *     erx_machine_stop_word(cpu), with acquire and release ordering, and the word it
 *     observed (zero when the swap succeeded) is what erx_machine_stop_claim judges;
 *   - ERX_STOP_STEP_SET_BIT is an atomic fetch-or into the admitted set, so two CPUs
 *     admitted at once never lose each other's bit;
 *   - ERX_STOP_STEP_FENCE is a full barrier between a store and the following load of the other side's word; the admission's store of its bit and
 *     the leader's claim are each followed by one, so at least one of the two loads
 *     sees the other side's store;
 *   - the claim's store is visible to every CPU before ERX_STOP_STEP_ASK sends the
 *     request or wakes a lock waiter, so a CPU that takes either finds the word set;
 *     which barrier gives that before the interrupt is sent is the architecture
 *     binding's (docs/design-debugger.md, "Unverified facts", P7);
 *   - a CPU publishes its slot by writing its registers, then storing its state with
 *     release ordering; the leader loads each state with acquire ordering before it
 *     counts the CPU, and reads registers only for a state that carries them
 *     (erx_stop_cpu_state_registers, generated from the ABI file);
 *   - the clock the census reads is a free-running counter that the stop does not stop,
 *     read in program order, and it never wraps, so a reading outside the census's
 *     window means the bound has passed or the counter is broken;
 *   - a CPU's depth (erx_machine_stop_claim) is raised by one at each entry into a stop
 *     path, before anything else that entry does: every claim, and every park that
 *     erx_machine_stop_check decides, goes through one routine that raises it first, so
 *     a CPU that faults after any write to its slot claims at depth two or more.
 *
 * The admitted set and the census sets are one u64, a bit for each CPU below
 * ERX_CPU_LIMIT; every `cpu` the glue passes is the kernel's number of a CPU, below
 * that limit, so no stop word is zero and no CPU lacks a bit.
 */

/* What a CPU's entry into the stop does, from the stop word its claim observed. */
typedef enum erx_stop_claim {
	ERX_STOP_LEAD = 1,		/* its swap succeeded: it leads the stop */
	ERX_STOP_FOLLOW,		/* another CPU leads: publish `concurrent` and park */
	ERX_STOP_NESTED,		/* it leads and failed again: print one line and end */
	ERX_STOP_NESTED_SILENT,		/* it failed again inside the nested stop: end, printing nothing */
	ERX_STOP_FOLLOW_SILENT,		/* another CPU leads and this one failed again: park, publishing nothing */
} erx_stop_claim_t;

/* Where a running CPU loads the stop word. */
typedef enum erx_stop_point {
	ERX_STOP_AT_REQUEST = 1,	/* it took the stop request */
	ERX_STOP_AT_LOCK_WAIT,		/* a pass of a spinlock's wait loop */
	ERX_STOP_AT_ADMISSION,		/* the last step of its start */
} erx_stop_point_t;

/* The next thing the glue does for one of the two machines below. */
typedef enum erx_stop_step {
	ERX_STOP_STEP_SET_BIT = 1,	/* fetch-or the CPU's bit into the admitted set */
	ERX_STOP_STEP_FENCE,		/* a full memory barrier */
	ERX_STOP_STEP_LOAD_WORD,	/* load the stop word and pass it to every later step */
	ERX_STOP_STEP_RUN,		/* admitted: run on (final) */
	ERX_STOP_STEP_PARK,		/* publish the slot with `state` and park (final) */
	ERX_STOP_STEP_LOAD_ADMITTED,	/* load the admitted set and pass it to the next step */
	ERX_STOP_STEP_ASK,		/* request the stop of `asked`, wake lock waiters, pass the time */
	ERX_STOP_STEP_LOOK,		/* pass which CPUs of `asked` have published, and the time */
	ERX_STOP_STEP_RECORD,		/* the census is over, `complete` or not (final) */
} erx_stop_step_t;

/* A CPU's admission. The glue takes `step` until it is RUN or PARK. */
typedef struct erx_stop_admission {
	uint32_t		cpu;
	uint32_t		taken;	/* steps of the admission's order taken so far */
	erx_stop_step_t		step;
	erx_stop_cpu_state_t	state;	/* for PARK: the state to publish */
} erx_stop_admission_t;

/* The leader's steps from its claim to the end of its census. */
typedef struct erx_stop_leader {
	uint32_t		cpu;
	erx_stop_step_t		step;
	uint64_t		asked;		/* the CPUs asked, once the admitted set is loaded */
	uint64_t		since_ns;	/* the time of the request */
	bool			complete;	/* at RECORD: every CPU asked had published */
} erx_stop_leader_t;

/* The stop word a claim by `cpu` stores: its number plus one. */
uint32_t	erx_machine_stop_word(uint32_t cpu);

/*
 * The claim's decision over the word the swap observed, the claiming CPU and its depth.
 * The depth counts this CPU's entries into a stop path, this one included: each claim,
 * and each park that erx_machine_stop_check decides (at the request, a lock's wait, the
 * admission). A CPU that finds its own word leads the stop and has failed inside it: it
 * never follows, so it never waits on itself. A CPU that finds another's word at depth
 * two or more has parked or followed already and failed again: it parks and publishes
 * nothing, so its first publication stands, or its slot stays zero if the fault came
 * before the state's store.
 */
erx_stop_claim_t	erx_machine_stop_claim(uint32_t observed, uint32_t cpu, uint32_t depth);

/*
 * What a CPU that loaded the stop word at `point` does: zero to run on, or the state it
 * publishes before it parks. The leader's own word never parks the leader, so its
 * stop path may wait for a lock.
 */
erx_stop_cpu_state_t	erx_machine_stop_check(erx_stop_point_t point, uint32_t word, uint32_t cpu);

/*
 * The admission, as its steps: set the bit, a barrier, load the stop word, then RUN or
 * PARK as `starting`. `word` is the value the last LOAD_WORD step loaded, zero before.
 */
erx_stop_admission_t	erx_machine_stop_admission_begin(uint32_t cpu);
erx_stop_admission_t	erx_machine_stop_admission_next(erx_stop_admission_t admission, uint32_t word);

/*
 * The leader, as its steps after a claim that led: a barrier, one load of the admitted
 * set, the request to every CPU of it but the leader, and the census rounds. `loaded` is
 * the admitted set after LOAD_ADMITTED and the published CPUs (a bit for each CPU whose
 * slot state erx_machine_stop_published accepts) after LOOK, and is ignored otherwise;
 * `now_ns` is the clock after ASK and LOOK. A round ends the census, complete, when every
 * CPU asked has published, which it checks first; otherwise it ends the census,
 * incomplete, when the clock reads outside the window from the request's time up to
 * ERX_STOP_CENSUS_MS after it, earlier than the request or the bound or more after it;
 * otherwise the next step is LOOK again.
 */
erx_stop_leader_t	erx_machine_stop_leader_begin(uint32_t cpu);
erx_stop_leader_t	erx_machine_stop_leader_next(erx_stop_leader_t leader, uint64_t loaded, uint64_t now_ns);

/*
 * Whether a slot's state is one a CPU publishes for itself, so the census counts it:
 * every state that carries registers but the leader's, so a counted CPU always has
 * its registers in the record.
 */
bool	erx_machine_stop_published(erx_stop_cpu_state_t state);

/*
 * A CPU's state in the record, once the leader has reached RECORD, given the state its
 * slot held when the leader looked: the leader is `leader`; a CPU outside the census is
 * `offline`, whatever it published later; an asked CPU is the state it published, or
 * `unanswered`: unpublished when the census ended.
 */
erx_stop_cpu_state_t	erx_machine_stop_final(const erx_stop_leader_t *leader, uint32_t cpu,
			    erx_stop_cpu_state_t published);

/* One entry of a kernel's boot memory map, classified by that kernel's table. */
typedef struct erx_ram_entry {
	uint64_t		base;
	uint64_t		length;
	erx_ram_class_t		ram_class;
} erx_ram_entry_t;

typedef enum erx_ram_map_status {
	ERX_RAM_MAP_OK = 0,
	ERX_RAM_MAP_OVERFLOW,		/* an entry's or a range's end passes the address space */
	ERX_RAM_MAP_TOO_MANY,		/* more ranges than ERX_DEBUG_RAM_RANGES */
	ERX_RAM_MAP_USED_OUTSIDE,	/* a used entry does not lie whole in one range */
} erx_ram_map_status_t;

/*
 * The readable-RAM map of a boot map (docs/design-debugger.md, "Readable RAM"): the
 * union of `ram` entries rounded inward to pages, less the union of `excluded` entries
 * rounded outward. `ignored` entries take no part, and a class outside the enum counts
 * as `excluded`. A map that overflows, needs more ranges than the anchor holds, or
 * leaves out part of a `used` entry, rounded outward, is refused, never cut: the
 * status says why and the map has no ranges. The map is the anchor's own `ram`
 * (erx_ram_map_t of abi/kernel.txt), so the glue builds it in place.
 */
erx_ram_map_status_t	erx_machine_stop_ram_map(const erx_ram_entry_t *entries, size_t nentries,
			    erx_ram_map_t *map);

/* The boot line's words for a refusal; NULL for ERX_RAM_MAP_OK. */
const char	*erx_machine_stop_ram_map_reason(erx_ram_map_status_t status);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_MACHINE_STOP_H */
