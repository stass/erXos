/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs erx_tlb_plan over the removals in a text file and prints each plan,
 * so the host test's model can apply it. Numbers are hexadecimal.
 *
 * Input, one removal after another:
 *   case ASID RANGE_PAGES_MAX COUNT     COUNT entry lines follow
 *   entry page|table|bogus VA SPAN GLOBAL
 *   null ASID RANGE_PAGES_MAX COUNT     COUNT entries behind a null pointer
 * Output, per removal:
 *   plan STATUS ASID NINVALS            NINVALS inval lines follow
 *   inval last|every|asid VA PAGES
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/tlb_plan.h"

#define DRIVER_ENTRIES_MAX	65536

static void driver_fail(const char *, unsigned long);
static bool driver_read_entry(const char *, erx_tlb_cleared_t *);
static void driver_print(int, const erx_tlb_plan_t *);
static const char *driver_reach_name(erx_tlb_reach_t);

static void
driver_fail(const char *reason, unsigned long line)
{
	fprintf(stderr, "tlb_plan_driver: line %lu: %s\n", line, reason);
	exit(2);
}

static bool
driver_read_entry(const char *line, erx_tlb_cleared_t *entry)
{
	char kind[16];
	unsigned global;

	if (sscanf(line, "entry %15s %" SCNx64 " %" SCNx64 " %u", kind,
	    &entry->va, &entry->span, &global) != 4 || global > 1)
		return (false);
	entry->global = global == 1;
	if (strcmp(kind, "page") == 0)
		entry->kind = ERX_TLB_CLEARED_PAGE;
	else if (strcmp(kind, "table") == 0)
		entry->kind = ERX_TLB_CLEARED_TABLE;
	else if (strcmp(kind, "bogus") == 0)
		entry->kind = (erx_tlb_cleared_kind_t)0;
	else
		return (false);
	return (true);
}

static const char *
driver_reach_name(erx_tlb_reach_t reach)
{
	switch (reach) {
	case ERX_TLB_LAST_LEVEL:
		return ("last");
	case ERX_TLB_EVERY_LEVEL:
		return ("every");
	case ERX_TLB_WHOLE_ASID:
		return ("asid");
	}
	return ("unknown");
}

static void
driver_print(int status, const erx_tlb_plan_t *plan)
{
	printf("plan %d %" PRIx32 " %" PRIu32 "\n", status, plan->asid,
	    plan->ninvals);
	for (uint32_t i = 0; i < plan->ninvals; i++) {
		printf("inval %s %" PRIx64 " %" PRIx64 "\n",
		    driver_reach_name(plan->invals[i].reach),
		    plan->invals[i].va, plan->invals[i].pages);
	}
}

int
main(int argc, char **argv)
{
	static erx_tlb_cleared_t entries[DRIVER_ENTRIES_MAX];
	static erx_tlb_plan_t plan;
	erx_tlb_removal_t removal;
	char line[256];
	FILE *input;
	unsigned long count, line_number;
	unsigned asid;
	int status;
	bool null_entries;

	if (argc != 2)
		driver_fail("usage: tlb_plan_driver FILE", 0);
	input = fopen(argv[1], "r");
	if (input == NULL)
		driver_fail("cannot open input", 0);

	line_number = 0;
	while (fgets(line, sizeof(line), input) != NULL) {
		line_number++;
		removal = (erx_tlb_removal_t){ .cleared = entries };
		null_entries = strncmp(line, "null ", 5) == 0;
		if (sscanf(line, null_entries ? "null %x %" SCNx64 " %lx" :
		    "case %x %" SCNx64 " %lx", &asid, &removal.range_pages_max,
		    &count) != 3 || count > DRIVER_ENTRIES_MAX)
			driver_fail("expected a case line", line_number);
		removal.asid = asid;
		removal.ncleared = count;
		if (null_entries)
			removal.cleared = NULL;

		for (unsigned long i = 0; !null_entries && i < count; i++) {
			if (fgets(line, sizeof(line), input) == NULL)
				driver_fail("missing entry line", line_number);
			line_number++;
			if (!driver_read_entry(line, &entries[i]))
				driver_fail("malformed entry line", line_number);
		}

		status = erx_tlb_plan(&removal, &plan);
		driver_print(status, &plan);
	}
	if (ferror(input))
		driver_fail("read error", line_number);
	fclose(input);
	return (0);
}
