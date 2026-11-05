/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "erx/abi_reader.h"
#include "liberx/backend/core/boot_manifest.h"

#define NODE_PREFIX		"system@"
#define NODE_PREFIX_LENGTH	(sizeof(NODE_PREFIX) - 1)

/* erx_manifest_open checked every string against the table, so these reads stay inside it. */
static const uint8_t *
string_at(const erx_manifest_view_t *view, const erx_mf_str_t *string)
{
	return (view->bytes + view->header.strings.offset + string->offset);
}

bool
erx_boot_manifest_read(const uint8_t *bytes, size_t length, erx_boot_manifest_t *result,
    const char **reason)
{
	erx_manifest_view_t view;
	erx_abi_error_t error;
	erx_mf_runtime_limits_t limits;
	const uint8_t *host;

	if (!erx_manifest_open(bytes, length, &view, &error)) {
		*reason = error.reason;
		return (false);
	}
	if (view.header.host.length > ERX_BOOT_NODE_MAX - NODE_PREFIX_LENGTH) {
		*reason = "host";
		return (false);
	}
	if (!erx_manifest_runtime_limits_at(&view, view.header.system_runtime_limits, &limits)) {
		*reason = "system_runtime_limits";
		return (false);
	}
	host = string_at(&view, &view.header.host);
	for (size_t at = 0; at < NODE_PREFIX_LENGTH; at++)
		result->node[at] = NODE_PREFIX[at];
	for (size_t at = 0; at < view.header.host.length; at++)
		result->node[NODE_PREFIX_LENGTH + at] = (char)host[at];
	result->node_len = NODE_PREFIX_LENGTH + view.header.host.length;
	result->system_args = (erx_boot_words_t){
		(const char *)string_at(&view, &view.header.system_args), view.header.system_args.length
	};
	result->limits = (erx_runtime_limits_t){
		.max_frame = limits.max_frame,
		.max_message_heap = limits.max_message_heap,
		.funnel_depth = limits.funnel_depth,
		.exports = limits.exports,
		.tmp = limits.tmp,
		.overlay = limits.overlay,
		.atoms = limits.atoms,
		.foreign_atoms = limits.foreign_atoms,
		.processes = limits.processes,
	};
	return (true);
}
