/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The release readers of erx/release.h that ERTS calls, for a domain's runtime in a
 * task (docs/design-stopgap.md, "The call table"). A task holds no archive index: its
 * release is the slice the boot information's release names, mapped at release_addr,
 * and the service answers each entry from the slice's record and checks a file
 * before ERTS first reads it. The root's own readers are liberx/release.c.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/release.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/runtime_entry.h"

int
erx_release_entry(uint64_t index, erx_release_entry_t *entry)
{
	return (erx_fiasco_release_entry(erx_boot_info()->release.raw, index, false, entry));
}

const uint8_t *
erx_release_addr(void)
{
	return ((const uint8_t *)(uintptr_t)erx_boot_info()->release_addr);
}

int
erx_release_check(uint64_t index, const char **reason)
{
	const int status = erx_fiasco_release_entry(erx_boot_info()->release.raw, index, true, NULL);

	if (status == ERX_ECORRUPT)
		*reason = "file";
	return (status);
}
