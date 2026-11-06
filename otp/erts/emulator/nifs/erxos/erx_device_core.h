/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device's pure decisions (docs/design-runtime.md, "The device NIF"): which
 * peripheral and register a name means, what a register allows, and how a field goes into a
 * word. It reads no hardware and no global state, needs nothing of ERTS and builds for the
 * host. Every table entry comes from tools/gen_hw.rb.
 */

#ifndef ERX_DEVICE_CORE_H
#define ERX_DEVICE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/hw/device_types.h"

/* What writing a field takes, decided before any access. */
typedef enum erx_device_field_op {
	ERX_DEVICE_FIELD_REFUSED,	/* the register or the value does not allow it */
	ERX_DEVICE_FIELD_WRITE,		/* one write of `bits`: a one-to-clear field */
	ERX_DEVICE_FIELD_UPDATE		/* one read, then one write of (word & keep) | bits */
} erx_device_field_op_t;

typedef struct erx_device_field_plan {
	erx_device_field_op_t	op;
	uint64_t		keep;
	uint64_t		bits;
} erx_device_field_plan_t;

/* The peripheral with this name in the generated table, or NULL. */
const erx_device_peripheral_t *erx_device_peripheral_find(const char *name, size_t length);
/* The register's or the field's index by its text, or `count` for none: for callers with no atoms. */
uint32_t	erx_device_register_named(const erx_device_peripheral_t *peripheral, const char *name);
uint32_t	erx_device_field_named(const erx_device_peripheral_t *peripheral, const erx_device_register_t *reg,
		    const char *name);

/* The first index in `keys` holding `key`, or `count`. Keys are what the caller interned the names as. */
static inline uint32_t
erx_device_key_find(const uintptr_t *keys, uint32_t count, uintptr_t key)
{
	uint32_t index = 0;

	while (index < count && keys[index] != key)
		index++;
	return (index);
}

/*
 * The byte offset of the register, or of one element of an array. An array takes an index
 * below its count and nothing else does, so a name in the wrong form is refused.
 */
static inline bool
erx_device_element_offset(const erx_device_register_t *reg, bool indexed, uint64_t index, uint64_t *offset)
{
	if (indexed != (reg->count > 1) || (indexed && index >= reg->count))
		return (false);
	*offset = (uint64_t)reg->offset + (indexed ? index * reg->stride : 0);
	return (true);
}

static inline bool
erx_device_read_allowed(const erx_device_register_t *reg)
{
	return (reg->access != ERX_DEVICE_WRITE_ONLY);
}

/* A word may set writable bits only, and never of a register the NIF owns, which erx_device.c's own sequences write. */
static inline bool
erx_device_write_allowed(const erx_device_register_t *reg, uint64_t value)
{
	return (reg->access != ERX_DEVICE_READ_ONLY && !reg->owned_by_nif && (value & ~reg->writable) == 0);
}

static inline bool
erx_device_field_read_allowed(const erx_device_register_t *reg, const erx_device_field_t *field)
{
	return (erx_device_read_allowed(reg) && field->access != ERX_DEVICE_WRITE_ONLY);
}

/* Whether a word read from outside has no bit above the register's width. */
static inline bool
erx_device_word_fits(const erx_device_register_t *reg, uint64_t word)
{
	return (reg->width >= 64 || (word >> reg->width) == 0);
}

static inline uint64_t
erx_device_field_get(const erx_device_field_t *field, uint64_t word)
{
	return ((word & field->mask) >> field->shift);
}

/*
 * A one-to-clear field is one write, since its siblings ignore zeros. An ordinary field
 * replaces its bits in a word read back, which the generator allows only for a register
 * whose read has no side effect and whose writable fields all mean replacement; any other
 * field is written with the whole register or not at all.
 */
static inline erx_device_field_plan_t
erx_device_field_plan(const erx_device_register_t *reg, const erx_device_field_t *field, uint64_t value)
{
	const erx_device_field_plan_t refused = { .op = ERX_DEVICE_FIELD_REFUSED };
	erx_device_field_plan_t plan = { .op = ERX_DEVICE_FIELD_WRITE };

	if (reg->owned_by_nif || field->access == ERX_DEVICE_READ_ONLY || value > (field->mask >> field->shift))
		return (refused);
	plan.bits = value << field->shift;
	if (field->clear)
		return (plan);
	if (!reg->plain_update)
		return (refused);
	plan.op = ERX_DEVICE_FIELD_UPDATE;
	plan.keep = reg->writable & ~field->mask;
	return (plan);
}

static inline uint64_t
erx_device_field_apply(const erx_device_field_plan_t *plan, uint64_t word)
{
	return ((word & plan->keep) | plan->bits);
}

#endif /* ERX_DEVICE_CORE_H */
