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
#include "erx/release.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/boot_info.h"
#include "liberx/backend/core/boot_manifest.h"
#include "liberx/backend/fiasco/boot_args.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/runtime_entry.h"
#include "liberx/backend/fiasco/service.h"
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

static const char	*release_read(const erx_boot_handoff_view_t *, erx_boot_manifest_t *);
static const char	*gather_args(const erx_boot_handoff_view_t *, const erx_boot_manifest_t *, size_t *);
static size_t		 console_uart_build(const erx_boot_console_t *);
static size_t		 console_uart_number(char *, uint64_t);
static const char	*console_refusal(const erx_boot_manifest_t *, const erx_boot_handoff_view_t *);
static size_t		 line_append(char *, size_t, erx_boot_words_t);

static alignas(ERX_PAGE_SIZE) uint8_t boot_page[ERX_PAGE_SIZE];
/*
 * The manifest's words, the console's, each device record's, then each erx.arg word, which
 * takes a byte and its NUL at the least.
 */
static erx_boot_words_t arg_words[2 + ERX_BOOT_DEVICES_MAX + ERX_BOOT_STRINGS_MAX / 2];
/* -erx console_uart BASE SIZE LINE: three numbers, each at most UINT64_MAX's 20 digits and its NUL. */
#define CONSOLE_UART_NUMBER_MAX	(20 + 1)
static const char console_uart_prefix[] = "-erx\0console_uart";
static char console_uart_words[sizeof(console_uart_prefix) + 3 * CONSOLE_UART_NUMBER_MAX];
_Static_assert(sizeof(console_uart_words) >= sizeof(console_uart_prefix) + 3 * CONSOLE_UART_NUMBER_MAX,
    "the console words hold the prefix and three numbers");
static char device_words[ERX_BOOT_DEVICES_MAX][ERX_BOOT_DEVICE_WORDS_MAX];

const erx_boot_info_t *
erx_boot_info(void)
{
	return ((const erx_boot_info_t *)(const void *)boot_page);
}

const char *
erx_fiasco_program_start(const erx_boot_handoff_view_t *handoff, const erx_manifest_view_t *view,
    const erx_boot_args_t *boot_args)
{
	erx_boot_inputs_t inputs = { 0 };
	erx_boot_manifest_t manifest;
	erx_boot_info_status_t status;
	const char *reason;
	uint64_t group;
	uint64_t cpuset;
	size_t nargs = 0;

	reason = release_read(handoff, &manifest);
	if (reason != NULL)
		return (reason);
	if (!erx_boot_console_matches(&manifest, handoff->stdout_path, handoff->stdout_path_len))
		return (console_refusal(&manifest, handoff));
	erx_fiasco_task_console_set(manifest.console.base);
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
	inputs.group = (erx_cap_t){ .raw = group };
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
 * archive is the one sigma0 mapped one to one for the root's life. Returns NULL, or the
 * reason the archive or its manifest was refused.
 */
static const char *
release_read(const erx_boot_handoff_view_t *handoff, erx_boot_manifest_t *manifest)
{
	const uint8_t *bytes;
	const char *reason;
	size_t length;

	if (erx_release_bind((const uint8_t *)(uintptr_t)handoff->image.start, (size_t)handoff->image.size, &reason) != 0 ||
	    erx_release_manifest(&bytes, &length, &reason) != 0 ||
	    !erx_boot_manifest_read(bytes, length, manifest, &reason))
		return (reason);
	return (NULL);
}

/*
 * The manifest's system_args, what its driver opens of the console's device entry, each device
 * record (docs/design-stopgap.md, "Device records"), then each erx.arg word of the kernel
 * command line, in its order. A plain word joins the flag before
 * it, which erx_pl011 expects. A manifest with no console entry has no such words, and the
 * driver's start then says why the console has none.
 */
static const char *
gather_args(const erx_boot_handoff_view_t *handoff, const erx_boot_manifest_t *manifest, size_t *nargs)
{
	size_t cursor = 0;
	const char *word;
	size_t word_len;

	arg_words[(*nargs)++] = manifest->system_args;
	if (manifest->console.size != 0)
		arg_words[(*nargs)++] = (erx_boot_words_t){ console_uart_words,
		    console_uart_build(&manifest->console) };
	for (size_t at = 0; at < manifest->device_count; at++) {
		const size_t length = erx_boot_device_words(&manifest->devices[at], device_words[at], sizeof(device_words[at]));

		if (length == 0)
			return ("a device record: its words outgrow ERX_BOOT_DEVICE_WORDS_MAX");
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
 * Writes the words into console_uart_words and returns their whole length, the last NUL
 * included. The buffer holds the prefix and three numbers of at most CONSOLE_UART_NUMBER_MAX
 * bytes each, as its _Static_assert says, so no write can fail.
 */
static size_t
console_uart_build(const erx_boot_console_t *console)
{
	size_t used = sizeof(console_uart_prefix);

	for (size_t at = 0; at < used; at++)
		console_uart_words[at] = console_uart_prefix[at];
	used += console_uart_number(console_uart_words + used, console->base);
	used += console_uart_number(console_uart_words + used, console->size);
	used += console_uart_number(console_uart_words + used, console->line);
	return (used);
}

/* VALUE in decimal and its NUL at WORD, at most CONSOLE_UART_NUMBER_MAX bytes; returns their count. */
static size_t
console_uart_number(char *word, uint64_t value)
{
	char digits[CONSOLE_UART_NUMBER_MAX - 1];
	size_t count = 0;
	size_t used = 0;

	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	while (count > 0)
		word[used++] = digits[--count];
	word[used++] = '\0';
	return (used);
}
