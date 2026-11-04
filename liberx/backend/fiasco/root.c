/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The native root task on Fiasco: it finds bootstrap's handoff record through
 * the kernel information page, accepts it, opens the archive the record names,
 * checks the archive's last entry, reports what it saw on the console, and
 * powers off (docs/design-stopgap.md, "Boot handoff").
 *
 * Only this one thread exists. Every page it reads comes from a page fault that
 * sigma0 answers one to one, with the rights bootstrap gave the page's region;
 * that is what keeps the handoff page and the archive read-only. A refusal
 * prints its reason and ends the machine, with no crash record.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sigma0/sigma0.h>
#include <l4/sys/consts.h>
#include <l4/sys/kip.h>

#include "erx/abi.h"
#include "erx/core/boot_handoff.h"
#include "erx/pack.h"
#include "kernel/crypto/blake3/blake3.h"
#include "liberx/backend/fiasco/console.h"

/* Where the root sees the kernel information page: no RAM on QEMU virt is here. */
#define ERX_ROOT_KIP_WINDOW	UINT64_C(0x10000000)
/* The longest line: the identifiers' digits, two counts and the words around. */
#define ERX_ROOT_LINE_MAX	256

/* The report's words, its identifiers as digits, and two 32-bit counts. */
_Static_assert(ERX_ROOT_LINE_MAX >= 64 +
    2 * (sizeof(((erx_boot_handoff_view_t *)0)->build_id) +
    sizeof(((erx_boot_handoff_view_t *)0)->index_hash)) + 2 * 10,
    "the root task's report fits one line");

void erx_fiasco_root_main(void);

static void root_append(char *, size_t *, const char *);
static void root_append_decimal(char *, size_t *, uint32_t);
static void root_append_hex(char *, size_t *, const uint8_t *, size_t);
static const char *root_boot(void);
static bool root_bytes_equal(const uint8_t *, const uint8_t *, size_t);
static _Noreturn void root_refuse(const char *);
static void root_report(const erx_boot_handoff_view_t *, uint32_t);

/* No stack holds these: the archive's checks want them large and long-lived. */
static erx_blake3_ctx_t root_hasher;
static erx_pack_scratch_t root_scratch;

void
erx_fiasco_root_main(void)
{
	const char *reason;

	reason = root_boot();
	if (reason != NULL)
		root_refuse(reason);
	erx_fiasco_machine_off();
}

static const char *
root_boot(void)
{
	const l4_kernel_info_t *kip;
	erx_boot_handoff_view_t handoff;
	erx_pack_view_t pack;
	erx_pack_error_t pack_error = { 0 };
	const char *reason;

	kip = l4sigma0_map_kip(L4_BASE_PAGER_CAP, (void *)ERX_ROOT_KIP_WINDOW,
	    L4_PAGESHIFT);
	if (kip == NULL)
		return ("kernel information page: not mapped");

	/* A kernel started without bootstrap's handoff page has a user_ptr of 0. */
	reason = erx_boot_handoff_accept((const uint8_t *)(uintptr_t)kip->user_ptr,
	    ERX_BOOT_HANDOFF_SIZE, &handoff);
	if (reason != NULL)
		return (reason);

	if (!erx_pack_open((const uint8_t *)(uintptr_t)handoff.image.start,
	    (size_t)handoff.image.size, &root_scratch, &root_hasher, &pack,
	    &pack_error))
		return (pack_error.reason);
	if (!root_bytes_equal(pack.header.index_hash, handoff.index_hash,
	    sizeof(handoff.index_hash)))
		return ("archive is not the one the record names");

	/*
	 * Entries lie in the archive in index order, so the last one's run is the
	 * archive's end: reading it shows the whole range reached this task.
	 */
	if (!erx_pack_file_check(&pack, pack.header.nentries - 1, &root_hasher,
	    &pack_error))
		return (pack_error.reason);
	root_report(&handoff, pack.header.nentries);
	return (NULL);
}

static bool
root_bytes_equal(const uint8_t *first, const uint8_t *second, size_t length)
{
	for (size_t index = 0; index < length; index++)
		if (first[index] != second[index])
			return (false);
	return (true);
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
root_append_decimal(char *line, size_t *used, uint32_t value)
{
	char digits[10];
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
