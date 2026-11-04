/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The system manifest's generated C reader, which the root runs at boot over the
 * archive's manifest entry. What the reader accepts must keep every table in reach:
 * each row its header counts reads back, and the row one past the end does not.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "erx/abi_reader.h"

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
	return (0);
}
