# Research record: what ERTS requires from its host, and prior art

A point-in-time report of what the Erlang runtime system (ERTS) of OTP
29.1.2 and the musl C library ask of the operating system beneath them, read
from their sources, and of what earlier systems did when they hosted BEAM
somewhere unusual. It settles which host facilities are mandatory, which a
build option or emulator flag removes, what a minimal Linux-compatible
system-call surface for ERTS looks like, and what Erlang distribution assumes
about its peers. [design.md](design.md) and `design-substrate.md` (a design
this record served, since superseded) use these findings; the measured
numbers are in [research-baselines.md](research-baselines.md). Findings here
are never edited in place; a re-check gets a new record.

**Date:** 2026-10-29.
**Host:** Apple M4 Max, macOS 27.0.1 (26A434).
**Sources read** (extracted and read only; no script, makefile or binary
from them was run):

* Erlang/OTP 29.1.2, `otp_src_29.1.2.tar.gz` from the GitHub release
  `OTP-29.1.2`, SHA-256
  `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`; its
  README dates the patch release 2026-10-14 and lists erts-17.1.1.
* musl 1.2.6, `musl-1.2.6.tar.gz` from musl.libc.org, SHA-256
  `d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a`.
* The download page https://www.erlang.org/downloads (2026-10-29) and
  https://musl.libc.org/ (2026-10-29).
* For [Prior art](#prior-art): the primary sources listed at the end of
  that section, fetched 2026-10-29; repository files were read at the
  commits given.

Paths below are relative to the root of each source tree; `erts/...` and
`lib/...` are OTP, `src/...` and `arch/...` are musl.

## Releases current on 2026-10-29

* **OTP.** The download page names 29.1.2 as the latest release. The 29 line
  has 29.0 through 29.0.6, 29.1, 29.1.1 and 29.1.2; the previous line ends at
  28.5.0.8, and 27 at 27.3.4.19. 29.1.2 fixes five CVEs according to its
  README. Homebrew on the primary host has 28.4.2.
* **musl.** 1.2.6 is the latest release. The site lists advisories that
  affect 1.2.6 and publishes patches for them: CVE-2026-107891 (`regcomp`
  with untrusted regular expressions), CVE-2026-40200 and CVE-2026-6042. A
  build of 1.2.6 applies all three.

## What the emulator starts

**Boot order.** `erl_start` (`erts/emulator/beam/erl_init.c`) calls
`erl_sys_args` (line 1281), starts the scheduler threads with
`erts_start_schedulers` (line 2610), and finally turns the main thread into
`erts_sys_main_thread` (line 2617). `erl_sys_late_init` (line 325) starts the
forker.

**Threads.** `erts_start_schedulers` (`erts/emulator/beam/erl_process.c`,
lines 8908 to 9012) creates, in order: a run-queue supervisor only when
`+sbwt` supervision is configured (`erts_runq_supervision_interval` is 0 by
default, line 343), the normal schedulers, the dirty CPU schedulers, the
dirty I/O schedulers, the auxiliary work threads and the poll threads. Other
threads: the async pool (`erl_async.c:206`), the system-message dispatcher
(`erl_trace.c`, around line 2914), and the signal dispatcher
(`erts/emulator/sys/unix/sys.c:1197`). Defaults and limits
(`erl_init.c`): one async thread (line 69); scheduler stack 128 kilowords,
dirty schedulers 40 kilowords (lines 71 to 73); dirty CPU schedulers default
to the scheduler count and dirty I/O schedulers to 10 (lines 865 to 867);
`+SDio` accepts 1 or more, never 0 (line 692 and lines 1085 to 1092). A node
therefore always runs at least one scheduler, one dirty CPU scheduler, one
dirty I/O scheduler, one aux thread, one poll thread, the signal dispatcher
and the main thread. On the host, `+S 1 +SDcpu 1 +SDio 1 +A 1` gave 9
threads ([measured](research-baselines.md#erts-node-baselines-host-otp-2842)).

**The forker is mandatory on Unix.** `erl_sys_late_init`
(`erts/emulator/sys/unix/sys_drivers.c:170-194`) always opens the `forker`
driver. `forker_start` (lines 1589 to 1695) reads `BINDIR` from the
environment and exits if it is missing (lines 1603 to 1612), creates an
`AF_UNIX` socket pair (line 1624), `fork`s (line 1634) and `execv`s
`$BINDIR/erl_child_setup` (line 1660). If `erl_child_setup` ever closes its
socket, the emulator exits: `forker_ready_input` calls `erts_exit` with
"erl_child_setup closed" (lines 1728 to 1741). No configure option or
emulator flag disables it; a search of `sys/unix/*.c`, `erl_init.c` and
`configure.ac` finds none. `erl_child_setup` exists so that
`open_port({spawn, ...})` and `os:cmd/1` can start OS processes. Every
other `fork` in the emulator is unrelated: `lib_src/pthread/ethread.c:159`
probes `lwsync` on PowerPC only.

**Signals.** `sys.c` installs handlers for `SIGINT` (break), `SIGQUIT`,
`SIGTERM` and `SIGUSR1` (lines 776 to 822) and ignores `SIGCHLD` and
`SIGPIPE`. Each handler only writes the signal number into a pipe
(`smp_sig_notify`, lines 1104 to 1120); the signal dispatcher thread reads
that pipe and turns signals into Erlang signals (`signal_dispatcher_thread_func`,
lines 1123 to 1180). Nothing else runs in signal context. The main thread,
after initialisation, blocks forever in `select(0, NULL, NULL, NULL, NULL)`
(lines 1229 to 1290, non-Darwin path). The only signal ERTS sends to its own
threads is the suspend signal (`SIGRTMIN+1`, `erts/emulator/beam/sys.h:920-928`)
through `sys_thr_suspend` (`sys.c:632-640`), used only while writing a
crash dump (`erl_crash_dump.c:584` and `:656`). Alternate signal stacks
(`sys_signal_stack.c:85-125`) exist only in the JIT build
(`BEAMASM && NATIVE_ERLANG_STACK`).

## The emulator's command line

`erl` is a script that runs `erlexec`, which builds the emulator's argument
vector and executes `beam.smp`. `erl -emu_args_exit` prints that vector and
exits. Measured on the host with Homebrew OTP 28.4.2 (erts-16.3.1) on
2026-10-29, for `erl -emu_args_exit -sname probe -noshell -mode embedded
-proto_dist inet_tcp -no_epmd -setcookie c +S 1 +SDcpu 1 +SDio 1 +sbwt
none`, one argument per line, joined here:

```text
-S 1 -SDcpu 1 -SDio 1 -sbwt none
-- -root <root> -bindir <root>/erts-16.3.1/bin -progname erl
-- -home <home>
-- -sname probe -noshell -mode embedded -proto_dist inet_tcp -no_epmd
   -setcookie c --
```

Emulator flags come first, rewritten from `+` to `-`; `erlexec` then adds
the installation paths and the home directory, each group closed by `--`,
and the arguments for `init` end with a final `--`. A host that starts
`beam.smp` directly writes the same vector.

## Kernel interfaces the emulator uses

**Futex.** ethread events on Linux use `syscall(__NR_futex, ...)` with
`FUTEX_WAIT_PRIVATE` and `FUTEX_WAKE_PRIVATE` and a relative timeout
(`erts/include/internal/pthread/ethr_event.h:39-60`,
`erts/lib_src/pthread/ethr_event.c:52-200`).

**Memory mapping.** On 64-bit systems with `MAP_FIXED` and `MAP_NORESERVE`,
ERTS defines `ERTS_HAVE_OS_PHYSICAL_MEMORY_RESERVATION`
(`erts/emulator/sys/common/erl_mmap.h:57-61`) and then:

* reserves address space with `mmap(PROT_NONE, MAP_PRIVATE|MAP_ANON|MAP_NORESERVE)`
  (`erl_mmap.c:1458-1497`);
* commits a range by mapping it again with `MAP_FIXED` and
  `PROT_READ|PROT_WRITE` (`os_reserve_physical`, lines 1466 to 1474);
* decommits by mapping it again with `MAP_FIXED|MAP_NORESERVE` and
  `PROT_NONE` (`os_unreserve_physical`, lines 1476 to 1483), exiting the VM if
  that fails;
* reserves a 1 GiB literal area this way at start-up
  (`ERTS_LITERAL_VIRTUAL_AREA_SIZE`, `erl_mmap.h:99`), so literal pointers
  need no tag bit (`erts/emulator/beam/erl_term.h:57-61`);
* grows single-block carriers with `mremap(MREMAP_MAYMOVE)` when available
  (`erl_mmap.c:1420-1444`), and treats a failed `mremap` as an allocation
  failure (`erts_mremap`, lines 1980 to 1994), so a host must implement it
  rather than refuse it.

**Polling.** With kernel poll (the Linux default), the poll set is epoll
(`erl_poll.h:161-172`), registrations use `EPOLLONESHOT`
(`erl_poll.c:773`), wake-ups go through a non-blocking pipe
(`create_wakeup_pipe`, lines 489 to 527), and sub-millisecond timeouts use a
`timerfd` (`create_timerfd` and `timerfd_set`, lines 539 to 581).
`--disable-kernel-poll` selects `poll(2)` instead (`configure.ac:199-205`).

**Time.** On Linux, `erts/emulator/sys/unix/sys_time.c` reads monotonic time
with `clock_gettime` (with `CLOCK_MONOTONIC_RAW` when present, lines 284 to
311), system time with `clock_gettime(CLOCK_REALTIME)`, and uses `times`
(line 74).

**Files.** `prim_file` on Unix (`erts/emulator/nifs/unix/unix_prim_file.c`)
uses `open`, `read`, `pread`, `pwrite`, `pwritev`, `write`, `lseek`, `fstat`,
`stat`, `lstat`, `access`, `readlink`, `opendir`/`readdir`, `mkdir`,
`rmdir`, `unlink`, `rename`, `link`, `symlink`, `chmod`, `chown`,
`ftruncate`, `fsync`, `fdatasync`, `fallocate` and `posix_fadvise`. Code is
loaded through `erl_prim_loader`, whose loader is `efile` (the local file
system through `prim_file`) or `inet` (a boot server on another node)
(`erts/preloaded/src/erl_prim_loader.erl:41-65`, `start_efile` at line
196).

**Paths probed.** The emulator opens Linux-specific files and tolerates
their absence: transparent-huge-page settings and `/proc/self/maps`
(`sys.c:160`, `:265`, `:301`), `/proc/self/cgroup` and
`/proc/self/mountinfo` for CPU quotas
(`erts/lib_src/common/erl_misc_utils.c:1080`, `:1132`), `/sys/devices/system/cpu`
and `/sys/devices/system/node` for topology (lines 115 and 116), `/dev/null`
when standard descriptors are closed (`sys.c:393-407`), and `/dev/zero` only
for a super carrier backed by a file (`erl_mmap.c:2261`). CPU counts come
from `sched_getaffinity` and `sysconf` (`erl_misc_utils.c:72`, `:298`,
`:303`).

**Dynamic loading.** `erl_unix_sys_ddll.c:97` calls `dlopen` on a
nonexistent library early to initialise the loader, and line 133 loads
drivers and NIFs. In a static musl binary `dlopen` fails cleanly, so only
NIFs and drivers linked in with `--enable-static-nifs` and
`--enable-static-drivers` are available (`HOWTO/INSTALL.md:406-416`, which
also requires `STATIC_ERLANG_NIF_LIBNAME` when compiling a static NIF).

**Randomness.** The emulator itself draws no operating-system randomness;
the only call is OpenSSL's `RAND_bytes` for encrypted crash dumps
(`erl_crash_dump.c:228`). musl uses `AT_RANDOM` for the stack protector
(`src/env/__libc_start_main.c:40`) and for mallocng's secret
(`src/malloc/mallocng/glue.h:48`).

**Operating-system name.** `os:type/0` reports the lower-cased `sysname`
from `uname` at run time (`os_flavor`, `sys.c:855-866`).

**Terminal.** `user_drv` uses the new shell only when standard input and
output are terminals (`lib/kernel/src/user_drv.erl:183-197`); `prim_tty`
then needs terminfo (`setupterm`, `tigetnum`, `tigetflag`) on any Unix
(`lib/kernel/src/prim_tty.erl:218-260` and `:333-346`); without it the shell
falls back to the old, line-buffered mode (`user_drv.erl:205-215`), which
relies on the terminal driver for echo and erasing. `prim_tty` also has an
**ssh mode** that needs neither a descriptor nor terminfo
(`prim_tty:init_ssh/3`, `prim_tty.erl:308-317`): the ssh daemon's
`ssh_cli` drives a full line-editing shell through it, starting the shell
with `group:start(self(), ShellSpawner, Options)` and exchanging
`{Driver, {data, Chars}}` and `{Group, Request}` messages
(`lib/ssh/src/ssh_cli.erl:73`, `:285-330`, `:407-423`, `:523-539`). Both
`prim_tty` and the group-to-driver protocol are internal to OTP.

## Build configuration

**C++ is needed only for the JIT and for an optional float formatter.** The
only C++ file outside the JIT, asmjit and wx is
`erts/emulator/sys/common/erl_float_short.cpp`, which is compiled only when
the built-in Ryu float formatter is disabled
(`erts/emulator/Makefile.in:1317-1319`); built-in Ryu is the default
(`erts/configure.ac:1300-1307`). The C++17 check runs only when the JIT is
enabled or built-in Ryu is disabled (lines 3112 to 3180), and with
`CXX=false` the JIT is disabled with a note and nothing else changes
(lines 3157 to 3179). The interpreter flavor (`emu`) links with `$(CC)`
(`Makefile.in:1356-1361`). An interpreter build with `CXX=false` is
therefore pure C. `configure.ac:98` still runs `AC_PROG_CXX`, which does not
fail without a C++ compiler.

**Cross-building needs a bootstrap system of the same release.**
`HOWTO/INSTALL-CROSS.md:116-176`: "a small Erlang bootstrap system has to be
built, or an Erlang/OTP system of the same release as the one being built
has to be provided in the `$PATH`", built with `./configure
--enable-bootstrap-only && make`; `make` verifies that the release matches
and fails otherwise. Homebrew's 28.4.2 cannot build 29.1.2.

## Distribution

**Carriers.** Since ERTS 10.0 a distribution controller may be a process
rather than a port, "so you perhaps do not even need a new driver"
(`erts/doc/guides/alt_dist.md:41-53`). A carrier module, named with the
suffix `_dist` and selected with `-proto_dist`, exports `listen/1,2`,
`address/0`, `accept/1`, `accept_connection/5`, `setup/5`, `close/1` and
`select/1` (lines 154 to 381); `dist_util` performs the handshake. The
examples `lib/kernel/examples/gen_tcp_dist` and `erl_uds_dist` implement
carriers entirely in Erlang with process controllers.

**Discovery.** `-no_epmd` stops `erl_distribution` from starting any EPMD
module (`lib/kernel/src/erl_distribution.erl:79-91`); a carrier can return
its own child specifications through `net_kernel:protocol_childspecs/0`
(same function, line 103). Alternatively `-epmd_module` names a module that
implements `start_link/0`, `names/1`, `register_node/3` and
`port_please/2` (`erts/doc/guides/alt_disco.md`).

**Trust.** `system/doc/design_principles/secure_coding.md`, "What is not
protected against" (lines 61 to 75): "All loaded code is assumed to be
trusted. There is no built-in sand-boxing mechanism for running untrusted
Erlang code ... a malicious BEAM module can do anything, including breaking
the memory safety protections of the runtime system and crashing the
virtual machine", and "All nodes connected through Erlang distribution are
assumed to be trusted, and have unrestricted access to all other connected
systems." Rule DEP-001 (lines 559 to 588): "Once a node is connected to the
cluster, it gains complete access to the resources and operations of all
other nodes."

**What a receiving node checks.** `erts_net_message`
(`erts/emulator/beam/dist.c`) rejects a control message whose sender pid
does not belong to the connection it arrived on, for links, unlinks,
monitors and exit signals (for example lines 2237, 2301 to 2302, 2358 and
2843), so a peer cannot impersonate a third node. It does not restrict which
local process a peer may address: `SEND` to any pid, `REG_SEND` to any
registered name, `EXIT2` to any pid (line 2809), `SPAWN_REQUEST` of any
function (line 2885) and `GROUP_LEADER` (line 2872) are all accepted from any
connected peer. Local pids are small sequential numbers, so a peer can name
processes it was never told about.

**Packet size.** Release builds fragment distribution messages into 64 KiB
pieces with an 18-byte fragment header (`erts/emulator/beam/dist.h:203-211`)
when `DFLAG_FRAGMENTS` is negotiated, which it is by default
(`DFLAG_DIST_DEFAULT`, lines 113 to 123). The atom cache
(`DFLAG_DIST_HDR_ATOM_CACHE`) is in the set a carrier may reject
(`DFLAG_DIST_REJECTABLE`, line 129 onwards).

**Decoding untrusted terms.** `binary_to_term/2` with `safe` "prevents
direct and indirect creation of new atoms (such as those embedded in certain
structures like process identifiers) and creation of new external function
references" and warns that it "does not guarantee that the data is safe for
your application" (`erts/preloaded/src/erlang.erl:1329-1345`). The decoder
`dec_term` (`erts/emulator/beam/external.c`, from line 4308) is iterative: it
threads unfinished terms through a `next` chain on the heap rather than
recursing, and yields by reduction count, so nesting depth cannot overflow
the C stack.

## musl's kernel interface on AArch64

* **System-call sites.** Every C-level system call goes through the inline
  `__syscall0` to `__syscall6` in `arch/aarch64/syscall_arch.h`, each a
  `svc 0`. Five assembly files issue `svc` directly:
  `src/thread/aarch64/clone.s` (thread creation, where the child resumes on
  a new stack), `src/thread/aarch64/syscall_cp.s` (cancellation points),
  `src/thread/aarch64/__unmapself.s` (a detached thread unmapping its own
  stack and exiting), `src/signal/aarch64/restore.s` (signal return) and
  `src/process/aarch64/vfork.s`.
* **Start-up order.** `__init_libc` (`src/env/__libc_start_main.c:21-56`)
  copies auxiliary-vector entries with tags below 38 into an array, then
  calls `__init_tls`, which may `mmap` the initial thread's TLS, and
  `__init_ssp`. A hook that redirects system calls must be installed between
  the auxiliary-vector scan and `__init_tls`, and must scan for its own tag
  because a private tag above 37 is not copied. Static PIE self-relocation
  in `ldso/dlstart.c` makes no system calls.
* **`AT_SYSINFO`.** `__init_libc` copies auxiliary-vector tag 32,
  `AT_SYSINFO`, into the internal variable `__sysinfo`
  (`src/env/__libc_start_main.c:31`, defined in
  `src/internal/defsysinfo.c`) on every architecture, before `__init_tls`;
  only the 32-bit x86 port uses it. Linux on AArch64 never sets the tag: its
  `ARCH_DLINFO` adds only `AT_SYSINFO_EHDR` and `AT_MINSIGSTKSZ` to the
  generic entries (Linux v6.12 `arch/arm64/include/asm/elf.h`). A host can
  therefore pass a value in `AT_SYSINFO` without patching musl's start-up
  code or adding a tag.
* **Threads.** `pthread_create` clones with `CLONE_VM | CLONE_FS |
  CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM | CLONE_SETTLS |
  CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID | CLONE_DETACHED`
  (`src/thread/pthread_create.c:243-245`); joining relies on the kernel
  clearing the child's TID word and waking it after the thread has left its
  stack. The first thread creation registers private expedited
  `membarrier` (line 260); `membarrier` itself falls back to signalling every
  thread when the system call fails (`src/linux/membarrier.c:24-55`).
  `setuid`-family calls and `setrlimit` use `__synccall`, which signals every
  thread.
* **Futex operations** used anywhere in `src`: `FUTEX_WAIT`, `FUTEX_WAKE`,
  `FUTEX_REQUEUE`, `FUTEX_CMP_REQUEUE`, `FUTEX_WAKE_OP`, `FUTEX_WAIT_BITSET`
  with `FUTEX_CLOCK_REALTIME`, and the priority-inheritance operations for
  priority-inheriting mutexes only, all with `FUTEX_PRIVATE` where possible.
* **`brk`** is used only by `sbrk`, the lite and old allocators; a refused
  `brk` costs nothing to the default allocator.
* **Signals sent to other threads.** Seven files issue `SYS_tkill` or
  `SYS_tgkill`: `src/exit/abort.c` and `src/signal/raise.c` (the calling
  thread), `src/thread/pthread_kill.c`, `src/thread/pthread_cancel.c` and
  `src/time/timer_delete.c` (no wait for delivery), and
  `src/thread/synccall.c` and `src/linux/membarrier.c`, which signal every
  other thread and wait on a semaphore until each handler has run. The
  `membarrier` fallback runs only when the system call fails for
  `MEMBARRIER_CMD_PRIVATE_EXPEDITED`, which only the dynamic linker issues
  (`ldso/dynlink.c:1686`).

## A minimal system-call surface for ERTS

Derived from the reading above: what a static, interpreter-flavor ERTS
linked with musl 1.2.6, with the forker removed, can reach on a node with no
network and no spawned ports. The substrate of `design-substrate.md` (since
superseded) was to count the calls each domain actually makes and report
any it does not implement, turning this derived list into a measured one on
the first boot.

| Area | Linux AArch64 system calls |
| --- | --- |
| threads and synchronisation | `clone` (thread flags only), `exit`, `exit_group`, `set_tid_address`, `set_robust_list`, `futex` (wait, wake, requeue, bitset), `sched_yield`, `sched_getaffinity`, `gettid`, `getpid`, `tkill`, `membarrier` (registration) |
| signals | `rt_sigaction`, `rt_sigprocmask`, `sigaltstack` (JIT only) |
| memory | `mmap`, `munmap`, `mprotect`, `madvise`, `mremap`, `brk` |
| time | `clock_gettime`, `clock_getres`, `clock_nanosleep`, `nanosleep`, `times`, `getrusage` |
| polling and pipes | `epoll_create1`, `epoll_ctl`, `epoll_pwait`, `timerfd_create`, `timerfd_settime`, `pipe2`, `pselect6` (the main thread's `select`), `ppoll` |
| descriptors | `read`, `write`, `readv`, `writev`, `pread64`, `pwrite64`, `preadv`, `pwritev`, `lseek`, `close`, `dup`, `dup3`, `fcntl`, `ioctl` (terminal and `FIONREAD`) |
| files | `openat`, `newfstatat`, `fstat`, `faccessat`, `readlinkat`, `getdents64`, `mkdirat`, `unlinkat`, `renameat`, `ftruncate`, `fsync`, `fdatasync`, `fallocate`, `fadvise64`, `getcwd`, `chdir`, `umask` |
| identity and limits | `uname`, `getuid`, `geteuid`, `getgid`, `getegid`, `getppid`, `prlimit64`, `prctl` (thread names), `sysinfo`, `getrandom` |

About 70 calls, none needing processes, signals delivered asynchronously,
or sockets.

## Corrections and additions

A second reading of the same sources on 2026-10-29, prompted by a review of
the design documents, corrects three statements above and adds three
findings. The earlier text stands as first written.

* **ERTS uses `ppoll` with descriptors.** With epoll as its poll set, ERTS
  also creates a poll-based fallback set with its own poll thread
  (`erts/emulator/sys/common/erl_check_io.c:2567-2578`), which the first
  auxiliary thread waits on with an infinite timeout
  (`erts/emulator/beam/erl_process.c:3258-3270`) through
  `ppoll(ps->poll_fds, ...)` (`erts/emulator/sys/common/erl_poll.c:1890-1895`).
  `ppoll` with descriptors is therefore part of the surface in
  [A minimal system-call surface for ERTS](#a-minimal-system-call-surface-for-erts),
  not only the main thread's descriptor-less `select`.
* **musl uses fewer futex operations than listed.** Beyond `FUTEX_WAIT` and
  `FUTEX_WAKE`, musl's C sources issue only `FUTEX_REQUEUE`
  (`src/thread/pthread_cond_timedwait.c:52-53`) and, for mutexes with the
  priority-inheritance protocol, `FUTEX_LOCK_PI` and its companions
  (`src/thread/pthread_mutex_timedlock.c:30`). `FUTEX_CMP_REQUEUE`,
  `FUTEX_WAKE_OP` and `FUTEX_WAIT_BITSET` appear in no C source under `src`.
* **The clear-on-exit address is the thread-list lock.** `pthread_create`
  passes `&__thread_list_lock`, not the new thread's identifier word, as the
  address the kernel clears and wakes when the thread exits
  (`src/thread/pthread_create.c:355`). A host that clears and wakes whatever
  address `clone` received serves both.
* **A positive `ERL_CRASH_DUMP_SECONDS` arms an alarm.** With a positive
  value ERTS calls `alarm()` while writing a crash dump; unset or negative
  means no alarm, and 0 means no dump
  (`erts/emulator/beam/erl_crash_dump.c:445-470`).
* **The distribution atom cache can make a packet large.** A message's
  first fragment may carry up to 255 new atom-cache entries
  (`ERTS_MAX_INTERNAL_ATOM_CACHE_ENTRIES`, `erts/emulator/beam/external.h:120`)
  of up to 1,020 bytes each (`MAX_ATOM_SZ_LIMIT`,
  `erts/emulator/beam/atom.h:31`) on top of the 64 KiB fragment; a carrier
  may reject the cache (`DFLAG_DIST_HDR_ATOM_CACHE` is rejectable,
  `erts/emulator/beam/dist.h:129`).
* **Job control lives in `user_drv`.** The `Ctrl-G` menu is `user_drv`'s
  `switch_loop` (`lib/kernel/src/user_drv.erl:478`, `:675`); a driver that
  uses `prim_tty` and `group` directly, as `ssh_cli` does, has none.

## Prior art

What earlier systems did when they hosted BEAM somewhere unusual, what OTP
and its community say about distribution between untrusted nodes, and the
kernel, capability and platform facts the erXos design builds on. Read
2026-10-29 from the sources listed at the end of this section; bracketed
keys refer to that list. Quotations are verbatim. **Unverified** marks a
claim no primary source confirmed.

### Systems that host BEAM

| System | Substrate | Runtime | Nodes and isolation | Status |
| --- | --- | --- | --- | --- |
| Kry10 KOS | seL4; every service a user-level component; BEAM on a C library with "partial POSIX syscalls" (musl and `libsel4muslcsys`), pthreads and LwIP inside its domain [K2] | BEAM, ARMv7 [K5] | several BEAM instances, each in its own protection domain, joined by Erlang distribution over a "KOS Distribution protocol carrier" on seL4 IPC and shared memory; a message server enforces the manifest's communication policy [K1][K2] | closed source; 1.0 for partners under NDA; "The runtime configuration of a KOS system is static"; no SMP [K1][K3] |
| Crazierl | own 32-bit x86 kernel in C; a FreeBSD system-call ABI of 64 calls in one `switch` (`kernel_src/kernel.c:2734-2824`) [C2] | the stock FreeBSD `erlang-runtime28` package with FreeBSD's dynamic loader [C3] | one node per machine; drivers and TCP/IP in Erlang over one NIF; "There is no security barrier between nodes in a dist cluster" [C4] | active [C1] |
| GRiSP | RTEMS 5 and 6, one address space | OTP with an RTEMS patch (1,635 lines for OTP 28), static NIFs only, Arm32 JIT patches [G1][G2] | one node per board | active [G1] |
| Tyn | Rust microkernel trapping about 50 Linux system calls | OTP 27, static musl, BEAM in ring 3 | two-node distribution | 2026 prototype [T1] |
| elixir_unikernel | Asterinas (Rust, Linux ABI) | static OTP 29.1.1 | one node | 2026 [E1] |
| Nanos | unikernel with a Linux ABI | OTP 23, six patches; epmd and `erl_child_setup` become threads | one node | inactive since 2022 [N1] |
| OSv, rumprun | unikernels | OTP 18 to 21; no `fork`, so no ports | one node | inactive [O1][R1] |
| Erlang on Xen (Ling) | Xen guest | its own VM, not ERTS | one node per guest; boot "in less than 100 milliseconds" (claim) | inactive since 2015 [L1] |
| HydrOS | multikernel, a "lightly modified BEAM" per core | modified BEAM | capability trees per process | inactive since 2018 [H1] |
| Nerves | Linux with `erlinit` as init | stock OTP | one node; A/B firmware updates with `fwup` | active [V1] |

Findings:

* **One BEAM per protection domain, joined by distribution over kernel IPC,
  is Kry10's design** (seL4 Summit, 2022-10-11). Its published material does
  not describe what isolates one BEAM from another once distribution
  connects them, which OTP itself says grants "complete access"
  ([Distribution](#distribution)). KOS is closed, ARMv7, uniprocessor and
  statically configured.
* **Every port of stock ERTS to a system without processes neutralises the
  forker**: GRiSP compiles it out with an `#ifdef` around the forker
  driver's registration in `erts/emulator/beam/io.c` [G2], Crazierl and Tyn
  fake `fork`, Nanos turns `erl_child_setup` into a thread, and OSv loads
  programs with `dlopen`. Every such port also replaces the external epmd:
  GRiSP adds an `-internal_epmd` option, Crazierl uses `-epmd_module` with a
  fixed port, Nanos runs epmd as a thread.
* **Most stock-ERTS hosts implement a Linux or FreeBSD system-call ABI in the
  kernel** (Crazierl, Tyn, Asterinas, Nanos). The library route is Kry10's
  and Unikraft's: Unikraft's lib-musl patch 0005 turns `__syscall` into
  direct calls into its system-call shim [U1], and seL4's musl sends every
  system call through `__sysinfo` (musllibc commit f81667c by Kent McLeod of
  Kry10, 2025-02-27) [S2]. seL4's `libsel4muslcsys` implements fewer than 30 calls,
  with no `clone`, `futex` or sockets [S1].
* **Unikraft has no Erlang port**: its maintainers said in 2021 that one
  "has not yet been done" [U2], and its library catalog has no Erlang or
  Elixir entry.

### Distribution between untrusted nodes

* **OTP.** "All nodes connected through Erlang distribution are assumed to be
  trusted" and "There is no built-in sand-boxing mechanism for running
  untrusted Erlang code" (Secure Coding, OTP 29.1.2) [D1]. The distribution
  protocol "is not by itself secure and does not aim to be so" [D2].
* **Filtering distribution.** Rickard Green of the OTP team, answering a
  prototype that filters distribution control messages per connection
  (2022-05-05): "No parts of OTP have been written to be prepared for
  communication using Erlang signaling with potentially hostile processes",
  and "I cannot see that we at OTP would ever have the resources for such a
  rewrite" [D3]. Filters exist regardless: WhatsApp's `erldist_filter`, a
  NIF that filters and logs distribution messages [D4], and
  `tcp_filter_dist`, a carrier with a per-message callback [D5]. Each decides
  message by message which control messages to let through.
* **The EEF Security Working Group**: "if one node in a cluster is
  compromised, all nodes are", and "Do not use Erlang distribution to connect
  layers in a multi-tier architecture" [D6].
* **SafeErlang** (Brown and Sahlin, ICICS 1999) proposed "unforgeable
  (capability) references with access rights", "a hierarchy of execution
  nodes to provide custom views of the resources available and to impose
  utilisation limits", and remote module loading [D7].

### Kernels and capabilities

* **Zircon.** Handle values are per-process integers, and "The kernel is free
  to re-use the integer values of closed handles", so they are not
  generation-safe. Rights only shrink (`zx_handle_duplicate`,
  `zx_handle_replace`). A channel message carries at most 65,536 bytes and
  64 handles, and a write "always consumes the handles" whether it succeeds
  or fails. Closing the last handle places the peer in `PEER_CLOSED` "before
  the zx_handle_close syscall returns", and the survivor can still drain its
  queue. Ports deliver one-shot asynchronous waits as packets. The system
  calls include no revocation [Z1].
* **seL4.** Revocation deletes the children in a capability derivation tree.
  MCS scheduling contexts bound a thread to a budget per period and can be
  donated to passive servers [S3][S4]. The SMP kernel "uses a big-lock
  approach, which makes sense for tightly-coupled cores that share an L2
  cache" [S5][S6]. The verified AArch64 kernel is "12,600 SLOC with
  hypervisor support" [S5].
* **Hubris.** A task's generation is part of its identifier and is checked on
  IPC; a mismatch returns a "dead code". The source uses 6 generation bits,
  which wrap (`sys/abi/src/lib.rs`, `INDEX_BITS = 10`), so a stale
  identifier can match again. A supervisor task restarts failed tasks, at
  most 20 times a second [B1].
* **MINIX 3.** The reincarnation server restarts failed drivers, and "a
  component's endpoint changes with each restart" so that "messages cannot be
  delivered to the wrong process during a failure" [M1].
* **QNX adaptive partitioning.** Partitions get a guaranteed minimum share of
  CPU over an averaging window of 100 ms by default, idle partitions' time is
  redistributed, and "we run server threads in the partition of their client
  thread while the server is working on behalf of that client" [Q1].
* **Capability theory.** "Only connectivity begets connectivity" (Miller,
  2006, section 9.2.5); revocation is a caretaker that forwards only while
  enabled, and a membrane wraps every capability that crosses it so that all
  revoke together (section 9.3) [P1]. CapTP and Cap'n Proto keep four
  tables per connection (questions, answers, imports, exports) to stretch
  references across machines, and break every import when the connection
  drops [P2][P3]. KeyKOS's meters account CPU time to principals [P4].
* **Singularity.** Processes communicate only through channels with exactly
  two endpoints and a contract, and a sealed process "prohibits dynamic code
  loading, self-modifying code, shared memory" [P5].
* **Barrelfish** "treats the machine as a network of independent cores" [P6].
* **Symbolics Genera.** Output on a window records "the underlying object,
  which is the object that was displayed" together with its presentation
  type, so displayed things stay live objects, and "The Inspector lets users
  see or manipulate any aspect of the current state of a complex data
  object" [P7].

### Architecture and platform

* **Linux arm64 boot protocol.** The image's 64-byte header carries the magic
  `0x644d5241`; the image sits `text_offset` bytes above a 2 MiB-aligned base;
  the device tree is 8-byte aligned, at most 2 MiB, with its physical address
  in `x0` and `x1` to `x3` zero; the MMU is off, interrupts are masked, and
  entry is at EL2 (recommended) or EL1 [A1].
* **PAN and unprivileged loads.** With `PSTATE.UAO` 0, `LDTR` and `STTR` at
  EL1 are checked against EL0 permissions, and PAN does not affect them; PAN
  faults privileged accesses to memory EL0 can access (Arm ARM DDI 0487 M.d,
  section C3.2.7 and the PAN pseudocode) [A2].
* **Timers.** The recommended PPIs are 27 for the EL1 virtual timer and 30
  for the non-secure physical timer (Arm BSA 1.2, Table 3) [A3];
  `CNTKCTL_EL1.EL0VCTEN` lets EL0 read `CNTVCT_EL0` [A2].
* **PSCI.** `CPU_ON` is function `0xC4000003` (SMC64), with the conduit, `smc`
  or `hvc`, given by the device tree's `/psci` `method` [A4].
* **SMMUv3.** It translates DMA only, for devices wired to it with a
  StreamID that firmware describes [A5]. QEMU `virt` with `iommu=smmuv3`
  places only the PCIe topology behind it; virtio-mmio and other platform
  devices are not translated [Q2].
* **QEMU `virt`.** A Linux image gets the device tree address in `x0`; an
  ELF image gets the device tree at the base of RAM only if the ELF leaves
  room below itself. The initrd goes at RAM base plus the smaller of half the
  RAM and 128 MiB, and the device tree after it, 2 MiB-aligned. A second
  non-secure PL011 exists only when a second `-serial` backend is given and
  TrustZone emulation is off; device addresses are not contractual and come
  from the device tree [Q2]. `icount` works only under single-threaded TCG,
  never with HVF [Q2]. HVF uses Apple's GICv3 for machine types from 11.1
  on, with no ITS (MSIs through GICv2m), and EL2 for guests needs an M3 or
  newer chip, according to an Apple engineer on qemu-devel rather than
  Apple's documentation [Q2][Q3].

### Sources

* [K1] Kry10, "Kry10 Technical Overview", undated (18 pp.),
  https://uploads-ssl.webflow.com/635675151c946163c2012450/66395a8a675c74f82097a749_kry10-technical-overview.pdf
* [K2] I. Kuz, "seL4 and BEAM: a match made in Erlang", seL4 Summit,
  2022-10-11, slides 9 to 17,
  https://sel4.systems/Foundation/Summit/2022/slides/d2_03_seL4_and_BEAM_a_match_made_in_Erlang_Ihor.pdf
* [K3] B. Multerer, "Kry10 Secure Platform", seL4 Summit, 2022-10-11,
  https://sel4.systems/Foundation/Summit/2022/slides/d2_01_Kry10_Secure_Platform_Boyd_Multerer.pdf
* [K4] Kry10, "KOS Release 2022.4", https://www.kry10.com/news/kos-release-2022-4
* [K5] K. McLeod and I. Kuz, "Freestanding Erlang: Porting BEAM close to the
  metal", Code BEAM talk page, 2026,
  https://codebeamamerica.com/talks/freestanding-erlang-porting-beam-close-to-the-metal/
* [C1] Crazierl, README at commit 922c1da (2026-03-19),
  https://github.com/russor/crazierl
* [C2] Crazierl, `kernel_src/kernel.c` at 922c1da.
* [C3] Crazierl, `Makefile` at 922c1da.
* [C4] Crazierl demo page, https://crazierl.org/demo/
* [G1] GRiSP platform tree at commit 9dfbeb5 (2026-10-28),
  https://github.com/grisp/grisp/tree/9dfbeb5b0317f0254fa4b95a50b9abb8471dacdd/grisp
* [G2] GRiSP, `grisp/default/28/build/patches/00100-rtems.patch` at 9dfbeb5.
* [T1] Tyn, Erlang Forums thread (2026-04-26) and repository
  `tyn-os/kernel` at 8353f67,
  https://erlangforums.com/t/tyn-a-rust-microkernel-that-runs-beam-on-bare-metal-no-linux/5577
* [E1] `bmalum/elixir_unikernel` at 480878f,
  https://github.com/bmalum/elixir_unikernel
* [N1] `nanovms/erlang` at fab8f74, https://github.com/nanovms/erlang
* [O1] `cloudius-systems/osv-apps`, `erlang/` at 0f91e79, and
  `OtoloNetworks/rebar3_osv`.
* [R1] `rumpkernel/rumprun-packages`, `erlang/` at ffbeedb.
* [L1] erlangonxen.org, Wayback snapshot 2013-12-30, and
  `cloudozer/ling` (last commit 2015-10-12).
* [H1] S. Williams, "How to Build an OS in Erlang: A Whistle-stop Tour of
  HydrOS", Erlang User Conference 2017; `attah/hydros`.
* [V1] `nerves-project/erlinit` v1.15.1 and `fwup-home/fwup` v1.17.1.
* [U1] `unikraft/lib-musl` patch 0005 at 5fed64e,
  https://github.com/unikraft/lib-musl
* [U2] Unikraft discussion 274 (2021-08-27),
  https://github.com/orgs/unikraft/discussions/274
* [S1] seL4 `libsel4muslcsys` at 262a34d,
  https://github.com/seL4/seL4_libs/tree/262a34dcb2f3285be01df9e5404d911132d567a6/libsel4muslcsys
* [S2] seL4 musllibc commit f81667c (2025-02-27),
  https://github.com/seL4/musllibc/commit/f81667cfc7329d5813a5b776231a561555796d79
* [S3] seL4 Reference Manual 16.0.0 (2026-07-22), sections 3.2 and 6.1,
  https://sel4.systems/Info/Docs/seL4-manual-latest.pdf
* [S4] A. Lyons, K. McLeod, H. Almatary, G. Heiser, "Scheduling-Context
  Capabilities", EuroSys 2018, doi:10.1145/3190508.3190539.
* [S5] seL4 FAQ, fetched 2026-10-29, https://sel4.systems/About/FAQ.html
* [S6] S. Peters, A. Danis, K. Elphinstone, G. Heiser, "For a Microkernel, a
  Big Lock Is Fine", APSys 2015, doi:10.1145/2797022.2797042.
* [D1] Erlang/OTP 29.1.2, "Secure Coding and Deployment Guidelines",
  https://www.erlang.org/doc/system/secure_coding.html
* [D2] ERTS, "Distribution Protocol",
  https://www.erlang.org/doc/apps/erts/erl_dist_protocol.html
* [D3] Erlang Forums, "RFC: Erlang Dist Security Filtering Prototype"
  (2022-01-31, reply 2022-05-05),
  https://erlangforums.com/t/rfc-erlang-dist-security-filtering-prototype/1002
* [D4] WhatsApp `erldist_filter` at e2b79ab,
  https://github.com/WhatsApp/erldist_filter
* [D5] `otp-interop/tcp_filter_dist`, https://github.com/otp-interop/tcp_filter_dist
* [D6] EEF Security WG, "Distribution Protocol and EPMD",
  https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/distribution
* [D7] L. Brown and D. Sahlin, "Extending Erlang for Safe Mobile Code
  Execution", ICICS 1999, LNCS 1726, pp. 39-53,
  doi:10.1007/978-3-540-47942-0_5.
* [Z1] Fuchsia documentation, pages dated 2025-02-28 to 2025-03-22: Handles,
  Rights, Channel, Objects (peered objects), `zx_channel_write`,
  `zx_channel_read`, `zx_handle_duplicate`, Port, `zx_object_wait_async`;
  and `zircon/vdso/handle.fidl` at 0d8ba96, https://fuchsia.dev/fuchsia-src/
* [B1] Hubris Reference (2026-10-27), sections 3.4, 7.2.1, 8.1.2 and 9.2,
  https://hubris.oxide.computer/reference/ ; source at c611e20,
  https://github.com/oxidecomputer/hubris
* [M1] J. Herder, H. Bos, B. Gras, P. Homburg, A. Tanenbaum, "Failure
  Resilience for Device Drivers", DSN 2007, doi:10.1109/DSN.2007.46.
* [Q1] QNX SDP 7.1, "Adaptive Partitioning" and the APS User's Guide,
  https://www.qnx.com/developers/docs/7.1/
* [P1] M. S. Miller, "Robust Composition", PhD dissertation, Johns Hopkins
  University, 2006, sections 9.2 and 9.3,
  http://www.erights.org/talks/thesis/markm-thesis.pdf
* [P2] CapTP, http://www.erights.org/elib/distrib/captp/index.html
* [P3] Cap'n Proto RPC protocol and `rpc.capnp` v1.5.0,
  https://capnproto.org/rpc.html
* [P4] A. Bomberger et al., "The KeyKOS Nanokernel Architecture", USENIX
  Workshop on Micro-kernels, 1992.
* [P5] G. Hunt and J. Larus, "Singularity: Rethinking the Software Stack",
  OSR 41(2), 2007; G. Hunt et al., "Sealing OS Processes to Improve
  Dependability and Safety", EuroSys 2007.
* [P6] A. Baumann et al., "The Multikernel", SOSP 2009,
  doi:10.1145/1629575.1629579.
* [P7] J. Walker, D. Moon, D. Weinreb, M. McMahon, "The Symbolics Genera
  Programming Environment", IEEE Software 4(6), 1987,
  doi:10.1109/MS.1987.232087; Symbolics, "Programming the User Interface",
  Genera 8 documentation.
* [A1] Linux, "Booting AArch64 Linux",
  https://docs.kernel.org/arch/arm64/booting.html
* [A2] Arm Architecture Reference Manual for A-profile, DDI 0487 M.d
  (2026-09-29), sections C3.2.7, D8.4.5 and D24.10.15.
* [A3] Arm Base System Architecture 1.2, DEN0094E (2025-07-11), Tables 3 and 4.
* [A4] Arm Power State Coordination Interface 1.3, DEN0022F.b (2024-10-07),
  section 5.1.4.
* [A5] Arm SMMU Architecture Specification v3, IHI 0070H.a (2026-03-09),
  chapters 2 and 3.
* [Q2] QEMU documentation 11.1.50, "Arm virt", "Record/replay" and "TCG
  instruction counting", https://www.qemu.org/docs/master/system/arm/virt.html ;
  QEMU source at 73294d0 (2026-10-28): `hw/arm/boot.c`, `hw/arm/virt.c`,
  `target/arm/hvf/hvf.c`, `system/vl.c`.
* [Q3] qemu-devel, "Re: HVF EL2 support" (2025-07-16),
  https://www.mail-archive.com/qemu-devel@nongnu.org/msg1127946.html

## Findings against the preliminary hypotheses

| Hypothesis | Finding |
| --- | --- |
| ERTS is POSIX-hosted and always multithreaded | holds: at least 7 threads (9 measured), pthreads, private futexes, reserve-then-commit `mmap` with a 1 GiB literal area, epoll with a wakeup pipe and `timerfd`, file I/O for code loading, `clock_gettime`, signal handlers that only write to a pipe, and `fork`/`execv` of `erl_child_setup` at boot, the one hard blocker, which needs a patch |
| ERTS cannot be the system scheduler, so the kernel schedules threads and ERTS schedules processes | holds: ERTS's schedulers are its own threads; no flag hands scheduling to the host |
| a domain maps naturally to an ERTS node, crossing domains is distribution, distribution assumes trust | holds, with the evidence quoted under "Trust" and "What a receiving node checks" |
| no verifier is needed if untrusted BEAM runs only in hardware-isolated domains | holds for cross-domain safety: OTP itself says malicious BEAM can break the VM, so isolation must come from the address space, not from checking bytecode; it does not hold inside one node |
| the POSIX substrate can live in user space with a patched musl system-call layer | feasible: musl has one inline system-call primitive and five assembly sites, and its start-up order leaves a safe point for the hook |
| the interpreter build avoids C++ | holds, with `CXX=false` and built-in Ryu |
| nothing close to an Erlang-native microkernel OS exists | does not hold: Kry10 KOS runs one BEAM per seL4 protection domain joined by distribution over kernel IPC (closed, ARMv7, uniprocessor, static configuration); none of the systems surveyed publishes a design that makes trust boundaries between such nodes explicit, creates nodes at run time, or carries kernel capabilities in Erlang messages ([Prior art](#prior-art)) |
