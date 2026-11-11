/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Host driver of the gate worker's core (otp/erts/emulator/sys/erxos/erx_gate_core.c), for
 * test/host/erx_gate_core_test.rb. Each case starts from an empty table and prints one line,
 *
 *   case NAME ok
 *   case NAME FAILED: WHAT
 *
 * and the driver exits 1 when any case failed.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "erx_gate_core.h"

#define PORT_LABEL	UINT64_C(4242)
#define PORT_IRQ	UINT64_C(0x5000)
#define OTHER_LABEL	UINT64_C(77)
#define OTHER_IRQ	UINT64_C(0x6000)

static erx_gate_table_t table;
static const char *failure;

static bool
expect(bool holds, const char *what)
{
	if (!holds && failure == NULL)
		failure = what;
	return (holds);
}

/* A record told apart from every other by its status. */
static erx_fault_t
record(int64_t status)
{
	erx_fault_t made;

	memset(&made, 0, sizeof(made));
	made.space = UINT64_C(0x100) + (uint64_t)status;
	made.status = status;
	return (made);
}

static bool
deposited(uint64_t label, int64_t status, uint64_t irq)
{
	const erx_fault_t sent = record(status);
	const erx_gate_outcome_t outcome = erx_gate_table_deliver(&table, label, &sent);

	return (outcome.verdict == ERX_GATE_DEPOSIT && outcome.irq == irq);
}

/* The label's slot holds exactly the records of statuses first..first+n-1, in that order. */
static bool
took_in_order(uint64_t label, int64_t first, size_t n, uint64_t lost)
{
	erx_fault_t taken[ERX_GATE_SLOT_RECORDS];
	uint64_t taken_lost = UINT64_MAX;
	const size_t count = erx_gate_table_take(&table, label, taken, &taken_lost);

	if (count != n || taken_lost != lost)
		return (false);
	for (size_t index = 0; index < n; index++) {
		const erx_fault_t want = record(first + (int64_t)index);

		if (memcmp(&taken[index], &want, sizeof(want)) != 0)
			return (false);
	}
	return (true);
}

/* A record for a label no sink holds is counted and dropped, and no sink gets it. */
static void
case_unknown_label(void)
{
	const erx_fault_t sent = record(1);
	erx_gate_outcome_t outcome;

	expect(erx_gate_table_add(&table, PORT_LABEL, PORT_IRQ) == ERX_OK, "add");
	outcome = erx_gate_table_deliver(&table, OTHER_LABEL, &sent);
	expect(outcome.verdict == ERX_GATE_DROP_UNKNOWN, "an unknown label is not dropped");
	expect(table.unknown == 1, "an unknown label is not counted");
	expect(took_in_order(PORT_LABEL, 0, 0, 0), "another sink got the unknown label's record");
	expect(took_in_order(OTHER_LABEL, 0, 0, 0), "a label no sink holds took something");
}

/* A second record for one sink is kept after the first, and each deposit names its IRQ object. */
static void
case_second_record_in_order(void)
{
	expect(erx_gate_table_add(&table, OTHER_LABEL, OTHER_IRQ) == ERX_OK, "add other");
	expect(erx_gate_table_add(&table, PORT_LABEL, PORT_IRQ) == ERX_OK, "add");
	expect(deposited(PORT_LABEL, 1, PORT_IRQ), "the first record is not deposited for its IRQ object");
	expect(deposited(PORT_LABEL, 2, PORT_IRQ), "the second record is not deposited for its IRQ object");
	expect(deposited(OTHER_LABEL, 9, OTHER_IRQ), "another sink's record is not deposited for its IRQ object");
	expect(took_in_order(PORT_LABEL, 1, 2, 0), "the two records are not kept in order");
	expect(took_in_order(PORT_LABEL, 0, 0, 0), "a take leaves records behind");
	expect(took_in_order(OTHER_LABEL, 9, 1, 0), "another sink's record is lost");
	expect(table.unknown == 0, "a known label is counted as unknown");
}

/* A slot refills after a take: a second round fills it whole and stays in order. */
static void
case_slot_refills(void)
{
	expect(erx_gate_table_add(&table, PORT_LABEL, PORT_IRQ) == ERX_OK, "add");
	for (int64_t status = 0; status < 5; status++)
		expect(deposited(PORT_LABEL, status, PORT_IRQ), "a record is not deposited");
	expect(took_in_order(PORT_LABEL, 0, 5, 0), "the first round is not in order");
	for (int64_t status = 5; status < 5 + ERX_GATE_SLOT_RECORDS; status++)
		expect(deposited(PORT_LABEL, status, PORT_IRQ), "a record of the second round is not deposited");
	expect(took_in_order(PORT_LABEL, 5, ERX_GATE_SLOT_RECORDS, 0), "the second round is not in order");
}

/* A full slot drops the newest record, counts it in the sink, keeps the rest, and triggers nothing. */
static void
case_full_slot(void)
{
	const erx_fault_t extra = record(ERX_GATE_SLOT_RECORDS);
	erx_gate_outcome_t outcome;

	expect(erx_gate_table_add(&table, PORT_LABEL, PORT_IRQ) == ERX_OK, "add");
	for (int64_t status = 0; status < ERX_GATE_SLOT_RECORDS; status++)
		expect(deposited(PORT_LABEL, status, PORT_IRQ), "a record is not deposited");
	outcome = erx_gate_table_deliver(&table, PORT_LABEL, &extra);
	expect(outcome.verdict == ERX_GATE_DROP_FULL, "a full slot takes another record");
	expect(took_in_order(PORT_LABEL, 0, ERX_GATE_SLOT_RECORDS, 1), "a full slot loses what it kept or its count");
	expect(took_in_order(PORT_LABEL, 0, 0, 0), "a take does not clear the lost count");
	expect(table.unknown == 0, "a full slot's drop is counted as unknown");
}

/* A removed sink's records go with it, and its label then names nothing until it is added again. */
static void
case_remove(void)
{
	const erx_fault_t sent = record(3);

	expect(erx_gate_table_add(&table, PORT_LABEL, PORT_IRQ) == ERX_OK, "add");
	expect(deposited(PORT_LABEL, 1, PORT_IRQ), "a record is not deposited");
	erx_gate_table_remove(&table, PORT_LABEL);
	expect(erx_gate_table_deliver(&table, PORT_LABEL, &sent).verdict == ERX_GATE_DROP_UNKNOWN,
	    "a removed sink still takes records");
	expect(erx_gate_table_add(&table, PORT_LABEL, OTHER_IRQ) == ERX_OK, "the label cannot be added again");
	expect(took_in_order(PORT_LABEL, 0, 0, 0), "a new sink inherits a removed one's records");
	expect(deposited(PORT_LABEL, 4, OTHER_IRQ), "the new sink does not name its own IRQ object");
	erx_gate_table_remove(&table, OTHER_LABEL);
	expect(took_in_order(PORT_LABEL, 4, 1, 0), "removing a label no sink holds touches another sink");
}

/* An add with no IRQ object or a label a sink holds is refused, and a full table refuses the next. */
static void
case_add_refusals(void)
{
	expect(erx_gate_table_add(&table, PORT_LABEL, ERX_CAP_NULL) == ERX_EINVAL, "a sink with no IRQ object");
	expect(erx_gate_table_add(&table, PORT_LABEL, PORT_IRQ) == ERX_OK, "add");
	expect(erx_gate_table_add(&table, PORT_LABEL, OTHER_IRQ) == ERX_EINVAL, "a label added twice");
	for (uint64_t label = 1; label < ERX_GATE_SINKS; label++)
		expect(erx_gate_table_add(&table, label, PORT_IRQ) == ERX_OK, "the table fills short of its size");
	expect(erx_gate_table_add(&table, ERX_GATE_SINKS, PORT_IRQ) == ERX_ELIMIT, "a full table takes a sink");
	erx_gate_table_remove(&table, 1);
	expect(erx_gate_table_add(&table, ERX_GATE_SINKS, PORT_IRQ) == ERX_OK, "a freed sink is not reused");
}

static const struct {
	const char	*name;
	void		(*run)(void);
} cases[] = {
	{ "unknown-label", case_unknown_label },
	{ "second-record-in-order", case_second_record_in_order },
	{ "slot-refills", case_slot_refills },
	{ "full-slot", case_full_slot },
	{ "remove", case_remove },
	{ "add-refusals", case_add_refusals },
};

int
main(void)
{
	int failed = 0;

	for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
		memset(&table, 0, sizeof(table));
		failure = NULL;
		cases[index].run();
		if (failure == NULL) {
			printf("case %s ok\n", cases[index].name);
		} else {
			printf("case %s FAILED: %s\n", cases[index].name, failure);
			failed = 1;
		}
	}
	return (failed);
}
