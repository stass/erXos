/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The domain library at boot and manifest startup (include/erx/dom_lib.h):
 * the boot image's files as the view sees them, the principals' budgets and
 * groups and the fault gate the root makes for the library
 * (docs/design-system.md, "The root task", steps 2 and 3), and the one
 * caller on the target of erx_dom_plan_configured, which chokepoint
 * dom-manifest-entries holds to this file. The view itself is
 * liberx/system/dom_boot_view.c's, which the manifest check builds too.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "erx/pack.h"
#include "liberx/backend/api.h"
#include "liberx/system/dom_apply.h"

static void	boot_files(const erx_pack_view_t *, erx_dom_file_t *);

/*
 * Every entry of the opened boot image, each judged by erx_dom_boot_image
 * from the bytes the archive holds from the entry's start, no more than
 * the entry's size: an entry too short for a manifest, or whose bytes
 * lie outside the archive, reads as a refused image.
 */
static void
boot_files(const erx_pack_view_t *pack, erx_dom_file_t *files)
{
	erx_pack_entry_t entry;
	size_t head_len;

	for (uint32_t index = 0; index < pack->header.nentries; index++) {
		files[index] = (erx_dom_file_t){ 0 };
		if (!erx_pack_entry_at(pack, index, &entry))
			continue;
		files[index] = (erx_dom_file_t){ .kind = entry.kind, .flags = entry.flags,
		    .offset = entry.data_off, .size = entry.data_size };
		head_len = 0;
		if (entry.data_off <= pack->length)
			head_len = (size_t)(pack->length - entry.data_off < entry.data_size ?
			    pack->length - entry.data_off : entry.data_size);
		erx_dom_boot_image(&files[index], head_len == 0 ? NULL : pack->bytes + entry.data_off, head_len);
	}
}

erx_dom_boot_sizes_t
erx_dom_boot_sizes(const erx_manifest_view_t *manifest, const erx_pack_view_t *pack)
{
	return (erx_dom_view_sizes(manifest, pack->header.nentries));
}

const char *
erx_dom_boot_view(erx_dom_lib_t *lib, const erx_manifest_view_t *manifest, const erx_pack_view_t *pack,
    const erx_dom_boot_tables_t *tables)
{
	boot_files(pack, tables->files);
	return (erx_dom_view_build(lib, manifest, pack->header.nentries, tables));
}

const char *
erx_dom_boot_up(erx_dom_lib_t *lib, const erx_boot_info_t *system_page, uint64_t system_space)
{
	const erx_dom_principal_t *principal;
	erx_dom_principal_held_t *held;

	lib->view.system_space = system_space;
	lib->held.system_group = system_page->group.raw;
	lib->held.time_page = system_page->time_page.raw;
	/* The stopgap's backend has one archive and reads no image handle. */
	lib->held.image = 0;
	lib->pack_flags = system_page->pack_flags;
	lib->det = (system_page->flags & ERX_BOOT_DET) != 0;
	for (uint32_t index = 0; index < lib->view.nprincipals; index++) {
		principal = &lib->view.principals[index];
		held = &lib->held.principals[index];
		if (erx_budget_create(ERX_CAP_SELF, ERX_BUDGET_ELASTIC, principal->memory / ERX_PAGE_SIZE,
		    principal->memory / ERX_PAGE_SIZE, &held->budget) != ERX_OK)
			return ("the domain library: the backend refused a principal's budget");
		if (erx_group_create(0, 0, &held->group) != ERX_OK)
			return ("the domain library: the backend refused a principal's group");
	}
	if (erx_gate_create(0, &lib->held.gate) != ERX_OK)
		return ("the domain library: the backend refused its fault gate");
	erx_dom_lib_system_set(lib);
	return (NULL);
}

erx_status_t
erx_dom_lib_configured(erx_dom_lib_t *lib, uint32_t id, uint32_t row, erx_dom_pid_t domain_pid,
    erx_dom_created_t *created)
{
	/* A plan holds a specification with its strings: too large for a stack. */
	static erx_dom_plan_t plan;
	erx_status_t status;

	status = erx_dom_plan_configured(&lib->view, id, row, domain_pid, &plan);
	if (status == ERX_OK)
		status = erx_dom_lib_apply(lib, &plan, created);
	memset(&plan, 0, sizeof(plan));
	return (status);
}
