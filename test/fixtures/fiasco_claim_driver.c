/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The claim against a fake kernel, over every order of creates, exits, reaps and
 * the kernel's late write of the marker, on two indices and three thread lives.
 * The write belongs to the life that exited. If it lands on a live thread, the
 * kernel has cleared that thread's marker, and the index would go to a third
 * thread while the second still runs on its UTCB.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "liberx/backend/fiasco/thread_claim.h"

#define INDICES	3u	/* index 0 is the first thread's: a claim starts at 1 */
#define LIVES	3u

typedef struct model {
	bool		used[INDICES];
	bool		alive[INDICES];
	bool		write_owed[INDICES];
	uint64_t	marker[INDICES];
	uint32_t	created;
} model_t;

static uint64_t orders;

static bool
view_used(void *context, uint32_t index)
{
	return (((const model_t *)context)->used[index]);
}

static uint64_t
view_marker(void *context, uint32_t index)
{
	return (((const model_t *)context)->marker[index]);
}

static const erx_fiasco_claim_view_t view = { .used = view_used, .marker = view_marker };

static void
explore(const model_t *state)
{
	model_t next;
	bool moved = false;

	if (state->created < LIVES) {
		next = *state;
		const uint32_t index = erx_fiasco_thread_claim_pick(&view, &next, 1, INDICES);

		if (index < INDICES) {
			if (next.write_owed[index]) {
				puts("claim: an index went to a new thread with the kernel's write still to come");
				exit(1);
			}
			next.used[index] = true;
			next.alive[index] = true;
			next.marker[index] = 1;
			next.created++;
			moved = true;
			explore(&next);
		}
	}
	for (uint32_t index = 1; index < INDICES; index++) {
		if (state->alive[index]) {
			/* The exit, the deletion's return and the reaper's last step, as one move. */
			next = *state;
			next.alive[index] = false;
			next.used[index] = false;
			next.write_owed[index] = true;
			moved = true;
			explore(&next);
		}
		if (state->write_owed[index]) {
			next = *state;
			next.write_owed[index] = false;
			next.marker[index] = 0;
			moved = true;
			explore(&next);
		}
	}
	if (!moved)
		orders++;
}

int
main(void)
{
	const model_t start = { .created = 0 };

	explore(&start);
	if (orders == 0) {
		puts("claim: no order ran");
		return (1);
	}
	printf("claim: %llu orders\n", (unsigned long long)orders);
	return (0);
}
