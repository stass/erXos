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
 * reads a lane larger than its own, whose size its boot page must name. After each end the domain is disconnected and
 * retired, and the pool holds what it held before. Then a create fails at each
 * step in turn and is undone, leaving the pool and the view as they were. Each
 * case says one line, which tools/lib/erx/native_domain.rb holds the transcript to.
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
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_domain/modes.h"

#define PROGRAM		"boot/native-domain"
#define RELEASE		"domains/native/release"
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
static erx_grant_t service_grants[DOMAINS];
static erx_dom_handles_t handles[DOMAINS];
static erx_dom_file_t files[ERX_PACK_ENTRIES_MAX];
static erx_dom_lib_t lib;
static erx_dom_spec_t request;
static uint32_t release;
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

	principals[0] = (erx_dom_principal_t){ .number = PRINCIPAL, .memory = 64 * MIB, .domains_max = DOMAINS,
	    .share = share, .default_limits = limits_default(), .ceiling_limits = limits_default() };
	lib.view = (erx_dom_view_t){ .domains = domains, .max_domains = DOMAINS, .connections = connections,
	    .max_connections = CONNECTIONS, .principals = principals, .nprincipals = 1, .files = files,
	    .nfiles = ERX_PACK_ENTRIES_MAX, .native_limits = limits_default(), .system_grant = share,
	    .service_grants = service_grants, .system_lane = ERX_LANE_MIN, .next_connection = 1,
	    .system_space = ERX_FIASCO_TASK_ROOT };
	lib.handles = handles;
	lib.host = "erxos";
	lib.host_len = 5;
	lib.cap_limit = 64;
	lib.fail_step = UINT32_MAX;
	lib.held.time_page = erx_fiasco_time_object();
	if (erx_group_create(0, 0, &lib.held.system_group) != ERX_OK ||
	    erx_group_create(0, 0, &lib.held.principal_group) != ERX_OK)
		return ("erx: domain: no groups\n");
	if (erx_budget_create(ERX_CAP_SELF, ERX_BUDGET_ELASTIC, 64 * MIB / ERX_PAGE_SIZE, 64 * MIB / ERX_PAGE_SIZE,
	    &budget) != ERX_OK)
		return ("erx: domain: no principal budget\n");
	lib.held.principal_budget = budget;
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
 * Whether domain id's boot page names the size of the lane it reads from the
 * system domain: the system domain's side takes a mapping of that lane's
 * bytes, and not of a lane twice as large.
 */
static bool
lanes_agree(uint32_t id)
{
	const erx_dom_handles_t *held = NULL;
	uint64_t addr, in_size;
	bool mapped;

	for (uint32_t slot = 0; slot < DOMAINS; slot++)
		if (domains[slot].id == id)
			held = &handles[slot];
	if (held == NULL || erx_vm_reserve(ERX_CAP_SELF, 0, ERX_PAGE_SIZE, 0, &addr) != ERX_OK)
		return (false);
	mapped = erx_vm_map(ERX_CAP_SELF, addr, ERX_PAGE_SIZE, held->made[ERX_DOM_OBJ_BOOTINFO], 0, ERX_PROT_R) == ERX_OK;
	in_size = mapped ? ((const erx_boot_info_t *)(uintptr_t)addr)->system_connection.in_size : 0;
	if (erx_vm_release(ERX_CAP_SELF, addr, ERX_PAGE_SIZE) != ERX_OK || !mapped)
		return (false);
	say_count("in_size", in_size);
	return (maps(held->made[ERX_DOM_OBJ_SYS_SIDE], erx_lane_side_bytes(in_size)) &&
	    !maps(held->made[ERX_DOM_OBJ_SYS_SIDE], erx_lane_side_bytes(in_size * 2)));
}

/*
 * Creates a domain running word, starts it, stops it with STOP_STATUS when
 * stop is set, and takes its end; then disconnects and retires it. True when
 * every call succeeded and the end is kind with status.
 */
static bool
domain_run(const char *word, uint32_t program, uint32_t connections, bool stop, erx_dom_end_kind_t kind,
    int64_t status)
{
	erx_dom_created_t created;
	erx_dom_report_t report = { 0 };
	erx_status_t made = erx_dom_lib_create(&lib, request_for(word, program, connections), NULL, 0, &created);
	bool passed;

	if (made != ERX_OK) {
		say_count("create_status", (uint64_t)(int64_t)made);
		say_count("failed_step", lib.failed_at);
		return (false);
	}
	passed = created.connection != 0 && (connections == 0 || lanes_agree(created.id)) &&
	    erx_dom_lib_start(&lib, created.id) == ERX_OK &&
	    erx_dom_lib_start(&lib, created.id) == ERX_EINVAL;
	if (passed && stop)
		passed = erx_dom_lib_stop(&lib, created.id, STOP_STATUS) == ERX_OK;
	passed = passed && end_wait(&report) && report.id == created.id;
	say_count("end_kind", (uint64_t)report.end.kind);
	say_count("end_status", (uint64_t)report.end.status);
	passed = passed && report.end.kind == kind && report.end.status == status &&
	    erx_dom_lib_retire(&lib, created.id) == ERX_EBUSY;
	passed = erx_dom_lib_disconnect(&lib, created.connection) == ERX_OK && passed;
	return (erx_dom_lib_retire(&lib, created.id) == ERX_OK && passed);
}

/* One case: its domain's run, with the pool as it was before. */
static void
case_end(const char *name, const char *word, uint32_t program, uint32_t connections, bool stop,
    erx_dom_end_kind_t kind, int64_t status)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	const bool passed = domain_run(word, program, connections, stop, kind, status);

	say_count("free_pages_lost", before - erx_fiasco_vm_free_pages());
	say_case(name, passed && erx_fiasco_vm_free_pages() == before);
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
	erx_dom_created_t created;
	bool passed = erx_dom_plan_request(&lib.view, request_for("halt", program, 0), NULL, 0, &plan) == ERX_OK;
	uint32_t failed = 0;

	for (uint32_t step = 0; passed && step < plan.nsteps; step++) {
		lib.fail_step = step;
		passed = erx_dom_lib_create(&lib, request_for("halt", program, 0), NULL, 0, &created) == ERX_ENOMEM &&
		    erx_fiasco_vm_free_pages() == before && principals[0].domains == 0 && domains[0].id == 0 &&
		    connections[0].number == 0;
		failed = passed ? step + 1 : step;
	}
	lib.fail_step = UINT32_MAX;
	say_count("undo_steps", failed);
	say_case("undo", passed && failed == plan.nsteps);
}

void
erx_fiasco_root_main(void)
{
	erx_boot_handoff_view_t handoff;
	static erx_pack_view_t pack;
	const char *reason = erx_fiasco_root_open(&handoff, &pack);
	uint32_t program = 0;

	if (reason == NULL)
		reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff.image.start, (size_t)handoff.image.size);
	if (reason == NULL && (erx_fiasco_launcher_find(&pack, PROGRAM, &program) != ERX_OK ||
	    erx_fiasco_launcher_find(&pack, RELEASE, &release) != ERX_OK))
		reason = "erx: domain: no program or release\n";
	if (reason == NULL) {
		erx_fiasco_task_set_archive(&pack);
		files_from(&pack, program);
		reason = library_up();
	}
	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	say_case("library", true);
	/* The first run takes the root's and the service's tables' pages, so it is not counted. */
	say_case("warm", domain_run("halt", program, 0, false, ERX_DOM_END_HALT, HALT_STATUS));
	case_end("halt", "halt", program, 0, false, ERX_DOM_END_HALT, HALT_STATUS);
	case_end("fault", "fault", program, 0, false, ERX_DOM_END_FAULT, ERX_FAULT_MEMORY);
	case_end("stop", "wait", program, 0, true, ERX_DOM_END_STOPPED, 0);
	case_end("lanes", "halt", program, 1, false, ERX_DOM_END_HALT, HALT_STATUS);
	case_undo(program);
	say("erx: domain: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	erx_fiasco_sleep_forever();
}
