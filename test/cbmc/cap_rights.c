/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CBMC harness: rights only shrink through a pass (kernel/core/cap.c,
 * erx_pass_plan and erx_rights_shrink; K2 and K24), over every request of
 * up to ERX_MSG_CAPS items and every source the table could have held.
 *
 * Bounds: ERX_MSG_CAPS items, the most a pass carries; the roster's unwind
 * set covers erx_pass_plan's loop and cap_plan_item's duplicate scan, and
 * the unwinding assertions prove it.
 *
 * Assumptions: none on the inputs; each source's status and view are
 * free, a superset of what erx_cap_read returns.
 *
 * Checked: an accepted plan gives each capability rights within its
 * source's rights and its item's mask, within its type's pass set unless
 * the creator's rule applies, and under the creator's rule without CODE
 * and, for a space, with INSPECT at most; each step names the source's
 * own slot, generation, object and type with the item's operation; a copy
 * needs DUP and a pass from the caller's own table GIVE; no slot is named
 * twice and no reserved value (slot 0) passes; only a route of
 * erx_pass_route_t is accepted, and the plan keeps the request's route and
 * tables. A refused plan carries no steps.
 */

#include "cbmc_harness.h"
#include "cap.c"

static erx_pass_item_t items[ERX_MSG_CAPS];
static erx_pass_source_t sources[ERX_MSG_CAPS];

void
harness(void)
{
	erx_pass_request_t request = {
		.items = items,
		.count = nondet_u32(),
		.room = nondet_u32(),
		.route = nondet_u32(),
	};
	erx_pass_plan_t plan;
	erx_status_t status;
	uint32_t i, j, kept;
	bool from_own, to_created;

	for (i = 0; i < ERX_MSG_CAPS; i++) {
		items[i] = (erx_pass_item_t){
			.cap = { .raw = nondet_u64() },
			.op = nondet_u32(),
			.mask = nondet_u32(),
			.type = nondet_u32(),
			.required = nondet_u32(),
		};
		sources[i] = (erx_pass_source_t){
			.status = nondet_i32(),
			.view = {
				.object = nondet_u64(),
				.type = nondet_u32(),
				.rights = { .bits = nondet_u32() },
				.slot = nondet_u32(),
				.generation = nondet_u64(),
			},
		};
	}

	status = erx_pass_plan(&request, sources, &plan);
	if (status != ERX_OK) {
		__CPROVER_assert(plan.stage == ERX_PASS_REFUSED && plan.count == 0,
		    "a refused plan carries no steps");
		return;
	}
	__CPROVER_assert(request.route >= ERX_PASS_RENDEZVOUS &&
	    request.route <= ERX_PASS_CREATED_TO_CREATED,
	    "only a named route passes");
	__CPROVER_assert((uint32_t)plan.route == request.route &&
	    plan.from == request.from && plan.to == request.to,
	    "a plan keeps its request's route and tables");
	/* The route's two questions, stated here apart from cap.c's. */
	from_own = request.route == ERX_PASS_RENDEZVOUS ||
	    request.route == ERX_PASS_OWN_TO_CREATED;
	to_created = request.route == ERX_PASS_OWN_TO_CREATED ||
	    request.route == ERX_PASS_CREATED_TO_CREATED;
	__CPROVER_assert(plan.stage == ERX_PASS_PLANNED &&
	    plan.count == request.count && request.count <= ERX_MSG_CAPS &&
	    request.count <= request.room, "an accepted plan fits the room");
	for (i = 0; i < plan.count; i++) {
		const erx_cap_view_t *view = &sources[i].view;
		uint32_t rights = plan.steps[i].rights.bits;

		kept = view->rights.bits & items[i].mask;
		__CPROVER_assert(sources[i].status == ERX_OK && view->slot != 0,
		    "only a live slot passes");
		__CPROVER_assert(plan.steps[i].slot == view->slot &&
		    plan.steps[i].generation == view->generation &&
		    plan.steps[i].object == view->object &&
		    plan.steps[i].type == view->type &&
		    (uint32_t)plan.steps[i].op == items[i].op,
		    "a step passes the source's own capability, as asked");
		__CPROVER_assert((rights & ~kept) == 0,
		    "K2: a pass keeps rights within the source's and the mask");
		if (!to_created)
			__CPROVER_assert((rights & ~erx_ktype_pass_mask(view->type)) == 0,
			    "K24: a pass between peers keeps its type's pass set");
		else {
			__CPROVER_assert((rights & ERX_HR_CODE) == 0,
			    "K24: CODE never passes under the creator's rule");
			__CPROVER_assert(view->type != ERX_K_SPACE ||
			    (rights & ~ERX_HR_INSPECT) == 0,
			    "K24: a space passes to its creation with INSPECT alone");
		}
		__CPROVER_assert(items[i].op != ERX_PASS_COPY ||
		    (view->rights.bits & ERX_HR_DUP) != 0, "a copy needs DUP");
		__CPROVER_assert(!from_own ||
		    (view->rights.bits & ERX_HR_GIVE) != 0,
		    "a pass from the caller's own table needs GIVE");
		for (j = 0; j < i; j++)
			__CPROVER_assert(plan.steps[j].slot != plan.steps[i].slot,
			    "no slot passes twice");
	}
}
