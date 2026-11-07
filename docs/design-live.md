# The live machine: shell, inspector, tracing and code from the host

The live machine is what a person sees of erXos: a command shell on the
serial console, with an Erlang shell one `erl` away, from which the whole
machine is reachable as terms; one
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

* **A terminal is a tty, as on UNIX and QNX.** A tty is one process's
  `termios` state between the terminal and the opens that read and write
  it. What a program writes reaches the terminal byte for byte, apart from
  what its output flags ask for, such as newline to CR-LF. Nothing filters
  it, so a program can send the terminal any escape code, as over `ssh` to
  a UNIX box. A tty has many writers, and their output can interleave.
* **The console carries bytes.** `erx_console` owns the serial line: it
  connects one session's tty to it at a time and shows its own menu, login
  prompt and log lines. Line editing is no part of it: OTP's `group`,
  `edlin` and `prim_tty` in its terminal-less mode run in the shell's
  domain, a program with its own line editor on a raw tty, as under OTP's
  SSH daemon, so they work with no terminal descriptor and no terminfo.
* **Text labelled with its source is escaped by whatever displays it**, as
  `ls` escapes odd file names. A log line, a domain's name, an inspection
  record and what the host tool prints from the guest pass through the
  line escape, so one record is one line and cannot pass for another's.
  `/proc`, which is inspector output, writes such text already escaped,
  by an injective escape of its own. Data everywhere else stays exact,
  `cat`, pipes and files included. The rules come from one source,
  `abi/terminal.txt`, from which a generator produces each displayer's
  tables, the kernel's an ASCII-only subset.
* **Release consoles log in.** A release build's console starts with a
  login, which the vault checks, and a session runs in its principal's
  own domain; the console's menu reaches only the sessions of the
  principal logged in at it; an Erlang shell in the system domain starts
  only under the system-shell facet, which the console grants to a login
  at a secure line and never to a session, in development builds to
  `root`'s login at the UART.
* **One schema, honest statuses.** An inspection record covers a kernel
  object, a domain, a program or a process; every attribute carries a
  status (`ok`, `partial`, `unknown`, `unsupported`, `timeout`, `error`),
  and every value says who reported it: the kernel, a trusted service,
  the runtime of the domain it describes, or, by its own name, a stopgap
  that stands in for one of them. A compromised domain can lie
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
* **Text is UTF-8.** The line escape renders controls, bidirectional
  overrides, invisible characters and invalid UTF-8 in labelled text as
  visible tokens, from one table generated from Unicode's data.

## Context

The [architecture](design.md#signature-experiences) makes the interactive
environment part of the machine's identity. The commands `ps`, `inspect`,
`trace`, `source` and `domains` are functions of the shell and of the host
tool. The design joins them with an inspector schema whose every value
carries a status, shells on `prim_tty` and `group` over a tty, a host link
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
   development builds the system domain's command shell, with the Erlang
   shell one `erl` away, in release builds
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

* **Exact output, labelled text escaped.** A program's bytes reach the
  operator's terminal as its tty's flags leave them (V1); text labelled
  with its source reaches it only through the line escape or, in a file of
  `/proc`, the field escape (V9).
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
 |  watch, inspect, |  frames      |   for its facet, each session's bytes    |
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
                             |         ^ a tty's bytes, both   ^ facets, on
                             |         | ways, as frames       | the connection
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
command server, and serves the session's programs their `/bin`
and other local files through the session's export; `erx_procfs` and
`erx_code`, with each principal's hot store, sit in the system domain
beside the inspector. `erx:i([processes, Pid])` asks `erx_inspector`, which
reads the pid's creation to find its domain, takes the domain's kernel
facts (its group's usage, its budget) with `erx_object_info`, and asks the
domain's agent about the process over the domain's connection; the record comes
back with each attribute's status and reporter, and `erx_render` writes it
with the line escape. On the Mac, `erx inspect /processes/<7.85.0>` sends the
same query over the host link and renders the same record. `erx watch src
--domain 7` recompiles a changed module with the host's `erlc` and loads
it through domain 7's code facet; the code service also records it in the
domain's overlay, so the domain its specification starts next time starts
with it.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **V1.** A tty changes a program's bytes only as its `termios` says | every write to a session's or a pseudo-terminal's tty goes through `erx_tty:output/3`, a pure function of the bytes, the room and the output flags, which returns its input with `OPOST` clear and otherwise changes only what a set flag names; nothing after it reads the bytes: `erx_console` copies a connected session's bytes to the console's driver, and the host tool's `console` command copies the terminal stream to its standard output | a filter on the output path; a write path that skips `output/3` | a test at the tty's byte boundary: it writes all 256 byte values and every CSI, OSC, DCS, APC, PM and SOS form through `write`, stdio and `erlang:display_string/2`, and compares the bytes on the line and at the host tool with what was handed to the tty; with an escaping step added on the path, the comparison fails. `io:put_chars/1` is text for the group's editor, not bytes ([The tty](#the-tty)), so its test compares `prim_tty`'s rendering with stock OTP's |
| **V2.** Inspection never fabricates | every attribute value is a tagged status and carries its reporter (`kernel`, `service`, `runtime` or a stopgap reporter the schema declares); renderers print the status and reporter of every value | a renderer that drops statuses, or an attribute filled with a default | one test per status and per reporter; a property test that every rendered record shows the same statuses as the record |
| **V3.** The host link's authority is exactly its session's facet table and the trees its configuration lists | calls name a facet by its number in the session table and nothing else; the table is created empty with the session, holds at most 1,024 entries (opening one more fails with `{error, system_limit}`), and dies with it; the files stream reaches only the grants of the listed trees, by `attach`'s tree name, and its fids end with the session | a request path that resolves names to processes; a table or a fid that survives its session; an `attach` that reaches a tree not listed | session replacement tests; a request naming a number of an ended session is refused; an `attach` of an unlisted tree fails with `enoent`, and a fid of a replaced session names nothing |
| **V4.** A call on the host link executes at most once per session | `erx_hostlink` keeps a window of the 64 highest call identifiers, each unseen, executing or answered, and never moves it past a call still executing: a call that would push one out is answered `{error, busy}` without executing; answered calls keep their replies while the kept replies total at most 1 MiB, and a reply that does not fit is not kept; a duplicate is answered from the window, or with `{error, reply_lost}` when its reply was not kept, and an identifier below the window is refused | a window that forgets executing calls | retry and expiry tests with a lost reply and a duplicate in flight; 64 calls executing when a 65th arrives, which gets `{error, busy}` and runs once when sent again |
| **V5.** Code enters the system domain only through the install facet | the system domain's runtime loads only installed storage: its release's files and the install arena, which only `erx_code:install_beam/2` writes and which refuses every caller but `erx_code`; `erx_code` takes modules only from install facets, which name them by hash, and checks each blob against its hash; a service that loads bytes it received gets `{error, not_installed}`; nothing reapplies installs after a reboot | a second writer of the install arena, `erx_code` accepting modules from something other than an install facet, or a path that reapplies stored installs | a test that `code:load_binary/3` with bytes from a request fails in the system domain; a test that a domain's code facet cannot load into the system domain; a test that `install_beam/2` refuses other callers; a test that a blob one bit off its hash is refused |
| **V6.** Only the system shell types expressions into the system domain, and only a login at a secure line opens it | the console starts an Erlang shell in the system domain only under the system-shell facet, which it grants to a login by a system-shell principal at a line the manifest marks `secure`, holds itself, lends only to the system shell it connects at that line and to that shell's `/proc` tree, and ends with that login; no session ever holds the facet, so no route into a session reaches the system shell ([Window tokens](#window-tokens)); the inspector answers `[kernel, crash]`, the crash record, only to a call that presents the facet, and `/proc/kernel/crash` is that query rendered as a file, so the one check gates both forms; every session's shell, the command shell's `erl` builtin and every Erlang command run in the session's own domain; a release manifest that marks a terminal window secure fails the manifest check | a shell or an evaluator started in the system domain by another path; a release build's console that starts a system shell without a login; a facet a session holds, or one that outlives its login; a system shell connected at another line | a release build's console shows a login, and a principal without the facet gets no system shell; `erl` in the console's command shell evaluates in the session's domain; a principal holding the facet who logs in at a terminal window that is not secure gets no system shell; a lock and a log out at the UART end its system shell; the system shell gets the crash record from `erx:inspect([kernel, crash], #{})` and from `/proc/kernel/crash`, while `root`'s session in a development build, whose inspect facet has scope `all`, gets `{error, scope}` from the call and `enoent` from the read; the manifest check refuses a release manifest marking a window secure; a seeded console that grants the facet at a line that is not secure fails; the routes into a session are tested under [Window tokens](#window-tokens) |
| **V7.** A console line reaches only the sessions of its principal | `erx_console` records one principal per line: the one the principal service confirmed at the line's login, or, at a window a window token opened, the principal of the session that asked for it; the line's menu lists, connects to, interrupts and kills only the sessions the domain service records for that principal; a lock detaches the line and keeps the principal's name only for its unlock prompt, a log out clears the record, and only a login, which the vault checks, sets it again; a line gets a principal without a login only from a token the console minted for a session's own request, and every shell at it is then that principal's ([Window tokens](#window-tokens)). A terminal window thus carries its principal's authority, as a UNIX terminal does, and a compromised display domain has the authority of the shells in its windows and what any window system has, as an X11 or Wayland server does, and nothing beyond: no system shell, which a release build never connects at a window, no presence at the machine and nothing of a principal that neither uses the display nor types at it ([Window tokens](#window-tokens)) | a menu action or an attach that takes a session without checking its principal; a lock that leaves a session attached; a shell without a login whose session the display chose | two principals log in in turn at one line, and each menu shows and reaches only its own sessions; a locked line refuses every menu action, and its sessions run on, until the same principal logs in again; connecting a terminal already connected at another line is refused with that line named, where a seeded console that moves it fails; the token tests are under [Window tokens](#window-tokens) |
| **V8.** A program appears only under its session | a program has no domain id and no pid space of its own: it is a sub-space the session created and a port of the session's runtime, so the kernel's topology under `INSPECT` on the session's space and the session's agent are the only sources that know of it, and both place it under the session's path | a path for a program outside its session; a program with a domain id | an inspection test that starts a program and finds it under `[domains, Id, programs]` and nowhere under `[domains]` |
| **V9.** Text labelled with its source is displayed only through the line escape, and written into `/proc` only through the field escape | each display of it builds its line with the escape: `erx_console`'s log lines and menu, `logger_simple_h`'s early log, `erx_render`, which prints inspection records and the shell's records (a line a command read from a file or a program is that writer's output, not labelled text, and prints as its bytes), and the host tool's printer; the kernel's log escapes on entry with its own ASCII class; `erx_procfs` writes every field of a `/proc` file through the field escape, so `cat` of one shows no raw control | a renderer that prints a name or a value raw; a `/proc` file that writes a reporter's text unescaped; a class of characters missing from the table; a print path in the host tool that skips its printer; a log event that reaches a terminal by another handler | tests that send every C0 and C1 control, every `Cf`, `Zl`, `Zp`, unassigned and default-ignorable character, invalid and overlong UTF-8 and every CSI, OSC, DCS, APC, PM and SOS form through each display and each host command, in a log record, a domain's name and an inspected value; a fuzz target per escaper; a test that re-derives the classes from OTP's Unicode data and fails if `abi/terminal.txt` disagrees; the source check on the host tool's output calls, with a seeded violation |

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
-type reporter() :: kernel | service | runtime
                  | {stopgap, Name :: atom()}.   % a stopgap reporter of the schema
-type value() :: {ok, term()} | {partial, term()} | unknown | unsupported
               | {timeout, Milliseconds :: pos_integer()} | {error, term()}.

-type children() :: [segment()] | {partial, [segment()]} | unknown.

-type segment() :: atom() | integer() | binary() | pid().
```

A reporter is one of three categories, or a stopgap reporter: a stopgap
component that does the kernel's, a service's or a runtime's work in its
place and reports what it can see of that work under its own name.
`liberx`'s Phase 1 backend counts the pages of a budget in the kernel's
place, so a budget's `used` is `{{stopgap, liberx_pool}, {partial,
Pages}}`, which a renderer prints as the value `[partial]` with the
reporter `liberx pool`
([design-stopgap.md](design-stopgap.md#reporting-a-budget)). The schema
declares each stopgap reporter with the category it stands in for, its
label, the scope of what it sees and the attributes it may report; a
record carries only its name, an atom of `erx_schema`. A value the
kernel interface reports with the attribute's full meaning, or reports
as `unsupported`, is `kernel`'s, whichever kernel backs the interface; a
value a stopgap computes in another reporter's place carries the
stopgap's name, so a stopgap's observation never passes for the
kernel's.

The collector of each source assigns the reporter, never the report: an
attribute from `erx_object_info` is `kernel`'s or that of the stopgap
reporter the schema lists on it, one from a service's
records `service`'s, and one from a domain's agent `runtime`'s, whatever
the agent's frame says.

The collector of `erx_object_info` decides each attribute from two masks
and the report's value. The first is the report's `reported` field
([design-abi.md](design-abi.md#inspection-schema)). The second is
`erx_info_partial(Topic)` of the system domain's own `liberx`: the
fields its backend counts only partly, zero on erXos's kernel. A partly
counted field has its `reported` bit clear, so a reader that knows
nothing of the second mask sees it as not reported, never as exact. For
an attribute of the topic's kind that lists `kernel` and is not
`derived`:

| `reported` bit | partial bit | Attribute |
| --- | --- | --- |
| set | clear | `{kernel, {ok, V}}` |
| clear | set | `{{stopgap, S}, {partial, V}}`, S the one stopgap reporter the attribute lists for `kernel` |
| clear, or no such field | clear | `{kernel, unsupported}` |
| set | set | `{kernel, {error, invalid}}`, a fault of `liberx` |

A partial bit on an attribute that lists no stopgap for `kernel` is a
fault of `liberx` too, and the attribute is `{kernel, {error, invalid}}`,
so a stopgap's count never passes for the kernel's. A call refused with
`ERX_ENOTSUP` makes every attribute of the topic `{kernel,
unsupported}`; `ERX_ERANGE` from a topic whose `index` counts entries
ends the listing and makes no record; any other refusal makes each
attribute `{kernel, {error, S}}`, S the status's name. The inspector
makes the call itself, on capabilities it holds, and the partial mask is
its own `liberx`'s, so no domain's report reaches either mask. The
kernel names no reporter: the schema names the stopgap reporter of a
field the system domain's `liberx` marks partial.

A value the inspector derives from other attributes, one the schema
marks `derived`, as a budget's spending and room, is `ok` only when
every input is `ok`; otherwise it is `unsupported` when an input is and
`unknown` when none is, and it carries the reporter of an input that is
not `ok`, so a partial count never yields a room that reads as exact.

`abi/inspection.txt`, included by the ABI root, declares the kinds, paths,
attribute keys, types, units, bounds, the reporters each attribute
admits, the stopgap reporters and visibility rules, in the grammar of
[design-abi.md](design-abi.md#inspection-schema). Ruby generates bounded
C builders, Erlang types and `erx_schema`,
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
| `[domains]`, `[domains, Id]` | domain: name, principal, state and death record (service); budget guarantee, cap and spending, group usage, threads (kernel); atom count, ETS tables, modules, process count (runtime) | each attribute marked |
| `[domains, Id, threads]`, `[domains, Id, threads, T]` | the domain's threads by object id, from `ERX_INFO_THREAD` on its space; thread: state and wait kind | kernel |
| `[domains, Id, capabilities]`, `[domains, Id, mappings]` | the domain's capability table and mapping records, paginated | kernel |
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
| `[budgets]`, `[budgets, Id]` | budget: kind (wall or elastic), guarantee, cap, used, carved, lent, pinned and threshold, the watch's threshold, as the kernel reports them; from them the inspector derives and shows spending (`used + carved + lent`), borrowing (spending above the guarantee, else 0), room (cap less spending, saturating at 0), deficit (spending above the cap after a shrink, else 0) and what a destroy would give back to the parent (`guarantee + borrowing - pinned`, exact, since a pin counts the record pages it keeps when it is made), never an unsigned difference that could wrap, with a test for a budget whose spending stands above its cap; a dead budget is not shown, since the kernel refuses every capability to it from its close, and what it still holds is in its nearest live ancestor's `used` and `pinned` ([design-kernel.md](design-kernel.md#budgets)); the funded domain (service) | kernel; the funded domain, service |
| `[kernel, trace]`, `[kernel, log]` | trace records and log lines | kernel |
| `[kernel, crash]` | the crash record of the machine's last end, read from the region that survives a warm reset where the platform keeps one, with its form: in a release build the brief form, the cause, program counter, fault address, build, boot value and its slot, uptime and time since the last pet, and nothing else; in a development build the full form, with the registers, the backtrace and the kernel's final lines ([design-kernel.md](design-kernel.md#the-root-task)); `unsupported` where it has none. Only a call that presents the system-shell facet reaches it, whatever its inspect facet's scope, and the console lends that facet only to the system shell it starts ([The console](#the-console)); any other caller gets `{error, scope}`, and the console shows nothing of it before a login ([design-system.md](design-system.md#the-crash-record)) | kernel |

For a process of the system domain, the runtime is the system domain's
own, which is trusted; its attributes are still marked `runtime`, because
that is who reported them.

The schema marks a path **append-only** when its record is a sequence of
entries that only grows at the end, as a ring's readers see it:
`[kernel, log]`. Each entry of such a path carries its sequence number,
and a query with `offset` returns the entries from that number on,
starting at the oldest the ring still holds, so a reader that follows the
path learns how many entries it missed. The web's log view reads such a
path ([design-web.md](design-web.md#views-on-the-line)).

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
24      4     target    control: facet number, 0 for the root; credit: total granted; else 0
28      n     body      at most 8,192 bytes
28+n    4     crc       CRC-32C of bytes 0 .. 28+n-1
```

Integers are little-endian. A files body is one whole 9P2000.L message
([Files between the host and the
machine](#files-between-the-host-and-the-machine)). A control body carries
a piece of a control message: a 16-byte header (`kind`, a byte: 1 call, 2
reply, 3 cast; `flags`, a byte, bit 0 `MORE`, set on every piece but the
last; 2 reserved bytes, zero; `total`, 4 bytes, the length of the whole
payload, the same in every frame; `id`, 8 bytes, the call identifier,
nonzero for calls and replies and zero for casts) followed by a piece of
an external-term-format payload. Every piece but the last is a full 8,176
bytes, the body less its header, so a message has exactly as many pieces
as its `total` needs and a receiver keeps no more than the `total` it
reserved; a piece of any other size is discarded with its message. The
pieces of one message are consecutive among the control frames of its
session, and frames of other streams may come between them. The layouts
and bounds are
`abi/protocols/hostlink.txt`'s, and the COBS encoding is Cheshire and
Baker's. A sender may send a zero before a frame, to end any damaged bytes
before it; two zeros in a row make no frame. A
receiver discards an encoded frame longer than 8,300 bytes, a frame whose
CRC fails, a frame with an unknown version or a stream its side does not
receive, and a frame of any session but the current one, and counts each;
it never answers malformed input. The one exception to the session rule is
a control frame of session 0, which carries the `hello` that opens a
session; a hello and its reply are one frame each, taken apart from the
current session's sequence, the message it is reassembling and its
resident limit, and a hello of more frames is discarded. `seq` grows by
one per frame and the session ends before it wraps. A receiver discards
and counts a frame whose `seq` is below the one it expects, a repeat,
and leaves the message it is reassembling alone; one that sees a gap
discards the message it was reassembling, and the sender's retry sends
it again. A message's `total`
may not exceed the session's limit, 16 MiB, or 8 KiB in
a release build whose configuration lists no facet for the host, and must
fit what is left of the session's resident limit ([The host
link](#the-host-link)), which bounds reassembly before any byte is kept.
A message whose `total` is over the session's limit is discarded and
counted, and one that does not fit the resident limit is refused; the
later pieces of either are skipped, not taken as the start of another
message. A piece that does not continue the message being reassembled (by
its kind, id, target or total), or bytes past `total`, discard that
message.

### Escape rules

`abi/terminal.txt` is the one source of the line escape's rules. It names
the Unicode general categories and properties whose characters are escaped,
the closed list of exceptions, the grammar of the escape tokens and the
bytes the kernel's log passes, and the field escape's byte token, which the
generator refuses unless it keeps the field escape injective. A Ruby
generator reads it together with the Unicode data OTP 29.1.2 carries (`lib/stdlib/uc_spec/UnicodeData.txt` and
`DerivedCoreProperties.txt`, Unicode 17.0.0) and produces the Erlang tables
of `erx_text`, the Ruby tables of the host tool, the TypeScript table of
the web client ([design-web.md](design-web.md#the-client)), and the
kernel's ASCII-only class for its log
([design-kernel.md](design-kernel.md#console-log-and-panic)), so every
display of labelled text escapes from the same rules.

## Algorithms and behavior

### The tty

A **tty** is the state of one terminal: its `termios`, its window size, the
input it holds and who reads it. One process owns that state and serves the
tty's two sides: the **master**, which carries bytes to and from the
terminal, and any number of **opens**, which programs and shells read and
write. Its decisions are one pure state machine, the **line discipline**,
the Erlang module `erx_tty`, the same for every tty and tested exhaustively
on the host:

* `output(Bytes, Room, Tty)` returns how many of `Bytes` it took and the bytes
  for the master, at most `Room` of them. With `OPOST` and `ONLCR` a newline
  becomes CR-LF, and no other byte changes unless a program sets another of
  POSIX's output flags. With `OPOST` clear the bytes are its input. A CR-LF is
  never split, so 4 KiB of newlines with 4 KiB of room takes 2 KiB. This is the
  only thing that ever happens to a program's output.
* `input(Bytes, Tty)` returns the next state and what to do: bytes to echo, a
  signal for the foreground group, a report that a waiting read can go on. A
  line in cooked mode holds at most 4,095 bytes and its end, and in raw mode at
  most 4 KiB wait unread; further bytes are dropped and counted, as Linux's
  line discipline does.
* `read_wait(Open, Tty)`, for a blocking read that starts to wait,
  `timer(Open, Tty)`, for its timer's end, and `read(Open, Max, Tty)`, for the
  read itself, return the next state and what to do: bytes for the reader, or
  none; a report that the read can go on; a timer to start or cancel.
* `set(Termios, Tty)` takes a new `termios`, checking it whole; a flag
  outside `erx_tty`'s table fails with `EINVAL`.
* `size(Rows, Columns, Tty)` takes a new window size, each from 1 to 65,535,
  and refuses any other.

The owner carries out what they return and owns the timers, so time reaches the
machine only as `timer`, and the exploration on the host drives it event by
event.

**Cooked and raw** mean what they mean on UNIX, as flags of `termios`:

* **Cooked**, `ICANON` set: the line discipline collects a line, applying
  `VERASE`, `VKILL`, `VWERASE` and `VEOF`, and a read gets one line. History
  and arrow keys are no part of it.
* **Raw**, `ICANON` clear: a read gets bytes as `VMIN` and `VTIME` ask for,
  by POSIX's four cases:
  * `VMIN` above 0, `VTIME` 0: the read can go on at `VMIN` bytes;
  * `VMIN` and `VTIME` above 0: at `VMIN` bytes, or when a timer that each byte
    restarts, and the first byte starts, ends;
  * `VMIN` 0, `VTIME` above 0: at the first byte, or when a timer that
    `read_wait` starts ends, and the read then returns no bytes;
  * both 0: at once, with whatever waits.
* `ECHO`, `ISIG` and `OPOST` are flags of their own, which `cfmakeraw` clears
  with the rest, so a tty made raw with it delivers `Ctrl-Z` as data.
* With `ISIG`, `VINTR`, `VQUIT` and `VSUSP` signal the foreground group.

A new tty starts cooked, with `ECHO`, `ISIG`, `ICRNL`, `OPOST` and `ONLCR`
set.

**A shell's line editor is a program on a raw tty.** `group`, `edlin` and
`prim_tty` are to a shell what readline is to `bash`. While the shell
prompts, its tty has `ICANON`, `ECHO`, `ICRNL` and `OPOST` clear, as stock
OTP sets a real terminal (`erts/emulator/nifs/common/prim_tty_nif.c:1115-1127`,
so `prim_tty` writes its own CR-LF), and `ISIG` clear, since `ssh_cli` and the
group take `Ctrl-C` as data. The process that drives the group, the terminal
relay or for the system shell `erx_console`, takes each request through
`prim_tty:handle_request/2`, whose state comes from `prim_tty:init_ssh/3`
(`lib/kernel/src/prim_tty.erl:308`), which needs neither a terminal
descriptor nor terminfo, and writes the bytes to the tty as any writer does, or
for the system shell to the driver. Input goes to the group as `{self(), {data, Chars}}`, the protocol `ssh_cli`
uses (`lib/ssh/src/ssh_cli.erl:420`), and `Ctrl-C` interrupts the shell's
evaluator as `ssh_cli` turns it into `exit(Group, interrupt)`
(`lib/ssh/src/ssh_cli.erl:409-411`). Before the shell starts a foreground
job it sets the tty's `termios` back to cooked, keeps the job's when the job
stops, and restores its own when the job ends or stops and the job's at `fg`,
as a UNIX shell does. So a program that ends in raw mode leaves nothing in
the `termios`. What it left on the terminal itself, an alternate screen, a
hidden cursor or a colour, stays until the operator runs `reset`, as on UNIX.

**The editor's rendering is not the tty's.** A process's `io:put_chars` is
Erlang's text I/O, not a write of bytes: the group turns it into
`{putc, Binary}`, which `prim_tty`, in stock OTP's cooked output mode
(`prim_tty.erl:329`), renders for the screen as stock OTP's shell does, with
CR-LF for a newline and caret notation for a control character
(`prim_tty.erl:696`, `:1227`, `:1280`). That is the shell's line editor at work,
as readline's redraw is `bash`'s. What `prim_tty` returns then reaches the tty
as a write. So there are two exact comparisons, each at its own boundary: what a
writer hands the tty against what the master gets, which V1 tests; and what
`prim_tty` renders from a request against what stock OTP's renders from the same
request. A program that needs exact bytes uses `write` or stdio, and Erlang code
uses `erlang:display_string/2`.

**Where a tty lives.** A session's tty lives in the session's domain, in its
terminal relay ([Job control](design-shell.md#job-control)), which answers
every `{tty, Open, Request}` of its programs. A tty's master is `erx_console`
while the tty is connected at a console line, the UART, the host link's
`console` line or a terminal window ([The console](#the-console)), or in
the second tier a program that holds a pseudo-terminal's master;
so a session's `/dev/tty` and a `/dev/pts/N` are one thing with different
masters ([design-programs.md](design-programs.md#the-terminal)).

The system shell's tty lives in `erx_console` and is simpler. Programs run only
under a session's domain (V8), so no program opens it and nothing can call
`tcsetattr` on it: it is raw with every flag clear for as long as it lives, and
`erx_tty` would return its input unchanged in both directions. So `erx_console`
runs no line discipline for it, and copies bytes between the driver and the
group's `prim_tty`. `erx:console_size/2` checks the size as `erx_tty:size/3`
does, so a zero column count never reaches `prim_tty`.

**Between domains.** A tty and a master in the system domain exchange five
closed messages, as frames on the domain's connection to the system domain.
Nothing crosses that the console has to interpret. Each receiver checks what it
gets, whatever the sender's own limits:

| Message | Direction | The receiver's check | If it fails |
| --- | --- | --- | --- |
| `{tty_output, N, Bytes}` | tty to master | a binary of at most 4 KiB, charged after `output/3`; `N` is the tty's next output number, or the last one again with `Bytes` empty | the console detaches the tty and logs a line under the domain's id |
| `{tty_taken, N}` | master to tty | `N` is the output outstanding | ignored, since it is a late repeat |
| `{tty_input, Bytes}` | master to tty | a binary of at most 4 KiB; `input/2` bounds what waits unread | dropped and counted |
| `{tty_size, Rows, Columns}` | master to tty | `size/3`, each from 1 to 65,535, so a zero column count never reaches `prim_tty` | the old size stays, counted |
| `tty_hangup` | master to tty | that atom; it holds from then on | not applicable |

**A lost answer does not stop a tty.** The system domain's peer may drop a
message to a domain whose lane stays full
([design-domains.md](design-domains.md#the-peer)), and a `{tty_taken, N}` is
such a message. So the tty has one output outstanding and numbers it, and with
no answer in 1 s it sends `{tty_output, N, <<>>}`, and again each second. A
master that has taken output `N` answers `{tty_taken, N}` again, with the
current `{tty_size, Rows, Columns}`, and `tty_hangup` if it has hung up: these
are states, so a repeat of them is harmless and a lost one is sent again. A
master that has not taken it, because the session is not connected, sends
nothing, and that one output is all the console holds for a session. A lost
`{tty_input, Bytes}` is typed input lost, as in a line's overrun, and the peer's
count reports it. A master in the tty's own domain, a pseudo-terminal's, sends
the same messages as plain Erlang messages, which are not dropped.

**Many writers.** Every open may write, in any job and at any time. The owner
serves writes in arrival order, and each writer's bytes stay in order. A write
can be split, since it takes only what room there is, and another writer's bytes
can land between its parts, as POSIX allows: it promises atomic writes for pipes
and FIFOs up to `PIPE_BUF`, and nothing for a terminal. A background job's write
goes through; `TOSTOP` follows UNIX in the second tier and is refused in the
first ([design-programs.md](design-programs.md#the-terminal)).

An Erlang writer sends `{tty_write, From, Ref, Bytes}` and waits in `receive`
for the answer, which comes when all its bytes are in the tty. A program cannot
wait that way, since a program's outstanding request holds up its signals
([Signals in liberx](design-programs.md#signals-in-liberx)): it waits for room
with no request outstanding, and then sends a write that is answered at once,
with the count taken ([Writing a
terminal](design-programs.md#the-terminal)).

**A stopped tty.** A tty whose master takes no more output is stopped, as a
line held by XOFF is: the owner holds at most 4 KiB, counted after `output/3`,
the outstanding output among them, and once that is full no write takes
anything, so writers wait. A session not connected to the console is in that
state until it is connected. Nothing is lost and nothing piles up.

**Why this shape.** It is the structure of a UNIX tty and of QNX's `devc`
drivers. UNIX keeps one `termios`, one line discipline and two queues per
terminal in the kernel, between open files and a serial driver or a
pseudo-terminal's master. QNX keeps the same in user mode: a `devc-ser*` or
`devc-pty` process is a resource manager built on the `io-char` library, which
holds each device's `termios`, queues and line discipline, and clients reach
it with `write` messages. The terminal relay has QNX's shape, in Erlang and
one per session, since a session's programs already take their terminal
requests to it. Neither system filters output.

### The console

`erx_console` is the system domain's console service. It serves
**console lines**, the terminals at which an operator logs in and works:
the UART, which is erXos's `/dev/console` as on UNIX; the host link's
`console` facet; and each terminal window that a display domain offers
through `offer_line` ([design-display.md](design-display.md#terminal-windows)).
Every line has its own menu, its own login and at most one connected
terminal, and the console treats them alike except where this section
names the UART.

**The UART.** The console's UART belongs to the system domain in every
manifest, which names it by its device-tree path in its `console` field;
at boot the device service refuses a manifest whose `console` path is not
the UART that `/chosen/stdout-path` names. Its driver, an Erlang process
over the device NIF, runs in the system domain beside `erx_console` and
feeds it directly ([design-system.md](design-system.md#drivers)):
received bytes arrive as messages, and the driver writes each write it is
sent to the UART whole and in order.

**Secure lines.** Each line has a `secure` attribute in the system
manifest ([design-system.md](design-system.md#the-manifest)), as UNIX's
`/etc/ttys` marks the terminals where root may log in. A release
manifest marks the UART and the host link secure by default and may
clear either. The manifest check refuses a release manifest that marks a
terminal window secure (property 9 of
[design-system.md](design-system.md#the-manifest)), so a display domain, which sees and can inject
every byte of its windows, never carries the system shell, which only a
login at a secure line opens (**The system shell**, below;
[design-display.md](design-display.md#security)). A development
manifest may mark a display's windows secure, and each is then a secure
line, where a `root` login gets the system shell: a development build
runs trusted code only, and its display domain is then in that build's
trusted base, which the manifest check reports. A development manifest marks the UART and
the host link secure by default, and the console logs `root` in at both:
at the UART at boot, and at the host link's `console` line when the host
opens it, so each shows the system shell; a development manifest that
clears either flag gets `root`'s session there and no system shell. The
host link holds every facet but the system-shell facet in a development
build anyway ([The host link](#the-host-link)), and its operator reads
the system shell's records only in the system shell at its `console`
line. Being secure
is a property of a login's line, and only a login there opens the system
shell, so no route into a session carries it, whatever line it starts
from ([Window tokens](#window-tokens)).

**Writers.** A line has one reader at a time and several writers, whose
writes can interleave, as on a UNIX terminal:

* the tty of the terminal connected at the line, whose bytes
  `erx_console` copies to the line without reading them;
* `erx_console` itself: the line's menu, its login prompt, and the log
  lines the system's log service sends that line (**Logs**, below).

The UART has two writers more, which reach no other line, as on UNIX
they reach `/dev/console` alone. They are the output that must work when
the services are broken, so they bypass every session, tty, menu and the
log service:

* the system domain's runtime, whose `erlang:display_string/2`,
  `erlang:display/1` and `standard_error` are the system's emergency
  output. They reach `erx_console`, which writes their bytes to the
  driver unchanged and answers when the driver has written them
  ([design-runtime.md](design-runtime.md#the-console-and-standard-io)).
  They are a writer on the UART, as `/dev/console` is on UNIX, and not on
  any tty, so no tty's `termios` applies to them and none waits on them:
  the only output settings of a terminal are those of its one tty, and
  the line has none of its own;
* the kernel's early console, the same UART, at the address its platform
  build fixes and checks against `stdout-path` at boot, which it writes by
  polling at boot, before the driver starts, and at a panic, after the
  system domain has stopped; so the kernel and the driver share the UART
  in time and never write it together.

A terminal window or the host link shows its own session's output and
the log lines the log service sends it, and nothing else.

**Log lines and program output.** A log line is one write to the driver,
whole, ending in CR-LF, between whatever else is written. It can land in
the middle of a program's line or an edited prompt, as a kernel message
does on a UNIX serial console, and `Ctrl-L` redraws an edited line. After
boot, kernel log records reach the console through `erx_console`, which
reads them with `erx_log_read` and writes each as a log line
([design-kernel.md](design-kernel.md#console-log-and-panic)).

* **Size.** The connected tty is told its line's size as
  `{tty_size, Rows, Columns}`: on the UART 80 by 24 unless the operator
  sets another with `erx:console_size/2`, on the host link what the host
  tool reports, and on a terminal window what its `wctl` gives.
* **Input.** Bytes go to the connected terminal's tty as
  `{tty_input, Bytes}`, whose line discipline decides what they mean
  ([The tty](#the-tty)). The one exception is `Ctrl-G`, which the console
  keeps for the line's menu and no session ever reads, so the operator can
  always reach the real menu. While the menu or a login prompt has a line,
  no terminal is connected there: the tty last connected at that line is
  stopped, and its programs read nothing typed there and write nothing
  there.
* **Job control.** OTP keeps job control in `user_drv`'s `switch_loop`
  ([research](research-erts-host.md#corrections-and-additions)), which the
  console does not use, so `erx_console` implements it: `Ctrl-G` opens a
  menu that lists the sessions of the line's principal, in a development
  build `root` at the UART, and connects to, interrupts, starts or kills
  one (V7). The menu also opens a terminal window, locks the line and
  logs out:
  * **New terminal window** opens a window whose line shows a shell in
    the session connected at this line, as a new window in rio runs a
    shell in its opener's namespace ([Window tokens](#window-tokens)).
  * **Lock** detaches the current terminal and shows the login prompt with
    the principal's name; the principal's sessions run on, and only a login
    as that principal at that line reaches them again. Another principal
    may log in at a locked line, and its menu shows only its own sessions.
    A lock acts on its own line alone: the windows opened from it keep
    their shells, as locking one UNIX terminal leaves the user's other
    terminals open, so an operator who leaves the UART locks or logs out
    at those windows too. At a window opened without a login the name is
    that of the principal whose session asked for the window, and
    unlocking it is a login like any other.
  * **Log out** ends every session the principal started at that line and
    the shell of a window opened there without a login, as a hang-up
    ends a UNIX login's jobs, and shows the login prompt. A session started at
    another line runs on: logging out at a window opened from a UART
    session ends the window's shell and tty, not the session.

  A session's programs stop and continue under the command shell's job
  control, which pauses and resumes their groups
  ([design-shell.md](design-shell.md#job-control)); the menu acts on whole
  sessions.
* **One line per terminal.** A tty is the controlling terminal of its
  shell's jobs, and a UNIX terminal session has one controlling terminal,
  so a terminal is connected at one line at most. Connecting a session's
  terminal that is connected at another line is refused, and the menu
  says so and names that line; the operator locks or logs out at the
  other line first.
* **Logging in.** In a release build every line starts with a login
  prompt. It hands the principal's name and the passphrase, which it never
  echoes, stores or logs, to the principal service, which passes the
  passphrase to the vault. A principal that has not enrolled sets its
  first passphrase here, at the UART only
  ([design-system.md](design-system.md#the-vault)). The vault opens
  one of the principal's credential slots with it and gives one of four
  answers: matched; did not match; limited, once a name, a principal's
  or not, has had 5 failures in 60 s from local terminals (the UART and
  the host link), 5 from terminal windows or 5 from network connections,
  each class counted apart so that a display domain typing wrong
  passphrases cannot lock a name out at the UART, or a line has had 5;
  or unavailable, when the vault's partition or its sealing backend
  fails, or for an enrolment or a passphrase change on a trial boot,
  which the console reports as such
  ([design-system.md](design-system.md#the-vault)). On a match the
  domain service starts the principal's session domain
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas)),
  and the console connects that session's tty at the line. A login at a
  terminal window is never presence at the machine: it cannot enrol a
  principal or open a slot made under another sealing backend
  ([design-system.md](design-system.md#the-vault)). In a development
  build the console logs `root` in at the UART at boot and at the host
  link's `console` line when the host opens it, each a login at a secure
  line (**Secure lines**, above), so their first prompt is the command
  shell's and the system shell is one `erl` away from it; a display's
  windows log no one in on their own, in any build.
* **Windows without a login.** A terminal window opened from a session
  shows that session's shell with no login, by a window token the console
  minted for that session's own request ([Window tokens](#window-tokens)).
* **The system shell.** An Erlang shell whose group and evaluator run in
  the system domain (`group:start/3`, `lib/kernel/src/group.erl:120`)
  starts only under the **system-shell facet**, and the facet belongs to
  a login at a secure line, never to a session. When a principal the
  manifest names logs in at a secure line (in a development build
  `root`, and in a release build by default nobody), the console grants
  the facet to that login, holds it, and lends it only to the system
  shell it starts at that line and to that shell's `/proc` tree, whose
  calls present it to the inspector
  for the records shown to the system shell alone; no session domain,
  terminal relay or session's facet table ever holds it. The system shell's tty
  lives in `erx_console` and is connected at that line alone, and its
  menu entry appears in no other line's menu. The facet and the system
  shell end with the login: at a lock, a log out, or the line's drop; the
  next login at a secure line grants a new one (V6). No session holds the
  facet, so whatever route reaches a session reaches the session's own
  domain and no system-shell authority ([Window tokens](#window-tokens)).
  Expressions typed in the system shell run with
  the system domain's authority, so the facet is as strong as the
  install facet, and the records shown only to the system shell, the
  crash record among them, are shown nowhere else.
* **Shells in other domains.** `erx:attach(Domain)` asks the domain's
  console facet to start a group with the standard shell inside that
  domain, over a tty in that domain. The shell, its evaluator and its line
  editing run in the target domain with that domain's authority; between
  the domains travel only the tty's bytes, its size and a hang-up, as frames
  on the domain's connection to the system domain ([The tty](#the-tty)), and
  the console reads none of them. A user's login shell is such a session.
  A caller attaches to a domain whose console facet it holds, as a
  principal's sessions hold those of the principal's own domains, so
  `erx:attach` reaches a principal's own sessions, as `screen -r` and
  `tmux attach` do on UNIX, and gives the shell that domain's authority,
  never the system shell's.
* **Logs.** Every log event of a runtime ends at one sink. The `default`
  handler of `kernel`'s logger in every domain is `erx_log_h`, whose process in
  a domain other than the system domain is the domain's logger proxy. It formats
  each event inside the domain, on one line, so the system domain never formats
  another domain's format string, and sends it as a log record,
  `{log, Level, Text}` with `Text` a binary of at most 4 KiB: to the domain's
  console facet, and in the system domain to `erx_console` directly. Two stock
  handlers remain:
  * `logger_simple_h`, which holds and prints a runtime's log events until
    `erx_log_h` is added, displays them with `erlang:display_string/2`
    (`logger_simple_h.erl:179`, `:230`). Edit 43 makes it build each event's
    text on one line and print `erx_text:escape_line/1` of it and a CR-LF in one
    call, so a boot's early log is attributed text at its display like any other.
  * `logger_std_h`, which writes to `user` and falls back to `standard_error`
    (`logger_std_h.erl:680`), is in no domain's default configuration. Given a
    file, it writes data; given a standard device by a principal in that
    principal's own domain, it writes that domain's own output to that domain's
    own tty, under no other name. The system release's configuration names it on
    no standard device, which the release check confirms.

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

#### Window tokens

A terminal window carries its principal's authority, as any UNIX
terminal does. A window opened without a login has the authority of the
session that asked for it, which is its principal's, so the window
reaches that principal's sessions as a login there would, and
`erx:attach` from it reaches them as `screen -r` and `tmux attach` do.
Which routes lead into a principal's own sessions is therefore no
security question, and nothing lists them. Three properties hold by
construction instead:

* **The system shell needs a login at a secure line.** The system-shell
  facet is granted to a login, held by the console and lent only to the
  system shell at that login's line (**The system shell**, above). A
  window token is not a login, so the window it opens never carries the
  system shell, whatever its line's `secure` attribute, and no session
  holds the facet, so nothing a session reaches starts one.
* **Physical presence means the UART.** Only a login at the UART is
  presence at the machine; a token window is not a login at all, and a
  login at a window enrols no principal and opens no slot made under
  another sealing backend ([design-system.md](design-system.md#the-vault)).
* **A line gets a principal without a login only from a token minted
  for a session's own request**, and every shell at it is then that
  principal's. Which session a window serves is the console's choice,
  never the display's.

**The one path to a token.** The console mints a window token only in
`new_window`, for the session that calls it. `new_window` is offered on
one facet alone, the console facet that the domain service gives a
session domain when it creates it; the console takes the session from
that facet and refuses the call from every other holder, itself among
them. The line's menu item **New terminal window** asks the terminal
relay of the session connected at the line to make that call on its
session's facet, so the session is the one caller, and the overlapping policy's "new terminal
window" item ([design-display.md](design-display.md#terminal-windows)) is
that menu action at the line of the window that has the keyboard, as if
`Ctrl-G` and the item had been typed there, which the display can already
do. A line whose terminal is the system shell, or which shows the menu or
a login, has no session connected, so a window asked for from it shows a
login. The request names the display, one the session is introduced to,
and from a window's menu that window's display.

**The token.** A window token is 128 random bits bound to the session and
to the display's `offer_line` facet. The console sends it to that display,
whose `erx_term` makes the window and presents the token with its
`offer_line` ([design-display.md](design-display.md#terminal-windows)). A
session has at most 4 live tokens, and a further request is refused. The
console consumes a token at its first presentation; it also dies unused
when its session ends or 60 s after it was minted, and the console logs
no token. The console keys every line by the `offer_line` facet that
offered it, so a display names only its own lines.

**What a token opens.** A valid token connects at the new line a tty that
the session's terminal relay makes, with a new shell of the session on
it, and records the session's principal as the line's principal (V7),
with no system-shell facet. The line then works as any line of that principal:
its menu reaches the principal's sessions, Lock shows the login with the
principal's name, and Log out ends the sessions started at that line and
the window's shell and tty, not the session that asked. One rule ends
the line's principal: it lasts until a lock or a log out at that line,
a log out at the line the window was opened from, which ends the
window's shell, or the end of the session that asked, whichever comes
first. The console knows the opener line only from its own record of
the menu action it handed to the relay, never from the session; a
window the session's own code asked for has no opener line. Then the
line drops to a login with its record cleared, and a session the
operator connected or started there from the menu is detached, not
ended. Once a principal logs in again at that line, it is a login line
like any other, and neither the asking session nor the opener line
ends it any more. "Opened from" names one line only: a window opened from a
window depends on its own opener's line and session, not on a chain. An
offer with no token, or with one that is unknown, used, expired
or bound to another display, gets a login and never a shell, so a window
that the display offers on its own, its first one and the single policy's
service terminal
([design-display.md](design-display.md#windows-and-the-window-system))
among them, shows a login.

**The display's bound.** A compromised display domain has the authority
of the shells in its windows, as an X11 or Wayland server does: it types
into them, and through them reaches what their principals reach, their
other sessions included. It has as well what every window system has:
it routes the input of the windows of the sessions introduced to it,
reads and writes its display's clipboard where `snarf` is on, and records the passphrase of every principal
who logs in at its windows, which it can type at a login again. It has
nothing beyond: no system shell, which a release build connects at no
window and a token window never carries; no presence; and nothing of a
principal that neither uses the display nor types at it, since it
cannot choose a token's session. A lock at the UART leaves the windows
opened from it running, as on UNIX, so their shells stay in that
authority until they are locked or logged out too.

**The line cap.** A display holds at most the number of lines its
`console_line` parameter allows, 16 by default, and an offer beyond it is
refused, so a display cannot make the console keep unbounded state.
The cap does not bound failed logins: a display that closes a line and
offers a fresh one escapes the per-line limit, and what bounds its
guesses is the vault's per-name count in the terminal windows' class. The cap is
shared by every principal whose sessions use the display, so one
principal's windows can fill it and leave another's requests without a
line; that is a recorded residual ([TODO.md](../TODO.md)).

**Tests.** A display's offers with no token, a forged one, a used one, an
expired one and another display's each get a login, where a seeded
console that accepts any token fails; `new_window` on a domain's console
facet that is not a session domain's, and from a holder other than that
session domain, is refused; the menu of a window opened from a session
lists that principal's sessions and no other principal's and no system
shell; `erx:attach` from that window of the UART login's session gives
that session's shell without the system-shell facet, so
`erx:inspect([kernel, crash], #{})` there answers `{error, scope}`; a
token window at a line a development manifest marks secure gets no
system shell; the overlapping policy's item yields a window with the
shell of the session connected at the keyboard's line, and a login where
none is; a window whose session ends shows a login, and a session the
operator connected there from the menu is detached and runs on; a lock at the UART
leaves a window opened from it running its shell, and a log out at the
UART ends the session and drops that window to a login; a window opened
from a token window drops to a login at a log out there while its asking
session runs on; a session's fifth
live token request is refused, and a token dies unused after 60 s and at
its session's end.

### Attributed text

Text is UTF-8 wherever it flows: Erlang strings and binaries, text files,
the terminal and every protocol. Data in files, in pipes and in records
stays exact, and a program's output reaches its tty exact. Only
**attributed text**, text shown under the name of its source, is escaped,
by whatever displays it, as `ls` escapes odd file names: a name a domain
chose or a log line a domain wrote must not pass for something else.
`/proc` is the one producer of files that escapes: what it writes is
inspector output, which `cat` shows as the bytes of a file, so it writes
its reporters' text already escaped, by the field escape below.

* `erx_console` escapes domain records and the names in its menu and its
  login prompt.
* `logger_simple_h` escapes each record it prints before the sink exists
  ([The console](#the-console)).
* `erx_render` escapes inspection records and the shell's records at a
  terminal. The one record it writes as its bytes is a line of data, a
  line a command read as bytes, which is its writer's output, not
  labelled text, and reaches the terminal as through `cat`. Toward a
  file or a pipe it writes its reversible framing instead
  ([Pipelines](design-shell.md#pipelines)), and what it writes there is
  data from then on, as FreeBSD's `ls > f` writes names unescaped: `cat f`
  shows a name a domain chose as its bytes.
* The host tool's printer escapes everything it prints from the guest:
  `inspect`, `source`, `trace`, the events stream and any guest bytes it
  quotes in a diagnostic. The one thing it does not escape is the terminal
  stream of `erx console`, which is a tty's output and which it copies to
  its standard output with the host's terminal raw, as `ssh` does.
* The kernel's log escapes every record on entry, writing every byte
  outside printable ASCII in text it did not write as `\xNN`, since it
  carries no Unicode table
  ([design-kernel.md](design-kernel.md#console-log-and-panic)).
* `erx_procfs` writes every field of a `/proc` file through the field
  escape ([The /proc tree](#the-proc-tree)).

The **line escape**, `erx_text:escape_line/1` and its Ruby twin, renders
these visibly, from the generated tables:

* a character of general category `Cc` (the C0 controls, tab and newline
  among them, DEL and the C1 controls U+0080 to U+009F, among them U+009B,
  which some terminals take as CSI), `Cf` (format characters: the
  bidirectional overrides and isolates U+202A to U+202E and U+2066 to
  U+2069, the zero-width characters, U+FEFF and the rest), `Zl` or `Zp`
  (the line and paragraph separators), or `Cn` (unassigned in that
  version), or with the property `Default_Ignorable_Code_Point`, which adds
  invisible characters outside `Cf` such as U+115F, U+3164, U+034F and the
  variation selectors; except the four that legible text needs, U+200C and
  U+200D (zero-width non-joiner and joiner, for Persian and emoji sequences)
  and U+FE0E and U+FE0F (text and emoji presentation);
* a byte that does not begin or continue a valid, shortest UTF-8 sequence,
  an overlong form or an encoded surrogate included, and a surrogate code
  point in an Erlang character list.

A character is written as `<U+` and four to six upper-case hexadecimal
digits and `>`, such as `<U+202E>`; a byte as `<0x` and two such digits
and `>`, such as `<0xC0>`. Every other character passes unchanged, the
backslash and `<` among them. Tokens are for the eye only: the data they
render keeps its bytes, and a token is not an injective encoding, since
text holding the eight characters `<U+202E>` looks like text that held
U+202E. The line escape is not the framing toward bytes, which writes
only tab, newline and backslash as `\t`, `\n` and `\\` so that a record
stays one line and changes nothing else
([Pipelines](design-shell.md#pipelines)); a value written toward bytes is
framed, and a value written to a terminal is escaped instead. The escape
takes whole text, since a record is whole when it is displayed, and holds
no state between calls. One record is one line under its source's name.

The **field escape**, `erx_text:escape_field/1`, is how `/proc` writes
attributed text into a file. It is the framing toward bytes with the line
escape's classes added: tab, newline and backslash become `\t`, `\n` and
`\\`, every byte of a character the line escape renders and every byte the
line escape writes as a byte token become `\x` and two upper-case
hexadecimal digits, such as `\xE2\x80\xAE` for U+202E and `\xC0` for a
stray `0xC0`, and everything else passes unchanged. Text without those
classes is written as the framing writes it. Because the backslash is
always doubled and `\x` never stands for a tab, a newline or a backslash,
the field escape is injective: `erx_text:unescape_field/1` recovers the
exact bytes and refuses text the field escape does not write, either a
backslash that starts no escape or a form the escape writes differently,
such as a raw tab or `\x41`. What it writes holds no character the line
escape changes, so a display that escapes it again shows it as it is.

**Secrets.** A term `{erx_secret, Text}`, the form in which a widget's
secret input reaches its application
([design-display.md](design-display.md#widget-trees)), prints as
`[secret]` in `erx_render`, in the trace relay's rendering of trace
messages and in `erx_log_h`'s formatter, wherever it is nested, so its text
reaches no screen, log line or trace record through them.

The escape keeps what a display says about a source honest. It does not make
a shared screen trustworthy: a program on the same terminal can print a line
that looks like a log line, as on UNIX, and the inspector and the host link's
events stream show the record itself. Each class has a test at each display,
and each escaper has a fuzz target. Implicit bidirectional reordering, by
which strong right-to-left letters move the neutral characters around them,
is not escaped: a residual risk.

### The command shell

Each session can run a command shell with rc's language beside its
Erlang shell, both listed in the same `Ctrl-G` menu; the console starts
the command shell first, and the shell's `erl` runs the Erlang shell above
it; its language, commands, pipelines
of records, jobs and terminal relay are
[design-shell.md](design-shell.md). It runs on the session's tty above,
and its Erlang commands reach the inspector, `/proc` and the code store
below with the session's facets. Its `ps` lists the session's own process
table: its Erlang processes and its programs, the latter from the
session's port table, so a session sees its programs without an inspect
facet, as a UNIX user sees their own processes.

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
a list of domains. A session's inspect facet has scope over its
principal's own domains, with one exception: in a development build
`root`'s session holds one of scope `all`, as the host link does
([The host link](#the-host-link)). In a release build no session's facet
has scope `all`, and machine-wide inspection is done in the system shell
at a secure line. A path's owner is decided by construction: a process's
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
every value's reporter, and below the table the scope of each stopgap
reporter it names.

### The /proc tree

`/proc` is the inspector's path namespace as a read-only file tree, served
by `erx_procfs`, an `erx_fs` server that the system domain starts for each
holder of an inspect facet, with that facet's scope
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)). A
domain mounts it at `/proc`, and a session's handler mounts it for a
program the session gives it to, so `cat`, `ls` and `grep` read live
state. The tree is a view of the inspector's tree and decides nothing
itself: a read of a file is the inspector's query for the file's path
through the facet the tree serves, rendered as text, and a path that
answers `{error, scope}` reads as `enoent`, so the tree grants nothing
that `erx:i/1` with the same facet does not, and each record has one gate
for both forms by construction. Each `erx_procfs` is linked to the facet it serves, so revoking the
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
  `/proc/kernel/crash` is `[kernel, crash]`, the last reset's crash
  record, rendered as a file: it answers only where that query does, in
  the system shell's tree, and reads as `enoent` in every other tree.
  The console starts the system shell's tree with that shell, over the
  system domain's inspect facet and presenting the system-shell facet it
  lends the shell; the tree is mounted only in the system shell's
  namespace, is never given to a program, and ends with the login; the kernel's trace
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
  value and its reporter, a stopgap reporter by its label, separated by
  tabs. A value prints through
  `erx_render`, as in records ([Pipelines](design-shell.md#pipelines)): an
  `ok` value bare and every other value as its status, `[unknown]`,
  `[partial]`, `[unsupported]`, `[timeout 500]` or `[error]`, so a file
  never fabricates (V2). A file of `/proc` is inspector output, text its
  reporters chose: every field of a `status` file, and every line of a
  `source`, `crash` or `log` file, is written through the field escape
  ([Attributed text](#attributed-text)), so each line is one attribute,
  no byte a domain chose reaches a reader as a control, and `cat` shows
  the file at a terminal as it shows any file. The field escape is
  injective, so a program that reads the file can recover each value's
  exact bytes with `erx_text:unescape_field/1` or its rules: the bytes
  the reporter gave, so a line of `/proc/kernel/log`, which the kernel
  log already escaped, shows each of its backslashes doubled. Only
  `/proc`'s generated content is escaped: `cat`, pipes and files still
  pass their bytes unchanged.
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
  it with `erx_trace_read`. A park or a wake has one source, the layer
  that carries it out: the kernel's ring, or on the stopgap the backend's
  ([design-stopgap.md](design-stopgap.md#the-trace-ring)). The runtime
  adapter adds to ERTS's trace only what it alone sees: capacity changes,
  yield requests honoured, refusals, connection closes and unheld frames
  ([design-runtime.md](design-runtime.md#failure-handling-diagnostics-and-debuggability)).
* **One timeline.** `erx:trace(Spec)` starts any mix of the three and
  prints one stream ordered by `erx_clock_ns`; the trace facet sends the
  merged stream to the process that started the trace, the shell's printer
  for `erx:trace/1` and a view's process for the web
  ([design-web.md](design-web.md#views-on-the-line)), and ends a trace whose
  receiving process ends; it streams the
  same events to the host as casts on the host link's events stream, where
  `tools/erx trace` renders them with pids and domain names resolved. The
  merger holds each event until every source has shown a later time, a
  source with nothing new counting the time of its last read, or until the
  event is 100 ms old, whichever comes first, so a source that stops
  answering delays the stream by at most 100 ms and holds at most 100 ms
  of the others' events; an event that arrives after later ones went out
  is printed at once, marked `late`, never dropped. The merger does not
  wait for a row whose call answered `ERX_ENOTSUP`.
* **Scope.** A trace facet has a scope, as an inspect facet does. A scoped
  trace facet traces only the processes and programs of its domains,
  through each domain's own runtime, and only the frames those domains
  receive; the kernel trace ring needs a trace facet of scope `all`.

**The request.** `Spec` is a map; a key left out takes its default:

```erlang
-type spec() :: #{select => [pid() | domain_id()],  % at most 16; default []
                  frames => boolean(),              % default false
                  kernel => boolean()}.             % default false
-type domain_id() :: 0..16#ffffffff.
```

A pid traces that process and a domain id every process of the domain,
each through OTP's trace session in its own runtime, with the flags
`running` and `monotonic_timestamp`. `frames` adds the frames received by
the selected domains and by the domains of the selected pids. `kernel`
adds the `backend` and `kernel` rows below, unfiltered by `select`, so
both need scope `all`. `erx:trace/1` returns
`{error, badarg}` for anything but such a map, an unknown key, more than
16 selections, no selection with `kernel` false, or `frames` with no
selection; `{error, no_facet}` without a trace facet; and `{error, scope}`
for a selection outside the facet's scope, an unknown domain id included,
so the answer does not tell which domains exist, or for `kernel` without
scope `all`.

**Rows.** Each event belongs to a row, named by its source, and carries
the reporter its collector assigns ([Inspection
records](#inspection-records)):

| Row | Reporter | On erXos's kernel | On the stopgap |
| --- | --- | --- | --- |
| `erts` | `runtime`, the system domain's included | OTP's trace events of the selection, its frames, and the adapter's events | OTP's `in` and `out` events of the selection; no frames, since the stopgap offers no lanes |
| `backend` | `{stopgap, liberx_trace}`, labelled `liberx trace` | none: `erx_backend_trace_read` answers `ERX_ENOTSUP` and the row is left out | the root's ring ([design-stopgap.md](design-stopgap.md#the-trace-ring)) |
| `kernel` | `kernel` | each CPU's ring, read with `erx_trace_read` | one `unsupported` line, from `erx_trace_read`'s `ERX_ENOTSUP` |

A row whose call answers `ERX_ENOTSUP` is shown as `unsupported` when
its reporter is `kernel`, and left out when its reporter is a stopgap's,
since a stand-in that does not run reports nothing. On the stopgap the
adapter emits none of its own events: what causes them, a grant that
changes, a yield request or a lane, is a kernel mechanism the stopgap does
not offer. The BIF `erx_trace_ring:read(Source, Cursor, Max)`, with
`Source` either `backend` or `{kernel, Cpu}`, `Cursor` either `present` or
a 64-bit cursor and `Max` from 1 to 512, makes the call of its row and
returns `{ok, Records, Next, Overwritten}`, each record a tuple of the
`erx_trace_record` fields after `seq`, or `{error, unsupported}` for
`ERX_ENOTSUP` and `{error, Status}` for any other refusal; an argument
outside those ranges raises `badarg`, and only the system domain's calls
succeed. `present` starts at the ring's next index, so `erx_tracer` starts
every ring there and counts as overwritten only records lost after the
trace began. It reads each ring of a trace whose `Spec` sets `kernel`
every 10 ms, and again at once after a read that returned `Max` records. A generated table
names each event and its arguments from `enum trace_event`, and a value
the table does not hold is shown as `{unknown, Value}`.

**Clocks.** Ring records carry `erx_clock_ns`, and so does the stream. An
OTP timestamp is `erlang:monotonic_time(nanosecond)`, which ERTS derives
from `erx_clock_ns`
(`otp/erts/emulator/sys/erxos/sys_time.c:77-80`) through its time
correction, which slews it but does not step it. Each runtime converts its own events
before they leave it: the BIF `erx_trace_ring:clocks/0` reads its Erlang
monotonic time and `erx_clock_ns` back to back in C, and the relay, or in
the system domain `erx_tracer`, adds their difference to every timestamp
of a batch, taking the pair again for each batch. While the wall clock
is not set the difference is constant, since the time supervisor finds
nothing to correct (the same file's header comment); after
`erx_time_set_wall` ERTS's correction may slew it, by at most 1 % in
stock OTP, so an event's time is off by at most 1 % of its distance from
its batch's pair.

**The stream.** Each entry reaches the receiving process as
`{erx_trace, Ref, entry()}`:

```erlang
-type entry() :: #{time := non_neg_integer(),         % erx_clock_ns
                   row := erts | backend | kernel,
                   event := atom() | {unknown, non_neg_integer()},
                   fields := #{atom() => term()},
                   reporter := reporter(),             % as in record()
                   late := boolean()}.
```

An `erts` event is OTP's message tag, with the pid, the domain and the
message's other elements as fields (`in` and `out` carry `mfa`). A
ring event is its `trace_event` name, with `cpu` (an integer, or
`unknown` when the record sets `cpu_unknown`), `thread`, `space` and its
named arguments as fields. Two events report on
a row itself: `unsupported`, with no fields, once at the trace's start
for a row shown as unsupported, and `overwritten`, with
`count`, for records a ring lost before they were read. The shell's
printer writes one line per entry, the time in seconds, the row, the
event, each field as `name=value` and the reporter's label in brackets,
with `late` after a late one:

```
   40.993000112 kernel unsupported [kernel]
   41.207113520 backend irq_deliver label=1 cpu=unknown thread=6 space=1 [liberx trace]
   41.207119044 backend wake slot=2 result=ok cpu=unknown thread=4 space=1 [liberx trace]
   41.207131870 erts in pid=<0.91.0> domain=4 mfa=timer:sleep/1 [runtime]
```

It builds the whole line and prints `erx_text:escape_line/1` of it, so no
field, a rendered atom from a traced domain included, can end the line or
carry a control character.

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
files can on UNIX. No specification of the system manifest is
exposed to it, since their overlays are never persisted, and the system
domain's installs are never persisted at all.

### The host link

The host link connects `tools/erx` to `erx_hostlink` over the second UART,
which belongs to the system domain on every platform and is served there
by a driver like the console's, beside `erx_hostlink`; the system
manifest names the UART by its device-tree path; under QEMU it is a UNIX
socket
(`-serial unix:build/qemu/RUN/hostlink.sock,server=on,wait=off` after the
console's `-serial`, in the run's owner-only directory).

The transport has one trusted physical or local peer. The harness creates
its UNIX socket in an owner-only directory with access restricted to that
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
  credit frames from `erx_hostlink` as it consumes input. A credit frame's
  `target` is the total the target has granted in the session, modulo
  2^32, so a later grant makes up for one lost with a damaged frame. The
  target counts every byte it reads from the link, a read's bytes before
  the frames they hold, from the read after the one that held the hello
  that opened the session; it grants once 4 KiB are owed, and grants what
  is owed, or repeats its last grant, whenever the link's input goes
  idle, so a host short of credit for a frame is never left waiting. The
  tool counts every byte it sends from its hello's first byte, and sends
  nothing between its hello and the reply but repeats of the hello, so
  the target never grants a byte the tool has not sent and grants less
  only by the hello and what was read with it. Those bytes must stay well
  under the 8,083 by which the initial credit exceeds the largest frame
  and its zero, so the tool repeats a hello only after waiting for its
  reply, never many times into one read. The tool takes a
  grant that adds more than it has sent and not yet had granted as stale
  and ignores it.
* **Streams.** The control stream carries calls, replies and casts; the
  terminal stream carries a console session's tty, raw in both directions;
  the events stream carries log lines and trace records;
  the files stream carries 9P2000.L messages
  ([Files between the host and the machine](#files-between-the-host-and-the-machine)).
  A crash dump is read as an inspection path, `[domains, Id, crash]` or
  `[kernel, crash]`, and the tool stores it as a file and never renders it
  raw; `[kernel, crash]` answers the host link's `inspect` facet
  `{error, scope}`, since only the system shell presents the system-shell
  facet, and the operator reads that record in the system shell at the
  host link's `console` line.
* **Sessions.** The tool opens a session with `{hello, Nonce}` in frames
  whose session is all zero, with `Nonce` a fresh 16-byte binary from the
  host's random source; the hello is a call to the root. The target
  replies `{hello, Nonce, SessionId, Build, Versions}`: that nonce, an
  independently generated nonzero 128-bit session identifier, its build
  identifier and format versions. The tool matches the nonce and refuses
  another build; the target closes the preceding session and its facets.
  A hello with the current session's nonce, sent again because its reply
  was lost or repeated on the link, gets that session's reply again and
  replaces nothing, so frames the tool sent under the first reply still
  reach the session; a hello with any other nonce replaces it. Identifiers are
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
  once its holder ends, `console`, and `web`, the web domain's relay for
  `tools/erx web` ([design-web.md](design-web.md#the-host-tools-front-end)),
  which development builds alone offer and a release manifest that lists
  it fails the manifest check; in release builds what the system
  manifest lists, by default nothing, and `console` there starts a login,
  as the serial console does. A `domain` facet carries
  `erx_domain`'s operations on one domain: stop it, and read its death
  record.
  * A session holds at most 1,024 facets; opening one more fails with
    `{error, system_limit}`. A facet's number is never reused within a
    session, so a number the host kept names nothing once its facet is
    closed, and a call to a number the table does not hold is answered
    `{error, noproc}`.
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
  target payloads with its own bounded decoder of the same grammar,
  `tools/lib/erx/etf.rb`, and prints them through the line escape: to the
  host, the target is untrusted too. The tool's decoder takes at most
  16 MiB of bytes and 16 MiB decoded, by an estimate of ERTS's heap words;
  refuses bytes after the term; decodes atoms to values of its own, never
  to Ruby symbols; finds repeated map keys by a digest of each key built
  as it is decoded, never by Ruby's recursive hashing; and refuses a term
  inside more than 1,024 containers in any position, the funnel's free
  tail positions included (a list continued by list tails is one list):
  its values are Ruby's, whose recursive comparison and printing overflow
  the main thread's stack a few thousand levels down. Its encoder holds
  the tool's own calls to the byte and depth bounds; the target checks
  their decoded size.

  In Phase 1, until `erx_etf`'s check exists, the implementation behind
  this check is `erx_hostlink_payload`: a payload passes when it is at
  most 16 MiB, is not in ETF's compressed form, decodes with
  `binary_to_term/2` in safe mode with no bytes after the term, and holds
  no pid, reference, port or fun; its decoded size, for the resident
  limit, is the decoded term's flat size plus the payload's own bytes,
  which bound its binaries' bytes. Safe mode creates no atom and no
  external fun, but the term is built on the heap before its size is
  known, up to about sixteen times the payload's bytes.
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
release builds the trees the system manifest lists, by default none. The
bridge tells the two apart by the system manifest's development flag,
which the image build checks against the kind of build it makes, so one
source decides; a manifest it cannot read lists none. An `attach` naming
another tree fails with `enoent`. On the host, `tools/erx
files` relays a UNIX socket in the harness's owner-only directory to the
files stream, checking each message's size field against the stream's
`msize` and nothing more, so any 9P2000.L client of the host mounts the
socket and parses the target's bytes as it parses any server's.

The bridge renames the host's fids to fids it holds itself, on the grant
of each fid's tree, so it owns every fid of the 9P session and its end
clunks them all ([design-files.md](design-files.md#fid-owners)). It
answers some messages without a grant: `version`, with the smaller
`msize`; anything but `version` before a session is open, and an
`attach` whose `Afid` is not `NOFID`, with `einval`; `auth` with
`enotsup`; a request on a fid it does not hold with `ebadf`; one that
names fids of two trees with `exdev`. It holds at most 256 fids, as many
as a session's program holds on a grant
([design-files.md](design-files.md#bounds)), and a fid beyond them fails
with `emfile`. It keeps at most 32 requests pending and at most 64
messages at its grants or held, a pending request counting twice until a
flush of it is in use, so that it always keeps room to flush every request
it sent; a request beyond 32 fails with `emfile`, and a message beyond 64,
or on a tag in use, is discarded and counted. The grants are the system
domain's own, shared with its processes, and a grant's 64 requests in
flight cannot be reserved, so a flush the bridge sends may still be
refused there, and it then waits behind its request. The flushes of one
request are answered in the order they came, after the request is
answered or abandoned, with at most one of them at the grant at a time,
and a flush of a flush joins the flushes of the request it names, so the
host never reuses a tag while an answer on it may still come. A `version`
resets the session whatever tags are in use. What the grants still hold
drains, and each forgotten request with no flush at its grant is flushed,
so a grant that abandons a request at a flush lets one that waits there,
a `lock`, go; what drains counts against both bounds until its grant
answers it. It cuts a `read`'s or
`readdir`'s `Count` to what an `Rread` of the session's `msize` holds
and answers `lopen`'s and `lcreate`'s `Iounit` as `msize` less 24, so
every reply fits a frame.

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
| `erx:i() -> ok` | the machine at a glance, through the caller's inspect facet: the machine's record, the root of every path, then each CPU, the caller's domain's group, budget and threads, and the processes, threads and processes a row each, every value with its reporter, within 80 columns |
| `erx:i(Path) -> ok \| {error, scope \| unsupported}` | renders the record for `Path` in the shell, through the caller's inspect facet, every value with its reporter; `scope` for a path outside the facet's scope or one that names nothing |
| `erx:domains() -> ok` | lists every domain the caller's inspect facet covers: id, name, principal, state, memory, CPU time and process count, each value marked with its reporter |
| `erx:ps() -> ok` | lists every process of every domain the caller's inspect facet covers, by domain, and under a session its programs: pid or program number, registered name or program name, current function, reductions, memory and queue length, each marked with its reporter; the `ps` command emits the same fields as records |
| `erx:inspect(Path, Options) -> {ok, record()} \| {error, Reason}` | `Options` holds `offset`, `limit` and `timeout`; `Reason` includes `scope` and `no_facet` |
| `erx:source(Pid \| {module(), atom(), arity()}) -> ok \| {error, Reason}` | prints the source lines around a process's current location or a function's first line; `{error, unsupported}` when the module's release carries no source |
| `erx:trace(Spec) -> {ok, reference()} \| {error, Reason}` | starts a trace of processes, frames or kernel events, `Spec` as in [Tracing](#tracing), that prints in the shell; `Reason` is `badarg`, `no_facet` or `scope`; `erx:trace_stop(Ref)` ends it |
| `erx:attach(Domain) -> ok \| {error, Reason}` | a console session with a shell inside `Domain`, through its console facet, which the caller holds for its own principal's domains; the shell has that domain's authority, never the system shell's ([Window tokens](#window-tokens)) |
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

`tools/erx console | load | watch | inspect | source | trace | files | web`;
`web` serves the web client to a browser on the host and relays it over
the `web` facet ([design-web.md](design-web.md#the-host-tools-front-end));
`files` relays a UNIX socket to the host link's files stream
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
escape rules, which are generated with each build and checked by build
identifier. One build produces every component of a boot; the host tool
checks the build identifier in the root's `hello` reply and refuses a
target from another build. The console relies on `prim_tty` and on the
protocol between `group` and its driver, both internal to OTP; erXos owns
its OTP tree, so they change only when erXos changes them, and any such
change reruns the console tests first.

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
| `erx_console` crashes | its supervisor | each session's group survives in its own process | the console restarts with every line showing a login: a restart ends every login, the system shell and its facet, every window's binding to a session and every unused window token, and the sessions run on, reachable by a login |
| The system domain faults, or halts outside an ordered shutdown | the kernel, through the fault gate or the watchdog ([design-kernel.md](design-kernel.md#the-root-task)) | nothing of the running system: every domain ends with the system domain's space; the kernel writes a crash record where the platform keeps one across a warm reset | the machine ends by `erx.panic`, which in a release build resets it and boots the committed slot; the console shows the boot banner, and `[kernel, crash]` and `/proc/kernel/crash` show the record to the system shell; the host tool's session ends and reconnects after the boot |
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
limits, on every console line, a menu that reaches only the line's
principal's sessions, V7, and the system shell
only for a login at a secure line, V6; a display domain, which sees and
can inject its windows' bytes, is an untrusted provider of lines, whose
windows open without a login only by a window token minted for a
session's own request, and which has the authority of the shells in its
windows and nothing beyond ([Window tokens](#window-tokens)), and the console
never logs a passphrase or a token); console
sessions in other domains (only a tty's bytes, its size and a hang-up
cross, and the console copies the bytes without reading them; the shell
runs with the target domain's authority, never the system domain's); the command
shell and its programs ([design-shell.md](design-shell.md#security)); the
`/proc` trees (one server per inspect facet, scope decided from the path
and the facets the server presents alone, names encoded injectively, snapshots bounded per grant); the code
store (blobs checked by hash before any loader reads them, each
principal's hot store written only by the code service, overlays and
stores read back from the data partition through a bounded, fuzzed
decoder); the inspector's scopes (owners from pids and kernel records,
never from domain reports); runtime reports (validated by the system
domain's funnel, then decoded in safe mode, with another domain's pids
dropped); and the host tool's decoder (bounded, same grammar, generated
line escape).

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
them. In development builds the host link holds every facet but the
system-shell facet, `install` among them, and `root`'s logins at the UART and at the host link's
`console` line and at a window the manifest marks secure hold the
system-shell facet, which makes each as powerful as the system domain,
and every `root` session inspects at scope `all`, wherever it logged in,
the web included. Hot-loaded code in a
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
text is not escaped ([Attributed text](#attributed-text)).

**A program can drive the terminal.** This is accepted, as on UNIX and over
`ssh`. A program on a tty, in whatever domain, can send the operator's
terminal any control sequence: it can draw anything, a fake prompt or a line
that looks like a log line included; set a window title; write the clipboard
with OSC 52 where the terminal allows it; make the terminal answer with a
report that arrives as input to whoever reads the tty; and leave the terminal
in a state the next program inherits. How far that reaches is the terminal's
own business, and `cat -v` shows output the operator does not trust. A
program cannot read what is typed outside its own connected tty, and `Ctrl-G`
always reaches the real menu, during which it can write nothing.

## Verification and testing

The inspection schema generates valid-input builders, boundary mutations
and fuzz entry points for the production validators. Independent fixtures
exercise every status/reporter combination, unauthorized paths and fields,
unknown keys without atom creation, and hostile names in every projection.
They check that rendering never turns missing data into success and that a
development-only field never reaches a release projection. The generated
reference tables and field projections are covered by the drift check.

* **Exact output:** the test of V1, on the console and on the host tool's
  `console` command. A seeded escaping step in `output/3` or in the console's
  copy fails it. `prim_tty` from `init_ssh/3` here and in stock OTP 29.1.2 turns
  the same requests, every printable and control character in `{putc, Binary}`
  among them, into the same bytes; a seeded change to its caret rendering fails
  it.
* **The line discipline:** `erx_tty` explored exhaustively over its flags and
  a small alphabet of bytes, and differentially against a host pseudo-terminal
  with the same `termios`, comparing what a reader gets, what is echoed and
  what the master gets. `ONLCR` applied with `OPOST` clear fails both. Its
  `set/2`, `size/3` and `input/2` have a fuzz target. The exploration also drives
  `read_wait/2`, `timer/2` and `read/3` as events, over each of POSIX's four
  `VMIN` and `VTIME` cases.
* **Cooked and raw:** a program that reads a line in cooked mode, with
  `VERASE` and `VKILL` typed; one that turns off `ECHO` and reads a password
  that is not echoed; one that goes raw, reads single keys and draws; `Ctrl-Z`
  from a program that clears `ICANON` and `ECHO` and keeps `ISIG`, after which
  the shell's prompt works, and `fg`, after which the program's settings are back.
  With the shell's restore removed, the prompt test fails. A program made raw
  with `cfmakeraw` reads `Ctrl-Z` as a byte; with `ISIG` ignored by `input/2`
  in the first case the program is never stopped, and that case fails.
* **Timed reads:** a blocking read with `VMIN` 0 and `VTIME` 1 returns no bytes
  after its timeout with no input, and a `poll` with the same settings reports
  nothing and starts no timer. In the exploration, `read_wait` that starts no
  timer leaves the first test waiting past its deadline, and `poll` that starts
  one fails the second. A cooked line past 4,095 bytes keeps its end and
  drops the rest with a count; with the bound removed the model's state grows
  past its limit.
* **Many writers:** two programs and an Erlang process in their session
  writing numbered records at once: each writer's bytes arrive complete and in
  order, whatever lands between them. With the owner taking the end of a
  write before its start, the test fails. 4 KiB of newlines under `ONLCR` reaches
  the master as 8 KiB in frames of at most 4 KiB; with the room counted before
  `output/3` the console refuses the frame and the test fails. A background job's
  write arrives, and `tcsetattr` with `TOSTOP` fails with `EINVAL` in the first
  tier. A log record written during a flood of program output arrives as one
  whole line, since the driver writes each write whole.
* **The tty's messages:** a seeded master that drops a `{tty_taken, N}` leaves
  the tty going on within 2 s; with the repeat removed, its writers wait past
  the deadline. A resize lost the same way arrives with the repeat. A
  `{tty_size, 24, 0}` leaves the old size and a count, with `size/3`'s check
  removed `prim_tty` fails with `badarith`. Output over 4 KiB, an `N` out of
  order, input over 4 KiB and each message's wrong shape are refused as the
  table says, each with a seeded receiver that skips its check. The messages
  have a fuzz target.
* **A stopped tty:** a session detached by the menu whose program goes on
  writing waits in `write` past 4 KiB, loses nothing and goes on when it is
  connected. With the room reported while the tty holds 4 KiB, the program's
  write returns while detached and the test fails. While it waits, a caught
  `SIGALRM` runs its handler and `write` returns the count taken, or `EINTR`
  with none, and another thread's `exec` goes through; with the wait made a
  request outstanding, both fail by their deadlines. During the menu and a login
  prompt a program's write reaches no byte of the line, and a program's read
  gets no byte typed there.
* **Attributed text:** the test of V9; a domain whose name and log records
  carry control sequences appears in the menu, the log and `erx inspect` with
  each shown as tokens, and with the escape removed from any one of those the
  comparison fails. A test re-derives the classes from OTP's Unicode data, and
  the host tool's source check has a seeded print that skips its printer.
  `erx_text` and the host tool's twin answer one shared file of vectors, at
  least one for each class, and a `/proc` file of a domain whose names hold
  every class shows no raw control under `cat` and unescapes to the names'
  exact bytes. The field escape's fuzz target checks that unescaping
  inverts it over random bytes and refuses what it does not write.
* **Logs:** a domain that floods log records past its rate, sends records
  of other shapes or oversized text, or writes control characters in them
  leaves one escaped line per accepted record under its own id and
  principal, whatever name it chose, and a count of the rest; a program's
  log lines appear under its session's id. A log event with a newline and an
  escape sequence, raised before `erx_log_h` is added, prints through
  `logger_simple_h` as one line with both as tokens; with edit 43 removed, the
  comparison fails. A release check refuses a system configuration that names
  `logger_std_h` on a standard device, and has a seeded violation. The console's
  two decoders of log records, for the kernel's records from `erx_log_read` and for the
  domains' records from their facets, have fuzz targets.
* **Inspection tests:** one per status and per reporter; the collector
  of `erx_object_info` over constructed reports, one per row of its
  table, a partial bit on an attribute with no stopgap, an attribute the
  layout has no field for, a `derived` attribute over a partial input,
  and each kind of refusal, `ERX_ERANGE` ending a listing among them,
  each paired with a
  seed that flips one bit or the status and must change the attribute;
  a host test that every bit of each stopgap backend's `erx_info_partial`
  names an attribute listing a stopgap for `kernel`, failing on a seeded
  bit for `guarantee`; scope tests for
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
  frame received by a domain outside its scope. The merger's pure core,
  in host tests over scripted sources: an `unsupported` row does not hold
  the stream, which a seeded merger that counts it as a source fails by
  holding every event for 100 ms; an `overwritten` count reaches the
  stream, which a seeded merger that drops it fails. The conversion, over
  a scripted clock pair: an OTP event lands at its `erx_clock_ns` time,
  which a seeded sign error fails. The decoder: an event value the table
  does not hold gives `{unknown, Value}` and a set `cpu_unknown` gives
  `cpu=unknown`, which a decoder seeded to name the value `park`, or to
  print the stored CPU, fails. `erx:trace/1` with 17 selections, an
  unknown key, no selection and `kernel` false, `frames` with no
  selection, no trace facet, and `kernel` under a scoped facet, each with
  its refusal, which a seeded check removed fails; an unknown domain id
  and an existing one outside the facet's scope give the same `{error,
  scope}`, which a check seeded to answer `badarg` for the unknown id
  fails. `erx_trace_ring:read/3` with a bignum cursor raises `badarg`,
  which a BIF seeded to truncate it fails. A traced process scheduled in a function whose name holds an
  escape sequence and a newline, whose line shows them escaped, which a
  printer seeded to skip `erx_text:escape_line/1` fails. The stopgap's
  ring and its four-CPU case are in
  [design-stopgap.md](design-stopgap.md#verification).
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
  session in the principal's domain; a principal the manifest does not
  name gets no system shell, and neither does one it names who logs in at
  a line that is not secure (V6); a release build's host-link `console`
  and every terminal window offered without a token start a login; a
  wrong passphrase is refused, and a sixth failure within 60 s is
  answered as limited, per name in each class of terminal and per line,
  and five failures at terminal windows leave the same name's login at
  the UART unlimited; each line's menu shows and reaches only its
  principal's sessions, a locked line reaches none of them
  until the same principal logs in there, a logout ends the sessions
  started there and the terminals opened there without a login, and a
  window opened from a session's menu shows that session's shell with no
  login ([Window tokens](#window-tokens)).
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
  shows the record, in the form the build writes, to the system shell on
  a platform that keeps one and `unsupported` on one that does not, any
  other caller gets `{error, scope}`,
  and the host tool reports its session ended with the
  outcome of its outstanding calls unknown, then reconnects.
* **QEMU transcript tests** for the console prompt, `erx:i/1`,
  `erx:source/1` and a host-side `erx watch` load, under HVF.
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

**Escaping in the data.** The record writer, pipes and files would escape
what they carry. It loses: data would no longer be exact. Escaping where
text is displayed under its source keeps every other path exact. `/proc`
is the exception, because nothing in it is data: everything it writes is
inspector output, so it escapes by the injective field escape, and a
reader that needs the bytes recovers them exactly.

**Rendering `/proc` at the terminal.** `cat` or the shell would recognise a
file of `/proc` and pass it through the line escape. It loses: `cat` writes
a file's bytes and cannot tell where they came from, a native program
reading the file would still pass the bytes on raw, and the shell would
need to know which server a path reaches.

**Filtering program output at the console.** The console would escape what
programs write and pass an allowlist of control sequences, with a mode for
full-screen programs. It loses: it differs from UNIX and QNX, it breaks what
programs may rightly send, and it takes a parser, a table of sequences, a mode
with a reset and a bounded request protocol between domains to do it. The
user's decision is that output functions leave the data alone.

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

* The Open Group, POSIX.1-2024, chapter 11, "General Terminal Interface";
  Linux man-pages, termios(3), https://man7.org/linux/man-pages/man3/termios.3.html
  (read 2026-11-04).
* QNX Neutrino System Architecture, "Device Drivers" and the `io-char`
  library's chapter on character I/O.
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
