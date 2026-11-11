/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of liberx/backend/core/object_info.c's machine and CPU reports
 * (test/host/object_info_test.rb): a reported bit stands exactly for a fact the
 * backend gave, with that fact's value, and a fact it did not give leaves its field
 * 0 and its bit clear. Each failure names the field, so a seeded fault is named.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/core/object_info.h"

static int cases, failures;

static void
check(int ok, const char *what)
{
	cases++;
	if (!ok) {
		failures++;
		printf("object info: %s\n", what);
	}
}

static erx_info_machine_t
machine_report(const erx_info_facts_t *facts)
{
	erx_info_machine_t report;

	memset(&report, 0xa5, sizeof(report));
	check(erx_info_report(ERX_INFO_MACHINE, 0, facts, &report, sizeof(report)) == ERX_OK, "machine refused");
	return (report);
}

static erx_info_cpu_t
cpu_report(const erx_info_facts_t *facts, uint64_t index)
{
	erx_info_cpu_t report;

	memset(&report, 0xa5, sizeof(report));
	check(erx_info_report(ERX_INFO_CPU, index, facts, &report, sizeof(report)) == ERX_OK, "cpu refused");
	return (report);
}

static void
machine_with_handoff(void)
{
	static const uint8_t build[8] = { 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
	erx_info_facts_t facts = { .cpus_online = 0x3, .uptime_ns = 5, .boot_known = true,
	    .boot_value = ERX_BOOT_VALUE_TRIAL };
	erx_info_machine_t report;

	memcpy(facts.build, build, sizeof(build));
	report = machine_report(&facts);
	check((report.reported & ERX_INFO_MACHINE_REPORTED_BUILD) != 0, "build not reported");
	check(memcmp(report.build, build, sizeof(build)) == 0, "build not the handoff's");
	check((report.reported & ERX_INFO_MACHINE_REPORTED_BOOT_VALUE) != 0, "boot_value not reported");
	check(report.boot_value == ERX_BOOT_VALUE_TRIAL, "boot_value not the handoff's");
	check((report.reported & ERX_INFO_MACHINE_REPORTED_ENTROPY_QUALITY) == 0 && report.entropy_quality == 0,
	    "entropy_quality reported");
	check(report.reported == (ERX_INFO_MACHINE_REPORTED_BUILD | ERX_INFO_MACHINE_REPORTED_BOOT_VALUE |
	    ERX_INFO_MACHINE_REPORTED_CPUS_ONLINE | ERX_INFO_MACHINE_REPORTED_UPTIME), "machine reported other bits");
}

static void
machine_without_handoff(void)
{
	static const uint8_t zero[8];
	erx_info_facts_t facts = { .cpus_online = 0x1, .uptime_ns = 5, .boot_value = ERX_BOOT_VALUE_NORMAL,
	    .build = { 1, 2, 3, 4, 5, 6, 7, 8 } };
	const erx_info_machine_t report = machine_report(&facts);

	check((report.reported & (ERX_INFO_MACHINE_REPORTED_BUILD | ERX_INFO_MACHINE_REPORTED_BOOT_VALUE)) == 0,
	    "build or boot_value reported without a handoff");
	check(memcmp(report.build, zero, sizeof(zero)) == 0 && report.boot_value == 0,
	    "build or boot_value written without a handoff");
}

/* Fiasco's idle count bounds a CPU's idle time neither way, so a CPU reports nothing. */
static void
cpu_reports_nothing(void)
{
	const erx_info_facts_t facts = { .cpus_online = 0x3, .uptime_ns = 5 };
	erx_info_cpu_t report = cpu_report(&facts, 1);

	check(report.reported == 0 && report.idle_time == 0, "cpu reported a field");
	check(erx_info_report(ERX_INFO_CPU, 2, &facts, &report, sizeof(report)) == ERX_ERANGE, "cpu off the map listed");
}

int
main(void)
{
	machine_with_handoff();
	machine_without_handoff();
	cpu_reports_nothing();
	printf("object info: %d cases, %d failures\n", cases, failures);
	return (failures == 0 ? 0 : 1);
}
