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
#include "erx/abi_reader.h"
#include "erx/cdefs.h"
#include "erx/dom.h"

/* include/erx/pack.h's; that header's erx_boot_inputs_t is the first stage's, not the boot page's. */
typedef struct erx_pack_view erx_pack_view_t;

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

/* One principal's budget and group, in the root's own table. */
typedef struct erx_dom_principal_held {
	uint64_t	budget;		/* carved from the root budget at the
					 * principal's memory: its domains' budgets
					 * carve from it */
	uint64_t	group;		/* its group: its requested domains' CPU parent */
} erx_dom_principal_held_t;

/* What the library holds of the system domain's: handles in the root's own table. */
typedef struct erx_dom_held {
	erx_dom_principal_held_t *principals;	/* view.nprincipals: principal
						 * number n at n - 1 */
	uint64_t	system_group;		/* the system domain's group: its bells, and
						 * a configured domain's CPU parent */
	uint64_t	image;			/* the boot image (SYSTEM): what erx_image_slice
						 * and erx_image_map read */
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
	uint64_t	*remains_held;	/* view.max_remains: each remains row's outer
					 * budget handle, ERX_CAP_NULL for none */
	erx_dom_held_t	 held;
	const char	*host;		/* the host part of a domain's node name */
	size_t		 host_len;	/* at most ERX_DOM_HOST_MAX */
	uint32_t	 pack_flags;	/* the boot image's, for each boot page */
	uint32_t	 cap_limit;	/* each domain's handle table */
	bool		 det;		/* the system's boot page has ERX_BOOT_DET,
					 * so each domain's page carries it */
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

/*
 * What erx_dom_create returns: the domain's id and the system domain's values
 * of its connection, which its agent opens the system side's port with.
 */
typedef struct erx_dom_created {
	uint32_t	id;
	uint32_t	connection;	/* its number, which is also the label
					 * the system domain's bell is bound
					 * with; 0 for none */
	uint64_t	side;		/* the domain's side: the system domain reads it */
	uint64_t	peer_side;	/* the system domain's side: it writes it */
	uint64_t	bell;		/* the domain's bell: the system domain triggers it */
	uint32_t	reader;		/* data area of peer_side's lane, the
					 * one the domain reads */
	uint32_t	system_lane;	/* data area of side's lane, the one
					 * the system domain reads */
	uint32_t	ctl_slots;	/* slots of the control table that
					 * ends peer_side */
	erx_dom_pid_t	domain_pid;	/* the one process that writes it */
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
 * Copies ended domain id's crash area, all ERX_CRASH_SIZE bytes, into dst at
 * offset 0, a memory object of the caller's at least that large, with
 * erx_mem_copy: the library never maps the area, so a deleted one fails the
 * copy with ERX_ESTALE instead of faulting. ERX_EINVAL for a domain not
 * ended, or one created without a crash area; the backend's refusal otherwise.
 * The caller reads dst with erx_dom_dump_read before the domain's retire.
 */
erx_status_t	erx_dom_lib_crash_copy(erx_dom_lib_t *, uint32_t id, uint64_t dst)
		    ERX_WARN_UNUSED_RESULT;

/*
 * The fault thread's wait, outside the lock: the next record at the gates bound
 * to the calling thread, with its label, or the backend's ERX_ETIMEDOUT. A
 * message whose tag is not a record from the kernel, an erx_fault_t of words
 * and no items, is ERX_EINVAL and is not read.
 */
erx_status_t	erx_dom_lib_take(uint64_t wait_by, uint64_t *label,
		    erx_fault_t *record) ERX_WARN_UNUSED_RESULT;

/*
 * The fault thread's handling of one record, under the lock
 * (erx_dom_record_step): a fault stops the domain's space; an exit record
 * destroys the domain's own budget and ends it. True when a domain ended, with
 * *report the end to send.
 */
bool		erx_dom_lib_record(erx_dom_lib_t *, uint64_t label,
		    const erx_fault_t *record, erx_dom_report_t *report);

/*
 * The system domain's one library, which the root's start builds before ERTS
 * runs (docs/design-system.md, "Starting the system domain", step 3) and
 * names with erx_dom_lib_system_set; NULL until then. The domain service's
 * NIF module, erx_domain_lib, reaches the library only through it.
 */
erx_dom_lib_t	*erx_dom_lib_system(void);
void		erx_dom_lib_system_set(erx_dom_lib_t *);

/*
 * The library at boot (docs/design-system.md, "The root task", steps 2 and
 * 3). The view is liberx/system/dom_boot_view.c's, pure and built by the
 * root and by the manifest check's host planner alike; the files and the
 * effects are liberx/system/dom_boot.c's. The tables come from memory the
 * caller supplies, one region laid out by erx_dom_boot_layout from the sizes
 * the manifest and the boot image give.
 */
typedef struct erx_dom_boot_sizes {
	uint32_t	max_domains;	/* the manifest's: domain records */
	uint32_t	max_connections; /* the manifest's: connection rows */
	uint32_t	nprincipals;	/* the manifest's principal rows */
	uint32_t	nconfigured;	/* its configured-domain rows */
	uint32_t	ntemplates;	/* its session templates */
	uint32_t	nfiles;		/* the boot image's entries */
} erx_dom_boot_sizes_t;

typedef struct erx_dom_boot_tables {
	erx_dom_t		*domains;	/* max_domains */
	erx_dom_handles_t	*handles;	/* max_domains */
	erx_dom_connection_t	*connections;	/* max_connections */
	erx_dom_link_handles_t	*links;		/* max_connections */
	erx_dom_remains_t	*remains;	/* 2 * max_connections */
	uint64_t		*remains_held;	/* 2 * max_connections */
	erx_dom_principal_t	*principals;	/* nprincipals */
	erx_dom_principal_held_t *held;		/* nprincipals */
	erx_dom_configured_t	*configured;	/* nconfigured */
	erx_dom_template_t	*templates;	/* ntemplates */
	erx_dom_file_t		*files;		/* nfiles */
} erx_dom_boot_tables_t;

/* The sizes of the view the manifest and a boot image of nfiles entries describe. */
erx_dom_boot_sizes_t erx_dom_view_sizes(const erx_manifest_view_t *, uint32_t nfiles);
/* The same for the opened boot image. */
erx_dom_boot_sizes_t erx_dom_boot_sizes(const erx_manifest_view_t *, const erx_pack_view_t *);

/*
 * Places the tables of sizes in one region starting at base, which is
 * page-aligned, each aligned for its type, and sets *bytes to the region's size; base 0 sizes only.
 * False when the size does not fit a size_t.
 */
bool		erx_dom_boot_layout(const erx_dom_boot_sizes_t *, uintptr_t base,
		    erx_dom_boot_tables_t *tables, size_t *bytes) ERX_WARN_UNUSED_RESULT;

/*
 * Judges file, its kind already set, from head_len bytes at head, the
 * start of its entry: an image whose manifest has this build's magic,
 * version and ABI version is accepted, with its flags. Pure.
 */
void		erx_dom_boot_image(erx_dom_file_t *file, const uint8_t *head, size_t head_len);

/*
 * Builds lib's view from the checked manifest into tables, which
 * erx_dom_boot_layout placed for erx_dom_boot_sizes and whose files hold
 * nfiles judged entries: the header's limits, the principals numbered from 1
 * in row order and each admitted by erx_dom_principal_check, the configured
 * rows, the files, and the host name. Pure: it makes no call. NULL, or the
 * reason the manifest cannot give a view, with lib's view left partial.
 */
const char	*erx_dom_view_build(erx_dom_lib_t *, const erx_manifest_view_t *,
		    uint32_t nfiles, const erx_dom_boot_tables_t *tables);

/*
 * The root's view: erx_dom_view_build over every entry of the opened boot
 * image, each judged by erx_dom_boot_image from the bytes the archive holds
 * at its start (liberx/system/dom_boot.c).
 */
const char	*erx_dom_boot_view(erx_dom_lib_t *, const erx_manifest_view_t *,
		    const erx_pack_view_t *, const erx_dom_boot_tables_t *tables);

/*
 * The effects at boot, after erx_dom_boot_view: each principal's budget,
 * carved from the root budget, and group; the fault gate; and the held
 * handles and boot-page values the system's own page gives (its group,
 * time page, pack flags and ERX_BOOT_DET), and system_space, the object id
 * by which the kernel's records name the system domain's space. Names lib with
 * erx_dom_lib_system_set. NULL, or the reason a call was refused; the
 * root then ends the machine, so nothing is undone.
 */
const char	*erx_dom_boot_up(erx_dom_lib_t *, const erx_boot_info_t *system_page,
		    uint64_t system_space);

/*
 * Manifest startup and restart: erx_dom_create of configured-domain row
 * `row` under domain id `id` and domain pid `domain_pid`, planned by
 * erx_dom_plan_configured and applied as erx_dom_lib_create applies a
 * request's plan. Like every entry, it runs under the caller's one
 * library lock. `row` is the row's index in the
 * manifest's domain table, which the record's origin keeps; manifest
 * startup walks the boot order, and the host planner, which plans the rows
 * in that order, gives the domain at place p of it the id
 * ERX_DOM_SYSTEM_ID + 1 + p, so startup gives the same ids.
 */
erx_status_t	erx_dom_lib_configured(erx_dom_lib_t *, uint32_t id, uint32_t row,
		    erx_dom_pid_t domain_pid, erx_dom_created_t *created) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_DOM_LIB_H */
