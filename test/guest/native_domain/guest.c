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
/*
 * What the logger case's domain runs: an error logged through the logger, whose text
 * holds a tab, an escape sequence and a newline, and a record of the domain's own making
 * sent to its logger proxy, which also holds a newline; then it waits for the proxy and
 * says it is done. Each record reaches the console as one record of the domain's space,
 * with every control shown as a token (tools/lib/erx/native_domain.rb).
 */
static const char logger_args[] = ERTS_BOOT
    "logger:error(\"tab\\there esc\\e[31mred nl~s\",[\"\\nend\"]),"
    "erx_log_h!{log,warning,<<\"raw\",9,\"t\",27,\"[0m\",10,\"x\">>},"
    "erx_log_h:sync(),erlang:display(logger_done),erlang:halt(0)";
/* What a BeamAsm domain runs: jit_reload, from the release's /test/, in one of its modes. */
#define JIT_RUN(mode)	ERTS_BOOT "{ok,B}=erl_prim_loader:read_file(\"/test/jit_reload.beam\")," \
    "{module,jit_reload}=erlang:load_module(jit_reload,B),jit_reload:run(" mode ")"
static const char jit_reload_args[] = JIT_RUN("reload");
static const char jit_write_rx_args[] = JIT_RUN("write_rx");
static const char jit_run_rw_args[] = JIT_RUN("run_rw");
/* What the crash case's domain runs: a halt with a slogan, which writes a crash dump. */
#define CRASH_SLOGAN	"native crash"
static const char crash_args[] = ERTS_BOOT "erlang:halt(\"" CRASH_SLOGAN "\")";

/* What a case does between a domain's create and its end. */
typedef enum run_action {
	RUN_PLAIN,	/* starts it and waits */
	RUN_STOP,	/* starts it, then stops it with STOP_STATUS */
	RUN_SPOIL,	/* spoils its boot page's version, then starts it */
	RUN_LANE,	/* starts it, then plays the system party on its connection */
	RUN_EXPORTS,	/* starts it, then plays the system party of the exports case */
	RUN_REFS,	/* starts it, then plays the system party of the refs case */
	RUN_CRASH	/* starts it, waits, then reads its crash area (crash_read) */
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

/* A request for a domain whose ERTS boots the ERTS release with logger_args. */
static const erx_dom_spec_t *
logger_request(uint32_t runtime)
{
	(void)erts_request(runtime);
	memcpy(request.strings, logger_args, sizeof(logger_args));
	request.args_len = (uint32_t)sizeof(logger_args);
	return (&request);
}

/* A request for a domain whose ERTS halts with CRASH_SLOGAN. */
static const erx_dom_spec_t *
crash_request(uint32_t runtime)
{
	(void)erts_request(runtime);
	memcpy(request.strings, crash_args, sizeof(crash_args));
	request.args_len = (uint32_t)sizeof(crash_args);
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
 * The connection case's domain: ERTS distributed over erx_dist, so net_kernel makes it
 * alive as guest@erxos with its domain id as creation and erx_connections opens the system
 * connection from the boot page. Once the system node is up, it checks net_adm:ping of it
* (pong) and of a domain it has no connection with (pang), that a monitor of a name
* there is DOWN with noconnection, that its creation is its id, and that a send to a
* registered name of the system node is dropped and counted and a monitor of one is DOWN
* with noproc at once, neither reaching the lane, halting with 1 on any
* failure. It checks D2's text property (edit 18) and says {identity, Id}, halting with 1
* unless Id is, in order: 100, the count of random pids and references of the system node
* whose text reads back as themselves (stock's text, an atom index, names no creation);
* true, its own pid prints its id; true, that text reads back; no (badarg), its own pid's
* text under 0; true, a pid of an earlier system node prints its creation 4000000; no,
* that text, since no connected node has it; no for each text whose number wraps its
* field onto the creation 4 (a pid's, a reference's, a port's); and no for a reference
* whose six numbers each end in '.', which ran past stock's arrays. The vector is
* positional because the eval must fit ERX_BOOT_STRINGS_MAX with the node names. Then it
* sends BURST messages of a KiB each to a pid of the system node, more than the lane
* holds, waits until the port's counts show the burst and one answer sent,
 * says them, and halts with 1 unless output paused for room and resumed on the bell and the
 * drain answered. It then waits: the party's flood of LINKs whose answers it never reads
 * ends the port with erx_lane_answers_unread, and erx_dist halts the domain with
 * DIST_LOST_STATUS. Each '~' is the domain's id.
 */
#define SYSTEM_NODE	"system@erxos"
#define DOMAIN_NODE	"guest@erxos"
#define BURST		16
#define TEXT_OF_(x)	#x
#define TEXT_OF(x)	TEXT_OF_(x)
#define BURST_TEXT	TEXT_OF(BURST)	/* BURST, as the expression writes it */
/* erx_dist's status when the system connection ends: EX_UNAVAILABLE of sysexits(3). */
#define DIST_LOST_STATUS	69
#define ERTS_DIST_BOOT	"--\0-root\0/\0-bindir\0/bin\0-progname\0erl\0-home\0/\0" \
    "-boot\0/bin/start\0-nouser\0-nocookie\0-no_epmd\0-proto_dist\0erx\0-eval\0"
static const char connection_eval[] =
    "S='" SYSTEM_NODE "',"
    "Up=fun U(0)->false;U(T)->lists:member(S,nodes()) orelse receive after 50->U(T-1) end end,"
    "Ok0=Up(600),"
    "Ok1=Ok0 andalso net_adm:ping(S)==pong andalso net_adm:ping('absent@erxos')==pang,"
    "M=monitor(process,{x,'absent@erxos'}),"
    "Ok2=Ok1 andalso receive {'DOWN',M,_,_,noconnection}->true after 10000->false end,"
    "Ok3=Ok2 andalso erlang:system_info(creation)==~ andalso node()=='" DOMAIN_NODE "',"
/* a send and a monitor to a registered name of the system domain stay in this domain */
"D=erx_dist:names_dropped(),"
"{x,S}!m,"
"M2=monitor(process,{x,S}),"
"(Ok3 andalso receive {'DOWN',M2,process,{x,S},noproc}->true after 10000->false end "
"andalso erx_dist:names_dropped()>D) orelse halt(1),"
/* D2: pid, port and reference texts (edit 18); E answers no for badarg */
"E=fun(F,T)->try erlang:F(T) catch error:badarg->no end end,"
"Lp=fun(T)->E(list_to_pid,T) end,"
"X=fun(C,N,Q)->binary_to_term(<<131,88,119,12,\"" SYSTEM_NODE "\",N:32,Q:32,C:32>>) end,"
"Rn=fun()->rand:uniform(1 bsl 32)-1 end,"
"Rs=[ok||_<-lists:seq(1,100),P1<-[X(4,Rn(),Rn())],"
"R1<-[binary_to_term(<<131,90,3:16,119,12,\"" SYSTEM_NODE "\",4:32,(Rn()):96>>)],"
"Lp(pid_to_list(P1))=:=P1,E(list_to_ref,ref_to_list(R1))=:=R1],"
"O=pid_to_list(self()),[_,Rt]=string:split(O,\".\"),Old=pid_to_list(X(4000000,1,0)),"
"Id=[length(Rs),lists:prefix(\"<~.\",O),Lp(O)=:=self(),"
"Lp(\"<0.\"++Rt),lists:prefix(\"<4000000.\",Old),Lp(Old),Lp(\"<18446744073709551620.1.0>\"),"
"E(list_to_ref,\"#Ref<18446744073709551620.1.2>\"),E(list_to_port,\"#Port<4294967300.1>\"),E(list_to_ref,\"#Ref<4.1.2.3.4.5.>\")],"
"erlang:display({identity,Id}),"
"Id==[100,true,true,no,true,no,no,no,no,no] orelse halt(1),"
    "P=proplists:get_value(S,erlang:system_info(dist_ctrl)),"
    "Pid=X(4,1,0),"
    "B=binary:copy(<<7>>,1024),"
    "[Pid!{burst,I,B}||I<-lists:seq(1," BURST_TEXT ")],"
    "W=fun W(T)->case iolist_to_binary(port_control(P,0,[])) of "
    "<<N:64,Pa:64,R:64,_:64,A:64,_/binary>> when (N>" BURST_TEXT " andalso A>0) orelse T==0->{N,Pa,R,A};"
    "_->receive after 50->W(T-1) end end end,"
    "{N,Pa,R,A}=W(600),"
    "erlang:display({lane,N,Pa,R,A}),"
    /* output paused for room and resumed on the bell, and the drain answered */
    "(N>" BURST_TEXT " andalso Pa>0 andalso R>0 andalso A>0) orelse halt(1),"
    "receive after infinity->ok end";

/*
 * The exports case's domain (R7, edits 8, 13 and 16), in lockstep with exports_party,
 * halting with the step's number at the first failure and with 0 when every step passed.
 * Once the system node is up: a pid handed out as a control term's sender gives the
 * system domain send alone (3), so the party's EXIT2 of kill is dropped, its LINK makes
 * no link (5) and its m1 arrives (4); a spawn by the party gives it send, link and exit on
 * the child (6, 7); with origins asked for, m3 arrives as {erx_origin, 4, m3} (8); net_kernel,
 * handed out, takes the party's spawn call without spawning, so the domain does not halt
 * with 77, once m5 (15) and a call of net_kernel's own say the call was read; an
 * explicit export of link alone survives handing the pid out again (9), so m2 is dropped
 * (11) and the party's LINK makes the link its exit of r7 crosses (10); a pid handed out
 * and then exited is the party's to monitor (12). Last, a process fills the export table
 * until system_limit (13), its peers numbered from 1000, past every domain id the cases
 * make; while it holds them, a gen_server:call to the party hands out an alias the table
 * has no room for, so the party's answer reaches no one, the call times out and the
 * refusals are counted (16); and its exit (17) frees what it held, so an export succeeds (14).
 */
static const char exports_eval[] =
    "S='" SYSTEM_NODE "',"
    "Up=fun U(0)->false;U(T)->lists:member(S,nodes()) orelse receive after 50->U(T-1) end end,"
    "H=fun(C,N)->C orelse halt(N) end,"
    "W=fun(M,N)->receive M->ok after 10000->halt(N) end end,"
    "H(Up(600),2),"
    "P=binary_to_term(<<131,88,119,12,\"" SYSTEM_NODE "\",1:32,0:32,4:32>>),"
    "Me=self(),G=fun(Q)->erx_dist:exports(Q) end,"
    "process_flag(trap_exit,true),"
    "P!a,H(G(Me)==[{4,[send]}],3),W(m1,4),{links,L}=process_info(Me,links),H(not lists:member(P,L),5),"
    "W(m4,6),H(lists:member([{4,[send,link,exit]}],[catch G(C)||C<-processes()]),7),"
    "ok=erx_dist:origins(true),P!d,W({erx_origin,4,m3},8),ok=erx_dist:origins(false),"
    "P!{n,whereis(net_kernel)},W(m5,15),sys:get_state(net_kernel),receive after 500->ok end,"
    "ok=erx_dist:export(Me,[link],4),P!b,H(G(Me)==[{4,[link]}],9),"
    "W({'EXIT',P,r7},10),receive m2->halt(11) after 0->ok end,"
    "Q=spawn(fun()->receive go->ok end end),P!{c,Q},R=monitor(process,Q),Q!go,"
    "W({'DOWN',R,process,Q,normal},12),P!c2,"
    "F=fun F(N)->case erx_dist:export(self(),[send],N) of ok->F(N+1);{error,system_limit}->N end end,"
    "{Fp,Rf}=spawn_monitor(fun()->Me!{k,F(1000)},receive go->ok end end),"
    "receive {k,K}->erlang:display({exports_filled,K-1000}),H(K>16000,13) end,"
    "D=erx_dist:exports_refused(),"
    "H(case catch gen_server:call(P,ping,3000) of {'EXIT',{timeout,_}}->erx_dist:exports_refused()>D;_->false end,16),"
    "Fp!go,W({'DOWN',Rf,process,Fp,normal},17),"
    "H(erx_dist:export(Me,[send],5)==ok,14),"
    "halt(0)";

/*
 * The refs case's domain (edits 17 and 14), in lockstep with refs_party, halting with the
 * step's number at the first failure. Ws gives a reference's identity, its four words as
 * a frame carries them, Mk the reference of this node of an identity of any length, Nb
 * the eight references one word away from an identity, Q makes K gen_server:calls, and Z
 * waits for the alias registry to come back to its count A0. A reference of this node has
 * four words (3), and one of three or five decodes to nothing (4); no neighbour of a
 * reference is the next one made (5), and a send to a neighbour of an alias reaches no
 * one (6); read_timer and cancel_timer find a timer by its reference (7, 9) and nothing
 * by a guessed one (8); ETS finds a table by its id through binary_to_term (10) and by no
 * neighbour (11). A thousand local calls (12), a thousand aliases unaliased and a
 * thousand that end with their owner leave the registry as it was (13). Two hundred
 * calls to the party take its answers through their aliases (14), not its answers to a
 * neighbour of each (15), and the registry comes back (16). The words of an alias never
 * handed out name nothing the party may send to (17); the table's id, round trip through
 * the party, is no table (18). Then z, and the party's reference of three words ends the
 * connection, so erx_dist halts the domain with DIST_LOST_STATUS.
 */
static const char refs_eval[] =
    "S='" SYSTEM_NODE "',"
    "H=fun(C,N)->C orelse halt(N) end,"
    "fun U(0)->halt(2);U(T)->lists:member(S,nodes()) orelse receive after 50->U(T-1) end end(600),"
    "P=binary_to_term(<<131,88,119,12,\"" SYSTEM_NODE "\",1:32,0:32,4:32>>),"
    "R=make_ref(),R2=make_ref(),B0=term_to_binary(R),H(binary:part(B0,0,4)==<<131,90,0,4>>,3),"
    "NC=binary:part(B0,4,byte_size(B0)-20),"
    "Ws=fun(F)->binary:part(term_to_binary(F),byte_size(B0)-16,16) end,"
    "Mk=fun(B)->binary_to_term(<<131,90,(byte_size(B) div 4):16,NC/binary,B/binary>>) end,"
    "Nb=fun(B)->[Mk(<<X:I/binary,(V+D):32,Y/binary>>)||I<-[0,4,8,12],D<-[-1,1],<<X:I/binary,V:32,Y/binary>><-[B]] end,"
    "H(Mk(Ws(R))=:=R andalso [element(1,catch Mk(<<1:J>>))||J<-[96,160]]==['EXIT','EXIT'],4),"
    "H(not lists:member(R2,Nb(Ws(R))),5),"
    "Al=alias(),[N!hit||N<-Nb(Ws(Al))],receive hit->halt(6) after 0->ok end,unalias(Al),"
    "Tm=erlang:start_timer(9999,self(),t),H(is_integer(erlang:read_timer(Tm)),7),"
    "H(lists:all(fun(F)->{erlang:read_timer(F),erlang:cancel_timer(F)}=={false,false} end,"
    "[Mk(rand:bytes(16))|Nb(Ws(Tm))]),8),"
    "H(is_integer(erlang:cancel_timer(Tm)),9),"
    "Tb=ets:new(t,[]),ets:insert(Tb,{k}),H(ets:lookup(binary_to_term(term_to_binary(Tb)),k)==[{k}],10),"
    "E=fun(F)->element(1,catch ets:info(F))=='EXIT' end,H(lists:all(E,Nb(Ws(Tb))),11),"
    "A0=erx_dist:aliases(),"
    "Z=fun Z(0)->false;Z(K)->erx_dist:aliases()==A0 orelse receive after 20->Z(K-1) end end,"
    "Sq=lists:seq(1,1000),Q=fun(G,K)->lists:all(fun(_)->gen_server:call(G,ping)==pong end,lists:sublist(Sq,K)) end,"
    "Sv=spawn(fun L()->receive {_,Fr,ping}->gen_server:reply(Fr,pong),L() end end),H(Q(Sv,1000),12),"
    "[unalias(alias())||_<-Sq],spawn(fun()->[alias()||_<-Sq] end),H(Z(100),13),"
    "H(Q(P,200),14),receive {_,forged}->halt(15) after 0->ok end,H(Z(100),16),"
    "A2=alias(),P!{w,Ws(A2)},receive mw->ok end,receive {_,w}->halt(17) after 0->ok end,"
    "P!{e,Tb},receive {e,T2}->H(T2==Tb andalso E(T2),18) end,P!z,"
    "receive after infinity->ok end";

/* How long the party waits for the domain's first frame, and for each later one. */
#define FIRST_NS	UINT64_C(60000000000)
#define NEXT_NS		UINT64_C(10000000000)
/* How long it leaves the lane unread, so the burst fills it. */
#define STALL_NS	UINT64_C(1000000000)
#define POLL_NS		UINT64_C(10000000)
/* The most LINKs the flood writes: far more than ERX_LANE_ANSWERS_MAX of answers. */
#define FLOOD_MAX	200000u
#define RECORD_MAX	2048u
#define DOP_LINK		1
#define DOP_SEND_SENDER		22
#define DOP_MONITOR_P		19
#define DOP_DEMONITOR_P		20
#define DOP_SPAWN_REQUEST	29
#define DOP_SPAWN_REPLY		31
#define DOP_PAYLOAD_EXIT	24
#define DOP_PAYLOAD_EXIT2	26
#define DOP_PAYLOAD_MONITOR_P_EXIT	28
#define DOP_ALIAS_SEND		33
/* A pid of the domain no process has: a number in ERTS's internal range. */
#define ABSENT_PID	4095u

/* The system party's ends of one domain's system connection, mapped into the root. */
typedef struct lane_party {
	erx_lane_writer_t	 writer;	/* the system domain's lane to the domain */
	erx_lane_reader_t	 reader;	/* the domain's lane to the system domain */
	uint64_t		 bell;		/* the domain's bell */
	uint32_t		 id;		/* the domain's id, its node's creation */
	uint32_t		 peer;		/* the system domain's id, as the page names it */
	uint64_t		 own, peer_side;	/* where the two sides are mapped, 0 for not */
	uint64_t		 own_bytes, peer_bytes;
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

/* A request for an ERTS domain distributed over erx_dist whose -eval is eval with its own id. */
static const erx_dom_spec_t *
connection_request(uint32_t runtime, const char *eval)
{
	/* The boot words without the literal's own NUL, which ends the last word twice. */
	size_t at = sizeof(ERTS_DIST_BOOT) - 1;

	(void)erts_request(runtime);
	memcpy(request.strings, ERTS_DIST_BOOT, at);
	if (!args_put(request.strings, sizeof(request.strings) - 1, &at, eval, request.id))
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
 * Writes a frame of control term ctl and payload (none when payload_len is 0), waiting up
 * to wait_ns for room, and
 * rings the domain's bell when a write crosses its wake. False when the lane refused it,
 * or when no room came by then: the domain stopped taking frames.
 */
static bool
party_put(lane_party_t *party, const uint8_t *ctl, size_t ctl_len, const uint8_t *payload, size_t payload_len,
    uint64_t wait_ns)
{
	const uint64_t deadline = erx_fiasco_clock_ns() + wait_ns;
	/* The frame header is little-endian on the wire, as this machine is. */
	const erx_frame_header_t header = { .ctl_len = (uint32_t)ctl_len, .payload_len = (uint32_t)payload_len };
	const erx_lane_iov_t iov[3] = { { .base = &header, .len = sizeof(header) }, { .base = ctl, .len = ctl_len },
	    { .base = payload, .len = payload_len } };
	const erx_lane_item_t item = { .iov = iov, .iovcnt = payload_len != 0 ? 3 : 2, .kind = ERX_REC_FRAME };

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

/* The domain's pid of number id and serial 0, as a frame names it. */
static erx_etf_pid_t
party_domain_pid(const lane_party_t *party, uint32_t id)
{
	return ((erx_etf_pid_t){ .node = (const uint8_t *)DOMAIN_NODE, .node_len = sizeof(DOMAIN_NODE) - 1, .id = id,
	    .creation = party->id });
}

/* Writes a MONITOR_P frame from a system process to the domain's pid to. */
static bool
party_monitor(lane_party_t *party, const erx_etf_pid_t *to)
{
	size_t ctl_len;
	uint8_t ctl[160];
	const erx_etf_ref_t ref = { .node = (const uint8_t *)SYSTEM_NODE, .node_len = sizeof(SYSTEM_NODE) - 1,
	    .creation = party->peer, .words = { 1, 2, 3, 0 } };
	erx_etf_writer_t writer;

	erx_etf_writer_init(&writer, ctl, sizeof(ctl));
	erx_etf_put_tuple(&writer, 4);
	erx_etf_put_integer(&writer, DOP_MONITOR_P);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	erx_etf_put_pid(&writer, to);
	erx_etf_put_ref(&writer, &ref);
	return (erx_etf_writer_done(&writer, &ctl_len) && party_put(party, ctl, ctl_len, NULL, 0, NEXT_NS));
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

	if (!args_put(node, sizeof(node) - 1, &node_len, DOMAIN_NODE, party->id))
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
		if (!party_put(party, ctl, ctl_len, NULL, 0, STALL_NS))
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
 * Whether a frame record is the SPAWN_REPLY {31, ReqId, To, Flags, Result} of a spawn that
 * made a process: Result, the control term's last element, is a pid of the domain.
 */
static bool
party_spawned(const lane_party_t *party, const uint8_t *record, size_t len)
{
	/* SMALL_TUPLE_EXT of 5, SMALL_INTEGER_EXT DOP_SPAWN_REPLY */
	static const uint8_t head[] = { 104, 5, 97, DOP_SPAWN_REPLY };
	/* NEW_PID_EXT, SMALL_ATOM_UTF8_EXT of the node; ID, Serial and Creation follow */
	static const uint8_t pid[] = { 88, 119, sizeof(DOMAIN_NODE) - 1 };
	const size_t pid_len = sizeof(pid) + sizeof(DOMAIN_NODE) - 1 + 12;
	party_frame_t frame;
	const uint8_t *at;

	if (!party_frame_split(record, len, &frame) || !party_ctl_starts(&frame, head, sizeof(head)) ||
	    frame.ctl_len < sizeof(head) + pid_len)
		return (false);
	at = frame.ctl + frame.ctl_len - pid_len;
	return (memcmp(at, pid, sizeof(pid)) == 0 && memcmp(at + sizeof(pid), DOMAIN_NODE, sizeof(DOMAIN_NODE) - 1) == 0 &&
	    ((uint32_t)at[pid_len - 4] << 24 | (uint32_t)at[pid_len - 3] << 16 | (uint32_t)at[pid_len - 2] << 8 |
	    at[pid_len - 1]) == party->id);
}

/* Whether a frame record is the spawned process's SEND_SENDER of spawned to its parent. */
static bool
party_child_sent(const uint8_t *record, size_t len)
{
	/* SMALL_TUPLE_EXT of 3, SMALL_INTEGER_EXT DOP_SEND_SENDER */
	static const uint8_t head[] = { 104, 3, 97, DOP_SEND_SENDER };
	static const uint8_t message[] = { 119, 7, 's', 'p', 'a', 'w', 'n', 'e', 'd' };
	party_frame_t frame;

	return (party_frame_split(record, len, &frame) && party_ctl_starts(&frame, head, sizeof(head)) &&
	    frame.payload_len == sizeof(message) && memcmp(frame.payload, message, sizeof(message)) == 0);
}

/*
 * Writes a SPAWN_REQUEST of module:function/arity from a system process, the args list
 * the payload; ref_word makes its reference distinct. The system domain may spawn into
 * every domain: each runtime exports spawn on its domain to it at boot (erx_exports_boot).
 */
static bool
party_spawn_put(lane_party_t *party, uint32_t ref_word, const char *module, const char *function, uint32_t arity,
    const uint8_t *args, size_t args_len)
{
	const erx_etf_ref_t ref = { .node = (const uint8_t *)SYSTEM_NODE, .node_len = sizeof(SYSTEM_NODE) - 1,
	    .creation = party->peer, .words = { ref_word, ref_word + 1, ref_word + 2, 0 } };
	uint8_t ctl[256];
	size_t ctl_len;
	erx_etf_writer_t writer;

	erx_etf_writer_init(&writer, ctl, sizeof(ctl));
	erx_etf_put_tuple(&writer, 6);
	erx_etf_put_integer(&writer, DOP_SPAWN_REQUEST);
	erx_etf_put_ref(&writer, &ref);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	erx_etf_put_tuple(&writer, 3);
	erx_etf_put_atom(&writer, module, strlen(module));
	erx_etf_put_atom(&writer, function, strlen(function));
	erx_etf_put_integer(&writer, arity);
	erx_etf_put_nil(&writer);
	return (erx_etf_writer_done(&writer, &ctl_len) && party_put(party, ctl, ctl_len, args, args_len, NEXT_NS));
}

/*
 * Spawns erlang:send(Parent, spawned) into the domain and takes the SPAWN_REPLY naming the
 * new process and the child's message, in either order.
 */
static bool
party_spawn(lane_party_t *party, uint8_t *record)
{
	uint8_t payload[96];
	size_t payload_len, len;
	bool replied = false, sent = false;
	erx_etf_writer_t writer;

	erx_etf_writer_init(&writer, payload, sizeof(payload));
	erx_etf_put_list(&writer, 2);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	erx_etf_put_atom(&writer, "spawned", 7);
	erx_etf_put_nil(&writer);
	if (!erx_etf_writer_done(&writer, &payload_len) ||
	    !party_spawn_put(party, 4, "erlang", "send", 2, payload, payload_len))
		return (false);
	for (int taken = 0; taken < 2; taken++) {
		if (!party_take(party, record, NEXT_NS, &len))
			return (false);
		replied = replied || party_spawned(party, record, len);
		sent = sent || party_child_sent(record, len);
	}
	return (replied && sent);
}

/* Spawns timer:sleep(infinity) into the domain and takes the SPAWN_REPLY naming the child. */
static bool
party_spawn_sleeper(lane_party_t *party, uint8_t *record)
{
	uint8_t payload[32];
	size_t payload_len, len;
	erx_etf_writer_t writer;

	erx_etf_writer_init(&writer, payload, sizeof(payload));
	erx_etf_put_list(&writer, 1);
	erx_etf_put_atom(&writer, "infinity", 8);
	erx_etf_put_nil(&writer);
	return (erx_etf_writer_done(&writer, &payload_len) &&
	    party_spawn_put(party, 7, "timer", "sleep", 1, payload, payload_len) &&
	    party_take(party, record, NEXT_NS, &len) && party_spawned(party, record, len));
}

/*
 * Writes a frame {op, From, to} from a system process, with the atom payload as its
 * payload, or none when payload is NULL: a LINK, a SEND_SENDER, a PAYLOAD_EXIT or a
 * PAYLOAD_EXIT2.
 */
static bool
party_signal(lane_party_t *party, uint8_t op, const erx_etf_pid_t *to, const char *payload)
{
	uint8_t ctl[160], body[32];
	size_t ctl_len, body_len = 0;
	erx_etf_writer_t writer;

	erx_etf_writer_init(&writer, ctl, sizeof(ctl));
	erx_etf_put_tuple(&writer, 3);
	erx_etf_put_integer(&writer, op);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	erx_etf_put_pid(&writer, to);
	if (!erx_etf_writer_done(&writer, &ctl_len))
		return (false);
	if (payload != NULL) {
		erx_etf_writer_init(&writer, body, sizeof(body));
		erx_etf_put_atom(&writer, payload, strlen(payload));
		if (!erx_etf_writer_done(&writer, &body_len))
			return (false);
	}
	return (party_put(party, ctl, ctl_len, body, body_len, NEXT_NS));
}

/* A domain pid as a frame carries it: NEW_PID_EXT, its node a SMALL_ATOM_UTF8_EXT. */
#define PARTY_PID_LEN	(3 + sizeof(DOMAIN_NODE) - 1 + 12)

static uint32_t
party_be32(const uint8_t *at)
{
	return ((uint32_t)at[0] << 24 | (uint32_t)at[1] << 16 | (uint32_t)at[2] << 8 | at[3]);
}

/* Reads the domain pid at at, len bytes in reach, into pid. False when it is not one. */
static bool
party_pid_read(const lane_party_t *party, const uint8_t *at, size_t len, erx_etf_pid_t *pid)
{
	static const uint8_t head[] = { 88, 119, sizeof(DOMAIN_NODE) - 1 };
	const uint8_t *numbers = at + sizeof(head) + sizeof(DOMAIN_NODE) - 1;

	if (len < PARTY_PID_LEN || memcmp(at, head, sizeof(head)) != 0 ||
	    memcmp(at + sizeof(head), DOMAIN_NODE, sizeof(DOMAIN_NODE) - 1) != 0)
		return (false);
	*pid = party_domain_pid(party, party_be32(numbers));
	pid->serial = party_be32(numbers + 4);
	return (party_be32(numbers + 8) == party->id);
}

/*
 * Whether a frame record is a SEND_SENDER {22, From, To} of the atom message; reads From,
 * the domain's sender, into from.
 */
static bool
party_from(const lane_party_t *party, const uint8_t *record, size_t len, const char *message, erx_etf_pid_t *from)
{
	/* SMALL_TUPLE_EXT of 3, SMALL_INTEGER_EXT DOP_SEND_SENDER */
	static const uint8_t head[] = { 104, 3, 97, DOP_SEND_SENDER };
	const size_t message_len = strlen(message);
	party_frame_t frame;

	return (party_frame_split(record, len, &frame) && party_ctl_starts(&frame, head, sizeof(head)) &&
	    party_pid_read(party, frame.ctl + sizeof(head), frame.ctl_len - sizeof(head), from) &&
	    frame.payload_len == 2 + message_len && frame.payload[0] == 119 && frame.payload[1] == message_len &&
	    memcmp(frame.payload + 2, message, message_len) == 0);
}

/* Whether a frame record is a SEND_SENDER of {Tag, Q}, Tag a one-letter atom and Q a domain pid; reads Q into q. */
static bool
party_handed(const lane_party_t *party, const uint8_t *record, size_t len, char tag, erx_etf_pid_t *q)
{
	static const uint8_t ctl_head[] = { 104, 3, 97, DOP_SEND_SENDER };
	/* SMALL_TUPLE_EXT of 2, SMALL_ATOM_UTF8_EXT of one letter; Q follows */
	static const uint8_t head[] = { 104, 2, 119, 1 };
	party_frame_t frame;

	return (party_frame_split(record, len, &frame) && party_ctl_starts(&frame, ctl_head, sizeof(ctl_head)) &&
	    frame.payload_len == sizeof(head) + 1 + PARTY_PID_LEN && memcmp(frame.payload, head, sizeof(head)) == 0 &&
	    frame.payload[sizeof(head)] == (uint8_t)tag && party_pid_read(party, frame.payload + sizeof(head) + 1, PARTY_PID_LEN, q));
}

/*
 * Whether a frame record is the exit that answers a LINK to a pid the system domain
 * holds no link on: {24, From, To} of PAYLOAD_EXIT, with noproc as the payload.
 */
static bool
party_exit_noproc(const uint8_t *record, size_t len)
{
	static const uint8_t head[] = { 104, 3, 97, DOP_PAYLOAD_EXIT };
	static const uint8_t reason[] = { 119, 6, 'n', 'o', 'p', 'r', 'o', 'c' };
	party_frame_t frame;

	return (party_frame_split(record, len, &frame) && party_ctl_starts(&frame, head, sizeof(head)) &&
	    frame.payload_len == sizeof(reason) && memcmp(frame.payload, reason, sizeof(reason)) == 0);
}

/*
 * Sends net_kernel, the domain's pid nk, the gen_server call stock net_kernel answers by
 * spawning for any caller: {spawn, erlang, halt, [77], Gleader}. net_kernel takes a
 * message from another domain only as {erx_origin, D, Msg} (erx_dist:listen/2), which no
 * clause of its handle_call matches, so the domain must not halt with 77.
 */
static bool
party_nk_spawn(lane_party_t *party, const erx_etf_pid_t *nk)
{
	const erx_etf_ref_t ref = { .node = (const uint8_t *)SYSTEM_NODE, .node_len = sizeof(SYSTEM_NODE) - 1,
	    .creation = party->peer, .words = { 10, 11, 12, 0 } };
	uint8_t ctl[160], payload[160];
	size_t ctl_len, payload_len;
	erx_etf_writer_t writer;

	erx_etf_writer_init(&writer, ctl, sizeof(ctl));
	erx_etf_put_tuple(&writer, 3);
	erx_etf_put_integer(&writer, DOP_SEND_SENDER);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	erx_etf_put_pid(&writer, nk);
	if (!erx_etf_writer_done(&writer, &ctl_len))
		return (false);
	erx_etf_writer_init(&writer, payload, sizeof(payload));
	erx_etf_put_tuple(&writer, 3);
	erx_etf_put_atom(&writer, "$gen_call", 9);
	erx_etf_put_tuple(&writer, 2);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	erx_etf_put_ref(&writer, &ref);
	erx_etf_put_tuple(&writer, 5);
	erx_etf_put_atom(&writer, "spawn", 5);
	erx_etf_put_atom(&writer, "erlang", 6);
	erx_etf_put_atom(&writer, "halt", 4);
	erx_etf_put_list(&writer, 1);
	erx_etf_put_integer(&writer, 77);
	erx_etf_put_nil(&writer);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	return (erx_etf_writer_done(&writer, &payload_len) && party_put(party, ctl, ctl_len, payload, payload_len, NEXT_NS));
}

/*
 * Maps both sides of domain id's system connection into the root as the system domain's
 * runtime would, and opens party on them. False on any failure; party_close releases
 * what it mapped either way.
 */
static bool
party_open(uint32_t id, lane_party_t *party)
{
	const erx_dom_handles_t *held;
	erx_boot_connection_t sys;
	uint64_t page;

	*party = (lane_party_t){ .id = id };
	party_ended = false;
	if (!boot_page_map(id, ERX_PROT_R, &held, &page))
		return (false);
	sys = ((const erx_boot_info_t *)(uintptr_t)page)->system_connection;
	if (erx_vm_release(ERX_CAP_SELF, page, ERX_PAGE_SIZE) != ERX_OK)
		return (false);
	party->bell = held->made[ERX_DOM_OBJ_DOM_BELL];
	party->peer = sys.peer;
	party->own_bytes = erx_lane_side_bytes(sys.in_size);
	party->peer_bytes = erx_lane_side_bytes(sys.out_size);
	return (erx_vm_reserve(ERX_CAP_SELF, 0, party->own_bytes, 0, &party->own) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, party->own, party->own_bytes, held->made[ERX_DOM_OBJ_SYS_SIDE], 0, ERX_PROT_RW) ==
	    ERX_OK &&
	    erx_vm_reserve(ERX_CAP_SELF, 0, party->peer_bytes, 0, &party->peer_side) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, party->peer_side, party->peer_bytes, held->made[ERX_DOM_OBJ_DOM_SIDE], 0,
	    ERX_PROT_R) == ERX_OK &&
	    erx_lane_writer_init(&party->writer, (void *)(uintptr_t)party->own, (const void *)(uintptr_t)party->peer_side,
	    sys.in_size) &&
	    erx_lane_reader_init(&party->reader, (const void *)(uintptr_t)party->peer_side, (void *)(uintptr_t)party->own,
	    sys.out_size));
}

/* Releases what party_open mapped. False when a release fails. */
static bool
party_close(lane_party_t *party)
{
	bool passed = true;

	if (party->own != 0)
		passed = erx_vm_release(ERX_CAP_SELF, party->own, party->own_bytes) == ERX_OK;
	if (party->peer_side != 0)
		passed = erx_vm_release(ERX_CAP_SELF, party->peer_side, party->peer_bytes) == ERX_OK && passed;
	return (passed);
}

/*
 * The system party on domain id's system connection: takes the burst's first frame,
 * leaves the lane unread for STALL_NS so the rest waits for room, takes the rest in
 * order, then monitors an absent pid of the domain and takes the DOWN noproc the
 * domain's drain answers, spawns a process into the domain (party_spawn), then floods
 * LINKs without reading their answers
 * (party_flood). Every frame it takes is one of these: none names a registered name, which
 * the domain's ERTS keeps to itself (edit 27 of docs/design-runtime.md). Serves the
 * domain's records as it waits, noting its end. Maps both sides as the system domain's
 * runtime would, and releases them.
 */
static bool
lane_party(uint32_t id)
{
	static uint8_t record[RECORD_MAX];
	lane_party_t party;
	erx_etf_pid_t absent;
	size_t len;
	bool passed;

	passed = party_open(id, &party);
	absent = party_domain_pid(&party, ABSENT_PID);
	passed = passed && party_take(&party, record, FIRST_NS, &len) && party_burst_index(record, len) == 1;
	if (passed)
		party_sleep(STALL_NS);
	for (uint32_t i = 2; passed && i <= BURST; i++)
		passed = party_take(&party, record, NEXT_NS, &len) && party_burst_index(record, len) == i;
	say_count("burst_taken", passed ? BURST : 0);
	passed = passed && party_monitor(&party, &absent) && party_take(&party, record, NEXT_NS, &len) &&
	    party_down_noproc(record, len) && party_spawn(&party, record);
	say_count("spawned", passed);
	passed = passed && party_flood(&party);
	return (party_close(&party) && passed);
}

/* A domain reference as a frame carries it: NEWER_REFERENCE_EXT of four words, its node a SMALL_ATOM_UTF8_EXT. */
#define PARTY_REF_LEN	(5 + sizeof(DOMAIN_NODE) - 1 + 4 + 4 * ERX_ETF_REF_WORDS)

/* Reads the domain reference at at, len bytes in reach, into ref. False when it is not one. */
static bool
party_ref_read(const lane_party_t *party, const uint8_t *at, size_t len, erx_etf_ref_t *ref)
{
	static const uint8_t head[] = { 90, 0, ERX_ETF_REF_WORDS, 119, sizeof(DOMAIN_NODE) - 1 };
	const uint8_t *creation = at + sizeof(head) + sizeof(DOMAIN_NODE) - 1;

	if (len < PARTY_REF_LEN || memcmp(at, head, sizeof(head)) != 0 ||
	    memcmp(at + sizeof(head), DOMAIN_NODE, sizeof(DOMAIN_NODE) - 1) != 0 || party_be32(creation) != party->id)
		return (false);
	*ref = (erx_etf_ref_t){ .node = (const uint8_t *)DOMAIN_NODE, .node_len = sizeof(DOMAIN_NODE) - 1,
	    .creation = party->id };
	for (uint32_t i = 0; i < ERX_ETF_REF_WORDS; i++)
		ref->words[i] = party_be32(creation + 4 + 4 * i);
	return (true);
}

/* Writes an ALIAS_SEND {33, From, Alias} from a system process, its payload {[alias | Alias], atom}. */
static bool
party_alias_send(lane_party_t *party, const erx_etf_ref_t *alias, const char *atom)
{
	uint8_t ctl[160], body[160];
	size_t ctl_len, body_len;
	erx_etf_writer_t writer;

	erx_etf_writer_init(&writer, ctl, sizeof(ctl));
	erx_etf_put_tuple(&writer, 3);
	erx_etf_put_integer(&writer, DOP_ALIAS_SEND);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	erx_etf_put_ref(&writer, alias);
	if (!erx_etf_writer_done(&writer, &ctl_len))
		return (false);
	erx_etf_writer_init(&writer, body, sizeof(body));
	erx_etf_put_tuple(&writer, 2);
	erx_etf_put_list(&writer, 1);
	erx_etf_put_atom(&writer, "alias", 5);
	erx_etf_put_ref(&writer, alias);
	erx_etf_put_atom(&writer, atom, strlen(atom));
	return (erx_etf_writer_done(&writer, &body_len) && party_put(party, ctl, ctl_len, body, body_len, NEXT_NS));
}

/* A MONITOR_P's control term, as far as its operation: {19, From, To, Ref}. */
static const uint8_t party_monitor_head[] = { 104, 4, 97, DOP_MONITOR_P };

/* Whether a frame's payload is gen_server:call's {'$gen_call', {Pid, [alias | Alias]}, ping}; reads Alias into alias. */
static bool
party_gen_call(const lane_party_t *party, const party_frame_t *frame, erx_etf_ref_t *alias)
{
	static const uint8_t head[] = { 104, 3, 119, 9, '$', 'g', 'e', 'n', '_', 'c', 'a', 'l', 'l', 104, 2 };
	/* LIST_EXT of one element, the atom alias; the reference is its tail */
	static const uint8_t tag[] = { 108, 0, 0, 0, 1, 119, 5, 'a', 'l', 'i', 'a', 's' };
	static const uint8_t ping[] = { 119, 4, 'p', 'i', 'n', 'g' };
	const uint8_t *at = frame->payload + sizeof(head) + PARTY_PID_LEN;
	erx_etf_pid_t from;

	return (frame->payload_len == sizeof(head) + PARTY_PID_LEN + sizeof(tag) + PARTY_REF_LEN + sizeof(ping) &&
	    memcmp(frame->payload, head, sizeof(head)) == 0 &&
	    party_pid_read(party, frame->payload + sizeof(head), PARTY_PID_LEN, &from) &&
	    memcmp(at, tag, sizeof(tag)) == 0 && party_ref_read(party, at + sizeof(tag), PARTY_REF_LEN, alias) &&
	    memcmp(at + sizeof(tag) + PARTY_REF_LEN, ping, sizeof(ping)) == 0);
}

/* Whether a frame's payload is {w, Words}, Words a binary of four big-endian words; reads them into ref. */
static bool
party_words(const lane_party_t *party, const party_frame_t *frame, erx_etf_ref_t *ref)
{
	static const uint8_t head[] = { 104, 2, 119, 1, 'w', 109, 0, 0, 0, 4 * ERX_ETF_REF_WORDS };

	if (frame->payload_len != sizeof(head) + 4 * ERX_ETF_REF_WORDS || memcmp(frame->payload, head, sizeof(head)) != 0)
		return (false);
	*ref = (erx_etf_ref_t){ .node = (const uint8_t *)DOMAIN_NODE, .node_len = sizeof(DOMAIN_NODE) - 1,
	    .creation = party->id };
	for (uint32_t i = 0; i < ERX_ETF_REF_WORDS; i++)
		ref->words[i] = party_be32(frame->payload + sizeof(head) + 4 * i);
	return (true);
}

/* Sends to the domain's pid to, from a system process, the payload bytes as they came, with their version byte. */
static bool
party_echo(lane_party_t *party, const erx_etf_pid_t *to, const party_frame_t *frame)
{
	static uint8_t body[RECORD_MAX + 1];
	uint8_t ctl[160];
	size_t ctl_len;
	erx_etf_writer_t writer;

	erx_etf_writer_init(&writer, ctl, sizeof(ctl));
	erx_etf_put_tuple(&writer, 3);
	erx_etf_put_integer(&writer, DOP_SEND_SENDER);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	erx_etf_put_pid(&writer, to);
	if (!erx_etf_writer_done(&writer, &ctl_len) || frame->payload_len >= sizeof(body))
		return (false);
	body[0] = 131;
	memcpy(body + 1, frame->payload, frame->payload_len);
	return (party_put(party, ctl, ctl_len, body, frame->payload_len + 1, NEXT_NS));
}

/*
 * Sends to the domain's pid to a reference of the domain's node with three words, which
 * no runtime of that domain made: a malformed frame, which ends the connection.
 */
static bool
party_short_ref(lane_party_t *party, const erx_etf_pid_t *to)
{
	uint8_t ctl[160], body[64];
	size_t ctl_len, at = 0;
	erx_etf_writer_t writer;
	const uint8_t head[] = { 131, 90, 0, 3, 119, sizeof(DOMAIN_NODE) - 1 };

	erx_etf_writer_init(&writer, ctl, sizeof(ctl));
	erx_etf_put_tuple(&writer, 3);
	erx_etf_put_integer(&writer, DOP_SEND_SENDER);
	party_pid(&writer, SYSTEM_NODE, 1, party->peer);
	erx_etf_put_pid(&writer, to);
	if (!erx_etf_writer_done(&writer, &ctl_len))
		return (false);
	memcpy(body, head, sizeof(head));
	at = sizeof(head);
	memcpy(body + at, DOMAIN_NODE, sizeof(DOMAIN_NODE) - 1);
	at += sizeof(DOMAIN_NODE) - 1;
	for (uint32_t word = 0; word < 4; word++) {
		const uint32_t value = word == 0 ? party->id : word;

		body[at++] = (uint8_t)(value >> 24);
		body[at++] = (uint8_t)(value >> 16);
		body[at++] = (uint8_t)(value >> 8);
		body[at++] = (uint8_t)value;
	}
	return (party_put(party, ctl, ctl_len, body, at, NEXT_NS));
}

/*
 * The system party of the exports case (exports_eval), in lockstep with the eval: each
 * frame the eval sends says which step comes next. Steps, by the frame that starts them:
 *
 * a: the eval's pid, handed out as a control term's sender, holds send alone: an EXIT2 of
 *    kill is dropped, a LINK is answered with an exit of noproc, and m1 is delivered.
 *    Then a spawn of timer:sleep(infinity), whose SPAWN_REPLY names the child, and m4.
 * d: the eval asked for origins, so m3 reaches it as {erx_origin, 4, m3}.
 * {n, NK}: net_kernel, handed out, gets stock net_kernel's spawn call (party_nk_spawn); then m5.
 * b: the eval exported its pid to the system domain with link alone and handed it out
 *    again: m2 is dropped, and a LINK makes a link, which an exit of r7 then crosses.
 * {c, Q} and c2: Q was handed out, then exited; a monitor of Q is answered DOWN noproc.
 * Then, with the table full, the MONITOR_P and request of a gen_server:call: its answer of
 * pong goes to the call's alias, on which the full table gave the system domain no hold.
 */
static bool
exports_party(uint32_t id)
{
	static uint8_t record[RECORD_MAX];
	lane_party_t party;
	erx_etf_pid_t eval, nk, q;
	erx_etf_ref_t alias;
	party_frame_t frame;
	size_t len;
	bool passed;

	passed = party_open(id, &party);
	passed = passed && party_take(&party, record, FIRST_NS, &len) && party_from(&party, record, len, "a", &eval) &&
	    party_signal(&party, DOP_PAYLOAD_EXIT2, &eval, "kill") && party_signal(&party, DOP_LINK, &eval, NULL) &&
	    party_take(&party, record, NEXT_NS, &len) && party_exit_noproc(record, len) &&
	    party_signal(&party, DOP_SEND_SENDER, &eval, "m1");
	say_count("exports_send_alone", passed);
	passed = passed && party_spawn_sleeper(&party, record) && party_signal(&party, DOP_SEND_SENDER, &eval, "m4");
	say_count("exports_spawned", passed);
	passed = passed && party_take(&party, record, NEXT_NS, &len) && party_from(&party, record, len, "d", &eval) &&
	    party_signal(&party, DOP_SEND_SENDER, &eval, "m3");
	passed = passed && party_take(&party, record, NEXT_NS, &len) && party_handed(&party, record, len, 'n', &nk) &&
	    party_nk_spawn(&party, &nk) && party_signal(&party, DOP_SEND_SENDER, &eval, "m5");
	say_count("exports_net_kernel", passed);
	passed = passed && party_take(&party, record, NEXT_NS, &len) && party_from(&party, record, len, "b", &eval) &&
	    party_signal(&party, DOP_SEND_SENDER, &eval, "m2") && party_signal(&party, DOP_LINK, &eval, NULL) &&
	    party_signal(&party, DOP_PAYLOAD_EXIT, &eval, "r7");
	say_count("exports_narrowed", passed);
	passed = passed && party_take(&party, record, NEXT_NS, &len) && party_handed(&party, record, len, 'c', &q) &&
	    party_take(&party, record, NEXT_NS, &len) && party_from(&party, record, len, "c2", &eval) &&
	    party_monitor(&party, &q) && party_take(&party, record, NEXT_NS, &len) && party_down_noproc(record, len);
	say_count("exports_exited", passed);
	passed = passed && party_take(&party, record, NEXT_NS, &len) && party_frame_split(record, len, &frame) &&
	    party_ctl_starts(&frame, party_monitor_head, sizeof(party_monitor_head)) &&
	    party_take(&party, record, NEXT_NS, &len) && party_frame_split(record, len, &frame) &&
	    party_gen_call(&party, &frame, &alias) && party_alias_send(&party, &alias, "pong");
	say_count("exports_alias_refused", passed);
	return (party_close(&party) && passed);
}

/*
 * The system party of the refs case (refs_eval), serving the eval's frames until its z:
 * the monitors and demonitors of gen_server:call it takes and leaves; each call it
 * answers through the call's alias, after an answer of forged to a neighbour of the
 * alias, one word flipped, which the domain must drop; for {w, Words} it sends w to the
 * alias of those words, which the domain never handed out, then mw; {e, Term} it sends
 * back as it came; at z it sends a reference of three words (party_short_ref).
 */
static bool
refs_party(uint32_t id)
{
	static const uint8_t send_head[] = { 104, 3, 97, DOP_SEND_SENDER };
	static const uint8_t demonitor_head[] = { 104, 4, 97, DOP_DEMONITOR_P };
	static const uint8_t echo_head[] = { 104, 2, 119, 1, 'e' };
	static uint8_t record[RECORD_MAX];
	lane_party_t party;
	erx_etf_pid_t eval;
	erx_etf_ref_t alias, forged;
	party_frame_t frame;
	uint64_t calls = 0, frames = 0;
	size_t len;
	bool passed, ended = false;

	passed = party_open(id, &party);
	while (passed && !ended) {
		passed = party_take(&party, record, frames++ == 0 ? FIRST_NS : NEXT_NS, &len) &&
		    party_frame_split(record, len, &frame);
		if (!passed || party_ctl_starts(&frame, party_monitor_head, sizeof(party_monitor_head)) ||
		    party_ctl_starts(&frame, demonitor_head, sizeof(demonitor_head)))
			continue;
		passed = party_ctl_starts(&frame, send_head, sizeof(send_head)) &&
		    party_pid_read(&party, frame.ctl + sizeof(send_head), frame.ctl_len - sizeof(send_head), &eval);
		if (passed && party_gen_call(&party, &frame, &alias)) {
			forged = alias;
			forged.words[0] ^= 1;
			passed = party_alias_send(&party, &forged, "forged") && party_alias_send(&party, &alias, "pong");
			calls++;
		} else if (passed && party_words(&party, &frame, &alias))
			passed = party_alias_send(&party, &alias, "w") && party_signal(&party, DOP_SEND_SENDER, &eval, "mw");
		else if (passed && frame.payload_len > sizeof(echo_head) &&
		    memcmp(frame.payload, echo_head, sizeof(echo_head)) == 0)
			passed = party_echo(&party, &eval, &frame);
		else if (passed && party_from(&party, record, len, "z", &eval)) {
			passed = party_short_ref(&party, &eval);
			ended = true;
		} else
			passed = false;
	}
	say_count("refs_calls", calls);
	return (party_close(&party) && passed);
}

/*
 * Copies ended domain id's crash area into an object of the root's,
 * mapped read-only, and reads it as the domain service does: the slogan
 * is CRASH_SLOGAN, the text starts as an ERTS dump does, and a truncated
 * dump fills the area. Prints the dump's length and truncation, never
 * its text, which the domain wrote.
 */
static bool
crash_read(uint32_t id)
{
	static const char start[] = "=erl_crash_dump:0.5\n";
	erx_dom_dump_t dump;
	uint64_t mem, addr = 0;
	bool passed;

	if (erx_mem_create(ERX_CAP_NULL, ERX_CRASH_SIZE, 0, &mem) != ERX_OK)
		return (false);
	passed = erx_dom_lib_crash_copy(&lib, id, mem) == ERX_OK &&
	    erx_vm_reserve(ERX_CAP_SELF, 0, ERX_CRASH_SIZE, 0, &addr) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, addr, ERX_CRASH_SIZE, mem, 0, ERX_PROT_R) == ERX_OK &&
	    erx_dom_dump_read((const uint8_t *)(uintptr_t)addr, ERX_CRASH_SIZE, &dump) == ERX_OK;
	if (passed) {
		say_count("crash_length", dump.length);
		say_count("crash_truncated", dump.truncated);
		passed = dump.slogan_len == sizeof(CRASH_SLOGAN) - 1 &&
		    memcmp(dump.slogan, CRASH_SLOGAN, dump.slogan_len) == 0 &&
		    dump.length >= sizeof(start) - 1 && memcmp(dump.text, start, sizeof(start) - 1) == 0 &&
		    (!dump.truncated || dump.length == ERX_CRASH_SIZE - ERX_DUMP_HEADER_SIZE);
	}
	if (addr != 0)
		passed = erx_vm_release(ERX_CAP_SELF, addr, ERX_CRASH_SIZE) == ERX_OK && passed;
	return (erx_cap_close(mem) == ERX_OK && passed);
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
	bool ended_itself, partied, passed, started;

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
	partied = passed && (action == RUN_EXPORTS || action == RUN_REFS);
	if (partied)
		passed = action == RUN_EXPORTS ? exports_party(created.id) : refs_party(created.id);
	if (passed && action == RUN_STOP)
		passed = erx_dom_lib_stop(&lib, created.id, STOP_STATUS) == ERX_OK;
	/*
	 * A failed exports or refs party leaves the domain to end itself first: the domain halts with
	 * the eval's failing step as its status, usually after the party has failed.
	 */
	if (partied && !passed && !party_ended)
		party_ended = end_wait(&party_report);
	ended_itself = partied && party_ended;
	/* A failed case still ends the domain it started, so the cases after it run. */
	if (started && !passed && !ended_itself)
		(void)erx_dom_lib_stop(&lib, created.id, STOP_STATUS);
	/* The party may have taken the end already, serving the domain's records. */
	if (started && (action == RUN_LANE || action == RUN_EXPORTS || action == RUN_REFS) && party_ended)
		report = party_report;
	else if (started && !end_wait(&report))
		passed = false;
	passed = started && report.id == created.id && passed;
	say_count("end_kind", (uint64_t)report.end.kind);
	say_count("end_status", (uint64_t)report.end.status);
	passed = passed && report.end.kind == kind && report.end.status == status &&
	    erx_dom_lib_retire(&lib, created.id) == ERX_EBUSY;
	if (passed && action == RUN_CRASH)
		passed = crash_read(created.id);
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
	case_end("logger", logger_request(erts), RUN_PLAIN, ERX_DOM_END_HALT, 0);
	case_end("erts_refused", erts_request(erts), RUN_SPOIL, ERX_DOM_END_HALT, ERX_FIASCO_TASK_STATUS_BOOT_PAGE);
	case_end("crash", crash_request(erts), RUN_CRASH, ERX_DOM_END_CRASH, 0);
	case_end("jit_reload", jit_request(jit, jit_reload_args, sizeof(jit_reload_args)), RUN_PLAIN, ERX_DOM_END_HALT, 0);
	case_end("jit_write_rx", jit_request(jit, jit_write_rx_args, sizeof(jit_write_rx_args)), RUN_PLAIN,
	    ERX_DOM_END_FAULT, ERX_FAULT_MEMORY);
	case_end("jit_run_rw", jit_request(jit, jit_run_rw_args, sizeof(jit_run_rw_args)), RUN_PLAIN,
	    ERX_DOM_END_FAULT, ERX_FAULT_MEMORY);
	case_end("connection", connection_request(erts, connection_eval), RUN_LANE, ERX_DOM_END_HALT, DIST_LOST_STATUS);
	case_end("exports", connection_request(erts, exports_eval), RUN_EXPORTS, ERX_DOM_END_HALT, 0);
	case_end("refs", connection_request(erts, refs_eval), RUN_REFS, ERX_DOM_END_HALT, DIST_LOST_STATUS);
	case_link(program);
	case_undo(program);
	say("erx: domain: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	erx_fiasco_sleep_forever();
}
