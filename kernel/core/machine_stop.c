/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The stop's decisions (docs/design-debugger.md, "The stop", "Readable RAM"); the
 * header says what the glue owes them.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/machine_stop.h"

_Static_assert(ERX_CPU_LIMIT <= 64, "the admitted set and the census sets are one u64");

#define	CENSUS_NS	((uint64_t)ERX_STOP_CENSUS_MS * 1000000u)

/*
 * The admission's order: its bit is visible before it looks at the stop word, so a CPU
 * that misses the stop is one the leader's load of the set finds.
 */
static const erx_stop_step_t admission_order[] = {
	ERX_STOP_STEP_SET_BIT,
	ERX_STOP_STEP_FENCE,
	ERX_STOP_STEP_LOAD_WORD,
};

#define	ADMISSION_STEPS	(sizeof(admission_order) / sizeof(admission_order[0]))

static uint64_t
cpu_bit(uint32_t cpu)
{
	return (cpu < ERX_CPU_LIMIT ? UINT64_C(1) << cpu : 0);
}

uint32_t
erx_machine_stop_word(uint32_t cpu)
{
	return (cpu + 1);
}

erx_stop_claim_t
erx_machine_stop_claim(uint32_t observed, uint32_t cpu, uint32_t depth)
{
	if (observed == 0)
		return (ERX_STOP_LEAD);
	if (observed != erx_machine_stop_word(cpu))
		return (ERX_STOP_FOLLOW);
	return (depth == 2 ? ERX_STOP_NESTED : ERX_STOP_NESTED_SILENT);
}

erx_stop_cpu_state_t
erx_machine_stop_check(erx_stop_point_t point, uint32_t word, uint32_t cpu)
{
	if (word == 0 || word == erx_machine_stop_word(cpu))
		return (0);
	switch (point) {
	case ERX_STOP_AT_LOCK_WAIT:
		return (ERX_STOP_CPU_STATE_WAITING);
	case ERX_STOP_AT_ADMISSION:
		return (ERX_STOP_CPU_STATE_STARTING);
	case ERX_STOP_AT_REQUEST:
		return (ERX_STOP_CPU_STATE_STOPPED);
	}
	return (ERX_STOP_CPU_STATE_STOPPED);
}

erx_stop_admission_t
erx_machine_stop_admission_begin(uint32_t cpu)
{
	return ((erx_stop_admission_t){ .cpu = cpu, .taken = 0, .step = admission_order[0], .state = 0 });
}

erx_stop_admission_t
erx_machine_stop_admission_next(erx_stop_admission_t admission, uint32_t word)
{
	if (admission.step == ERX_STOP_STEP_RUN || admission.step == ERX_STOP_STEP_PARK)
		return (admission);
	admission.taken++;
	if (admission.taken < ADMISSION_STEPS) {
		admission.step = admission_order[admission.taken];
		return (admission);
	}
	admission.state = erx_machine_stop_check(ERX_STOP_AT_ADMISSION, word, admission.cpu);
	admission.step = admission.state == 0 ? ERX_STOP_STEP_RUN : ERX_STOP_STEP_PARK;
	return (admission);
}

erx_stop_leader_t
erx_machine_stop_leader_begin(uint32_t cpu)
{
	return ((erx_stop_leader_t){ .cpu = cpu, .step = ERX_STOP_STEP_FENCE });
}

/* Whether the census has run out of time; a clock earlier than the request ends it too. */
static bool
census_expired(uint64_t since_ns, uint64_t now_ns)
{
	return (now_ns < since_ns || now_ns - since_ns >= CENSUS_NS);
}

erx_stop_leader_t
erx_machine_stop_leader_next(erx_stop_leader_t leader, uint64_t loaded, uint64_t now_ns)
{
	switch (leader.step) {
	case ERX_STOP_STEP_FENCE:
		leader.step = ERX_STOP_STEP_LOAD_ADMITTED;
		break;
	case ERX_STOP_STEP_LOAD_ADMITTED:
		leader.asked = loaded & ~cpu_bit(leader.cpu);
		leader.step = ERX_STOP_STEP_ASK;
		break;
	case ERX_STOP_STEP_ASK:
		leader.since_ns = now_ns;
		leader.step = ERX_STOP_STEP_LOOK;
		break;
	case ERX_STOP_STEP_LOOK:
		if ((leader.asked & ~loaded) == 0) {
			leader.complete = true;
			leader.step = ERX_STOP_STEP_RECORD;
		} else if (census_expired(leader.since_ns, now_ns)) {
			leader.complete = false;
			leader.step = ERX_STOP_STEP_RECORD;
		}
		break;
	default:
		break;
	}
	return (leader);
}

bool
erx_machine_stop_published(erx_stop_cpu_state_t state)
{
	return (state == ERX_STOP_CPU_STATE_STOPPED || state == ERX_STOP_CPU_STATE_WAITING ||
	    state == ERX_STOP_CPU_STATE_CONCURRENT || state == ERX_STOP_CPU_STATE_STARTING);
}

bool
erx_machine_stop_has_regs(erx_stop_cpu_state_t state)
{
	return (state == ERX_STOP_CPU_STATE_LEADER || erx_machine_stop_published(state));
}

erx_stop_cpu_state_t
erx_machine_stop_final(const erx_stop_leader_t *leader, uint32_t cpu, erx_stop_cpu_state_t published)
{
	if (cpu == leader->cpu)
		return (ERX_STOP_CPU_STATE_LEADER);
	if ((leader->asked & cpu_bit(cpu)) == 0)
		return (ERX_STOP_CPU_STATE_OFFLINE);
	if (erx_machine_stop_published(published))
		return (published);
	return (ERX_STOP_CPU_STATE_UNANSWERED);
}

/*
 * The readable-RAM map works in page numbers, with exclusive ends: an address's page
 * number is below 2^52, so no page arithmetic overflows. A union is read straight from
 * the entries, with no sorting and no scratch memory; the boot maps are a few dozen
 * entries, so scans that are cubic in the entries at worst cost nothing worth a buffer.
 */

/* How an entry takes part in the map; a class outside the enum is EXCLUDED. */
typedef enum ram_kind {
	RAM_KIND_RAM,
	RAM_KIND_USED,
	RAM_KIND_EXCLUDED,
	RAM_KIND_IGNORED,
} ram_kind_t;

static ram_kind_t
ram_kind(erx_ram_class_t ram_class)
{
	switch (ram_class) {
	case ERX_RAM_CLASS_RAM:
		return (RAM_KIND_RAM);
	case ERX_RAM_CLASS_USED:
		return (RAM_KIND_USED);
	case ERX_RAM_CLASS_IGNORED:
		return (RAM_KIND_IGNORED);
	default:
		return (RAM_KIND_EXCLUDED);
	}
}

/* Whether an entry's last byte lies below 2^64; an empty entry has none. */
static bool
entry_fits(const erx_ram_entry_t *entry)
{
	return (entry->length == 0 || entry->length - 1 <= UINT64_MAX - entry->base);
}

/*
 * An entry as pages [*first, *end) of its kind: a `ram` entry rounded inward, any other
 * outward. False when no whole page is left, or the entry is not of `kind`. The entry
 * fits (entry_fits).
 */
static bool
entry_pages(const erx_ram_entry_t *entry, ram_kind_t kind, uint64_t *first, uint64_t *end)
{
	uint64_t last;

	if (ram_kind(entry->ram_class) != kind || entry->length == 0)
		return (false);
	last = entry->base + (entry->length - 1);
	if (kind == RAM_KIND_RAM) {
		*first = entry->base / ERX_PAGE_SIZE + (entry->base % ERX_PAGE_SIZE != 0);
		*end = last / ERX_PAGE_SIZE + (last % ERX_PAGE_SIZE == ERX_PAGE_SIZE - 1);
	} else {
		*first = entry->base / ERX_PAGE_SIZE;
		*end = last / ERX_PAGE_SIZE + 1;
	}
	return (*first < *end);
}

/* Whether page `page` lies in the union of `kind`. */
static bool
union_covers(const erx_ram_entry_t *entries, size_t nentries, ram_kind_t kind, uint64_t page)
{
	uint64_t first, end;

	for (size_t i = 0; i < nentries; i++)
		if (entry_pages(&entries[i], kind, &first, &end) && first <= page && page < end)
			return (true);
	return (false);
}

/* The lowest page at or above `page` in the union of `kind`; false when there is none. */
static bool
union_next(const erx_ram_entry_t *entries, size_t nentries, ram_kind_t kind, uint64_t page, uint64_t *next)
{
	uint64_t first, end;
	bool found = false;

	for (size_t i = 0; i < nentries; i++) {
		if (!entry_pages(&entries[i], kind, &first, &end) || end <= page)
			continue;
		if (first < page)
			first = page;
		if (!found || first < *next)
			*next = first;
		found = true;
	}
	return (found);
}

/*
 * The end of the union of `kind`'s run through page `page`, which it covers. Each pass
 * that extends the run moves its end to a larger entry's end, so a pass per entry
 * reaches the run's end.
 */
static uint64_t
union_run_end(const erx_ram_entry_t *entries, size_t nentries, ram_kind_t kind, uint64_t page)
{
	uint64_t first, end, run_end = page;
	bool extended = true;

	for (size_t pass = 0; extended && pass <= nentries; pass++) {
		extended = false;
		for (size_t i = 0; i < nentries; i++) {
			if (entry_pages(&entries[i], kind, &first, &end) && first <= run_end && run_end < end) {
				run_end = end;
				extended = true;
			}
		}
	}
	return (run_end);
}

/*
 * Adds pages [first, end) to the map. A range that reaches the top of the address
 * space is refused, so base + length never wraps for a reader that compares bytes.
 */
static erx_ram_map_status_t
map_add(erx_ram_map_t *map, uint64_t first, uint64_t end)
{
	if (map->nranges == ERX_DEBUG_RAM_RANGES)
		return (ERX_RAM_MAP_TOO_MANY);
	if (end > UINT64_MAX / ERX_PAGE_SIZE)
		return (ERX_RAM_MAP_OVERFLOW);
	map->range[map->nranges++] = (erx_ram_range_t){
		.base = first * ERX_PAGE_SIZE,
		.length = (end - first) * ERX_PAGE_SIZE,
	};
	return (ERX_RAM_MAP_OK);
}

/*
 * Sweeps the pages upward from zero, one readable run at a time. Each round moves
 * `page` strictly upward to the end of an excluded run or of a readable range, each
 * an end or a start of some entry's pages, so the sweep ends after at most two rounds
 * per entry. A
 * readable range ends where the ram run ends or the next excluded run begins, and the
 * next one starts past a gap, so no two ranges touch.
 */
static erx_ram_map_status_t
map_sweep(const erx_ram_entry_t *entries, size_t nentries, erx_ram_map_t *map)
{
	uint64_t page = 0, start, end, excluded;
	erx_ram_map_status_t status;

	while (union_next(entries, nentries, RAM_KIND_RAM, page, &start)) {
		if (union_covers(entries, nentries, RAM_KIND_EXCLUDED, start)) {
			page = union_run_end(entries, nentries, RAM_KIND_EXCLUDED, start);
			continue;
		}
		end = union_run_end(entries, nentries, RAM_KIND_RAM, start);
		if (union_next(entries, nentries, RAM_KIND_EXCLUDED, start, &excluded) && excluded < end)
			end = excluded;
		if ((status = map_add(map, start, end)) != ERX_RAM_MAP_OK)
			return (status);
		page = end;
	}
	return (ERX_RAM_MAP_OK);
}

/* Whether pages [first, end) lie whole inside one range of the map. */
static bool
map_holds(const erx_ram_map_t *map, uint64_t first, uint64_t end)
{
	for (uint32_t i = 0; i < map->nranges; i++) {
		uint64_t range_first = map->range[i].base / ERX_PAGE_SIZE;
		uint64_t range_end = range_first + map->range[i].length / ERX_PAGE_SIZE;

		if (range_first <= first && end <= range_end)
			return (true);
	}
	return (false);
}

static erx_ram_map_status_t
map_build(const erx_ram_entry_t *entries, size_t nentries, erx_ram_map_t *map)
{
	uint64_t first, end;
	erx_ram_map_status_t status;

	for (size_t i = 0; i < nentries; i++)
		if (ram_kind(entries[i].ram_class) != RAM_KIND_IGNORED && !entry_fits(&entries[i]))
			return (ERX_RAM_MAP_OVERFLOW);
	if ((status = map_sweep(entries, nentries, map)) != ERX_RAM_MAP_OK)
		return (status);
	for (size_t i = 0; i < nentries; i++)
		if (entry_pages(&entries[i], RAM_KIND_USED, &first, &end) && !map_holds(map, first, end))
			return (ERX_RAM_MAP_USED_OUTSIDE);
	return (ERX_RAM_MAP_OK);
}

erx_ram_map_status_t
erx_machine_stop_ram_map(const erx_ram_entry_t *entries, size_t nentries, erx_ram_map_t *map)
{
	erx_ram_map_status_t status;

	*map = (erx_ram_map_t){ .nranges = 0 };
	if ((status = map_build(entries, nentries, map)) != ERX_RAM_MAP_OK)
		*map = (erx_ram_map_t){ .nranges = 0 };
	return (status);
}

const char *
erx_machine_stop_ram_map_reason(erx_ram_map_status_t status)
{
	switch (status) {
	case ERX_RAM_MAP_OVERFLOW:
		return ("an entry or a range ends past the address space");
	case ERX_RAM_MAP_TOO_MANY:
		return ("more readable ranges than the anchor holds");
	case ERX_RAM_MAP_USED_OUTSIDE:
		return ("memory in use lies outside the readable ranges");
	case ERX_RAM_MAP_OK:
	default:
		return (NULL);
	}
}
