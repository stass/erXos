/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root task's well-known slots against the design's own tables: the
 * slot numbers of docs/design-abi.md ("Numeric assignment and versions"),
 * and the rights each root capability carries, from the type and memory
 * tables of docs/design-kernel.md ("Rights"), and the machine page's and
 * the crash record's offsets from its "The root task", all written out here
 * by hand so the generator does not supply its own answers.
 */

#include <stdio.h>
#include <string.h>

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

/*
 * The three boot records and the reserved values, against the numbers the
 * design documents state, written out here by hand: docs/design-kernel.md
 * ("The root task"), docs/design-platforms.md ("Device secrets") and
 * docs/design-runtime.md ("Data model").
 */
static int
check_records(void)
{
	static const unsigned char device_label[] = "erXos device secret";
	static const unsigned char sealing_label[] = "erXos sealing secret";
	static const unsigned char device_bytes[] = ERX_DEVICE_SECRET_LABEL_BYTES;
	static const unsigned char sealing_bytes[] = ERX_SEALING_SECRET_LABEL_BYTES;

	/* The reserved values: slot bits above any table, generation 0. */
	CHECK(ERX_CAP_SELF == UINT64_C(0xffffff));
	CHECK(ERX_CAP_SELF_THREAD == UINT64_C(0xfffffe));
	CHECK(ERX_CAPS_MAX == 1048576 && ERX_CAP_SLOT_BITS == 24);
	CHECK(erx_kind_ktype(ERX_KIND_RESERVED_SPACE) == ERX_K_SPACE);
	CHECK(erx_kind_default_mask(ERX_KIND_RESERVED_SPACE) ==
	    (ERX_HR_MAP | ERX_HR_THREADS | ERX_HR_CAPS | ERX_HR_STOP));
	CHECK(erx_kind_ktype(ERX_KIND_RESERVED_THREAD) == ERX_K_THREAD);
	CHECK(erx_kind_default_mask(ERX_KIND_RESERVED_THREAD) == ERX_HR_CONFIGURE);

	/* The machine page. */
	CHECK(ERX_MACHINE_PAGE_SIZE == 4096 && ERX_MACHINE_PAGE_ALIGN == 4096);
	CHECK(ERX_MACHINE_PAGE_OFF_LEASE_DEADLINE_NS == 0);
	CHECK(ERX_MACHINE_PAGE_OFF_BOOT_VALUE == 8);
	CHECK(ERX_MACHINE_PAGE_OFF_BOOT_SLOT == 12);
	CHECK(ERX_MACHINE_PAGE_OFF_FLAGS == 16);
	CHECK(ERX_MACHINE_PAGE_OFF_ENTROPY_QUALITY == 20);
	CHECK(ERX_MACHINE_PAGE_OFF_MEMORY_BYTES == 24);
	CHECK(ERX_MACHINE_PAGE_OFF_CPU_COUNT == 32);
	CHECK(ERX_MACHINE_PAGE_OFF_WATCHDOG_PERIOD_S == 36);
	CHECK(ERX_MACHINE_PAGE_OFF_WATCHDOG_DEADLINE_S == 40);
	CHECK(ERX_MACHINE_PAGE_OFF_WATCHDOG_BOOT_S == 44);
	CHECK(ERX_MACHINE_PAGE_OFF_BUILD_ID == 48);
	CHECK(ERX_BOOT_VALUE_UNKNOWN == 1 && ERX_BOOT_VALUE_NORMAL == 2 &&
	    ERX_BOOT_VALUE_TRIAL == 3);
	CHECK(ERX_BOOT_SLOT_NONE == 0 && ERX_BOOT_SLOT_A == 1 && ERX_BOOT_SLOT_B == 2);
	CHECK(ERX_ENTROPY_QUALITY_GOOD == 1 && ERX_ENTROPY_QUALITY_WEAK == 2 &&
	    ERX_ENTROPY_QUALITY_FIXED == 3);
	CHECK(ERX_MACHINE_DET == 1 && ERX_MACHINE_CRASH_FOUND == 2);

	/* The crash record: the brief form, then the full form's fixed prefix. */
	CHECK(ERX_CRASH_BRIEF_SIZE == 120 && ERX_CRASH_BRIEF_ALIGN == 8);
	CHECK(ERX_CRASH_BRIEF_OFF_BUILD_ID == 48);
	CHECK(ERX_CRASH_BRIEF_OFF_BOOT_VALUE == 56);
	CHECK(ERX_CRASH_BRIEF_OFF_BOOT_SLOT == 60);
	CHECK(ERX_CRASH_BRIEF_OFF_NFRAMES == 64);
	CHECK(ERX_CRASH_BRIEF_OFF_FAULT == 72);
	CHECK(ERX_CRASH_RECORD_SIZE == 904 && ERX_CRASH_RECORD_ALIGN == 8);
	CHECK(ERX_CRASH_RECORD_OFF_HEADER == 0);
	CHECK(ERX_CRASH_RECORD_OFF_REGS == 120);
	CHECK(ERX_CRASH_RECORD_OFF_FRAMES == 392);
	CHECK(ERX_CRASH_SIZE == 16384 && ERX_CRASH_VERSION == 2);

	/* The device-secret page, and the labels spelled out as text. */
	CHECK(ERX_DEVICE_SECRET_PAGE_SIZE == 40);
	CHECK(ERX_DEVICE_SECRET_PAGE_OFF_STATUS == 0);
	CHECK(ERX_DEVICE_SECRET_PAGE_OFF_SECRET == 8);
	CHECK(sizeof(((erx_device_secret_page_t *)0)->secret) == 32);
	CHECK(ERX_DEVICE_SECRET_PAGE_ALIGN == 8);
	CHECK(ERX_DEVICE_SECRET_STATUS_PRESENT == 1 &&
	    ERX_DEVICE_SECRET_STATUS_NO_KEY == 2 &&
	    ERX_DEVICE_SECRET_STATUS_NEVER_PROVISIONED == 3 &&
	    ERX_DEVICE_SECRET_STATUS_READ_FAILED == 4);
	CHECK(ERX_DEVICE_SECRET_LABEL_SIZE == 19 && sizeof(device_bytes) == 19);
	CHECK(memcmp(device_bytes, device_label, 19) == 0);
	CHECK(ERX_SEALING_SECRET_LABEL_SIZE == 20 && sizeof(sealing_bytes) == 20);
	CHECK(memcmp(sealing_bytes, sealing_label, 20) == 0);

	/* The root extension: one value per slot, slot 1 first, past the page. */
	CHECK(ERX_BOOT_INFO_SIZE == 280);
	CHECK(ERX_BOOT_INFO_OFF_SPACES_GROUP == 64 && ERX_BOOT_INFO_OFF_TIME_PAGE == 72);
	CHECK(ERX_BOOT_ROOT_EXTENSION_SIZE == 88 && ERX_BOOT_ROOT_EXTENSION_ALIGN == 8);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_ROOT_BUDGET == 0);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_ROOT_GROUP == 8);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_SYSTEM_GROUP == 16);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_ROOT_RESOURCE == 24);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_BOOT_IMAGE == 32);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_TIME_PAGE == 40);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_SELF_SPACE == 48);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_SELF_THREAD == 56);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_DEVICE_SECRET == 64);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_MACHINE_PAGE == 72);
	CHECK(ERX_BOOT_ROOT_EXTENSION_OFF_PREVIOUS_CRASH == 80);
	return (0);
}

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
	if (check_records() != 0)
		return (1);
	puts("root capability checks passed");
	return (0);
}
