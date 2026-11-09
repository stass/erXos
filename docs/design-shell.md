# The command shell

Each session can run a **command shell** beside its Erlang shell: erXos's
own, written in Erlang, speaking the language of rc, Plan 9's shell, by
the user's decision. Builtins, Erlang commands and programs share one
command namespace; every pipe carries bytes, as on UNIX, and every
command reads and writes text as FreeBSD's command of the same name does;
and jobs of Erlang processes and programs stop, continue and end together.
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
* **Text in every pipe.** A stage reads and writes bytes whatever is at
  the other end, and a command named like a FreeBSD utility behaves like
  it, with FreeBSD 15.1 as its test oracle. A value a command cannot
  measure prints as FreeBSD prints a missing one, `-` or nothing, never as
  a number. Live values with their statuses are the Erlang shell's and the
  inspector's ([design-live.md](design-live.md#inspection)).
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
commands are Erlang modules that read and write text as FreeBSD's
commands of the same names do; and the other UNIX commands it runs are
toybox's applets, each a program in a sub-space of the session
and a port of its runtime
([design-programs.md](design-programs.md#a-program-is-a-port)). It sits
in each session's domain, beside the Erlang shell in the same `Ctrl-G`
menu, and uses the session's tty
([design-live.md](design-live.md#the-tty)), the inspector
([design-live.md](design-live.md#inspection)), the session's
namespace ([design-files.md](design-files.md)) and the spawn path
([design-programs.md](design-programs.md)).

The command shell is the first shell of the system domain's console, as a
UNIX console's login shell is. The console shows the release slogan, the
line `rc: the command shell; erl starts the Erlang shell` and the prompt
`% `. When that shell ends, by `exit` or a crash, while input may still
come, the console starts a fresh one, as getty starts another login. Once
the input has ended, the shell's end ends the runtime, with status 0 if
the shell ended normally and 1 if not, as stock's shell halts at the end
of its input. With `-noshell` or `-noinput` there is no shell. The
`erl` command runs the Erlang shell on the console above the command
shell until that shell ends. Its banner is `Eshell V... (type help(). for
help)` and names no `Ctrl-G`, because `Ctrl-G` on the console belongs to
the console's menu ([design-live.md](design-live.md#the-console)).
`erx_shell:start().` typed at that Erlang shell starts another command
shell above it, whose `exit` returns to the Erlang shell.

## Requirements

* **S-R1.** A command shell per session with rc's language, line editing
  and job control, builtins, Erlang commands and programs in one command
  namespace, and pipes of bytes between them; the same language as a
  program, `rc`, for programs' `system` and `popen`.
* **S-R2.** A line, a stage or a command can fail, overflow or crash
  without ending the session.
* **S-R3.** The shell's behaviour agrees with Plan 9's rc wherever it
  claims rc's language, each difference documented with a test.
* **S-R4.** An Erlang command named like a FreeBSD utility agrees with
  FreeBSD 15.1's, in output, diagnostics and exit status, for every option
  it offers, each difference documented with a test.

Non-functional: parsing adds microseconds to a line, a write between two
Erlang stages costs one message, and a program's start dominates any line
that runs one ([Performance](#performance)).

Non-goals: a POSIX shell, vi-style editing, and running third-party `sh`
scripts ([Alternatives considered](#alternatives-considered)).

## Overview

Each unit of a line or script, rc's line, is tokenized and parsed into a
syntax tree, in a child process of the evaluator with a fixed heap,
bounded at 4 KiB of source and a nesting depth of 256
([Bounds](#the-language)), and evaluated: each stage of a pipeline, each
command substitution and each background block is an Erlang process with
a copy of the shell's variables. A stage that names an Erlang command
calls it in that process; a stage that names a program has the command
server start it ([design-programs.md](design-programs.md#starting-a-program)).
Every stage reads and writes bytes: two Erlang stages pass them as
messages, and a stage that meets a program meets a pipe, but no stage can
tell which by what it reads. The terminal relay serves the foreground
job's terminal, and job control acts on the job's programs and Erlang
processes.

```text
  session domain                                      programs: sub-spaces
 +--------------------------------------------------+  +--------------+
 | console line, <-> terminal relay <-> /dev/tty    |  |              |
 | or erx_term           opens of the foreground job|  |              |
 | shell: parse -> evaluate -> stages               |  |              |
 |   Erlang stage --bytes---> Erlang stage --bytes--+--+-> program    |
 |                                          (pipe)  |  |  (a port,    |
 | command server (pid 1): process ids, jobs and    |  |   channel to |
 | handlers; the port driver                        |  |   handler)   |
 +--------------------------------------------------+  +--------------+
```

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **SH1.** A command acts only through the capabilities it was handed, and one handed fewer than the session's runs in a domain of its own | an Erlang command receives its grants and facets in its context and reaches services only through them; the shell's own lines run in the session's domain with the session's capabilities, since that is what the user typed them with; a command that `within` narrows, and every Erlang command a program starts, runs in a command domain built from exactly the capabilities its starter named, which its starter held, and named from its principal's pool of reusable names ([design-system.md](design-system.md#identifiers)), each facet among them made by the system domain for that domain alone and with no wider scope, and a program runs in a sub-space whose handler acts only on the program's own table ([design-programs.md](design-programs.md#what-a-program-can-start), [design-programs.md](design-programs.md#facets)); a handler never runs a builtin or a function for a program | a command that reaches a service by a registered name of the system domain; a narrowed or program-started command run in the session's domain; a domain given a capability its starter did not hold | a test that every command run in a session without an inspect facet gets `no_facet`; a test that a command domain's capabilities are exactly the grants and facets named before its startup message; `xargs ps` from a program with and without the `inspect` right, and a command domain that asks for the session's own facet instead of its own, which is refused; a narrowed program that asks its handler for every name of the command namespace in turn starts only what `/bin` lists and reaches nothing outside its grants |
| **SH2.** A failing line, stage or command never ends the session | each stage, substitution and background block is an Erlang process of its own with `max_heap_size` set, counting the binaries it references; every input that reaches a stage is bounded in bytes, a line a command reads at 64 KiB and the bytes in flight between two Erlang stages at 64 KiB, so no input makes a stage grow without bound; every evaluator's Erlang stages are admitted whole within the session's stage allowance, an eighth of its budget, within the half the session keeps for its own services and from which no program's budget is carved ([design-system.md](design-system.md#resource-policy)), and only a foreground line waits for it, so stages together stay within memory the session keeps for them and no evaluator waits for an allowance its own parent holds; the parser, in a child process of the evaluator with a fixed heap, refuses a unit over its bounds before it runs; a program is a sub-space with a budget of its own, carved from the other half, so what it spends never counts against a stage | a stage evaluated in the shell's own process; an unbounded parse; an input path without a byte bound; stages admitted beyond the allowance; a nested evaluator that waits for the allowance; a program's budget carved from the services' half | the overflow, deep-nesting and runaway-recursion tests; a native program that writes a 1 GiB line without a newline into an Erlang stage, which fails that stage alone; as many stages as the allowance admits, each near its limit, and one more pipeline, which waits; a substitution inside a fully admitted pipeline, and a background job beyond the allowance, each of which fails with `too many stages` at once; a loop of programs that spends the programs' half, during which the shell still parses, prompts and runs builtins; the parser's fuzz target |
| **SH3.** No command prints a value it does not have | a command formats a value only when its reader returned it with the status `ok`; any other value prints as FreeBSD prints a missing one, `-` in a column and nothing for a field labelled by its own letter ([Pipelines](#pipelines)); the one exception is `top`'s header, where a partial figure prints its number with its reporter named, in the line's label or after the figure ([design-live.md](design-live.md#the-command-shell)) | a formatter that prints 0, an old value or a guess for a missing one; a partial figure of `top`'s header without its reporter named | `ps`'s and the `Ctrl-T` line's tests with each value in turn `unknown`, `partial`, `timeout` and `unsupported`, where a formatter that prints 0 fails; `top`'s header tests with each figure in turn `ok`, `partial` under one and several reporters, `unknown`, `timeout`, `unsupported` and `error`, where a partial figure printed without its reporter named fails ([design-live.md](design-live.md#invariants) V2) |

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
```

The command namespace is a map from name to `command()`, built when the
session starts from the generated command catalogs of its releases and
the image's program list. A release's catalog derives from command module
metadata and the native program list, without executing command bodies.
It supplies lookup entries, help and required facets, retaining the
precedence and unresolved-conflict rules below.
A session sees only commands of releases it holds. Live-loaded command
metadata passes the same checks before publication
([design-generation.md](design-generation.md#configuration-and-command-catalogs)).
The command server keeps the jobs and the session's process table
([design-programs.md](design-programs.md#the-parties)). What flows
between stages is bytes, which the shell does not interpret
([Pipelines](#pipelines)).

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
  provided. The shell is a group's shell, as the Erlang shell is, and reads
  a line at a time under `$prompt(1)`, `% ` by default; a unit that only
  more lines can complete reads on under `$prompt(2)`, empty by default. A
  whole unit runs in an evaluator process of its own, so `Ctrl-C` ends it
  and the shell reads on with the variables it had before it and `$status`
  saying the line was interrupted; `Ctrl-C`
  while a line is typed drops the unit read so far. A foreground line is
  a job, so what it starts ends with it, by its job tag
  ([Job control](#job-control)). A unit that does not
  parse is reported, sets `$status` as in a script and is skipped; `exit`
  and the end of input, `Ctrl-D`, end the shell.
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
  admits eight stages at once, which a pipeline of `ps`, `grep`, `sort`
  and `wc` with a substitution leaves room in. So a runaway recursion
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
  shell itself is one `erl` away: with no argument, `erl` runs the Erlang
  shell on the terminal above the command shell until that shell ends.
* **Authority.** The shell runs inside the session's domain with that
  domain's authority and facets, and nothing more; neither the shell nor
  any command has authority of its own (SH1). `bind`, `mount` and
  `unmount` change the session domain's namespace, which every shell and
  command of the session shares.

Its interpreter is ordinary Erlang, an estimated 2,000 to 3,000 lines for
the language and as much again for the interactive layer: a tokenizer and a
parser that build a syntax tree for each unit of source, rc's line, and
an evaluator over the tree. Plan
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
`erx_shell` application, are pure functions from the source read so far
to the syntax tree of its next unit and the source after it,
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
not parse. An `if not` stands only where it follows an `if`, as rc's
parser checks: first in a sequence after an `if`, or after an `if not`
whose body is an `if` or empty, or as the body of such an `if not`;
elsewhere it is a syntax error. Where it may stand passes from command
to command of a sequence and from unit to unit of a source, through
lines with no command; a source, an `eval`'s text, a block, a function's
body and a switch arm start without it (rc carries it into an arm whose
`case` has no patterns; the shell does not). After a syntax error `$status`
is the diagnostic's message alone, as in rc. The depth bound counts levels: `{...}`, `if`, `if not`, `for`,
`while`, `switch`, `fn`, `!`, `@`, a redirection or an assignment written
before a command, `(...)`, `$`, `$#`, `$"`, `` `{...} ``, `<{...}` and
`>{...}` each
hold what is inside them one level deeper. Sequences, `&&` and `||` chains,
pipelines, `^` joins and a simple command's words are flat lists, so a long
pipeline is not deep. No tree is deeper than its levels allow, so neither
the parser nor anything that walks a tree recurses further.

**Bounds.** A source is parsed one unit at a time, as rc does. The unit is
rc's line: the commands up to a newline outside every construct, with the
lines an open construct or a trailing `|`, `&&` or `||` carries it over
and the bodies of its here documents. A unit, its newline and
here-document bodies included, is at most 4 KiB of source, and the parser
reads no more of a source than that. The evaluator parses each unit in a
child process whose heap is fixed at 8 MiB, so the heap a parse takes is
bounded by the unit alone, whatever the evaluator's own heap holds; the
child hands back the tree as its exit reason, and one that the heap limit
kills gives `line too long`, never a crash of the evaluator. The bound is
half that heap over the worst cost per byte of source that a sweep of
costly shapes at the bound measures, 778 bytes, rounded up to 1,024 since
the heap grows in garbage-collection steps; a test parses each of the
sweep's sources within half the heap, so a larger parse heap raises the
bound in proportion and the test says whether it still holds. A script or
`-c` string has no size bound; a unit over the bound fails with `line too
long` and a script stops there, as at a syntax error, after the units
before it have run. Nesting stays bounded at 256. One loop serves the
terminal, `rc file`, `. file` and `rc -c`: it hands the parser the lines
it has read, saying whether more may follow, so an unfinished last line is
never run cut short; it runs the unit it gets back and keeps the rest; on
`incomplete` it reads another line, or at the end of the input reports the
diagnostic. After a faulty unit a script stops and the terminal goes on:
after a syntax error or `too_deep` from the line after the fault, as rc
skips to the end of that line, and after `line too long`, whose end is
unknown, with none of what it holds.

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
   (`-erx_command(ps)`): the UNIX utilities `ps`, `echo`, `cat`, `ls`,
   `pwd`, `mkdir`, `rm`, `mv`, `cp`, `grep`, `sort`, `wc`, `uname`,
   `dmesg`, `true` and `false`, which follow FreeBSD's utilities of the same names
   ([Text commands](#text-commands)), so toybox's applets of those names
   are never built; the network utilities `ifconfig [-a] [interface]`
   and `ping`, which follow FreeBSD's ifconfig(8) and ping(8) over
   erXos's own stack, reading interfaces through `erx_net:interfaces/0`
   and echo replies through `erx_icmp_sock`
   ([design-network-stack.md](design-network-stack.md)); and erXos's own `i`, `domains`, `source`, `trace`,
   `attach`, `bind`, `mount` and `unmount`, which have no FreeBSD
   counterpart;
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

Every stage of a pipeline reads bytes and writes bytes, as on UNIX. An
Erlang command reads its standard input and writes its standard output as
bytes whatever is at the other end, the terminal, a file, a program or
another Erlang command, so `ps -m | head`, `cat f | grep error | wc -l`
and `ls | xargs rm` mean on erXos what they mean on FreeBSD. The shell
does not interpret what flows. Only the transport differs:

* between two Erlang commands, both processes of the session's domain,
  each write is one message holding its bytes, with at most 64 KiB in
  flight to the reader, the size of a pipe's first ring
  ([design-pipes.md](design-pipes.md#the-objects-of-a-pipe)); the reader
  sees the end of the stream once the writer's stage has ended and every
  write has been read, and a writer whose reader has ended stops with the
  status `sigpipe`, as a program would;
* wherever a program takes part, the stages are joined by pipes
  ([design-pipes.md](design-pipes.md)); the session's pipe server makes
  each end for the stage that uses it, so every end has one holder and
  the session knows them all
  ([design-pipes.md](design-pipes.md#making-a-pipe));
* a redirection hands a stage a file the shell opened, and a stream with
  neither a pipe nor a redirection is the session's terminal.

A command's output is bytes, as a program's is, and the tty passes it
unchanged ([The tty](design-live.md#the-tty)). Where FreeBSD's command
looks at whether its output is a terminal, as `ls` does to choose columns
and to hide characters that do not print, the Erlang command asks
`erx_cmd:isatty/2`; nothing else in a command depends on what is at the
other end. So Erlang commands, programs, files and the terminal combine
in any order with one meaning, and no stage renders, frames or reparses
another's output.

**Values erXos does not measure.** A command prints a value it could not
get as FreeBSD's tools print a value they do not have (SH3). In a column
it prints `-`, as FreeBSD's `ps` prints a column with no value
(`bin/ps/ps.c:757-759`), so every row keeps its columns and `awk`, `cut`
and `sort -k` find the same field in every row. Where each field carries
its own label, as in the `Ctrl-T` line, the field is left out. A command
never prints a bare number for a value it does not have, and never prints the
inspector's status tokens: which values were unknown, partial or late,
and who reported them, is what the Erlang shell's `erx:ps()` and
`erx:i/1` and the inspector show
([design-live.md](design-live.md#inspection-records)). erXos's own
commands with no FreeBSD counterpart, `i`, `domains`, `source` and
`trace`, are the inspector's front ends in the command shell and print
what their `erx:` functions print, status tokens included. `top`'s
header is the one exception: its figures are rounded for a person to
read, not fields a stage parses, so a partial figure there prints its
number with its reporter named, `Mem (root pool): 118M Total, 74M Free` ([design-live.md](design-live.md#the-command-shell)).

**Names a source chose.** A command that prints text a source chose, a
file's name or a process's, escapes it where FreeBSD's command of the
same name does, with erXos's escapes
([Attributed text](design-live.md#attributed-text)). `ls` writes a name
through the line escape when its output is a terminal, where FreeBSD's
prints `?` for each character that does not print, and as its bytes
otherwise, as FreeBSD's does (`bin/ls/ls.c:247-256`). `ps` writes a
process's name and arguments through the field escape wherever its output
goes, as FreeBSD's writes them through `strvis(3)`
(`bin/ps/print.c:93-100`), so each row is one line and holds no control
character. A line a command reads and passes on, as `grep`, `sort` and
`cat` do, is its writer's bytes and reaches the terminal as through
`cat`.

**Bounds.** A line an Erlang command reads with `erx_cmd:read_line/1` is
at most 64 KiB, beyond which its stage fails with `line too long` rather
than gather it; FreeBSD's tools take lines of any length, a documented
difference. At most 64 KiB are in flight between two Erlang stages. A
command that holds its input, as `sort` does, holds it within its stage's
`max_heap_size`, and one whose input outgrows that fails alone, where
FreeBSD's `sort` spills to temporary files, another documented
difference. So input of any size, from any producer, ends at most the
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

### Text commands

The Erlang commands named like FreeBSD utilities offer a small core of
each utility's options, enough for the common idioms, and behave as
FreeBSD 15.1's do for those: the same bytes on standard output, FreeBSD's
diagnostics on standard error, as `NAME: ...`, and FreeBSD's exit
statuses (S-R4). An option a command does not offer is a usage error;
more options are later additions, each with its oracle test. Text
compares as bytes, as FreeBSD's tools compare it under `LC_ALL=C`, the
locale the oracle runs in. `ps`, `top` and `ls` are specified with the live
machine ([design-live.md](design-live.md#the-command-shell)); `cat`,
`echo` and the file utilities copy, print or change files as FreeBSD's
do. The text filters:

* **`grep [-EFcilnqrv] pattern [file ...]`** writes the lines that match
  `pattern`, a POSIX basic regular expression, an extended one under
  `-E` or a fixed string under `-F`, reading standard input when no file
  is named. `-i` ignores ASCII case, `-v` selects the lines that do not
  match, `-c` writes counts, `-l` the names of files with a match, `-n`
  puts each line's number before it, `-q` writes nothing and stops at
  the first match, and `-r` reads directories recursively. With more
  than one file, each line starts with its file's name and `:`. The status is 0 when a line was selected, 1
  when none was and 2 on an error. Every input is read as text, as
  FreeBSD's `grep -a` reads it. A pure translator, `erx_grep_re`, turns
  a pattern of at most 4 KiB into an `re` expression, or refuses it with
  status 2 where FreeBSD's `regcomp(3)` would, so `re` never reads POSIX
  syntax as its own. Each match runs under `re`'s match limit, and a line
  that passes it ends `grep` with status 2 and `grep: pattern too
  complex`, so no pattern spends unbounded time on a line. A program can
  hand `grep` its pattern, so the translator has a fuzz target.
* **`sort [-nru] [-k field[,field]] [file ...]`** writes its input's lines
  in order, comparing whole lines byte by byte, or the keys `-k` names.
  Fields split where a run of blanks begins, as FreeBSD's do, and a key
  runs from its first field to the end of the line or to the end of its
  second field. `-n` compares the number at the start of each key,
  optional blanks, `-` and a decimal point included, and a key with no
  number compares as zero, as on FreeBSD, so a column header and a `-`
  sort among the zeros. `-r` reverses the order, and `-u` writes the first
  of each set of lines with equal keys. Lines with equal keys are ordered
  as FreeBSD orders them, by a last comparison of the whole lines, which
  `-u` turns off. A last line without a newline gets one.
* **`wc [-clmw] [file ...]`** counts lines, words and bytes, or characters
  under `-m`, in FreeBSD's layout, with a total line when more than one
  file is named.

**`dmesg [-a]`** writes the kernel's message buffer, as FreeBSD's
`dmesg` writes `kern.msgbuf`: erXos's buffer is the kernel log, and
`dmesg` writes `/proc/kernel/log` unchanged, its lines from the oldest
the ring still holds, each through the field escape, with `[missing N]`
where records are missing
([design-live.md](design-live.md#the-proc-tree)). `-a`, FreeBSD's
"syslog records and console output too", is accepted and changes
nothing, since the log holds only its lines. `-c`, which clears the
buffer, is a usage error, since nothing in user space clears the kernel
log, as are `-M` and `-N`, which read a crash dump's buffer, and an
argument; the usage line is FreeBSD's, `usage: dmesg [-ac] [-M core [-N
system]]`. `dmesg` reads only what its namespace's `/proc` shows, so it
shows the log only where the tree's facet has scope `all`.

**`uname [-abiKmnoprsv]`** writes what system this is, as FreeBSD's
`uname` does: the fields its flags select on one line, one space apart,
in FreeBSD's order whatever the order of the flags: the system's name
(`-s`, or `-o`), the host name (`-n`), the release (`-r`), the version
(`-v`), the machine type (`-m`), the processor architecture (`-p`), the
configuration (`-i`), the kernel (`-K`) and the build identifier
(`-b`). `-a` is `-mnrsv`, as on FreeBSD and macOS, no flag is `-s`, and
an argument is a usage error:

```
% uname -a
erXos erxos 0.1.0 n1234-5e45e725588e Sun Nov  8 18:02:11 UTC 2026 qemu-virt/development fiasco-50bbe8a98119 arm64
```

The version takes the best of FreeBSD's and macOS's: FreeBSD's source
revision and kernel configuration, macOS's full date and kernel
version, and neither's repetition of the name and the release. It is
four words, the source revision, its date, the configuration and the
kernel. It holds only facts of the source and its configuration, never
the branch the source is checked out on, the build host or the time of
the build, so it is the same on every branch and one commit built for
one configuration gives one image. Each value has one source:

* the name, `erXos`, and the release are `uname_sysname` and
  `uname_release` of `abi/erx_abi.txt`, and the machine type and
  processor are the architecture's `arch_machine` and
  `arch_machine_arch` in `abi/arch/<arch>.txt`, FreeBSD's `MACHINE` and
  `MACHINE_ARCH` (on AArch64 `arm64` and `aarch64`, as FreeBSD names
  them; macOS's `-p` says `arm`); the C library's `uname(3)` reads the
  same, and the runtime's `os:type/0` and `os:version/0` derive from the
  same name and release, as stock ERTS derives them from `uname(2)`;
* the host name is the host part of the node name liberx gives the
  runtime, whether or not it runs distribution, which is the system
  manifest's `host` ([design-system.md](design-system.md#identifiers)),
  a system identifier and so ASCII, which needs no escaping;
* the build identifier is the boot image's, the pack header's
  `build_id` in hexadecimal, as the boot banner and the host link's
  hello show it; it plays the part of FreeBSD's `kern.build_id`;
* the source revision is the one the image was built from, in
  FreeBSD's `newvers.sh` form without its branch,
  `[n<count>-]<hash>[-dirty]`: the count of first-parent commits,
  left out in a shallow clone, the commit's first 12 hex digits, and
  `-dirty` when tracked files differ from the commit;
* the date is that commit's committer date, in UTC and in the layout of
  macOS's `date` (`%a %b %e %H:%M:%S %Z %Y`), never the time of the
  build, so the same tree in the same state packs the same image;
* the configuration is the platform record's name and the build kind,
  with a slash between, in the place where FreeBSD's `-i` names the
  kernel configuration: `qemu-virt/development` for an image of
  `config/platforms/qemu-virt.json` built for development, the kind
  the archive header's `development` bit records;
* the kernel is the packed kernel's name and the first 12 hex digits of
  its recorded upstream revision, `fiasco-` and the revision of
  `fiasco/kernel/ORIGIN.md`, which the builder of the kernel the image
  packs answers, so it follows the kernel when erXos's own replaces the
  stand-in.

The image build gathers the last four where it packs the image, and
writes them into the system release as a small file at `build_facts_path`
of `abi/erx_abi.txt`, one `name value` line per fact; its receipt names
the code that writes it, as a compiled file's names its sources. Only the
commit's facts come from the build host. `erx_build` reads the file back,
refuses it whole unless every line is in its place with a value of its
field's shape, and `uname` writes each value through the field escape.

A value the command's domain cannot know is written `unknown`, as GNU's
`uname` writes a field it cannot tell: the host name of a runtime that is
not a node, the build identifier where init was given none, every build
fact of a hosted runtime or a domain, whose release has no such file, and
the revision and the date of an image built from a tree that is not a git
checkout. FreeBSD's `-U` (the userland's `__FreeBSD_version`) has no
erXos value and is not offered, nor are the `UNAME_x` environment
variables that override a field. The values are erXos's own, so the
FreeBSD oracle has
no `uname` case; its tests pin the order, the layout and the values.

### Starting programs

The session's command server starts each program of a line
([design-programs.md](design-programs.md)). The shell derives each
program's grants from the session's namespace, unless the line narrows it:
`within /data/logs -- find /data/logs -name '*.err'` starts `find` with
one grant, rooted at `/data/logs` and read-only, and no `/bin`, so `find`
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
interrupts it, `Ctrl-T` reports on it ([`Ctrl-T`](#ctrl-t-status-and-the-info-request)),
and `kill %N` ends a job, with `SIGTERM` unless a signal is named.

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

**Numbers, names and reports.** Only the shell's own line makes jobs: its
`&` starts a numbered job, and a line that `Ctrl-Z` stops becomes one. An
`&` inside a job, a stage, a substitution or a subshell keeps its block in
that job, as an `&` inside a UNIX subshell stays in its process group. A
job takes the lowest free number, and `%N`, `%%`, `%+`, `%` and `%-` name
jobs as FreeBSD sh reads them, the current job being the one most recently
started, stopped or continued. `fg` and `bg` act only from the shell's own
line; `jobs` and `kill` act from any piece of it; a script has no job
control. What the shell shows follows FreeBSD sh: `[N]` when `&` starts a
job, `[N] + State  command` for `jobs` and for a job that stops, and the
report of a background job that is done before the next prompt; a job's
command and status reach the terminal through the line escape. `fg`
returns when its job ends, with the job's status, or stops, with the
stopping signal's name as rc names one (`sigtstp`). `kill` takes FreeBSD
kill's `-s NAME`, `-NAME`, `-NUMBER` and `-l`, with FreeBSD's names and
numbers, which the ABI file's signal table gives the builtin and every
program alike, so `kill -17` means `STOP` whoever sends it
([design-programs.md](design-programs.md#signal-numbers)); on a job of Erlang commands
`HUP`, `INT`, `QUIT`, `KILL` and `TERM` end it, `STOP` and `TSTP` stop it
and `CONT` continues it in the background. When the shell ends, for any
reason, its jobs end with it, so no job outlives its session.

#### `Ctrl-T`: status and the info request

`Ctrl-T` asks what the foreground job is doing, as FreeBSD's `VSTATUS`
does. On FreeBSD 15.1 the terminal does two things in order. With
`ISIG`, `ICANON` and `IEXTEN` set, the line discipline takes the `VSTATUS`
character, `^T` by default, echoes nothing and keeps the line typed so far
(`sys/kern/tty_ttydisc.c:1101-1106`). `tty_signal_pgrp` then prints a status
line from `tty_info` unless `NOKERNINFO` is set, and sends `SIGINFO` to the
foreground process group (`sys/kern/tty.c:1531-1551`). `SIGINFO` is ignored by
default (`sys/kern/kern_sig.c:233`), so only a program that catches it
answers: `cp` writes `from -> to  45%` to its standard error
(`bin/cp/utils.c:223-228`), `rm` writes the path it removed last
(`bin/rm/rm.c:265-268`), `sleep` writes `about N second(s) left out of the
original M` (`bin/sleep/sleep.c:116-126`), and `dd` and `fetch` write their
transfer counts; `cat` and `mv` do not catch it.

**The construction: a third terminal signal of the job.** `Ctrl-T` takes
the path `Ctrl-Z` takes. The line discipline turns it into the event
`info`. The relay passes `info` to the shell's group, and the group passes
it to the shell, which alone knows its jobs. The job table answers with
one effect, `{info, Tags}`. `Tags` are the jobs in the foreground: the
line, and the job the line waits for in `fg`, the same jobs `Ctrl-C` ends.
The shell carries the effect out over the members `{terminate, Tag}`
reaches: the processes that carry the tags, and the programs the command
server records for the job. Carrying it out takes two steps, in FreeBSD's
order: write the status line, which the tty drops when its `NOKERNINFO` is
set; then deliver the info request to each member. Each requirement follows:

* **The shell prints the line.** It is the one party that knows both kinds
  of member of the foreground job. The line discipline is a pure machine
  that knows no process, and the relay knows the job's programs but not its
  Erlang processes. FreeBSD's kernel prints the line because it holds the
  process group; in erXos the shell holds the job.
* **Order.** The line is written before any request is sent, so it comes
  before every member's answer, as on FreeBSD.
* **No foreground job.** The table answers `{info, []}`, and the line
  ends with FreeBSD's text for that case, below; no request goes out.
* **At the prompt.** While the shell prompts, the tty is raw with `ISIG`
  clear, so `Ctrl-T` is a key for `edlin`, which transposes two
  characters. FreeBSD's `sh` does the same in emacs mode: libedit clears
  `ICANON` and `IEXTEN` while it edits and binds `^T` to
  `ed-transpose-chars` (`contrib/libedit/tty.c:79-88`,
  `contrib/libedit/map.c:90`).
* **In `erl`.** The Erlang shell has no jobs. At its prompt and while it
  evaluates, `Ctrl-T` is input for its editor, as it is for stock OTP on
  FreeBSD, whose raw tty has `ICANON` clear
  ([design-live.md](design-live.md#the-tty)).

The shell runs each report in a short-lived process of its own, which
reads the members, writes the line and then sends the requests. So a slow
read, such as a member in a command domain whose agent answers late,
delays only that report, never `Ctrl-C` or the prompt.

**The status line** has FreeBSD's form (`sys/kern/tty_info.c:306-309`,
`:388-394`), with two spaces before `cmd:`:

```
cmd: NAME PID [STATE] R.RRr U.UUu S.SSs P% Kk
```

FreeBSD's line starts with `load: L` and two spaces; erXos leaves that
field out, since no reporter keeps a load average within a session's
scope and a machine-wide one would cross it.

A pure module, `erx_tty_info`, named after FreeBSD's file, chooses the
member and formats the line. Each value is an inspection attribute
([design-live.md](design-live.md#inspection-records)). A value that is `ok`
is formatted as FreeBSD formats its field: seconds to hundredths,
truncated; percent and KiB as integers. Any other value, whatever its
status, prints as the text rule of [Pipelines](#pipelines) prints a
missing value (SH3). `R`, `U`, `S`, `P` and `K` each carry their own
letter, so a field without a value is left out, with its letter and the
space before it, and the line shows only what erXos measured. `NAME` and
`STATE` have no letter and stand by position, so a missing one prints
`-`, a missing state as `[-]`. A missing value is never shown as a
number, and the line holds no status token: which reporter could not
answer is the inspector's to show. The
values come from the session's own process table, which is also the
source of its `ps` ([design-live.md](design-live.md#the-command-shell)), so no
inspect facet is needed:

| Field | An Erlang process | A program |
| --- | --- | --- |
| `NAME` | its registered name, else its `proc_lib` label when that is an atom or a binary, else the function it started in. Each stage's first process is labelled with its command's name, and the line's process with `rc` | its name, as `ps` shows it |
| `PID` | its pid as `ps` prints it, `<D.N.S>` | its process id |
| `STATE` | `running` (status `running` or `garbage_collecting`), `runnable`, `suspended` or `exiting`; while it waits in `receive`, the function it waits in, `M:F/A`, which stands where FreeBSD shows the wait channel | the chosen thread's state as the kernel reports it: `running`, `runnable` or its wait kind; `suspended` when the program is paused |
| `R` | time since the shell started it, for the line's process and a stage's first process; left out for any other, since the runtime keeps no start time | time since it started, from the command server's table |
| `U`, `S` | unsupported, so left out: the runtime keeps no CPU time per process | `U` is its group's CPU time, as `getrusage` reports it ([design-programs.md](design-programs.md#the-posix-lite-personality)); `S` is unsupported and left out, since the kernel does not split the two |
| `P` | unsupported, so left out: the runtime keeps no CPU time per process | its `pcpu` as `ps` prints it, its CPU time over the time since it started ([design-live.md](design-live.md#the-command-shell)) |
| `K` | its memory as `process_info/2` reports it, in KiB, rounded up | its sub-space's charges, in KiB |

`NAME` and `STATE` are text the member's domain or program reported. Each
is cut at a character boundary, `NAME` at 19 bytes (FreeBSD's
`MAXCOMLEN`) and `STATE` at 32 bytes, since an Erlang function name is
longer than a wait channel. Each then goes through the line escape, so a
name that holds a control sequence shows as tokens. A member that ends
while it is read is missing each value it no longer has, which the line
leaves out or prints as `-`, as `ps` does.

**Choosing the member** follows FreeBSD's `proc_compare`
(`tty_info.c:164-216`) with the measures erXos keeps:

1. a member that is running or runnable comes before one that is neither;
2. one that is not ending comes before one that is;
3. a program comes before an Erlang process, since its record carries the
   kernel's measures;
4. more work comes first: CPU time for a program, reductions for an Erlang
   process;
5. the highest pid wins.

FreeBSD ranks by recent CPU use, a decayed average; neither the kernel nor
the runtime keeps one per process, so step 4 uses the total. In a program,
the line shows its first running thread, else its first runnable one,
else its first thread.

**Where it goes.** The line reaches the terminal as one status write, which
the relay hands to `erx_tty`'s `status/3`
([design-live.md](design-live.md#the-tty)). That function returns the line,
starting with a newline when the tty's output column is not 0. It returns
nothing when `NOKERNINFO` is set or the tty has less than 256 bytes of
room. These are FreeBSD's rules (`tty.c:1542-1543`, `tty_info.c:300-309`,
`tty.c:2067-2072`). It also returns nothing when the room is less than the
whole line, so a line is never cut. A dropped line is not an error, and
the requests still go out.

With no foreground job, the line is `no foreground process group`. When
the foreground jobs have no member left, it is `empty foreground process
group`. These are FreeBSD's texts (`tty_info.c:311-324`), without the
load field.

**The info request.**

* **Programs.** The shell asks each program's handler to send it
  `SIGINFO`, as the relay asks for `SIGINT`
  ([design-programs.md](design-programs.md#the-terminal)). A program that
  does not catch it runs on.
* **Erlang commands opt in**, as a program catches `SIGINFO`. A process
  calls `erx_cmd:catch_info()`, which sets the key `'$erx_info'` in its
  own dictionary. The shell reads that key in the same `process_info/2`
  call that reads the member's values. It sends `{erx_cmd, info}` to each
  member that set the key, and sends nothing to any other member. A
  spawned helper inherits nothing: each process that wants requests opts
  in. `erx_cmd:info_requested()` takes every pending request without
  waiting and returns whether there was one, so requests coalesce as a
  pending signal does. A process that waits in `receive` matches
  `{erx_cmd, info}` itself. The request does not go to the job's group
  leader: the leader is only the route of input and output, and passing
  requests on would make it keep a list of who asked. It does not go to
  every process either: an unexpected message lengthens the queue of a
  process that never reads it, and `gen_server` logs it.
* **What answers.** The Erlang commands answer as FreeBSD's tools do. `cp`
  copies in pieces of 64 KiB, checks for a request between pieces, and
  writes `from -> to  N%` to its standard error, the percent three columns
  wide. `rm` writes the path it removed last to its standard output. `wc`
  writes its counts so far to its standard error, as FreeBSD's does
  (`usr.bin/wc/wc.c:142`, `:176-186`). `cat`, `mv`, `ls`, `grep` and
  `sort` do not opt in, as FreeBSD's do not catch `SIGINFO`.

`kill -s INFO %N`, `kill -INFO %N` and `kill -29 %N` deliver the info
request to a job and print no status line, as FreeBSD's `kill` does;
`INFO` is listed by `kill -l`. On a pseudo-terminal of the second tier, the
relay knows the foreground process group, so the relay builds the line with
`erx_tty_info` from the command server's table for that group's programs,
and then has their handlers send `SIGINFO`.

The system domain's console runs no line discipline
([design-live.md](design-live.md#the-tty)). There, `erx_console` maps
`Ctrl-T` to the event `info`, as it maps `Ctrl-Z` to `suspend`. A
command shell's group passes `info` to the shell, unless the input request
it is serving is the shell's own, in which case `Ctrl-T` is `edlin`'s key.
The Erlang shell's group gets it as the key. The console's output column
is unknown, so the line always starts with a newline there.

## Interfaces

**Erlang commands** implement `erx_cmd`:

```erlang
-callback run(Args :: [binary()], Ctx :: erx_cmd:ctx()) ->
              ok | {error, usage} | {error, term()}.
```

Command metadata declares the public names and help in the command
module, beside its `-erx_needs` declaration. The generator emits the
catalog from them and checks the `run/2` export against the behaviour.
The command body is handwritten; no separate name or help list is
maintained in the shell or host tool. Generated catalogs describe required facets and
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
`erx_cmd:write/2` writes bytes to standard output, waiting while 64 KiB
are in flight to a neighbouring Erlang stage or while a pipe has no room;
`erx_cmd:read/1` takes the next bytes or `eof` from standard input, and
`erx_cmd:read_line/1` the next line, at most 64 KiB, or `eof`;
`erx_cmd:isatty/2` says whether a standard stream is the terminal
([Pipelines](#pipelines)), and `erx_cmd:columns/1` gives the terminal's width,
`COLUMNS` first, as FreeBSD's `ls` and `ps` read it. `erx_cmd:catch_info/0` opts the calling process
in to `Ctrl-T`'s info request, and `erx_cmd:info_requested/0` takes the
requests pending for it
([`Ctrl-T`](#ctrl-t-status-and-the-info-request)). No other source of authority exists for a
command: the system domain's services are reached only through facets in
the context.

A context's pids are names. A command domain holds its grants and facets
before its startup message, each a process the system domain made for
that domain and exported to it; neither that message nor the bytes of a
pipeline introduce authority. A command cannot turn a pid printed by
`ps`, as `<D.N.S>` with `D` the id of the domain that owns the process,
or read from a pipe, into permission to signal,
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
  `erl` away, unchanged.
* **`q()` ends the Erlang shell, not the runtime.** At any Erlang shell,
  restricted ones included, `q()` ends that shell, as stock OTP's `exit()`
  does, and the shell below it reads on; stock OTP's `q()` stops the
  runtime. The Erlang shell is a shell started from the command shell, so
  leaving it must not stop the machine the command shell runs on. `q()` is
  a shell-local command, so a `user_default:q/0` does not replace it.
  `c:q/0`, `init:stop/0` and `halt()` still stop the runtime.

The shell has no persistent format and no version: scripts are text in
rc's language, which the shell keeps as rc defines it, and Erlang commands
are modules of the session's releases, built with the tree. A change to
`erx_cmd` or to erXos's additions to the language replaces the old form
outright, and a command module built for the old `erx_cmd` is rebuilt with
the tree, never adapted ([design.md](design.md#compatibility)).

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A shell unit, rc's line, is over 4 KiB, nests deeper than 256, or does not parse | the command shell's parser, in a child process of the evaluator | nothing: the unit is not run, nor anything after it in a script | no one: what ran before it stands | `syntax error` with the line and column, or `line too long`; `$status` says so |
| An evaluator, stage or command passes its heap limit | `max_heap_size` | nothing of that process | the runtime, which kills the process | its stage's status is the kill's reason |
| A command reads a line over 64 KiB | `erx_cmd:read_line/1` | nothing of that stage | the stage ends; its pipes' ends close with it | its stage's status is `line too long` |
| An evaluator's Erlang stages do not fit the stage allowance | the shell, before it starts them | nothing: no stage runs | none | a foreground line waits for running stages to end, and fails with `too many stages` when it could never fit; a background job, a substitution or a pipeline inside a stage fails with `too many stages` at once |
| A program cannot start: no such command, a quota, a pipe's read ends, the session's budget | the command server, from the handler's answer | nothing: the ends made for the program are gone, so the line's other stages see the end of their pipes | the spawn path, which undoes each step it took ([design-programs.md](design-programs.md#starting-a-program)) | the reason as the stage's status, such as `not found`, `permission denied` or `quota` |
| A stage crashes or faults | the command server's monitor on an Erlang stage; a program's exit or fault record, through its handler | nothing: a crashed stage's pipe ends close with it, and a program's with its image | the session's pipe server, and the port driver for a program ([design-programs.md](design-programs.md#a-programs-end)) | the neighbouring stages see the end of the stream or a broken pipe; `$status` lists the crash or the signal |

**Diagnostics.** `jobs` lists each job's stages, programs and state; the
inspector shows the session's processes and its programs as ports under
the session; a stage's crash reason, cut at 256 bytes, is its `$status`.

## Security

The command shell runs with the session's authority, bounded at 4 KiB
and depth 256 a unit of source, which the evaluator parses in a child
process with a fixed heap, and by its processes' heap limit, with fuzz targets
for its parser and for `grep`'s pattern translator. Each program it starts holds
only the descriptors, grants and rights its starter handed it, starts only
what `/bin` lists and only with the right to start commands, and reaches
the terminal only through the session's tty, which does not filter it, as
on UNIX ([design-programs.md](design-programs.md#security)). An Erlang
command's output reaches it the same way, and a line `grep` or `sort`
passes on reaches it as through `cat`; a name a source chose is escaped
by the command that prints it, `ls` at a terminal through the line escape
and `ps` everywhere through the field escape, as FreeBSD's `ls` and `ps`
escape theirs ([Pipelines](#pipelines), V9 of
[design-live.md](design-live.md#invariants)). A command acts only
through what it was handed, and one with less than the session's runs in
a domain of its own (SH1). An Erlang command run in the session's domain is
trusted session code: the context is its interface, not a boundary.

**Residual risks accepted.** The `erl` builtin evaluates any expression
with the session's authority, as the Erlang shell does. One allocation
larger than the session's free memory, which only a command's own code can
ask for, can end the session, as any trusted session code can (SH2).

## Verification and testing

Catalog checks cover metadata/callback mismatches, duplicate names,
the existing precedence, absent required facets, and live-loaded metadata refused
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
  scripts; `make setup` runs it, and `make check` runs it again when the
  build is missing or older than its recipe or pin. `Erx::RcOracle` runs
  a script with a fixed `$path` and `$home`, an empty private working directory, standard input at end
  of file and a deadline, returning its output and final `$status`, or
  saying it timed out or gave no status, never guessing one.
  Every script of the shell's test corpus runs under both, and their
  output and `$status` are compared; each difference is a bug, a
  documented difference with a test (the interactive layer, `within`), or an upstream bug recorded as such. A script that
  stops at a syntax error is compared by the diagnostic's message alone,
  since rc names the file and line (`rc: FILE:LINE: message`) and the
  shell the line and column; both set `$status` to the message. The
  corpus calls
  only rc's builtins and toybox's applets, which the test also builds for
  the host and puts first in plan9port rc's `$path`, so both shells run
  the same commands; it starts from plan9port's own `test.rc` and its
  parser checks, and from the `trip.rc` of Byron Rakitzis's rc (zlib),
  with the cases for that implementation's extensions set apart. The
  tokenizer and parser have a fuzz target that checks the 4 KiB bound on
  a unit both ways and the depth-256 bound, and a sweep parses each costly
  shape at the unit bound within half the parse process's heap.
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
* **`Ctrl-T`** ([`Ctrl-T`](#ctrl-t-status-and-the-info-request)). Each case
  is paired with a seeded fault that makes it fail:
  * `erx_tty`'s exploration: `VSTATUS` with `ISIG`, `ICANON` and `IEXTEN`
    set gives `info`, echoes nothing and keeps the partial line; with any
    of the three clear, it is an ordinary byte. The same cases run
    differentially against a host pseudo-terminal with `NOKERNINFO` set,
    since macOS's tty takes `VSTATUS` as FreeBSD's does. Dropping the
    `IEXTEN` condition, or echoing the key, fails the test.
  * `status/3`: a leading newline at a column other than 0, and nothing
    when there is less than 256 bytes of room. Removing either rule fails
    the test.
  * `erx_tty_info`: the choice of member, checked exhaustively over small
    sets of members against a model of the five rules; swapping rules 1
    and 2 fails. Golden lines in which every value is known, and lines in
    which each field in turn is `unknown`, `partial`, `timeout` and
    `unsupported`: a lettered field is left out, and `NAME` and `STATE`
    print `-` and `[-]`. A formatter that prints a missing value as 0,
    or prints a status token, fails. A name
    and a state that hold `ESC ] 8 ;`, a newline and a bidirectional
    override reach the master only as tokens; bypassing the line escape
    fails.
  * The job table: `info/1` gives the line's tag, both tags while the line
    waits in `fg`, and `[]` with no line. Returning only the line's tag
    fails the `fg` case.
  * Erlang commands: `cp` of a large file from a test server that delays
    each piece. `Ctrl-T` shows the line naming `cp`, then `cp`'s
    `from -> to  N%`, in that order. A helper process that did not opt in
    keeps an empty queue. A `cp` that does not call `catch_info`, and a
    report that sends the requests before it writes the line, each fail.
  * Programs: FreeBSD's `sleep`, built as a test program, shows the line
    naming `sleep` and its process id, then its own report. A program that
    does not catch `SIGINFO` runs on. With `NOKERNINFO` set, only `sleep`'s
    report appears. Making `SIGINFO`'s default action end the program
    fails the second case.
  * The prompt and `erl`: `Ctrl-T` transposes two characters and prints no
    line. A console that maps the key to `info` while the shell's own line
    is being read fails.
  * `kill -INFO %1` delivers the request and prints no line.
  * FreeBSD as the oracle: the FreeBSD 15.1 oracle guest
    ([design-network-stack.md](design-network-stack.md)) runs `sleep 30`,
    `cp` of a large file and `cat | cat` on a pseudo-terminal driven by the
    harness, sends `^T` mid-line and at column 0, and records each line.
    The same commands on erXos give lines of the same shape, compared with
    every number masked: the same fields, the
    two spaces before `cmd:`, the leading newline, and the same no-job
    texts. `cp`'s and `sleep`'s own reports match byte for byte once the
    numbers are masked. A one-space separator fails the comparison.
* **`rc` as a program:** `system` and `popen` from a C program, with
  `$status` mapped to wait statuses for an empty status, a number, a
  signal's name and an error's text, and for pipelines of one, two and
  three stages that all succeed, which exit 0, and that fail in the first,
  the last or every stage; an `rc -c` that runs `ps`, which lists
  processes only when `rc` was handed the `inspect` right, and one that
  names `erl`, which finds none; `rc` narrowed without `/bin`, which
  starts nothing; each line of the porting table run under `rc` with the
  result its sh form gives under the host's `/bin/sh`.
* **Text commands against FreeBSD** ([Text commands](#text-commands),
  S-R4). Each case is paired with a seeded fault that makes it fail:
  * The oracle: the FreeBSD 15.1 oracle guest
    ([design-network-stack.md](design-network-stack.md)) runs each case
    of the commands' corpus with `LC_ALL=C` over the same input files,
    and erXos's output, standard error and exit status must match it
    byte for byte. The corpus covers each option each command offers,
    alone and combined: `grep` with basic, extended and fixed patterns,
    `-r` over a tree, a match and no match for the status, and a pattern
    `regcomp(3)` refuses; `sort` with keys, `-n` over numbers, words, a
    header line and `-`, `-r`, `-u` and a last line without a newline;
    `wc` of one file and several; `ls` and `ls -l` of a file, a
    directory and several of each. Seeded: a `sort -n` that orders a
    non-number apart from zero, a `grep` that exits 0 on no match, and
    an `ls` that heads a single directory, each fail.
  * `ps` and `ls` at a terminal and in a pipe: `ps` and `ls` through
    `cat` write the pipe's layout and `ls` at a terminal its columns,
    checked against the guest on a pseudo-terminal and in a pipe; an
    `ls` that ignores `erx_cmd:isatty/2` fails. `ps` lines compare with
    every number masked, and `-r`, `-m` and `-o` with a fixed process
    table of the host test build, so the order is exact.
  * Missing values (SH3): `ps -o pid,state,time,pcpu,rss,comm` over a
    process table in which each value in turn is `unknown`, `partial`,
    `timeout` and `unsupported` prints `-` in that column and keeps every
    row's column count; `ps -r` puts the rows without `pcpu` last, in the
    default order. A formatter that prints 0, or that drops the column,
    fails.
  * Names: a file name and a process name holding `ESC ] 8 ;`, a tab, a
    newline and a bidirectional override; `ls` at a terminal shows tokens
    and through `cat` the bytes, `ps` shows the field escape both ways.
    Bypassing either escape fails.
  * Between Erlang stages: `cat` of a 1 GiB file into `grep -q .` ends
    `cat` with `sigpipe` once `grep` has stopped; a
    writer of 1 MiB to a reader that never reads holds at most 64 KiB in
    flight; a 1 GiB line without a newline into `grep` fails that stage
    with `line too long`. A writer that sends without waiting fails the
    second case.
  * `uname`: each flag alone, and the nine field flags in every order,
    write their fields in FreeBSD's order, `-a` writes five, the version
    is its four words and the date macOS's layout, a field the running
    system cannot tell writes `unknown`, a runtime given a node name but
    no distribution finds its host, a build fact passes the field escape,
    and `-U`, an unknown flag and an argument are usage errors; the build
    facts' reader refuses every malformed file whole, and the build
    refuses to write a fact of the wrong shape; the production image's
    boot runs `uname -a`, `uname -i` and `uname -K` at the command shell
    and matches the name, the manifest's host, the revision, the date,
    `qemu-virt/development`, the kernel and the machine type. A selection
    in the order of the flags fails.
  * `ifconfig` and `ping`: ifconfig writes an interface in FreeBSD's
    layout, flags, netmask in hex and broadcast included, selects one by
    name, refuses an unknown one, and takes a configuring argument or a
    bad flag as a usage error; ping's options and their diagnostics are
    FreeBSD's, and its pure core counts a reply only for a sequence
    number it sent and remembers, marks and counts a duplicate, takes
    each round-trip time from its own send record, never from the
    reply's data, and writes FreeBSD's reply lines and statistics; the
    network device suite runs `ifconfig` and
    `ping -c 3 10.0.2.2` at the command shell on QEMU and matches vtnet0
    with slirp's lease, three replies and no loss. Matching a reply of
    any sequence number fails.
  * `grep`'s translator: every construct of POSIX basic and extended
    expressions against a table of `regcomp(3)` results taken from the
    guest; a pattern built to backtrack ends with status 2 within the
    match limit; the translator's fuzz target, with its 4 KiB bound
    checked both ways. A translator that passes `\d` through to `re`
    fails the table.
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
microseconds, a write between two Erlang stages is one message, and
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
program; it loses because a shell in Erlang runs Erlang commands in the
session's domain without a process per stage, and reaches the inspector,
tracing and the code store directly.

**Records between Erlang stages.** Erlang commands could pass the
inspector's values to each other, each with its status, and filter them
with a predicate language of their own. It loses. It makes two kinds of
pipe, and at every edge where a record meets a file, a program or the
terminal it needs a renderer, a framing that keeps a record one line, a
reader that turns lines back into records, a mark that tells a line read
as bytes from text a source chose, and a predicate grammar with its own
bounds and fuzz target. The record commands then behave like no UNIX
command and combine with programs only through that edge, against
principle 5 of [design.md](design.md). Live values with their statuses
are what the Erlang shell and the inspector already give, one `erl`
away ([design-live.md](design-live.md#inspection)).

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
| Users expect POSIX shell syntax | high | friction at first use | the Erlang shell and rc's short manual are one `erl` and one `help` away; a tcsh-compatible shell is in the roadmap |
| rc's oracle and the shell disagree where rc's behaviour is unspecified | medium | test noise | each difference is classified once and pinned by a test |
| The relay's single path for terminal writes serialises a job's output through one process | low | a job of many chatty programs is bounded by the relay's throughput | the relay handles at most 4 KiB unanswered and the console is the bottleneck anyway; `tools/erx bench pipe` with a pipeline writing to the terminal |

Its language, its editing and its toolbox are the user's decisions, and a
shell compatible with tcsh is a roadmap item
([plan.md](plan.md#beyond-the-plan)). For `Ctrl-T`, the line adds no
stacks, as FreeBSD's does only with `kern.tty_info_kstacks`: `erx:source/1`
and the inspector already show where a process is. `cat` does not answer
the info request, as FreeBSD's does not catch `SIGINFO`; `cp`, `rm` and
`wc` answer.

Open decisions, each with a recommendation:

* **`pcpu` for a program.** FreeBSD's `%CPU` is a decayed average of
  recent use, which neither the kernel nor the command server keeps.
  `ps` prints a program's CPU time over the time since it started,
  which POSIX allows, since it leaves "recently" unspecified, and which
  makes `ps -r` useful at once. Recommended: keep it, and add a decayed
  average only if users find the lifetime figure misleading.
* **Which processes plain `ps` lists.** FreeBSD's `ps` lists only the
  user's processes that have a terminal unless `-x` is given. erXos's
  lists the session's whole process table, its services included, and
  offers no `-x`. Recommended: keep the whole table until the list
  proves too long in use, then add FreeBSD's default and `-x` together.
* **The terminal's name in `TT`.** The session's tty needs a device name
  that `tty(1)` prints and `ps` abbreviates; no design names one yet.
  The session's own tty is a pseudo-terminal whose master is the
  console ([design-programs.md](design-programs.md#the-terminal)).
  Recommended: name it `/dev/pts/0` in the session's export, as the
  second tier names the pseudo-terminals a program makes, so `TT`
  prints `0` as on FreeBSD.
* **Presentations from text commands.** The inspector's values carry
  presentation links at a terminal that declares them
  ([design-display.md](design-display.md#presentations)); FreeBSD's
  `ps` and `ls` print none. Recommended: text commands print none, so
  their bytes match FreeBSD's at a terminal too; a clickable pid comes
  from `erx:ps()` and the inspector.

## References

* T. Duff, "Rc - The Plan 9 Shell", Plan 9 Programmer's Manual, AT&T
  Bell Laboratories, 1990; plan9port at `1f139691`, Byron Rakitzis's rc
  and tcsh, as checked in
  [research-boards-storage.md](research-boards-storage.md#the-command-shells-oracle).
* Erlang/OTP 29.1.2: `lib/stdlib/src/edlin.erl`, the line editor whose
  editing, history and expansion hook the shell uses.
