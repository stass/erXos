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

#include "erx/abi_reader.h"
#include "erx/dom.h"
#include "erx/lane.h"

/* The parts of an erx_grant_t rate: thousandths of one CPU. */
#define DOM_MILLI	UINT64_C(1000)

#define DOM_WRITER	(ERX_HR_READ | ERX_HR_WRITE | ERX_HR_MAP)
#define DOM_READER	(ERX_HR_READ | ERX_HR_MAP)

/*
 * A party of a connection gets its own side to write, the peer's to read
 * and the peer's bell to ring; its own bell stays the library's, bound to
 * its group, and it learns only the bell's label. A pixel area's writer
 * gets it to write and its reader to read, as a side. A device's holder gets
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
	{ ERX_DOM_OBJ_AREA_A, ERX_DOM_OBJ_SPACE_A, 0, DOM_WRITER, 0 },
	{ ERX_DOM_OBJ_AREA_A, ERX_DOM_OBJ_SPACE_B, 0, DOM_READER, 0 },
	{ ERX_DOM_OBJ_AREA_B, ERX_DOM_OBJ_SPACE_B, 0, DOM_WRITER, 0 },
	{ ERX_DOM_OBJ_AREA_B, ERX_DOM_OBJ_SPACE_A, 0, DOM_READER, 0 },
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
 * Installs add at most one per grants row, and gives one GIVE step each.
 */
#define DOM_FIXED_STEPS_MAX	18u
_Static_assert(DOM_FIXED_STEPS_MAX + ERX_DOM_GRANTS_ROWS + ERX_DOM_GIVES_MAX <=
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
		    uint32_t, erx_dom_pid_t, erx_dom_spec_t *);
static void	dom_spec_partial(const erx_dom_view_t *, uint32_t, uint32_t,
		    erx_dom_spec_t *);
static bool	dom_session_words(uint32_t, const char *, uint32_t, erx_dom_spec_t *);
static void	dom_spec_session(const erx_dom_view_t *, uint32_t, uint32_t, uint32_t, uint64_t,
		    const char *, uint32_t, const char *, uint32_t, erx_dom_pid_t, erx_dom_spec_t *);
static bool	dom_apps_hold(const erx_dom_view_t *, uint64_t);
static bool	dom_display_name(const char *, uint32_t);
static void	dom_decimal(uint32_t, erx_dom_spec_t *);
static bool	dom_word_put(char *, size_t, size_t *, const char *, const char *, size_t);
static bool	dom_number_put(char *, size_t, size_t *, const char *, uint32_t);
static bool	dom_display_words(const erx_dom_display_t *, erx_dom_spec_t *);
static erx_status_t dom_plan_in(const erx_dom_spec_t *, const erx_dom_view_t *,
		    erx_dom_plan_t *, bool *, uint64_t *, uint64_t *, uint64_t *);
static erx_status_t dom_plan_gives(const erx_dom_view_t *, erx_dom_plan_t *);
static erx_status_t dom_plan(const erx_dom_spec_t *, const erx_dom_view_t *,
		    erx_dom_plan_t *);
static erx_status_t dom_check_files(const erx_dom_spec_t *,
		    const erx_dom_view_t *, bool *, uint64_t *);
static erx_status_t dom_check_sizes(const erx_dom_spec_t *,
		    const erx_dom_view_t *, uint64_t *, uint64_t *);
static erx_status_t dom_check_grants(const erx_dom_spec_t *,
		    const erx_dom_view_t *, const erx_dom_principal_t *);
static bool	dom_remains_hold(const erx_dom_view_t *, uint32_t);
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
 * A child grant fits a parent when its slice is one its threads can take
 * as their quantum, ERX_SLICE_MIN_US .. ERX_SLICE_MAX_US, whatever the
 * parent's (a share of the manifest holds it by the reader's range rules,
 * a request only by this check), and it asks for no CPU, urgency, rate or
 * group feature the parent lacks.
 */
static bool
dom_grant_fits(const erx_grant_t *child, const erx_grant_t *parent)
{
	uint64_t child_rate, parent_rate;

	if (child->slice_us < ERX_SLICE_MIN_US ||
	    child->slice_us > ERX_SLICE_MAX_US ||
	    !dom_grant_rate(child, &child_rate) ||
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
 * with its own budget, and a retired domain has no record, so neither
 * counts and nothing has to be taken back.
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
 * The data area of the lane the domain reads from the system domain: its
 * lane alone, since connection-control records travel in the control
 * table after it (docs/design-domains.md, "The control table").
 */
static bool
dom_reader_lane(const erx_dom_spec_t *spec, uint64_t *area)
{
	if (erx_lane_ctl_side_bytes(spec->lane, spec->connections) == 0)
		return (false);
	*area = spec->lane;
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
	case ERX_DOM_SESSION:
		/* A session makes its programs as sub-spaces (property 14). */
		return (spec->origin.record < view->ntemplates &&
		    (spec->flags & ERX_DOM_SPACES) != 0 ? ERX_OK : ERX_EINVAL);
	default:
		return (ERX_EINVAL);
	}
}

/*
 * The runtime is an accepted image and the release a slice of ordinary
 * files and empty directories. A partial-boot domain runs a native program with no release. A
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
		if ((file->kind != ERX_ENTRY_FILE &&
		    file->kind != ERX_ENTRY_DIRECTORY) ||
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
		sys_side = erx_lane_ctl_side_bytes(*reader, spec->connections);
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
 * Whether a retired domain's remains hold id, which the connection rows
 * naming it still mean, so no new domain may take it.
 */
static bool
dom_remains_hold(const erx_dom_view_t *view, uint32_t id)
{
	for (uint32_t index = 0; id != 0 && index < view->max_remains; index++)
		if (view->remains[index].id == id)
			return (true);
	return (false);
}

/*
 * Room for the domain: a free record, an id neither a record nor remains
 * hold, the principal's quota, its budget and, for an app entry, the apps
 * budget beside every app's sessions (dom_apps_hold),
 * and a free connection row for the system connection. Fills the plan's
 * slot and connection.
 */
static erx_status_t
dom_check_room(const erx_dom_spec_t *spec, const erx_dom_view_t *view,
    const erx_dom_principal_t *principal, erx_dom_plan_t *plan)
{
	uint64_t carved, need;

	plan->slot = view->max_domains;
	if (dom_remains_hold(view, spec->id))
		return (ERX_EINVAL);
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
	if (!dom_add(spec->memory, spec->outer, &need) ||
	    !dom_add(principal->carved, need, &carved) ||
	    carved > principal->memory ||
	    (erx_dom_app_principal(view, principal->number) && !dom_apps_hold(view, need)))
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
	/* A principal's request names no limits record, so no band above the lowest. */
	spec->band = ERX_BAND_APP;
	spec->space_band = ERX_BAND_APP;
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
 * The boot page's flags of a plan: det when the machine runs in deterministic
 * mode. No plan sets supervised: a supervised domain's code server waits
 * for its start load (docs/design-live.md, "The code server"), and nothing
 * sends start loads until erx_code's targets are built (docs/todo-domains.md,
 * "code service, start loads to supervised domains"). Leaving it clear fails
 * safe: the code server starts the domain at once on its release, and nothing
 * is sent a start load it would wait for.
 */
uint32_t
erx_dom_plan_boot_flags(const erx_dom_view_t *view ERX_UNUSED,
    const erx_dom_plan_t *plan ERX_UNUSED, bool det)
{
	return (det ? ERX_BOOT_DET : 0);
}

bool
erx_dom_from_row(const erx_dom_origin_t *origin, uint32_t row)
{
	return (origin->kind == ERX_DOM_CONFIGURED && origin->record == row);
}

/*
 * The configured constructor: everything from the checked manifest row,
 * whose name, arguments and environment, and a display domain's display
 * words (dom_display_words), fit the spec (boot_configured holds the view's
 * rows to that). The bound on the name is checked again here, as
 * the copy's own: a name that did not fit would be left empty, which
 * planning refuses.
 */
static void
dom_spec_configured(const erx_dom_view_t *view, uint32_t id, uint32_t row,
    erx_dom_pid_t domain_pid, erx_dom_spec_t *spec)
{
	const erx_dom_configured_t *source = &view->configured[row];

	memset(spec, 0, sizeof(*spec));
	spec->version = ERX_DOM_SPEC_VERSION;
	spec->id = id;
	spec->principal = source->principal;
	spec->domain_pid = domain_pid;
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
	/* Its sub-spaces are its own work, a driver's native shim among them. */
	spec->band = source->band;
	spec->space_band = source->band;
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
	if (source->display.name_len != 0 && !dom_display_words(&source->display, spec))
		spec->name_len = 0;
}

/*
 * A display domain's display words after its own environment
 * (docs/design-display.md, "A display's session"), the keys of
 * ERX_DOM_DISPLAY_WORDS_MAX in its order, the policy and the palette as
 * their members' names. False, with the environment unchanged, when they
 * overrun the strings, which the view's reserve for them
 * (ERX_DOM_DISPLAY_WORDS_MAX) rules out, or when the policy or the palette
 * is no member, which the view refuses; the caller then
 * leaves the name empty, which planning refuses.
 */
static bool
dom_display_words(const erx_dom_display_t *display, erx_dom_spec_t *spec)
{
	const char *policy = erx_mf_display_policy_name(display->policy);
	const char *palette = erx_mf_display_palette_name(display->palette);
	const size_t start = (size_t)spec->args_len + spec->env_len;
	size_t used = start;

	if (start > sizeof(spec->strings) || policy == NULL || palette == NULL ||
	    !dom_word_put(spec->strings, sizeof(spec->strings), &used, ERX_DISPLAY_KEY_STRING "=", display->name, display->name_len) ||
	    !dom_word_put(spec->strings, sizeof(spec->strings), &used, ERX_DISPLAY_POLICY_KEY_STRING "=", policy, strlen(policy)) ||
	    !dom_number_put(spec->strings, sizeof(spec->strings), &used, ERX_DISPLAY_IDLE_DIM_KEY_STRING "=", display->idle_dim_s) ||
	    !dom_number_put(spec->strings, sizeof(spec->strings), &used, ERX_DISPLAY_IDLE_OFF_KEY_STRING "=", display->idle_off_s) ||
	    !dom_word_put(spec->strings, sizeof(spec->strings), &used, ERX_DISPLAY_PALETTE_KEY_STRING "=", palette, strlen(palette))) {
		if (start <= sizeof(spec->strings))
			memset(spec->strings + start, 0, sizeof(spec->strings) - start);
		return (false);
	}
	spec->env_len += (uint32_t)(used - start);
	return (true);
}

/* The word NAME VALUE and its NUL at words + *used, or false when they overrun capacity. */
static bool
dom_word_put(char *words, size_t capacity, size_t *used, const char *name, const char *value, size_t value_len)
{
	const size_t name_len = strlen(name);

	if (*used > capacity || capacity - *used < name_len + value_len + 1)
		return (false);
	memcpy(words + *used, name, name_len);
	memcpy(words + *used + name_len, value, value_len);
	words[*used + name_len + value_len] = '\0';
	*used += name_len + value_len + 1;
	return (true);
}

/* The word NAME and value in decimal, as dom_word_put. */
static bool
dom_number_put(char *words, size_t capacity, size_t *used, const char *name, uint32_t value)
{
	char digits[10];
	size_t count = sizeof(digits);

	do {
		digits[--count] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	return (dom_word_put(words, capacity, used, name, digits + count, sizeof(digits) - count));
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
	spec->band = view->native_band;
	spec->space_band = view->native_band;
}

/*
 * The session constructor: everything but the id, the pid, the name, the
 * principal and the memory is session template `template`'s and its
 * resolved limits'; the principal and memory are the template's own or,
 * for an app's session, its entry's and its record's
 * (erx_dom_plan_app_session); the name is the one the domain service
 * chose, and its environment the template's with the session's principal
 * and default display after it
 * (dom_session_words). The template's arguments and environment, with
 * those words at their longest, fit the spec's strings, which
 * boot_templates checked when it built the view. A name that does not fit
 * is left empty, which planning refuses, as it refuses an empty name of a
 * configured row; so is the name of a session whose words do not fit.
 */
static void
dom_spec_session(const erx_dom_view_t *view, uint32_t id, uint32_t template,
    uint32_t principal, uint64_t memory, const char *name, uint32_t name_len,
    const char *display, uint32_t display_len, erx_dom_pid_t domain_pid, erx_dom_spec_t *spec)
{
	const erx_dom_template_t *source = &view->templates[template];

	memset(spec, 0, sizeof(*spec));
	spec->version = ERX_DOM_SPEC_VERSION;
	spec->id = id;
	spec->principal = principal;
	spec->domain_pid = domain_pid;
	spec->origin = (erx_dom_origin_t){ ERX_DOM_SESSION, template };
	spec->flags = source->flags;
	spec->release = source->release;
	spec->release_files = source->release_files;
	spec->runtime = source->runtime;
	spec->memory = memory;
	spec->outer = source->outer;
	spec->grant = source->grant;
	spec->spaces = source->spaces;
	spec->runtime_limits = source->runtime_limits;
	spec->lane = source->lane;
	spec->connections = source->connections;
	spec->system_lane = view->system_lane;
	spec->crash = ERX_CRASH_SIZE;
	/* Its programs are the user's code. */
	spec->band = source->band;
	spec->space_band = ERX_BAND_APP;
	if (name != NULL && name_len <= sizeof(spec->name)) {
		spec->name_len = name_len;
		memcpy(spec->name, name, name_len);
	}
	spec->args_len = source->args_len;
	spec->env_len = source->env_len;
	if (source->args_len != 0)
		memcpy(spec->strings, source->args, source->args_len);
	if (source->env_len != 0)
		memcpy(spec->strings + source->args_len, source->env, source->env_len);
	if (!dom_session_words(principal, display, display_len, spec))
		spec->name_len = 0;
}

/*
 * A session's words after its environment (ERX_DOM_SESSION_WORDS_MAX):
 * principal=N, its principal's number (docs/design-programs.md, "Users
 * and files"), and display=NAME, its default display
 * (docs/design-display.md, "Choosing a display"), which a display_len of 0
 * leaves out. False when the words overrun the strings, which the view's
 * reserve for them rules out; the caller then leaves the name empty.
 */
static bool
dom_session_words(uint32_t principal, const char *display, uint32_t display_len, erx_dom_spec_t *spec)
{
	const size_t start = (size_t)spec->args_len + spec->env_len;
	size_t used = start;

	if (start > sizeof(spec->strings) ||
	    !dom_number_put(spec->strings, sizeof(spec->strings), &used, ERX_PRINCIPAL_KEY_STRING "=", principal) ||
	    (display_len != 0 &&
	    !dom_word_put(spec->strings, sizeof(spec->strings), &used, ERX_DISPLAY_KEY_STRING "=", display, display_len)))
		return (false);
	spec->env_len += (uint32_t)(used - start);
	return (true);
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
	case ERX_DOM_STEP_MSI:
	case ERX_DOM_STEP_DMA:
	case ERX_DOM_STEP_CONTIGUOUS:
		return (true);
	case ERX_DOM_STEP_IMAGE_MAP:
	case ERX_DOM_STEP_MAP:
	case ERX_DOM_STEP_INSTALL:
	case ERX_DOM_STEP_BOOTINFO:
	case ERX_DOM_STEP_GIVE:
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
		    .size = erx_lane_ctl_side_bytes(reader, spec->connections) });
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
	/* Each give before the boot page, which names what it installed. */
	for (uint32_t give = 0; give < plan->ngives; give++)
		dom_step(plan, (erx_dom_step_t){ .kind = ERX_DOM_STEP_GIVE,
		    .index = give });
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
    uint32_t row, erx_dom_pid_t domain_pid, erx_dom_plan_t *plan)
{
	erx_dom_spec_t spec;

	if (row >= view->nconfigured)
		return (ERX_EINVAL);
	dom_spec_configured(view, id, row, domain_pid, &spec);
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

erx_status_t
erx_dom_plan_session(const erx_dom_view_t *view, uint32_t id,
    uint32_t template, const char *name, uint32_t name_len,
    const char *display, uint32_t display_len,
    erx_dom_pid_t domain_pid, erx_dom_plan_t *plan)
{
	const erx_dom_template_t *source;
	erx_dom_spec_t spec;

	if (template >= view->ntemplates || !dom_display_name(display, display_len))
		return (ERX_EINVAL);
	/* The app template names no principal, so its plan finds none and is refused. */
	source = &view->templates[template];
	dom_spec_session(view, id, template, source->principal, source->memory, name, name_len,
	    display, display_len, domain_pid, &spec);
	return (dom_plan(&spec, view, plan));
}

erx_status_t
erx_dom_plan_app_session(const erx_dom_view_t *view, uint32_t id,
    uint32_t entry, uint64_t memory, const char *name, uint32_t name_len,
    const char *display, uint32_t display_len, erx_dom_pid_t domain_pid,
    erx_dom_plan_t *plan)
{
	const erx_dom_apps_t *apps = &view->apps;
	erx_dom_spec_t spec;

	if (entry >= apps->max || memory > apps->memory ||
	    !dom_display_name(display, display_len))
		return (ERX_EINVAL);
	dom_spec_session(view, id, apps->template, apps->first + entry, memory, name, name_len,
	    display, display_len, domain_pid, &spec);
	/* An app's code is untrusted, so it never runs above an interactive domain, whatever the template's record names. */
	spec.band = ERX_BAND_APP;
	return (dom_plan(&spec, view, plan));
}

/*
 * Whether display_len bytes of display can be a session's display word: at
 * most a name's length, and no NUL, which would end the word and start
 * another. A length of 0 is no display.
 */
static bool
dom_display_name(const char *display, uint32_t display_len)
{
	return (display_len <= ERX_DOM_NAME_MAX &&
	    (display_len == 0 || memchr(display, '\0', display_len) == NULL));
}

erx_status_t
erx_dom_apps_place(erx_dom_view_t *view, uint32_t template, uint64_t memory,
    uint32_t max)
{
	const uint32_t first = view->nprincipals + 1;
	const erx_dom_template_t *source;
	erx_dom_principal_t config;

	if (view->apps.max != 0 || max == 0 || max > ERX_APPS_MAX_LIMIT ||
	    template >= view->ntemplates || view->templates[template].principal != 0 ||
	    memory == 0 || !dom_page_aligned(memory))
		return (ERX_EINVAL);
	source = &view->templates[template];
	for (uint32_t entry = 0; entry < max; entry++) {
		config = (erx_dom_principal_t){ .number = first + entry, .memory = memory,
		    .domains_max = 1, .share = source->grant,
		    .default_limits = source->runtime_limits,
		    .ceiling_limits = source->runtime_limits };
		if (erx_dom_principal_check(view, &config, &view->principals[first - 1 + entry]) != ERX_OK) {
			view->nprincipals = first - 1;
			return (ERX_EINVAL);
		}
		/* The next entry's check sees this one's number taken. */
		view->nprincipals = first + entry;
	}
	view->apps = (erx_dom_apps_t){ .template = template, .first = first, .max = max, .memory = memory };
	return (ERX_OK);
}

bool
erx_dom_app_principal(const erx_dom_view_t *view, uint32_t number)
{
	return (view->apps.max != 0 && number >= view->apps.first &&
	    number - view->apps.first < view->apps.max);
}

/*
 * Whether the apps budget holds `more` bytes beside what every app entry's
 * domains carve now: each entry's budget may reach the whole apps budget,
 * so what the entries carve together is what the apps budget bounds.
 */
static bool
dom_apps_hold(const erx_dom_view_t *view, uint64_t more)
{
	const erx_dom_principal_t *entry = &view->principals[view->apps.first - 1];
	uint64_t carved = more;

	for (uint32_t index = 0; index < view->apps.max; index++)
		if (!dom_add(carved, entry[index].carved, &carved))
			return (false);
	return (carved <= view->apps.memory);
}

/*
 * Validates a specification a constructor built (docs/design-system.md,
 * "Creating a domain", step 1) and writes its plan.
 */
static erx_status_t
dom_plan(const erx_dom_spec_t *spec, const erx_dom_view_t *view,
    erx_dom_plan_t *plan)
{
	uint64_t reader, child, span;
	erx_status_t status;
	bool jit;

	status = dom_plan_in(spec, view, plan, &jit, &span, &child, &reader);
	if (status == ERX_OK) {
		plan->reader = reader;
		dom_plan_steps(plan, jit, span, child);
		status = erx_dom_plan_check(plan);
	}
	if (status != ERX_OK)
		memset(plan, 0, sizeof(*plan));
	return (status);
}

/*
 * dom_plan's checks, with the plan's specification, parent, slot,
 * connection and gives written in place as they pass.
 */
static erx_status_t
dom_plan_in(const erx_dom_spec_t *spec, const erx_dom_view_t *view,
    erx_dom_plan_t *plan, bool *jit, uint64_t *span, uint64_t *child,
    uint64_t *reader)
{
	const erx_dom_principal_t *principal;
	erx_status_t status;

	if (view->ending)
		return (ERX_EBUSY);
	if (spec->version != ERX_DOM_SPEC_VERSION ||
	    spec->id <= ERX_SYSTEM_DOMAIN_ID || spec->id > ERX_DOM_ID_MAX ||
	    (spec->flags & ~ERX_DOM_FLAGS_KNOWN) != 0)
		return (ERX_EINVAL);
	/* The vault's domain waits for the vault (M11). */
	if ((spec->flags & ERX_DOM_SECRET) != 0)
		return (ERX_EINVAL);
	principal = dom_principal(view, spec->principal);
	if (principal == NULL)
		return (ERX_EINVAL);
	if ((status = dom_check_origin(spec, view)) != ERX_OK ||
	    (status = dom_check_files(spec, view, jit, span)) != ERX_OK ||
	    (status = dom_check_sizes(spec, view, reader, child)) != ERX_OK)
		return (status);
	if (spec->origin.kind != ERX_DOM_PARTIAL_BOOT &&
	    !dom_limits_within(&spec->runtime_limits,
	    &principal->ceiling_limits))
		return (ERX_EINVAL);
	if ((status = dom_check_grants(spec, view, principal)) != ERX_OK)
		return (status);

	memset(plan, 0, sizeof(*plan));
	plan->spec = *spec;
	plan->parent = spec->origin.kind == ERX_DOM_CONFIGURED ?
	    ERX_DOM_PARENT_SYSTEM : ERX_DOM_PARENT_PRINCIPAL;
	if ((status = dom_check_room(spec, view, principal, plan)) != ERX_OK)
		return (status);
	return (spec->origin.kind == ERX_DOM_CONFIGURED ? dom_plan_gives(view, plan) : ERX_OK);
}

/*
 * A configured domain's gives (docs/design-system.md, "Devices"): one per
 * unit the manifest places on its row, in the order of each unit's first
 * catalogue entry, each planned by erx_dom_plan_unit_give, the one planner
 * of a unit's objects, for the domain the plan makes. ERX_ELIMIT past
 * ERX_DOM_DEVICES_MAX devices in all, which the boot view keeps every row
 * within; otherwise the first give's refusal.
 */
static erx_status_t
dom_plan_gives(const erx_dom_view_t *view, erx_dom_plan_t *plan)
{
	const erx_dom_device_entry_t *entry;
	erx_status_t status;
	uint32_t devices = 0;
	bool given;

	for (uint32_t index = 0; index < view->ndevices; index++) {
		entry = &view->devices[index];
		if (!erx_dom_from_row(&plan->spec.origin, entry->row))
			continue;
		given = false;
		for (uint32_t at = 0; at < plan->ngives; at++)
			given = given || plan->gives[at].unit == entry->unit;
		if (given)
			continue;
		if (plan->ngives == ERX_DOM_GIVES_MAX)
			return (ERX_ELIMIT);
		status = erx_dom_plan_unit_give(view, plan, entry->unit,
		    &plan->gives[plan->ngives]);
		if (status != ERX_OK)
			return (status);
		devices += plan->gives[plan->ngives++].ndevices;
		if (devices > ERX_DOM_DEVICES_MAX)
			return (ERX_ELIMIT);
	}
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
	if (dom_remains_hold(view, spec->id))
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
	memset(&dom->fault, 0, sizeof(dom->fault));
	dom->end = (erx_dom_end_t){ .kind = ERX_DOM_END_NONE };
	memset(&dom->record, 0, sizeof(dom->record));
	/* The sum above was checked, so its two terms cannot wrap. */
	dom->own_bytes = spec->memory;
	dom->outer_bytes = spec->outer;
	principal->domains++;
	principal->carved = carved;
	if (connected) {
		row = &view->connections[plan->connection_row];
		row->number = plan->connection;
		row->a = ERX_SYSTEM_DOMAIN_ID;
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
	/* A device's objects are a give's alone, which a GIVE step applies. */
	case ERX_DOM_STEP_RESOURCE:
	case ERX_DOM_STEP_WINDOW:
	case ERX_DOM_STEP_IRQ:
	case ERX_DOM_STEP_MSI:
	case ERX_DOM_STEP_DMA:
	case ERX_DOM_STEP_CONTIGUOUS:
		return (false);
	case ERX_DOM_STEP_GIVE:
		/* A give of this domain, on its own budget into its own space. */
		return (step->index < plan->ngives && step->index < ERX_DOM_GIVES_MAX &&
		    plan->spec.origin.kind == ERX_DOM_CONFIGURED &&
		    made[ERX_DOM_OBJ_BUDGET] && made[ERX_DOM_OBJ_SPACE] &&
		    plan->gives[step->index].holder == plan->spec.id &&
		    plan->gives[step->index].slot == plan->slot &&
		    erx_dom_unit_check(&plan->gives[step->index]) == ERX_OK);
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

/*
 * The creation's gives hold ERX_DOM_DEVICES_MAX devices at most in all,
 * each in one give alone, and one give per unit, so no object of a device
 * is planned twice. Each give's own count is read within its array.
 */
static bool
dom_gives_apart(const erx_dom_plan_t *plan)
{
	const erx_dom_unit_plan_t *give, *other;
	uint32_t devices = 0;

	for (uint32_t at = 0; at < plan->ngives; at++) {
		give = &plan->gives[at];
		if (give->ndevices > ERX_DOM_DEVICES_MAX ||
		    (devices += give->ndevices) > ERX_DOM_DEVICES_MAX)
			return (false);
		for (uint32_t before = 0; before < at; before++) {
			other = &plan->gives[before];
			if (other->unit == give->unit)
				return (false);
			for (uint32_t d = 0; d < give->ndevices; d++)
				for (uint32_t e = 0; e < other->ndevices; e++)
					if (give->devices[d].index == other->devices[e].index)
						return (false);
		}
	}
	return (true);
}

erx_status_t
erx_dom_plan_check(const erx_dom_plan_t *plan)
{
	bool made[ERX_DOM_OBJ_MADE_COUNT] = { false };
	const erx_dom_step_t *step;
	uint32_t gives = 0;

	if (plan->nsteps > ERX_DOM_PLAN_STEPS_MAX || plan->ngives > ERX_DOM_GIVES_MAX ||
	    !dom_gives_apart(plan))
		return (ERX_EINVAL);
	for (uint32_t index = 0; index < plan->nsteps; index++) {
		step = &plan->steps[index];
		/* Every give once, in order, and all before the boot page names them. */
		if ((step->kind == ERX_DOM_STEP_GIVE && step->index != gives++) ||
		    (step->kind == ERX_DOM_STEP_BOOTINFO && gives != plan->ngives))
			return (ERX_EINVAL);
		if (step->budget >= ERX_DOM_OBJ_COUNT ||
		    step->target >= ERX_DOM_OBJ_COUNT ||
		    step->aux >= ERX_DOM_OBJ_COUNT ||
		    !dom_step_ok(plan, step, made))
			return (ERX_EINVAL);
		if (dom_step_makes(step->kind))
			made[step->obj] = true;
	}
	return (gives == plan->ngives ? ERX_OK : ERX_EINVAL);
}

erx_dom_undo_kind_t
erx_dom_step_undo(erx_dom_step_kind_t kind)
{
	switch (kind) {
	case ERX_DOM_STEP_CARVE:
	case ERX_DOM_STEP_RESOURCE:
	case ERX_DOM_STEP_WINDOW:
	case ERX_DOM_STEP_IRQ:
	case ERX_DOM_STEP_MSI:
	case ERX_DOM_STEP_DMA:
		return (ERX_DOM_UNDO_DESTROY);
	case ERX_DOM_STEP_CONTIGUOUS:
		return (ERX_DOM_UNDO_KEEP);
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
	case ERX_DOM_STEP_GIVE:
		/*
		 * Its objects die with the holder's budget, but the apply
		 * phase closes their handles and keeps a fresh memory by
		 * the give's own steps' undo, erx_dom_unit_undo.
		 */
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

/*
 * PCIe functions' layouts (docs/design-pcie.md, "The catalogue and
 * gives"). A report is refused through pci_refuse, which names the record
 * and field; nothing is written to the bridge before every check passed.
 */

#define PCI_BARS	(sizeof(((erx_pcie_function_t *)NULL)->bars) / sizeof(erx_pcie_bar_t))

static erx_status_t
pci_refuse(erx_dom_pci_refusal_t *refusal, uint32_t record, const char *field)
{
	*refusal = (erx_dom_pci_refusal_t){ .record = record, .field = field };
	return (ERX_EINVAL);
}

/*
 * A report refused whole: the latest report is refused, so no earlier one
 * gives a function. A bridge with no layouts, the only one a placement
 * check refuses for, has nothing to unconfirm.
 */
static void
pci_unconfirm(erx_dom_pci_bridge_t *bridge)
{
	for (uint32_t at = 0; at < bridge->nlayouts; at++)
		bridge->layouts[at].confirmed = false;
}

/*
 * A BAR's span: its hardware size, 2^size_log2, in whole pages. A size_log2 past
 * ERX_PCIE_BAR_SIZE_LOG2_MAX, which a report refuses on a placed BAR, is taken
 * at that bound.
 */
static uint64_t
pci_span(const erx_pcie_bar_t *bar)
{
	const uint64_t size = UINT64_C(1) << (bar->size_log2 < ERX_PCIE_BAR_SIZE_LOG2_MAX ? bar->size_log2 :
	    ERX_PCIE_BAR_SIZE_LOG2_MAX);

	return (size < ERX_PAGE_SIZE ? ERX_PAGE_SIZE : size);
}

static bool
pci_placed(const erx_pcie_bar_t *bar)
{
	return (bar->kind == ERX_PCIE_BAR_MEMORY && (bar->flags & ERX_PCIE_BAR_PLACED) != 0);
}

bool
erx_dom_pci_bar_cpu(const erx_pcie_bridge_t *facts, const erx_pcie_bar_t *bar, erx_dom_range_t *cpu)
{
	const uint64_t span = pci_span(bar);

	if (!pci_placed(bar))
		return (false);
	for (uint32_t at = 0; at < ERX_PCIE_WINDOWS_MAX; at++) {
		const erx_pcie_window_t *const window = &facts->windows[at];

		/* The tree's windows do not wrap in PCI or CPU space (erx_dt_bridge). */
		if (window->size == 0 || (window->flags & ERX_PCIE_WINDOW_IO) != 0 || bar->address < window->pci ||
		    bar->address - window->pci > window->size || span > window->size - (bar->address - window->pci))
			continue;
		*cpu = (erx_dom_range_t){ .base = window->cpu + (bar->address - window->pci), .size = span };
		return (true);
	}
	return (false);
}

static bool
pci_ranges_meet(erx_dom_range_t a, erx_dom_range_t b)
{
	return (a.base <= b.base + (b.size - 1) && b.base <= a.base + (a.size - 1));
}

/*
 * Whether a BAR's kind, flags and size are in their sets
 * (abi/formats/pcie.txt): its true size up to ERX_PCIE_BAR_SIZE_LOG2_WIDE,
 * so an unplaced function reports a BAR too large to place as it is; only
 * a memory BAR marked placed, held to ERX_PCIE_BAR_SIZE_LOG2_MAX, and a
 * placed 32-bit one ending within 4 GiB. A memory BAR of a ready function
 * is placed, since the walk reports one it did not place unplaced.
 */
static bool
pci_bar_in_sets(const erx_pcie_bar_t *bar, bool ready)
{
	const bool placed = (bar->flags & ERX_PCIE_BAR_PLACED) != 0;

	if (erx_pcie_bar_kind_name(bar->kind) == NULL || (bar->flags & ~ERX_PCIE_BAR_FLAGS_KNOWN) != 0 ||
	    bar->size_log2 > ERX_PCIE_BAR_SIZE_LOG2_WIDE)
		return (false);
	if (!placed)
		return (!ready || bar->kind != ERX_PCIE_BAR_MEMORY);
	if (bar->kind != ERX_PCIE_BAR_MEMORY || bar->size_log2 > ERX_PCIE_BAR_SIZE_LOG2_MAX)
		return (false);
	return ((bar->flags & ERX_PCIE_BAR_ADDR64) != 0 ||
	    bar->address <= (UINT64_C(1) << 32) - (UINT64_C(1) << bar->size_log2));
}

/*
 * The checks every report meets, which relate a record to its bridge and
 * to the others: its bridge, a bus in the bridge's range, a device and
 * function within their bounds, a place no other record holds, a state and
 * BARs in their sets, each 64-bit BAR followed by its absent upper half.
 */
static erx_status_t
pci_report_well_formed(const erx_pcie_bridge_t *facts, const erx_pcie_function_t *report, uint32_t count,
    erx_dom_pci_refusal_t *refusal)
{
	for (uint32_t at = 0; at < count; at++) {
		const erx_pcie_function_t *const record = &report[at];

		if (record->bridge != facts->index)
			return (pci_refuse(refusal, at, "bridge"));
		if (record->bus < facts->bus_first || record->bus > facts->bus_last)
			return (pci_refuse(refusal, at, "bus"));
		if (record->device > ERX_PCIE_DEVICE_MAX)
			return (pci_refuse(refusal, at, "device"));
		if (record->function > ERX_PCIE_FUNCTION_MAX)
			return (pci_refuse(refusal, at, "function"));
		for (uint32_t other = 0; other < at; other++) {
			if (report[other].bus == record->bus && report[other].device == record->device &&
			    report[other].function == record->function)
				return (pci_refuse(refusal, at, "function"));
		}
		if (erx_pcie_state_name(record->state) == NULL)
			return (pci_refuse(refusal, at, "state"));
		for (uint32_t bar = 0; bar < PCI_BARS; bar++) {
			const erx_pcie_bar_t *const this = &record->bars[bar];

			if (!pci_bar_in_sets(this, record->state == ERX_PCIE_STATE_READY))
				return (pci_refuse(refusal, at, "bars"));
			if ((this->flags & ERX_PCIE_BAR_ADDR64) != 0 &&
			    (bar + 1 == PCI_BARS || record->bars[bar + 1].kind != ERX_PCIE_BAR_ABSENT))
				return (pci_refuse(refusal, at, "bars"));
		}
	}
	return (ERX_OK);
}

/*
 * The placement's own rules, which a placing report's every record meets
 * before the bridge takes any: each placed memory BAR aligned to its span,
 * inside a window, meeting no earlier BAR's span and no entry's register
 * range; each MSI-X table inside its BAR's hardware size.
 */
static erx_status_t
pci_report_placed(const erx_pcie_bridge_t *facts, const erx_dom_device_entry_t *entries, uint32_t nentries,
    const erx_pcie_function_t *report, uint32_t count, erx_dom_pci_refusal_t *refusal)
{
	erx_dom_range_t spans[ERX_PCIE_FUNCTIONS_MAX * PCI_BARS];
	uint32_t nspans = 0;

	for (uint32_t at = 0; at < count; at++) {
		const erx_pcie_function_t *const record = &report[at];

		for (uint32_t bar = 0; bar < PCI_BARS; bar++) {
			erx_dom_range_t cpu;

			if (!pci_placed(&record->bars[bar]))
				continue;
			if (record->bars[bar].address % pci_span(&record->bars[bar]) != 0 ||
			    !erx_dom_pci_bar_cpu(facts, &record->bars[bar], &cpu))
				return (pci_refuse(refusal, at, "bars"));
			for (uint32_t other = 0; other < nspans; other++) {
				if (pci_ranges_meet(cpu, spans[other]))
					return (pci_refuse(refusal, at, "bars"));
			}
			for (uint32_t entry = 0; entry < nentries; entry++) {
				for (uint32_t range = 0; range < entries[entry].nranges; range++) {
					if (pci_ranges_meet(cpu, entries[entry].ranges[range]))
						return (pci_refuse(refusal, at, "bars"));
				}
			}
			spans[nspans++] = cpu;
		}
		if (record->msix_offset != 0) {
			const uint64_t end = (uint64_t)record->msix_table_offset +
			    (uint64_t)record->msix_table_size * ERX_PCIE_MSIX_ENTRY_SIZE;

			if (record->msix_table_bar >= PCI_BARS ||
			    record->bars[record->msix_table_bar].kind != ERX_PCIE_BAR_MEMORY ||
			    end > UINT64_C(1) << record->bars[record->msix_table_bar].size_log2)
				return (pci_refuse(refusal, at, "msix_table_offset"));
		}
	}
	return (ERX_OK);
}

/* The record at layout's place in report, or NULL. */
static const erx_pcie_function_t *
pci_reported(const erx_pcie_function_t *layout, const erx_pcie_function_t *report, uint32_t count)
{
	for (uint32_t at = 0; at < count; at++) {
		if (report[at].bus == layout->bus && report[at].device == layout->device &&
		    report[at].function == layout->function)
			return (&report[at]);
	}
	return (NULL);
}

/* Whether record and layout are one function, without their states; the decoder zeroes every padding byte. */
static bool
pci_same(const erx_pcie_function_t *layout, const erx_pcie_function_t *record)
{
	erx_pcie_function_t as_layout = *record;

	as_layout.state = layout->state;
	return (memcmp(layout, &as_layout, sizeof(as_layout)) == 0);
}

/*
 * The report's records read into report: no more than
 * ERX_PCIE_FUNCTIONS_MAX, each exactly one record's bytes, since the
 * decoder reads a prefix of a longer string.
 */
static erx_status_t
pci_report_read(const erx_dom_pci_record_t *records, uint32_t count, erx_pcie_function_t *report,
    erx_dom_pci_refusal_t *refusal)
{
	if (count > ERX_PCIE_FUNCTIONS_MAX)
		return (pci_refuse(refusal, count, "functions"));
	for (uint32_t at = 0; at < count; at++) {
		if (records[at].size != ERX_PCIE_FUNCTION_SIZE ||
		    !erx_pcie_function_decode(records[at].bytes, records[at].size, &report[at]))
			return (pci_refuse(refusal, at, "record"));
	}
	return (ERX_OK);
}

erx_status_t
erx_dom_pci_report(erx_dom_pci_bridge_t *bridge, const erx_dom_device_entry_t *entries, uint32_t nentries,
    const erx_dom_pci_record_t *records, uint32_t count, erx_dom_pci_refusal_t *refusal)
{
	erx_pcie_function_t report[ERX_PCIE_FUNCTIONS_MAX];
	erx_status_t status;

	/* A report refused whole leaves no earlier confirmation to give a function. */
	if ((status = pci_report_read(records, count, report, refusal)) != ERX_OK ||
	    (status = pci_report_well_formed(&bridge->facts, report, count, refusal)) != ERX_OK) {
		pci_unconfirm(bridge);
		return (status);
	}
	if (bridge->nlayouts == 0) {
		if ((status = pci_report_placed(&bridge->facts, entries, nentries, report, count, refusal)) != ERX_OK)
			return (status);
		for (uint32_t at = 0; at < count; at++)
			bridge->layouts[at] = (erx_dom_pci_layout_t){ .record = report[at] };
		bridge->nlayouts = count;
	}
	for (uint32_t at = 0; at < bridge->nlayouts; at++) {
		erx_dom_pci_layout_t *const layout = &bridge->layouts[at];
		const erx_pcie_function_t *const record = pci_reported(&layout->record, report, count);

		layout->confirmed = record != NULL && pci_same(&layout->record, record);
		layout->state = record == NULL ? 0 : record->state;
		if (record != NULL && bridge->firmware_lost)
			layout->state = ERX_PCIE_STATE_NOT_READY;
	}
	return (ERX_OK);
}

const erx_dom_pci_layout_t *
erx_dom_pci_givable(const erx_dom_pci_bridge_t *bridge, uint8_t bus, uint8_t device, uint8_t function)
{
	for (uint32_t at = 0; at < bridge->nlayouts && !bridge->firmware_lost; at++) {
		const erx_dom_pci_layout_t *const layout = &bridge->layouts[at];

		if (layout->record.bus == bus && layout->record.device == device && layout->record.function == function)
			return (layout->confirmed && layout->state == ERX_PCIE_STATE_READY ? layout : NULL);
	}
	return (NULL);
}

void
erx_dom_pci_firmware(erx_dom_pci_bridge_t *bridge, erx_status_t status)
{
	if (status == ERX_ETIMEDOUT)
		bridge->firmware_lost = true;
}

/*
 * The index-th of the view's records that names device row device, a row of the
 * catalogue, if its tag is tag; ERX_ENOTSUP for a record of another tag or none.
 */
static erx_status_t
firmware_row(const erx_dom_view_t *view, uint32_t device, uint32_t index, uint32_t tag,
    erx_mf_firmware_request_t *row)
{
	uint32_t seen = 0;

	for (uint32_t at = 0; at < view->nfirmware; at++) {
		if (view->firmware[at].device != device)
			continue;
		if (seen == index) {
			if (view->firmware[at].tag != tag)
				return (ERX_ENOTSUP);
			*row = view->firmware[at];
			return (ERX_OK);
		}
		seen++;
	}
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_bridge_row(const erx_dom_view_t *view, uint32_t bridge, erx_mf_firmware_request_t *row)
{
	if (bridge >= view->ndevices)
		return (ERX_EINVAL);
	/* A row with a catalogue, so the status its request answers always has a bridge to mark. */
	for (uint32_t at = 0; at < view->npci_bridges; at++) {
		if (view->pci_bridges[at].facts.index == bridge)
			return (firmware_row(view, bridge, 0, ERX_FW_TAG_NOTIFY_XHCI_RESET, row));
	}
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_power_row(const erx_dom_view_t *view, uint32_t device, uint32_t phase, erx_mf_firmware_request_t *row)
{
	if (device >= view->ndevices)
		return (ERX_EINVAL);
	if (!view->devices[device].power_line)
		return (ERX_ENOTSUP);
	return (firmware_row(view, device, phase, ERX_FW_TAG_SET_GPIO_STATE, row));
}

uint8_t
erx_dom_pci_route(const erx_dom_device_entry_t *entry, const erx_pcie_function_t *function)
{
	const bool masked = (function->msi_flags & ERX_PCIE_MSI_VECTOR_MASK) != 0;
	const bool wide = (function->msi_flags & ERX_PCIE_MSI_ADDR64) != 0;

	if (entry->nlines != 0)
		return (ERX_PCIE_ROUTE_INTX);
	/* pcireg.h gives the per-vector mask's offset only for a 64-bit capability. */
	if (function->msi_offset != 0 && (!masked || wide))
		return (ERX_PCIE_ROUTE_MSI);
	if (function->msix_offset != 0)
		return (ERX_PCIE_ROUTE_MSIX);
	return (ERX_PCIE_ROUTE_NONE);
}

/*
 * Whether compatible, a NUL-terminated string, is the function's identity:
 * pci, its vendor and device id in four lowercase hexadecimal digits each,
 * apart by a comma (docs/design-pcie.md, "The catalogue and gives").
 */
static bool
pci_identity(const char *compatible, const erx_pcie_function_t *function)
{
	static const char digits[] = "0123456789abcdef";
	char identity[sizeof("pci0000,0000")] = "pci0000,0000";

	for (uint32_t at = 0; at < 4; at++) {
		identity[3 + at] = digits[(function->vendor >> (12 - 4 * at)) & 0xf];
		identity[8 + at] = digits[(function->device_id >> (12 - 4 * at)) & 0xf];
	}
	return (compatible != NULL && strcmp(compatible, identity) == 0);
}

/*
 * Whether a function of a bridge raises only the line its place's row
 * names: on an open bridge no row names one, and on a closed one its place
 * is listed and its reported pin is the place's (docs/design-pcie.md, "The
 * closed bus").
 */
static bool
pci_pin_listed(const erx_pcie_bridge_t *facts, const erx_pcie_function_t *function)
{
	if ((facts->flags & ERX_PCIE_BRIDGE_CLOSED) == 0)
		return (true);
	for (uint32_t at = 0; at < ERX_PCIE_CLOSED_MAX; at++) {
		const erx_pcie_place_t *const place = &facts->places[at];

		if (place->bus != 0 && place->bus == function->bus && place->device == function->device &&
		    place->function == function->function)
			return (place->pin == function->pin);
	}
	return (false);
}

const erx_dom_pci_layout_t *
erx_dom_pci_given(const erx_dom_pci_bridge_t *bridges, uint32_t nbridges, const erx_dom_device_entry_t *entry,
    const erx_pcie_bridge_t **facts)
{
	const erx_dom_pci_layout_t *layout;

	for (uint32_t at = 0; at < nbridges; at++) {
		if (bridges[at].facts.index != entry->bridge)
			continue;
		layout = erx_dom_pci_givable(&bridges[at], entry->bus, entry->device, entry->function);
		if (layout == NULL || !pci_identity(entry->compatible, &layout->record) ||
		    !pci_pin_listed(&bridges[at].facts, &layout->record))
			return (NULL);
		*facts = &bridges[at].facts;
		return (layout);
	}
	return (NULL);
}
