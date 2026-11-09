/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The domain library's pure core: the planning entries with their origin
 * constructors, the creation planner, the whole-plan check, the undo of a
 * failed creation and the record of an applied one in the view,
 * and the validation of a principal's configuration
 * (docs/design-system.md, "The domain library" and "Creating a domain").
 * Nothing here performs a kernel call; the apply phase performs a plan's
 * steps in order and, when one fails, destroys what erx_dom_plan_undo
 * names.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/dom.h"
#include "erx/lane.h"

/* The parts of an erx_grant_t rate: thousandths of one CPU. */
#define DOM_MILLI	UINT64_C(1000)

#define DOM_WRITER	(ERX_HR_READ | ERX_HR_WRITE | ERX_HR_MAP)
#define DOM_READER	(ERX_HR_READ | ERX_HR_MAP)

/*
 * A party of a connection gets its own side to write, the peer's to read
 * and the peer's bell to ring; its own bell stays the library's, bound to
 * its group, and it learns only the bell's label. A device's holder gets
 * its windows, lines and DMA window to drive it, and PHYS on its contiguous
 * memory alone.
 */
const erx_dom_grant_row_t erx_dom_grants[ERX_DOM_GRANTS_ROWS] = {
	{ ERX_DOM_OBJ_BUDGET, ERX_DOM_OBJ_SPACE, 0, ERX_HR_ALLOC,
	    ERX_HR_SPACES | ERX_HR_CARVE | ERX_HR_DUP | ERX_HR_GIVE },
	{ ERX_DOM_OBJ_GROUP, ERX_DOM_OBJ_SPACE, 0,
	    ERX_HR_ATTACH | ERX_HR_SIGNAL, 0 },
	{ ERX_DOM_OBJ_SPACES_GROUP, ERX_DOM_OBJ_SPACE, ERX_DOM_SPACES,
	    ERX_HR_CONFIGURE | ERX_HR_ATTACH | ERX_HR_SIGNAL | ERX_HR_DUP |
	    ERX_HR_GIVE, 0 },
	{ ERX_DOM_OBJ_DOM_SIDE, ERX_DOM_OBJ_SPACE, 0, DOM_WRITER, 0 },
	{ ERX_DOM_OBJ_SYS_SIDE, ERX_DOM_OBJ_SPACE, 0, DOM_READER, 0 },
	{ ERX_DOM_OBJ_SYS_BELL, ERX_DOM_OBJ_SPACE, 0, ERX_HR_TRIGGER, 0 },
	{ ERX_DOM_OBJ_TIME_PAGE, ERX_DOM_OBJ_SPACE, 0, DOM_READER, 0 },
	{ ERX_DOM_OBJ_SLICE, ERX_DOM_OBJ_SPACE, 0, DOM_READER, 0 },
	{ ERX_DOM_OBJ_CRASH, ERX_DOM_OBJ_SPACE, 0, DOM_WRITER, 0 },
	{ ERX_DOM_OBJ_SIDE_A, ERX_DOM_OBJ_SPACE_A, 0, DOM_WRITER, 0 },
	{ ERX_DOM_OBJ_SIDE_B, ERX_DOM_OBJ_SPACE_A, 0, DOM_READER, 0 },
	{ ERX_DOM_OBJ_BELL_B, ERX_DOM_OBJ_SPACE_A, 0, ERX_HR_TRIGGER, 0 },
	{ ERX_DOM_OBJ_SIDE_B, ERX_DOM_OBJ_SPACE_B, 0, DOM_WRITER, 0 },
	{ ERX_DOM_OBJ_SIDE_A, ERX_DOM_OBJ_SPACE_B, 0, DOM_READER, 0 },
	{ ERX_DOM_OBJ_BELL_A, ERX_DOM_OBJ_SPACE_B, 0, ERX_HR_TRIGGER, 0 },
	{ ERX_DOM_OBJ_DEV_WINDOW, ERX_DOM_OBJ_HOLDER_SPACE, 0, DOM_WRITER, 0 },
	{ ERX_DOM_OBJ_DEV_IRQ, ERX_DOM_OBJ_HOLDER_SPACE, 0,
	    ERX_HR_BIND | ERX_HR_ACK, 0 },
	{ ERX_DOM_OBJ_DEV_DMA, ERX_DOM_OBJ_HOLDER_SPACE, 0,
	    ERX_HR_MAP | ERX_HR_BIND, 0 },
	{ ERX_DOM_OBJ_DEV_MEMORY, ERX_DOM_OBJ_HOLDER_SPACE, 0,
	    DOM_WRITER | ERX_HR_PHYS, 0 },
	{ ERX_DOM_OBJ_DEV_KEPT, ERX_DOM_OBJ_HOLDER_SPACE, 0,
	    DOM_WRITER | ERX_HR_PHYS, 0 },
};

/*
 * The most steps dom_plan_steps writes besides installs: three carves,
 * the space, two groups, four memory objects, two bells, the slice, the
 * image map, two mappings, the boot page write and the first thread.
 * Installs add at most one per grants row.
 */
#define DOM_FIXED_STEPS_MAX	18u
_Static_assert(DOM_FIXED_STEPS_MAX + ERX_DOM_GRANTS_ROWS <=
    ERX_DOM_PLAN_STEPS_MAX, "every plan fits its step array");

/*
 * The runtime limits a request may leave out, each named in
 * dom_spec_request and dom_limits_within: a new field of the ABI's layout
 * changes its size or its last offset and stops the build here.
 */
_Static_assert(sizeof(erx_runtime_limits_t) == 64 &&
    offsetof(erx_runtime_limits_t, peer_held_total) == 56 &&
    ERX_DOM_LIMITS_FIELDS == 11, "every runtime limit is handled");

static bool	dom_add(uint64_t, uint64_t, uint64_t *);
static bool	dom_page_aligned(uint64_t);
static uint32_t	dom_popcount(uint64_t);
static erx_dom_principal_t *dom_principal(const erx_dom_view_t *, uint32_t);
static bool	dom_grant_rate(const erx_grant_t *, uint64_t *);
static bool	dom_grant_fits(const erx_grant_t *, const erx_grant_t *);
static bool	dom_service_grant(const erx_dom_t *);
static bool	dom_system_reserve(const erx_dom_view_t *, const erx_grant_t *);
static bool	dom_limits_within(const erx_runtime_limits_t *,
		    const erx_runtime_limits_t *);
static bool	dom_strings(const erx_dom_spec_t *);
static bool	dom_name(const erx_dom_spec_t *);
static bool	dom_reader_lane(const erx_dom_spec_t *, uint64_t *);
static erx_status_t dom_check_origin(const erx_dom_spec_t *,
		    const erx_dom_view_t *);
static erx_status_t	dom_spec_request(const erx_dom_view_t *,
		    const erx_dom_principal_t *, const erx_dom_spec_t *,
		    const erx_runtime_limits_t *, uint32_t, erx_dom_spec_t *);
static void	dom_spec_configured(const erx_dom_view_t *, uint32_t,
		    uint32_t, erx_dom_spec_t *);
static void	dom_spec_partial(const erx_dom_view_t *, uint32_t, uint32_t,
		    erx_dom_spec_t *);
static void	dom_decimal(uint32_t, erx_dom_spec_t *);
static erx_status_t dom_plan(const erx_dom_spec_t *, const erx_dom_view_t *,
		    erx_dom_plan_t *);
static erx_status_t dom_check_files(const erx_dom_spec_t *,
		    const erx_dom_view_t *, bool *, uint64_t *);
static erx_status_t dom_check_sizes(const erx_dom_spec_t *,
		    const erx_dom_view_t *, uint64_t *, uint64_t *);
static erx_status_t dom_check_grants(const erx_dom_spec_t *,
		    const erx_dom_view_t *, const erx_dom_principal_t *);
static erx_status_t dom_check_room(const erx_dom_spec_t *,
		    const erx_dom_view_t *, const erx_dom_principal_t *,
		    erx_dom_plan_t *);
static void	dom_step(erx_dom_plan_t *, erx_dom_step_t);
static bool	dom_step_makes(erx_dom_step_kind_t);
static uint32_t	dom_row_rights(const erx_dom_spec_t *,
		    const erx_dom_grant_row_t *);
static bool	dom_plan_makes(const erx_dom_plan_t *, erx_dom_obj_t);
static bool	dom_row_applies(const erx_dom_plan_t *,
		    const erx_dom_grant_row_t *);
static void	dom_plan_steps(erx_dom_plan_t *, bool, uint64_t, uint64_t);
static bool	dom_carved_budget(const bool *, erx_dom_obj_t);
static bool	dom_granted(const erx_dom_spec_t *, const erx_dom_step_t *);
static bool	dom_step_ok(const erx_dom_plan_t *, const erx_dom_step_t *,
		    const bool *);

static bool
dom_add(uint64_t a, uint64_t b, uint64_t *sum)
{
	return (!__builtin_add_overflow(a, b, sum));
}

static bool
dom_page_aligned(uint64_t bytes)
{
	return (bytes % ERX_PAGE_SIZE == 0);
}

static uint32_t
dom_popcount(uint64_t bits)
{
	return ((uint32_t)__builtin_popcountll(bits));
}

/* The principal numbered number, writable for erx_dom_plan_record. */
static erx_dom_principal_t *
dom_principal(const erx_dom_view_t *view, uint32_t number)
{
	if (number == 0)
		return (NULL);
	for (uint32_t index = 0; index < view->nprincipals; index++)
		if (view->principals[index].number == number)
			return (&view->principals[index]);
	return (NULL);
}

/*
 * A grant's rate, in thousandths of a CPU: an uncapped grant's is the size
 * of its cpuset, a capped one's its quota over its period, rounded up. A
 * grant whose rate this cannot state (an empty cpuset, a period out of
 * range, a quota past what its cpuset could spend, nonzero padding) has
 * none, and no plan carries it.
 */
static bool
dom_grant_rate(const erx_grant_t *grant, uint64_t *rate)
{
	static const uint8_t zero[sizeof(grant->padding_0)];
	uint64_t most;

	if (grant->cpuset == 0 ||
	    memcmp(grant->padding_0, zero, sizeof(zero)) != 0)
		return (false);
	if (grant->quota_ns == ERX_QUOTA_NONE) {
		*rate = dom_popcount(grant->cpuset) * DOM_MILLI;
		return (true);
	}
	if (grant->period_ns < ERX_PERIOD_MIN || grant->period_ns > ERX_PERIOD_MAX)
		return (false);
	most = grant->period_ns * dom_popcount(grant->cpuset);
	if (grant->quota_ns > most)
		return (false);
	/* quota <= period * 64 <= 6.4e10, so quota * 1000 fits. */
	*rate = (grant->quota_ns * DOM_MILLI + grant->period_ns - 1) /
	    grant->period_ns;
	return (true);
}

/*
 * A child grant fits a parent when it asks for no CPU, urgency, rate or
 * group feature the parent lacks.
 */
static bool
dom_grant_fits(const erx_grant_t *child, const erx_grant_t *parent)
{
	uint64_t child_rate, parent_rate;

	if (!dom_grant_rate(child, &child_rate) ||
	    !dom_grant_rate(parent, &parent_rate))
		return (false);
	return ((child->cpuset & ~parent->cpuset) == 0 &&
	    (child->flags & ~parent->flags) == 0 &&
	    child->ceiling.raw <= parent->ceiling.raw && child_rate <= parent_rate);
}

/*
 * Whether a record's grant is a service grant, one that counts against
 * system's reserve: a configured domain's, whose group is under system,
 * from the plan's apply until the domain ends. BUILDING counts, so a
 * group that may already exist is never left out; whatever marks a
 * record BUILDING writes its grant with it. An ended domain's group went
 * with its own budget, and a retired record is free, so neither counts
 * and nothing has to be taken back.
 */
static bool
dom_service_grant(const erx_dom_t *dom)
{
	if (dom->origin.kind != ERX_DOM_CONFIGURED)
		return (false);
	switch (dom->state) {
	case ERX_DOM_BUILDING:
	case ERX_DOM_BUILT:
	case ERX_DOM_RUNNING:
		return (true);
	case ERX_DOM_FREE:
	case ERX_DOM_ENDED:
	case ERX_DOM_RETIRED:
		return (false);
	}
	return (false);
}

/*
 * The system-reserve predicate (docs/design-system.md, "The manifest",
 * property 13), over the service grants of the view's records with
 * grant added: their rates sum to at most system's rate less
 * system_reserve of it. A grant on system's CPUs takes at most its rate
 * there, and system's rate is at most its CPUs, so no separate per-CPU
 * clause is needed.
 */
static bool
dom_system_reserve(const erx_dom_view_t *view, const erx_grant_t *grant)
{
	uint64_t system_rate, rate, rates;	/* rates starts at grant's */
	uint64_t keep = DOM_MILLI - view->system_reserve;

	if (view->system_reserve > DOM_MILLI ||
	    !dom_grant_rate(&view->system_grant, &system_rate) ||
	    !dom_grant_rate(grant, &rates))
		return (false);
	for (uint32_t index = 0; index < view->max_domains; index++) {
		if (!dom_service_grant(&view->domains[index]))
			continue;
		if (!dom_grant_rate(&view->domains[index].grant, &rate) ||
		    !dom_add(rates, rate, &rates))
			return (false);
	}
	/*
	 * Each rate is at most 64,000, and there are at most 2^32 - 1 records
	 * and grant, so rates is under 2^48 and rates * DOM_MILLI under 2^58.
	 */
	return (rates * DOM_MILLI <= system_rate * keep);
}

static bool
dom_limits_within(const erx_runtime_limits_t *limits,
    const erx_runtime_limits_t *ceiling)
{
	return (limits->reserved == 0 && limits->max_frame != 0 &&
	    limits->max_frame <= ERX_FRAME_MAX &&
	    limits->max_frame <= ceiling->max_frame &&
	    limits->max_message_heap <= ceiling->max_message_heap &&
	    limits->funnel_depth <= ceiling->funnel_depth &&
	    limits->exports <= ceiling->exports &&
	    limits->tmp <= ceiling->tmp &&
	    limits->overlay <= ceiling->overlay &&
	    limits->atoms <= ceiling->atoms &&
	    limits->foreign_atoms <= ceiling->foreign_atoms &&
	    limits->processes <= ceiling->processes &&
	    limits->peer_held <= ceiling->peer_held &&
	    limits->peer_held_total <= ceiling->peer_held_total);
}

/* Arguments and environment fit the strings and each ends in a NUL. */
static bool
dom_strings(const erx_dom_spec_t *spec)
{
	uint64_t total = (uint64_t)spec->args_len + spec->env_len;

	if (total > ERX_BOOT_STRINGS_MAX)
		return (false);
	if (spec->args_len != 0 && spec->strings[spec->args_len - 1] != '\0')
		return (false);
	return (spec->env_len == 0 || spec->strings[total - 1] == '\0');
}

/*
 * The name is an identifier (docs/design-system.md, "Identifiers"): 1 to
 * ERX_DOM_NAME_MAX bytes of [a-z0-9_-], the first a letter or digit, so
 * the node name the boot page carries is ASCII and has one '@'.
 */
static bool
dom_name(const erx_dom_spec_t *spec)
{
	char c;

	if (spec->name_len == 0 || spec->name_len > ERX_DOM_NAME_MAX)
		return (false);
	for (uint32_t at = 0; at < spec->name_len; at++) {
		c = spec->name[at];
		if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
		    (at > 0 && (c == '_' || c == '-'))))
			return (false);
	}
	return (true);
}

/*
 * The data area of the lane the domain reads from the system domain: the
 * smallest power of two holding its lane and the reserve for its
 * connections' control records.
 */
static bool
dom_reader_lane(const erx_dom_spec_t *spec, uint64_t *area)
{
	uint64_t need = (uint64_t)spec->connections * ERX_DOM_CTL_RESERVE;
	uint64_t size = ERX_LANE_MIN;

	if (spec->lane < ERX_LANE_MIN || spec->lane > ERX_LANE_MAX ||
	    !dom_add(need, spec->lane, &need) || need > ERX_LANE_MAX)
		return (false);
	while (size < need)
		size *= 2;
	*area = size;
	return (true);
}

/*
 * The origin names its source. The planning entries build the
 * specification from that source, so its fields are the row's by
 * construction and only the range needs checking.
 */
static erx_status_t
dom_check_origin(const erx_dom_spec_t *spec, const erx_dom_view_t *view)
{
	switch (spec->origin.kind) {
	case ERX_DOM_REQUEST:
		return (spec->origin.record == ERX_MF_NONE ? ERX_OK : ERX_EINVAL);
	case ERX_DOM_CONFIGURED:
		return (spec->origin.record < view->nconfigured ? ERX_OK : ERX_EINVAL);
	case ERX_DOM_PARTIAL_BOOT:
		return (spec->origin.record < view->npartial ? ERX_OK : ERX_EINVAL);
	default:
		return (ERX_EINVAL);
	}
}

/*
 * The runtime is an accepted image and the release a slice of ordinary
 * files. A partial-boot domain runs a native program with no release. A
 * file the boot marks ERX_ENTRY_SEAL is the vault's, whose domain is
 * refused until the vault exists. *span is the bytes the release's slice
 * covers, the backend's own sum: from its first file's offset to its last
 * file's end rounded up to a page; 0 for no release.
 */
static erx_status_t
dom_check_files(const erx_dom_spec_t *spec, const erx_dom_view_t *view,
    bool *jit, uint64_t *span)
{
	const erx_dom_file_t *file;
	uint64_t last, end;

	*span = 0;

	if (spec->runtime >= view->nfiles)
		return (ERX_EINVAL);
	file = &view->files[spec->runtime];
	if (file->kind != ERX_ENTRY_IMAGE || !file->image_ok ||
	    (file->flags & (ERX_ENTRY_SYSTEM | ERX_ENTRY_SEAL)) != 0 ||
	    (file->image_flags & ~ERX_IMAGE_FLAGS_KNOWN) != 0)
		return (ERX_EINVAL);
	*jit = (file->image_flags & ERX_IMAGE_JIT) != 0;

	if (spec->origin.kind == ERX_DOM_PARTIAL_BOOT)
		return (spec->release == 0 && spec->release_files == 0 ?
		    ERX_OK : ERX_EINVAL);
	last = (uint64_t)spec->release + spec->release_files;
	if (spec->release_files == 0 || last > view->nfiles)
		return (ERX_EINVAL);
	for (uint32_t index = spec->release; index < last; index++) {
		file = &view->files[index];
		if (file->kind != ERX_ENTRY_FILE ||
		    (file->flags & (ERX_ENTRY_SYSTEM | ERX_ENTRY_SEAL)) != 0)
			return (ERX_EINVAL);
	}
	/* The span: from the first file's offset to the last file's end, in whole pages. */
	file = &view->files[last - 1];
	if (!dom_add(file->offset, file->size, &end) ||
	    !dom_add(end, ERX_PAGE_SIZE - 1, &end))
		return (ERX_EINVAL);
	end -= end % ERX_PAGE_SIZE;
	/* A span of 0 is the host manifest check's, whose files have no bytes; the slice refuses it. */
	if (end < view->files[spec->release].offset)
		return (ERX_EINVAL);
	*span = end - view->files[spec->release].offset;
	return (ERX_OK);
}

/*
 * Budget, crash area, lane and strings sizes. *reader is the data area of
 * the lane the domain reads and *child the system connection's child
 * budget, both 0 for a partial-boot domain, which has no connection.
 */
static erx_status_t
dom_check_sizes(const erx_dom_spec_t *spec, const erx_dom_view_t *view,
    uint64_t *reader, uint64_t *child)
{
	uint64_t sys_side, dom_side, outer_need;

	if (spec->memory == 0 || !dom_page_aligned(spec->memory) ||
	    !dom_page_aligned(spec->outer) || spec->crash != ERX_CRASH_SIZE ||
	    !dom_strings(spec) || !dom_name(spec))
		return (ERX_EINVAL);

	*reader = 0;
	*child = 0;
	if (spec->origin.kind == ERX_DOM_PARTIAL_BOOT) {
		if (spec->lane != 0 || spec->connections != 0 ||
		    spec->system_lane != 0)
			return (ERX_EINVAL);
	} else {
		if (spec->connections > view->max_connections ||
		    spec->system_lane != view->system_lane ||
		    !dom_reader_lane(spec, reader))
			return (ERX_EINVAL);
		sys_side = erx_lane_side_bytes(*reader);
		dom_side = erx_lane_side_bytes(spec->system_lane);
		if (sys_side == 0 || dom_side == 0 ||
		    !dom_add(sys_side, dom_side, child) ||
		    !dom_add(*child, 2 * ERX_DOM_BELL_BYTES, child))
			return (ERX_EINVAL);
	}
	/* The outer budget holds the crash area and the system child. */
	if (!dom_add(spec->crash, *child, &outer_need) ||
	    spec->outer < outer_need)
		return (ERX_EINVAL);
	return (ERX_OK);
}

/*
 * The grants fit the CPU parent the origin selects (docs/design-system.md,
 * "The domain library"): system for a configured domain, which must also
 * leave system's reserve, else the principal's group; and the sub-space
 * group's grant fits the domain's.
 */
static erx_status_t
dom_check_grants(const erx_dom_spec_t *spec, const erx_dom_view_t *view,
    const erx_dom_principal_t *principal)
{
	static const erx_grant_t none;

	if (spec->origin.kind == ERX_DOM_CONFIGURED) {
		if (!dom_grant_fits(&spec->grant, &view->system_grant) ||
		    !dom_system_reserve(view, &spec->grant))
			return (ERX_EINVAL);
	} else if (!dom_grant_fits(&spec->grant, &principal->share)) {
		return (ERX_EINVAL);
	}
	if ((spec->flags & ERX_DOM_SPACES) != 0)
		return (dom_grant_fits(&spec->spaces, &spec->grant) ?
		    ERX_OK : ERX_EINVAL);
	return (memcmp(&spec->spaces, &none, sizeof(none)) == 0 ?
	    ERX_OK : ERX_EINVAL);
}

/*
 * Room for the domain: a free record, the principal's quota, its budget,
 * and a free connection row for the system connection. Fills the plan's
 * slot and connection.
 */
static erx_status_t
dom_check_room(const erx_dom_spec_t *spec, const erx_dom_view_t *view,
    const erx_dom_principal_t *principal, erx_dom_plan_t *plan)
{
	uint64_t carved;

	plan->slot = view->max_domains;
	for (uint32_t index = 0; index < view->max_domains; index++) {
		if (view->domains[index].id == spec->id)
			return (ERX_EINVAL);
		if (view->domains[index].id == 0 &&
		    plan->slot == view->max_domains)
			plan->slot = index;
	}
	if (plan->slot == view->max_domains ||
	    principal->domains >= principal->domains_max)
		return (ERX_ELIMIT);
	if (!dom_add(principal->carved, spec->memory, &carved) ||
	    !dom_add(carved, spec->outer, &carved) ||
	    carved > principal->memory)
		return (ERX_ENOMEM);

	plan->connection = 0;
	plan->connection_row = ERX_DOM_NO_ROW;
	if (spec->origin.kind == ERX_DOM_PARTIAL_BOOT)
		return (ERX_OK);
	if (view->next_connection == 0)
		return (ERX_ELIMIT);
	for (uint32_t index = 0; index < view->max_connections; index++) {
		if (view->connections[index].number == 0) {
			plan->connection_row = index;
			plan->connection = view->next_connection;
			return (ERX_OK);
		}
	}
	return (ERX_ELIMIT);
}

/*
 * The request constructor: req's fields with every field the library
 * owns set here, and the runtime limits not given taken from the
 * principal's defaults. The strings past the arguments and environment,
 * and the name's bytes past its length, are zeroed, so nothing the caller
 * left there reaches the boot page. ERX_EINVAL when the copy's strings or
 * name overrun their buffer.
 */
static erx_status_t
dom_spec_request(const erx_dom_view_t *view,
    const erx_dom_principal_t *principal, const erx_dom_spec_t *req,
    const erx_runtime_limits_t *limits, uint32_t given, erx_dom_spec_t *spec)
{
	const erx_runtime_limits_t *fallback = &principal->default_limits;
	size_t used;

	*spec = *req;
	if ((uint64_t)spec->args_len + spec->env_len > sizeof(spec->strings) ||
	    spec->name_len > sizeof(spec->name))
		return (ERX_EINVAL);
	used = (size_t)spec->args_len + spec->env_len;
	memset(spec->name + spec->name_len, 0, sizeof(spec->name) - spec->name_len);
	spec->version = ERX_DOM_SPEC_VERSION;
	spec->origin = (erx_dom_origin_t){ ERX_DOM_REQUEST, ERX_MF_NONE };
	spec->system_lane = view->system_lane;
	spec->crash = ERX_CRASH_SIZE;
	memset(spec->strings + used, 0, sizeof(spec->strings) - used);
#define	DOM_PICK(bit, field) do {					\
	spec->runtime_limits.field = (given & (UINT32_C(1) << (bit))) != 0 ?	\
	    limits->field : fallback->field;					\
} while (0)
	DOM_PICK(0, max_frame);
	DOM_PICK(1, max_message_heap);
	DOM_PICK(2, funnel_depth);
	DOM_PICK(3, exports);
	DOM_PICK(4, tmp);
	DOM_PICK(5, overlay);
	DOM_PICK(6, atoms);
	DOM_PICK(7, foreign_atoms);
	DOM_PICK(8, processes);
	DOM_PICK(9, peer_held);
	DOM_PICK(10, peer_held_total);
#undef DOM_PICK
	spec->runtime_limits.reserved = 0;
	return (ERX_OK);
}

/*
 * The configured constructor: everything from the checked manifest row,
 * whose name, arguments and environment fit the spec (boot_configured holds
 * the view's rows to that). The bound on the name is checked again here, as
 * the copy's own: a name that did not fit would be left empty, which
 * planning refuses.
 */
static void
dom_spec_configured(const erx_dom_view_t *view, uint32_t id, uint32_t row,
    erx_dom_spec_t *spec)
{
	const erx_dom_configured_t *source = &view->configured[row];

	memset(spec, 0, sizeof(*spec));
	spec->version = ERX_DOM_SPEC_VERSION;
	spec->id = id;
	spec->principal = source->principal;
	spec->origin = (erx_dom_origin_t){ ERX_DOM_CONFIGURED, row };
	spec->flags = source->flags;
	spec->release = source->release;
	spec->release_files = source->release_files;
	spec->runtime = source->runtime;
	spec->memory = source->memory;
	spec->outer = source->outer;
	spec->grant = source->grant;
	spec->spaces = source->spaces;
	spec->runtime_limits = source->runtime_limits;
	spec->lane = source->lane;
	spec->connections = source->connections;
	spec->system_lane = view->system_lane;
	spec->crash = ERX_CRASH_SIZE;
	if (source->name_len <= sizeof(spec->name)) {
		spec->name_len = source->name_len;
		memcpy(spec->name, source->name, source->name_len);
	}
	spec->args_len = source->args_len;
	spec->env_len = source->env_len;
	if (source->args_len != 0)
		memcpy(spec->strings, source->args, source->args_len);
	if (source->env_len != 0)
		memcpy(spec->strings + source->args_len, source->env, source->env_len);
}

/*
 * The partial-boot constructor: the program row and the native limits. A
 * native program's row has no name, so its name is its id in decimal.
 */
static void
dom_spec_partial(const erx_dom_view_t *view, uint32_t id, uint32_t row,
    erx_dom_spec_t *spec)
{
	const erx_dom_partial_t *source = &view->partial[row];

	memset(spec, 0, sizeof(*spec));
	spec->version = ERX_DOM_SPEC_VERSION;
	spec->id = id;
	spec->principal = view->partial_principal;
	spec->origin = (erx_dom_origin_t){ ERX_DOM_PARTIAL_BOOT, row };
	dom_decimal(id, spec);
	spec->runtime = source->runtime;
	spec->memory = source->memory;
	spec->outer = source->outer;
	spec->grant = source->grant;
	spec->runtime_limits = view->native_limits;
	spec->crash = ERX_CRASH_SIZE;
}

/* id in decimal as spec's name: at most ten digits, which ERX_DOM_NAME_MAX holds. */
static void
dom_decimal(uint32_t id, erx_dom_spec_t *spec)
{
	char digits[10];
	uint32_t count = 0;

	do {
		digits[count++] = (char)('0' + id % 10);
		id /= 10;
	} while (id != 0);
	spec->name_len = count;
	for (uint32_t at = 0; at < count; at++)
		spec->name[at] = digits[count - 1 - at];
}

static void
dom_step(erx_dom_plan_t *plan, erx_dom_step_t step)
{
	/* DOM_FIXED_STEPS_MAX and the grants rows bound nsteps, statically. */
	plan->steps[plan->nsteps++] = step;
}

/* Whether a step of this kind makes its object, rather than using it. */
static bool
dom_step_makes(erx_dom_step_kind_t kind)
{
	switch (kind) {
	case ERX_DOM_STEP_CARVE:
	case ERX_DOM_STEP_SPACE:
	case ERX_DOM_STEP_GROUP:
	case ERX_DOM_STEP_MEM:
	case ERX_DOM_STEP_BELL:
	case ERX_DOM_STEP_SLICE:
	case ERX_DOM_STEP_THREAD:
	case ERX_DOM_STEP_RESOURCE:
	case ERX_DOM_STEP_WINDOW:
	case ERX_DOM_STEP_IRQ:
	case ERX_DOM_STEP_DMA:
	case ERX_DOM_STEP_CONTIGUOUS:
		return (true);
	case ERX_DOM_STEP_IMAGE_MAP:
	case ERX_DOM_STEP_MAP:
	case ERX_DOM_STEP_INSTALL:
	case ERX_DOM_STEP_BOOTINFO:
		return (false);
	}
	return (false);
}

/* Whether a step before this point makes obj. */
static bool
dom_plan_makes(const erx_dom_plan_t *plan, erx_dom_obj_t obj)
{
	for (uint32_t index = 0; index < plan->nsteps; index++)
		if (plan->steps[index].obj == obj &&
		    dom_step_makes(plan->steps[index].kind))
			return (true);
	return (false);
}

/* The rights a row gives a domain of this specification. */
static uint32_t
dom_row_rights(const erx_dom_spec_t *spec, const erx_dom_grant_row_t *row)
{
	return (row->rights |
	    ((spec->flags & ERX_DOM_SPACES) != 0 ? row->spaces_rights : 0));
}

/*
 * A grants row applies to a creation when the specification has its
 * flags and its object exists: one the library holds, or one the plan
 * made, so a domain with no connection or no release gets no install of
 * them.
 */
static bool
dom_row_applies(const erx_dom_plan_t *plan, const erx_dom_grant_row_t *row)
{
	return (row->target == ERX_DOM_OBJ_SPACE &&
	    (row->flags & ~plan->spec.flags) == 0 &&
	    (row->obj >= ERX_DOM_OBJ_MADE_COUNT || dom_plan_makes(plan, row->obj)));
}

/*
 * The creation's steps, in the order of docs/design-system.md, "Creating
 * a domain", step 2: budgets; space; groups; boot page, crash area and
 * system connection; slice and mappings; installs; boot page write; first
 * thread. Every object is charged to the domain's own budget, its outer
 * budget, or the system connection's child carved from the outer budget.
 */
static void
dom_plan_steps(erx_dom_plan_t *plan, bool jit, uint64_t span,
    uint64_t child)
{
	const uint64_t reader = plan->reader;
	const erx_dom_spec_t *spec = &plan->spec;
	bool spaces = (spec->flags & ERX_DOM_SPACES) != 0;
	bool connected = plan->connection != 0;
	bool release = spec->release_files != 0;
	const erx_dom_grant_row_t *row;

	plan->nsteps = 0;
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_CARVE,
	    .obj = ERX_DOM_OBJ_BUDGET, .budget = ERX_DOM_OBJ_PRINCIPAL_BUDGET,
	    .size = spec->memory });
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_CARVE,
	    .obj = ERX_DOM_OBJ_OUTER, .budget = ERX_DOM_OBJ_PRINCIPAL_BUDGET,
	    .size = spec->outer });
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_SPACE,
	    .obj = ERX_DOM_OBJ_SPACE, .budget = ERX_DOM_OBJ_BUDGET,
	    .target = ERX_DOM_OBJ_SYSTEM_SPACE, .aux = ERX_DOM_OBJ_FAULT_GATE,
	    .label = spec->id, .flags = jit ? ERX_SPACE_JIT : 0 });
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_GROUP,
	    .obj = ERX_DOM_OBJ_GROUP, .budget = ERX_DOM_OBJ_BUDGET,
	    .target = ERX_DOM_OBJ_PARENT_GROUP, .flags = ERX_DOM_GROUP_GRANT });
	if (spaces)
		dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_GROUP,
		    .obj = ERX_DOM_OBJ_SPACES_GROUP, .budget = ERX_DOM_OBJ_BUDGET,
		    .target = ERX_DOM_OBJ_GROUP, .flags = ERX_DOM_GROUP_SPACES });
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_MEM,
	    .obj = ERX_DOM_OBJ_BOOTINFO, .budget = ERX_DOM_OBJ_BUDGET,
	    .size = ERX_PAGE_SIZE });
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_MEM,
	    .obj = ERX_DOM_OBJ_CRASH, .budget = ERX_DOM_OBJ_OUTER,
	    .size = spec->crash });
	if (connected) {
		dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_CARVE,
		    .obj = ERX_DOM_OBJ_SYS_BUDGET, .budget = ERX_DOM_OBJ_OUTER,
		    .size = child });
		dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_MEM,
		    .obj = ERX_DOM_OBJ_SYS_SIDE, .budget = ERX_DOM_OBJ_SYS_BUDGET,
		    .size = erx_lane_side_bytes(reader) });
		dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_MEM,
		    .obj = ERX_DOM_OBJ_DOM_SIDE, .budget = ERX_DOM_OBJ_SYS_BUDGET,
		    .size = erx_lane_side_bytes(spec->system_lane) });
		/* The system domain's bell is labelled with the connection. */
		dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_BELL,
		    .obj = ERX_DOM_OBJ_SYS_BELL, .budget = ERX_DOM_OBJ_SYS_BUDGET,
		    .target = ERX_DOM_OBJ_SYSTEM_GROUP, .label = plan->connection });
		/*
		 * The domain's takes the first label of its own counter below
		 * ERX_LABEL_SPLIT (docs/design-runtime.md, "The event table").
		 */
		dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_BELL,
		    .obj = ERX_DOM_OBJ_DOM_BELL, .budget = ERX_DOM_OBJ_SYS_BUDGET,
		    .target = ERX_DOM_OBJ_GROUP, .label = ERX_DOM_SYSTEM_LABEL });
	}
	if (release)
		dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_SLICE,
		    .obj = ERX_DOM_OBJ_SLICE, .budget = ERX_DOM_OBJ_BUDGET,
		    .index = spec->release, .count = spec->release_files });
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_IMAGE_MAP,
	    .target = ERX_DOM_OBJ_SPACE, .index = spec->runtime, .count = 1 });
	if (release)
		dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_MAP,
		    .obj = ERX_DOM_OBJ_SLICE, .target = ERX_DOM_OBJ_SPACE,
		    .size = span });
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_MAP,
	    .obj = ERX_DOM_OBJ_BOOTINFO, .target = ERX_DOM_OBJ_SPACE,
	    .size = ERX_PAGE_SIZE });

	/* Installs come only from erx_dom_grants, one per row that applies. */
	for (size_t index = 0; index < ERX_DOM_GRANTS_ROWS; index++) {
		row = &erx_dom_grants[index];
		if (dom_row_applies(plan, row))
			dom_step(plan, (erx_dom_step_t){
			    .kind = ERX_DOM_STEP_INSTALL, .obj = row->obj,
			    .target = row->target,
			    .rights = dom_row_rights(spec, row) });
	}
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_BOOTINFO,
	    .obj = ERX_DOM_OBJ_BOOTINFO });
	dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_THREAD,
	    .obj = ERX_DOM_OBJ_THREAD, .budget = ERX_DOM_OBJ_BUDGET,
	    .target = ERX_DOM_OBJ_SPACE, .aux = ERX_DOM_OBJ_GROUP });
}

erx_status_t
erx_dom_plan_request(const erx_dom_view_t *view, const erx_dom_spec_t *req,
    const erx_runtime_limits_t *limits, uint32_t given, erx_dom_plan_t *plan)
{
	const erx_dom_principal_t *principal;
	erx_dom_spec_t spec;
	erx_status_t status;

	principal = dom_principal(view, req->principal);
	if (principal == NULL || (given & ~ERX_DOM_LIMITS_ALL) != 0 ||
	    (given != 0 && limits == NULL))
		return (ERX_EINVAL);
	status = dom_spec_request(view, principal, req, limits, given, &spec);
	if (status == ERX_OK)
		status = dom_plan(&spec, view, plan);
	/* The request's strings stay in no stack copy past the call. */
	memset(&spec, 0, sizeof(spec));
	return (status);
}

erx_status_t
erx_dom_plan_configured(const erx_dom_view_t *view, uint32_t id,
    uint32_t row, erx_dom_plan_t *plan)
{
	erx_dom_spec_t spec;

	if (row >= view->nconfigured)
		return (ERX_EINVAL);
	dom_spec_configured(view, id, row, &spec);
	return (dom_plan(&spec, view, plan));
}

erx_status_t
erx_dom_plan_partial(const erx_dom_view_t *view, uint32_t id, uint32_t row,
    erx_dom_plan_t *plan)
{
	erx_dom_spec_t spec;

	if (row >= view->npartial)
		return (ERX_EINVAL);
	dom_spec_partial(view, id, row, &spec);
	return (dom_plan(&spec, view, plan));
}

/*
 * Validates a specification a constructor built (docs/design-system.md,
 * "Creating a domain", step 1) and writes its plan.
 */
static erx_status_t
dom_plan(const erx_dom_spec_t *spec, const erx_dom_view_t *view,
    erx_dom_plan_t *plan)
{
	const erx_dom_principal_t *principal;
	erx_dom_plan_t draft;
	uint64_t reader, child, span;
	erx_status_t status;
	bool jit;

	if (view->ending)
		return (ERX_EBUSY);
	if (spec->version != ERX_DOM_SPEC_VERSION ||
	    spec->id <= ERX_DOM_SYSTEM_ID || spec->id > ERX_DOM_ID_MAX ||
	    (spec->flags & ~ERX_DOM_FLAGS_KNOWN) != 0)
		return (ERX_EINVAL);
	/* The vault's domain waits for the vault (M11). */
	if ((spec->flags & ERX_DOM_SECRET) != 0)
		return (ERX_EINVAL);
	principal = dom_principal(view, spec->principal);
	if (principal == NULL)
		return (ERX_EINVAL);
	if ((status = dom_check_origin(spec, view)) != ERX_OK ||
	    (status = dom_check_files(spec, view, &jit, &span)) != ERX_OK ||
	    (status = dom_check_sizes(spec, view, &reader, &child)) != ERX_OK)
		return (status);
	if (spec->origin.kind != ERX_DOM_PARTIAL_BOOT &&
	    !dom_limits_within(&spec->runtime_limits,
	    &principal->ceiling_limits))
		return (ERX_EINVAL);
	if ((status = dom_check_grants(spec, view, principal)) != ERX_OK)
		return (status);

	memset(&draft, 0, sizeof(draft));
	draft.spec = *spec;
	draft.parent = spec->origin.kind == ERX_DOM_CONFIGURED ?
	    ERX_DOM_PARENT_SYSTEM : ERX_DOM_PARENT_PRINCIPAL;
	if ((status = dom_check_room(spec, view, principal, &draft)) != ERX_OK)
		return (status);
	draft.reader = reader;
	dom_plan_steps(&draft, jit, span, child);
	if ((status = erx_dom_plan_check(&draft)) != ERX_OK)
		return (status);
	*plan = draft;
	return (ERX_OK);
}

/*
 * The connection number after number: numbers only grow within a boot,
 * and 0 marks them spent once the last is taken.
 */
static uint32_t
dom_next_number(uint32_t number)
{
	return (number == UINT32_MAX ? 0 : number + 1);
}

erx_status_t
erx_dom_plan_record(erx_dom_view_t *view, const erx_dom_plan_t *plan)
{
	const erx_dom_spec_t *spec = &plan->spec;
	bool connected = plan->connection_row != ERX_DOM_NO_ROW;
	erx_dom_principal_t *principal;
	erx_dom_connection_t *row;
	erx_dom_t *dom;
	uint64_t carved;

	/* Everything is checked before anything is written. */
	principal = dom_principal(view, spec->principal);
	if (principal == NULL || principal->domains == UINT32_MAX ||
	    !dom_add(principal->carved, spec->memory, &carved) ||
	    !dom_add(carved, spec->outer, &carved) ||
	    plan->slot >= view->max_domains ||
	    view->domains[plan->slot].id != 0)
		return (ERX_EINVAL);
	/* A plan made against an older view may no longer leave the reserve. */
	if (spec->origin.kind == ERX_DOM_CONFIGURED &&
	    !dom_system_reserve(view, &spec->grant))
		return (ERX_EINVAL);
	/* The slot's id is 0, so this also refuses an id of 0. */
	for (uint32_t index = 0; index < view->max_domains; index++)
		if (view->domains[index].id == spec->id)
			return (ERX_EINVAL);
	/* The system connection, when there is one, takes the next number. */
	if (!connected && plan->connection != 0)
		return (ERX_EINVAL);
	if (connected && (plan->connection_row >= view->max_connections ||
	    view->connections[plan->connection_row].number != 0 ||
	    plan->connection == 0 || plan->connection != view->next_connection))
		return (ERX_EINVAL);

	dom = &view->domains[plan->slot];
	dom->id = spec->id;
	dom->principal = spec->principal;
	dom->origin = spec->origin;
	dom->state = ERX_DOM_BUILT;
	dom->flags = spec->flags;
	dom->system_connection = plan->connection;
	dom->connections = spec->connections;
	dom->grant = spec->grant;
	dom->labels = connected ? ERX_DOM_SYSTEM_LABEL : 0;
	dom->stop = (erx_dom_end_t){ .kind = ERX_DOM_END_NONE };
	dom->end = (erx_dom_end_t){ .kind = ERX_DOM_END_NONE };
	memset(&dom->record, 0, sizeof(dom->record));
	/* The sum above was checked, so its two terms cannot wrap. */
	dom->carved = spec->memory + spec->outer;
	principal->domains++;
	principal->carved = carved;
	if (connected) {
		row = &view->connections[plan->connection_row];
		row->number = plan->connection;
		row->a = ERX_DOM_SYSTEM_ID;
		row->b = spec->id;
		row->closing = false;
		view->next_connection = dom_next_number(plan->connection);
	}
	return (ERX_OK);
}

static bool
dom_carved_budget(const bool *made, erx_dom_obj_t obj)
{
	return ((obj == ERX_DOM_OBJ_BUDGET || obj == ERX_DOM_OBJ_OUTER ||
	    obj == ERX_DOM_OBJ_SYS_BUDGET) && made[obj]);
}

/* An install's object has a row of erx_dom_grants that covers it. */
static bool
dom_granted(const erx_dom_spec_t *spec, const erx_dom_step_t *step)
{
	const erx_dom_grant_row_t *row;

	for (size_t index = 0; index < ERX_DOM_GRANTS_ROWS; index++) {
		row = &erx_dom_grants[index];
		if (row->obj == step->obj && row->target == step->target &&
		    (row->flags & ~spec->flags) == 0 &&
		    (step->rights & ~dom_row_rights(spec, row)) == 0)
			return (true);
	}
	return (false);
}

/*
 * One step against what the steps before it made: what it makes is new,
 * what it uses exists, and what it charges is a budget the plan carved.
 */
static bool
dom_step_ok(const erx_dom_plan_t *plan, const erx_dom_step_t *step,
    const bool *made)
{
	erx_dom_obj_t obj = step->obj;
	bool fresh = obj < ERX_DOM_OBJ_MADE_COUNT && obj != ERX_DOM_OBJ_NONE &&
	    !made[obj];
	bool charged = dom_carved_budget(made, step->budget);

	switch (step->kind) {
	case ERX_DOM_STEP_CARVE:
		return (fresh && (obj == ERX_DOM_OBJ_BUDGET ||
		    obj == ERX_DOM_OBJ_OUTER || obj == ERX_DOM_OBJ_SYS_BUDGET) &&
		    (step->budget == ERX_DOM_OBJ_PRINCIPAL_BUDGET || charged) &&
		    step->size != 0);
	case ERX_DOM_STEP_SPACE:
		return (fresh && obj == ERX_DOM_OBJ_SPACE && charged &&
		    step->target == ERX_DOM_OBJ_SYSTEM_SPACE &&
		    step->aux == ERX_DOM_OBJ_FAULT_GATE &&
		    step->label == plan->spec.id);
	case ERX_DOM_STEP_GROUP:
		return (fresh && charged && ((obj == ERX_DOM_OBJ_GROUP &&
		    step->target == ERX_DOM_OBJ_PARENT_GROUP) ||
		    (obj == ERX_DOM_OBJ_SPACES_GROUP &&
		    step->target == ERX_DOM_OBJ_GROUP &&
		    made[ERX_DOM_OBJ_GROUP])));
	case ERX_DOM_STEP_MEM:
		return (fresh && charged && step->size != 0 &&
		    (obj == ERX_DOM_OBJ_BOOTINFO || obj == ERX_DOM_OBJ_CRASH ||
		    obj == ERX_DOM_OBJ_SYS_SIDE || obj == ERX_DOM_OBJ_DOM_SIDE));
	case ERX_DOM_STEP_BELL:
		return (fresh && charged &&
		    ((obj == ERX_DOM_OBJ_SYS_BELL &&
		    step->target == ERX_DOM_OBJ_SYSTEM_GROUP) ||
		    (obj == ERX_DOM_OBJ_DOM_BELL &&
		    step->target == ERX_DOM_OBJ_GROUP &&
		    made[ERX_DOM_OBJ_GROUP])));
	case ERX_DOM_STEP_SLICE:
		return (fresh && obj == ERX_DOM_OBJ_SLICE && charged &&
		    step->count != 0);
	case ERX_DOM_STEP_IMAGE_MAP:
		return (step->target == ERX_DOM_OBJ_SPACE &&
		    made[ERX_DOM_OBJ_SPACE]);
	case ERX_DOM_STEP_MAP:
		return ((obj == ERX_DOM_OBJ_SLICE ||
		    (obj == ERX_DOM_OBJ_BOOTINFO && step->size == ERX_PAGE_SIZE)) &&
		    step->size % ERX_PAGE_SIZE == 0 &&
		    made[obj] && step->target == ERX_DOM_OBJ_SPACE &&
		    made[ERX_DOM_OBJ_SPACE]);
	case ERX_DOM_STEP_INSTALL:
		return (obj < ERX_DOM_OBJ_COUNT && obj != ERX_DOM_OBJ_NONE &&
		    (obj >= ERX_DOM_OBJ_MADE_COUNT || made[obj]) &&
		    step->target == ERX_DOM_OBJ_SPACE &&
		    made[ERX_DOM_OBJ_SPACE] && dom_granted(&plan->spec, step));
	case ERX_DOM_STEP_BOOTINFO:
		return (obj == ERX_DOM_OBJ_BOOTINFO && made[obj]);
	case ERX_DOM_STEP_THREAD:
		return (fresh && obj == ERX_DOM_OBJ_THREAD && charged &&
		    step->target == ERX_DOM_OBJ_SPACE &&
		    made[ERX_DOM_OBJ_SPACE] && step->aux == ERX_DOM_OBJ_GROUP &&
		    made[ERX_DOM_OBJ_GROUP]);
	/* A device's objects are erx_dom_plan_device_give's alone. */
	case ERX_DOM_STEP_RESOURCE:
	case ERX_DOM_STEP_WINDOW:
	case ERX_DOM_STEP_IRQ:
	case ERX_DOM_STEP_DMA:
	case ERX_DOM_STEP_CONTIGUOUS:
		return (false);
	}
	return (false);
}

erx_status_t
erx_dom_principal_check(const erx_dom_view_t *view,
    const erx_dom_principal_t *config, erx_dom_principal_t *record)
{
	uint64_t rate;

	if (config->number == 0)
		return (ERX_EINVAL);
	if (dom_principal(view, config->number) != NULL)
		return (ERX_EEXIST);
	/* A ceiling within itself is a profile a runtime can start with. */
	if (config->memory == 0 || !dom_page_aligned(config->memory) ||
	    !dom_grant_rate(&config->share, &rate) ||
	    !dom_limits_within(&config->ceiling_limits,
	    &config->ceiling_limits) ||
	    !dom_limits_within(&config->default_limits,
	    &config->ceiling_limits))
		return (ERX_EINVAL);
	*record = *config;
	record->carved = 0;
	record->domains = 0;
	return (ERX_OK);
}

erx_status_t
erx_dom_plan_check(const erx_dom_plan_t *plan)
{
	bool made[ERX_DOM_OBJ_MADE_COUNT] = { false };
	const erx_dom_step_t *step;

	if (plan->nsteps > ERX_DOM_PLAN_STEPS_MAX)
		return (ERX_EINVAL);
	for (uint32_t index = 0; index < plan->nsteps; index++) {
		step = &plan->steps[index];
		if (step->budget >= ERX_DOM_OBJ_COUNT ||
		    step->target >= ERX_DOM_OBJ_COUNT ||
		    step->aux >= ERX_DOM_OBJ_COUNT ||
		    !dom_step_ok(plan, step, made))
			return (ERX_EINVAL);
		if (dom_step_makes(step->kind))
			made[step->obj] = true;
	}
	return (ERX_OK);
}

erx_dom_undo_kind_t
erx_dom_step_undo(erx_dom_step_kind_t kind)
{
	switch (kind) {
	case ERX_DOM_STEP_CARVE:
	case ERX_DOM_STEP_RESOURCE:
	case ERX_DOM_STEP_WINDOW:
	case ERX_DOM_STEP_IRQ:
	case ERX_DOM_STEP_DMA:
	case ERX_DOM_STEP_CONTIGUOUS:
		return (ERX_DOM_UNDO_DESTROY);
	case ERX_DOM_STEP_SPACE:
	case ERX_DOM_STEP_GROUP:
	case ERX_DOM_STEP_MEM:
	case ERX_DOM_STEP_BELL:
	case ERX_DOM_STEP_SLICE:
	case ERX_DOM_STEP_IMAGE_MAP:
	case ERX_DOM_STEP_MAP:
	case ERX_DOM_STEP_INSTALL:
	case ERX_DOM_STEP_BOOTINFO:
	case ERX_DOM_STEP_THREAD:
		return (ERX_DOM_UNDO_BY_BUDGET);
	}
	return (ERX_DOM_UNDO_BY_BUDGET);
}

uint32_t
erx_dom_steps_undo(const erx_dom_step_t *steps, uint32_t nsteps,
    uint32_t applied, erx_dom_obj_t *undo)
{
	uint32_t count = 0;

	if (applied > nsteps)
		applied = nsteps;
	for (uint32_t index = applied; index > 0; index--)
		if (erx_dom_step_undo(steps[index - 1].kind) ==
		    ERX_DOM_UNDO_DESTROY)
			undo[count++] = steps[index - 1].obj;
	return (count);
}

uint32_t
erx_dom_plan_undo(const erx_dom_plan_t *plan, uint32_t applied,
    erx_dom_obj_t *undo)
{
	return (erx_dom_steps_undo(plan->steps, plan->nsteps, applied, undo));
}
