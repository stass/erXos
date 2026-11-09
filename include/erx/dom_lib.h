/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DOM_LIB_H
#define ERX_DOM_LIB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/dom.h"

/*
 * The domain library's run-time half (docs/design-system.md, "The domain
 * library", "Creating a domain" and "Ending a domain"): it applies the pure
 * core's plans (include/erx/dom.h) over the function API in the system
 * domain's root, keeps the handles each creation made, and turns the records
 * at its fault gate into ends. Effects live here and decisions in the core:
 * every entry plans first, and only a plan the core accepted is applied.
 *
 * Every entry runs under the caller's one library lock, the fault thread's
 * erx_dom_lib_record included, so the view and the handles change only under
 * it. erx_dom_lib_take alone takes no lock: it waits at the gate.
 *
 * Handles: each object a creation makes has one handle in the root's table,
 * kept in the domain's erx_dom_handles_t with the budget it is charged to.
 * Destroying a budget deletes everything charged to it; the library then
 * closes exactly the handles whose charge leads to that budget, so the
 * root's table holds no stale handle after a teardown or an undo. The
 * record's capabilities in the view are always copied from these handles
 * (lib_view_caps), so a closed handle leaves no value behind there either,
 * and a teardown finds each capability it names among the handles of the
 * domains it concerns before it destroys anything. The
 * domain receives copies of its budget and objects (erx_cap_pass copies), so
 * the library's handle to its own budget is never the last one.
 */

/* What the library holds of the system domain's: handles in the root's own table. */
typedef struct erx_dom_held {
	uint64_t	principal_budget;	/* the built-in system principal's budget */
	uint64_t	principal_group;	/* its group: a requested domain's CPU parent */
	uint64_t	system_group;		/* the system domain's group: its bells, and
						 * a configured domain's CPU parent */
	uint64_t	time_page;		/* the time page's object */
	uint64_t	gate;			/* the library's fault gate, bound to its
						 * fault thread */
} erx_dom_held_t;

/* One creation's handles in the root's table, object by object. */
typedef struct erx_dom_handles {
	uint64_t	made[ERX_DOM_OBJ_MADE_COUNT];	/* ERX_CAP_NULL for none */
	erx_dom_obj_t	charge[ERX_DOM_OBJ_MADE_COUNT];	/* the budget each is charged to,
							 * or a budget carved from */
} erx_dom_handles_t;

/*
 * One connection between two domains' handles, object by object from
 * ERX_DOM_OBJ_LINK_BUDGET_A: its two child budgets, two sides and two
 * bells. A system connection's handles are its domain's, so its row's
 * stay empty.
 */
#define ERX_DOM_LINK_OBJS	(ERX_DOM_OBJ_BELL_B - ERX_DOM_OBJ_LINK_BUDGET_A + 1u)

typedef struct erx_dom_link_handles {
	uint64_t	made[ERX_DOM_LINK_OBJS];	/* ERX_CAP_NULL for none */
	erx_dom_obj_t	charge[ERX_DOM_LINK_OBJS];	/* the budget each is charged to,
							 * or carved from */
} erx_dom_link_handles_t;

typedef struct erx_dom_lib {
	erx_dom_view_t	 view;		/* the core's view; its tables are the caller's */
	erx_dom_handles_t *handles;	/* view.max_domains, record for record */
	erx_dom_link_handles_t *links;	/* view.max_connections, row for row */
	erx_dom_held_t	 held;
	const char	*host;		/* the host part of a domain's node name */
	size_t		 host_len;	/* at most ERX_DOM_HOST_MAX */
	uint32_t	 pack_flags;	/* the boot image's, for each boot page */
	uint32_t	 cap_limit;	/* each domain's handle table */
#ifdef ERX_DOM_TEST_HOOKS
	uint32_t	 fail_step;	/* the step a create or a connect fails at,
					 * with ERX_ENOMEM; UINT32_MAX for none */
	bool		 fail_made;	/* fail it once it has made its object, as
					 * a refused bind or configure does; else
					 * before it is applied */
	uint32_t	 failed_at;	/* the step the last refused one stopped at */
#endif
} erx_dom_lib_t;

#define ERX_DOM_HOST_MAX	64u

/* What erx_dom_create returns: the domain's id and the system domain's values of its connection. */
typedef struct erx_dom_created {
	uint32_t	id;
	uint32_t	connection;	/* its number; 0 for none */
	uint64_t	side;		/* the domain's side: the system domain reads it */
	uint64_t	peer_side;	/* the system domain's side: it writes it */
	uint64_t	bell;		/* the domain's bell: the system domain triggers it */
} erx_dom_created_t;

/* An end the fault thread reports as {domain_ended, Id, End, Record}. */
typedef struct erx_dom_report {
	uint32_t	id;
	erx_dom_end_t	end;
	erx_fault_t	record;
} erx_dom_report_t;

/*
 * erx_dom_create for an admitted request (erx_dom_plan_request's arguments):
 * plans, applies each step in order, and records the plan in the view. On a
 * refused step every applied one is undone, which destroys the two budgets the
 * plan carved, and the step's status is returned with *created untouched.
 */
erx_status_t	erx_dom_lib_create(erx_dom_lib_t *, const erx_dom_spec_t *req,
		    const erx_runtime_limits_t *limits, uint32_t given,
		    erx_dom_created_t *created) ERX_WARN_UNUSED_RESULT;

/* erx_dom_start: ERX_OK; ERX_EINVAL for a domain not built; the backend's refusal otherwise. */
erx_status_t	erx_dom_lib_start(erx_dom_lib_t *, uint32_t id) ERX_WARN_UNUSED_RESULT;

/* erx_dom_stop: erx_dom_plan_stop's answer, or the backend's refusal of the stop. */
erx_status_t	erx_dom_lib_stop(erx_dom_lib_t *, uint32_t id, int64_t status) ERX_WARN_UNUSED_RESULT;

/* One party's values of a connection, in its own table. */
typedef struct erx_dom_party {
	uint64_t	side;		/* its own side, which it writes */
	uint64_t	peer_side;	/* the other's side, which it reads */
	uint64_t	peer_bell;	/* the other's bell, which it triggers */
	uint32_t	label;		/* the label its own bell delivers to its group */
} erx_dom_party_t;

/* What erx_dom_lib_connect returns: the connection's number and each party's values. */
typedef struct erx_dom_linked {
	uint32_t	number;
	erx_dom_party_t	a, b;
} erx_dom_linked_t;

/*
 * erx_dom_connect(a, b, a_reads, b_reads), erx_dom_plan_connect's
 * arguments: plans, applies each step in order, and records the
 * connection in the view. On a refused step the children carved so far
 * are destroyed, which deletes the sides and bells charged to them and,
 * on erXos's kernel, clears every install of them (K25), and the step's status is returned with
 * *linked untouched: ERX_ENOMEM when a party's outer budget cannot hold
 * its child.
 */
erx_status_t	erx_dom_lib_connect(erx_dom_lib_t *, uint32_t a, uint32_t b,
		    uint32_t a_reads, uint32_t b_reads, erx_dom_linked_t *linked)
		    ERX_WARN_UNUSED_RESULT;

/* erx_dom_disconnect and erx_dom_retire: their plans' answers. */
erx_status_t	erx_dom_lib_disconnect(erx_dom_lib_t *, uint32_t number) ERX_WARN_UNUSED_RESULT;
erx_status_t	erx_dom_lib_retire(erx_dom_lib_t *, uint32_t id) ERX_WARN_UNUSED_RESULT;

/*
 * The fault thread's wait, outside the lock: the next record at the gates bound
 * to the calling thread, with its label, or the backend's ERX_ETIMEDOUT.
 */
erx_status_t	erx_dom_lib_take(uint64_t deadline, uint64_t *label,
		    erx_fault_t *record) ERX_WARN_UNUSED_RESULT;

/*
 * The fault thread's handling of one record, under the lock
 * (erx_dom_record_step): a fault stops the domain's space; an exit record
 * destroys the domain's own budget and ends it. True when a domain ended, with
 * *report the end to send.
 */
bool		erx_dom_lib_record(erx_dom_lib_t *, uint64_t label,
		    const erx_fault_t *record, erx_dom_report_t *report);

#endif /* ERX_DOM_LIB_H */
