/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The system's program on the native root: binds the boot archive as the release, as the
 * hosted entry does its mapped file, fills the boot information page from the handoff
 * record, the manifest and the kernel command line, and enters musl's start path, whose
 * main is in runtime_main.c (docs/design-stopgap.md, "Boot information").
 */

#include <stdalign.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/core/boot_pair.h"
#include "erx/release.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/boot_info.h"
#include "liberx/backend/core/boot_manifest.h"
#include "erx/dom_lib.h"
#include "liberx/backend/fiasco/boot_args.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/runtime_entry.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/runtime_entry.h"

/*
 * The system domain's id is 4 because a domain's id is its node's creation and stock
 * ERTS gives no node a creation below 4 (docs/design-domains.md, "Domain ids, pids and
 * references"). It is a rule of the domain design, not an ABI constant: the hosted entry
 * names the same number.
 */
#define SYSTEM_DOMAIN_ID	4
#define MCPU_PER_CPU		1000

int	main(int, char **, char **);

static const char	*release_read(const erx_boot_handoff_view_t *, bool, erx_boot_manifest_t *);
static const char	*gather_args(const erx_boot_handoff_view_t *, const erx_boot_manifest_t *, size_t *);
static size_t		 boot_build(erx_boot_pair_t);
static size_t		 word_append(char *, size_t, size_t, const char *);
static const char	*library_view(const erx_manifest_view_t *, const erx_pack_view_t *);
static const char	*library_up(const erx_boot_handoff_view_t *);
static const char	*console_refusal(const erx_boot_manifest_t *, const erx_boot_handoff_view_t *);
static size_t		 line_append(char *, size_t, erx_boot_words_t);
static const char	*device_give(const erx_boot_device_t *, const erx_dom_device_entry_t *, char *, size_t, size_t *);
static const char	*tree_accept(void);
static const char	*tree_facts(void);
static const char	*device_memory(const erx_dom_device_entry_t *, uint64_t *, const char **);

/* The system domain's one domain library and the tables its view lies in (library_view). */
static erx_dom_lib_t library;
static erx_dom_boot_tables_t library_tables;

static alignas(ERX_PAGE_SIZE) uint8_t boot_page[ERX_PAGE_SIZE];
/*
 * The manifest's words, the console's, the boot pair's, the build's, each device record's, then
 * each erx.arg word, which takes a byte and its NUL at the least.
 */
static erx_boot_words_t arg_words[4 + ERX_BOOT_DEVICES_MAX + ERX_BOOT_STRINGS_MAX / 2];
/* -erx console_uart BASE SIZE LINE MARK CLOCK (erx_boot_console_words). */
static char console_uart_words[ERX_BOOT_CONSOLE_WORDS_MAX];
/* Each device record's words: the given form's, or the host link's physical one, which is shorter. */
static char device_words[ERX_BOOT_DEVICES_MAX][ERX_BOOT_GIVEN_WORDS_MAX];
/*
 * The firmware's device tree, accepted once before the first device asks it
 * (docs/design-device-tree.md, "Facts into records"), a device's path as the reader takes
 * it, ended by NUL, and the line the root prints for each device that asked.
 */
static erx_dt_t boot_tree;
static char tree_path[ERX_PATH_MAX];
static char tree_line[ERX_BOOT_TREE_LINE_MAX];
_Static_assert(ERX_BOOT_GIVEN_WORDS_MAX >= ERX_BOOT_DEVICE_WORDS_MAX, "a device record's room holds either form");
/* -erx boot VALUE SLOT: the longest names are "unknown" and "none", each with its NUL. */
static const char boot_prefix[] = "-erx\0boot";
static char boot_words[ERX_BOOT_PAIR_WORDS_MAX];
/* -erx build ID (erx_boot_build_words), the system domain's; the domain library writes every other domain's. */
static char build_words[ERX_BOOT_BUILD_WORDS_MAX];
_Static_assert(sizeof(((erx_boot_handoff_view_t *)0)->build_id) == sizeof(uint64_t),
    "the build identifier is one 64-bit number");

const erx_boot_info_t *
erx_boot_info(void)
{
	return ((const erx_boot_info_t *)(const void *)boot_page);
}

/*
 * The system domain's one domain library (docs/design-system.md, "The root task", step 3),
 * in two halves. library_view builds its view from the manifest and the archive, the device
 * catalogue among it, so the tree's facts join the catalogue's entries (tree_facts) before
 * any device is given, the root's own included; library_up brings the library up once the
 * system's boot page holds the values the library copies into every domain's. Its tables
 * come from the root budget, mapped for the root's life, and the library outlives the boot,
 * so both are never released.
 */
static const char *
library_view(const erx_manifest_view_t *manifest, const erx_pack_view_t *pack)
{
	const erx_dom_boot_sizes_t sizes = erx_dom_boot_sizes(manifest, pack);
	uint64_t addr, mem;
	size_t bytes;

	if (!erx_dom_boot_layout(&sizes, 0, &library_tables, &bytes) || bytes > SIZE_MAX - ERX_PAGE_SIZE)
		return ("the domain library: its tables do not fit the address space");
	bytes = (bytes + ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE * ERX_PAGE_SIZE;
	if (erx_mem_create(ERX_CAP_NULL, bytes, 0, &mem) != ERX_OK ||
	    erx_vm_reserve(ERX_CAP_SELF, 0, bytes, 0, &addr) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, addr, bytes, mem, 0, ERX_PROT_RW) != ERX_OK ||
	    !erx_dom_boot_layout(&sizes, (uintptr_t)addr, &library_tables, &bytes))
		return ("the domain library: the backend refused its tables");
	return (erx_dom_boot_view(&library, manifest, pack, &library_tables));
}

static const char *
library_up(const erx_boot_handoff_view_t *handoff)
{
	/* A block holder's boot page carries the pair, and every domain's page the build, as the root's own does. */
	library.boot = handoff->boot;
	library.build_id = erx_boot_handoff_build_id(handoff);
	return (erx_dom_boot_up(&library, erx_boot_info(), ERX_FIASCO_TASK_ROOT));
}

const char *
erx_fiasco_program_start(const erx_boot_handoff_view_t *handoff, const erx_manifest_view_t *view,
    const erx_pack_view_t *pack, const erx_boot_args_t *boot_args)
{
	erx_boot_inputs_t inputs = { 0 };
	erx_boot_manifest_t manifest;
	erx_boot_info_status_t status;
	const char *reason;
	uint64_t group;
	uint64_t cpuset;
	size_t nargs = 0;

	reason = release_read(handoff, boot_args->hostlink, &manifest);
	if (reason != NULL)
		return (reason);
	if (!erx_boot_console_matches(&manifest, handoff->stdout_path, handoff->stdout_path_len))
		return (console_refusal(&manifest, handoff));
	erx_fiasco_task_console_set(erx_boot_console_page(&manifest));
	reason = library_view(view, pack);
	if (reason != NULL)
		return (reason);
	reason = tree_facts();
	if (reason != NULL)
		return (reason);
	reason = gather_args(handoff, &manifest, &nargs);
	if (reason != NULL)
		return (reason);
	cpuset = view->header.system_share.cpuset & erx_fiasco_cpus_online();
	if (cpuset == 0)
		return ("manifest: the system's share names no CPU this machine has");
	if (erx_group_create(0, 0, &group) != ERX_OK)
		return ("the system's group: the backend refused it");
	if (boot_args->group_report) {
		reason = erx_fiasco_park_report_start();
		if (reason != NULL)
			return (reason);
	}
	inputs.domain_id = SYSTEM_DOMAIN_ID;
	inputs.flags = ERX_BOOT_ROOT | (boot_args->det ? ERX_BOOT_DET : 0);
	inputs.pack_flags = handoff->flags;
	inputs.capacity_mcpu = MCPU_PER_CPU * (uint32_t)__builtin_popcountll(cpuset);
	inputs.space = (erx_cap_t){ .raw = ERX_CAP_SELF };
	inputs.group = (erx_cap_t){ .raw = group };
	inputs.time_page = (erx_cap_t){ .raw = erx_fiasco_time_object() };
	inputs.release_addr = (uint64_t)(uintptr_t)erx_release_addr();
	inputs.cpuset = cpuset;
	inputs.node = manifest.node;
	inputs.node_len = manifest.node_len;
	inputs.args = arg_words;
	inputs.nargs = nargs;
	inputs.limits = manifest.limits;
	status = erx_boot_info_build(&inputs, boot_page, sizeof(boot_page));
	if (status != ERX_BOOT_INFO_OK)
		return (erx_boot_info_reason(status));
	reason = library_up(handoff);
	if (reason != NULL)
		return (reason);
	erx_fiasco_libc_root_start(main);
}

/*
 * The device service's refusal of a console that is not the UART
 * /chosen/stdout-path names (docs/design-system.md, "Devices"), naming both
 * paths. Each is printed only as a node path (erx_boot_node_path_valid), which
 * is ASCII without controls, and cut at ERX_BOOT_STDOUT_PATH_MAX bytes; the
 * handoff's path is always one, and a manifest path that is not one is named
 * by a fixed word.
 */
static const char *
console_refusal(const erx_boot_manifest_t *manifest, const erx_boot_handoff_view_t *handoff)
{
	static const char console_is[] = "manifest: the console ";
	static const char stdout_is[] = " is not the node /chosen/stdout-path names, ";
	static const char no_node[] = "(none)";
	static const char not_node[] = "(not a node path)";
	static char line[sizeof(console_is) + sizeof(stdout_is) + 2 * ERX_BOOT_STDOUT_PATH_MAX];
	const erx_boot_words_t console = erx_boot_node_path_valid((const uint8_t *)manifest->console_path.bytes,
	    manifest->console_path.length) ? manifest->console_path : (erx_boot_words_t){ not_node, sizeof(not_node) - 1 };
	const erx_boot_words_t node = handoff->stdout_path_len == 0 ? (erx_boot_words_t){ no_node, sizeof(no_node) - 1 } :
	    (erx_boot_words_t){ handoff->stdout_path, handoff->stdout_path_len };
	size_t used = 0;

	used = line_append(line, used, (erx_boot_words_t){ console_is, sizeof(console_is) - 1 });
	used = line_append(line, used, console);
	used = line_append(line, used, (erx_boot_words_t){ stdout_is, sizeof(stdout_is) - 1 });
	used = line_append(line, used, node);
	line[used] = '\0';
	return (line);
}

/* Appends at most ERX_BOOT_STDOUT_PATH_MAX bytes of words at line + used; returns the new length. */
static size_t
line_append(char *line, size_t used, erx_boot_words_t words)
{
	const size_t length = words.length < ERX_BOOT_STDOUT_PATH_MAX ? words.length : ERX_BOOT_STDOUT_PATH_MAX;

	for (size_t at = 0; at < length; at++)
		line[used + at] = words.bytes[at];
	return (used + length);
}

/*
 * Binds the boot archive as the release, then reads its manifest into *manifest. The
 * archive is the one sigma0 mapped one to one for the root's life. The host link's record is
 * there only under erx.hostlink=1 (hostlink). Returns NULL, or the reason the archive or its
 * manifest was refused.
 */
static const char *
release_read(const erx_boot_handoff_view_t *handoff, bool hostlink, erx_boot_manifest_t *manifest)
{
	const uint8_t *bytes;
	const char *reason;
	size_t length;

	if (erx_release_bind((const uint8_t *)(uintptr_t)handoff->image.start, (size_t)handoff->image.size, &reason) != 0 ||
	    erx_release_manifest(&bytes, &length, &reason) != 0 ||
	    !erx_boot_manifest_read(bytes, length, hostlink, manifest, &reason))
		return (reason);
	return (NULL);
}

/*
 * The manifest's system_args, what its driver opens of the console's device entry, the boot
 * value and slot of the handoff, the boot image's build identifier, which the host link's hello
 * reports (docs/design-live.md, "The host link"), each device record (docs/design-stopgap.md, "Device records"),
 * then each erx.arg word of the kernel command line, in its order. A plain word joins the flag
 * before it, which erx_pl011 expects. A manifest with no console entry has no such words, and
 * the driver's start then says why the console has none.
 */
static const char *
gather_args(const erx_boot_handoff_view_t *handoff, const erx_boot_manifest_t *manifest, size_t *nargs)
{
	size_t cursor = 0;
	const char *word;
	size_t word_len;
	size_t boot_length;
	size_t build_length;
	const char *reason;

	arg_words[(*nargs)++] = manifest->system_args;
	if (manifest->console.size != 0) {
		const size_t console_length = erx_boot_console_words(&manifest->console, console_uart_words,
		    sizeof(console_uart_words));

		if (console_length == 0)
			return ("the console: its words outgrow their room");
		arg_words[(*nargs)++] = (erx_boot_words_t){ console_uart_words, console_length };
	}
	boot_length = boot_build(handoff->boot);
	if (boot_length == 0)
		return ("the handoff: a boot value or slot that has no name");
	arg_words[(*nargs)++] = (erx_boot_words_t){ boot_words, boot_length };
	build_length = erx_boot_build_words(erx_boot_handoff_build_id(handoff), build_words, sizeof(build_words));
	if (build_length == 0)
		return ("the handoff: the build identifier's words outgrow their room");
	arg_words[(*nargs)++] = (erx_boot_words_t){ build_words, build_length };
	for (size_t at = 0; at < manifest->device_count; at++) {
		const erx_boot_device_t *const device = &manifest->devices[at];
		size_t length = 0;

		if (device->given) {
			/* The view has one catalogue entry per manifest device row, the device's among them. */
			if (device->index >= library.view.ndevices)
				return ("a device record: its row has no catalogue entry");
			if ((reason = device_give(device, &library.view.devices[device->index], device_words[at],
			    sizeof(device_words[at]), &length)) != NULL)
				return (reason);
		} else {
			length = erx_boot_device_words(device, device_words[at], sizeof(device_words[at]));
		}
		if (length == 0)
			return ("a device record: its words outgrow their room");
		arg_words[(*nargs)++] = (erx_boot_words_t){ device_words[at], length };
	}
	while (erx_boot_args_next_arg(handoff->bootargs, handoff->bootargs_len, &cursor, &word, &word_len)) {
		if (*nargs == sizeof(arg_words) / sizeof(arg_words[0]))
			return ("the kernel command line: more erx.arg words than the page holds");
		arg_words[(*nargs)++] = (erx_boot_words_t){ word, word_len };
	}
	return (NULL);
}

/*
 * Accepts the firmware's device tree into boot_tree, once, before any device asks it
 * (docs/design-device-tree.md, "Facts into records"). Returns NULL, or why the root cannot
 * boot: the handoff carries no tree, or the reader refused it, naming its fixed reason.
 */
static const char *
tree_accept(void)
{
	static const char refused[] = "the device tree: ";
	static char line[sizeof(refused) + ERX_BOOT_STDOUT_PATH_MAX];
	const void *bytes;
	const char *reason;
	size_t size, length = 0, used;

	if (erx_boot_tree(&bytes, &size) != ERX_OK)
		return ("the device tree: the handoff carries none");
	if ((reason = erx_dt_accept(bytes, size, &boot_tree)) == NULL)
		return (NULL);
	while (reason[length] != '\0')
		length++;
	used = line_append(line, 0, (erx_boot_words_t){ refused, sizeof(refused) - 1 });
	used = line_append(line, used, (erx_boot_words_t){ reason, length });
	line[used] = '\0';
	return (line);
}

/*
 * Accepts the firmware's device tree (tree_accept) and joins its facts to the catalogue's
 * entries once, before any device is given (docs/design-device-tree.md, "Facts into
 * records"). A row of a kind a runtime drives (its role_word is set) that asks (erx_boot_row_asks) has its facts read from boot_tree
 * at its node path, and every entry's DMA memory becomes what its facts admit
 * (erx_boot_dma_memory), so a row that asked nothing gets none. The root prints the line of
 * each asking row a holder holds; the line of a row the system domain holds waits for the
 * root's own give, which makes its memory first (device_give). Returns NULL, or why the root
 * cannot boot: the tree is refused, or a row that asks names a path that is not a node path.
 */
static const char *
tree_facts(void)
{
	const char *reason;
	size_t length;

	if ((reason = tree_accept()) != NULL)
		return (reason);
	for (uint32_t index = 0; index < library.view.ndevices; index++) {
		erx_dom_device_entry_t *const entry = &library_tables.devices[index];
		const bool network = entry->role == ERX_MF_DEVICE_ROLE_NETWORK;
		const uint64_t row_memory = entry->memory;
		const erx_boot_words_t path = { entry->path, entry->path_len };

		entry->asked = entry->role_word != NULL && erx_boot_row_asks(row_memory, network);
		if (entry->asked) {
			if (path.length == 0 || path.length >= sizeof(tree_path) ||
			    !erx_boot_node_path_valid((const uint8_t *)path.bytes, path.length))
				return ("a device record: its device-tree path is not a node path");
			for (size_t at = 0; at < path.length; at++)
				tree_path[at] = path.bytes[at];
			tree_path[path.length] = '\0';
			erx_dt_device(&boot_tree, tree_path, ERX_DT_ROW_NODE, &entry->facts);
		}
		entry->memory = erx_boot_dma_memory(entry->asked ? &entry->facts : NULL, row_memory);
		if (entry->asked && entry->row != ERX_MF_NONE && (length = erx_boot_tree_line(path, row_memory, network,
		    &entry->facts, NULL, tree_line, sizeof(tree_line))) != 0)
			erx_fiasco_console_write(tree_line, length);
	}
	return (NULL);
}

/*
 * The root's own give of a device the system domain holds (docs/design-stopgap.md, "Device
 * records"), whose catalogue entry is entry. It makes in the root's own table the objects a
 * holder's creation makes: the register window over the pages of the device's registers,
 * its line's IRQ object and, when the entry admits DMA memory, its contiguous memory for the
 * boot (device_memory). A device whose entry asked the firmware's tree has the root print
 * its facts' line. It then writes the -erx given record (erx_boot_device_given) from the
 * entry's facts into words, capacity bytes, with *length its whole length, 0 when it does
 * not fit.
 *
 * Nothing deletes the objects: the system domain holds the device for the boot, and a
 * fault of the system domain resets the machine. Returns NULL, or why the root cannot
 * boot: the backend refused an object, so the device would have no driver.
 */
static const char *
device_give(const erx_boot_device_t *device, const erx_dom_device_entry_t *entry, char *words, size_t capacity,
    size_t *length)
{
	const erx_dt_device_t *const facts = entry->asked ? &entry->facts : NULL;
	uint64_t window_handle, line_handle, memory_handle = ERX_CAP_NULL;
	const char *absent = NULL, *reason;
	erx_boot_window_t window;
	erx_boot_given_t given;
	size_t line_length;

	if (!erx_boot_device_window(device, &window))
		return ("a device record: its registers are empty or wrap");
	if (erx_mem_create_physical(ERX_CAP_NULL, ERX_CAP_NULL, window.base, window.size, ERX_MEM_ATTR_DEVICE,
	    &window_handle) != ERX_OK)
		return ("a device record: the backend refused its register window");
	if (erx_irq_create(ERX_CAP_NULL, ERX_CAP_NULL, ERX_IRQ_LINE, device->line, &line_handle) != ERX_OK)
		return ("a device record: the backend refused its line");
	if (entry->memory != 0 && (reason = device_memory(entry, &memory_handle, &absent)) != NULL)
		return (reason);
	if (facts != NULL && (line_length = erx_boot_tree_line(device->path, device->dma_memory, device->network, facts,
	    absent, tree_line, sizeof(tree_line))) != 0)
		erx_fiasco_console_write(tree_line, line_length);
	given = erx_boot_device_given(device, &window, facts, window_handle, line_handle, memory_handle);
	*length = erx_boot_given_words(&given, words, capacity);
	return (NULL);
}

/*
 * The contiguous memory of a device whose catalogue entry admits some (tree_facts, so the
 * entry asked and its facts have a range the memory may lie in). The backend places the
 * run inside that range, and a pool the range does not cover (ERX_ERANGE) gives none, with
 * the reason "outside". erx_boot_dma_absent then checks the device address the object
 * gives, so a device never gets memory outside its range whatever the backend did.
 * *memory is the object, or ERX_CAP_NULL for none, and *absent the reason for none, NULL
 * when the device has its memory. An object made and then refused stays, unused, in the
 * root's table (TODO.md). Returns NULL, or why the root cannot boot: the backend refused
 * the memory otherwise, or its device address.
 */
static const char *
device_memory(const erx_dom_device_entry_t *entry, uint64_t *memory, const char **absent)
{
	const erx_mem_dma_range_t range = { .cpu = entry->facts.cpu, .bus = entry->facts.bus, .last = entry->facts.last };
	uint64_t made, address;
	int status;

	status = erx_mem_create_contiguous_in(ERX_CAP_NULL, entry->memory, &range, &made);
	if (status == ERX_ERANGE) {
		*absent = "outside";
		return (NULL);
	}
	if (status != ERX_OK)
		return ("a device record: the backend refused its DMA memory");
	if (erx_mem_dma_addr(made, 0, &address) != ERX_OK)
		return ("a device record: the backend refused its DMA memory's device address");
	if ((*absent = erx_boot_dma_absent(&entry->facts, address, entry->memory)) == NULL)
		*memory = made;
	return (NULL);
}

/*
 * Writes -erx boot VALUE SLOT into boot_words, by the names of include/erx/core/boot_pair.h
 * (docs/design-stopgap.md, "Boot information"), and returns their whole length, the last NUL
 * included, or 0 for a value or slot that has no name. The handoff's reader accepts only a
 * valid pair, so a pair always has its names, and boot_words holds the longest two.
 */
static size_t
boot_build(erx_boot_pair_t boot)
{
	const char *value = erx_boot_value_name(boot.value);
	const char *slot = erx_boot_slot_name(boot.slot);
	size_t used = sizeof(boot_prefix);

	if (value == NULL || slot == NULL)
		return (0);
	for (size_t at = 0; at < used; at++)
		boot_words[at] = boot_prefix[at];
	used = word_append(boot_words, sizeof(boot_words), used, value);
	if (used != 0)
		used = word_append(boot_words, sizeof(boot_words), used, slot);
	return (used);
}

/* NAME and its NUL at WORDS + USED, within SIZE bytes; returns the new length, or 0 if they do not fit. */
static size_t
word_append(char *words, size_t size, size_t used, const char *name)
{
	size_t at = 0;

	do {
		if (used + at == size)
			return (0);
		words[used + at] = name[at];
	} while (name[at++] != '\0');
	return (used + at);
}
