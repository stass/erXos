/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The gate worker's core: what a record from the domain's fault gate does to the table
 * (erx_gate_core.h). Pure: it reads and writes only the table it is given.
 */

#include <string.h>

#include "erx_gate_core.h"

/* The sink holding label, or NULL. A free sink holds no label. */
static erx_gate_sink_t *
find(erx_gate_table_t *table, uint64_t label)
{
	for (size_t index = 0; index < ERX_GATE_SINKS; index++) {
		erx_gate_sink_t *const sink = &table->sinks[index];

		if (sink->irq != ERX_CAP_NULL && sink->label == label)
			return (sink);
	}
	return (NULL);
}

int
erx_gate_table_add(erx_gate_table_t *table, uint64_t label, uint64_t irq)
{
	if (irq == ERX_CAP_NULL || find(table, label) != NULL)
		return (ERX_EINVAL);
	for (size_t index = 0; index < ERX_GATE_SINKS; index++) {
		erx_gate_sink_t *const sink = &table->sinks[index];

		if (sink->irq == ERX_CAP_NULL) {
			memset(sink, 0, sizeof(*sink));
			sink->label = label;
			sink->irq = irq;
			return (ERX_OK);
		}
	}
	return (ERX_ELIMIT);
}

void
erx_gate_table_remove(erx_gate_table_t *table, uint64_t label)
{
	erx_gate_sink_t *const sink = find(table, label);

	if (sink != NULL)
		memset(sink, 0, sizeof(*sink));
}

erx_gate_outcome_t
erx_gate_table_deliver(erx_gate_table_t *table, uint64_t label, const erx_fault_t *record)
{
	erx_gate_sink_t *const sink = find(table, label);

	if (sink == NULL) {
		table->unknown++;
		return ((erx_gate_outcome_t){ .verdict = ERX_GATE_DROP_UNKNOWN });
	}
	if (sink->count == ERX_GATE_SLOT_RECORDS) {
		/* Each record it keeps was followed by a trigger, so the port's look is still to come. */
		sink->lost++;
		return ((erx_gate_outcome_t){ .verdict = ERX_GATE_DROP_FULL });
	}
	sink->records[sink->count++] = *record;
	return ((erx_gate_outcome_t){ .verdict = ERX_GATE_DEPOSIT, .irq = sink->irq });
}

size_t
erx_gate_table_take(erx_gate_table_t *table, uint64_t label, erx_fault_t records[ERX_GATE_SLOT_RECORDS],
    uint64_t *lost)
{
	erx_gate_sink_t *const sink = find(table, label);
	size_t count;

	*lost = 0;
	if (sink == NULL)
		return (0);
	count = sink->count;
	memcpy(records, sink->records, count * sizeof(records[0]));
	*lost = sink->lost;
	sink->count = 0;
	sink->lost = 0;
	return (count);
}
