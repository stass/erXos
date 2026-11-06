# The command shell

Each session can run a **command shell** beside its Erlang shell: erXos's
own, written in Erlang, speaking the language of rc, Plan 9's shell, by
the user's decision. Builtins, Erlang commands and programs share one
command namespace; pipes between Erlang commands carry records whose
values keep their statuses, and pipes that meet programs carry bytes; and
jobs of Erlang processes and programs stop, continue and end together.
The same interpreter runs as a program, `rc`, for programs' `system` and
`popen`. The key idea is that the shell adds no authority and no new
mechanism: authority is the capabilities a command is handed, grants and
facets and the right to start commands, never the kind of command; the
shell runs in the session's domain with the session's capabilities,
starts programs through the spawn path of
[design-programs.md](design-programs.md), and stops them by pausing their
spaces. The architecture is in [design.md](design.md); the live machine
around the shell, its console, inspector and `/proc`, in
[design-live.md](design-live.md); namespaces in
[design-files.md](design-files.md).

Decisions every reader of this document needs:

* **rc's language, written in Erlang.** One quoting rule, list variables
  and no rescanning, with emacs-style editing and job control added; a
  shell compatible with tcsh is a possible addition in the roadmap.
* **One command namespace.** A name is a function or builtin, an Erlang
  command, or a program command, in that order; programs see the Erlang
  and program commands that `/bin` lists, never a builtin or a function.
* **Records between Erlang stages.** A record maps fields to values that
  keep their statuses, so no stage turns `unknown` into a number.
* **Capabilities, not command kinds.** A command acts only through the
  capabilities it was handed: the session's by default, fewer under
  `within`, and a program's own when a program starts it. A command with
  fewer than the session's runs in a domain of its own, so its
  confinement rests on the kernel (SH1).
* **Job control by pauses.** Stopping a job pauses its programs, a hold
  the kernel keeps on each program's space, and suspends its Erlang
  processes; the terminal relay never waits on a program.

## Context

The vision puts the interactive environment first, and UNIX users bring
UNIX habits: `ls | grep`, `ps`, job control. The command shell meets them
without making POSIX the base: its language is rc's, whose single quoting
rule and list values remove the Bourne shell's commonest traps; its
commands are Erlang modules that pass records; and the UNIX commands it
runs are toybox's applets, each a program in a sub-space of the session
and a port of its runtime
([design-programs.md](design-programs.md#a-program-is-a-port)). It sits
in each session's domain, beside the Erlang shell in the same `Ctrl-G`
menu, and uses the session's tty
([design-live.md](design-live.md#the-tty)), the inspector's records
([design-live.md](design-live.md#inspection-records)), the session's
namespace ([design-files.md](design-files.md)) and the spawn path
([design-programs.md](design-programs.md)).

## Requirements

* **S-R1.** A command shell per session with rc's language, line editing
  and job control, builtins, Erlang commands and programs in one command
  namespace, and structured pipes; the same language as a program, `rc`,
  for programs' `system` and `popen`.
* **S-R2.** A line, a stage or a command can fail, overflow or crash
  without ending the session.
* **S-R3.** The shell's behaviour agrees with Plan 9's rc wherever it
  claims rc's language, each difference documented with a test.

Non-functional: parsing adds microseconds to a line, a record between
Erlang stages costs one message, and a program's start dominates any line
that runs one ([Performance](#performance)).

Non-goals: a POSIX shell, vi-style editing, and running third-party `sh`
scripts ([Alternatives considered](#alternatives-considered)).

## Overview

A line is tokenized and parsed into a syntax tree, bounded at 64 KiB and a
nesting depth of 256, and evaluated: each stage of a pipeline, each
command substitution and each background block is an Erlang process with
a copy of the shell's variables. A stage that names an Erlang command
calls it in that process; a stage that names a program has the command
server start it ([design-programs.md](design-programs.md#starting-a-program)).
Stages that are both Erlang pass records; a stage that meets a program or
a file meets bytes, and the shell renders records into lines or reads
lines into records at that edge. The terminal relay serves the foreground
job's terminal, and job control acts on the job's programs and Erlang
processes.

```text
  session domain                                      programs: sub-spaces
 +--------------------------------------------------+  +--------------+
 | console line  <-> terminal relay <-> /dev/tty    |  |              |
 |                       opens of the foreground job|  |              |
 | shell: parse -> evaluate -> stages               |  |              |
 |   Erlang stage --records--> Erlang stage --bytes-+--+-> program    |
 |                                          (pipe)  |  |  (a port,    |
 | command server (pid 1): process ids, jobs and    |  |   channel to |
 | handlers; the port driver                        |  |   handler)   |
 +--------------------------------------------------+  +--------------+
```

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **SH1.** A command acts only through the capabilities it was handed, and one handed fewer than the session's runs in a domain of its own | an Erlang command receives its grants and facets in its context and reaches services only through them; the shell's own lines run in the session's domain with the session's capabilities, since that is what the user typed them with; a command that `within` narrows, and every Erlang command a program starts, runs in a command domain built from exactly the capabilities its starter named, which its starter held, and named from its principal's pool of reusable names ([design-system.md](design-system.md#identifiers)), each facet among them made by the system domain for that domain alone and with no wider scope, and a program runs in a sub-space whose handler acts only on the program's own table ([design-programs.md](design-programs.md#what-a-program-can-start), [design-programs.md](design-programs.md#facets)); a handler never runs a builtin or a function for a program | a command that reaches a service by a registered name of the system domain; a narrowed or program-started command run in the session's domain; a domain given a capability its starter did not hold | a test that every command run in a session without an inspect facet gets `no_facet`; a test that a command domain's capabilities are exactly the grants and facets named before its startup message; `xargs ps` from a program with and without the `inspect` right, and a command domain that asks for the session's own facet instead of its own, which is refused; a narrowed program that asks its handler for every name of the command namespace in turn starts only what `/bin` lists and reaches nothing outside its grants |
| **SH2.** A failing line, stage or command never ends the session | each stage, substitution and background block is an Erlang process of its own with `max_heap_size` set, counting the binaries it references; every input that reaches a stage is bounded in bytes, a line at 64 KiB, a record at 64 KiB and a pipe's records in flight at 256 and 1 MiB, so no input makes a stage grow without bound; every evaluator's Erlang stages are admitted whole within the session's stage allowance, an eighth of its budget, within the half the session keeps for its own services and from which no program's budget is carved ([design-system.md](design-system.md#resource-policy)), and only a foreground line waits for it, so stages together stay within memory the session keeps for them and no evaluator waits for an allowance its own parent holds; the parser refuses a line over its bounds before anything runs; a program is a sub-space with a budget of its own, carved from the other half, so what it spends never counts against a stage | a stage evaluated in the shell's own process; an unbounded parse; an input path without a byte bound; stages admitted beyond the allowance; a nested evaluator that waits for the allowance; a program's budget carved from the services' half | the overflow, deep-nesting and runaway-recursion tests; a native program that writes a 1 GiB line without a newline into an Erlang stage, which fails that stage alone; a record over 64 KiB, which fails its stage; as many stages as the allowance admits, each near its limit, and one more pipeline, which waits; a substitution inside a fully admitted pipeline, and a background job beyond the allowance, each of which fails with `too many stages` at once; a loop of programs that spends the programs' half, during which the shell still parses, prompts and runs builtins; the parser's fuzz target |
| **SH3.** No stage turns a status into a value | a record's values are `attr()` values with their statuses; `where` and `sort` treat a comparison with a value that is not `ok` as undecided; `erx_render` prints every status as such | a stage that unwraps a value without its status | the record tests over `unknown` and `timeout` values ([design-live.md](design-live.md#invariants) V2) |

## Data model

The shell's state is a few Erlang terms in the session's domain:

```erlang
-type command() :: {function, binary()}       % defined with fn
                 | {builtin, atom()}          % rc's and erXos's builtins
                 | {erlang, erx_cmd:entry()}  % metadata and a version-bound local fun
                 | {program, binary()}.       % a program command, in /bin
-type job() :: #{id := pos_integer(),         % %N
                 stages := [pid()],           % the job's Erlang processes
                 programs := [2..16#7fffffff],% process ids, at each spawn
                 group_leader := pid(),       % inherited by its Erlang processes
                 state := foreground | background | paused}.
-type record() :: #{atom() => erx_schema:attr()}.   % fields its command declares
```

The command namespace is a map from name to `command()`, built when the
session starts from the generated command catalogs of its releases and
the image's program list. A release's catalog derives from command module
metadata and the native program list, without executing command bodies.
It supplies lookup entries, help, required facets and declared record
fields, retaining the precedence and unresolved-conflict rules below.
A session sees only commands of releases it holds. Live-loaded command
metadata passes the same checks before publication
([design-generation.md](design-generation.md#configuration-and-command-catalogs)).
The command server keeps the jobs and the session's process table
([design-programs.md](design-programs.md#the-parties)). A record's
fields are atoms its command declares; its values are the inspector's
`attr()` values, each with a status and a reporter
([design-live.md](design-live.md#inspection-records)).

## Algorithms and behavior

### The language

The shell speaks rc's language as Tom Duff's paper defines it, with
what a terminal needs added:

* **Language.** One quoting rule, `'...'` with `''` for a quote inside;
  variables whose values are lists, set with `x=(a b c)` and read with
  `$x`, `$#x`, `$x(2)` and `$"x`; values never scanned again for splitting
  or globbing; concatenation with `^`, and the free carets rc inserts;
  command substitution with `` `{cmd} ``, split on `$ifs`; `if(...)` and
  `if not`, `for(x in ...)` and `for(x)`, `while(...)`, `switch(...)` with
  `case`, `~` for matching, `!` for negation, `&&` and `||`; functions
  with `fn`; here documents with `<<`; redirection by descriptor number
  (`>`, `>>`, `<`, `>[2]file`, `>[2=1]`) and pipes of any descriptor
  (`|`, `|[2]`); `&` for a background job; globbing over the session's
  namespace; `$status`, `$*`, `$home`, `$prompt`, and `$pid` and `$apid`,
  the process ids of the shell, which is the command server's 1, and of
  the last program of its last background job, empty when that job
  started none ([design-programs.md](design-programs.md)).
* **Status is a string**, as in rc: empty for success. A program's status
  follows the exit status table of
  [design-programs.md](design-programs.md#a-programs-end): its exit status
  `n` gives `n`, 0 the empty string, and an end by a signal the signal's
  name, such as `sigint`. An Erlang command's error gives its reason as
  text, printed with `~0tp` and cut at 256 bytes, such as `enoent`; an
  Erlang stage whose consumer ended gives `sigpipe`, as a program would. A
  pipeline's `$status` is its stages' statuses joined with `|`, as rc
  joins them, and counts as success, as rc's does, when every one of them
  is empty.
* **Interaction**, which rc leaves to its terminal and erXos adds:
  emacs-style line editing and history from OTP's `edlin`, basic
  completion of command names and paths through `edlin`'s expansion hook,
  and job control ([Job control](#job-control)). vi-style editing is not
  provided.
* **One evaluator per stage.** A pipeline's stage, a command substitution
  and a `{...}` block run in the background are each an Erlang process
  that starts with a copy of the shell's variables and functions, so no
  `fork` is needed and a stage cannot change its parent's variables, as in
  rc. Every evaluator, stage and Erlang command runs with `max_heap_size`
  set, with `include_shared_binaries`, so the binaries it references
  count, ending the process beyond it; the default is 4 MiB, so the stage
  allowance, an eighth of the session's budget and 32 MiB at the default
  budget of 256 MiB
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas)),
  admits eight stages at once, which a pipeline of `ps`, `where`, `sort`
  and `count` with a substitution leaves room in. So a runaway recursion
  ends its own stage, never the session. The limit acts at garbage
  collection, so what a stage takes in is bounded too
  ([Pipelines](#pipelines)).
* **What rc does that erXos cannot.** `exec` and `rfork` fail with a
  diagnostic, since the shell has no image to replace and no process to
  fork; `fn sigint` and `fn sighup` run when the shell itself is
  interrupted or its terminal goes away, as in rc; a list variable reaches
  a program's environment with its elements joined by U+0001, as
  plan9port's rc exports lists, and programs get `PATH=/bin`.
* **An escape to Erlang.** The builtin `erl EXPR` evaluates an Erlang
  expression in the session's evaluator and prints its value; the Erlang
  shell itself is one `Ctrl-G` away.
* **Authority.** The shell runs inside the session's domain with that
  domain's authority and facets, and nothing more; neither the shell nor
  any command has authority of its own (SH1). `bind`, `mount` and
  `unmount` change the session domain's namespace, which every shell and
  command of the session shares.

Its interpreter is ordinary Erlang, an estimated 2,000 to 3,000 lines for
the language and as much again for the interactive layer: a tokenizer and a
parser that build a syntax tree for each line or script, bounded at 64 KiB
of source and a nesting depth of 256, and an evaluator over the tree. Plan
9's rc is its oracle ([Verification and
testing](#verification-and-testing)). One cost is deliberate: one-liners
written for a POSIX shell (`2>&1`, `$(...)`, `for ... do`, `export`) do not
paste into it, nor into a program's `system`, which runs `rc` ([rc as a
program](#rc-as-a-program)), and scripts that need more than its language
are better written in Erlang, as escripts. A POSIX shell for third-party
scripts is not the command shell's: toybox's own shell, which needs
`fork`, runs as a program in the personality's second tier
([design-programs.md](design-programs.md#toybox)).

The tokenizer and the parser, `erx_shell_lex` and `erx_shell_parse` in the
`erx_shell` application, are pure functions from a source to a syntax tree
or a diagnostic, and their types are the tree the evaluator walks. They
follow plan9port rc's grammar in what binds to what. A diagnostic names a
line and a column, counted in bytes from 1, and says what is wrong in fixed
words without quoting the source. A source that ends where more input could
complete it gives `incomplete` rather than `syntax`: an open quote, brace or
`if(...)` condition, a here document with no terminator, a line continued
at its end, or an `&&`, `|` or `if(...)` with nothing after it. The
tokenizer reads a source as if it ended with a newline, so only constructs
that may span lines can reach its end. The interactive layer then
reads another line, and a script that ends that way fails as one that does
not parse. The depth bound counts levels: `{...}`, `if`, `if not`, `for`,
`while`, `switch`, `fn`, `!`, `@`, a redirection or an assignment written
before a command, `(...)`, `$`, `$#`, `$"`, `` `{...} ``, `<{...}` and
`>{...}` each
hold what is inside them one level deeper. Sequences, `&&` and `||` chains,
pipelines, `^` joins and a simple command's words are flat lists, so a long
pipeline is not deep. No tree is deeper than its levels allow, so neither
the parser nor anything that walks a tree recurses further.

### Commands

A command name resolves in one **command namespace**, the same for the
shell and for `erx:` functions that run commands:

1. a function the session defined with `fn`, or a builtin of the shell
   (rc's `.`, `builtin`, `cd`, `eval`, `exit`, `flag`, `shift`, `wait`
   and `whatis`, and erXos's `erl`, `within`, `jobs`, `fg`, `bg` and
   `kill`, which signals a job, as in `kill %2`, or a process id of the
   session);
2. an **Erlang command**, a module of the session's releases that
   implements the `erx_cmd` behaviour and declares its name
   (`-erx_command(ps)`), such as `ps`, `i`, `domains`, `source`, `trace`,
   `attach`, `bind`, `mount`, `unmount`, `where`, `select`, `sort` and
   `count`;
3. a **program command**: one of toybox's applets or another program of
   the boot image, each of which the session's export also lists in
   `/bin` ([design-programs.md](design-programs.md#what-a-program-can-start)).

A name that contains `/` is a path, not a name, and is not looked up:
the shell resolves it through the session's namespace and starts the
file it names as a program, through an `rx` grant, as `posix_spawn`
does; a path that names nothing gives the status `not found`, and a file
that no `rx` grant reaches gives `permission denied`. No `#!` line is
interpreted: an rc script runs as `rc file` or `. file`.

The table is built when the session starts from its releases' catalogs.
A name has one meaning: an Erlang command
shadows a program of the same name, and the build leaves out any toybox
applet whose name an Erlang command of the system release declares, so
toybox's `ps` and `kill`, which read Linux's `/proc`, are never built; two
of a session's releases that declare one Erlang command conflict, and the
session's table leaves the name unresolved, with `whatis` naming both. A
name that resolves to nothing fails with the status `not found`. A program
resolves names through its `/bin`, which lists the program commands and
the Erlang commands of the command shell's release, never a builtin or a
function, since those act on the shell itself. An Erlang command a program
starts runs in the program's command domain with exactly the program's
capabilities: the grants of its namespace, and for each of its rights
beyond files a facet the system domain makes for the command domain, with
no wider scope ([design-programs.md](design-programs.md#facets)), so
`xargs ps` lists processes when the program holds the `inspect` right and
fails with `no_facet` when it does not. In the session, `kill` is the
builtin, which knows the session's jobs, as in `kill %2`; a program's
`kill` is the Erlang command of that name, which runs in the program's
command domain and signals process ids through the program's handler,
which allows what the program's `signal` right reaches and its own
children ([design-programs.md](design-programs.md#the-program-protocol)).

An Erlang command receives its arguments as binaries, its environment and
working directory, its three standard streams, each the terminal, a
file, a pipe end or a neighbouring Erlang stage, and its capabilities: the
grants of its namespace and its facets. It returns `ok`, a usage error or
another error; a crash is an error whose reason goes to standard error. A
command declares the facets it uses (`-erx_needs([inspect])`), so one run
without them fails with `no_facet` before it starts, and its help says
what it needs.

An Erlang command run in the session's own domain is still Erlang code in
that domain: the context is the interface through which it acts, not a
boundary, and a command that ignored its context could reach whatever the
session's domain holds. That is why the session's domain runs only
commands with the session's whole authority, which the user typed them
with, and every command with less runs in a domain of its own, where the
kernel and that domain's own runtime enforce what it holds
([design-domains.md](design-domains.md#authority)).

### Pipelines

Between two Erlang commands, both processes of the session's domain, a
stage passes the next its records as messages, at most 256 in flight, so
`ps | where 'memory > 10000000' | sort -k reductions` filters and sorts
records rather than text. A record is a map from field names, atoms its
command declares in order, to `attr()` values, each with its status and
reporter as in [Inspection records](design-live.md#inspection-records), so
a value the inspector could not get stays `unknown` through every stage.
One renderer, `erx_render`, which `/proc` shares, prints an `ok` value
bare and every other value as its status, `[unknown]`, `[partial]`,
`[unsupported]`, `[timeout 500]` or `[error]`. `where` keeps a record when
its predicate is true; a comparison with a value that is not `ok` is
neither true nor false, so `where` drops such a record and `where -u`
lists those it could not decide, and `sort` places them last: no stage
turns a status into a value.

**Bounds.** A record is at most 64 KiB, as `erlang:external_size/1`
measures it, and a stage that would send a larger one fails with
`record too large`; a stage holds at most 256 records and 1 MiB of them in
flight to the next; and a line of bytes arriving at an Erlang command is
at most 64 KiB, beyond which its stage fails with `line too long` rather
than gather it. So input of any size, from any producer, ends at most the
stage it reaches.

**Admission.** The shell admits each evaluator's Erlang stages whole, each
at its `max_heap_size`, against the session's **stage allowance**, an
eighth of the session's budget, within the half of it the session keeps
for its own services, the shell, the terminal relay, the handlers and the
pipe server, and from which no program's budget is carved: the other
half is the session's pool for programs, a budget of its own, from which
every program's budget is carved and on which every program draws
([design-system.md](design-system.md#resource-policy)). A foreground line
that does not fit waits for running stages to end, and one that could
never fit fails with `too many stages`. Every other evaluator, a
background job, a command substitution and a pipeline inside a stage, is
admitted at once or fails with `too many stages`: a substitution that
waited could wait for the allowance its own pipeline holds, and background
jobs that waited would queue without bound. So the stages together stay
within the memory the session keeps for them, and no line waits on its own
admission.

`where`'s predicate has its own small grammar, bounded at 4 KiB and a
nesting depth of 64, with a fuzz target, and no evaluation of Erlang:

```text
pred   := term { "or" term }
term   := factor { "and" factor }
factor := "not" factor | "(" pred ")" | FIELD op value
op     := "=" | "!=" | "<" | "<=" | ">" | ">=" | "~"
value  := INTEGER | 'QUOTED STRING' | WORD
```

A predicate is true, false or **undecided**, by Kleene's three-valued
logic: `not` exchanges true and false and keeps undecided; `and` is false
when either side is false, true when both are true, and undecided
otherwise; `or` is true when either side is true, false when both are
false, and undecided otherwise. A comparison of a field the record lacks,
or whose value is not `ok`, is undecided. Two integers compare as numbers;
any other pair compares as text, the field's value as `erx_render` prints
it against the literal's text, byte by byte, so for a field `n` holding
10, `n < 9` is false and `n < '9'` is true. `~` matches the field's text
against a glob, as rc's `~` does, with an iterative matcher that keeps one
point to backtrack to, so a match takes at most the text's length times
the pattern's length in steps; one that would take more than 2^24 steps is
undecided. So every predicate is decided, or reported undecided, in
bounded time.

Wherever a program takes part, the stages are joined by pipes
([design-pipes.md](design-pipes.md)), which carry bytes; the session's
pipe server makes each end for the stage that uses it, so every end has
one holder and the session knows them all
([design-pipes.md](design-pipes.md#making-a-pipe)). Text appears only
where a stage meets something that reads bytes:

* at the terminal, records render as aligned columns under a header line,
  whose values `erx_render` writes with the line escape;
* toward a native program or a file, each record renders as one line of
  its fields in declared order, separated by tabs, each value printed by
  `erx_render` with its tabs, newlines and backslashes written as `\t`,
  `\n` and `\\`, with no header and no other change, so `awk`, `cut` and
  `wc -l` see one record per line and exactly the data;
* bytes arriving at an Erlang command from a native program or a file
  become one record per line with one field, `line`, so
  `where 'line ~ *error*'` filters lines.

### Starting programs

The session's command server starts each program of a line
([design-programs.md](design-programs.md)). The shell derives each
program's grants from the session's namespace, unless the line narrows it:
`within /data/logs -- grep -r error /data/logs` starts `grep` with one
grant, rooted at `/data/logs` and read-only, and no `/bin`, so `grep`
reaches nothing else and can start nothing
([design-files.md](design-files.md#narrowing-for-a-program)); its
namespace has no `/`, so the paths above its grant read as an empty root
that lists only the names leading to the grant, and every other path fails
with `ENOENT` ([design-files.md](design-files.md#resolving-a-path));
naming `/bin` among `within`'s paths keeps the program commands, and `-f`
names a right the session holds, as in `within -f inspect -- ps` or
`within -f signal /bin /tmp -- xargs kill`, where `xargs` needs `/bin` to
start `kill`. What `-f` hands over depends on what runs: a program's
record holds the right, which its handler checks, and the command domain
in which the program runs `ps` or `kill` receives a facet the system
domain makes for that domain, since a facet acts for its grantee alone
([design-programs.md](design-programs.md#facets)). `within` before an
Erlang command runs it in a command domain of its own with only the named
grants and facets, which the inspector shows as a domain of the session.
A program's standard streams are pipes to other stages; for a
redirection, files the shell opened and passes, sharing their offsets; or
opens on the session's `/dev/tty`, which the terminal relay serves, so a
program's output and error streams reach the terminal in the order it
wrote them and no program can use up another's pipe ends
([design-programs.md](design-programs.md#the-terminal)).

### rc as a program

`rc` is also a program command, in `/bin` with toybox's applets, so a
program can run a script: `system` and `popen` run `rc -c` with their
command, by the user's decision
([design-programs.md](design-programs.md#the-posix-lite-personality)), and
`rc script` runs a file. From the session's shell, `rc file` and `. file`
run the script in an evaluator of the session's, with the session's
authority; for a program, `rc` runs in the program's command domain,
built from what the program handed it, whose image is the command image,
the runtime image running this shell's release in program mode
([design-programs.md](design-programs.md#what-a-program-can-start)):

* **The same language.** The interpreter is the session shell's, with its
  bounds and its parser's fuzz target, without the interactive layer.
* **A program's authority.** Its command namespace holds rc's own builtins
  (`.`, `builtin`, `cd`, `eval`, `exit`, `flag`, `shift`, `wait` and
  `whatis`), erXos's `within`, the Erlang commands of its release, which
  run in the same command domain with the capabilities `rc` holds, and the
  program commands of its `/bin`; it has no `erl` and no job control, and
  its `kill` signals what its `signal` right reaches and its own children,
  through the program protocol. Globbing, redirections and `cd` go through
  its own namespace, and its standard streams are its descriptors 0, 1
  and 2, never a terminal of its own.
* **Its status.** It ends with a status derived from `$status` after its
  last command, by a pure function over the status's components, the parts
  between its `|`s: when every component is empty, as for a successful
  command or pipeline, it is exit 0; otherwise the last non-empty
  component decides, a decimal number from 0 to 255 being that exit
  status, a signal's name ending it as if by that signal, and anything
  else, an error's text among them, exit 1. A script it cannot parse
  writes the parser's diagnostic to its standard error and exits 1.

A command for `system` is rc, not sh. The common translations:

| sh | rc |
| --- | --- |
| `cmd 2>&1`, `cmd 2>/dev/null` | `cmd >[2=1]`, `cmd >[2]/dev/null` |
| `$(cmd)`, `` `cmd` `` | `` `{cmd} `` |
| `"a $x b"` | `'a '$x' b'`: `"` does not quote in rc |
| `export X=1` | `X=1`: rc exports every variable |
| `$?`, `$#`, `$@`, `$!` | `$status`, `$#*`, `$*`, `$apid` |
| `if [ -f f ]; then a; else b; fi` | `if(test -f f) a; if not b` |
| `for i in a b; do c $i; done` | `for(i in a b) c $i` |
| `f() { ... }` | `fn f { ... }` |

`X=1 cmd`, `&&`, `||`, `|`, `<`, `>`, `>>` and `&` mean the same in both.

### Job control

`&` runs a pipeline in the background; `jobs` lists the jobs, `fg` and
`bg` take a job's number, `Ctrl-Z` stops the foreground job, `Ctrl-C`
interrupts it, and `kill %N` ends a job, with `SIGTERM` unless a signal is
named.

**The terminal relay** is the process of the session's domain that owns
the session's tty ([design-live.md](design-live.md#the-tty)) and serves
the session's `/dev/tty`: the opens that the session's programs hold on it,
their standard streams among them
([design-programs.md](design-programs.md#the-terminal)). It holds the
`termios`, runs the line discipline, drives the group of the session's shell
and talks to the tty's master. It is the only process that reads terminal
input for programs, it takes requests only through the programs' handlers,
which never wait on a program, and it never waits on one itself, so a busy
or hostile program delays none of its work:

* **Input.** Bytes from the master go through the line discipline to what
  reads the tty: the group while the shell prompts, on a raw tty with
  `edlin`'s editing and history, and otherwise the foreground job, whose opens
  may compete, as on UNIX, with the relay serving their reads one at a time. In
  cooked mode the line discipline collects a line and the relay answers the
  foreground job's pending read with it, newline included, when the line
  ends. `Ctrl-D` at the start of a line answers that read with no bytes,
  which the program reads as the end of its input; its later reads go on, as
  on a UNIX terminal. Input typed after `Ctrl-C` and before the next prompt
  is discarded. The relay handles input before output, so `Ctrl-C` and
  `Ctrl-Z` act however much output waits.
* **Output.** What any program writes to the terminal goes through the line
  discipline's output and to the master as `{tty_output, N, Bytes}`, in the
  order the writes arrive, so one program's output and error streams
  interleave as it wrote them and two programs' as they arrive. The relay
  holds at most 4 KiB for the master, and a write takes only what room there
  is. A program that writes faster than the terminal, or to a session that is
  not connected, waits for room with no request outstanding, so a signal
  interrupts it as on a UNIX terminal
  ([design-programs.md](design-programs.md#the-terminal)), and nothing piles up
  in the session. A background job's write goes through as well; `TOSTOP`
  comes with process groups, in the second tier, and follows POSIX there.
* **Interrupts.** With `ISIG`, `Ctrl-C` and `Ctrl-Z` reach the relay's
  line discipline as input. `Ctrl-C` asks the handler of every program of
  the foreground job to send it `SIGINT`, ends the job's Erlang commands
  with reason `interrupt`, and discards the output the relay holds at that
  moment, as a terminal flushes its output on an interrupt; `Ctrl-Z` stops
  the job.
* **Modes across jobs.** The shell sets the tty back to cooked before it
  starts a foreground job, keeps a stopped job's `termios` for its `fg`, and
  takes its own raw setting back when the job ends or stops, as a UNIX shell
  does.

**Jobs and their tags.** A job is the set of its stages and of every
program they started, which the command server records at each spawn
([design-programs.md](design-programs.md#job-control)). Its Erlang
processes are those that carry its **job tag**, a runtime attribute that
every process takes from the process that spawns it, at its creation, and
never changes, so a stage's helpers belong to its job however they are
spawned; the group leader, which a process may change, stays only the
route of its input and output. The runtime acts on a tag at the one point
where its schedulers pick a process to run: a process of a stopped job is
set aside there instead of running, and one of an ending job exits there,
so a process spawned at any moment is stopped or ended with its job, and
no list of members is kept or raced
([design-runtime.md](design-runtime.md)).

**Ending a job** signals its programs through their handlers and ends its
tag's processes. It also reaches members that wait in `receive`: it marks
the job ending and then wakes each member it finds among the runtime's
processes, and each spawn checks its job after the new process exists, so
a process spawned while the search runs is either found by it or ended by
its spawner. `kill %N` of a paused job resumes it after the signal, as a
UNIX shell continues a stopped job it signals.

**Stopping and continuing.** Stopping a job pauses its programs, through
the port driver's pause of each program's image, and marks its tag
stopped; a program that a paused member starts or forks, or that the
shell starts for the stopped job, starts paused. `fg` and `bg` clear the
mark, resume the programs and then have each program's handler send it
`SIGCONT`. A `SIGCONT` that reaches one program of a stopped job from
elsewhere, under the `kill` rules, resumes that program and makes the job
table show the job running in the background, while its other members
stay stopped until `fg` or `bg`, as a UNIX job's other processes do
([design-programs.md](design-programs.md#job-control)). On the stopgap,
which pauses no space, stopping a job stops only its Erlang commands: the
shell reports those stopped and names the job's programs, which run on, so
the job table never shows a running program as stopped
([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)).

**Reading in the background.** Only the foreground job reads the
terminal; a background job that reads it waits until it is brought to the
foreground.

## Interfaces

**Erlang commands** implement `erx_cmd`:

```erlang
-callback run(Args :: [binary()], Ctx :: erx_cmd:ctx()) ->
              ok | {error, usage} | {error, term()}.
-callback fields() -> [atom()].        % the order of the fields it emits
-optional_callbacks([fields/0]).
```

Command metadata declares the public names, help and output fields in
the command module, beside its `-erx_needs` declaration. The generator
emits the catalog and the optional `fields/0` wrapper from those fields
and checks the `run/2` export against the behaviour. The command body is
handwritten; no separate name, help or field list is maintained in the
shell or host tool. Generated catalogs describe required facets and
never grant them. Runtime entries pair the metadata with its verified
module blob hash and a local entry fun of that version. Command starts
check that binding before invoking the fun. The code server makes entries
unavailable during replacement and republishes them only with the matching
loaded code; a partial or unknown load is reconciled before another start.
Catalog failure never silently dispatches replacement code under old
metadata ([design-generation.md](design-generation.md#configuration-and-command-catalogs)).

`Ctx` holds the command's environment, working directory, standard
streams and capabilities: its grants and its facets, each a pid with the
facet's name, from which `erx_cmd:facet(Ctx, Name)` returns the facet or
`{error, no_facet}`. A module declares the facets it needs with
`-erx_needs(Names)`, which the shell checks before it runs the command.
`erx_cmd:emit/2` writes a record or a line to standard output, waiting
while 256 records are in flight to the next stage, and `erx_cmd:read/1`
takes the next record, line or `eof` from standard input
([Pipelines](#pipelines)). No other source of authority exists for a
command: the system domain's services are reached only through facets in
the context.

A context's pids are names. A command domain holds its grants and facets
before its startup message, each a process the system domain made for
that domain and exported to it; neither that message nor a record flowing
through an Erlang pipeline introduces authority. A command cannot turn a
pid printed by `ps`, as `<D.N.S>` with `D` the id of the domain that owns
the process, or received in a pipeline, into permission to signal,
inspect or manage it: only a facet in its context, within the facet's
declared scope, authorizes that action
([design-domains.md](design-domains.md#authority)). Starting a narrowed
Erlang command builds its domain from the named capabilities alone, as a
program's table is built from its starter's
([design-programs.md](design-programs.md#the-startup-message)).

**Builtins.** rc's `.`, `builtin`, `cd`, `eval`, `exit`, `flag`, `shift`,
`wait` and `whatis`, and erXos's `erl`, `within`, `jobs`, `fg`, `bg` and
`kill` ([Commands](#commands)); `rc` as a program has rc's builtins and
`within` ([rc as a program](#rc-as-a-program)).

**Interaction with other subsystems.** The console carries the bytes of
the session's tty
([design-live.md](design-live.md#the-tty)); the command server starts
programs through the spawn path and keeps their handlers, and the port
driver creates, pauses and ends their sub-spaces
([design-programs.md](design-programs.md),
[design-runtime.md](design-runtime.md#programs-as-ports)); `/proc`, the
inspector and the code store are reached through Erlang commands with the
facets in their context ([design-live.md](design-live.md)); and `bind`,
`mount` and `unmount` change the session domain's namespace
([design-files.md](design-files.md#building-binding-and-mounting)).

## Compatibility and migration

* **The command shell is not a POSIX shell.** Scripts written for `sh` do
  not run in it, and one-liners take rc's syntax
  ([The language](#the-language)); the Erlang shell stays one
  `Ctrl-G` away, unchanged.

The shell has no persistent format and no version: scripts are text in
rc's language, which the shell keeps as rc defines it, and Erlang commands
are modules of the session's releases, built with the tree. A change to
`erx_cmd` or to erXos's additions to the language replaces the old form
outright, and a command module built for the old `erx_cmd` is rebuilt with
the tree, never adapted ([design.md](design.md#compatibility)).

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A shell line is over 64 KiB, nests deeper than 256, or does not parse | the command shell's parser | nothing: the line is not run | no one: nothing ran | `syntax error` with the line and column; `$status` says so |
| An evaluator, stage or command passes its heap limit | `max_heap_size` | nothing of that process | the runtime, which kills the process | its stage's status is the kill's reason |
| A stage meets a line or a record over 64 KiB | the stage's reader, or its send | nothing of that stage | the stage ends; its pipes' ends close with it | its stage's status is `line too long` or `record too large` |
| An evaluator's Erlang stages do not fit the stage allowance | the shell, before it starts them | nothing: no stage runs | none | a foreground line waits for running stages to end, and fails with `too many stages` when it could never fit; a background job, a substitution or a pipeline inside a stage fails with `too many stages` at once |
| A program cannot start: no such command, a quota, a pipe's read ends, the session's budget | the command server, from the handler's answer | nothing: the ends made for the program are gone, so the line's other stages see the end of their pipes | the spawn path, which undoes each step it took ([design-programs.md](design-programs.md#starting-a-program)) | the reason as the stage's status, such as `not found`, `permission denied` or `quota` |
| A stage crashes or faults | the command server's monitor on an Erlang stage; a program's exit or fault record, through its handler | nothing: a crashed stage's pipe ends close with it, and a program's with its image | the session's pipe server, and the port driver for a program ([design-programs.md](design-programs.md#a-programs-end)) | the neighbouring stages see the end of the stream or a broken pipe; `$status` lists the crash or the signal |

**Diagnostics.** `jobs` lists each job's stages, programs and state; the
inspector shows the session's processes and its programs as ports under
the session; a stage's crash reason, cut at 256 bytes, is its `$status`.

## Security

The command shell runs with the session's authority, bounded at 64 KiB
and depth 256 a line and by its processes' heap limit, with fuzz targets
for its parser and for `where`'s predicates. Each program it starts holds
only the descriptors, grants and rights its starter handed it, starts only
what `/bin` lists and only with the right to start commands, and reaches
the terminal only through the session's tty, which does not filter it, as
on UNIX ([design-programs.md](design-programs.md#security)). A command acts only
through what it was handed, and one with less than the session's runs in
a domain of its own (SH1). An Erlang command run in the session's domain is
trusted session code: the context is its interface, not a boundary.

**Residual risks accepted.** The `erl` builtin evaluates any expression
with the session's authority, as the Erlang shell does. One allocation
larger than the session's free memory, which only a command's own code can
ask for, can end the session, as any trusted session code can (SH2).

## Verification and testing

Catalog checks cover metadata/callback mismatches, duplicate names,
the existing precedence, absent required facets, records whose
fields disagree with the declaration, and live-loaded metadata refused
before publication. Races between starts and code replacement, including
lost acknowledgements and failure after load but before catalog publication,
never mix metadata and entry-code versions. An independently written command fixture exercises
the generated lookup and help; the shell's parser and semantic oracle
remain independent of catalog generation.

* **The command shell against rc.** The oracle is Plan 9's rc as
  plan9port carries it (MIT), built from source at a pinned commit as a
  host test tool, since Homebrew offers no package for it
  ([research](research-boards-storage.md#the-command-shells-oracle)).
  `tools/erx build rc-oracle` compiles rc and the lib9 members it links
  with erXos's own compiler invocations, never plan9port's build
  scripts, and `Erx::RcOracle` runs a script with a fixed `$path` and
  `$home`, an empty private working directory, standard input at end
  of file and a deadline, returning its output and final `$status`, or
  saying it timed out or gave no status, never guessing one.
  Every script of the shell's test corpus runs under both, and their
  output and `$status` are compared; each difference is a bug, a
  documented difference with a test (the interactive layer, records in
  pipes, `within`), or an upstream bug recorded as such. The corpus calls
  only rc's builtins and toybox's applets, which the test also builds for
  the host and puts first in plan9port rc's `$path`, so both shells run
  the same commands; it starts from plan9port's own `test.rc` and its
  parser checks, and from the `trip.rc` of Byron Rakitzis's rc (zlib),
  with the cases for that implementation's extensions set apart. The
  tokenizer and parser have a fuzz target that checks the 64 KiB and
  depth-256 bounds.
* **Interaction:** line editing, history and completion through a scripted
  terminal; `Ctrl-Z`, `fg`, `bg`, `Ctrl-C` and `kill %N` on a job of
  Erlang commands, of programs, of both, and of programs three generations
  deep; on the stopgap, `Ctrl-Z` on a job of both, after which the job
  table shows its Erlang commands stopped and its programs running; an
  Erlang command whose helper process the job's stop holds; a stage that
  spawns helpers in a loop while `Ctrl-Z` and then `kill %N` arrive, none
  of which runs after the stop or survives the end; `Ctrl-D` answering
  one read of a program with the end of file while its next read goes
  on; a program whose output and error streams both go to the terminal,
  which arrive in the order it wrote them; a background job that reads
  the terminal; a program that floods its output while `Ctrl-C` is typed,
  which stops within a second at 115,200 baud; a program that stops
  draining its channel while the relay has its handler send `Ctrl-C`,
  which leaves the relay and the prompt responsive; `kill %1` of a
  stopped job; a program that catches `SIGCONT` and sees it after `fg`;
  and a `SIGCONT` that another program of the POSIX session sends to a
  member of a stopped job, after which `jobs` shows the job running and
  `fg` brings back its other members.
* **`rc` as a program:** `system` and `popen` from a C program, with
  `$status` mapped to wait statuses for an empty status, a number, a
  signal's name and an error's text, and for pipelines of one, two and
  three stages that all succeed, which exit 0, and that fail in the first,
  the last or every stage; an `rc -c` that runs `ps`, which lists
  processes only when `rc` was handed the `inspect` right, and one that
  names `erl`, which finds none; `rc` narrowed without `/bin`, which
  starts nothing; each line of the porting table run under `rc` with the
  result its sh form gives under the host's `/bin/sh`.
* **Records:** `ps | where ... | sort ...` over records whose values are
  `unknown` or `timeout`, which `where` neither keeps nor coerces and
  `where -u` lists; each truth table of `not`, `and` and `or` over true,
  false and undecided; integers against integers, text and mixed pairs; a
  glob made to backtrack over a 64 KiB field, which is undecided past its
  step budget; the predicate parser's fuzz target with its bounds.
* **Programs from the shell:** pipelines of toybox applets and Erlang
  commands in every order, redirections to and from files of the session's
  export and of `/data`, `within` with a path outside the narrowed
  namespace (`enoent`), a narrowed program that tries every command name;
  `xargs ps` from a program with the `inspect` right, which lists
  processes through the facet the system domain makes for the command
  domain that runs `ps`, and without it, which fails with `no_facet`; the
  session's own `inspect` facet, asked by that command domain directly,
  which answers `badarg`; `watch ps` likewise;
  `within -f signal /bin /tmp -- xargs kill`, which ends a sibling that
  the right reaches and gets `ESRCH` for one it does not; `within -- ps`
  with no facet, which fails with `no_facet` from a command domain the
  inspector shows; an executable started by its path through an `rx`
  grant, and by a path that only an `rw` grant reaches, which gives
  `permission denied`; and a `make`-shaped line, a program that starts
  200 children writing to one pipe whose reader is paused, every one of
  which starts.

## Performance

The command shell adds little to what it runs: parsing a line is
microseconds, a record passed between Erlang stages is one message, and
a program's start, budgeted at 1 ms under HVF, dominates a line that
runs programs ([design-programs.md](design-programs.md#performance)).

## Portability

The shell is Erlang and depends on nothing of the architecture.

## Dependencies

No new library. One host test tool: plan9port's rc, built from its pinned
source out of tree as the shell's oracle, never shipped (MIT,
[design.md](design.md#dependencies)). toybox and `wak` belong to the
native programs ([design-programs.md](design-programs.md#toybox)).

## Alternatives considered

**A POSIX shell.** A shell for `sh` scripts would let pasted one-liners
run. It loses: rc's one quoting rule and its values that are never scanned
again remove the Bourne shell's commonest traps, as Duff's paper argues;
a conforming POSIX shell is several times the size of rc's language (an
estimate); and the user chose rc's language, with a shell compatible with
tcsh as a possible addition in the roadmap
([plan.md](plan.md#beyond-the-plan)). toybox's own shell, which sits in
its pending directory, and shells such as mksh or a port of tcsh need
`fork` and process groups, which only the personality's second tier
provides ([design-programs.md](design-programs.md#the-second-tier)).

**A shell in C over the POSIX-lite personality.** It would be one more
program; it loses because a shell in Erlang passes records between
Erlang commands, runs them in the session's domain without a process per
stage, and reaches the inspector, tracing and the code store directly.

**Terminal streams as pipes to the relay.** Each program's standard
output and error to the terminal would be two pipes whose far ends the
relay reads. It loses: two streams of one program interleave as two pipes
do, not as the program wrote them, so an error message can appear before
the output it follows; and each stream costs a pipe. Opens on `/dev/tty`
reach the relay through the program's handler in the order written and
cost no pipe ([Job control](#job-control)).

**Job control through a party outside the session.** A separate trusted
program would pause and resume a session's programs at the shell's
request. It loses: the session created each program's space and holds
the capability to pause it, so a third party on the path adds a protocol
and a trust boundary and removes nothing; the session's own port driver
pauses the space ([design-programs.md](design-programs.md#job-control)).

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Users expect POSIX shell syntax | high | friction at first use | the Erlang shell and rc's short manual are one `Ctrl-G` and one `help` away; a tcsh-compatible shell is in the roadmap |
| rc's oracle and the shell disagree where rc's behaviour is unspecified | medium | test noise | each difference is classified once and pinned by a test |
| The relay's single path for terminal writes serialises a job's output through one process | low | a job of many chatty programs is bounded by the relay's throughput | the relay handles at most 4 KiB unanswered and the console is the bottleneck anyway; `tools/erx bench pipe` with a pipeline writing to the terminal |

No open question remains for the shell: its language, its editing and its
toolbox are the user's decisions, and a shell compatible with tcsh is a
roadmap item ([plan.md](plan.md#beyond-the-plan)).

## References

* T. Duff, "Rc - The Plan 9 Shell", Plan 9 Programmer's Manual, AT&T
  Bell Laboratories, 1990; plan9port at `1f139691`, Byron Rakitzis's rc
  and tcsh, as checked in
  [research-boards-storage.md](research-boards-storage.md#the-command-shells-oracle).
* Erlang/OTP 29.1.2: `lib/stdlib/src/edlin.erl`, the line editor whose
  editing, history and expansion hook the shell uses.
