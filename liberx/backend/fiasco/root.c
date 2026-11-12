/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The native root task on Fiasco: it finds bootstrap's handoff record through
 * the kernel information page, accepts it, opens the archive the record names,
 * checks the archive's last entry, reads the system manifest, takes the machine's
 * memory from sigma0 into the pool and refuses the boot if that falls short of the
 * manifest's root_memory, starts the root service, reports what it saw on the
 * console, and runs its program, ERTS, through musl's start path
 * (docs/design-stopgap.md, "Boot handoff").
 *
 * Until erx_fiasco_root_up returns, only this one thread exists, and every page
 * it reads comes from a page fault that sigma0 answers one to one, with the
 * rights bootstrap gave the page's region; that is what keeps the handoff page
 * and the archive read-only. A refusal prints its reason and ends the machine,
 * with no crash record.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/core/boot_handoff.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/runtime_entry.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/vm.h"
#include "liberx/backend/fiasco/watchdog_thread.h"

/* The longest line: a refusal that names two device-tree paths of ERX_BOOT_STDOUT_PATH_MAX bytes. */
#define ERX_ROOT_LINE_MAX	640

/* The report's words, its identifiers as digits, and two 32-bit counts. */
_Static_assert(ERX_ROOT_LINE_MAX >= 64 +
    2 * (sizeof(((erx_boot_handoff_view_t *)0)->build_id) +
    sizeof(((erx_boot_handoff_view_t *)0)->index_hash)) + 2 * 10,
    "the root task's report fits one line");
_Static_assert(ERX_ROOT_LINE_MAX >= 128 + 2 * ERX_BOOT_STDOUT_PATH_MAX,
    "the console refusal and its words fit one line");

extern char erx_fiasco_image_start[];
extern char erx_fiasco_image_end[];

ERX_DECLARE_ABI_NOTE(erx_fiasco_root_abi_note);

/*
 * The archive's view outlives the boot: the service slices and maps the image's
 * entries through it for every domain the domain library builds (slice.c), and
 * the library's view reads its entries. Its bytes are the handoff's image, mapped
 * for the root's life.
 */
static erx_pack_view_t root_pack;

void erx_fiasco_root_main(void);

static void root_append(char *, size_t *, const char *);
static void root_append_decimal(char *, size_t *, uint64_t);
static void root_append_hex(char *, size_t *, const uint8_t *, size_t);
static const char *root_boot(erx_boot_handoff_view_t *, erx_manifest_view_t *, erx_boot_args_t *);
static uint64_t root_image_bytes(void);
static bool root_memory_fits(uint64_t, uint64_t, uint64_t);
static _Noreturn void root_refuse(const char *);
static void root_report(const erx_boot_handoff_view_t *, uint32_t);
static void root_report_manifest(const erx_manifest_view_t *, uint64_t);
static void root_report_watchdog(const erx_watchdog_config_t *, erx_watchdog_mode_t);

void
erx_fiasco_root_main(void)
{
	erx_boot_handoff_view_t handoff;
	erx_manifest_view_t manifest;
	erx_boot_args_t boot_args;
	const char *reason;

	reason = root_boot(&handoff, &manifest, &boot_args);
	if (reason == NULL)
		reason = erx_fiasco_program_start(&handoff, &manifest, &root_pack, &boot_args);
	root_refuse(reason);
}

static const char *
root_boot(erx_boot_handoff_view_t *handoff, erx_manifest_view_t *manifest, erx_boot_args_t *boot_args)
{
	const char *reason;

	reason = erx_fiasco_root_open(handoff, &root_pack);
	if (reason != NULL)
		return (reason);
	erx_fiasco_task_set_archive(&root_pack);
	erx_fiasco_service_boot(handoff);
	reason = erx_fiasco_root_read_manifest(&root_pack, manifest);
	if (reason != NULL)
		return (reason);
	if (!erx_boot_args_parse(handoff->bootargs, handoff->bootargs_len, boot_args))
		return ("the kernel command line: a word of erx. that this build refuses");
	reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff->image.start,
	    (size_t)handoff->image.size);
	if (reason != NULL)
		return (reason);
	const uint64_t free_pages = erx_fiasco_vm_free_pages();

	if (!root_memory_fits(free_pages, root_image_bytes(), manifest->header.root_memory))
		return ("manifest: root_memory is more than this machine gives the root");
	const erx_watchdog_config_t config = boot_args->have_watchdog ? boot_args->watchdog :
	    erx_watchdog_config_default();
	const erx_watchdog_mode_t mode = boot_args->det ? ERX_WATCHDOG_MODE_DETERMINISTIC : ERX_WATCHDOG_MODE_NORMAL;

	reason = erx_fiasco_watchdog_start(&config, mode);
	if (reason != NULL)
		return (reason);
	root_report(handoff, root_pack.header.nentries);
	root_report_manifest(manifest, free_pages);
	root_report_watchdog(&config, mode);
	return (NULL);
}

/* The bytes of the root's own image, which root_memory counts beside the pool. */
static uint64_t
root_image_bytes(void)
{
	return ((uint64_t)(erx_fiasco_image_end - erx_fiasco_image_start));
}

/*
 * Whether the pool and the image hold what the manifest gives the root. The pool
 * has by now paid for its page index and the root's thread table. The packer holds
 * the archive to the same rule, counting those and the rest of what the boot keeps
 * (RootStartup.check_archive in tools/lib/erx/manifest.rb). The page count is
 * bounded by the machine's RAM, so the sum stays far from the width of the type.
 */
static bool
root_memory_fits(uint64_t free_pages, uint64_t image_bytes, uint64_t root_memory)
{
	return (free_pages * ERX_PAGE_SIZE + image_bytes >= root_memory);
}

static void
root_append(char *line, size_t *used, const char *text)
{
	while (*text != '\0' && *used < ERX_ROOT_LINE_MAX)
		line[(*used)++] = *text++;
}

static void
root_append_hex(char *line, size_t *used, const uint8_t *bytes, size_t length)
{
	static const char digits[] = "0123456789abcdef";

	for (size_t index = 0; index < length && *used + 2 <= ERX_ROOT_LINE_MAX; index++) {
		line[(*used)++] = digits[bytes[index] >> 4];
		line[(*used)++] = digits[bytes[index] & 0xf];
	}
}

static void
root_append_decimal(char *line, size_t *used, uint64_t value)
{
	char digits[20];
	size_t count = 0;

	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	while (count > 0 && *used < ERX_ROOT_LINE_MAX)
		line[(*used)++] = digits[--count];
}

/*
 * One line, so a transcript test reads it whole: what the record says, and how
 * many entries the archive it read holds.
 */
static void
root_report(const erx_boot_handoff_view_t *handoff, uint32_t entries)
{
	char line[ERX_ROOT_LINE_MAX];
	size_t used = 0;

	root_append(line, &used, "erx: root task: build ");
	root_append_hex(line, &used, handoff->build_id, sizeof(handoff->build_id));
	root_append(line, &used, " index ");
	root_append_hex(line, &used, handoff->index_hash, sizeof(handoff->index_hash));
	root_append(line, &used, " entries ");
	root_append_decimal(line, &used, entries);
	root_append(line, &used, "\n");
	erx_fiasco_console_write(line, used);
}

/*
 * What the root read of the manifest, as numbers only: its strings stay off the console.
 * The pool's free pages, as root_boot read them once, and the root's image are what
 * root_memory_fits counted, from which the production image suite works out what the
 * boot kept besides.
 */
static void
root_report_manifest(const erx_manifest_view_t *manifest, uint64_t free_pages)
{
	char line[ERX_ROOT_LINE_MAX];
	size_t used = 0;

	root_append(line, &used, "erx: root task: manifest root_memory ");
	root_append_decimal(line, &used, manifest->header.root_memory);
	root_append(line, &used, " baseline ");
	root_append_decimal(line, &used, manifest->header.system_baseline);
	root_append(line, &used, " units ");
	root_append_decimal(line, &used, manifest->header.units.count);
	root_append(line, &used, " pool pages ");
	root_append_decimal(line, &used, free_pages);
	root_append(line, &used, " image ");
	root_append_decimal(line, &used, root_image_bytes());
	root_append(line, &used, "\n");
	erx_fiasco_console_write(line, used);
}

/* What the watchdog runs with. In deterministic mode the step machine keeps it off, whatever the numbers say. */
static void
root_report_watchdog(const erx_watchdog_config_t *config, erx_watchdog_mode_t mode)
{
	char line[ERX_ROOT_LINE_MAX];
	size_t used = 0;

	root_append(line, &used, "erx: root task: watchdog ");
	if (mode == ERX_WATCHDOG_MODE_DETERMINISTIC) {
		root_append(line, &used, "off");
	} else {
		root_append_decimal(line, &used, config->period_s);
		root_append(line, &used, ",");
		root_append_decimal(line, &used, config->deadline_s);
		root_append(line, &used, ",");
		root_append_decimal(line, &used, config->boot_s);
	}
	root_append(line, &used, "\n");
	erx_fiasco_console_write(line, used);
}

static _Noreturn void
root_refuse(const char *reason)
{
	char line[ERX_ROOT_LINE_MAX];
	size_t used = 0;

	root_append(line, &used, "erx: root task refused the boot: ");
	root_append(line, &used, reason);
	root_append(line, &used, "\n");
	erx_fiasco_console_write(line, used);
	erx_fiasco_machine_off();
}
