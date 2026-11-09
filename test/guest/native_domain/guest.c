/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root of the native_domain suite: the domain library's apply phase
 * (liberx/system/dom_apply.c) over the Fiasco backend. Each case creates a
 * domain from a request whose task runs program.c, and checks its end as the
 * library's fault gate reports it: a halt is HALT with the program's status, a
 * fault FAULT, a stop STOPPED. Every domain gets RELEASE as its release,
 * which the program reads through its slice; one with a connection quota
 * reads a lane larger than its own, whose size its boot page must name. Then
 * a domain runs the ERTS image on the ERTS release to init, which says so and
 * halts with 0, and one whose boot page was spoiled ends at its runtime's
 * entry with the reader's reason, before ERTS runs. After each end the domain
 * is disconnected and retired, and the pool and the root's handle table hold
 * what they held before. Two running domains are connected and disconnected.
 * Then a connect, and a create, fails at each step in turn, before the step
 * and once it has made its object, and is undone, leaving the pool, the
 * handles and the view as they were. Each case says one line, which
 * tools/lib/erx/native_domain.rb holds the transcript to.
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "erx/lane.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/service.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_domain/modes.h"

#define PROGRAM		"boot/native-domain"
#define RELEASE		"domains/native/release"
#define ERTS		"runtimes/emu"
#define ERTS_RELEASE	"domains/erts/"
#define ERTS_MEMORY	(UINT64_C(160) << 20)
#define LIBRARY_MEMORY	(UINT64_C(256) << 20)
#define WAIT_NS		UINT64_C(10000000000)
#define DOMAINS		4u
#define CONNECTIONS	4u
#define PRINCIPAL	1u
#define MIB		(UINT64_C(1) << 20)
#define STOP_STATUS	7

void erx_fiasco_root_main(void);

static erx_dom_t domains[DOMAINS];
static erx_dom_connection_t connections[CONNECTIONS];
static erx_dom_principal_t principals[1];
static erx_dom_principal_held_t principals_held[1];
static erx_dom_handles_t handles[DOMAINS];
static erx_dom_link_handles_t links[CONNECTIONS];
static erx_dom_file_t files[ERX_PACK_ENTRIES_MAX];
static erx_dom_lib_t lib;
static erx_dom_spec_t request;
static uint32_t release;
/* The ERTS domain release's run of entries in the boot image. */
static uint32_t erts_release, erts_files;
/*
 * What a domain's ERTS runs: its release's boot script, as the system's
 * system_args do, then a line that says init ran it, then halt(0). A domain
 * has no tty yet, and -noshell would start user_drv, whose NIF is gone, so it
 * starts no user; erlang:display writes to the console through the service.
 */
static const char erts_args[] = "--\0-root\0/\0-bindir\0/bin\0-progname\0erl\0-home\0/\0"
    "-boot\0/bin/start\0-nouser\0-nocookie\0-kernel\0start_distribution\0false\0"
    "-eval\0erlang:display(init_started),erlang:halt(0)";

/* What a case does between a domain's create and its end. */
typedef enum run_action {
	RUN_PLAIN,	/* starts it and waits */
	RUN_STOP,	/* starts it, then stops it with STOP_STATUS */
	RUN_SPOIL	/* spoils its boot page's version, then starts it */
} run_action_t;
static uint32_t next_id = ERX_DOM_SYSTEM_ID + 1;

static void
say(const char *text)
{
	erx_fiasco_console_write(text, strlen(text));
}

static void
say_case(const char *name, bool passed)
{
	say("erx: domain: ");
	say(name);
	say(passed ? " ok\n" : " FAILED\n");
}

static void
say_count(const char *name, uint64_t value)
{
	char line[24];
	size_t used = sizeof(line) - 1;

	line[used] = '\0';
	do {
		line[--used] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0 && used > 0);
	say("erx: domain: ");
	say(name);
	say(" ");
	say(&line[used]);
	say("\n");
}

static erx_runtime_limits_t
limits_default(void)
{
	return ((erx_runtime_limits_t){ .max_frame = 65536, .max_message_heap = MIB, .funnel_depth = 64,
	    .exports = 64, .tmp = MIB, .overlay = MIB, .atoms = 1024, .foreign_atoms = 1024, .processes = 1024,
	    .peer_held = MIB, .peer_held_total = 4 * MIB });
}

/* The library's view of the boot image's files: each entry's kind, flags and span. */
static void
files_from(const erx_pack_view_t *pack, uint32_t program)
{
	erx_pack_entry_t entry;

	for (uint32_t index = 0; index < pack->header.nentries && index < ERX_PACK_ENTRIES_MAX; index++)
		if (erx_pack_entry_at(pack, index, &entry))
			files[index] = (erx_dom_file_t){ .kind = (uint8_t)entry.kind, .flags = (uint8_t)entry.flags,
			    .offset = entry.data_off, .size = entry.data_size };
	/* The stand-in program is an ELF file with no image manifest, which the test admits as an accepted image. */
	files[program].kind = ERX_ENTRY_IMAGE;
	files[program].image_ok = true;
}

/* The view of one built-in principal, the held handles and a gate bound to this thread. */
static const char *
library_up(void)
{
	const erx_grant_t share = { .quota_ns = ERX_QUOTA_NONE, .cpuset = 1, .capacity_mcpu = 1000 };
	uint64_t budget;

	principals[0] = (erx_dom_principal_t){ .number = PRINCIPAL, .memory = LIBRARY_MEMORY, .domains_max = DOMAINS,
	    .share = share, .default_limits = limits_default(), .ceiling_limits = limits_default() };
	lib.view = (erx_dom_view_t){ .domains = domains, .max_domains = DOMAINS, .connections = connections,
	    .max_connections = CONNECTIONS, .principals = principals, .nprincipals = 1, .files = files,
	    .nfiles = ERX_PACK_ENTRIES_MAX, .native_limits = limits_default(), .system_grant = share,
	    .system_lane = ERX_LANE_MIN, .next_connection = 1,
	    .system_space = ERX_FIASCO_TASK_ROOT };
	lib.handles = handles;
	lib.links = links;
	lib.host = "erxos";
	lib.host_len = 5;
	lib.cap_limit = 64;
	lib.fail_step = UINT32_MAX;
	lib.held.principals = principals_held;
	lib.held.time_page = erx_fiasco_time_object();
	/* The stopgap's backend has one archive and reads no image handle. */
	lib.held.image = 0;
	if (erx_group_create(0, 0, &lib.held.system_group) != ERX_OK ||
	    erx_group_create(0, 0, &principals_held[0].group) != ERX_OK)
		return ("erx: domain: no groups\n");
	if (erx_budget_create(ERX_CAP_SELF, ERX_BUDGET_ELASTIC, LIBRARY_MEMORY / ERX_PAGE_SIZE, LIBRARY_MEMORY / ERX_PAGE_SIZE,
	    &budget) != ERX_OK)
		return ("erx: domain: no principal budget\n");
	principals_held[0].budget = budget;
	if (erx_gate_create(0, &lib.held.gate) != ERX_OK || erx_gate_bind(lib.held.gate, ERX_CAP_SELF_THREAD, 0) != ERX_OK)
		return ("erx: domain: no fault gate\n");
	return (NULL);
}

/* A request for a domain whose program does what word says, with RELEASE and a connections quota. */
static const erx_dom_spec_t *
request_for(const char *word, uint32_t program, uint32_t connections)
{
	const size_t length = strlen(word) + 1;

	memset(&request, 0, sizeof(request));
	request.id = next_id++;
	request.principal = PRINCIPAL;
	request.runtime = program;
	request.release = release;
	request.release_files = 1;
	request.connections = connections;
	request.memory = 2 * MIB;
	request.outer = MIB;
	request.grant = (erx_grant_t){ .quota_ns = ERX_QUOTA_NONE, .cpuset = 1, .capacity_mcpu = 1000 };
	request.lane = ERX_LANE_MIN;
	memcpy(request.strings, word, length);
	request.args_len = (uint32_t)length;
	return (&request);
}

/* A request for a domain whose ERTS image boots the ERTS release with erts_args. */
static const erx_dom_spec_t *
erts_request(uint32_t runtime)
{
	(void)request_for("erts", runtime, 0);
	request.release = erts_release;
	request.release_files = erts_files;
	request.memory = ERTS_MEMORY;
	memcpy(request.strings, erts_args, sizeof(erts_args));
	request.args_len = (uint32_t)sizeof(erts_args);
	return (&request);
}

/*
 * The first entry under ERTS_RELEASE and the count of entries under it. The
 * index is sorted, so they are one run; an entry past a gap is refused.
 */
static bool
erts_release_find(const erx_pack_view_t *pack)
{
	const size_t prefix = strlen(ERTS_RELEASE);

	for (uint32_t index = 0; index < pack->header.nentries; index++) {
		const uint8_t *name;
		size_t length;

		if (!erx_pack_path_at(pack, index, &name, &length) || length <= prefix ||
		    memcmp(name, ERTS_RELEASE, prefix) != 0)
			continue;
		if (erts_files == 0)
			erts_release = index;
		else if (index != erts_release + erts_files)
			return (false);
		erts_files++;
	}
	return (erts_files != 0);
}

/* Waits at the gate until the library ends a domain, handling every record on the way. */
static bool
end_wait(erx_dom_report_t *report)
{
	const uint64_t deadline = erx_fiasco_clock_ns() + WAIT_NS;
	erx_fault_t record;
	uint64_t label;

	while (erx_dom_lib_take(deadline, &label, &record) == ERX_OK)
		if (erx_dom_lib_record(&lib, label, &record, report))
			return (true);
	return (false);
}

/* Whether mem, an object the root holds, takes a mapping of size bytes. */
static bool
maps(uint64_t mem, uint64_t size)
{
	uint64_t addr;
	bool mapped;

	if (size == 0 || erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &addr) != ERX_OK)
		return (false);
	mapped = erx_vm_map(ERX_CAP_SELF, addr, size, mem, 0, ERX_PROT_R) == ERX_OK;
	return (erx_vm_release(ERX_CAP_SELF, addr, size) == ERX_OK && mapped);
}

/*
 * Maps domain id's boot page into the root with prot, at *addr, and names
 * its handles in *held; the caller releases the mapping. False, with
 * nothing mapped, for an id with no record or a refused mapping.
 */
static bool
boot_page_map(uint32_t id, uint32_t prot, const erx_dom_handles_t **held, uint64_t *addr)
{
	*held = NULL;
	for (uint32_t slot = 0; slot < DOMAINS; slot++)
		if (domains[slot].id == id)
			*held = &handles[slot];
	if (*held == NULL || erx_vm_reserve(ERX_CAP_SELF, 0, ERX_PAGE_SIZE, 0, addr) != ERX_OK)
		return (false);
	if (erx_vm_map(ERX_CAP_SELF, *addr, ERX_PAGE_SIZE, (*held)->made[ERX_DOM_OBJ_BOOTINFO], 0, prot) == ERX_OK)
		return (true);
	(void)erx_vm_release(ERX_CAP_SELF, *addr, ERX_PAGE_SIZE);
	return (false);
}

/*
 * Whether domain id's boot page names the size of the lane it reads from the
 * system domain: the system domain's side takes a mapping of that lane's
 * bytes, and not of a lane twice as large.
 */
static bool
lanes_agree(uint32_t id)
{
	const erx_dom_handles_t *held;
	uint64_t addr, in_size;

	if (!boot_page_map(id, ERX_PROT_R, &held, &addr))
		return (false);
	in_size = ((const erx_boot_info_t *)(uintptr_t)addr)->system_connection.in_size;
	if (erx_vm_release(ERX_CAP_SELF, addr, ERX_PAGE_SIZE) != ERX_OK)
		return (false);
	say_count("in_size", in_size);
	return (maps(held->made[ERX_DOM_OBJ_SYS_SIDE], erx_lane_side_bytes(in_size)) &&
	    !maps(held->made[ERX_DOM_OBJ_SYS_SIDE], erx_lane_side_bytes(in_size * 2)));
}

/*
 * Spoils domain id's boot page through a writable mapping of the root's:
 * a version the reader refuses, so its runtime ends with the reason.
 */
static bool
page_spoil(uint32_t id)
{
	const erx_dom_handles_t *held;
	uint64_t addr;

	if (!boot_page_map(id, ERX_PROT_RW, &held, &addr))
		return (false);
	((erx_boot_info_t *)(uintptr_t)addr)->version = ERX_BOOT_VERSION + 1;
	return (erx_vm_release(ERX_CAP_SELF, addr, ERX_PAGE_SIZE) == ERX_OK);
}

/*
 * Creates the domain spec asks for, does what action says, and takes its
 * end; then disconnects and retires it. True when every call succeeded and
 * the end is kind with status.
 */
static bool
domain_run(const erx_dom_spec_t *spec, run_action_t action, erx_dom_end_kind_t kind, int64_t status)
{
	const uint32_t connections = spec->connections;
	erx_dom_created_t created;
	erx_dom_report_t report = { 0 };
	erx_status_t made = erx_dom_lib_create(&lib, spec, NULL, 0, &created);
	bool passed;

	if (made != ERX_OK) {
		say_count("create_status", (uint64_t)(int64_t)made);
		say_count("failed_step", lib.failed_at);
		return (false);
	}
	passed = created.connection != 0;
	if (passed && connections != 0)
		passed = lanes_agree(created.id);
	if (passed && action == RUN_SPOIL)
		passed = page_spoil(created.id);
	if (passed)
		passed = erx_dom_lib_start(&lib, created.id) == ERX_OK;
	/* A domain starts once. */
	if (passed)
		passed = erx_dom_lib_start(&lib, created.id) == ERX_EINVAL;
	if (passed && action == RUN_STOP)
		passed = erx_dom_lib_stop(&lib, created.id, STOP_STATUS) == ERX_OK;
	passed = passed && end_wait(&report) && report.id == created.id;
	say_count("end_kind", (uint64_t)report.end.kind);
	say_count("end_status", (uint64_t)report.end.status);
	passed = passed && report.end.kind == kind && report.end.status == status &&
	    erx_dom_lib_retire(&lib, created.id) == ERX_EBUSY;
	passed = erx_dom_lib_disconnect(&lib, created.connection) == ERX_OK && passed;
	return (erx_dom_lib_retire(&lib, created.id) == ERX_OK && passed);
}

/* The entries in use in the root's handle table. */
static uint32_t
handles_used(void)
{
	return (erx_fiasco_object_handles_used(ERX_FIASCO_TASK_ROOT));
}

/* The connection rows the view holds. */
static uint32_t
rows_used(void)
{
	uint32_t used = 0;

	for (uint32_t row = 0; row < CONNECTIONS; row++)
		used += connections[row].number != 0;
	return (used);
}

/* One case: its domain's run, with the pool as it was before. */
static void
case_end(const char *name, const erx_dom_spec_t *spec, run_action_t action, erx_dom_end_kind_t kind,
    int64_t status)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	const uint32_t held = handles_used();
	const bool passed = domain_run(spec, action, kind, status);

	say_count("free_pages_lost", before - erx_fiasco_vm_free_pages());
	say_count("handles_left", handles_used() - held);
	say_case(name, passed && erx_fiasco_vm_free_pages() == before && handles_used() == held);
}

/* Creates and starts a domain that waits to be stopped; its id, or 0. */
static uint32_t
waiter(uint32_t program, uint32_t *connection)
{
	erx_dom_created_t created;

	*connection = 0;
	if (erx_dom_lib_create(&lib, request_for("wait", program, 1), NULL, 0, &created) != ERX_OK ||
	    erx_dom_lib_start(&lib, created.id) != ERX_OK)
		return (0);
	*connection = created.connection;
	return (created.id);
}

/* Stops two waiters, takes both ends, disconnects them from the system domain and retires them. */
static bool
waiters_end(const uint32_t *ids, const uint32_t *system)
{
	erx_dom_report_t report;
	bool passed = true;

	for (int which = 0; which < 2; which++)
		passed = erx_dom_lib_stop(&lib, ids[which], STOP_STATUS) == ERX_OK && passed;
	for (int which = 0; which < 2; which++)
		passed = end_wait(&report) && report.end.kind == ERX_DOM_END_STOPPED && passed;
	for (int which = 0; which < 2; which++)
		passed = erx_dom_lib_disconnect(&lib, system[which]) == ERX_OK &&
		    erx_dom_lib_retire(&lib, ids[which]) == ERX_OK && passed;
	return (passed);
}

/*
 * A connection between two running domains: each party is given its side,
 * the other's side and the other's bell, and its own bell's label, past the
 * system connection's; a self-connection is refused, and a disconnect frees
 * the row once; a second connection takes the next labels and no page. Then a connect refused at each step in
 * turn, before the step and once it has made its object, is undone with the
 * pool, the handles and the rows as they were. Last, the domains end, and
 * the pool and the handles are those of before the case.
 */
static void
case_link(uint32_t program)
{
	uint64_t before;
	uint32_t held;
	erx_dom_linked_t linked = { 0 };
	uint32_t ids[2], system[2], steps = 0;
	uint64_t pages, warm;
	uint32_t handles, rows;
	bool passed;

	/* Two domains alive at once grow the service's task tables first, which they keep; not counted. */
	ids[0] = waiter(program, &system[0]);
	ids[1] = waiter(program, &system[1]);
	passed = ids[0] != 0 && ids[1] != 0 && waiters_end(ids, system);
	say_case("link_warm", passed);
	before = erx_fiasco_vm_free_pages();
	held = handles_used();
	ids[0] = waiter(program, &system[0]);
	ids[1] = waiter(program, &system[1]);
	pages = erx_fiasco_vm_free_pages();
	passed = passed && ids[0] != 0 && ids[1] != 0 &&
	    erx_dom_lib_connect(&lib, ids[0], ids[0], ERX_LANE_MIN, ERX_LANE_MIN, &linked) == ERX_EINVAL &&
	    erx_dom_lib_connect(&lib, ids[0], ids[1], ERX_LANE_MIN, ERX_LANE_MIN, &linked) == ERX_OK &&
	    linked.number != 0 && linked.a.side != ERX_CAP_NULL && linked.a.peer_side != ERX_CAP_NULL &&
	    linked.a.peer_bell != ERX_CAP_NULL && linked.b.side != ERX_CAP_NULL &&
	    linked.b.peer_side != ERX_CAP_NULL && linked.b.peer_bell != ERX_CAP_NULL &&
	    linked.a.label == ERX_DOM_SYSTEM_LABEL + 1 && linked.b.label == ERX_DOM_SYSTEM_LABEL + 1 &&
	    erx_dom_lib_disconnect(&lib, linked.number) == ERX_OK &&
	    erx_dom_lib_disconnect(&lib, linked.number) == ERX_EINVAL;
	/* The first connection takes the service's tables' pages, as the first domain does; a second takes none. */
	warm = pages - erx_fiasco_vm_free_pages();
	pages = erx_fiasco_vm_free_pages();
	passed = passed && erx_dom_lib_connect(&lib, ids[0], ids[1], ERX_LANE_MIN, ERX_LANE_MIN, &linked) == ERX_OK &&
	    linked.a.label == ERX_DOM_SYSTEM_LABEL + 2 && erx_dom_lib_disconnect(&lib, linked.number) == ERX_OK &&
	    erx_fiasco_vm_free_pages() == pages;
	say_count("link_warm_pages", warm);
	say_case("link", passed);

	pages = erx_fiasco_vm_free_pages();
	handles = handles_used();
	rows = rows_used();
	for (uint32_t step = 0; passed && step < 2 * ERX_DOM_LINK_STEPS; step++) {
		lib.fail_step = step / 2;
		lib.fail_made = step % 2 != 0;
		passed = erx_dom_lib_connect(&lib, ids[0], ids[1], ERX_LANE_MIN, ERX_LANE_MIN, &linked) == ERX_ENOMEM &&
		    lib.failed_at == step / 2 && erx_fiasco_vm_free_pages() == pages && handles_used() == handles &&
		    rows_used() == rows;
		steps = passed ? step + 1 : step;
	}
	lib.fail_step = UINT32_MAX;
	lib.fail_made = false;
	say_count("link_undo_steps", steps);
	say_case("link_undo", passed && steps == 2 * ERX_DOM_LINK_STEPS);

	passed = waiters_end(ids, system);
	say_count("link_ended", passed);
	say_count("free_pages_lost", before - erx_fiasco_vm_free_pages());
	say_count("handles_left", handles_used() - held);
	say_case("link_end", passed && erx_fiasco_vm_free_pages() + warm == before && handles_used() == held);
}

/*
 * A create refused at each step in turn (the hooked failure), which the
 * library undoes: ERX_ENOMEM, no record taken, nothing left in the pool.
 */
static void
case_undo(uint32_t program)
{
	static erx_dom_plan_t plan;
	const uint64_t before = erx_fiasco_vm_free_pages();
	const uint32_t held = handles_used();
	erx_dom_created_t created;
	bool passed = erx_dom_plan_request(&lib.view, request_for("halt", program, 0), NULL, 0, &plan) == ERX_OK;
	uint32_t failed = 0;

	/* Each step twice: refused before it is applied, then once it has made its object. */
	for (uint32_t step = 0; passed && step < 2 * plan.nsteps; step++) {
		lib.fail_step = step / 2;
		lib.fail_made = step % 2 != 0;
		passed = erx_dom_lib_create(&lib, request_for("halt", program, 0), NULL, 0, &created) == ERX_ENOMEM &&
		    lib.failed_at == step / 2 && erx_fiasco_vm_free_pages() == before && handles_used() == held &&
		    principals[0].domains == 0 && domains[0].id == 0 && connections[0].number == 0;
		failed = passed ? step + 1 : step;
	}
	lib.fail_step = UINT32_MAX;
	lib.fail_made = false;
	say_count("undo_steps", failed);
	say_case("undo", passed && failed == 2 * plan.nsteps);
}

void
erx_fiasco_root_main(void)
{
	erx_boot_handoff_view_t handoff;
	static erx_pack_view_t pack;
	const char *reason = erx_fiasco_root_open(&handoff, &pack);
	uint32_t program = 0, erts = 0;

	if (reason == NULL)
		reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff.image.start, (size_t)handoff.image.size);
	if (reason == NULL && (erx_fiasco_launcher_find(&pack, PROGRAM, &program) != ERX_OK ||
	    erx_fiasco_launcher_find(&pack, RELEASE, &release) != ERX_OK ||
	    erx_fiasco_launcher_find(&pack, ERTS, &erts) != ERX_OK || !erts_release_find(&pack)))
		reason = "erx: domain: no program or release\n";
	if (reason == NULL) {
		erx_fiasco_task_set_archive(&pack);
		files_from(&pack, program);
		files[erts].kind = ERX_ENTRY_IMAGE;
		files[erts].image_ok = true;
		reason = library_up();
	}
	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	say_case("library", true);
	/* The first run takes the root's and the service's tables' pages, so it is not counted. */
	say_case("warm", domain_run(request_for("halt", program, 0), RUN_PLAIN, ERX_DOM_END_HALT, HALT_STATUS));
	case_end("halt", request_for("halt", program, 0), RUN_PLAIN, ERX_DOM_END_HALT, HALT_STATUS);
	case_end("fault", request_for("fault", program, 0), RUN_PLAIN, ERX_DOM_END_FAULT, ERX_FAULT_MEMORY);
	case_end("stop", request_for("wait", program, 0), RUN_STOP, ERX_DOM_END_STOPPED, 0);
	case_end("lanes", request_for("halt", program, 1), RUN_PLAIN, ERX_DOM_END_HALT, HALT_STATUS);
	case_end("erts", erts_request(erts), RUN_PLAIN, ERX_DOM_END_HALT, 0);
	case_end("erts_refused", erts_request(erts), RUN_SPOIL, ERX_DOM_END_HALT, ERX_FIASCO_TASK_STATUS_BOOT_PAGE);
	case_link(program);
	case_undo(program);
	say("erx: domain: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	erx_fiasco_sleep_forever();
}
