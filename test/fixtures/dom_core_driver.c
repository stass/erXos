/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the domain library's pure core (liberx/system/dom_core.c),
 * judged by test/host/dom_core_test.rb. Five modes:
 *
 * explore  plans each creation variant, prints its steps, then applies it
 *          to an independent model of budgets and objects, failing at
 *          every step in turn; the core's undo must leave nothing of the
 *          domain. A full apply must leave, after destroying the own budget
 *          alone, exactly what the outer budget pays for. Prints a FAIL
 *          line for any breach, and counters.
 * cases    plans one mutation of a valid specification per case and prints
 *          "case NAME STATUS"; the test holds the expected statuses.
 *          A session case plans session template case_row of the view.
 * seeded   checks plans with one seeded violation each and prints
 *          "seeded NAME STATUS", after the constructor cases' "ctor" lines.
 * principal  checks one principal configuration per case.
 * record   records plans into the view and prints what each left there.
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
static erx_dom_remains_t remains[2 * NCONNECTIONS];
static erx_dom_principal_t principal;
static erx_dom_configured_t configured;
static erx_dom_partial_t partial;
static erx_dom_template_t session_template;
static erx_dom_view_t view;
static unsigned long failures;

/* Files: 0 runtime, 1 JIT runtime, 2-4 release, 5 system, 6 sealed, 7 bad image. */
static const erx_dom_file_t files[] = {
	{ ERX_ENTRY_IMAGE, 0, true, 0, 1 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_IMAGE, 0, true, ERX_IMAGE_JIT, 2 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_FILE, 0, false, 0, 3 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_FILE, 0, false, 0, 4 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_FILE, 0, false, 0, 5 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_FILE, ERX_ENTRY_SYSTEM, false, 0, 6 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_FILE, ERX_ENTRY_SEAL, false, 0, 7 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_IMAGE, 0, false, 0, 8 * ERX_PAGE_SIZE, 100 },
};

/* Eight names of a device object kind, one per device, window or line. */
#define EIGHT(kind)	kind "0", kind "1", kind "2", kind "3", kind "4", kind "5", kind "6", kind "7"
static const char *const obj_names[] = {
	"NONE", "BUDGET", "OUTER", "SPACE", "GROUP", "SPACES_GROUP", "BOOTINFO",
	"CRASH", "SYS_BUDGET", "SYS_SIDE", "DOM_SIDE", "SYS_BELL", "DOM_BELL",
	"SLICE", "THREAD", "LINK_BUDGET_A", "LINK_BUDGET_B", "SIDE_A", "SIDE_B",
	"BELL_A", "BELL_B", "AREA_A", "AREA_B", EIGHT("DEV_RESOURCE"),
	EIGHT("DEV_WINDOW"), EIGHT("DEV_IRQ"), EIGHT("DEV_DMA"), EIGHT("DEV_MEMORY"),
	"PRINCIPAL_BUDGET", "PARENT_GROUP", "SYSTEM_SPACE",
	"SYSTEM_GROUP", "FAULT_GATE", "TIME_PAGE", "OUTER_A", "OUTER_B",
	"GROUP_A", "GROUP_B", "SPACE_A", "SPACE_B", "ROOT_RESOURCE",
	"SYSTEM_BUDGET", "HOLDER_BUDGET", "HOLDER_SPACE", EIGHT("DEV_KEPT")
};
#undef EIGHT
_Static_assert(sizeof(obj_names) / sizeof(obj_names[0]) == ERX_DOM_OBJ_COUNT,
    "obj_names names every object");

static const char *const step_names[] = {
	"CARVE", "SPACE", "GROUP", "MEM", "BELL", "SLICE", "IMAGE_MAP", "MAP",
	"INSTALL", "BOOTINFO", "THREAD", "RESOURCE", "WINDOW", "IRQ", "DMA",
	"CONTIGUOUS", "GIVE"
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
	memset(remains, 0, sizeof(remains));
	principal = (erx_dom_principal_t){ .number = 1, .memory = 64 * MIB,
	    .domains_max = 3, .share = grant(UINT64_C(20000000), 0xf, 40),
	    .default_limits = limits(1), .ceiling_limits = limits(2) };
	configured = (erx_dom_configured_t){ .principal = 1,
	    .flags = ERX_DOM_SPACES, .release = 2, .release_files = 3,
	    .runtime = 1, .memory = 4 * MIB, .outer = MIB,
	    .grant = grant(UINT64_C(5000000), 0x3, 50),
	    .spaces = grant(UINT64_C(2500000), 0x1, 50),
	    .runtime_limits = limits(1), .lane = 65536, .connections = 2,
	    .name = "srv", .name_len = 3 };
	/* Atoms the principal's default is not, so a plan shows the template's. */
	session_template = (erx_dom_template_t){ .principal = 1,
	    .flags = ERX_DOM_SPACES, .release = 2, .release_files = 3,
	    .runtime = 1, .memory = 4 * MIB, .outer = MIB,
	    .grant = grant(UINT64_C(5000000), 0x3, 30),
	    .spaces = grant(UINT64_C(2500000), 0x1, 30),
	    .runtime_limits = limits(1), .lane = 65536, .connections = 2,
	    .args = "a", .args_len = 2 };
	session_template.runtime_limits.atoms = 6000;
	partial = (erx_dom_partial_t){ .runtime = 0, .memory = MIB,
	    .outer = 64 * 1024, .grant = grant(UINT64_C(1000000), 0x1, 10) };
	view = (erx_dom_view_t){ .domains = domains, .max_domains = NDOMAINS,
	    .connections = connections, .max_connections = NCONNECTIONS,
	    .remains = remains, .max_remains = 2 * NCONNECTIONS,
	    .principals = &principal, .nprincipals = 1, .files = files,
	    .nfiles = sizeof(files) / sizeof(files[0]),
	    .configured = &configured, .nconfigured = 1, .partial = &partial,
	    .npartial = 1, .partial_principal = 1, .native_limits = limits(1),
	    .templates = &session_template, .ntemplates = 1,
	    .system_grant = grant(ERX_QUOTA_NONE, 0xf, 63),
	    .system_reserve = 250, .system_lane = 16384, .next_connection = 1 };
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
	req.name_len = 3;
	memcpy(req.name, "dom", 3);
	return (req);
}

/*
 * The row a configured or partial-boot case plans, or the template a
 * session case plans; a mutation may move it.
 */
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
	case ERX_DOM_STEP_GIVE:
		/* A give installs into the space, on the domain's budget. */
		return (m->alive[ERX_DOM_OBJ_SPACE] && m->alive[ERX_DOM_OBJ_BUDGET]);
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

/*
 * What the plan's space step asks of the kernel: jit for ERX_SPACE_JIT, plain
 * for none, other for anything else.
 */
static void
print_space(const char *variant, const erx_dom_plan_t *plan)
{
	const char *kind;

	for (uint32_t index = 0; index < plan->nsteps; index++) {
		if (plan->steps[index].kind != ERX_DOM_STEP_SPACE)
			continue;
		if (plan->steps[index].flags == ERX_SPACE_JIT)
			kind = "jit";
		else if (plan->steps[index].flags == 0)
			kind = "plain";
		else
			kind = "other";
		printf("space %s %s\n", variant, kind);
	}
}

/*
 * A plan's space only, for the variants that cross the runtime image with
 * sub-spaces, so the JIT flag is seen to follow from the image and nothing else.
 */
static void
space_one(const char *variant, erx_status_t status, const erx_dom_plan_t *plan)
{
	if (status != ERX_OK) {
		printf("FAIL %s: planned %d\n", variant, (int)status);
		failures++;
		return;
	}
	print_space(variant, plan);
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
	print_space(variant, plan);
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
	req.runtime = 1;
	space_one("request-jit",
	    erx_dom_plan_request(&view, &req, NULL, 0, &plan), &plan);
	req.runtime = 0;
	req.flags = ERX_DOM_SPACES;
	req.spaces = grant(UINT64_C(5000000), 0x1, 20);
	space_one("request-spaces",
	    erx_dom_plan_request(&view, &req, NULL, 0, &plan), &plan);
	req.flags = ERX_DOM_SPACES;
	req.spaces = grant(UINT64_C(5000000), 0x1, 20);
	req.runtime = 1;
	explore_one("request-spaces-jit",
	    erx_dom_plan_request(&view, &req, NULL, 0, &plan), &plan);
	explore_one("configured", erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan),
	    &plan);
	explore_one("partial", erx_dom_plan_partial(&view, 7, 0, &plan), &plan);
	printf("explore variants=4 applied=%lu undone=%lu failures=%lu\n",
	    applied_total, undone, failures);
	return (failures == 0 ? 0 : 1);
}

typedef enum origin_pick {
	PICK_REQUEST, PICK_CONFIGURED, PICK_PARTIAL, PICK_SESSION
} origin_pick_t;

/*
 * One case: mutate the request or the view, plan from the origin, print.
 * A configured, partial-boot or session case's mutations change the
 * view's rows; a session is named by the request's name.
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
		status = erx_dom_plan_configured(&view, 6, case_row, ERX_DOM_PID_NONE, &plan);
		break;
	case PICK_PARTIAL:
		status = erx_dom_plan_partial(&view, 7, case_row, &plan);
		break;
	case PICK_SESSION:
		status = erx_dom_plan_session(&view, 8, case_row, req.name,
		    req.name_len, ERX_DOM_PID_NONE, &plan);
		break;
	default:
		status = ERX_EINVAL;
	}
	printf("case %s %d\n", name, (int)status);
	reset_view();
}

/* A running domain of origin kind in slot, with grant, as if recorded. */
static void
running(uint32_t slot, uint32_t kind, erx_grant_t grant)
{
	domains[slot] = (erx_dom_t){ .id = 100 + slot, .principal = 1,
	    .origin = { .kind = kind }, .state = ERX_DOM_RUNNING,
	    .grant = grant };
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
MUTATION(m_template_at, case_row = 1)
MUTATION(m_template_past, case_row = UINT32_C(0xffffffff))
/* No sub-space grant either, so only the origin's SPACES clause refuses it. */
MUTATION(m_session_no_spaces, (session_template.flags = 0,
    memset(&session_template.spaces, 0, sizeof(session_template.spaces))))
MUTATION(m_session_ceiling, session_template.runtime_limits.atoms = limits(2).atoms + 1)
MUTATION(m_name_empty, s->name_len = 0)
MUTATION(m_name_lead, s->name[0] = '-')
MUTATION(m_name_upper, s->name[1] = 'O')
MUTATION(m_name_dot, s->name[1] = '.')
MUTATION(m_name_long, s->name_len = ERX_DOM_NAME_MAX + 1)
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
/*
 * configured: system's 3 CPUs of headroom with running configured domains
 * taking 2.5 of them
 */
MUTATION(m_services_room, (running(0, ERX_DOM_CONFIGURED, grant(ERX_QUOTA_NONE, 0x3, 1)),
    running(1, ERX_DOM_CONFIGURED, grant(UINT64_C(5000000), 0x4, 1))))
MUTATION(m_services_over, (running(0, ERX_DOM_CONFIGURED, grant(ERX_QUOTA_NONE, 0x3, 1)),
    running(1, ERX_DOM_CONFIGURED, grant(UINT64_C(6000000), 0x4, 1))))
/* a request's group is under its principal's, so its grant takes no reserve */
MUTATION(m_services_request, running(0, ERX_DOM_REQUEST, grant(ERX_QUOTA_NONE, 0xf, 1)))
/* grants outside system's CPUs still count in the rate clause */
MUTATION(m_services_outside, (view.system_grant = grant(ERX_QUOTA_NONE, 0x3, 63),
    view.system_reserve = 1,
    running(0, ERX_DOM_CONFIGURED, grant(ERX_QUOTA_NONE, 0xc, 1)),
    running(1, ERX_DOM_CONFIGURED, grant(ERX_QUOTA_NONE, 0x30, 1)),
    running(2, ERX_DOM_CONFIGURED, grant(UINT64_C(5000000), 0x1, 1))))
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
	run_case("name_empty", PICK_REQUEST, m_name_empty);
	run_case("name_lead", PICK_REQUEST, m_name_lead);
	run_case("name_upper", PICK_REQUEST, m_name_upper);
	run_case("name_dot", PICK_REQUEST, m_name_dot);
	run_case("name_long", PICK_REQUEST, m_name_long);
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
	run_case("services_request", PICK_CONFIGURED, m_services_request);
	run_case("services_outside", PICK_CONFIGURED, m_services_outside);
	run_case("narrow_share_configured", PICK_CONFIGURED, m_narrow_share);
	run_case("narrow_share_request", PICK_REQUEST, m_narrow_share_request);
	run_case("ok_session", PICK_SESSION, NULL);
	run_case("session_no_spaces", PICK_SESSION, m_session_no_spaces);
	run_case("session_ceiling", PICK_SESSION, m_session_ceiling);
	run_case("session_principal_memory", PICK_SESSION, m_principal_memory);
	run_case("session_quota_full", PICK_SESSION, m_quota_full);
	run_case("session_template_at", PICK_SESSION, m_template_at);
	run_case("session_template_past", PICK_SESSION, m_template_past);
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
	/*
	 * Files 2-4 start at page 3 and the last ends 100 bytes into page 5, so
	 * the slice's map covers three pages; the lane the domain reads is its
	 * 64 KiB lane alone, the control records travelling in the table.
	 */
	for (uint32_t index = 0; index < plan.nsteps; index++)
		if (plan.steps[index].kind == ERX_DOM_STEP_MAP &&
		    plan.steps[index].obj == ERX_DOM_OBJ_SLICE)
			printf("ctor spans %llu %llu\n",
			    (unsigned long long)(plan.steps[index].size / ERX_PAGE_SIZE),
			    (unsigned long long)plan.reader);
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
	    (int)erx_dom_plan_configured(&view, 6, 1, ERX_DOM_PID_NONE, &plan));
	printf("ctor partial_row_out %d\n",
	    (int)erx_dom_plan_partial(&view, 6, 1, &plan));
	status = erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan);
	printf("ctor configured_owned %d %u %u %u %.*s\n", (int)status,
	    plan.spec.origin.kind, plan.spec.origin.record, (unsigned)plan.parent,
	    (int)plan.spec.name_len, plan.spec.name);
	/* A display domain's environment is its row's words, then its display's. */
	configured.env = "LANG=C";
	configured.env_len = sizeof("LANG=C");
	configured.display = (erx_dom_display_t){ .name = "screen", .name_len = 6,
	    .policy = ERX_MF_DISPLAY_POLICY_RIO, .idle_dim_s = 60, .idle_off_s = 4294967295u };
	status = erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan);
	printf("ctor configured_display %d ", (int)status);
	for (uint32_t at = 0; at < plan.spec.env_len; at++) {
		const char byte = plan.spec.strings[plan.spec.args_len + at];

		putchar(byte == '\0' ? '|' : byte);
	}
	printf("\n");
	configured.env = NULL;
	configured.env_len = 0;
	configured.display = (erx_dom_display_t){ .name = NULL };
	/* Everything but the name, id and pid is the template's. */
	status = erx_dom_plan_session(&view, 8, 0, "sess", 4,
	    (erx_dom_pid_t){ 3, 1 }, &plan);
	printf("ctor session_owned %d %u %u %u %u %u %u %u %.*s\n", (int)status,
	    plan.spec.origin.kind, plan.spec.origin.record, (unsigned)plan.parent,
	    plan.spec.flags, plan.spec.runtime_limits.atoms,
	    (unsigned)(plan.spec.memory / MIB), plan.spec.domain_pid.number,
	    (int)plan.spec.name_len, plan.spec.name);
	status = erx_dom_plan_partial(&view, 7, 0, &plan);
	printf("ctor partial_owned %d %u %u %u %.*s\n", (int)status,
	    plan.spec.origin.kind, plan.connection, plan.connection_row,
	    (int)plan.spec.name_len, plan.spec.name);
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
 * What a plan's record left in the view: the slot's record, the
 * principal's counts, the built or running configured records whose grant
 * is the configured row's, the next connection number and the plan's
 * connection row, or "-" for none.
 */
static void
print_record(const char *name, erx_status_t status, const erx_dom_plan_t *plan)
{
	const erx_dom_t *dom = &domains[plan->slot % NDOMAINS];
	const erx_dom_connection_t *row;
	unsigned services = 0;

	for (uint32_t index = 0; index < NDOMAINS; index++)
		services += domains[index].origin.kind == ERX_DOM_CONFIGURED &&
		    (domains[index].state == ERX_DOM_BUILT ||
		    domains[index].state == ERX_DOM_RUNNING) &&
		    memcmp(&domains[index].grant, &configured.grant,
		    sizeof(configured.grant)) == 0;
	printf("record %s %d id=%u state=%d labels=%u connection=%u "
	    "principal=%u,%llu services=%u next=%u", name, (int)status, dom->id,
	    (int)dom->state, dom->labels, dom->system_connection,
	    principal.domains, (unsigned long long)principal.carved,
	    services, view.next_connection);
	if (plan->connection_row >= NCONNECTIONS) {
		printf(" row=-\n");
		return;
	}
	row = &connections[plan->connection_row];
	printf(" row=%u,%u,%u\n", row->number, row->a, row->b);
}

/* A configured domain's plan, id 6, against a reset view. */
static erx_dom_plan_t
configured_plan(void)
{
	erx_dom_plan_t plan;

	reset_view();
	if (erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan) != ERX_OK)
		failures++;
	return (plan);
}

/*
 * A restart of a configured domain whose grant takes two of system's
 * three CPUs of headroom: while the first domain lives a second plan of
 * its row is past the reserve, and once it has ended, or ended and been
 * retired, the restart fits, since only a living record's grant counts.
 * Two plans made against the same view each fit it alone; once the first
 * is recorded, the second no longer leaves the reserve.
 */
static void
restarts(void)
{
	erx_dom_teardown_t teardown;
	erx_dom_plan_t plan, again;
	erx_dom_t *dom;
	erx_status_t retired;

	reset_view();
	configured.grant = grant(ERX_QUOTA_NONE, 0x3, 50);
	if (erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan) != ERX_OK ||
	    erx_dom_plan_record(&view, &plan) != ERX_OK) {
		failures++;
		return;
	}
	dom = &domains[plan.slot];
	printf("record restart_living %d\n",
	    (int)erx_dom_plan_configured(&view, 7, 0, ERX_DOM_PID_NONE, &again));
	dom->state = ERX_DOM_RUNNING;
	printf("record restart_running %d\n",
	    (int)erx_dom_plan_configured(&view, 7, 0, ERX_DOM_PID_NONE, &again));
	dom->state = ERX_DOM_ENDED;
	printf("record restart_ended %d\n",
	    (int)erx_dom_plan_configured(&view, 7, 0, ERX_DOM_PID_NONE, &again));
	/* The system connection closed, as erx_dom_disconnect leaves it. */
	connections[plan.connection_row] = (erx_dom_connection_t){ 0 };
	if (erx_dom_plan_retire(&view, 6, &teardown) != ERX_OK) {
		failures++;
		return;
	}
	erx_dom_retire_record(&view, &teardown);
	printf("record restart_retired %d id=%u principal=%u,%llu\n",
	    (int)erx_dom_plan_configured(&view, 7, 0, ERX_DOM_PID_NONE, &again), dom->id,
	    principal.domains, (unsigned long long)principal.carved);

	/*
	 * A principal with room for one domain, whose configured domain ends
	 * while a survivor, domain 9, still holds their connection: the retire
	 * releases the domain at once and keeps only its outer budget, so the
	 * restart fits while the remains stay carved from the principal.
	 */
	reset_view();
	principal.domains_max = 1;
	if (erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan) != ERX_OK ||
	    erx_dom_plan_record(&view, &plan) != ERX_OK) {
		failures++;
		return;
	}
	domains[plan.slot].state = ERX_DOM_ENDED;
	connections[plan.connection_row] = (erx_dom_connection_t){ 0 };
	connections[NCONNECTIONS - 1] = (erx_dom_connection_t){ .number = 50,
	    .a = 6, .b = 9, .closing = true };
	retired = erx_dom_plan_retire(&view, 6, &teardown);
	printf("record restart_held_retire %d\n", (int)retired);
	if (retired == ERX_OK)
		erx_dom_retire_record(&view, &teardown);
	printf("record restart_held %d principal=%u,%llu\n",
	    (int)erx_dom_plan_configured(&view, 7, 0, ERX_DOM_PID_NONE, &again),
	    principal.domains, (unsigned long long)principal.carved);
	/* The connection rows still name 6, so no new domain takes the id. */
	printf("record restart_held_same_id %d\n",
	    (int)erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &again));

	reset_view();
	configured.grant = grant(ERX_QUOTA_NONE, 0x3, 50);
	if (erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan) != ERX_OK ||
	    erx_dom_plan_configured(&view, 7, 0, ERX_DOM_PID_NONE, &again) != ERX_OK ||
	    erx_dom_plan_record(&view, &plan) != ERX_OK) {
		failures++;
		return;
	}
	/* Only the reserve stands between the second plan and its record. */
	again.slot = plan.slot + 1;
	again.connection_row = plan.connection_row + 1;
	again.connection = view.next_connection;
	printf("record restart_stale %d\n", (int)erx_dom_plan_record(&view, &again));
	configured.grant = grant(UINT64_C(5000000), 0x3, 50);
	again.spec.grant = configured.grant;
	printf("record restart_stale_fits %d\n", (int)erx_dom_plan_record(&view, &again));
}

/*
 * erx_dom_plan_record: each recorded plan is what the next plan sees, a
 * configured domain's record keeps its grant and its system
 * connection takes the next number, a partial-boot domain takes neither,
 * and a plan that no longer fits the view leaves it as it was.
 */
static int
records(void)
{
	erx_dom_spec_t req = base_request();
	erx_dom_plan_t plan, spent;

	plan = configured_plan();
	print_record("configured", erx_dom_plan_record(&view, &plan), &plan);
	if (erx_dom_plan_configured(&view, 7, 0, ERX_DOM_PID_NONE, &plan) != ERX_OK)
		failures++;
	print_record("configured_again", erx_dom_plan_record(&view, &plan),
	    &plan);
	if (erx_dom_plan_partial(&view, 8, 0, &plan) != ERX_OK)
		failures++;
	print_record("partial", erx_dom_plan_record(&view, &plan), &plan);
	req.id = 9;
	printf("record quota_spent %d\n",
	    (int)erx_dom_plan_request(&view, &req, NULL, 0, &spent));

	plan = configured_plan();
	(void)erx_dom_plan_record(&view, &plan);
	print_record("twice", erx_dom_plan_record(&view, &plan), &plan);
	plan = configured_plan();
	domains[plan.slot].id = 9;
	print_record("slot_taken", erx_dom_plan_record(&view, &plan), &plan);
	plan = configured_plan();
	view.next_connection = 2;
	print_record("not_next", erx_dom_plan_record(&view, &plan), &plan);
	plan = configured_plan();
	plan.spec.principal = 9;
	print_record("unknown_principal", erx_dom_plan_record(&view, &plan),
	    &plan);
	plan = configured_plan();
	principal.carved = UINT64_MAX;
	print_record("carve_overflow", erx_dom_plan_record(&view, &plan), &plan);
	restarts();
	return (failures == 0 ? 0 : 1);
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

/*
 * A configured row's gives (docs/design-system.md, "Devices"): a catalogue
 * of device 0, an unconfined transport of unit 0 placed on configured row
 * 0, and device 1, of unit 1, the system domain's, each on a line of its
 * own. gives_shared_view adds device 2, of unit 0, on a page of its own
 * and on device 0's line. Each line names a case and its result.
 */
static erx_dom_device_entry_t give_devices[3];
static erx_dom_device_t give_records[3];

static void
gives_view(void)
{
	reset_view();
	memset(give_records, 0, sizeof(give_records));
	give_devices[0] = (erx_dom_device_entry_t){ .unit = 0, .row = 0, .nranges = 1, .nlines = 1,
	    .ranges = { { 0x0a003000, 0x1000 } }, .lines = { 48 }, .memory = 0x100000,
	    .role_word = "block", .peripheral = "virtio_mmio" };
	give_devices[1] = (erx_dom_device_entry_t){ .unit = 1, .row = ERX_MF_NONE, .nranges = 1, .nlines = 1,
	    .ranges = { { 0x09000000, 0x1000 } }, .lines = { 33 }, .role_word = "uart", .peripheral = "pl011" };
	give_records[1].index = 1;
	view.devices = give_devices;
	view.device_records = give_records;
	view.ndevices = 2;
}

static void
gives_shared_view(void)
{
	gives_view();
	give_devices[2] = (erx_dom_device_entry_t){ .unit = 0, .row = 0, .nranges = 1, .nlines = 1,
	    .ranges = { { 0x0a004000, 0x1000 } }, .lines = { 48 },
	    .role_word = "block", .peripheral = "virtio_mmio" };
	give_records[2].index = 2;
	view.ndevices = 3;
}

/* How many IRQ objects a give makes. */
static uint32_t
irq_steps(const erx_dom_unit_plan_t *give)
{
	uint32_t count = 0;

	for (uint32_t step = 0; step < give->nsteps; step++)
		count += give->steps[step].kind == ERX_DOM_STEP_IRQ ? 1 : 0;
	return (count);
}

/* Adds give as plan's second give, its GIVE step right after the first's. */
static void
second_give(erx_dom_plan_t *plan, const erx_dom_unit_plan_t *give)
{
	uint32_t at = 0;

	while (at < plan->nsteps && plan->steps[at].kind != ERX_DOM_STEP_GIVE)
		at++;
	memmove(&plan->steps[at + 2], &plan->steps[at + 1], (plan->nsteps - at - 1) * sizeof(plan->steps[0]));
	plan->steps[at + 1] = (erx_dom_step_t){ .kind = ERX_DOM_STEP_GIVE, .index = 1 };
	plan->nsteps++;
	plan->gives[1] = *give;
	plan->ngives = 2;
}

/* The index of the step of kind in plan, or nsteps for none. */
static uint32_t
step_of(const erx_dom_plan_t *plan, erx_dom_step_kind_t kind)
{
	uint32_t index = 0;

	while (index < plan->nsteps && plan->steps[index].kind != kind)
		index++;
	return (index);
}

static int
gives(void)
{
	static erx_dom_plan_t plan, seeded;
	erx_status_t status;
	uint32_t give, boot;

	gives_view();
	status = erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan);
	give = step_of(&plan, ERX_DOM_STEP_GIVE);
	boot = step_of(&plan, ERX_DOM_STEP_BOOTINFO);
	printf("gives first %d ngives=%u index=%u before_boot=%d holder=%d last=%s\n", (int)status, plan.ngives,
	    plan.gives[0].devices[0].index, give + 1 == boot, plan.gives[0].holder == 6 && plan.gives[0].slot == plan.slot,
	    obj_names[plan.gives[0].steps[plan.gives[0].nsteps - 1].obj]);

#define SEED(name, edit) do {						\
	seeded = plan;							\
	edit;								\
	printf("gives seeded %s %d\n", name, (int)erx_dom_plan_check(&seeded));	\
} while (0)
	SEED("valid", (void)0);
	SEED("after_boot", { seeded.steps[give] = plan.steps[boot]; seeded.steps[boot] = plan.steps[give]; });
	SEED("unplanned", seeded.ngives = 2);
	SEED("no_step", seeded.steps[give] = plan.steps[give - 1]);
	SEED("other_holder", seeded.gives[0].holder = 7);
	SEED("other_slot", seeded.gives[0].slot = plan.slot + 1);
	SEED("window_phys", seeded.gives[0].steps[4].rights |= ERX_HR_PHYS);
	printf("gives direct shared=%d line=%u\n", plan.gives[0].devices[0].shared, plan.gives[0].devices[0].line);

	/*
	 * Devices 0 and 2, of unit 0, share a line: the unit's one give makes
	 * its one IRQ object, which both records name, and marks it shared in
	 * both, and makes a window for each device's page.
	 */
	gives_shared_view();
	status = erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan);
	printf("gives shared %d ngives=%u devices=%u irqs=%u lines=%u,%u marks=%d,%d\n", (int)status, plan.ngives,
	    plan.gives[0].ndevices, irq_steps(&plan.gives[0]), plan.gives[0].devices[0].line,
	    plan.gives[0].devices[1].line, plan.gives[0].devices[0].shared, plan.gives[0].devices[1].shared);
	SEED("shared_valid", (void)0);
	/* A device in two gives of the creation, each of its own unit. */
	SEED("device_twice", {
		second_give(&seeded, &plan.gives[0]);
		seeded.gives[1].unit = 1;
	});
	/* A unit in two gives, each of devices of its own. */
	SEED("unit_twice", {
		second_give(&seeded, &plan.gives[0]);
		seeded.gives[1].devices[0].index = seeded.gives[1].steps[0].index = 1;
		seeded.gives[1].devices[1].index = seeded.gives[1].steps[1].index = 3;
	});
	SEED("units_apart", {
		second_give(&seeded, &plan.gives[0]);
		seeded.gives[1].unit = 1;
		seeded.gives[1].devices[0].index = seeded.gives[1].steps[0].index = 1;
		seeded.gives[1].devices[1].index = seeded.gives[1].steps[1].index = 3;
	});
#undef SEED

	/* A living domain of the row holds the device: the next creation of it is refused. */
	gives_view();
	domains[NDOMAINS - 1] = (erx_dom_t){ .id = 9, .state = ERX_DOM_RUNNING,
	    .origin = { ERX_DOM_CONFIGURED, 0 }, .grant = configured.grant };
	give_records[0] = (erx_dom_device_t){ .index = 0, .holder = 9, .memory = { 77 } };
	status = erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan);
	printf("gives busy %d nsteps=%u\n", (int)status, plan.nsteps);
	/* Once it has ended, its restart is given the device again over the kept memory. */
	domains[NDOMAINS - 1].state = ERX_DOM_ENDED;
	status = erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan);
	printf("gives again %d ngives=%u last=%s\n", (int)status, plan.ngives,
	    obj_names[plan.gives[0].steps[plan.gives[0].nsteps - 1].obj]);
	return (failures == 0 ? 0 : 1);
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
	if (argc == 2 && strcmp(argv[1], "record") == 0)
		return (records());
	if (argc == 2 && strcmp(argv[1], "gives") == 0)
		return (gives());
	fprintf(stderr,
	    "usage: dom_core_driver explore|cases|seeded|principal|record|gives\n");
	return (2);
}
