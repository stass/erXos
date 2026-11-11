/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The system manifest's generated C reader, which the root runs at boot over the
 * archive's manifest entry. What the reader accepts must keep every table in reach:
 * each row its header counts reads back, and the row one past the end does not.
 * The domain library's boot view (liberx/system/dom_boot_view.c) then reads every
 * manifest the reader accepts, as the root does next, and what it admits must keep
 * the placement and string rules it exists for (view_check).
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi_reader.h"
#include "erx/dom_lib.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/*
 * Reads a table's rows. A row within the count that does not read back means the reader
 * accepted a table it cannot serve, and so does a row past the count that does.
 */
#define MANIFEST_TABLE(view, table, type)					\
	do {									\
		type row;							\
										\
		for (size_t index = 0; index < (view)->header.table.count; index++) \
			if (!erx_manifest_##table##_at((view), index, &row))	\
				abort();					\
		if (erx_manifest_##table##_at((view), (view)->header.table.count, &row)) \
			abort();						\
	} while (0)

/* The tables a view of a manifest larger than this needs are not worth a run. */
#define VIEW_TABLES_MAX	((size_t)64 << 20)

/*
 * What a view the library admits holds: an entry per device row, each in one
 * unit and on that unit's holder, with a record of its own index; no two units
 * on one register page; each configured row's words with room for both
 * node names; and every service and facet row, each server and grantee a
 * configured row or the system domain, no facet granted to its own server,
 * no grantee taking two facets of one service name, and no facet naming an
 * operation or parameter, which the domain service would otherwise grant
 * unchecked.
 */
static void
view_check(const erx_manifest_view_t *view, const erx_dom_lib_t *lib)
{
	const erx_dom_view_t *dom = &lib->view;
	const erx_dom_device_entry_t *a, *b;
	const erx_dom_configured_t *row;
	const erx_dom_facet_t *facet;
	const erx_dom_service_t *a_service, *b_service;
	erx_mf_facet_t facet_row;
	erx_mf_unit_t unit;

	if (dom->ndevices != view->header.devices.count ||
	    dom->nservices != view->header.services.count || dom->nfacets != view->header.facets.count)
		abort();
	for (uint32_t index = 0; index < dom->nservices; index++)
		if (dom->services[index].server != ERX_MF_NONE && dom->services[index].server >= dom->nconfigured)
			abort();
	for (uint32_t index = 0; index < dom->nfacets; index++) {
		facet = &dom->facets[index];
		if (!erx_manifest_facets_at(view, index, &facet_row) || facet_row.operations.count != 0 ||
		    facet_row.parameters.count != 0 || facet->service >= dom->nservices ||
		    (facet->grantee != ERX_MF_NONE && facet->grantee >= dom->nconfigured) ||
		    facet->grantee == dom->services[facet->service].server)
			abort();
		for (uint32_t earlier = 0; earlier < index; earlier++) {
			a_service = &dom->services[dom->facets[earlier].service];
			b_service = &dom->services[facet->service];
			if (dom->facets[earlier].grantee == facet->grantee && a_service->name_len == b_service->name_len &&
			    memcmp(a_service->name, b_service->name, b_service->name_len) == 0)
				abort();
		}
	}
	for (uint32_t index = 0; index < dom->ndevices; index++) {
		a = &dom->devices[index];
		if (!erx_manifest_units_at(view, a->unit, &unit) || unit.holder != a->row ||
		    dom->device_records[index].index != index || a->nranges > 1 || a->confined)
			abort();
		for (uint32_t other = index + 1; other < dom->ndevices; other++) {
			b = &dom->devices[other];
			if (a->unit != b->unit && a->nranges != 0 && b->nranges != 0 &&
			    a->ranges[0].base < b->ranges[0].base + b->ranges[0].size &&
			    b->ranges[0].base < a->ranges[0].base + a->ranges[0].size)
				abort();
		}
	}
	for (uint32_t index = 0; index < dom->nconfigured; index++) {
		row = &dom->configured[index];
		if ((uint64_t)row->args_len + row->env_len + 2u * ERX_DOM_NODE_MAX > ERX_BOOT_STRINGS_MAX)
			abort();
	}
}

/* The library's view of an accepted manifest, in tables laid out as the root lays them. */
static void
view_build(const erx_manifest_view_t *view)
{
	const erx_dom_boot_sizes_t sizes = erx_dom_view_sizes(view, 0);
	erx_dom_boot_tables_t tables;
	erx_dom_lib_t lib;
	size_t bytes;
	void *region;

	if (!erx_dom_boot_layout(&sizes, 0, &tables, &bytes) || bytes > VIEW_TABLES_MAX)
		return;
	if ((region = calloc(1, bytes == 0 ? 1 : bytes)) == NULL)
		return;
	if (!erx_dom_boot_layout(&sizes, (uintptr_t)region, &tables, &bytes))
		abort();
	if (erx_dom_view_build(&lib, view, 0, &tables) == NULL)
		view_check(view, &lib);
	free(region);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_manifest_view_t view;
	erx_abi_error_t error = { 0 };

	if (!erx_manifest_open(data, size, &view, &error)) {
		if (error.reason == NULL || error.field == NULL)
			abort();
		return (0);
	}
	MANIFEST_TABLE(&view, principals, erx_mf_principal_t);
	MANIFEST_TABLE(&view, domains, erx_mf_domain_t);
	MANIFEST_TABLE(&view, limits, erx_mf_limits_t);
	MANIFEST_TABLE(&view, runtime_limits, erx_mf_runtime_limits_t);
	MANIFEST_TABLE(&view, lane_classes, erx_mf_lane_class_t);
	MANIFEST_TABLE(&view, units, erx_mf_unit_t);
	MANIFEST_TABLE(&view, devices, erx_mf_device_t);
	MANIFEST_TABLE(&view, windows, erx_mf_window_t);
	MANIFEST_TABLE(&view, services, erx_mf_service_t);
	MANIFEST_TABLE(&view, facets, erx_mf_facet_t);
	MANIFEST_TABLE(&view, facet_operations, erx_mf_operation_t);
	MANIFEST_TABLE(&view, facet_parameters, erx_mf_parameter_t);
	MANIFEST_TABLE(&view, introductions, erx_mf_introduction_t);
	MANIFEST_TABLE(&view, images, erx_mf_image_t);
	MANIFEST_TABLE(&view, extents, erx_mf_extent_t);
	MANIFEST_TABLE(&view, boot_order, erx_mf_boot_order_t);
	MANIFEST_TABLE(&view, liveness, erx_mf_liveness_t);
	MANIFEST_TABLE(&view, shell_principals, erx_mf_shell_principal_t);
	MANIFEST_TABLE(&view, partial_boot, erx_mf_partial_boot_t);
	view_build(&view);
	return (0);
}
