/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The domain library at boot and manifest startup (include/erx/dom_lib.h):
 * the view the system manifest and the boot image describe, the principals'
 * budgets and groups and the fault gate the root makes for it
 * (docs/design-system.md, "The root task", steps 2 and 3), and the one
 * caller on the target of erx_dom_plan_configured, which chokepoint
 * dom-manifest-entries holds to this file.
 *
 * The view is built the way the manifest check's host planner sees it
 * (tools/lib/erx/manifest.rb, plan_view), so the boot plans configured rows
 * against what the check proved: principals numbered by row from 1, each
 * configured row's limits from its limits record and that record's
 * runtime-limits profile, and each image's manifest accepted when its magic,
 * version and ABI version are this build's. The configured rows stay in the
 * manifest's table order, since a record's origin names its row there.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "erx/pack.h"
#include "liberx/backend/api.h"
#include "liberx/system/dom_apply.h"

/*
 * Each domain's handle table. The manifest names no size for it; this is
 * what a domain's runtime and its connections use, with room to spare.
 */
#define BOOT_CAP_LIMIT	64u

static bool	boot_limits(const erx_manifest_view_t *, uint32_t, erx_runtime_limits_t *);
static const char *boot_principals(erx_dom_lib_t *, const erx_manifest_view_t *,
		    const erx_dom_boot_tables_t *);
static const char *boot_configured(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_configured_t *);
static void	boot_files(erx_dom_view_t *, const erx_pack_view_t *, erx_dom_file_t *);
static bool	boot_place(size_t *, size_t, size_t, uint32_t, size_t *);

erx_dom_boot_sizes_t
erx_dom_boot_sizes(const erx_manifest_view_t *manifest, const erx_pack_view_t *pack)
{
	return ((erx_dom_boot_sizes_t){ .max_domains = manifest->header.max_domains,
	    .max_connections = manifest->header.max_connections,
	    .nprincipals = manifest->header.principals.count,
	    .nconfigured = manifest->header.domains.count, .nfiles = pack->header.nentries });
}

/*
 * Places count elements of size bytes, aligned to align, at offset *at of
 * the region, and moves *used past them. False on overflow.
 */
static bool
boot_place(size_t *used, size_t size, size_t align, uint32_t count, size_t *at)
{
	const size_t pad = (align - *used % align) % align;
	size_t bytes;

	return (!__builtin_mul_overflow(size, (size_t)count, &bytes) &&
	    !__builtin_add_overflow(*used, pad, at) &&
	    !__builtin_add_overflow(*at, bytes, used));
}

bool
erx_dom_boot_layout(const erx_dom_boot_sizes_t *sizes, uintptr_t base, erx_dom_boot_tables_t *tables,
    size_t *bytes)
{
	size_t used = 0, at;

	/* Each table at its offset from base; with base 0, none, and only the size counts. */
#define BOOT_PLACE(field, count)						\
	(boot_place(&used, sizeof(*tables->field), _Alignof(__typeof__(*tables->field)), (count), &at) && \
	    ((tables->field = base == 0 ? NULL : (__typeof__(tables->field))(base + at)), true))
	if (!BOOT_PLACE(domains, sizes->max_domains) ||
	    !BOOT_PLACE(handles, sizes->max_domains) ||
	    !BOOT_PLACE(connections, sizes->max_connections) ||
	    !BOOT_PLACE(links, sizes->max_connections) ||
	    !BOOT_PLACE(principals, sizes->nprincipals) ||
	    !BOOT_PLACE(held, sizes->nprincipals) ||
	    !BOOT_PLACE(configured, sizes->nconfigured) ||
	    !BOOT_PLACE(files, sizes->nfiles))
		return (false);
#undef BOOT_PLACE
	*bytes = used;
	return (true);
}

/*
 * erx_runtime_limits_t from limits record index: its runtime-limits
 * profile's fields and its own peer-held bounds (manifest.rb,
 * startup_limits). False for an index the tables do not hold.
 */
static bool
boot_limits(const erx_manifest_view_t *manifest, uint32_t index, erx_runtime_limits_t *limits)
{
	erx_mf_limits_t record;
	erx_mf_runtime_limits_t profile;

	if (!erx_manifest_limits_at(manifest, index, &record) ||
	    !erx_manifest_runtime_limits_at(manifest, record.runtime_limits, &profile))
		return (false);
	*limits = (erx_runtime_limits_t){ .max_frame = profile.max_frame,
	    .max_message_heap = profile.max_message_heap, .funnel_depth = profile.funnel_depth,
	    .exports = profile.exports, .tmp = profile.tmp, .overlay = profile.overlay,
	    .atoms = profile.atoms, .foreign_atoms = profile.foreign_atoms,
	    .processes = profile.processes, .peer_held = record.peer_held,
	    .peer_held_total = record.peer_held_total };
	return (true);
}

/* Principal row i is principal i + 1, admitted by erx_dom_principal_check against those before it. */
static const char *
boot_principals(erx_dom_lib_t *lib, const erx_manifest_view_t *manifest, const erx_dom_boot_tables_t *tables)
{
	erx_dom_principal_t config;
	erx_mf_principal_t row;

	lib->view.principals = tables->principals;
	lib->view.nprincipals = 0;
	for (uint32_t index = 0; index < manifest->header.principals.count; index++) {
		if (!erx_manifest_principals_at(manifest, index, &row))
			return ("manifest: a principal row the reader cannot read");
		config = (erx_dom_principal_t){ .number = index + 1, .memory = row.memory,
		    .domains_max = row.domains, .share = row.grant };
		if (!boot_limits(manifest, row.default_limits, &config.default_limits) ||
		    !boot_limits(manifest, row.ceiling_limits, &config.ceiling_limits))
			return ("manifest: a principal's limits name no limits record");
		if (erx_dom_principal_check(&lib->view, &config, &tables->principals[index]) != ERX_OK)
			return ("manifest: the domain library refuses a principal");
		/* No handle yet, and not ERX_CAP_NULL, which a budget argument reads as the caller's own. */
		tables->held[index] = (erx_dom_principal_held_t){ UINT64_MAX, UINT64_MAX };
		lib->view.nprincipals = index + 1;
	}
	return (NULL);
}

/* Each configured-domain row as manifest.rb's plan_view gives it to the host planner. */
static const char *
boot_configured(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_configured_t *configured)
{
	erx_mf_domain_t domain;
	erx_mf_limits_t profile;
	erx_dom_configured_t *row;

	view->configured = configured;
	view->nconfigured = 0;
	for (uint32_t index = 0; index < manifest->header.domains.count; index++) {
		row = &configured[index];
		if (!erx_manifest_domains_at(manifest, index, &domain) ||
		    !erx_manifest_limits_at(manifest, domain.limits, &profile))
			return ("manifest: a configured domain names no limits record");
		if (domain.principal >= manifest->header.principals.count)
			return ("manifest: a configured domain names no principal");
		*row = (erx_dom_configured_t){ .principal = domain.principal + 1,
		    .flags = (profile.flags & ERX_MF_LIMITS_SPACES) != 0 ? ERX_DOM_SPACES : 0,
		    .release = domain.release, .release_files = domain.release_files, .runtime = domain.runtime,
		    .memory = profile.memory, .outer = profile.outer, .grant = profile.grant,
		    .spaces = profile.spaces, .lane = profile.lane, .connections = profile.connections };
		if (!boot_limits(manifest, domain.limits, &row->runtime_limits))
			return ("manifest: a configured domain names no limits record");
		view->nconfigured = index + 1;
	}
	return (NULL);
}

/*
 * Every entry of the opened boot image, with an image's manifest accepted
 * when its magic, version and ABI version are this build's (manifest.rb,
 * plan_file); erx_image_map checks the rest when it maps one. An entry
 * too short for a manifest, or whose manifest bytes lie outside the
 * archive, reads as a refused image.
 */
static void
boot_files(erx_dom_view_t *view, const erx_pack_view_t *pack, erx_dom_file_t *files)
{
	erx_image_manifest_t image;
	erx_pack_entry_t entry;
	uint64_t end;
	bool read;

	view->files = files;
	view->nfiles = 0;
	for (uint32_t index = 0; index < pack->header.nentries; index++) {
		files[index] = (erx_dom_file_t){ 0 };
		if (erx_pack_entry_at(pack, index, &entry)) {
			files[index] = (erx_dom_file_t){ .kind = entry.kind, .flags = entry.flags,
			    .offset = entry.data_off, .size = entry.data_size };
			read = entry.kind == ERX_ENTRY_IMAGE && entry.data_size >= ERX_IMAGE_MANIFEST_SIZE &&
			    !__builtin_add_overflow(entry.data_off, (uint64_t)ERX_IMAGE_MANIFEST_SIZE, &end) &&
			    end <= pack->length &&
			    erx_image_manifest_decode(pack->bytes + entry.data_off, ERX_IMAGE_MANIFEST_SIZE, &image);
			if (read && image.magic == ERX_IMAGE_MAGIC && image.version == ERX_IMAGE_VERSION &&
			    image.abi_version == ERX_ABI_VERSION) {
				files[index].image_ok = true;
				files[index].image_flags = image.flags;
			}
		}
		view->nfiles = index + 1;
	}
}

const char *
erx_dom_boot_view(erx_dom_lib_t *lib, const erx_manifest_view_t *manifest, const erx_pack_view_t *pack,
    const erx_dom_boot_tables_t *tables)
{
	const erx_manifest_t *header = &manifest->header;
	const char *reason;

	memset(lib, 0, sizeof(*lib));
	lib->view.domains = tables->domains;
	lib->view.max_domains = header->max_domains;
	lib->view.connections = tables->connections;
	lib->view.max_connections = header->max_connections;
	memset(tables->domains, 0, sizeof(*tables->domains) * header->max_domains);
	memset(tables->connections, 0, sizeof(*tables->connections) * header->max_connections);
	for (uint32_t index = 0; index < header->max_domains; index++)
		for (uint32_t obj = 0; obj < ERX_DOM_OBJ_MADE_COUNT; obj++)
			tables->handles[index].made[obj] = ERX_CAP_NULL;
	for (uint32_t index = 0; index < header->max_connections; index++)
		for (uint32_t obj = 0; obj < ERX_DOM_LINK_OBJS; obj++)
			tables->links[index].made[obj] = ERX_CAP_NULL;
	lib->handles = tables->handles;
	lib->links = tables->links;
	lib->held.principals = tables->held;
	if ((reason = boot_principals(lib, manifest, tables)) != NULL ||
	    (reason = boot_configured(&lib->view, manifest, tables->configured)) != NULL)
		return (reason);
	if (!boot_limits(manifest, header->native_limits, &lib->view.native_limits))
		return ("manifest: native_limits names no limits record");
	boot_files(&lib->view, pack, tables->files);
	lib->view.system_grant = header->system_share;
	lib->view.system_reserve = header->system_reserve;
	lib->view.system_lane = header->system_lane;
	lib->view.next_connection = 1;
	if (header->host.length > ERX_DOM_HOST_MAX)
		return ("manifest: the host name is longer than a node name holds");
	/* The reader checked every string against the string table; the manifest's bytes outlive the boot. */
	lib->host = (const char *)manifest->bytes + header->strings.offset + header->host.offset;
	lib->host_len = header->host.length;
	lib->cap_limit = BOOT_CAP_LIMIT;
#ifdef ERX_DOM_TEST_HOOKS
	lib->fail_step = UINT32_MAX;
#endif
	return (NULL);
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
erx_dom_lib_configured(erx_dom_lib_t *lib, uint32_t id, uint32_t row, erx_dom_created_t *created)
{
	/* A plan holds a specification with its strings: too large for a stack. */
	static erx_dom_plan_t plan;
	erx_status_t status;

	status = erx_dom_plan_configured(&lib->view, id, row, &plan);
	if (status == ERX_OK)
		status = erx_dom_lib_apply(lib, &plan, created);
	memset(&plan, 0, sizeof(plan));
	return (status);
}
