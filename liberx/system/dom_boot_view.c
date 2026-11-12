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
 *
 * The device catalogue is the manifest's device table, entry for entry,
 * each entry placed on its unit's holder; the view is refused unless the
 * placement gives every unit whole to one holder (boot_devices), so
 * nothing builds a domain from a placement the view did not admit. Each
 * configured row and session template must leave room in its boot page's
 * strings for what the library adds to its own words (boot_strings_fit).
 * The service and facet rows are carried for the domain service
 * (boot_services), each server a configured row or the system domain, and
 * each grantee the system domain, a configured row or a session template.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/boot_words.h"
#include "erx/device_kinds.h"
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
static bool	boot_pages(uint64_t, uint64_t, erx_dom_range_t *);
static bool	boot_pages_meet(const erx_dom_device_entry_t *, const erx_dom_device_entry_t *);
static const char *boot_units(const erx_manifest_view_t *, erx_dom_device_entry_t *);
static const char *boot_devices(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_device_entry_t *, erx_dom_device_t *);
static bool	boot_strings_fit(uint64_t, uint64_t, uint32_t, bool);
static const char *boot_places(erx_dom_configured_t *, uint32_t, const erx_manifest_view_t *);
static const char *boot_configured(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_configured_t *);
static const char *boot_templates(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_template_t *);
static const char *boot_services(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_service_t *, erx_dom_facet_t *);
static const char *boot_facet_grantee(const erx_dom_view_t *, const erx_mf_facet_t *,
		    const erx_dom_service_t *);
static bool	boot_facet_repeats(const erx_dom_view_t *, const erx_dom_facet_t *, uint32_t);

erx_dom_boot_sizes_t
erx_dom_view_sizes(const erx_manifest_view_t *manifest, uint32_t nfiles)
{
	return ((erx_dom_boot_sizes_t){ .max_domains = manifest->header.max_domains,
	    .max_connections = manifest->header.max_connections,
	    .nprincipals = manifest->header.principals.count,
	    .nconfigured = manifest->header.domains.count,
	    .ntemplates = manifest->header.sessions.count, .nfiles = nfiles,
	    .ndevices = manifest->header.devices.count,
	    .nservices = manifest->header.services.count,
	    .nfacets = manifest->header.facets.count });
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
	    !BOOT_PLACE(files, sizes->nfiles) ||
	    !BOOT_PLACE(devices, sizes->ndevices) ||
	    !BOOT_PLACE(device_records, sizes->ndevices) ||
	    !BOOT_PLACE(services, sizes->nservices) ||
	    !BOOT_PLACE(facets, sizes->nfacets))
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
 * The pages a device's register window touches, from its base's page to its
 * last byte's. False for an empty window or one that runs past the address
 * space, so the pages' end never wraps either.
 */
static bool
boot_pages(uint64_t base, uint64_t size, erx_dom_range_t *pages)
{
	const uint64_t mask = ~(uint64_t)(ERX_PAGE_SIZE - 1);
	uint64_t end;

	if (size == 0 || __builtin_add_overflow(base, size, &end) ||
	    __builtin_add_overflow(end, ERX_PAGE_SIZE - 1, &end))
		return (false);
	*pages = (erx_dom_range_t){ base & mask, (end & mask) - (base & mask) };
	return (true);
}

/* Whether two entries' register pages share a page; an entry with no window shares none. */
static bool
boot_pages_meet(const erx_dom_device_entry_t *a, const erx_dom_device_entry_t *b)
{
	const erx_dom_range_t *x = &a->ranges[0], *y = &b->ranges[0];

	return (a->nranges != 0 && b->nranges != 0 &&
	    x->base < y->base + y->size && y->base < x->base + x->size);
}

/*
 * The kind of a device-tree device, erx/device_kinds.h's row of its role and
 * compatible string, whose names its holder's record carries; NULL for a
 * kind no runtime drives. The reader checked every string against the
 * string table.
 */
static const erx_device_kind_t *
boot_kind(const erx_manifest_view_t *manifest, const erx_mf_device_t *device)
{
	const char *compatible = (const char *)manifest->bytes + manifest->header.strings.offset +
	    device->compatible.offset;

	for (size_t at = 0; at < ERX_DEVICE_KINDS_COUNT; at++) {
		const erx_device_kind_t *kind = &erx_device_kinds[at];

		if (kind->role == device->role && strlen(kind->compatible) == device->compatible.length &&
		    memcmp(kind->compatible, compatible, device->compatible.length) == 0)
			return (kind);
	}
	return (NULL);
}

/*
 * Each entry's unit, its unit's name and its holder, from the unit rows'
 * spans of the device table. The reader proved the spans a partition of
 * the table; a span off a row boundary, past the table, or over a device
 * another span holds is refused all the same, so every entry has exactly
 * one unit. The reader proved each unit's name an identifier of 1 to 63
 * bytes (ERX_DOM_NAME_MAX) in the string table, whose bytes outlive the
 * view.
 */
static const char *
boot_units(const erx_manifest_view_t *manifest, erx_dom_device_entry_t *entries)
{
	const erx_mf_span_t table = manifest->header.devices;
	const char *strings = (const char *)manifest->bytes + manifest->header.strings.offset;
	erx_mf_unit_t unit;
	uint32_t first;

	for (uint32_t index = 0; index < table.count; index++)
		entries[index] = (erx_dom_device_entry_t){ .unit = UINT32_MAX };
	for (uint32_t at = 0; at < manifest->header.units.count; at++) {
		if (!erx_manifest_units_at(manifest, at, &unit) || unit.devices.offset < table.offset ||
		    (unit.devices.offset - table.offset) % ERX_MF_DEVICE_SIZE != 0)
			return ("manifest: a unit's devices are not a span of the device table");
		first = (unit.devices.offset - table.offset) / ERX_MF_DEVICE_SIZE;
		if (first > table.count || unit.devices.count > table.count - first)
			return ("manifest: a unit's devices are not a span of the device table");
		for (uint32_t index = first; index < first + unit.devices.count; index++) {
			if (entries[index].unit != UINT32_MAX)
				return ("manifest: a device is in two units");
			entries[index].unit = at;
			entries[index].unit_name = strings + unit.name.offset;
			entries[index].unit_name_len = unit.name.length;
			entries[index].row = unit.holder;
		}
	}
	for (uint32_t index = 0; index < table.count; index++)
		if (entries[index].unit == UINT32_MAX)
			return ("manifest: a device is in no unit");
	return (NULL);
}

/*
 * The device catalogue and its placement (docs/design-system.md,
 * "Devices"): an entry per device row, in its unit and on its unit's
 * holder, and a record per entry with no holder and no object yet. A
 * device-tree device has its register window, as whole pages, and its
 * line; a PCIe function has neither, since configuration space gives
 * them. Units are derived from register pages, since a page has at most
 * one MMIO object: devices whose pages meet are one unit, so the manifest
 * must have them in one unit row, which has one holder. A unit split
 * across two rows, two holders on one page included, refuses the view.
 * So does a unit on a configured row whose own devices share a page: a
 * give windows one device, and the library refuses a window over a page
 * another entry's window meets, so every creation of that row would fail;
 * only the system domain, whose windows the root makes, may hold such a
 * unit until the catalogue's entry is the unit (TODO.md).
 * So does a device marked confined: the stopgap's catalogue lists no IOMMU
 * stream, and a confined device is given only on one; and DMA memory that is
 * not whole pages, which no give can make.
 */
static const char *
boot_devices(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_device_entry_t *entries,
    erx_dom_device_t *records)
{
	const uint32_t count = manifest->header.devices.count;
	const erx_device_kind_t *kind;
	erx_mf_device_t device;
	erx_dom_device_entry_t *entry;
	const char *reason;

	view->devices = entries;
	view->device_records = records;
	view->ndevices = 0;
	if ((reason = boot_units(manifest, entries)) != NULL)
		return (reason);
	for (uint32_t index = 0; index < count; index++) {
		entry = &entries[index];
		if (!erx_manifest_devices_at(manifest, index, &device))
			return ("manifest: a device row the reader cannot read");
		if (device.dma == ERX_MF_DMA_CONFINED)
			return ("manifest: a device marked confined has no IOMMU stream");
		entry->role = device.role;
		entry->memory = device.dma == ERX_MF_DMA_UNCONFINED ? device.dma_memory : 0;
		if (entry->memory % ERX_PAGE_SIZE != 0)
			return ("manifest: a device's DMA memory is not whole pages");
		if (device.selector == ERX_MF_SELECTOR_DT) {
			if (!boot_pages(device.base, device.size, &entry->ranges[0]))
				return ("manifest: a device's register window is empty or wraps");
			entry->nranges = 1;
			entry->offset = device.base - entry->ranges[0].base;
			entry->size = device.size;
			entry->clock = device.clock;
			entry->nlines = 1;
			entry->lines[0] = device.line;
			kind = boot_kind(manifest, &device);
			if (kind != NULL) {
				entry->role_word = kind->role_word;
				entry->peripheral = kind->peripheral;
				entry->compatible = kind->compatible;
			}
		}
		records[index] = (erx_dom_device_t){ .index = index, .resource = { ERX_CAP_NULL },
		    .dma = { ERX_CAP_NULL }, .memory = { ERX_CAP_NULL } };
		for (uint32_t at = 0; at < ERX_DEVICE_RANGES_MAX; at++)
			records[index].windows[at] = (erx_cap_t){ ERX_CAP_NULL };
		for (uint32_t at = 0; at < ERX_DEVICE_IRQS_MAX; at++)
			records[index].irqs[at] = (erx_cap_t){ ERX_CAP_NULL };
	}
	for (uint32_t a = 0; a < count; a++) {
		for (uint32_t b = a + 1; b < count; b++) {
			if (!boot_pages_meet(&entries[a], &entries[b]))
				continue;
			if (entries[a].unit != entries[b].unit)
				return ("manifest: devices that share a register page are in two units");
			/* One unit has one holder (boot_units), so a's row is b's. */
			if (entries[a].row != ERX_MF_NONE)
				return ("manifest: devices of a unit a configured domain holds share a register page");
		}
	}
	view->ndevices = count;
	return (NULL);
}

/*
 * Whether a domain's boot page's strings hold its arguments and
 * environment beside what the library writes there (docs/design-stopgap.md,
 * "Boot information"): its own node name and the system node's, -erx
 * build, a -erx given record per device it holds, and -erx boot when it holds a
 * block device. The reserve takes each at its longest, so a row the view
 * admits never fails its creation for its strings: a node name at
 * ERX_DOM_NODE_MAX, though the system node's is at most 71 bytes, and the
 * difference also covers the NUL the page adds to args or env that lack a
 * final one. No sum can wrap: each term is at most a u32 times a small
 * constant.
 */
static bool
boot_strings_fit(uint64_t args_len, uint64_t env_len, uint32_t held, bool block)
{
	const uint64_t reserve = 2u * (uint64_t)ERX_DOM_NODE_MAX + ERX_BOOT_BUILD_WORDS_MAX +
	    (uint64_t)held * ERX_BOOT_GIVEN_WORDS_MAX +
	    (block ? ERX_BOOT_PAIR_WORDS_MAX : 0);

	return (args_len + env_len + reserve <= ERX_BOOT_STRINGS_MAX);
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

/*
 * Each configured-domain row, its limits resolved from its limits record and
 * its strings judged against the devices the catalogue places on it, so
 * it reads view->devices, which boot_devices builds first.
 */
static const char *
boot_configured(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_configured_t *configured)
{
	erx_mf_domain_t domain;
	erx_mf_limits_t profile;
	erx_dom_configured_t *row;
	const char *strings;
	uint32_t held;
	bool block;

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
		held = 0;
		block = false;
		for (uint32_t device = 0; device < view->ndevices; device++) {
			if (view->devices[device].row != index)
				continue;
			/* Its holder opens it from its record, which names its kind. */
			if (view->devices[device].role_word == NULL)
				return ("manifest: a configured domain holds a device of a kind no runtime drives");
			held++;
			block = block || view->devices[device].role == ERX_MF_DEVICE_ROLE_BLOCK;
		}
		if (held > ERX_DOM_GIVES_MAX)
			return ("manifest: a configured domain holds more devices than its creation gives");
		if (!boot_strings_fit(domain.args.length, domain.env.length, held, block))
			return ("manifest: a configured domain's arguments and environment leave the boot page's strings "
			    "no reserve for its node names and device records");
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
		row->boot_timeout_s = domain.boot_timeout_s;
		row->place = UINT32_MAX;
		view->nconfigured = index + 1;
	}
	return (boot_places(configured, view->nconfigured, manifest));
}

/*
 * Each session template, keyed by its principal, its limits resolved from
 * its limits record as a configured row's: the check writes them in
 * principal order, one per principal (property 14), and a manifest that
 * gives a principal two is refused.
 */
static const char *
boot_templates(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_template_t *templates)
{
	erx_mf_session_t session;
	erx_mf_limits_t profile;
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
		    !erx_manifest_limits_at(manifest, session.limits, &profile))
			return ("manifest: a session template names no principal or limits record");
		/* The principal's number, from 1, as the view numbers principals. */
		principal = session.principal + 1;
		if (index > 0 && principal <= templates[index - 1].principal)
			return ("manifest: the session templates are not one per principal in principal order");
		if (!boot_strings_fit(session.args.length, session.env.length, 0, false))
			return ("manifest: a session template's arguments and environment leave the boot page's strings "
			    "no reserve for its node names");
		templates[index] = (erx_dom_template_t){ .principal = principal,
		    .flags = (profile.flags & ERX_MF_LIMITS_SPACES) != 0 ? ERX_DOM_SPACES : 0,
		    .memory = profile.memory, .outer = profile.outer, .grant = profile.grant,
		    .spaces = profile.spaces, .lane = profile.lane, .connections = profile.connections,
		    .release = session.release,
		    .release_files = session.release_files, .runtime = session.runtime,
		    .args = strings + session.args.offset, .args_len = session.args.length,
		    .env = strings + session.env.offset, .env_len = session.env.length };
		if (!boot_limits(manifest, session.limits, &templates[index].runtime_limits))
			return ("manifest: a session template names no limits record");
		view->ntemplates = index + 1;
	}
	return (NULL);
}

/*
 * Whether facet row index grants its grantee a service of the name an
 * earlier row grants it: a grantee's registry holds each facet under its
 * service's name, so it takes one facet of a name (property 2), and the
 * domain service's erx_domain_mints refuses a second. Quadratic in the
 * facet rows, which are few.
 */
static bool
boot_facet_repeats(const erx_dom_view_t *view, const erx_dom_facet_t *facets, uint32_t index)
{
	const erx_dom_service_t *service, *other;

	service = &view->services[facets[index].service];
	for (uint32_t earlier = 0; earlier < index; earlier++) {
		other = &view->services[facets[earlier].service];
		if (facets[earlier].grantee_kind == facets[index].grantee_kind &&
		    facets[earlier].grantee == facets[index].grantee && other->name_len == service->name_len &&
		    memcmp(other->name, service->name, service->name_len) == 0)
			return (true);
	}
	return (false);
}

/*
 * Why facet's grantee cannot take a facet of service, or NULL. The
 * system domain takes no facet of its own services; a configured row
 * none of its own; and a session template a configured domain's, which
 * the server grants each session directly, or the system domain's, whose
 * facet the domain service starts for each session (property 14). The
 * reader has checked the grantee's index against its kind's table and
 * made the system domain's 0; the bounds are checked again against the
 * view's own.
 */
static const char *
boot_facet_grantee(const erx_dom_view_t *view, const erx_mf_facet_t *facet, const erx_dom_service_t *service)
{
	switch (facet->grantee_kind) {
	case ERX_MF_GRANTEE_SYSTEM:
		if (service->server == ERX_MF_NONE)
			return ("manifest: a facet is granted to its service's own server");
		return (NULL);
	case ERX_MF_GRANTEE_DOMAIN:
		if (facet->grantee >= view->nconfigured)
			return ("manifest: a facet's grantee is no configured domain");
		if (facet->grantee == service->server)
			return ("manifest: a facet is granted to its service's own server");
		return (NULL);
	case ERX_MF_GRANTEE_SESSION:
		if (facet->grantee >= view->ntemplates)
			return ("manifest: a facet's grantee is no session template");
		return (NULL);
	default:
		return ("manifest: a facet's grantee is of no kind the boot knows");
	}
}

/*
 * The service and facet rows, which the domain service reads
 * (erx_domain_lib:configured/0), so it reads view->nconfigured, which
 * boot_configured and boot_templates set first. A server is a configured
 * row or ERX_MF_NONE, and a grantee the system domain, a configured row or
 * a session template; a facet is never granted to its service's own
 * server, a grantee takes one facet of a service name, and a facet names no
 * operation or parameter (erx_dom_facet_t). The reader has checked every
 * index and string against its table.
 */
static const char *
boot_services(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_service_t *services,
    erx_dom_facet_t *facets)
{
	erx_mf_service_t service;
	erx_mf_facet_t facet;
	const char *strings, *reason;

	view->services = services;
	view->nservices = 0;
	view->facets = facets;
	view->nfacets = 0;
	/* The reader checked every string against the string table; the manifest's bytes outlive the view. */
	strings = (const char *)manifest->bytes + manifest->header.strings.offset;
	for (uint32_t index = 0; index < manifest->header.services.count; index++) {
		if (!erx_manifest_services_at(manifest, index, &service))
			return ("manifest: a service row the reader cannot read");
		if (service.server != ERX_MF_NONE && service.server >= view->nconfigured)
			return ("manifest: a service's server is neither the system domain nor a configured domain");
		if (service.name.length == 0 || service.name.length > ERX_DOM_NAME_MAX)
			return ("manifest: a service's name is not 1 to 63 bytes");
		services[index] = (erx_dom_service_t){ .name = strings + service.name.offset,
		    .name_len = service.name.length, .server = service.server,
		    .interface = service.interface };
		view->nservices = index + 1;
	}
	for (uint32_t index = 0; index < manifest->header.facets.count; index++) {
		if (!erx_manifest_facets_at(manifest, index, &facet))
			return ("manifest: a facet row the reader cannot read");
		if (facet.service >= view->nservices)
			return ("manifest: a facet names no service");
		if ((reason = boot_facet_grantee(view, &facet, &services[facet.service])) != NULL)
			return (reason);
		if (facet.operations.count != 0 || facet.parameters.count != 0)
			return ("manifest: a facet names operations or parameters, which the boot cannot check");
		facets[index] = (erx_dom_facet_t){ .grantee_kind = facet.grantee_kind,
		    .grantee = facet.grantee, .service = facet.service,
		    .max_request = facet.max_request, .in_flight = facet.in_flight,
		    .reductions = facet.reductions, .period_ns = facet.period_ns,
		    .max_heap_size = facet.max_heap_size, .queue = facet.queue };
		if (boot_facet_repeats(view, facets, index))
			return ("manifest: a grantee takes two facets of one service name");
		view->nfacets = index + 1;
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
	    (reason = boot_devices(&lib->view, manifest, tables->devices, tables->device_records)) != NULL ||
	    (reason = boot_configured(&lib->view, manifest, tables->configured)) != NULL ||
	    (reason = boot_templates(&lib->view, manifest, tables->templates)) != NULL ||
	    (reason = boot_services(&lib->view, manifest, tables->services, tables->facets)) != NULL)
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
	lib->device_records = tables->device_records;
#ifdef ERX_DOM_TEST_HOOKS
	lib->fail_step = UINT32_MAX;
#endif
	return (NULL);
}
