# Debugging

What a developer has today to find out why something fails, from the
outside in, and what is not built. [Tracing](tracing.md) covers following a
live system as it runs; this page is about reading what it left.

Each section says what is built and what is designed only. The designs are
[design-log.md](../design-log.md), [design-live.md](../design-live.md) (the
inspector, `/proc` and tracing), [design-fiasco.md](../design-fiasco.md)
(the kernel's own lines and its end) and
[design-debugger.md](../design-debugger.md) (reading a stopped kernel).

## The boot transcript and the console

* `tools/erx boot` puts the guest's serial console on your terminal, so the
  transcript is what scrolls by: Fiasco's banner, the root task's lines,
  the system domain's Erlang banner and the command shell's. Redirect it
  with your shell's own tools to keep it. Ctrl-A then C switches to QEMU's
  monitor and back.
* `tools/erx qemu` boots the Fiasco image from the build and prints the
  serial log's path when it ends. The harness writes a guest's serial log
  to `build/qemu/ACCEL-PID-RANDOM/serial.log` unless its caller names
  another directory.
* A command that `tools/erx` runs keeps its output and a record of its
  arguments and deadline in `build/logs/NAME-PID-RANDOM.log` and `.json`.
  `tools/erx status` lists commands recorded as running.
* On a Raspberry Pi 4 the serial adapter's log is the transcript; wiring,
  `screen -L`, and what to send with a bug report are in
  [Raspberry Pi 4](raspberry-pi-4.md#what-you-need) and
  [When something fails](raspberry-pi-4.md#when-something-fails).

The kernel log is also a file: `dmesg` in `rc` writes `/proc/kernel/log`,
the ring's lines from the oldest it still holds, each escaped, with
`[missing N]` where records were overwritten. The system log service
(`erx_syslog`) takes the ring every 100 ms, stamps and rate-limits every
domain's records and feeds the console. A log file under `/var/log` that
keeps them across a reboot is designed
([design-log.md](../design-log.md#the-file-tree)) and not built: the tree
has no `erx_logfs`.

## The shell, the inspector and `/proc`

Reach the machine with `ssh -p 2222 root@127.0.0.1` on a medium booted with
your key, or on the serial console, and you are in `rc`
([README](../../README.md#getting-started)). `ps` and `top` list processes,
`dmesg` the kernel log, `erl` starts an Erlang shell.

In that Erlang shell:

* `erx:i()` prints the machine: its CPUs, the system domain's group,
  budget and threads, and the processes, each value with the reporter
  that measured it.
* `erx:i(Path)` prints one record, for a path of `abi/inspection.txt`
  such as `[domains, 4, budget]`; `erx:i(Pid)` is `erx:i([processes,
  Pid])`. `erx:inspect(Path, Options)` returns the same record as data.
* `erx:source(Pid)` prints the source lines around a process's current
  location, or `erx:source({M, F, A})` around a function.

`/proc` is the same tree as files: each node is a directory whose `status`
file lists one attribute per line with its value and its reporter, and a
listing the inspector could not give whole has a `.partial` or `.unknown`
marker. `cat /proc/cpus/0/status` and `cat /proc/time/status` work from the
shell. The paths built are the ones `abi/inspection.txt` declares: the
machine, `cpus`, `groups`, `budgets`, `domains` (with each domain's
threads, modules and processes), `processes`, `apps`, `time`, `ntp` and
`kernel/log`.

A value that Fiasco cannot measure reads `[unsupported]`, `[partial]`,
`[unknown]` or `[timeout N]`, never a made-up number; the reporter says who
answered. A domain's group and budget, for example, read as unsupported for
every domain but the system domain. `tools/erx web --socket PATH`, with the
machine booted `--hostlink`, shows the same records in a browser.

Designed, not built: `/proc/kernel/crash`, the previous reset's crash
record ([design-system.md](../design-system.md#the-crash-record)); the
schema has no such path yet, and `dmesg -M` and `-N`, which would read a
crash dump's buffer, are refused as usage errors. The kernel's trace rows
are unsupported on Fiasco by design
([design-fiasco.md](../design-fiasco.md#the-trace-ring)).

## Erlang crash reports

In every domain but the system domain, `erx_report` filters OTP's crash and
logger reports: a report names the process, its registered name, the
error's class, the reason's leading atom and the stack's functions, and no
process state, message, dictionary or call argument. So a crash report from
a service domain tells you where, and the rest has to come from the
domain's own logging or from reproducing it in the system domain. A
module's `format_status/1` hides its terms from every `proc_lib`,
`gen_server` and `gen_statem` report. When a configured domain ends,
`dmesg` shows `erx_domain: configured domain NAME (domain N) ended,
REASON; restarting it`, and for a fault the program counter, cause and
address ([Raspberry Pi 4](raspberry-pi-4.md#when-something-fails)).

## Hosted mode, `lldb` and the sanitizers

A crash inside ERTS or the C library is slow to chase in QEMU. Hosted mode
builds the same runtime as a macOS process, where AddressSanitizer and
`lldb` work as on any Mac program. It builds only on macOS.

```sh
tools/erx build runtime
make check-runtime-hosted
```

The first command builds the hosted runtime into `build/runtime/hosted/`
(`make setup` already ran it once). The second builds it and runs its
integration tests, among them one that drives a terminal to the `1>` prompt.
No `tools/erx` command starts a hosted shell for you: the tests start
`build/runtime/hosted/otp/bin/aarch64-hosted-erxos/beam.emu` with the
release archive `build/runtime/hosted/release/system.pack` as its one
argument, on a terminal. Do the same by hand, or start it under `lldb`.
A test that passes only hosted is not a pass: QEMU is the authority
([book, C.7](../book/c-building.md#c7-hosted-mode)).

Hosted mode runs one runtime. Running domains and their connections as Mac
processes, so that `lldb` and the sanitizers see across domains, is
designed and waits for a consumer ([plan.md](../plan.md), track H).

The host C code of the kernel cores and parsers runs under the sanitizers
on the host with `make check-sanitizers`
([Testing](testing.md#the-slower-gates)).

## Deterministic mode

`erx.det=1` on the kernel command line runs one CPU under QEMU's TCG with
instruction counting, every domain on the interpreter, so two boots of one
image write the same transcript byte for byte
([design-fiasco.md](../design-fiasco.md#deterministic-mode)). The QEMU gate
uses it to compare transcripts. `tools/erx boot` has no flag for it.

## The kernel debugger

No kernel is built with Fiasco's own debugger, JDB, or with the kernel's
console input: the fork has neither, so a kernel trap or panic never waits
at a prompt. A kernel panic stops every CPU, prints `erx: kernel stop:`
with its reason, then the crash record that says where each CPU was, and
resets the machine, on QEMU and on a Pi 4 alike
([design-debugger.md](../design-debugger.md)). A kernel trap still prints
Fiasco's own trap state and takes Fiasco's panic path.

Designed, not built: `tools/erx debug` reads what the machine left:

* the crash record, from a console log;
* a memory image, which the harness takes of every failing QEMU run and
  reports on;
* a board that holds after its stop, when its command line carries
  `erx.hold=1`, over the console wire you already have;
* QEMU's stub or a recorded QEMU run, which add breakpoints, watchpoints
  and running backwards to the write that made a value.

Its views are the paths of `/proc`: `tools/erx debug FILE inspect
budgets/7` prints the record the running machine's `/proc/budgets/7` gave.

## What is not built

* **QEMU's GDB stub.** The harness (`tools/lib/erx/qemu*.rb`) does not pass
  `-s` or `-gdb`. Attaching to a guest's kernel is designed, as one target
  of `tools/erx debug` ([The kernel debugger](#the-kernel-debugger)); no
  design describes attaching a debugger to a native program. The one place the tree uses a stub is a research
  record about the SD host controller model
  ([research-sdhci-qemu-model.md](../research-sdhci-qemu-model.md)).
  `tools/erx boot --medium FILE --print` prints the plain QEMU command, to
  which you can add flags yourself.
* **A native debugger, core files and a remote Erlang debugger.** They
  are planned for 0.2, to be designed together with LVGL-in-app
  ([the item](../todo-apps.md#planned-features)).
  [design-programs.md](../design-programs.md) says erXos writes no core
  file, which that design has to settle.
* **JTAG.** The Pi 4's JTAG pins appear in
  [design-fiasco.md](../design-fiasco.md) and
  [design-header-io.md](../design-header-io.md) as a header assignment.
  A probe is designed as a target of `tools/erx debug` and is unverified
  on the board; no page describes a probe setup.
* **Logs that outlive a boot,** and `/proc/kernel/crash`, above.
