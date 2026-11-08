/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the domain library's pure core (liberx/system/dom_core.c),
 * judged by test/host/dom_core_test.rb. Three modes:
 *
 * explore  plans each creation variant, prints its steps, then applies it
 *          to an independent model of budgets and objects, failing at
 *          every step in turn; the core's undo must leave nothing of the
 *          domain. A full apply must leave, after destroying the own budget
 *          alone, exactly what the outer budget pays for. Prints a FAIL
 *          line for any breach, and counters.
 * cases    plans one mutation of a valid specification per case and prints
 *          "case NAME STATUS"; the test holds the expected statuses.
 * seeded   checks plans with one seeded violation each and prints
 *          "seeded NAME STATUS".
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "erx/dom.h"

#define MIB		(UINT64_C(1) << 20)
#define NDOMAINS	4
#define NCONNECTIONS	4

static erx_dom_t domains[NDOMAINS];
static erx_dom_connection_t connections[NCONNECTIONS];
static erx_dom_principal_t principal;
static erx_dom_configured_t configured;
static erx_dom_partial_t partial;
static erx_grant_t services[4];
static erx_dom_view_t view;
static unsigned long failures;

/* Files: 0 runtime, 1 JIT runtime, 2-4 release, 5 system, 6 sealed, 7 bad image. */
static const erx_dom_file_t files[] = {
	{ ERX_ENTRY_IMAGE, 0, true, 0 },
	{ ERX_ENTRY_IMAGE, 0, true, ERX_IMAGE_JIT },
	{ ERX_ENTRY_FILE, 0, false, 0 },
	{ ERX_ENTRY_FILE, 0, false, 0 },
	{ ERX_ENTRY_FILE, 0, false, 0 },
	{ ERX_ENTRY_FILE, ERX_ENTRY_SYSTEM, false, 0 },
	{ ERX_ENTRY_FILE, ERX_ENTRY_SEAL, false, 0 },
	{ ERX_ENTRY_IMAGE, 0, false, 0 },
};

static const char *const obj_names[] = {
	"NONE", "BUDGET", "OUTER", "SPACE", "GROUP", "SPACES_GROUP", "BOOTINFO",
	"CRASH", "SYS_BUDGET", "SYS_SIDE", "DOM_SIDE", "SYS_BELL", "DOM_BELL",
	"SLICE", "THREAD", "LINK_BUDGET_A", "LINK_BUDGET_B", "SIDE_A", "SIDE_B",
	"BELL_A", "BELL_B", "DEV_RESOURCE",
	"DEV_WINDOW0", "DEV_WINDOW1", "DEV_WINDOW2", "DEV_WINDOW3",
	"DEV_WINDOW4", "DEV_WINDOW5", "DEV_WINDOW6", "DEV_WINDOW7",
	"DEV_IRQ0", "DEV_IRQ1", "DEV_IRQ2", "DEV_IRQ3",
	"DEV_IRQ4", "DEV_IRQ5", "DEV_IRQ6", "DEV_IRQ7",
	"DEV_DMA", "DEV_MEMORY", "PRINCIPAL_BUDGET", "PARENT_GROUP", "SYSTEM_SPACE",
	"SYSTEM_GROUP", "FAULT_GATE", "TIME_PAGE", "OUTER_A", "OUTER_B",
	"GROUP_A", "GROUP_B", "SPACE_A", "SPACE_B", "ROOT_RESOURCE",
	"SYSTEM_BUDGET", "HOLDER_BUDGET", "HOLDER_SPACE", "DEV_KEPT"
};
_Static_assert(sizeof(obj_names) / sizeof(obj_names[0]) == ERX_DOM_OBJ_COUNT,
    "obj_names names every object");

static const char *const step_names[] = {
	"CARVE", "SPACE", "GROUP", "MEM", "BELL", "SLICE", "IMAGE_MAP", "MAP",
	"INSTALL", "BOOTINFO", "THREAD", "RESOURCE", "WINDOW", "IRQ", "DMA",
	"CONTIGUOUS"
};

static erx_grant_t
grant(uint64_t quota, uint64_t cpuset, uint8_t ceiling)
{
	erx_grant_t g;

	memset(&g, 0, sizeof(g));
	g.quota_ns = quota;
	g.period_ns = quota == ERX_QUOTA_NONE ? 0 : UINT64_C(10000000);
	g.cpuset = cpuset;
	g.ceiling.raw = ceiling;
	return (g);
}

static erx_runtime_limits_t
limits(uint32_t scale)
{
	return ((erx_runtime_limits_t){ .max_frame = 65536 * scale,
	    .max_message_heap = 1048576 * scale, .funnel_depth = 64 * scale,
	    .exports = 256 * scale, .tmp = MIB * scale, .overlay = MIB * scale,
	    .atoms = 4096 * scale, .foreign_atoms = 1024 * scale,
	    .processes = 1024 * scale, .peer_held = MIB * scale,
	    .peer_held_total = 4 * MIB * scale });
}

/* A machine with room for one more domain of each kind. */
static void
reset_view(void)
{
	memset(domains, 0, sizeof(domains));
	memset(connections, 0, sizeof(connections));
	principal = (erx_dom_principal_t){ .number = 1, .memory = 64 * MIB,
	    .domains_max = 3, .share = grant(UINT64_C(20000000), 0xf, 40),
	    .default_limits = limits(1), .ceiling_limits = limits(2) };
	configured = (erx_dom_configured_t){ .principal = 1,
	    .flags = ERX_DOM_SPACES, .release = 2, .release_files = 3,
	    .runtime = 1, .memory = 4 * MIB, .outer = MIB,
	    .grant = grant(UINT64_C(5000000), 0x3, 50),
	    .spaces = grant(UINT64_C(2500000), 0x1, 50),
	    .runtime_limits = limits(1), .lane = 65536, .connections = 2 };
	partial = (erx_dom_partial_t){ .runtime = 0, .memory = MIB,
	    .outer = 64 * 1024, .grant = grant(UINT64_C(1000000), 0x1, 10) };
	view = (erx_dom_view_t){ .domains = domains, .max_domains = NDOMAINS,
	    .connections = connections, .max_connections = NCONNECTIONS,
	    .principals = &principal, .nprincipals = 1, .files = files,
	    .nfiles = sizeof(files) / sizeof(files[0]),
	    .configured = &configured, .nconfigured = 1, .partial = &partial,
	    .npartial = 1, .partial_principal = 1, .native_limits = limits(1),
	    .system_grant = grant(ERX_QUOTA_NONE, 0xf, 63),
	    .system_reserve = 250, .service_grants = services,
	    .nservice_grants = 0, .system_lane = 16384, .next_connection = 1 };
}

static erx_dom_spec_t
base_request(void)
{
	erx_dom_spec_t req;

	memset(&req, 0, sizeof(req));
	req.id = 5;
	req.principal = 1;
	req.release = 2;
	req.release_files = 3;
	req.runtime = 0;
	req.memory = 4 * MIB;
	req.outer = MIB;
	req.grant = grant(UINT64_C(10000000), 0x3, 30);
	req.lane = 65536;
	req.connections = 2;
	req.runtime_limits = limits(1);
	req.args_len = 2;
	memcpy(req.strings, "a", 2);
	return (req);
}

/* The row a configured or partial-boot case plans; a mutation may move it. */
static uint32_t case_row;

/* The independent model: what is alive and what pays for it. */
typedef struct model {
	bool		alive[ERX_DOM_OBJ_COUNT];
	erx_dom_obj_t	payer[ERX_DOM_OBJ_COUNT];
	unsigned	in_space;	/* installs and mappings into the space */
} model_t;

static void
fail(const char *variant, unsigned at, const char *what)
{
	printf("FAIL %s at %u: %s\n", variant, at, what);
	failures++;
}

static bool
made(erx_dom_obj_t obj)
{
	return (obj > ERX_DOM_OBJ_NONE && obj < ERX_DOM_OBJ_MADE_COUNT);
}

/* Applies one step; false when it uses an object that is not alive. */
static bool
model_apply(model_t *m, const erx_dom_step_t *step)
{
	switch (step->kind) {
	case ERX_DOM_STEP_CARVE:
	case ERX_DOM_STEP_SPACE:
	case ERX_DOM_STEP_GROUP:
	case ERX_DOM_STEP_MEM:
	case ERX_DOM_STEP_BELL:
	case ERX_DOM_STEP_SLICE:
	case ERX_DOM_STEP_THREAD:
		if (made(step->budget) && !m->alive[step->budget])
			return (false);
		m->alive[step->obj] = true;
		m->payer[step->obj] = step->budget;
		return (true);
	case ERX_DOM_STEP_IMAGE_MAP:
	case ERX_DOM_STEP_MAP:
	case ERX_DOM_STEP_INSTALL:
		if (!m->alive[ERX_DOM_OBJ_SPACE] ||
		    (made(step->obj) && !m->alive[step->obj]))
			return (false);
		m->in_space++;
		return (true);
	case ERX_DOM_STEP_BOOTINFO:
		return (m->alive[step->obj]);
	case ERX_DOM_STEP_RESOURCE:
	case ERX_DOM_STEP_WINDOW:
	case ERX_DOM_STEP_IRQ:
	case ERX_DOM_STEP_DMA:
	case ERX_DOM_STEP_CONTIGUOUS:
		return (false);
	}
	return (false);
}

/* Destroys a budget and, to a fixed point, everything it pays for. */
static void
model_destroy(model_t *m, erx_dom_obj_t budget)
{
	bool changed = true;

	m->alive[budget] = false;
	while (changed) {
		changed = false;
		for (int obj = 0; obj < ERX_DOM_OBJ_MADE_COUNT; obj++) {
			if (m->alive[obj] && made(m->payer[obj]) &&
			    !m->alive[m->payer[obj]]) {
				m->alive[obj] = false;
				changed = true;
			}
		}
	}
	if (!m->alive[ERX_DOM_OBJ_SPACE])
		m->in_space = 0;
}

static unsigned long undone, applied_total;

/* Applies the first `at` steps, fails the next, and undoes. */
static void
inject(const char *variant, const erx_dom_plan_t *plan, unsigned at)
{
	erx_dom_obj_t undo[ERX_DOM_PLAN_STEPS_MAX];
	model_t m;
	uint32_t n;

	memset(&m, 0, sizeof(m));
	for (unsigned index = 0; index < at; index++) {
		if (!model_apply(&m, &plan->steps[index]))
			fail(variant, index, "step uses a dead object");
		applied_total++;
	}
	n = erx_dom_plan_undo(plan, at, undo);
	for (uint32_t index = 0; index < n; index++) {
		if (!m.alive[undo[index]])
			fail(variant, at, "undo destroys a dead budget");
		model_destroy(&m, undo[index]);
		undone++;
	}
	for (int obj = 0; obj < ERX_DOM_OBJ_MADE_COUNT; obj++)
		if (m.alive[obj]) {
			printf("FAIL %s at %u: %s survives the undo\n", variant,
			    at, obj_names[obj]);
			failures++;
		}
	if (m.in_space != 0)
		fail(variant, at, "an install survives the undo");
}

/* A full apply: the own budget's destroy leaves what the outer budget pays. */
static void
ending(const char *variant, const erx_dom_plan_t *plan)
{
	model_t m;
	char line[512] = "";
	size_t used = 0;

	memset(&m, 0, sizeof(m));
	for (uint32_t index = 0; index < plan->nsteps; index++)
		if (!model_apply(&m, &plan->steps[index]))
			fail(variant, index, "step uses a dead object");
	model_destroy(&m, ERX_DOM_OBJ_BUDGET);
	for (int obj = 0; obj < ERX_DOM_OBJ_MADE_COUNT; obj++)
		if (m.alive[obj]) {
			used += snprintf(line + used, sizeof(line) - used, " %s",
			    obj_names[obj]);
		}
	printf("after-destroy %s%s\n", variant, line);
	model_destroy(&m, ERX_DOM_OBJ_OUTER);
	for (int obj = 0; obj < ERX_DOM_OBJ_MADE_COUNT; obj++)
		if (m.alive[obj])
			fail(variant, plan->nsteps, "survives the retire");
}

static void
print_steps(const char *variant, const erx_dom_plan_t *plan)
{
	printf("steps %s", variant);
	for (uint32_t index = 0; index < plan->nsteps; index++)
		printf(" %s:%s", step_names[plan->steps[index].kind],
		    obj_names[plan->steps[index].kind == ERX_DOM_STEP_IMAGE_MAP ?
		    plan->steps[index].target : plan->steps[index].obj]);
	printf("\n");
}

static void
explore_one(const char *variant, erx_status_t status,
    const erx_dom_plan_t *plan)
{
	if (status != ERX_OK) {
		printf("FAIL %s: planned %d\n", variant, (int)status);
		failures++;
		return;
	}
	print_steps(variant, plan);
	for (unsigned at = 0; at <= plan->nsteps; at++)
		inject(variant, plan, at);
	ending(variant, plan);
}

static int
explore(void)
{
	erx_dom_spec_t req;
	erx_dom_plan_t plan;

	reset_view();
	req = base_request();
	explore_one("request", erx_dom_plan_request(&view, &req, NULL, 0, &plan),
	    &plan);
	req.flags = ERX_DOM_SPACES;
	req.spaces = grant(UINT64_C(5000000), 0x1, 20);
	req.runtime = 1;
	explore_one("request-spaces-jit",
	    erx_dom_plan_request(&view, &req, NULL, 0, &plan), &plan);
	explore_one("configured", erx_dom_plan_configured(&view, 6, 0, &plan),
	    &plan);
	explore_one("partial", erx_dom_plan_partial(&view, 7, 0, &plan), &plan);
	printf("explore variants=4 applied=%lu undone=%lu failures=%lu\n",
	    applied_total, undone, failures);
	return (failures == 0 ? 0 : 1);
}

typedef enum origin_pick { PICK_REQUEST, PICK_CONFIGURED, PICK_PARTIAL } origin_pick_t;

/*
 * One case: mutate the request or the view, plan from the origin, print.
 * A configured or partial-boot case's mutations change the view's rows.
 */
static void
run_case(const char *name, origin_pick_t pick,
    void (*mutate)(erx_dom_spec_t *))
{
	erx_dom_spec_t req = base_request();
	erx_dom_plan_t plan;
	erx_status_t status;

	case_row = 0;
	if (mutate != NULL)
		mutate(&req);
	switch (pick) {
	case PICK_REQUEST:
		/* Every limit given, so a case may set any of them. */
		status = erx_dom_plan_request(&view, &req, &req.runtime_limits,
		    ERX_DOM_LIMITS_ALL, &plan);
		break;
	case PICK_CONFIGURED:
		status = erx_dom_plan_configured(&view, 6, case_row, &plan);
		break;
	case PICK_PARTIAL:
		status = erx_dom_plan_partial(&view, 7, case_row, &plan);
		break;
	default:
		status = ERX_EINVAL;
	}
	printf("case %s %d\n", name, (int)status);
	reset_view();
}

#define MUTATION(name, body)						\
	static void name(erx_dom_spec_t *s) { (void)s; body; }
MUTATION(m_id_zero, s->id = 0)
MUTATION(m_id_system, s->id = ERX_DOM_SYSTEM_ID)
MUTATION(m_id_last, s->id = UINT32_C(0xffffffff))
MUTATION(m_id_in_use, domains[2].id = s->id)
MUTATION(m_unknown_flag, s->flags |= 0x80)
MUTATION(m_secret, s->flags |= ERX_DOM_SECRET)
MUTATION(m_unknown_principal, s->principal = 9)
MUTATION(m_configured_row_out, case_row = 1)
MUTATION(m_partial_row_out, case_row = 1)
MUTATION(m_runtime_out, s->runtime = 99)
MUTATION(m_runtime_file, s->runtime = 2)
MUTATION(m_runtime_bad, s->runtime = 7)
MUTATION(m_release_past_end, s->release_files = 7)
MUTATION(m_release_empty, s->release_files = 0)
MUTATION(m_release_system, (s->release = 3, s->release_files = 3))
MUTATION(m_release_sealed, (s->release = 6, s->release_files = 1))
MUTATION(m_release_image, (s->release = 1, s->release_files = 2))
MUTATION(m_release_wraps, (s->release = UINT32_C(0xffffffff), s->release_files = 2))
MUTATION(m_memory_zero, s->memory = 0)
MUTATION(m_memory_unaligned, s->memory += 1)
MUTATION(m_outer_small, s->outer = ERX_PAGE_SIZE * 4)
MUTATION(m_lane_small, s->lane = ERX_LANE_MIN - 1)
MUTATION(m_lane_large, s->lane = ERX_LANE_MAX)
MUTATION(m_connections_over, s->connections = NCONNECTIONS + 1)
MUTATION(m_strings_long, (s->args_len = ERX_BOOT_STRINGS_MAX, s->env_len = 2))
MUTATION(m_strings_wrap, (s->args_len = UINT32_C(0xffffffff), s->env_len = 2))
MUTATION(m_args_no_nul, s->strings[1] = 'x')
MUTATION(m_env_no_nul, (s->env_len = 2, s->strings[2] = 'e', s->strings[3] = 'x'))
MUTATION(m_env_ok, (s->env_len = 2, s->strings[2] = 'e', s->strings[3] = 0))
MUTATION(m_limits_ceiling, s->runtime_limits.atoms = limits(2).atoms + 1)
MUTATION(m_limits_reserved, s->runtime_limits.reserved = 1)
MUTATION(m_limits_frame_zero, s->runtime_limits.max_frame = 0)
MUTATION(m_grant_cpus, s->grant.cpuset = 0x10)
MUTATION(m_grant_empty, s->grant.cpuset = 0)
MUTATION(m_grant_rate, s->grant = grant(ERX_QUOTA_NONE, 0x7, 30))
MUTATION(m_grant_ceiling, s->grant.ceiling.raw = 41)
MUTATION(m_grant_period, s->grant.period_ns = ERX_PERIOD_MIN - 1)
MUTATION(m_grant_quota, s->grant.quota_ns = UINT64_C(30000000))
MUTATION(m_grant_padding, s->grant.padding_0[1] = 1)
MUTATION(m_spaces_no_flag, s->spaces = grant(UINT64_C(1000000), 0x1, 1))
MUTATION(m_spaces_over, (s->flags |= ERX_DOM_SPACES, s->spaces = grant(UINT64_C(20000000), 0x3, 1)))
MUTATION(m_spaces_ok, (s->flags |= ERX_DOM_SPACES, s->spaces = grant(UINT64_C(5000000), 0x1, 1)))
MUTATION(m_quota_full, principal.domains = principal.domains_max)
MUTATION(m_table_full, for (int i = 0; i < NDOMAINS; i++) domains[i].id = 100 + i)
MUTATION(m_connections_full, for (int i = 0; i < NCONNECTIONS; i++) connections[i].number = i + 1)
MUTATION(m_principal_memory, principal.carved = principal.memory - 4 * MIB)
MUTATION(m_ending, view.ending = true)
/* a configured grant must fit system as well as leave its reserve */
MUTATION(m_configured_outside, configured.grant.cpuset = 0x30)
MUTATION(m_configured_ceiling, view.system_grant.ceiling.raw = 20)
MUTATION(m_configured_flags, configured.grant.flags = ERX_GROUP_DEFER)
/* configured: system's 3 CPUs of headroom with services taking 2.5 of them */
MUTATION(m_services_room, (services[0] = grant(ERX_QUOTA_NONE, 0x3, 1),
    services[1] = grant(UINT64_C(5000000), 0x4, 1), view.nservice_grants = 2))
MUTATION(m_services_over, (services[0] = grant(ERX_QUOTA_NONE, 0x3, 1),
    services[1] = grant(UINT64_C(6000000), 0x4, 1), view.nservice_grants = 2))
/* grants outside system's CPUs still count in the rate clause */
MUTATION(m_services_outside, (view.system_grant = grant(ERX_QUOTA_NONE, 0x3, 63),
    view.system_reserve = 1, services[0] = grant(ERX_QUOTA_NONE, 0xc, 1),
    services[1] = grant(ERX_QUOTA_NONE, 0x30, 1), view.nservice_grants = 2,
    services[2] = grant(UINT64_C(5000000), 0x1, 1), view.nservice_grants = 3))
/* a narrow principal share: a configured service fits system, a request not */
MUTATION(m_narrow_share, principal.share = grant(ERX_QUOTA_NONE, 0x1, 40))
MUTATION(m_narrow_share_request, (principal.share = grant(ERX_QUOTA_NONE, 0x1, 40),
    s->grant = configured.grant))

static int
cases(void)
{
	reset_view();
	run_case("ok_request", PICK_REQUEST, NULL);
	run_case("ok_configured", PICK_CONFIGURED, NULL);
	run_case("ok_partial", PICK_PARTIAL, NULL);
	run_case("id_zero", PICK_REQUEST, m_id_zero);
	run_case("id_system", PICK_REQUEST, m_id_system);
	run_case("id_last", PICK_REQUEST, m_id_last);
	run_case("id_in_use", PICK_REQUEST, m_id_in_use);
	run_case("unknown_flag", PICK_REQUEST, m_unknown_flag);
	run_case("secret", PICK_REQUEST, m_secret);
	run_case("unknown_principal", PICK_REQUEST, m_unknown_principal);
	run_case("configured_row_out", PICK_CONFIGURED, m_configured_row_out);
	run_case("partial_row_out", PICK_PARTIAL, m_partial_row_out);
	run_case("partial_connections_full", PICK_PARTIAL, m_connections_full);
	run_case("runtime_out", PICK_REQUEST, m_runtime_out);
	run_case("runtime_file", PICK_REQUEST, m_runtime_file);
	run_case("runtime_bad", PICK_REQUEST, m_runtime_bad);
	run_case("release_past_end", PICK_REQUEST, m_release_past_end);
	run_case("release_empty", PICK_REQUEST, m_release_empty);
	run_case("release_system", PICK_REQUEST, m_release_system);
	run_case("release_sealed", PICK_REQUEST, m_release_sealed);
	run_case("release_image", PICK_REQUEST, m_release_image);
	run_case("release_wraps", PICK_REQUEST, m_release_wraps);
	run_case("memory_zero", PICK_REQUEST, m_memory_zero);
	run_case("memory_unaligned", PICK_REQUEST, m_memory_unaligned);
	run_case("outer_small", PICK_REQUEST, m_outer_small);
	run_case("lane_small", PICK_REQUEST, m_lane_small);
	run_case("lane_large", PICK_REQUEST, m_lane_large);
	run_case("connections_over", PICK_REQUEST, m_connections_over);
	run_case("strings_long", PICK_REQUEST, m_strings_long);
	run_case("strings_wrap", PICK_REQUEST, m_strings_wrap);
	run_case("args_no_nul", PICK_REQUEST, m_args_no_nul);
	run_case("env_no_nul", PICK_REQUEST, m_env_no_nul);
	run_case("env_ok", PICK_REQUEST, m_env_ok);
	run_case("limits_ceiling", PICK_REQUEST, m_limits_ceiling);
	run_case("limits_reserved_cleared", PICK_REQUEST, m_limits_reserved);
	run_case("limits_frame_zero", PICK_REQUEST, m_limits_frame_zero);
	run_case("grant_cpus", PICK_REQUEST, m_grant_cpus);
	run_case("grant_empty", PICK_REQUEST, m_grant_empty);
	run_case("grant_rate", PICK_REQUEST, m_grant_rate);
	run_case("grant_ceiling", PICK_REQUEST, m_grant_ceiling);
	run_case("grant_period", PICK_REQUEST, m_grant_period);
	run_case("grant_quota", PICK_REQUEST, m_grant_quota);
	run_case("grant_padding", PICK_REQUEST, m_grant_padding);
	run_case("spaces_no_flag", PICK_REQUEST, m_spaces_no_flag);
	run_case("spaces_over", PICK_REQUEST, m_spaces_over);
	run_case("spaces_ok", PICK_REQUEST, m_spaces_ok);
	run_case("quota_full", PICK_REQUEST, m_quota_full);
	run_case("table_full", PICK_REQUEST, m_table_full);
	run_case("connections_full", PICK_REQUEST, m_connections_full);
	run_case("principal_memory", PICK_REQUEST, m_principal_memory);
	run_case("ending", PICK_REQUEST, m_ending);
	run_case("configured_outside", PICK_CONFIGURED, m_configured_outside);
	run_case("configured_ceiling", PICK_CONFIGURED, m_configured_ceiling);
	run_case("configured_flags", PICK_CONFIGURED, m_configured_flags);
	run_case("services_room", PICK_CONFIGURED, m_services_room);
	run_case("services_over", PICK_CONFIGURED, m_services_over);
	run_case("services_outside", PICK_CONFIGURED, m_services_outside);
	run_case("narrow_share_configured", PICK_CONFIGURED, m_narrow_share);
	run_case("narrow_share_request", PICK_REQUEST, m_narrow_share_request);
	return (0);
}

/*
 * Constructor cases: defaults fill what a request leaves out, the origin
 * and the library's own fields are the constructor's whatever the request
 * says, and the strings past the arguments are zeroed.
 */
static void
constructors(void)
{
	erx_dom_spec_t req = base_request();
	erx_runtime_limits_t given = limits(2);
	erx_dom_plan_t plan;
	erx_status_t status;

	given.atoms = 5000;
	status = erx_dom_plan_request(&view, &req, &given, UINT32_C(1) << 6, &plan);
	printf("ctor given_atoms %d %u %u\n", (int)status,
	    plan.spec.runtime_limits.atoms, plan.spec.runtime_limits.processes);
	printf("ctor unknown_mask %d\n",
	    (int)erx_dom_plan_request(&view, &req, &given, UINT32_C(1) << 11, &plan));
	printf("ctor null_limits %d\n",
	    (int)erx_dom_plan_request(&view, &req, NULL, 1, &plan));
	req.principal = 2;
	printf("ctor unknown_principal %d\n",
	    (int)erx_dom_plan_request(&view, &req, NULL, 0, &plan));
	req = base_request();
	req.version = 9;
	req.origin = (erx_dom_origin_t){ ERX_DOM_CONFIGURED, 0 };
	req.crash = 0;
	req.system_lane = 4096;
	req.strings[5] = 'z';
	status = erx_dom_plan_request(&view, &req, NULL, 0, &plan);
	printf("ctor request_owned %d %u %u %u %u %u %u %d\n", (int)status,
	    plan.spec.version, plan.spec.origin.kind, plan.spec.origin.record,
	    plan.spec.crash, plan.spec.system_lane, (unsigned)plan.parent,
	    plan.spec.strings[5]);
	printf("ctor configured_row_out %d\n",
	    (int)erx_dom_plan_configured(&view, 6, 1, &plan));
	printf("ctor partial_row_out %d\n",
	    (int)erx_dom_plan_partial(&view, 6, 1, &plan));
	status = erx_dom_plan_configured(&view, 6, 0, &plan);
	printf("ctor configured_owned %d %u %u %u\n", (int)status,
	    plan.spec.origin.kind, plan.spec.origin.record, (unsigned)plan.parent);
	status = erx_dom_plan_partial(&view, 7, 0, &plan);
	printf("ctor partial_owned %d %u %u %u\n", (int)status,
	    plan.spec.origin.kind, plan.connection, plan.connection_row);
}

static int
seeded(void)
{
	erx_dom_spec_t req = base_request();
	erx_dom_plan_t plan, seed;
	erx_dom_step_t *last;

	reset_view();
	constructors();
	if (erx_dom_plan_request(&view, &req, NULL, 0, &plan) != ERX_OK)
		return (1);
	printf("seeded valid %d\n", (int)erx_dom_plan_check(&plan));

	/* The one installer: a foreign gate in the domain's table. */
	seed = plan;
	seed.steps[seed.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_INSTALL, .obj = ERX_DOM_OBJ_FAULT_GATE,
	    .target = ERX_DOM_OBJ_SPACE };
	printf("seeded foreign_gate %d\n", (int)erx_dom_plan_check(&seed));

	/* A right the grants row lacks. */
	seed = plan;
	seed.steps[seed.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_INSTALL, .obj = ERX_DOM_OBJ_SYS_BELL,
	    .target = ERX_DOM_OBJ_SPACE, .rights = ERX_HR_TRIGGER | ERX_HR_BIND };
	printf("seeded extra_right %d\n", (int)erx_dom_plan_check(&seed));

	/* The sub-space group's rights without ERX_DOM_SPACES. */
	seed = plan;
	seed.steps[seed.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_INSTALL, .obj = ERX_DOM_OBJ_BUDGET,
	    .target = ERX_DOM_OBJ_SPACE, .rights = ERX_HR_ALLOC | ERX_HR_SPACES };
	printf("seeded spaces_right %d\n", (int)erx_dom_plan_check(&seed));

	/* An object charged to the principal, which no undo destroys. */
	seed = plan;
	for (uint32_t index = 0; index < seed.nsteps; index++)
		if (seed.steps[index].obj == ERX_DOM_OBJ_CRASH)
			seed.steps[index].budget = ERX_DOM_OBJ_PRINCIPAL_BUDGET;
	printf("seeded principal_charge %d\n", (int)erx_dom_plan_check(&seed));

	/* A step that uses the space before it exists. */
	seed = plan;
	last = &seed.steps[0];
	*last = (erx_dom_step_t){ .kind = ERX_DOM_STEP_MAP,
	    .obj = ERX_DOM_OBJ_BOOTINFO, .target = ERX_DOM_OBJ_SPACE };
	printf("seeded out_of_order %d\n", (int)erx_dom_plan_check(&seed));

	/* An object enumerator past the table. */
	seed = plan;
	seed.steps[1].budget = ERX_DOM_OBJ_COUNT;
	printf("seeded obj_range %d\n", (int)erx_dom_plan_check(&seed));
	return (0);
}

/*
 * erx_dom_principal_check over a configuration with one field broken per
 * case, against a view that holds principal 1.
 */
static void
principal_case(const char *name, void (*breaks)(erx_dom_principal_t *))
{
	erx_dom_principal_t config = { .number = 2, .memory = 16 * MIB,
	    .carved = 7, .domains_max = 4, .domains = 3,
	    .share = grant(UINT64_C(5000000), 0x3, 40),
	    .default_limits = limits(1), .ceiling_limits = limits(2) };
	erx_dom_principal_t record;
	erx_status_t status;

	reset_view();
	breaks(&config);
	memset(&record, 0xa5, sizeof(record));
	status = erx_dom_principal_check(&view, &config, &record);
	if (status != ERX_OK) {
		printf("principal %s %d\n", name, (int)status);
		return;
	}
	printf("principal %s 0 number=%u carved=%llu domains=%u same=%d\n",
	    name, record.number, (unsigned long long)record.carved,
	    record.domains, record.memory == config.memory &&
	    record.domains_max == config.domains_max &&
	    memcmp(&record.share, &config.share, sizeof(config.share)) == 0 &&
	    memcmp(&record.ceiling_limits, &config.ceiling_limits,
	    sizeof(config.ceiling_limits)) == 0);
}

#define PRINCIPAL(fn, body)	static void fn(erx_dom_principal_t *p) { body; }
PRINCIPAL(p_ok, (void)p)
PRINCIPAL(p_number_zero, p->number = 0)
PRINCIPAL(p_number_taken, p->number = 1)
PRINCIPAL(p_memory_zero, p->memory = 0)
PRINCIPAL(p_memory_unaligned, p->memory = 16 * MIB + 1)
PRINCIPAL(p_share_empty, p->share.cpuset = 0)
PRINCIPAL(p_share_padding, p->share.padding_0[0] = 1)
PRINCIPAL(p_domains_zero, p->domains_max = 0)
PRINCIPAL(p_default_over, p->default_limits.atoms = p->ceiling_limits.atoms + 1)
PRINCIPAL(p_default_frame_zero, p->default_limits.max_frame = 0)
PRINCIPAL(p_ceiling_frame_zero, p->ceiling_limits.max_frame = 0)
PRINCIPAL(p_ceiling_frame_over, p->ceiling_limits.max_frame = ERX_FRAME_MAX + 1)
PRINCIPAL(p_ceiling_reserved, p->ceiling_limits.reserved = 1)
#undef PRINCIPAL

static int
principals(void)
{
	principal_case("ok", p_ok);
	principal_case("number_zero", p_number_zero);
	principal_case("number_taken", p_number_taken);
	principal_case("memory_zero", p_memory_zero);
	principal_case("memory_unaligned", p_memory_unaligned);
	principal_case("share_empty", p_share_empty);
	principal_case("share_padding", p_share_padding);
	principal_case("domains_zero", p_domains_zero);
	principal_case("default_over", p_default_over);
	principal_case("default_frame_zero", p_default_frame_zero);
	principal_case("ceiling_frame_zero", p_ceiling_frame_zero);
	principal_case("ceiling_frame_over", p_ceiling_frame_over);
	principal_case("ceiling_reserved", p_ceiling_reserved);
	return (0);
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "explore") == 0)
		return (explore());
	if (argc == 2 && strcmp(argv[1], "cases") == 0)
		return (cases());
	if (argc == 2 && strcmp(argv[1], "seeded") == 0)
		return (seeded());
	if (argc == 2 && strcmp(argv[1], "principal") == 0)
		return (principals());
	fprintf(stderr, "usage: dom_core_driver explore|cases|seeded|principal\n");
	return (2);
}
