/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the domain library's boot view (liberx/system/dom_boot_view.c),
 * run by test/host/dom_planner_test.rb: it builds the view from a packed
 * manifest's bytes, as tools/host/dom_plan.c does with no archive files,
 * and prints what /dev and the domain service read of it.
 *
 *   dom-view MANIFEST
 *
 * One line per catalogue entry, then one per service row:
 *
 *   device INDEX unit=NAME compatible=STRING|none ranges=BASE+SIZE,... lines=LINE,... confined=0|1
 *   service INDEX name=NAME server=ROW|none interface=NUMBER
 *
 * numbers in hexadecimal for ranges and decimal elsewhere. A view the
 * library refuses prints `refused REASON` alone. A malformed input prints
 * nothing and exits 2.
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "input.h"

static void
print_device(uint32_t index, const erx_dom_device_entry_t *entry)
{
	printf("device %" PRIu32 " unit=%.*s compatible=%s ranges=", index, (int)entry->unit_name_len,
	    entry->unit_name, entry->compatible == NULL ? "none" : entry->compatible);
	for (uint32_t at = 0; at < entry->nranges; at++)
		printf("%s0x%" PRIx64 "+0x%" PRIx64, at == 0 ? "" : ",", entry->ranges[at].base,
		    entry->ranges[at].size);
	printf(" lines=");
	for (uint32_t at = 0; at < entry->nlines; at++)
		printf("%s%" PRIu32, at == 0 ? "" : ",", entry->lines[at]);
	printf(" confined=%d\n", entry->confined ? 1 : 0);
}

static void
print_service(uint32_t index, const erx_dom_service_t *service)
{
	printf("service %" PRIu32 " name=%.*s server=", index, (int)service->name_len, service->name);
	if (service->server == ERX_MF_NONE)
		printf("none");
	else
		printf("%" PRIu32, service->server);
	printf(" interface=%" PRIu32 "\n", service->interface);
}

int
main(int argc, char **argv)
{
	static erx_dom_lib_t lib;
	erx_manifest_view_t manifest;
	erx_abi_error_t error;
	erx_dom_boot_sizes_t sizes;
	erx_dom_boot_tables_t tables;
	const char *reason;
	uint8_t *bytes, *region;
	size_t length, region_len;

	if (argc != 2 || (bytes = erx_host_input_read(argv[1], &length)) == NULL ||
	    !erx_manifest_open(bytes, length, &manifest, &error))
		return (2);
	/* The tables in one page-aligned region, as the root lays them out. */
	sizes = erx_dom_view_sizes(&manifest, 0);
	if (!erx_dom_boot_layout(&sizes, 0, &tables, &region_len) || region_len > SIZE_MAX - 2 * ERX_PAGE_SIZE)
		return (2);
	region_len = (region_len + 2 * ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE * ERX_PAGE_SIZE;
	if ((region = aligned_alloc(ERX_PAGE_SIZE, region_len)) == NULL ||
	    !erx_dom_boot_layout(&sizes, (uintptr_t)region, &tables, &region_len))
		return (2);
	memset(region, 0, region_len);
	if ((reason = erx_dom_view_build(&lib, &manifest, 0, &tables)) != NULL) {
		printf("refused %s\n", reason);
		return (fflush(stdout) == 0 ? 0 : 2);
	}
	for (uint32_t index = 0; index < lib.view.ndevices; index++)
		print_device(index, &lib.view.devices[index]);
	for (uint32_t index = 0; index < lib.view.nservices; index++)
		print_service(index, &lib.view.services[index]);
	return (fflush(stdout) == 0 ? 0 : 2);
}
