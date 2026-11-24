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
 * erx_dom_principal_check against those before it, and the apps row's max
 * app entries follow them, placed from the app template (boot_apps), so
 * the principal and held tables have room for both; each configured row
 * takes its limits from its limits record and that record's runtime-limits
 * profile, and the rows stay in the manifest's table order, since a
 * record's origin names its row there. The files are judged one entry at a
 * time by erx_dom_boot_image from the bytes that start the entry.
 *
 * The device catalogue is the manifest's device table, entry for entry,
 * each entry placed on its unit's holder; the view is refused unless the
 * placement gives every unit whole to one holder (boot_devices), so
 * nothing builds a domain from a placement the view did not admit. Each
 * PCIe host bridge row has a catalogue beside it (boot_bridges), which the
 * root joins to the tree's facts (erx_dom_view_bridge) and the PCIe
 * domain's reports fill under the library's lock (erx_dom_lib_pci_report),
 * the view's one table written after the boot outside a domain's plan. The
 * firmware request records are kept as the manifest has them (boot_firmware),
 * for the firmware entries to resolve a device's row from. Each
 * configured row and session template must leave room in its boot page's
 * strings for what the library adds to its own words (boot_strings_fit).
 * The service and facet rows are carried for the domain service
 * (boot_services), each server a configured row or the system domain, and
 * each grantee the system domain, a configured row or a session template,
 * with each facet's parameters checked against what its service declares.
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
#include "liberx/backend/core/boot_manifest.h"

/*
 * Each domain's handle table. The manifest names no size for it; this is
 * what a domain's runtime and its connections use, with room to spare,
 * and its ERX_CODE_OBJECTS_MAX code objects' copies beside them.
 */
#define BOOT_CAP_LIMIT	64u
_Static_assert(ERX_CODE_OBJECTS_MAX <= BOOT_CAP_LIMIT / 4, "a session's code objects leave most of its table");

static bool	boot_place(size_t *, size_t, size_t, uint32_t, size_t *);
static bool	boot_limits(const erx_manifest_view_t *, uint32_t, erx_runtime_limits_t *);
static uint32_t	boot_apps_max(const erx_manifest_view_t *);
static const char *boot_principals(erx_dom_lib_t *, const erx_manifest_view_t *,
		    const erx_dom_boot_tables_t *);
static const char *boot_apps(erx_dom_lib_t *, const erx_manifest_view_t *);
static const char *boot_app_grants(const erx_dom_view_t *, const erx_manifest_view_t *);
static bool	boot_app_grant(const erx_dom_view_t *, uint32_t, uint32_t, uint32_t);
static bool	boot_app_holds(const erx_dom_view_t *, uint32_t, uint32_t);
static bool	boot_app_names(const erx_manifest_view_t *, const erx_mf_apps_t *, uint32_t);
static bool	boot_app_tree_grant(const erx_dom_view_t *, uint32_t, uint32_t, const uint8_t *, size_t);
static bool	boot_pages(uint64_t, uint64_t, erx_dom_range_t *);
static bool	boot_compatible_is(const erx_manifest_view_t *, const erx_mf_device_t *, const char *);
static bool	boot_reach(const erx_dom_device_entry_t *, erx_dom_range_t *);
static bool	boot_pages_meet(const erx_dom_device_entry_t *, const erx_dom_device_entry_t *);
static bool	boot_lines_meet(const erx_dom_device_entry_t *, const erx_dom_device_entry_t *);
static const char *boot_units(const erx_manifest_view_t *, erx_dom_device_entry_t *);
static const char *boot_devices(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_device_entry_t *, erx_dom_device_t *);
static uint32_t	boot_bridges_count(const erx_manifest_view_t *);
static bool	boot_is_bridge(const erx_mf_device_t *);
static const char *boot_bridges(erx_dom_view_t *, const erx_manifest_view_t *, erx_dom_pci_bridge_t *);
static const char *boot_firmware(erx_dom_view_t *, const erx_manifest_view_t *, erx_mf_firmware_request_t *);
static bool	boot_strings_fit(uint64_t, uint64_t, uint32_t, uint32_t, bool, bool);
static bool	boot_env_names_display(const char *, uint32_t);
static bool	boot_env_sets(const char *, uint32_t, const char *);
static const char *boot_display(const erx_manifest_view_t *, uint32_t, const char *, uint32_t,
		    erx_dom_display_t *);
static const char *boot_places(erx_dom_configured_t *, uint32_t, const erx_manifest_view_t *);
static const char *boot_system_image(erx_dom_lib_t *, const erx_manifest_view_t *);
static const char *boot_drives(const erx_manifest_view_t *, erx_dom_device_entry_t *, uint32_t);
static const char *boot_configured(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_configured_t *, uint32_t);
static const char *boot_templates(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_template_t *);
static const char *boot_services(erx_dom_view_t *, const erx_manifest_view_t *,
		    erx_dom_service_t *, erx_dom_facet_t *, const erx_service_operation_t **,
		    erx_dom_parameter_t *);
static const char *boot_facet_operations(const erx_manifest_view_t *, uint32_t first, uint32_t count,
		    const erx_dom_service_t *, const erx_service_operation_t **);
static const char *boot_parameter(const erx_mf_parameter_t *, const erx_service_parameter_t *,
		    const uint8_t *, erx_dom_parameter_t *);
static bool boot_set_follows(const erx_dom_parameter_t *, const erx_dom_parameter_t *);
static const char *boot_facet_parameters(const erx_manifest_view_t *, uint32_t first, uint32_t count,
		    uint32_t interface, erx_dom_parameter_t *);
static const char *boot_facet_grantee(const erx_dom_view_t *, const erx_mf_facet_t *,
		    const erx_dom_service_t *);
static bool	boot_facet_repeats(const erx_dom_view_t *, const erx_dom_facet_t *, uint32_t);

erx_dom_boot_sizes_t
erx_dom_view_sizes(const erx_manifest_view_t *manifest, uint32_t nfiles)
{
	return ((erx_dom_boot_sizes_t){ .max_domains = manifest->header.max_domains,
	    .max_connections = manifest->header.max_connections,
	    .nprincipals = manifest->header.principals.count + boot_apps_max(manifest),
	    .nconfigured = manifest->header.domains.count,
	    .ntemplates = manifest->header.sessions.count, .nfiles = nfiles,
	    .ndevices = manifest->header.devices.count,
	    .nservices = manifest->header.services.count,
	    .nfacets = manifest->header.facets.count,
	    .noperations = manifest->header.facet_operations.count,
	    .nparameters = manifest->header.facet_parameters.count,
	    .npci_bridges = boot_bridges_count(manifest),
	    .nfirmware = manifest->header.firmware_requests.count });
}

/* Whether a device row is a PCIe host bridge's: a device-tree row of role configuration. */
static bool
boot_is_bridge(const erx_mf_device_t *device)
{
	return (device->selector == ERX_MF_SELECTOR_DT && device->role == ERX_MF_DEVICE_ROLE_CONFIGURATION);
}

/* The manifest's PCIe host bridge rows; a row the reader cannot read counts none, and boot_bridges refuses it. */
static uint32_t
boot_bridges_count(const erx_manifest_view_t *manifest)
{
	erx_mf_device_t device;
	uint32_t count = 0;

	for (uint32_t index = 0; index < manifest->header.devices.count; index++)
		count += erx_manifest_devices_at(manifest, index, &device) && boot_is_bridge(&device) ? 1 : 0;
	return (count);
}

/*
 * The apps row's max, the app entries the view places after the
 * principals (boot_apps), or 0 for a manifest with no apps row. The
 * reader bounds the row's max to apps_max_limit, so the principal table's
 * size cannot overflow.
 */
static uint32_t
boot_apps_max(const erx_manifest_view_t *manifest)
{
	erx_mf_apps_t row;

	return (manifest->header.apps.count == 1 && erx_manifest_apps_at(manifest, 0, &row) ? row.max : 0);
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
	    !BOOT_PLACE(code, sizes->max_domains) ||
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
	    !BOOT_PLACE(facets, sizes->nfacets) ||
	    !BOOT_PLACE(operations, sizes->noperations) ||
	    !BOOT_PLACE(parameters, sizes->nparameters) ||
	    !BOOT_PLACE(pci_bridges, sizes->npci_bridges) ||
	    !BOOT_PLACE(firmware, sizes->nfirmware))
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

/*
 * The pages an entry may reach: a framebuffer row's window, which the tree
 * places its framebuffer in later, and any other row's register pages.
 * False for an entry with neither, a PCIe function's.
 */
static bool
boot_reach(const erx_dom_device_entry_t *entry, erx_dom_range_t *pages)
{
	if (entry->role == ERX_MF_DEVICE_ROLE_FRAMEBUFFER)
		*pages = entry->window;
	else if (entry->nranges != 0)
		*pages = entry->ranges[0];
	else
		return (false);
	return (true);
}

/* Whether two entries may reach a page in common (boot_reach). */
static bool
boot_pages_meet(const erx_dom_device_entry_t *a, const erx_dom_device_entry_t *b)
{
	erx_dom_range_t x, y;

	return (boot_reach(a, &x) && boot_reach(b, &y) &&
	    x.base < y.base + y.size && y.base < x.base + x.size);
}

/*
 * Whether two entries name one interrupt line; an entry with no line, a framebuffer's, a
 * device-tree row's whose line is 0 or a PCIe function's that is at no closed bridge's
 * place, shares none.
 */
static bool
boot_lines_meet(const erx_dom_device_entry_t *a, const erx_dom_device_entry_t *b)
{
	for (uint32_t x = 0; x < a->nlines; x++) {
		for (uint32_t y = 0; y < b->nlines; y++) {
			if (a->lines[x] == b->lines[y])
				return (true);
		}
	}
	return (false);
}

/* Whether a device row's compatible string is text. The reader checked it against the string table. */
static bool
boot_compatible_is(const erx_manifest_view_t *manifest, const erx_mf_device_t *device, const char *text)
{
	const char *compatible = (const char *)manifest->bytes + manifest->header.strings.offset +
	    device->compatible.offset;

	return (strlen(text) == device->compatible.length && memcmp(text, compatible, device->compatible.length) == 0);
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
	for (size_t at = 0; at < ERX_DEVICE_KINDS_COUNT; at++) {
		const erx_device_kind_t *kind = &erx_device_kinds[at];

		if (kind->role == device->role && boot_compatible_is(manifest, device, kind->compatible))
			return (kind);
	}
	return (NULL);
}

/*
 * A PCIe function's entry (docs/design-usb.md, "The Phase 1 part"): its kind
 * by its identity, the row's role and compatible string as a device-tree
 * row's is, and its position, the device-tree row of role configuration
 * whose path its row names as its bridge, and its place on that bridge.
 * The manifest check proves the bridge a placed PCIe bridge; a row whose
 * bridge names none is refused all the same, so every function's entry
 * names its bridge's. The reader bounds its bus to a PCIe bus number. A
 * function of no kind is held, not driven, so no give makes its memory.
 */
static const char *
boot_function(const erx_manifest_view_t *manifest, const erx_mf_device_t *device, erx_dom_device_entry_t *entry)
{
	const char *const strings = (const char *)manifest->bytes + manifest->header.strings.offset;
	const erx_device_kind_t *kind = boot_kind(manifest, device);
	erx_mf_device_t bridge;

	entry->bridge = ERX_MF_NONE;
	for (uint32_t index = 0; index < manifest->header.devices.count && entry->bridge == ERX_MF_NONE; index++) {
		if (!erx_manifest_devices_at(manifest, index, &bridge))
			return ("manifest: a device row the reader cannot read");
		if (boot_is_bridge(&bridge) &&
		    bridge.path.length == device->bridge.length &&
		    memcmp(strings + bridge.path.offset, strings + device->bridge.offset, bridge.path.length) == 0)
			entry->bridge = index;
	}
	if (entry->bridge == ERX_MF_NONE)
		return ("manifest: a PCIe function's bridge names no PCIe bridge row");
	entry->bus = (uint8_t)device->bus;
	entry->device = device->device;
	entry->function = device->function;
	entry->dma_limit = device->dma_limit;
	if (kind == NULL && entry->memory != 0)
		return ("manifest: a device of a kind no runtime drives has DMA memory");
	if (kind != NULL) {
		entry->role_word = kind->role_word;
		entry->peripheral = kind->peripheral;
		entry->compatible = kind->compatible;
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
 * line; a PCIe function has its kind and position (boot_function), no
 * window, since its report gives its BARs, and a line only at a closed
 * bridge's place. Units are closed under
 * sharing a register page and sharing an
 * interrupt line (docs/design-shared-devices.md, "The unit rule"), since a
 * page has at most one MMIO object and a line one IRQ object: devices
 * whose pages meet or that name one line are one unit, so the manifest
 * must have them in one unit row, which has one holder. A unit split
 * across two rows, two holders on one page or one line included, refuses
 * the view. So does a device marked confined: the Fiasco backend's catalogue
 * lists no IOMMU stream, and a confined device is given only on one; and
 * DMA memory that is not whole pages, or of a device-tree row of no kind,
 * which no give makes. Devices of one unit may share pages and lines on
 * any row: a configured row's creation gives the unit whole, one window
 * over each page run and one IRQ object for each line, which every record
 * of the run or the line names (erx_dom_plan_unit_give).
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
		if (device.selector == ERX_MF_SELECTOR_DT && device.role == ERX_MF_DEVICE_ROLE_FRAMEBUFFER) {
			/* No range and no line until the tree places the framebuffer (erx/dom.h). */
			if (!boot_pages(device.base, device.size, &entry->window))
				return ("manifest: a framebuffer's window is empty or wraps");
			if (entry->memory != 0 || !boot_compatible_is(manifest, &device, ERX_FRAMEBUFFER_COMPATIBLE))
				return ("manifest: a framebuffer row has DMA memory or is not a simple-framebuffer");
			entry->path = (const char *)manifest->bytes + manifest->header.strings.offset + device.path.offset;
			entry->path_len = device.path.length;
		} else if (device.selector == ERX_MF_SELECTOR_DT) {
			if (!boot_pages(device.base, device.size, &entry->ranges[0]))
				return ("manifest: a device's register window is empty or wraps");
			entry->nranges = 1;
			entry->offset = device.base - entry->ranges[0].base;
			entry->size = device.size;
			entry->clock = device.clock;
			entry->power_line = device.power_off_ms != 0;
			/* Line 0 is no line: the node raises no interrupt (docs/design-abi.md). */
			entry->nlines = device.line != 0 ? 1 : 0;
			entry->lines[0] = device.line;
			/* The reader checked the path against the string table. */
			entry->path = (const char *)manifest->bytes + manifest->header.strings.offset + device.path.offset;
			entry->path_len = device.path.length;
			kind = boot_kind(manifest, &device);
			/* A device of no kind is held, not driven, so no give makes its memory. */
			if (kind == NULL && entry->memory != 0)
				return ("manifest: a device of a kind no runtime drives has DMA memory");
			/* A driven device's path is its record's PATH, so its give never fails for it. */
			if (kind != NULL && !erx_boot_device_path_valid((erx_boot_words_t){ entry->path, entry->path_len }))
				return ("manifest: a driven device's path is not a node path its record holds");
			if (kind != NULL) {
				entry->role_word = kind->role_word;
				entry->peripheral = kind->peripheral;
				entry->compatible = kind->compatible;
			}
		} else {
			/* A function at a closed bridge's place names the INTx line its
			 * bridge routes for the place's pin, which joins the line
			 * relation as a device-tree line does; any other names none
			 * (docs/design-pcie.md, "The closed bus"). */
			entry->nlines = device.line != 0 ? 1 : 0;
			entry->lines[0] = device.line;
			if ((reason = boot_function(manifest, &device, entry)) != NULL)
				return (reason);
		}
		entry->selector = device.selector;
		records[index] = (erx_dom_device_t){ .index = index, .resource = { ERX_CAP_NULL },
		    .dma = { ERX_CAP_NULL }, .memory = { ERX_CAP_NULL } };
		for (uint32_t at = 0; at < ERX_DOM_UNIT_WINDOWS_MAX; at++)
			records[index].windows[at] = (erx_cap_t){ ERX_CAP_NULL };
		for (uint32_t at = 0; at < ERX_DOM_UNIT_LINES_MAX; at++)
			records[index].irqs[at] = (erx_cap_t){ ERX_CAP_NULL };
	}
	for (uint32_t a = 0; a < count; a++) {
		for (uint32_t b = a + 1; b < count; b++) {
			const bool page = boot_pages_meet(&entries[a], &entries[b]);

			if (!page && !boot_lines_meet(&entries[a], &entries[b]))
				continue;
			/* Within a unit a give makes one window per page run and one
			 * IRQ object per line (erx_dom_plan_unit_give). */
			if (entries[a].unit != entries[b].unit)
				return (page ? "manifest: devices that share a register page are in two units" :
				    "manifest: devices that share an interrupt line are in two units");
		}
	}
	view->ndevices = count;
	return (boot_drives(manifest, entries, count));
}

/*
 * Each PCIe host bridge row's catalogue (erx/dom.h, docs/design-pcie.md,
 * "Records"), in device row order: its record's index the row, its flags
 * the row's closed mark, and its places the places table's span the row
 * names, with no layouts. Its buses and windows are the tree's, which the
 * root joins later (erx_dom_view_bridge), so until then they are zero and
 * no report places a BAR. A row naming more places than a bridge's record
 * holds refuses the view.
 */
static const char *
boot_bridges(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_pci_bridge_t *bridges)
{
	erx_dom_pci_bridge_t *bridge;
	erx_mf_device_t device;
	uint32_t count = 0, first;

	view->pci_bridges = bridges;
	view->npci_bridges = 0;
	for (uint32_t index = 0; index < manifest->header.devices.count; index++) {
		if (!erx_manifest_devices_at(manifest, index, &device))
			return ("manifest: a device row the reader cannot read");
		if (!boot_is_bridge(&device))
			continue;
		if (device.places.count > ERX_PCIE_CLOSED_MAX)
			return ("manifest: a PCIe bridge row lists more places than its record holds");
		/* A span is the byte offset of its first row; the reader proved the
		 * spans a partition of the places table. */
		first = (device.places.offset - manifest->header.places.offset) / ERX_PCIE_PLACE_SIZE;
		bridge = &bridges[count++];
		*bridge = (erx_dom_pci_bridge_t){ .facts = { .index = index,
		    .flags = (device.flags & ERX_MF_DEVICE_CLOSED) != 0 ? ERX_PCIE_BRIDGE_CLOSED : 0 } };
		for (uint32_t at = 0; at < device.places.count; at++) {
			if (!erx_manifest_places_at(manifest, first + at, &bridge->facts.places[at]))
				return ("manifest: a PCIe bridge's place the reader cannot read");
		}
	}
	view->npci_bridges = count;
	return (NULL);
}

/*
 * The manifest's firmware request records, record for record: the reader checked each
 * device index against the device table and each tag against fw_tag.
 */
static const char *
boot_firmware(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_mf_firmware_request_t *records)
{
	view->firmware = records;
	view->nfirmware = 0;
	for (uint32_t index = 0; index < manifest->header.firmware_requests.count; index++) {
		if (!erx_manifest_firmware_requests_at(manifest, index, &records[index]))
			return ("manifest: a firmware request the reader cannot read");
	}
	view->nfirmware = manifest->header.firmware_requests.count;
	return (NULL);
}

void
erx_dom_view_bridge(erx_dom_pci_bridge_t *bridge, const erx_pcie_bridge_t *tree, erx_dt_bridge_status_t status)
{
	const bool known = status == ERX_DT_BRIDGE_OK;

	bridge->facts.bus_first = known ? tree->bus_first : 1;
	bridge->facts.bus_last = known ? tree->bus_last : 0;
	memcpy(bridge->facts.windows, tree->windows, sizeof(bridge->facts.windows));
	memcpy(bridge->facts.inbound, tree->inbound, sizeof(bridge->facts.inbound));
	if (!known) {
		memset(bridge->facts.windows, 0, sizeof(bridge->facts.windows));
		memset(bridge->facts.inbound, 0, sizeof(bridge->facts.inbound));
	}
}

/* The catalogue of the host bridge of device row bridge, or NULL for a row with none. */
static erx_dom_pci_bridge_t *
lib_pci_bridge(erx_dom_lib_t *lib, uint32_t bridge)
{
	for (uint32_t at = 0; at < lib->view.npci_bridges; at++) {
		if (lib->pci_bridges[at].facts.index == bridge)
			return (&lib->pci_bridges[at]);
	}
	return (NULL);
}

erx_status_t
erx_dom_lib_pci_report(erx_dom_lib_t *lib, uint32_t bridge, const erx_dom_pci_record_t *records, uint32_t count,
    erx_dom_pci_refusal_t *refusal)
{
	erx_dom_pci_bridge_t *const held = lib_pci_bridge(lib, bridge);

	if (held == NULL) {
		*refusal = (erx_dom_pci_refusal_t){ .record = count, .field = "bridge" };
		return (ERX_EINVAL);
	}
	return (erx_dom_pci_report(held, lib->view.devices, lib->view.ndevices, records, count, refusal));
}

erx_status_t
erx_dom_lib_pci_mode(erx_dom_lib_t *lib, uint32_t index, uint32_t mode)
{
	const erx_pcie_bridge_t *facts;
	erx_dom_device_t *record;

	if (index >= lib->view.ndevices || lib->view.devices[index].selector != ERX_MF_SELECTOR_PCI ||
	    mode > UINT8_MAX || erx_pcie_mode_name((uint8_t)mode) == NULL)
		return (ERX_EINVAL);
	record = &lib->device_records[index];
	/* A raise only for a function a living domain holds and its catalogue gives. */
	if (mode != ERX_PCIE_MODE_OFF && (record->holder == 0 ||
	    erx_dom_pci_given(lib->pci_bridges, lib->view.npci_bridges, &lib->view.devices[index], &facts) == NULL))
		return (ERX_EINVAL);
	record->setting.mode = (uint8_t)mode;
	return (ERX_OK);
}

void
erx_dom_lib_pci_firmware(erx_dom_lib_t *lib, uint32_t bridge, erx_status_t status)
{
	erx_dom_pci_bridge_t *const held = lib_pci_bridge(lib, bridge);

	if (held != NULL)
		erx_dom_pci_firmware(held, status);
}

erx_status_t
erx_dom_lib_pci_answered(erx_dom_lib_t *lib, uint32_t domain)
{
	erx_status_t status = ERX_EINVAL;

	if (domain == 0)
		return (ERX_EINVAL);
	for (uint32_t at = 0; at < lib->view.npci_bridges; at++) {
		erx_dom_pci_bridge_t *const bridge = &lib->pci_bridges[at];

		if (lib->device_records[bridge->facts.index].holder == domain) {
			bridge->answered = domain;
			status = ERX_OK;
		}
	}
	return (status);
}

/* A framebuffer record takes no more room than the given record the reserve counts for it. */
_Static_assert(ERX_BOOT_FRAMEBUFFER_WORDS_MAX <= ERX_BOOT_GIVEN_WORDS_MAX, "a framebuffer record fits a given record's room");

/*
 * Whether a domain's boot page's strings hold its arguments and
 * environment beside what the library writes there (docs/design-fiasco.md,
 * "Boot information"): its own node name and the system node's, -erx_record
 * build, a -erx_record given record per device of a kind it holds, a -erx_record drive record per drive
 * on its devices (boot_drives), -erx_record boot when it holds a
 * block device of a kind, and -erx_record system_image when it holds the system
 * window (system_image). The reserve takes each at its longest, so a row the view
 * admits never fails its creation for its strings: a node name at
 * ERX_DOM_NODE_MAX, though the system node's is at most 71 bytes, and the
 * difference also covers the NUL the page adds to args or env that lack a
 * final one. No sum can wrap: each term is at most a u32 times a small
 * constant.
 */
static bool
boot_strings_fit(uint64_t args_len, uint64_t env_len, uint32_t records, uint32_t drives, bool block,
    bool system_image)
{
	const uint64_t reserve = 2u * (uint64_t)ERX_DOM_NODE_MAX + ERX_BOOT_BUILD_WORDS_MAX +
	    (uint64_t)records * ERX_BOOT_GIVEN_WORDS_MAX + (uint64_t)drives * ERX_BOOT_DRIVE_WORDS_MAX +
	    (block ? ERX_BOOT_PAIR_WORDS_MAX : 0) + (system_image ? ERX_BOOT_SYSTEM_IMAGE_WORDS_MAX : 0);

	return (args_len + env_len + reserve <= ERX_BOOT_STRINGS_MAX);
}

/*
 * Whether an environment of env_len bytes of NUL-terminated KEY=VALUE words
 * sets one of the keys a display domain's display record gives it
 * (ERX_DOM_DISPLAY_WORDS_MAX).
 */
static bool
boot_env_names_display(const char *env, uint32_t env_len)
{
	static const char *const keys[] = { ERX_DISPLAY_KEY_STRING, ERX_DISPLAY_POLICY_KEY_STRING,
	    ERX_DISPLAY_IDLE_DIM_KEY_STRING, ERX_DISPLAY_IDLE_OFF_KEY_STRING, ERX_DISPLAY_PALETTE_KEY_STRING };

	for (size_t key = 0; key < sizeof(keys) / sizeof(keys[0]); key++) {
		if (boot_env_sets(env, env_len, keys[key]))
			return (true);
	}
	return (false);
}

/* Whether an environment of env_len bytes of NUL-terminated KEY=VALUE words sets key. */
static bool
boot_env_sets(const char *env, uint32_t env_len, const char *key)
{
	const size_t length = strlen(key);
	uint32_t at = 0, end;

	while (at < env_len) {
		for (end = at; end < env_len && env[end] != '\0'; end++)
			continue;
		if (end - at > length && memcmp(env + at, key, length) == 0 && env[at + length] == '=')
			return (true);
		at = end + 1;
	}
	return (false);
}

/*
 * The display configured row `row` serves, or none: the display record of
 * the windows service whose server the row is (docs/design-display.md, "A
 * display's session"). The reader has checked each record's service index,
 * its policy and the service's name, and property 18 of
 * docs/design-system.md gives each windows service one record and its
 * server no other display; the view checks them again, as the copy's own,
 * so no domain's environment names two displays. A display domain whose
 * own environment (env_len bytes at env) sets one of its display's keys is
 * refused, so each key has one value. The walk is over every display
 * record for each row; a manifest has a display or two.
 */
static const char *
boot_display(const erx_manifest_view_t *manifest, uint32_t row, const char *env, uint32_t env_len,
      erx_dom_display_t *served)
{
	erx_mf_display_t display;
	erx_mf_service_t service;
	const char *strings;

	*served = (erx_dom_display_t){ .name = NULL };
	/* The reader checked every string against the string table; the manifest's bytes outlive the view. */
	strings = (const char *)manifest->bytes + manifest->header.strings.offset;
	for (uint32_t index = 0; index < manifest->header.displays.count; index++) {
		if (!erx_manifest_displays_at(manifest, index, &display) ||
		    !erx_manifest_services_at(manifest, display.service, &service))
			return ("manifest: a display record names no service");
		if (service.server != row)
			continue;
		if (served->name_len != 0)
			return ("manifest: a configured domain serves two displays");
		if (service.name.length == 0 || service.name.length > ERX_DOM_NAME_MAX)
			return ("manifest: a service's name is not 1 to 63 bytes");
		*served = (erx_dom_display_t){ .name = strings + service.name.offset,
		    .name_len = service.name.length, .policy = display.policy,
		    .idle_dim_s = display.idle_dim_s, .idle_off_s = display.idle_off_s,
		    .palette = display.palette };
	}
	if (served->name_len != 0 && boot_env_names_display(env, env_len))
		return ("manifest: a display domain's environment sets a key its display record gives it");
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

/*
 * Sets lib's system_image_holder, the configured row that holds the
 * manifest's system window, plus one, or 0 for a manifest with none; and
 * system_image, the manifest's row that the holder's boot page alone
 * carries as -erx_record system_image
 * (docs/design-fiasco.md, "The booted slot"). Property 8's rules across
 * these rows are the view's to judge, and the build runs it (property 12):
 * it refuses a second system window, a holder past the domains table and a
 * window without the row or the row without it, so the record has one row
 * to name and one holder or none; that the holder holds the block device is
 * the check's alone. It sets record_volume when the manifest holds a
 * record_volume window (docs/design-ssh.md, "Who publishes it"), and
 * refuses a second one and one held by anything but the system window's
 * holder, the system domain included, so the record names the window only
 * in the boot page of the domain that holds it.
 */
static const char *
boot_system_image(erx_dom_lib_t *lib, const erx_manifest_view_t *manifest)
{
	erx_mf_window_t window;
	uint32_t row = ERX_MF_NONE, volume_holder = ERX_MF_NONE;

	for (uint32_t index = 0; index < manifest->header.windows.count; index++) {
		if (!erx_manifest_windows_at(manifest, index, &window))
			return ("manifest: a window the reader cannot read");
		if (window.role == ERX_MF_WINDOW_ROLE_RECORD_VOLUME) {
			/* A configured holder, so ERX_MF_NONE stays the mark of none seen. */
			if (volume_holder != ERX_MF_NONE || window.holder >= manifest->header.domains.count)
				return ("manifest: more than one record_volume window, or one held by no configured domain");
			volume_holder = window.holder;
		}
		if (window.role != ERX_MF_WINDOW_ROLE_SYSTEM)
			continue;
		if (row != ERX_MF_NONE || window.holder >= manifest->header.domains.count)
			return ("manifest: more than one system window, or one held by no configured domain");
		row = window.holder;
	}
	if ((row == ERX_MF_NONE) != (manifest->header.system_image.count == 0) ||
	    (row != ERX_MF_NONE && !erx_manifest_system_image_at(manifest, 0, &lib->system_image)))
		return ("manifest: a system window without its system_image row, or the row without the window");
	if (volume_holder != ERX_MF_NONE && volume_holder != row)
		return ("manifest: a record_volume window not held by the system window's holder");
	lib->system_image_holder = row == ERX_MF_NONE ? 0 : row + 1;
	lib->record_volume = volume_holder != ERX_MF_NONE;
	return (NULL);
}

/*
 * Hangs each drive window on its device's entry, the first count of
 * entries (docs/design-fiasco.md, "Drive records"), in the window table's
 * order, so every give of the device writes its records and a domain
 * learns only the drives on what it holds. The window's holder, a
 * configured row, is the drive grant's grantee, the media domain, which
 * learns a drive through its grant and gets no record. The manifest check
 * holds each drive to a usb or block device, a number below mf_none and
 * the media domain as its holder, and a domain's devices to
 * ERX_DOM_DRIVES_MAX drives (boot_configured); a manifest past those is
 * refused, so every record a creation writes has its room and every grant
 * a grantee.
 */
static const char *
boot_drives(const erx_manifest_view_t *manifest, erx_dom_device_entry_t *entries, uint32_t count)
{
	erx_dom_device_entry_t *entry;
	erx_mf_window_t window;

	for (uint32_t at = 0; at < manifest->header.windows.count; at++) {
		if (!erx_manifest_windows_at(manifest, at, &window))
			return ("manifest: a window the reader cannot read");
		if (window.role != ERX_MF_WINDOW_ROLE_DRIVE)
			continue;
		if (window.device >= count)
			return ("manifest: a drive window names no device");
		entry = &entries[window.device];
		if ((entry->role != ERX_MF_DEVICE_ROLE_USB && entry->role != ERX_MF_DEVICE_ROLE_BLOCK) ||
		    window.drive == ERX_MF_NONE)
			return ("manifest: a drive window not on a usb or block device, or naming no drive");
		if (window.holder >= manifest->header.domains.count)
			return ("manifest: a drive window held by no configured domain");
		if (entry->ndrives == ERX_DOM_DRIVES_MAX)
			return ("manifest: a device carries more drives than its holder's boot page records");
		entry->drives[entry->ndrives++] = (erx_dom_drive_t){ .number = window.drive, .holder = window.holder };
	}
	return (NULL);
}

/*
 * Each configured-domain row, its limits resolved from its limits record and
 * its strings judged against the devices the catalogue places on it, so
 * it reads view->devices, which boot_devices builds first. Every device
 * on the row is given; only a driven one (erx_dom_entry_driven) gets a
 * record, -erx_record given or -erx_record framebuffer, and each drive on
 * the row's devices a -erx_record drive (boot_drives). The row
 * system_image_holder names, the system window's holder, gets -erx_record
 * system_image too.
 */
static const char *
boot_configured(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_configured_t *configured,
    uint32_t system_image_holder)
{
	erx_mf_domain_t domain;
	erx_mf_limits_t profile;
	erx_dom_configured_t *row;
	const char *strings, *reason;
	uint32_t held, records, drives;
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
		    .spaces = profile.spaces, .lane = profile.lane, .connections = profile.connections,
		    .band = profile.band };
		if (!boot_limits(manifest, domain.limits, &row->runtime_limits))
			return ("manifest: a configured domain names no limits record");
		if (domain.name.length == 0 || domain.name.length > ERX_DOM_NAME_MAX)
			return ("manifest: a configured domain's name is not 1 to 63 bytes");
		held = 0;
		records = 0;
		drives = 0;
		block = false;
		for (uint32_t device = 0; device < view->ndevices; device++) {
			if (view->devices[device].row != index)
				continue;
			held++;
			drives += view->devices[device].ndrives;
			if (!erx_dom_entry_driven(&view->devices[device]))
				continue;
			records++;
			block = block || view->devices[device].role == ERX_MF_DEVICE_ROLE_BLOCK;
		}
		if (held > ERX_DOM_DEVICES_MAX)
			return ("manifest: a configured domain holds more devices than its creation gives");
		if (drives > ERX_DOM_DRIVES_MAX)
			return ("manifest: a configured domain's devices carry more drives than its boot page records");
		/* The reader checked every string against the string table; the manifest's bytes outlive the view. */
		strings = (const char *)manifest->bytes + manifest->header.strings.offset;
		if ((reason = boot_display(manifest, index, strings + domain.env.offset, domain.env.length,
		    &row->display)) != NULL)
			return (reason);
		if (!boot_strings_fit(domain.args.length, domain.env.length +
		    (row->display.name_len != 0 ? ERX_DOM_DISPLAY_WORDS_MAX : 0), records, drives, block,
		    index + 1 == system_image_holder))
			return ("manifest: a configured domain's arguments and environment leave the boot page's strings "
			    "no reserve for its node names, device records and display");
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
		if ((session.principal != ERX_MF_NONE && session.principal >= manifest->header.principals.count) ||
		    !erx_manifest_limits_at(manifest, session.limits, &profile))
			return ("manifest: a session template names no principal or limits record");
		/*
		 * The principal's number, from 1, as the view numbers principals;
		 * 0 for the app template, which names none and comes last
		 * (boot_apps).
		 */
		principal = session.principal == ERX_MF_NONE ? 0 : session.principal + 1;
		if (index > 0 && (templates[index - 1].principal == 0 ||
		    (principal != 0 && principal <= templates[index - 1].principal)))
			return ("manifest: the session templates are not one per principal in principal order, "
			    "with the app template last");
		/*
		 * A session's principal and default display are the words its start
		 * adds after the template's environment (erx_dom_plan_session), which
		 * must neither be shadowed by the template's own nor overrun the
		 * strings. The reader's string class has ended the template's last
		 * word.
		 */
		if (boot_env_sets(strings + session.env.offset, session.env.length, ERX_PRINCIPAL_KEY_STRING) ||
		    boot_env_sets(strings + session.env.offset, session.env.length, ERX_DISPLAY_KEY_STRING))
			return ("manifest: a session template's environment sets a variable its start gives it");
		if (!boot_strings_fit(session.args.length, session.env.length + ERX_DOM_SESSION_WORDS_MAX, 0, 0, false, false))
			return ("manifest: a session template's arguments and environment leave the boot page's strings "
			    "no reserve for its node names, principal and display");
		templates[index] = (erx_dom_template_t){ .principal = principal,
		    .flags = (profile.flags & ERX_MF_LIMITS_SPACES) != 0 ? ERX_DOM_SPACES : 0,
		    .memory = profile.memory, .outer = profile.outer, .grant = profile.grant,
		    .spaces = profile.spaces, .lane = profile.lane, .connections = profile.connections,
		    .band = profile.band, .release = session.release,
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
 * The apps row's app entries (docs/design-packaging.md, "An app's
 * principal"), placed after the manifest's principals by
 * erx_dom_apps_place from the row's budget and max and the app template,
 * the session template that names no principal, which boot_templates
 * keeps last. The row and the template come together: the build derives
 * the template from the row, so a manifest with one and not the other is
 * refused, and the view holds app entries exactly when the manifest has
 * an apps row. Each entry starts with no handle, as a principal does.
 */
static const char *
boot_apps(erx_dom_lib_t *lib, const erx_manifest_view_t *manifest)
{
	erx_dom_view_t *view = &lib->view;
	const bool has_app_template = view->ntemplates != 0 && view->templates[view->ntemplates - 1].principal == 0;
	erx_mf_apps_t row;

	if (manifest->header.apps.count == 0)
		return (has_app_template ? "manifest: an app template with no apps row" : NULL);
	if (!erx_manifest_apps_at(manifest, 0, &row))
		return ("manifest: an apps row the reader cannot read");
	/* boot_templates keeps the one template naming no principal last; the row must name that one. */
	if (!has_app_template || row.app_template != view->ntemplates - 1)
		return ("manifest: an apps row whose app_template is not the session template naming no principal");
	/* The principal and held tables hold boot_apps_max entries past the principals: place those. */
	if (erx_dom_apps_place(view, row.app_template, row.memory, boot_apps_max(manifest)) != ERX_OK)
		return ("manifest: the domain library refuses the app entries");
	for (uint32_t entry = 0; entry < view->apps.max; entry++)
		lib->held.principals[view->apps.first - 1 + entry] = (erx_dom_principal_held_t){ UINT64_MAX, UINT64_MAX };
	return (NULL);
}

/*
 * The app template's facet rows the apps row names by index
 * (docs/design-packaging.md, "The template's rows by index"), checked
 * once here so that every later reader of the indices, erx_pkg_manifest
 * among them, takes them as the build packed them: packages_facet grants
 * the template the service named packages_service; system_facet grants it
 * the service named system_service; each app_services row's facet grants
 * the template that row's service; and the template
 * holds no facet row besides those, each named once, so an app's session
 * reaches only the services the apps row names and admission sees each of
 * them once. The reader checked each index against its table; boot_apps
 * checked app_template.
 */
static const char *
boot_app_grants(const erx_dom_view_t *view, const erx_manifest_view_t *manifest)
{
	static const uint8_t packages[] = ERX_PACKAGES_SERVICE_BYTES;
	static const uint8_t system[] = ERX_SYSTEM_SERVICE_BYTES;
	erx_mf_app_service_t granted;
	erx_mf_apps_t row;
	uint32_t held;

	if (manifest->header.apps.count == 0)
		return (NULL);
	if (!erx_manifest_apps_at(manifest, 0, &row))
		return ("manifest: an apps row the reader cannot read");
	if (!boot_app_tree_grant(view, row.app_template, row.packages_facet, packages, sizeof(packages)))
		return ("manifest: the apps row's packages_facet is not the app template's grant of packages_service");
	if (!boot_app_tree_grant(view, row.app_template, row.system_facet, system, sizeof(system)))
		return ("manifest: the apps row's system_facet is not the app template's grant of system_service");
	/* The one apps row's services span partitions app_services, so it holds every row. */
	for (uint32_t index = 0; index < manifest->header.app_services.count; index++) {
		if (!erx_manifest_app_services_at(manifest, index, &granted))
			return ("manifest: an app_services row the reader cannot read");
		if (!boot_app_grant(view, row.app_template, granted.facet, granted.service))
			return ("manifest: an app_services row's facet is not the app template's grant of its service");
	}
	/*
	 * Every app's session holds what the template holds: the named rows and
	 * nothing else, each named once, so the template holds exactly its
	 * packages row, its system row and app_services.count facets.
	 */
	held = 0;
	for (uint32_t facet = 0; facet < view->nfacets; facet++) {
		if (!boot_app_holds(view, row.app_template, facet))
			continue;
		if (!boot_app_names(manifest, &row, facet))
			return ("manifest: the app template holds a facet the apps row does not name");
		held++;
	}
	if (held != 2 + manifest->header.app_services.count)
		return ("manifest: the apps row names one of the app template's facets twice");
	return (NULL);
}

/*
 * Whether the apps row names facet row facet: its packages_facet, its
 * system_facet or an app_services row's facet.
 */
static bool
boot_app_names(const erx_manifest_view_t *manifest, const erx_mf_apps_t *row, uint32_t facet)
{
	erx_mf_app_service_t granted;

	if (row->packages_facet == facet || row->system_facet == facet)
		return (true);
	for (uint32_t index = 0; index < manifest->header.app_services.count; index++)
		if (erx_manifest_app_services_at(manifest, index, &granted) && granted.facet == facet)
			return (true);
	return (false);
}

/*
 * Whether facet row facet grants session template template the service
 * of the name name, len bytes.
 */
static bool
boot_app_tree_grant(const erx_dom_view_t *view, uint32_t template, uint32_t facet, const uint8_t *name, size_t len)
{
	const erx_dom_service_t *service = &view->services[view->facets[facet].service];

	return (boot_app_holds(view, template, facet) && service->name_len == len && memcmp(service->name, name, len) == 0);
}

/* Whether facet row facet grants session template template the service service. */
static bool
boot_app_grant(const erx_dom_view_t *view, uint32_t template, uint32_t facet, uint32_t service)
{
	return (boot_app_holds(view, template, facet) && view->facets[facet].service == service);
}

/* Whether facet row facet is granted to session template template. */
static bool
boot_app_holds(const erx_dom_view_t *view, uint32_t template, uint32_t facet)
{
	const erx_dom_facet_t *row = &view->facets[facet];

	return (row->grantee_kind == ERX_MF_GRANTEE_SESSION && row->grantee == template);
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
 * Why row is not a value of parameter, or NULL with the value in *value:
 * it is of the declared kind and within the declared bound, a member
 * kind's bound being exactly its members (erx_service_parameter_t), and
 * text or bytes point into strings, the manifest's string table. A device
 * reference is its row's index in the device table, which the reader has
 * checked against that table (abi/manifest.txt), and the view's devices
 * are that table's rows in order. A domain or principal reference, which
 * nothing carries to the domain service, is refused, as the packer
 * refuses one. The reader has checked a boolean's value and each string
 * against the string table.
 */
static const char *
boot_parameter(const erx_mf_parameter_t *row, const erx_service_parameter_t *parameter, const uint8_t *strings,
    erx_dom_parameter_t *value)
{
	bool within;

	if (row->kind != parameter->kind)
		return ("manifest: a facet parameter is not of its declared kind");
	*value = (erx_dom_parameter_t){ .declared = parameter, .scalar = row->scalar };
	switch (row->kind) {
	case ERX_MF_PARAMETER_U64:
	case ERX_MF_PARAMETER_BOOLEAN:
	case ERX_MF_PARAMETER_MEMBER:
		within = row->scalar >= parameter->minimum && row->scalar <= parameter->maximum;
		break;
	case ERX_MF_PARAMETER_I64:
		within = (int64_t)row->scalar >= (int64_t)parameter->minimum &&
		    (int64_t)row->scalar <= (int64_t)parameter->maximum;
		break;
	case ERX_MF_PARAMETER_IDENTIFIER:
	case ERX_MF_PARAMETER_NAMESPACE_PATH:
	case ERX_MF_PARAMETER_BYTES:
		within = row->bytes.length <= parameter->maximum;
		value->bytes = strings + row->bytes.offset;
		value->bytes_len = row->bytes.length;
		break;
	case ERX_MF_PARAMETER_DEVICE:
		within = true;
		value->index = row->index;
		break;
	default:
		return ("manifest: a facet parameter is a reference, which the boot does not carry");
	}
	return (within ? NULL : "manifest: a facet parameter is outside its declared bound");
}

/*
 * Checks a facet's count operation rows, from row first of the manifest's
 * operation table, into operations[0] to operations[count - 1], against
 * what its service's interface declares (erx_service_operations); the
 * reason it refuses them, or NULL. The rows are strictly ascending, as the
 * packer writes them, so one walk over the declarations, with a cursor on
 * the first row not yet matched, matches each row to its declaration and
 * leaves over only a row that is undeclared, repeated or out of order. On
 * Fiasco only the system domain's erx_facet checks a grant's
 * operations (docs/design-time.md, "On Fiasco"), so a facet of a service a
 * configured domain serves names none; a tree's interface declares none
 * (abi_contracts.rb).
 */
static const char *
boot_facet_operations(const erx_manifest_view_t *manifest, uint32_t first, uint32_t count,
    const erx_dom_service_t *service, const erx_service_operation_t **operations)
{
	const erx_service_operation_t *declared;
	erx_mf_operation_t row;
	size_t ndeclared;
	uint32_t matched = 0;

	if (count != 0 && service->server != ERX_MF_NONE)
		return ("manifest: a facet names operations of a service a configured domain serves");
	declared = erx_service_operations(service->interface, &ndeclared);
	for (size_t at = 0; at < ndeclared && matched < count; at++) {
		if (!erx_manifest_facet_operations_at(manifest, first + matched, &row))
			return ("manifest: a facet operation row the reader cannot read");
		if (row.operation == declared[at].number)
			operations[matched++] = &declared[at];
	}
	if (matched != count)
		return ("manifest: a facet operation is undeclared, stated twice or out of order");
	return (NULL);
}

/*
 * Whether value strictly follows before, the element of its set before it,
 * in the order a set is packed in (docs/design-abi.md, "Services, facets
 * and their parameter schemas"): a u64 by its value, an identifier
 * lexicographically over unsigned bytes, a name before every longer name it
 * begins. So no element follows itself. A set is of those two kinds alone
 * (abi_contracts.rb), and boot_parameter has checked that each element is
 * of its declaration's kind.
 */
static bool
boot_set_follows(const erx_dom_parameter_t *before, const erx_dom_parameter_t *value)
{
	uint32_t common;
	int order;

	if (value->declared->kind != ERX_MF_PARAMETER_IDENTIFIER)
		return (value->scalar > before->scalar);
	common = before->bytes_len < value->bytes_len ? before->bytes_len : value->bytes_len;
	order = memcmp(before->bytes, value->bytes, common);
	return (order < 0 || (order == 0 && before->bytes_len < value->bytes_len));
}

/*
 * Checks a facet's count parameter rows, from row first of the manifest's
 * parameter table, into parameters[0] to parameters[count - 1], against
 * what its service's interface declares (erx_service_parameters); the
 * reason it refuses them, or NULL. The rows follow the declarations'
 * number order, at most most rows a declaration, a set's elements in
 * strictly ascending order (boot_set_follows), as the packer writes them:
 * one walk over the declarations, with a cursor on the first row not yet
 * matched, checks each row of a declaration's key against it
 * (boot_parameter) and against the row before it, refuses a required
 * declaration with no row, and leaves over only a row that is
 * undeclared, past its declaration's most, repeated or out of order.
 */
static const char *
boot_facet_parameters(const erx_manifest_view_t *manifest, uint32_t first, uint32_t count, uint32_t interface,
    erx_dom_parameter_t *parameters)
{
	const uint8_t *strings = manifest->bytes + manifest->header.strings.offset;
	const erx_service_parameter_t *declared;
	erx_mf_parameter_t row;
	const char *reason;
	size_t ndeclared;
	uint32_t matched = 0, of;

	declared = erx_service_parameters(interface, &ndeclared);
	for (size_t at = 0; at < ndeclared; at++) {
		for (of = 0; of < declared[at].most && matched < count; of++, matched++) {
			if (!erx_manifest_facet_parameters_at(manifest, first + matched, &row))
				return ("manifest: a facet parameter row the reader cannot read");
			if (row.key != declared[at].number)
				break;
			if ((reason = boot_parameter(&row, &declared[at], strings, &parameters[matched])) != NULL)
				return (reason);
			if (of > 0 && !boot_set_follows(&parameters[matched - 1], &parameters[matched]))
				return ("manifest: a facet parameter set is unsorted or repeats a value");
		}
		if (of == 0 && declared[at].required)
			return ("manifest: a facet leaves out a parameter its service requires");
	}
	if (matched != count)
		return ("manifest: a facet parameter is undeclared, stated twice or out of order");
	return (NULL);
}

/*
 * The service and facet rows, which the domain service reads
 * (erx_domain_lib:configured/0), so it reads view->nconfigured, which
 * boot_configured and boot_templates set first. A server is a configured
 * row or ERX_MF_NONE, and a grantee the system domain, a configured row or
 * a session template; a facet is never granted to its service's own
 * server, a grantee takes one facet of a service name, and its operations
 * (boot_facet_operations) and parameters (boot_facet_parameters) are its
 * service's. The reader has checked every index and string
 * against its table.
 */
static const char *
boot_services(erx_dom_view_t *view, const erx_manifest_view_t *manifest, erx_dom_service_t *services,
    erx_dom_facet_t *facets, const erx_service_operation_t **operations, erx_dom_parameter_t *parameters)
{
	erx_mf_service_t service;
	erx_mf_facet_t facet;
	uint32_t first, named;
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
		/* A span's offset is in bytes; the reader checked that the spans partition the table. */
		named = (facet.operations.offset - manifest->header.facet_operations.offset) / ERX_MF_OPERATION_SIZE;
		if ((reason = boot_facet_operations(manifest, named, facet.operations.count,
		    &services[facet.service], &operations[named])) != NULL)
			return (reason);
		first = (facet.parameters.offset - manifest->header.facet_parameters.offset) / ERX_MF_PARAMETER_SIZE;
		if ((reason = boot_facet_parameters(manifest, first, facet.parameters.count,
		    services[facet.service].interface, &parameters[first])) != NULL)
			return (reason);
		facets[index] = (erx_dom_facet_t){ .grantee_kind = facet.grantee_kind,
		    .grantee = facet.grantee, .service = facet.service,
		    .max_request = facet.max_request, .in_flight = facet.in_flight,
		    .reductions = facet.reductions, .period_ns = facet.period_ns,
		    .max_heap_size = facet.max_heap_size, .queue = facet.queue,
		    .operations = &operations[named], .noperations = facet.operations.count,
		    .parameters = &parameters[first], .nparameters = facet.parameters.count };
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
	erx_mf_limits_t native;
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
	for (uint32_t index = 0; index < header->max_domains; index++)
		for (uint32_t obj = 0; obj < ERX_CODE_OBJECTS_MAX; obj++)
			tables->code[index].objects[obj] = ERX_CAP_NULL;
	lib->handles = tables->handles;
	lib->code = tables->code;
	lib->links = tables->links;
	lib->remains_held = tables->remains_held;
	lib->held.principals = tables->held;
	if ((reason = boot_principals(lib, manifest, tables)) != NULL ||
	    (reason = boot_devices(&lib->view, manifest, tables->devices, tables->device_records)) != NULL ||
	    (reason = boot_bridges(&lib->view, manifest, tables->pci_bridges)) != NULL ||
	    (reason = boot_firmware(&lib->view, manifest, tables->firmware)) != NULL ||
	    (reason = boot_system_image(lib, manifest)) != NULL ||
	    (reason = boot_configured(&lib->view, manifest, tables->configured, lib->system_image_holder)) != NULL ||
	    (reason = boot_templates(&lib->view, manifest, tables->templates)) != NULL ||
	    (reason = boot_apps(lib, manifest)) != NULL ||
	    (reason = boot_services(&lib->view, manifest, tables->services, tables->facets, tables->operations,
	    tables->parameters)) != NULL ||
	    (reason = boot_app_grants(&lib->view, manifest)) != NULL)
		return (reason);
	if (!boot_limits(manifest, header->native_limits, &lib->view.native_limits) ||
	    !erx_manifest_limits_at(manifest, header->native_limits, &native))
		return ("manifest: native_limits names no limits record");
	lib->view.native_band = native.band;
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
	lib->boot_timeout_s = header->boot_timeout_s;
	lib->cap_limit = BOOT_CAP_LIMIT;
	lib->device_records = tables->device_records;
	lib->pci_bridges = tables->pci_bridges;
#ifdef ERX_DOM_TEST_HOOKS
	lib->fail_step = UINT32_MAX;
#endif
	return (NULL);
}

bool
erx_dom_view_framebuffer(erx_dom_device_entry_t *entry, const erx_dt_framebuffer_t *fb, const char *format)
{
	const erx_dt_window_t window = { entry->window.base, entry->window.size };
	erx_boot_window_t pages;

	entry->framebuffer = *fb;
	entry->format = format;
	entry->nranges = 0;
	if (!erx_boot_framebuffer_place(fb, format, window, &pages))
		return (false);
	entry->ranges[0] = (erx_dom_range_t){ pages.base, pages.size };
	entry->nranges = 1;
	entry->offset = pages.offset;
	entry->size = fb->length;
	return (true);
}
