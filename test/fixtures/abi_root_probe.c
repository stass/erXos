/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root task's well-known slots against the design's own tables: the
 * slot numbers of docs/design-abi.md ("Numeric assignment and versions"),
 * and the rights each root capability carries, from the type and memory
 * tables of docs/design-kernel.md ("Rights"), written out here by hand so
 * the generator does not supply its own answers.
 */

#include <stdio.h>

#include "erx/abi.h"

#define CHECK(condition)						\
	do {								\
		if (!(condition)) {					\
			printf("failed at line %d: %s\n", __LINE__,	\
			    #condition);				\
			return (1);					\
		}							\
	} while (0)

typedef struct root_slot {
	uint32_t	slot;
	uint32_t	type;
	uint32_t	rights;
	uint32_t	optional;
} root_slot_t;

static const root_slot_t root_slots[] = {
	/* the root budget: a budget's rights but DESTROY */
	{ 1, ERX_K_BUDGET, ERX_HR_ALLOC | ERX_HR_SPACES | ERX_HR_CODE |
	    ERX_HR_CARVE | ERX_HR_INSPECT | ERX_HR_DUP | ERX_HR_GIVE, 0 },
	/* the root group and system, created as any group */
	{ 2, ERX_K_GROUP, ERX_HR_CONFIGURE | ERX_HR_ATTACH | ERX_HR_SIGNAL |
	    ERX_HR_INSPECT | ERX_HR_DUP | ERX_HR_GIVE | ERX_HR_DESTROY, 0 },
	{ 3, ERX_K_GROUP, ERX_HR_CONFIGURE | ERX_HR_ATTACH | ERX_HR_SIGNAL |
	    ERX_HR_INSPECT | ERX_HR_DUP | ERX_HR_GIVE | ERX_HR_DESTROY, 0 },
	/* the root resource: a carved resource's rights, POWER, TRACE, ENTROPY */
	{ 4, ERX_K_RESOURCE, ERX_HR_CARVE | ERX_HR_POWER | ERX_HR_TRACE |
	    ERX_HR_ENTROPY | ERX_HR_INSPECT | ERX_HR_DUP | ERX_HR_GIVE, 0 },
	/* the boot image: never WRITE, never DESTROY */
	{ 5, ERX_K_MEMORY, ERX_HR_READ | ERX_HR_EXEC | ERX_HR_MAP |
	    ERX_HR_CHILD | ERX_HR_CARVE | ERX_HR_SYSTEM | ERX_HR_INSPECT |
	    ERX_HR_DUP | ERX_HR_GIVE, 0 },
	{ 6, ERX_K_MEMORY, ERX_HR_READ | ERX_HR_WRITE | ERX_HR_MAP |
	    ERX_HR_INSPECT | ERX_HR_DUP | ERX_HR_GIVE, 0 },
	/* its own space and thread, created as any space and thread */
	{ 7, ERX_K_SPACE, ERX_HR_MAP | ERX_HR_THREADS | ERX_HR_CAPS |
	    ERX_HR_STOP | ERX_HR_INSPECT | ERX_HR_DUP | ERX_HR_GIVE |
	    ERX_HR_DESTROY, 0 },
	{ 8, ERX_K_THREAD, ERX_HR_CONTROL | ERX_HR_CONFIGURE | ERX_HR_INSPECT |
	    ERX_HR_DUP | ERX_HR_GIVE | ERX_HR_DESTROY, 0 },
	/* the device-secret page: no DUP or GIVE, so it never leaves */
	{ 9, ERX_K_MEMORY, ERX_HR_READ | ERX_HR_MAP | ERX_HR_INSPECT, 0 },
	{ 10, ERX_K_MEMORY, ERX_HR_READ | ERX_HR_MAP | ERX_HR_INSPECT |
	    ERX_HR_DUP | ERX_HR_GIVE, 0 },
	/* the previous crash record, null when the boot found none */
	{ 11, ERX_K_MEMORY, ERX_HR_READ | ERX_HR_MAP | ERX_HR_INSPECT |
	    ERX_HR_DUP | ERX_HR_GIVE | ERX_HR_DESTROY, 1 },
};

int
main(void)
{
	CHECK(ERX_ROOT_SLOT_ROOT_BUDGET == 1 && ERX_ROOT_SLOT_ROOT_GROUP == 2 &&
	    ERX_ROOT_SLOT_SYSTEM_GROUP == 3 && ERX_ROOT_SLOT_ROOT_RESOURCE == 4 &&
	    ERX_ROOT_SLOT_BOOT_IMAGE == 5 && ERX_ROOT_SLOT_TIME_PAGE == 6 &&
	    ERX_ROOT_SLOT_SELF_SPACE == 7 && ERX_ROOT_SLOT_SELF_THREAD == 8 &&
	    ERX_ROOT_SLOT_DEVICE_SECRET == 9 && ERX_ROOT_SLOT_MACHINE_PAGE == 10 &&
	    ERX_ROOT_SLOT_PREVIOUS_CRASH == 11);
	for (size_t index = 0; index < sizeof(root_slots) / sizeof(root_slots[0]);
	    index++) {
		const root_slot_t *root = &root_slots[index];
		uint32_t kind = erx_root_slot_kind(root->slot);

		CHECK(kind != 0);
		CHECK(erx_kind_ktype(kind) == root->type);
		CHECK(erx_kind_default_mask(kind) == root->rights);
		CHECK(erx_root_slot_optional(root->slot) == root->optional);
	}
	/* Slot 0 is never issued, and no slot past the last is a root slot. */
	CHECK(ERX_CAP_NULL == 0);
	CHECK(erx_root_slot_kind(0) == 0 && erx_root_slot_kind(12) == 0);
	CHECK(erx_root_slot_kind(UINT32_MAX) == 0);
	puts("root capability checks passed");
	return (0);
}
