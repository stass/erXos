/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the domain library's pure core (liberx/system/dom_core.c),
 * judged by test/host/dom_core_test.rb. Nine modes:
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
 * gives    gives devices to domains and prints each give's status.
 * apps     plans app sessions against the apps budget.
 * pci      takes PCIe reports into a bridge's catalogue.
 * firmware resolves firmware request rows against the allow-list.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "erx/abi_reader.h"
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
	"CONTIGUOUS", "MSI", "GIVE"
};

static erx_grant_t
grant(uint64_t quota, uint64_t cpuset, uint8_t ceiling)
{
	erx_grant_t g;

	memset(&g, 0, sizeof(g));
	g.quota_ns = quota;
	g.period_ns = quota == ERX_QUOTA_NONE ? 0 : UINT64_C(10000000);
	g.cpuset = cpuset;
	g.slice_us = 1000;
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
	    .band = ERX_BAND_DRIVER, .name = "srv", .name_len = 3 };
	/* Atoms the principal's default is not, so a plan shows the template's. */
	session_template = (erx_dom_template_t){ .principal = 1, .band = ERX_BAND_INTERACTIVE,
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
	    .native_band = ERX_BAND_INTERACTIVE,
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
	case ERX_DOM_STEP_MSI:
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
		    req.name_len, NULL, 0, ERX_DOM_PID_NONE, &plan);
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
MUTATION(m_id_system, s->id = ERX_SYSTEM_DOMAIN_ID)
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
MUTATION(m_grant_slice_zero, s->grant.slice_us = 0)
MUTATION(m_grant_slice_low, s->grant.slice_us = ERX_SLICE_MIN_US - 1)
MUTATION(m_grant_slice_high, s->grant.slice_us = ERX_SLICE_MAX_US + 1)
MUTATION(m_grant_slice_min, s->grant.slice_us = ERX_SLICE_MIN_US)
MUTATION(m_spaces_slice_max, (s->flags |= ERX_DOM_SPACES, s->spaces = grant(UINT64_C(5000000), 0x1, 1),
    s->spaces.slice_us = ERX_SLICE_MAX_US))
MUTATION(m_spaces_slice, (s->flags |= ERX_DOM_SPACES, s->spaces = grant(UINT64_C(5000000), 0x1, 1),
    s->spaces.slice_us = 0))
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
	run_case("grant_slice_zero", PICK_REQUEST, m_grant_slice_zero);
	run_case("grant_slice_low", PICK_REQUEST, m_grant_slice_low);
	run_case("grant_slice_high", PICK_REQUEST, m_grant_slice_high);
	run_case("grant_slice_min", PICK_REQUEST, m_grant_slice_min);
	run_case("spaces_slice_max", PICK_REQUEST, m_spaces_slice_max);
	run_case("spaces_slice", PICK_REQUEST, m_spaces_slice);
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
	printf("ctor boot_flags request %u %u\n",
	    erx_dom_plan_boot_flags(&view, &plan, false),
	    erx_dom_plan_boot_flags(&view, &plan, true));
	printf("ctor configured_row_out %d\n",
	    (int)erx_dom_plan_configured(&view, 6, 1, ERX_DOM_PID_NONE, &plan));
	printf("ctor partial_row_out %d\n",
	    (int)erx_dom_plan_partial(&view, 6, 1, &plan));
	status = erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan);
	printf("ctor configured_owned %d %u %u %u %.*s\n", (int)status,
	    plan.spec.origin.kind, plan.spec.origin.record, (unsigned)plan.parent,
	    (int)plan.spec.name_len, plan.spec.name);
	printf("ctor boot_flags configured %u %u\n",
	    erx_dom_plan_boot_flags(&view, &plan, false),
	    erx_dom_plan_boot_flags(&view, &plan, true));
	/* A display domain's environment is its row's words, then its display's. */
	configured.env = "LANG=C";
	configured.env_len = sizeof("LANG=C");
	configured.display = (erx_dom_display_t){ .name = "screen", .name_len = 6,
	    .policy = ERX_MF_DISPLAY_POLICY_SINGLE, .idle_dim_s = 60, .idle_off_s = 4294967295u,
	    .palette = ERX_MF_DISPLAY_PALETTE_DARK };
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
	status = erx_dom_plan_session(&view, 8, 0, "sess", 4, NULL, 0,
	    (erx_dom_pid_t){ 3, 1 }, &plan);
	printf("ctor session_owned %d %u %u %u %u %u %u %u %.*s %u\n", (int)status,
	    plan.spec.origin.kind, plan.spec.origin.record, (unsigned)plan.parent,
	    plan.spec.flags, plan.spec.runtime_limits.atoms,
	    (unsigned)(plan.spec.memory / MIB), plan.spec.domain_pid.number,
	    (int)plan.spec.name_len, plan.spec.name, plan.spec.env_len);
	printf("ctor boot_flags session %u %u\n",
	    erx_dom_plan_boot_flags(&view, &plan, false),
	    erx_dom_plan_boot_flags(&view, &plan, true));
	/*
	 * A session's principal, then its default display, are words after the
	 * template's environment; a display name with a NUL or longer than a
	 * name is refused.
	 */
	session_template.env = "LANG=C";
	session_template.env_len = sizeof("LANG=C");
	status = erx_dom_plan_session(&view, 8, 0, "sess", 4, "screen", 6,
	    (erx_dom_pid_t){ 3, 1 }, &plan);
	printf("ctor session_display %d ", (int)status);
	for (uint32_t at = 0; at < plan.spec.env_len; at++) {
		const char byte = plan.spec.strings[plan.spec.args_len + at];

		putchar(byte == '\0' ? '|' : byte);
	}
	printf("\n");
	printf("ctor session_display_refused %d %d\n",
	    (int)erx_dom_plan_session(&view, 8, 0, "sess", 4, "a\0b", 3, (erx_dom_pid_t){ 3, 1 }, &plan),
	    (int)erx_dom_plan_session(&view, 8, 0, "sess", 4, "screen", ERX_DOM_NAME_MAX + 1,
	    (erx_dom_pid_t){ 3, 1 }, &plan));
	session_template.env = NULL;
	session_template.env_len = 0;
	status = erx_dom_plan_partial(&view, 7, 0, &plan);
	printf("ctor partial_owned %d %u %u %u %.*s\n", (int)status,
	    plan.spec.origin.kind, plan.connection, plan.connection_row,
	    (int)plan.spec.name_len, plan.spec.name);
	printf("ctor boot_flags partial %u %u\n",
	    erx_dom_plan_boot_flags(&view, &plan, false),
	    erx_dom_plan_boot_flags(&view, &plan, true));
	/* Each origin's bands, its own and its sub-spaces', from what the constructor reads. */
	printf("ctor bands partial=%u,%u", plan.spec.band, plan.spec.space_band);
	req = base_request();
	req.band = ERX_BAND_DRIVER;
	req.space_band = ERX_BAND_DRIVER;
	status = erx_dom_plan_request(&view, &req, NULL, 0, &plan);
	printf(" request=%d,%u,%u", (int)status, plan.spec.band, plan.spec.space_band);
	status = erx_dom_plan_configured(&view, 6, 0, ERX_DOM_PID_NONE, &plan);
	printf(" configured=%d,%u,%u", (int)status, plan.spec.band, plan.spec.space_band);
	status = erx_dom_plan_session(&view, 8, 0, "sess", 4, NULL, 0, (erx_dom_pid_t){ 3, 1 }, &plan);
	printf(" session=%d,%u,%u\n", (int)status, plan.spec.band, plan.spec.space_band);
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
 * App entries and app sessions (docs/design-packaging.md, "An app's
 * principal" and "An app's session"): the view of reset_view with a second
 * template, the app template, which names no principal, and room for
 * APP_ENTRIES app entries after principal 1 under an apps budget of
 * APPS_MIB. Each line names a case and its result.
 */
#define APP_ENTRIES	3
#define APPS_MIB	16

static erx_dom_principal_t app_principals[1 + APP_ENTRIES];
static erx_dom_template_t app_templates[2];

static void
reset_apps(void)
{
	reset_view();
	app_principals[0] = principal;
	app_templates[0] = session_template;
	app_templates[1] = session_template;
	app_templates[1].principal = 0;
	view.principals = app_principals;
	view.templates = app_templates;
	view.ntemplates = 2;
}

/* Plans entry's session with mib MiB under id and records it. */
static erx_status_t
app_session(uint32_t id, uint32_t entry, uint64_t mib, erx_dom_plan_t *plan)
{
	erx_status_t status;

	status = erx_dom_plan_app_session(&view, id, entry, mib * MIB, "app_1", 5, NULL, 0,
	    (erx_dom_pid_t){ id, 1 }, plan);
	return (status == ERX_OK ? erx_dom_plan_record(&view, plan) : status);
}

/*
 * PCIe reports (erx_dom_pci_report): a bridge of the Pi 4's shape, whose one
 * memory window moves PCI 0xc0000000 to CPU 0x600000000 (docs/design-usb.md,
 * "The Raspberry Pi 4"), and one device-tree entry inside that CPU range. Each
 * case prints the report's status and refused field, and whether the
 * function at bus 1, device 0 is givable after it.
 */
#define PCI_BRIDGE	3u
#define PCI_WINDOW_PCI	UINT64_C(0xc0000000)
#define PCI_WINDOW_CPU	UINT64_C(0x600000000)
#define PCI_ENTRY_CPU	(PCI_WINDOW_CPU + 0x100000)

static erx_dom_pci_bridge_t pci_bridge;
static erx_dom_device_entry_t pci_entries[1];

static void
pci_fresh(void)
{
	pci_bridge = (erx_dom_pci_bridge_t){ .facts = { .index = PCI_BRIDGE, .bus_first = 0, .bus_last = 1,
	    .windows = { { .pci = PCI_WINDOW_PCI, .cpu = PCI_WINDOW_CPU, .size = 0x40000000 } } } };
	pci_entries[0] = (erx_dom_device_entry_t){ .nranges = 1, .ranges = { { .base = PCI_ENTRY_CPU, .size = 0x1000 } } };
}

/* The VL805 at 1.0.0, ready, its one 64-bit BAR of 4 KiB at PCI address at. */
static erx_pcie_function_t
pci_function(uint8_t device, uint64_t at)
{
	return ((erx_pcie_function_t){ .bridge = PCI_BRIDGE, .bus = 1, .device = device, .state = ERX_PCIE_STATE_READY,
	    .vendor = 0x1106, .device_id = 0x3483, .class_code = 0x0c0330, .pin = 1,
	    .bars = { { .kind = ERX_PCIE_BAR_MEMORY, .flags = ERX_PCIE_BAR_ADDR64 | ERX_PCIE_BAR_PLACED, .size_log2 = 12,
	    .address = at } } });
}

/* A report's records as their sender hands them, read whole by the intake (erx_dom_pci_report). */
static void
pci_raw_case(const char *name, const erx_dom_pci_record_t *records, uint32_t count)
{
	erx_dom_pci_refusal_t refusal = { .record = 0, .field = "none" };
	const erx_status_t status = erx_dom_pci_report(&pci_bridge, pci_entries, 1, records, count, &refusal);

	printf("pci %s %d %u %s givable=%d\n", name, (int)status, refusal.record, refusal.field,
	    erx_dom_pci_givable(&pci_bridge, 1, 0, 0) != NULL ? 1 : 0);
}

static void
pci_case(const char *name, const erx_pcie_function_t *report, uint32_t count)
{
	erx_dom_pci_refusal_t refusal = { .field = "none" };
	uint8_t bytes[ERX_PCIE_FUNCTIONS_MAX][ERX_PCIE_FUNCTION_SIZE];
	erx_dom_pci_record_t records[ERX_PCIE_FUNCTIONS_MAX];
	erx_status_t status;

	for (uint32_t at = 0; at < count; at++) {
		(void)erx_pcie_function_encode(&report[at], bytes[at], sizeof(bytes[at]));
		records[at] = (erx_dom_pci_record_t){ bytes[at], sizeof(bytes[at]) };
	}
	status = erx_dom_pci_report(&pci_bridge, pci_entries, 1, records, count, &refusal);
	printf("pci %s %d %s givable=%d\n", name, (int)status, refusal.field,
	    erx_dom_pci_givable(&pci_bridge, 1, 0, 0) != NULL ? 1 : 0);
}

static int
pcis(void)
{
	erx_pcie_function_t report[2];
	erx_dom_range_t cpu = { 0, 0 };

	pci_fresh();
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	pci_case("placed", report, 1);
	printf("pci cpu %d 0x%llx+0x%llx\n", erx_dom_pci_bar_cpu(&pci_bridge.facts, &report[0].bars[0], &cpu) ? 1 : 0,
	    (unsigned long long)cpu.base, (unsigned long long)cpu.size);
	/*
	 * The give reads the latest report alone (docs/design-system.md, "The rows held at
	 * boot"): a function it confirmed ready is givable though no report was answered,
	 * and one it did not list is not.
	 */
	printf("pci unanswered answered=%u givable=%d unlisted=%d\n", pci_bridge.answered,
	    erx_dom_pci_givable(&pci_bridge, 1, 0, 0) != NULL ? 1 : 0, erx_dom_pci_givable(&pci_bridge, 1, 1, 0) != NULL ? 1 : 0);
	/* A later report confirms the layout it repeats and no other. */
	pci_case("same", report, 1);
	report[0].revision = 1;
	pci_case("changed", report, 1);
	pci_case("missing", report, 0);
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[0].state = ERX_PCIE_STATE_NOT_READY;
	pci_case("not_ready", report, 1);
	pci_fresh();
	pci_bridge.firmware_lost = true;
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	pci_case("firmware_lost", report, 1);
	/* The mark set after a confirming report gives nothing all the same. */
	pci_fresh();
	pci_case("before_mark", report, 1);
	pci_bridge.firmware_lost = true;
	printf("pci marked givable=%d\n", erx_dom_pci_givable(&pci_bridge, 1, 0, 0) != NULL ? 1 : 0);
	/* A refused later report leaves no earlier confirmation; an empty first report lays nothing. */
	pci_fresh();
	pci_case("laid", report, 1);
	report[1] = report[0];
	pci_case("refused_later", report, 2);
	/*
	 * A record that is not one record's bytes, and a report past the bound,
	 * whose records the intake does not read, are refused whole as well.
	 */
	pci_fresh();
	pci_case("read", report, 1);
	{
		uint8_t bytes[ERX_PCIE_FUNCTION_SIZE];
		erx_dom_pci_record_t unread[2];

		(void)erx_pcie_function_encode(&report[0], bytes, sizeof(bytes));
		unread[0] = (erx_dom_pci_record_t){ bytes, sizeof(bytes) };
		unread[1] = (erx_dom_pci_record_t){ bytes, sizeof(bytes) - 1 };
		pci_raw_case("unread", unread, 2);
		pci_case("reread", report, 1);
		unread[1] = (erx_dom_pci_record_t){ NULL, 0 };
		pci_raw_case("no_bytes", unread, 2);
		pci_case("reread", report, 1);
		pci_raw_case("too_many", NULL, ERX_PCIE_FUNCTIONS_MAX + 1);
	}
	pci_fresh();
	pci_case("empty", report, 0);
	pci_case("after_empty", report, 1);

	/* Placement refusals: each leaves the bridge to place again. */
	const struct { const char *name; uint64_t at; } outside[] = {
		{ "below", PCI_WINDOW_PCI - 0x1000 },
		{ "past_end", PCI_WINDOW_PCI + 0x40000000 },
		{ "unaligned", PCI_WINDOW_PCI + 0x800 },
		{ "entry", PCI_WINDOW_PCI + (PCI_ENTRY_CPU - PCI_WINDOW_CPU) },
	};
	for (size_t at = 0; at < sizeof(outside) / sizeof(outside[0]); at++) {
		pci_fresh();
		report[0] = pci_function(0, outside[at].at);
		pci_case(outside[at].name, report, 1);
	}
	pci_fresh();
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[1] = pci_function(1, PCI_WINDOW_PCI);
	pci_case("overlap", report, 2);
	pci_fresh();
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[0].msix_offset = 0x90;
	report[0].msix_table_size = 2;
	report[0].msix_table_offset = 0x1000 - 0x10;
	pci_case("msix_past", report, 1);
	report[0].msix_table_offset = 0x1000 - 0x20;
	pci_case("msix_inside", report, 1);
	pci_fresh();
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[0].bars[1] = report[0].bars[0];
	pci_case("upper_half", report, 1);
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[0].bridge = PCI_BRIDGE + 1;
	pci_case("other_bridge", report, 1);
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[0].bus = 2;
	pci_case("bus", report, 1);
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[1] = report[0];
	pci_case("twice", report, 2);
	report[0].state = 0;
	pci_case("state", report, 1);
	/* A placing report refused whole leaves the next to place. */
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	pci_case("after_refusals", report, 1);

	/* A BAR too large to place is reported at its true size on an unplaced function (abi/formats/pcie.txt). */
	const erx_pcie_bar_t huge = { .kind = ERX_PCIE_BAR_MEMORY, .flags = ERX_PCIE_BAR_ADDR64, .size_log2 = 40 };
	pci_fresh();
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[0].state = ERX_PCIE_STATE_UNPLACED;
	report[0].bars[2] = huge;
	pci_case("unplaced_huge", report, 1);
	report[0].bars[2] = huge;
	report[0].bars[2].size_log2 = 64;
	pci_case("size_64", report, 1);
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[0].bars[0].kind = ERX_PCIE_BAR_IO;
	report[0].bars[0].flags = ERX_PCIE_BAR_PLACED;
	pci_case("io_placed", report, 1);
	/* A ready function has every memory BAR placed. */
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[0].bars[0].flags = ERX_PCIE_BAR_ADDR64;
	report[0].bars[0].address = 0;
	pci_case("ready_unplaced", report, 1);
	/* A window of 4 GiB holds a placed BAR's span clamped to the placing bound, so only the bound refuses one of 8 GiB. */
	pci_fresh();
	pci_bridge.facts.windows[0].size = UINT64_C(0x100000000);
	report[0] = pci_function(0, UINT64_C(0x100000000));
	report[0].bars[0].size_log2 = 33;
	pci_case("placed_huge", report, 1);
	/* A window reaching past 4 GiB holds a 64-bit BAR there and no 32-bit one. */
	pci_fresh();
	pci_bridge.facts.windows[0].size = 0x80000000;
	report[0] = pci_function(0, UINT64_C(0x100000000));
	report[0].bars[0].flags = ERX_PCIE_BAR_PLACED;
	pci_case("narrow_above_4g", report, 1);
	report[0] = pci_function(0, UINT64_C(0x100000000));
	pci_case("wide_above_4g", report, 1);
	pci_fresh();
	report[0] = pci_function(ERX_PCIE_DEVICE_MAX + 1, PCI_WINDOW_PCI);
	pci_case("device_bound", report, 1);
	report[0] = pci_function(0, PCI_WINDOW_PCI);
	report[0].function = ERX_PCIE_FUNCTION_MAX + 1;
	pci_case("function_bound", report, 1);

	/* Only a timed-out notification loses the bridge's firmware, and nothing finds it again. */
	pci_fresh();
	erx_dom_pci_firmware(&pci_bridge, ERX_EBUSY);
	printf("pci firmware busy lost=%d\n", pci_bridge.firmware_lost ? 1 : 0);
	erx_dom_pci_firmware(&pci_bridge, ERX_ETIMEDOUT);
	printf("pci firmware timedout lost=%d\n", pci_bridge.firmware_lost ? 1 : 0);
	erx_dom_pci_firmware(&pci_bridge, ERX_OK);
	printf("pci firmware ok lost=%d\n", pci_bridge.firmware_lost ? 1 : 0);
	return (0);
}

/*
 * The firmware requests' allow-list (erx_dom_bridge_row, erx_dom_power_row) over a
 * view built here, so each of its three checks has a case only it refuses: a
 * device's power line, a bridge's catalogue, and a row's tag. Devices: 0 a bridge
 * with its notification; 1 a bridge whose first row is a power row; 2 a power line
 * whose second row is a notification; 3 a device with no line whose row is a power
 * row; 4 a device with no catalogue whose row is a notification. Each case prints
 * "firmware NAME STATUS", and an answered one its row's tag and first argument.
 */
static void
firmware_case(const char *name, erx_status_t status, const erx_mf_firmware_request_t *row)
{
	if (status == ERX_OK)
		printf("firmware %s 0 tag=0x%x argument=0x%x\n", name, (unsigned)row->tag,
		    (unsigned)row->arguments[0]);
	else
		printf("firmware %s %d\n", name, (int)status);
}

static int
firmwares(void)
{
	static const erx_dom_device_entry_t entries[5] = { [2] = { .power_line = true } };
	static const erx_dom_pci_bridge_t bridges[2] = { { .facts = { .index = 0 } }, { .facts = { .index = 1 } } };
	static const erx_mf_firmware_request_t rows[] = {
		{ .device = 0, .tag = ERX_FW_TAG_NOTIFY_XHCI_RESET, .arguments = { 0x100000 } },
		{ .device = 1, .tag = ERX_FW_TAG_SET_GPIO_STATE, .arguments = { 0x80 } },
		{ .device = 2, .tag = ERX_FW_TAG_SET_GPIO_STATE, .arguments = { 0x80 } },
		{ .device = 2, .tag = ERX_FW_TAG_NOTIFY_XHCI_RESET, .arguments = { 0x100000 } },
		{ .device = 3, .tag = ERX_FW_TAG_SET_GPIO_STATE, .arguments = { 0x80 } },
		{ .device = 4, .tag = ERX_FW_TAG_NOTIFY_XHCI_RESET, .arguments = { 0x100000 } },
	};
	const erx_dom_view_t fw = { .devices = entries, .ndevices = 5, .pci_bridges = bridges,
	    .npci_bridges = 2, .firmware = rows, .nfirmware = sizeof(rows) / sizeof(rows[0]) };
	erx_mf_firmware_request_t row;

	firmware_case("bridge", erx_dom_bridge_row(&fw, 0, &row), &row);
	firmware_case("bridge_power_tag", erx_dom_bridge_row(&fw, 1, &row), &row);
	firmware_case("line", erx_dom_power_row(&fw, 2, 0, &row), &row);
	firmware_case("line_notify_tag", erx_dom_power_row(&fw, 2, 1, &row), &row);
	firmware_case("line_past_rows", erx_dom_power_row(&fw, 2, 2, &row), &row);
	firmware_case("no_line", erx_dom_power_row(&fw, 3, 0, &row), &row);
	firmware_case("no_catalogue", erx_dom_bridge_row(&fw, 4, &row), &row);
	firmware_case("outside", erx_dom_bridge_row(&fw, 5, &row), &row);
	firmware_case("outside_line", erx_dom_power_row(&fw, 5, 0, &row), &row);
	return (0);
}

static int
apps(void)
{
	static erx_dom_plan_t plan;
	const erx_dom_principal_t *entry;

	reset_apps();
	printf("apps place %d", (int)erx_dom_apps_place(&view, 1, APPS_MIB * MIB, APP_ENTRIES));
	entry = &view.principals[view.nprincipals - 1];
	printf(" first=%u max=%u principals=%u last=%u,%u,%u,%d\n", view.apps.first, view.apps.max,
	    view.nprincipals, entry->number, (unsigned)(entry->memory / MIB), entry->domains_max,
	    memcmp(&entry->share, &app_templates[1].grant, sizeof(entry->share)) == 0);
	printf("apps place_twice %d %u\n", (int)erx_dom_apps_place(&view, 1, APPS_MIB * MIB, 1),
	    view.nprincipals);
	reset_apps();
	printf("apps place_refused %d %d %d %d %d %d %u\n",
	    (int)erx_dom_apps_place(&view, 1, APPS_MIB * MIB, 0),
	    (int)erx_dom_apps_place(&view, 1, APPS_MIB * MIB, ERX_APPS_MAX_LIMIT + 1),
	    (int)erx_dom_apps_place(&view, 2, APPS_MIB * MIB, 1),
	    (int)erx_dom_apps_place(&view, 0, APPS_MIB * MIB, 1),
	    (int)erx_dom_apps_place(&view, 1, 0, 1),
	    (int)erx_dom_apps_place(&view, 1, APPS_MIB * MIB + 1, 1), view.nprincipals);
	/*
	 * An entry the check refuses leaves the view as it was: the second entry's
	 * number is the manifest principal's, renumbered here.
	 */
	app_principals[0].number = 3;
	printf("apps place_entry_refused %d %u %u\n", (int)erx_dom_apps_place(&view, 1, APPS_MIB * MIB, 2),
	    view.nprincipals, view.apps.max);

	reset_apps();
	(void)erx_dom_apps_place(&view, 1, APPS_MIB * MIB, APP_ENTRIES);
	printf("apps session %d", (int)erx_dom_plan_app_session(&view, 8, 2, 8 * MIB, "app_1", 5,
	    "screen", 6, (erx_dom_pid_t){ 3, 1 }, &plan));
	printf(" principal=%u memory=%u outer=%u origin=%u,%u band=%u,%u words=", plan.spec.principal,
	    (unsigned)(plan.spec.memory / MIB), (unsigned)(plan.spec.outer / MIB),
	    plan.spec.origin.kind, plan.spec.origin.record, plan.spec.band, plan.spec.space_band);
	for (uint32_t at = 0; at < plan.spec.env_len; at++) {
		const char byte = plan.spec.strings[plan.spec.args_len + at];

		putchar(byte == '\0' ? '|' : byte);
	}
	printf("\n");
	printf("apps session_refused %d %d %d %d\n",
	    (int)erx_dom_plan_session(&view, 8, 1, "app_1", 5, NULL, 0, (erx_dom_pid_t){ 3, 1 }, &plan),
	    (int)erx_dom_plan_app_session(&view, 8, APP_ENTRIES, 8 * MIB, "app_1", 5, NULL, 0,
	    (erx_dom_pid_t){ 3, 1 }, &plan),
	    (int)erx_dom_plan_app_session(&view, 8, 0, (APPS_MIB + 1) * MIB, "app_1", 5, NULL, 0,
	    (erx_dom_pid_t){ 3, 1 }, &plan),
	    (int)erx_dom_plan_app_session(&view, 8, 0, 8 * MIB, "app_1", 5, "a\0b", 3,
	    (erx_dom_pid_t){ 3, 1 }, &plan));
	/* One session per app; the apps budget bounds what every app's sessions carve together. */
	/* The last entry first, so the sum that counts every entry is seen to count it. */
	printf("apps budget %d", (int)app_session(8, APP_ENTRIES - 1, 8, &plan));
	printf(" second=%d", (int)app_session(9, APP_ENTRIES - 1, 4, &plan));
	printf(" over=%d", (int)app_session(9, 1, 8, &plan));
	printf(" fits=%d", (int)app_session(9, 1, 4, &plan));
	printf(" full=%d\n", (int)app_session(10, 0, 4, &plan));
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
	if (argc == 2 && strcmp(argv[1], "apps") == 0)
		return (apps());
	if (argc == 2 && strcmp(argv[1], "pci") == 0)
		return (pcis());
	if (argc == 2 && strcmp(argv[1], "firmware") == 0)
		return (firmwares());
	fprintf(stderr,
	    "usage: dom_core_driver explore|cases|seeded|principal|record|gives|apps|pci|firmware\n");
	return (2);
}
