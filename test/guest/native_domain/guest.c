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
 * entry with the reader's reason, before ERTS runs. Three domains run the
 * BeamAsm image (JIT) on the same release, in spaces made with ERX_SPACE_JIT
 * from the image's flag: one reloads a module in a loop while a process on
 * each of the domain's CPUs calls it and finds no stale code, and halts with 0;
 * in the others a block of the code space runs through its executable alias,
 * then is written through that alias, or run through its writable one, which
 * ends the domain with a memory fault (jit_reload.erl).
 * Then an ERTS domain opens
 * its system connection's lane port, and the root, as the system domain with
 * liberx's lane writer and reader, takes a burst that fills the lane while it
 * does not read, and monitors a pid the domain does not have, which the
 * domain's drain answers with DOWN noproc, then floods it with LINKs to that
 * pid without reading their answers, which ends the domain's port. After each end the domain
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
#include "erx/abi_reader.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "erx/etf.h"
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
#include "liberx/backend/fiasco/umtx.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_domain/modes.h"

#define PROGRAM		"boot/native-domain"
#define RELEASE		"domains/native/release"
#define ERTS		"runtimes/emu"
#define JIT		"runtimes/jit"
#define ERTS_RELEASE	"domains/erts/"
#define ERTS_MEMORY	(UINT64_C(160) << 20)
#define LIBRARY_MEMORY	(UINT64_C(256) << 20)
/* Under the suite's 60 s per case: a BeamAsm domain boots and reloads for some seconds. */
#define WAIT_NS		UINT64_C(50000000000)
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
#define ERTS_BOOT	"--\0-root\0/\0-bindir\0/bin\0-progname\0erl\0-home\0/\0" \
    "-boot\0/bin/start\0-nouser\0-nocookie\0-kernel\0start_distribution\0false\0-eval\0"
static const char erts_args[] = ERTS_BOOT "erlang:display(init_started),erlang:halt(0)";
/* What a BeamAsm domain runs: jit_reload, from the release's /test/, in one of its modes. */
#define JIT_RUN(mode)	ERTS_BOOT "{ok,B}=erl_prim_loader:read_file(\"/test/jit_reload.beam\")," \
    "{module,jit_reload}=erlang:load_module(jit_reload,B),jit_reload:run(" mode ")"
static const char jit_reload_args[] = JIT_RUN("reload");
static const char jit_write_rx_args[] = JIT_RUN("write_rx");
static const char jit_run_rw_args[] = JIT_RUN("run_rw");

/* What a case does between a domain's create and its end. */
typedef enum run_action {
	RUN_PLAIN,	/* starts it and waits */
	RUN_STOP,	/* starts it, then stops it with STOP_STATUS */
	RUN_SPOIL,	/* spoils its boot page's version, then starts it */
	RUN_LANE	/* starts it, then plays the system party on its connection */
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
	/* Every CPU, so that a BeamAsm domain can run on each. */
	const uint64_t cpus = erx_fiasco_cpus_online();
	const erx_grant_t share = { .quota_ns = ERX_QUOTA_NONE, .cpuset = cpus,
	    .capacity_mcpu = 1000 * (uint32_t)__builtin_popcountll(cpus) };
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
	request.name_len = 5;
	memcpy(request.name, "guest", 5);
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
 * A request for a domain whose BeamAsm image runs args (a JIT_RUN) on the
 * ERTS release, on every CPU.
 */
static const erx_dom_spec_t *
jit_request(uint32_t runtime, const char *args, size_t args_len)
{
	const uint64_t cpus = erx_fiasco_cpus_online();

	(void)erts_request(runtime);
	request.grant = (erx_grant_t){ .quota_ns = ERX_QUOTA_NONE, .cpuset = cpus,
	    .capacity_mcpu = 1000 * (uint32_t)__builtin_popcountll(cpus) };
	memcpy(request.strings, args, args_len);
	request.args_len = (uint32_t)args_len;
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
 * The connection case's domain: ERTS made alive as d<id>@erxos with its domain id as
 * creation, the system connection's lane port opened toward SYSTEM_NODE and made the
 * controller of that node's entry with the frames' flag set and the system domain's id as
 * creation, then BURST messages of a KiB each to a pid of the system node, more than the
 * lane holds. It waits until the port's counts show the burst and one answer sent, says
 * them, then waits for the port to end with erx_lane_answers_unread under the party's
 * flood of LINKs, and halts with 0 only when output paused for room and resumed on the
 * bell, the drain answered, and the port ended so. Each '~' is the domain's id.
 */
#define SYSTEM_NODE	"sys@erxos"
#define BURST		16
#define TEXT_OF_(x)	#x
#define TEXT_OF(x)	TEXT_OF_(x)
#define BURST_TEXT	TEXT_OF(BURST)	/* BURST, as the expression writes it */
static const char connection_eval[] =
    "register(net_kernel,self()),"
    "process_flag(trap_exit,true),"
    "true=erlang:setnode('d~@erxos',~),"
    "P=open_port({spawn_driver,\"erx_lane system " SYSTEM_NODE "\"},[binary]),"
    /* PUBLISHED, DIST_MONITOR(_NAME), UNICODE_IO, SEND_SENDER, EXIT_PAYLOAD; SPAWN, ALIAS, NATIVE_RECORDS */
    "F=element(3,erts_internal:get_dflags()) bor 16#481029 bor (16#49 bsl 32),"
    /* net_kernel makes the entry pending before setnode/3, as erx_dist does */
    "_=erts_internal:new_connection('" SYSTEM_NODE "'),"
    "_=erlang:setnode('" SYSTEM_NODE "',P,{F,4}),"
    /* erx_dist's run of the input task, for frames that came before the port controlled the entry */
    "<<>>=iolist_to_binary(erlang:port_control(P,1,[])),"
    "S=binary_to_term(<<131,88,119,9,\"" SYSTEM_NODE "\",1:32,0:32,4:32>>),"
    "B=binary:copy(<<7>>,1024),"
    "[S!{burst,I,B}||I<-lists:seq(1," BURST_TEXT ")],"
    "W=fun W(T)->case iolist_to_binary(erlang:port_control(P,0,[])) of "
    "<<N:64,Pa:64,R:64,_:64,A:64,_/binary>> when (N>" BURST_TEXT " andalso A>0) orelse T==0->{N,Pa,R,A};"
    "_->receive after 50->W(T-1) end end end,"
    "{N,Pa,R,A}=W(600),"
    "erlang:display({lane,N,Pa,R,A}),"
    /* the party's flood of LINKs it never reads the answers to ends the port */
    "U=receive {'EXIT',P,erx_lane_answers_unread}->1 after 60000->0 end,"
    "erlang:halt(if N>" BURST_TEXT ",Pa>0,R>0,A>0,U==1->0;true->1 end)";

/* How long the party waits for the domain's first frame, and for each later one. */
#define FIRST_NS	UINT64_C(60000000000)
#define NEXT_NS		UINT64_C(10000000000)
/* How long it leaves the lane unread, so the burst fills it. */
#define STALL_NS	UINT64_C(1000000000)
#define POLL_NS		UINT64_C(10000000)
/* The most LINKs the flood writes: far more than ERX_LANE_ANSWERS_MAX of answers. */
#define FLOOD_MAX	200000u
#define RECORD_MAX	2048u
/* The most REG_SENDs of the domain's own services the party skips before each frame it waits for. */
#define SKIP_MAX	8u
#define DOP_LINK		1
#define DOP_REG_SEND		6
#define DOP_SEND_SENDER		22
#define DOP_MONITOR_P		19
#define DOP_PAYLOAD_MONITOR_P_EXIT	28
/* A pid of the domain no process has: a number in ERTS's internal range. */
#define ABSENT_PID	4095u

/* The system party's ends of one domain's system connection, mapped into the root. */
typedef struct lane_party {
	erx_lane_writer_t	 writer;	/* the system domain's lane to the domain */
	erx_lane_reader_t	 reader;	/* the domain's lane to the system domain */
	uint64_t		 bell;		/* the domain's bell */
	uint32_t		 id;		/* the domain's id, its node's creation */
	uint32_t		 peer;		/* the system domain's id, as the page names it */
} lane_party_t;

/* Appends text to buf at *at, each '~' as id in decimal. False when it does not fit. */
static bool
args_put(char *buf, size_t cap, size_t *at, const char *text, uint32_t id)
{
	for (; *text != '\0'; text++) {
		char digits[10];
		size_t n = 0;
		uint32_t v = id;

		if (*text != '~') {
			if (*at >= cap)
				return (false);
			buf[(*at)++] = *text;
			continue;
		}
		do {
			digits[n++] = (char)('0' + v % 10);
			v /= 10;
		} while (v != 0);
		while (n > 0) {
			if (*at >= cap)
				return (false);
			buf[(*at)++] = digits[--n];
		}
	}
	return (true);
}

/* A request for an ERTS domain whose -eval is connection_eval with its own id. */
static const erx_dom_spec_t *
connection_request(uint32_t runtime)
{
	static const char eval_word[] = "-eval";
	size_t at;

	(void)erts_request(runtime);
	/* erts_args ends with "-eval\0" and its expression; keep the word, swap the expression. */
	at = 0;
	for (size_t i = 0; i + sizeof(eval_word) <= sizeof(erts_args); i++)
		if (memcmp(&erts_args[i], eval_word, sizeof(eval_word)) == 0)
			at = i + sizeof(eval_word);
	if (at == 0 || !args_put(request.strings, sizeof(request.strings) - 1, &at, connection_eval, request.id))
		return (NULL);
	request.strings[at++] = '\0';
	request.args_len = (uint32_t)at;
	return (&request);
}

/* Whether the domain the party plays against ended while it waited, and its end. */
static bool party_ended;
static erx_dom_report_t party_report;

/*
 * Waits ns, serving the domain's records meanwhile: the root is its pager, so a domain
 * whose fault waits for the root stops until the root takes it. Notes the domain's end.
 */
static void
party_sleep(uint64_t ns)
{
	static uint32_t never;
	const uint64_t deadline = erx_fiasco_clock_ns() + ns;
	erx_fault_t record;
	uint64_t label;

	while (!party_ended && erx_dom_lib_take(deadline, &label, &record) == ERX_OK)
		party_ended = erx_dom_lib_record(&lib, label, &record, &party_report);
	(void)erx_umtx_wait((uint64_t)(uintptr_t)&never, 0, deadline);
}

/*
 * Takes the domain's next frame record whole into buf, ringing the domain's bell when a
 * read crosses the room its output waits for. False on a deadline, a lane that fails a
 * check, or a record that is not a frame or is larger than RECORD_MAX.
 */
static bool
party_take(lane_party_t *party, uint8_t *buf, uint64_t wait_ns, size_t *len)
{
	const uint64_t deadline = erx_fiasco_clock_ns() + wait_ns;
	size_t got = 0;

	for (;;) {
		erx_lane_part_t part;
		const erx_lane_status_t status = erx_lane_take(&party->reader, buf + got, RECORD_MAX - got, &part);

		if (status == ERX_LANE_TOOK && part.ring && erx_irq_trigger(party->bell) != ERX_OK)
			return (false);
		if (status == ERX_LANE_MALFORMED)
			return (false);
		if (status == ERX_LANE_EMPTY) {
			if (erx_fiasco_clock_ns() > deadline)
				return (false);
			party_sleep(POLL_NS);
			continue;
		}
		if (part.opened && (part.kind != ERX_REC_FRAME || part.len > RECORD_MAX))
			return (false);
		got += part.copied;
		if (part.closed) {
			*len = got;
			return (true);
		}
	}
}

static void
party_pid(erx_etf_writer_t *writer, const char *node, uint32_t id, uint32_t creation)
{
	const erx_etf_pid_t pid = { .node = (const uint8_t *)node, .node_len = strlen(node), .id = id,
	    .creation = creation };

	erx_etf_put_pid(writer, &pid);
}

/*
 * Writes a frame of control term ctl and no payload, waiting up to wait_ns for room, and
 * rings the domain's bell when a write crosses its wake. False when the lane refused it,
 * or when no room came by then: the domain stopped taking frames.
 */
static bool
party_put(lane_party_t *party, const uint8_t *ctl, size_t ctl_len, uint64_t wait_ns)
{
	const uint64_t deadline = erx_fiasco_clock_ns() + wait_ns;
	/* The frame header is little-endian on the wire, as this machine is. */
	const erx_frame_header_t header = { .ctl_len = (uint32_t)ctl_len };
	const erx_lane_iov_t iov[2] = { { .base = &header, .len = sizeof(header) }, { .base = ctl, .len = ctl_len } };
	const erx_lane_item_t item = { .iov = iov, .iovcnt = 2, .kind = ERX_REC_FRAME };

	for (;;) {
		erx_lane_put_t put;
		const erx_lane_put_status_t status = erx_lane_put(&party->writer, &item, &put);

		if (put.ring && erx_irq_trigger(party->bell) != ERX_OK)
			return (false);
		if (status == ERX_LANE_PUT_DONE)
			return (true);
		if (status != ERX_LANE_PUT_SHORT || erx_fiasco_clock_ns() > deadline)
			return (false);
		party_sleep(POLL_NS);
	}
}

/* Writes a MONITOR_P frame from a system process to a pid of the domain that no process has. */
static bool
party_monitor(lane_party_t *party)
{
	char node[24];
	size_t node_len = 0, ctl_len;
	uint8_t ctl[160];
	const erx_etf_ref_t ref = { .node = (const uint8_t *)SYSTEM_NODE, .node_len = sizeof(SYSTEM_NODE) - 1,
	    .creation = party->peer, .words = { 1, 2, 3, 0 } };
	erx_etf_writer_t writer;

	if (!args_put(node, sizeof(node) - 1, &node_len, "d~@erxos", party->id))
		return (false);
	node[node_len] = '\0';
	erx_etf_writer_init(&writer, ctl, sizeof(ctl));
	erx_etf_put_tuple(&writer, 4);
	erx_etf_put_integer(&writer, DOP_MONITOR_P);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	party_pid(&writer, node, ABSENT_PID, party->id);
	erx_etf_put_ref(&writer, &ref);
	return (erx_etf_writer_done(&writer, &ctl_len) && party_put(party, ctl, ctl_len, NEXT_NS));
}

/*
 * Floods the domain with LINKs from a system process to a pid of the domain that no
 * process has, reading none of the exits that answer them, until the domain stops taking
 * them: past ERX_LANE_ANSWERS_MAX of answers unsent its port ends, and the domain halts.
 * True when a LINK waited STALL_NS for room, or the domain ended, before FLOOD_MAX.
 */
static bool
party_flood(lane_party_t *party)
{
	char node[24];
	size_t node_len = 0, ctl_len;
	uint8_t ctl[160];
	erx_etf_writer_t writer;

	if (!args_put(node, sizeof(node) - 1, &node_len, "d~@erxos", party->id))
		return (false);
	node[node_len] = '\0';
	erx_etf_writer_init(&writer, ctl, sizeof(ctl));
	erx_etf_put_tuple(&writer, 3);
	erx_etf_put_integer(&writer, DOP_LINK);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	party_pid(&writer, node, ABSENT_PID, party->id);
	if (!erx_etf_writer_done(&writer, &ctl_len))
		return (false);
	for (uint32_t sent = 0; sent < FLOOD_MAX && !party_ended; sent++) {
		if (!party_put(party, ctl, ctl_len, STALL_NS))
			return (true);
	}
	return (party_ended);
}

/* A term of a frame without its version byte, which ERTS's pass-through encoding writes. */
static void
party_term_bare(const uint8_t **term, size_t *len)
{
	if (*len > 0 && (*term)[0] == 131) {
		(*term)++;
		(*len)--;
	}
}

/* A frame record's control term and payload, each without its version byte. */
typedef struct party_frame {
	const uint8_t	*ctl, *payload;
	size_t		 ctl_len, payload_len;
} party_frame_t;

/* Splits a frame record. False when its header does not describe the record. */
static bool
party_frame_split(const uint8_t *record, size_t len, party_frame_t *frame)
{
	erx_frame_header_t header;

	if (!erx_frame_header_decode(record, len, &header) || header.ctl_len > len - ERX_FRAME_HEADER_SIZE ||
	    header.payload_len != len - ERX_FRAME_HEADER_SIZE - header.ctl_len)
		return (false);
	frame->ctl = record + ERX_FRAME_HEADER_SIZE;
	frame->ctl_len = header.ctl_len;
	frame->payload = frame->ctl + frame->ctl_len;
	frame->payload_len = header.payload_len;
	party_term_bare(&frame->ctl, &frame->ctl_len);
	party_term_bare(&frame->payload, &frame->payload_len);
	return (true);
}

/* Whether a frame's control term starts with head. */
static bool
party_ctl_starts(const party_frame_t *frame, const uint8_t *head, size_t head_len)
{
	return (frame->ctl_len > head_len && memcmp(frame->ctl, head, head_len) == 0);
}

/*
 * Whether a frame record is the absent target's DOWN. The connection's flags carry
 * EXIT_PAYLOAD, so ERTS sends it as {28, _, _, _} with noproc as the payload
 * (dist.c, erts_dsig_send_m_exit), not as the 5-tuple DOP_MONITOR_P_EXIT.
 */
static bool
party_down_noproc(const uint8_t *record, size_t len)
{
	/* SMALL_TUPLE_EXT of 4, SMALL_INTEGER_EXT DOP_PAYLOAD_MONITOR_P_EXIT; SMALL_ATOM_UTF8_EXT noproc */
	static const uint8_t head[] = { 104, 4, 97, DOP_PAYLOAD_MONITOR_P_EXIT };
	static const uint8_t reason[] = { 119, 6, 'n', 'o', 'p', 'r', 'o', 'c' };
	party_frame_t frame;

	return (party_frame_split(record, len, &frame) && party_ctl_starts(&frame, head, sizeof(head)) &&
	    frame.payload_len == sizeof(reason) && memcmp(frame.payload, reason, sizeof(reason)) == 0);
}

/* I is one SMALL_INTEGER_EXT byte only below 256. */
_Static_assert(BURST < 256, "party_burst_index reads I as one byte");

/*
 * The I of a frame of the eval's burst, a SEND_SENDER of {burst, I, B} to a pid; 0 for
 * any other frame.
 */
static uint32_t
party_burst_index(const uint8_t *record, size_t len)
{
	/* SMALL_TUPLE_EXT of 3, SMALL_INTEGER_EXT DOP_SEND_SENDER */
	static const uint8_t ctl_head[] = { 104, 3, 97, DOP_SEND_SENDER };
	/* SMALL_TUPLE_EXT of 3, SMALL_ATOM_UTF8_EXT burst, SMALL_INTEGER_EXT; I follows */
	static const uint8_t head[] = { 104, 3, 119, 5, 'b', 'u', 'r', 's', 't', 97 };
	party_frame_t frame;

	if (!party_frame_split(record, len, &frame) || !party_ctl_starts(&frame, ctl_head, sizeof(ctl_head)) ||
	    frame.payload_len <= sizeof(head) || memcmp(frame.payload, head, sizeof(head)) != 0)
		return (0);
	return (frame.payload[sizeof(head)]);
}

/*
 * Takes the domain's next frame that is not a REG_SEND. The domain's own kernel services
 * send REG_SENDs when the connection comes up (rex's features_request, global's
 * init_connect), in no fixed order with the eval's frames, which go to pids; the party
 * skips at most SKIP_MAX of them. False also for a record its header does not describe.
 */
static bool
party_take_eval(lane_party_t *party, uint8_t *record, uint64_t wait_ns, size_t *len)
{
	/* SMALL_TUPLE_EXT of 4, SMALL_INTEGER_EXT DOP_REG_SEND */
	static const uint8_t reg_send[] = { 104, 4, 97, DOP_REG_SEND };
	party_frame_t frame;

	for (uint32_t skipped = 0; skipped <= SKIP_MAX; skipped++) {
		if (!party_take(party, record, wait_ns, len) || !party_frame_split(record, *len, &frame))
			return (false);
		if (!party_ctl_starts(&frame, reg_send, sizeof(reg_send)))
			return (true);
	}
	return (false);
}

/*
 * The system party on domain id's system connection: takes the burst's first frame,
 * leaves the lane unread for STALL_NS so the rest waits for room, takes the rest in
 * order, then monitors an absent pid of the domain and takes the DOWN noproc the
 * domain's drain answers, then floods LINKs without reading their answers
 * (party_flood). Skips the domain's REG_SENDs throughout (party_take_eval). Serves the
 * domain's records as it waits, noting its end. Maps both sides as the system domain's
 * runtime would, and releases them.
 */
static bool
lane_party(uint32_t id)
{
	static uint8_t record[RECORD_MAX];
	const erx_dom_handles_t *held;
	erx_boot_connection_t sys;
	lane_party_t party = { .id = id };
	uint64_t page, own = 0, peer = 0, own_bytes, peer_bytes;
	size_t len;
	bool passed;

	party_ended = false;
	if (!boot_page_map(id, ERX_PROT_R, &held, &page))
		return (false);
	sys = ((const erx_boot_info_t *)(uintptr_t)page)->system_connection;
	if (erx_vm_release(ERX_CAP_SELF, page, ERX_PAGE_SIZE) != ERX_OK)
		return (false);
	party.bell = held->made[ERX_DOM_OBJ_DOM_BELL];
	party.peer = sys.peer;
	own_bytes = erx_lane_side_bytes(sys.in_size);
	peer_bytes = erx_lane_side_bytes(sys.out_size);
	passed = erx_vm_reserve(ERX_CAP_SELF, 0, own_bytes, 0, &own) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, own, own_bytes, held->made[ERX_DOM_OBJ_SYS_SIDE], 0, ERX_PROT_RW) == ERX_OK &&
	    erx_vm_reserve(ERX_CAP_SELF, 0, peer_bytes, 0, &peer) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, peer, peer_bytes, held->made[ERX_DOM_OBJ_DOM_SIDE], 0, ERX_PROT_R) == ERX_OK &&
	    erx_lane_writer_init(&party.writer, (void *)(uintptr_t)own, (const void *)(uintptr_t)peer, sys.in_size) &&
	    erx_lane_reader_init(&party.reader, (const void *)(uintptr_t)peer, (void *)(uintptr_t)own, sys.out_size);
	passed = passed && party_take_eval(&party, record, FIRST_NS, &len) && party_burst_index(record, len) == 1;
	if (passed)
		party_sleep(STALL_NS);
	for (uint32_t i = 2; passed && i <= BURST; i++)
		passed = party_take_eval(&party, record, NEXT_NS, &len) && party_burst_index(record, len) == i;
	say_count("burst_taken", passed ? BURST : 0);
	passed = passed && party_monitor(&party) && party_take_eval(&party, record, NEXT_NS, &len) &&
	    party_down_noproc(record, len) && party_flood(&party);
	if (own != 0)
		passed = erx_vm_release(ERX_CAP_SELF, own, own_bytes) == ERX_OK && passed;
	if (peer != 0)
		passed = erx_vm_release(ERX_CAP_SELF, peer, peer_bytes) == ERX_OK && passed;
	return (passed);
}

/*
 * Creates the domain spec asks for, does what action says, and takes its
 * end; then disconnects and retires it. True when every call succeeded and
 * the end is kind with status.
 */
static bool
domain_run(const erx_dom_spec_t *spec, run_action_t action, erx_dom_end_kind_t kind, int64_t status)
{
	erx_dom_created_t created;
	erx_dom_report_t report = { 0 };
	erx_status_t made;
	bool passed, started;

	if (spec == NULL)
		return (false);
	made = erx_dom_lib_create(&lib, spec, NULL, 0, &created);
	if (made != ERX_OK) {
		say_count("create_status", (uint64_t)(int64_t)made);
		say_count("failed_step", lib.failed_at);
		return (false);
	}
	passed = created.connection != 0;
	if (passed && spec->connections != 0)
		passed = lanes_agree(created.id);
	if (passed && action == RUN_SPOIL)
		passed = page_spoil(created.id);
	started = passed && erx_dom_lib_start(&lib, created.id) == ERX_OK;
	passed = started;
	/* A domain starts once. */
	if (passed)
		passed = erx_dom_lib_start(&lib, created.id) == ERX_EINVAL;
	if (passed && action == RUN_LANE)
		passed = lane_party(created.id);
	if (passed && action == RUN_STOP)
		passed = erx_dom_lib_stop(&lib, created.id, STOP_STATUS) == ERX_OK;
	/* A failed case still ends the domain it started, so the cases after it run. */
	if (started && !passed)
		(void)erx_dom_lib_stop(&lib, created.id, STOP_STATUS);
	/* The party may have taken the end already, serving the domain's records. */
	if (started && action == RUN_LANE && party_ended)
		report = party_report;
	else if (started && !end_wait(&report))
		passed = false;
	passed = started && report.id == created.id && passed;
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
	uint32_t program = 0, erts = 0, jit = 0;

	if (reason == NULL)
		reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff.image.start, (size_t)handoff.image.size);
	if (reason == NULL && (erx_fiasco_launcher_find(&pack, PROGRAM, &program) != ERX_OK ||
	    erx_fiasco_launcher_find(&pack, RELEASE, &release) != ERX_OK ||
	    erx_fiasco_launcher_find(&pack, ERTS, &erts) != ERX_OK ||
	    erx_fiasco_launcher_find(&pack, JIT, &jit) != ERX_OK || !erts_release_find(&pack)))
		reason = "erx: domain: no program or release\n";
	if (reason == NULL) {
		erx_fiasco_task_set_archive(&pack);
		files_from(&pack, program);
		files[erts].kind = ERX_ENTRY_IMAGE;
		files[erts].image_ok = true;
		/*
		 * The BeamAsm image's manifest marks it ERX_IMAGE_JIT, which the domain
		 * service reads from it; this root reads no manifest, so it sets the flag
		 * the library makes ERX_SPACE_JIT from.
		 */
		files[jit].kind = ERX_ENTRY_IMAGE;
		files[jit].image_ok = true;
		files[jit].image_flags = ERX_IMAGE_JIT;
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
	case_end("jit_reload", jit_request(jit, jit_reload_args, sizeof(jit_reload_args)), RUN_PLAIN, ERX_DOM_END_HALT, 0);
	case_end("jit_write_rx", jit_request(jit, jit_write_rx_args, sizeof(jit_write_rx_args)), RUN_PLAIN,
	    ERX_DOM_END_FAULT, ERX_FAULT_MEMORY);
	case_end("jit_run_rw", jit_request(jit, jit_run_rw_args, sizeof(jit_run_rw_args)), RUN_PLAIN,
	    ERX_DOM_END_FAULT, ERX_FAULT_MEMORY);
	case_end("connection", connection_request(erts), RUN_LANE, ERX_DOM_END_HALT, 0);
	case_link(program);
	case_undo(program);
	say("erx: domain: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	erx_fiasco_sleep_forever();
}
