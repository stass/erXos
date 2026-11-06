# Research record: how ERTS 29.1.2 works inside

A point-in-time report of how the Erlang runtime system of OTP 29.1.2 (ERTS
17.1.1) works inside, read from its source, as evidence for erXos, which runs
a fork of this ERTS inside its kernel. What ERTS asks of its host is in
[research-erts-host.md](research-erts-host.md); the layers through which the
emulator reaches that host (ethread, the sys layer, polling, memory mapping,
configure) are summarised in
[The operating-system layer](#the-operating-system-layer). Findings are
never edited in place; a re-check gets a record of its own.

**Date:** 2026-10-29.
**Host:** Apple M4 Max, macOS 27.0.1 (Darwin 27.0.0); Homebrew LLVM clang
23.1.4 for the toolchain probe.
**Sources read** (extracted and read only; no script, makefile or binary
from them was run):

* Erlang/OTP 29.1.2, `otp_src_29.1.2.tar.gz` from the GitHub release
  `OTP-29.1.2`, SHA-256
  `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`
  (re-hashed on the date above): ERTS 17.1.1 (`erts/vsn.mk`), asmjit at
  commit `5fe1940275d0` (`erts/emulator/asmjit.version`), and the documents
  under [Sources](#sources).

## Method and conventions

The tree was read with `sed -n`, `grep` and `wc`; nothing in it was
configured, built or run. Thirteen read-only passes produced the findings,
merged and deduplicated here. Before writing, 316 cited line ranges and
absence claims were re-read against the tree and 7 citations corrected, and
every citation in the Facts section was re-read once more while writing.

* **Corrections:** `struct process` ends at erl_process.h:1204, not 1196; pid
  index scrambling is erl_ptab.h:301-309, not 309-316; the table maximum is
  erl_ptab.h:174 with erl_node_container_utils.h:180, not erl_ptab.h:177;
  `ErtsNonMsgSignal` is erl_proc_sig_queue.h:165-168, not 146-161; the
  signal opcodes are erl_proc_sig_queue.h:174-196, not 164-186; the reduction
  charge in `erts_schedule` is erl_process.c:9678, not 9683; `prim_file` has
  33 NIFs, 32 of them dirty I/O, not 32 in all. Two loader-trust citations of
  the x86-64 JIT are replaced by the AArch64 equivalents. Other citations
  come from the passes, which read the cited lines.
* **Paths** are relative to the OTP root. A bare file name is in
  `erts/emulator/beam/`; `emu/` and `jit/` are its subdirectories, `jit/arm/`
  being the AArch64 JIT. `asmjit/`, `sys/` and `nifs/` are under
  `erts/emulator/`; `inc/` is `erts/include/internal/`, `lib_src/` is
  `erts/lib_src/`, `pre/` is `erts/preloaded/src/` and `kernel/` is
  `lib/kernel/src/`. `configure.ac` is in `erts/`, `Makefile.in` in
  `erts/emulator/`, and documents keep their full paths.
* **Conventions.** "(inferred)" marks a deduction from code that was read.
  KW is a kiloword of 1024 words, and a word is 8 bytes. Facts describe a
  64-bit release build with configure's defaults, and "the JIT" is BeamAsm on
  AArch64 Linux. The two Linux facts are cited by file and function because
  their measurement notes record no line numbers.

## Processes and the process table

A process is one flat `struct process` from the fixed-size allocator plus one
heap-and-stack block, published by an atomic store into a pointer table at a
slot encoded in its pid. Lookup is a lock-free read that is safe only while
the reader delays thread progress, and scheduling is a CAS loop on a 32-bit
state word holding three priorities and 25 flags.

* `struct process` (erl_process.h:1043-1204) begins with the table header
  (erl_ptab.h:79-103) and the hot BEAM registers, and heap and stack share
  one block (erl_process.h:1018-1020, 1046-1060); a running process keeps its
  X registers in per-scheduler memory (beam_common.c:306-345).
* Other threads write `state`, `xstate`, `run_queue` and `common.timer` by
  CAS, and `sig_inq`, `bif_timers` and `sys_task_qs` under the MSGQ, BTM and
  STATUS locks (erl_process.h:1165-1173; erl_hl_timer.c:692-706;
  erl_process_lock.h:113-150); a running process holds its own MAIN lock for
  its whole slice (erl_process.c:10193, 9758).

State flags (erl_process.h:1231-1339); flag index N is bit 6 + N, and bits
0-5 hold the ACT (effective), USR (user) and PRQ (queue) priorities:

| Flags (index) | Meaning |
|---|---|
| IN_PRQ_MAX..LOW (0-3), IN_RUNQ (8), PROXY (16) | which queues hold the real struct or a proxy |
| FREE (4), EXITING (5) | out of the table; exiting but still visible |
| MSG_SIG_IN_Q (6), NMSG_SIG_IN_Q (13), SIG_Q (19) | signals in the outer or middle queue |
| ACTIVE (7), ACTIVE_SYS (14), DIRTY_ACTIVE_SYS (22) | wants to run code, system work, dirty system work |
| RUNNING (9), RUNNING_SYS (15), DIRTY_RUNNING (23), DIRTY_RUNNING_SYS (24) | executing |
| SUSPENDED (10), GC (11), SYS_TASKS (12), DELAYED_SYS (17), OFF_HEAP_MSGQ (18) | other states |
| DIRTY_CPU_PROC (20), DIRTY_IO_PROC (21) | dirty work requested |

* A sender schedules the receiver only if ACTIVE is clear; the CAS enqueues
  only an ACTIVE process that is not suspended, running or queued, and a
  struct queued at another priority gets a whole proxy `Process`
  (erl_proc_sig_queue.h:2079-2089; erl_process.c:6937-6976, 6437-6482).
* `erl_create_process` allocates the struct with `erts_alloc_fnf` and a
  233-word default heap and schedules it last; a full table gives
  `system_limit` (erl_process.c:12185, 12524-12540, 13121; erl_vm.h:66).
* The table has `+P` slots, 2^20 by default, at most 2^27 - 1, scrambled
  across cache lines; insertion publishes with a release store, and deletion
  asserts a managed thread (erl_process.h:86; erl_ptab.h:174, 301-309;
  erl_ptab.c:510-555, 685-713; erl_node_container_utils.h:180).
* `erts_proc_lookup_raw` asserts that the caller delays thread progress and
  reads the slot without locking; `erts_proc_lookup` also rejects EXITING
  processes (erl_process_lock.h:1135-1157).

## The scheduler loop and run queues

Each normal scheduler owns a run queue and each dirty pool shares one.
`erts_schedule` runs at every switch on the scheduler thread's own C stack:
it retires the outgoing process, does housekeeping, picks the next process by
strict priority, runs its pending signals, system tasks and GC, and returns
it with a fresh budget. Balancing is driven by reductions, not time.

* A run queue has one plain `pthread_mutex_t`, an atomic flag word and three
  FIFO lists for four priorities, low sharing normal's; there are n + 2
  queues, the dirty CPU and dirty I/O queues last (erl_process.h:472-519;
  erl_process.c:6121-6125; inc/ethread.h:157-159).
* Priorities are MAX 0, HIGH 1, NORMAL 2 and LOW 3, the pick takes the lowest
  non-empty level, and a low process is passed over 7 times while normal ones
  wait (erl_process.h:122-132; erl_process.c:10004-10006, 4040-4054;
  strictness and count inferred).
* `erts_schedule` (erl_process.c:9607-10497) charges reductions, re-reads the
  clock every 4000 reductions to bump timers, checks balance, updates thread
  progress, runs aux work, steals, sleeps or polls when empty, and claims the
  next process with one CAS on `p->state` (erl_process.c:9678-9700,
  9801-9821, 9857-9866, 9907-9969, 9982-10031, 10136).
* A switch saves only `i`, `htop`, `stop`, the live X registers, `arity` and
  `current`: there is no machine context and no per-process C stack
  (emu/beam_emu.c:466-500; jit/arm/process_main.cpp:105-160).
* The JIT keeps the Erlang stack pointer in x20, apart from `sp`, because the
  "ARM JIT doesn't support native stack due to its 16-byte alignment
  requirement"; its `process_main` never returns, and a scheduler thread that
  returns aborts the VM (jit/arm/beam_asm.hpp:85; configure.ac:3223-3227;
  erl_process.c:8799-8804).
* A queue checks balance every `2000*CONTEXT_REDS` reductions, so a full
  rebalance runs about once per 8 million reductions on the busiest queue
  and never on an idle node; compact load, the default, marks surplus queues
  INACTIVE (erl_process.c:63-65, 4922-4935, 5101-5149; erl_init.c:803;
  cadence inferred).
* Work moves by emigration at enqueue, refused by bound processes, by
  immigration, and by trylock stealing of up to half a victim's top
  priority, at most 100 (erl_process.h:2711-2733; erl_process.c:4115-4205,
  4531-4534, 4640-4715); erl_process.c has no floating point and computes
  utilization in integer parts per million (erl_process.c:998).

## Scheduler sleep and wake

An idle scheduler spins, then blocks on its private thread event, a futex on
Linux, with a nanosecond timeout from its timer wheel, or, holding the single
poll token, in epoll or kqueue on the pollset all normal schedulers share. A
waker clears the target's sleep flags by CAS, then sets the event or writes
the pollset's wake pipe.

* `scheduler_wait` keeps running immediate aux work instead of sleeping, then
  calls `erts_check_io(ssi->psi, timeout_time, false)` as poll sleeper or
  `erts_tse_twait(ssi->event, timeout)`, with timeout -1 on a dirty scheduler
  (erl_process.c:3452-3672, 3567, 3596-3602).
* All schedulers spin 10,000 times before an event sleep, calling
  `sched_yield()` every 100 iterations, and on AArch64 the spin body is only
  a compiler barrier (erl_process.c:69-85, 3065-3085; inc/ethread.h:418-429,
  441-460).
* Waking writes the wake pipe or sets the event, and `add2runq` notifies
  after every enqueue without checking whether the target sleeps
  (erl_process.c:3675-3743, 6894, 3915-3923; sys/common/erl_poll.c:428-460).
* The event is `futex(FUTEX_WAIT_PRIVATE)` on Linux and a mutex plus
  condition variable elsewhere (inc/pthread/ethr_event.h:27-80;
  lib_src/pthread/ethr_event.c:52-200); a contended process lock spins up to
  2000 times, then waits (erl_process_lock.c:77-140, 394-453).

## Aux work

Aux work is an atomic bitmask per thread, one bit per kind of deferred
housekeeping. Normal schedulers run it on every loop pass, while waiting and
while offline, and so does the aux thread; on a dirty scheduler it is a
fatal error.

| Kinds (erl_process.h:297-317) | Work | erl_process.c |
|---|---|---|
| DELAYED_AW_WAKEUP | batched wakeups of other threads | 1738-1797 |
| DD, DD_THR_PRGR; FIX_ALLOC_* | frees made into this allocator instance; shrinking fixed pools | 2057-2185 |
| THR_PRGR_LATER_OP | callbacks due at a thread-progress value | 2281-2369 |
| CNCLD_TMRS, CNCLD_TMRS_THR_PRGR | timers owned here and cancelled elsewhere | 2187-2276 |
| ASYNC_READY, ASYNC_READY_CLEAN | finished async-pool jobs | 1992-2054 |
| MISC, MISC_THR_PRGR | (function, argument) jobs from a lock-free queue | 1806-1989 |
| SET_TMO, MSEG_CACHE_CHECK, YIELD, REAP_PORTS, DEBUG_WAIT_COMPLETED | aux timer, mseg cache, resumed scans, halting, tests | 2372-2397, 2524-2652, 2882-2889 |

* A flag is set by atomic OR, with a poke when the bit was clear
  (erl_process.c:1604-1634); MISC jobs come from code loading, ETS, NIF
  resource destructors, distribution, time correction and tracing
  (code_ix.c:585; erl_db.c:625; erl_nif.c:2970; dist.c:545;
  erl_time_sup.c:2128; erl_bif_trace.c:1202).
* Work blocked on thread progress registers a wakeup, so a scheduler with
  immediate work never sleeps (erl_process.c:2697-2698, 3519-3532); aux work
  on a dirty scheduler raises `ERTS_INTERNAL_ERROR("Executing aux work on a
  dirty scheduler.")` (erl_process.c:3506-3508).

## Dirty schedulers

Dirty CPU and dirty I/O schedulers are two pools, each sharing one run queue.
A process goes dirty by setting state bits and yielding, runs there without
its MAIN lock, and returns through a finalizer on a normal scheduler; dirty
threads are outside thread progress, run no aux work, own no timer wheel and
sleep without a timeout.

* Dirty CPU threads default to the scheduler count and dirty I/O threads to
  10, and each thread has a preallocated shadow `Process` (erl_init.c:865-867;
  erl_process.c:6149-6153, 6032-6040).
* A NIF goes dirty through `enif_schedule_nif` or a dirty declaration and a
  BIF through `erts_schedule_bif`; the reductions are exhausted, and
  schedule-out moves the process to a dirty queue (erl_nif.c:3437-3483,
  3540-3584; bif.c:5650-5726; erl_process.c:6492-6529).
* A dirty NIF runs with `env.proc = erts_make_dirty_shadow_proc(esdp, c_p)`
  after `erts_proc_unlock(c_p, ERTS_PROC_LOCK_MAIN)`, and a normal scheduler
  may meanwhile run that process's exit (erl_nif.c:453, 468, 509-529;
  erl_process.c:10095-10111).
* A GC estimated at 128*1024 words or more runs on a dirty CPU scheduler
  (erl_gc.h:26; erl_gc.c:686-716); dirty CPU work costs `(CONTEXT_REDS-1)/1000
  + 1` = 4 reductions per microsecond, though the comment says two
  (erl_process.h:2970-2981; beam_common.c:152-176).
* Dirty threads register as unmanaged and sleep with timeout -1, and only
  normal schedulers get a timer wheel (erl_process.c:8834, 8884, 8744,
  3596-3602).

## Thread progress

Thread progress is a 64-bit global epoch that a leader advances once every
other managed thread has confirmed the next value or is asleep; unmanaged
threads can only delay it. It is ERTS's deferred-reclamation and
code-publication barrier, and `erts_thr_progress_block()` doubles as a
stop-the-world for managed threads.

* Managed threads are the normal schedulers, aux threads, the system-message
  dispatcher and the poll threads; async and dirty threads are unmanaged
  (erl_init.c:1222-1242; erl_thr_progress.c:36-43).
* Reaching a value implies a full barrier, a sleeping managed thread counts
  as having reached it, and `erts_thr_progress_later()` is the caller's
  confirmed value + 2 (erl_thr_progress.c:55-65, 224-235, 708-761;
  erl_thr_progress.h:233-262).
* Sleepers use wakeup callbacks, and `finalize_wait` issues the deferred ISB
  of code loading (erl_thr_progress.h:108-114; erl_thr_progress.c:884-949).
* "erts_thr_progress_block() will not block dirty NIFs"; `system_flag`,
  `delete_module`, NIF upgrade, tracing and distribution use the block
  (erl_nif.c:4966-4969; bif.c:5057; beam_bif_load.c:714;
  erl_bif_trace.c:1090; dist.c:861).
* Later ops go on the calling normal scheduler's aux work; they free exited
  processes, ETS tables, `persistent_term` data, migration tables, timers and
  signal buffers, and commit code (erl_process.c:2325-2369, 14765-14769,
  4858-4891; erl_db.c:519-533; erl_bif_persistent.c:773-779;
  erl_hl_timer.c:1554-1694; erl_proc_sig_queue.c:10591; code_ix.c:546-592).

## Thread-specific data

`ErtsSchedulerData` sits in cache-aligned global arrays and is found through
`pthread_getspecific`. No compiler TLS is used, and a default UNIX build
creates 13 pthread keys.

* `erts_get_scheduler_data()` is an out-of-line call returning
  `erts_tsd_get(sched_data_key)`, that is `pthread_getspecific`, from 137 call
  sites in 42 files; `p->scheduler_data` is faster while a process is
  scheduled in (erl_process.c:6429-6432, 10232, 9756;
  erl_threads.h:2431-2434; lib_src/pthread/ethread.c:611-620).
* Allocator-instance selection, the managed-thread test and the thread event
  also read TSD on hot paths (erl_alloc.h:325-332; erl_thr_progress.h:198-202;
  inc/ethread.h:680-690).
* No `__thread`, `_Thread_local`, `thread_local` or `__declspec(thread)`
  occurs under erts/emulator, erts/lib_src or erts/include except in a README
  and a Windows CRT name (lib_src/yielding_c_fun/README.md:183;
  nifs/win32/win_prim_file.c:541).

| Keys | Created at | Hold |
|---|---|---|
| `ethr_ts_event_key__`, `ethr_stacklimit_key__` | lib_src/pthread/ethread.c:285; lib_src/common/ethr_aux.c:261 | thread event; stack limit |
| `erts_thr_prgr_data_key__`, `erts_is_crash_dumping_key` | erl_thr_progress.c:390; erl_init.c:837 | thread-progress data; crash-dump flag |
| `sched_data_key`, `erts_thr_alloc_data_key` | erl_process.c:655; erl_alloc.c:656 | `ErtsSchedulerData`; allocator instance |
| `match_pseudo_process_key`, `the_binary_malloc_tsd_key` | erl_db_util.c:547; erl_bif_re.c:217 | match-spec process; `re` allocation |
| two driver-list keys | io.c:3011, 3013 | lock state; last error |
| `erts_msacc_key` | erl_msacc.c:77 | microstate accounting, on by default (configure.ac:330-341) |
| `tid_key` | erl_drv_thread.c:129 | all driver and NIF TSD, one array per thread |
| port-task pre-allocator key | erl_sched_spec_pre_alloc.c:99, from erl_port_task.c:157 | pre-allocated port tasks |

## Threads created at startup

The signal dispatcher, the system-message dispatcher and the async pool come
first, then every scheduler, dirty scheduler, aux and poll thread, and the
main thread parks in `select()`. The set is fixed at boot, and every idle
thread blocks in a host primitive.

| Thread | Count (flag) | Stack | Progress | Idle in | Created at |
|---|---|---|---|---|---|
| `erts_ssig_disp` | 1 | OS default | none | `read()` on a pipe | sys/unix/sys.c:1183-1201 |
| `erts_smsg_disp` | 1 | OS default | managed | condition variable | erl_trace.c:2902-2918 |
| `erts_async_N`, joinable | 1 (`+A`) | 16 KW | unmanaged | event | erl_async.c:193-214 |
| `erts_sched_N` | ncpu (`+S`), all, even offline | 128 KW | managed | event or pollset | erl_process.c:8941-8949 |
| `erts_dcpus_N`, `erts_dios_N` | schedulers; 10 | 40 KW | unmanaged | event, no timeout | erl_process.c:8956-8971 |
| `erts_aux_N`, `erts_poll_N` | 1 + `+Mdai`; 1 | 40 KW, inherited | managed | event or pollset; epoll | erl_process.c:8974-9008 |
| `erts_runq_sup` | only if `+sfwi` > 0 | 16 KW | none | sleep | erl_process.c:8921-8933 |
| main | 1 | process | none | `select(0, NULL, NULL, NULL, NULL)` | sys/unix/sys.c:1276-1286 |

* The order is signal dispatcher, system-message dispatcher, async pool and
  forker, system processes, `erts_start_schedulers()` and
  `erts_sys_main_thread()`, with the defaults above (erl_init.c:1281, 297,
  306, 325, 2540-2617, 69-73, 848, 865-867).
* Aux and poll threads inherit the dirty I/O stack size, and a stack is
  KW x 8 x 1024 bytes plus a guard page (erl_process.c:8964-9008;
  lib_src/pthread/ethread.c:358-371); an 8-CPU host with defaults runs 31
  threads plus main (inferred), and `erl_child_setup` is a separate process
  forked through the forker port (sys/unix/sys_drivers.c:170-193).

## Reductions and preemption

A slice is `CONTEXT_REDS` = 4000 reductions (erl_vm.h:53), held in
`p->fcalls` and in a register while the process runs. The counter is tested
only at safe points in the running code, and no thread can shorten another's
slice: preemption is entirely cooperative.

* The interpreter tests it at local, export and fun calls, returns, BIF and
  NIF calls and receive (emu/macros.tab:154-232; emu/bif_instrs.tab:557-561;
  emu/msg_instrs.tab:65-72).
* The JIT keeps the counter in `w22` and ends every function prologue with
  `i_test_yield`, "yielding on function ingress (rather than on each call)";
  returns, BIF and NIF calls and receive test it too (jit/arm/beam_asm.hpp:87;
  jit/arm/ops.tab:929-944; jit/arm/instr_call.cpp:51-52;
  jit/arm/instr_bif.cpp:399-400, 932-933; jit/arm/instr_msg.cpp:125-126).
* BIFs charge with `BUMP_REDS` and trap by setting `p->i` (bif.h:67-210,
  320-335, 462-505), GC costs `moved_live/10 + resize_moved/100`
  (erl_gc.c:218-229), and `enif_consume_timeslice` does nothing on dirty
  schedulers (erl_nif.c:3341-3360).
* Only the thread running a process writes its `fcalls`; `setitimer`,
  `timer_create`, `SIGPROF` and `SIGVTALRM` appear nowhere in the emulator,
  and senders only set state bits (erl_process.c:10435, 6951-6971;
  emu/beam_emu.c:477).
* A NIF, a BIF that does not trap, or a GC below 128K words therefore holds
  its scheduler until it returns (inferred; erl_gc.h:26).

## Timers

Each normal scheduler owns a lock-free two-level timer wheel with 1 ms ticks
and a service of red-black trees for long timers. Timers fire at schedule
points and on wake-up, and other schedulers reach a timer only through its
owner's aux work.

* The wheels use 14 + 14 bits, a soon wheel of "about 16 seconds" and a later
  wheel of "about 37 hours and 16 minutes"; the struct has `1 + SOON + LATER`
  slot pointers and no lock, 262,152 bytes per scheduler (erl_time.h:41-64;
  time.c:243-246, 291-317; size inferred).
* Insert and cancel are O(1), and bumping runs callbacks without locks,
  yielding after a budget of 10000 at 100 per timeout (time.c:219-225,
  784-1031, 1256-1321).
* The next timeout is capped at one week "in order to avoid issues with
  primitives that have a limited maximum timeout time" (time.c:619-635).
* A timer records its owner's scheduler id, and cancelling it elsewhere
  queues it to the owner as aux work (erl_hl_timer.c:96-107, 910, 1766-1789).
* `receive ... after` rejects 2^32 ms or more; on expiry the owner CASes
  `common.timer` and schedules the process (erl_hl_timer.c:2800-2801,
  692-706; erl_process.c:10451-10459).

## Signal queues

A process has an outer queue that any sender appends to under the receiver's
MSGQ lock, and middle and inner queues that only the receiver touches under
its MAIN lock. No queue operation is lock-free: every enqueue takes the MSGQ
lock or one of 64 buffer mutexes (inferred from the paths below).

* "A receive expression can only operate on messages once they have entered
  the inner queue" (erl_proc_sig_queue.h:23-80); a non-message signal shares
  the message header, tagged with an opcode, and counts in `mlenoffs` the
  messages before it (erl_message.h:241; erl_proc_sig_queue.h:152-168,
  375-383).
* A send tries a buffer, takes MSGQ, drops the message if the receiver is
  EXITING, appends and notifies; a non-message signal is refused only when
  the receiver is FREE (erl_message.c:372-458;
  erl_proc_sig_queue.c:1076-1252).
* MSGQ is a trylock, else a blocking lock that bumps a contention counter;
  64 buffer slots, a mutex each, are installed for off_heap receivers past a
  contention of 50 (erl_proc_sig_queue.c:10240-10248, 10597-10694;
  erl_message.h:38-56).
* A fetch under MAIN and MSGQ flushes the buffers in slot order and splices
  the outer queue onward, and handling runs under MAIN alone at a cost of 4
  per signal (erl_proc_sig_queue.c:1332-1526, 10532-10563, 52, 6229-7178).

Signal opcodes (erl_proc_sig_queue.h:174-196):

| Op | Signal | Op | Signal | Op | Signal |
|---|---|---|---|---|---|
| 0 | EXIT (`exit/2`) | 7 | GROUP_LEADER | 14 | DIST_SPAWN_REPLY |
| 1 | EXIT_LINKED | 8 | TRACE_CHANGE_STATE | 15 | ALTACT_MSG |
| 2 | MONITOR_DOWN | 9 | PERSISTENT_MON_MSG | 16 | RECV_MARK |
| 3 | MONITOR | 10 | IS_ALIVE | 17 | UNLINK_ACK |
| 4 | DEMONITOR | 11 | PROCESS_INFO | 18 | ADJ_MSGQ |
| 5 | LINK | 12 | SYNC_SUSPEND | 19 | FLUSH |
| 6 | UNLINK | 13 | RPC | 20 | NIF_SELECT |

## Ordering

The only documented guarantee is order per sender-receiver pair, and
distribution may lose signals. Sender-keyed buffers, flushes before direct
enqueues and a receivability rule keep that order.

* "if an entity sends multiple signals to the same destination entity, the
  order is preserved", and over distribution "signals can be lost"
  (system/doc/reference_manual/ref_man_processes.md:503-511).
* Buffer hashing on the sender "guarantees that all signals from the same
  process are ordered in send order", and direct enqueues flush the buffers
  first (erl_proc_sig_queue.c:10284-10287, 863-865, 1830-1836;
  erl_message.c:438-445).
* A local MONITOR signal waits in `esdp->pending_signal` until the next
  signal or message to that receiver, or schedule-out
  (erl_proc_sig_queue.c:1102-1167; erl_process.c:9666-9667).
* A message becomes receivable only after every non-message signal before it
  is handled (erl_proc_sig_queue.c:7040-7045, 3804-3813).
* A spawn reply precedes the child's DOWN or EXIT (erl_process.c:12966-12969);
  a flush concatenates slots in index order, so different senders' signals
  can be reordered (erl_proc_sig_queue.c:10532-10563; inferred).

## Sending and copying

A local send sizes and copies the term, skipping literals and sharing refc
binaries by refcount. By default the sender copies straight onto the
receiver's heap under a trylock of the receiver's MAIN lock.

* The copy skips literals outside the purge area and increments refc
  binaries' counts (erl_message.c:771, 797; copy.c:83-107, 834-846).
* on_heap is the default (erl_process.c:132): the sender trylocks the
  receiver's MAIN lock and advances its `HEAP_TOP`, or else fills a fragment
  (erl_message.c:621-696, 965-1004).
* The sender pays `msize/64` reductions, at most `CONTEXT_REDS`
  (erl_message.c:881-886); distribution messages stay encoded until the
  receiver's `loop_rec` decodes them (external.c:872-899;
  emu/msg_instrs.tab:114-136).

## Receive

`loop_rec` scans only the inner queue and, when it runs dry, fetches and
handles signals. If none came, it returns holding MSGQ, so `wait` clears
ACTIVE without losing a wakeup.

* The helper "returns with message queue lock locked" when no message
  arrived, and `wait` clears ACTIVE under MSGQ and schedules out
  (emu/msg_instrs.tab:44-142, 371-385; erl_proc_sig_queue.c:7730-7869).
* A corrupt distribution message is dropped in `loop_rec`, and receive
  markers let a receive on a fresh reference skip older messages
  (emu/msg_instrs.tab:114-136; erl_proc_sig_queue.c:4290-4349).

## Links and monitors

Each side keeps its own half in a tree or list under its own MAIN lock and
changes the peer only by signal. A monitor is one refcounted allocation whose
halves are themselves the signals.

* "One should absolutely *not* acquire the lock of the other involved
  process/port and operate on its monitor tree/list directly"
  (erl_monitor_link.h:50-58); `ErtsMonitorData` holds both halves, the ref
  and an atomic refcount (erl_monitor_link.h:719-727).
* `unlink` sends a 64-bit id, and the ack removes the half only if the id
  matches (bif.c:1223-1364; erl_proc_sig_queue.c:6662-6780).
* `kill` cannot be trapped, and an alias is a reference embedding the pid,
  checked by the receiver (erl_proc_sig_queue.c:4740-4770, 6030-6111;
  erl_bif_unique.h:259-286).

## Process exit

Exit is a resumable state machine run by the dying process, yielding on
reductions. Removal from the table and the FREE flag come before any link
exit or DOWN is sent.

* A system process exiting ends the VM; otherwise `erts_do_exit_process`
  takes all locks, sets EXITING and charges 100 reductions
  (erl_process.c:14186-14188, 14195-14229).
* The phases are TIMERS, BLCKD_MSHED, BLCKD_NMSHED, USING_DB,
  CLEAN_SYS_TASKS, FREE, CLEAN_SYS_TASKS_AFTER, LINKS, MONITORS, LT_MONITORS,
  HANDLE_PROC_SIG, DIST_SEND, DIST_LINKS, DIST_MONITORS,
  DIST_PEND_SPAWN_MONITORS and DONE (erl_process.c:14234-14251).
* FREE unregisters the name, "the last "erlang resource"", then "Time of
  death!" deletes the slot (erl_process.c:14420-14469); the table's
  reference is dropped after thread progress (erl_process.c:14765-14769).
* Messages to an EXITING process are dropped, and other signals are refused
  after FREE with `noproc` (erl_message.c:413-427;
  erl_proc_sig_queue.c:1221, 7344-7364).

## Distribution

A remote signal is a control tuple plus an optional payload, encoded by the
sender in its own context and queued in fragments on the DistEntry; a busy
queue suspends the sender. The receiver's `erts_net_message` runs in the
connection controller's context and checks the sender against the connection.

| Operation | Control tuple (opcodes from dist.h:141-183) | dist.c |
|---|---|---|
| link; unlink and ack | `{1 LINK, From, To}`; `{35 UNLINK_ID, Id, From, To}`, `{36 UNLINK_ID_ACK, Id, From, To}` | 1453-1495 |
| monitor, demonitor | `{19 MONITOR_P, Watcher, Watched, Ref}`, `{20 DEMONITOR_P, ...}` | 1527-1572 |
| monitored process exits | `{21 MONITOR_P_EXIT, Watched, Watcher, Ref, Reason}`, or opcode 28 with the reason as payload | 1498-1521 |
| send to pid | `{2 SEND, '', To}`, or `{22 SEND_SENDER, From, To}`; `_TT` forms add a trace token | 1676-1700 |
| send to name, to alias | `{6 REG_SEND, From, '', Name}`; `{33 ALIAS_SEND, From, Alias}` | 1668-1682 |
| priority or alias with `DFLAG_ALTACT_SIG` | `{37 ALTACT_SIG_SEND, Flags, From, To}` | 1646-1666 |
| link exit; `exit/2` | `{3 EXIT, From, To, Reason}`; `{8 EXIT2, From, To, Reason}`; opcodes 24 and 26 carry the reason as payload | 1772-1828 |
| `group_leader/2` | `{7 GROUP_LEADER, Leader, Pid}` | 1831-1840 |
| `spawn_request`, reply | `{29 SPAWN_REQUEST, ReqId, From, GroupLeader, MFA, Opts}` with the arguments as payload; `{31 SPAWN_REPLY, ReqId, To, Flags, Result}` | 1842-1898 |

* `erts_dsig_prepare` records the connection id (dist.c:3215-3306), and
  `erts_dsig_send` charges encoding to the sender, drops the signal if the
  connection id changed and suspends the sender while the queue is over
  `erts_dist_buf_busy_limit` (dist.c:3339-3700).
* Fragments are 64 KiB with an 18-byte header (dist.h:205-211), and data
  with a stale 24-bit connection id is rejected on receipt
  (external.c:902-960; external.h:137).
* `erts_net_message` (dist.c:2017-3169) rejects link, unlink, monitor and
  exit senders whose DistEntry is not the connection's, and bad data kills
  the connection (dist.c:2237, 2301-2302, 2357-2358, 2842-2843, 3163).
* On connection loss `erts_do_net_exits` detaches the connection's links and
  monitors, and a cleanup runs as aux work on the current scheduler in
  `CONTEXT_REDS` slices at 40 reductions per item (dist.c:922-1117, 302,
  372-477, 510-547).
* A broken link becomes EXIT_LINKED with `noconnection` sent as if from the
  remote pid (erl_proc_sig_queue.c:2553-2577); a message to a pid of an older
  incarnation of this node is discarded with a log entry (bif.c:2489-2501).

## Pids

A local pid is an immediate made of a 4-bit tag, a 28-bit number carrying the
scrambled table index and a 32-bit serial. A remote pid is a boxed
`ExternalThing` pointing at an interned ErlNode.

* At most 2^27 - 1 processes exist (erl_term.h:79-81, 645-653;
  erl_ptab.h:174, 301-309), and `ExternalThing` holds an ErlNode pointer and
  a 32-bit number and serial (erl_term.h:1137-1167).
* `phash` and `phash2` hash a remote pid by number only, while
  `erts_internal_hash` mixes in the ErlNode pointer
  (erl_term_hashing.c:273-278, 1613-1616, 2172-2178).
* Encoding always uses NEW_PID_EXT; decoding a local pid is
  `make_internal_pid(make_pid_data(ser, num))` after range checks only, as is
  `list_to_pid` (external.c:2967-2975, 3175-3182; bif.c:4574-4577).

## Spawn atomicity

Spawning with a link or monitor is documented as atomic. Locally the child's
link, monitor and spawn reply are in place before it is scheduled; remotely
the serving node replies only on an unchanged connection.

* "The spawn operation and the link operation will be performed atomically"
  (system/doc/reference_manual/ref_man_processes.md:572-575); the child is
  created with all locks held, and the reply is sent before
  `schedule_process` (erl_process.c:12533-12536, 12907-12974, 13121).
* Remote `spawn_opt/5` on `noconnection` or `notsup` spawns a local
  `erts_internal:crasher` (pre/erlang.erl:11049-11075); the serving node
  queues the arguments as the first message and replies only if the
  connection id is unchanged (erl_process.c:13044-13110).

## Mailbox limits and accounting

There is no limit on mailbox length or bytes. `max_heap_size` is checked only
at GC and counts on_heap queued messages but not off_heap ones, and memory in
transit is charged to no process.

* A grep for mailbox limits finds only the `long_message_queue` monitor
  (pre/erlang.erl:6461; erl_trace.c:1890); "The size check is only done when
  a garbage collection is triggered" (pre/erlang.erl:8105-8165;
  erl_gc.c:606-640).
* `process_info(memory)` counts the outer queue only with
  `include_sigs_in_transit` (erl_process_dump.c:117-185).

## Code loading

`erts_internal:prepare_loading/2` parses a module and generates its code
without taking a lock; `erlang:finish_loading/1` takes the global load
permission and commits the module to the staging code index behind a code
barrier. A module has current and old code, and old code is freed only after
every process has checked its own stack.

* Both are plain BIFs, and the JIT generates machine code inside
  `prepare_loading` on the calling normal scheduler (bif.tab:611, 768;
  beam_bif_load.c:231-266, 340-508; jit/asm_load.c:1013-1018); the parser
  requires Code, AtU8, ImpT and ExpT among 16 known chunks and inserts atoms
  as it parses (beam_file.c:1588-1605, 1645-1681, 291).
* Three code indices version the module, export, fun, record, catch and
  range tables, and a reader's index "is guaranteed to be valid until the
  calling BIF returns" (code_ix.h:72, 156-162; code_ix.c:142-171).
* Commit runs `isb` on every normal scheduler and then a thread-progress
  later op, under the global "stage" and "mod" permissions with FIFO waiters
  (code_ix.c:39-41, 51-82, 546-592).
* Loading over current plus old code fails with `not_purged`; a purge, run
  only by `erts_code_purger`, makes every process check its own stack, kills
  referencing processes on a hard purge and queues the literal area
  (beam_bif_load.c:429-455, 2088-2090, 1148-1217, 2222-2327).
* `finish_loading` and `delete_module` check no caller, and sticky modules
  exist only in kernel's `code_server` (beam_bif_load.c:340-354;
  kernel/code_server.erl:81-98).

## Loader trust

The loader checks the container, operand tags and table indices but verifies
no data flow, types or stack frames: it relies on the compiler's
`beam_validator`, nothing records that the validator ran, and the JIT also
trusts the Type chunk. OTP's guide declares loaded code fully trusted.

* "All loaded code is assumed to be trusted", and "a malicious BEAM module
  can do anything, including breaking the memory safety protections of the
  runtime system" (system/doc/design_principles/secure_coding.md:61-66).
* Checked: chunk bounds, opcode range, atom and literal indices, labels,
  register numbers below `MAX_REG` (1024), import arity and operand tags
  (beam_file.c:2291-2334, 2408; erl_vm.h:55; beam_load.c:530-542, 639-644).
* Unchecked: y registers against the frame, guarded only by a debug `ASSERT`
  in the JIT's `deallocate` (jit/arm/instr_common.cpp:223-229); operand
  widths outside DEBUG (emu/emu_load.c:1010-1024; jit/asm_load.c:469-483);
  register numbers in type-hinted operands (beam_file.c:2415-2439); string
  offsets (emu/emu_load.c:474-484).
* The line table's name check admits an index one past the end of its array
  (beam_file.c:475, 494-495, 517; inferred from the arithmetic); file counts
  become allocation sizes, and allocation failure ends the VM
  (beam_file.c:1491-1496; erl_alloc.h:207-210).
* For `tuple_size/1` on an operand the Type chunk calls a tuple, the JIT
  reads the header unchecked, and the Type chunk is outside the module's MD5
  (jit/arm/instr_guard_bifs.cpp:1335-1350; beam_file.c:1751-1830).
* LitT is decoded without `safe`, and atoms created by a failed load stay
  (beam_file.c:1437, 1447, 1851-1855).

## Atoms

One node-global atom table only grows, under one rwlock, and an atom term is
an immediate holding its index. Filling the table ends the emulator, atoms are
never freed, and each distribution connection caches atoms.

* The table is an IndexTable under a FREQUENT_READ rwlock, lookup by index
  takes no lock, and an atom term is `index << 6 | 0x0B` (atom.c:38-40,
  457-465; atom.h:71-75; erl_term.h:79-88, 300).
* The default limit is 1,048,576 atoms, `+t` accepts 8192 to 2^31 - 1, and a
  name holds at most 255 characters (atom.h:29-44; erl_init.c:138).
* A full table calls `erts_exit(ERTS_DUMP_EXIT, "no more index entries in %s
  (max=%d)\n", ...)` (index.c:87-90); `atom_free` is empty, and names live in
  the never-freed global literal area (atom.c:141-157, 188-191).
* `list_to_atom`, `binary_to_atom`, `binary_to_term` without `safe`,
  distribution headers, the loader and NIFs create atoms (bif.c:3217-3235;
  external.c:4535, 1099-1102; beam_file.c:274-295; erl_nif.c:2085-2112).
* Each connection caches 2048 atoms each way, slotted by atom index mod 2039,
  at most 255 per message (external.h:102-120; external.c:212-231,
  1071-1107).

## ETS

Every table is node-global and reachable from any normal scheduler, named by
a magic reference or, for a named table, by an atom in a node-wide registry.
Protection is a status bit checked against the caller's pid on each access,
which the owner and any process flagged ETS super user pass.

* A tid is a magic binary holding an atomic table pointer that delete swaps
  to NULL (erl_db.c:264-356); the name registry's buckets are atomic pointers
  written under 256 mutexes and read lock-free, and there is no table-count
  limit (erl_db.c:371-412, 820-881, 4784-4801).
* An access lacking `DB_READ`, `DB_WRITE` or `DB_INFO` fails unless the
  caller owns the table or has `F_ETS_SUPER_USER` (erl_db_util.h:449-451;
  erl_db.c:788-790, 902-904); the exported `erts_internal:ets_super_user/1`
  sets that flag on its caller with no check (erl_db.c:4712-4722;
  bif.tab:199).
* `ets:all/0` lists private tables and `ets:info/1,2` reads any table
  (erl_db.c:3574-3584, 4434, 4544); a process meeting a busy table finishes
  another process's pending `insert/2` itself (erl_db.c:773-787).
* Objects are deep-copied, literals included, sharing off-heap parts by
  refcount, with no quota (erl_db_util.c:3559-3623; erl_db.h:161-196); each
  table has an rwlock, and `write_concurrency` hash tables add 64 bucket
  locks by default, up to 8192 (erl_db.c:683-699; erl_db_hash.h:51-55;
  erl_db_hash.c:98-103).

## Binaries

Off-heap data is a refcounted `Binary` shared across the node and held by a
process through a 3-word `BinRef` wrapped by a 5-word `ErlSubBits`. Binaries
of at most 64 bytes live on the heap, and a local send increments the
refcount instead of copying bytes.

* `Binary` holds flags, an atomic refcount and the bytes, whose writable
  flags are "valid iff the reference count is 1" (erl_binary.h:40-71); a
  `BinRef` "should never be exposed to the user" (erl_bits.h:58-154).
* A slice over 64 bytes shares its parent's `BinRef` (erl_bits.h:166-168;
  erl_bits.c:2635-2670), and a process's off-heap list drives a virtual
  binary heap GC (erl_gc.c:2996-3110).
* A NIF resource is a magic binary whose destructor runs as misc aux work on
  the scheduler dropping the last reference, and resource types are global,
  keyed by module and name (erl_binary.h:87-103; erl_nif.c:2500-2518,
  2957-3030, 3121-3262).
* Distribution decoding may keep a whole receive buffer alive when one
  binary exceeds 25% of it (external.c:4925-4953).

## External term format

One decoder serves `binary_to_term`, distribution, loader literals, NIFs and
compressed ETS objects: a bounds-checking size pass, then an iterative
builder that can yield. `safe` blocks only the creation of atoms and export
entries, and local pids are rebuilt from bare numbers.

| Kind | Tags, with their characters (external.h:33-84) |
|---|---|
| integers, floats | SMALL_INTEGER `a`, INTEGER `b`, SMALL_BIG `n`, LARGE_BIG `o`; NEW_FLOAT `F`, FLOAT `c` |
| atoms | ATOM `d`, SMALL_ATOM `s`, ATOM_UTF8 `v`, SMALL_ATOM_UTF8 `w`; ATOM_CACHE_REF `R` in distribution |
| pids, ports, references | NEW_PID `X`, PID `g`; V4_PORT `x`, NEW_PORT `Y`, PORT `f`; NEWER_REFERENCE `Z`, NEW_REFERENCE `r`, REFERENCE `e` |
| containers | SMALL_TUPLE `h`, LARGE_TUPLE `i`, NIL `j`, STRING `k`, LIST `l`, MAP `t` |
| binaries, funs, records | BINARY `m`, BIT_BINARY `M`; NEW_FUN `p`, EXPORT `q`, FUN `u` (rejected on decode); RECORD `C` |
| framing | version 131, LOCAL `y`, COMPRESSED `P`; DIST_HEADER `D`, DIST_FRAG_HEADER `E`, DIST_FRAG_CONT `F`, HOPEFUL_DATA `H` |
| ETS-internal | ATOM_INTERNAL_REF2 `I`, ATOM_INTERNAL_REF3 `K`, BINARY_INTERNAL_REF `J`, BITSTRING_INTERNAL_REF `L`, MAGIC_REF_INTERNAL_REF `N` |

* `decoded_size` checks every length and computes the exact heap, and
  `dec_term` builds without recursion or a depth limit (external.c:6040-6549,
  4307-5492, 4427-4430); `binary_to_term` decodes `ERTS_BIF_REDS_LEFT` x 128
  bytes per slice and traps (external.c:1915-1954).
* `safe` is tested only for atoms and EXPORT_EXT (external.c:4530-4539,
  3073-3082, 5032-5036); NEW_FUN_EXT always makes a fun stub, and a remote pid
  always gets a node entry (external.c:5162-5167, 3189).
* A local reference whose numbers match a live magic binary decodes to a
  magic reference to it, and a magic binary enters `magic_ref_table` when
  encoded or printed (external.c:4845-4854, 3644; bif.c:4463, 4792-4796).
* The pointer-carrying internal tags need the ETS-only `internal_tags` flag,
  but ATOM_INTERNAL_REF2 and 3, raw atom indices, are not gated
  (external.c:6405-6436, 1259-1264).
* Limits: tuple arity below 2^24, references of at most 5 words, at most 255
  fun free variables, finite floats (external.c:6146-6184, 6229, 6287, 6392);
  decoding ends without checking for trailing bytes, which `used` counts
  (external.c:2090-2108; pre/erlang.erl:1363-1374).
* The encoder never emits PID_EXT, PORT_EXT, NEW_PORT_EXT, REFERENCE_EXT,
  NEW_REFERENCE_EXT or FUN_EXT (external.c:2967-4036); the LOCAL_EXT hash "is
  not guaranteed to, and is not intended to, prevent decoding of an
  intentionally forged encoding" (erts/doc/guides/erl_ext_dist.md:770-774).

## BIFs and NIFs

BIFs come from a static table compiled into C arrays, each with an export
entry from boot, and the loader binds most BIF calls as direct C calls. NIFs
are loaded by an instruction, bound to the calling module, and run as
unrestricted native code on the scheduler thread.

* `bif.tab` has 473 `bif`, 73 `ubif` and 7 `hbif` lines and no `gcbif` kind
  (bif.tab:28-39, 64-470; erts/emulator/utils/make_tables:94), from which
  `make_tables` generates `bif_table[]` and the dirty wrappers
  (erts/emulator/utils/make_tables:169-341).
* An import of a BIF binds straight to `bif_table[n]`, and nothing restricts
  which module imports which BIF, `erts_internal` and `erts_debug` included
  (emu/emu_load.c:117-140; jit/asm_load.c:182-192).
* `load_nif` takes the code-modification permission, finds the calling module
  from the PC, `dlopen`s the library, calls its init before the version
  checks and runs `upgrade` under a thread-progress block
  (emu/bif_instrs.tab:638-666; erl_nif.c:4743-4822, 4951-4988).
* A NIF's flags must be 0, DIRTY_IO or DIRTY_CPU (erl_nif.c:4868-4875); the
  static NIFs `prim_tty`, `erl_tracer`, `prim_buffer`, `prim_file`, `zlib`,
  `zstd`, `prim_socket` and `prim_net` are initialised at boot
  (Makefile.in:1236-1243; erl_nif.c:5311-5322).

## Registered names and persistent_term

Registered names are one node-wide hash from atoms to raw `Process` or `Port`
pointers, with no owner. `persistent_term` is one node-global table read
without locks or copying, updated one writer at a time and published after
thread progress.

* `register/2` takes any live, unnamed local pid or port, `unregister/1`
  checks no ownership, and `whereis/1` carries the comment "this is a rather
  unsafe BIF" (register.c:36-43, 175-265, 429-544; bif.c:2340).
* `persistent_term:get/1` returns the stored term without copying
  (erl_bif_persistent.c:358-372); an update copies `{Key, Value}` into its own
  literal area, visible after a thread-progress later op
  (erl_bif_persistent.c:744-779).
* Nothing checks the caller, and erasing a non-immediate value starts the
  node-wide literal-area copy (erl_bif_persistent.c:551-567, 1292-1305;
  pre/persistent_term.erl:29-31).

## Inspecting and controlling another process

None of these operations checks the caller; at most they check that the
target is a local pid, and some run on the caller's thread against the
target's struct. Holding a pid is enough to read a process's mailbox and
dictionary, kill, suspend, trace or retarget it.

| Operation | Check | Runs | Citation |
|---|---|---|---|
| `process_info/1,2` | local pid | caller, under the target's locks if it is idle with no signals pending; else a signal | erl_bif_info.c:1364-1418; erl_process.c:14835-14889 |
| `exit(Pid, kill)` | none | signal; untrappable | bif.c:1721-1870; erl_proc_sig_queue.c:4740-4770 |
| `suspend_process/1,2` | not self, local pid | caller, or a signal | erl_process.c:9012-9174, 9026-9030 |
| `garbage_collect/2`, `check_process_code/3` | none | system task in the target | erl_process.c:11309-11515 |
| `group_leader/2` | none | caller under trylock, else a signal | bif.c:4860-4941 |
| `trace/3,4` | not traced by another live tracer | caller, holding all tracee locks | erl_bif_trace.c:853-868, 1004-1005 |
| `process_flag(Pid, save_calls, _)`, `process_display/2` | none | RPC in the target | bif.c:2262-2303; erl_bif_info.c:4116-4156 |

* A system process's exit ends the node; the code purger, the literal-area
  collector, three dirty signal handlers and the trace cleaner are system
  processes, and any process can spawn more with the exported
  `erts_internal:spawn_system_process/3` (erl_process.c:14186-14188;
  erl_init.c:2540-2606; bif.tab:733).
* `erts_debug:set_internal_state(available_internal_state, true)` is open to
  any process and only logs a warning; it then exposes abort, thread-progress
  blocking and `proc_sig_block` on any pid (erl_bif_info.c:4332, 5041-5057,
  5232-5233, 5452-5469).
* `system_flag/2`, `halt/1,2`, `trace_pattern` and `erts_debug:breakpoint/2`
  act node-wide with no caller check (bif.c:4972-5304, 4309-4398;
  erl_bif_trace.c:2621-2703; beam_debug.c:269-342).

## Literal areas

Module literals and persistent terms live in literal areas, shared by pointer
and never moved by GC. Freeing an area needs every process on the node to
copy its references out, and global literals are never freed.

* With the default physical-memory reservation, a pointer is a literal
  exactly when it lies in one reserved range, 1 GiB by default
  (erl_alloc.h:193-196, 345-348; sys/common/erl_mmap.c:407).
* Send, signals and spawn arguments skip literals except those of the area
  being released, while ETS copies them (copy.c:83-107; erl_db_util.c:3655).
* Release publishes the area, waits for thread progress, has every process
  copy references out of its queue, heap, stack and dictionary, and frees it
  (beam_bif_load.c:1465-1523, 1654-1724;
  pre/erts_literal_area_collector.erl:118-160;
  erl_proc_sig_queue.c:8128-8240).

## Census of node-global state

Nearly every naming and identity space is node-global, and several are
bounded tables that are never reclaimed. Per-process state is the heap and
stack, mailbox, dictionary, links and monitors, group leader, off-heap list,
owned ETS tables and trace flags (erl_process.h:1043-1204).

| Area | Node-global state | Citation |
|---|---|---|
| code | code indices and permissions; module table x3 (65,536), export, fun and record tables (524,288 each), each ending the VM when full | code_ix.c:48-82; module.c:44; export.c:36; erl_fun.c:35; erl_record.c:39; erl_code_staged.h:104, 367-371; index.c:87-90 |
| code | catches, ranges, breakpoints, JIT allocator, purger and literal-release state | beam_catches.c:57; beam_ranges.c:64-65; jit/beam_jit_main.cpp:77-79; beam_bif_load.c:53-68 |
| native | `bif_table[]`, NIF call table, resource types, static NIFs, drivers | erts/emulator/utils/make_tables:284-296; erl_nif.c:4657, 2504; io.c:69-70 |
| terms | atoms, global literals, `persistent_term`, `magic_ref_table`, unique counters, every refcounted `Binary` | atom.c:38-40; erl_global_literals.c:51-66; erl_bif_persistent.c:187; erl_bif_unique.c:41-44 |
| names | registered names; ETS name registry, every table | register.c:37-43; erl_db.c:374-401 |
| entities | process, port, node and dist tables; per-connection atom caches | erl_process.c:152; io.c:76; erl_node_tables.c:38-53 |
| runtime | run queues, scheduler data and registers, thread progress, time, pollsets | erl_process.c:348, 393-395; erl_thr_progress.c:262-264; erl_time_sup.c:51-67 |
| control | trace sessions, seq tracer, logger, debugger, internal-state switch, environment copy | erl_bif_trace.c:116-117; erl_trace.c:72-75; erl_debugger.c:38-51; sys/unix/sys_env.c:33-34 |

## BeamAsm on AArch64

BeamAsm compiles each module whole, at load time, into asmjit memory mapped
twice on Linux, RX and RW, for the module's whole life. Cache maintenance
uses unprivileged instructions plus an ISB that a code barrier delivers to
every normal scheduler, and generated code pins process state in x19-x28.

* The allocator tries dual mapping first and silently falls back to
  single-mapped RWX memory; `+JPperf`, `+JMsingle`, Valgrind and macOS arm64
  force single mapping (jit/beam_jit_main.cpp:181-243;
  erts/doc/references/erl_cmd.md:793-800).
* The dual mapping is a memfd mapped twice `MAP_SHARED`, and sealing calls
  `protect_jit_memory`, a no-op without `pthread_jit_write_protect_np`, so the
  RW alias stays writable (asmjit/core/virtmem.cpp:587-613, 1218-1224;
  jit/beam_jit_main.cpp:430-448).
* Each seal flushes the module with `dc cvau`, `dsb ish`, `ic ivau` and `dsb
  ish`; the `isb` runs on each normal scheduler as aux work, and dirty
  schedulers, which run only C, get none (jit/beam_jit_main.cpp:450-505;
  code_ix.c:546-592; beam_common.c:56-61).

| Register | Role (jit/arm/beam_asm.hpp) | Line |
|---|---|---|
| x19; x20, x21, w22, x23 | register block; E (Erlang stack), `c_p`, FCALLS, HTOP | 83; 85-88 |
| x24; x25-x28, x15-x16 | active code index; X0-X3 callee-saved, X4-X5 caller-saved | 95; 117-131 |
| x0-x14; x18 | arguments and temporaries; never used ("reserved on Apple platforms") | 153-175 |
| d8-d15 | Erlang float registers 0-7 | 182-189 |

* `process_main` carves the register block, over 16 KiB, off the scheduler
  thread's `sp` and never returns (jit/arm/process_main.cpp:61-75;
  erl_process.h:658-666; size inferred).
* Generated code uses q registers and NEON `cnt` and has no PAC or BTI
  instructions, JIT pages get no `PROT_BTI`, and configure adds
  `-mbranch-protection=standard` when the compiler accepts it
  (jit/arm/instr_common.cpp:459, 857-879; asmjit/core/virtmem.cpp:430-436;
  make/autoconf/otp.m4:3182).
* The JIT is C++17 with exceptions, RTTI and the STL (configure.ac:3117-3128);
  `ERTS_ASSERT("Failed to allocate module code")` cannot fire, and
  `handleError` does not override asmjit's `handle_error`, whose default
  ignores errors (jit/beam_jit_common.cpp:121-123;
  jit/beam_jit_common.hpp:75, 116; asmjit/core/errorhandler.cpp:15-17).

## OTP boot on a UNIX host

`erl_init:start/2` loads the static NIFs and calls `init:boot/1`, `init`
reads the boot script through `erl_prim_loader`, and kernel starts
`kernel_sup` with a fixed child order. Every file read ends in `prim_file`
NIFs over POSIX calls, and the terminal goes through `prim_tty` NIFs.

* `erl_init:start/2` loads the `zlib`, `erl_tracer`, `prim_buffer` and
  `prim_file` NIFs (pre/erl_init.erl:35-50), and `init` needs one `-root` and
  one `-bindir` and reads `Root/bin/start.boot` (pre/init.erl:1226-1240).
* `kernel_sup` is one_for_all with intensity 0 and starts `code_server`,
  `standard_error`, `file_server_2`, `on_load`, `inet_db`, the distribution
  children, `erl_signal_server`, `user`, `logger_sup`, `kernel_config`,
  `kernel_refc` and `kernel_safe_sup`, in that order
  (kernel/kernel.erl:91-94, 168-226).
* The `efile` loader exits unless `prim_file:get_cwd()` succeeds, and
  `code_server` hard-matches `{ok,Dirs} = erl_prim_loader:list_dir(LibDir)`
  (pre/erl_prim_loader.erl:196-214; kernel/code_server.erl:104-113);
  `prim_file` is 33 NIFs, 32 of them dirty I/O
  (nifs/common/prim_file_nif.c:177-219).
* Raw terminal mode on `{unix,_}` requires terminfo, while
  `prim_tty:init_ssh/3` opens no descriptors and serves `ssh_cli`
  (kernel/prim_tty.erl:331-349, 308-317; lib/ssh/src/ssh_cli.erl:538-541).

## The operating-system layer

ERTS reaches its host through layers chosen when it is configured: ethread
for threads, locks, events and atomics; a sys layer picked by
`ERLANG_OSTYPE`; a poll set over file descriptors; and memory primitives
under `erl_mmap`. None has a back end that fits a kernel, and configure
rejects an operating system it does not know. These findings come from a
separate read-only pass; fourteen of their citations were re-read before
writing.

* ethread has two back ends, pthread and win32, and otherwise stops with
  `#error "No supported thread lib found"` (inc/ethread.h:120-221). A back
  end supplies threads, thread-specific data, a "qlock", a mutex and
  condition variable, a per-thread event and a monotonic clock
  (inc/ethread.h:526-551; inc/ethr_internal.h:55-79) (inferred from the
  declarations).
* ERTS's own mutex is compiled out (`#if !defined(ETHR_FORCE_PTHREAD_MUTEX)
  && 0`, inc/ethread.h:158-160), so `ethr_mutex` and `ethr_cond` wrap
  `pthread_mutex_t` and `pthread_cond_t` (inc/ethr_mutex.h:216-232). Its own
  reader-writer lock is on by default (inc/ethread.h:154-156) and queues
  waiters under a qlock that is a pthread mutex (inc/ethr_mutex.h:100-111).
* The per-thread event is a futex word on Linux and otherwise a mutex, a
  condition variable and a pipe (inc/pthread/ethr_event.h:27-158); a thread
  finds its event through `pthread_getspecific` (inc/ethread.h:641-651).
  ethread keeps its own monotonic clock for timed waits
  (lib_src/pthread/ethread.c:681-747).
* The emulator never calls pthread directly: every call is in
  lib_src/pthread/ethread.c (819 lines), and a grep of `erts/emulator` finds
  only a comment (erl_threads.h:260-268).
* AArch64 has no architecture directory in ethread, so its atomics are the
  compiler's `__atomic` builtins (inc/ethread.h:399-403;
  inc/gcc/ethr_atomic.h:37-150). ERTS trusts their memory ordering on
  AArch64 only for GCC 8.3 or later and Apple clang 12 or later; with any
  other clang, LLVM's included, it uses relaxed operations with explicit
  barriers (inc/gcc/ethread.h:59-92, 124-138), which are `dmb sy`, `dmb st`
  and `dmb ld` (inc/gcc/ethr_membar.h:166-183).
  `--enable-trust-gcc-atomic-builtins-memory-barriers` overrides this and
  defaults to off (make/autoconf/otp.m4:1663-1671).
* The sys layer is `sys/unix` or `sys/win32`, chosen by `ERLANG_OSTYPE`
  (configure.ac:908-916; sys.h:120-127). Its contract is the function list
  of sys.h (sys.h:672-957) and three drivers that io.c always initialises:
  `fd`, `spawn` and, outside win32, `forker` (io.c:3029-3035). The win32
  layer is about 6,500 lines of C (sys/win32/, by `wc`).
* The UNIX layer parks the initial thread in `select` forever
  (sys/unix/sys.c:1229-1287), dispatches signals from a pipe on a thread of
  its own (sys/unix/sys.c:1105-1201), probes whether memory is readable by
  writing it into a pipe (sys/unix/sys.c:497-516), and allocates with
  `malloc` and `posix_memalign` (sys/unix/sys.c:951-1024).
* Time is read through macros chosen at configure time, in a compile-time
  unit of nanoseconds or microseconds, or a unit set at run time, which
  win32 sets to its performance counter's frequency (erl_unix_sys.h:193-211;
  erl_win_sys.h:185-186; sys/win32/sys_time.c:444-458). configure has no
  option for a raw hardware counter, and a missing wall clock is fatal
  (make/autoconf/otp.m4:826-1114, 2626-2627).
* The poll set is a compile-time choice of kqueue, epoll, /dev/poll, `poll`
  or `select`, all over file descriptors (sys/common/erl_poll.h:58-138); no
  configure option removes it, and `erts_poll_init` always runs
  (sys/common/erl_check_io.c:2527-2598).
* `erl_mmap` and the segment cache exist only with a genuine `mmap`
  (sys/common/erl_mmap.h:69-75; sys/common/erl_mseg.h:37-43); without it, as
  on win32, carriers come from the system allocator. `ErtsMMapInit` has a
  `predefined_area` for handing ERTS a ready region, which nothing assigns
  (sys/common/erl_mmap.h:80-97). Without physical-memory reservation,
  literals carry a pointer tag instead of being recognised by address
  (erl_term.h:55-61).
* autoconf's `config.sub` (autoconf 2.72) rejects an operating system it
  does not list, such as `erxos`, with "Invalid configuration ... OS
  'erxos' not recognized" (make/autoconf/config.sub:1784-1788); its list
  includes `fuchsia`, `zephyr`, `mlibc` and `none`
  (make/autoconf/config.sub:1738-1775).
* configure builds both flavours, `FLAVORS="emu jit"`, and makes the JIT
  the primary flavour when it finds a C++17 compiler (configure.ac:3175-3179,
  3344-3357). `--enable-static-nifs` links NIFs into the emulator
  (configure.ac:395-399).

## Sizes and toolchain probe

Line counts of the pinned tree by `wc -l`, comments and blank lines included,
with areas named from `erts/emulator/` or `erts/`, and a probe of the host
LLVM toolchain for EL1 code, whose source follows. Four counts and every
probe result were re-measured for this record.

| Area | Lines | Area | Lines | Area | Lines | Area | Lines |
|---|---|---|---|---|---|---|---|
| beam/*.{c,h} | 264,197 | beam/emu/*.{c,h} | 2,519 | beam/jit (6,383 in C and C++) | 6,510 | beam/jit/arm | 19,923 |
| asmjit, all | 113,517 | asmjit core and arm | 57,817 | sys/common | 12,472 | sys/unix | 6,566 |
| sys/win32 | 7,410 | lib_src common and pthread | 14,052 | include/internal | 18,011 | nifs/common | 37,374 |
| nifs/unix | 11,809 | drivers common and unix | 16,832 | bundled pcre | 45,759 | bundled zlib; zstd; ryu | 20,529; 46,791; 1,647 |
| erts/preloaded/src | 29,218 | lib/kernel/src | 94,034 | lib/stdlib/src | 184,136 | lib/compiler/src | 82,291 |
| lib/sasl/src | 11,582 | lib/runtime_tools/src | 8,764 | lib/tools/src | 21,319 | lib/crypto/src | 6,252 |

```c
__thread int counter;
_Thread_local void *cur;
int bump(void) { return ++counter; }
void *get(void) { return cur; }
double fadd(double a, double b) { return a + b; }
```

* With `clang --target=aarch64-none-elf -O2 -ffreestanding -S`,
  `-ftls-model=local-exec -mtp=el1` reaches both variables with `mrs x8,
  TPIDR_EL1` and `add`s with `:tprel_hi12:` and `:tprel_lo12_nc:`;
  `-mtp=el0` gives `TPIDR_EL0`, and `-fPIC -ftls-model=initial-exec` gives
  `adrp :gottprel:` and `ldr :gottprel_lo12:` (probe lines 1-4).
* `-mgeneral-regs-only` rejects `fadd`: "'fadd' requires 'double' type
  support, but ABI 'aapcs' does not support it" (probe line 5).
* `ld.lld` and `lld` are not installed, and Homebrew LLVM ships compiler-rt
  only for Darwin (`~/homebrew/opt/llvm/lib/clang/23/lib/darwin`).

## Precedents outside OTP

Two facts from Linux v6.12 on arm64, taken from the measurement notes. They
are cited by file and function and were not re-read for this record.

* `get_current()` finds the current task with `asm ("mrs %0, sp_el0" : "=r"
  (sp_el0));` (arch/arm64/include/asm/current.h, `get_current`).
* Running a KVM guest is a call that returns on every exit:
  `kvm_arch_vcpu_ioctl_run` loops over `kvm_arm_vcpu_enter_exit(vcpu)`, which
  calls `kvm_call_hyp_ret(__kvm_vcpu_run, vcpu)`, and `handle_exit`
  (arch/arm64/kvm/arm.c, `kvm_arch_vcpu_ioctl_run`).

## Facts that constrain erXos

The facts that most constrain ERTS inside a kernel. Each is one sentence.

1. A switch saves only `i`, `htop`, `stop`, live X registers, `arity` and
   `current`; no process has a C stack (emu/beam_emu.c:466-500).
2. Preemption is cooperative: a NIF, a BIF that does not trap or a GC below
   128K words holds its thread until it returns (erl_vm.h:53; erl_gc.h:26).
3. Lock-free process lookup depends on thread progress, which dirty threads
   never confirm (erl_process_lock.h:1135-1157; erl_process.c:8834, 8884).
4. A dirty NIF runs without its process's MAIN lock while a normal scheduler
   may run that process's exit (erl_nif.c:468; erl_process.c:10095-10111).
5. Scheduler data is reached through `pthread_getspecific`, with 13 keys and
   no compiler TLS (erl_threads.h:2431-2434; lib_src/pthread/ethread.c:619).
6. All scheduler threads exist from boot, and an idle one spins 10,000 times
   and then blocks in a futex or epoll (erl_process.c:8941-8949, 69-85).
7. Timers, aux work and thread-progress later ops each belong to one normal
   scheduler (erl_hl_timer.c:1766-1789; erl_process.c:2325-2335).
8. Every enqueue locks the receiver's MSGQ or one of its 64 buffer mutexes,
   and an on_heap send writes into its heap (erl_message.c:372-458, 621-696).
9. Order holds only per sender-receiver pair, and a message waits for every
   earlier non-message signal (erl_proc_sig_queue.c:10284-10287, 7040-7045).
10. A monitor's two halves share one allocation, and RPC signals carry C
    function pointers (erl_monitor_link.h:719-727; erl_proc_sig_queue.h:1074).
11. Connection loss fans out to every link and monitor on the connection,
    however many, as aux work on one scheduler (dist.c:922-1117, 510-547).
12. Any process can forge a local pid, and a reference matching a live magic
    binary decodes to it (external.c:3175-3182, 4845-4854; bif.c:4574-4577).
13. A full atom, module, export or fun table ends the emulator, and atoms are
    never freed (index.c:87-90; erl_code_staged.h:367-371; atom.c:188-191).
14. `safe` stops only atom and export creation; decoding still creates fun
    stubs and node entries (external.c:4530-4539, 5162-5167, 3189).
15. Loaded code is fully trusted, and the JIT relies on the unverified Type
    chunk (system/doc/design_principles/secure_coding.md:61-66;
    jit/arm/instr_guard_bifs.cpp:1335-1350).
16. `exit/2`, suspension, tracing and `group_leader/2` check nothing about the
    caller beyond a local pid (bif.c:1721-1730, 4860-4870;
    erl_process.c:9024-9032; erl_bif_trace.c:853-868).
17. A system process's death halts the node, and any process can spawn one
    (erl_process.c:14186-14188; bif.tab:733).
18. Literals are shared by pointer, so freeing a literal area makes every
    process copy references out (copy.c:83-107; beam_bif_load.c:1465-1523).
19. On Linux BeamAsm keeps a writable alias of all code, and if dual mapping
    fails it silently uses RWX memory (jit/beam_jit_main.cpp:225-229, 430-448).
20. Loading code needs EL0 `dc cvau` and `ic ivau` and an `isb` run only by
    normal schedulers (jit/beam_jit_main.cpp:450-505; code_ix.c:546-592).
21. JIT code uses d8-d15 and q registers and has no BTI landing pads
    (jit/arm/beam_asm.hpp:182-189; asmjit/core/virtmem.cpp:430-436).
22. Boot reads every file through `prim_file` NIFs and stops if `get_cwd` or
    `list_dir` of the library root fails (pre/erl_prim_loader.erl:196-214;
    kernel/code_server.erl:104-113).

## Sources

The sources behind every citation. All were read or run on 2026-10-29.

* Erlang/OTP 29.1.2: `otp_src_29.1.2.tar.gz` from the GitHub release
  `OTP-29.1.2` of erlang/otp, whose README is dated 2026-10-14, SHA-256
  `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`, read
  2026-10-29; asmjit at commit `5fe1940275d04432da841896bac0a66cc2375551`.
* Documents in that tree: system/doc/design_principles/secure_coding.md,
  system/doc/reference_manual/ref_man_processes.md,
  erts/doc/guides/erl_ext_dist.md, erts/doc/references/erl_cmd.md,
  erts/emulator/internal_doc/BeamAsm.md, and the documentation in
  pre/erlang.erl and pre/persistent_term.erl.
* Linux stable (gitlab.com/linux-kernel/stable), tag v6.12:
  arch/arm64/include/asm/current.h and arch/arm64/kvm/arm.c, read
  2026-10-29 for the measurement notes.
* Homebrew LLVM clang 23.1.4, run 2026-10-29 for the toolchain probe.
