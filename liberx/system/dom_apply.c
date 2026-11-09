/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The domain library's apply phase and end handling (include/erx/dom_lib.h):
 * the effects around the pure core of dom_core.c and dom_life.c. Each entry
 * asks the core for a plan or an action, then performs it over the function
 * API; nothing here decides what a domain gets.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/boot_info.h"
#include "liberx/system/dom_apply.h"
#include "liberx/system/dom_install.h"

/* A domain's node name: its name, '@', and the host. */
#define APPLY_NODE_MAX	(ERX_DOM_NAME_MAX + 1u + ERX_DOM_HOST_MAX)
/* The system domain's identifier, its node's name before '@'. */
#define SYSTEM_NAME	"system"
/* A handle no table holds: what a step gets for an object no creation names. */
#define APPLY_NO_HANDLE	UINT64_MAX

/* One creation in progress: the plan, the handles made so far, and what the steps learnt. */
typedef struct apply {
	erx_dom_lib_t		*lib;
	const erx_dom_plan_t	*plan;
	erx_dom_handles_t	 handles;
	uint64_t		 installed[ERX_DOM_OBJ_COUNT];	/* each install's value in
								 * the domain's table */
	uint64_t		 pc;		/* the runtime image's entry */
	uint64_t		 bootinfo_addr;	/* where the domain sees its boot page */
	uint64_t		 release_addr;	/* where it sees its release slice */
} apply_t;

/*
 * A run of made objects' handles with the budget each is charged to:
 * made[i] is object first + i. A creation's are its domain's
 * erx_dom_handles_t, a connection's its row's erx_dom_link_handles_t.
 */
typedef struct handle_set {
	uint64_t	*made;
	erx_dom_obj_t	*charge;
	erx_dom_obj_t	 first;
	uint32_t	 count;
} handle_set_t;

/* One connection in progress: the plan, the handles made so far, and each party's values. */
typedef struct link {
	erx_dom_lib_t			*lib;
	const erx_dom_link_plan_t	*plan;
	erx_dom_link_handles_t		 handles;
	erx_dom_linked_t		 linked;
} link_t;

static void	set_close_under(handle_set_t *, erx_dom_obj_t);
static erx_dom_obj_t set_find(const handle_set_t *, uint64_t);

static const erx_dom_principal_held_t *apply_principal(const apply_t *);
static uint64_t	apply_object(const apply_t *, erx_dom_obj_t);
static int	apply_step(apply_t *, const erx_dom_step_t *);
static int	apply_map(apply_t *, const erx_dom_step_t *);
static int	apply_install(apply_t *, const erx_dom_step_t *);
static bool	apply_node(const erx_dom_lib_t *, const char *, size_t, char *, size_t *);
static int	apply_bootinfo(apply_t *);
static int	apply_thread(apply_t *, const erx_dom_step_t *);
static int	apply_group(apply_t *, const erx_dom_step_t *);
static erx_status_t apply_plan(apply_t *, erx_dom_created_t *);
static void	apply_undo(apply_t *, uint32_t);
static void	apply_keep(apply_t *, erx_dom_created_t *);
static erx_status_t teardown_apply(erx_dom_lib_t *, const erx_dom_teardown_t *);
static void	lib_view_caps(erx_dom_lib_t *, uint32_t);
static uint32_t	lib_slot(const erx_dom_lib_t *, uint32_t);

/* Pages to hold bytes, rounded up; the plan bounds every size, so this never wraps. */
static uint64_t
pages_of(uint64_t bytes)
{
	return (bytes / ERX_PAGE_SIZE + (bytes % ERX_PAGE_SIZE != 0));
}

/*
 * The held handles of the plan's principal. The core planned against a view
 * whose principals are numbered 1 to nprincipals (erx_dom_boot_view), so the
 * number always names one; a number outside them names none of the held
 * handles, and the step that uses them is refused by the backend.
 */
static const erx_dom_principal_held_t *
apply_principal(const apply_t *apply)
{
	static const erx_dom_principal_held_t none = { APPLY_NO_HANDLE, APPLY_NO_HANDLE };
	const uint32_t number = apply->plan->spec.principal;

	if (number == 0 || number > apply->lib->view.nprincipals)
		return (&none);
	return (&apply->lib->held.principals[number - 1]);
}

/* The handle a step names: one the creation made, or one the library holds. */
static uint64_t
apply_object(const apply_t *apply, erx_dom_obj_t obj)
{
	const erx_dom_held_t *held = &apply->lib->held;

	if (obj < ERX_DOM_OBJ_MADE_COUNT)
		return (apply->handles.made[obj]);
	switch (obj) {
	case ERX_DOM_OBJ_PRINCIPAL_BUDGET:
		return (apply_principal(apply)->budget);
	case ERX_DOM_OBJ_PARENT_GROUP:
		/* The plan's resolved CPU parent; apply does not choose again. */
		return (apply->plan->parent == ERX_DOM_PARENT_SYSTEM ?
		    held->system_group : apply_principal(apply)->group);
	case ERX_DOM_OBJ_SYSTEM_SPACE:
		return (ERX_CAP_SELF);
	case ERX_DOM_OBJ_SYSTEM_GROUP:
		return (held->system_group);
	case ERX_DOM_OBJ_FAULT_GATE:
		return (held->gate);
	case ERX_DOM_OBJ_TIME_PAGE:
		return (held->time_page);
	default:
		/*
		 * A connection's or a device's: no creation names them. Not
		 * ERX_CAP_NULL, which a budget argument reads as the caller's own.
		 */
		return (APPLY_NO_HANDLE);
	}
}

static handle_set_t
set_of_domain(erx_dom_handles_t *handles)
{
	return ((handle_set_t){ handles->made, handles->charge, ERX_DOM_OBJ_NONE, ERX_DOM_OBJ_MADE_COUNT });
}

static handle_set_t
set_of_link(erx_dom_link_handles_t *handles)
{
	return ((handle_set_t){ handles->made, handles->charge, ERX_DOM_OBJ_LINK_BUDGET_A, ERX_DOM_LINK_OBJS });
}

static bool
set_holds(const handle_set_t *set, erx_dom_obj_t obj)
{
	return (obj >= set->first && (uint32_t)(obj - set->first) < set->count);
}

/* Notes a handle a step made, with its budget, before anything else can fail. */
static void
set_note(handle_set_t *set, const erx_dom_step_t *step, uint64_t handle)
{
	set->made[step->obj - set->first] = handle;
	set->charge[step->obj - set->first] = step->budget;
}

static void
apply_made(apply_t *apply, const erx_dom_step_t *step, uint64_t handle)
{
	handle_set_t set = set_of_domain(&apply->handles);

	set_note(&set, step, handle);
}

/*
 * The steps a creation and a connection share, each making one object of
 * the set: a wall budget (K32) under budget, or a memory object or a bell
 * charged to it. The library binds each bell itself, since BIND says where
 * its deliveries go; the bell is noted before the bind, so a refused bind
 * leaves it to the undo, which reaches it by its budget.
 */
static int
make_step(handle_set_t *set, const erx_dom_step_t *step, uint64_t budget, uint64_t target)
{
	uint64_t handle = ERX_CAP_NULL, pages;
	int status;

	if (!set_holds(set, step->obj))
		return (ERX_EINVAL);
	switch (step->kind) {
	case ERX_DOM_STEP_CARVE:
		pages = pages_of(step->size);
		status = erx_budget_create(budget, ERX_BUDGET_WALL, pages, pages, &handle);
		break;
	case ERX_DOM_STEP_MEM:
		status = erx_mem_create(budget, pages_of(step->size) * ERX_PAGE_SIZE, 0, &handle);
		break;
	case ERX_DOM_STEP_BELL:
		status = erx_irq_create(budget, ERX_CAP_NULL, ERX_IRQ_SOFT, 0, &handle);
		if (status != ERX_OK)
			return (status);
		set_note(set, step, handle);
		return (erx_irq_bind(handle, target, step->label));
	default:
		return (ERX_EINVAL);
	}
	if (status == ERX_OK)
		set_note(set, step, handle);
	return (status);
}

#ifdef ERX_DOM_TEST_HOOKS
/* The hooked failure (dom_lib.h) of step, before it is applied or once it has been. */
static erx_status_t
hook_step(const erx_dom_lib_t *lib, uint32_t step, bool after, erx_status_t status)
{
	return (step == lib->fail_step && after == lib->fail_made && status == ERX_OK ? ERX_ENOMEM : status);
}
#else
#define hook_step(lib, step, after, status)	(status)
#endif

/*
 * One step's call. A step that makes its object in one call breaks to the
 * common apply_made; a step that makes its object and then configures it
 * (GROUP, THREAD, and BELL in make_step) notes the handle itself between the
 * two calls and returns, so a failed second call still leaves the object to
 * the undo. The steps a connection shares are make_step's.
 */
static int
apply_step(apply_t *apply, const erx_dom_step_t *step)
{
	uint64_t budget = apply_object(apply, step->budget);
	uint64_t handle = ERX_CAP_NULL;
	handle_set_t set;
	int status;

	switch (step->kind) {
	case ERX_DOM_STEP_CARVE:
	case ERX_DOM_STEP_MEM:
	case ERX_DOM_STEP_BELL:
		set = set_of_domain(&apply->handles);
		return (make_step(&set, step, budget, apply_object(apply, step->target)));
	case ERX_DOM_STEP_SPACE:
		status = erx_space_create(budget, apply_object(apply, step->target),
		    apply_object(apply, step->aux), step->label, step->flags,
		    apply->lib->cap_limit, &handle);
		break;
	case ERX_DOM_STEP_GROUP:
		return (apply_group(apply, step));
	case ERX_DOM_STEP_SLICE:
		status = erx_image_slice(budget, apply->lib->held.image, step->index, step->count, &handle);
		break;
	case ERX_DOM_STEP_IMAGE_MAP:
		return (erx_image_map(apply_object(apply, step->target), apply->lib->held.image, step->index, &apply->pc));
	case ERX_DOM_STEP_MAP:
		return (apply_map(apply, step));
	case ERX_DOM_STEP_INSTALL:
		return (apply_install(apply, step));
	case ERX_DOM_STEP_BOOTINFO:
		return (apply_bootinfo(apply));
	case ERX_DOM_STEP_THREAD:
		return (apply_thread(apply, step));
	default:
		/* A device's steps belong to erx_dom_device_give, not to a creation. */
		return (ERX_EINVAL);
	}
	if (status == ERX_OK)
		apply_made(apply, step, handle);
	return (status);
}

/* A group with the specification's grant, which the stopgap checks and does not keep. */
static int
apply_group(apply_t *apply, const erx_dom_step_t *step)
{
	const erx_grant_t *grant = step->flags == ERX_DOM_GROUP_SPACES ?
	    &apply->plan->spec.spaces : &apply->plan->spec.grant;
	uint64_t words[sizeof(*grant) / sizeof(uint64_t)];
	uint64_t handle;
	int status;

	status = erx_group_create(apply_object(apply, step->budget),
	    apply_object(apply, step->target), &handle);
	if (status != ERX_OK)
		return (status);
	apply_made(apply, step, handle);
	memcpy(words, grant, sizeof(words));
	for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++)
		(void)erx_utcb_mr_store(erx_utcb_self(), word, words[word]);
	return (erx_group_configure(handle));
}

/*
 * A read-only mapping of the boot page or the release slice, of the size
 * the plan gives, at an address the domain's space chooses, which the boot
 * page then names.
 */
static int
apply_map(apply_t *apply, const erx_dom_step_t *step)
{
	const uint64_t space = apply_object(apply, step->target);
	uint64_t addr;
	int status;

	status = erx_vm_reserve(space, 0, step->size, 0, &addr);
	if (status != ERX_OK)
		return (status);
	status = erx_vm_map(space, addr, step->size, apply_object(apply, step->obj), 0, ERX_PROT_R);
	if (status != ERX_OK)
		return (status);
	if (step->obj == ERX_DOM_OBJ_SLICE)
		apply->release_addr = addr;
	else
		apply->bootinfo_addr = addr;
	return (ERX_OK);
}

/* A creation's install (A7), through the library's one funnel; the boot page names the value it takes. */
static int
apply_install(apply_t *apply, const erx_dom_step_t *step)
{
	return (erx_dom_install(step, apply_object(apply, step->obj), apply_object(apply, step->target),
	    &apply->installed[step->obj]));
}

/*
 * A node name into node (APPLY_NODE_MAX bytes): name, an identifier
 * (planning checked a domain's), '@', and the library's host. False for
 * a name longer than ERX_DOM_NAME_MAX or a host longer than
 * ERX_DOM_HOST_MAX, which the caller set.
 */
static bool
apply_node(const erx_dom_lib_t *lib, const char *name, size_t name_len, char *node, size_t *len)
{
	if (name_len > ERX_DOM_NAME_MAX || lib->host_len > ERX_DOM_HOST_MAX)
		return (false);
	memcpy(node, name, name_len);
	node[name_len] = '@';
	memcpy(node + name_len + 1, lib->host, lib->host_len);
	*len = name_len + 1 + lib->host_len;
	return (true);
}

/* Writes the boot page through a mapping of the root's own, released after. */
static int
apply_bootinfo(apply_t *apply)
{
	const erx_dom_plan_t *plan = apply->plan;
	const erx_dom_spec_t *spec = &plan->spec;
	const uint64_t page = apply->handles.made[ERX_DOM_OBJ_BOOTINFO];
	const erx_boot_words_t args = { spec->strings, spec->args_len };
	const erx_boot_words_t env = { spec->strings + spec->args_len, spec->env_len };
	char node[APPLY_NODE_MAX], system_node[APPLY_NODE_MAX];
	erx_boot_inputs_t inputs = { 0 };
	uint64_t addr;
	int status;

	if (!apply_node(apply->lib, spec->name, spec->name_len, node, &inputs.node_len))
		return (ERX_EINVAL);
	inputs.node = node;
	inputs.domain_id = spec->id;
	inputs.flags = apply->lib->det ? ERX_BOOT_DET : 0;
	inputs.pack_flags = apply->lib->pack_flags;
	inputs.capacity_mcpu = spec->grant.capacity_mcpu;
	inputs.cpuset = spec->grant.cpuset;
	inputs.budget = (erx_cap_t){ .raw = apply->installed[ERX_DOM_OBJ_BUDGET] };
	/*
	 * No install names a space to itself: a domain names its own as every
	 * space does, by ERX_CAP_SELF. group_ctl and group_stat stay
	 * ERX_CAP_NULL on the stopgap, whose group status page is the home
	 * task's own (docs/design-stopgap.md, "Boot information").
	 */
	inputs.space = (erx_cap_t){ .raw = ERX_CAP_SELF };
	inputs.group = (erx_cap_t){ .raw = apply->installed[ERX_DOM_OBJ_GROUP] };
	inputs.spaces_group = (erx_cap_t){ .raw = apply->installed[ERX_DOM_OBJ_SPACES_GROUP] };
	inputs.time_page = (erx_cap_t){ .raw = apply->installed[ERX_DOM_OBJ_TIME_PAGE] };
	inputs.release = (erx_cap_t){ .raw = apply->installed[ERX_DOM_OBJ_SLICE] };
	inputs.release_addr = apply->release_addr;
	inputs.crash_area = (erx_cap_t){ .raw = apply->installed[ERX_DOM_OBJ_CRASH] };
	/*
	 * The domain writes its own side, sized to the system domain's lane, and
	 * reads the system domain's, whose data area is the plan's reader.
	 */
	if (plan->connection != 0) {
		/* The peer is system@<host>, the node the root's boot page names. */
		if (!apply_node(apply->lib, SYSTEM_NAME, sizeof(SYSTEM_NAME) - 1, system_node, &inputs.system_node_len))
			return (ERX_EINVAL);
		inputs.system_node = system_node;
		inputs.system_connection = (erx_boot_connection_t){
		    .side = { .raw = apply->installed[ERX_DOM_OBJ_DOM_SIDE] },
		    .peer_side = { .raw = apply->installed[ERX_DOM_OBJ_SYS_SIDE] },
		    .peer_bell = { .raw = apply->installed[ERX_DOM_OBJ_SYS_BELL] },
		    .label = ERX_DOM_SYSTEM_LABEL, .peer = ERX_DOM_SYSTEM_ID,
		    .out_size = spec->system_lane, .in_size = plan->reader };
	}
	inputs.args = &args;
	inputs.nargs = spec->args_len != 0;
	inputs.env = &env;
	inputs.nenv = spec->env_len != 0;
	inputs.limits = spec->runtime_limits;

	status = erx_vm_reserve(ERX_CAP_SELF, 0, ERX_PAGE_SIZE, 0, &addr);
	if (status != ERX_OK)
		return (status);
	status = erx_vm_map(ERX_CAP_SELF, addr, ERX_PAGE_SIZE, page, 0, ERX_PROT_RW);
	if (status == ERX_OK) {
		const erx_boot_info_status_t built = erx_boot_info_build(&inputs,
		    (void *)(uintptr_t)addr, ERX_PAGE_SIZE);

		if (built != ERX_BOOT_INFO_OK)
			status = ERX_EINVAL;
	}
	if (erx_vm_release(ERX_CAP_SELF, addr, ERX_PAGE_SIZE) != ERX_OK && status == ERX_OK)
		status = ERX_EINVAL;
	return (status);
}

/* The first thread, stopped, at the image's entry with the boot page's address as its argument. */
static int
apply_thread(apply_t *apply, const erx_dom_step_t *step)
{
	erx_thread_start_t start = { 0 };
	uint64_t words[sizeof(start) / sizeof(uint64_t)];
	uint64_t handle;
	int status;

	start.regs.pc = apply->pc;
	start.regs.gpr[0] = apply->bootinfo_addr;
	memcpy(words, &start, sizeof(words));
	for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++)
		(void)erx_utcb_mr_store(erx_utcb_self(), word, words[word]);
	status = erx_thread_create(apply_object(apply, step->budget),
	    apply_object(apply, step->target), apply_object(apply, step->aux),
	    ERX_THREAD_CLASS_WORKER, &handle);
	if (status == ERX_OK)
		apply_made(apply, step, handle);
	return (status);
}

/*
 * Whether obj's charge leads to budget: obj is budget, or is charged to it or
 * to a budget carved from it. A chain passes each made object once at most,
 * and ends at a budget outside the set, such as a party's outer budget.
 */
static bool
set_under(const handle_set_t *set, erx_dom_obj_t obj, erx_dom_obj_t budget)
{
	for (uint32_t hops = 0; hops < set->count && set_holds(set, obj); hops++) {
		if (obj == budget)
			return (true);
		obj = set->charge[obj - set->first];
	}
	return (false);
}

/* Closes every handle whose object went with budget's destroy. */
static void
set_close_under(handle_set_t *set, erx_dom_obj_t budget)
{
	for (uint32_t index = 0; index < set->count; index++) {
		if (set->made[index] == ERX_CAP_NULL || !set_under(set, (erx_dom_obj_t)(set->first + index), budget))
			continue;
		(void)erx_cap_close(set->made[index]);
		set->made[index] = ERX_CAP_NULL;
	}
}

/*
 * The undo of applied steps (A4): destroys the count budgets of undo, which
 * a plan's undo lists last first, each deleting every object charged to it,
 * then closes the handles to what went. A destroy of a budget the library
 * made cannot fail.
 */
static void
set_undo(handle_set_t *set, const erx_dom_obj_t *undo, uint32_t count)
{
	for (uint32_t index = 0; index < count; index++) {
		if (!set_holds(set, undo[index]) || set->made[undo[index] - set->first] == ERX_CAP_NULL)
			continue;
		(void)erx_object_destroy(set->made[undo[index] - set->first]);
		set_close_under(set, undo[index]);
	}
}

/* The undo of a creation's first applied steps. */
static void
apply_undo(apply_t *apply, uint32_t applied)
{
	erx_dom_obj_t undo[ERX_DOM_PLAN_STEPS_MAX];
	handle_set_t set = set_of_domain(&apply->handles);

	set_undo(&set, undo, erx_dom_plan_undo(apply->plan, applied, undo));
}

/* Copies the record's capabilities in the view from the handles the library keeps for it. */
static void
lib_view_caps(erx_dom_lib_t *lib, uint32_t slot)
{
	const uint64_t *made = lib->handles[slot].made;
	erx_dom_t *dom = &lib->view.domains[slot];

#define CAP(obj)	((erx_cap_t){ .raw = made[obj] })
	dom->budget = CAP(ERX_DOM_OBJ_BUDGET);
	dom->outer = CAP(ERX_DOM_OBJ_OUTER);
	dom->space = CAP(ERX_DOM_OBJ_SPACE);
	dom->group = CAP(ERX_DOM_OBJ_GROUP);
	dom->spaces_group = CAP(ERX_DOM_OBJ_SPACES_GROUP);
	dom->crash = CAP(ERX_DOM_OBJ_CRASH);
	dom->bootinfo = CAP(ERX_DOM_OBJ_BOOTINFO);
	dom->first_thread = CAP(ERX_DOM_OBJ_THREAD);
#undef CAP
}

/* Keeps the creation's handles for its record, and fills its connection's row from them. */
static void
apply_keep(apply_t *apply, erx_dom_created_t *created)
{
	const erx_dom_plan_t *plan = apply->plan;
	const uint64_t *made = apply->handles.made;
	erx_dom_connection_t *row;

	apply->lib->handles[plan->slot] = apply->handles;
	lib_view_caps(apply->lib, plan->slot);
	*created = (erx_dom_created_t){ .id = plan->spec.id, .connection = plan->connection };
	if (plan->connection_row == ERX_DOM_NO_ROW)
		return;
	row = &apply->lib->view.connections[plan->connection_row];
	row->budget_a = (erx_cap_t){ .raw = ERX_CAP_NULL };
	row->budget_b = (erx_cap_t){ .raw = made[ERX_DOM_OBJ_SYS_BUDGET] };
	row->side_a = (erx_cap_t){ .raw = made[ERX_DOM_OBJ_SYS_SIDE] };
	row->side_b = (erx_cap_t){ .raw = made[ERX_DOM_OBJ_DOM_SIDE] };
	row->bell_a = (erx_cap_t){ .raw = made[ERX_DOM_OBJ_SYS_BELL] };
	row->bell_b = (erx_cap_t){ .raw = made[ERX_DOM_OBJ_DOM_BELL] };
	created->side = made[ERX_DOM_OBJ_DOM_SIDE];
	created->peer_side = made[ERX_DOM_OBJ_SYS_SIDE];
	created->bell = made[ERX_DOM_OBJ_DOM_BELL];
}

/*
 * Applies the plan's steps in order and records it. On a refusal, the steps
 * applied so far are undone, the refused one included, since it may have
 * made its object before it failed; undo reaches that object by its budget.
 */
static erx_status_t
apply_plan(apply_t *apply, erx_dom_created_t *created)
{
	const erx_dom_plan_t *plan = apply->plan;
	erx_status_t status = ERX_OK;
	uint32_t applied;

	for (applied = 0; applied < plan->nsteps; applied++) {
		status = hook_step(apply->lib, applied, false, ERX_OK);
		if (status == ERX_OK)
			status = hook_step(apply->lib, applied, true, apply_step(apply, &plan->steps[applied]));
		if (status != ERX_OK)
			break;
	}
	if (status == ERX_OK)
		status = erx_dom_plan_record(&apply->lib->view, plan);
#ifdef ERX_DOM_TEST_HOOKS
	apply->lib->failed_at = applied;
#endif
	if (status != ERX_OK) {
		apply_undo(apply, applied < plan->nsteps ? applied + 1 : plan->nsteps);
		return (status);
	}
	apply_keep(apply, created);
	return (ERX_OK);
}

erx_status_t
erx_dom_lib_create(erx_dom_lib_t *lib, const erx_dom_spec_t *req,
    const erx_runtime_limits_t *limits, uint32_t given, erx_dom_created_t *created)
{
	/* A plan holds a specification with its strings: too large for a stack. */
	static erx_dom_plan_t plan;
	erx_status_t status;

	status = erx_dom_plan_request(&lib->view, req, limits, given, &plan);
	if (status == ERX_OK)
		status = erx_dom_lib_apply(lib, &plan, created);
	/* No copy of the plan or its strings stays in this static buffer past the call. */
	memset(&plan, 0, sizeof(plan));
	return (status);
}

erx_status_t
erx_dom_lib_apply(erx_dom_lib_t *lib, const erx_dom_plan_t *plan, erx_dom_created_t *created)
{
	/* What the steps learn, with a copy of each handle: too large for a stack. */
	static apply_t apply;
	erx_status_t status;

	apply = (apply_t){ .lib = lib, .plan = plan };
	status = apply_plan(&apply, created);
	memset(&apply, 0, sizeof(apply));
	return (status);
}

/* The record holding id, or view.max_domains for none. */
static uint32_t
lib_slot(const erx_dom_lib_t *lib, uint32_t id)
{
	for (uint32_t slot = 0; id != 0 && slot < lib->view.max_domains; slot++)
		if (lib->view.domains[slot].id == id)
			return (slot);
	return (lib->view.max_domains);
}

erx_status_t
erx_dom_lib_start(erx_dom_lib_t *lib, uint32_t id)
{
	const uint32_t slot = lib_slot(lib, id);
	erx_dom_t *dom;
	erx_status_t status;

	if (slot == lib->view.max_domains || lib->view.domains[slot].state != ERX_DOM_BUILT)
		return (ERX_EINVAL);
	dom = &lib->view.domains[slot];
	status = erx_thread_start(dom->first_thread.raw);
	if (status == ERX_OK)
		dom->state = ERX_DOM_RUNNING;
	return (status);
}

/* Performs a STOP action: the stop is noted before the space is told, so its exit record finds it. */
static erx_status_t
lib_stop(erx_dom_lib_t *lib, const erx_dom_action_t *action)
{
	erx_dom_t *dom = &lib->view.domains[action->slot];
	erx_status_t status;

	dom->stop = action->end;
	status = erx_space_stop(dom->space.raw, action->status);
	if (status != ERX_OK)
		dom->stop = (erx_dom_end_t){ .kind = ERX_DOM_END_NONE };
	return (status);
}

erx_status_t
erx_dom_lib_stop(erx_dom_lib_t *lib, uint32_t id, int64_t status)
{
	erx_dom_action_t action;
	erx_status_t planned;

	planned = erx_dom_plan_stop(&lib->view, id, status, &action);
	if (planned != ERX_OK || action.kind != ERX_DOM_ACT_STOP)
		return (planned);
	return (lib_stop(lib, &action));
}

/* The made object whose handle is cap, or ERX_DOM_OBJ_COUNT for none. */
static erx_dom_obj_t
set_find(const handle_set_t *set, uint64_t cap)
{
	for (uint32_t index = 0; cap != ERX_CAP_NULL && index < set->count; index++)
		if (set->made[index] == cap)
			return ((erx_dom_obj_t)(set->first + index));
	return (ERX_DOM_OBJ_COUNT);
}

/*
 * The handles that hold the teardown's capabilities: the destroyed or
 * retired domain's; for a system connection its domain's (b), whose child
 * holds both sides; for a connection between domains its row's. *slot is
 * the record whose capabilities the view copies again after, or
 * view.max_domains for a connection's own. False when the record is none.
 */
static bool
teardown_set(erx_dom_lib_t *lib, const erx_dom_teardown_t *teardown, handle_set_t *set, uint32_t *slot)
{
	const erx_dom_connection_t *row;

	*slot = teardown->index;
	if (teardown->kind == ERX_DOM_DISCONNECT) {
		row = &lib->view.connections[teardown->index];
		if (row->a != ERX_DOM_SYSTEM_ID) {
			*set = set_of_link(&lib->links[teardown->index]);
			*slot = lib->view.max_domains;
			return (true);
		}
		*slot = lib_slot(lib, row->b);
	}
	if (*slot >= lib->view.max_domains)
		return (false);
	*set = set_of_domain(&lib->handles[*slot]);
	return (true);
}

/*
 * Destroys the budgets the teardown names, each found among the handles
 * that hold it before any is destroyed, then closes the handles to what
 * went and copies the record's capabilities again. ERX_EINVAL, destroying
 * nothing, when a capability is not among those handles: a value that
 * matched elsewhere could name another domain's object.
 */
static erx_status_t
teardown_apply(erx_dom_lib_t *lib, const erx_dom_teardown_t *teardown)
{
	erx_dom_obj_t obj[2];
	handle_set_t set;
	uint32_t slot;
	const uint32_t count = teardown->ndestroy;

	if (count > 2 || !teardown_set(lib, teardown, &set, &slot))
		return (ERX_EINVAL);
	for (uint32_t index = 0; index < count; index++) {
		obj[index] = set_find(&set, teardown->destroy[index].raw);
		if (obj[index] == ERX_DOM_OBJ_COUNT)
			return (ERX_EINVAL);
	}
	for (uint32_t index = 0; index < count; index++) {
		(void)erx_object_destroy(teardown->destroy[index].raw);
		set_close_under(&set, obj[index]);
	}
	if (slot < lib->view.max_domains)
		lib_view_caps(lib, slot);
	return (ERX_OK);
}

/* The handle a connection's step names: one it made, or one of a party's records. */
static uint64_t
link_object(const link_t *link, erx_dom_obj_t obj)
{
	const uint64_t *const a = link->lib->handles[link->plan->a_slot].made;
	const uint64_t *const b = link->lib->handles[link->plan->b_slot].made;

	if (obj >= ERX_DOM_OBJ_LINK_BUDGET_A && obj <= ERX_DOM_OBJ_BELL_B)
		return (link->handles.made[obj - ERX_DOM_OBJ_LINK_BUDGET_A]);
	switch (obj) {
	case ERX_DOM_OBJ_OUTER_A:
		return (a[ERX_DOM_OBJ_OUTER]);
	case ERX_DOM_OBJ_OUTER_B:
		return (b[ERX_DOM_OBJ_OUTER]);
	case ERX_DOM_OBJ_GROUP_A:
		return (a[ERX_DOM_OBJ_GROUP]);
	case ERX_DOM_OBJ_GROUP_B:
		return (b[ERX_DOM_OBJ_GROUP]);
	case ERX_DOM_OBJ_SPACE_A:
		return (a[ERX_DOM_OBJ_SPACE]);
	case ERX_DOM_OBJ_SPACE_B:
		return (b[ERX_DOM_OBJ_SPACE]);
	default:
		return (APPLY_NO_HANDLE);
	}
}

/*
 * Where an install's value goes: the party whose space it enters, as its
 * own side, the other's side or the other's bell; NULL for anything else.
 */
static uint64_t *
link_value(link_t *link, const erx_dom_step_t *step)
{
	const bool to_a = step->target == ERX_DOM_OBJ_SPACE_A;
	erx_dom_party_t *const party = to_a ? &link->linked.a : &link->linked.b;

	if (!to_a && step->target != ERX_DOM_OBJ_SPACE_B)
		return (NULL);
	if (step->obj == (to_a ? ERX_DOM_OBJ_SIDE_A : ERX_DOM_OBJ_SIDE_B))
		return (&party->side);
	if (step->obj == (to_a ? ERX_DOM_OBJ_SIDE_B : ERX_DOM_OBJ_SIDE_A))
		return (&party->peer_side);
	if (step->obj == (to_a ? ERX_DOM_OBJ_BELL_B : ERX_DOM_OBJ_BELL_A))
		return (&party->peer_bell);
	return (NULL);
}

/* One step of a connection; a bell's label is the one its party learns. */
static int
link_step(link_t *link, const erx_dom_step_t *step)
{
	handle_set_t set = set_of_link(&link->handles);
	uint64_t *value;

	if (step->kind == ERX_DOM_STEP_INSTALL) {
		value = link_value(link, step);
		if (value == NULL)
			return (ERX_EINVAL);
		return (erx_dom_install(step, link_object(link, step->obj), link_object(link, step->target),
		    value));
	}
	if (step->kind == ERX_DOM_STEP_BELL)
		(step->obj == ERX_DOM_OBJ_BELL_A ? &link->linked.a : &link->linked.b)->label = step->label;
	return (make_step(&set, step, link_object(link, step->budget), link_object(link, step->target)));
}

/* Copies a connection row's capabilities in the view from the handles the library keeps for it. */
static void
link_view_caps(erx_dom_lib_t *lib, uint32_t row)
{
	const uint64_t *const made = lib->links[row].made;
	erx_dom_connection_t *const conn = &lib->view.connections[row];

#define CAP(obj)	((erx_cap_t){ .raw = made[(obj) - ERX_DOM_OBJ_LINK_BUDGET_A] })
	conn->budget_a = CAP(ERX_DOM_OBJ_LINK_BUDGET_A);
	conn->budget_b = CAP(ERX_DOM_OBJ_LINK_BUDGET_B);
	conn->side_a = CAP(ERX_DOM_OBJ_SIDE_A);
	conn->side_b = CAP(ERX_DOM_OBJ_SIDE_B);
	conn->bell_a = CAP(ERX_DOM_OBJ_BELL_A);
	conn->bell_b = CAP(ERX_DOM_OBJ_BELL_B);
#undef CAP
}

erx_status_t
erx_dom_lib_connect(erx_dom_lib_t *lib, uint32_t a, uint32_t b, uint32_t a_reads, uint32_t b_reads,
    erx_dom_linked_t *linked)
{
	erx_dom_obj_t undo[ERX_DOM_LINK_STEPS];
	erx_dom_link_plan_t plan;
	link_t link;
	handle_set_t set;
	erx_status_t status;
	uint32_t applied;

	status = erx_dom_plan_connect(&lib->view, a, b, a_reads, b_reads, &plan);
	if (status != ERX_OK)
		return (status);
	link = (link_t){ .lib = lib, .plan = &plan };
	for (applied = 0; applied < plan.nsteps; applied++) {
		status = hook_step(lib, applied, false, ERX_OK);
		if (status == ERX_OK)
			status = hook_step(lib, applied, true, link_step(&link, &plan.steps[applied]));
		if (status != ERX_OK)
			break;
	}
	if (status == ERX_OK)
		status = erx_dom_link_record(&lib->view, &plan);
#ifdef ERX_DOM_TEST_HOOKS
	lib->failed_at = applied;
#endif
	if (status != ERX_OK) {
		/* The refused step may have made its object; the undo reaches it by its budget. */
		set = set_of_link(&link.handles);
		set_undo(&set, undo, erx_dom_link_undo(&plan, applied < plan.nsteps ? applied + 1 : plan.nsteps, undo));
		return (status);
	}
	lib->links[plan.row] = link.handles;
	link_view_caps(lib, plan.row);
	link.linked.number = plan.number;
	*linked = link.linked;
	return (ERX_OK);
}

erx_status_t
erx_dom_lib_disconnect(erx_dom_lib_t *lib, uint32_t number)
{
	erx_dom_teardown_t teardown;
	erx_status_t status;

	status = erx_dom_plan_disconnect(&lib->view, number, &teardown);
	if (status == ERX_OK)
		status = teardown_apply(lib, &teardown);
	if (status != ERX_OK)
		return (status);
	memset(&lib->view.connections[teardown.index], 0, sizeof(lib->view.connections[0]));
	memset(&lib->links[teardown.index], 0, sizeof(lib->links[0]));
	return (ERX_OK);
}

erx_status_t
erx_dom_lib_retire(erx_dom_lib_t *lib, uint32_t id)
{
	erx_dom_teardown_t teardown;
	erx_status_t status;

	status = erx_dom_plan_retire(&lib->view, id, &teardown);
	if (status == ERX_OK)
		status = teardown_apply(lib, &teardown);
	if (status != ERX_OK)
		return (status);
	erx_dom_retire_record(&lib->view, &teardown);
	memset(&lib->handles[teardown.index], 0, sizeof(lib->handles[0]));
	return (ERX_OK);
}

erx_status_t
erx_dom_lib_crash_copy(erx_dom_lib_t *lib, uint32_t id, uint64_t dst)
{
	const uint32_t slot = lib_slot(lib, id);
	const erx_dom_t *dom;

	if (slot == lib->view.max_domains)
		return (ERX_EINVAL);
	dom = &lib->view.domains[slot];
	if (dom->state != ERX_DOM_ENDED || dom->crash.raw == ERX_CAP_NULL)
		return (ERX_EINVAL);
	return (erx_mem_copy(dst, 0, dom->crash.raw, 0, ERX_CRASH_SIZE));
}

erx_status_t
erx_dom_lib_take(uint64_t wait_by, uint64_t *label, erx_fault_t *record)
{
	const erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t words[sizeof(*record) / sizeof(uint64_t)];
	erx_msgtag_t tag;
	erx_status_t status;

	status = erx_ipc_wait(wait_by, &tag, label);
	if (status != ERX_OK)
		return (status);
	if (erx_msgtag_raw_words_get(tag.raw) != sizeof(words) / sizeof(words[0]) ||
	    erx_msgtag_raw_items_get(tag.raw) != 0)
		return (ERX_EINVAL);
	for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++)
		words[word] = atomic_load_explicit(&utcb->mr[word], memory_order_relaxed);
	memcpy(record, words, sizeof(words));
	return (ERX_OK);
}

bool
erx_dom_lib_record(erx_dom_lib_t *lib, uint64_t label, const erx_fault_t *record,
    erx_dom_report_t *report)
{
	erx_dom_action_t action;
	erx_dom_t *dom;

	erx_dom_record_step(&lib->view, label, record, &action);
	switch (action.kind) {
	case ERX_DOM_ACT_STOP:
		/* A space the backend will not stop keeps its fault; nothing else can end it. */
		(void)lib_stop(lib, &action);
		return (false);
	case ERX_DOM_ACT_END:
		dom = &lib->view.domains[action.slot];
		/*
		 * The space has ended whatever the teardown does. A refusal can come
		 * only from a library whose handles lost the budget, and leaves its
		 * objects in place rather than destroy what another value names.
		 */
		(void)teardown_apply(lib, &action.teardown);
		dom->end = action.end;
		dom->record = *record;
		dom->state = ERX_DOM_ENDED;
		*report = (erx_dom_report_t){ .id = dom->id, .end = action.end, .record = *record };
		return (true);
	case ERX_DOM_ACT_DROP:
	default:
		return (false);
	}
}

/* Written once, by the root's start, before any thread that reads it runs. */
static erx_dom_lib_t *dom_lib_system;

erx_dom_lib_t *
erx_dom_lib_system(void)
{
	return (dom_lib_system);
}

void
erx_dom_lib_system_set(erx_dom_lib_t *lib)
{
	dom_lib_system = lib;
}
