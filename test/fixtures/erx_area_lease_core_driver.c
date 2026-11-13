/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of the lease's core (otp/erts/emulator/nifs/erxos/
 * erx_area_lease_core.c), run by test/host/erx_area_lease_core_test.rb.
 * Each case prints "NAME ok" or "NAME FAIL: why".
 *
 * transitions: every sequence of up to SEQUENCE_MAX events, each a take
 * by the holder's port, a take by another owner's port, a give-back, the
 * holder's exit or the driver's return, from a held lease. The driver's
 * return enters a sequence only after a take was granted, as the driver
 * returns only what it took, and at most once. In each: a take is granted
 * at most once, only to the holder's port and only while held; the lease
 * is returned at most once; a taken lease is returned only by its driver
 * and a held one only by the holder's exit or a give-back; and once the
 * holder has exited and every granted take has been returned by its
 * driver, the lease has been returned exactly once.
 *
 * range: erx_area:lend/4's check of a range against its area.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>

#include "erx_area_lease_core.h"
#include "erx/abi.h"

#define SEQUENCE_MAX	7

enum { TAKE_HOLDER, TAKE_OTHER, GIVE_BACK, HOLDER_EXIT, DRIVER_RETURN, KINDS };

static const char *failure;

static bool
replay(const int *events, int count)
{
	erx_lease_state_t state = ERX_LEASE_HELD;
	int takes = 0, returns = 0, driver_returns = 0;
	bool exited = false;

	for (int i = 0; i < count; i++) {
		static const erx_lease_event_t event_of[KINDS] = {
			[TAKE_HOLDER] = ERX_LEASE_TAKE, [TAKE_OTHER] = ERX_LEASE_TAKE,
			[GIVE_BACK] = ERX_LEASE_GIVE_BACK, [HOLDER_EXIT] = ERX_LEASE_HOLDER_EXIT,
			[DRIVER_RETURN] = ERX_LEASE_DRIVER_RETURN,
		};
		erx_lease_step_t step = erx_lease_step(state, event_of[events[i]], events[i] == TAKE_HOLDER);

		if (step.taken && (events[i] != TAKE_HOLDER || state != ERX_LEASE_HELD))
			return (failure = "a take granted to another port or a lease not held", false);
		if (step.returned && state == ERX_LEASE_TAKEN && events[i] != DRIVER_RETURN)
			return (failure = "a taken lease returned by someone other than its driver", false);
		if (step.returned && state == ERX_LEASE_HELD && events[i] != GIVE_BACK && events[i] != HOLDER_EXIT)
			return (failure = "a held lease returned by something other than its holder", false);
		if (step.returned != (step.next == ERX_LEASE_RETURNED && state != ERX_LEASE_RETURNED))
			return (failure = "a return that does not enter returned", false);
		takes += step.taken;
		returns += step.returned;
		driver_returns += events[i] == DRIVER_RETURN;
		exited |= events[i] == HOLDER_EXIT;
		state = step.next;
		if (takes > 1 || returns > 1)
			return (failure = "a second take or a second return", false);
	}
	if (exited && driver_returns == takes && returns != 1)
		return (failure = "a lease never returned after its holder's exit and its driver's return", false);
	return (true);
}

/* Every sequence of count events in which a driver's return follows its take. */
static bool
explore(int *events, int count, int length, int takes_granted)
{
	if (count == length)
		return (replay(events, count));
	for (int kind = 0; kind < KINDS; kind++) {
		int granted = takes_granted;

		if (kind == DRIVER_RETURN) {
			bool returned = false;

			for (int i = 0; i < count; i++)
				returned |= events[i] == DRIVER_RETURN;
			if (takes_granted == 0 || returned)
				continue;
		}
		if (kind == TAKE_HOLDER && takes_granted == 0) {
			/* Granted only while held: no return before it. */
			bool returned = false;

			for (int i = 0; i < count; i++)
				returned |= events[i] == GIVE_BACK || events[i] == HOLDER_EXIT;
			granted += !returned;
		}
		events[count] = kind;
		if (!explore(events, count + 1, length, granted))
			return (false);
	}
	return (true);
}

static void
transitions(void)
{
	int events[SEQUENCE_MAX];

	for (int length = 1; length <= SEQUENCE_MAX; length++)
		if (!explore(events, 0, length, 0)) {
			printf("transitions FAIL: %s\n", failure);
			return;
		}
	printf("transitions ok\n");
}

static void
range(void)
{
	const uint64_t page = ERX_PAGE_SIZE, area = 4 * page, most = ERX_PROG_MEM_BYTES / ERX_PAGE_SIZE;
	struct { uint64_t offset, pages, area; bool writable, ok; } cases[] = {
		{ 0, 4, area, true, true },			/* ends at the area's last page */
		{ page, 4, area, true, false },			/* one page past it */
		{ UINT64_MAX - page + 1, 2, UINT64_MAX, true, false }, /* offset + bytes past 2^64 */
		{ page + 1, 1, area, true, false },		/* one byte past a page boundary */
		{ 0, 0, area, true, false },
		{ 0, most, most * page, true, true },
		{ 0, most + 1, (most + 1) * page, true, false },
		{ 0, 1, area, false, false },			/* a read-only area */
	};

	for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++)
		if (erx_lease_range_ok(cases[i].offset, cases[i].pages, page, cases[i].area, cases[i].writable) !=
		    cases[i].ok) {
			printf("range FAIL: case %zu\n", i);
			return;
		}
	printf("range ok\n");
}

int
main(void)
{
	transitions();
	range();
	return (0);
}
