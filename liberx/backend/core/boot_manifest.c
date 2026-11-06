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

/*
 * ERTS echoes a flag it refuses to the terminal, with %s at dozens of sites of its
 * argument parsing, so a word holds printable ASCII alone and none of them can carry
 * a terminal escape. The words are separated by NUL.
 */
static bool
words_are_printable(const uint8_t *bytes, size_t length)
{
	for (size_t at = 0; at < length; at++) {
		if (bytes[at] != '\0' && (bytes[at] < 0x20 || bytes[at] > 0x7e))
			return (false);
	}
	return (true);
}

static bool
string_equal(const erx_manifest_view_t *view, const erx_mf_str_t *left, const erx_mf_str_t *right)
{
	const uint8_t *const a = string_at(view, left);
	const uint8_t *const b = string_at(view, right);

	if (left->length != right->length)
		return (false);
	for (uint32_t at = 0; at < left->length; at++) {
		if (a[at] != b[at])
			return (false);
	}
	return (true);
}

static erx_boot_console_t
console_read(const erx_manifest_view_t *view)
{
	erx_mf_device_t device;

	for (uint32_t at = 0; view->header.console.length != 0 && at < view->header.devices.count; at++) {
		if (erx_manifest_devices_at(view, at, &device) && device.selector == ERX_MF_SELECTOR_DT &&
		    device.role == ERX_MF_DEVICE_ROLE_UART && string_equal(view, &device.path, &view->header.console))
			return ((erx_boot_console_t){ .base = device.base, .size = device.size, .line = device.line });
	}
	return ((erx_boot_console_t){ 0 });
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
	if (!words_are_printable(string_at(&view, &view.header.system_args), view.header.system_args.length)) {
		*reason = "system_args_text";
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
	result->console = console_read(&view);
	result->console_path = (erx_boot_words_t){
		(const char *)string_at(&view, &view.header.console), view.header.console.length
	};
	return (true);
}

bool
erx_boot_console_matches(const erx_boot_manifest_t *manifest, const char *stdout_path, size_t stdout_len)
{
	if (manifest->console_path.length == 0 || manifest->console_path.length != stdout_len)
		return (false);
	for (size_t at = 0; at < stdout_len; at++) {
		if (manifest->console_path.bytes[at] != stdout_path[at])
			return (false);
	}
	return (true);
}
