/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The export table: what each peer domain holds on this domain's names
 * (docs/design-domains.md, "Exports"; docs/design-runtime.md, "The export table's three
 * writers"). It is no structure of its own: a name's holders are an erx_exports_t field of
 * the name's own record, a process's on its Process and the domain's on this file's record
 * of the domain, so a holder ends with what it names.
 */

#ifndef ERX_EXPORTS_H
#define ERX_EXPORTS_H

#include <stdint.h>

#include "erx/funnel.h"
#include "erx_exports_set.h"

struct dist_entry_;
struct process;

/* The locks and the domain's record; erl_init calls it before any process exists. */
void	erx_exports_init(void);

/*
 * The three writers (R7), each an act of the name's owner:
 *
 * 1. erx_exports_hand_out: the external encoder put name, an internal pid (edit 8) or an
 *    active alias (edit 14), into a frame for conn, a domain's connection with this one;
 *    its peer gets send on it, on conn, where it holds nothing yet. An alias's holders
 *    are on its registry entry (erx_alias.h) and close when the alias ends.
 * 2. erx_exports_spawned: a SPAWN_REQUEST on connection conn_id of dep made child; the
 *    peer gets send, link and exit on it, on that connection, before the child runs.
 *    When the table is full, or memory short, either writes nothing and counts the
 *    refusal (erx_dist:exports_refused/0): the peer holds nothing on the name.
 * 3. erx_dist:export/3, a BIF of this file, and the boot exports the lane driver asks
 *    for with erx_exports_boot: exactly the rights named.
 *
 * tools/lib/erx/chokepoint_rules/exports.rb keeps every other site off the insert.
 */
void	erx_exports_hand_out(Eterm name, const erx_exports_conn_t *conn);
void	erx_exports_spawned(struct process *child, struct dist_entry_ *dep, uint32_t conn_id);

/*
 * The boot exports toward the system domain, on its connection system: send on init and
 * spawn on the domain, written before the system connection's first frame is read.
 */
void	erx_exports_boot(const erx_exports_conn_t *system);

/* Edit 13: a process's exit ends its holders, under ERTS's exit path. */
void	erx_exports_close(erx_exports_t *set);

/*
 * The funnel's question (erx_funnel_lookup_fn): what the peer of the erx_exports_conn_t
 * conn points at holds on name, on that connection. Reads only this runtime's memory,
 * and writes nothing.
 */
erx_funnel_hold_t erx_exports_lookup(const void *conn, const erx_funnel_name_t *name);

/*
 * The connection of dep: another domain's entry's creation and the serial the entry took
 * when its connection went pending (erl_node_tables.c), which setnode gives the lane port
 * (erx_lane_connect), so the encoder and the funnel name one connection; peer 0 for this
 * node's entry or one of another machine. A holder written on one connection grants
 * nothing on any later connection between the same two domains. The caller holds dep's
 * lock.
 */
erx_exports_conn_t erx_exports_conn_of(struct dist_entry_ *dep);

#endif /* ERX_EXPORTS_H */
