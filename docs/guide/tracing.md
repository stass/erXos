# Tracing

How to watch a running erXos: what the tracer shows today, what OTP's own
tracing does here, the kernel layer's trace, and how to measure. For
reading what a failure left behind, see [Debugging](debugging.md).

The design is the "Tracing" section of
[design-live.md](../design-live.md#tracing). Each section below says what
is built and what is designed only.

## `erx:trace/1`: one stream in the shell

In the Erlang shell (`erl` from `rc`, or the console's `1>` prompt):

```erlang
1> {ok, Ref} = erx:trace(#{select => [Pid]}).
2> erx:trace_stop(Ref).
```

`erx:trace/1` takes a map and prints one line per event in the shell until
`erx:trace_stop/1` ends it or the shell does:

* `select`: a list of at most 16 pids or domain ids to trace, with OTP's
  trace session and the flags `running` and `monotonic_timestamp`; a pid
  gives its `in` and `out` scheduling events.
* `kernel`: `true` adds the layer below ERTS, unfiltered by `select`.
  On Fiasco that is the `backend` row, the root service's ring of parks,
  wakes and interrupt deliveries, and one `unsupported` line for the
  `kernel` row, because Fiasco has no trace ring of the kind erXos's own
  kernel will have ([design-fiasco.md](../design-fiasco.md#the-trace-ring)).
* `frames`: accepted by the request check, so a typo in the map is refused
  at once, but `erlang/apps/erx/src/erx_trace.erl` opens only the `erts`
  session and the ring rows. Frame events are designed, not built.

It returns `{error, badarg}` for a map it does not understand, `{error,
scope}` for a selection the caller's facet does not cover (an unknown
domain id included) and `{error, no_facet}` without a trace facet.

A line is the time in seconds, the row, the event, `name=value` fields
and the reporter's label in brackets; text from a traced process is
escaped once, as the whole line. Design-live's example of a kernel and
runtime trace together:

```
   41.207119044 backend wake result=ok slot=2 cpu=unknown thread=4 space=1 [liberx trace]
   41.207131870 erts in pid=<0.91.0> domain=4 mfa=timer:sleep/1 [runtime]
```

The events of the rows are merged in time order. A slow receiver cannot
make the trace pile up: past a window of unacknowledged entries, entries
are dropped and reported as a `dropped` line with a count, and an event
that arrives after later ones went out is marked `late`, never lost.

The trace's tests are `test/erlang/erx_trace_tests.erl` and
`erx_tracer_tests.erl` on the host and the `native_trace` QEMU suite
(`tools/erx check-qemu --suite native_trace`), which checks the `kernel`
row's `unsupported` line, a backend park and wake of one slot, and a test
workload's `in` event.

Limits today:

* Only the system domain's processes can be traced. The trace scope is the
  constant `all` and the traceable domains are the system domain alone;
  a trace started in a session domain's own runtime claims scope `all` and
  counts that runtime's pids as the system domain's, which
  [todo-inspection.md](../todo-inspection.md) lists as a bug. Tracing a
  process in another domain through a relay in that domain is designed,
  not built.
* The shell has no `trace/1` shortcut; spell it `erx:trace/1`.

## OTP's own tracing

OTP's trace sessions, `erlang:trace/3` and `erlang:trace_pattern/3`, run
unchanged and trace the processes of their own runtime
([design-live.md](../design-live.md#tracing)). OTP's emulator test suites,
trace suites among them, run on erXos in the oracle gate and are compared
with stock OTP, so a difference is a recorded bug. One is recorded:
`trace_call_count_SUITE:combo` fails in its `dynamic_pre_post` group
([todo-runtime.md](../todo-runtime.md)). Whether `dbg` and the other tracing
tools of OTP's runtime tools application are in the image was not checked
for this page.

## What reaches a log, not a stream

The log service carries records and the kernel's ring, not a trace. See
[Debugging](debugging.md#the-boot-transcript-and-the-console). Development
builds also record every device register access in a per-domain trace
that is written to the crash area and read after a fault
([design-runtime.md](../design-runtime.md#the-device-access-trace)); its
cost is on the performance watch list
([todo-performance.md](../todo-performance.md)).

## The kernel's trace ring

erXos's own kernel keeps a ring of trace records per CPU: dispatches,
parks, wakes, preemptions, throttling, faults and interrupts
([design-kernel.md](../design-kernel.md#trace-ring)). It is designed with
the kernel and not built. On Fiasco the root service keeps one ring of
4,096 records in user mode, in the same record layout, which is the
`backend` row above, and the inspector's `[kernel, trace]` reads
unsupported. Fiasco's own kernel debugger is in
[Debugging](debugging.md#the-kernel-debugger).

## Designed, not built

* `tools/erx trace`, which would render the same events on the host from
  the host link's events stream with pids and domain names resolved.
* A trace relay in each traced domain, and frame events recorded by each
  runtime's funnel.
* Web views of a trace ([design-web.md](../design-web.md#views-on-the-line)).

## Benchmarks

`tools/erx bench WORKLOAD` measures and writes a report. The rule in
CLAUDE.md is that a change to the boot path, kernel entry, scheduler, IPC,
domain creation or cross-domain messaging comes with before and after
numbers from it, and a number written into a document names the host,
accelerator, QEMU version, compiler, flags, workload and baseline. TCG
numbers are never compared with HVF or native ones.

| Command | Measures |
| --- | --- |
| `tools/erx bench otp-pingpong`, `otp-ring`, `otp-spawn`, `otp-switch` `[--flavour emu\|jit] [--iterations N] [--samples N]` | stock OTP's message, spawn and switch costs on this host: the baseline, not erXos. Report path under `build/bench/`. `make bench FLAVOUR=jit` runs two of them. |
| `tools/erx bench boot --accel tcg\|hvf [--runs N] [--image PATH]` | boot time of the development image to the kernel banner, the root task, the system domain's Erlang banner and the shell; median and spread |
| `tools/erx bench g3 --accel tcg\|hvf` | the footprint at shell start and boot time to the shell, on erXos and on stock OTP, in one report |
| `tools/erx bench g5 --accel tcg\|hvf` | interpreter and BeamAsm domains on one workload under QEMU |
| `tools/erx bench bytes --accel hvf` | the network primitives of `erx_bytes` as the stack calls them, on erXos |
| `tools/erx bench web --accel hvf` | a record view's round trip over `tools/erx web`, unpaced and at a UART's rate |
| `tools/erx bench net-freebsd --host H [--runs N] [--only LIST]` | `erx_net` and lwIP on a FreeBSD x86-64 test host, one table; `H` is the host's ssh name, or the value of `ERX_NET_BENCH_HOST` |

A declared benchmark such as `nullcall` runs through `--systems`:
`tools/erx bench nullcall --systems erxos` boots erXos alone under HVF and
prints its rows, and naming more systems boots them side by side. Several
design documents name workloads the tool does not have yet, such as
`app-start` and `fs`; `tools/erx bench` refuses them as unknown, so a
document's mention of one is a plan. Costs suspected and not
yet measured are listed in [todo-performance.md](../todo-performance.md),
each with the measurement that settles it.
