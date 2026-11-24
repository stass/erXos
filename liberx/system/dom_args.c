/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The boot page's arguments of a creation (liberx/system/dom_args.h): a
 * pure function of the library's view, the plan and what each give made.
 * It reads no hardware or global state; the apply phase (dom_apply.c)
 * learns from the kernel what the records need first.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "liberx/backend/core/boot_info.h"
#include "liberx/backend/core/boot_manifest.h"
#include "liberx/system/dom_args.h"

/* What one erx_dom_args reads. */
typedef struct args {
	const erx_dom_lib_t		*lib;
	const erx_dom_plan_t		*plan;
	const erx_dom_give_made_t	*gives;		/* plan->gives, give for give */
} args_t;

/*
 * The value in the holder's table of the give's object obj + n, or
 * ERX_CAP_NULL for n ERX_DOM_UNIT_NONE: a device with no window or line
 * names none. Every record of a run or a line names its one object under
 * one handle.
 */
static uint64_t
args_unit_installed(const args_t *args, uint32_t at, erx_dom_obj_t obj, uint32_t n)
{
	return (n == ERX_DOM_UNIT_NONE ? ERX_CAP_NULL : args->gives[at].installed[obj + n]);
}

erx_msi_message_t
erx_dom_give_message(const erx_dom_give_made_t *give, const erx_dom_unit_device_t *device)
{
	if ((device->route != ERX_PCIE_ROUTE_MSI && device->route != ERX_PCIE_ROUTE_MSIX) ||
	    device->line >= ERX_DOM_UNIT_LINES_MAX)
		return ((erx_msi_message_t){ 0 });
	return (give->messages[device->line]);
}

/*
 * The -erx_record function record of PCIe function d of give `at`
 * (erx_boot_function_words): as a given device's, and its place, its
 * route, an MSI-X route's message and table, and each placed BAR's window
 * and offset there, the give's WINDOW step whose run holds the BAR's span,
 * which the plan check proved is one of them; the BARs' spans are the
 * device's ranges, in BAR order (erx/dom.h).
 */
static size_t
args_function_words(const args_t *args, uint32_t at, uint32_t d, char *words, size_t capacity)
{
	const erx_dom_unit_plan_t *give = &args->plan->gives[at];
	const erx_dom_unit_device_t *device = &give->devices[d];
	const erx_dom_device_entry_t *entry = &args->lib->view.devices[device->index];
	const erx_pcie_function_t *record = &device->function;
	const uint64_t *installed = args->gives[at].installed;
	const uint64_t held = installed[ERX_DOM_OBJ_DEV_MEMORY + d] != ERX_CAP_NULL ?
	    installed[ERX_DOM_OBJ_DEV_MEMORY + d] : installed[ERX_DOM_OBJ_DEV_KEPT + d];
	const bool memory = args->gives[at].memory[d];
	const bool msix = device->route == ERX_PCIE_ROUTE_MSIX;
	erx_boot_function_t function = { .role = entry->role_word, .peripheral = entry->peripheral,
	    .bridge = entry->bridge, .bus = record->bus, .device = record->device, .function = record->function,
	    .line = args_unit_installed(args, at, ERX_DOM_OBJ_DEV_IRQ, device->line), .line_shared = device->shared,
	    .memory = memory ? held : ERX_CAP_NULL, .memory_size = memory ? entry->memory : 0,
	    .coherent = erx_boot_coherent(entry->asked ? &entry->facts : NULL, entry->memory), .route = device->route,
	    .message = msix ? erx_dom_give_message(&args->gives[at], device) : (erx_msi_message_t){ 0 },
	    .table_bar = msix ? record->msix_table_bar : 0, .table_offset = msix ? record->msix_table_offset : 0,
	    .table_size = msix ? record->msix_table_size : 0 };
	uint32_t range = 0;

	for (uint32_t bar = 0; bar < sizeof(function.bars) / sizeof(function.bars[0]); bar++) {
		function.bars[bar].size_log2 = record->bars[bar].size_log2;
		function.bars[bar].window = ERX_CAP_NULL;
		if (record->bars[bar].kind != ERX_PCIE_BAR_MEMORY ||
		    (record->bars[bar].flags & ERX_PCIE_BAR_PLACED) == 0 || range == device->nranges)
			continue;
		const erx_dom_range_t *span = &device->ranges[range++];
		for (uint32_t step = 0; step < give->nsteps; step++) {
			const erx_dom_step_t *window = &give->steps[step];

			if (window->kind != ERX_DOM_STEP_WINDOW)
				continue;
			if (span->base >= window->base && span->base - window->base < window->size) {
				function.bars[bar].window = installed[window->obj];
				function.bars[bar].offset = span->base - window->base;
				break;
			}
		}
	}
	return (erx_boot_function_words(&function, words, capacity));
}

/*
 * The -erx_record given record of device d of give `at` (erx_boot_given_words)
 * into words, capacity bytes: the values its give's installs took in the
 * holder's table, its window's and its line's, ERX_CAP_NULL for a device
 * whose node raises no line, marked shared as the plan
 * says, and its memory's; its registers' offset into its window from the
 * plan; the facts of its catalogue entry, COHERENT and, for a network row,
 * MAC, and its catalogue entry's index, its manifest device row, as
 * INDEX; or for a framebuffer row its -erx_record framebuffer record
 * (erx_boot_framebuffer_words) over its window; and its length, or 0 when
 * the words do not fit, which the view's names and paths rule out. A device of no
 * kind has no role word to write, so args_given_words answers 0 for one;
 * erx_dom_args asks only of a device its give marks driven, so never for
 * one. The registers' offset and size are the give's, which the plan
 * check proved lie whole inside the window.
 */
static size_t
args_given_words(const args_t *args, uint32_t at, uint32_t d, char *words, size_t capacity)
{
	const erx_dom_unit_device_t *device = &args->plan->gives[at].devices[d];
	const erx_dom_device_entry_t *entry = &args->lib->view.devices[device->index];
	const erx_dt_device_t *facts = entry->asked ? &entry->facts : NULL;
	const uint64_t *installed = args->gives[at].installed;
	const uint64_t held = installed[ERX_DOM_OBJ_DEV_MEMORY + d] != ERX_CAP_NULL ?
	    installed[ERX_DOM_OBJ_DEV_MEMORY + d] : installed[ERX_DOM_OBJ_DEV_KEPT + d];
	const uint64_t window = args_unit_installed(args, at, ERX_DOM_OBJ_DEV_WINDOW, device->window);
	const bool memory = args->gives[at].memory[d];
	const erx_boot_given_t given = { .role = entry->role_word, .peripheral = entry->peripheral,
	    .path = { entry->path, entry->path_len }, .window = window, .offset = device->offset, .size = device->reg_size,
	    .line = args_unit_installed(args, at, ERX_DOM_OBJ_DEV_IRQ, device->line), .line_shared = device->shared,
	    .memory = memory ? held : ERX_CAP_NULL, .memory_size = memory ? entry->memory : 0, .clock = entry->clock,
	    .coherent = erx_boot_coherent(facts, entry->memory),
	    .mac = facts != NULL && entry->role == ERX_MF_DEVICE_ROLE_NETWORK ? erx_boot_mac_number(facts) : 0,
	    .index = device->index };

	if (device->pci)
		return (device->driven ? args_function_words(args, at, d, words, capacity) : 0);
	if (entry->role == ERX_MF_DEVICE_ROLE_FRAMEBUFFER)
		return (erx_boot_framebuffer_words(&entry->framebuffer, entry->format, window, device->offset, words,
		    capacity));
	if (!device->driven)
		return (0);
	return (erx_boot_given_words(&given, words, capacity));
}

/*
 * Whether an entry writes no record: a framebuffer the tree did not place
 * in its window (erx_dom_view_framebuffer) has no range (erx/dom.h), so
 * its give made no window for it and its holder finds no framebuffer
 * record.
 */
static bool
args_unrecorded(const erx_dom_device_entry_t *entry)
{
	return (entry->role == ERX_MF_DEVICE_ROLE_FRAMEBUFFER && entry->nranges == 0);
}

/*
 * The runs, at most ERX_DOM_ARGS_RUNS_MAX:
 * - the specification's own;
 * - -erx_record build with the boot image's build identifier;
 * - for each device of the gives, a -erx_record drive record per drive on
 *   it (docs/design-fiasco.md, "Drive records"), so a domain learns the
 *   drives on what it holds and no other, before its -erx_record given or
 *   -erx_record framebuffer record if it has one;
 * - for a holder of a block device of a kind, -erx_record boot with the
 *   boot's pair;
 * - for the configured row that holds the system window alone
 *   (boot_system_image), -erx_record system_image from the manifest's
 *   system_image row, which the root's own page never carries.
 * All but the drive and system_image records are as the root's own page
 * carries them. A device of no kind, which its give marks not driven
 * (erx_dom_entry_driven), is held with its unit and has no record, so no
 * driver opens it, as the root writes none for the system domain's
 * (devices_read); nor has a framebuffer the tree did not place
 * (args_unrecorded). The plan check holds the gives to ERX_DOM_DEVICES_MAX
 * devices in all and the view their drives to ERX_DOM_DRIVES_MAX, so each
 * record has its words.
 */
size_t
erx_dom_args(const erx_dom_lib_t *lib, const erx_dom_plan_t *plan, const erx_dom_give_made_t *gives,
    erx_dom_args_t *out)
{
	const args_t args = { .lib = lib, .plan = plan, .gives = gives };
	const erx_dom_spec_t *spec = &plan->spec;
	const erx_dom_unit_plan_t *give;
	const erx_dom_device_entry_t *entry;
	erx_boot_words_t *runs = out->runs;
	size_t count = 0, length;
	uint32_t record = 0, drive = 0;
	bool block = false;

	if (spec->args_len != 0)
		runs[count++] = (erx_boot_words_t){ spec->strings, spec->args_len };
	if ((length = erx_boot_build_words(lib->build_id, out->build_words, sizeof(out->build_words))) == 0)
		return (0);
	runs[count++] = (erx_boot_words_t){ out->build_words, length };
	for (uint32_t at = 0; at < plan->ngives; at++) {
		give = &plan->gives[at];
		for (uint32_t d = 0; d < give->ndevices; d++) {
			entry = &lib->view.devices[give->devices[d].index];
			for (uint32_t n = 0; n < entry->ndrives; n++) {
				if (drive == ERX_DOM_DRIVES_MAX ||
				    (length = erx_boot_drive_words(entry->role, entry->drives[n].number, out->drive_words[drive],
				    sizeof(out->drive_words[drive]))) == 0)
					return (0);
				runs[count++] = (erx_boot_words_t){ out->drive_words[drive++], length };
			}
			if (!give->devices[d].driven || args_unrecorded(entry))
				continue;
			if (record == ERX_DOM_DEVICES_MAX ||
			    (length = args_given_words(&args, at, d, out->given_words[record],
			    sizeof(out->given_words[record]))) == 0)
				return (0);
			runs[count++] = (erx_boot_words_t){ out->given_words[record++], length };
			block = block || entry->role == ERX_MF_DEVICE_ROLE_BLOCK;
		}
	}
	if (block) {
		length = erx_boot_pair_words(lib->boot.value, lib->boot.slot, out->pair_words, sizeof(out->pair_words));
		if (length == 0)
			return (0);
		runs[count++] = (erx_boot_words_t){ out->pair_words, length };
	}
	if (lib->system_image_holder != 0 && erx_dom_from_row(&spec->origin, lib->system_image_holder - 1)) {
		length = erx_boot_system_image_words(&lib->system_image, lib->record_volume, out->system_image_words,
		    sizeof(out->system_image_words));
		if (length == 0)
			return (0);
		runs[count++] = (erx_boot_words_t){ out->system_image_words, length };
	}
	return (count);
}
