/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/core/boot_handoff.h"
#include "erx/core/boot_pair.h"
#include "erx/device_kinds.h"
#include "liberx/backend/core/boot_manifest.h"
#include "liberx/backend/core/manifest_dma.h"

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
 * string, and machine.console names which one (console_read), whose record names the
 * peripheral uart_kinds gives its compatible string. The host link's UART is
 * the other of the two, named by machine.hostlink, and becomes the record hostlink_kind
 * describes, which the host link's driver alone asks for (docs/design-live.md, "The host
 * link"), when the boot asks for the host link: a machine may have no UART at that path,
 * and a driver's first read of an absent device faults the system domain
 * (docs/design-stopgap.md, "Device records").
 */
typedef erx_device_kind_t device_kind_t;

/*
 * The UARTs the root names, each compatible string's CMSIS-SVD peripheral: the console's
 * record carries it, and erx_console starts that peripheral's driver
 * (docs/design-stopgap.md, "The console").
 */
typedef struct uart_kind {
	const char	*compatible;
	const char	*peripheral;
} uart_kind_t;

#define PL011_COMPATIBLE	"arm,pl011"
#define PL011_PERIPHERAL	"pl011"
#define MINI_UART_PERIPHERAL	"mini_uart"

_Static_assert(sizeof(PL011_PERIPHERAL) <= ERX_BOOT_NAME_WORD_MAX && sizeof(MINI_UART_PERIPHERAL) <= ERX_BOOT_NAME_WORD_MAX,
    "erx/boot_words.h's console record holds every UART kind's peripheral");

static const uart_kind_t uart_kinds[] = {
	{ PL011_COMPATIBLE, PL011_PERIPHERAL },
	{ "brcm,bcm2835-aux-uart", MINI_UART_PERIPHERAL },
};

#define UART_KINDS_COUNT	(sizeof(uart_kinds) / sizeof(uart_kinds[0]))

/* Selected by machine.hostlink's path, among the PL011s, the one UART its driver drives. */
static const device_kind_t hostlink_kind = { ERX_MF_DEVICE_ROLE_UART, PL011_COMPATIBLE, "hostlink", PL011_PERIPHERAL };

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
 * Whether a device-tree device other than the one at index self names line, which makes
 * the line shared (docs/design-shared-devices.md, "Lines inside a domain"). This is the
 * relation of the domain library's boot view, boot_lines_meet in
 * liberx/system/dom_boot_view.c, over the manifest's own entries: each device-tree entry
 * names exactly one line, except a framebuffer row, whose line field is 0 but which names
 * none (erx/dom.h); a PCIe function names none. The boot view refuses a manifest
 * that puts devices sharing a line in two units, so another device of the manifest that
 * names the line is another device of the same unit. erx_manifest_open checked every
 * entry, so every read succeeds.
 */
static bool
line_shared(const erx_manifest_view_t *view, uint32_t self, uint32_t line)
{
	erx_mf_device_t other;

	for (uint32_t at = 0; at < view->header.devices.count; at++) {
		if (at != self && erx_manifest_devices_at(view, at, &other) && other.selector == ERX_MF_SELECTOR_DT &&
		    other.role != ERX_MF_DEVICE_ROLE_FRAMEBUFFER && other.line == line)
			return (true);
	}
	return (false);
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
			const bool framebuffer = device.selector == ERX_MF_SELECTOR_DT && device.role == ERX_MF_DEVICE_ROLE_FRAMEBUFFER;

			if ((kind = device_kind(view, &device, hostlink)) == NULL && !framebuffer)
				continue;
			if (result->device_count == ERX_BOOT_DEVICES_MAX)
				return ("device_records");
			/* A framebuffer row has no kind: its record is made from its catalogue entry. */
			if (framebuffer) {
				result->devices[result->device_count++] = (erx_boot_device_t){ .framebuffer = true,
				    .base = device.base, .size = device.size,
				    .path = { (const char *)string_at(view, &device.path), device.path.length }, .index = index };
				continue;
			}
			result->devices[result->device_count++] = (erx_boot_device_t){
				.role = kind->role_word, .peripheral = kind->peripheral, .given = kind != &hostlink_kind,
				.base = device.base,
				.size = device.size, .line = device.line,
				.line_shared = line_shared(view, index, device.line), .clock = device.clock,
				.dma_memory = device.dma_memory, .network = kind->role == ERX_MF_DEVICE_ROLE_NETWORK,
				.path = { (const char *)string_at(view, &device.path), device.path.length },
				.index = index,
			};
			/* Its path is its record's PATH, so the record is never refused for it. */
			if (!erx_boot_device_path_valid(result->devices[result->device_count - 1].path))
				return ("device_path");
		}
	}
	return (NULL);
}

/* The peripheral uart_kinds gives a UART's compatible string; NULL for a UART of no kind. */
static const char *
uart_peripheral(const erx_manifest_view_t *view, const erx_mf_str_t *compatible)
{
	for (size_t at = 0; at < UART_KINDS_COUNT; at++) {
		if (string_is(view, compatible, uart_kinds[at].compatible))
			return (uart_kinds[at].peripheral);
	}
	return (NULL);
}

/* The UART machine.console names, if its compatible string is a UART kind's. */
static erx_boot_console_t
console_read(const erx_manifest_view_t *view)
{
	erx_mf_device_t device;
	const char *peripheral;

	for (uint32_t at = 0; view->header.console.length != 0 && at < view->header.devices.count; at++) {
		if (!erx_manifest_devices_at(view, at, &device) || device.selector != ERX_MF_SELECTOR_DT ||
		    device.role != ERX_MF_DEVICE_ROLE_UART || !string_equal(view, &device.path, &view->header.console))
			continue;
		peripheral = uart_peripheral(view, &device.compatible);
		if (peripheral == NULL)
			break;
		return ((erx_boot_console_t){ .peripheral = peripheral, .base = device.base, .size = device.size,
		    .line = device.line, .line_shared = line_shared(view, at, device.line), .clock = device.clock });
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

uint64_t
erx_boot_console_page(const erx_boot_manifest_t *manifest)
{
	return (manifest->console.base & ~((uint64_t)ERX_PAGE_SIZE - 1));
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

/* The room of the longest decimal number, 2^64 - 1, with its NUL. */
#define DECIMAL_MAX	sizeof("18446744073709551615")

/* value's decimal digits, without leading zeros and with a NUL, at the end of digits. */
static const char *
decimal_digits(char digits[DECIMAL_MAX], uint64_t value)
{
	size_t at = DECIMAL_MAX - 1;

	digits[at] = '\0';
	do {
		digits[--at] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	return (digits + at);
}

/* value in decimal as one word, as word_put writes it. */
static bool
number_put(char *words, size_t capacity, size_t *used, uint64_t value)
{
	char digits[DECIMAL_MAX];

	return (word_put(words, capacity, used, decimal_digits(digits, value)));
}

bool
erx_boot_device_path_valid(erx_boot_words_t path)
{
	return (path.length != 0 && path.length <= ERX_DEVICE_PATH_MAX &&
	    erx_boot_node_path_valid((const uint8_t *)path.bytes, path.length));
}

/*
 * A device's path and its NUL as one word, as word_put writes text, or false, writing
 * nothing, for a path erx_boot_device_path_valid refuses or one that does not fit.
 */
static bool
path_put(char *words, size_t capacity, size_t *used, erx_boot_words_t path)
{
	if (!erx_boot_device_path_valid(path) || path.length >= capacity - *used)
		return (false);
	for (size_t at = 0; at < path.length; at++)
		words[(*used)++] = path.bytes[at];
	words[(*used)++] = '\0';
	return (true);
}

/*
 * The word a record writes after its line (docs/design-shared-devices.md, "Lines inside a
 * domain"): shared when another device of the line's unit names it too, direct otherwise.
 */
static const char *
line_mark(bool shared)
{
	return (shared ? "shared" : "direct");
}

_Static_assert(sizeof("shared") <= ERX_BOOT_MARK_WORD_MAX && sizeof("direct") <= ERX_BOOT_MARK_WORD_MAX,
    "erx/boot_words.h's records hold either line mark");

size_t
erx_boot_console_words(const erx_boot_console_t *console, char *words, size_t capacity)
{
	size_t used = 0;

	if (console->peripheral != NULL && word_put(words, capacity, &used, ERX_BOOT_RECORD_FLAG) &&
	    word_put(words, capacity, &used, "console") && word_put(words, capacity, &used, console->peripheral) &&
	    number_put(words, capacity, &used, console->base) && number_put(words, capacity, &used, console->size) &&
	    number_put(words, capacity, &used, console->line) &&
	    word_put(words, capacity, &used, line_mark(console->line_shared)) &&
	    number_put(words, capacity, &used, console->clock))
		return (used);
	return (0);
}

size_t
erx_boot_device_words(const erx_boot_device_t *device, char *words, size_t capacity)
{
	size_t used = 0;

	if (!device->framebuffer && word_put(words, capacity, &used, ERX_BOOT_RECORD_FLAG) &&
	    word_put(words, capacity, &used, "device") && word_put(words, capacity, &used, device->role) &&
	    word_put(words, capacity, &used, device->peripheral) && path_put(words, capacity, &used, device->path) &&
	    number_put(words, capacity, &used, device->base) && number_put(words, capacity, &used, device->size) &&
	    number_put(words, capacity, &used, device->line) &&
	    word_put(words, capacity, &used, line_mark(device->line_shared)) &&
	    number_put(words, capacity, &used, device->clock))
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

bool
erx_boot_row_asks(uint64_t dma_memory, bool network)
{
	return (dma_memory != 0 || network);
}

uint64_t
erx_boot_dma_memory(const erx_dt_device_t *facts, uint64_t dma_memory)
{
	return (facts != NULL && erx_boot_dma_absent(facts, 0, 0) == NULL ? dma_memory : 0);
}

erx_mem_dma_range_t
erx_boot_dma_range(const erx_dt_device_t *facts)
{
	return ((erx_mem_dma_range_t){ .cpu = facts->cpu, .bus = facts->bus, .last = facts->last });
}

bool
erx_boot_coherent(const erx_dt_device_t *facts, uint64_t dma_memory)
{
	return (erx_boot_dma_memory(facts, dma_memory) != 0 && facts->coherent);
}

erx_boot_given_t
erx_boot_device_given(const erx_boot_device_t *device, const erx_boot_window_t *window, const erx_dt_device_t *facts,
    uint64_t window_handle, uint64_t line_handle, uint64_t memory_handle)
{
	const bool memory = device->dma_memory != 0 && memory_handle != ERX_CAP_NULL;

	return ((erx_boot_given_t){ .role = device->role, .peripheral = device->peripheral, .path = device->path,
	    .window = window_handle,
	    .offset = window->offset, .size = device->size, .line = line_handle, .line_shared = device->line_shared,
	    .memory = memory ? memory_handle : ERX_CAP_NULL, .memory_size = memory ? device->dma_memory : 0,
	    .clock = device->clock, .coherent = erx_boot_coherent(facts, device->dma_memory),
	    .mac = facts != NULL && device->network ? erx_boot_mac_number(facts) : 0 });
}

const char *
erx_boot_dma_absent(const erx_dt_device_t *facts, uint64_t first, uint64_t size)
{
	static const char *const status_reasons[] = {
		[ERX_DT_DMA_NO_NODE] = "no_node",
		[ERX_DT_DMA_COHERENCE] = "coherence",
		[ERX_DT_DMA_CELLS] = "cells",
		[ERX_DT_DMA_MALFORMED] = "malformed",
		[ERX_DT_DMA_RANGES] = "ranges",
	};
	uint64_t last, bus_last;

	if (facts->dma != ERX_DT_DMA_OK)
		return ((size_t)facts->dma < sizeof(status_reasons) / sizeof(status_reasons[0]) &&
		    status_reasons[facts->dma] != NULL ? status_reasons[facts->dma] : "malformed");
	if (size == 0)
		return (NULL);
	if (facts->last < facts->cpu || __builtin_add_overflow(facts->bus, facts->last - facts->cpu, &bus_last) ||
	    __builtin_add_overflow(first, size - 1, &last) || first < facts->bus || last > bus_last)
		return ("outside");
	return (NULL);
}

uint64_t
erx_boot_mac_number(const erx_dt_device_t *facts)
{
	uint64_t mac = 0;

	if (facts->mac_status != ERX_DT_MAC_OK)
		return (0);
	for (size_t at = 0; at < ERX_DT_MAC_BYTES; at++)
		mac = mac << 8 | facts->mac[at];
	return (mac);
}

/* length bytes of text at line + *used, or false, writing nothing, when they do not fit. */
static bool
text_put(char *line, size_t capacity, size_t *used, const char *text, size_t length)
{
	if (length > capacity - *used)
		return (false);
	for (size_t at = 0; at < length; at++)
		line[(*used)++] = text[at];
	return (true);
}

static bool
string_put(char *line, size_t capacity, size_t *used, const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	return (text_put(line, capacity, used, text, length));
}

/* value as 0x and its hexadecimal digits, without leading zeros. */
static bool
hex_put(char *line, size_t capacity, size_t *used, uint64_t value)
{
	static const char digit[] = "0123456789abcdef";
	char text[sizeof("0x0123456789abcdef") - 1];
	size_t at = sizeof(text);

	do {
		text[--at] = digit[value & 0xf];
		value >>= 4;
	} while (value != 0);
	text[--at] = 'x';
	text[--at] = '0';
	return (text_put(line, capacity, used, text + at, sizeof(text) - at));
}

size_t
erx_boot_tree_line(erx_boot_words_t path, uint64_t dma_memory, bool network, const erx_dt_device_t *facts,
    const char *absent, char *line, size_t capacity)
{
	const char *const reason = absent != NULL ? absent : erx_boot_dma_absent(facts, 0, 0);
	size_t used = 0;
	bool fits = path.length != 0 && erx_boot_node_path_valid((const uint8_t *)path.bytes, path.length) &&
	    string_put(line, capacity, &used, "erx: device tree: ") &&
	    text_put(line, capacity, &used, path.bytes, path.length) &&
	    string_put(line, capacity, &used, ":");

	if (fits && dma_memory != 0 && reason != NULL)
		fits = string_put(line, capacity, &used, " dma absent ") && string_put(line, capacity, &used, reason);
	else if (fits && dma_memory != 0)
		fits = string_put(line, capacity, &used, facts->coherent ? " coherent 1 range " : " coherent 0 range ") &&
		    hex_put(line, capacity, &used, facts->cpu) && string_put(line, capacity, &used, " ") &&
		    hex_put(line, capacity, &used, facts->bus) && string_put(line, capacity, &used, " ") &&
		    hex_put(line, capacity, &used, facts->last);
	if (fits && network)
		fits = string_put(line, capacity, &used, facts->mac_status == ERX_DT_MAC_OK ? " mac present" : " mac absent");
	return (fits && string_put(line, capacity, &used, "\n") ? used : 0);
}

size_t
erx_boot_given_words(const erx_boot_given_t *given, char *words, size_t capacity)
{
	size_t used = 0;

	if (word_put(words, capacity, &used, ERX_BOOT_RECORD_FLAG) && word_put(words, capacity, &used, "given") &&
	    word_put(words, capacity, &used, given->role) && word_put(words, capacity, &used, given->peripheral) &&
	    path_put(words, capacity, &used, given->path) && number_put(words, capacity, &used, given->window) &&
	    number_put(words, capacity, &used, given->offset) &&
	    number_put(words, capacity, &used, given->size) && number_put(words, capacity, &used, given->line) &&
	    word_put(words, capacity, &used, line_mark(given->line_shared)) &&
	    number_put(words, capacity, &used, given->memory) && number_put(words, capacity, &used, given->memory_size) &&
	    number_put(words, capacity, &used, given->clock) &&
	    number_put(words, capacity, &used, given->coherent ? 1 : 0) &&
	    number_put(words, capacity, &used, given->mac))
		return (used);
	return (0);
}

/*
 * Whether format is a name the record's room holds: not NULL and not empty, and at most
 * ERX_BOOT_FORMAT_WORD_MAX bytes with its NUL.
 */
static bool
format_named(const char *format)
{
	size_t length = 0;

	if (format == NULL)
		return (false);
	while (length < ERX_BOOT_FORMAT_WORD_MAX && format[length] != '\0')
		length++;
	return (length != 0 && length < ERX_BOOT_FORMAT_WORD_MAX);
}

bool
erx_boot_framebuffer_place(const erx_dt_framebuffer_t *fb, const char *format, erx_dt_window_t window,
    erx_boot_window_t *pages)
{
	const erx_boot_device_t over = { .base = fb->base, .size = fb->length };
	erx_boot_window_t whole;

	if (fb->status != ERX_DT_FB_OK || !format_named(format) || !erx_boot_device_window(&over, &whole))
		return (false);
	/* Inside the window, checked without an end that could wrap. */
	if (whole.base < window.base || whole.size > window.size || whole.base - window.base > window.size - whole.size)
		return (false);
	*pages = whole;
	return (true);
}

size_t
erx_boot_framebuffer_words(const erx_dt_framebuffer_t *fb, const char *format, uint64_t window, uint64_t offset,
    char *words, size_t capacity)
{
	size_t used = 0;

	if (fb->status == ERX_DT_FB_OK && format_named(format) && word_put(words, capacity, &used, ERX_BOOT_RECORD_FLAG) &&
	    word_put(words, capacity, &used, "framebuffer") && number_put(words, capacity, &used, window) &&
	    number_put(words, capacity, &used, offset) && number_put(words, capacity, &used, fb->length) &&
	    number_put(words, capacity, &used, fb->width) && number_put(words, capacity, &used, fb->height) &&
	    number_put(words, capacity, &used, fb->stride) && word_put(words, capacity, &used, format))
		return (used);
	return (0);
}

/* value in decimal, without leading zeros, into a line. */
static bool
decimal_put(char *line, size_t capacity, size_t *used, uint64_t value)
{
	char digits[DECIMAL_MAX];

	return (string_put(line, capacity, used, decimal_digits(digits, value)));
}

/*
 * The fixed word of a framebuffer the reader found none of, one too many of or one it cannot
 * read: status is neither ERX_DT_FB_OK nor ERX_DT_FB_OUTSIDE, whose lines carry facts.
 */
static const char *
framebuffer_reason(erx_dt_fb_status_t status)
{
	switch (status) {
	case ERX_DT_FB_NONE:
		return ("none");
	case ERX_DT_FB_AMBIGUOUS:
		return ("ambiguous");
	case ERX_DT_FB_UNSUPPORTED:
		return ("unsupported");
	default:
		return ("malformed");
	}
}

size_t
erx_boot_framebuffer_line(erx_boot_words_t path, const erx_dt_framebuffer_t *fb, const char *format, char *line,
    size_t capacity)
{
	size_t used = 0;
	bool fits = path.length != 0 && erx_boot_node_path_valid((const uint8_t *)path.bytes, path.length) &&
	    string_put(line, capacity, &used, "erx: device tree: ") &&
	    text_put(line, capacity, &used, path.bytes, path.length) &&
	    string_put(line, capacity, &used, ":");

	if (fits && fb->status == ERX_DT_FB_OK)
		fits = format_named(format) && string_put(line, capacity, &used, " framebuffer ") && decimal_put(line, capacity, &used, fb->width) &&
		    string_put(line, capacity, &used, "x") && decimal_put(line, capacity, &used, fb->height) &&
		    string_put(line, capacity, &used, " ") && decimal_put(line, capacity, &used, fb->stride) &&
		    string_put(line, capacity, &used, " ") && string_put(line, capacity, &used, format);
	else if (fits && fb->status == ERX_DT_FB_OUTSIDE)
		fits = string_put(line, capacity, &used, " framebuffer absent outside ") &&
		    hex_put(line, capacity, &used, fb->base) && string_put(line, capacity, &used, " ") &&
		    hex_put(line, capacity, &used, fb->length);
	else if (fits)
		fits = string_put(line, capacity, &used, " framebuffer absent ") &&
		    string_put(line, capacity, &used, framebuffer_reason(fb->status));
	return (fits && string_put(line, capacity, &used, "\n") ? used : 0);
}

size_t
erx_boot_pair_words(uint32_t value, uint32_t slot, char *words, size_t capacity)
{
	const char *value_name = erx_boot_value_name(value), *slot_name = erx_boot_slot_name(slot);
	size_t used = 0;

	if (value_name != NULL && slot_name != NULL && word_put(words, capacity, &used, ERX_BOOT_RECORD_FLAG) &&
	    word_put(words, capacity, &used, "boot") && word_put(words, capacity, &used, value_name) &&
	    word_put(words, capacity, &used, slot_name))
		return (used);
	return (0);
}

size_t
erx_boot_build_words(uint64_t build_id, char *words, size_t capacity)
{
	size_t used = 0;

	if (word_put(words, capacity, &used, ERX_BOOT_RECORD_FLAG) && word_put(words, capacity, &used, "build") &&
	    number_put(words, capacity, &used, build_id))
		return (used);
	return (0);
}

bool
erx_boot_manifest_dma_total(const erx_manifest_view_t *view, uint64_t *total)
{
	erx_mf_device_t device;
	uint64_t sum = 0;

	for (uint32_t at = 0; at < view->header.devices.count; at++) {
		if (!erx_manifest_devices_at(view, at, &device) || __builtin_add_overflow(sum, device.dma_memory, &sum))
			return (false);
	}
	*total = sum;
	return (true);
}
