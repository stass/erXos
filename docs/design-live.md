# The live machine: shell, inspector, tracing and code from the host

The live machine is what a person sees of erXos: a command shell on the
serial console, with an Erlang shell one `erl` away, from which the whole
machine is reachable as terms; one
inspector that shows kernel objects, domains and the processes of every
domain through a single schema whose every value carries a status and
says who reported it; tracing of processes, of cross-domain frames and of
kernel events; hot code loading, drivers included, from the development
host and from files on the machine; and navigation
from any process to the line of source it is executing. It is the
Genera-like heart of the system, and it is ordinary Erlang code in the
system domain, apart from the host tool, which is Ruby. The architecture is
in [design.md](design.md); the system domain, the root task, in
[design-system.md](design-system.md); domains, connections, exports and facets,
which decide who may see and change what, in
[design-domains.md](design-domains.md); programs as ports of their
session in [design-programs.md](design-programs.md#a-program-is-a-port).

This document owns the tty, which carries a program's bytes unchanged but
for what its `termios` asks ([The tty](#the-tty)); the console, which
carries bytes and logs a person in on release builds
([The console](#the-console)); the escaping of text labelled with its
source ([Attributed text](#attributed-text)); the inspection schema and
its honest statuses ([Inspection records](#inspection-records)), indexed
by the pid space ([Paths](#paths)); `/proc` ([The /proc tree](#the-proc-tree));
tracing; the host link and its session facet table
([The host link](#the-host-link)); code named by its hash, installed
into the system domain only through the install facet and loaded into
other domains through a scoped code facet, by any of three routes
([One load, three routes](#one-load-three-routes),
[The code store](#the-code-store)); and files crossing as 9P2000.L both
ways ([Files between the host and the machine](#files-between-the-host-and-the-machine)).
The command shell's language and commands are
[design-shell.md](design-shell.md)'s. The [Invariants](#invariants) state
each rule with how it is checked.

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
4. Hot code loading, drivers included, into the system domain (with the
   install facet) and into other domains (with a code facet whose scope
   holds them), by three routes that end in one load: from the host over
   the host link, from the host over SSH, and from a file already on the
   machine; code loaded into a supervised domain survives that domain's
   restarts.
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
line editing; remote logins over a network, which are
[design-ssh.md](design-ssh.md)'s, though the host tool's SSH route rides
on them ([One load, three routes](#one-load-three-routes)).

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
 +------------------+        |     | erx_procfs: the system domain's /proc    |
                             |     | erx_inspector: kernel objects, the       |
                             |     | services' records, runtime agents        |
                             |     |         system domain (user mode)        |
                             |     +------------------------------------------+
                             |         ^ a tty's bytes, both   ^ facets, on
                             |         | ways, as frames       | the connection
                             |     +------------------------------------------+
                             |     | session domain: Erlang shell, command    |
                             |     | shell, terminal relay, terminals on a    |
                             |     | display (erx_term), command server, a    |
                             |     | handler per program, the export,         |
                             |     | erx_inspect_agent, and /proc: erx_procfs |
                             |     | over the session's inspect facet         |
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
and other local files through the session's export. A person at a
display types into a terminal, `erx_term`, a program of their session
that is the master of one of the session's ttys
([design-display.md](design-display.md#the-terminal)), so no byte of it
passes through the system domain; `erx_code`, with each principal's hot
store, sits in the system domain beside the inspector, and each domain's
`/proc` is `erx_procfs` in its own runtime, a view of the inspector
through the domain's inspect facet. In a session, `erx:i([processes,
Pid])` asks the session's inspect facet, which hands the path, and nothing
else, to `erx_inspector` in the system domain; the inspector reads the
pid's creation to find its domain, takes the domain's kernel facts (its
group's usage, its budget) with `erx_object_info`, and asks the domain's
inspection agent about the process over the domain's connection; the
record comes back to the session with each attribute's status and
reporter, and `erx_render` writes it with the line escape. On the Mac, `erx inspect /processes/<7.85.0>` sends the
same query over the host link and renders the same record. `erx watch src
--domain 7` recompiles a changed module with the host's `erlc` and loads
it into domain 7 through the code facet; the code service also records it in the
domain's overlay, so the domain its specification starts next time starts
with it.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **V1.** A tty changes a program's bytes only as its `termios` says | every program's write to a session's or a pseudo-terminal's tty goes through `erx_tty:output/3`, a pure function of the bytes, the room and the output flags, which returns its input with `OPOST` clear and otherwise changes only what a set flag names; nothing after it reads the bytes: `erx_console` copies a connected session's bytes to the console's driver, and the host tool's `console` command copies the terminal stream to its standard output | a filter on the output path; a write path that skips `output/3` | a test at the tty's byte boundary: it writes all 256 byte values and every CSI, OSC, DCS, APC, PM and SOS form through `write`, stdio and `erlang:display_string/2`, and compares the bytes on the line and at the host tool with what was handed to the tty; with an escaping step added on the path, the comparison fails. `io:put_chars/1` is text for the group's editor, not bytes ([The tty](#the-tty)), so its test compares `prim_tty`'s rendering with stock OTP's |
| **V2.** Inspection never fabricates | every attribute value is a tagged status and carries its reporter (`kernel`, `service`, `runtime` or a backend reporter the schema declares); renderers of inspection records print the status and reporter of every value, and the command shell's text commands, which print as FreeBSD's do, print a value without the status `ok` as `-` or not at all, never as a bare number; `top`'s header alone prints a partial figure's number with its reporter named, in the line's label or after the figure ([design-shell.md](design-shell.md#invariants) SH3) | a renderer that drops statuses, or an attribute filled with a default; a partial figure of `top`'s header printed without its reporter named | one test per status and per reporter; a property test that every rendered record shows the same statuses as the record; `top`'s header tests with each figure in turn of every status ([design-shell.md](design-shell.md#invariants) SH3) |
| **V3.** The host link's authority is exactly its session's facet table and the trees its configuration lists | calls name a facet by its number in the session table and nothing else; the table is created empty with the session, holds at most 1,024 entries (opening one more fails with `{error, system_limit}`), and dies with it; the files stream reaches only the grants of the listed trees, by `attach`'s tree name, and its fids end with the session | a request path that resolves names to processes; a table or a fid that survives its session; an `attach` that reaches a tree not listed | session replacement tests; a request naming a number of an ended session is refused; an `attach` of an unlisted tree fails with `enoent`, and a fid of a replaced session names nothing |
| **V4.** A call on the host link executes at most once per session | `erx_hostlink` keeps a window of the 64 highest call identifiers, each unseen, executing or answered, and never moves it past a call still executing: a call that would push one out is answered `{error, busy}` without executing; answered calls keep their replies while the kept replies total at most 1 MiB, and a reply that does not fit is not kept; a duplicate is answered from the window, or with `{error, reply_lost}` when its reply was not kept, and an identifier below the window is refused | a window that forgets executing calls | retry and expiry tests with a lost reply and a duplicate in flight; 64 calls executing when a 65th arrives, which gets `{error, busy}` and runs once when sent again |
| **V5.** Code enters the system domain only through the install facet | the system domain's runtime loads only installed storage: its release's files and the install arena, which only `erx_code:install_beam/2` writes and which refuses every caller but `erx_code`; `erx_code` takes modules only from install facets, which name them by hash, and checks each blob against its hash; a service that loads bytes it received gets `{error, not_installed}`; nothing reapplies installs after a reboot | a second writer of the install arena, `erx_code` accepting modules from something other than an install facet, or a path that reapplies stored installs | a test that `code:load_binary/3` with bytes from a request fails in the system domain; a test that a domain's code facet cannot load into the system domain; a test that `install_beam/2` refuses other callers; a test that a blob one bit off its hash is refused |
| **V6.** Only the system shell types expressions into the system domain, and only a login at a secure line opens it | the console starts an Erlang shell in the system domain only under the system-shell facet, which it grants to a login by a system-shell principal at a line the manifest marks `secure`, holds itself, lends only to the system shell it connects at that line and to that shell's `/proc` tree, and ends with that login; the console's lines are the UART and the host link's `console` line alone; no session ever holds the facet, so no route into a session reaches the system shell, a terminal on a display included, since a terminal is a program of its session; the inspector answers `[kernel, crash]`, the crash record, only to a call that presents the facet, and `/proc/kernel/crash` is that query rendered as a file, so the one check gates both forms; every session's shell, the command shell's `erl` builtin and every Erlang command run in the session's own domain | a shell or an evaluator started in the system domain by another path; a release build's console that starts a system shell without a login; a facet a session holds, or one that outlives its login; a system shell connected at another line | a release build's console shows a login, and a principal without the facet gets no system shell; `erl` in the console's command shell evaluates in the session's domain; a lock and a log out at the UART end its system shell; the system shell gets the crash record from `erx:inspect([kernel, crash], #{})` and from `/proc/kernel/crash`, while `root`'s session in a development build, whose inspect facet has scope `all`, gets `{error, scope}` from the call and `enoent` from the read, at a console line and at a terminal on a display alike; a seeded console that grants the facet at a line that is not secure fails |
| **V7.** A console line reaches only the sessions of its principal | `erx_console` records one principal per line: the one the principal service confirmed at the line's login; the line's menu lists, connects to, interrupts and kills only the sessions the domain service records for that principal; a lock detaches the line and keeps the principal's name only for its unlock prompt, a log out clears the record, and only a login, which the vault checks, sets it again | a menu action or an attach that takes a session without checking its principal; a lock that leaves a session attached | two principals log in in turn at one line, and each menu shows and reaches only its own sessions; a locked line refuses every menu action, and its sessions run on, until the same principal logs in again; connecting a terminal already connected at another line is refused with that line named, where a seeded console that moves it fails |
| **V8.** A program appears only under its session | a program has no domain id and no pid space of its own: it is a sub-space the session created and a port of the session's runtime, so the kernel's topology under `INSPECT` on the session's space and the session's agent are the only sources that know of it, and both place it under the session's path | a path for a program outside its session; a program with a domain id | an inspection test that starts a program and finds it under `[domains, Id, programs]` and nowhere under `[domains]` |
| **V9.** Text labelled with its source is displayed only through the line escape, and written into `/proc` only through the field escape | each display of it builds its line with the escape: `erx_console`'s log lines and menu, `logger_simple_h`'s early log, `erx_render`, which prints inspection records, `ls`, which writes names at a terminal through it, and the host tool's printer; `ps` and `top` write names through the field escape wherever their output goes, so they hold nothing the line escape would change; the kernel's log escapes on entry with its own ASCII class; `erx_procfs` writes every field of a `/proc` file through the field escape, so `cat` of one shows no raw control | a renderer that prints a name or a value raw; a `/proc` file that writes a reporter's text unescaped; a class of characters missing from the table; a print path in the host tool that skips its printer; a log event that reaches a terminal by another handler | tests that send every C0 and C1 control, every `Cf`, `Zl`, `Zp`, unassigned and default-ignorable character, invalid and overlong UTF-8 and every CSI, OSC, DCS, APC, PM and SOS form through each display and each host command, in a log record, a domain's name and an inspected value; a fuzz target per escaper; a test that re-derives the classes from OTP's Unicode data and fails if `abi/terminal.txt` disagrees; the source check on the host tool's output calls, with a seeded violation |
| **V10.** An inspection answer hands out no name | the inspection schema has no pid, port, reference or fun type: a process is a `proc_id()` of three numbers and an alias its owner's `proc_id()` ([Inspection records](#inspection-records)), and the inspect service passes every answer through `erx_schema:validate_record/1`, which refuses a record holding any of them at any depth, before it leaves the system domain; so encoding an answer never adds a holder to the system domain's export table, whatever the facet's scope | a schema type that admits a live pid, or an attribute filled with one; an answer path that skips the validation | a test that reads `[processes, P]` of a system-domain process with a group leader, links and monitors, and `[domains, 4, exports]`, through a session's facet of scope `all`, and finds `erx:exports/1` of each name the record shows unchanged; seeded: a collector that puts the live group leader into the record, which the validation refuses, and a validation removed, which the exports check catches |
| **V11.** A load reaches only the domains its facet's scope holds, by whichever route it came | every route ends in one exchange on a facet of the `code` interface held by the host link's session or by a session of the machine, whose scope the domain service fixed when it minted the facet, the system domain alone for the install facet and `erx_domain_core:code_scope/3`'s answer for a code facet, and which no request states; `erx_code` resolves the domain a load or a reset names against the facet's scope at each load, and no code facet's scope holds the system domain ([One load, three routes](#one-load-three-routes)) | a scope taken from a request; a code scope that holds the system domain; a route that reaches `erx_code` other than through a facet | `code_scope/3` over every principal and build flag; a load into a domain outside the scope gets `{error, scope}`, as one into a domain that does not exist, and a load with `-d 4` through the code facet gets it too; seeded: `all` for a principal that is not a system-shell principal, `all` in a release build and the system domain in a code scope, each failing a case of `code_scope/3` |

## Data model

### Inspection records

```erlang
-type record() :: #{schema := 1,
                    path := [segment()],
                    kind := atom(),          % machine, cpu, thread, group, domain, program, ...
                    id := term(),
                    attrs := #{atom() => attr()},
                    children := children(),
                    entries => entries()}.     % only on a path the schema marks with entries

-type attr() :: {reporter(), value()}.
-type reporter() :: kernel | service | runtime
                  | {backend, Name :: atom()}.   % a backend reporter of the schema
-type value() :: {ok, term()} | {partial, term()} | unknown | unsupported
               | {timeout, Milliseconds :: pos_integer()} | {error, term()}.

-type children() :: [segment()] | {partial, [segment()]} | unknown.

-type entries() :: {ok | partial, Next :: non_neg_integer(),
                    [{Sequence :: non_neg_integer(), term()}]}.

-type segment() :: atom() | integer() | binary() | proc_id().

-type proc_id() :: {pid, Domain :: non_neg_integer(),
                    Number :: non_neg_integer(), Serial :: non_neg_integer()}.
```

**Names travel as data.** A record names a process by its `proc_id()`,
the three numbers of its pid's text `<D.N.S>`
([design-domains.md](design-domains.md#domain-ids-pids-and-references)),
and never holds a pid, port, reference or fun, in its path, its id, its
children, its entries or any attribute, however deeply nested: a group
leader, a link, a monitor, a program's owner, a pipe end's holder and a
device's driver process are each a `proc_id()`, and an alias in an
export table is `{alias, Owner}`, its owner's `proc_id()`, without its
four words. Encoding a pid or an alias of the encoding domain toward a
peer hands the peer `send` on it
([design-domains.md](design-domains.md#exports), "Handing out a name"),
so a record that held the system domain's own pids would give every
holder of a scope that covers the system domain the right to message
and monitor its processes; a record of numbers hands out nothing, and
`list_to_pid/1` on its text makes a name the funnel still refuses,
since knowing a pid grants nothing. The schema has no pid, port,
reference or fun type, so `erx_schema:validate_record/1` refuses a
record that holds one anywhere, and the inspect service validates every
answer with it before the answer leaves the system domain (V10). A
caller's `erx:i(Pid)` and `erx:source(Pid)` turn a live pid into its
`proc_id()` in the caller's own runtime, and renderers print one as
`<D.N.S>`.

A record of a path the schema marks with `entries` may carry them: each
entry's value, of the path's entry type, with its sequence number, the
numbers increasing and each below `Next`, the number the next query of
the path starts from. `partial` says entries remain from `Next` on. A
number the entries skip is an entry the query did not get, so a gap,
never a made-up entry, is what shows one; `erx_schema:validate_record/1`
checks the entries with the rest of the record, at most a page of them.

A reporter is one of three categories, or a backend reporter: a
component behind an interface, such as `liberx`'s Fiasco backend, that
does the kernel's, a service's or a runtime's work in its place and
reports what it can see of that work under its own name.
`liberx`'s Phase 1 backend counts the pages of its pool in the kernel's
place, so the root's budget's `used` is `{{backend, liberx_pool},
{partial, Pages}}`, which a renderer prints as the value `[partial]`
with the reporter `root pool`, and a budget carved from it reports
`used` as `unsupported`
([design-fiasco.md](design-fiasco.md#reporting-a-budget)). The schema
declares each backend reporter with the category it stands in for, its
label, the scope of what it sees and the attributes it may report; a
record carries only its name, an atom of `erx_schema`. A value the
kernel interface reports with the attribute's full meaning, or reports
as `unsupported`, is `kernel`'s, whichever kernel backs the interface; a
value a backend computes in another reporter's place carries the
backend reporter's name, so a backend's observation never passes for the
kernel's.

The collector of each source assigns the reporter, never the report: an
attribute from `erx_object_info` is `kernel`'s or that of Fiasco
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
| clear | set | `{{backend, S}, {partial, V}}`, S the one backend reporter the attribute lists for `kernel` |
| clear, or no such field | clear | `{kernel, unsupported}` |
| set | set | `{kernel, {error, invalid}}`, a fault of `liberx` |

A partial bit on an attribute that lists no backend for `kernel` is a
fault of `liberx` too, and the attribute is `{kernel, {error, invalid}}`,
so a backend's count never passes for the kernel's. A call refused with
`ERX_ENOTSUP` makes every attribute of the topic `{kernel,
unsupported}`; `ERX_ERANGE` from a topic whose `index` counts entries
ends the listing and makes no record; any other refusal makes each
attribute `{kernel, {error, S}}`, S the status's name. The inspector
makes the call itself, on capabilities it holds, and the partial mask is
its own `liberx`'s, so no domain's report reaches either mask. The
kernel names no reporter: the schema names the backend reporter of a
field the system domain's `liberx` marks partial.

A value the inspector derives from other attributes, one the schema
marks `derived`, as a budget's spending and room, is `ok` only when
every input is `ok`; otherwise it is `unsupported` when an input is and
`unknown` when none is, and it carries the reporter of an input that is
not `ok`, so a partial count never yields a room that reads as exact.

`abi/inspection.txt`, included by the ABI root, declares the kinds, paths,
attribute keys, types, units, bounds, the reporters each attribute
admits, the backend reporters and visibility rules, in the grammar of
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
| `[domains]`, `[domains, Id]` | domain: name, principal, state and death record, and for a domain of a supervised specification its overlay's published revision and the revision its start load carried (service, the last from the code service); budget guarantee, cap and spending, group usage, threads (kernel); atom count, ETS tables, modules, process count, run queue, and its answer to its start load as the code service received it (runtime) | each attribute marked |
| `[domains, Id, threads]`, `[domains, Id, threads, T]` | the domain's threads by object id, from `ERX_INFO_THREAD` on its space; thread: state and wait kind | kernel |
| `[domains, Id, capabilities]`, `[domains, Id, mappings]` | the domain's capability table and mapping records, paginated, from the space's `handles` and `mappings` topics; in development builds alone, on either kernel, for tests and development ([design-fiasco.md](design-fiasco.md#reporting-kernel-objects)) | kernel; on Fiasco the backend reporter `liberx_placements`, from the root's placement records, each record's object `partial` |
| `[domains, Id, connections]`, `[domains, Id, connections, Peer]` | the domain's connections: the peer domain and each lane's size (service, from the domain service's records); each doorbell's trigger count (kernel, from the IRQ object); frames accepted and refused on each lane (runtime, from the domain's funnel) | each attribute marked |
| `[domains, Id, exports]` | the domain's export table: each name as data, a process's `proc_id()` or an alias as `{alias, Owner}`, with the peer domain and rights, paginated | runtime |
| `[domains, Id, programs]`, `[domains, Id, programs, N]` | for a session's domain, its programs, `N` a program's process id, each a port of the session's runtime: name, owner pid, state, exit status, the fids its handler holds for it, its namespace, its failed write-backs of shared mappings (runtime, from the session's agent); its sub-space's state and charges and its group's usage (kernel, from `INSPECT` on the session's space and group tree); below it, `threads`, `capabilities` and `mappings` of the sub-space (the last two in development builds alone) as the session's agent relays them from the capabilities it holds, marked runtime, or `unsupported` | each attribute marked |
| `[domains, Id, pipes]`, `[domains, Id, pipes, N]` | for a session's domain, its pipes: each end's holder, a program by its number or a process, each ring's size and the bytes its header reports, marked as reported by the ring ([design-pipes.md](design-pipes.md#failure-handling-diagnostics-and-debuggability)) | runtime, from the session's pipe server |
| `[domains, Id, processes]` | the domain's pids, paginated | runtime |
| `[domains, Id, crash]` | the domain's last crash dump, paginated; marked truncated when its header says so; in a development build, the device access trace of its last end, decoded, each entry without a recorded completion shown as such ([design-runtime.md](design-runtime.md#the-device-access-trace)) | service, from the crash area; the trace marked as the domain's report |
| `[domains, Id, modules]`, `[..., modules, Module]` | module: version (its blob's SHA-256), OTP's `md5`, source file, origin (boot image, overlay, loaded in the domain), whether its source is in the boot image | runtime |
| `[domains, Id, modules, Module, history]` | the last 16 hashes the code service published for the module in its specification's overlay, newest first, with their times | service, from the code service |
| `[domains, Id, modules, Module, source]` | source text, paginated by lines | runtime, from the boot image |
| `[processes, ProcId]` | process: domain (from the `proc_id()` itself); state, priority, reductions, current function and location, heap and stack size, message queue length, registered name, group leader, `trap_exit`, links and monitors | the domain, by construction; the rest, runtime |
| `[processes, Pid, source]` | the source lines around the process's current location | runtime |
| `[devices]`, `[devices, Name]`, `[devices, Name, registers]` | device: the domain that holds it and its driver process, interrupt bindings, DMA profile (service, from the device service's table); registers read by the driver's domain through the device NIF at the device service's request and decoded field by field from the device's SVD description (runtime of the driver's domain); a register whose read has side effects is `unsupported` | each attribute marked |
| `[devices, Name, trace]` | a snapshot of the device's register accesses among the 256 newest of its domain's access trace, oldest first, each with its sequence number, register and element, read or write, width, value and whether its completion was recorded, a read's value `unknown` without it; in scope `all` alone; `unsupported` in a release build and for a device of a domain without a crash area ([design-runtime.md](design-runtime.md#the-device-access-trace)) | runtime of the driver's domain, at the device service's request |
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
path learns how many entries it missed. An offset past the newest entry,
or one that is not a sequence number, is `{error, invalid}`. A record of
the kernel log holds at most a page of lines, each as the log core
rendered it without its newline, and a record the ring overwrote, or one
that failed the reader's checks, is a gap in the numbers. The web's log
view reads such a path ([design-web.md](design-web.md#views-on-the-line)).

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
* `rendered(Bytes, Room, Tty)` is `output/3` with `OPOST` clear, whatever the
  `termios` says: it takes what another renderer, the console's line editor,
  made for the terminal already.
* `input(Bytes, Room, Tty)` returns what to do (bytes to echo, a signal
  for the foreground group, `flushed_loss` ahead of a signal whose flush
  dropped a loss, a report that a waiting read can go on), the
  bytes it did not take, the room left and the next state. `Room` is the
  room the owner has for the master, `{Free, Kept, Stopped}`: what is free
  of it, what it holds that a flush cannot drop, the output it has sent and
  the master has not taken, and whether output is stopped. It stops after a
  key that makes a signal and returns the bytes after it untaken, as
  FreeBSD's `ttydisc_rint` signals the
  foreground group before it takes the next byte
  (`sys/kern/tty_ttydisc.c:1124-1133`), so the owner acts on the signal before
  any reader can be reported the bytes typed after the key
  ([design-shell.md](design-shell.md#the-terminal-relays-protocol)), and then
  passes them to `input/3` again, with the room it returned. A
  line in cooked mode holds at most 4,095 bytes and its end, and in raw mode at
  most 4 KiB wait unread; further bytes are dropped and counted, with a bell
  when `IMAXBEL` is set, as FreeBSD's `ttydisc_rint` drops a byte that finds
  the queue full (`sys/kern/tty_ttydisc.c:1220-1236`). FreeBSD holds back
  the device instead when a line waits to be read; a master cannot be held
  back, so the tty drops in that case too. Echo goes to the master with a
  program's output, so it takes the owner's room for the master, as
  `output/3` does: a piece of echo, one byte's rendering or one character's
  erase, that does not fit what is left is dropped whole and the rest of
  the room stays, as
  FreeBSD's `ttydisc_echo_force` puts echo in the output queue through
  `ttyoutq_write_nofrag` (`sys/kern/tty_ttydisc.c:724-760`,
  `sys/kern/tty_outq.c:322-334`) while a program's write waits for room
  (`sys/kern/tty_ttydisc.c:628-645`). A master that does not read so gets
  no more echo than the room, however many calls a signal key cuts its
  input into. The tty knows the whole room, the 4 KiB the owner holds for
  the master at most, the output outstanding at the master among them
  (`master_room/0`, the one record of it), and a signal's `flush_output`,
  which empties what the owner holds but `Kept`, gives echo the rest of
  the whole room back before the key is echoed, in FreeBSD's order:
  `ttydisc_rint` flushes the queues and then echoes the key
  (`sys/kern/tty_ttydisc.c:1128-1130`). So the room `input/3` returns is
  what the echo left of `Free`, or of the whole room less `Kept` after a
  flush, and no owner counts echo itself.
  A `VREPRINT` retypes `VREPRINT`, a newline and the line, as FreeBSD's
  `ttydisc_reprint` does (`sys/kern/tty_ttydisc.c:786-799`), but its walk
  ends at the first piece that does not fit. FreeBSD tries every piece
  and its queue drops each that does not fit, so each `VREPRINT` walks the
  whole line; a master that reads nothing and sends `VREPRINT` over and
  over at a little room would cost the owner a walk of the line per key.
  Ending the walk there bounds what a `VREPRINT` renders by the room it
  fills, but for pieces that render to nothing, and with `ECHO` clear,
  when nothing of a cooked line echoes, the line is not walked. The
  bytes differ from FreeBSD's only by the smaller pieces that would
  still fit after the first that does not, which make no sense on the
  screen without it.
* `lost(Tty)` takes a loss of input, a unit after the input the tty holds
  that takes no room, and returns the reports and timer starts one byte
  would cause and the next state; `input/3` makes one where it drops a
  byte for room ([Lost input](#lost-input)).
* `read_wait(Open, Count, Tty)`, for a blocking read of `Count` bytes that
  starts to wait,
  `poll_wait(Open, Tty)`, for a `poll` that waits for input,
  `cancel(Open, Tty)`, for a wait that a signal or a close ends,
  `timer(Timer, Tty)`, for a timer's end, and `read(Open, Max, Tty)`, for the
  read itself, which gives each loss as one NUL, and `read_input(Open, Tty)`,
  the line editor's read of one unit, a byte or `lost`, both through one
  consuming step, return the next state and
  what to do: bytes for the reader;
  `eof` for an end of file, `VEOF` at the start of a cooked line or a read
  that finds no bytes after a hangup; no bytes for a raw read with nothing
  to wait for; or `eagain` when another reader took the bytes. The end of
  file and an empty raw read stay apart because an Erlang command's read
  returns `eof` for one and `<<>>` for the other, and only the step that
  makes the answer knows which it is; a program's `read` returns 0 for
  both, as POSIX's does. A report `{ready, Open}`,
  once per wait, that the read can go on; a timer to start or cancel. Each
  timer start names a fresh `{Open, Serial}`, so the end of a timer that was
  cancelled or replaced does nothing. A `poll` is ready at a complete line
  in cooked mode and at one byte in raw mode, whatever `VMIN` says, since
  FreeBSD's `poll` counts the bytes a read could take (`ttydisc.h:72`);
  so a `poll` starts no `VTIME` timer and, with nothing to read, reports
  nothing.
* `set(Termios, Tty)` takes a new `termios`, checking it whole; a flag
  outside `erx_tty`'s table fails with `EINVAL`. The `termios` is an Erlang
  map of four flag lists, the character size, the special characters by name
  and the two speeds, and is all a tty holds of it; the program protocol
  turns a C program's `struct termios` into it and keeps only the bits the
  table names, as FreeBSD's `tcsetattr` drops the bits it does not support
  (`sys/kern/tty.c:1760-1764`), so a FreeBSD program that sets one gets
  success, as POSIX allows, and sees it clear in `tcgetattr`. The table is
  `abi/termios.txt`, from which both that codec (`erx_abi_termios`) and
  musl's `bits/termios.h` are generated, so the flag bits, `c_cc` indices,
  `NCCS` and `_POSIX_VDISABLE` the codec reads are those a C program
  writes, and `struct termios` and its `B` speeds, each its rate, are
  FreeBSD's (`sys/sys/_termios.h`). A change of
  `ICANON`, `VEOF` or `VEOL` moves what the new mode counts as complete to
  the readable bytes (`tty.c:1803-1812`), and every waiter waits again under
  the new rules.
* `hangup(Tty)`, for the master's `tty_hangup`, drops the input the tty
  holds, as FreeBSD's carrier loss flushes both queues
  (`sys/kern/tty_ttydisc.c:713-714`), makes every waiter ready, and makes
  every later read that finds no bytes an end of file.
* `size(Rows, Columns, Tty)` takes a new window size, each from 1 to 65,535,
  and refuses any other. It returns `winch` when the size differs from the
  one the tty holds and nothing when it is the same, so only a change
  reaches the foreground job
  ([design-shell.md](design-shell.md#window-size)).
* `status(Line, Room, Tty)` returns the bytes of a status line for the
  master. They start with a newline when the output column, which
  `output/3` keeps, is not 0. It returns nothing when `NOKERNINFO` is set,
  as FreeBSD's `tty_signal_pgrp` prints nothing then
  (`sys/kern/tty.c:1542-1543`), and when `Room` is under 256
  bytes, as FreeBSD prints its status line only with that much room
  (`sys/kern/tty.c:2057-2062`), or too small for the whole line, so a
  status line is never cut.

The owner carries out what they return and owns the timers, so time reaches the
machine only as `timer`, and the exploration on the host drives it event by
event. The owner names a wait by its open and its kind, `{Open, read}` or
`{Open, in}`, so a blocking read and a `poll` of one open, from two threads of a
program, are two waiters, and neither replaces the other.

**Cooked and raw** mean what they mean on UNIX, as flags of `termios`:

* **Cooked**, `ICANON` set: the line discipline collects a line, applying
  `VERASE`, `VKILL`, `VWERASE` and `VEOF`, and a read gets one line. History
  and arrow keys are no part of it.
* **Raw**, `ICANON` clear: a read gets bytes as `VMIN` and `VTIME` ask for,
  by POSIX's four cases:
  * `VMIN` above 0, `VTIME` 0: the read can go on at `VMIN` bytes;
  * `VMIN` and `VTIME` above 0: at `VMIN` bytes, or when a timer that the
    first byte starts ends. Later bytes do not restart it: FreeBSD sets one
    deadline after the first byte (`ttydisc_read_raw_interbyte_timer`,
    `tty_ttydisc.c:360-405`, with `:306-320`), where POSIX's interbyte
    wording reads as a restart at each byte. macOS's tty is expected to
    restart it (not yet verified against its source), so a comparison with a
    host pseudo-terminal on macOS treats this case as a documented
    difference and tests FreeBSD's rule;
  * `VMIN` 0, `VTIME` above 0: at the first byte, or when a timer that
    `read_wait` starts ends, and the read then returns no bytes;
  * both 0: at once, with whatever waits.

  In the first two cases a read of fewer bytes than `VMIN` can go on at its
  own count, as FreeBSD's read returns once its buffer is full
  (`tty_ttydisc.c:290`, `:331`, `:384`), which is why `read_wait` takes the
  count.
* `ECHO`, `ISIG` and `OPOST` are flags of their own, which `cfmakeraw` clears
  with the rest, so a tty made raw with it delivers `Ctrl-Z` as data.
* With `ISIG`, `VINTR`, `VQUIT` and `VSUSP` signal the foreground group.
  With `ICANON` and `IEXTEN` also set, `VSTATUS` gives the event `info`
  for the foreground job. The key is not echoed, nothing is flushed, and the
  line typed so far is kept, as on FreeBSD
  ([design-shell.md](design-shell.md#ctrl-t-status-and-the-info-request)).

* With `IXON`, `VSTOP` stops output and `VSTART` starts it again, and with
  `IXANY` any key starts it, as FreeBSD's do (`tty_ttydisc.c:1055-1058`,
  `:1141-1162`). Output stopped is the owner's alone, recorded with what it
  holds for the master as FreeBSD keeps `TF_STOPPED` with the output queue
  (`sys/sys/tty.h:82`): `input/3` is given it in the room and returns
  `stop_output` and `start_output` as its keys change it. While output is
  stopped, `output/3` and echo still take the room, as FreeBSD's
  `ttydisc_write` fills the output queue whatever `TF_STOPPED` says
  (`tty_ttydisc.c:560-665`), and the owner sends the master nothing until
  output starts. A signal from a key and `info` start it too, and a
  window-size change always does, as FreeBSD's `tty_signal_pgrp` does
  (`tty.c:1536-1538`, `:1646`).

A new tty starts cooked, with FreeBSD's defaults
(`sys/sys/ttydefaults.h:46-52`, `:102-104`): `ECHO`, `ECHOE`, `ECHOKE`,
`ECHOCTL`, `ISIG`, `ICANON`, `IEXTEN`, `BRKINT`, `ICRNL`, `IMAXBEL`,
`IXON`, `IXANY`, `IUTF8`, `OPOST` and `ONLCR` set, and `VSTATUS` `^T`.

**A shell's line editor is a program on a raw tty.** `group`, `edlin` and
`prim_tty` are to a shell what readline is to `bash` and libedit to
FreeBSD's `sh`. While the shell prompts, its tty has `ICANON` and `ECHO`
clear, as stock OTP sets a real terminal
(`erts/emulator/nifs/common/prim_tty_nif.c:1115-1127`), and `VMIN` 1 and
`VTIME` 0, so a key is read as it is typed. `ISIG`, `ICRNL` and `OPOST`
stay set, which stock OTP clears, as libedit keeps them while it edits
(`contrib/libedit/tty.c:79-88`): `Ctrl-C` and `Ctrl-Z` are then the
tty's signals whether or not the editor is reading, an Enter typed ahead
of a command is a newline in the tty, the end of the command's cooked
line ([design-shell.md](design-shell.md#the-terminal-relays-protocol)),
and `edlin` takes `\n` as it takes `\r`
(`lib/stdlib/src/edlin_key.erl:201-202`); and a line a program writes
while the shell prompts, a background job's, goes out with the CR-LF of
the tty's `ONLCR`, as on FreeBSD. `prim_tty` writes its own CR-LF, which
`OPOST` never processes again ("The editor's rendering is not the
tty's", below). The process that drives the group
is `erx_console`, whose line driver is the session's terminal relay for a
session's shell and the UART's driver for the system shell
([design-runtime.md](design-runtime.md)). It takes each request through
`prim_tty:handle_request/2`, whose state comes from `prim_tty:init_ssh/3`
(`lib/kernel/src/prim_tty.erl:308`), which needs neither a terminal
descriptor nor terminfo, and writes the bytes to its driver; the relay
writes them to the tty as rendered output, which takes its turn in the
tty's one output queue as any writer's bytes do but passes the tty with
`OPOST` clear (`erx_tty:rendered/3`). Input goes to the group as `{self(), {data, Chars}}`, the protocol `ssh_cli`
uses (`lib/ssh/src/ssh_cli.erl:420`). A session's console takes it from
the tty as libedit does, one byte at a time and only while its group's
editor waits for a key (`contrib/libedit/read.c:289`, at FreeBSD commit
`95719d8a`), through an open of the relay, and gives it to the group as
the answer `{self(), {read, Ref, Chars}}` to the group's ask, edit 72 of
[design-runtime.md](design-runtime.md). The editor alone decides
where a line ends, whatever keys its keymap binds to that, and the
command shell's group reads for the shell alone, refusing every other
process's input request (edit 74), and the shell asks for no line
before it has acted on the last, so a line typed ahead for the next
command stays in the tty for that command
([design-shell.md](design-shell.md#the-terminal-relays-protocol)).
`Ctrl-C` interrupts the shell's evaluator as `ssh_cli` turns it into
`exit(Group, interrupt)` (`lib/ssh/src/ssh_cli.erl:409-411`). A foreground
job starts with the session's cooked `termios`, a stopped job keeps its
own for `fg`, and the prompt takes the terminal back when the job ends or
stops, as a UNIX shell does. Each time it does, the cooked `termios`
takes in what the job left by libedit's rule, which takes a setting only
when it is canonical and forces `ECHO`, `ISIG` and `ICRNL` on among other
flags ([design-shell.md](design-shell.md#the-terminal-relays-protocol)).
So a program that ends in raw mode leaves nothing in the `termios`, and
`stty status ^X` lasts. What it left on the terminal itself, an alternate screen, a
hidden cursor or a colour, stays until the operator runs `reset`, as on UNIX.

**The editor's rendering is not the tty's.** A process's `io:put_chars` is
Erlang's text I/O, not a write of bytes: the group turns it into
`{putc, Binary}`, which `prim_tty`, in stock OTP's cooked output mode
(`prim_tty.erl:329`), renders for the screen as stock OTP's shell does, with
CR-LF for a newline and caret notation for a control character
(`prim_tty.erl:696`, `:1227`, `:1280`). That is the shell's line editor at work,
as readline's redraw is `bash`'s. What `prim_tty` returns then reaches the tty
as rendered output, whose bytes the tty passes with `OPOST` clear whoever holds
the terminal, so a redraw that reaches the tty after a job has taken it cooked
is not processed a second time. A program's bytes, a command's through
`erx_console:write/1` among them, are processed once, by the tty, and the
editor's rendering once, by `prim_tty`. So there are two exact comparisons, each at its own boundary: what a
writer hands the tty against what the master gets, which V1 tests; and what
`prim_tty` renders from a request against what stock OTP's renders from the same
request. A program that needs exact bytes uses `write` or stdio, and Erlang code
uses `erlang:display_string/2`.

**Where a tty lives.** A session's ttys live in the session's domain, in its
terminal relay ([Job control](design-shell.md#job-control)), which answers
every `{tty, Open, Request}` of its programs and of the Erlang commands of
the session's own domain. A tty's master is `erx_console`
while the tty is connected at a console line, the UART or the host link's
`console` line ([The console](#the-console)); a terminal on a display,
`erx_term`, a process of the session
([design-display.md](design-display.md#the-terminal)); or in the second
tier a program that holds a pseudo-terminal's master;
so a session's `/dev/tty` and a `/dev/pts/N` are one thing with different
masters ([design-programs.md](design-programs.md#the-terminal)). Each master
has a tty of its own, driven by a terminal relay of its own
([design-shell.md](design-shell.md#the-terminal-relays-protocol)): the
console's is made as the session starts, and its relay alone holds the
name the runtime's writers look for; a master in the session's domain
asks the session for a new one, as `posix_openpt` makes a
pseudo-terminal.

The system shell's tty lives in `erx_console` and is simpler. Programs run only
under a session's domain (V8), so no program opens it and nothing can call
`tcsetattr` on it: its settings follow the driver's `Terminal` for as long as
it lives, the prompt's `termios` above less `IXON` and `IMAXBEL` on a
person's terminal, and every flag clear on a pipe, which also has no
`Ctrl-G` menu ([Lost input](#lost-input)). `erx_console` runs it as the
bounded store its groups read on demand and as the output processing of a
command's bytes (`erx_console:write/1`), which its `OPOST` and `ONLCR` send
CR-LF on a person's terminal and its clear flags leave as written on a pipe;
it copies output from the group's `prim_tty` to the driver unchanged. `erx:console_size/2` checks the
size as `erx_tty:size/3` does, so a zero column count never reaches `prim_tty`.

**Between domains.** A tty and a master in the system domain exchange seven
closed messages, as frames on the domain's connection to the system domain.
Nothing crosses that the console has to interpret. Each receiver checks what it
gets, whatever the sender's own limits:

| Message | Direction | The receiver's check | If it fails |
| --- | --- | --- | --- |
| `{tty_open, Tty}` | tty to master | `Tty` is a pid of the domain its console facet names; the first names the session's tty, and the same pid again is nothing | the console detaches the tty and logs a line under the domain's id |
| `{tty_output, N, Bytes}` | tty to master | a binary of at most 4 KiB, charged after `output/3`; `N` is the tty's next output number, or the last one again with `Bytes` empty | the console detaches the tty and logs a line under the domain's id |
| `{tty_taken, N}` | master to tty | `N` is the output outstanding | ignored, since it is a late repeat |
| `{tty_input, N, Bytes}` | master to tty | a binary of at most 4 KiB; `input/3` bounds what waits unread; `N` the next input number, a higher one taken after a loss in the gap ([Lost input](#lost-input)) | dropped and counted |
| `{tty_lost, N}` | master to tty | `N` as for `tty_input`; ignored after a hangup; `lost/1` takes it | dropped and counted |
| `{tty_size, Rows, Columns}` | master to tty | `size/3`, each from 1 to 65,535, so a zero column count never reaches `prim_tty` | the old size stays, counted |
| `tty_hangup` | master to tty | that atom; it holds from then on | not applicable |

**A lost answer does not stop a tty.** The system domain's peer may drop a
message to a domain whose lane stays full
([design-domains.md](design-domains.md#the-peer)), and a `{tty_taken, N}` is
such a message. So the tty has one output outstanding and numbers it, and with
no answer in 1 s it sends `{tty_open, Tty}` and `{tty_output, N, <<>>}`, and
again each second. A
master that has taken output `N` answers `{tty_taken, N}` again, with the
current `{tty_size, Rows, Columns}`, and `tty_hangup` if it has hung up: these
are states, so a repeat of them is harmless and a lost one is sent again. A
master that has not taken it, because the session is not connected, sends
nothing, and that one output is all the console holds for a session. A resend
whose first send was lost arrives as the next output with no bytes: the master
takes it as such, so those bytes are lost, as in a line's overrun, and the
console logs a line naming the session's domain and the output's number. A lost
`tty_input` or `tty_lost` leaves a gap in the input numbers, which the tty takes
as a loss at its place ([Lost input](#lost-input)), and the peer's count reports
it. A master in the tty's own domain, `erx_term` or a
pseudo-terminal's, sends the same messages as plain Erlang messages, which
are not dropped.

The tty learns its master from `erx:cap(console)`, and the console learns
the tty from the tty's own `{tty_open, Tty}`, which its console facet
forwards with the session's domain id, so the console takes as a session's
tty only a process of that session's domain; the ready report names no
tty, since the relay starts after it, once init holds the domain's facets. That
master is the session's own console facet, which the domain service mints
from the session's spec, `console => erx_console:facet()`, in front of the
console's facet endpoint, a process that takes the facets' forwarded
messages and refuses every call, so a session reaches nothing of the
console but its tty's seven messages; the facet's `max_request` is the
encoded size of the largest `tty_output`, and it forwards each of the
tty's messages with the session's domain id
([Facets](design-domains.md#facets)). A tty's bytes are a live
conversation, so the facet is an instance of the `console` interface,
which `abi/services/console.txt` declares with the seven messages of the
table above and which cites this section. The console
takes an output only once its line driver has written it, so a session
has at most one output in the console and the driver together. A master
in another domain is heard only through the envelope of its own domain
(D18). Once `tty_hangup` holds, the tty drops what it holds and takes every
later write at once with nothing sent, and the relay sends the tty's
console `erx_console_eof` at once, whether or not a read waits, so the
console ends every shell on the tty and then the tty ends, as a UNIX
session ends with its terminal's
hangup; the session's other ttys run on. The relay watches its master in
either domain, a master in another domain through a monitor its domain's
funnel admits as for any pid that domain exported with `send`, and the
master's end, its domain's end included, is the tty's hangup, as a
pseudo-terminal master's close is, so a channel that ends without saying
`tty_hangup` still ends its tty.

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

An Erlang command reads the tty the same way, because its outstanding
read must not block its `receive` either: it asks for one ready report, the
line discipline's `read_wait`, takes the report as a message, and then sends
a read that `read/3` answers at once, so one `receive` of the command takes
its keys, its size reports and its own timers
([Interfaces](design-shell.md#interfaces)). The read names the report it
follows, so a signal made in between leaves the bytes in the tty
([design-shell.md](design-shell.md#the-terminal-relays-protocol), "A
reader the signal ends").

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

`erx_console` is the system domain's console service. It serves two
**console lines**, the terminals at which an operator logs in and works:
the UART, which is erXos's `/dev/console` as on UNIX, and the host link's
`console` facet. Each has its own menu, its own login and at most one
connected terminal, and the console treats them alike except where this
section names the UART. A terminal on a display is no console line: it
is a program of a session, the master of one of the session's ttys
([design-display.md](design-display.md#the-terminal)), and the console
has no part in it.

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
clear either. A display domain, which sees and can inject every key typed
at it, never carries the system shell, which only a login at a secure
line opens (**The system shell**, below;
[design-display.md](design-display.md#security)). A development manifest marks the UART and
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
from: `erx:attach` of a session, a terminal on a display, or a shell the
session starts.

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
  polling until the log service's first take hands the log to the
  console, before the driver starts, and again at a panic or the
  machine's end; so the kernel and the driver share the UART in time,
  and while the driver runs it is the UART's only user. On Fiasco the
  kernel's own lines go from that take on to a ring of the kernel's,
  which each take drains into the log as kernel records, and reach the
  UART only when the machine stops, or when a development build's
  kernel enters its debugger, which shares the UART with the driver
  from then on if the operator resumes
  ([design-fiasco.md](design-fiasco.md#the-kernels-lines)). On Fiasco
  neither a kernel stop nor the machine's end stops a thread first
  ([design-fiasco.md](design-fiasco.md#the-end-path)), so a stop's
  report and the end's last lines can fall among a driver write still
  under way. A test root's
  test tasks, which run with no console driver and no take, write their
  bytes to it unchanged
  ([design-fiasco.md](design-fiasco.md#the-console)).

The host link shows its own session's output and the log lines the log
service sends it, and nothing else.

**Log lines and program output.** A log line is one write to the driver,
whole, ending in CR-LF, between whatever else is written. It can land in
the middle of a program's line or an edited prompt, as a kernel message
does on a UNIX serial console, and `Ctrl-L` redraws an edited line. After
boot, kernel log records and every domain's log records reach the console
through the log service, `erx_syslog`, which takes the kernel's ring with
`erx_log:take/0` and sends `erx_console` the lines, one batch at a time
([design-log.md](design-log.md#consumers-and-backlogs),
[design-kernel.md](design-kernel.md#console-log-and-panic)).

* **Size.** The connected tty is told its line's size as
  `{tty_size, Rows, Columns}`: on the UART 80 by 24 unless the operator
  sets another with `erx:console_size/2`, and on the host link what the
  host tool reports.
* **Input.** Bytes go to the connected terminal's tty as
  `{tty_input, N, Bytes}`, whose line discipline decides what they mean
  ([The tty](#the-tty)). A UART's receive overrun, which no flow control
  prevents on the console's line, is a loss of input, which the driver
  reports as an event of its own, in order with the bytes, and the console
  passes on as `tty_lost` ([Lost input](#lost-input)): a shell's `edlin`
  finishes no line of a read that lost input and rings the bell, until
  the user empties the edited buffer, so a line that lost bytes never
  runs, and a program that reads its tty gets a NUL where the input was
  lost, the byte FreeBSD gives there. The one
  exception is `Ctrl-G`, which the console
  keeps for the line's menu and no session ever reads, so the operator can
  always reach the real menu. While the menu or a login prompt has a line,
  no terminal is connected there: the tty last connected at that line is
  stopped, and its programs read nothing typed there and write nothing
  there.
* **Ctrl-G and a terminal's replies.** `Ctrl-G` is BEL, 0x07, and a
  terminal also ends an OSC reply with BEL when the query did, so a
  session that asks the operator's terminal for, say, its colours would
  otherwise have the reply open the menu. `erx_console_keys` tells them
  apart with ECMA-48's escape parser run over the input: `ESC` followed by
  `]`, `P`, `_`, `^` or `X` opens a string control, and so does the 8-bit
  form of each written as UTF-8 (U+009D and the rest), which a terminal
  told to answer in 8-bit controls sends in UTF-8 mode; a BEL inside an
  open string ends it and stays in the input, as ST does, `ESC [` opens a
  control sequence, such as a cursor report, that its final byte ends,
  `ESC` begins an escape and `CAN` or `SUB` cancels a string or a sequence, and every other BEL is a
  typed `Ctrl-G`, `ESC BEL` (Meta-`Ctrl-G`) included. A raw 8-bit control
  byte is not recognized: the line is UTF-8, in which such a byte is a
  continuation byte. The escape state carries from one read to the next,
  so while a session or the shell has the line no reply makes a `Ctrl-G`
  however its reads are cut. A person who types `Alt-]`, which sends
  `ESC ]`, opens a string, and the next `Ctrl-G` only closes it; the one
  after opens the menu. Two things no rule over the bytes can catch are
  security residuals ([TODO.md](../TODO.md)): a terminal that reports text
  a session chose, as xterm's title report does where it is allowed, lets
  the session type anything at the line, and a session that switches the
  terminal's keyboard mode can make `Ctrl-G` arrive as an escape sequence;
  the menu's rules below keep a burst of reported text from choosing in it.
* **Job control.** OTP keeps job control in `user_drv`'s `switch_loop`
  ([research](research-erts-host.md#corrections-and-additions)), which the
  console does not use, so `erx_console` implements it: `Ctrl-G` opens a
  menu that lists the sessions of the line's principal, in a development
  build `root` at the UART, and connects to, interrupts, starts or kills
  one (V7). The menu also locks the line and logs out:
  * **Lock** detaches the current terminal and shows the login prompt with
    the principal's name; the principal's sessions run on, and only a login
    as that principal at that line reaches them again. Another principal
    may log in at a locked line, and its menu shows only its own sessions.
    A lock acts on its own line alone, as locking one UNIX terminal leaves
    the user's other terminals open.
  * **Log out** ends every session the principal started at that line, as
    a hang-up ends a UNIX login's jobs, and shows the login prompt. A
    session started at another line runs on.

  The menu is text the console writes on the line, one entry a line, each
  with its key, as `screen`'s window list is: `s` the system shell, `1` to
  `9` and then the letters but `n` and `s` the principal's live sessions
  by domain id, each by its name and domain id, and `n` "start a session".
  A session is live when its domain pid is up and its tty is named and has
  passed every check; a principal with more sessions than keys is told
  how many are not listed. Esc or `Ctrl-G` returns the line to the session
  that had it while the menu lists it, and otherwise to the system shell,
  and that entry is marked `*`. A session's name is attributed text and
  reaches the menu only through the line escape (V9). Its pure core,
  `erx_console_menu`, decides what the menu lists and what each read
  means, and `erx_console` owns the line and carries the choice out. Three
  rules keep text a terminal writes from choosing in the menu, since a
  person's keys arrive one read at a time: the rest of the read that
  carried the `Ctrl-G` is dropped; a read of more than one byte while the
  menu has the line, such as an arrow key, a paste or a reply, is no key;
  and a byte read while the input is inside a string, escape or control
  sequence the terminal is sending is no key either, but Esc after an
  escape, which no terminal sends; each only rings the bell. Esc leaves
  the input in an escape, so a reply whose `ESC` was read alone, and taken
  for the key, keeps its BEL; a person who types `]`, `P`, `_`, `^` or `X`
  right after it opens a string, and the next `Ctrl-G` only closes it.
  Connecting a session or leaving the menu first ends whatever the line's
  last holder left, a string open or its text hidden, and the system
  shell, when it gets the line back at a terminal, draws its line again,
  since what it wrote while hidden was dropped. A session that ends while
  it has the line, its domain pid ending with `{domain_down, Id, Info}`,
  gives the line back to the system shell after one line, `session root_1
  ended: {halt,3}`, its name and `Info` through the line escape, since a
  crash's slogan is the session's own text. A session the menu shows
  that ends while the menu has the line leaves it, and the menu is drawn
  again under that line; the end of a session the menu does not
  show is not shown at that line unless it is the line principal's, which
  the menu may only count. Only the console
  of a line has the menu: a session's tty relay reads a BEL as a raw tty
  does.

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
  the host link) or 5 from network connections, each class counted apart
  so that a network peer typing wrong passphrases cannot lock a name out
  at the UART, or a line has had 5;
  or unavailable, when the vault's partition or its sealing backend
  fails, or for an enrolment or a passphrase change on a trial boot,
  which the console reports as such
  ([design-system.md](design-system.md#the-vault)). On a match the
  domain service starts the principal's session domain
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas)),
  and the console connects that session's tty at the line. In a development
  build the console logs `root` in at the UART at boot and at the host
  link's `console` line when the host opens it, each a login at a secure
  line (**Secure lines**, above). At the UART the login starts root's
  session, `root_1`, which takes the line once its tty names itself, so
  the first prompt a person answers is the session's command shell, and
  V6 holds in the session's own shells; the system domain's command shell,
  with the system shell one `erl` away, is the menu's `s`. A login session
  that does not report ready within the machine's boot timeout
  ([design-system.md](design-system.md#the-manifest)), as on a machine
  merely slower than its manifest allows for, is started again, as the
  domain service restarts a configured domain, within a start row's
  default intensity: again up to `start_restarts_default` times, 5, in a
  row, counted as a configured domain's timeouts are until a login session
  reports ready ([design-system.md](design-system.md#boot)), so a login
  that hangs is given up whatever the machine's boot timeout; each start
  is stopped at that timeout. A login session that cannot start, or still
  times out past the
  intensity, leaves the line with the system's command shell after one
  line saying why. When a login's session that has had the line ends,
  the console logs `root` in again, as getty starts another login, and the
  new session takes the line; one that ended before it ever had the line
  is not started again, so a session that ends as it comes up does not
  loop. A
  new session, from the login or the menu, takes the lowest name no living
  session holds: `root_1` again once it has ended, `root_2` beside it,
  within the principal's domain quota. Logins at a
  display are not designed: a display serves the session its manifest
  entry names, started without a login
  ([design-display.md](design-display.md#a-displays-session)).
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
  domain and no system-shell authority.
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
  `{log, Level, Text}` with `Text` a binary of at most 4 KiB: through the
  domain's log facet, and in the system domain directly, to the log service
  ([design-log.md](design-log.md#writing)). Two stock handlers remain:
  * `logger_simple_h`, which holds and prints a runtime's log events until
    `erx_log_h` is added, displays them with `erlang:display_string/2`
    (`logger_simple_h.erl:179`, `:230`). Edit 43 makes it build each event's
    text on one line, a format string applied to its arguments, and print
    `erx_text:escape_line/1` of it and a CR-LF in one call, so a boot's early log is
    attributed text at its display like any other.
  * `logger_std_h`, which writes to `user` and falls back to `standard_error`
    (`logger_std_h.erl:680`), is in no domain's default configuration. Given a
    file, it writes data; given a standard device by a principal in that
    principal's own domain, it writes that domain's own output to that domain's
    own tty, under no other name. The system release's configuration names it on
    no standard device, which the release check confirms.

  The log service admits only that shape and at most 16 KiB of log lines per
  second per domain, the rate `erx_debug_log` allows a space, each record
  charged its whole line, and renders each like a kernel log record, stamped
  with the time it arrived, under the domain's id and principal, which come
  from the facet's grantee and the domain service, and then the domain's
  name, with the line escape. A name is unique only within its principal, so
  no domain can pass for another by choosing one, and no domain chooses the
  time its lines show. The service hands each line to the console and to the
  store, which `/var/log` serves ([design-log.md](design-log.md)). A
  program's log lines are its session's: the handler receives them on the
  channel and the session's proxy sends them under the session's id, with
  the program's name in the text.

### Lost input

A console UART has no flow control on its line, so input that arrives
faster than its driver drains the receive FIFO is lost: the mini UART's
FIFO holds eight bytes, about 0.7 ms at 115,200 baud
(`erlang/apps/erx_uart/src/erx_mini_uart.erl`), and a paste overruns it
whenever the driver is late. The driver sees every such loss only
because it is the UART's only user while it runs
([The console](#the-console)): a kernel write between its reads would
hold the UART's interrupts off and, on the mini UART, read `LSR` and
clear the overrun bit that marks the loss, which is why on Fiasco the
kernel's lines go to its ring from the log service's first take
([design-fiasco.md](design-fiasco.md#the-kernels-lines)). Input is lost
in other places too: a frame
the system domain's peer drops on its way to a session's tty, a byte the
tty has no room for, and a character the line editor's bounds refuse. A
command line that lost bytes anywhere must never run: `cd /tmp` with its
`/tmp` lost, followed by `rm -rf *`, is the case to prevent.

**What FreeBSD does.** uart(4) reads the FIFO into a receive ring of
max(384, three FIFO depths) entries (`sys/dev/uart/uart_core.c:635`,
freebsd-src `releng/15.0` commit `2b7df8c1`), and its line discipline
mostly holds input back rather than dropping it. `uart_tty_intr` hands
the ring's entries to `ttydisc_rint` one at a time; a byte that does not
fit the input queue is refused, and uart(4) keeps it in the ring, stops
handing entries up and, under `CRTS_IFLOW`, drops RTS
(`sys/dev/uart/uart_tty.c:335-352`), until reads have drained the queue
to 10%, or nothing in it is a finished line (`sys/kern/tty.c:136`,
`sys/kern/tty_ttydisc.c:428-431`), and
`uart_tty_inwakeup` raises RTS again and resumes
(`uart_tty.c:222-237`). `ttydisc_rint` drops a byte only when nothing in
the full queue is readable, so that a queue full of an unfinished line
cannot stall, and that drop is unmarked
(`sys/kern/tty_ttydisc.c:1220-1236`). Input is otherwise lost only where
the line loses it: once the ring is full the FIFO, no longer read,
overruns (the low-level drivers' receive loops are not checked here). An
overrun the FIFO reports puts one entry, `UART_STAT_OVERRUN` with data
byte 0, in the ring, or, when the ring is full, in its one spare slot,
where the next entry overwrites it, so the mark is lost
(`sys/dev/uart/uart_bus.h:176-221`); the overrun is counted in
`sc_rxoverruns` and the receiver flushed, losing the FIFO's bytes
too (`uart_core.c:322-335`).
`uart_tty_intr` hands that NUL to the line discipline with `TRE_OVERRUN`,
and `ttydisc_rint` acts only on `TRE_BREAK`, `TRE_FRAMING` and
`TRE_PARITY` (`sys/kern/tty_ttydisc.c:1028-1052`); `TRE_OVERRUN`
(`sys/kern/ttydisc.h:68`) is read nowhere in the tty layer. So a FreeBSD
reader gets a NUL byte where the UART lost input, which the line
discipline then treats as any typed NUL: it echoes it, erases it and
charges it to the queue. erXos's console drivers hold input back the same
way, in the FIFO, below.

**The construction: a loss travels as the end of input does.** At every
hop where the end of input is a message or answer of its own, in order
with the bytes, a loss is one too, and nothing on the way gives it a byte
value. A NUL is again only a byte. Every place that drops input makes a
loss at the place of what it dropped, so a loss is never silent. The loss
becomes the byte NUL at one place alone, where it leaves erXos's code for
a reader of bytes, a program; every reader that collects lines refuses
the line instead.

**The invariant.** Every character a group takes after a loss lands in a
damaged request, until the user discards a damaged request: empties its
edited buffer, or ends it with `Ctrl-C`. A damaged request finishes no
line, so no line that follows a loss runs until the user has acted. The
rules below derive it for any interleaving of input, nested reads and
signals. Every loss reaches the group in order before the bytes after it
(the hops below, and a flush that drops a loss reports it ahead of its
signal). When it arrives it damages every unfinished request. From then
on the group takes a character only for its current request, which is
either one that was unfinished at the loss, damaged since, or one
started later, which starts damaged while any unfinished request is
damaged. A request loses its damage only by the user's discard of it or
at the end of input; while one damaged request is still unfinished,
every new one starts damaged again. The premise that closes the
argument is about endings: `group` ends every request through one
function, `pop_state/2` (`otp/lib/kernel/src/group.erl:691`), which
takes how the request ended, and a
damaged request reaches it only by the user's discard (`Ctrl-C`), by
the end of input, or by an error (a driver's `{error, _}`, a failed
translation or collection), since it returns no line. An error is
neither the user's act nor the end, so a damaged request that ends with
one leaves its loss held for the group's next ask, and the next request
takes that loss first, as a held flushed loss is taken. `pop_state/2`
holds the loss at every ending but the user's discard and the end of
input, so an ending that does not say how it ended damages too much,
never too little. Input an error drops with its request is input lost,
and is held as a loss the same way. An answer to no outstanding ask, a
loss or characters the group cannot place, is input lost too: it
damages every unfinished request and is held for the next one, which
starts damaged even after the user discards those: an answer to no ask is
a driver's fault, and nothing tells which request its bytes were for. No other ending
exists: `group` does not watch the process that asked, so a reader's
exit leaves its request unfinished until it ends one of these ways, and
the I/O protocol has no timeout or cancellation on the group's side. So
the only ways out are the user's own discard of a damaged request, or
the end of input, after which no character comes.

| Hop | The end of input | A loss |
| --- | --- | --- |
| console UART driver to `erx_console` | `erx_console_eof` | `erx_console_lost`, after the bytes that certainly came before the loss |
| `erx_console` to a session's tty | `tty_hangup` | `{tty_lost, N}`, numbered in one sequence with `{tty_input, N, Bytes}`; a gap in the numbers is a loss |
| inside a tty | the hangup | a loss unit in the held input, made also where the tty drops a byte for room |
| tty to the line editor's reader | the read answer `eof` | the read answer `lost`, from `{tty_read_input, Open, N}`; a byte read, `tty_read`, gives NUL instead |
| a console to its group | `{Drv, eof}` | the ask's answer `{Drv, {read, Ref, lost}}` |
| group to `edlin` | `edlin:edit_line(eof, Cont, Damage)` | `edlin:edit_line(lost, Cont, Damage)`, and a character `edlin`'s bounds refuse |

**Where a UART's loss is placed.** Only a console UART's driver makes
one. It sends its input as a sequence of messages, bytes as
`{erx_console_input, Bytes}` and each loss as `erx_console_lost`, in the
order it read them; losses with no byte read between them are one. The
rule for placing a loss is conservative: the loss goes before every byte
that might have arrived after it, so a byte is never sent ahead of a loss
it may follow, and a loss placed early damages at worst a line that was
whole.

* **Mini UART.** `LSR`'s receiver overrun bit "is set if ... one or more
  characters arrived whilst the receive FIFO was full. The newly arrived
  characters have been discarded. This bit is cleared each time this
  register is read" (BCM2711 ARM Peripherals, 2.2.2, `AUX_MU_LSR_REG` bit
  1; the FIFO is eight symbols deep, 2.2). So a read of `LSR` that shows
  an overrun says the loss happened after the previous read of `LSR`, when
  the FIFO held eight bytes from before it, of which the driver has read
  `P` since that previous read: one when a data read came between the two
  `LSR` reads, as in a drain, and none when it did not, as in a send's
  poll. At least `8 - P` bytes left in the FIFO came before the loss, and
  any byte after them may have come after it, so the loss goes after the
  next `8 - P` bytes the driver reads, or where the FIFO reads empty if
  that comes first. A newline that arrived after the loss, which the FIFO
  can hold in its last place when the overrun fell between a drain's read
  of `LSR` and its read of the byte, is therefore read after the loss.
* **PL011.** The receive FIFO stores each character with its error bits,
  and `OE` "is set to 1 if data is received and the receive FIFO is
  already full", cleared "once there is an empty space in the FIFO and a
  new character can be written to it" (BCM2711 ARM Peripherals, 11.5,
  `DR` bit 11), and its status "is set immediately when an overrun
  condition occurs" (`RSRECR`). The driver puts the loss before the byte
  whose word has `OE` set. If `OE` rides on the first character written
  after the loss, that is the loss's place; if it rides on the last
  character the full FIFO held, the loss goes one byte early. Either way no
  byte that came after the loss is sent before it.

A drain is finite: the mini UART's reads at most 32 bytes, four FIFO
depths, and the PL011's at most 64 words, two FIFO depths, so a device
that never reports its FIFO empty holds neither driver; and no drain
reads more bytes than the driver's pending store (below) has room for.
A drain that stopped at its bound with room left in the store is
continued by the driver itself, with no delivery to acknowledge, once
the messages already waiting are served. The PL011 needs that: its
interrupt is raised when its FIFO reaches its level, and the driver
clears it before the drain (Arm DDI 0183G, 3-17), so the words a drain
stopped at its bound leaves cross no level again: QEMU's model raises
the interrupt only when the FIFO goes from empty to one word and takes
no byte into a full FIFO (`hw/char/pl011.c`, `pl011_fifo_rx_put`,
`pl011_can_receive`), and silicon raises at most the receive timeout
once the line is idle. The mini UART's interrupt is a level, raised
while its FIFO holds a byte, so its line, still raised, would deliver
again; it continues a stopped drain the same way, and both drivers keep
one rule.

**One input message outstanding per console driver.** A driver that
feeds the console has at most one input message the console has not
taken. The console answers each
`{erx_console_input, Bytes}` and each `erx_console_lost` with
`erx_console_taken`, as `erx_console_written` answers output, and a driver
sends its next input message only after that answer, so the console's
mailbox holds at most one input message from its driver, whatever the
console's delay. While it waits, a driver keeps draining the FIFO into a
pending store of one drain's bytes, 32 for the mini UART and 64 for the
PL011, but reads no more input than the store can hold, as `erx_stdio`
reads no more of a pipe until the answer. Every drain is bounded by the
store's room inside the drain itself, so a delivery's drain, a
continued drain and a send's poll of the receive side alike leave in the
FIFO what the store cannot take; a byte that finds the store full is a
bug, and crashes the driver. A loss takes no room, and losses with no
byte between them are one, so the store holds at most one loss between
two of its bytes.

A drain that stops with the store full pauses the receive side: the
driver masks its receive interrupts at the device, the PL011's receive
and receive-timeout interrupts in `IMSC` and the mini UART's in `IER`,
still acknowledges each delivery that comes, and on the answer that
leaves the store room again unmasks them and drains. Masking at the
device, rather than withholding the acknowledgement, keeps the line
free: the mini UART's interrupt is a level that a byte in its FIFO keeps
raised, so unmasked it would deliver again after every acknowledgement,
and on the Raspberry Pi 4 it shares the auxiliary block's line with the
SPI controllers ([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain)),
which a withheld acknowledgement would hold as well. While the driver is
paused the bytes wait in the FIFO. QEMU's PL011 model takes no byte into
a full FIFO and so holds the line's bytes back; a silicon FIFO overruns,
and the driver marks that loss as above, so a console that falls behind
costs input only where the line itself loses it, marked, and never
memory, as long as the driver is its UART's one reader and writer. On
the Raspberry Pi 4 it is not yet: a polled write of Fiasco's to the mini
UART reads `LSR`, clearing its overrun bit, and saves and restores `IER`
around the write (`fiasco/kernel/src/lib/uart/uart_16550.cc`, `write`),
so it can hide a loss and undo a pause or its end, a residual of
[TODO.md](../TODO.md). The mini UART keeps its marks and its count of data reads since
the last read of `LSR` across a pause, and a send's reads of `LSR`, which
clear its overrun bit, still go through its one reader of `LSR`, so an
overrun during a pause is placed as any other. That the PL011 marks an
overrun with `OE` on silicon is unverified, since QEMU's model sets no
`OE`. On the answer the driver sends what the store holds, bytes and
losses in order, one message at a time, each again after its answer.

A driver waits for the answer without stopping its output: it serves
`{erx_console_output, From, Bytes}` while input waits, so output never
depends on input being taken, and a paused driver reads nothing, so a
noisy line costs it no more than a delivery's acknowledgement. The
**liveness invariant** is the console's: on a person's terminal, as
both UART drivers' lines are, it answers a driver's input message as soon as it handles it, waiting on no group and on no tty, so
a paused driver resumes as soon as the console runs, whatever its groups
and sessions do.

The rule binds only the drivers that feed the console. A driver of
another UART line, the PL011 serving the host link or a Bluetooth
controller, feeding `erx_hostlink` or `erx_line`, sends its bytes as they
come and makes no loss: a store that dropped bytes there would drop them
silently, since not every such protocol checks its frames (H4, the
Bluetooth UART transport, has no checksum), and draining into a store
regardless of the answer would defeat RTS/CTS on a line that has it,
whose sender a full receiver is meant to hold off. The host link's
console line makes no loss of its own, since a frame that fails its CRC
or sequence ends the link's session
([Failure handling](#failure-handling-diagnostics-and-debuggability)).
A terminal on a display, `erx_term`, and an SSH channel lose no input of
their own.

**Both consoles read on demand.** A console's groups never get input they
did not ask for: each group has at most one ask outstanding (edit 72 of
[design-runtime.md](design-runtime.md#the-edits-outside-syserxos)), and
the console answers it with what the bytes read for it complete, or with
`{Drv, {read, Ref, lost}}`. A session's console reads its relay's tty
with `{tty_read_input, Open, N}`
([design-shell.md](design-shell.md#the-terminal-relays-protocol)). The
system console reads a tty of its own the same way, an `erx_tty` in its
process that holds its groups' input and processes a command's bytes on
their way to the driver, its settings chosen by the driver's `Terminal`:

* **A person's terminal** (`Terminal` true, both UARTs and `erx_stdio` on
  a terminal): the prompt's `termios` of [A shell's line editor](#the-tty)
  less `IXON` and `IMAXBEL`, so nothing stops or rings the console's
  output: the driver writes whole what passes this tty, a command's bytes
  alone, under its `OPOST` and `ONLCR`, and the console's rendering does
  not pass it. `ISIG` makes
  `Ctrl-C`, `Ctrl-Z` and `Ctrl-\` signals at arrival, which the console
  carries out as a session's console carries out the relay's events, and
  `ICRNL` reads CR as LF, as a session's prompt does: CR and LF each end a
  line, and CRLF ends two, the second empty. The console answers each
  input message at once, since a terminal's input must keep reaching
  signal processing while the group reads nothing, so `Ctrl-C` reaches an
  Erlang shell's running evaluation however much is typed ahead; what the
  tty's bound drops is a loss.
* **A pipe** (`Terminal` false, `erx_stdio` reading a pipe or a file): every
  flag clear, and no `Ctrl-G` menu, since no person is at the line, so
  `erx_console_keys` does not run and the bytes reach the group as the
  pipe gave them: CR, LF and CRLF unchanged, a byte 3 and a BEL are
  bytes, and a character read gets the byte the pipe held. The console answers an input message only once its
  tty has room for another drain, so a pipe is held back, never cut, and
  nothing is a loss.

So the input waiting for a group is bounded in both roles by one tty's
bound, 4 KiB of bytes and at most one loss between two of them. At
`erx_console_eof` the console hands the group `{self(), eof}` once its tty
is empty, so the end still follows every byte read before it. The system
console's own scan for `Ctrl-C` and `Ctrl-Z` and its push of input to its
group are deleted.

A loss also drops the bytes of a character it cut, which can never
complete it correctly, and returns `erx_console_keys` to its ground
state, as `CAN` does, since what the terminal was sending is damaged.

**A flush keeps its loss.** A signal key flushes the unread input, and the
unread input may hold a loss whose bytes before it are already in the
editing group's buffer: with `rm ` read, a dropped frame holding `-i `, a
`Ctrl-\` and then `target` and Enter, the flush would drop the loss the gap
made, `quit` would leave the read going, and `rm target` would run. So the
console takes the event `lost`, from its relay or from its own tty, as it
takes a read's `lost`, for the group the event names: it answers that
group's outstanding ask with it, or holds it for the group's next ask, so
the read is damaged before any later key reaches it. The signal that
follows then acts as before: `interrupt` ends the current read, and with
it that read's damage and the bytes the console held for the group, but
not a loss the console holds for the group's next ask, since a read set
aside may resume; `quit` and `suspend` leave the read going, damaged. A `lost` that arrives while the group reads
nothing, as during an Erlang shell's evaluation, damages its next read,
which costs the user one emptied buffer and never runs a damaged line.
While the menu has the line a loss rings the bell, as any byte that is no
key does; while a session has the line, `erx_tty_master` sends the
session's tty `{tty_lost, N}`.

**One input sequence across domains.** A master numbers its input
messages, `{tty_input, N, Bytes}` and `{tty_lost, N}` alike, from 0 when it
and the tty first meet, as the tty numbers its output, and the tty checks
the number before it takes either. A number one above the last it took is
the next message. A higher number is a gap: the messages between were
lost on the way, so the tty takes a loss at that place first and then the
message. A number not above the last is refused, dropped and counted. A
gap costs no retransmission and no hangup: every byte that came after a
lost message comes in a later-numbered one, which shows the gap before the
tty takes the byte, so a dropped `tty_lost` or `tty_input` is a loss at
its place, not a silent one. A master in the tty's own domain numbers the
same way, though its plain messages are never dropped, so the protocol has
one form.

**The tty.** `erx_tty`'s held input is a sequence of units, each a byte or
a loss. `lost(Tty)` appends a loss, and `input/3` appends one where it
drops a byte for room. A loss is no byte the terminal sent: it matches no
special character, echoes nothing and takes no byte of room, so a loss is
kept when the bytes fill the bound; units are bounded all the same, since
losses with no byte between them are one, so a tty holds at most one loss
more than its bound has bytes.

* **Readiness.** The tty settles its waiters over units: a loss counts as
  one unit wherever a byte counts, for `VMIN`, for a `poll` and for the
  first unit that starts a `VMIN` and `VTIME` timer, and is no line end.
  So `lost/1` returns the same actions `input/3` returns for one byte that
  ends no line and makes no signal: the `{ready, Open}` reports and the
  `timer_start` it causes and the next state. A loss alone makes a raw
  read with `VMIN` 1 and a raw `poll` ready, and with `VMIN` 2 and `VTIME`
  1 starts the timer.
* **Consuming.** One operation takes units from the front of the readable
  input, at most a given count, up to the first line's end when the tty is
  cooked; both reads use it. `read/3` takes at most `Max` units and gives
  each loss as one NUL at its place, so a raw read of `ab`, a loss and
  `cd` with `Max` 5 returns `ab`, NUL, `cd`, and a short `Max` takes that
  many units. `read_input/2` takes one unit and answers it as a byte or as
  `lost`. A cooked line ends at its newline, `VEOF` or `VEOL` as before; a
  loss is a unit of the line, so a line of a loss and `VEOF` is a line of
  one NUL, not an end of file.
* **Editing a cooked line.** An erase never removes a loss alone: `VERASE` and
  `VWERASE` remove bytes before the cursor and keep the line's losses at
  its new end, and only an edit that removes the line's last byte drops
  them; an edit that finds no byte changes nothing, as a key that leaves
  `edlin`'s empty buffer empty clears no damage. So a loss alone on a line,
  where `cd /tmp` and its newline were lost whole, survives a habitual
  `VERASE` or `VKILL` and reaches the program as a NUL on the next line,
  and one rule clears a damaged line in the tty and in `edlin`.
* **Moving units.** A change of `ICANON`, `VEOF` or `VEOL` recounts what
  is readable over units, so a cooked line's losses move with its bytes.
  A signal's flush and a hangup drop losses with the bytes, as FreeBSD's
  `tty_flush` drops the queue (`sys/kern/tty_ttydisc.c:1124-1133`), but a
  flush never drops a loss unseen: when the input it drops holds one, it
  returns `flushed_loss` ahead of the signal, which the relay passes on as
  the event `lost` (below) to the console, the one holder that reads lines
  for groups, and to no job's shell. A hangup needs none, since it ends
  every read.
* **A program's own line.** A program that edits its own line in raw
  mode, as a line editor library does, gets a loss only as the NUL it
  reads, as on FreeBSD, and is otherwise unprotected: a loss that a
  signal key flushes before the program reads it reaches it not at all,
  so with `rm ` already read, a dropped frame, `Ctrl-\`, `target` and
  Enter, a program that leaves the read going at `quit` runs `rm target`,
  as on FreeBSD, whose flush drops the overrun's NUL with the queue
  (`sys/kern/tty_ttydisc.c:1124-1133`). Under the cooked `termios` the line is the tty's own, which the
  flush drops whole with its loss.

**Compatibility with FreeBSD.** A program's read of a loss the UART made
gives the NUL FreeBSD's read gives at that place, and that byte is all the
compatibility claimed. The rest differs on purpose: a loss echoes nothing
where FreeBSD echoes `^@` under `ECHOCTL`; an erase never removes it, so
`ab`, a loss, `VERASE` and a newline read as `a`, NUL and a newline where
FreeBSD reads `ab` and a newline; it takes no byte of room; and a byte the
tty drops for room, or a gap in the master's numbers, reads as a NUL where
FreeBSD drops silently. Each keeps a damaged line damaged.

**The group and `edlin`.** Each of the group's input requests carries a
damage of its own, saved with it when `group` sets the request aside to
serve another read and restored with it when it resumes, and gone with
the request at its answer. `group` passes the current request's damage
into every call of `edlin`'s editing and takes it back from the result,
`edlin:edit_line(Input, Cont, Damage)`, so a line state `group` rebuilds
during a read (a history move, a search, a format, an external editor)
cannot lose it. The group's damage is not stored anywhere: it is the
derived fact that some unfinished request of the group is damaged. Three
rules use it, and every way a request changes is one of them:

* **A loss damages every unfinished request**, the current one and every
  one set aside, since the group's one ask outlives a nested read, an
  Erlang shell's `io:get_line/1` or `io:get_password/0` from another
  process, and whichever request is current takes the answer, so the
  bytes the loss stands for may have been meant for any of them. A
  character `edlin`'s bounds refuse arrived for the current request, so
  it damages that request alone.
* **A request starts with the group's damage**: damaged when any
  unfinished request of the group is damaged, undamaged otherwise.
* **A request's damage ends only by the user's discard or the end of
  input**: when the user empties its own edited buffer, when `Ctrl-C`
  ends it, or at the end of input. A damaged request that ends any
  other way, with an error, leaves its loss held for the group's next
  ask, beside the group's one ask, which outlives requests already.
  The end of one request clears nothing of another's.

Two nestings show the rules at work, with no case of their own. A prompt holding
`file:delete("`, a dropped frame holding `scratch/`, then
`io:get_password/0` from another process and a `Ctrl-C`: the loss
damages both reads, the interrupt ends the password read, and the prompt
resumes damaged. The other nesting, a helper's `io:get_line/1` damaged
by a loss of `% ` from a pasted `% file:delete("important").`, and then
the shell's next command read: that read starts damaged, because the
helper's read is unfinished and damaged, so the paste's rest runs
nothing. Each of the group's modes then does one thing:

* **Edited** (`edlin`): a loss damages the read, drops any escape sequence
  under way and rings the bell, and so does an inserted character that
  `edlin`'s bounds refuse, the 65,536 codepoints of a line or the 32 of a
  grapheme cluster (edit 73), since that character is input lost. An
  operation that is not the insertion of received input and that a bound
  refuses whole, a yank, a history recall or a format, leaves the line
  and its damage as they were, with the bell. A damaged read finishes no
  line: Enter, an accepted history search and every other way out of
  `edlin` pass through its one finishing function
  ([design-runtime.md](design-runtime.md#the-edits-outside-syserxos),
  edit 81), which refuses while the read is damaged and rings the bell,
  and keeps editing; at the end of input it drops the line and hands the
  end on, so the read ends. The damage ends only when the edited buffer,
  every line of a multi-line edit together, is emptied by an explicit
  discard or by an edit that removes text and leaves nothing (`Ctrl-U` at
  the end of a one-line buffer, erasing its last character), or when the
  read ends, as `Ctrl-C` ends it at a prompt. A key that leaves an
  already-empty buffer empty ends nothing, so a read that starts damaged,
  or a loss before the first character, keeps the damage until text typed
  after it is emptied again. Moving through the history or searching it
  keeps the damage, since the line it shows replaces what the user sees,
  not what the read lost. Text keeps the damage of the read it came from
  wherever `edlin` stores it: the kill buffer, which the caller keeps beside
  the read and a group in its state, a value each edit passes on with its
  damage, which the group's reports hide
  ([design-runtime.md](design-runtime.md#the-edits-outside-syserxos), edit 75,
  says what a report hides and what its own domain sees); a kill in a damaged read stores its text
  damaged, and a yank of damaged text damages the read it lands in, the
  same read or a later one,
  so `Ctrl-U` then `Ctrl-Y` cannot bring a damaged line back undamaged;
  the history stack, whose lines a search reads as text, does not keep a
  damaged read's line at all. A refused Enter drops the rest of the
  delivery that carried it, with its one bell, so what that delivery
  carried after the Enter, a password meant for a later read with echo
  off among it, is not echoed into the line; later deliveries, the rest
  of a paste the console cut into several among them, edit the line as
  usual, damaged still, and nothing runs until the user has emptied the
  buffer.
* **Dumb** (no editing, cooked collection): a damaged read returns no
  line: each line it collects is dropped through its newline, with the
  bell, until the read ends, by `Ctrl-C` or at the end of input. Dumb
  mode has no buffer the user can empty, so `Ctrl-C` is its one discard.
  On a console UART it is reached only by reads with echo off, such as
  `io:get_password/0`, because both UART drivers report a terminal, and
  a pipe, the other dumb reader, makes no loss.

`erx_console` puts no group in raw mode (`terminal_mode` raw, characters
as they arrive), so no raw-mode request exists on a console and this
design gives it no rule; a console that offered raw mode would need one
that keeps the invariant.

**Ordering.** Each hop is one sender to one receiver: the driver to its
console and a console to its group are Erlang messages between one pair
of processes, which arrive in the order sent; the console's frames to a
session's tty go through one lane in send order (D9), and the input
numbers turn a frame the peer dropped into a loss at its place; a tty
holds each loss at its place among the bytes; and a console reads its tty
through calls answered in turn. No hop reorders a loss against the bytes
around it, so the loss reaches `edlin` between the keys typed before and
after it, however the input was cut into deliveries.

**Failure paths and refusals.**

* `{tty_lost, N}` has one shape; the tty drops and counts any other, as it
  drops a bad `tty_input`, and ignores both after a hangup. A message that
  comes through another domain's envelope than the tty's master's is not
  the master's, and the relay takes none of it. A master that gets
  `tty_lost` from a tty detaches the tty, as for any message the table
  does not list.
* `{tty_read_input, Open, N}` has `tty_read`'s checks: `{error, ebadf}` on
  a write-only open, and `eagain` when another reader took the unit, the
  open may not read or `N` is not the relay's signal number.
* Storage is finite at every hop: a drain reads at most 32 bytes or 64
  words, and no more bytes than its driver's store has room for; a
  console driver has one input message outstanding and holds at most
  one drain's bytes, with at most one loss between two of them, while it
  waits for `erx_console_taken`, so the console's mailbox holds at most one
  input message from its driver however long the console is delayed; a
  console holds at most one ask's answer, and one held loss, for each
  group, and a tty's bound of input; a tty holds at most one loss more
  than its bytes; a session's tty takes its master's frames, which the
  peer bounds by the lane and drops past it, a drop being a gap and so a
  loss; and the damage is one fact of each input request. A damaged line grows only
  with the paste that follows it, up to edit 73's bounds, whose refused
  characters keep it damaged.
* A master that reports losses without end, or a device that does, keeps
  every line from finishing on its tty; a master can also send any bytes
  it likes. Neither is a crossing of authority: only the tty's own master
  reaches the tty, and the driver is the line's.
* No read outlives the path that fed it: the end of the system console's
  driver ends the runtime, and a master's end hangs its tty up, which
  ends the tty's shells, so a loss in flight cannot be forgotten by a
  read that goes on.

**Concepts before and after.** Before: the marker byte
(`erlang/apps/erx_uart/src/erx_uart_marker.hrl`), which every consumer of
line bytes had to know; `edlin_key` reading NUL as a character and ending
any escape sequence at it (edit 80); `edlin`'s scan of the line for NUL at
each finish; the hold after a refused Enter, with its sorting of keys into
dropped text, line ends and edits; `group`'s rule that a line holding NUL
is not kept when moving through the history; a search term holding NUL;
the system console's own scan for `Ctrl-C` and `Ctrl-Z` and its push of
input to its group; and the open cases that followed from the double
meaning, a typed `Ctrl-@` or a PL011 break holding the line, dumb mode
returning a marked line, and a refused search resending its requests.
Silent losses stood beside them: a dropped `tty_input`, a byte the tty
dropped for room, a character `edlin`'s bounds dropped, and the mini
UART's late mark. After, one event, carried by each hop's existing
protocol beside its end of input, and one fact of a read. Their
obligations are these, each with one owner:

* every master numbers its input, and the tty checks the number before it
  takes a byte or a loss (`erx_tty_link`);
* every step of `erx_tty` that removes held input keeps the losses among
  the bytes, the tty settles its waiters over units, and one consuming
  operation serves both reads (`erx_tty`);
* every place that drops input makes a loss there: the drivers' placement
  rule, the tty's bound and `edlin`'s bounds;
* a loss damages every unfinished request of a group, a request starts
  damaged while any unfinished one is, and each request carries its damage
  through suspension and every
  `edlin` call (`group`), and `edlin`'s one finishing function refuses a
  damaged read;
* both consoles read on demand through one reader, and every driver that
  feeds the console has one input message outstanding, answered as output is: at once for a person's
  terminal, which overflows into a loss, and once there is room for a pipe,
  which waits;
* a flush never drops a loss unseen by a line read of the console's: it
  reports `flushed_loss`, the relay passes it on as `lost` only while the
  console holds, and the console damages the read the signal leaves going.

A typed NUL is stock's key bound to nothing, the PL011's break is the
byte the UART read, and the hold, the scan, the history rule, the marker
byte and the system console's push path are deleted.

**Verification.** Each case is paired with a seeded fault that makes it
fail, so the case proves the code under it ran.

| Test | What passes | Seeded fault that must fail it |
| --- | --- | --- |
| `erx_mini_uart_tests`, a fake device: `LSR` shows data, a byte is read, the next `LSR` shows an overrun, and the FIFO then gives seven bytes and a newline | the drain's messages are the bytes before, the seven bytes, `erx_console_lost`, then the newline | the loss placed after eight bytes, as if no byte had been read since the previous `LSR` |
| the same, the overrun shown by a send's poll of `LSR`, with no data read between | the loss after eight bytes | the loss placed after seven |
| the same, a fake device whose `DATA_READY` never clears | each drain sends at most 32 bytes and returns; the line delivers again | the drain bound removed |
| `erx_pl011_tests`: a data word with `OE` set | `erx_console_lost` before that word's byte | the loss sent after the byte |
| the same, a fake device whose `RXFE` never sets | each drain reads at most 64 words and returns | the drain bound removed |
| the same, a played line's driver whose FIFO, after the start's drain, holds a 150-byte paste and reads empty only after it | every byte goes up after one delivery, with one acknowledgement | the stopped drain left for an interrupt; the continued drain acknowledging the line |
| the same paste on a played console's driver, each message taken only once the driver is quiet | every byte goes up, with no `erx_console_lost` | none of its own: the late console's row seeds what it covers |
| the same, a drain into a store with room for two bytes, the FIFO holding `a`, `b` with `OE` and `c` | the drain gives `a`, the loss and `b`, and stops | the drain reading past the store's room |
| `erx_console_master_tests`, the system line through the real group and `edlin`: `ab`, a loss, `c` and Enter | no line is returned; the bell rings | the console answering an ask with the loss after the next byte |
| the same, a loss after the first byte of a two-byte UTF-8 character | that byte is dropped and the loss answered | the cut byte answered as a character |
| the same, a group that asks nothing while 10 KiB, then a loss, then more arrive | the console holds one tty's bound; what it dropped is one loss, which the next read meets before the later bytes | the store's drop not marked as a loss |
| hosted mode, a 64 KiB script piped into `erx_stdio` (`Terminal` false) with a group that reads slowly | every line runs and the shell halts at the end with status 0 | the console answering a pipe at once, so the bound drops input and a line is refused |
| hosted mode on a terminal: an Erlang shell evaluating `timer:sleep(infinity)`, 8 KiB typed ahead, then `Ctrl-C` | the evaluation is interrupted | the console answering a terminal's input only when its tty has room, so `Ctrl-C` waits upstream |
| the same, `erx_stdio` waiting for `erx_console_taken` while the shell writes 64 KiB | all the output is written | the driver's wait for the answer not serving output |
| the system console, a pipe giving `a` CR `b` LF `c` CR LF, read by `io:get_line/1` and by `io:get_chars/2` of one character | the bytes reach the group unchanged; the character read gets CR | the pipe given the terminal's `ICRNL` |
| the same, a pipe giving `a` BEL `b` LF, read by `io:get_line/1` and by `io:get_chars/2` of one character after `a` | the line is `a`, BEL, `b`; the character read gets BEL; no menu opens | menu recognition run on a pipe |
| the system console on a terminal, CR, LF and CR LF each after a word | CR and LF each end the line; CR LF ends it and then an empty line | `ICRNL` cleared for a terminal |
| `erx_mini_uart_tests` and `erx_pl011_tests`, a late console: 200 bytes arrive in bursts of ten, each once a drain reads the FIFO empty, and each message is taken only once the driver is quiet | every byte goes up, with no `erx_console_lost` and one message outstanding at a time; the receive interrupts are masked while the store is full and unmasked at the end; the mini UART's level line is not delivered again and again | a drain ignoring the store's room (the store's crash); the interrupts left masked on the answer; a full store left unmasked (the PL011's mask never written; the mini UART's level line delivered after every acknowledgement); a message per drain without waiting |
| `erx_console_keys_tests`: a loss inside an OSC string, then `Ctrl-G` | the menu opens | the parser's state kept across the loss |
| `erx_tty_master_tests`: a session has the line; bytes, a loss, bytes | `{tty_input, 0, _}`, `{tty_lost, 1}`, `{tty_input, 2, _}` | the loss sent without a number of the sequence |
| `erx_tty_link_tests`: numbers 0, 1, 3; then 2; then `{tty_lost, x}`; then a loss after a hangup | 3 is taken after a loss at its place; 2 is refused and counted; the bad shape is dropped and counted; the late loss is ignored | the gap check removed, so 3 is taken with no loss |
| `erx_session_relay_tests`: `{tty_lost, N}` through another domain's envelope than the master's | not taken; the tty is unchanged | the envelope check skipped for `tty_lost` |
| `erx_tty_master_tests`: a tty sends `{tty_lost, 0}` | the master detaches the tty | the master taking it |
| `erx_tty_tests`, raw: `ab`, a loss, `cd` with `VMIN` 5 | ready at the fifth unit; `read/3` of 5 gives `ab`, NUL, `cd`; `read_input/2` gives `a`, `b`, `lost`, `c`, `d` | a read that does not shift the remaining losses |
| `erx_tty_tests`, raw: a loss alone with `VMIN` 1, with a `poll`, and with `VMIN` 2 and `VTIME` 1 | the read and the poll are ready; the timer starts | readiness counting bytes only |
| `erx_console_master_tests`, a session: `rm ` read into the editor, frame 1 (`-i `) dropped, frame 2 `Ctrl-\`, frame 3 `target` and Enter | no line is returned; the bell rings | the flush dropping the gap's loss without `flushed_loss` |
| the same with `Ctrl-Z` in frame 2, and with `Ctrl-C` | `Ctrl-Z`: no line is returned; `Ctrl-C`: the read ends, and the next read is undamaged | the ended read's damage passed on to the next read |
| `erx_tty_tests`, raw: 4 KiB waiting, then three bytes | one loss after the 4 KiB, kept though no byte of room is left | the drop not marked |
| `erx_tty_tests`, cooked: `cd`, a loss, `/`, then `VERASE`, then `VKILL`; a loss then `VEOF`; `ICANON` cleared over a line with a loss | the loss stays after the erase and is gone after the kill; the second line reads as one NUL; the loss moves to the readable input in its place | an erase that removes the loss |
| `erx_tty_tests`, cooked: a loss on an empty line, then `VERASE`, `VWERASE` or `VKILL`, and newline; then a loss, `x`, `VERASE` and newline | each of the first reads NUL and newline; the last reads a newline alone | an edit that removes no byte dropping the line's loss |
| `erx_tty_tests`' exploration and `erx_tty_fuzz` | `lost` is in the event alphabet; every reachable state keeps losses within the held bytes, one at most between two bytes | losses not dropped by a signal's flush |
| `erx_session_relay_core_tests`: `tty_read_input` on a read open, a write-only open, and with a stale signal number | `lost` at a loss; `{error, ebadf}`; `eagain` with the unit still held | the request served with a stale number |
| `erx_session_relay_core_tests`: `rm `, a loss and `Ctrl-\` while the console holds, and the same while a job holds | the console gets `lost` and then `quit`, with its group; the shell gets `quit` alone | the console's `lost` dropped; `lost` sent to the shell |
| `edlin_lost_tests` (replacing `edlin_marker_tests`), through `edlin` and a group: a loss, more text, Enter | no line finishes; the bell rings at the loss and at Enter | the finishing function ignoring the damage |
| the same: a loss, `Ctrl-U` at the end, new text, Enter | the new line finishes | the damage cleared by any edit key |
| the same: a loss before the first character, `Ctrl-U` on the empty buffer, text, Enter | no line finishes | a key that leaves an empty buffer empty clearing the damage |
| the same, a multi-line edit: a loss in its second line, that line emptied, Enter | no line finishes until the first line is emptied too | the current line's emptiness taken for the buffer's |
| the same: a loss, a history move, Enter | no line finishes | the history move rebuilding the line state without the damage |
| the same: a loss, then more text, Enter and a pasted password in one delivery, then text in the next | no line finishes; the bell rings once at Enter; the password is dropped and the next delivery's text joins the line | the refused Enter keeping the rest of its delivery |
| the same: `rm -rf /tmp/bu`, a loss, `Ctrl-U`, `Ctrl-Y`, Enter; the kill, `Ctrl-C`, and a yank and Enter in the next request | no line finishes in any; after the kill neither the group's process dictionary nor `sys:get_status` shows the killed text (`otp_report_status_tests`) | a kill storing its text without the damage; a yank ignoring the damage; a kill buffer kept in the process dictionary |
| the same: a damaged read's history search, accepted with Enter, left with `Ctrl-A` to edit, or cancelled, then Enter | no line finishes | a search's ending rebuilding the line state without the damage |
| the same: read A undamaged, read B from another process, a loss answering no outstanding ask, B's line and Enter; B's buffer emptied, a new line and Enter; then A resumes and Enter | B finishes no line until its buffer is emptied, then returns the new line; A finishes no line | the stray loss dropped, or only held for the next request |
| the same: a stray loss while no request reads, then a read, a line and Enter | no line finishes | the stray loss dropped |
| the same: a read and `ls`, a loss answering no outstanding ask, `Ctrl-U`, `pwd` and Enter; then a new read, `x` and Enter | the first read returns `pwd`; the second finishes no line | the stray loss not held past the discard (`held_loss` left unset for an answer to no ask) |
| the same: a read, an answer with characters to no outstanding ask, a line and Enter | no line finishes | the stray characters dropped as an unknown message |
| the same: a loss, then `Ctrl-U`, a new line and Enter in one delivery, then the next request's line | both lines finish | the ending reading the damage from before the edit |
| the same, dumb mode: a read in latin1 that a pasted line fails, with more lines pasted after it, then the next read's line | the first read fails; the next returns no line | the input the error drops not held as a loss |
| the same, nested edited reads: read A damaged, then read B from another process, B's line and Enter; B's buffer emptied, a new line and Enter; then A resumes and Enter | B starts damaged and finishes no line until its buffer is emptied, then returns the new line; A finishes no line | B starting undamaged |
| the same, the reversed nesting: a helper's `io:get_line/1` A takes a loss of `% ` from a pasted `% file:delete("important").`, the evaluation ends and the shell's command read B starts, then `file:delete("important").` and Enter | B finishes no line | B starting undamaged while A is damaged |
| the same, an error ending: the only request A damaged by a loss, the driver's `{error, x}` ending A, then the shell's next read B, a line and Enter | A answers `{error, x}`; B takes the held loss first and finishes no line | the error ending dropping A's loss, so B starts undamaged |
| the same, a refused character: B damaged by a grapheme cluster of 33 codepoints, then read C from another process, a line and Enter | C starts damaged and finishes no line | a request started while another is damaged by a refusal starting undamaged |
| the same, nested password read: read A undamaged, `io:get_password/0` B with a loss, then B's next line, then `Ctrl-C`, then A's Enter | B returns no line and ends interrupted; A resumes damaged and finishes no line | a loss damaging only the current request |
| the same, prompt A holding `file:delete("`, frame 1 (`scratch/`) dropped, `io:get_password/0` B from another process, frame 2 `Ctrl-C`, frame 3 `important").` and Enter | B ends interrupted; A resumes damaged and finishes no line | the end of B clearing A's damage |
| the same sequence with `Ctrl-\` in frame 2, then a clean line for B | B returns no line; A stays damaged under it | a damaged dumb read returning the next line |
| the same sequence with `Ctrl-Z` in frame 2 | as with `Ctrl-\` | as with `Ctrl-\` |
| the same: a short command with a grapheme cluster of 33 codepoints, Enter | no line finishes | the refused character dropped with the bell alone |
| the same: a line at 65,536 codepoints, one more character, Enter; and a yank the bound refuses, Enter | the first finishes no line; the second finishes the line unchanged | a refused yank damaging the read |
| the same: a loss at the end of input | the line is dropped and the read ends | the line returned |
| the same: a typed NUL, and NUL after `ESC [ 3` | the NUL is dropped and the line finishes; no crash | NUL read as a character |
| the same, dumb mode: `pass`, a loss, `word` and a newline, then `next` and a newline, then `Ctrl-C` | no line is returned; the read ends interrupted, and the next read is undamaged | the damaged read returning `next` |
| `erx_console_input_fuzz` | losses in its alphabet; no crash, and no line with a loss in it is returned | the console answering a loss as NUL |

The QEMU console suite pastes over the UART at the line's rate and
passes on whatever the guest's timing gives, so it cannot be the test of
a loss; the host tests above drive the real console, group and `edlin`
with the driver's messages, and the drivers' tests drive a fake device
whose reads are scripted.

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
* `erx_render` escapes inspection records, in the Erlang shell and in
  the command shell's inspector commands.
* The command shell's `ls` escapes the names it prints when its output
  is a terminal and writes them as their bytes elsewhere, as FreeBSD's
  `ls` does, so `cat f` after `ls > f` shows a name a domain chose as its
  bytes; `ps` writes names and arguments through the field escape
  wherever its output goes, as FreeBSD's writes them through `strvis(3)`
  ([Pipelines](design-shell.md#pipelines)). A line a command reads and
  passes on, as `grep` and `sort` do, is its writer's output, not
  labelled text, and reaches the terminal as through `cat`.
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
U+202E. The line escape is for a display; text written into a file or a
pipe is written by the field escape below, or not escaped at all. The
escape takes whole text, since a record is whole when it is displayed,
and holds no state between calls. One record is one line under its
source's name.

The **field escape**, `erx_text:escape_field/1`, is how `/proc` writes
attributed text into a file, and `ps` into its output. Tab, newline and
backslash become `\t`, `\n` and `\\`, every byte of a character the line
escape renders and every byte the line escape writes as a byte token
become `\x` and two upper-case hexadecimal digits, such as `\xE2\x80\xAE`
for U+202E and `\xC0` for a stray `0xC0`, and everything else passes
unchanged. Because the backslash is
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
it; its language, commands, pipelines of text, jobs and terminal relay
are [design-shell.md](design-shell.md), `ps`, `top` and `ls` among the
commands ([Text commands](design-shell.md#text-commands)). Each command
shell runs on one of the session's ttys above, the console line's or, at
a display, its terminal window's
([design-display.md](design-display.md#the-terminal)), and its Erlang
commands reach the inspector, `/proc` and the code store below with the
session's facets. Its commands print text as FreeBSD's commands of the
same names do, with a value erXos does not measure printed as `-`
([Pipelines](design-shell.md#pipelines)); a process as a live value,
with each value's status and reporter, is the Erlang shell's `erx:ps()`
and `erx:i/1`.

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
* **Runtime attributes** come from the domain's inspection agent,
  `erx_inspect_agent`, a process each domain starts at boot, which runs
  `process_info/2` and friends inside the domain and answers with a frame
  on the domain's connection to the system domain, which the system
  domain's funnel validates before the inspector decodes it
  ([design-domains.md](design-domains.md#the-funnel), [The runtime
  agent](#the-runtime-agent)). A late answer becomes `{timeout, 500}`
  (`inspect_agent_wait`, 500 ms, which the interface declares), a domain that is booting `unknown`, an attribute
  the runtime cannot provide `unsupported`, a list cut at the page limit
  of 1,000 entries `partial`. For the system domain's own processes the
  inspector calls the same collectors in its own runtime.

**Scopes.** Queries arrive through an inspect facet whose scope is `all` or
a principal's domains, with the machine trees its grantee's other
grants entitle it to read, and which also carries its grantee's principal.
Both live only in the facet, in the system
domain, fixed when the facet is minted ([The inspect
service](#the-inspect-service)); a holder sends a path and its options and
nothing else, so no view and no value of the holder's own runtime can
translate or widen them. The scope decides every attribute but those of
the visibility class `display`, a window's tree, which the principal
decides and no scope reaches, `all` included: the inspector answers
one only to a caller whose principal is that of the domain that owns
the path or that of the session of the display the window is on, which
it resolves at each query from the domain service's records of the
domain's grants and of each display's session
([design-display.md](design-display.md#the-widget-server)). To every
other caller such an attribute is outside the scope, with the answer
that gives. In the system domain, whose services are its own,
`erx:i/1`, the shell's commands and `/proc` call the inspector in the same
runtime at scope `all`. A session's inspect facet has scope over its
principal's own domains, with one exception: in a development build
`root`'s session holds one of scope `all`, as the host link does
([The host link](#the-host-link)). In a release build no session's facet
has scope `all`, and machine-wide inspection is done in the system shell
at a secure line. A path's owner is decided by construction: a process's
domain is its pid's creation, a program's is the session under whose path
it lies, and every other path names its domain or belongs to the machine.
A scoped facet reaches only the paths its domains own and the machine's
`visible any` attributes: listings contain only its domains, `[]` and
`[cpus, N]` show only the machine attributes the schema marks `visible
any`, `[cpus]` lists the CPUs, `[time]` shows the clock's record, and
every other machine-wide path
(`[groups, ...]`, `[budgets, ...]`, `[devices, ...]`, `[kernel, ...]`)
answers `{error, scope}`; a domain's own group and budget are under its
path. The one machine tree a grant adds is the start table's: a scoped
facet whose grantee is a session template that holds the start
service's tree, `start`, also reaches `[apps]` and every `[apps, Name]`,
so whoever may command the start table, and edit `/etc/start.conf`,
reads the table's applied state, its last read's problems and its
rows' names, which `service status`, `service -e` and `service -c`
need ([design-apps.md](design-apps.md#interfaces)). It reaches nothing
else the scope did not: a row's `domain` attribute names the session's
domain, whose own path `[domains, Id]` stays outside the scope unless
the principal is the facet's, and a release build still gives no
session scope `all`. A path outside the scope and a path that names nothing get the
same answer, `{error, scope}`, so a scoped facet cannot learn whether a
process outside its scope exists. The machine attributes `visible any`
are those every UNIX user reads: the build identifier, the development
flag and the DMA profile, which reveal nothing of other domains, and the
uptime, the CPUs online and the memory total and free, which `uptime`
and `top` show anyone, and each CPU's idle time and ready threads, the
machine's load. Free memory moves as other domains commit and release
pages, and a CPU's idle time and ready threads as other domains run, so
they tell a domain how busy the others keep the machine; erXos accepts
that side channel so that every session sees the machine's load, as the
desktop's `stats` shows it
([design-desktop-programs.md](design-desktop-programs.md#stats)).
The clock's record, `[time]`, is `visible any` but for two attributes:
whether this boot set the clock, and the clock service's last sample
and step, so that every session can tell whether its wall time is real
([design-time.md](design-time.md#what-proc-shows)). The domain that
sent the sample and the server it came from, `source` and `server`,
are facts of another domain and stay `visible all`, as a CPU's running
thread, interrupts and throttled groups do.

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
every value's reporter, and below the table the scope of each backend
reporter it names.

#### The inspect service

The inspector is reached from another domain through one interface,
`inspect`, which `abi/services/inspect.txt` declares and which cites
this section. Its three operations are the inspector's three queries:

| Operation | Request | Answer |
| --- | --- | --- |
| `inspect` | `Path`, `Options` | `{ok, Record}`, or `{error, Reason}` with `Reason` one of `scope`, `unsupported`, `invalid`, `failed` and `badarg` |
| `entries` | `Path` | `{ok, Records}` or `{partial, Records}`, the records of a listing's entries, or `{error, Reason}` with `Reason` one of `scope`, `unsupported`, `failed` and `badarg` |
| `literals` | `Path` | `{ok, Literals}`, the literal segments the schema declares below `Path` that name something to the caller, in the schema's order, or `{error, Reason}` with `Reason` one of `scope`, `failed` and `badarg` |

`literals` answers which of a path's declared children exist for the
caller without collecting any record: from the schema, the scope check
of `inspect` and the facts the query worker holds before it collects,
whether a domain is living in the domain service's view and whether
this runtime collects a domain's records. A literal path names something
exactly where the scope reaches it and those facts admit it, since no
collector of a literal path answers `{error, scope}`: a collector that
cannot answer says `unsupported` or `failed`, which a `status` file
shows. So `Literals` holds exactly the children whose `inspect` would
not answer `{error, scope}`, and it never names a path outside the
scope; a path the scope does not reach answers `{error, scope}`, as
`inspect` does, and one whose children are entries rather than literals,
or one within the scope that names nothing, such as a domain that ended,
answers `{ok, []}`. Below `[domains, D]` the facts differ by child: a
domain's `group` and `budget` exist while the domain lives, and its
`threads`, `modules` and `processes` only where the system domain's
runtime collects them, for the system domain itself.

A path is data, so a value someone needs to read is a path of
`abi/inspection.txt` and never an operation, a facet or a validator of
its own: the kernel log is `[kernel, log]` through `inspect`, as at the
system shell. An ordinary listing has no continuation: `entries` returns
its first page, marked `partial` when it was cut, and a reader that needs
what the page left out narrows its path; only an append-only record's
`Next` resumes where a page stopped.

**Who holds one, and its scope.** The system manifest declares the
service once, served by the system domain, and its facet rows name the
grantees. The default manifests grant it to every session template, so
every user can run `erx:i/1` and read `/proc`, and a manifest that
wants sessions without it leaves the row out. They grant it to no
configured domain: a configured service's principal is commonly the
`system` principal, which the configured domains share
([design-system.md](design-system.md#identifiers)), so its `{principal, P,
Trees}` would reach far beyond the service, and a manifest grants it to one
only for a need of that domain's own. The web domain holds none; its views read through
the session's ([design-web.md](design-web.md#overview)). The process
that serves `inspect` in the system domain, the one every inspect facet
names as its service and ends with, is `erx_inspect_srv`, which
`kernel`'s supervisor starts before the domain service; it takes no
request itself, since each facet forwards its requests to query workers
(below), and its end ends every inspect facet. The domain
service starts each facet in the system domain, in front of the
inspector, and sends it with the grantee's ready answer, a session's and
a configured domain's alike
([design-system.md](design-system.md#facets-a-configured-domain-serves),
"Facets of the system domain's services"), with the scope
that one pure function, `erx_domain_core:inspect_scope/4`, gives for the
grantee's principal, the manifest's system-shell principals, its
development flag and whether a facet row grants the grantee `start`:
`all` for a system-shell principal (`root` in a development build) in
a development build, and otherwise `{principal, P, Trees}`, the
principal's domains and the machine trees `Trees`, `[apps]` for a
session template that holds `start` and none otherwise, and with the grantee's principal itself, which a
facet of scope `all` would otherwise not carry. Both are parameters the
domain service computes at the mint ([design-system.md](design-system.md#facets-a-configured-domain-serves),
"Parameters the domain service computes at the mint"). The inspector resolves `{principal, P, Trees}` at each
query from the domain service's records, its death records included,
so a domain the principal starts later is in scope from its start and
one that ended stays in scope while its record is kept, and a path of a
domain that is not the principal's gets the answer of a path that names
nothing. No other code decides a scope: the console and the web line
take what the session holds, and the host link's root has the scope of
its configuration (below). A command
domain gets the facet attenuated in front of its starter's, as any
facet ([design-domains.md](design-domains.md#facets)).

**How a query travels.** `erx_inspector:inspect/1,2`, `entries/1` and
`literals/1` take no scope. In any runtime but the system domain's they call the
domain's `inspect` facet and return its answer, or `{error, no_facet}`
when the domain holds none; `erx:i/1`, `erx:inspect/2`, the shell's
commands that query the inspector (`top`'s header, `dmesg`), `/proc` and
the web line's views all go through them, so each holder has one gate
for every form of an inspector query. What a runtime holds of its own is
not such a query: `ps` and the `Ctrl-T` line read the session's own
process table and port table in its own runtime, with no facet
([Text commands](design-shell.md#text-commands),
[design-shell.md](design-shell.md#ctrl-t-status-and-the-info-request)),
as a UNIX user sees their own processes, and a runtime's own
`process_info/2` is stock OTP's. In the system domain no facet stands
between: they start a query worker (below) at scope `all` in the same
runtime and wait for its answer, so a system-domain query asks other
domains' agents as a facet's does, and the system shell's calls present
the system-shell facet besides, whose principal is the caller's; the
system domain's other calls, the host link's among them, carry no
principal and so read no attribute of the class `display`. In front of
the inspector, the facet's
callback decodes each request with `erx_inspect_query` (Bounds, below),
hands the path, the options, its own scope and its grantee's principal
to a query worker it starts
for its grantee, and forwards the request to it, up to the grant's limit
in flight, which the default manifests set to 2, so a query that waits
on a slow domain holds up no other holder's query and the inspector's work is charged to the
grantee's share. A command domain's attenuated facet forwards to its
starter's, whose workers serve it, so it adds no workers of its own.

**The query worker.** Each admitted request runs in one process of the
system domain, a process the facet starts for its grantee
([design-domains.md](design-domains.md#facets), "Processes a facet
starts"). Each monitors the other: the worker ends when the facet does,
so revoking the grant ends it, and the facet, which monitors the worker
as the service of the request it forwarded, answers that request
`{error, failed}` when the worker ends before answering. A service's
reply precedes its end, both being its own signals, so a request that
is still outstanding when the worker ends has failed. A worker the
system domain starts for its own call monitors its caller the same way,
and the caller's wait answers `{error, failed}` if the worker ends
first. Every worker is bounded alike:

* **Lifetime.** It sends the one answer and exits. It lives at most
  `inspect_query_max`, 5 s, which the interface declares; at that
  deadline it answers with what it has, a listing it had not finished
  `partial` and each runtime attribute it had not collected `{timeout,
  5000}`, and exits.
* **Collection is bounded before the answer is built.** It asks one
  domain's agent at a time ([The runtime agent](#the-runtime-agent)),
  and adds an answer's entries to the page only while the page has room,
  1,000 entries and an encoding within `inspect_reply_max`, dropping the
  rest of that answer as soon as it is merged; once the page is full it
  asks no more and marks the listing `partial`. So it holds at most the
  page it is building and one agent's answer.
* **What it receives.** It takes every message in arrival order and
  keeps only the answer to its one outstanding question; anything else,
  a late or second answer or a message from a domain its pid reached as
  the sender of a question, it drops as it takes it, so it never holds
  more than one message it does not want and never scans its queue.
  Frames queued on it undecoded are held to the system domain's
  `system_queue` and the one frame that crossed it, as on every system
  process without a quota of its own
  ([design-domains.md](design-domains.md#flow-control)). Its request
  limit for messages from other domains is `inspect_message_heap_min`,
  set as the `erx_facet` behaviour sets a facet's, so the funnel drops a
  decoded answer past it; the facet's `max_request` of 4 KiB binds the
  grantee's requests to the facet, not the agents' answers to the
  worker.
* **Its heap.** Its `max_heap_size` is `inspect_worker_heap`, which the
  interface declares: the page it builds and one agent's answer, each
  within `inspect_message_heap_min`, the frames queued on it, at most
  `system_queue` and one frame of the system domain's `max_frame`, which
  count toward `max_heap_size` with shared binaries, and room for the
  collectors. OTP checks `max_heap_size` during a major collection
  against both semispaces of its copying collector, and grows the heap
  in steps, so the bound sits far above the live data: a worker holding
  one answer of 81,000 words and its page peaks at 833,000 words of old
  and new heap. Every collection of a worker is a major one
  (`fullsweep_after` 0), so an answer it has merged and dropped is gone
  at its next collection instead of lingering in an old generation, and
  its heap holds only the page and the answer it is taking. A worker
  that passes the bound is ended by OTP, and the facet answers the
  request `{error, failed}`, as for any worker that ends before
  answering; a system-domain caller's wait answers the same.
* **Its reservation.** The grant's limit in flight times
  `inspect_worker_heap` is a term of what the grantee can make the system
  domain hold, which the domain service reserves when it admits the
  grantee ([design-domains.md](design-domains.md#flow-control), "What a
  domain can make the system domain hold").

The answer bound, the floors and the worker's heap are provisional,
sized for the trusted workloads of Phase 1: `inspect_reply_max` 256 KiB;
`inspect_max_frame_min` 512 KiB, an answer and its envelope in one
frame; `inspect_message_heap_min` 1 MiB, four times the answer bound;
`inspect_worker_heap` 16 MiB, which holds an answer at the decoded
floor with the page through the collector's growth step from 514,838 to
832,040 words, measured on a worker holding an 81,000-word answer under
OTP's growth policy; and a reservation of 32 MiB per holder at the
default manifests' limit of 2 in flight. The measurement of the encoded and decoded sizes
of records and pages, and of the peak memory of the workers together
([todo-performance.md](todo-performance.md)), sets them: the decoded
floor from the largest decoded answer, the frame floor from the largest
encoded one with its envelope, and the worker's heap and the
reservation from the peak. `inspect_funnel_depth_min` is not
provisional: the generator computes it from the schema, the deepest
nesting any record's type allows, as the `net` generator computes its
floors.

**Bounds.** A request is a path of at most 16 segments, each an atom
that is a literal of a path `erx_schema` declares, an integer below
2^64, a `proc_id()` of three integers each below 2^32, or a binary of
at most 765 bytes, the longest encoded entry name; and options holding at most
`offset`, a sequence number below 2^64, and `limit`, a page of 1 to
1,000 (`erx:inspect/2`'s `timeout` is the caller's own wait and is not sent); the interface declares the three bounds as
`inspect_path_max`, `inspect_name_max` and `inspect_page_max`.
The funnel decodes it in safe mode, so it creates no atom, and the
facet's one decoder, `erx_inspect_query`, a pure function, refuses
anything else with `{error, badarg}`, a scope or any other key among the
options included, walking at most the 16 segments it accepts. A
request whose encoding passes the grant's `max_request`, 4 KiB in the
default manifests, the facet drops unanswered before it decodes it, as
every facet does ([design-domains.md](design-domains.md#facets)), so its
caller's wait ends in `{error, failed}`; a path the schema declares, its
names within an ordinary length, is far within it. An answer's encoding is at most
`inspect_reply_max`, 256 KiB, which the interface declares: the
inspector stops a listing at 1,000 entries, and stops a listing or an
append-only record's entries earlier when the next one would pass that
bound, marking it `partial`; an append-only record's `Next` says where
the next query starts;
the schema's bounds keep every record without entries within
`inspect_reply_max`, which the generator checks for each kind, so no
record needs cutting.
The interface declares a floor on each of the three limits the funnel
applies to a frame, `inspect_max_frame_min` on `max_frame`,
`inspect_message_heap_min` on `max_message_heap` and
`inspect_funnel_depth_min` on `funnel_depth`, which every grantee of an
`inspect` facet and the system domain, which serves it and takes the
runtime agents' answers of the same bound, carry in their limits, so no
receiver's funnel drops a valid answer
([design-system.md](design-system.md#the-manifest), property 16;
[design-domains.md](design-domains.md#principals-sessions-and-quotas),
"Floors from a protocol"). The query decoder has a fuzz target.

**The host link.** The host link's `inspect` root is not a facet of
another domain: the host link is the system domain's, so its root calls
the inspector's core at the scope the host link's configuration gives,
`all` in a development build ([The host link](#the-host-link)).

#### The runtime agent

What only a domain's runtime knows, its processes, modules, exports,
programs and pipes, the inspector asks that domain's inspection agent:

* **The agent.** `erx_inspect_agent`, a process of `erx` that every
  domain but the system domain starts before init's ready report, which
  names it as `inspect` and so exports it to the system domain with
  `send` ([design-domains.md](design-domains.md#domain-lifecycle)). The domain
  service keeps its pid in the domain's record for the domain's life
  only when the reporting incarnation owns it, its node the
  incarnation's node and its creation the incarnation's domain id, by
  the check a provider's mint passes
  ([design-system.md](design-system.md#facets-a-configured-domain-serves),
  "Providers"); any other value is refused, logged and counted, and
  leaves the domain without an agent. A domain without one, refused or
  not yet reported ready, has `unknown` runtime attributes.
* **The question.** `{erx_inspect_ask, Alias, Query}`, `Query` being
  `{inspect, Path, Options}` or `{entries, Path}`, in the system
  domain's envelope; the agent drops and counts a message from any
  other origin or of any other shape
  ([design-domains.md](design-domains.md#messages-between-the-domain-service-and-a-runtime)).
  It answers only a path its own domain owns, `[domains, Self | _]`, and
  `[processes, Pid]` and every path the schema declares below it, such
  as `[processes, Pid, source]`, for a `Pid` whose domain is its own,
  and the listing `{entries, [processes]}` with its own processes only,
  with the attributes
  its runtime's collectors give, and answers any other path `{error,
  scope}`: a runtime describes only itself. A session's agent relays its
  programs' attributes from its command server's process table and the
  programs' handlers, as `ps` reads them
  ([design-programs.md](design-programs.md#the-command-server)), and its
  pipes' from its pipe server. The agent takes questions one at a time, in order, and keeps
  its answer within `inspect_reply_max` by the inspector's own rules of
  cutting.
* **The wait.** The query worker sends each question with a fresh
  `reply` alias, which ends at its first message, and waits
  `inspect_agent_wait`, 500 ms, which the interface declares, for the
  answer; a query that spans several domains, such as `[processes]`
  at scope `all`, asks them one after another, each under its own
  deadline, within the query's `inspect_query_max`. An answer that
  misses its deadline makes each runtime attribute it would have given
  `{timeout, 500}` and a listing it would have filled `partial`, and when
  it arrives later the alias has ended and it is dropped. A frame over
  the system domain's `max_frame`, or a decoded answer over the worker's
  request limit, is dropped by the funnel, so it too reads as a timeout.
* **What the inspector believes.** The funnel validates the frame, and
  the worker takes the answer only when everything in it agrees with
  the question it asked: it arrives in the envelope of the domain asked
  and to the question's alias, while that question is outstanding; its
  record's `path` is the path asked, or for `entries` each record's path
  is one entry below it; its `kind` and `id` are those the schema gives
  that path, with every domain id and every `proc_id()` of the path and
  the id the asked domain's; its attributes are only those the schema
  lets `runtime` report for that kind; and it passes
  `erx_schema:validate_record/1`, so it holds no pid, reference, port or
  fun (V10). An answer that fails any of these is dropped whole and
  counted, and reads as `{error, invalid}` for each runtime attribute it
  would have given. Of an accepted answer the worker drops from the
  attributes every `proc_id()` of another domain, and marks every
  attribute it takes `runtime`, whatever the frame says. Kernel and
  service attributes it collects itself, so a lying runtime can misname
  its own processes and programs but cannot hide its charges or describe
  another domain. Who answered is the envelope's domain, which the
  peer stamps, and the alias, which only the asked domain was handed,
  so the agent leg adds no identity scheme of its own.

#### System values: one tree, many views

erXos has no `sysctl` facility. The machine's figures (its uptime, CPUs
online, memory total and free), a domain's (its runtime's run queue,
processes and atoms) and every other system-wide value are attributes of
the inspector's tree, declared once in `abi/inspection.txt`, and `/proc`
is that tree as files. Every way of reading a system value is a view of
the one tree and decides nothing itself: `erx:i/1` and `erx:inspect` at
an Erlang shell, the `/proc` files, the host tool's `erx inspect`, the
text commands (`top`'s header reads `[]`, its own process's record, the
record of the domain that names and that domain's budget), and a
`sysctl(3)` reader in the POSIX-lite personality. A value has one name,
one reporter and one status wherever it is read, so no view shows what
another would refuse or mark partial. Plan 9 serves its system values as
files the same way; FreeBSD's split between `sysctl` names and `procfs`
files, with a permission model of its own for each, is what one tree
avoids, and erXos's `/proc` carries statuses and reporters that FreeBSD's
`sysctl` values lack.

The tree is read-only. Configuration lives in the system manifest, whose
security properties a build check proves
([design-system.md](design-system.md)); a writable system value would be
a second, unproven way to change the machine, so no view writes one, and
changing a setting is changing the manifest.

The `sysctl(3)` reader maps the FreeBSD names programs
ask for onto attributes of `/proc/status`, read through the program's own
namespace, so a program sees exactly what its `/proc` grant shows:
`hw.ncpu` is `cpus_online`, `hw.physmem` `memory_total` and
`kern.boottime` the wall clock less `uptime`; `hw.pagesize` is the ABI's
page size, which the C library is generated with, as `getpagesize(3)`
is. A name whose value is not `ok` (partial, unknown, unsupported, timed
out), and a name no attribute holds, such as `vm.loadavg`, since erXos
keeps no load average, is `ENOENT`: a reader of a bare number cannot
tell a partial count from an exact one, so it gets none.

**Who sees what: the facet's scope, then the grant's root.** The inspect
facet's scope limits what any view of a tree served through that facet
can answer: it is the security boundary, and the inspector applies it to
every query before it looks anything up, by the rules of
[Scopes](#inspection) alone: the schema's `visible` classes for
attributes, a domain's paths for that domain, and the fixed set of
machine paths a scoped facet reaches. The root of a `/proc` grant,
`/proc/domains/7` say, narrows what one program sees within that scope:
least privilege, by the namespace rules every file grant follows
([design-files.md](design-files.md#narrowing-for-a-program)). These two
are the only gates. No view and no reader gets an allow list of paths of
its own: a value some readers must not see gets a `visible` class in
`abi/inspection.txt`, and a program that should see less gets a narrower
root.

### The /proc tree

`/proc` is the inspector's path namespace as a read-only file tree, served
by `erx_procfs`, an `erx_fs` server that each domain's runtime starts in
that domain and mounts at `/proc`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)). A
session's handler gives a program a grant of it, rooted where the session
chooses, so `cat`, `ls` and `grep` read live state. The tree is a view
of the inspector's tree and decides nothing itself: a read of a file is
the query `erx_inspector:inspect/2` makes for the file's path, which in a
domain other than the system domain goes through the domain's inspect
facet ([The inspect service](#the-inspect-service)), rendered as text in
the reader's runtime; a path that answers `{error, scope}` reads as
`enoent`, so the tree grants nothing that `erx:i/1` in the same domain
does not, and each record has one gate for both forms by construction. A
domain that holds no inspect facet finds every path of its `/proc`
`enoent`, and a revoked facet admits no query after its end, so from
then on each open is `enoent` while snapshots already open stay as they
were read. The scope is the facet's, in the system domain; the root of a
program's grant narrows within it, at the session's own server, which
the program reaches only through fids its handler walked. The server's
fid state, its rendering and its snapshots are the reader's domain's
memory and work, charged to it.

* **Paths.** Each inspector path is a directory whose `status` file holds
  its record, and whose subdirectories are the paths below it:
  `/proc/status` is the machine (`[]`), `/proc/domains/7/status` a domain,
  `/proc/domains/7/processes/` its pids, `/proc/domains/7/programs/3/status`
  a session's program with process id 3, and `/proc/processes/7.85.0/status` a
  process, its pid written without angle brackets so a shell needs no
  quoting. `/proc/processes/7.85.0/source` holds the source lines around
  the process's location, as `erx:source/1` prints them, and
  `/proc/domains/7/crash` the domain's last crash dump; the server fetches
  their pages from the inspector as reads reach them. `/proc/kernel/log`
  shows the kernel log's lines without consuming them, from the oldest
  the ring still holds, one entry per line, with a line `[missing N]` where
  N entries of the sequence are missing, whether the ring overwrote them
  or they failed the reader's checks; an open asks for its pages
  from sequence number 0, each from where the page before stopped, and
  `dmesg` writes the file ([design-shell.md](design-shell.md#text-commands)).
  `/proc/devices/Name/trace` shows a device's access trace snapshot, one
  entry per line.
  `/proc/kernel/log` answers wherever `[kernel, log]` does, for an inspect
  facet of scope `all`, and
  `/proc/kernel/crash` is `[kernel, crash]`, the last reset's crash
  record, rendered as a file: it answers only where that query does, in
  the system shell's tree, and reads as `enoent` in every other tree.
  The console starts the system shell's tree with that shell, in the
  system domain's runtime at scope `all` and presenting the system-shell
  facet it lends the shell; the tree is mounted only in the system shell's
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
  value and its reporter, a backend reporter by its label, separated by
  tabs. A value prints through
  `erx_render`, as the inspector's printers print it: an
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
* **Snapshots.** Opening a file runs one inspector query, or for an
  append-only path's file one a page, at most 16, whose deadline
  is the inspector's own, `inspect_query_max`, and reads see that snapshot
  until the file is closed; a record is at most 64 KiB, and a larger one is
  cut, with `[partial]` as its last line. A grant holds at most 256 open
  snapshots, so one reader makes its tree hold at most 16 MiB of its own
  domain's memory, within the grant process's heap limit, and a 257th
  open fails with `emfile`
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)). A
  directory whose children the schema names, `/proc` itself and
  `/proc/domains/7` among them, is listed by one `literals` query, which
  collects no record, and a walk to such a child asks the same query of
  its parent, so neither costs a listing's records; any other answer
  than `{ok, Literals}` or one that names nothing (`{error, scope}`,
  `{error, no_facet}`) shows every declared child, whose `status` then
  says why the query failed. A
  directory lists at most 1,000 entries, the inspector's page; a longer
  listing ends with an entry named `.partial`, whose file says how many
  entries were left out, and a directory whose listing the inspector
  could not get holds only `.unknown`, whose file gives the status.
* **What a runtime reports.** An agent's answer whose path, kind or ids
  name another domain is dropped whole, and the processes of another
  domain it lists are dropped, so a lying runtime can describe only its
  own processes ([The runtime agent](#the-runtime-agent)). The schema
  declares a kind whose reporter is `runtime` only at paths under a
  domain id or a process id, and its generator refuses any other, so
  `/proc` holds what the system observes, the kernel's, the system
  services', the configured domains' and each runtime's about its own
  processes, and no app's words. An app speaks in a tree of its own, at
  `/svc/NAME` ([design-app-trees.md](design-app-trees.md)); of an app,
  `/proc` shows the start table's record at `/proc/apps/NAME` and its
  session's domain.
* **Scope.** A path outside the facet's scope answers `enoent`, as a path
  that names nothing does. The inspector decides scope from the path and
  the domain service's record of the domain the path names, before it
  collects anything, and a domain that does not exist and one outside the
  scope get the same answer, so the answer never depends on whether
  something outside the scope exists.

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
  that carries it out: the kernel's ring, or on Fiasco the backend's
  ([design-fiasco.md](design-fiasco.md#the-trace-ring)). The runtime
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
  wait for a row whose call answered `ERX_ENOTSUP`. A ring read refused
  with any other status shows one `error` entry for that ring, with the
  status as `status`, a kernel ring's CPU as `cpu` and the row's
  reporter; the trace reads that ring no more, does not wait for it, and
  goes on with the others.
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

| Row | Reporter | On erXos's kernel | On Fiasco |
| --- | --- | --- | --- |
| `erts` | `runtime`, the system domain's included | OTP's trace events of the selection, its frames, and the adapter's events | OTP's `in` and `out` events of the selection, and its frames, which its funnel sees on Fiasco's lanes as on erXos's kernel; none of the adapter's events |
| `backend` | `{backend, liberx_trace}`, labelled `liberx trace` | none: `erx_backend_trace_read` answers `ERX_ENOTSUP` and the row is left out | the root's ring ([design-fiasco.md](design-fiasco.md#the-trace-ring)) |
| `kernel` | `kernel` | each CPU's ring, read with `erx_trace_read` | one `unsupported` line, from `erx_trace_read`'s `ERX_ENOTSUP` |

A row whose call answers `ERX_ENOTSUP` is shown as `unsupported` when
its reporter is `kernel`, and left out when its reporter is a backend's,
since a stand-in that does not run reports nothing. On Fiasco the
adapter emits none of its own events: what causes them, a grant that
changes, a yield request or a lane, is a kernel mechanism Fiasco does
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
`erx_time_set_offset` ERTS's correction may slew it, by at most 1 % in
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
named arguments as fields. Four events report on
a row itself: `unsupported`, with no fields, once at the trace's start
for a row shown as unsupported, `error`, with `status`, for a ring whose
read was refused, `overwritten`, with
`count`, for records a ring lost before they were read, and `dropped`,
with `count`, for entries the trace did not deliver.

**Flow control.** The receiving process acknowledges the stream in
windows: it sends `{erx_trace_ack, Ref}` after every 64 entries it has
handled (`erx_trace:handled/2` counts them), and the trace has at most
a window of 256 entries out beyond those acknowledged, however many
acknowledgements arrive. An entry that finds the window shut is dropped
and counted by row, and so is a session message past the 4,096 one
round of 10 ms takes. Once the window is open again, the next round
hands the merger one `dropped` entry per row, with the count, stamped
with the round's time, and the merger releases it in time order like
any other entry, so it never prints ahead of an entry held from before
it; a `dropped` entry that then finds the window shut is counted again
with its count, and a trace that ends reports what it still counts,
last. A slow receiver, a receiver that never acknowledges, or a trace
whose output feeds itself (the console's driver traced while the shell
prints) therefore holds at most 256 entries in the receiver, for which
the trace keeps only counters, and two traces at once hold twice that.
A receiver that acknowledges entries it has not handled can only fill
its own mailbox. What the trace process holds itself, the round's
batch, the merger's held entries and the session messages waiting in
its mailbox, is bounded by its heap: it is spawned with `max_heap_size`
at 2,097,152 words (16 MiB with 64-bit words), `kill => true` and its
message queue on the heap, so a flood of session messages from busy
schedulers, which ERTS delivers without flow control, or entries the
merger holds kill the trace process at a garbage collection, never the
system domain; the kill also logs ERTS's error report. The bound is an
estimate to be measured: a full round is 4,096 session messages and
4,096 entries per ring read, some 25 words an entry, and about two
rounds are held, some 600,000 words for the `erts` row and the backend
ring, each kernel ring adding about 200,000. The trace's own processes, the trace process and
the printer, are spawned with the spawn option `{erx_untraced, true}`
(OTP edit 52 of
[design-runtime.md](design-runtime.md#the-edits-outside-syserxos)),
which keeps a process out of every trace session from its first
instruction to its end: no session, its own or another's, opened before
or after, sees it run, call a traced function or anything else, whatever
it selects. It does only that: unlike `sensitive`, it hides nothing
from `process_info` or crash dumps and leaves `seq_trace`, which is no
session, as it is: a caller holding a sequential trace token passes it
to the trace process and the printer, and the system's sequential
tracer then sees the trace's stream. An untraced process takes no
session's flags when it is created and uses up no parent's
`set_on_first_spawn`.

**The end.** The receiver holds a monitor of the trace process, whose
pid `erx_trace:start/3` returns and which spawns the shell's printer
and so is known to it, after the session opened, so a refused trace
leaves no printer. The trace process ends `normal` after a stop, having
delivered what it still held, when the receiver ends, with nobody left
to deliver to, or when the caller of `erx_trace:start/3` or
`erx_trace:print/2` dies before it has
taken the reference, since nobody could then stop it. Any other reason
is a failure, `killed` for a trace process past its heap bound
included, and the printer then prints one escaped line,
`erx:trace failed:` and the reason. A trace process that fails before
it answers its caller has started nothing the caller could stop, and
`erx:trace/1` returns `{error, {failed, Why}}` with the reason; a
printer it had already spawned may print its failure line as well. The shell's
printer writes one line per entry, the time in seconds, the row, the
event, each field as `name=value` (`pid` and `domain` first, `cpu`,
`thread` and `space` last, the others by name) and the reporter's label in brackets,
with `late` after a late one:

```
   40.993000112 kernel unsupported [kernel]
   41.207113520 backend irq_deliver label=1 cpu=unknown thread=6 space=1 [liberx trace]
   41.207119044 backend wake result=ok slot=2 cpu=unknown thread=4 space=1 [liberx trace]
   41.207131870 erts in pid=<0.91.0> domain=4 mfa=timer:sleep/1 [runtime]
```

It builds the whole line and prints `erx_text:escape_line/1` of it, so no
field, a rendered atom from a traced domain included, can end the line or
carry a control character.

### Code from the host

Command modules also publish a generated catalog binding to their loaded
blob hash, metadata and local entry fun. Their code server makes affected
entries unavailable during replacement; after a load whose outcome is unknown,
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
* **Into another domain.** A **code facet** sends the modules to the
  domain's code server, which loads them in that domain's runtime
  ([The code server](#the-code-server)). The
  install facet and the code facet are two services of one interface,
  `code` (`abi/services/code.txt`), served by `erx_code` with one request
  reader, and they differ only in scope, which the domain service fixes
  when it mints the facet, as it fixes an inspect facet's
  ([The inspect service](#the-inspect-service)): the install facet's
  scope is the system domain alone, and a code facet's is what one pure
  function, `erx_domain_core:code_scope/3`, gives for the grantee's
  principal, the manifest's system-shell principals and its development
  flag: `all`, every domain but the system domain, for a system-shell
  principal (`root` in a development build) in a development build, and
  otherwise `{principal, P}`, the principal's own domains, resolved from
  the domain service's records at each load. Every load names its domain,
  by id or by name; a domain outside the scope and one that names nothing
  get the same `{error, scope}`, and the system domain is in no code
  facet's scope, so V5 holds whatever a code facet asks (V11).
  Development builds give a code facet to the host link and to `root`'s
  session; release builds give one to the session templates whose facet
  rows name it, by default none. A supervised domain's end at a load
  that is not published (**A supervised domain keeps only published
  code**, below) is part of a code facet's contract: a supervised domain
  in the facet's scope that loads a batch `erx_code` does not publish
  ends, loses its running state and restarts from its published overlay,
  so a manifest that names the facet in a template's rows lets that
  template's sessions cause that end. A module travels in
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
  into its domain from outside since the specification was started
  ([The code store](#the-code-store)).
  * A load has three steps, each with one actor: the code service writes
    a candidate overlay; the domain's code server loads the modules of it
    that are not already current as one batch, with
    `code:prepare_loading/1` and `code:finish_loading/1` as `erx_code`
    does, so either all of them are current or none is, and answers; the
    code service publishes the candidate, with a new revision, when the
    batch loaded, and otherwise discards it, and tells the code server
    which it did. The code server keeps a loaded batch only once told it
    was published, and otherwise ends its domain, so a domain of the
    specification runs only code its published overlay names. That the
    batch loaded is the domain runtime's report; the published overlay is
    the code service's own fact, and every report keeps the two apart
    ([What an answer proves](#the-code-server)). Every ERTS runtime refuses a
    module with an `-on_load` function, as OTP's atomic loading does
    (`on_load_not_allowed`), so a NIF's module changes only with its
    image.
  * A domain started from the specification loads the published overlay
    before its release's applications start, through its start load
    ([The code server](#the-code-server)). A start whose start load is
    refused or goes unanswered fails, and the overlay
    stays published, so no domain of the specification runs past
    `kernel` on anything but its published overlay, as far as its
    runtime reports; the operator's reset is the way back to the release
    ([Resetting an overlay](#the-code-server)). An overlay always
    stands over the release it was loaded over, with nothing to check:
    a specification boots the same release for as long as its overlay
    lives (**Targets**, [The code server](#the-code-server)).
  * An overlay lives in memory only, in `erx_code`, and lasts until the
    machine ends or `erx_code` restarts
    ([When `erx_code` ends](#the-code-server)), as the system domain's
    installs last until the machine ends. A reboot therefore returns every
    domain to its release, and a change that must outlive one ships in a
    release: a system update for the system's own code
    ([design-storage.md](design-storage.md#system-updates)), a new
    version of its package for an app's
    ([design-packaging.md](design-packaging.md#installing-updating-and-removing)).
    Nothing of the code service is written to a data partition.
  * An overlay's blobs are at most the specification's `overlay` limit
    (16 MiB by default), held in its principal's hot store, so a principal
    pays for its own overlays and they outlive the domains that run them.
* **One load at a time for each target.** A load's **target** is the
  system domain, a supervised specification, or a domain no
  specification restarts. `erx_code` runs at most one load at a time for
  each target and keeps no queue: a load into a target that has one in
  flight is answered `{error, busy}`, and its sender sends it again once
  the first has ended, so it runs over the code the first left and
  writes its candidate over the overlay the first published. Loads into
  different targets run at once, and an install never waits for another
  domain. The service itself never waits on a domain: it serves
  `missing`, `put` and the pieces a code server asks for while loads are
  in flight. `erx_code` publishes a candidate in the same step that takes
  the answer which ends its load, and builds a start load in the step
  that takes the start, so a start load carries the overlay published
  when the start arrived, never one a load is still replacing.
* **The deadline.** A load into another domain ends at the first of
  three events: its code server answers, which publishes or discards the
  candidate; that server ends, which discards it and answers
  `{error, domain_ended}`; or 30 s pass from when the code service sent
  the load, after which it discards the candidate and answers
  `{error, timeout}`. For a supervised target that means the load was
  not published, and a batch its code server loads anyway ends its
  domain (below); for any other target the outcome is unknown: the code
  server may still load the batch, or may not. A code server's end is its
  domain's end, since the code server is a `permanent` child of
  `kernel_sup`, whose intensity is 0
  (`otp/lib/kernel/src/kernel.erl:101-103`), so `{error, domain_ended}`
  always means the domain ended ([The code server](#the-code-server)).
  The 30 s of a facet's load never include a boot: a load into a domain
  that has not reported ready is answered `{error, busy}`
  ([The code server](#the-code-server)), and a boot that hangs is the
  boot timeout's ([design-system.md](design-system.md#boot)). The start
  load's own 30 s run inside the boot,
  beside the boot timeout, and whichever passes first ends a start that
  hangs. A domain that never answers holds up only its own target, for
  30 s. An answer that arrives for a load no longer in flight is dropped.
  A facet waits for its load's answer with no deadline of its own, since
  the service ends every load it starts; the host tool has its own
  ([One load, three routes](#one-load-three-routes)). An install runs in
  the system domain's own runtime and has no deadline: `erx_code`'s
  atomic load runs no code of the modules it loads.
  * **A supervised domain keeps only published code.** A batch runs
    from the moment its runtime loads it, so for up to 30 s a
    supervised domain may run a batch its overlay does not yet name;
    what this rule promises is that no such domain keeps running it
    past that window, not that the batch never ran. The code server
    of a supervised domain that has loaded a batch waits for
    `erx_code`'s word that the batch was published, until 30 s after it
    took the load, and ends its domain if the word does not come
    ([The code server](#the-code-server)). The domain service then
    starts the specification's next domain from its published overlay,
    and that domain runs the code its overlay names once its runtime
    reports the overlay's revision loaded. The code server is the one
    party that knows whether the batch loaded, so it decides, and one
    rule covers every way a load can end unpublished: the deadline, an
    `invalid` message, `erx_code`'s end in the middle of the load, and a
    word lost on the way. Nothing in the system domain stops the domain
    for it. A domain whose code server takes more than 30 s abandons the
    load before it loads anything and runs on; one that loads the batch
    just as `erx_code`'s deadline passes ends and loses its running
    state, with the time a 16 MiB batch takes on the slowest machines on
    the [performance watch list](todo-performance.md#erts-and-the-runtime).
  * **Any other target is left running.** A domain no specification
    restarts has no overlay to fall out of step with, and an end would
    be for good, so its code server waits for no word and a timeout
    leaves it running. Whether the batch loaded is its runtime's fact
    (**What is already current**, below): sending the load again changes
    nothing already current and loads the rest.
  * **These ends count as restarts.** Each is one end of the
    specification within its restart intensity
    ([design-system.md](design-system.md#boot)), which the development
    manifest's rows set to 5 within 600 s (`restarts` and
    `restart_period_s` in `config/manifest/development.txt`). A developer
    whose loads keep ending a domain sees one log line for each end;
    past the intensity the domain is left down and shown so in the
    inspector, and a load that names it names no domain and gets
    `{error, scope}`. A domain the manifest marks `required`, as no
    development row is, ends the machine instead.
* **What is already current** is the loading runtime's fact, never the
  code service's: a code server, and `erx_code` for the system domain,
  loads only the modules whose hash differs from that of the module's
  current code in its runtime, and a batch whose every module is current
  changes nothing and purges nothing. A hot-loaded module's current hash
  is its file name, which the loader sets to its hash in hexadecimal
  (`code:which/1`), and a release module's is its release manifest's
  entry, so the fact survives a restart of the code service, whose store
  and history start empty while the modules it loaded stay loaded. A load
  sent again therefore changes nothing still current and is otherwise an
  ordinary load: if another load replaced a module in between, the repeat
  puts the repeated hash back, since the last load wins.
* **`erx watch DIR`** recompiles each changed source with the host's
  `erlc` and loads the result; `erx load FILE.beam ...` loads files as
  they are; both name their target with `--system` or `--domain D`
  ([One load, three routes](#one-load-three-routes)).

#### One load, three routes

A load is one exchange with a facet of the `code` interface: `missing`
with the modules' hashes, `put` for each piece of each blob the
principal's store lacks, and `load` with the domain and the manifest
([The code store](#the-code-store)). Whoever holds the facet can load,
within its scope, and nothing else decides where code may go (V11). Two
holders run the exchange: the host link's session, for the host tool,
and the session command `load`, for SSH and for files. The routes
differ only in how the bytes reach a holder, and each has a consumer the
others do not serve:

| Route | Holder of the facet | What carries the bytes | Its consumer |
| --- | --- | --- | --- |
| **The host link** | the host link's session, through its root's `install` and `code` | the host link protocol over the second UART: QEMU's UNIX socket, or a board's UART through a serial adapter or a UART bridge's UNIX socket | QEMU, and a board whose network is down, not yet up or broken by the code being loaded |
| **SSH** | the session the SSH login started, through its own facets | an SSH `exec` of `load`, with the modules on its standard input | a board on the network: the route at the network's speed |
| **A file** | the session that runs `load` | the session's own read of a file it can read | a module already on the machine: copied with `scp`, written by a program, or kept from before |

A driver is an Erlang process over a device shim
([design-system.md](design-system.md#drivers)), so loading one is
loading its domain's modules, and replacing a driver needs no new image
and no new card.

**The host link from a board.** A board's host link is the UART its
platform record names, separate from the console's (UART3 on the
Raspberry Pi 4, `config/platforms/raspi4b.json`'s `hostlink`), and the
root hands it to the system domain only under `erx.hostlink=1` on the
command line ([The host link](#the-host-link)). QEMU's plan adds the
word, and the card writer (`Erx::BootPartition`) puts it on a
development card's command line, where the board's boot reads it into
`/chosen/bootargs`, and never on a release card's. The host reaches the UART through
a serial adapter, a tty of the host (`--tty`), or through a UART bridge
that serves the line as a UNIX socket on the host, as a Glasgow
interface can (`--socket`). Nothing on the machine changes with the
transport: the frames, sessions, credit and roots are the host link's.

The host link authenticates nothing, so its peer is whoever on the
developer's host can open the socket or the tty. The harness makes its
socket in an owner-only directory; a bridge's socket belongs in a
directory only its user can enter, which whoever runs the bridge sets up
and the host's file permissions enforce; a serial adapter is open to
whatever its device node's mode allows, which on macOS is every local
user (the development Mac's serial nodes are mode 0666). A development
build trusts each of them, as it trusts physical access to the board;
release builds open only the roots their configuration gives, by default
none. The tool offers no network transport, and does not inspect a
socket's directory, since that would not stop another user who reaches
the bridge directly.

**`load`.**

```text
load (-s | -d DOMAIN) [-v] FILE.beam ...
load (-s | -d DOMAIN) [-v] -m MODULE[:BYTES] ...
load -d DOMAIN -r
```

`load` is a command of the session ([design-shell.md](design-shell.md#commands)).
`-s` loads into the system domain through the context's `install`
facet, and `-d DOMAIN` into the domain named by its id or name through
the context's `code` facet. Exactly one is given, and the choice is the
user's, never a rule about domain ids: `-d 4` goes to the code facet,
whose scope never holds the system domain, and fails with `scope`.
Without the facet its flag needs, `load` fails with `load: no install
facet` or `load: no code facet` before it reads anything. The first form
reads each file through the session's namespace with the session's own
rights and names each module by its file's base name without `.beam`,
as `erlc` names its output. The second reads the modules from standard
input, one after another: `-m MODULE:BYTES` takes exactly `BYTES` bytes
and `-m MODULE` the rest of the input, so only the last `-m` may leave
out its size, and input that ends early or goes on past the last module
loads nothing. Either way `load` reads every module whole into memory,
at most 16 MiB in all, the default `overlay` limit, hashes it and then
runs the exchange once, so each byte is read once and the bytes hashed
are the bytes sent. The third form reads and loads nothing: it sends the
code facet's `reset` for DOMAIN's specification, whose next domain then
boots its release as built, the recovery from an overlay whose start
load fails ([Resetting an overlay](#the-code-server)).

A file is input to the code service and never code: it is not mapped,
run or loaded in place, and the target domain loads only the blob the
code service hands it, checked against its hash
([The code store](#the-code-store)), so writing a file loads nothing,
and a load from a file is the request a load from the host makes. Any
file the session can read serves: one copied to `/data` with
`scp x.beam DEST:/data/`, which the SSH service serves through SFTP
([design-ssh.md](design-ssh.md#sftp)), one written through the host
link's files stream, or one a program of the session wrote. Over SSH the
file is optional: `ssh DEST load -d D -m x < x.beam` loads the module
from the command's standard input, which a job's pipes carry unchanged
([design-ssh.md](design-ssh.md#sessions-ttys-and-shells)).

`load` prints nothing on success; `-v` prints each module with its hash
and whether its blob was sent, and for a load into another domain one
line more, `DOMAIN: published revision R, loaded as its runtime
reports` (`published none` for a domain no specification restarts),
which names the code service's fact and the runtime's report apart
([What an answer proves](#the-code-server)). It writes each failure to standard error
as `load: NAME: REASON`, `NAME` the file or the module (DOMAIN for a
reset) and `REASON` the code service's, and exits 1; a call without
`-s` or `-d`, with both, with no module, or with `-r` beside `-s` or a
module is a usage error. FreeBSD has no command that loads code
into a running process, so `load` is erXos's own name (Alternatives
considered, `kldload`).

**The host tool's transports.**

```text
tools/erx load  TRANSPORT (--system | --domain D) FILE...
tools/erx watch TRANSPORT (--system | --domain D) [--interval SECONDS] DIR
TRANSPORT: --socket PATH [--build HEX] | --tty DEVICE [--build HEX] | --ssh DEST
```

A command takes exactly one transport and exactly one of `--system`,
through the install facet, and `--domain D`, through the code facet, as
`load` takes `-s` and `-d`. Every command that opens a host link session
takes `--socket` and `--tty`; only `load` and `watch` take `--ssh`.

* `--socket PATH` connects to a UNIX socket: QEMU's, in the run's
  owner-only directory, or a UART bridge's.
* `--tty DEVICE` opens a serial adapter, such as `/dev/cu.usbserial-X`
  on macOS, refuses a path that is not a character device, and puts the
  line in raw mode at 115,200 baud, 8 data bits, no parity and no flow
  control, the one rate the host link's driver programs
  (`abi/services/line.txt`'s `rate`), by running `stty` with the open
  device as its standard input, the terminal POSIX's `stty` sets, on
  FreeBSD, macOS and Linux alike.
* `--build HEX` makes the tool refuse a machine whose host link `hello`
  reports another build identifier.
* `--ssh DEST` runs `ssh -T DEST load -d D -m NAME:BYTES ...` (or `-s`)
  with an argument vector and writes the modules to its standard input
  one after another; `load`'s exit status is the load's outcome, and its
  standard error, which arrives on `ssh`'s, the tool prints through the
  line escape, as everything it prints from the target (V9). `DEST` is
  OpenSSH's destination, `[user@]host` or `ssh://[user@]host[:port]`, so
  the user's ssh configuration, agent and known hosts apply. `ssh` joins
  the words after `DEST` into the one command line that `rc -c` reads, so
  before it starts `ssh` the tool refuses a `DEST` that begins with `-`,
  which `ssh` would take as an option, and a domain or a module name that
  begins with `-` or holds any character but a letter, a digit, `_`,
  `.`, `-` and `@`.

The host link route sends only the blobs the store lacks; the SSH route
sends every module of the batch, which at the network's speed costs less
than the exchange that would avoid it. The tool gives up on a load after
120 s, past the code service's own deadline, and then says the load's
outcome is unknown.

A `watch` opens a connection for each change, which loads, as one
batch, the last good compile of every module the watch has compiled
since it started, and closes it. Since the runtime loads only the
modules not already current, a change loads what changed, and the first
change after a reboot, which dropped the domain's overlay, puts all of
the watch's code back; the tool needs no way to tell a reboot from a
lost connection, and holds the host link's one session only while it
loads.

**Picking up the code.** A load makes the new code current in the
domain's runtime, as `code:atomic_load/1` does: a process takes it at its
next call of the module by name, `Module:Function(...)`, as an OTP
behaviour calls its callbacks, and a process whose state the new code cannot read must start
again. A driver starts again through its holder's driver supervisor,
which a session holding the device service's control facet asks for with
`reset` written to the device's `ctl` in `/dev`
([design-system.md](design-system.md#the-holders-driver-control-facet)):
the restarted process runs the new code and resets its device, and the
domain runs on. A whole domain starts again when it ends, or through the
host link's `domain` facet's stop: the next domain of a supervised
specification loads the published overlay before its applications start
(Overlays, above). No route needs a restart of its own.

**How long a load lasts.** As long as its overlay: across a supervised
domain's restarts, until the machine ends or `erx_code` restarts
([Overlays](#code-from-the-host)). A reboot therefore returns every
domain, every driver's among them, to its release's code, which is also
the recovery from a driver that breaks every route, and `erx watch`
puts its code back at its next change. A change of the system's own
code that must outlive a reboot ships as a system update
([design-storage.md](design-storage.md#system-updates)), which the host
link's `update` facet takes, with the card left in the board.

**What is logged.** The code service writes one log record per load,
start load and reset, under the system domain's name: the facet's holder
(the host link, or a session's domain id and principal; none for a start
load), the target domain's id and name and its specification, each
module's name and hash, and the outcome. A success records the overlay
revision the code service published, as its own fact, and the domain's
answer as its runtime's report; a failure records the step that refused
and its reason. Module
names are the holder's text and reach a display only through the log
sink's escape (V9). How the session was logged into is the login's own
record ([design-ssh.md](design-ssh.md#logging), [The console](#the-console)),
so the code service records no route.

#### The code server

Every domain but the system domain runs one **code server**,
`erx_code_agent`, a process of `erx`, and it is the only process through
which `erx_code` loads code into that domain. It is not OTP's
`code_server`, which it loads through. The protocol between them
has one exchange: `erx_code` sends a manifest, the code server asks for
the blobs it lacks one piece at a time, loads the batch whole and
answers, and in a supervised domain `erx_code` then tells it the batch
was published. Every load into the domain is that exchange, including the
**start load** that puts a supervised specification's published overlay
in place before its domain's applications start. A target has at most
one load in flight, and a load into a target that has one is refused, so
nothing is ever queued for a target.

One rule makes a supervised domain run only what its published overlay
names: **its code server keeps code from `erx_code` only while the
`erx_code` that published it lives.** It keeps a loaded batch only once
`erx_code` has said the batch was published, and once it holds any
module so published it ends its domain when that `erx_code` ends. The
domain service then starts the specification's next domain from the
overlay `erx_code` holds. The rule sits with the code server because the
code server is the one party that knows what its runtime loaded; the
code service stops no domain for a load, holds no link to any domain,
and writes nothing that must outlive it.

**The endpoint and its export.**

* `kernel_sup` starts the code server as a `permanent` child after
  `kernel_safe_sup` (edit 41 of
  [design-runtime.md](design-runtime.md#the-edits-outside-syserxos)).
  `kernel_sup`'s intensity is 0, so the code server's end, whatever its
  reason, ends its domain, and "the code server ended" and "the domain
  ended" are one event. In the system domain, and on a host that is not
  erXos, `start_link/0` answers `ignore`: the system domain loads only
  through `erx_code`'s own install path (V5), so it has no code server to
  send a load to.
* At its start the code server compares its runtime's limits with the
  protocol's floors (**Floors**, below) and fails its start when one is
  below its floor. It then sends `{erx_code_agent, self()}` to the
  domain pid that `erx_dist:boot/0` names. Encoding that message hands
  the code server to the system domain with `send` (edit 8), which is all
  the protocol needs: `erx_code` sends to the code server and monitors
  nothing of it, so the domain needs no explicit export. The domain pid
  takes the first such
  report, which comes before init's ready report because `kernel` starts
  before every other application, and keeps it only when the reporting
  incarnation owns the pid, node and creation both, by the check the
  inspection agent's pid passes ([The runtime agent](#the-runtime-agent)).
  Any other report it refuses, logs and counts. It passes a kept report
  to the domain service as `{domain_code_agent, Ref, Id, Agent}`, which
  the service takes only for the live record that `Ref` names, and not
  once its boot timeout has passed. The service records the code server
  in the domain's record and, for a domain whose build answer carried the
  `supervised` flag, tells `erx_code` with
  `erx_code:started(Id, Target, DomainPid, Agent)`, a message, not a
  call, with `Target` the domain's target (**Targets**, below).
  `erx_code:started/4` looks the registered name up and sends only to a
  process it finds, since a send to an unregistered name raises
  `badarg` in the sender: with no `erx_code` registered nothing is sent,
  the domain service runs on, and the domain's boot ends at its boot
  timeout, as for any start load that never comes.
  `erx_code` calls the domain service (to resolve a load, to stop a
  domain at a reset) and the domain service never calls `erx_code`, so
  neither ever waits on the other in a cycle.
* A domain of a supervised specification carries the `supervised` flag
  in its boot information: a configured domain whose row allows a
  restart, or a created domain whose specification's restart is
  `permanent` or `transient`, the domains the domain service restarts;
  a session, a temporary domain and a partial-boot program do not
  ([Overlays](#code-from-the-host)). The domain library sets the flag
  from the plan, with no key of its own: a configured domain's plan names
  its row, whose restart intensity the library's view holds, and the flag
  is set when that intensity allows a restart (`restarts` above 0); a
  created domain's plan carries its request's `restart`. One function
  computes the boot information's flags, `erx_dom_plan_boot_flags`, and
  the library reports the `supervised` bit of what it wrote in its answer
  to the build (`erx_dom_created_t`, `supervised` in the map
  `erx_domain_lib` returns). That answer is
  the one owner of whether a domain is supervised: the domain service
  records it with the domain and passes it on, to `erx_code` among
  others, and no Erlang code recomputes it from a specification. The code
  server reads it with `erx_dist:supervised/0` and its runtime's frame
  limits with `erx:limits/0`, both BIFs over what the runtime installed
  at its start ([design-runtime.md](design-runtime.md#erlang-visible-behaviour)). Its code
  server waits for its start load and returns from its start only once
  `erx_code` has said the start load was taken. `kernel`'s start
  therefore completes, and every other application starts, over the
  published overlay; the processes `kernel` started before the code
  server take a loaded module at their next call of it by name. A start
  load the code server refuses, or loads and `erx_code` does not
  confirm, ends the code server and so the domain (**An answer**,
  below); a report the domain pid refused, a start load that never comes
  because an `erx_code` restart lost the notification, or one the code
  server abandoned at its deadline before loading it, leaves the boot to
  the domain's boot timeout ([design-system.md](design-system.md#boot)).
* In any other domain the code server returns from its start once it has
  sent its report. Such a domain has no overlay, so its boot never waits
  on `erx_code`.
* A domain takes loads once its record names a code server, it has
  reported ready, and it is its target's current domain. A target's
  current domain is the one whose start `erx_code` last took, and a load
  that resolves to any other domain is answered `{error, busy}`. Only a
  target with no current domain takes the first ready domain a load
  resolves to as its current domain: a domain no specification restarts,
  at its first load, and any target of a restarted `erx_code`, which has
  no notification for a domain started before it.
* A domain whose start load failed, or that a reset stopped, is
  **closed**: it stays its target's current domain until its
  specification's next domain starts, and takes no facet load, even if
  it reports ready; a load into it is answered `{error, busy}`.

**Messages.** Each message from `erx_code` reaches the code server as
`{erx_origin, SystemId, Msg}`, the envelope of the system connection.
The code server drops and counts any message of another origin or shape.
A process of its own domain can forge that envelope and gains nothing by
it, since it can already load code into its own runtime with
`code:load_binary/3`, or end its own domain.

| Message | Direction | Meaning |
| --- | --- | --- |
| `{erx_code_agent, Agent}` | code server to its domain pid, once, at its start | names the code server ([design-domains.md](design-domains.md#messages-between-the-domain-service-and-a-runtime)) |
| `{erx_code_load, Alias, Manifest}` | `erx_code` to the code server | make every module of `Manifest` current as one batch. `Manifest` is `[{Name, Hash, Size}]`: 0 to `code_modules_max` entries, each name once; `Name` is 1 to 255 bytes of a module name's alphabet, as the code service's request reader admits it; `Hash` is 32 bytes; `Size` is a positive integer. The sizes add up to at most the target's `overlay` limit, or to `code_load_bytes_max` for a domain no specification restarts. `Alias` is an alias of `erx_code` made for this load alone; the message hands it to the domain with `send` |
| `{erx_code_get, Alias, Hash, Offset}` | code server to `Alias` | asks for the piece of blob `Hash` that starts at `Offset` |
| `{erx_code_piece, Alias, Hash, Offset, Bytes}` | `erx_code` to the code server | that piece: `code_piece_max` bytes, or the rest of the blob for its last piece |
| `{erx_code_loaded, Alias, Result}` | code server to `Alias` | the outcome: `ok`, `{error, {hash_mismatch, Name}}`, or `{error, {not_loaded, [{Name, What}]}}` with `What` an atom `code:atomic_load/1` gives |
| `{erx_code_published, Alias, Lifeline}` | `erx_code` to the code server of a supervised domain, after its `ok` | the batch is published, or for a start load taken; `Lifeline` is `erx_code`'s lifeline (**When `erx_code` ends**, below), which the message hands to the domain with `send`, the right that covers a monitor |

Every message of a load carries its alias. A message sent to an alias does
not say which alias it came through, so the receiver needs the alias in
the message to know which load it belongs to. The 30 s deadline is
`code_load_wait`, 30,000 ms, which `abi/services/code.txt` declares
beside the piece, module and byte limits, so both sides read it from
one place. No message carries an overlay revision: the
revision is `erx_code`'s fact, and the code server has no use for it.

**Floors.** The protocol cannot survive the funnel dropping one of its
messages: a dropped load or piece shows only as the load's deadline,
which leaves the load unpublished, a dropped word of publication ends a
supervised domain whose batch was published, and a dropped start load
fails every start of its specification. So the code protocol has a floor
on each of the three limits the funnel applies to a frame, `max_frame`,
`max_message_heap` and `funnel_depth`, for each direction
([design-domains.md](design-domains.md#principals-sessions-and-quotas),
"Floors from a protocol"). The ABI generator computes them from
`abi/services/code.txt`'s `code_modules_max` and `code_piece_max`
(`tools/lib/erx/abi_code_bounds.rb`), each rounded up to a power of two:
the load floors `code_load_*_min`, from a load of `code_modules_max`
modules with 255-byte names, a piece of `code_piece_max` bytes and the
word of publication; the answer floors `code_answer_*_min`, from the
report, a request for a piece and an answer that names every module of
such a load, each with the longest reason of `code_load_reason`
(**An answer**, below); and the facet floors `code_facet_*_min`, from a code
facet's requests (a load into the system domain or into a domain named
by 255 bytes, a reset and a put) and its replies (the hashes a
`missing` lacks, and a refusal naming every module of a load), since a
floor binds both receivers of a facet. It derives `code_request_max`,
the longest request of the `code` interface in its call envelope, from
the same two limits. Every
domain but the system domain receives loads, whatever its
configuration, so the manifest check holds every configured domain's
and session template's runtime limits to the load floors and the system
domain's to the answer floors, every facet of the `code` interface to a
`max_request` of at least `code_request_max`, and its grantee and
server to the facet floors
([design-system.md](design-system.md#the-manifest), property 16). A
domain made from a request runs with the limits its request names,
which no manifest check sees, so every code server also checks the
load floors against its own limits as `erx:limits/0` reports them
before it sends its report. A domain below a
floor fails its start with one log line naming the limit, its value and
the floor, so no domain runs whose funnel would drop a load.
Since a candidate overlay never names more than `code_modules_max`
modules (**A send**, below), every published overlay reaches its next
domain in one message.

**The code server's side.** The code server takes one load at a time and
handles each in four steps, all within 30 s of when it took the load:

1. **Plan.** It goes through the manifest in order. It skips a module
   whose current hash is already `Hash`
   ([What is already current](#code-from-the-host)), and it takes the
   bytes from its release when its release's manifest lists `Hash`.
   Every other blob it fetches. It makes an atom of a name only for a
   module it loads; to check whether a module is current it uses
   `binary_to_existing_atom/1`, and a name with no atom yet names no
   loaded module.
2. **Fetch.** It fetches blob after blob in manifest order, and the
   pieces of each blob in order from offset 0. It asks for the next
   piece only after the previous one has arrived, so `erx_code` never
   has more than one piece queued for it. Once `Size` bytes of a blob
   have arrived, the code server checks them against `Hash` with
   `erx_bytes:sha256/1`. If any blob fails
   the check, the code server answers `{error, {hash_mismatch, Name}}`
   and loads nothing.
3. **Load.** It loads the batch with `erx_code_batch:load/1`, the one
   function `erx_code` also uses for the system domain. That function
   calls `code:prepare_loading/1` and then `code:finish_loading/1`,
   purges once when every refusal is `not_purged`, and names each
   module's file by its hash in hexadecimal. It refuses a module with an
   `-on_load` function (`on_load_not_allowed`), as
   [Overlays](#code-from-the-host) says. Then the code server answers.
4. **Keep.** In a supervised domain, after it answers `ok`, the code
   server waits for `{erx_code_published, Alias, Lifeline}`. When it
   comes, the load is done, and if the load named any module the code
   server monitors `Lifeline` from then on, once for the domain's life.
   If the 30 s pass first, the code server exits with
   `{erx_code, unpublished}`, which ends its domain. A refusal loaded
   nothing, and in a domain no specification restarts there is no
   overlay to keep in step with, so in either case the load is done at
   the answer.

A load whose 30 s pass before its batch is loaded is abandoned, with no
answer and no bytes kept; a start load so abandoned leaves the code
server waiting for its start load, which `erx_code` does not send
again, so the domain's boot timeout ends the domain. A load whose 30 s
pass once its batch is loaded, in a supervised domain, ends the domain
as step 4 does. By that time
`erx_code` has already ended the load, because its own 30 s started
earlier, at the send, and it publishes nothing for a load it has ended.
The alias is gone, so an answer would be dropped anyway. A load that
arrives while another is in progress waits, postponed, until the load
in progress ends. This can happen only just after a deadline, because
`erx_code` sends a target's next load only once it has ended the
previous one. The code server is a `gen_statem`, which enters each
callback through an external call. So a load that replaces the code
server's own modules, or
`erx_code_batch`, leaves it running: when a later load purges old code,
the code server is not running any of it.

**`erx_code`'s side.** `erx_code_target` is a pure state machine with one
state for each target: its current domain and whether that domain is
closed (**The endpoint and its export**, above), at most one load in
flight, and a supervised target's published overlay. `erx_code` does
the effects: aliases, timers, monitors, sends, the store and the calls
to the domain service. Each load is tied to the one domain id its
request resolved to.

**Targets.** The domain service names a domain's target, from the
domain's record alone (`erx_domain_core:target/1`), and hands the name
to `erx_code` in every `started` and in every resolution of a load.
`erx_code` keys its targets by that name and never computes one:

* `{configured, Row}` for a domain of configured row `Row` whose build
  answer carried the `supervised` flag. Every domain the row starts in
  the boot has this target, so the row's overlay outlives each of them.
* `{domain, Id}` for a domain whose build answer did not carry the flag:
  one domain, one target. A domain id is never reused within a boot
  ([design-system.md](design-system.md#the-domain-services-record)).

The system domain is no such target: it loads only through `erx_code`'s
install path. Both names follow from facts that last the boot, a
manifest row and a domain id, so a restarted `erx_code`, which begins
with no targets, names every target as its predecessor did. It makes a
configured target at the first `started` or load that names it and
keeps it until it ends itself, so a row's overlay lasts as long as
`erx_code` does; the manifest's rows bound how many such targets it
ever holds. It makes a target `{domain, Id}` at its first load and
drops it when that load ends: such a domain has no overlay, and nothing
of its target is needed after the load, so these targets number at most
the loads in flight.

A created specification that the domain service restarts
(`restart => permanent | transient`) is supervised too, and its target
needs a name that outlives each of its domains. A domain's record ends
with the domain, so the name needs a record of the specification
itself, which the domain service keeps while it restarts the
specification and which carries the name into each of its domains.
That record, the name, and the bound on how many such targets
`erx_code` keeps, those of specifications left down included, are one
open decision ([Risks and open questions](#risks-and-open-questions)).

A target holds no release. While `erx_code` holds a configured target,
its row boots one release: the boot image's one domain release under
the script the row names
([design-fiasco.md](design-fiasco.md#the-production-image)), and the
boot image does not change within a boot. An overlay lives at most
until the machine ends ([Overlays](#code-from-the-host)), so it always
stands over the release it was loaded over. The release manifest the
verdicts read (**The verdicts**, below) is therefore the same for every
target: that of the domain release. A created specification boots the
script its request named at every restart, so its target, once named,
holds no release either.

**The effect layer.** Beside its store, `erx_code` keeps its lifeline
(**When `erx_code` ends**, below), its targets by name, and, for each
load in flight, the load's alias with its target, its deadline, its
timer and the monitor of its domain pid. It applies the actions
`erx_code_target` returns in order, each one effect: `begin_load`
monitors the domain pid, records the load's deadline, the monotonic
time `code_load_wait` from now, starts a timer for it and holds the
load's blobs in the store; `send` sends a load or a word of publication
to the code server; `serve` slices a piece from the stored blob and
sends it; `end_load` deactivates the alias with `unalias/1`, cancels
the timer, removes the monitor and lets the blobs go; `unalias`
deactivates an alias no load took; `stop_domain` stops a domain through
the domain service by its id; `reply` answers a facet; `log` writes a
record naming the target.

Every message to a domain, a load, a piece or a word of publication,
leaves through one function, which sends with `erlang:send/3`'s
`nosuspend` from a process whose `async_dist` flag is cleared, as the
domain pid sends to a runtime agent. So `erx_code` never waits on a
domain, whatever the system domain's peer does with a connection whose
queue is busy: a send refused as `nosuspend` is a message dropped, like
one dropped past `system_queue`
([design-domains.md](design-domains.md#flow-control)), and the load's
deadline, or for a word of publication the code server's, already ends
what it leaves waiting. A system domain that suspends no sender refuses
none, and the function changes nothing there.

Each event reaches one target:

* `{erx_origin, D, Msg}` goes to the target whose load holds the alias
  `Msg` names as its second element (`erx_code_target:alias/1`), as
  `received(D, Msg)`; a message naming no alias, or an alias of no load
  in flight, is dropped. If the load's deadline has passed when the
  message is taken, the target gets `deadline` first, so the message
  then names no load in flight and is dropped: a load ends at its
  deadline however long its answer and its timer waited in the queue
  together, and `erx_code` never publishes a batch after its deadline,
  by when the code server's own deadline may also have passed and ended
  its domain for want of the word of publication;
* the load's timer, as `deadline`, and its monitor's `'DOWN'`, as
  `domain_down`, go to the target that holds the alias;
* `started(Id, Target, DomainPid, Agent)` goes to `Target`, with a new
  alias for the start load.

A code server's piece requests and answers reach `erx_code` as every
frame from its domain does. The code server sends to the alias, an
`ALIAS_SEND` frame, which the system domain's funnel admits only when
the domain's connection holds `send` on the alias
([design-domains.md](design-domains.md#exports)). The load handed it
that right: encoding `{erx_code_load, Alias, Manifest}` for the domain's
connection wrote the holder. The runtime then delivers the message in the
domain's envelope (D18 of
[design-domains.md](design-domains.md#invariants)), as it delivers an
inspection agent's answer to its asker's alias
([The runtime agent](#the-runtime-agent)). `unalias/1` at a load's end
closes every holder of the alias, so the funnel drops a later send to it
as unauthorised, before any process sees it.

The alias is not the only name of `erx_code`'s side a load hands the
domain. The sender of every message `erx_code` sends it is `erx_code`'s
own pid, handed out with `send` like any sender
([design-domains.md](design-domains.md#exports), case 1), and the word
of publication hands out the lifeline. Both last as long as their
processes. Neither lets a domain act on another's load: what it sends
to either arrives in its envelope too, the lifeline drops every message,
and `erx_code` routes a message by the alias it names and
`erx_code_target` takes it only from the domain of a load in flight
that holds that alias, so a domain reaches nothing but its own load's
protocol while that load runs. What a domain can make `erx_code` hold
through its pid is what it can make any system process it can name
hold: the frames queued on it, up to that process's quota
([design-domains.md](design-domains.md#flow-control)). Taking the pid's
`send` back after each send would need an operation the export table
does not have, a per-name withdrawal of a holder, and would protect
nothing the routing does not.

* **A request.** A code facet's `load` is `{load, Domain, Manifest}`.
  `Domain` is a binary: decimal digits are a domain id, and anything
  else is a domain's name. The facet forwards the request with its
  grant's scope and its grantee's principal, both fixed when the domain
  service minted it (`erx_domain_core:code_scope/3`). An install facet
  forwards `{load, Manifest}` with the scope `system`. `erx_code` reads
  `{load, Manifest}` only under `system` and `{load, Domain, Manifest}`
  and `{reset, Domain}` only under a code scope, and answers anything
  else `{error, bad_request}`. A load into another domain is resolved by
  one call to the domain service, which applies the scope to its records
  and returns the domain's id, domain pid, target, principal, `supervised`
  flag, its specification's `overlay` limit and code server, and whether
  the domain has reported ready, or `scope`. The `overlay` limit is the
  one in the runtime limits of the specification the domain's record
  keeps; the library's build answer carries the `supervised` flag alone,
  so the limit a load is held to is the specification's, whatever the
  library built.
* **The verdicts.** `erx_code` then computes two verdicts from its store
  and hands them to `erx_code_target`, each a pure function of the
  principal's store, the target's release manifest and the hashes of
  the load and its candidate:
  * the **plan**: the hashes that neither the store nor the release
    holds, and the stored size of each blob of the load that the store
    holds;
  * the **charge**, for a facet's load into a supervised target: the
    bytes of the candidate overlay's blobs, each counted once, less
    those the release holds and those the store already keeps for a
    published overlay or a load in flight. The verdict is `no_memory`
    when those bytes do not fit in the store beside what it keeps.

  Only a facet's load into a supervised target forms a candidate, so
  only it is charged: a start load's candidate is the published overlay
  itself, which the store already keeps, and a domain no specification
  restarts has no overlay. `erx_code_target` decides in one order, and
  the first that applies is the answer, with nothing kept for the load:
  1. `{error, busy}`: the target has a load in flight, or the domain has
     not reported ready with a code server, is not the target's current
     domain, or is closed. Its sender sends the load again later.
  2. `{error, {missing, Hashes}}`: the plan found blobs neither the store
     nor the release holds.
  3. `{error, overlay_full}`: the candidate, the overlay now published
     with the load's modules over it, has more blob bytes than the
     specification's `overlay` limit, or more than `code_modules_max`
     modules.
  4. `{error, no_memory}`: the charge's verdict.

  The store keeps every blob that the load in flight names until that
  load ends, so a piece the plan found is still there when the code
  server asks for it.
* **A send.** `erx_code` monitors the domain's domain pid, makes an
  alias, sends `{erx_code_load, Alias, Manifest}` and starts its 30 s
  timer. A facet's load into a supervised target keeps its candidate in
  memory until the load ends.
* **A start.** `started(Id, Target, DomainPid, Agent)` for the
  target's current domain changes nothing. For any other domain it ends
  with `{error, domain_ended}` a load of the target that is sent to
  another domain. A specification has one live domain at a time, so the
  start of its next domain means its last domain has ended, whichever of
  this and the monitor's `'DOWN'` arrives first. The started domain
  becomes the target's current domain, and `erx_code` builds its start
  load. The start load's manifest is the
  published overlay, or no modules at all if the specification has
  none, and it is sent as **A send** says. The store holds every blob a
  published overlay names, so a start load can always be built.
* **A piece request** is valid only if it meets all of these
  conditions: it arrives in the envelope of the load's domain, to the
  alias of the load in flight, and asks for the next piece in
  manifest order, either the next offset of the blob being fetched, or
  offset 0 of a later blob of the manifest once the previous blob is
  complete (the code server skips the blobs it does not fetch).
  `erx_code` answers a valid request with the piece, which it slices
  from the stored blob: `code_piece_max` bytes, or the rest of the blob
  by the stored size the plan gave, never by the manifest's `Size`. A
  request for a blob the store does not hold, such as one only the
  release holds, is not valid. Because of that cursor, `erx_code` serves
  each piece of a load at most once, so a target can make the system
  domain copy no more than the load's own bytes. `erx_code` writes each
  manifest entry's `Size`: the stored size of a blob the store holds,
  and the release manifest's size of one only the release holds. A
  `Size` that disagreed with the stored blob would load nothing and
  serve nothing past the blob: one below it makes the code server check
  too few bytes and answer `hash_mismatch`, and one above it makes the
  code server ask for a piece past the blob's end, which ends the load
  as `invalid`.
* **An answer** is valid in the same envelope and to the same alias,
  with a result of the shape in the table whose every `Name` is one of
  the manifest's and every `What` a member of `abi/services/code.txt`'s
  `code_load_reason`, the closed set of reasons `code:atomic_load/1`
  gives, `system_limit` from the JIT's exhausted code space among them.
  The answer floors count `What` as that set's longest member, so an
  answer of any other atom, which could outgrow them, is invalid, and a
  code server whose batch is refused for a reason outside the set ends,
  with its domain, rather than send one. `ok` is the domain's runtime's
  report that the batch loaded (**What an answer proves**, below).
  * `ok` to a facet's load into a supervised target publishes the
    candidate with a new revision: `erx_code` replaces the target's
    overlay with it, which cannot fail, since the candidate was charged
    when it was formed. In the same step `erx_code` sends
    `{erx_code_published, Alias, Lifeline}` and answers
    `{ok, Revision}`. Into a domain no specification restarts, which has
    no overlay, `ok` answers `{ok, none}`.
  * `ok` to a start load records the revision the start load carried
    and that the domain's runtime reported it loaded, and sends
    `{erx_code_published, Alias, Lifeline}`.
  * An error to a facet's load discards the candidate and is the load's
    answer.
  * An error to a start load fails the start and closes the domain, and
    the published overlay stays as it was: the code server that refused
    it ends its domain with `{start_load, Result}`, which the domain's
    death record keeps, and `erx_code` writes one log record naming the
    specification, the overlay's revision and the refusal. The failed
    start is one end of the specification within its restart intensity,
    so an overlay that no longer loads leaves its specification down
    once that intensity is spent, never running its release in the
    overlay's place. Recovery is the operator's explicit reset
    (**Resetting an overlay**, below).
* **The ends.** A load ends at the first of these events:
  * a valid answer;
  * the end of its domain, through the domain pid's `'DOWN'` or the
    start of the target's next domain, which answers
    `{error, domain_ended}`;
  * its deadline, which answers `{error, timeout}`;
  * a message in the envelope of its domain that names its alias and is
    neither a valid piece request nor a valid answer, which answers
    `{error, invalid}`.

  A message names its alias as its second element, since a receiver
  cannot tell which alias a message came through. A message that names
  no alias cannot be tied to a load and is dropped; the load's deadline
  still bounds a code server that sends only such messages. A message
  that names another alias, or arrives in another domain's envelope,
  changes nothing.

  A timeout and `invalid` end the same way: the candidate is discarded
  and nothing is published, so a supervised domain whose code server
  loads the batch anyway ends at its own deadline (step 4), and any
  other target is left running with an unknown outcome
  ([The deadline](#code-from-the-host)). For a start load they fail the
  start: a code server that loaded the batch ends at its own deadline
  (step 4), and one that had not abandons the load and goes on waiting
  for a start load, which never comes, so the domain's boot timeout
  ends it, as for a start load that never arrives. A start load ended
  by `domain_ended` writes no log record, since the domain's end is
  logged already. Every end deactivates the alias, cancels the
  timer, removes the domain pid's monitor and answers the facet (a start
  load has no facet). Once the alias is deactivated the runtime drops
  every later message sent to it, so an answer that arrives after its
  load has ended reaches nothing. No check is needed for that case.

**Resetting an overlay.** `{reset, Domain}` is the code interface's
recovery from an overlay that no longer loads. `Domain` names a
specification by the id of one of its domains or by the name they take,
and the domain service resolves it under the facet's scope as it
resolves a load, except that the specification need have no live
domain, so one that refused start loads have left down can be reset;
the scope decides by the specification's principal, never by the id or
name alone. A reset is answered `{error, busy}` while a load into the
target is in flight, and `{error, no_overlay}` for a domain no
specification restarts. Otherwise `erx_code` stops a live domain of the
specification through the domain service, as the `domain` facet's stop
does, since that domain may run modules the empty overlay does not
name, and closes it; then it publishes the empty overlay and answers
`{ok, Revision}`, all in one step, so a start of the specification's
next domain is taken only after it and its start load is empty. It
stops that domain by its id, never by name or specification: an id is
never reused within a boot
([design-system.md](design-system.md#the-domain-services-record)),
while a name passes to a later domain once its holder ends
([The host link](#the-host-link)), so a stop that comes late stops
nothing. The specification's next domain boots its release as built;
one that its restart intensity left down stays down until it is started
again, as after any other cause of its ends.
`load -d DOMAIN -r` sends it ([One load, three routes](#one-load-three-routes)).

**When `erx_code` ends.** Overlays live only in `erx_code`, so its
restart begins with no overlays, no stores and no histories, and the
domains that run published code must not outlive the `erx_code` that
holds it. `erx_code`'s **lifeline** carries that: a process `erx_code`
starts and links to at its own start, which traps exits, drops every
other message it receives, and exits on the exit signal from
`erx_code` whatever its reason, `normal` included, so it ends with
`erx_code` however `erx_code` ends. A code server monitors it from
the first confirmed load that names a module (step 4), and its
`'DOWN'`, whatever its reason, `noconnection` and `noproc` included,
makes the code server exit with `{erx_code, down}`, which ends its
domain. A monitor needs only the `send` right the word of publication
hands over ([design-domains.md](design-domains.md#exports)), so no
export is written for it, and it fires for every way the lifeline can
end. So when `erx_code` ends:

* every supervised domain that runs a published module ends, and the
  specification's next domain, which the domain service starts as for
  any end, takes an empty start load from the restarted `erx_code` and
  boots its release, as after a reboot;
* a supervised domain with a load in flight whose batch loaded hears no
  word of publication and ends at its code server's deadline;
* a domain no specification restarts holds no overlay and runs on, and
  whether its batch loaded is its runtime's fact (**What is already
  current**, [Code from the host](#code-from-the-host));
* every facet waiting on `erx_code` answers its caller `{error, failed}`,
  as for any service that ends before it replies
  ([design-system.md](design-system.md#facets-a-configured-domain-serves)).

A supervised domain whose overlay is empty holds no published module,
monitors nothing, and runs on. The restarted `erx_code` writes one log
record saying that every overlay was dropped, and each domain's end is
logged with its reason. A restarted `erx_code` asks the domain service
for each principal's hot store afresh, which frees the store its
predecessor held, so no principal pays for blobs nothing names.

**What an answer proves.** Only the holder of an install facet or a code
facet can make `erx_code` start a load, and only into a domain its scope
holds (V11). A start load carries only what earlier loads through such
facets published for the same specification. The target domain cannot
start a load. It can only ask for the pieces of a load in flight, each
piece once, within that load's 30 s. `erx_code` accepts an answer only
from the domain it asked, through an alias that only that domain was
handed, while the load is in flight. That is the inspection agent's rule
([The runtime agent](#the-runtime-agent)), and the protocol adds no
identity scheme of its own. The system domain is in no code scope and
runs no code server, so nothing this protocol carries can reach its
runtime (V5). The lifeline drops what it receives, so the `send` right a
domain holds on it reaches nothing of `erx_code`.

The envelope and the alias say which domain answered, not what it did.
`ok` is that domain's runtime's report, and nothing in the system domain
can see what another runtime loaded, so asking again would only ask the
same witness. Two facts are therefore kept apart, and every report says
which one it gives:

* **the published overlay**, what the system domain holds and sends at
  the specification's next start: the code service's own fact, reported
  as `service`;
* **the runtime's report** that a batch, or a start load's revision,
  loaded: the domain's own word, reported as `runtime`.

A load's answer `{ok, Revision}` gives the first and relays the second;
its log record names both with their sources ([What is logged](#one-load-three-routes));
and the inspector shows the published revision as `service` and the
modules a domain runs, and its runtime's answer to its start load, as
`runtime` ([Paths](#paths)). A runtime that answers `ok` falsely, or
keeps a batch it was not told was published, misleads only about
itself: its domain can run any code of its own anyway, and its next
domain receives the published overlay again.

**Concurrency.** `erx_code` is one process, and every decision it makes
is a function of `erx_code_target`'s state and one event. It never waits
on a domain: it only sends, each send with `nosuspend` (**The effect
layer**, above), and a message refused or dropped past `system_queue`
([design-domains.md](design-domains.md#flow-control)) appears as the
load's deadline passing, or, for a word of publication, as the code
server's. A domain whose connection is busy therefore delays no other
target's load, timer or monitor. It waits only on its calls to the domain service, which
never calls `erx_code`. Loads into different
targets interleave freely. An install runs in `erx_code`'s own runtime
and waits on no domain. A facet waits for its load's answer with no
timeout, and `erx_code` answers it with `gen_server:reply/2` when the
load ends.

**Failure paths.**

* **The target restarts in the middle of a load.** The load answers
  `{error, domain_ended}`. The next domain's start load reads the
  published overlay.
* **A piece is refused.** A code server that follows the protocol never
  meets this: the plan found every blob, and the store keeps each one
  until its load ends. A piece request that `erx_code` cannot serve is
  out of order, past its blob's stored end, or names a blob the load
  does not name or the store does not hold, so it ends the load as
  `invalid`.
* **A blob does not match its hash.** The code server answers
  `hash_mismatch`, nothing is loaded and the candidate is discarded.
* **The target domain ends.** This is the same as a restart, except
  that no next domain starts for a target that no specification
  restarts.
* **A domain's connection is busy.** A send refused as `nosuspend` is
  dropped; the load ends at its deadline, or, for a lost word of
  publication, the code server ends its domain at its own, and every
  other target's load runs on meanwhile.
* **A load ends unpublished after the batch loaded**, at the deadline,
  as `invalid`, or because its word of publication was lost. The
  supervised domain's code server ends it at its own deadline, and its
  next domain starts from the published overlay.
* **A start load is refused or unanswered.** The start fails and the
  domain is closed; it ends by its code server's exit, or, when its code
  server abandoned the load before loading it, by its boot timeout; the
  published overlay stays.
* **`erx_code` ends.** Every facet waiting on it answers its caller
  `{error, failed}`, every supervised domain that runs a published
  module ends through its lifeline monitor, and every overlay is
  dropped (**When `erx_code` ends**, above).

**Refusals and error results** of a load into another domain, and of a
reset:

* `{error, scope}`: outside the facet's scope, or no such domain.
* `{error, bad_request}` and `{error, {bad_manifest, Why}}`: the request
  reader refused the request.
* `{error, busy}`: the target has a load in flight, or the domain has
  not reported ready, is not its target's current domain, or is closed;
  nothing is kept, and the sender sends the request again.
* `{error, {missing, Hashes}}`: blobs that neither the store nor the
  target's release holds.
* `{error, overlay_full}`: the candidate overlay is past its byte or
  module bound.
* `{error, no_memory}`: the charge's verdict: the principal's hot store
  cannot keep the candidate's blobs beside what it keeps.
* `{error, no_overlay}`: a reset of a domain no specification restarts.
* `{error, {hash_mismatch, Name}}` and `{error, {not_loaded, Failed}}`:
  the code server refused the load.
* `{error, domain_ended}` and `{error, invalid}`, as above.
* `{error, timeout}`: nothing was published; a supervised domain that
  loads the batch anyway ends, and for any other domain the outcome is
  unknown.
* `{error, unavailable}`: no `erx_code` is registered when the facet
  forwards the request.
* `{error, failed}`: `erx_code` ended before it answered; the facet
  gives this answer, and nothing it published survives.

A load meets `busy`, `missing`, `overlay_full` and `no_memory` in that
order (**The verdicts**), and nothing is sent before all four pass.

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
  service's request ([design-system.md](design-system.md#the-domain-library)).
  A store lives as long as the `erx_code` that asked for it
  ([When `erx_code` ends](#the-code-server)) and is never written to a
  data partition. A store is
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
  last 16 hashes it published for each module and the time of each, so the
  history survives the domain's restarts, as the overlay does, and it
  frees a blob that no
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

### The host link

The host link connects `tools/erx` to `erx_hostlink` over the second UART,
which belongs to the system domain on every platform and is served there
by a driver like the console's, beside `erx_hostlink`; the system
manifest names the UART by its device-tree path; under QEMU it is a UNIX
socket
(`-serial unix:build/qemu/RUN/hostlink.sock,server=on,wait=off` after the
console's `-serial`, in the run's owner-only directory). On Fiasco the
root hands the host link's device record only under `erx.hostlink=1`
([design-fiasco.md](design-fiasco.md#the-command-line)), which the harness
adds with the second `-serial`. On a board the host reaches the UART
through a serial adapter or a UART bridge's UNIX socket
([One load, three routes](#one-load-three-routes)).

The transport has one trusted physical or local peer: whoever can open
its socket or its tty on the developer's host. The harness creates its
UNIX socket in an owner-only directory with access restricted to that
host user; a board installation controls physical access to its UART,
and the developer's host controls, by its file permissions, who opens
the serial adapter or the bridge's socket
([One load, three routes](#one-load-three-routes)).
CRC detects corruption and session identifiers reject stale traffic;
neither authenticates an active attacker that can read or inject the link.
A bridge that serves the line on a network is outside this transport
contract, and the host tool has no transport that reaches one. Remote
use is the SSH route, an SSH `exec` of the session command `load`, which
runs in the login's own session with that session's facets, never the
host link's ([One load, three routes](#one-load-three-routes)); it does
not reuse CRC as a MAC or add a custom cipher.

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
  tool signs with the build's development key), `code` (scope `all`, each
  load naming its domain), `domain` for every domain, named by its
  domain id, which is never reused, where a name, unique among live
  domains machine-wide, passes to a later domain once its holder ends,
  `console`, and `web`, the web domain's relay for
  `tools/erx web` ([design-web.md](design-web.md#the-host-tools-front-end)),
  which development builds alone offer and a release manifest that lists
  it fails the manifest check; in release builds what the system
  manifest lists, by default nothing, and `console` there starts a login,
  as the serial console does. A `domain` facet carries
  `erx_domain`'s operations on one domain: stop it, and read its death
  record. These roots are targets of the host link's own protocol,
  `abi/protocols/hostlink.txt`, at the machine's edge, and not facets
  minted for another domain: the host link is the system domain's, so
  each root calls a service of the system domain in that domain's own
  runtime, at the scope its configuration gives, and its admission is
  the host link's session table, V3. The one root that reaches another
  domain, `web`, does so through the system domain's facet of the web
  domain's `web` interface (`abi/services/web.txt`), a declared instance
  like any other. The same services reached from a domain are facets of
  their declared interfaces: the host link's `inspect` and a session's
  are one interface at two scopes, and so are the host link's `code` and
  a session's.
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
with `emfile`. It keeps at most 32 requests pending and at most 64 tags
in use, requests and flushes together, at its grants or held; a request
beyond 32 fails with `emfile`, and a message that would take a 65th tag,
or one on a tag in use, is discarded and counted. The grants are the system
domain's own, shared with its processes, and a grant's 64 requests in
flight cannot be reserved, so a request the bridge sends may still be
refused there; a flush is never refused, since a grant admits one flush
waiting for each request in flight besides them
([design-files.md](design-files.md#bounds)). The flushes of one
request are answered in the order they came, after the request is
answered or abandoned, with at most one of them at the grant at a time,
and a flush of a flush joins the flushes of the request it names, so the
host never reuses a tag while an answer on it may still come. A `version`
is served only while no session is open; once one is, a `version` is
refused with `einval` and changes nothing. This departs from 9P2000,
whose `version` resets a session in mid-course and abandons every tag in
use: no client the bridge serves sends one, and a client starts afresh by
opening a new host-link session, whose end clunks everything the old one
held. So what a grant holds always has the tag the host named it by, and
the bounds count only requests and flushes. It cuts a `read`'s or
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
| `erx:i(Path) -> ok \| {error, scope \| unsupported}` | renders the record for `Path` in the shell, through the caller's inspect facet, every value with its reporter; a pid in `Path` becomes its `proc_id()` in the caller's own runtime, so no request carries a pid; `scope` for a path outside the facet's scope or one that names nothing |
| `erx:domains() -> ok` | lists every domain the caller's inspect facet covers: id, name, principal, state, memory, CPU time and process count, each value marked with its reporter |
| `erx:ps() -> ok` | lists every process of every domain the caller's inspect facet covers, by domain, and under a session its programs: pid or program number, registered name or program name, current function, reductions, memory and queue length, each marked with its reporter; the `ps` command prints FreeBSD's columns as text ([Text commands](design-shell.md#text-commands)) |
| `erx:inspect(Path, Options) -> {ok, record()} \| {error, Reason}` | `Options` holds `offset`, `limit` and `timeout`; `Reason` includes `scope` and `no_facet` |
| `erx:source(Pid \| {module(), atom(), arity()}) -> ok \| {error, Reason}` | prints the source lines around a process's current location or a function's first line; `{error, unsupported}` when the module's release carries no source |
| `erx:trace(Spec) -> {ok, reference()} \| {error, Reason}` | starts a trace of processes, frames or kernel events, `Spec` as in [Tracing](#tracing), that prints in the shell; `Reason` is `badarg`, `no_facet` or `scope` for a refusal, and `{failed, Why}` when the trace process ends before it has started the trace, `Why` its exit reason; `erx:trace_stop(Ref)` ends it |
| `erx:attach(Domain) -> ok \| {error, Reason}` | a console session with a shell inside `Domain`, through its console facet, which the caller holds for its own principal's domains; the shell has that domain's authority, never the system shell's ([The console](#the-console)) |
| `erx:console_size(Width, Height) -> ok` | system domain only |
| `erx_code:history(DomainId, Module) -> {ok, [{Hash, Time}]} \| {error, scope}` | the hashes loaded into a domain for a module, newest first, at most 16, through the caller's inspect facet ([The code store](#the-code-store)) |

**Shortcuts.** The shell commands of the vision work without the `erx:`
prefix in every domain's Erlang shell: `ps()`, `i(Path)`, `domains()`,
`source(X)`, `trace(Spec)`, `trace_stop(Ref)` and `attach(Domain)` are
exports of erXos's `shell_default`, which the shell consults for a local
call it does not recognise, after `user_default` and before the functions
defined in the shell (`lib/stdlib/src/shell.erl`, `non_builtin_local_func/4`). Each is a
one-line call of its `erx` function, with the same facets and no
authority of its own. Living in `shell_default`, they survive a release
that brings its own `user_default`. None shadows OTP's own commands: the
shell's commands (`v`, `h`, `b`, `f`, `rd`, `rf`, `rl`, `rp`, `rr`,
`history`, `results` and the rest, `shell:local_func/0`) come first, and
OTP's `shell_default` exports `i/0` and `i/3`, its process listing and
process information, but not `i/1`, so `i()` and `i(X, Y, Z)` keep OTP's
meaning and `i(Path)` is the inspector; `erx:i()` keeps its prefix. A
function defined at the prompt has each of its calls resolved by name
and arity (`shell.erl`, `reconstruct1/3`, through
`edlin_expand:shell_default_or_bif/2`): a call of a shortcut's name and
arity goes to `shell_default`, and every other call where stock sends
it, by name alone over OTP's own exports, so `trace(Spec)` is the
shortcut while `trace(P, true, [send])` stays `erlang:trace/3`, and
argument completion, by name alone, completes `trace(` as stock does.
`shell_default`'s `erx_shortcuts` attribute lists the shortcuts for
that resolution. A function of a shortcut's name and arity cannot be
defined at the prompt, as one of the name of an OTP export cannot, a
documented difference with a test; one of a shortcut's name at another
arity is defined or refused as on stock. A test derives the shell's command list and
OTP's `shell_default` exports from OTP's modules and fails if a
shortcut collides with either or with an auto-imported BIF, and compares erXos's resolution with
stock's for every name stock exports from `shell_default` or `erlang`,
every shell command and every shortcut, at every arity, and fails on
any difference but a shortcut's own name and arity.

### The host tool

`tools/erx console | load | watch | inspect | source | trace | files | web`;
`web` serves the web client to a browser on the host and relays it over
the `web` facet ([design-web.md](design-web.md#the-host-tools-front-end));
`files` relays a UNIX socket to the host link's files stream
([Files between the host and the machine](#files-between-the-host-and-the-machine)).
A command that opens a host link session reaches the machine by one of
`--socket` and `--tty`, and `load` and `watch` also by `--ssh`
([One load, three routes](#one-load-three-routes)). Every command
has long options, exits 0 on success, 1 on failure and 2 on a usage error,
starts every subprocess with an argument vector, and gives up after a
deadline it names.

## Compatibility and migration

Until a release promises compatibility, nothing here owes any to an
earlier build ([design.md](design.md)). Every format carries
a version, which serves only to make a mismatch fail loudly: host link
frames (the version byte, 2), inspection records (`schema` 1), and the
escape rules, which are generated with each build and checked by build
identifier. One build produces every component of a boot; the host tool
checks the build identifier in the root's `hello` reply and refuses a
target from another build. The console relies on `prim_tty` and on the
protocol between `group` and its driver, both internal to OTP; erXos owns
its OTP tree, so they change only when erXos changes them, and any such
change reruns the console tests first.

No state here outlives a boot: the code service keeps its overlays,
histories and hot stores in memory only, so no build reads what an
earlier one wrote.

Three surfaces are erXos's own and differ on purpose from what users may
know:

* **`/proc` is not Linux's.** A program that parses Linux's `/proc` files
  finds other files, and toybox's applets that do so are not built
  ([The /proc tree](#the-proc-tree)).
* **A module's version is its hash.** The store's hash is the SHA-256 of
  the whole file; OTP's `module_info(md5)` keeps its meaning.
* **The shortcuts live in `shell_default`.** A function of one of their
  names and arities cannot be defined at the prompt.

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
| A supervised domain's code server reports while no `erx_code` is registered | the domain service's `started` finds no process | nothing sent | the domain's boot ends at its boot timeout, and its specification restarts within its restart intensity |
| `erx_code` sends to a domain whose connection's queue is busy | `erlang:send/3` answers `nosuspend` | the message dropped; nothing else changes, and every other target's load runs on | the load ends at its deadline with `{error, timeout}` and a log record, or, for a word of publication, the code server ends its domain at its own deadline |
| A start load is refused, goes unanswered for 30 s, or answers `invalid` | the code server's own refusal, or the code server's deadline with no word of publication; otherwise the domain's boot timeout | the published overlay unchanged; the domain ended, counted against its specification's restart intensity, and left down once that is spent | a log record and the domain's death record naming the refusal, the log record also the specification and the overlay's revision; `load -d DOMAIN -r` resets the overlay, and the next domain boots its release |
| A load or a reset names a target that has a load in flight, or a load names a domain that has not reported ready, is not its target's current domain, or is closed | `erx_code`'s target state | nothing kept | `{error, busy}`; `load: NAME: busy`, and the sender sends it again |
| A supervised domain loads a batch that `erx_code` does not publish: the load ended at its deadline or as `invalid`, or the word of publication was lost | the code server's deadline in step 4 | the published overlay unchanged; the domain ended by its code server, counted against its specification's restart intensity, and its next domain started from the published overlay | `{error, timeout}` or `{error, invalid}`, which for a supervised domain means nothing was published; the domain's end and reason in the log |
| `erx_code` ends | its lifeline's `'DOWN'` at each code server that monitors it, and each code server's deadline for a load in flight | no overlay, store or history; every supervised domain that ran a published module ended and restarted on its release; a domain no specification restarts runs on | the facet's `{error, failed}`; one log record from the restarted `erx_code` that every overlay was dropped, and each domain's end in the log |
| A domain's limits are below the code protocol's floors | its code server, at its start | the domain ends before its applications start | a log line naming the limit, its value and the floor |
| A code server's message naming the load's alias that the load in flight does not expect: a piece out of order, past its blob's stored end, or of a blob outside the load or not in the store, or an answer naming a module outside it | `erx_code_target`'s check | as at the deadline: the candidate discarded and nothing published | `{error, invalid}`; outcome unknown for a domain no specification restarts |
| `erx_console` crashes | its supervisor | each session's group survives in its own process | the console restarts with every line showing a login: a restart ends every login and the system shell and its facet, and the sessions run on, reachable by a login; terminals on displays are the sessions' own and do not notice |
| The system domain faults, or halts outside an ordered shutdown | the kernel, through the fault gate or the watchdog ([design-kernel.md](design-kernel.md#the-root-task)) | nothing of the running system: every domain ends with the system domain's space; the kernel writes a crash record where the platform keeps one across a warm reset | the machine ends by `erx.panic`, which in a release build resets it and boots the committed slot; the console shows the boot banner, and `[kernel, crash]` and `/proc/kernel/crash` show the record to the system shell; the host tool's session ends and reconnects after the boot |
| A `/proc` read meets a slow domain | the inspector's deadline | the snapshot, with `[timeout 500]` for the attributes that missed it | the file shows the status, never a guess |
| A blob does not match its hash | the code server's check | nothing loaded; the bad copy discarded | `{error, hash_mismatch}` from the load, in every flavour of load |
| A principal's hot store cannot keep a candidate overlay's blobs | the charge's verdict, which `erx_code` computes from the store before the load is sent | nothing sent; the candidate discarded | the load fails with `{error, no_memory}` |
| A load names a domain outside its facet's scope, or one that does not exist | `erx_code`'s scope check at `load` | nothing loaded; blobs already sent stay in the principal's store until it frees what nothing names | `{error, scope}`, alike for both; `load: NAME: scope` from the command |
| A domain's code server does not answer a load within 30 s | `erx_code`'s deadline | the candidate discarded and nothing published; a domain left running unless its code server loads the batch anyway, which in a supervised domain then ends it (the row above) | `{error, timeout}`; outcome unknown for a domain no specification restarts; loads into other targets were never held up |
| The domain ends while a load into it is in flight | `erx_code`'s monitor of the domain's domain pid, or the start of its specification's next domain, whichever comes first | the candidate discarded; the next domain's start load reads the published overlay | `{error, domain_ended}` |
| The connection ends before a load answers: a reset, a pulled cable, `ssh` ending, or the network domain stopped by the code being loaded; or the tool's 120 s pass | the tool | whatever the code service did, which is one of the endings above or the published candidate | the tool says the load's outcome is unknown and exits 1; the inspector's `[domains, Id, modules, Module]`, which the domain's runtime reports, shows the hash each module runs, `[..., history]` what was loaded, and the overlay's revision what a restart runs; sending the load again is a new load that skips what is still current |
| A loaded driver breaks the network, and with it the SSH route | the operator | the host link and the console, which need no network | the operator loads a fix over the host link, `load`s at the console a file already on the machine, or reboots, which returns every driver domain to its release |
| `load` reads more than 16 MiB, or its standard input ends before or goes on after its modules | the command, before the exchange | nothing sent | `load: NAME: too large`, `load: standard input: short` or `load: standard input: trailing bytes`, status 1 |
| `--ssh` names a destination that begins with `-`, or a domain or module name `rc` would not read as one word | the host tool, before it starts `ssh` | nothing sent | a usage error naming the option |
| `--tty` names a path that is not a character device, or `stty` fails | the host tool | nothing sent | the tool's error with `stty`'s message, through the line escape |

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
only for a login at a secure line, V6, on the UART and the host link
alone; a display domain provides no line, and a terminal on a display is
a program of its session ([design-display.md](design-display.md#security));
and the console never logs a passphrase); console
sessions in other domains (only a tty's bytes, its size and a hang-up
cross, and the console copies the bytes without reading them; the shell
runs with the target domain's authority, never the system domain's); the command
shell and its programs ([design-shell.md](design-shell.md#security)); the
inspect service (the scope held only by the facet in the system domain
and fixed at its mint by one pure function, a request that carries a
path and options alone, a bounded query decoder in safe mode with a fuzz
target, answers within `inspect_reply_max` that name processes as data
and so hand out no name, V10, and query workers within a heap, a
lifetime and a reservation of their own); the `/proc` trees (a
server in each reader's own runtime over its inspect facet, so the tree
can show nothing its facet does not answer, names encoded injectively,
snapshots bounded per grant and charged to the reader); the code
store (blobs checked by hash before any loader reads them, each
principal's hot store written only by the code service and kept in
memory only, so no file system can supply code to a domain); the code facets (one interface whose scope the domain service
fixes at the mint and `erx_code` checks at each load, whichever route
carried the request, V11; `load`, which holds only its session's
facets, reads at most 16 MiB, and whose files and standard input are
input to the code service, never code; and a deadline on every load into
another domain, so a domain that never answers holds up only its own
target; and a code server that keeps no batch `erx_code` has not
published and monitors, never links to, `erx_code`'s lifeline, which
drops what it receives); the host
tool's transports (a UNIX socket or a tty, whose
reach the host's permissions decide, a `--ssh` destination never taken
as an option and no word `rc` would split, and `ssh`'s standard error
printed through the line escape); the inspector's scopes (owners from pids and kernel records,
never from domain reports); runtime reports (validated by the system
domain's funnel, then decoded in safe mode, taken only when the asked
domain, the alias, the path, the kind and the ids agree with the
question, with another domain's processes dropped); and the host tool's decoder (bounded, same grammar, generated
line escape).

**Information that leaks.** Holders of an inspect facet see the names,
current functions and resource use of what their scope covers; that is the
facet's purpose. A scoped facet sees nothing machine-wide beyond the
attributes the schema marks `visible any`: the build identifier, the
development flag, the DMA profile, the uptime, the CPUs online, the
memory total and free, and each CPU's idle time and ready threads, the
last three of which move with the other domains' activity, a side
channel accepted so that every session sees the machine's load
([Scopes](#inspection)), and the clock's record without the domain that
sent the last sample and the server it came from. Pids and domain ids reveal
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
`console` line hold the
system-shell facet, which makes each as powerful as the system domain,
and every `root` session inspects at scope `all`, wherever it logged in,
the web included. In development builds `root`'s session, an SSH login's
included, holds the install facet and a code facet of scope `all`, so
whoever holds one of `root`'s login keys can load code into every domain
over the network; the code facet adds nothing to what the install facet
gives already, since code in the system domain reaches every domain. Hot-loaded code in a
domain has that domain's full authority, as OTP states for any loaded
code. A replay of a recorded host link after a machine reset runs its calls
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
program cannot read what is typed outside its own connected tty, and at a
console line `Ctrl-G` always reaches the real menu, during which it can
write nothing.

## Verification and testing

The inspection schema generates valid-input builders, boundary mutations
and fuzz entry points for the production validators. Independent fixtures
exercise every status/reporter combination, unauthorized paths and fields,
unknown keys without atom creation, and hostile names in every projection.
They check that rendering never turns missing data into success and that a
development-only field never reaches a release projection. The generated
reference tables and field projections are generated into the build tree and fall under the
determinism test of the generated tree.

Each area below names its oracles and fuzz targets, and the seeded
faults that must make its tests fail where it has any.

* **Exact output:** the test of V1, on the console and on the host tool's
  `console` command; seeded: an escaping step in `output/3` or in the
  console's copy. `prim_tty` from `init_ssh/3` here and in stock OTP
  29.1.2, the oracle, turns the same requests, every printable and
  control character in `{putc, Binary}` among them, into the same bytes,
  except a C0 control character other than tab, newline, return and escape, which stock shows with bit 5
  set (`^ ` for NUL) and erXos in caret notation (`^@`; edit 79 of
  [design-runtime.md](design-runtime.md#the-edits-outside-syserxos));
  seeded: a change to its caret rendering.
* **The line discipline:** `erx_tty` explored exhaustively over its flags
  and a small alphabet of bytes, and differentially against a host
  pseudo-terminal with the same `termios`, comparing what a reader gets,
  what is echoed and what the master gets; the exploration also drives
  `read_wait/3`, `timer/2` and `read/3` over each of POSIX's four `VMIN`
  and `VTIME` cases. `set/2`, `size/3` and `input/3` have a fuzz target,
  which checks that feeding untaken bytes back with the returned room
  gives the same state and actions as a byte at a time, that the room
  returned is what the echo left, and that a signal key at room 0 echoes
  after its flush. `erx_tty_modes`' `adopt/2` is checked exhaustively
  against libedit's masks. Seeded: `ONLCR` applied with `OPOST` clear; a
  `read_wait` that ignores its count; an `input/3` that goes on past a
  signal key; echoes joined out of order; a dropped piece of echo that
  drops the rest of its call; a bound of each call's own on repeated
  `VREPRINT` and `VINTR` under `NOFLSH`; a flush that keeps the room, and
  one that also gives back the output not taken; FreeBSD's walk past the
  drop on a `VREPRINT` with room up to a `^A`; an `adopt/2` without its
  masks. A waiting reader is told once per call, after its last key, as
  FreeBSD's `ttydisc_rint_done` wakes readers once after a run of
  `ttydisc_rint` calls (`sys/kern/tty_ttydisc.c:1294-1305`).
* **Cooked and raw**, by Erlang commands through `erx_cmd`
  ([design-shell.md](design-shell.md#interfaces)) and by C programs with
  the signal handshake
  ([design-programs.md](design-programs.md#the-terminal)): cooked lines
  with `VERASE` and `VKILL`, unechoed passwords, raw keys, and `Ctrl-Z`
  and `fg` around a program that changed the modes. Seeded: the shell's
  restore removed, which breaks the prompt; `ISIG` ignored by `input/3`,
  under which `Ctrl-Z` never stops the program.
* **Timed reads:** `VMIN` 0 and `VTIME` 1 for a blocking read and a
  `poll`. Seeded: a `read_wait` that starts no timer; a `poll` that
  starts one; the 4,095-byte bound on a cooked line removed, which grows
  the model's state past its limit.
* **Many writers:** two programs and an Erlang process writing numbered
  records at once, each writer's bytes arriving complete and in order.
  Seeded: the owner taking the end of a write before its start; the room
  counted before `output/3`, which makes 4 KiB of newlines under `ONLCR`
  overflow a frame.
* **The tty's messages**, which have a fuzz target. Seeded: a master that
  drops a `{tty_taken, N}` or a resize, with the repeat removed; `size/3`'s
  check removed, under which `{tty_size, 24, 0}` makes `prim_tty` fail
  with `badarith`; a receiver that skips each of the table's checks.
* **A stopped tty:** a detached session's program waits in `write` past
  4 KiB, loses nothing, takes a caught signal and lets another thread
  `exec`. Seeded: the room reported while the tty holds 4 KiB; the wait
  made a request outstanding.
* **Attributed text:** the test of V9, through the menu, the log,
  `erx inspect` and `/proc`. A test re-derives the character classes from
  OTP's Unicode data; `erx_text` and the host tool's twin answer one
  shared file of vectors; the field escape's fuzz target checks that
  unescaping inverts it and refuses what it does not write. Seeded: the
  escape removed from any one display; a host-tool print that skips its
  printer, caught by the source check.
* **Logs:** a domain that floods, malforms or poisons its records leaves
  one escaped line per accepted record under its own id and principal,
  and a count of the rest. The console's two decoders of log records
  have fuzz targets. Seeded: edit 43 removed, under which `logger_simple_h`
  prints a newline raw; a system configuration that names
  `logger_std_h` on a standard device, which the release check refuses.
* **Inspection:** one test per status and per reporter; the collector of
  `erx_object_info` over constructed reports, one per row of its table;
  scopes; a domain whose agent lies, which appears marked `runtime`; a
  session's program and its child under the session alone (V8). Seeded:
  a flipped bit or status for each collector row; a backend bit for
  `guarantee` that names no `kernel` attribute. The trace merger delays
  the stream by at most 100 ms for a source that stops answering and
  marks a late event `late`.
* **The inspect service and the runtime agent.** Seeded, each failing its
  case:
  * `erx_domain_core:inspect_scope/4`, over every principal, build flag
    and `start` grant: `all` for every principal of a development build;
    `[apps]` among the trees of a grantee without `start`;
  * in a release build: a scope that ignores its trees; a resolver that
    lets a tree's paths reach the domains they name;
  * an admission path that takes a scope from a request's options;
  * a session start that mints the facet with the session's own domain
    as its scope, and one that mints `all` for every session;
  * a scope fixed as a list at the mint, which misses a later command
    domain;
  * a template grant the domain service skips; a runtime that invents a
    scope when it holds no facet; a `ps` that queries the inspector;
  * a wait with no deadline, and a facet that serves its requests in its
    own process one after another;
  * an agent that answers any origin; an agent that takes exactly
    `[processes, Pid]`;
  * a worker that checks an agent's answer with
    `erx_schema:validate_record/1` alone, which takes an answer about
    another process, another domain or an attribute `runtime` may not
    report;
  * a check of the agent pid's creation alone;
  * a query worker that asks every domain before it builds the page; one
    that takes only its answer by a selective receive; one with no
    deadline of its own;
  * the byte cut at `inspect_reply_max` removed; a schema kind whose
    largest record passes it, which the generator refuses;
  * the query decoder's fuzz target (`tools/fuzz/erx_inspect_query.rb`)
    checks that it accepts exactly the requests within the Bounds, never
    raises and creates no atom; seeded: the bound on a path's length
    removed.
* **Tracing:** traces of processes and frames across domains, scoped
  facets, and the trace process's flow control, with the merger, the
  clock conversion and the decoder as pure cores in host tests. Seeded:
  a merger that counts an `unsupported` row as a source, and one that
  drops an `overwritten` count; a sign error in the conversion; a decoder
  that names an unknown value `park` or prints a CPU marked unknown; each
  refusal of `erx:trace/1` removed; an unknown domain id answered
  `badarg` rather than `scope`; an `erx_trace_ring:read/3` that truncates
  a bignum cursor; a printer that skips `erx_text:escape_line/1`; a
  window that stays open, drops without reporting, or has no cap; a
  `dropped` report that skips the merger, ignores the shut window or
  counts as one; a check that takes a malformed `trace_ts` or a message
  with another reference. A process spawned with `{erx_untraced, true}`
  is never seen. Fiasco's ring and its four-CPU case are in
  [design-fiasco.md](design-fiasco.md#verification).
* **Host link:** the session protocol (hello, calls, the window, expiry,
  replacement) is a pure state machine. An independent TLA+/TLC model
  checks its contract, and a host test explores the implementation over every
  interleaving of two sessions, lost frames and duplicates against an
  independent oracle. Each model property maps to a concrete check under
  [Protocol verification](design-verification.md). A fuzz target
  for the deframer (COBS, CRC, header, credit) and one for the Ruby
  decoder, each with a persisted corpus.
  Tests inject equal and unequal 128-bit session identifiers, fresh hello
  nonces, and near-exhausted frame/call counters: a counter never wraps
  into a prior request, and a hello replayed after a machine reset
  matches no session. The harness checks owner-only socket access, and
  release configuration refuses an unauthenticated network bridge. CRC
  success is never treated as peer authentication.
* **Files with the host:** the oracle is Linux's 9P2000.L client in the
  oracle guest, which mounts the `proc` and `data` trees through
  `tools/erx files` and runs a file-semantics corpus; under QEMU, OTP's
  `file_SUITE` runs over a host directory at `/host`, and a fake 9P
  server's malformed replies fail each request with `eio` and nothing
  more. `erx_9p` has a fuzz target over the files stream's bytes. Seeded:
  a bridge that keeps its fids across a session's replacement; one that
  skips the `Aname` check. A recorded-frame test establishes behavior for
  its chosen identifiers, not a proof that a random collision cannot
  occur.
* **Logins:** the release console's login, the secure-line rule (V6),
  the failure limit per name, class of terminal and line, and each
  line's menu (V7). Seeded: a console that grants the system-shell facet
  at a line that is not secure; one that moves a terminal connected at
  another line.
* **Code:** hot loads with and without the install facet, atomic
  batches, and overlays across restarts.
  * `erx_domain_core:code_scope/3` over every principal and build flag,
    and a load into a domain outside the scope, by name and by id,
    answered as one into a domain that does not exist, and `-d 4`
    through the code facet answered the same. Seeded: `all` for a
    principal that is not a system-shell principal; `all` in a release
    build; the system domain in a code scope (V11).
  * A second load into a domain while the first is in flight is answered
    `{error, busy}` with nothing kept, and sent again once the first has
    ended it publishes its candidate over the first's overlay. Seeded: a
    service that admits the second load while the first is in its steps,
    under which the second publishes an overlay without the first's
    modules.
  * A silent target, in a host test with the deadline shortened: a stub
    code server of a supervised specification that never answers, and
    another that answers after the deadline. The load answers
    `{error, timeout}`, nothing is published, no word of publication is
    sent, the late answer publishes nothing, and meanwhile an install
    and another principal's load into another domain complete. Seeded:
    one load in flight for the whole machine, under which the other load
    is answered `busy`; the deadline removed, under which the silent
    load never answers.
  * A code server, on a host node, of a domain no specification
    restarts, whose load ends at `erx_code`'s deadline just before it
    loads the batch: the batch loads and the domain runs on. Seeded: the
    keep step applied in every domain, under which the code server ends
    its domain.
  * A reset that races its domain's restart: the domain ends after the
    domain service resolved the reset and before the stop, and a later
    domain of another specification has taken its name. The reset stops
    nothing, the other domain runs on, and the specification's next
    domain takes an empty start load. Seeded: a stop by name, under
    which the other domain is stopped.
  * A facet's load into a domain that has not reported ready, a
    supervised one whose start load the test holds back and one no
    specification restarts that is still booting, is answered `busy` with nothing sent, and the start
    completes. Seeded: the ready check removed, under which the load
    into the booting domain is sent and its 30 s run inside the boot.
  * A domain no specification restarts boots to ready with `erx_code`
    stopped, and a supervised one waits for its start load. Seeded: the
    `supervised` flag ignored, under which every code server waits and
    the first domain's boot ends at its boot timeout.
  * The plan's flags, in the domain library's host test: a configured
    row whose `restarts` is above 0 and a request whose `restart` is
    `permanent` or `transient` get `supervised`; a configured row whose
    `restarts` is 0, a `temporary` request, a session and a partial-boot
    program do not, with and without `det`. Seeded: the flag for every
    configured row, under which the row with no restart is supervised.
  * The domain service's notice, in a host test over its stand-in
    library and a stand-in `erx_code`: a configured row whose build
    answer carries `supervised` sends one `started` when its code server
    reports, naming `{configured, Row}`, and the row's next domain, after
    a restart, sends one naming the same target and its own id; a domain
    whose answer does not carry the flag sends none, and nor does a
    report that arrives after its domain's boot timeout, or one whose
    `Ref` is not the live record's for its id. With no `erx_code`
    registered, a supervised domain's report is recorded, nothing is
    sent, and the service answers its next request. Seeded: the target
    derived from the domain's id, under which the two notices name
    different targets; the flag ignored, under which the unsupervised
    domain is announced; the record found by id alone, under which the
    report with the wrong `Ref` sends a `started`; a plain send to the
    registered name, under which the service ends with `badarg`.
  * `erx_code`'s effect layer for start loads, extending
    `test/erlang/erx_code_tests.erl`, with stub domain pids and code
    servers and the deadline shortened: `started` sends the code server
    an empty start load, whose `ok`, sent to the load's alias in the
    domain's envelope, is answered with the word of publication naming
    the lifeline; `started` for the target's next domain ends the first
    domain's load, so its later `ok` publishes nothing; a silent code
    server's load ends at the deadline with one log record; a domain
    pid's end ends its load with none; each end deactivates the alias
    and removes the monitor; an `ok` that the test queues before the
    deadline while `erx_code` is held with `sys:suspend/1`, and releases
    after it, publishes nothing and ends the load as timed out. Seeded:
    the target keyed by domain id, under which the first domain's late
    `ok` is published; the monitor left out, under which the ended
    domain's load waits for its deadline; the deadline check left out,
    under which the held `ok`, ahead of its timer in the queue, is
    published.
  * A busy connection, in the same file: a stub code server on a peer
    node the test has stopped, behind a connection whose queue a helper
    process with `async_dist` set has filled past ERTS's busy limit, and
    a second stub on a node that answers. Both get `started`; the second
    start load is answered and published, and the first ends at its
    deadline with one log record. Seeded: a plain send in place of the
    one send function, under which `erx_code` is suspended at the first
    start load and the second never comes.
  * A stub code server of a supervised specification that answers `ok`
    receives the word of publication, and the facet's answer is
    `{ok, R}`; a start of the specification's next domain then carries
    revision R. Seeded: the word left out, under which the code server
    ends its domain at its deadline though its load was published.
  * The code server's keep step on a host node, against a stub
    `erx_code` and a stub lifeline: an `ok` that is never confirmed ends
    the code server with `{erx_code, unpublished}` at its deadline; a
    confirmed load that names a module makes it monitor the lifeline,
    and the lifeline's end, with the reason `normal` and with `kill`,
    ends it with `{erx_code, down}`; a confirmed empty start load leaves
    it running when the lifeline ends. Seeded: the keep step removed,
    under which the unconfirmed batch runs on; the monitor taken after
    an empty start load, under which a domain with no overlay ends with
    `erx_code`; a link to the lifeline in place of the monitor, under
    which the lifeline's `normal` end leaves the code server running.
  * The lifeline on a host node: `erx_code`'s exit with the reason
    `normal`, with `shutdown` and with `kill` each ends the lifeline.
    Seeded: the lifeline without trapping exits, under which
    `erx_code`'s `normal` exit leaves it, and every domain running
    published code, alive.
  * A start load answered `{not_loaded, ...}`, one answered
    `hash_mismatch`, and one whose `ok` is never confirmed: each start
    fails, the code server ends its domain, with `{start_load, Result}`
    in the death record for a refusal, the log names the specification,
    the overlay's revision and the refusal, and the overlay stays
    published, so the next start sends it again until the restart
    intensity is spent. Then `load -d D -r` publishes the empty overlay
    and the next domain boots its release; a reset of a specification
    with a live domain stops that domain by its id. Seeded: the overlay
    dropped at a refusal, under which the next domain boots the release
    with the overlay gone; a reset without the stop, under which the
    live domain runs modules the empty overlay does not name.
  * `erx_code` killed in a host test with five stub domains: a
    supervised one whose code server holds every piece of its load and
    has not yet answered, a supervised one that runs a published overlay
    with no load in flight, a supervised one whose overlay is empty, one
    no specification restarts with a load in flight, and a supervised
    one whose code server holds its start load and has not yet answered.
    The first ends at its deadline once it loads its batch, the second
    at the lifeline's `'DOWN'`, the fifth at its code server's deadline
    with `{erx_code, unpublished}`, its `ok` to the old alias reaching no
    process, and the next domain of each boots its release from an empty
    start load of the restarted `erx_code`; the third and fourth run on;
    the facet answers `{error, failed}`; the restarted `erx_code` logs
    that every overlay was dropped and holds no alias, timer or monitor
    of its predecessor's loads. Seeded: the keep step removed, under
    which the first runs a batch no overlay names; the lifeline monitor
    removed, under which the second runs on its overlay's code after
    that overlay is gone; the code server's wait for the word of a start
    load without its deadline, under which the fifth ends only at its
    boot timeout.
  * A domain whose `max_frame`, `max_message_heap` or `funnel_depth` is
    below the code protocol's floor ends at its start with one log line
    naming the limit, its value and the floor; one at every floor takes
    a load of `code_modules_max` modules with 255-byte names. Seeded: the
    floor check removed, under which the domain below the floor boots
    and that load ends in `{error, timeout}`, its frame dropped by the
    funnel.
  * The inspector shows a specification's published revision with the
    reporter `service` and a domain's answer to its start load with the
    reporter `runtime`, and `load -v` prints both apart. Seeded: the
    answer marked `service`, which V2's reporter test catches.
  * A load sent twice leaves a process that runs the module's previous
    code running, and so does a repeat into a domain no specification
    restarts after the code service restarts.
    Seeded: the skip of a module already current removed, under which
    the second load purges and ends that process; the skip decided from
    the code service's history, under which the repeat after the restart
    purges.
  * A batch into another domain whose second module carries `-on_load`
    leaves none of the batch current. Seeded: a code server that loads
    module by module, under which the first module runs its new code.
  * The code protocol, exhaustively, in a host test
    ([The code server](#the-code-server)). `erx_code_target` and the code
    server's core run against a model connection that can deliver, delay
    or drop each message, and a model lifeline that ends when the
    modelled `erx_code` ends. The test tries every order of up to eight
    events drawn from: two facet loads into domain D1 of one supervised
    specification, a reset of it, D1's start, a repeat of D1's start,
    D2's start, D1's `'DOWN'`,
    `erx_code`'s deadline, the code server's deadline, the end of
    `erx_code`, and a code server that answers `ok`, answers an error,
    answers late, sends an out-of-order piece request, sends a message
    that names no alias, or is silent.
    After each step it checks these. At most one load is in flight for
    the target, and a load or reset that arrives while one is in flight
    is answered `busy`. Every request is answered exactly once. A load is
    sent only to the domain it was resolved to, and a facet's load only
    after that domain's start load was confirmed. A candidate is
    published, and its word sent, only on an `ok` that came in the
    envelope of the domain the load was sent to while that load was in
    flight. A failed start load leaves the published overlay as it was.
    A start load carries the overlay published when the start was taken.
    A modelled code server holds a loaded batch past its deadline only
    if it was confirmed, and holds a published module only while the
    modelled `erx_code` that published it lives, so a live domain's code
    is always its specification's published overlay or a batch still
    within its deadline. A reset stops exactly the domain it resolved, by
    its id. A closed domain, and any domain other than the target's
    current one, is sent no facet load, and a repeated start of the
    current domain changes nothing. Each piece is served at most once
    per load. Seeded: a domain left open after its start load failed,
    under which a facet's load is sent to D1 though it never took its
    overlay; an answer accepted from any envelope, under which D2's late
    `ok` publishes D1's candidate; the overlay dropped at a refused
    start load; a word of publication sent for a load that ended at its
    deadline, under which D1 keeps a batch its published overlay does
    not name; the model lifeline's monitor left out, under which D1
    keeps an overlay the restarted `erx_code` no longer holds; the piece
    cursor removed, under which a piece is served twice.
  * The verdicts and the pieces, in a host test of `erx_code`'s charge
    and `erx_code_target`: a load that is at once into a target with a
    load in flight, missing a blob and past the `overlay` limit is
    answered `busy`; once the target is free, `missing`; with the blob
    stored, `overlay_full`; within the limit but with a store too small
    for it, `no_memory`; nothing is sent for any of them. A candidate
    whose blobs the release holds, or a published overlay of the same
    principal already keeps, is charged nothing. A blob stored at
    65,537 bytes is served as a full piece and a one-byte piece; a
    request at its stored end, and one for a blob only the release
    holds, end the load as `invalid`. A start load ended by
    `domain_ended` writes no log record. Seeded: `missing` decided
    before `busy`, under which the busy target's load is answered
    `missing`; the charge counting the release's blobs, under which the
    release-held candidate is refused `no_memory`; pieces cut to the
    manifest's `Size`, under which the request past the stored end is
    served; a reset that publishes the empty overlay without a new
    revision, under which two different overlays carry one revision.
  * The code server against a stub `erx_code`, on a host node: it skips
    a module already current, reads a blob its release lists from the
    release, fetches the rest in manifest order one piece at a time,
    answers `{hash_mismatch, Name}` with nothing loaded for a blob one
    bit off and for a manifest `Size` one byte short of the blob, and
    abandons a load whose pieces stop coming at its deadline. A load
    that replaces `erx_code_agent` itself, then a second one that
    replaces it again, then a probe, all succeed with the same code
    server process running throughout. Seeded: the hash check removed,
    under which the bad blob loads; a frame of the code server's own
    code left below `gen_statem`'s loop, under which the second
    self-replacing load's purge ends the code server.
  * The domain pid keeps a code server report only from the domain's own
    incarnation. A report naming a pid of another creation is refused,
    and a supervised domain's boot ends at its boot timeout. Seeded: the
    ownership check removed, under which the foreign pid is kept and
    sent the start load.
  * A fuzz target, `tools/fuzz/erx_code_reply.rb`, for `erx_code_target`'s
    reader of a code server's messages, which are the system domain's
    untrusted input in this protocol. It runs arbitrary terms against
    arbitrary in-flight loads. It checks that the reader never raises,
    accepts a piece request only for the cursor's next piece within its
    blob's stored size, ties no message that names no alias to a load,
    and accepts an answer only when every name in it is from the manifest.
    Seeded: the name check removed, which the target finds as an
    accepted answer naming a module outside the load. The code server's
    reader of `erx_code`'s messages has no fuzz target: those messages
    come from the system domain, the trusted base whose fault resets
    the machine. The funnel has already validated the frame, and the
    code server only matches its shape.
  * `load` in a host test, with stub facets in its context: two files,
    and two modules on standard input as `-m a:N -m b`, each loading the
    bytes given; `-d 4` answered `scope`; input that ends early, input
    with bytes past the last module, and 16 MiB and one byte, each
    refused with nothing sent; no code facet answered `load: no code
    facet`. Seeded: a sized `-m` read to the end of the input, under
    which the second module is missing; the 16 MiB bound removed, under
    which the stub facet receives the oversized batch.
  * The host tool's transports in host tests: `--ssh` refuses
    `-oProxyCommand=x` as `DEST` and a module named `a;b`, and otherwise
    runs `load -d D -m a:N -m b:M` with the two modules' bytes on its
    standard input, recorded by a stand-in `ssh` on the test's `PATH`;
    `--tty` carries all 256 byte values both ways unchanged over a host
    pty pair; `ssh`'s standard error reaches the tool's output escaped.
    Seeded: the refusal of a leading `-` removed, under which the
    stand-in records an option; the word check removed, under which it
    records `a;b`; `stty`'s raw mode dropped, under which the pty's
    `ICRNL` and `ONLCR` change CR and LF; a print of `ssh`'s standard
    error that skips the printer, which the source check on the host
    tool's output calls catches.
  * `watch` against a stub transport that forgets every module, as a
    reboot does: the next change loads the unchanged module too. Seeded:
    a watch that sends only the changed module, under which the
    unchanged one is missing after the reset.
* **Start loads under QEMU.** A configured row of the domain suite's
  manifest whose `restarts` is above 0 boots to ready through its start
  load; the suite stops the domain through the domain service, and the
  row's next domain boots to ready through a second start load. Seeded
  by hand when the case lands, each failing it: the domain service's
  `started` left out, under which the row's boot ends at its boot
  timeout, which shows the code server waited; `erx_code`'s word of
  publication left out, under which the code server ends its domain
  with `{erx_code, unpublished}` 30 s after its start load. The suite's
  boot timeout is longer than `code_load_wait`, as the machine's
  default of 60 s is, so the second seed's end is the code server's and
  not the boot timeout's.
* **Loading, by every route, under QEMU.** A supervised test domain whose
  release carries a probe module that answers its version; each case
  loads a probe with a new answer and reads the answer through the
  domain; the first case also stops the domain through the `domain` facet
  and reads the answer again from its next domain (the overlay), since
  every route ends in the same load. The routes: the host link over
  QEMU's UNIX socket (`--socket`) and over `-serial pty` (`--tty`); SSH
  through the forwarded port with the development key (`--ssh`, and
  `ssh DEST load -d D -m probe < probe.beam` by hand); and `load` at the
  console, over a file `scp` copied to `/data`. Only the new blob gives
  the new answer, so a passing case shows its route carried the load.
  Seeded, each failing its case: one byte of the probe flipped after the
  tool hashed it, answered `hash_mismatch` with the old answer kept, on
  every route; for the first case, a code server that answers its start
  load `ok` without loading it ([The code server](#the-code-server)); for `load`, a
  probe file named after another module, which `code:prepare_loading/1`
  refuses with nothing loaded; for SSH, a session template without the
  code facet, answered `load: no code facet`. The case also checks the
  one log record of each load.
* **On the Raspberry Pi 4**, which is tested by hand, the board's manual
  checklist, on a card whose command line carries `erx.hostlink=1`,
  loads a changed driver module with `erx load --ssh` and with
  `erx load --tty` through UART3, and again with `scp` and `load`,
  restarts the driver with `reset` in `/dev`, and reboots to find the
  release's driver again.
* **The machine reset:** a system-domain fault injected under QEMU, after
  which the guest reboots into the committed slot, `[kernel, crash]`
  answers only the system shell, and the host tool reports its
  outstanding calls' outcome unknown and reconnects.
* **QEMU transcript tests** for the console prompt, `erx:i/1`,
  `erx:source/1` and a host-side `erx watch` load, under HVF.
* **`/proc`:** statuses, scopes with equal timing for out-of-scope and
  missing processes, snapshots, `.partial` and `.unknown` files, names
  the encoding makes plain, and the 256-snapshot bound (`emfile`). The
  decoder of `/proc` names has a fuzz target, checking that every name it
  accepts encodes back to itself and that no two names decode alike.
* **The code store:** a blob one bit off its hash is refused in every
  flavour of load, `erx watch` sends only missing blobs, and a principal
  that asks for another's blob is told it is missing, with storing a blob
  another principal holds taking as long as storing a new one.

## Performance

The host link runs over an emulated UART: under HVF each register access
traps to QEMU, so throughput is bounded by trap cost rather than baud
rate. An estimate of 1 to 10 us per byte gives 0.1 to 1 MB/s, so a 100 KiB
module uploads in 0.1 to 1 s and an inspection record of 2 KiB returns in
2 to 20 ms. These are estimates; `tools/erx bench hostlink` measures
throughput and round trip under HVF and TCG, and a virtio-console
transport replaces the UART behind the same framing if the measurement
misses the budgets in [Requirements](#requirements). On a board the host
link runs at its UART's rate: at 115,200 baud, with ten bits on the line
for each byte, 11,520 bytes a second, less COBS's byte in 254 and 32
bytes of header and CRC in each frame of up to 8,192, about 11,400
bytes a second. The hand-written `erx_*` modules of the native runtime
build, compiled with `debug_info`, are 451 files whose median is 9,340
bytes, about 0.8 s on the line; `erx_genet`, the Raspberry Pi 4's
Ethernet driver, is 19,228 bytes, about 1.7 s; the largest,
`erx_domain_srv`, is 86,828 bytes, about 7.6 s; and the generated
`erx_abi_layout` is 192,784 bytes, about 17 s. These are the sizes of
the files in `build/runtime/native/otp/lib/*/ebin` and the line's
arithmetic, not a measured load. The missing-blob exchange sends only the modules that
changed, so a driver's edit loads in a second or two. The SSH route
sends every module of a batch at the network's speed, so it is the
route to iterate on over a board's network, and the host link the route
that needs no network. The files stream
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
standard library for the host tool, which runs the host's own `ssh`
(OpenSSH) and `stty` as subprocesses for its SSH and tty transports.
QEMU's virtio-9p server, part of the
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

**Overlays shared by every principal.** One store and one set of
overlays would serve all principals. It loses: a deduplicating store
answers a second uploader faster and so tells one principal what
another loaded, and a blob kept once cannot be charged to two budgets.
Per-principal stores and overlays delete both problems.

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
decision is that output functions leave the data alone.

**A kernel record per process, for authoritative process facts.** The
inspector could then report a process's state and CPU time without asking
its domain. It would need a record outside the runtime for every spawn,
which the design avoids on purpose. Process facts are runtime-reported and
marked so; the facts that matter for trust (a domain's CPU time, memory,
threads, sub-spaces and doorbell traffic) come from the kernel and the
system domain's own records.

**`/proc` served by the system domain for each holder of an inspect
facet.** The system domain would run an `erx_procfs` per facet, and a
domain would mount it over the connection as it mounts `/data`. It loses
because records must cross the boundary anyway: `erx:i`, `top` and the
browser need each value's status, reporter and type, which `/proc` text
renders away, so the typed `inspect` interface exists in any case, and a
second server of the same tree would be a second crossing with a second
admission path to keep equal to the first. It would also put a 9P fid
state machine, text rendering and up to 16 MiB of snapshots per reader
in the trusted base, charged to the system domain, where in the reader's
runtime they are the reader's. The security does not move: the scope is
the facet's either way, and the root of a program's grant narrows at the
session's server, which the program cannot touch.

**One crossing as files only.** The typed facet would go, and the
browser and `erx:i` would read a term-encoded `record` file beside each
`status`. It loses a file kind added to the tree, and listings would cost a
walk, an open, a read and a clunk per process for `erx:ps()` and a
browser's listing, where a listing page is one round trip.

**A facet for each value someone needs.** The kernel log, say, would get
a `log` facet in front of a reader in the system domain. Each such facet
is a request shape, a validator and a grant rule of its own, decided
beside the inspector's scopes rather than by them, so a value could be
reached by two routes with two answers. A path of the schema reaches it
through the one gate.

**A query worker that asks every domain at once.** A listing across many
domains would wait out one deadline rather than one per stalled domain.
It loses because the worker would hold one answer per domain asked
before it could cut the page, so its heap, and the reservation each
holder makes in the system domain, would grow with the number of
domains; asking one at a time bounds both by one answer, and
`inspect_query_max` bounds the wait.

**SSH ending at `erx_hostlink`.** The SSH route would carry the host
link's frames to the system domain's host link endpoint. It loses twice:
the login would hold the host link's facets rather than its session's,
against S1 of [design-ssh.md](design-ssh.md#requirements), and the host
link has one session at a time, so a load over SSH would end the UART's
session and its console line. Ending in the login's session gives the
login exactly its session's authority.

**The host link protocol over SSH.** A session command would serve one
host link session on its standard input and output, so the host tool
would speak one protocol on every transport and keep the missing-blob
exchange over SSH. It loses: the command would carry the host link's
framing, credit, call window, session replacement and kept replies over
a byte stream SSH already delivers whole and in order; the host link's
session table owns and closes the facets it opens, where such a command
would borrow its session's and need rules of its own for them; and what
the exchange saves over sending the whole batch is bytes, which the
network makes cheap.

**A TCP transport to a UART bridge.** `--tcp 127.0.0.1:PORT` would reach
a bridge that serves the line over TCP. It loses: every process of every
user on the host can connect to the loopback, so the bridge would hand
the install facet to all of them, and the tool cannot tell a bridge that
listens on the loopback alone from one that listens on every interface.
A UNIX socket in a directory only its user can enter takes its access
control from the host's file permissions.

**One load at a time for the whole machine.** `erx_code` would serve one
request at a time for every domain. It loses: a domain that never
answers would hold up every load, recovery installs included, and the
pieces a code server asks for would wait behind the load that needs
them.

**A queue for each target.** `erx_code` would hold a load into a busy
target until the load in flight ended. It loses: a queued load holds its
manifest and blobs in the system domain for as long as the target takes
to drain, and a request the facet forwarded outlives the facet's
revocation, so ending sessions does not bound what such a queue holds.
No caller needs it: the host tool and `load` send one load at a time
and report `busy`, and a start load needs no priority, since a target
with a start load in flight refuses every other load until its domain
has reported ready.

**Dropping an overlay whose start load is refused.** The domain would
boot its release as built. It
loses: a refusal shows that this attempt failed, not that running the
release is safe; the overlay may hold an unrelated working fix, and the
release's code may meet data the overlay's code already changed. Keeping
the overlay and failing the start leaves that choice to the operator's
reset.

**A release hash with each start.** The domain service would carry the
hash of the release a domain boots in `started`, and `erx_code` would
drop an overlay loaded over another release by publishing the empty
overlay. It loses: nothing could make the hashes differ. A supervised
target's specification boots one release for as long as the overlay
lives (**Targets**, [The code server](#the-code-server)), so the check
would cost a hash in the domain record, a source for it in the domain
library and a log record, to catch a state that cannot occur. A design
that lets a specification's release change within a boot names the new
release a new specification, and so a new target with an empty overlay.

**A target per domain id.** `erx_code` would key every target by the id
of the domain a load or a start names. It loses: each restart of a
specification would start a new target with an empty overlay, so no
overlay would outlive a domain, which is what overlays are for.

**Stopping a supervised domain from `erx_code`.** `erx_code` would stop
a supervised domain by its id at a load's deadline, at `invalid` and
at a refused start load, and would link to its code server while a
load is in flight, so that its own end ended the domain. It loses: a
stop acts on a guess, since only the code server knows whether the
batch loaded, and so it costs a slow but healthy domain its state even
when nothing loaded; the link needs an explicit export with `link`
from every code server, fails silently with `noproc` when that export
is missing and with `normal` when `erx_code` ends that way, and covers
only a load in flight, never the overlays an `erx_code` restart
loses. The code server's keep step and the lifeline's monitor cover
all of these with one rule at the one party that knows.

**A start load for every domain.** Every domain's code server would wait
for a start load, with no modules when the domain has no overlay. It
loses: a domain no specification restarts can have no overlay, and
waiting would make its boot depend on `erx_code` for nothing.

**A mark of a published overlay in the domain service.** `erx_code`
would tell the domain service which specifications have an overlay, and
only their domains would wait, so a supervised specification without an
overlay would not wait either. It loses: the mark is a second copy of
`erx_code`'s fact, which `erx_code` would have to set before it
publishes, clear after a reset and clear for every specification when
it restarts, in that order, or a domain would boot without its
overlay. The start load asks the one copy when the domain starts.

**Refusing a target after its deadline.** A target whose load missed the
deadline would refuse loads until its domain ended. It loses: it adds a
state and a refusal, where the code server's keep step already
resolves every load that ended unpublished within its own 30 s.

**Keeping only published code in every domain.** The code server of a
domain no specification restarts would also end its domain when a
batch it loaded was not published. It loses: such a domain has no
overlay its code could fall out of step with, so the end would only
end it for good, with whatever state it held.

**Keeping overlays on the data partition.** Each principal's overlays
and hot store would be written to its directory, so a load would
outlive a reboot. It loses for now: publication would wait on a file
server that never times out, so it needs a worker, a deadline of its
own and a rule that an abandoned write cannot land after a newer one;
what it writes must be read back through a bounded, fuzzed decoder;
and a file-system domain that a crafted partition compromises could
run code in every supervised domain whose overlay it serves. Its
consumer, live loading on a development machine, is served without
it: `erx watch` loads its whole set again at its next change, and a
change that must last ships in a release. Whether to add it is an
open decision (Risks and open questions).

**Overlays kept across an `erx_code` restart.** Each principal's
overlays would live in a memory object the domain service holds, with
the store, and a restarted `erx_code` would read them back, so its
restart would end no domain. It loses: the memory object needs a
layout, a commit that a crash in the middle of a write cannot tear,
and a reader, for the one event of a fault in a trusted service,
where the lifeline's monitor restarts the affected domains on their
releases at the cost of a reload.

**Partial batches in other domains.** A code server would load a batch
module by module and keep what loaded when one module failed. It loses:
an ordinary refusal would leave code that is neither the old batch nor
the new, beside an overlay that names the old; atomic loading costs only
modules with `-on_load`, which are NIFs' modules and change with their
image anyway.

**A watch that keeps its connection.** It would load only what changed
and load everything again on a new connection. It loses: it holds the
host link's one session between changes and must notice a dead
connection, where loading the watch's whole set at each change needs
neither, since the runtime skips what is current.

**The code server in init's ready report.** The code server would be
named in `{erx_ready, ...}` beside the inspection agent, with no report
of its own. It loses: the ready report comes after every application
has started, and a supervised specification's overlay must be in place
before they start, so its domains would need a second way to fetch the
overlay at boot. A report of its own, sent from `kernel`, lets the start
load be an ordinary load, and costs a domain without an overlay one
message and no wait.

**Pieces pushed by `erx_code`.** `erx_code` would send a load's blobs
straight after the manifest. It loses: it would send blobs the domain
already has current or holds in its release, and it would have to pace
its sends against the domain's lane. When the code server asks, it
fetches only what it lacks, and at most one piece is ever queued for it.

**A code facet per domain.** The host link's root would open one facet
for each domain id. It loses: a session cannot hold a facet of a domain
started after it, and every such facet would carry the same rule of who
may have it; one facet whose scope is resolved at each load, as an
inspect facet's is, reaches every domain the principal starts later.

**`kldload` for the shell's command.** It would greet a FreeBSD user
with a familiar name, and promise what the command is not: `kldload(8)`
links a module into the kernel, and `load` hands a runtime's code
service bytes to load in one domain.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| The emulated UART is too slow for comfortable uploads | medium | slow `erx watch` | `tools/erx bench hostlink`; virtio-console behind the same framing |
| A board's host link at 115,200 baud is slow for large loads | high | about 0.8 s for a median module, 1.7 s for `erx_genet` and 17 s for the largest generated one ([Performance](#performance)) | the missing-blob exchange sends only changed modules; the SSH route loads at the network's speed |
| A domain legitimately busy for 30 s meets a load's deadline | low | the load answers `{error, timeout}` with nothing published; a supervised domain whose code server loads the batch just as the deadline passes ends, loses its running state and restarts from its published overlay, an accepted trade-off | the deadline is `code_load_wait`, one constant of `abi/services/code.txt`; a load is a fetch over the domain's lane and an atomic load that runs none of its modules' code, which takes far less; the time of a 16 MiB batch on the Raspberry Pi 4 and under TCG is on the [performance watch list](todo-performance.md#erts-and-the-runtime) |
| A loaded driver ends its domain at every start, from its published overlay | medium | the domain restarts as its specification says, without serving | `load -d DOMAIN -r` at the console or over the host link, or a reboot, which drops a driver domain's overlay; either returns the domain to its release; a driver that ends only its own process is reloaded while its domain runs |
| `erx_code` fails | low | every supervised domain that runs a published module restarts on its release, and every overlay is lost | `erx_code` is a trusted service with a pure core tested exhaustively; the restart is logged; `erx watch` loads its set again at its next change |
| `prim_tty`'s ssh mode misses a feature the shell uses | low | a rendering gap | the console tests cover every request type; erXos owns `prim_tty` and can extend it |
| A domain answers inspections slowly | medium | sluggish `erx:i/1` | deadlines and `timeout` statuses; kernel and service attributes need no answer |
| Records are larger than `inspect_reply_max` allows a listing page of 1,000 | medium | `erx:ps()` and listings at scope `all` page early and show `partial` | the cut is by bytes, so a page is never lost, only shorter; the record sizes are on the performance watch list |
| The provisional answer bound and floors are wrong for real records | medium | answers cut early, or a reservation per holder larger than needed | the bounds are interface constants, set from the measurement of encoded and decoded sizes and of the workers' peak ([The inspect service](#the-inspect-service)); the measurement is on the performance watch list |
| Frame traces of a user domain are only as true as that domain's funnel says | low | a compromised domain hides or invents frames in its own trace | the trace is marked `runtime`; the other end of every conversation is traced too, and the system domain's end is trusted; doorbell counts come from the kernel |
| The code store's history keeps blobs alive that no domain needs | medium | memory growth | at most 16 hashes per module per specification, charged to the principal; blobs that no history, overlay or release of the principal names are freed |
| Escaping default-ignorable characters breaks legitimate text | low | a sequence shows as tokens, such as a subdivision flag built from tag characters | the four exceptions cover joiners and presentation selectors; each case is decided with a test |

Whether release builds offer a host link at all
belongs to the release process ([plan.md](plan.md#beyond-the-plan)); the
mechanism is the same in every build, and a release build's session holds
only the facets its system configuration lists, by default none.

Open decisions:

* **A supervised specification without an overlay still waits on
  `erx_code`.** Only a domain of a supervised specification waits for a
  start load, so a domain no specification restarts never depends on
  `erx_code` at boot. A supervised specification's domain waits even
  when its overlay is empty, as every overlay is after a boot, and gets
  a start load with no modules, because whether a specification has an
  overlay is `erx_code`'s fact, and asking at the start reads the one
  copy. The cost is that a supervised domain whose start load does not
  come, because `erx_code` is down or restarting, fails its start at its
  boot timeout; repeated, that spends its restart intensity and leaves
  it down, and for a domain the manifest marks `required` ends the
  machine. Sparing those domains needs the mark in the domain service
  that Alternatives considered rejects, with its ordering obligations.
  Recommendation: keep the wait for supervised specifications;
  `erx_code` starts before the domain service, so only a restart of it
  during a boot costs a boot.
* **What an `erx_code` restart does to overlays.** Every overlay is
  lost, and every supervised domain that runs a published module ends
  through its lifeline monitor and restarts on its release
  ([When `erx_code` ends](#the-code-server)), so no domain runs code
  its specification's overlay does not name. The cost is the running
  state of those domains and the developer's reload. Keeping overlays
  across the restart needs the memory object that Alternatives
  considered describes. Recommendation: accept the restart, as the
  trusted base's other services are restarted rather than repaired;
  the deferred case is in
  [todo-domains.md](todo-domains.md#planned-features).
* **A created specification's target.** A created domain whose request
  names `restart => permanent | transient` is supervised, and its
  overlay must outlive each of its domains, while a domain's record ends
  with the domain ([Targets](#the-code-server)). Naming its target needs
  a record of the specification, one the domain service keeps while it
  restarts the specification, which carries the name, such as the id of
  the specification's first domain, into every domain of it. It also
  needs a bound on the targets `erx_code` keeps, since every new
  specification is a new name even under a reused domain name, and an
  empty overlay costs no blob quota: the domain service's word to
  `erx_code` when it gives a specification up, stopped for good or left
  down past its restart intensity, so `erx_code` drops its target, and
  the names quota then bounds the specifications alive at once.
  Recommendation: decide it with the design of a created domain's
  restart, which needs the same record for its own restart intensity,
  and set the `supervised` flag only for configured rows until that
  design names the target: a created domain's code server then starts
  its domain at once on its release, with no overlay, which fails safe.
* **Overlays across reboots.** Decided: overlays live in memory only, so a
  reboot returns every domain to its release, and M10 does not keep them on
  the data partition. Persisting them costs what Alternatives considered lists
  under "Keeping overlays on the data partition", and requirement 4 asks only
  that a load survive its domain's restarts. If a consumer appears, add a
  snapshot that `erx_code` writes after publishing and reads only when it
  starts, which never decides a load
  ([todo-domains.md](todo-domains.md#planned-features)).

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
