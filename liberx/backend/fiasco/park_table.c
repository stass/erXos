/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "liberx/backend/fiasco/park_table.h"

_Static_assert(ERX_GROUP_EXECUTORS_MAX <= 64, "a used bit per slot, and a slot fits parked's bytes");

static bool	park_slot_valid(const erx_fiasco_park_t *, uint32_t);
static bool	park_leave(erx_fiasco_park_t *, uint32_t);
static bool	park_on_list(const erx_fiasco_park_t *, uint32_t);
static erx_fiasco_park_result_t park_take_oldest(erx_fiasco_park_t *);
static erx_fiasco_park_result_t park_locked_step(erx_fiasco_park_group_t *, const erx_fiasco_park_effects_t *,
    void *, const erx_fiasco_park_event_t *);
static void	park_mirror_slot(erx_fiasco_park_group_t *, uint32_t);

static bool
park_slot_valid(const erx_fiasco_park_t *park, uint32_t slot)
{
	return (slot < ERX_GROUP_EXECUTORS_MAX && (park->used & (UINT64_C(1) << slot)) != 0);
}

static bool
park_on_list(const erx_fiasco_park_t *park, uint32_t slot)
{
	for (uint32_t index = 0; index < park->parked_count; index++)
		if (park->parked[index] == slot)
			return (true);
	return (false);
}

/* Whether the slot was on the list: if not, a waker owes it an up. The rest keep their order. */
static bool
park_leave(erx_fiasco_park_t *park, uint32_t slot)
{
	uint32_t index = 0;

	while (index < park->parked_count && park->parked[index] != slot)
		index++;
	if (index == park->parked_count)
		return (false);
	for (index++; index < park->parked_count; index++)
		park->parked[index - 1] = park->parked[index];
	park->parked_count--;
	return (true);
}

static erx_fiasco_park_result_t
park_take_oldest(erx_fiasco_park_t *park)
{
	uint32_t slot;

	if (park->parked_count == 0)
		return ((erx_fiasco_park_result_t){ .action = ERX_FIASCO_PARK_NOTHING });
	slot = park->parked[0];
	(void)park_leave(park, slot);
	return ((erx_fiasco_park_result_t){ .action = ERX_FIASCO_PARK_UP, .slot = slot });
}

erx_fiasco_park_result_t
erx_fiasco_park_step(erx_fiasco_park_t *park, const erx_fiasco_park_event_t *event)
{
	const uint32_t slot = event->slot;

	switch (event->op) {
	case ERX_FIASCO_PARK_OP_CLAIM:
		for (uint32_t free_slot = 0; free_slot < ERX_GROUP_EXECUTORS_MAX; free_slot++) {
			if (!park_slot_valid(park, free_slot)) {
				park->used |= UINT64_C(1) << free_slot;
				return ((erx_fiasco_park_result_t){ .action = ERX_FIASCO_PARK_CLAIMED, .slot = free_slot });
			}
		}
		break;
	case ERX_FIASCO_PARK_OP_RELEASE:
		if (!park_slot_valid(park, slot))
			break;
		park->used &= ~(UINT64_C(1) << slot);
		park->group_epoch++;
		return (park_take_oldest(park));
	case ERX_FIASCO_PARK_OP_TRIGGER:
		park->group_epoch++;
		return (park_take_oldest(park));
	case ERX_FIASCO_PARK_OP_PARK:
		/* A listed slot has a park in progress, so a second one is refused. */
		if (!park_slot_valid(park, slot) || park_on_list(park, slot))
			break;
		if (park->group_epoch != event->group_seen || park->slot_epoch[slot] != event->slot_seen)
			return ((erx_fiasco_park_result_t){ .action = ERX_FIASCO_PARK_RETURN });
		park->parked[park->parked_count++] = (uint8_t)slot;
		return ((erx_fiasco_park_result_t){ .action = ERX_FIASCO_PARK_SLEEP });
	case ERX_FIASCO_PARK_OP_TIMEOUT:
		if (!park_slot_valid(park, slot))
			break;
		return ((erx_fiasco_park_result_t){ .action = park_leave(park, slot) ? ERX_FIASCO_PARK_TIMED_OUT :
		    ERX_FIASCO_PARK_OWED });
	case ERX_FIASCO_PARK_OP_WAKE:
		if (!park_slot_valid(park, slot))
			break;
		park->slot_epoch[slot]++;
		if (park_leave(park, slot))
			return ((erx_fiasco_park_result_t){ .action = ERX_FIASCO_PARK_UP, .slot = slot });
		return ((erx_fiasco_park_result_t){ .action = ERX_FIASCO_PARK_NOTHING });
	}
	return ((erx_fiasco_park_result_t){ .action = ERX_FIASCO_PARK_REFUSED });
}

static void
park_mirror_slot(erx_fiasco_park_group_t *group, uint32_t slot)
{
	const erx_fiasco_park_t *const park = &group->park;
	erx_exec_stat_t *const exec = &group->status->exec[slot];
	uint32_t state = ERX_EXEC_STATE_NONE;

	if (park_slot_valid(park, slot))
		state = park_on_list(park, slot) ? ERX_EXEC_STATE_PARKED : ERX_EXEC_STATE_RUNNING;
	atomic_store_explicit(&exec->state, state, memory_order_relaxed);
	atomic_store_explicit(&exec->epoch, park->slot_epoch[slot], memory_order_release);
}

/*
 * The step and its mirror, whose release stores pair with the executor's acquire
 * loads: an executor that read an epoch sees the work published before that advance.
 */
static erx_fiasco_park_result_t
park_locked_step(erx_fiasco_park_group_t *group, const erx_fiasco_park_effects_t *effects, void *context,
    const erx_fiasco_park_event_t *event)
{
	erx_fiasco_park_result_t result;

	effects->lock(context);
	result = erx_fiasco_park_step(&group->park, event);
	atomic_store_explicit(&group->status->parked, group->park.parked_count, memory_order_relaxed);
	if (event->op != ERX_FIASCO_PARK_OP_CLAIM && event->op != ERX_FIASCO_PARK_OP_TRIGGER &&
	    event->slot < ERX_GROUP_EXECUTORS_MAX)
		park_mirror_slot(group, event->slot);
	if (result.action == ERX_FIASCO_PARK_UP || result.action == ERX_FIASCO_PARK_CLAIMED)
		park_mirror_slot(group, result.slot);
	atomic_store_explicit(&group->status->epoch, group->park.group_epoch, memory_order_release);
	effects->unlock(context);
	return (result);
}

uint32_t
erx_fiasco_park_claim(erx_fiasco_park_group_t *group, const erx_fiasco_park_effects_t *effects, void *context)
{
	const erx_fiasco_park_event_t event = { .op = ERX_FIASCO_PARK_OP_CLAIM };
	const erx_fiasco_park_result_t result = park_locked_step(group, effects, context, &event);

	return (result.action == ERX_FIASCO_PARK_CLAIMED ? result.slot : ERX_FIASCO_PARK_NO_SLOT);
}

void
erx_fiasco_park_release(erx_fiasco_park_group_t *group, const erx_fiasco_park_effects_t *effects, void *context,
    uint32_t slot)
{
	const erx_fiasco_park_event_t event = { .op = ERX_FIASCO_PARK_OP_RELEASE, .slot = slot };
	const erx_fiasco_park_result_t result = park_locked_step(group, effects, context, &event);

	if (result.action == ERX_FIASCO_PARK_UP)
		effects->up(context, result.slot);
}

void
erx_fiasco_park_trigger(erx_fiasco_park_group_t *group, const erx_fiasco_park_effects_t *effects, void *context)
{
	const erx_fiasco_park_event_t event = { .op = ERX_FIASCO_PARK_OP_TRIGGER };
	const erx_fiasco_park_result_t result = park_locked_step(group, effects, context, &event);

	if (result.action == ERX_FIASCO_PARK_UP)
		effects->up(context, result.slot);
}

int
erx_fiasco_park_wait(erx_fiasco_park_group_t *group, const erx_fiasco_park_effects_t *effects, void *context,
    uint32_t slot, uint64_t group_seen, uint64_t slot_seen, uint64_t deadline)
{
	const erx_fiasco_park_event_t park = { .op = ERX_FIASCO_PARK_OP_PARK, .slot = slot,
	    .group_seen = group_seen, .slot_seen = slot_seen };
	const erx_fiasco_park_event_t timeout = { .op = ERX_FIASCO_PARK_OP_TIMEOUT, .slot = slot };

	if (park_locked_step(group, effects, context, &park).action != ERX_FIASCO_PARK_SLEEP)
		return (ERX_OK);
	if (effects->down(context, slot, deadline))
		return (ERX_OK);
	if (park_locked_step(group, effects, context, &timeout).action == ERX_FIASCO_PARK_TIMED_OUT)
		return (ERX_ETIMEDOUT);
	/* A waker took this slot as the deadline came: its up is on the way. */
	effects->absorb(context, slot);
	return (ERX_OK);
}

int
erx_fiasco_park_wake(erx_fiasco_park_group_t *group, const erx_fiasco_park_effects_t *effects, void *context,
    uint32_t slot)
{
	const erx_fiasco_park_event_t event = { .op = ERX_FIASCO_PARK_OP_WAKE, .slot = slot };
	const erx_fiasco_park_result_t result = park_locked_step(group, effects, context, &event);

	if (result.action == ERX_FIASCO_PARK_REFUSED)
		return (ERX_EINVAL);
	if (result.action == ERX_FIASCO_PARK_UP)
		effects->up(context, result.slot);
	return (ERX_OK);
}
