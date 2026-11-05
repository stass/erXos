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

static alignas(ERX_PAGE_SIZE) uint8_t boot_page[ERX_PAGE_SIZE];
/* The manifest's words, then each erx.arg word, which takes a byte and its NUL at the least. */
static erx_boot_words_t arg_words[2 + ERX_BOOT_STRINGS_MAX / 2];
/* The driver erx_console starts, until the PL011 has one: output through the debug log. */
static const char console_driver_words[] = "-erx\0console_driver\0erx_debug_console";

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
	reason = gather_args(handoff, &manifest, &nargs);
	if (reason != NULL)
		return (reason);
	cpuset = view->header.system_share.cpuset & erx_fiasco_cpus_online();
	if (cpuset == 0)
		return ("manifest: the system's share names no CPU this machine has");
	if (erx_group_create(0, 0, &group) != ERX_OK)
		return ("the system's group: the backend refused it");
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

/* The manifest's system_args, the console's driver, then each erx.arg word of the kernel command line, in its order. */
static const char *
gather_args(const erx_boot_handoff_view_t *handoff, const erx_boot_manifest_t *manifest, size_t *nargs)
{
	size_t cursor = 0;
	const char *word;
	size_t word_len;

	arg_words[(*nargs)++] = manifest->system_args;
	arg_words[(*nargs)++] = (erx_boot_words_t){ console_driver_words, sizeof(console_driver_words) };
	while (erx_boot_args_next_arg(handoff->bootargs, handoff->bootargs_len, &cursor, &word, &word_len)) {
		if (*nargs == sizeof(arg_words) / sizeof(arg_words[0]))
			return ("the kernel command line: more erx.arg words than the page holds");
		arg_words[(*nargs)++] = (erx_boot_words_t){ word, word_len };
	}
	return (NULL);
}
