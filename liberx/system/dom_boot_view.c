/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The domain library's view at boot (include/erx/dom_lib.h): the tables the
 * system manifest and the boot image describe, built from the packed
 * manifest's bytes (docs/design-system.md, "The root task", step 2). Pure:
 * it makes no call, reads no global state and builds for the host.
 *
 * It is the one builder of that view. The root builds it before ERTS runs
 * (erx_dom_boot_view in liberx/system/dom_boot.c), and the manifest
 * check's host planner (tools/host/dom_plan.c) builds it from the very bytes
 * the build packs, before planning each configured domain against it. So
 * what the boot plans against is what the check proved, field by field, and
 * a manifest this file or erx_dom_principal_check refuses fails the build,
 * not the boot.
 *
 * Principals are numbered by row from 1, each admitted by
 * erx_dom_principal_check against those before it; each configured row
 * takes its limits from its limits record and that record's runtime-limits
 * profile, and the rows stay in the manifest's table order, since a
 * record's origin names its row there. The files are judged one entry at a
 * time by erx_dom_boot_image from the bytes that start the entry.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"

/*
 * Each domain's handle table. The manifest names no size for it; this is
 * what a domain's runtime and its connections use, with room to spare.
 */
#define BOOT_CAP_LIMIT	64u

static bool	boot_place(size_t *, size_t, size_t, uint32_t, size_t *);
static bool	boot_limits(const erx_manifest_view_t *, uint32_t, erx_runtime_limits_t *);
static const char *boot_principals(erx_dom_lib_t *, const erx_manifest_view_t *,
		    const erx_dom_boot_tables_t *);
static const char *boot_places(erx_dom_configured_t *, uint32_t, const erx_manifest_view_t *);
static const char *boot_configured(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_configured_t *);
static const char *boot_templates(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_template_t *);

erx_dom_boot_sizes_t
erx_dom_view_sizes(const erx_manifest_view_t *manifest, uint32_t nfiles)
{
	return ((erx_dom_boot_sizes_t){ .max_domains = manifest->header.max_domains,
	    .max_connections = manifest->header.max_connections,
	    .nprincipals = manifest->header.principals.count,
	    .nconfigured = manifest->header.domains.count,
	    .ntemplates = manifest->header.sessions.count, .nfiles = nfiles });
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
	    !BOOT_PLACE(remains, (size_t)sizes->max_connections * 2) ||
	    !BOOT_PLACE(remains_held, (size_t)sizes->max_connections * 2) ||
	    !BOOT_PLACE(principals, sizes->nprincipals) ||
	    !BOOT_PLACE(held, sizes->nprincipals) ||
	    !BOOT_PLACE(configured, sizes->nconfigured) ||
	    !BOOT_PLACE(templates, sizes->ntemplates) ||
	    !BOOT_PLACE(files, sizes->nfiles))
		return (false);
#undef BOOT_PLACE
	*bytes = used;
	return (true);
}

/*
 * An image entry's manifest accepted when its magic, version and ABI
 * version are this build's; erx_image_map checks the rest when it maps one.
 * Fewer bytes than a manifest, or an entry of another kind, read as no
 * accepted image.
 */
void
erx_dom_boot_image(erx_dom_file_t *file, const uint8_t *head, size_t head_len)
{
	erx_image_manifest_t image;

	file->image_ok = false;
	file->image_flags = 0;
	if (file->kind != ERX_ENTRY_IMAGE || head_len < ERX_IMAGE_MANIFEST_SIZE ||
	    !erx_image_manifest_decode(head, ERX_IMAGE_MANIFEST_SIZE, &image))
		return;
	if (image.magic == ERX_IMAGE_MAGIC && image.version == ERX_IMAGE_VERSION &&
	    image.abi_version == ERX_ABI_VERSION) {
		file->image_ok = true;
		file->image_flags = image.flags;
	}
}

/*
 * erx_runtime_limits_t from limits record index: its runtime-limits
 * profile's fields and its own peer-held bounds. False for an index the
 * tables do not hold.
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

/*
 * Each row's place in the boot order, which the check computed (property 10)
 * and the packer wrote: every configured row exactly once, so the domain
 * service walks the rows in that order by place.
 */
static const char *
boot_places(erx_dom_configured_t *configured, uint32_t nconfigured, const erx_manifest_view_t *manifest)
{
	erx_mf_boot_order_t step;

	if (manifest->header.boot_order.count != nconfigured)
		return ("manifest: the boot order does not place every configured domain");
	for (uint32_t place = 0; place < nconfigured; place++) {
		if (!erx_manifest_boot_order_at(manifest, place, &step) || step.domain >= nconfigured ||
		    configured[step.domain].place != UINT32_MAX)
			return ("manifest: the boot order does not place every configured domain once");
		configured[step.domain].place = place;
	}
	return (NULL);
}

/* Each configured-domain row, its limits resolved from its limits record. */
static const char *
boot_configured(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_configured_t *configured)
{
	erx_mf_domain_t domain;
	erx_mf_limits_t profile;
	erx_dom_configured_t *row;
	const char *strings;

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
		if (domain.name.length == 0 || domain.name.length > ERX_DOM_NAME_MAX)
			return ("manifest: a configured domain's name is not 1 to 63 bytes");
		if ((uint64_t)domain.args.length + domain.env.length > ERX_BOOT_STRINGS_MAX)
			return ("manifest: a configured domain's arguments and environment exceed the boot page's strings");
		/* The reader checked every string against the string table; the manifest's bytes outlive the view. */
		strings = (const char *)manifest->bytes + manifest->header.strings.offset;
		row->name = strings + domain.name.offset;
		row->name_len = domain.name.length;
		row->args = strings + domain.args.offset;
		row->args_len = domain.args.length;
		row->env = strings + domain.env.offset;
		row->env_len = domain.env.length;
		row->kind = domain.kind;
		row->restarts = domain.restarts;
		row->restart_period_s = domain.restart_period_s;
		row->place = UINT32_MAX;
		view->nconfigured = index + 1;
	}
	return (boot_places(configured, view->nconfigured, manifest));
}

/*
 * Each session template, keyed by its principal: the check writes them in
 * principal order, one per principal (property 14), and a manifest that
 * gives a principal two is refused.
 */
static const char *
boot_templates(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_template_t *templates)
{
	erx_mf_session_t session;
	const char *strings;
	uint32_t principal;

	view->templates = templates;
	view->ntemplates = 0;
	/* The reader checked every string against the string table; the manifest's bytes outlive the view. */
	strings = (const char *)manifest->bytes + manifest->header.strings.offset;
	for (uint32_t index = 0; index < manifest->header.sessions.count; index++) {
		if (!erx_manifest_sessions_at(manifest, index, &session))
			return ("manifest: a session template the reader cannot read");
		if (session.principal >= manifest->header.principals.count ||
		    session.limits >= manifest->header.limits.count)
			return ("manifest: a session template names no principal or limits record");
		/* The principal's number, from 1, as the view numbers principals. */
		principal = session.principal + 1;
		if (index > 0 && principal <= templates[index - 1].principal)
			return ("manifest: the session templates are not one per principal in principal order");
		if ((uint64_t)session.args.length + session.env.length > ERX_BOOT_STRINGS_MAX)
			return ("manifest: a session template's arguments and environment exceed the boot page's strings");
		templates[index] = (erx_dom_template_t){ .principal = principal,
		    .limits = session.limits, .release = session.release,
		    .release_files = session.release_files, .runtime = session.runtime,
		    .args = strings + session.args.offset, .args_len = session.args.length,
		    .env = strings + session.env.offset, .env_len = session.env.length };
		view->ntemplates = index + 1;
	}
	return (NULL);
}

const char *
erx_dom_view_build(erx_dom_lib_t *lib, const erx_manifest_view_t *manifest, uint32_t nfiles,
    const erx_dom_boot_tables_t *tables)
{
	const erx_manifest_t *header = &manifest->header;
	const char *reason;

	memset(lib, 0, sizeof(*lib));
	/* Remains rows are twice the connection rows, counted in a uint32_t. */
	if (header->max_connections > UINT32_MAX / 2)
		return ("max_connections is too large");
	lib->view.domains = tables->domains;
	lib->view.max_domains = header->max_domains;
	lib->view.connections = tables->connections;
	lib->view.max_connections = header->max_connections;
	lib->view.remains = tables->remains;
	lib->view.max_remains = header->max_connections * 2;
	memset(tables->domains, 0, sizeof(*tables->domains) * header->max_domains);
	memset(tables->connections, 0, sizeof(*tables->connections) * header->max_connections);
	memset(tables->remains, 0, sizeof(*tables->remains) * lib->view.max_remains);
	for (uint32_t index = 0; index < lib->view.max_remains; index++)
		tables->remains_held[index] = ERX_CAP_NULL;
	for (uint32_t index = 0; index < header->max_domains; index++)
		for (uint32_t obj = 0; obj < ERX_DOM_OBJ_MADE_COUNT; obj++)
			tables->handles[index].made[obj] = ERX_CAP_NULL;
	for (uint32_t index = 0; index < header->max_connections; index++)
		for (uint32_t obj = 0; obj < ERX_DOM_LINK_OBJS; obj++)
			tables->links[index].made[obj] = ERX_CAP_NULL;
	lib->handles = tables->handles;
	lib->links = tables->links;
	lib->remains_held = tables->remains_held;
	lib->held.principals = tables->held;
	if ((reason = boot_principals(lib, manifest, tables)) != NULL ||
	    (reason = boot_configured(&lib->view, manifest, tables->configured)) != NULL ||
	    (reason = boot_templates(&lib->view, manifest, tables->templates)) != NULL)
		return (reason);
	if (!boot_limits(manifest, header->native_limits, &lib->view.native_limits))
		return ("manifest: native_limits names no limits record");
	lib->view.files = tables->files;
	lib->view.nfiles = nfiles;
	lib->view.system_grant = header->system_share;
	lib->view.system_reserve = header->system_reserve;
	lib->view.system_lane = header->system_lane;
	lib->view.next_connection = 1;
	if (header->host.length > ERX_DOM_HOST_MAX)
		return ("manifest: the host name is longer than a node name holds");
	/* The reader checked every string against the string table; the manifest's bytes outlive the view. */
	lib->host = (const char *)manifest->bytes + header->strings.offset + header->host.offset;
	lib->host_len = header->host.length;
	lib->cap_limit = BOOT_CAP_LIMIT;
#ifdef ERX_DOM_TEST_HOOKS
	lib->fail_step = UINT32_MAX;
#endif
	return (NULL);
}
