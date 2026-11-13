/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device_dma_order and erx_device_dma_check on the host (test/host/erx_device_dma_test.rb).
 *
 * A queue of QUEUE_BUFFERS buffers with a split ring's two ring regions is driven through
 * every transition its calls allow: every post from every set of posted buffers to every
 * larger one, every completion to every smaller one, every reset and every install, and an
 * observation of the used ring, each for a coherent and a non-coherent device and with the
 * line equal to the granule and a quarter of it. Each plan is checked, ordered, and the
 * effects held to the design's order: the zeroing before the writes and covering exactly the
 * bytes no write fills, every clean before the first publish barrier, a publish barrier
 * before every publish, maintenance at every line of every region it covers, the report
 * barrier, ordering loads and stores, after the reads, and the completion barrier after every
 * taking back and before every copy; for a coherent device no maintenance and the same
 * barriers. Then the check refuses each malformed plan the design lists.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "otp/erts/emulator/nifs/erxos/erx_device_dma.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define GRANULE		64u
#define QUEUE_BUFFERS	4u
#define STRIDE		(2u * GRANULE)
#define RINGS		0u		/* the descriptor table and the available ring */
#define RINGS_LENGTH	(2u * GRANULE)
#define USED		(RINGS + RINGS_LENGTH)
#define USED_LENGTH	GRANULE
#define POOL		(USED + USED_LENGTH)
/* A region of the record after the pool, held by the record and by no queue. */
#define RECORD_REGION	(POOL + QUEUE_BUFFERS * STRIDE)
#define MEMORY		(RECORD_REGION + GRANULE)
#define DEVICE_BASE	UINT64_C(0x40000000)
#define PUBLICATION	(RINGS + 66u)	/* the available index */
#define NOTIFY		0x50u
#define READY		0x44u
#define STEPS_MAX	64u
#define EFFECTS_MAX	ERX_DMA_EFFECTS_BOUND(ERX_DMA_REGIONS_MAX, STEPS_MAX)

static const uint32_t owned_registers[] = { NOTIFY, READY, 0x80u, 0x84u };
static const uint8_t out_bytes[24] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 };

static erx_dma_context_t
context(void)
{
	return ((erx_dma_context_t){ .memory_size = MEMORY, .device_base = DEVICE_BASE, .window_size = 0x100, .address_bits = 32,
	    .granule = GRANULE, .publication = PUBLICATION, .publication_width = 2,
	    .owned_count = sizeof(owned_registers) / sizeof(owned_registers[0]), .owned = owned_registers });
}

/* The queue's regions with the used ring the device's when installed, and buffer i the device's when bit i is set. */
static void
view(erx_dma_state_t *state, bool installed, uint32_t posted)
{
	state->count = 0;
	state->regions[state->count++] = (erx_dma_region_t){ RINGS, RINGS_LENGTH, ERX_DMA_RING, ERX_DMA_CPU };
	state->regions[state->count++] = (erx_dma_region_t){ USED, USED_LENGTH, ERX_DMA_RING,
	    installed ? ERX_DMA_DEVICE : ERX_DMA_CPU };
	for (uint32_t buffer = 0; buffer < QUEUE_BUFFERS; buffer++)
		state->regions[state->count++] = (erx_dma_region_t){ POOL + buffer * STRIDE, STRIDE, ERX_DMA_BUFFER,
		    (posted >> buffer & 1u) != 0 ? ERX_DMA_DEVICE : ERX_DMA_CPU };
}

static erx_dma_step_t
write_bytes(uint64_t offset, uint64_t length)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_WRITE, .target = ERX_DMA_MEMORY, .source = ERX_DMA_BYTES,
	    .offset = offset, .length = length, .bytes = out_bytes });
}

static erx_dma_step_t
write_value(erx_dma_source_t source, uint64_t offset, uint32_t width, uint64_t value, uint64_t extent)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_WRITE, .target = ERX_DMA_MEMORY, .source = source, .width = width,
	    .offset = offset, .value = value, .extent = extent });
}

static erx_dma_step_t
publish_register(uint32_t reg, uint64_t value)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_VALUE,
	    .width = 4, .reg = reg, .reg_high = ERX_DMA_NO_REGISTER, .value = value });
}

static erx_dma_step_t
publish_index(uint16_t index)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_MEMORY, .source = ERX_DMA_VALUE,
	    .width = 2, .offset = PUBLICATION, .value = index });
}

/*
 * A post of every buffer in `fresh`: two out segments with a gap between them, a descriptor
 * address and an available entry for each, then the available index and the doorbell.
 */
static uint32_t
post_steps(uint32_t fresh, erx_dma_step_t *steps)
{
	uint32_t count = 0;

	for (uint32_t buffer = 0; buffer < QUEUE_BUFFERS; buffer++) {
		const uint64_t at = POOL + buffer * STRIDE;

		if ((fresh >> buffer & 1u) == 0)
			continue;
		steps[count++] = write_bytes(at, 10);
		steps[count++] = write_bytes(at + 40, 24);
		steps[count++] = write_value(ERX_DMA_ADDRESS, RINGS + 16u * buffer, 8, DEVICE_BASE + at, STRIDE);
		steps[count++] = write_value(ERX_DMA_VALUE, RINGS + 68u + 2u * buffer, 2, buffer, 0);
	}
	steps[count++] = publish_index(7);
	steps[count++] = publish_register(NOTIFY, 0);
	return (count);
}

/* An install: both ring regions zeroed, the used ring's address published over two registers, then ready. */
static uint32_t
install_steps(uint32_t standing, erx_dma_step_t *steps)
{
	uint32_t count = 0;

	steps[count++] = (erx_dma_step_t){ .kind = ERX_DMA_WRITE, .target = ERX_DMA_MEMORY, .source = ERX_DMA_ZEROS,
	    .offset = RINGS, .length = RINGS_LENGTH };
	steps[count++] = (erx_dma_step_t){ .kind = ERX_DMA_WRITE, .target = ERX_DMA_MEMORY, .source = ERX_DMA_ZEROS,
	    .offset = USED, .length = USED_LENGTH };
	for (uint32_t buffer = 0; buffer < QUEUE_BUFFERS; buffer++) {
		if ((standing >> buffer & 1u) != 0)
			steps[count++] = write_value(ERX_DMA_ADDRESS, RINGS + 16u * buffer, 8, DEVICE_BASE + POOL +
			    buffer * STRIDE, STRIDE);
	}
	steps[count++] = (erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_ADDRESS,
	    .width = 8, .reg = 0x80u, .reg_high = 0x84u, .value = DEVICE_BASE + USED, .extent = USED_LENGTH };
	steps[count++] = publish_register(READY, 1);
	return (count);
}

/* A completion of every buffer in `done`: each copies a prefix of its buffer. */
static uint32_t
complete_steps(uint32_t done, erx_dma_step_t *steps)
{
	uint32_t count = 0;

	for (uint32_t buffer = 0; buffer < QUEUE_BUFFERS; buffer++) {
		if ((done >> buffer & 1u) != 0)
			steps[count++] = (erx_dma_step_t){ .kind = ERX_DMA_COPY, .target = ERX_DMA_MEMORY,
			    .offset = POOL + buffer * STRIDE, .length = 100 };
	}
	return (count);
}

/* An observation: the used index, two used entries, and the device's status register. */
static uint32_t
observe_steps(erx_dma_step_t *steps)
{
	uint32_t count = 0;
	const uint64_t fields[] = { USED + 2, USED + 4, USED + 8, USED + 12, USED + 16 };

	for (uint32_t field = 0; field < sizeof(fields) / sizeof(fields[0]); field++)
		steps[count++] = (erx_dma_step_t){ .kind = ERX_DMA_REPORT, .target = ERX_DMA_MEMORY,
		    .width = field == 0 ? 2 : 4, .offset = fields[field] };
	steps[count++] = (erx_dma_step_t){ .kind = ERX_DMA_REPORT, .target = ERX_DMA_REGISTER, .width = 4, .reg = 0x70u };
	return (count);
}

/* -------------------------------------------------------------------------------------------
 * The order's properties
 */

typedef struct run {
	const erx_dma_state_t	*before;
	const erx_dma_state_t	*after;
	const erx_dma_plan_t	*plan;
	bool			coherent;
	uint32_t		line;
	erx_dma_effects_t	effects;
} run_t;

static bool
is_maintenance(const erx_dma_effect_t *effect)
{
	return (effect->kind == ERX_DMA_EFFECT_CLEAN || effect->kind == ERX_DMA_EFFECT_CLEAN_INVAL);
}

static const erx_dma_step_t *
step_of(const run_t *run, const erx_dma_effect_t *effect)
{
	return (effect->kind == ERX_DMA_EFFECT_STEP ? &run->plan->steps[effect->step] : NULL);
}

/*
 * Every line of [offset, offset + length) is reached by a maintenance instruction of `kind`,
 * among effects [from, to). Each effect's instructions are at every effect->line from its start.
 */
static bool
lines_reached(const run_t *run, erx_dma_effect_kind_t kind, uint64_t offset, uint64_t length, uint32_t from, uint32_t to)
{
	bool reached[MEMORY / 4] = { false };

	for (uint32_t index = from; index < to; index++) {
		const erx_dma_effect_t *const effect = &run->effects.effects[index];

		if (effect->kind != kind)
			continue;
		for (uint64_t at = effect->offset; at < effect->offset + effect->length; at += effect->line)
			reached[at / run->line] = true;
	}
	for (uint64_t at = offset; at < offset + length; at += run->line) {
		if (!reached[at / run->line])
			return (false);
	}
	return (true);
}

static void
verify_hand_over(const run_t *run)
{
	const erx_dma_effect_t *const effects = run->effects.effects;
	uint32_t first_write = run->effects.count, first_publish_barrier = run->effects.count;
	uint8_t covered[MEMORY] = { 0 };

	for (uint32_t index = 0; index < run->effects.count; index++) {
		const erx_dma_step_t *const step = step_of(run, &effects[index]);

		if (step != NULL && step->kind == ERX_DMA_WRITE && first_write == run->effects.count)
			first_write = index;
		if (effects[index].kind == ERX_DMA_EFFECT_BARRIER && first_publish_barrier == run->effects.count)
			first_publish_barrier = index;
		/* Every zeroing before the writes, and a byte zeroed or filled once at most. */
		if (effects[index].kind == ERX_DMA_EFFECT_ZERO) {
			CHECK(index < first_write);
			for (uint64_t at = effects[index].offset; at < effects[index].offset + effects[index].length; at++)
				CHECK(covered[at]++ == 0);
		}
		if (step != NULL && step->kind == ERX_DMA_WRITE && step->source == ERX_DMA_BYTES) {
			for (uint64_t at = step->offset; at < step->offset + step->length; at++)
				covered[at]++;
		}
		/* Every publish right after a publish barrier, which completes the maintenance of a non-coherent device. */
		if (step != NULL && step->kind == ERX_DMA_PUBLISH) {
			CHECK(index > 0 && effects[index - 1].kind == ERX_DMA_EFFECT_BARRIER);
			CHECK(effects[index - 1].barrier == ERX_DMA_BARRIER_PUBLISH);
			CHECK(effects[index - 1].completes == !run->coherent);
			CHECK(effects[index - 1].orders == (ERX_DMA_ORDERS_LOADS | ERX_DMA_ORDERS_STORES));
		}
		/* No maintenance after the first publish barrier but a publication's own line, and none before a write. */
		if (is_maintenance(&effects[index])) {
			for (uint32_t later = index + 1; later < run->effects.count; later++) {
				const erx_dma_step_t *const after_clean = step_of(run, &effects[later]);

				CHECK(effects[later].kind != ERX_DMA_EFFECT_ZERO);
				CHECK(after_clean == NULL || after_clean->kind != ERX_DMA_WRITE);
			}
			CHECK(!run->coherent);
			CHECK(effects[index].kind == ERX_DMA_EFFECT_CLEAN);
			if (index > first_publish_barrier) {
				const erx_dma_step_t *const published = step_of(run, &effects[index - 1]);

				CHECK(published != NULL && published->kind == ERX_DMA_PUBLISH && published->target == ERX_DMA_MEMORY);
				CHECK(effects[index].offset <= published->offset &&
				    published->offset + published->width <= effects[index].offset + effects[index].length);
			}
		}
	}
	/* Every byte of a buffer passing to the device is filled or zeroed, exactly once. */
	for (uint32_t region = 0; region < run->before->count; region++) {
		const erx_dma_region_t *const r = &run->before->regions[region];
		const bool passing = r->writer == ERX_DMA_CPU && run->after->regions[region].writer == ERX_DMA_DEVICE;

		if (passing && r->kind == ERX_DMA_BUFFER) {
			for (uint64_t at = r->offset; at < r->offset + r->length; at++)
				CHECK(covered[at] == 1);
		}
		/* Every region passing, and every ring the CPU keeps (each plan here writes them), cleaned at every line before the first publish barrier. */
		if (!run->coherent && (passing || (r->kind == ERX_DMA_RING && r->writer == ERX_DMA_CPU)))
			CHECK(lines_reached(run, ERX_DMA_EFFECT_CLEAN, r->offset, r->length, 0, first_publish_barrier));
	}
}

static void
verify_take_back(const run_t *run)
{
	const erx_dma_effect_t *const effects = run->effects.effects;
	uint32_t first_copy = run->effects.count, barrier = run->effects.count, copies = 0;

	for (uint32_t index = 0; index < run->effects.count; index++) {
		if (effects[index].kind == ERX_DMA_EFFECT_STEP) {
			CHECK(run->plan->steps[effects[index].step].kind == ERX_DMA_COPY);
			first_copy = first_copy < index ? first_copy : index;
			copies++;
		}
		if (effects[index].kind == ERX_DMA_EFFECT_BARRIER) {
			CHECK(effects[index].barrier == ERX_DMA_BARRIER_COMPLETION && effects[index].completes);
			barrier = index;
		}
		if (is_maintenance(&effects[index])) {
			CHECK(!run->coherent && effects[index].kind == ERX_DMA_EFFECT_CLEAN_INVAL);
			CHECK(index < barrier || barrier == run->effects.count);
		}
	}
	CHECK(copies == run->plan->count);
	for (uint32_t region = 0; region < run->before->count; region++) {
		const erx_dma_region_t *const r = &run->before->regions[region];

		if (run->coherent || r->writer != ERX_DMA_DEVICE || run->after->regions[region].writer != ERX_DMA_CPU)
			continue;
		/* Every region coming back taken back at every line, and its barrier, before every copy. */
		CHECK(barrier < first_copy);
		CHECK(lines_reached(run, ERX_DMA_EFFECT_CLEAN_INVAL, r->offset, r->length, 0, barrier));
	}
	if (run->coherent)
		CHECK(barrier == run->effects.count);
}

static void
verify_observe(const run_t *run)
{
	const erx_dma_effect_t *const effects = run->effects.effects;
	const uint32_t count = run->effects.count;
	uint32_t first_read = count;

	for (uint32_t index = 0; index < count; index++) {
		if (effects[index].kind == ERX_DMA_EFFECT_STEP && first_read == count)
			first_read = index;
		if (is_maintenance(&effects[index]))
			CHECK(!run->coherent && effects[index].kind == ERX_DMA_EFFECT_CLEAN_INVAL && index < first_read);
	}
	CHECK(count >= 1 + run->plan->count);
	/* The report barrier last, after every read, ordering loads and stores both. */
	CHECK(effects[count - 1].kind == ERX_DMA_EFFECT_BARRIER && effects[count - 1].barrier == ERX_DMA_BARRIER_REPORT);
	CHECK(effects[count - 1].orders == (ERX_DMA_ORDERS_LOADS | ERX_DMA_ORDERS_STORES));
	CHECK(first_read + run->plan->count == count - 1);
	if (!run->coherent) {
		CHECK(first_read > 0 && effects[first_read - 1].kind == ERX_DMA_EFFECT_BARRIER);
		CHECK(effects[first_read - 1].barrier == ERX_DMA_BARRIER_COMPLETION && effects[first_read - 1].completes);
		for (uint32_t step = 0; step < run->plan->count; step++) {
			const erx_dma_step_t *const report = &run->plan->steps[step];

			if (report->target == ERX_DMA_MEMORY)
				CHECK(lines_reached(run, ERX_DMA_EFFECT_CLEAN_INVAL, report->offset - report->offset % run->line,
				    run->line, 0, first_read));
		}
	} else {
		CHECK(first_read == 0);
	}
}

/* Checks the plan, orders it for each device and line, and holds the effects to the order. */
static void
exercise(const erx_dma_state_t *before, const erx_dma_state_t *after, const erx_dma_plan_t *plan)
{
	static erx_dma_effect_t storage[EFFECTS_MAX];
	const erx_dma_context_t ctx = context();
	const uint32_t lines[] = { GRANULE, GRANULE / 4 };

	CHECK(erx_device_dma_check(&ctx, before, after, plan));
	for (uint32_t coherent = 0; coherent < 2; coherent++) {
		for (uint32_t line = 0; line < 2; line++) {
			run_t run = { before, after, plan, coherent != 0, lines[line],
			    { .capacity = EFFECTS_MAX, .effects = storage } };

			CHECK(erx_device_dma_order(before, after, plan, run.coherent, GRANULE, run.line, &run.effects));
			switch (plan->call) {
			case ERX_DMA_CALL_POST:
			case ERX_DMA_CALL_INSTALL:
				verify_hand_over(&run);
				break;
			case ERX_DMA_CALL_COMPLETE:
			case ERX_DMA_CALL_RESET:
				verify_take_back(&run);
				break;
			default:
				verify_observe(&run);
				break;
			}
		}
	}
}

static void
every_transition(void)
{
	erx_dma_state_t before, after;
	erx_dma_step_t steps[STEPS_MAX];
	erx_dma_plan_t plan = { .steps = steps };
	uint32_t transitions = 0;
	const uint32_t all = (1u << QUEUE_BUFFERS) - 1;

	for (uint32_t posted = 0; posted <= all; posted++) {
		for (uint32_t other = 0; other <= all; other++) {
			view(&before, true, posted);
			view(&after, true, other);
			if ((posted & other) == posted && other != posted) {
				plan.call = ERX_DMA_CALL_POST;
				plan.count = post_steps(other & ~posted, steps);
				exercise(&before, &after, &plan);
				transitions++;
			}
			if ((posted & other) == other) {
				plan.call = ERX_DMA_CALL_COMPLETE;
				plan.count = complete_steps(posted & ~other, steps);
				exercise(&before, &after, &plan);
				transitions++;
			}
		}
		view(&before, true, posted);
		view(&after, false, 0);
		plan = (erx_dma_plan_t){ .call = ERX_DMA_CALL_RESET, .count = 0, .steps = steps };
		exercise(&before, &after, &plan);
		view(&before, false, 0);
		view(&after, true, posted);
		plan.call = ERX_DMA_CALL_INSTALL;
		plan.count = install_steps(posted, steps);
		exercise(&before, &after, &plan);
		view(&before, true, posted);
		view(&after, true, posted);
		plan.call = ERX_DMA_CALL_OBSERVE;
		plan.count = observe_steps(steps);
		exercise(&before, &after, &plan);
		transitions += 3;
	}
	/* 81 posts and completions each way over 4 buffers' subsets, plus reset, install and observe per set. */
	CHECK(transitions == 65 + 81 + 3 * 16);
}

/* -------------------------------------------------------------------------------------------
 * The check's refusals
 */

static bool
checks(const erx_dma_state_t *before, const erx_dma_state_t *after, erx_dma_call_t call, erx_dma_step_t step)
{
	const erx_dma_context_t ctx = context();
	const erx_dma_plan_t plan = { .call = call, .count = 1, .steps = &step };

	return (erx_device_dma_check(&ctx, before, after, &plan));
}

static void
refusals(void)
{
	erx_dma_state_t before, after;
	erx_dma_context_t ctx = context();
	const erx_dma_plan_t empty = { .call = ERX_DMA_CALL_POST, .count = 0, .steps = NULL };

	view(&before, true, 0x1);
	view(&after, true, 0x3);
	/* The plain post is accepted, so each refusal below is its own. */
	CHECK(checks(&before, &after, ERX_DMA_CALL_POST, write_bytes(POOL + STRIDE, 10)));
	/* A region off a granule, and one past the record's memory. */
	before.regions[3].length = after.regions[3].length = STRIDE - 8;
	CHECK(!erx_device_dma_check(&ctx, &before, &after, &empty));
	view(&before, true, 0x1);
	view(&after, true, 0x3);
	before.regions[5].length = after.regions[5].length = 4 * STRIDE;
	CHECK(!erx_device_dma_check(&ctx, &before, &after, &empty));
	view(&before, true, 0x1);
	view(&after, true, 0x3);
	/* A write into a buffer the device holds, into one not passing, and a ring value into a buffer. */
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, write_bytes(POOL, 10)));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, write_bytes(POOL + 2 * STRIDE, 10)));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, write_value(ERX_DMA_VALUE, POOL + STRIDE, 4, 1, 0)));
	/* A write into the used ring the device writes, and one across two regions. */
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, write_value(ERX_DMA_VALUE, USED, 4, 1, 0)));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, write_bytes(POOL + 2 * STRIDE - 4, 10)));
	/* A publish of a register the driver writes, not the NIF, and of a ring field that is not the publication. */
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, publish_register(0x30u, 1)));
	CHECK(checks(&before, &after, ERX_DMA_CALL_POST, publish_register(NOTIFY, 1)));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, (erx_dma_step_t){ .kind = ERX_DMA_PUBLISH,
	    .target = ERX_DMA_MEMORY, .source = ERX_DMA_VALUE, .width = 2, .offset = PUBLICATION + 2, .value = 1 }));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, publish_register(NOTIFY, UINT64_C(1) << 32)));
	/* An address over two registers: both owned, distinct, and only as an address of width 8. */
	CHECK(checks(&before, &after, ERX_DMA_CALL_POST, (erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER,
	    .source = ERX_DMA_ADDRESS, .width = 8, .reg = 0x80u, .reg_high = 0x84u, .value = DEVICE_BASE + POOL, .extent = 1 }));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, (erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER,
	    .source = ERX_DMA_ADDRESS, .width = 8, .reg = 0x80u, .reg_high = 0x30u, .value = DEVICE_BASE + POOL, .extent = 1 }));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, (erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER,
	    .source = ERX_DMA_VALUE, .width = 8, .reg = 0x80u, .reg_high = 0x84u, .value = 1 }));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, (erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER,
	    .source = ERX_DMA_VALUE, .width = 8, .reg = NOTIFY, .reg_high = ERX_DMA_NO_REGISTER, .value = 1 }));
	/* Overlapping regions, and two states whose regions differ. */
	before.regions[3].length = after.regions[3].length = 2 * STRIDE;
	CHECK(!erx_device_dma_check(&ctx, &before, &after, &empty));
	view(&before, true, 0x1);
	after.regions[2].kind = ERX_DMA_RING;
	CHECK(!erx_device_dma_check(&ctx, &before, &after, &empty));
	view(&after, true, 0x3);
	/* A state change the call does not allow: a post that takes a buffer back, a completion of a ring. */
	CHECK(!checks(&after, &before, ERX_DMA_CALL_POST, publish_register(NOTIFY, 1)));
	view(&before, true, 0x3);
	view(&after, false, 0x1);
	CHECK(!checks(&before, &after, ERX_DMA_CALL_COMPLETE,
	    (erx_dma_step_t){ .kind = ERX_DMA_COPY, .target = ERX_DMA_MEMORY, .offset = POOL + STRIDE, .length = 8 }));
	/* A copy of a buffer not coming back, and past its end. */
	view(&after, true, 0x1);
	CHECK(checks(&before, &after, ERX_DMA_CALL_COMPLETE,
	    (erx_dma_step_t){ .kind = ERX_DMA_COPY, .target = ERX_DMA_MEMORY, .offset = POOL + STRIDE, .length = 8 }));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_COMPLETE,
	    (erx_dma_step_t){ .kind = ERX_DMA_COPY, .target = ERX_DMA_MEMORY, .offset = POOL, .length = 8 }));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_COMPLETE,
	    (erx_dma_step_t){ .kind = ERX_DMA_COPY, .target = ERX_DMA_MEMORY, .offset = POOL + STRIDE, .length = STRIDE + 1 }));
	/* A step the call does not make. */
	CHECK(!checks(&before, &after, ERX_DMA_CALL_COMPLETE, write_bytes(POOL + STRIDE, 10)));
	/* A report of memory the CPU writes, and one off its width. */
	view(&before, true, 0x1);
	view(&after, true, 0x1);
	CHECK(!checks(&before, &after, ERX_DMA_CALL_OBSERVE,
	    (erx_dma_step_t){ .kind = ERX_DMA_REPORT, .target = ERX_DMA_MEMORY, .width = 2, .offset = PUBLICATION }));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_OBSERVE,
	    (erx_dma_step_t){ .kind = ERX_DMA_REPORT, .target = ERX_DMA_MEMORY, .width = 4, .offset = USED + 2 }));
	/* A register report off its alignment or past the window. */
	CHECK(!checks(&before, &after, ERX_DMA_CALL_OBSERVE,
	    (erx_dma_step_t){ .kind = ERX_DMA_REPORT, .target = ERX_DMA_REGISTER, .width = 4, .reg = 0x72u }));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_OBSERVE,
	    (erx_dma_step_t){ .kind = ERX_DMA_REPORT, .target = ERX_DMA_REGISTER, .width = 4, .reg = 0x100u }));
	/* Addresses: inside the record's memory and the width; a region of the record is accepted. */
	view(&after, true, 0x3);
	CHECK(checks(&before, &after, ERX_DMA_CALL_POST,
	    write_value(ERX_DMA_ADDRESS, RINGS + 16, 8, DEVICE_BASE + RECORD_REGION, GRANULE)));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST,
	    write_value(ERX_DMA_ADDRESS, RINGS + 16, 8, DEVICE_BASE + RECORD_REGION, GRANULE + 1)));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, write_value(ERX_DMA_ADDRESS, RINGS + 16, 8, DEVICE_BASE - 1, 1)));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, write_value(ERX_DMA_ADDRESS, RINGS + 16, 8, DEVICE_BASE + MEMORY, 1)));
	CHECK(!checks(&before, &after, ERX_DMA_CALL_POST, write_value(ERX_DMA_ADDRESS, RINGS + 16, 8, DEVICE_BASE, 0)));
	ctx.address_bits = 30;
	{
		const erx_dma_step_t step = write_value(ERX_DMA_ADDRESS, RINGS + 16, 8, DEVICE_BASE + POOL, STRIDE);
		const erx_dma_plan_t plan = { .call = ERX_DMA_CALL_POST, .count = 1, .steps = &step };

		CHECK(!erx_device_dma_check(&ctx, &before, &after, &plan));
		ctx.address_bits = 31;
		CHECK(erx_device_dma_check(&ctx, &before, &after, &plan));
	}
}

int
main(void)
{
	every_transition();
	refusals();
	printf("erx_device_dma_order done\n");
	return (0);
}
