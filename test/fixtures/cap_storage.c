/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The storage contract of a capability table, driven from outside the
 * core as its owner sees it: only erx/cap.h, so a table, its directory
 * and its pages are untyped storage. erx_cap_table_init and
 * erx_cap_table_add_page refuse storage that is missing, misaligned or
 * too small, and a page that overlaps one the table already holds or its
 * directory, since slots written over a page already in use would give a
 * retired or live slot a fresh generation. Exits 0 when every case holds,
 * and prints the first one that does not.
 */

#include <stdalign.h>
#include <stdio.h>

#include "erx/cap.h"

#define STORAGE_LIMIT	(2 * ERX_CAP_PAGE_SLOTS)
#define STORAGE_PAGE	(ERX_CAP_PAGE_SLOTS * ERX_CAP_SLOT_SIZE)

static alignas(64) unsigned char table[256];
static alignas(64) unsigned char directory[64];
static alignas(64) unsigned char pages[3][STORAGE_PAGE];

static int
expect(const char *name, erx_status_t got, erx_status_t want)
{
	if (got == want)
		return (0);
	printf("%s: status %d, expected %d\n", name, got, want);
	return (1);
}

int
main(void)
{
	erx_cap_table_t *t = (erx_cap_table_t *)(void *)table;
	size_t dirsize = erx_cap_directory_size(STORAGE_LIMIT);
	int bad = 0;

	if (erx_cap_table_size() > sizeof(table) ||
	    erx_cap_table_align() > 64 || dirsize > sizeof(directory) ||
	    erx_cap_directory_size(1) != 0 ||
	    erx_cap_directory_size(ERX_CAPS_MAX + 1) != 0) {
		printf("sizes\n");
		return (1);
	}
	bad |= expect("no directory",
	    erx_cap_table_init(t, NULL, dirsize, STORAGE_LIMIT), ERX_EINVAL);
	bad |= expect("small directory",
	    erx_cap_table_init(t, directory, dirsize - 1, STORAGE_LIMIT),
	    ERX_EINVAL);
	bad |= expect("misaligned directory",
	    erx_cap_table_init(t, directory + 1, dirsize, STORAGE_LIMIT),
	    ERX_EINVAL);
	bad |= expect("limit 1",
	    erx_cap_table_init(t, directory, dirsize, 1), ERX_EINVAL);
	bad |= expect("init",
	    erx_cap_table_init(t, directory, dirsize, STORAGE_LIMIT), ERX_OK);
	bad |= expect("no page",
	    erx_cap_table_add_page(t, NULL, STORAGE_PAGE), ERX_EINVAL);
	bad |= expect("small page",
	    erx_cap_table_add_page(t, pages[0], STORAGE_PAGE - 1), ERX_EINVAL);
	bad |= expect("misaligned page",
	    erx_cap_table_add_page(t, pages[0] + 1, STORAGE_PAGE), ERX_EINVAL);
	bad |= expect("page over the directory",
	    erx_cap_table_add_page(t, directory, STORAGE_PAGE), ERX_EINVAL);
	bad |= expect("first page",
	    erx_cap_table_add_page(t, pages[0], STORAGE_PAGE), ERX_OK);
	bad |= expect("the same page again",
	    erx_cap_table_add_page(t, pages[0], STORAGE_PAGE), ERX_EINVAL);
	bad |= expect("a page overlapping it",
	    erx_cap_table_add_page(t, pages[0] + 64, STORAGE_PAGE), ERX_EINVAL);
	bad |= expect("second page",
	    erx_cap_table_add_page(t, pages[1], STORAGE_PAGE), ERX_OK);
	bad |= expect("past the limit",
	    erx_cap_table_add_page(t, pages[2], STORAGE_PAGE), ERX_ELIMIT);
	return (bad);
}
