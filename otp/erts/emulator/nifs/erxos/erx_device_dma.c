/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The sequencer and the whole-plan check. See erx_device_dma.h.
 *
 * The ERX_DMA_SEED_* macros plant the faults test/host/erx_device_dma_test.rb shows its
 * checks catch; no build defines them otherwise.
 */

#include "erx_device_dma.h"

#ifdef ERX_DMA_SEED_NO_GRANULE_CHECK
#define SEED_NO_GRANULE_CHECK	true
#else
#define SEED_NO_GRANULE_CHECK	false
#endif
#ifdef ERX_DMA_SEED_NO_CLEAN
#define SEED_NO_CLEAN	true
#else
#define SEED_NO_CLEAN	false
#endif
#ifdef ERX_DMA_SEED_HANDOVER_BUFFERS_ONLY
#define SEED_HANDOVER_BUFFERS_ONLY	true
#else
#define SEED_HANDOVER_BUFFERS_ONLY	false
#endif
#ifdef ERX_DMA_SEED_NO_BUFFER_HANDOVER
#define SEED_NO_BUFFER_HANDOVER	true
#else
#define SEED_NO_BUFFER_HANDOVER	false
#endif
#ifdef ERX_DMA_SEED_NO_ZEROING
#define SEED_NO_ZEROING	true
#else
#define SEED_NO_ZEROING	false
#endif
#ifdef ERX_DMA_SEED_PUBLISH_BEFORE_CLEAN
#define SEED_PUBLISH_BEFORE_CLEAN	true
#else
#define SEED_PUBLISH_BEFORE_CLEAN	false
#endif
#ifdef ERX_DMA_SEED_REPORT_BARRIER_LOADS
#define SEED_REPORT_BARRIER_LOADS	true
#else
#define SEED_REPORT_BARRIER_LOADS	false
#endif
#ifdef ERX_DMA_SEED_NO_REPORT_BARRIER
#define SEED_NO_REPORT_BARRIER	true
#else
#define SEED_NO_REPORT_BARRIER	false
#endif
#ifdef ERX_DMA_SEED_NO_TAKE_BACK
#define SEED_NO_TAKE_BACK	true
#else
#define SEED_NO_TAKE_BACK	false
#endif
#ifdef ERX_DMA_SEED_STEP_BY_GRANULE
#define SEED_STEP_BY_GRANULE	true
#else
#define SEED_STEP_BY_GRANULE	false
#endif

static bool
power_of_two(uint64_t value)
{
	return (value != 0 && (value & (value - 1)) == 0);
}

static bool
width_valid(uint32_t width)
{
	return (width == 1 || width == 2 || width == 4 || width == 8);
}

/* [offset, offset + length) as an end, false when it does not fit 64 bits. */
static bool
range_end(uint64_t offset, uint64_t length, uint64_t *end)
{
	return (!__builtin_add_overflow(offset, length, end));
}

static bool
passing_to_device(const erx_dma_state_t *before, const erx_dma_state_t *after, uint32_t region)
{
	return (before->regions[region].writer == ERX_DMA_CPU && after->regions[region].writer == ERX_DMA_DEVICE);
}

static bool
coming_back(const erx_dma_state_t *before, const erx_dma_state_t *after, uint32_t region)
{
	return (before->regions[region].writer == ERX_DMA_DEVICE && after->regions[region].writer == ERX_DMA_CPU);
}

/* The region holding all of [offset, offset + length), length > 0, or state->count for none. */
static uint32_t
region_holding(const erx_dma_state_t *state, uint64_t offset, uint64_t length)
{
	uint32_t low = 0, high = state->count;
	uint64_t end;

	if (length == 0 || !range_end(offset, length, &end))
		return (state->count);
	/* The regions ascend and are disjoint: find the last one starting at or before offset. */
	while (high - low > 1) {
		const uint32_t middle = low + (high - low) / 2;

		if (state->regions[middle].offset <= offset)
			low = middle;
		else
			high = middle;
	}
	if (state->count == 0 || state->regions[low].offset > offset ||
	    end - state->regions[low].offset > state->regions[low].length)
		return (state->count);
	return (low);
}

/* The bytes a write or a publish to memory stores. */
static uint64_t
stored_length(const erx_dma_step_t *step)
{
	return (step->source == ERX_DMA_BYTES || step->source == ERX_DMA_ZEROS ? step->length : step->width);
}

/* A step's store fills buffer bytes: the out segments' bytes, or zeros the plan writes. */
static bool
fills(const erx_dma_step_t *step)
{
	return (step->kind == ERX_DMA_WRITE && (step->source == ERX_DMA_BYTES || step->source == ERX_DMA_ZEROS));
}

/* -------------------------------------------------------------------------------------------
 * The check
 */

static bool
context_whole(const erx_dma_context_t *context)
{
	uint64_t end;

	if (!power_of_two(context->granule) || context->address_bits == 0 || context->address_bits > 64 ||
	    context->memory_size == 0 || !range_end(context->device_base, context->memory_size, &end) ||
	    (context->owned_count != 0 && context->owned == NULL))
		return (false);
	if (context->publication == ERX_DMA_NO_PUBLICATION)
		return (true);
	return (width_valid(context->publication_width) && context->publication % context->publication_width == 0 &&
	    range_end(context->publication, context->publication_width, &end) && end <= context->memory_size);
}

/* Both states list the same regions, each whole granules inside the memory, ascending and disjoint. */
static bool
regions_whole(const erx_dma_context_t *context, const erx_dma_state_t *before, const erx_dma_state_t *after)
{
	uint64_t previous_end = 0;

	if (before->count != after->count || before->count > ERX_DMA_REGIONS_MAX)
		return (false);
	for (uint32_t index = 0; index < before->count; index++) {
		const erx_dma_region_t *const region = &before->regions[index];
		const erx_dma_region_t *const other = &after->regions[index];
		uint64_t end;

		if (region->offset != other->offset || region->length != other->length || region->kind != other->kind)
			return (false);
		if ((region->kind != ERX_DMA_RING && region->kind != ERX_DMA_BUFFER) ||
		    (region->writer != ERX_DMA_CPU && region->writer != ERX_DMA_DEVICE) ||
		    (other->writer != ERX_DMA_CPU && other->writer != ERX_DMA_DEVICE))
			return (false);
		if (region->length == 0 || !range_end(region->offset, region->length, &end) ||
		    end > context->memory_size || region->offset < previous_end)
			return (false);
		if (!SEED_NO_GRANULE_CHECK &&
		    (region->offset % context->granule != 0 || region->length % context->granule != 0))
			return (false);
		previous_end = end;
	}
	return (true);
}

/* Every region's writer changes only as the call allows. */
static bool
writers_follow(erx_dma_call_t call, const erx_dma_state_t *before, const erx_dma_state_t *after)
{
	for (uint32_t index = 0; index < before->count; index++) {
		const erx_dma_writer_t was = before->regions[index].writer;
		const erx_dma_writer_t is = after->regions[index].writer;
		const bool buffer = before->regions[index].kind == ERX_DMA_BUFFER;
		bool allowed;

		switch (call) {
		case ERX_DMA_CALL_OBSERVE:
			allowed = was == is;
			break;
		case ERX_DMA_CALL_POST:
			allowed = was == is || (buffer && was == ERX_DMA_CPU);
			break;
		case ERX_DMA_CALL_COMPLETE:
			allowed = was == is || (buffer && was == ERX_DMA_DEVICE);
			break;
		case ERX_DMA_CALL_INSTALL:
			allowed = was == ERX_DMA_CPU;
			break;
		case ERX_DMA_CALL_RESET:
			allowed = is == ERX_DMA_CPU;
			break;
		default:
			allowed = false;
			break;
		}
		if (!allowed)
			return (false);
	}
	return (true);
}

static bool
owned(const erx_dma_context_t *context, uint32_t reg)
{
	for (uint32_t index = 0; index < context->owned_count; index++) {
		if (context->owned[index] == reg)
			return (true);
	}
	return (false);
}

/*
 * A value fits its width; an address also lies, with its whole reach, inside the memory, the
 * form's width and its own field, so no reach wraps.
 */
static bool
value_whole(const erx_dma_context_t *context, const erx_dma_step_t *step)
{
	uint64_t offset, last;

	if (step->source != ERX_DMA_VALUE && step->source != ERX_DMA_ADDRESS)
		return (false);
	if (!width_valid(step->width) || (step->width < 8 && step->value >> (8 * step->width) != 0))
		return (false);
	if (step->source == ERX_DMA_VALUE)
		return (true);
	if (step->value < context->device_base || step->extent == 0)
		return (false);
	offset = step->value - context->device_base;
	if (offset >= context->memory_size || step->extent > context->memory_size - offset)
		return (false);
	/* The reach's last byte is device_base + memory_size - 1 at most, which context_whole showed fits. */
	last = step->value + step->extent - 1;
	if (step->width < 8 && last >> (8 * step->width) != 0)
		return (false);
	return (context->address_bits == 64 || last >> context->address_bits == 0);
}

/* A 32-bit register inside the peripheral's window. */
static bool
register_whole(const erx_dma_context_t *context, uint32_t reg)
{
	return (reg % 4 == 0 && context->window_size >= 4 && reg <= context->window_size - 4);
}

static bool
write_allowed(const erx_dma_context_t *context, const erx_dma_state_t *before, const erx_dma_state_t *after,
    const erx_dma_step_t *step)
{
	const uint64_t length = stored_length(step);
	uint32_t region;

	if (step->target != ERX_DMA_MEMORY)
		return (false);
	switch (step->source) {
	case ERX_DMA_BYTES:
		if (step->bytes == NULL)
			return (false);
		break;
	case ERX_DMA_ZEROS:
		break;
	case ERX_DMA_VALUE:
	case ERX_DMA_ADDRESS:
		if (!value_whole(context, step) || step->offset % step->width != 0)
			return (false);
		break;
	default:
		return (false);
	}
	region = region_holding(before, step->offset, length);
	if (region == before->count)
		return (false);
	if (before->regions[region].kind == ERX_DMA_RING)
		return (before->regions[region].writer == ERX_DMA_CPU);
	/* Into a buffer, only the bytes it is handed over with, never a ring field's value. */
	return (fills(step) && passing_to_device(before, after, region));
}

static bool
publish_allowed(const erx_dma_context_t *context, const erx_dma_state_t *before, const erx_dma_step_t *step)
{
	uint32_t region;

	if (!value_whole(context, step))
		return (false);
	if (step->target == ERX_DMA_REGISTER && step->reg_high == ERX_DMA_NO_REGISTER)
		return (step->width == 4 && register_whole(context, step->reg) && owned(context, step->reg));
	if (step->target == ERX_DMA_REGISTER)
		return (step->source == ERX_DMA_ADDRESS && step->width == 8 && step->reg_high != step->reg &&
		    register_whole(context, step->reg) && register_whole(context, step->reg_high) &&
		    owned(context, step->reg) && owned(context, step->reg_high));
	if (step->target != ERX_DMA_MEMORY || context->publication == ERX_DMA_NO_PUBLICATION ||
	    step->offset != context->publication || step->width != context->publication_width)
		return (false);
	region = region_holding(before, step->offset, step->width);
	return (region != before->count && before->regions[region].kind == ERX_DMA_RING &&
	    before->regions[region].writer == ERX_DMA_CPU);
}

static bool
copy_allowed(const erx_dma_state_t *before, const erx_dma_state_t *after, const erx_dma_step_t *step)
{
	const uint32_t region = region_holding(before, step->offset, step->length);

	return (step->target == ERX_DMA_MEMORY && region != before->count &&
	    before->regions[region].kind == ERX_DMA_BUFFER && coming_back(before, after, region));
}

static bool
report_allowed(const erx_dma_context_t *context, const erx_dma_state_t *before, const erx_dma_step_t *step)
{
	uint32_t region;

	if (!width_valid(step->width))
		return (false);
	if (step->target == ERX_DMA_REGISTER)
		return (step->width == 4 && register_whole(context, step->reg));
	if (step->target != ERX_DMA_MEMORY || step->offset % step->width != 0)
		return (false);
	region = region_holding(before, step->offset, step->width);
	return (region != before->count && before->regions[region].kind == ERX_DMA_RING &&
	    before->regions[region].writer == ERX_DMA_DEVICE);
}

/* Which kind of step each call makes: hand-overs write and publish, take-backs copy, observations report. */
static bool
step_fits_call(erx_dma_call_t call, erx_dma_step_kind_t kind)
{
	switch (call) {
	case ERX_DMA_CALL_OBSERVE:
		return (kind == ERX_DMA_REPORT);
	case ERX_DMA_CALL_POST:
	case ERX_DMA_CALL_INSTALL:
		return (kind == ERX_DMA_WRITE || kind == ERX_DMA_PUBLISH);
	case ERX_DMA_CALL_COMPLETE:
		return (kind == ERX_DMA_COPY);
	default:
		return (false);
	}
}

bool
erx_device_dma_check(const erx_dma_context_t *context, const erx_dma_state_t *before, const erx_dma_state_t *after,
    const erx_dma_plan_t *plan)
{
	if (plan->call > ERX_DMA_CALL_RESET || !context_whole(context) || !regions_whole(context, before, after) ||
	    !writers_follow(plan->call, before, after) || (plan->count != 0 && plan->steps == NULL))
		return (false);
	for (uint32_t index = 0; index < plan->count; index++) {
		const erx_dma_step_t *const step = &plan->steps[index];
		bool allowed;

		if (!step_fits_call(plan->call, step->kind))
			return (false);
		switch (step->kind) {
		case ERX_DMA_WRITE:
			allowed = write_allowed(context, before, after, step);
			break;
		case ERX_DMA_PUBLISH:
			allowed = publish_allowed(context, before, step);
			break;
		case ERX_DMA_COPY:
			allowed = copy_allowed(before, after, step);
			break;
		case ERX_DMA_REPORT:
			allowed = report_allowed(context, before, step);
			break;
		default:
			allowed = false;
			break;
		}
		if (!allowed)
			return (false);
	}
	return (true);
}

/* -------------------------------------------------------------------------------------------
 * The sequencer
 */

/* The effects being written, and whether every one fitted. */
typedef struct order {
	erx_dma_effects_t	*out;
	bool			fitted;
	bool			coherent;
	uint32_t		line;	/* the step of every maintenance instruction */
} order_t;

static void
emit(order_t *order, erx_dma_effect_t effect)
{
	if (order->out->count == order->out->capacity) {
		order->fitted = false;
		return;
	}
	order->out->effects[order->out->count++] = effect;
}

static void
emit_step(order_t *order, uint32_t step)
{
	emit(order, (erx_dma_effect_t){ .kind = ERX_DMA_EFFECT_STEP, .step = step });
}

/* Maintenance over a range already on lines; none for a coherent device. */
static void
emit_maintenance(order_t *order, erx_dma_effect_kind_t kind, uint64_t offset, uint64_t length)
{
	if (order->coherent)
		return;
	emit(order, (erx_dma_effect_t){ .kind = kind, .offset = offset, .length = length, .line = order->line });
}

/* The lines covering [offset, offset + width): their first byte and the end of the last. */
static void
lines_of(const order_t *order, uint64_t offset, uint32_t width, uint64_t *start, uint64_t *end)
{
	const uint64_t mask = ~(uint64_t)(order->line - 1);

	*start = offset & mask;
	*end = (offset + width + order->line - 1) & mask;
}

static void
emit_barrier(order_t *order, erx_dma_barrier_t barrier, uint32_t orders, bool completes)
{
	emit(order, (erx_dma_effect_t){ .kind = ERX_DMA_EFFECT_BARRIER, .barrier = barrier, .orders = orders,
	    .completes = completes });
}

/* The end of the fills that cover byte `at`, or `at` when none does. */
static uint64_t
past_fills(const erx_dma_plan_t *plan, uint64_t at)
{
	bool moved = true;

	/* Fills may overlap or abut, so repeat until no fill covers the cursor. */
	while (moved) {
		moved = false;
		for (uint32_t index = 0; index < plan->count; index++) {
			const erx_dma_step_t *const step = &plan->steps[index];

			if (fills(step) && step->offset <= at && step->offset + step->length > at) {
				at = step->offset + step->length;
				moved = true;
			}
		}
	}
	return (at);
}

/* The first byte after `at` and before `end` that a fill starts at, or `end`. */
static uint64_t
next_fill(const erx_dma_plan_t *plan, uint64_t at, uint64_t end)
{
	uint64_t next = end;

	for (uint32_t index = 0; index < plan->count; index++) {
		const erx_dma_step_t *const step = &plan->steps[index];

		if (fills(step) && step->offset > at && step->offset < next)
			next = step->offset;
	}
	return (next);
}

/*
 * Rule 1 for one buffer passing to the device: zeros over every byte of it that no write of the
 * plan fills, one zeroing per gap between fills. A fill lies inside one region, so a fill that
 * covers a byte of the buffer is inside the buffer.
 */
static void
emit_zeroing(order_t *order, const erx_dma_plan_t *plan, const erx_dma_region_t *buffer)
{
	const uint64_t end = buffer->offset + buffer->length;
	uint64_t cursor = past_fills(plan, buffer->offset);

	while (cursor < end) {
		const uint64_t gap_end = next_fill(plan, cursor, end);

		emit(order, (erx_dma_effect_t){ .kind = ERX_DMA_EFFECT_ZERO, .offset = cursor, .length = gap_end - cursor });
		cursor = past_fills(plan, gap_end);
	}
}

/* Which regions the plan's writes touch, so a ring region the CPU keeps writing is handed over for reading. */
static void
mark_written(const erx_dma_state_t *before, const erx_dma_plan_t *plan, bool written[ERX_DMA_REGIONS_MAX])
{
	for (uint32_t index = 0; index < before->count; index++)
		written[index] = false;
	for (uint32_t index = 0; index < plan->count; index++) {
		const erx_dma_step_t *const step = &plan->steps[index];
		uint32_t region;

		if (step->kind != ERX_DMA_WRITE)
			continue;
		region = region_holding(before, step->offset, stored_length(step));
		if (region != before->count)
			written[region] = true;
	}
}

/*
 * Rule 2: every region passing to the device, and every region the CPU wrote and keeps,
 * cleaned whole.
 */
static void
emit_handover_cleans(order_t *order, const erx_dma_state_t *before, const erx_dma_state_t *after,
    const bool written[ERX_DMA_REGIONS_MAX])
{
	for (uint32_t index = 0; index < before->count; index++) {
		const erx_dma_region_t *const region = &before->regions[index];
		bool passing = passing_to_device(before, after, index);
		const bool read_by_device = written[index] && after->regions[index].writer == ERX_DMA_CPU;

		if (SEED_HANDOVER_BUFFERS_ONLY)
			passing = passing && region->kind == ERX_DMA_BUFFER;
		if (SEED_NO_BUFFER_HANDOVER)
			passing = passing && region->kind != ERX_DMA_BUFFER;
		if ((passing || read_by_device) && !SEED_NO_CLEAN)
			emit_maintenance(order, ERX_DMA_EFFECT_CLEAN, region->offset, region->length);
	}
}

/*
 * A decision that hands over: the zeroing, the writes, the cleans, then each publish after a
 * publish barrier, a ring field's followed by the clean of its lines.
 */
static void
order_hand_over(order_t *order, const erx_dma_state_t *before, const erx_dma_state_t *after,
    const erx_dma_plan_t *plan)
{
	bool written[ERX_DMA_REGIONS_MAX];

	for (uint32_t index = 0; index < before->count; index++) {
		if (passing_to_device(before, after, index) && before->regions[index].kind == ERX_DMA_BUFFER &&
		    !SEED_NO_ZEROING)
			emit_zeroing(order, plan, &before->regions[index]);
	}
	for (uint32_t index = 0; index < plan->count; index++) {
		if (plan->steps[index].kind == ERX_DMA_WRITE)
			emit_step(order, index);
	}
	mark_written(before, plan, written);
	if (!SEED_PUBLISH_BEFORE_CLEAN)
		emit_handover_cleans(order, before, after, written);
	for (uint32_t index = 0; index < plan->count; index++) {
		const erx_dma_step_t *const step = &plan->steps[index];

		if (step->kind != ERX_DMA_PUBLISH)
			continue;
		emit_barrier(order, ERX_DMA_BARRIER_PUBLISH, ERX_DMA_ORDERS_LOADS | ERX_DMA_ORDERS_STORES, !order->coherent);
		emit_step(order, index);
		if (step->target == ERX_DMA_MEMORY) {
			uint64_t start, end;

			lines_of(order, step->offset, step->width, &start, &end);
			emit_maintenance(order, ERX_DMA_EFFECT_CLEAN, start, end - start);
		}
	}
	if (SEED_PUBLISH_BEFORE_CLEAN)
		emit_handover_cleans(order, before, after, written);
}

/*
 * An observation: the clean and invalidate of every line of ring memory it reads, the
 * completion barrier, the reads, then the report barrier. Consecutive reads in one line share
 * its maintenance.
 */
static void
order_observe(order_t *order, const erx_dma_plan_t *plan)
{
	const uint32_t first = order->out->count;
	bool maintained = false;

	for (uint32_t index = 0; index < plan->count && !order->coherent; index++) {
		const erx_dma_step_t *const step = &plan->steps[index];
		erx_dma_effect_t *const last = order->out->count > first ? &order->out->effects[order->out->count - 1] : NULL;
		uint64_t start, end;

		if (step->target != ERX_DMA_MEMORY)
			continue;
		lines_of(order, step->offset, step->width, &start, &end);
		maintained = true;
		if (last != NULL && start >= last->offset && start <= last->offset + last->length) {
			if (end > last->offset + last->length)
				last->length = end - last->offset;
			continue;
		}
		emit_maintenance(order, ERX_DMA_EFFECT_CLEAN_INVAL, start, end - start);
	}
	if (maintained)
		emit_barrier(order, ERX_DMA_BARRIER_COMPLETION, ERX_DMA_ORDERS_LOADS | ERX_DMA_ORDERS_STORES, true);
	for (uint32_t index = 0; index < plan->count; index++)
		emit_step(order, index);
	if (plan->count != 0 && !SEED_NO_REPORT_BARRIER)
		emit_barrier(order, ERX_DMA_BARRIER_REPORT,
		    SEED_REPORT_BARRIER_LOADS ? ERX_DMA_ORDERS_LOADS : ERX_DMA_ORDERS_LOADS | ERX_DMA_ORDERS_STORES, false);
}

/* A decision that takes back: the clean and invalidate of every region coming back, the completion barrier, the copies. */
static void
order_take_back(order_t *order, const erx_dma_state_t *before, const erx_dma_state_t *after,
    const erx_dma_plan_t *plan)
{
	bool maintained = false;

	for (uint32_t index = 0; index < before->count && !order->coherent; index++) {
		if (!coming_back(before, after, index) || SEED_NO_TAKE_BACK)
			continue;
		emit_maintenance(order, ERX_DMA_EFFECT_CLEAN_INVAL, before->regions[index].offset,
		    before->regions[index].length);
		maintained = true;
	}
	if (maintained)
		emit_barrier(order, ERX_DMA_BARRIER_COMPLETION, ERX_DMA_ORDERS_LOADS | ERX_DMA_ORDERS_STORES, true);
	for (uint32_t index = 0; index < plan->count; index++)
		emit_step(order, index);
}

bool
erx_device_dma_order(const erx_dma_state_t *before, const erx_dma_state_t *after, const erx_dma_plan_t *plan,
    bool coherent, uint32_t granule, uint32_t line, erx_dma_effects_t *effects)
{
	order_t order = { .out = effects, .fitted = true, .coherent = coherent, .line = line };

	effects->count = 0;
	if (before->count != after->count || before->count > ERX_DMA_REGIONS_MAX || !power_of_two(granule) ||
	    !power_of_two(line) || line > granule || (plan->count != 0 && plan->steps == NULL))
		return (false);
	if (SEED_STEP_BY_GRANULE)
		order.line = granule;
	switch (plan->call) {
	case ERX_DMA_CALL_OBSERVE:
		order_observe(&order, plan);
		break;
	case ERX_DMA_CALL_POST:
	case ERX_DMA_CALL_INSTALL:
		order_hand_over(&order, before, after, plan);
		break;
	case ERX_DMA_CALL_COMPLETE:
	case ERX_DMA_CALL_RESET:
		order_take_back(&order, before, after, plan);
		break;
	default:
		return (false);
	}
	return (order.fitted);
}
