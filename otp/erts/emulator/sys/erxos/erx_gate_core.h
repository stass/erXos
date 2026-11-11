/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The gate worker's core (docs/design-runtime.md, "The event table"): the table from each
 * label a port gave a space it created to that label's slot and the port's IRQ object, and what an
 * exit or fault record taken from the domain's fault gate does there. A record whose label
 * a sink holds is kept in the sink's slot, after every record kept before it, and the
 * sink's IRQ object is to be triggered; any other record is dropped and counted. It knows
 * nothing of ERTS and calls no kernel, so a host test drives every path. erx_gate.c holds
 * its effects: the gate, the worker thread, the lock and the trigger.
 */

#ifndef ERX_GATE_CORE_H
#define ERX_GATE_CORE_H

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/* Labels registered at once, two per program; a lookup searches, so the table stays small. */
#define ERX_GATE_SINKS		64
/*
 * Records a slot keeps until its port takes them. A program's image posts its exit record
 * and one per faulting thread, and its anchor its exit record, each under its own label.
 */
#define ERX_GATE_SLOT_RECORDS	8

/* A sink is free while irq is ERX_CAP_NULL. records[0..count) are kept, oldest first. */
typedef struct {
	uint64_t	label;		/* what the port's spaces carry */
	uint64_t	irq;		/* the port's own IRQ object */
	uint32_t	count;
	uint64_t	lost;		/* records a full slot dropped since the port's last take */
	erx_fault_t	records[ERX_GATE_SLOT_RECORDS];
} erx_gate_sink_t;

typedef struct {
	erx_gate_sink_t	sinks[ERX_GATE_SINKS];
	uint64_t	unknown;	/* records whose label no sink held */
} erx_gate_table_t;

typedef enum {
	ERX_GATE_DEPOSIT = 1,		/* kept: trigger irq */
	ERX_GATE_DROP_UNKNOWN,		/* no sink holds the label: counted in the table */
	ERX_GATE_DROP_FULL		/* the sink's slot is full: counted in the sink */
} erx_gate_verdict_t;

typedef struct {
	erx_gate_verdict_t	verdict;
	uint64_t		irq;	/* ERX_GATE_DEPOSIT's only */
} erx_gate_outcome_t;

/*
 * Every function below runs under the caller's one lock over the table, so a sink's slot,
 * its IRQ object and its removal are each one step against the worker's delivery.
 */

/* ERX_OK; ERX_EINVAL for irq ERX_CAP_NULL or a label a sink holds; ERX_ELIMIT with the table full. */
int	erx_gate_table_add(erx_gate_table_t *table, uint64_t label, uint64_t irq);
/* Frees the label's sink and the records it kept; a label no sink holds is nothing to do. */
void	erx_gate_table_remove(erx_gate_table_t *table, uint64_t label);
/* Keeps the record in the label's slot, or drops and counts it. */
erx_gate_outcome_t erx_gate_table_deliver(erx_gate_table_t *table, uint64_t label, const erx_fault_t *record);
/*
 * Moves every record the label's slot kept into records, oldest first, and empties the
 * slot: the count moved, with *lost the records a full slot dropped since the last take.
 * A label no sink holds moves nothing and has lost nothing.
 */
size_t	erx_gate_table_take(erx_gate_table_t *table, uint64_t label, erx_fault_t records[ERX_GATE_SLOT_RECORDS],
	    uint64_t *lost);

#endif /* ERX_GATE_CORE_H */
