# The live machine: shell, inspector, tracing and code from the host

The live machine is what a person sees of erXos: an Erlang shell on the
serial console from which the whole machine is reachable as terms; one
inspector that shows kernel objects, domains and the processes of every
domain through a single schema whose every value carries a status and
says who reported it; tracing of processes, of cross-domain frames and of
kernel events; hot code loading from the development host; and navigation
from any process to the line of source it is executing. It is the
Genera-like heart of the system, and it is ordinary Erlang code in the
system domain, apart from the host tool, which is Ruby. The architecture is
in [design.md](design.md); the system domain, the root task, in
[design-system.md](design-system.md); domains, connections, exports and facets,
which decide who may see and change what, in
[design-domains.md](design-domains.md); programs as ports of their
session in [design-programs.md](design-programs.md#a-program-is-a-port).

Decisions every reader of this document needs:

* **The console is a terminal driver, not a terminal.** `erx_console`
  drives OTP's `prim_tty` in its terminal-less mode and the shell's `group`
  process, as OTP's SSH daemon does, so line editing and history work with
  no terminal descriptor and no terminfo.
* **Untrusted text never drives a terminal.** A terminal has three
  writers, the kernel's early console, `erx_console` and the host tool's
  printer; each escapes every character it did not generate, and passes
  rendered output through an allowlist of exactly the control sequences
  its renderer emits. Data everywhere else stays exact. The rules come
  from one source, `abi/terminal.txt`, from which a generator produces
  each writer's tables, the kernel's an ASCII-only subset.
* **Release consoles log in.** A release build's console starts with a
  login, which the vault checks, and a session runs in its principal's
  own domain; the console's menu reaches only the sessions of the
  principal logged in at it; an Erlang shell in the system domain starts
  only for a holder of the system-shell facet, which development builds
  give to `root`.
* **One schema, honest statuses.** An inspection record covers a kernel
  object, a domain, a program or a process; every attribute carries a
  status (`ok`, `partial`, `unknown`, `unsupported`, `timeout`, `error`),
  and every value says who reported it: the kernel, a trusted service, or
  the runtime of the domain it describes. A compromised domain can lie
  about its own processes, and the record says so.
* **The pid space is the inspector's index.** Any process is
  `[processes, Pid]`, whatever domain it lives in. Its owner is its pid's
  creation, so the inspector routes every query and checks every scope by
  construction, never by asking a domain who owns what.
* **A program is shown under its session.** A native program is a port of
  its session's runtime and a sub-space of its session's domain; the
  inspector lists it under `[domains, Id, programs]` with its name, never
  as a domain, and `ps` in a session lists the session's process table.
* **The host link is a session with a capability table.** COBS frames with
  CRC-32C over the second serial port carry Erlang terms checked with the
  frame grammar. What the host may do is the set of facets its session
  holds, and the trees it may mount: everything in development builds,
  the configured set in release builds.
* **Files cross as 9P2000.L, both ways.** QEMU's virtio-9p mounts the
  development host's tree in the machine, and a 9P2000.L client on the
  host mounts an erXos tree through the host link's files stream, with
  9P's fids and tags as the handles, through one codec.
* **Code reaches the system domain only through the install facet.** Hot
  loading into the system domain needs it; development builds give it to
  the host link. Code for any other domain goes through that domain's code
  facet and harms nobody else if it is malformed.
* **Code is named by its hash.** Every module and native image is a blob
  named by the SHA-256 of its bytes, loaded only after its bytes match;
  manifests map names to hashes, and the host sends only the blobs the
  target lacks.
* **A command shell with rc's language, written in Erlang.** By the user's
  decision each session can run a shell that speaks Plan 9's rc, with
  emacs-style line editing and job control added; a command is a builtin, an
  Erlang command or a program in one namespace, a command acts only through
  the capabilities it was handed, and pipes between Erlang commands carry
  records whose values keep their statuses.
* **The machine is a file tree too.** `/proc` mirrors the inspector's
  paths as read-only files, through the reader's inspect facet, so `cat`,
  `ls` and `grep` read live state and gain nothing `erx:i/1` does not give.
* **Text is UTF-8, and terminals see it escaped visibly.** Each terminal
  writer's escaper renders controls, bidirectional overrides, invisible
  characters and invalid UTF-8 as visible tokens, from one table generated
  from Unicode's data.

## Context

The [architecture](design.md#signature-experiences) makes the interactive
environment part of the machine's identity. The commands `ps`, `inspect`,
`trace`, `source` and `domains` are functions of the shell and of the host
tool. The design joins them with an inspector schema whose every value
carries a status, a console built on `prim_tty` and `group`, a host link
with sessions and a request window, code overlays that survive restarts,
and source navigation.

The proposal this design follows asks that "the inspector combines
authoritative kernel domain/native-thread state with runtime-supplied
lightweight-process details, distinguishing trustworthy accounting from
untrusted reports". Three parties report: the kernel, about its objects
(spaces, threads, groups, budgets, memory, capabilities, IRQ objects); the
trusted services, about what they keep (the domain service's records of
domains, connections and death records, the device service's device table, the
code service's overlays); and each domain's runtime, about its own
processes, programs and exports, through the domain's agent.

Symbolics Genera is the model. Its output records kept "the underlying
object, which is the object that was displayed", so what a user saw stayed a
live object, and its Inspector let users "see or manipulate any aspect of
the current state of a complex data object"
([research](research-prior-art.md#genera)). In erXos the displayed objects
are processes, domains, programs, groups and budgets, and the paths that
name them are the same in the shell and on the host. Plan 9 is the model
for the rest: the command shell speaks rc's language, and `/proc` shows the
same paths as files, served like any other file tree of a domain's
namespace ([design-files.md](design-files.md)).

## Requirements

Functional:

1. A line-editing shell on the serial console in every configuration
   that runs the system domain, with history and a job-control menu: in
   development builds the system domain's Erlang shell, in release builds
   a login whose session runs in the principal's own domain.
2. One inspection interface for kernel objects (machine, CPUs, threads,
   groups, budgets, capabilities, mappings), domains with their connections and
   exports, a session's programs, and the processes of every domain, from
   the shell and from the host, leading from each process to its module's
   version and the source line it executes.
3. Tracing of process events through OTP's trace sessions, of
   cross-domain frames at each receiving runtime's funnel, and of kernel
   events through the kernel trace ring, shown in the shell and streamed
   to the host.
4. Hot code loading from the host and from the shell into the system
   domain (with the install facet) and into other domains (with their
   code facets); code loaded into a supervised domain survives that
   domain's restarts.
5. A host tool, `tools/erx`, with `console`, `load`, `watch`, `inspect`,
   `source`, `trace` and `files`.
6. The inspector's paths as a read-only file tree, `/proc`.
7. Code named, loaded and kept by its SHA-256 hash.
8. File access between the development host and the machine in both
   directions, as 9P2000.L mounts.

Non-functional:

* **Safety of the operator's terminal.** No byte from the target reaches the
  host terminal except through the generated filter; no character from a
  session reaches the serial console except through the escape.
* **Bounded parsing.** The host link's bytes are untrusted in every build:
  bounded frames, CRC, the frame grammar for payloads.
* **Latency budgets**, under HVF: an inspection of one process over the
  host link within 20 ms, and a hot load of a 100 KiB module within 1 s.
  The estimates in [Performance](#performance) put the emulated UART at
  the edge of both budgets; if measurement misses them, a virtio-console
  transport replaces the UART behind the same framing.
* **Determinism.** In deterministic mode the console transcript of a boot
  is byte-identical across runs.

Non-goals: a graphical interface (the schema can feed one); reapplying the
system domain's installs after a reboot, since its code changes only
through the install facet and durably only through a system update
([design-storage.md](design-storage.md#system-updates)); a POSIX shell; vi-style
line editing; remote access over a network, which belongs to a networking
design.

## Overview

```text
   host (macOS)                         target (QEMU virt)
 +------------------+    UART 0    +------------------------------------------+
 | terminal         |<============>| console's driver and the host link's     |
 +------------------+              |   driver (Erlang, over the device NIF)   |
                                   |        | bytes, as messages              |
 +------------------+    UART 1    |        v                                 |
 | tools/erx        |<============>|                                          |
 |  console, load,  |  COBS+CRC    | erx_console: login, the system shell     |
 |  watch, inspect, |  frames      |   for its facet, other sessions' sides   |
 |  source, trace,  |              | erx_hostlink -- session facet table      |
 |  files           |              |        |-- inspect facet -> erx_inspector|
 +------------------+              |        |-- code and install facets       |
                                   |        |      -> erx_code, hot stores    |
 +------------------+  virtio-9p   |        |-- trace facet  -> erx_tracer    |
 | QEMU 9P server   |<-------.     |        |-- console facet                 |
 | (a host dir)     |        |     |        `-- files stream: 9P bridge      |
 +------------------+        |     | erx_procfs: /proc per inspect facet      |
                             |     | erx_inspector: kernel objects, the       |
                             |     | services' records, domain agents         |
                             |     |         system domain (user mode)        |
                             |     +------------------------------------------+
                             |         ^ terminal requests     ^ facets, on
                             |         | and input, as frames  | the connection
                             |     +------------------------------------------+
                             |     | session domain: Erlang shell, command    |
                             |     | shell, terminal relay, command server,   |
                             |     | a handler per program, the export        |
                             |     +------------------------------------------+
                             |         | channels, pipes, data areas
                             |         v
                             |     +------------------------------------------+
                             |     | programs: sub-spaces of the session,     |
                             |     | ports of its runtime (toybox's applets)  |
                             |     +------------------------------------------+
                             `---- host-tree domain: virtio driver, 9P bridge,
                                   /host for the domains the manifest names
```

A person at the serial console of a development build types into the
system shell, a process of the system domain; in a release build, into
the shell of a session that runs in their own domain after a login, from
which the inspector is reached through the session's inspect facet. The
command shell runs in the session's domain beside its terminal relay and
command server, and serves the session's programs their `/bin`, `/tmp`
and other local files through the session's export; `erx_procfs` and
`erx_code`, with each principal's hot store, sit in the system domain
beside the inspector. `erx:i([processes, Pid])` asks `erx_inspector`, which
reads the pid's creation to find its domain, takes the domain's kernel
facts (its group's usage, its budget) with `erx_object_info`, and asks the
domain's agent about the process over the domain's connection; the record comes
back with each attribute's status and reporter, and the console escapes it
as it writes it. On the Mac, `erx inspect /processes/<7.85.0>` sends the
same query over the host link and renders the same record. `erx watch src
--domain 7` recompiles a changed module with the host's `erlc` and loads
it through domain 7's code facet; the code service also records it in the
domain's overlay, so the domain its specification starts next time starts
with it.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **V1.** No character from a session or a domain reaches a terminal unescaped, except the terminal-mode allowlist's sequences from the foreground job of the session in terminal mode | a terminal has three writers, each the only writer of its byte stream: `erx_console`, the only process that sends bytes to the console's driver, which escapes the characters of every request, `put_bytes` included, before `prim_tty` renders it, with the streaming escape of [Text on terminals](#text-on-terminals), passes rendered bytes through the allowlist of `prim_tty`'s own sequences, and in terminal mode passes only the sequences the terminal-mode parser accepts against its generated table ([Terminal mode](#terminal-mode)); the host tool, which escapes and filters everything it prints with the same generated tables; and the kernel's early console, which the kernel writes by polling only at boot and at a panic and on which it escapes every byte from outside the trusted base | a fourth writer; a request type whose characters skip the escape; a class of characters missing from the table; a print path in the host tool that bypasses the filter | tests that send every C0 and C1 control, every `Cf`, `Zl`, `Zp`, unassigned and default-ignorable character, invalid and overlong UTF-8, sequences split across requests, and every CSI, OSC, DCS, APC, PM and SOS form through each request type and each host command; a fuzz target per escaper; a test re-derives the allowlist from `prim_tty` and the classes from OTP's Unicode data and fails if `abi/terminal.txt` disagrees; the build check that only `erx_console` sends to the console's driver, with the check that the kernel writes its early console only at boot and at a panic, and the source check on the host tool's output calls, each with a seeded violation |
| **V2.** Inspection never fabricates | every attribute value is a tagged status and carries its reporter (`kernel`, `service` or `runtime`); renderers print the status and reporter of every value | a renderer that drops statuses, or an attribute filled with a default | one test per status and per reporter; a property test that every rendered record shows the same statuses as the record |
| **V3.** The host link's authority is exactly its session's facet table and the trees its configuration lists | calls name a facet by its number in the session table and nothing else; the table is created empty with the session, holds at most 1,024 entries (opening one more fails with `{error, system_limit}`), and dies with it; the files stream reaches only the grants of the listed trees, by `attach`'s tree name, and its fids end with the session | a request path that resolves names to processes; a table or a fid that survives its session; an `attach` that reaches a tree not listed | session replacement tests; a request naming a number of an ended session is refused; an `attach` of an unlisted tree fails with `enoent`, and a fid of a replaced session names nothing |
| **V4.** A call on the host link executes at most once per session | `erx_hostlink` keeps a window of the 64 highest call identifiers, each unseen, executing or answered, and never moves it past a call still executing: a call that would push one out is answered `{error, busy}` without executing; answered calls keep their replies while the kept replies total at most 1 MiB, and a reply that does not fit is not kept; a duplicate is answered from the window, or with `{error, reply_lost}` when its reply was not kept, and an identifier below the window is refused | a window that forgets executing calls | retry and expiry tests with a lost reply and a duplicate in flight; 64 calls executing when a 65th arrives, which gets `{error, busy}` and runs once when sent again |
| **V5.** Code enters the system domain only through the install facet | the system domain's runtime loads only installed storage: its release's files and the install arena, which only `erx_code:install_beam/2` writes and which refuses every caller but `erx_code`; `erx_code` takes modules only from install facets, which name them by hash, and checks each blob against its hash; a service that loads bytes it received gets `{error, not_installed}`; nothing reapplies installs after a reboot | a second writer of the install arena, `erx_code` accepting modules from something other than an install facet, or a path that reapplies stored installs | a test that `code:load_binary/3` with bytes from a request fails in the system domain; a test that a domain's code facet cannot load into the system domain; a test that `install_beam/2` refuses other callers; a test that a blob one bit off its hash is refused |
| **V6.** Only a holder of the system-shell facet types expressions into the system domain | the console starts an Erlang shell in the system domain only for a session that holds the facet; every other session's shell, the command shell's `erl` builtin and every Erlang command run in the session's own domain; release builds give the facet to the principals the system configuration names, by default none | a shell or an evaluator started in the system domain by another path; a release build's console that starts a system shell without a login | a test that a release build's console shows a login and that a session without the facet gets no system shell; a test that `erl` in the console's command shell evaluates in the session's domain |
| **V7.** A console reaches only the sessions of the principal logged in at it | `erx_console` records the principal that the principal service confirmed at the console's login, and its menu lists, connects to, interrupts and kills only the sessions the domain service records for that principal; locking or logging out detaches the console and clears the record, and only a login, which the vault checks, sets it again | a menu action or an attach that takes a session without checking its principal; a lock that leaves a session attached | a test that logs two principals in turn at one console and finds that each menu shows and reaches only its own sessions; a test that locks the console and finds every menu action refused, and the sessions running, until the same principal logs in again |
| **V8.** A program appears only under its session | a program has no domain id and no pid space of its own: it is a sub-space the session created and a port of the session's runtime, so the kernel's topology under `INSPECT` on the session's space and the session's agent are the only sources that know of it, and both place it under the session's path | a path for a program outside its session; a program with a domain id | an inspection test that starts a program and finds it under `[domains, Id, programs]` and nowhere under `[domains]` |

## Data model

### Inspection records

```erlang
-type record() :: #{schema := 1,
                    path := [segment()],
                    kind := atom(),          % machine, cpu, thread, group, domain, program, ...
                    id := term(),
                    attrs := #{atom() => attr()},
                    children := children()}.

-type attr() :: {reporter(), value()}.
-type reporter() :: kernel | service | runtime.
-type value() :: {ok, term()} | {partial, term()} | unknown | unsupported
               | {timeout, Milliseconds :: pos_integer()} | {error, term()}.

-type children() :: [segment()] | {partial, [segment()]} | unknown.

-type segment() :: atom() | integer() | binary() | pid().
```

`abi/inspection.txt`, included by the ABI root, declares the kinds, paths,
attribute keys, types, units, bounds, reporter categories and visibility
rules. Ruby generates bounded C builders, Erlang types and `erx_schema`,
Ruby bindings and validators, and shell/host/`/proc` projections from it
([design-generation.md](design-generation.md#inspection-and-diagnostics)).
The maps above describe that generated interface. Kinds, attribute keys
and statuses are atoms of `erx_schema`, loaded in the system domain and
in every domain's boot code.
Names that a domain reports about itself (registered names, module and
function names, program names) are binaries, so a record from any domain
decodes in the system domain whatever atoms that domain holds. The schema
number changes only when an attribute changes meaning or disappears;
adding attributes keeps it.

### Paths

| Path | Kind and attributes | Reporter |
| --- | --- | --- |
| `[]` | machine: build identifier, development flag, DMA profile, entropy quality, CPUs online, memory total and free, uptime, the boot value | kernel |
| `[cpus]`, `[cpus, N]` | CPU: running thread, idle time, ready threads per urgency, interrupts taken, throttled groups | kernel |
| `[groups]`, `[groups, Id]` | group: grant, capacity, usage, throttling, executors and their states, child groups; machine-wide, for scope `all` | kernel; the policy's intent, service |
| `[domains, Id, group]`, `[domains, Id, budget]` | the domain's group and budget, as above, within the facet's scope | kernel |
| `[domains]`, `[domains, Id]` | domain: name, principal, state and death record (service); budget limit and charge, group usage, threads (kernel); atom count, ETS tables, modules, process count (runtime) | each attribute marked |
| `[domains, Id, threads]`, `[..., capabilities]`, `[..., mappings]` | the domain's threads, capability table and mapping records, paginated | kernel |
| `[domains, Id, connections]`, `[domains, Id, connections, Peer]` | the domain's connections: the peer domain and each lane's size (service, from the domain service's records); each doorbell's trigger count (kernel, from the IRQ object); frames accepted and refused on each lane (runtime, from the domain's funnel) | each attribute marked |
| `[domains, Id, exports]` | the domain's export table: local pid or alias, peer domain and rights, paginated | runtime |
| `[domains, Id, programs]`, `[domains, Id, programs, N]` | for a session's domain, its programs, each a port of the session's runtime: name, owner pid, state, exit status, the fids its handler holds for it, its namespace, its failed write-backs of shared mappings (runtime, from the session's agent); its sub-space's state and charges and its group's usage (kernel, from `INSPECT` on the session's space and group tree); below it, `threads`, `capabilities` and `mappings` of the sub-space as the session's agent relays them from the capabilities it holds, marked runtime, or `unsupported` | each attribute marked |
| `[domains, Id, pipes]`, `[domains, Id, pipes, N]` | for a session's domain, its pipes: each end's holder, a program by its number or a process, each ring's size and the bytes its header reports, marked as reported by the ring ([design-pipes.md](design-pipes.md#failure-handling-diagnostics-and-debuggability)) | runtime, from the session's pipe server |
| `[domains, Id, processes]` | the domain's pids, paginated | runtime |
| `[domains, Id, crash]` | the domain's last crash dump, paginated; marked truncated when its header says so | service, from the crash area |
| `[domains, Id, modules]`, `[..., modules, Module]` | module: version (its blob's SHA-256), OTP's `md5`, source file, origin (boot image, overlay, loaded in the domain), whether its source is in the boot image | runtime |
| `[domains, Id, modules, Module, history]` | the last 16 hashes loaded for the module, newest first, with their times | service, from the code service |
| `[domains, Id, modules, Module, source]` | source text, paginated by lines | runtime, from the boot image |
| `[processes, Pid]` | process: domain (from the pid itself); state, priority, reductions, current function and location, heap and stack size, message queue length, registered name, group leader, `trap_exit`, links and monitors | the domain, by construction; the rest, runtime |
| `[processes, Pid, source]` | the source lines around the process's current location | runtime |
| `[devices]`, `[devices, Name]`, `[devices, Name, registers]` | device: the domain that holds it and its driver process, interrupt bindings, DMA profile (service, from the device service's table); registers read by the driver's domain through the device NIF at the device service's request and decoded field by field from the device's SVD description (runtime of the driver's domain); a register whose read has side effects is `unsupported` | each attribute marked |
| `[budgets]`, `[budgets, Id]` | budget: limit, charged, funded domain | kernel |
| `[kernel, trace]`, `[kernel, log]` | trace records and log lines | kernel |
| `[kernel, crash]` | the crash record of the machine's last end, read from the region that survives a warm reset where the platform keeps one, with its form: in a release build the brief form, the cause, program counter, fault address, build, uptime and time since the last pet, and nothing else; in a development build the full form, with the registers, the backtrace and the kernel's final lines ([design-kernel.md](design-kernel.md#the-root-task)); `unsupported` where it has none. Only a caller that holds the system-shell facet reaches it, whatever its inspect facet's scope; any other gets `{error, scope}`, and the console shows nothing of it before a login ([design-system.md](design-system.md#the-crash-record)) | kernel |

For a process of the system domain, the runtime is the system domain's
own, which is trusted; its attributes are still marked `runtime`, because
that is who reported them.

Generated builders and validators preserve every status and reporter.
A reporter tag does not authenticate a report; the inspector checks the
source and the caller's scope before collecting or exposing restricted
attributes. Every new field declares its visibility and public
projections, so adding it cannot silently expose it. Path dispatch and
formatting are generated; data collection and scope policy are handwritten.
All rendered names and values still pass through the sink's escaper.

### Host link frames

Each frame is encoded with consistent overhead byte stuffing (COBS) and
ends with a zero byte, so a receiver resynchronises at the next zero after
any damage. A decoded frame is:

```text
offset  size  field
0       1     version   = 2
1       1     stream    0 control, 1 terminal, 2 events, 3 credit, 4 files
2       2     reserved  = 0
4       16    session   opaque session identifier from hello; all zero before it
20      4     seq       frame number within the session and direction, from 0
24      4     target    control: facet number, 0 for the root; credit: bytes granted; else 0
28      n     body      at most 8,192 bytes
28+n    4     crc       CRC-32C of bytes 0 .. 28+n-1
```

Integers are little-endian. A files body is one whole 9P2000.L message
([Files between the host and the
machine](#files-between-the-host-and-the-machine)). A control body carries
a piece of a control message: a 16-byte header (`kind`: 1 call, 2 reply, 3
cast; `flags` bit 0 `MORE`; `total`, the length of the whole payload, the
same in every frame; `id`, the call identifier, nonzero for calls and
replies) followed by a piece of an external-term-format payload. A
receiver discards an encoded frame longer than 8,300 bytes, a frame whose
CRC fails, a frame with an unknown version or a stream its side does not
receive, and a frame of any session but the current one, and counts each;
it never answers malformed input. The one exception to the session rule is
a control frame of session 0, which carries the `hello` that opens a
session. `seq` grows by one per frame and the session ends before it
wraps; a receiver that sees a gap discards the message it was
reassembling, and the sender's retry sends it again. A message's `total`
may not exceed the session's limit, 16 MiB, or 8 KiB, one frame's body, in
a release build whose configuration lists no facet for the host, and must
fit what is left of the session's resident limit ([The host
link](#the-host-link)), which bounds reassembly before any byte is kept.

### Terminal filter rules

`abi/terminal.txt` is the one source of the terminal rules. It names the
Unicode general categories and properties whose characters are escaped, the
closed list of exceptions, the grammar of the escape tokens, and the control
sequences `prim_tty` emits in terminal-less mode, which form the allowlist,
and the **terminal-mode allowlist** of [Terminal mode](#terminal-mode). A
Ruby generator reads it together with the Unicode data OTP 29.1.2 carries
(`lib/stdlib/uc_spec/UnicodeData.txt` and `DerivedCoreProperties.txt`,
Unicode 17.0.0) and produces the Erlang tables of `erx_text`, the Ruby
tables of the host tool, and the kernel's ASCII-only class for its log
([design-kernel.md](design-kernel.md#console-log-and-panic)), so every
terminal writer filters from the same rules.

## Algorithms and behavior

### The console

`erx_console` is the system domain's console service. The console's
UART belongs to the system domain in every manifest, which names it by
its device-tree path in its `console` field; at boot the device service
refuses a manifest whose `console` path is not the UART that
`/chosen/stdout-path` names. Its driver, an Erlang process over the
device NIF, runs in the system domain beside `erx_console` and feeds it
directly ([design-system.md](design-system.md#drivers)): received bytes
arrive as messages, and the driver writes to the UART only what
`erx_console` sends it. `erx_console` is the console's one sink: every
byte it sends has passed its escaping, and a build check fails on any
other process that sends to the console's driver. The kernel keeps only
its early console, the same UART, at the address its platform build
fixes and checks against `stdout-path` at boot, which it writes by
polling at boot, before the driver starts, and at a panic, after the
system domain has stopped; so the two share the UART in time and never
write it together. After boot, kernel log records reach the console
only through `erx_console`, which reads them with `erx_log_read` and
renders them between shell lines
([design-kernel.md](design-kernel.md#console-log-and-panic)).

* **Rendering.** It creates terminal state with `prim_tty:init_ssh/3`
  (`lib/kernel/src/prim_tty.erl:308`), which needs neither a terminal
  descriptor nor terminfo, for an 80 by 24 terminal unless the operator sets
  another size with `erx:console_size/2` or the host tool reports one. Each
  request from a session's group passes through `erx_text:escape_request/1`,
  which escapes the characters it carries with the streaming escaper of
  [Text on terminals](#text-on-terminals) and bounds its numbers: lengths to
  64 KiB, and for a session in another domain, cursor movements to the
  session's own edit region, the rows its prompt and input occupy, so no
  session can move up and rewrite lines another source wrote. A request to
  clear the screen, which `edlin` sends for `Ctrl-L`, is rendered as
  newlines that scroll the screen. `prim_tty` turns the request into bytes;
  `erx_text:to_terminal/1` checks them against the allowlist; the result
  goes to the console's driver. The closed set of requests the console accepts
  is `prim_tty`'s, plus `{put_bytes, Bytes}`, with which a session's
  terminal relay hands over program output exactly as programs wrote it, for
  the console to escape ([Job control](design-shell.md#job-control)).
* **Input.** Bytes go to the current session's group as
  `{self(), {data, Chars}}`, the protocol `ssh_cli` uses
  (`lib/ssh/src/ssh_cli.erl:420`). `Ctrl-C` and `Ctrl-Z` pass through as
  data: the session's side turns `Ctrl-C` into an interrupt of its Erlang
  shell's evaluator, as `ssh_cli` turns it into `exit(Group, interrupt)`
  (`lib/ssh/src/ssh_cli.erl:409-411`), and the command shell's relay acts
  on both for its jobs.
* **Job control.** OTP keeps job control in `user_drv`'s `switch_loop`
  ([research](research-erts-host.md#corrections-and-additions)), which the
  console does not use, so `erx_console` implements it: `Ctrl-G` opens a
  menu that lists the sessions of the principal logged in at the console,
  in a development build `root`, and connects to, interrupts, starts or
  kills one (V7). The menu also locks the console and logs out:
  * **Lock** detaches the current session and shows the login prompt with
    the principal's name; the principal's sessions run on, and only a login
    as that principal reaches them again. Another principal may log in at
    a locked console, and its menu shows only its own sessions.
  * **Log out** ends every session the principal started at the console,
    as a hang-up ends a Unix login's jobs, and shows the login prompt.

  A session's programs stop and continue under the command shell's job
  control, which pauses and resumes their groups
  ([design-shell.md](design-shell.md#job-control)); the menu acts on whole
  sessions.
* **Logging in.** In a release build the console starts with a login
  prompt. It hands the principal's name and the passphrase, which it never
  echoes, stores or logs, to the principal service, which passes the
  passphrase to the vault. A principal that has not enrolled sets its
  first passphrase here, at the console only
  ([design-system.md](design-system.md#the-vault)). The vault opens
  one of the principal's credential slots with it and gives one of four
  answers: matched; did not match; limited, once a name, a principal's
  or not, has had 5 failures in 60 s from local terminals, the console
  and the host link, or 5 from network connections, or a terminal has had
  5; or unavailable, when the vault's partition or its sealing backend
  fails, or for an enrolment or a passphrase change on a trial boot,
  which the console reports as such
  ([design-system.md](design-system.md#the-vault)). On a match the
  domain service starts the principal's session domain
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas)),
  and the console drives that session's shell as a session in another
  domain; the host link's `console` facet logs in the same way. In a
  development build the console's first session is `root`'s, and its first
  prompt is the system shell's.
* **The system shell.** An Erlang shell whose group and evaluator run in
  the system domain (`group:start/3`, `lib/kernel/src/group.erl:120`)
  starts only for a session that holds the **system-shell facet**, which
  development builds give to `root`'s console session and release builds
  to the principals the system configuration names, by default none
  (V6). Expressions typed there run with the system domain's authority, so
  the facet is as strong as the install facet.
* **Shells in other domains.** `erx:attach(Domain)` asks the domain's
  console facet to start a group with the standard shell inside that
  domain, driving a driver process that `erx_console` serves for the new
  session. The shell, its evaluator and its line editing run in the target
  domain with that domain's authority; between the domains travel only
  terminal requests and input, as frames on the domain's connection to the
  system domain, and the console accepts only the closed set of requests
  above and renders them like its own. A user's login shell is such a
  session.
* **Logs.** Each domain's logger proxy formats its log events inside the
  domain, so the system domain never formats another domain's format
  string, and sends each to the domain's console facet as a log record,
  `{log, Level, Text}` with `Text` a binary of at most 4 KiB.
  The console accepts only that shape and at most 16 KiB of text per
  second per domain, the rate `erx_debug_log` allows a space, beyond which
  it drops and counts records. It renders each like a kernel log record,
  stamped with the time it arrived, with the line escape, under the domain's
  id and principal, which come from the lane the record arrived on and the
  domain service, and then the domain's name, escaped. A name is unique
  only within its principal, so no domain can pass for another by choosing
  one, and no domain chooses the time its lines show. A program's log
  lines are its session's: the handler receives them on the channel and
  the session's proxy sends them under the session's id, with the
  program's name in the text.

### Text on terminals

Text is UTF-8 wherever it flows: Erlang strings and binaries, text files,
the terminal and every protocol. A terminal has exactly three writers:
the kernel's early console, `erx_console`, and the host tool's printer.
Each escapes, at the moment it writes, every character it did not
generate itself, and nothing else escapes anything: data in files, in
pipes, in `/proc` and in records stays exact, so no list of renderers has
to remember an escape. Each writer renders the same classes visibly, from
the generated tables:

* a character of general category `Cc` (the C0 controls, DEL and the C1
  controls U+0080 to U+009F, among them U+009B, which some terminals take
  as CSI), `Cf` (format characters: the bidirectional overrides and
  isolates U+202A to U+202E and U+2066 to U+2069, the zero-width
  characters, U+FEFF and the rest), `Zl` or `Zp` (the line and paragraph
  separators), or `Cn` (unassigned in that version), or with the property
  `Default_Ignorable_Code_Point`, which adds invisible characters outside
  `Cf` such as U+115F, U+3164, U+034F and the variation selectors; except
  the four that legible text needs, U+200C and U+200D (zero-width
  non-joiner and joiner, for Persian and emoji sequences) and U+FE0E and
  U+FE0F (text and emoji presentation);
* a byte that does not begin or continue a valid, shortest UTF-8 sequence,
  an overlong form or an encoded surrogate included, and a surrogate code
  point in an Erlang character list.

A character is written as `<U+` and four to six upper-case hexadecimal
digits and `>`, such as `<U+202E>`; a byte as `<0x` and two such digits
and `>`, such as `<0xC0>`. Tokens are for the eye only: the data they
render keeps its bytes. Each escaper is streaming: it keeps the start of
a UTF-8 sequence that a request, a pipe read or a frame splits, at most
three bytes per stream, and writes it as bytes when the stream ends or the
next byte cannot continue it.

The **strict escape**, `erx_text:escape/1`, applies these and passes tab
and newline; the **line escape**, `erx_text:escape_line/1`, escapes
newline as well, so one record is one line under its source's name and no
domain can write a line that looks like another's. Log records and other
text attributed to a source render with the line escape. The allowlist of
`to_terminal/1` holds exactly the control sequences `prim_tty` emits in
this mode, less screen clearing, recorded by a test that renders every
request type and edge case. Anything outside it, such as screen clearing,
mode switches, mouse reporting, concealed text and every operating system
command, device control, application program command, privacy message and
start of string sequence, is written escaped. The host tool prints through
the same tables, generated as Ruby. The kernel log, which carries no
Unicode table, writes every byte outside printable ASCII and tab in text
it did not write as `\xNN`
([design-kernel.md](design-kernel.md#console-log-and-panic)). Each class
has a test at each writer, and each escaper has a fuzz target. Implicit
bidirectional reordering, by which strong right-to-left letters move the
neutral characters around them, is not escaped: a residual risk.

### Terminal mode

Full-screen programs, `vi` and `less` among them, draw with control
sequences, so a session's foreground job may put its console stream into
**terminal mode** ([design-programs.md](design-programs.md#the-second-tier)).
The session's terminal relay asks for it with `{terminal_mode, on | off}`
when the foreground job's terminal leaves or enters canonical mode, and
the console grants it only to the session it is connected to. In terminal
mode, `erx_console` still escapes every character of the job's output, as
in [Text on terminals](#text-on-terminals), except the control sequences
of the terminal-mode allowlist, which it passes:

* **The grammar.** A pure parser, `erx_text:term_mode/2`, reads ECMA-48
  control sequences, the introducer, at most 16 numeric parameters of at
  most five digits each, intermediate bytes and a final byte, bounded at
  64 bytes a sequence, streaming across writes like the escaper; it has a
  fuzz target.
* **What passes**, by the allowlist's generated table: cursor movement and
  addressing (`CUU`, `CUD`, `CUF`, `CUB`, `CUP`, `HVP`, `CHA`, `VPA`),
  erasing (`ED`, `EL`, `ECH`), inserting and deleting characters and lines
  (`ICH`, `DCH`, `IL`, `DL`), scrolling regions and scrolling (`DECSTBM`,
  `SU`, `SD`), graphic rendition (`SGR`) without concealed text, saving and
  restoring the cursor, the alternate screen (DEC private mode 1049), the
  cursor's visibility (25), and the application keypad and cursor keys,
  each with its parameters range-checked against the console's size.
* **What never passes**: every operating system command (window titles
  and OSC 52, which writes the operator's clipboard, among them), device
  control, application program command, privacy message and start of
  string sequence; every request that makes the terminal answer, such as
  device status and device attributes reports, whose answers would arrive
  as input; mouse reporting; and anything the table does not list. Each
  is written escaped, so a program draws wrongly rather than reaching the
  operator's terminal.

When the job leaves the foreground, ends, or turns terminal mode off, the
console first closes whatever sequence or UTF-8 character the job left
incomplete: the parser writes the bytes it holds escaped and returns to
its ground state, so nothing that follows is taken as the rest of the
job's sequence. It then writes the sequences that undo every mode the
allowlist can set (the main screen, a visible cursor, normal keypad and
cursor keys, the full scrolling region, default rendition), so no job
leaves the terminal in a state the next one inherits. The kernel's early
console and the host tool's printer have no terminal mode: the host tool
forwards a console stream in terminal mode through the same generated
table.

### The command shell

Each session can run a command shell with rc's language beside its
Erlang shell, in the same `Ctrl-G` menu; its language, commands, pipelines
of records, jobs and terminal relay are
[design-shell.md](design-shell.md). It renders through the console above,
and its Erlang commands reach the inspector, `/proc` and the code store
below with the session's facets. Its `ps` lists the session's own process
table: its Erlang processes and its programs, the latter from the
session's port table, so a session sees its programs without an inspect
facet, as a Unix user sees their own processes.

### Inspection

`erx_inspector` answers queries for paths, gathering each attribute from
its reporter:

* **Kernel attributes** come from `erx_object_info` on the capabilities
  the system domain holds as the root task: `INSPECT` on every domain's
  space, budget and group, and the root resource with `TRACE` for the
  trace ring ([design-system.md](design-system.md#authority)). `INSPECT`
  on a space enumerates the topology, state and charges of the spaces
  below it a page at a time, so a session's programs appear beneath its
  space with their charges, authoritative; it does not confer detailed
  authority over a sub-space's registers, capability table or mappings.
  Those the session's agent relays from the capabilities the session
  holds as the sub-space's creator, marked `runtime`, or reports
  `unsupported`; no space capability passes to the inspector
  ([design-system.md](design-system.md#sub-spaces)). Which sub-space is
  which program is the session's runtime's to say, since the port table is
  its own; the record carries the kernel's object id beside the runtime's
  name, so a lying session can misname a sub-space but not hide its
  charges.
* **Service attributes** come from the system services' own records: the
  domain service's (domains, their states and death records, the connections it
  created and their lanes), the device service's device table, and the
  code service's overlays and histories.
* **Runtime attributes** come from the domain's agent, a process each
  domain starts at boot, which runs `process_info/2` and friends inside the
  domain and answers with a frame on the domain's connection to the system
  domain, which the system domain's funnel validates before the inspector
  decodes it ([design-domains.md](design-domains.md#the-funnel)). A late
  answer becomes `{timeout, 500}` (500 ms by default), a domain that is
  booting `unknown`, an attribute the runtime cannot provide
  `unsupported`, a list cut at the page limit of 1,000 entries `partial`.

**Scopes.** Queries arrive through an inspect facet whose scope is `all` or
a list of domains. A path's owner is decided by construction: a process's
domain is its pid's creation, a program's is the session under whose path
it lies, and every other path names its domain or belongs to the machine.
A scoped facet reaches only the paths its domains own: listings contain
only those, `[]` shows only machine attributes that reveal nothing of
other domains (build identifier, development flag, DMA profile), and every
other machine-wide path (`[cpus, ...]`, `[groups, ...]`, `[budgets, ...]`,
`[devices, ...]`, `[kernel, ...]`) answers `{error, scope}`; a domain's own
group and budget are under its path. A path outside the scope
and a path that names nothing get the same answer, `{error, scope}`, so a
scoped facet cannot learn whether a process outside its scope exists.

**From a process to its source.** A process record carries its current
location, `{Module, Function, Arity, File, Line}`, and its module's
version. `[processes, Pid, source]` returns the lines of the module's
source around that line from the boot image when the module came from a
release that carries sources, and `unsupported` otherwise; every line is a
binary that renderers escape. The runtime finds the file by the base name
in the location, in the `src` or `include` directory beside the `ebin`
directory that `code:which/1` reports. `erx:source(Pid)` prints those lines
in the shell; `tools/erx source PID` reads the same file from the build
tree when the module's version matches the one the runtime reports, and
asks the target otherwise, so modules loaded from the host show their
source there even when no release carries it.

`erx:i(Path)` renders a record as a table in the shell; `tools/erx inspect`
renders the same record on the host. Both escape every string and show
every value's reporter.

### The /proc tree

`/proc` is the inspector's path namespace as a read-only file tree, served
by `erx_procfs`, an `erx_fs` server that the system domain starts for each
holder of an inspect facet, with that facet's scope
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)). A
domain mounts it at `/proc`, and a session's handler mounts it for a
program the session gives it to, so `cat`, `ls` and `grep` read live
state, and the tree grants nothing that `erx:i/1` with the same facet does
not. Each `erx_procfs` is linked to the facet it serves, so revoking the
facet ends the tree and every fid on it; like every file grant, the tree's
grant acts for the domain it was made for
([design-files.md](design-files.md#narrowing-for-a-program)), so a session
that gives it to a program shares the facet's view with that program
until the facet ends.

* **Paths.** Each inspector path is a directory whose `status` file holds
  its record, and whose subdirectories are the paths below it:
  `/proc/status` is the machine (`[]`), `/proc/domains/7/status` a domain,
  `/proc/domains/7/processes/` its pids, `/proc/domains/7/programs/3/status`
  a session's third program, and `/proc/processes/7.85.0/status` a
  process, its pid written without angle brackets so a shell needs no
  quoting. `/proc/processes/7.85.0/source` holds the source lines around
  the process's location, as `erx:source/1` prints them, and
  `/proc/domains/7/crash` the domain's last crash dump; the server fetches
  their pages from the inspector as reads reach them. `/proc/kernel/log`
  shows the kernel log's recent lines without consuming them, and
  `/proc/kernel/crash` the last reset's crash record, only in a tree
  served for a holder of the system-shell facet; the kernel's trace
  ring has no file, since only a tracer drains it ([Tracing](#tracing)).
* **Names.** A name a domain reports, such as a module's or a program's,
  becomes an entry name through one injective encoding, which the same
  server decodes: every byte outside `A` to `Z`, `a` to `z`, `0` to `9`
  and `_+,:=@-`, and a leading `.`, is written as `%` and two upper-case
  hexadecimal digits, so no entry is `.` or `..` or holds `/`, and no
  encoded name starts with `.`. Names that start with `.` are the tree's
  own markers: `.partial` and `.unknown` below. The device service's
  `/dev` names its devices by the same encoding
  ([design-system.md](design-system.md#devices)).
* **Content.** A `status` file has one line per attribute: its name, its
  value and its reporter, separated by tabs. A value prints through
  `erx_render`, as in records ([Pipelines](design-shell.md#pipelines)): an
  `ok` value bare and every other value as its status, `[unknown]`,
  `[partial]`, `[unsupported]`, `[timeout 500]` or `[error]`, so a file
  never fabricates (V2). Tabs, newlines and backslashes in a value are
  written as `\t`, `\n` and `\\`, so each line is one attribute; every
  other byte stays exact, and a terminal's writer escapes it when it is
  shown.
* **Snapshots.** Opening a file runs one inspector query, whose deadline
  is the inspector's own (500 ms by default), and reads see that snapshot
  until the file is closed; a record is at most 64 KiB, and a larger one is
  cut, with `[partial]` as its last line. A grant holds at most 256 open
  snapshots, so one reader makes its tree hold at most 16 MiB, within the
  grant process's heap limit, and a 257th open fails with `emfile`
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)). A
  directory lists at most 1,000 entries, the inspector's page; a longer
  listing ends with an entry named `.partial`, whose file says how many
  entries were left out, and a directory whose listing the inspector
  could not get holds only `.unknown`, whose file gives the status.
* **What a runtime reports.** The pids a domain's agent lists for its
  domain whose creation is another domain's are dropped, so a lying
  runtime can describe only its own processes.
* **Scope.** A path outside the facet's scope answers `enoent`, as a path
  that names nothing does. The inspector decides scope from the path
  alone, before it looks anything up, so the answer never depends on
  whether something outside the scope exists.

The same paths serve the host: `erx inspect /processes/7.85.0` renders the
record that `cat /proc/processes/7.85.0/status` shows.

### Tracing

The ABI event declarations generate typed emitters, bounded readers and
C/Erlang/Ruby field/unit tables for logs and traces. Release/development
projections explicitly select permitted fields; the schema does not make
a runtime report trusted or let a decoder bypass the output escaper
([design-generation.md](design-generation.md#inspection-and-diagnostics)).

* **Processes.** OTP's trace sessions run unchanged in every runtime and
  trace that runtime's own processes. A trace facet starts a **trace
  relay** in the traced domain, a process of that domain's agent that is
  the tracer OTP sees; the relay renders each trace message into a record
  of binaries and plain terms inside the domain and sends the records, in
  batches of at most 64 KiB, to the tracer's pid in the system domain,
  which the facet placed in the request and so exported to the domain
  ([design-domains.md](design-domains.md#exports)). The system domain's
  funnel admits the records because their grammar creates no atom (D5);
  a trace message's atoms are rendered where they live.
* **Frames.** Every runtime's funnel is the one place that sees each frame
  arriving on the domain's lanes, so frame tracing is the receiver's: when
  a domain is traced, its runtime records each frame its funnel accepts or
  refuses on any lane, as `{frame, Peer, To, Operation, Bytes, Outcome}`
  with the time, into its own ERTS trace with the same timestamps as its
  process events, and the trace relay streams them like any other record.
  The outcome is the receiver's own (accepted, refused as malformed, or
  refused as unauthorised), and the peer is the lane's domain, never a
  field of the frame. Frames into the system domain are recorded by the
  system domain's own funnel, which is trusted; frames into any other
  domain are that domain's report, marked `runtime`. A frame a domain sent
  is seen in the trace of its receiver, so tracing a conversation traces
  both ends.
* **Kernel events.** The kernel trace ring records dispatches, parks and
  wakes, preemptions and yield requests, throttling, faults, domain-level
  events, doorbell triggers and interrupts
  ([design-kernel.md](design-kernel.md#trace-ring)); `erx_tracer` drains
  it with `erx_trace_read`. The runtime adapter's own events (parks, wakes,
  capacity changes, refusals) go into ERTS's trace with the same timestamps
  ([design-runtime.md](design-runtime.md#failure-handling-diagnostics-and-debuggability)).
* **One timeline.** `erx:trace(Spec)` starts any mix of the three and
  prints one stream ordered by monotonic time; the trace facet streams the
  same events to the host as casts on the host link's events stream, where
  `tools/erx trace` renders them with pids and domain names resolved. The
  merger holds each event until every source has shown a later time, a
  source with nothing new counting the time of its last read, or until the
  event is 100 ms old, whichever comes first, so a source that stops
  answering delays the stream by at most 100 ms and holds at most 100 ms
  of the others' events; an event that arrives after later ones went out
  is printed at once, marked `late`, never dropped.
* **Scope.** A trace facet has a scope, as an inspect facet does. A scoped
  trace facet traces only the processes and programs of its domains,
  through each domain's own runtime, and only the frames those domains
  receive; the kernel trace ring needs a trace facet of scope `all`.

### Code from the host

Command modules also publish a generated catalog binding to their loaded
blob hash, metadata and local entry fun. Their code server makes affected
entries unavailable during replacement; after a partial or unknown load,
it reconciles them against the code actually loaded before another command
can start. The published restart overlay is a separate fact. This follows
the version-binding contract in
[design-generation.md](design-generation.md#configuration-and-command-catalogs)
and does not add application-state rollback.

* **Into the system domain.** The install facet hands the modules to
  `erx_code`, the system domain's code service, which checks each module's
  hash and name against its payload, copies the modules into the install
  arena with `erx_code:install_beam/2`, and activates them as one batch
  with `code:atomic_load/1`, so either every module of the batch is
  current or none is. A failed check changes nothing; a failed atomic
  load keeps the old code and reports which module failed. The overlay
  lives in the install arena until the machine ends; after a reboot the
  system domain runs its booted release and the host installs again,
  sending only the blobs the store lacks. Only the release slice and the
  install arena supply code to that runtime (V5). Development builds give
  the install facet to the host link and `root`'s session; release builds
  give it to the configured principals.
* **Into another domain.** A domain's code facet, held by its owner and, in
  development builds, by the host, sends the modules to the domain's code
  server, which loads them in that domain's runtime. A module travels in
  pieces of at most 64 KiB that the code server asks for one at a time,
  so a module of any size fits every frame, every heap limit and the
  domain's lane from the system domain, and the code service queues at
  most one piece per request. Module names travel as binaries and become
  atoms only in the domain that loads them. A malformed module fails or
  crashes only that domain.
* **Overlays.** A **supervised** domain is one the domain service starts
  again from the same specification when it ends, as a supervisor restarts
  a child (`restart => permanent | transient` in its spec); a specification
  has at most one live domain at a time. The code service keeps one
  overlay per supervised specification: the manifest of the modules loaded
  into its domain from outside since the specification was started, with
  the hash of the manifest of the release it was loaded over
  ([The code store](#the-code-store)).
  * A load has three steps, each with one actor: the code service writes
    a candidate overlay; the domain's code server loads every module of it
    and answers; the code service publishes the candidate, with a new
    revision, only if every module loaded, and otherwise discards it, and a
    domain that loaded part of it keeps that code until it next restarts.
  * A domain started from the specification loads the published overlay
    before its release's applications start, and reports the revision it
    loaded, so no restart runs without published code. An overlay whose
    release hash differs from the release the domain boots is dropped
    instead: after a system update, old modules never run over the new
    release, trial boots included.
  * An overlay persists where its principal's data does: in the
    principal's own directory on the data partition, applied only to that
    principal's specifications. A specification of the system
    configuration, such as the vault's or a storage domain's, keeps its
    overlay in memory only, so its code changes durably only by a system
    update, as the system domain's does. With no writable data partition
    mounted, read-only, absent, or during a trial, every overlay lives in
    memory only, and a reboot drops it.
  * An overlay's blobs are at most the specification's `overlay` limit
    (16 MiB by default), held in its principal's hot store, so a principal
    pays for its own overlays and they outlive the domains that run them.
* **`erx watch DIR --domain ID`** recompiles each changed source with the
  host's `erlc` and loads the result; `erx load FILE.beam ... --domain ID`
  loads files as they are.

### The code store

Every compiled artifact, a BEAM module or a native image, is a **blob**
named by the SHA-256 of its bytes, and a module's version is its blob's
hash. A **manifest** maps names to hashes: the boot image's index is one,
each release has one, a system update's slot carries its boot image's and
its EROFS images' manifests, and an overlay is one.

* **Stores.** Read-only blobs live in the boot image and in EROFS images,
  under their manifests. A blob in the boot image is mapped by every
  domain that loads it from the same pages; a blob in an EROFS image is
  read and hash-checked by each domain that loads it, in its own memory
  ([design-storage.md](design-storage.md#reading-erofs-images)).
  Hot-loaded blobs live in each principal's **hot store**, which only the
  code service writes: a memory object the domain service creates from
  that principal's budget through the domain library, on the code
  service's request ([design-system.md](design-system.md#the-domain-library)),
  and, where a data partition is mounted, a directory of the principal's
  own on it, one file per blob, named by its hash. A store is
  deduplicated only within itself and against its principal's own
  releases, so it never tells one principal what another loaded, and
  every blob is charged to the one principal that stored it. A hot blob
  is copied into each domain that loads it, charged to that domain.
* **Loading** names a hash: a domain's code server fetches the blob from
  its release slice when the slice's manifest lists the hash, and from the
  code service otherwise, and checks the bytes against the hash before
  ERTS's loader reads them
  ([design-runtime.md](design-runtime.md#code-in-the-system-domain)). A
  hash gives integrity and identity, not trust: a blob a user supplied
  stays untrusted input to the loader, which fails or crashes only the
  domain that loads it.
* **History and rollback.** The code service keeps, with each overlay, the
  last 16 hashes loaded for each module and the time of each, so the
  history survives the domain's restarts, and it frees a blob that no
  history, overlay or release of its principal names.
  `erx_code:history/2` and the inspector's
  `[domains, Id, modules, Module, history]` show them, through the
  caller's inspect facet, and a rollback is a load of an older hash whose
  blob the principal's store still holds.
* **Sending only what is missing.** `erx watch` and `erx load` compute
  each module's hash on the host, ask the code service which hashes the
  principal's store lacks, send only those blobs, in the pieces above, and
  then load the manifest.
* **The system domain** loads code only through the install facet (V5),
  which names hashes; blobs come from any store and are checked by hash,
  so a store can fail an install but never change what is installed. An
  install lasts until the machine ends: after a reboot the host installs
  again, and sends only the blobs the store lacks.

The overlays and stores read back from the data partition are untrusted
input: the code service decodes them with a bounded grammar, which has a
fuzz target, and checks every blob against its hash before it serves it.
A persisted overlay is still only as trustworthy as the data partition: a
file-system domain that a crafted partition compromises can rewrite the
overlays and stores of every principal whose directory it serves, with
blobs that match their hashes, and so run code in those principals'
supervised domains at their next start, as anyone who can write a user's
files can on Unix. No specification of the system manifest is
exposed to it, since their overlays are never persisted, and the system
domain's installs are never persisted at all.

### The host link

The host link connects `tools/erx` to `erx_hostlink` over the second UART,
which belongs to the system domain on every platform and is served there
by a driver like the console's, beside `erx_hostlink`; the system
manifest names the UART by its device-tree path; under QEMU it is a Unix
socket
(`-serial unix:build/hostlink.sock,server=on,wait=off` after the console's
`-serial`).

The transport has one trusted physical or local peer. The harness creates
its Unix socket in an owner-only directory with access restricted to that
host user; a board installation controls physical access to its UART.
CRC detects corruption and session identifiers reject stale traffic;
neither authenticates an active attacker that can read or inject the link.
An unauthenticated network bridge is outside this transport contract and
is refused by release configuration. Remote use needs an authenticated
channel that binds the peer to the host-link session, such as the system's
SSH service; it does not reuse CRC as a MAC or add a custom cipher.

* **Flow control.** The host link's driver buffers at most 64 KiB of
  received bytes and drops beyond that, counting the loss
  ([design-system.md](design-system.md#drivers)), so the tool
  sends only within credit: 16 KiB at the start of a session, renewed by
  credit frames from `erx_hostlink` as it consumes input.
* **Streams.** The control stream carries calls, replies and casts; the
  terminal stream carries raw input for a console session and its rendered,
  filtered output; the events stream carries log lines and trace records;
  the files stream carries 9P2000.L messages
  ([Files between the host and the machine](#files-between-the-host-and-the-machine)).
  A crash dump is read as an inspection path, `[domains, Id, crash]` or
  `[kernel, crash]`, and the tool stores it as a file and never renders it
  raw.
* **Sessions.** The tool opens a session with `{hello, Nonce}` in frames
  whose session is all zero, with `Nonce` a fresh 16-byte binary from the
  host's random source. The target replies with that nonce, an independently
  generated nonzero 128-bit session identifier, its build identifier and
  format versions. The tool matches the nonce and refuses another build;
  the target closes the preceding session and its facets. Identifiers are
  opaque bytes, not authority or authentication. With good independent
  entropy, an old identifier matches one new session with probability
  2^-128; over many sessions the collision bound grows with the number of
  pairs. Weak or fixed entropy permits repetitions and is accepted only in
  trusted development modes. The tool never treats freshness as proof of
  who sent a frame. Both frame and call counters end a session before
  exhaustion instead of wrapping.
* **Calls.** Call identifiers grow within a session. A call whose
  identifier is in the window and unseen executes; one still executing is
  ignored; one answered gets its kept reply again; one below the window is
  refused with `{error, expired}`. One above the window that would move it
  past a call still executing is answered `{error, busy}`, neither
  executed nor seen, and the window stays where it is, so no executing
  call loses its place; the tool keeps at most 64 calls outstanding and
  sends such a call again once an earlier one is answered. A machine reset
  ends every session; the outcome of calls whose replies never arrived is
  then unknown, and the tool says so.
* **Facets without pids.** A serial line carries no pids, so `erx_hostlink`
  keeps the session's facets in a table and shows them to the host as
  numbers; a reply that contains a facet returns `{'$host_cap', N}`, and a
  call names its target facet in the frame's `target` field. This table is
  the one place in erXos that needs CapTP's import table, because it is the
  one place where authority crosses a wire with no lane and no funnel at
  the far end. The root (target 0) offers `{open, Name}` for the facets the
  host may open: in development builds `inspect` and `trace` (scope `all`),
  `install`, `update` (the update service's facet, for updates the host
  tool signs with the build's development key), `code` and `domain` for
  every domain, named by its domain id, which is never reused, where a
  name, unique among live domains machine-wide, passes to a later domain
  once its holder ends, and `console`; in release builds what the system
  manifest lists, by default nothing, and `console` there starts a login,
  as the serial console does. A `domain` facet carries
  `erx_domain`'s operations on one domain: stop it, and read its death
  record.
  * A session holds at most 1,024 facets; opening one more fails with
    `{error, system_limit}`. A facet's number is never reused within a
    session, so a number the host kept names nothing once its facet is
    closed.
  * A pid in a reply that is not one of the session's facets is rendered
    as `{'$pid', Text}`, and a reference as `{'$ref', Text}`, where `Text`
    is its printed form. These are names: the host cannot address them.
  * These handles serve the calls on facets alone; file access carries
    none, since the files stream's handles are 9P's fids.
* **Decoding.** A payload from the host is checked by `liberx`'s `erx_etf`
  with the host grammar, the system grammar of
  [design-domains.md](design-domains.md#the-funnel) less pids and
  references, at most 16 MiB decoded, and only then decoded with
  `binary_to_term/2` in safe mode, so it creates no atom. The tool decodes
  target payloads with its own bounded decoder of the same grammar and
  filters terminal output with the generated allowlist: to the host, the
  target is untrusted too.
* **Resident bytes.** What a session makes `erx_hostlink` hold stays
  within the session's resident limit, 32 MiB (an estimate), charged to
  the system domain's budget, which holds one session's, since the link
  has one session at a time. Each part is reserved before its bytes are
  kept: the message being reassembled at its `total`, from its first
  frame; each call admitted and not yet answered at its decoded size,
  which `erx_etf` computes before anything is decoded; and each reply kept
  for the call window at its encoded size. A message or a call that the
  limit cannot hold is answered `{error, busy}`, neither executed nor
  seen, so the transport's credit, the call window and the resident limit
  together bound what a host, logged in or not, can make the target hold.

### Files between the host and the machine

File access between the development host and the machine is a 9P2000.L
mount, in both directions, through the codec and the bridges of
[design-files.md](design-files.md#the-codec). No facet number, call
identifier or term handle takes part: a 9P session's fids and tags are
its handles, and `attach` names the tree.

**The machine mounts the host's tree.** Under QEMU, a configuration that
asks for it gives the guest a virtio-9p device, which QEMU's 9P2000.L
server backs with a directory of the host, such as the developer's build
tree; no guest gets one otherwise, as no guest gets a network device
unasked. The manifest gives the device to the **host-tree domain**, a
domain of its own, whose Erlang driver runs the virtio queue over the
device NIF and whose 9P bridge serves the host's tree to erXos's clients:
each domain the manifest names gets a grant of the bridge, mounted at
`/host`, read-only unless the manifest says otherwise. The bridge asks
QEMU for an `msize` of 65,560, so a read carries at most the 65,536 bytes
a read carries inside the machine, and decodes every reply with `erx_9p`,
since bytes from the host are untrusted input like any other; a reply that
fails the codec fails its request with `eio`. The bridge waits for a reply
before it sends a request that depends on it, a walk's before the `lopen`
of its fid, since QEMU runs each request on its own and may answer out of
order. QEMU's server leaves the `data_version` bit of `getattr`'s `valid`
mask clear, so files under `/host` have no version and are never cached
under one, and a session reads each afresh for every map
([design-files.md](design-files.md#identity-and-version)). Three limits of
QEMU's server bound `/host`. Its `lock` always answers success and its
`getlock` always unlocked, so record locks over `/host` lock nothing. On a
macOS or FreeBSD host it translates only six error numbers to Linux's and
passes the rest in the host's numbering, where macOS's `EAGAIN`, 35, reads
as Linux's `EDEADLK`, so the bridge reads every number outside the
protocol's list as `eio`, and an error under `/host` on such a host may
arrive as `eio`. And a name that is not valid UTF-8, which a Linux host's
directory may hold and a macOS host's may not, fails the `readdir` of its
directory, since erXos requires UTF-8 names. A domain may load code it
reads from `/host` with its own authority, as from any of its files; the
system domain still loads code only through the install facet (V5).

**A host client mounts an erXos tree.** The host link's **files stream**,
stream 4, carries 9P2000.L messages, one whole message in each frame's
body, so the host link's `msize` is 8,192, a frame's body, enough for the
largest message of every operation, and no message is reassembled.
`erx_hostlink`'s 9P bridge decodes each with `erx_9p` and relays it to the
grant of the tree that `attach`'s `Aname` names, among the trees the
host-link configuration lists: in development builds `proc`, the
inspector's tree at scope `all`, and `data`, the data partition's root; in
release builds the trees the system manifest lists, by default none. An
`attach` naming another tree fails with `enoent`. On the host, `tools/erx
files` relays a Unix socket in the harness's owner-only directory to the
files stream, checking each message's size field against the stream's
`msize` and nothing more, so any 9P2000.L client of the host mounts the
socket and parses the target's bytes as it parses any server's.

The files stream lives inside a host-link session. Its first message is
`version`, as 9P2000.L asks; the 9P session ends with the host-link
session, and the bridge then clunks every fid it holds, so a replaced
session leaves nothing open on the machine. A message lost with a damaged
frame is not sent again: its request waits until its client flushes it,
as 9P over any transport without retransmission does. What a host may
reach through the files stream is exactly the listed trees, within each
grant's rights and bounds (V3).

## Interfaces

### Erlang, in every domain

| Function | Contract |
| --- | --- |
| `erx:i() -> ok` | `erx:i([])`: the machine's record, the root of every path |
| `erx:i(Path) -> ok` | renders the record for `Path` in the shell, through the caller's inspect facet |
| `erx:domains() -> ok` | lists every domain the caller's inspect facet covers: id, name, principal, state, memory, CPU time and process count, each value marked with its reporter |
| `erx:ps() -> ok` | lists every process of every domain the caller's inspect facet covers, by domain, and under a session its programs: pid or program number, registered name or program name, current function, reductions, memory and queue length, each marked with its reporter; the `ps` command emits the same fields as records |
| `erx:inspect(Path, Options) -> {ok, record()} \| {error, Reason}` | `Options` holds `offset`, `limit` and `timeout`; `Reason` includes `scope` and `no_facet` |
| `erx:source(Pid \| {module(), atom(), arity()}) -> ok \| {error, Reason}` | prints the source lines around a process's current location or a function's first line; `{error, unsupported}` when the module's release carries no source |
| `erx:trace(Spec) -> {ok, reference()} \| {error, Reason}` | starts a trace of processes, frames or kernel events that prints in the shell; `erx:trace_stop(Ref)` ends it |
| `erx:attach(Domain) -> ok \| {error, Reason}` | a console session with a shell inside `Domain`, through its console facet |
| `erx:console_size(Width, Height) -> ok` | system domain only |
| `erx_code:history(DomainId, Module) -> {ok, [{Hash, Time}]} \| {error, scope}` | the hashes loaded into a domain for a module, newest first, at most 16, through the caller's inspect facet ([The code store](#the-code-store)) |

**Shortcuts.** The shell commands of the vision work without the `erx:`
prefix in every domain's Erlang shell: `ps()`, `i(Path)`, `domains()`,
`source(X)`, `trace(Spec)`, `trace_stop(Ref)` and `attach(Domain)` are
exports of erXos's `shell_default`, which the shell consults for a local
call it does not recognise, after `user_default` and before the functions
defined in the shell (`lib/stdlib/src/shell.erl:1604-1633`). Each is a
one-line call of its `erx` function, with the same facets and no
authority of its own. Living in `shell_default`, they survive a release
that brings its own `user_default`. None shadows OTP's own commands: the
shell's commands (`v`, `h`, `b`, `f`, `rd`, `rf`, `rl`, `rp`, `rr`,
`history`, `results` and the rest, `shell.erl:1304`) come first, and
OTP's `shell_default` exports `i/0` and `i/3`, its process listing and
process information, but not `i/1`, so `i()` and `i(X, Y, Z)` keep OTP's
meaning and `i(Path)` is the inspector; `erx:i()` keeps its prefix. A
function of the same name and arity that a user defines in the shell is
shadowed by a shortcut, a documented difference with a test. A test
derives the shell's command list and OTP's `shell_default` exports from
OTP's modules and fails if a shortcut collides with either.

### The host tool

`tools/erx console | load | watch | inspect | source | trace | files`;
`files` relays a Unix socket to the host link's files stream
([Files between the host and the machine](#files-between-the-host-and-the-machine)).
Every command
has long options, exits 0 on success, 1 on failure and 2 on a usage error,
starts every subprocess with an argument vector, and gives up after a
deadline it names.

## Compatibility and migration

Until a release promises compatibility, nothing here owes any to an
earlier build, and a change to a format replaces the old form outright,
with no reader for an earlier version. Every format here carries a
version, which serves only to make a mismatch fail loudly: host link
frames (the version byte, 2), inspection records (`schema` 1), and the
terminal rules, which are generated with each build and checked by build
identifier. One build produces every component of a boot; the host tool
checks the build identifier in the root's `hello` reply and refuses a
target from another build. The console relies on `prim_tty` and on the
protocol between `group` and its driver, both internal to OTP; erXos owns
its OTP tree, so they change only when erXos changes them, and any such
change reruns the console tests and regenerates the allowlist first.

The one state here that outlives a boot is what the code service keeps on
a data partition: each principal's overlays with their histories, and its
hot store's blobs. A blob is named by its hash and checked against it, so
it needs no version. The overlays' records carry version 1; a record of
any other version is refused with a diagnostic and never read under
another layout, and the domains whose overlay it held start from their
releases' manifests, as after a fresh installation. No build converts
one.

Three surfaces are erXos's own and differ on purpose from what users may
know:

* **`/proc` is not Linux's.** A program that parses Linux's `/proc` files
  finds other files, and toybox's applets that do so are not built
  ([The /proc tree](#the-proc-tree)).
* **A module's version is its hash.** The store's hash is the SHA-256 of
  the whole file; OTP's `module_info(md5)` keeps its meaning.
* **The shortcuts live in `shell_default`.** A function a user defines in
  the shell under one of their names and arities is shadowed by it.

The startup message carries version 1 as well, and a reader refuses
another version. The file protocol is 9P2000.L, whose `version` names it,
and the host link's files stream and the host-tree domain speak it as
any 9P2000.L peer does.

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | What is seen |
| --- | --- | --- | --- |
| A domain does not answer an inspection | deadline | | `{timeout, Ms}` for its runtime attributes; kernel and service attributes still `ok` |
| A domain is booting, ended or ending | the domain service's state | | `unknown` for runtime attributes; the death record and crash dump for an ended one |
| A session does not answer for one of its programs | deadline | the program's kernel attributes | `{timeout, Ms}` for the program's runtime attributes; its sub-space's charges still `ok` |
| A scoped facet asks for another domain's path | scope check | | `{error, scope}` |
| Damaged host-link frame | COBS or CRC | frame discarded, counted | the tool retries; counters under `[]` |
| Host-link session replaced or expired | session number, call window | the old session's facets closed | old frames discarded; an expired call gets `{error, expired}` |
| Host overruns its credit | the host link driver's receive buffer full | bytes dropped, counted | the session's next frames fail CRC or sequence; the tool reconnects |
| A 9P2000.L message on the files stream fails the codec | `erx_9p` in the bridge | message discarded, counted | no reply; the host's client flushes the request or gives up |
| A message of the files stream lost with a damaged frame | the frame's CRC or sequence | nothing | the request waits until the host's client flushes it |
| QEMU's 9P server answers with bytes that fail the codec, or stops answering | `erx_9p` in the host-tree bridge; the client's flush | the request failed | `eio` for that request; `/host` stays mounted |
| A load the domain refuses | the code server's reply | the candidate overlay discarded | the reply lists what loaded and what failed |
| An overlay names another release | the release hash at the domain's start | the overlay dropped | a log line naming the specification; the domain runs its release as built |
| No writable data partition is mounted | the code service | overlays and stores in memory only | a log line at boot; a reboot drops them |
| `erx_console` crashes | its supervisor | each session's group survives in its own process | the console restarts and reattaches the current session |
| The system domain faults, or halts outside an ordered shutdown | the kernel, through the fault gate or the watchdog ([design-kernel.md](design-kernel.md#the-root-task)) | nothing of the running system: every domain ends with the system domain's space; the kernel writes a crash record where the platform keeps one across a warm reset | the machine ends by `erx.panic`, which in a release build resets it and boots the committed slot; the console shows the boot banner, and `[kernel, crash]` and `/proc/kernel/crash` show the record to a holder of the system-shell facet; the host tool's session ends and reconnects after the boot |
| A `/proc` read meets a slow domain | the inspector's deadline | the snapshot, with `[timeout 500]` for the attributes that missed it | the file shows the status, never a guess |
| A blob does not match its hash | the code server's check | nothing loaded; the bad copy discarded | `{error, hash_mismatch}` from the load, in every flavour of load |
| A principal's hot store cannot hold a blob | the code service's charge to the principal's budget | nothing stored | the load fails with `{error, no_memory}` |

The inspector, the tracer and the host link are ordinary supervised Erlang
processes in the system domain; a crash in any of them restarts it under
its supervisor, and nothing outside the system domain notices but a
delayed answer.

## Security

**Boundaries.** The host link (untrusted bytes in every build: an
8,300-byte bound before decoding, CRC, session numbers, a call window,
credit, the host grammar and safe decoding for payloads, only the
session's facets, and on the files stream `erx_9p` within an `msize` of
8,192 and only the listed trees); the host-tree domain (QEMU's 9P bytes
decoded by `erx_9p` in a domain that holds the virtio-9p device and
nothing else of the machine, its tree mounted only where the manifest
names it, and no path from it to the system domain's code but the install
facet); the console (a login in release builds, which the vault checks and
limits, a menu that reaches only the logged-in principal's sessions, V7,
and the system shell only for the system-shell facet, V6); console
sessions in other domains (only the closed set of terminal requests
crosses, every character escaped by the console, every number bounded,
cursor movements kept to the session's edit region; the shell runs with
the target domain's authority, never the system domain's); the command
shell and its programs ([design-shell.md](design-shell.md#security)); the
`/proc` trees (one server per inspect facet, scope decided from the path
alone, names encoded injectively, snapshots bounded per grant); the code
store (blobs checked by hash before any loader reads them, each
principal's hot store written only by the code service, overlays and
stores read back from the data partition through a bounded, fuzzed
decoder); the inspector's scopes (owners from pids and kernel records,
never from domain reports); runtime reports (validated by the system
domain's funnel, then decoded in safe mode, with another domain's pids
dropped); and the host tool's decoder (bounded, same grammar, generated
terminal filter).

**Information that leaks.** Holders of an inspect facet see the names,
current functions and resource use of what their scope covers; that is the
facet's purpose. A scoped facet sees nothing machine-wide beyond the build
identifier, development flag and DMA profile. Pids and domain ids reveal
creation order. A domain reads only its own release's files from the boot
image, so the sources a release carries are visible to the domains running
that release and to the system domain. Each domain's debug-log lines reach
the kernel log within a rate limit, and what is dropped is counted
([design-kernel.md](design-kernel.md#console-log-and-panic)). `/proc`
shows exactly what `erx:i/1` with the same facet shows. Each principal's
hot store is its own and deduplicated only within itself and against the
principal's releases, so neither its answers nor its timing tell one
principal what another loaded.

**Residual risks accepted.** Runtime-reported attributes of a process, a
program's name among them, are what its domain claims; the record marks
them. In development builds the host link holds every facet, including
`install`, and `root`'s console session holds the system-shell facet,
which makes each as powerful as the system domain. Hot-loaded code in a
domain has that domain's full authority, as OTP states for any loaded
code. A persisted overlay is only as trustworthy as the data partition,
and a compromised file system of that partition can run code in the
supervised domains of every principal whose directory it serves, never in
a domain of the system configuration ([The code store](#the-code-store));
it cannot forge a principal's login, since the vault's key files live on a
partition of their own ([design-system.md](design-system.md#the-vault)).
A replay of a recorded host link after a machine reset runs its calls
again on a development build with weak or fixed entropy ([The host
link](#the-host-link)). Implicit bidirectional reordering of displayed
text is not escaped ([Text on terminals](#text-on-terminals)). A
full-screen program in terminal mode can draw anything the allowlist
permits within the console's screen, a fake prompt included, as on Unix;
it cannot set titles, write the clipboard or make the terminal answer.

## Verification and testing

The inspection schema generates valid-input builders, boundary mutations
and fuzz entry points for the production validators. Independent fixtures
exercise every status/reporter combination, unauthorized paths and fields,
unknown keys without atom creation, and hostile names in every projection.
They check that rendering never turns missing data into success and that a
development-only field never reaches a release projection. The generated
reference tables and field projections are covered by the drift check.

* **Terminal tests** feed every C0 and C1 control, every `Cf`, `Zl`, `Zp`,
  unassigned and default-ignorable character, the four exceptions,
  surrogates in character lists, UTF-8 sequences split across requests,
  pipe reads and frames, and every CSI, OSC, DCS, APC, PM and SOS form
  through each console request type, `put_bytes` included, and each host
  command, and compare the transcript with the expected escapes; a session
  in another domain that moves the cursor above its edit region or clears
  the screen rewrites no other line; a second test re-derives the
  allowlist from `prim_tty` and fails if `abi/terminal.txt` disagrees; the
  build check that only the three writers write terminal bytes has a test
  that seeds a fourth.
* **Terminal mode:** each sequence of the terminal-mode allowlist passes
  with in-range parameters and is clamped or escaped beyond them; every
  OSC form, OSC 52 and titles included, every DCS, APC, PM and SOS form,
  every reporting request and every mouse mode is written escaped; a
  sequence split across writes passes or is escaped whole; a job that
  leaves the alternate screen, a scrolling region and hidden cursor and
  then leaves the foreground leaves the terminal reset; a session that is
  not connected to the console cannot turn terminal mode on; the
  terminal-mode parser has a fuzz target.
* **Logs:** a domain that floods log records past its rate, sends records
  of other shapes or oversized text, or writes control characters in them
  leaves one escaped line per accepted record under its own id and
  principal, whatever name it chose, and a count of the rest; a program's
  log lines appear under its session's id. The console's two decoders of
  log records, for the kernel's records from `erx_log_read` and for the
  domains' records from their facets, have fuzz targets.
* **Inspection tests:** one per status and per reporter; scope tests for
  facets limited to some domains; a record for every path kind against a
  domain whose agent lies, which must appear marked `runtime`, and whose
  listing of another domain's pids is dropped; a session's program with a
  running child, before and after it execs, listed under the session as a
  port with its sub-space's charges from the kernel, its child as another
  program of the session, and neither anywhere under `[domains]` (V8); a
  session whose agent misnames a program, whose record still shows the
  kernel's object id and charges; a `[domains, Id, connections]` record whose
  doorbell counts come from the kernel and whose frame counts are marked
  `runtime`. The trace merger with a source that stops answering, which
  delays the stream by at most 100 ms, and a source whose event arrives
  late, which is printed marked `late`.
* **Tracing:** a trace of a process whose messages carry atoms the system
  domain does not hold, rendered in the traced domain and shown in the
  shell; a frame trace of a conversation between two traced domains, each
  frame appearing in its receiver's trace with the lane's peer, including
  a malformed frame shown as refused; a scoped trace facet that sees no
  frame received by a domain outside its scope.
* **Host link:** session replacement; a recorded hello and its calls
  replayed after a machine reset with entropy `good`, which match no
  session; a retried call executed once; 64 calls executing when a 65th
  arrives, which gets `{error, busy}`; a duplicate whose reply was not
  kept; an expired identifier refused; a lost frame in a fragmented
  message; credit exhaustion; the 1,025th facet; a closed facet's number
  refused. The session protocol (hello, calls, the window, expiry,
  replacement) is a pure state machine. An independent TLA+/TLC model
  checks its contract, and a host test explores the implementation over every
  interleaving of two sessions, lost frames and duplicates against an
  independent oracle. Each model property maps to a concrete check under
  [Protocol verification](design-verification.md). A fuzz target
  for the deframer (COBS, CRC, header, credit) and one for the Ruby
  decoder, each with a persisted corpus.
  Tests inject equal and unequal 128-bit session identifiers, fresh hello
  nonces, and near-exhausted frame/call counters: a counter never wraps
  into a prior request. The harness checks owner-only socket access, and
  release configuration refuses an unauthenticated network bridge. CRC
  success is never treated as peer authentication.
* **Files with the host:** Linux's 9P2000.L client in the oracle guest
  mounts the `proc` and `data` trees through `tools/erx files` and runs a
  file-semantics corpus; an `attach` of an unlisted tree fails with
  `enoent`; a host-link session replaced while fids are open, after which
  the bridge holds none; a message cut by a damaged frame, which only a
  flush ends; `erx_9p`'s fuzz target over the files stream's bytes; under
  QEMU, the machine mounts a host directory at `/host` and runs OTP's
  `file_SUITE` over it, and a fake 9P server whose replies are malformed
  fails each request with `eio` and nothing more. Seeded failures: a
  bridge that keeps its fids across a session's replacement, which the
  replacement case catches, and one that skips the `Aname` check, which
  the unlisted tree catches. A recorded-frame test
  establishes behavior for its chosen identifiers, not a proof that a
  random collision cannot occur.
* **Logins:** a release build's console shows a login and starts the
  session in the principal's domain; a session without the system-shell
  facet gets no system shell; a release build's host-link `console` starts
  a login; a wrong passphrase is refused, and a sixth failure within 60 s
  is answered as limited, per name and per terminal; the menu shows
  and reaches only the logged-in principal's sessions, a locked console
  reaches none of them until the same principal logs in, and a logout ends
  the sessions started there (V7).
* **Code:** a hot load into the system domain from the host in a
  development build; a refused load without the install
  facet; `code:load_binary/3` of a module from outside installed storage
  refused in the system domain with `{error, not_installed}`; an atomic
  load of a batch with one bad module, after which no module of the batch
  changed; an overlay surviving a domain restart; an overlay dropped when
  its release changes, on a normal boot and on a trial; an overlay of the
  system configuration that never reaches the data partition; a load that
  the domain refuses; two loads into one domain at once; a module larger
  than one host-link frame; the decoder of overlays and stores read back
  from the data partition, with a fuzz target.
* **The machine reset:** a system-domain fault injected in a QEMU test,
  after which the guest reboots into the committed slot, `[kernel, crash]`
  shows the record, in the form the build writes, to a holder of the
  system-shell facet on a platform that keeps one and `unsupported` on
  one that does not, a caller without that facet gets `{error, scope}`,
  and the host tool reports its session ended with the
  outcome of its outstanding calls unknown, then reconnects.
* **QEMU transcript tests** for the console prompt, `erx:i/1`,
  `erx:source/1` and a host-side `erx watch` load, under TCG and HVF.
* **`/proc`:** each status rendered in a file; a scoped tree's `enoent`
  for an existing process outside its scope and for a missing one, with
  equal timing; a snapshot that stays fixed while the process changes; a
  directory past 1,000 entries and its `.partial` file; a listing the
  inspector cannot get and its `.unknown` file; module and program names
  with `/`, `..`, a leading `.` and control characters, which the encoding
  makes plain entries; a reader that opens 256 snapshots, which its grant
  holds within 16 MiB, and a 257th open, which fails with `emfile`; values
  with tabs, newlines and control characters, which stay exact in the
  file; a program of a session reading `/proc` through a fid its
  handler walked from the session's. The decoder of `/proc` names has a
  fuzz target, checking that every name it accepts encodes back to itself
  and that no two names decode alike.
* **The code store:** a blob one bit off its hash refused in every
  flavour of load; `erx watch` sending only missing blobs; history and a
  rollback, across a domain's restart; an overlay that survives a reboot;
  a principal that asks for another principal's blob is told it is
  missing, and storing a blob another principal holds takes as long as
  storing a new one.

## Performance

The host link runs over an emulated UART: under HVF each register access
traps to QEMU, so throughput is bounded by trap cost rather than baud
rate. An estimate of 1 to 10 us per byte gives 0.1 to 1 MB/s, so a 100 KiB
module uploads in 0.1 to 1 s and an inspection record of 2 KiB returns in
2 to 20 ms. These are estimates; `tools/erx bench hostlink` measures
throughput and round trip under HVF and TCG, and a virtio-console
transport replaces the UART behind the same framing if the measurement
misses the budgets in [Requirements](#requirements). The files stream
moves at most 8,192 bytes a message over the same UART, so a host mount
reads at the UART's speed less the 24 bytes a message that `P9_IOHDRSZ`
reserves for a read's or a write's header; a mount through virtio-9p moves
64 KiB a message at QEMU's speed, which `tools/erx bench fs` measures
against the release file system. An inspection of a process also costs one
round trip on the connection between the system domain and the process's
domain, to its agent, and of a program one more inside its session, to its
handler.

A `/proc` read costs one inspector query. Checking a blob's hash costs one
pass of the SHA-256 primitive over it
([design-runtime.md](design-runtime.md#per-byte-primitives)), an
estimated 200 to 500 MB/s in portable C, so 0.2 to 0.5 ms for a 100 KiB
module, and an estimated 0.05 to 0.1 ms where the CPU's SHA-256
instructions serve it, at 1 to 2 GB/s; `tools/erx bench sha256` measures
both paths.

## Portability

Everything here is Erlang except `tools/erx`, which is Ruby on macOS and
Linux. Nothing depends on the architecture; whether `[kernel, crash]` has
a record to show depends on whether the platform keeps a region across a
warm reset ([design-platforms.md](design-platforms.md#firmware)).

## Dependencies

No new library: OTP's `kernel` (`prim_tty`, `group`, `code`), `stdlib`
and `runtime_tools` (trace sessions) from erXos's OTP tree, and Ruby's
standard library for the host tool. QEMU's virtio-9p server, part of the
QEMU the harness runs, backs the host-tree domain; a host that mounts an
erXos tree brings its own 9P2000.L client. The command shell's dependencies are
in [design-shell.md](design-shell.md#dependencies).

## Alternatives considered

**`user_drv` with a terminal descriptor.** OTP's own terminal path needs a
descriptor and terminfo; erXos has neither, and the ssh mode of `prim_tty`
is the path OTP already maintains for terminals it does not own.

**A shell that runs in the system domain for every session.** Simpler, but
a user's shell would evaluate with the system domain's authority. Running
the shell inside the target domain makes the console a renderer only.

**Files over the host link as facets and calls.** A file facet would
offer open, read and write as calls with facet numbers for open files. It
loses: it would be a file protocol of erXos's own at the edge, which no
host tool mounts, while 9P2000.L is already the file protocol and any
9P2000.L client mounts it with its own fids and tags as handles.

**The host link carrying the host's tree.** The machine would mount the
host's tree over the UART, served by the host tool. It loses to QEMU's
virtio-9p, a 9P2000.L server QEMU maintains, at a virtio queue's speed
rather than an emulated UART's; boards, which have no virtio-9p, mount
nothing of the host.

**A CapTP-style table for every capability.** Inside the machine each
runtime's export table says which of its processes a peer domain may
address, and the lane says who the peer is
([design-domains.md](design-domains.md#exports)), so a table of numbers
is needed only on the serial wire, where no pid can travel and no lane
names the sender.

**Frames traced by a third party.** A router between domains would record
every frame it carried, delivered or dropped, in rings the tracer reads,
and the trace would be authoritative for every domain. It loses with the
router: there is no third party on a connection, and a receiver's own funnel is
the one place that knows whether a frame was accepted; the trace is the
receiver's report, trusted for the system domain and marked `runtime`
elsewhere, and a conversation is traced at both its ends.

**Programs as domains in the inspector.** Each program would have a domain
id and a path under `[domains]`, with its own agent. It loses with
program domains: a program is a sub-space and a port of its session, the
kernel places it beneath the session's space, and the session is the one
party that knows its name, its grants and its descriptors; a path under
the session shows it where it lives.

**A system-domain restart shown by the console.** A separate root task
would restart the system runtime and the console would come back with a
login while other domains ran on. It loses with that root task: a fault of
the system domain is a machine reset, every domain ends with it, and what
the console shows after is the boot banner and, through the inspector, the
crash record the kernel wrote before the reset.

**Overlays shared by every principal, in one directory.** One store and
one overlay directory would serve all principals. It loses: a forged
overlay could then target any specification, the vault's included, a
deduplicating store answers a second uploader faster and so tells one
principal what another loaded, and a blob kept once cannot be charged to
two budgets. Per-principal stores and overlays, with none persisted for
the system configuration, delete all three problems.

**Escaping in the data.** Every renderer, `/proc` and the record writer
included, would escape what it produces. It loses: data would no longer
be exact, the encoding would not be injective, and safety would rest on
every renderer remembering to escape. Escaping at the three terminal
writers needs no list.

**A kernel record per process, for authoritative process facts.** The
inspector could then report a process's state and CPU time without asking
its domain. It would need a record outside the runtime for every spawn,
which the design avoids on purpose. Process facts are runtime-reported and
marked so; the facts that matter for trust (a domain's CPU time, memory,
threads, sub-spaces and doorbell traffic) come from the kernel and the
system domain's own records.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| The emulated UART is too slow for comfortable uploads | medium | slow `erx watch` | `tools/erx bench hostlink`; virtio-console behind the same framing |
| `prim_tty`'s ssh mode misses a feature the shell uses | low | a rendering gap | the console tests cover every request type; erXos owns `prim_tty` and can extend it |
| A domain answers inspections slowly | medium | sluggish `erx:i/1` | deadlines and `timeout` statuses; kernel and service attributes need no answer |
| Frame traces of a user domain are only as true as that domain's funnel says | low | a compromised domain hides or invents frames in its own trace | the trace is marked `runtime`; the other end of every conversation is traced too, and the system domain's end is trusted; doorbell counts come from the kernel |
| The code store's history keeps blobs alive that no domain needs | medium | memory and storage growth | at most 16 hashes per module per specification, charged to the principal; blobs that no history, overlay or release of the principal names are freed |
| Escaping default-ignorable characters breaks legitimate text | low | a sequence shows as tokens, such as a subdivision flag built from tag characters | the four exceptions cover joiners and presentation selectors; each case is decided with a test |

Open questions: none. Whether release builds offer a host link at all
belongs to the release process ([plan.md](plan.md#beyond-the-plan)); the
mechanism is the same in every build, and a release build's session holds
only the facets its system configuration lists, by default none.

## References

* Erlang/OTP 29.1.2: `lib/kernel/src/prim_tty.erl` (`init_ssh/3`, line
  308), `lib/kernel/src/group.erl` (`start/3`, line 120),
  `lib/ssh/src/ssh_cli.erl` (line 420; `to_group/3`, lines 409-411, read
  2026-10-30), `lib/kernel/src/user_drv.erl`; see
  [research-erts-host.md](research-erts-host.md) and
  [research-erts-internals.md](research-erts-internals.md).
* J. Walker, D. Moon, D. Weinreb, M. McMahon, "The Symbolics Genera
  Programming Environment", IEEE Software 4(6), 1987,
  doi:10.1109/MS.1987.232087.
* S. Cheshire and M. Baker, "Consistent Overhead Byte Stuffing", IEEE/ACM
  Transactions on Networking 7(2), 1999.
* CRC-32C (Castagnoli), RFC 3720, section 12.1.
* M. S. Miller, "Robust Composition", PhD dissertation, Johns Hopkins
  University, 2006 (caretakers and membranes).
* The Unicode Character Database 17.0.0, as OTP 29.1.2 carries it in
  `lib/stdlib/uc_spec/` (`UnicodeData.txt`, 40,575 lines;
  `DerivedCoreProperties.txt`, whose `Default_Ignorable_Code_Point`
  ranges include U+034F, U+115F to U+1160, U+3164, U+FE00 to U+FE0F and
  U+E0000 to U+E0FFF; its `README-UPDATE.txt` records the update to
  17.0.0), read 2026-10-30.
* Erlang/OTP 29.1.2: `lib/stdlib/src/shell.erl` (the shell's own
  commands, line 1304; `user_default`, then `shell_default`, then the
  functions defined in the shell, lines 1604-1633), read 2026-10-30.
