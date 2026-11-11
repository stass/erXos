/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "erx/abi_reader.h"
#include "erx/core/boot_pair.h"
#include "erx/device_kinds.h"
#include "liberx/backend/core/boot_manifest.h"

#define NODE_PREFIX		"system@"
#define NODE_PREFIX_LENGTH	(sizeof(NODE_PREFIX) - 1)

/*
 * The kinds of device the system domain's ERTS drives are erx/device_kinds.h's: a device
 * of a unit the system domain holds, at a device-tree path, whose role and compatible
 * string are a row's, becomes a device record with the row's names. Which transport is
 * which device is the platform record's and the manifest's to say, so the selection is
 * by configuration and touches no register: only erx_device reads a device, and a
 * driver's first reads, of the transport's magic, version and device id, find whether a
 * disk is behind it. The console is not a row: two UARTs share its role and compatible
 * string, and machine.console names which one (console_read). The host link's UART is
 * the other of the two, named by machine.hostlink, and becomes the record hostlink_kind
 * describes, which the host link's driver alone asks for (docs/design-live.md, "The host
 * link"), when the boot asks for the host link: a machine may have no UART at that path,
 * and a driver's first read of an absent device faults the system domain
 * (docs/design-stopgap.md, "Device records").
 */
typedef erx_device_kind_t device_kind_t;

/* Selected by machine.hostlink's path, among the UARTs of its driver's compatible string. */
static const device_kind_t hostlink_kind = { ERX_MF_DEVICE_ROLE_UART, "arm,pl011", "hostlink", "pl011" };

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

static bool
string_is(const erx_manifest_view_t *view, const erx_mf_str_t *string, const char *text)
{
	const uint8_t *const bytes = string_at(view, string);
	uint32_t at = 0;

	for (; at < string->length; at++) {
		if (text[at] == '\0' || bytes[at] != (uint8_t)text[at])
			return (false);
	}
	return (text[at] == '\0');
}

static const device_kind_t *
device_kind(const erx_manifest_view_t *view, const erx_mf_device_t *device, bool hostlink)
{
	if (device->selector != ERX_MF_SELECTOR_DT)
		return (NULL);
	if (hostlink && device->role == hostlink_kind.role && string_is(view, &device->compatible, hostlink_kind.compatible) &&
	    view->header.hostlink.length != 0 && string_equal(view, &device->path, &view->header.hostlink))
		return (&hostlink_kind);
	for (size_t at = 0; at < ERX_DEVICE_KINDS_COUNT; at++) {
		if (device->role == erx_device_kinds[at].role && string_is(view, &device->compatible, erx_device_kinds[at].compatible))
			return (&erx_device_kinds[at]);
	}
	return (NULL);
}

/*
 * A unit's device span is a file offset to its first record and a count, as every span is
 * (docs/design-abi.md, "slice"); *first is that record's index in the device table. False
 * for a span off a record boundary or past the table, which erx_manifest_open refuses, so
 * this is a second check, not the first.
 */
static bool
unit_first_device(const erx_manifest_view_t *view, const erx_mf_unit_t *unit, uint32_t *first)
{
	const erx_mf_span_t table = view->header.devices;
	uint32_t offset;

	if (unit->devices.offset < table.offset)
		return (false);
	offset = unit->devices.offset - table.offset;
	if (offset % ERX_MF_DEVICE_SIZE != 0 || unit->devices.count > table.count ||
	    offset / ERX_MF_DEVICE_SIZE > table.count - unit->devices.count)
		return (false);
	*first = offset / ERX_MF_DEVICE_SIZE;
	return (true);
}

/*
 * The device records of the units the system domain holds, in the order of the device
 * table. The manifest is the one source of which domain holds a device, and a unit's
 * holder is the only place that says so (docs/design-abi.md, "Devices and partition
 * windows"). Returns NULL, or the check that refused the manifest: a unit or device the
 * reader cannot read, or more records than ERX_BOOT_DEVICES_MAX.
 */
static const char *
devices_read(const erx_manifest_view_t *view, bool hostlink, erx_boot_manifest_t *result)
{
	erx_mf_device_t device;
	erx_mf_unit_t unit;
	uint32_t first;

	result->device_count = 0;
	for (uint32_t at = 0; at < view->header.units.count; at++) {
		if (!erx_manifest_units_at(view, at, &unit) || !unit_first_device(view, &unit, &first))
			return ("units");
		if (unit.holder != ERX_MF_NONE)
			continue;
		for (uint32_t index = first; index < first + unit.devices.count; index++) {
			const device_kind_t *kind;

			if (!erx_manifest_devices_at(view, index, &device))
				return ("devices");
			if ((kind = device_kind(view, &device, hostlink)) == NULL)
				continue;
			if (result->device_count == ERX_BOOT_DEVICES_MAX)
				return ("device_records");
			result->devices[result->device_count++] = (erx_boot_device_t){
				.role = kind->role_word, .peripheral = kind->peripheral, .given = kind != &hostlink_kind,
				.base = device.base,
				.size = device.size, .line = device.line, .dma_memory = device.dma_memory,
			};
		}
	}
	return (NULL);
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
erx_boot_manifest_read(const uint8_t *bytes, size_t length, bool hostlink, erx_boot_manifest_t *result,
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
	if ((*reason = devices_read(&view, hostlink, result)) != NULL)
		return (false);
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

/* TEXT and its NUL at words + *used, or false, writing nothing, when they do not fit. */
static bool
word_put(char *words, size_t capacity, size_t *used, const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	if (length >= capacity - *used)
		return (false);
	for (size_t at = 0; at <= length; at++)
		words[(*used)++] = text[at];
	return (true);
}

static bool
number_put(char *words, size_t capacity, size_t *used, uint64_t value)
{
	char digits[sizeof("18446744073709551615")];
	size_t at = sizeof(digits) - 1;

	digits[at] = '\0';
	do {
		digits[--at] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	return (word_put(words, capacity, used, digits + at));
}

size_t
erx_boot_device_words(const erx_boot_device_t *device, char *words, size_t capacity)
{
	size_t used = 0;

	if (word_put(words, capacity, &used, "-erx") && word_put(words, capacity, &used, "device") &&
	    word_put(words, capacity, &used, device->role) && word_put(words, capacity, &used, device->peripheral) &&
	    number_put(words, capacity, &used, device->base) && number_put(words, capacity, &used, device->size) &&
	    number_put(words, capacity, &used, device->line))
		return (used);
	return (0);
}

bool
erx_boot_device_window(const erx_boot_device_t *device, erx_boot_window_t *window)
{
	const uint64_t page_mask = (uint64_t)ERX_PAGE_SIZE - 1;
	const uint64_t first = device->base & ~page_mask;
	uint64_t last;

	if (device->size == 0 || __builtin_add_overflow(device->base, device->size - 1, &last) ||
	    (last | page_mask) == UINT64_MAX)
		return (false);
	*window = (erx_boot_window_t){ .base = first, .size = (last | page_mask) + 1 - first, .offset = device->base - first };
	return (true);
}

erx_boot_given_t
erx_boot_device_given(const erx_boot_device_t *device, const erx_boot_window_t *window, uint64_t window_handle,
    uint64_t line_handle, uint64_t memory_handle)
{
	return ((erx_boot_given_t){ .role = device->role, .peripheral = device->peripheral, .window = window_handle,
	    .offset = window->offset, .size = device->size, .line = line_handle,
	    .memory = device->dma_memory != 0 ? memory_handle : ERX_CAP_NULL, .memory_size = device->dma_memory });
}

size_t
erx_boot_given_words(const erx_boot_given_t *given, char *words, size_t capacity)
{
	size_t used = 0;

	if (word_put(words, capacity, &used, "-erx") && word_put(words, capacity, &used, "given") &&
	    word_put(words, capacity, &used, given->role) && word_put(words, capacity, &used, given->peripheral) &&
	    number_put(words, capacity, &used, given->window) && number_put(words, capacity, &used, given->offset) &&
	    number_put(words, capacity, &used, given->size) && number_put(words, capacity, &used, given->line) &&
	    number_put(words, capacity, &used, given->memory) && number_put(words, capacity, &used, given->memory_size))
		return (used);
	return (0);
}

size_t
erx_boot_pair_words(uint32_t value, uint32_t slot, char *words, size_t capacity)
{
	const char *value_name = erx_boot_value_name(value), *slot_name = erx_boot_slot_name(slot);
	size_t used = 0;

	if (value_name != NULL && slot_name != NULL && word_put(words, capacity, &used, "-erx") &&
	    word_put(words, capacity, &used, "boot") && word_put(words, capacity, &used, value_name) &&
	    word_put(words, capacity, &used, slot_name))
		return (used);
	return (0);
}

size_t
erx_boot_build_words(uint64_t build_id, char *words, size_t capacity)
{
	size_t used = 0;

	if (word_put(words, capacity, &used, "-erx") && word_put(words, capacity, &used, "build") &&
	    number_put(words, capacity, &used, build_id))
		return (used);
	return (0);
}
