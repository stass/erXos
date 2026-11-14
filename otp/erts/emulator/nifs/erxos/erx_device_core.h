/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device's pure decisions (docs/design-runtime.md, "The device NIF"): which
 * peripheral and register a name means, which pages hold a window, what a register allows,
 * and how a field goes into a word. It reads no hardware and no global state, needs nothing of ERTS and builds for the
 * host. Every table entry comes from tools/gen_hw.rb.
 */

#ifndef ERX_DEVICE_CORE_H
#define ERX_DEVICE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/hw/device_types.h"

/*
 * The pages that hold a window. A window may be smaller than a page and start anywhere in
 * one, as each 0x200-byte virtio-mmio slot does, but the kernel maps device memory in whole
 * pages only, so the mapping is the window's first page through its last, and the register
 * table's offsets apply from `offset`, the window's base inside the first page.
 */
typedef struct erx_device_pages {
	uint64_t	base;	/* the first page: physical, or an offset in the window object */
	uint64_t	size;	/* the bytes of the pages, a multiple of ERX_PAGE_SIZE */
	uint64_t	offset;	/* the window's base less `base`, below ERX_PAGE_SIZE */
} erx_device_pages_t;

/*
 * False for an empty window and for one that wraps or reaches the address space's last
 * page, whose end a page-sized size cannot state.
 */
static inline bool
erx_device_window_pages(uint64_t base, uint64_t size, erx_device_pages_t *pages)
{
	const uint64_t mask = ERX_PAGE_SIZE - 1;
	uint64_t last;

	if (size == 0 || __builtin_add_overflow(base, size - 1, &last) || (last | mask) == UINT64_MAX)
		return (false);
	pages->base = base & ~mask;
	pages->size = (last | mask) + 1 - pages->base;
	pages->offset = base & mask;
	return (true);
}

/*
 * Whether a window base suits every register of the peripheral: device memory faults on an
 * access not aligned to its width, so a base that would misalign one is refused at open.
 */
static inline bool
erx_device_base_aligned(const erx_device_peripheral_t *peripheral, uint64_t base)
{
	for (uint32_t index = 0; index < peripheral->register_count; index++) {
		const uint64_t bytes = peripheral->registers[index].width / 8u;

		if (bytes > 1 && (base & (bytes - 1)) != 0)
			return (false);
	}
	return (true);
}

/* Whether two windows' mappings would share a page. */
static inline bool
erx_device_pages_overlap(const erx_device_pages_t *a, const erx_device_pages_t *b)
{
	return (a->base < b->base + b->size && b->base < a->base + a->size);
}

/*
 * Where a queue lies in its device's one memory object: its rings at the first page no
 * earlier queue took, its pool at the page after them, and `end`, the bytes taken with it.
 * Each starts on a page, so no queue shares a page with another's rings or pool.
 */
typedef struct erx_device_carve {
	uint64_t	rings;
	uint64_t	pool;
	uint64_t	end;
} erx_device_carve_t;

/* Bytes rounded up to whole pages; false when the rounding wraps. */
static inline bool
erx_device_page_round(uint64_t bytes, uint64_t *rounded)
{
	const uint64_t mask = ERX_PAGE_SIZE - 1;

	if (__builtin_add_overflow(bytes, mask, rounded))
		return (false);
	*rounded &= ~mask;
	return (true);
}

/*
 * The next queue's place after the `taken` bytes of a memory of `size`, for rings of
 * `ring_bytes` and a pool of `pool_bytes`. False, deciding nothing, when the queue would end
 * past `size` or a sum wraps. `taken` is always whole pages, as every `end` is.
 */
static inline bool
erx_device_carve(uint64_t taken, uint64_t size, uint64_t ring_bytes, uint64_t pool_bytes, erx_device_carve_t *carve)
{
	uint64_t rings_rounded, pool_rounded, pool, end;

	if (!erx_device_page_round(ring_bytes, &rings_rounded) || !erx_device_page_round(pool_bytes, &pool_rounded) ||
	    __builtin_add_overflow(taken, rings_rounded, &pool) || __builtin_add_overflow(pool, pool_rounded, &end) ||
	    end > size)
		return (false);
	*carve = (erx_device_carve_t){ .rings = taken, .pool = pool, .end = end };
	return (true);
}

/*
 * A region's place after the `taken` bytes of a memory of `size`, by the rule queues use: its
 * `bytes`, nonzero, rounded up to whole pages at the first page nothing earlier took, so
 * queues and regions share one allocator and no two share a page. False, deciding nothing,
 * when the region would end past `size`, a sum wraps, or its length passes `length_max`, the
 * largest the record's region entry can state.
 */
typedef struct erx_device_region_carve {
	uint64_t	start;
	uint64_t	length;	/* whole pages */
	uint64_t	end;
} erx_device_region_carve_t;

static inline bool
erx_device_carve_region(uint64_t taken, uint64_t size, uint64_t bytes, uint64_t length_max,
    erx_device_region_carve_t *carve)
{
	uint64_t length, end;

	if (bytes == 0 || !erx_device_page_round(bytes, &length) || length > length_max ||
	    __builtin_add_overflow(taken, length, &end) || end > size)
		return (false);
	*carve = (erx_device_region_carve_t){ .start = taken, .length = length, .end = end };
	return (true);
}

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
/* Whether the peripheral is the named one or a kind whose registers begin with that one's. */
bool	erx_device_peripheral_is(const erx_device_peripheral_t *peripheral, const char *name);
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

/*
 * Whether `word` may be issued to an SD host controller's command register, `cmdtm`, whose
 * transfer-mode field `dma` is the DMA enable: a word of the register's width that sets
 * only bits its fields hold and leaves DMA off. The register is owned, so its own
 * writable mask, which write/3 would apply, is the bound here as well.
 */
static inline bool
erx_device_command_allowed(const erx_device_register_t *cmdtm, const erx_device_field_t *dma, uint64_t word)
{
	return (cmdtm->access != ERX_DEVICE_READ_ONLY && (word & ~cmdtm->writable) == 0 && (word & dma->mask) == 0);
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
