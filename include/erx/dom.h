/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DOM_H
#define ERX_DOM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/sched.h"

/*
 * The domain library's pure core (docs/design-system.md, "The domain
 * library" and "Creating a domain"). The library is the one party that
 * creates, installs into and ends domains; this core decides how. It
 * reads no hardware or global state: every decision is a function of a
 * copied specification and the caller's view of the machine, and the
 * result is a plan, a list of steps that the apply phase performs in
 * order. It builds for the host, where its tests and fuzz target run.
 *
 * Who may do what:
 * - only the three planning entries below build an erx_dom_origin_t, each
 *   from its own source, so no caller hands the planner an origin; a
 *   source check keeps the origin kinds out of every other file, and
 *   another the callers of the configured and partial-boot entries
 *   (tools/lib/erx/chokepoint_rules/dom.rb);
 * - every install a plan makes is drawn from erx_dom_grants, which has
 *   no row for an IPC gate, so a plan that installs one fails
 *   erx_dom_plan_check (the one installer, A7);
 * - every object a plan creates is charged to a budget the same plan
 *   carved, so undoing a creation is destroying those budgets (A4).
 */

#define ERX_DOM_SPEC_VERSION	1u
/* The system domain's id; every other domain's id is above it. */
#define ERX_DOM_SYSTEM_ID	4u
/* The last id the domain service's counter hands out. */
#define ERX_DOM_ID_MAX		UINT32_C(0xfffffffe)

/* Origin kinds; zero is no origin, so a zeroed origin fails planning. */
#define ERX_DOM_REQUEST		1u
#define ERX_DOM_CONFIGURED	2u
#define ERX_DOM_PARTIAL_BOOT	3u

/* Specification and record flags. */
#define ERX_DOM_SECRET		0x1u	/* the vault's; refused in Phase 1b-A */
#define ERX_DOM_SPACES		0x2u	/* holds SPACES, with a sub-space group */
#define ERX_DOM_FLAGS_KNOWN	(ERX_DOM_SECRET | ERX_DOM_SPACES)

/*
 * The room the lane a domain reads from the system domain keeps for one
 * connection-control record, per connection its quota allows
 * (docs/design-domains.md, "The reserve"): a control payload of at most
 * ERX_CTL_MAX bytes with its frame and record headers.
 */
#define ERX_DOM_CTL_RESERVE	(ERX_CTL_MAX + 64u)
/* What a plan reserves on a budget for one bell, an IRQ object. */
#define ERX_DOM_BELL_BYTES	ERX_PAGE_SIZE
/* The most steps a creation plan holds. */
#define ERX_DOM_PLAN_STEPS_MAX	40u
/* The fields of erx_runtime_limits_t a request may leave out; dom_core.c
 * pins the layout, so a new field fails the build until it is handled. */
#define ERX_DOM_LIMITS_FIELDS	11u
#define ERX_DOM_LIMITS_ALL	((UINT32_C(1) << ERX_DOM_LIMITS_FIELDS) - 1)

typedef struct erx_dom_origin {
	uint32_t	kind;		/* ERX_DOM_REQUEST, ERX_DOM_CONFIGURED,
					 * or ERX_DOM_PARTIAL_BOOT */
	uint32_t	record;		/* REQUEST: ERX_MF_NONE; otherwise the
					 * index in the origin's manifest table */
} erx_dom_origin_t;

typedef enum erx_dom_state {
	ERX_DOM_FREE,		/* no domain; id is 0 */
	ERX_DOM_BUILDING,	/* plan being applied */
	ERX_DOM_BUILT,		/* built; first thread waiting for erx_dom_start */
	ERX_DOM_RUNNING,
	ERX_DOM_ENDED,		/* stopped; own budget destroyed; reported;
				 * outer budget kept */
	ERX_DOM_RETIRED		/* outer budget destroyed; record reusable */
} erx_dom_state_t;

typedef enum erx_dom_end_kind {
	ERX_DOM_END_NONE,	/* no end yet: a record's stop until the library
				 * stops its space, so a zeroed stop is none */
	ERX_DOM_END_HALT,	/* the space stopped itself with a halt status */
	ERX_DOM_END_CRASH,	/* the space stopped itself with ERX_EXIT_CRASH */
	ERX_DOM_END_FAULT,	/* a thread faulted; the library stopped the space */
	ERX_DOM_END_STOPPED	/* the library stopped it on request */
} erx_dom_end_kind_t;

typedef struct erx_dom_end {
	erx_dom_end_kind_t	kind;
	int64_t			status;	/* HALT: the status; FAULT: the fault kind */
} erx_dom_end_t;

/* One domain record (docs/design-system.md, "The domain library's records"). */
typedef struct erx_dom {
	uint32_t	id;		/* the domain id; 0 for a free record */
	uint32_t	principal;
	erx_dom_origin_t origin;	/* immutable creation source and manifest row */
	erx_dom_state_t	state;
	uint32_t	flags;		/* ERX_DOM_SECRET, ERX_DOM_SPACES */
	erx_cap_t	budget;		/* its own budget, carved from its principal's */
	erx_cap_t	outer;		/* its outer budget, carved beside it */
	erx_cap_t	space, group;
	erx_cap_t	spaces_group;	/* ERX_DOM_SPACES: its sub-space group */
	erx_cap_t	crash;		/* its crash area, charged to its outer budget */
	erx_cap_t	bootinfo;	/* its boot information page */
	erx_cap_t	sealing;	/* the vault's mapping of the sealing page */
	erx_cap_t	first_thread;
	uint32_t	system_connection;	/* its connection to the system domain */
	uint32_t	connections;	/* its connections quota, the spec's */
	uint32_t	labels;		/* bell labels its event table has taken: the
					 * system connection's is 1, and each
					 * connection's bell takes the next */
	erx_dom_end_t	stop;		/* the stop the library made: FAULT with
					 * the kind, or STOPPED; NONE until it
					 * stops the space */
	erx_dom_end_t	end;		/* classified end, once ERX_DOM_ENDED */
	erx_fault_t	record;		/* the record that ended it */
} erx_dom_t;

/* One connection row; a is ERX_DOM_SYSTEM_ID for a system connection. */
typedef struct erx_dom_connection {
	uint32_t	number;		/* 0 for a free row */
	uint32_t	a, b;		/* domain ids */
	erx_cap_t	budget_a;	/* a's child budget; ERX_CAP_NULL when a is 4 */
	erx_cap_t	budget_b;	/* b's; when a is 4 it holds both sides and bells */
	erx_cap_t	side_a;		/* a's side, which b reads */
	erx_cap_t	side_b;		/* b's side, which a reads */
	erx_cap_t	bell_a;		/* bound to a's group */
	erx_cap_t	bell_b;		/* bound to b's group */
	bool		closing;
} erx_dom_connection_t;

/*
 * One device record, one per entry of the root resource's device list
 * (docs/design-system.md, "Devices"). Everything but memory is charged to
 * the holder's own budget, so it dies at the holder's end, and a holder
 * that names no living domain holds nothing.
 */
typedef struct erx_dom_device {
	uint32_t	index;		/* in the root resource's device list */
	uint32_t	holder;		/* the living domain it is given to; 0 for none */
	erx_cap_t	resource;	/* the carved resource */
	erx_cap_t	windows[ERX_DEVICE_RANGES_MAX];	/* its register windows */
	erx_cap_t	irqs[ERX_DEVICE_IRQS_MAX];	/* its lines' IRQ objects */
	erx_cap_t	dma;		/* confined: its DMA window; else ERX_CAP_NULL */
	erx_cap_t	memory;		/* unconfined: its contiguous memory, made at
					 * its first give, charged to the system
					 * domain and kept for the boot; else
					 * ERX_CAP_NULL */
} erx_dom_device_t;

/* A page-aligned range of device addresses. */
typedef struct erx_dom_range {
	uint64_t	base, size;
} erx_dom_range_t;

/*
 * One entry of the device service's catalogue, from the root resource's
 * device list: what erx_dom_device_give creates for the device.
 */
typedef struct erx_dom_device_entry {
	uint32_t	nranges;	/* at most ERX_DEVICE_RANGES_MAX */
	uint32_t	nlines;		/* at most ERX_DEVICE_IRQS_MAX */
	erx_dom_range_t	ranges[ERX_DEVICE_RANGES_MAX];	/* its register ranges */
	bool		confined;	/* it has an IOMMU stream, so a DMA window */
	uint64_t	memory;		/* unconfined: the contiguous memory the
					 * platform reserves for it, bytes; 0
					 * for none */
} erx_dom_device_entry_t;

/*
 * A creation specification: the domain service's description of a domain,
 * a fixed layout built only by an origin constructor
 * (docs/design-system.md, "The domain library"). strings holds args_len
 * bytes of NUL-separated arguments, then env_len bytes of NUL-separated
 * environment.
 */
typedef struct erx_dom_spec {
	uint32_t	version;	/* ERX_DOM_SPEC_VERSION */
	uint32_t	id;		/* allocated by the domain service; nonzero, unused */
	uint32_t	principal;
	erx_dom_origin_t origin;	/* set by the library's origin constructor */
	uint32_t	flags;		/* ERX_DOM_SECRET, ERX_DOM_SPACES */
	uint32_t	release;	/* index of the release's first file in the boot image */
	uint32_t	release_files;	/* number of files in its slice */
	uint32_t	runtime;	/* index of the runtime image file */
	uint64_t	memory;		/* its own budget's guarantee and cap, bytes */
	uint64_t	outer;		/* its outer budget's guarantee and cap, bytes */
	erx_grant_t	grant;		/* the domain group's grant */
	erx_grant_t	spaces;		/* ERX_DOM_SPACES: the sub-space group's grant */
	erx_runtime_limits_t runtime_limits;	/* complete startup values */
	uint32_t	lane;		/* data area of the lane the domain reads */
	uint32_t	connections;	/* its connections quota, sizing the reserve */
	uint32_t	system_lane;	/* data area of the lane the system domain reads */
	uint32_t	crash;		/* crash area size; zero for none */
	uint32_t	args_len;
	uint32_t	env_len;	/* args_len + env_len <= ERX_BOOT_STRINGS_MAX */
	char		strings[ERX_BOOT_STRINGS_MAX];
} erx_dom_spec_t;

/*
 * A principal's view: its budget, quotas and resolved profiles. Phase 1b-A
 * has one, the built-in system principal (docs/plan.md, Phase 1b).
 */
typedef struct erx_dom_principal {
	uint32_t	number;		/* 0 for none */
	uint64_t	memory;		/* its budget, from which domain budgets carve */
	uint64_t	carved;		/* what its domains' budgets hold now */
	uint32_t	domains_max;	/* its domain quota */
	uint32_t	domains;	/* its living domains */
	erx_grant_t	share;		/* its group's grant under users */
	erx_runtime_limits_t default_limits;
	erx_runtime_limits_t ceiling_limits;
} erx_dom_principal_t;

/*
 * One file of the boot image as the library sees it: its entry kind and
 * flags, and for an image its manifest's flags and whether its manifest
 * and ABI version passed the boot's checks.
 */
typedef struct erx_dom_file {
	uint8_t		kind;		/* ERX_ENTRY_FILE or ERX_ENTRY_IMAGE */
	uint8_t		flags;		/* ERX_ENTRY_SYSTEM, ERX_ENTRY_SEAL */
	bool		image_ok;	/* image: manifest and ABI version accepted */
	uint32_t	image_flags;	/* image: ERX_IMAGE_JIT */
} erx_dom_file_t;

/* A checked configured-domain row of the system manifest. */
typedef struct erx_dom_configured {
	uint32_t	principal;
	uint32_t	flags;		/* ERX_DOM_SPACES */
	uint32_t	release, release_files, runtime;
	uint64_t	memory, outer;
	erx_grant_t	grant, spaces;
	erx_runtime_limits_t runtime_limits;
	uint32_t	lane, connections;
} erx_dom_configured_t;

/* A checked native program row of a partial-boot manifest. */
typedef struct erx_dom_partial {
	uint32_t	runtime;	/* the program's image */
	uint64_t	memory, outer;
	erx_grant_t	grant;
} erx_dom_partial_t;

/*
 * The library's view of the machine, which planning reads under the
 * library lock. The tables are the library's own; the rest is fixed at
 * boot from the checked system manifest and the boot image, except
 * service_grants, the grants of the living configured domains under
 * system, and ending. The planners read the view through a const
 * pointer; erx_dom_plan_record and erx_dom_link_record write the domain
 * records, the connection rows, the principals' counts, the service
 * grants and next_connection, so those tables are not const.
 */
typedef struct erx_dom_view {
	erx_dom_t		*domains;	/* max_domains records */
	uint32_t		 max_domains;
	erx_dom_connection_t	*connections;	/* max_connections rows */
	uint32_t		 max_connections;
	erx_dom_principal_t	*principals;
	uint32_t		 nprincipals;
	const erx_dom_device_entry_t *devices;	/* the catalogue: ndevices entries */
	const erx_dom_device_t	*device_records; /* ndevices records, entry for entry */
	uint32_t		 ndevices;
	const erx_dom_file_t	*files;		/* the boot image's files */
	uint32_t		 nfiles;
	const erx_dom_configured_t *configured;
	uint32_t		 nconfigured;
	const erx_dom_partial_t	*partial;
	uint32_t		 npartial;
	uint32_t		 partial_principal;	/* the partial boot's principal */
	erx_runtime_limits_t	 native_limits;
	erx_grant_t		 system_grant;	/* system's grant */
	uint32_t		 system_reserve;	/* thousandths of system's rate */
	erx_grant_t		*service_grants; /* room for max_domains */
	uint32_t		 nservice_grants;
	uint32_t		 system_lane;	/* the manifest's */
	uint32_t		 next_connection; /* the next connection's number:
						  * numbers start at 1 and only grow,
						  * so none is reused in a boot; 0
						  * once they are spent */
	uint64_t		 system_space;	/* object id of the system domain's
						 * space, as records name it */
	bool			 ending;	/* the ending record is installed */
} erx_dom_view_t;

/*
 * The objects a plan names. The first group is what the plan makes; the
 * second is what the library already holds, which a plan only refers to.
 */
typedef enum erx_dom_obj {
	ERX_DOM_OBJ_NONE,
	ERX_DOM_OBJ_BUDGET,		/* the domain's own budget */
	ERX_DOM_OBJ_OUTER,		/* its outer budget */
	ERX_DOM_OBJ_SPACE,
	ERX_DOM_OBJ_GROUP,
	ERX_DOM_OBJ_SPACES_GROUP,
	ERX_DOM_OBJ_BOOTINFO,
	ERX_DOM_OBJ_CRASH,
	ERX_DOM_OBJ_SYS_BUDGET,		/* the system connection's child budget */
	ERX_DOM_OBJ_SYS_SIDE,		/* the system domain's side: the domain reads it */
	ERX_DOM_OBJ_DOM_SIDE,		/* the domain's side: the system domain reads it */
	ERX_DOM_OBJ_SYS_BELL,		/* bound to the system domain's group */
	ERX_DOM_OBJ_DOM_BELL,		/* bound to the domain's group */
	ERX_DOM_OBJ_SLICE,		/* the release slice */
	ERX_DOM_OBJ_THREAD,		/* the first thread */
	/* A connection between domains a and b (erx_dom_plan_connect). */
	ERX_DOM_OBJ_LINK_BUDGET_A,	/* a's child budget, carved from a's outer */
	ERX_DOM_OBJ_LINK_BUDGET_B,	/* b's, carved from b's outer */
	ERX_DOM_OBJ_SIDE_A,		/* a's side: a writes it, b reads it */
	ERX_DOM_OBJ_SIDE_B,		/* b's side: b writes it, a reads it */
	ERX_DOM_OBJ_BELL_A,		/* bound to a's group: a waits on it */
	ERX_DOM_OBJ_BELL_B,		/* bound to b's group */
	/* A device given to a domain (erx_dom_plan_device_give). */
	ERX_DOM_OBJ_DEV_RESOURCE,	/* the device's resource, carved from the root's */
	ERX_DOM_OBJ_DEV_WINDOW,		/* register window i is DEV_WINDOW + i */
	ERX_DOM_OBJ_DEV_IRQ = ERX_DOM_OBJ_DEV_WINDOW + ERX_DEVICE_RANGES_MAX,
					/* line i's IRQ object is DEV_IRQ + i */
	ERX_DOM_OBJ_DEV_DMA = ERX_DOM_OBJ_DEV_IRQ + ERX_DEVICE_IRQS_MAX,
					/* a confined device's DMA window */
	ERX_DOM_OBJ_DEV_MEMORY,		/* an unconfined device's contiguous
					 * memory, made at its first give */
	ERX_DOM_OBJ_MADE_COUNT,
	/* Held by the library. */
	ERX_DOM_OBJ_PRINCIPAL_BUDGET = ERX_DOM_OBJ_MADE_COUNT,
	ERX_DOM_OBJ_PARENT_GROUP,	/* the plan's resolved CPU parent */
	ERX_DOM_OBJ_SYSTEM_SPACE,
	ERX_DOM_OBJ_SYSTEM_GROUP,
	ERX_DOM_OBJ_FAULT_GATE,		/* the library's fault gate */
	ERX_DOM_OBJ_TIME_PAGE,
	ERX_DOM_OBJ_OUTER_A,		/* a connection's parties' records' objects */
	ERX_DOM_OBJ_OUTER_B,
	ERX_DOM_OBJ_GROUP_A,
	ERX_DOM_OBJ_GROUP_B,
	ERX_DOM_OBJ_SPACE_A,
	ERX_DOM_OBJ_SPACE_B,
	ERX_DOM_OBJ_ROOT_RESOURCE,	/* the root resource, listing every device */
	ERX_DOM_OBJ_SYSTEM_BUDGET,	/* the system domain's own budget */
	ERX_DOM_OBJ_HOLDER_BUDGET,	/* a device's holder's own budget */
	ERX_DOM_OBJ_HOLDER_SPACE,
	ERX_DOM_OBJ_DEV_KEPT,		/* the device record's contiguous memory,
					 * made at an earlier give */
	ERX_DOM_OBJ_COUNT
} erx_dom_obj_t;

typedef enum erx_dom_step_kind {
	ERX_DOM_STEP_CARVE,		/* obj: a wall budget of size under budget */
	ERX_DOM_STEP_SPACE,		/* obj under target (parent), aux, label, flags */
	ERX_DOM_STEP_GROUP,		/* obj under target with grant */
	ERX_DOM_STEP_MEM,		/* obj of size, charged to budget */
	ERX_DOM_STEP_BELL,		/* obj, charged to budget, bound to target with label */
	ERX_DOM_STEP_SLICE,		/* obj from files [index, index + count), charged to budget */
	ERX_DOM_STEP_IMAGE_MAP,		/* the runtime image file index into target */
	ERX_DOM_STEP_MAP,		/* obj into target, read-only */
	ERX_DOM_STEP_INSTALL,		/* obj into target with rights */
	ERX_DOM_STEP_BOOTINFO,		/* write obj from the installs' values */
	ERX_DOM_STEP_THREAD,		/* obj in space target and group aux, stopped */
	ERX_DOM_STEP_RESOURCE,		/* obj: device index carved from resource
					 * target, charged to budget */
	ERX_DOM_STEP_WINDOW,		/* obj: physical memory with device
					 * attributes over register range index of
					 * resource target, size bytes, charged to
					 * budget */
	ERX_DOM_STEP_IRQ,		/* obj: an IRQ object of line index of
					 * resource target, charged to budget */
	ERX_DOM_STEP_DMA,		/* obj: a DMA window on resource target's
					 * stream, charged to budget */
	ERX_DOM_STEP_CONTIGUOUS		/* obj: contiguous memory of size, charged
					 * to budget */
} erx_dom_step_kind_t;

/* What undoes an applied step. */
typedef enum erx_dom_undo_kind {
	ERX_DOM_UNDO_DESTROY,		/* destroy the step's object: a carved
					 * budget, with all charged to it, or a
					 * device's object */
	ERX_DOM_UNDO_BY_BUDGET		/* goes with a carved budget's destroy */
} erx_dom_undo_kind_t;

typedef struct erx_dom_step {
	erx_dom_step_kind_t kind;
	erx_dom_obj_t	obj;		/* what the step makes, maps or installs */
	erx_dom_obj_t	budget;		/* the budget charged, or carved from */
	erx_dom_obj_t	target;		/* the parent, space or group it goes into */
	erx_dom_obj_t	aux;		/* SPACE: its fault gate; THREAD: its group */
	uint64_t	size;		/* CARVE, MEM: bytes */
	uint32_t	index, count;	/* SLICE, IMAGE_MAP: boot image files */
	uint32_t	label;		/* SPACE: the domain id; BELL: its label */
	uint32_t	rights;		/* INSTALL: ERX_HR_* */
	uint32_t	flags;		/* SPACE: ERX_SPACE_JIT; GROUP: grant index */
} erx_dom_step_t;

/*
 * Where a domain's group goes, derived from its origin. Zero is neither,
 * so a zeroed plan names no parent.
 */
typedef enum erx_dom_parent {
	ERX_DOM_PARENT_SYSTEM = 1,	/* a configured domain: under system */
	ERX_DOM_PARENT_PRINCIPAL	/* requested, partial boot: its principal's group */
} erx_dom_parent_t;

/* GROUP step flags: which grant of the specification the group takes. */
#define ERX_DOM_GROUP_GRANT	0u
#define ERX_DOM_GROUP_SPACES	1u

/* The label of a domain's bell on its system connection. */
#define ERX_DOM_SYSTEM_LABEL	1u

/* A plan's connection_row when the domain has no system connection. */
#define ERX_DOM_NO_ROW		UINT32_MAX

typedef struct erx_dom_plan {
	erx_dom_spec_t	spec;		/* the validated specification */
	erx_dom_parent_t parent;
	uint32_t	slot;		/* the free record the domain takes */
	uint32_t	connection;	/* its system connection's number; 0 for none */
	uint32_t	connection_row;	/* that connection's row, or ERX_DOM_NO_ROW */
	uint32_t	nsteps;
	erx_dom_step_t	steps[ERX_DOM_PLAN_STEPS_MAX];
} erx_dom_plan_t;

/*
 * One row of erx_dom_grants: what a domain may hold of an object. A row
 * applies when the specification has its flags; spaces_rights are added
 * to rights when the specification has ERX_DOM_SPACES.
 */
typedef struct erx_dom_grant_row {
	erx_dom_obj_t	obj;
	erx_dom_obj_t	target;		/* the space it goes into */
	uint32_t	flags;		/* required specification flags, or 0 */
	uint32_t	rights;
	uint32_t	spaces_rights;
} erx_dom_grant_row_t;

/*
 * Every install a plan may make into a domain's table (A7), one row per
 * object and the space it goes into: nine for a creation, into SPACE;
 * three into each party of a connection; and five into a device's holder,
 * where the row of DEV_WINDOW covers every register window and the row of
 * DEV_IRQ every line.
 */
#define ERX_DOM_GRANTS_ROWS	20u
extern const erx_dom_grant_row_t erx_dom_grants[ERX_DOM_GRANTS_ROWS];

/*
 * The planning entries, one per creation origin. Each builds the
 * specification from its source itself, so the origin is set here and
 * nowhere else and no caller hands the planner an origin; then validates
 * it against the view and writes the creation plan. Each returns ERX_OK;
 * ERX_EINVAL for a specification outside its ranges; ERX_ELIMIT for a full
 * table or an exhausted quota; ERX_ENOMEM when the principal's budget
 * cannot hold the domain's two budgets; ERX_EBUSY once the machine is
 * ending. *plan is written only on ERX_OK.
 *
 * erx_dom_plan_request plans an admitted request: req supplies id,
 * principal, flags, release, release_files, runtime, memory, outer, grant,
 * spaces, lane, connections, args_len, env_len and strings, and every other
 * field is ignored; given is a mask over the fields of erx_runtime_limits_t
 * in layout order, each field given read from limits, which may be NULL
 * when given is 0, and each other field the principal's default.
 *
 * erx_dom_plan_configured plans configured-domain row `row` of the checked
 * manifest under domain id `id`; only manifest startup and restart call
 * it. erx_dom_plan_partial plans partial-boot program row `row`; only the
 * root's partial-boot entry calls it.
 */
erx_status_t	erx_dom_plan_request(const erx_dom_view_t *,
		    const erx_dom_spec_t *req, const erx_runtime_limits_t *limits,
		    uint32_t given, erx_dom_plan_t *plan);
erx_status_t	erx_dom_plan_configured(const erx_dom_view_t *, uint32_t id,
		    uint32_t row, erx_dom_plan_t *plan);
erx_status_t	erx_dom_plan_partial(const erx_dom_view_t *, uint32_t id,
		    uint32_t row, erx_dom_plan_t *plan);

/*
 * Records a creation plan in the view it was planned against, as the
 * domain then lives: the plan's slot becomes the domain's record, built,
 * with its id, principal, origin, flags and connections quota, and, with
 * a system connection, that connection's number and the first bell
 * label; its principal counts one more domain and carves its two
 * budgets; a configured domain's grant joins the service grants; and the
 * system connection takes its row and number. The record's capabilities
 * are left as they are, for the apply phase to fill from its effects.
 * The manifest check's host planner (tools/host/dom_plan.c) records each
 * configured domain's plan before planning the next; the apply phase,
 * which the domain library's run-time half brings (DL2), is to call it
 * once a plan's steps have all succeeded, so the view the host plans
 * against and the one the boot keeps move by the same function.
 * ERX_OK; ERX_EINVAL, with the view unchanged, for a plan that does not
 * fit the view: a slot or row out of range or taken, an id a record
 * holds, an unknown principal, a connection number not the view's next,
 * a carve past 64 bits, or no room for one more service grant.
 */
erx_status_t	erx_dom_plan_record(erx_dom_view_t *, const erx_dom_plan_t *plan);

/*
 * erx_dom_principal's validation of a principal's configuration, from the
 * manifest's principal row: a nonzero number no principal of the view
 * holds (ERX_EEXIST otherwise); a nonzero, page-aligned budget; a share
 * with a rate; a nonzero domain quota; and a ceiling profile no runtime
 * could exceed (a frame within ERX_FRAME_MAX), with the default profile
 * within it. ERX_EINVAL for anything else. On ERX_OK, *record is the
 * principal as the library keeps it, its counts carved and domains zero.
 * Whether the root budget holds its budget, and the users group its share,
 * is the kernel's to say when the library carves and creates them.
 */
erx_status_t	erx_dom_principal_check(const erx_dom_view_t *,
		    const erx_dom_principal_t *config, erx_dom_principal_t *record);

/*
 * Checks a plan whole before it is applied: every step names objects
 * already made or held, every made object is charged to a budget the plan
 * carved, and every install has a row of erx_dom_grants whose rights
 * cover it. ERX_EINVAL otherwise. The planning entries' plans pass it.
 */
erx_status_t	erx_dom_plan_check(const erx_dom_plan_t *plan);

/* What undoes an applied step of this kind. */
erx_dom_undo_kind_t erx_dom_step_undo(erx_dom_step_kind_t);

/*
 * The undo of a creation whose first `applied` steps were applied: the
 * objects to destroy, in order, into undo, which holds
 * ERX_DOM_PLAN_STEPS_MAX entries. Returns their number.
 */
uint32_t	erx_dom_plan_undo(const erx_dom_plan_t *plan, uint32_t applied,
		    erx_dom_obj_t *undo);
/* The same over any step list: the carves among its first `applied`, last first. */
uint32_t	erx_dom_steps_undo(const erx_dom_step_t *steps, uint32_t nsteps,
		    uint32_t applied, erx_dom_obj_t *undo);

/*
 * A connection's plan (docs/design-system.md, "Introducing two domains"):
 * a child budget carved from each party's outer budget, the two sides and
 * the two bells, each charged to the child of the party that reads it or
 * waits on it, and each party's share installed from erx_dom_grants. The
 * held objects it names are the parties' records' (OUTER_A, GROUP_A,
 * SPACE_A and b's), which the apply phase resolves from a_slot and b_slot.
 * Every object a party is given is charged to one of the two children, so
 * destroying the children deletes each, and a deletion clears every
 * capability to the object from every table (docs/design-kernel.md, K25):
 * neither a failed connect's undo nor a disconnect leaves anything in a
 * living party's table, and no install needs a slot of its own.
 */
#define ERX_DOM_LINK_STEPS	12u

typedef struct erx_dom_link_plan {
	uint32_t	a, b;		/* the parties' domain ids */
	uint32_t	a_slot, b_slot;	/* their records */
	uint32_t	row;		/* the free connection row it takes */
	uint32_t	number;		/* its number, view->next_connection */
	uint32_t	nsteps;
	erx_dom_step_t	steps[ERX_DOM_LINK_STEPS];
} erx_dom_link_plan_t;

/*
 * Plans erx_dom_connect(a, b, a_reads, b_reads): a_reads sizes the data
 * area of the side a reads, b's, and b_reads the one b reads. ERX_OK;
 * ERX_EINVAL for a == b, a domain with no record or outside built and
 * running, or a size that is not a lane's; ERX_ELIMIT for a full table,
 * spent connection numbers, a party at its connections quota or out of
 * bell labels. *plan is written only on ERX_OK. Whether a reader's outer
 * budget covers its child is the kernel's to say, at the carve.
 */
erx_status_t	erx_dom_plan_connect(const erx_dom_view_t *, uint32_t a,
		    uint32_t b, uint32_t a_reads, uint32_t b_reads,
		    erx_dom_link_plan_t *plan);

/*
 * Checks a connection's plan whole: each object is charged to the child of
 * the party that reads it or waits on it, each child is carved from its
 * own party's outer budget, and each install has its row of
 * erx_dom_grants. ERX_EINVAL otherwise.
 */
erx_status_t	erx_dom_link_check(const erx_dom_link_plan_t *plan);

/* The undo of a connection whose first `applied` steps were applied. */
uint32_t	erx_dom_link_undo(const erx_dom_link_plan_t *plan,
		    uint32_t applied, erx_dom_obj_t *undo);

/*
 * Records a connection's plan in the view, as erx_dom_plan_record does a
 * creation's: its row holds the connection's number and parties, each
 * party's record takes the bell label the plan bound, and the view's next
 * connection number moves past it. A party's count of connections is the
 * rows that name it, so nothing else counts them. ERX_OK; ERX_EINVAL,
 * with the view unchanged, for a plan that does not fit the view: a
 * party's slot out of range or not the party's, a row out of range or
 * taken, a number not the view's next, or a bell label not the party's
 * next or not below ERX_LABEL_SPLIT.
 */
erx_status_t	erx_dom_link_record(erx_dom_view_t *,
		    const erx_dom_link_plan_t *plan);

/*
 * What a disconnect, the destroy at an exit record or a retire does: it
 * destroys the capabilities in order, then frees the row or record, or
 * for a destroy leaves the record for the report to mark ended. A destroy
 * cannot be undone, and none of these can fail on a capability the
 * library holds.
 */
typedef enum erx_dom_teardown_kind {
	ERX_DOM_DISCONNECT = 1,	/* index: the connection row it frees */
	ERX_DOM_DESTROY,	/* index: the record of the domain whose own
				 * budget it destroys */
	ERX_DOM_RETIRE		/* index: the record it frees */
} erx_dom_teardown_kind_t;

typedef struct erx_dom_teardown {
	erx_dom_teardown_kind_t kind;
	uint32_t	index;
	uint32_t	ndestroy;
	erx_cap_t	destroy[2];
} erx_dom_teardown_t;

/*
 * erx_dom_disconnect(number): destroys the connection's child budgets,
 * one when a is the system domain. ERX_OK, or ERX_EINVAL for an unknown
 * number. The domain service asks only once each party has unmapped the
 * connection's objects or ended.
 */
erx_status_t	erx_dom_plan_disconnect(const erx_dom_view_t *,
		    uint32_t number, erx_dom_teardown_t *);

/*
 * erx_dom_retire(id): destroys the ended domain's outer budget, with its
 * crash area, and frees its record. ERX_OK; ERX_EINVAL unless the domain
 * has ended; ERX_EBUSY while a connection row names it, since each such
 * row holds a child of its outer budget.
 */
erx_status_t	erx_dom_plan_retire(const erx_dom_view_t *, uint32_t id,
		    erx_dom_teardown_t *);

/*
 * What the library does next for a domain: the fault thread's answer to a
 * record at its gate (erx_dom_record_step), or erx_dom_stop's.
 */
typedef enum erx_dom_act {
	ERX_DOM_ACT_DROP,	/* nothing: no living domain has the label, or
				 * the library is already stopping its space */
	ERX_DOM_ACT_STOP,	/* set the record's stop to end, then
				 * erx_space_stop(space, status) */
	ERX_DOM_ACT_END		/* apply teardown, report {domain_ended, Id,
				 * end, record}, set the record's end and
				 * record, and its state to ERX_DOM_ENDED */
} erx_dom_act_t;

typedef struct erx_dom_action {
	erx_dom_act_t	kind;
	uint32_t	slot;		/* STOP, END: the domain's record */
	int64_t		status;		/* STOP: the stop's status */
	erx_dom_end_t	end;		/* STOP: the noted stop; END: the end */
	erx_dom_teardown_t teardown;	/* END: the destroy of its own budget */
} erx_dom_action_t;

/*
 * The classified end of a domain from its exit record
 * (docs/design-system.md, "Ending a domain"). An exit record names its
 * stopper's space, and only the library, in the system domain's space
 * system_space, holds a capability that stops another domain's space, so
 * a record whose stopper is in system_space is a stop the library made:
 * the FAULT it noted, or STOPPED. Any other stop is the domain's own:
 * CRASH for ERX_EXIT_CRASH and HALT with the status otherwise,
 * ERX_EXIT_NOTHREAD among them. noted is the domain record's stop.
 */
erx_dom_end_t	erx_dom_classify(const erx_fault_t *exit,
		    uint64_t system_space, erx_dom_end_t noted);

/*
 * The fault thread's step for a record at the library's gate whose label
 * is label. An exit record of a built or running domain ends it: its own
 * budget is destroyed and the end classified. Any other record of one the
 * library is not already stopping stops it as a FAULT of the record's
 * kind, with status ERX_EXIT_CRASH. Every other record is dropped: one
 * whose label names no record, or a domain building, ended or retired.
 */
void		erx_dom_record_step(const erx_dom_view_t *, uint64_t label,
		    const erx_fault_t *record, erx_dom_action_t *action);

/*
 * erx_dom_stop(id, status): stops a built or running domain's space, with
 * its sub-spaces, noting the end as STOPPED; a second stop, or a stop of
 * a domain the library is already stopping for a fault, is a DROP. ERX_OK,
 * or ERX_EINVAL for an unknown id or one outside built and running.
 */
erx_status_t	erx_dom_plan_stop(const erx_dom_view_t *, uint32_t id,
		    int64_t status, erx_dom_action_t *action);

/*
 * A device's give (docs/design-system.md, "Devices"): its resource carved
 * from the root's, a register window per range and an IRQ object per
 * line, each charged to the holder's own budget; a DMA window for a
 * confined device, on the same budget, or for an unconfined one its
 * contiguous memory, made at its first give on the system domain's budget
 * and kept in the device record after; and the holder's share installed
 * from erx_dom_grants. The holder is alive, so nothing here is undone by
 * a budget: undo destroys each object the plan made, last first, and the
 * deletion clears every capability to it from the holder's table. The
 * kept memory outlives an undo, so its install is the plan's last step:
 * the apply phase writes the device record, which cannot fail, after it.
 */
#define ERX_DOM_DEVICE_STEPS	(2u * (ERX_DEVICE_RANGES_MAX + ERX_DEVICE_IRQS_MAX) + 3u)
	/* the resource, a window per range, an IRQ object per line and the
	 * DMA window or memory, then an install of each but the resource */

typedef struct erx_dom_device_plan {
	uint32_t	index;		/* the device's entry and record */
	uint32_t	holder;		/* the domain id it goes to */
	uint32_t	slot;		/* the holder's record */
	uint32_t	nsteps;
	erx_dom_step_t	steps[ERX_DOM_DEVICE_STEPS];
} erx_dom_device_plan_t;

/*
 * Plans erx_dom_device_give(id, index). ERX_OK; ERX_EINVAL for a domain
 * with no record or outside built and running, an index past the
 * catalogue or a record whose index is not its own, an entry with more
 * ranges or lines than the ABI allows or a
 * range that is empty, unaligned, wraps, or overlaps another entry's;
 * ERX_EBUSY for a device whose record names a living holder, this domain
 * included. *plan is written only on ERX_OK.
 */
erx_status_t	erx_dom_plan_device_give(const erx_dom_view_t *, uint32_t id,
		    uint32_t index, erx_dom_device_plan_t *plan);

/*
 * Checks a device's plan whole: the resource is carved from the root's
 * before anything is made from it, each window, line and DMA window comes
 * from that resource and is charged to the holder's budget, contiguous
 * memory to the system domain's, and each install has its row of
 * erx_dom_grants. ERX_EINVAL otherwise.
 */
erx_status_t	erx_dom_device_check(const erx_dom_device_plan_t *plan);

/* The undo of a give whose first `applied` steps were applied: every
 * object they made, last first, into undo, which holds ERX_DOM_DEVICE_STEPS. */
uint32_t	erx_dom_device_undo(const erx_dom_device_plan_t *plan,
		    uint32_t applied, erx_dom_obj_t *undo);

#endif /* ERX_DOM_H */
