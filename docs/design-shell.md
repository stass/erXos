# The command shell

Each session can run a **command shell** beside its Erlang shell: erXos's
own, written in Erlang, speaking the language of rc, Plan 9's shell. Builtins, Erlang commands and programs share one
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

The decisions that shape it: rc's language, with one quoting rule, list
variables and no rescanning, and emacs-style editing and job control
added ([The language](#the-language)); one command namespace
([Commands](#commands)); text in every pipe, each command behaving like
FreeBSD 15.1's of the same name and printing a value it cannot measure as
FreeBSD prints a missing one ([Pipelines](#pipelines), SH3); capabilities,
not command kinds, with a command handed fewer than the session's run in
a domain of its own (SH1); and job control by pauses, so the terminal
relay never waits on a program ([Job control](#job-control)).

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
 | command server (pid 1): process ids and the      |  |   channel to |
 | process table; handlers; the port driver         |  |   handler)   |
 +--------------------------------------------------+  +--------------+
```

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **SH1.** A command acts only through the capabilities it was handed, and one handed fewer than the session's runs in a domain of its own | an Erlang command receives its grants and facets in its context and reaches services only through them; the shell's own lines run in the session's domain with the session's capabilities, since that is what the user typed them with; a command that `within` narrows, and every Erlang command a program starts, runs in a command domain built from exactly the capabilities its starter named, which its starter held, and named from its principal's pool of reusable names ([design-system.md](design-system.md#identifiers)), each facet among them made by the system domain for that domain alone and with no wider scope, and a program runs in a sub-space whose handler acts only on the program's own table ([design-programs.md](design-programs.md#what-a-program-can-start), [design-programs.md](design-programs.md#facets)); a handler never runs a builtin or a function for a program | a command that reaches a service by a registered name of the system domain; a narrowed or program-started command run in the session's domain; a domain given a capability its starter did not hold | a test that every command run in a session without an inspect facet gets `no_facet`, which `top` prints as `[no inspect facet]` beside each figure; a test that a command domain's capabilities are exactly the grants and facets named before its startup message; `xargs ps` from a program with and without the `inspect` right, and a command domain that asks for the session's own facet instead of its own, which is refused; a narrowed program that asks its handler for every name of the command namespace in turn starts only what `/bin` lists and reaches nothing outside its grants; the command-needs build check, which refuses a command that names a module of a service of the system domain, or a path under the point where `erx_ns` mounts the service's tree, without declaring its facet, and a module of the command shell that names one and is no command |
| **SH2.** A failing line, stage or command never ends the session | each stage, substitution and background block is an Erlang process of its own with `max_heap_size` set, counting the binaries it references; every input that reaches a stage is bounded in bytes, a line a command reads at 64 KiB and the bytes in flight between two Erlang stages at 64 KiB, so no input makes a stage grow without bound; every evaluator's Erlang stages are admitted whole within the session's stage allowance, an eighth of its budget, within the half the session keeps for its own services and from which no program's budget is carved ([design-system.md](design-system.md#resource-policy)), and only a foreground line waits for it, so stages together stay within memory the session keeps for them and no evaluator waits for an allowance its own parent holds; the parser, in a child process of the evaluator with a fixed heap, refuses a unit over its bounds before it runs; a program is a sub-space with a budget of its own, carved from the other half, so what it spends never counts against a stage | a stage evaluated in the shell's own process; an unbounded parse; an input path without a byte bound; stages admitted beyond the allowance; a nested evaluator that waits for the allowance; a program's budget carved from the services' half | the overflow, deep-nesting and runaway-recursion tests; a native program that writes a 1 GiB line without a newline into an Erlang stage, which fails that stage alone; as many stages as the allowance admits, each near its limit, and one more pipeline, which waits; a substitution inside a fully admitted pipeline, and a background job beyond the allowance, each of which fails with `too many stages` at once; a loop of programs that spends the programs' half, during which the shell still parses, prompts and runs builtins; the parser's fuzz target |
| **SH3.** No command prints a value it does not have | a command formats a value only when its reader returned it with the status `ok`; any other value prints as FreeBSD prints a missing one, `-` in a column and nothing for a field labelled by its own letter ([Pipelines](#pipelines)); the one exception is `top`'s header, where a partial figure prints its number with its reporter named, in the line's label or after the figure, and a missing one prints `-` with why in brackets ([Text commands](#text-commands)) | a formatter that prints 0, an old value or a guess for a missing one; a partial figure of `top`'s header without its reporter named | `ps`'s and the `Ctrl-T` line's tests with each value in turn `unknown`, `partial`, `timeout` and `unsupported`, where a formatter that prints 0 fails; `top`'s header tests with each figure in turn `ok`, `partial` under one and several reporters, `unknown`, `timeout`, `unsupported` and `error`, where a partial figure printed without its reporter named fails ([design-live.md](design-live.md#invariants) V2) |

## Data model

The shell's state is a few Erlang terms in the session's domain:

```erlang
-type command() :: {function, binary()}       % defined with fn
                 | {builtin, atom()}          % rc's and erXos's builtins
                 | {erlang, erx_cmd:entry()}  % metadata and a version-bound local fun
                 | {program, binary()}.       % a program command, in /bin
-type job() :: #{id := pos_integer(),         % %N
                 stages := [pid()],           % the job's Erlang processes
                 tag := erx_job:tag(),        % carried by its Erlang processes
                 termios := erx_tty:termios() | none,
                                              % what the job left when a stop last
                                              % took the terminal from it, for its fg
                 state := foreground | background | stopped()}.
-type stopped() :: {stopped, [{pid(), reference()}]}.
                                              % each requester its stop owes a reply,
                                              % with the reference the reply carries
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
The shell's job table keeps the jobs. The replies a stop owes live only in
its `stopped()` state, so leaving that state is the one place they are
given ([Job control](#job-control), "A stop keeps its answers"). A
job's programs are the rows of
the command server's process table that carry its job tag, each
recorded at its spawn, so neither keeps the other's facts
([design-programs.md](design-programs.md#the-command-server)). What flows
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
  namespace; `$status`, `$*`, `$home`, the session's home, where an
  interactive shell starts ([design-files.md](design-files.md#building-binding-and-mounting),
  "A user's home"), `$prompt`, and `$pid` and `$apid`,
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
  and every Erlang process it started, and the shell reads on, once the
  line's job is over, with the variables it had before it and `$status`
  saying the line was interrupted; `Ctrl-C`
  while a line is typed drops the unit read so far. A foreground line is
  a job, which is over when its evaluator and its programs have all
  ended ([Job control](#job-control)). A unit that does not
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
  ([Pipelines](#pipelines)). A command that needs more, as `vi` does for
  its buffer, declares a larger heap, at most 16 MiB, and its stage grows
  to it when the command starts ([Pipelines](#pipelines)).
* **What rc does that erXos cannot.** `exec` and `rfork` fail with a
  diagnostic, since the shell has no image to replace and no process to
  fork; `fn sigint` runs when the shell itself is interrupted, as in rc,
  but `fn sighup` never runs, since a hangup ends every shell on its tty
  at once ([The terminal relay's protocol](#the-terminal-relays-protocol));
  a list variable reaches a program's environment with its elements
  joined by U+0001, as
  plan9port's rc exports lists, and programs get `PATH=/bin`.
* **An escape to Erlang.** The builtin `erl EXPR` evaluates an Erlang
  expression in the session's evaluator and prints its value; the Erlang
  shell itself is one `erl` away: with no argument, `erl` runs the Erlang
  shell on the terminal above the command shell until that shell ends.
* **Authority.** The shell runs inside the session's domain with that
  domain's authority and facets, and nothing more; neither the shell nor
  any command has authority of its own (SH1). `mount` and `umount`
  change the session domain's namespace, which every shell and
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
   `date`, `dmesg`, `true` and `false`, which follow FreeBSD's utilities of the same names
   ([Text commands](#text-commands)), so toybox's applets of those names
   are never built; the screen editor `vi`, which behaves like FreeBSD's
   nvi in its basics ([design-vi.md](design-vi.md)), so toybox's `vi` is
   never built either; the network utilities `ifconfig [-a] [interface]`,
   `ping` and `host`, which follow FreeBSD's ifconfig(8), ping(8) and
   host(1) over erXos's own stack, and `ntpctl`, after OpenBSD's
   ntpctl(8), reading interfaces through
   `erx_net:interfaces/0`, echo replies through `erx_icmp_sock` and
   names through `inet_res`
   ([design-network-stack.md](design-network-stack.md)); `reboot` and
   `halt`, which follow FreeBSD's reboot(8), need the `machine` grant and
   write one end to `/machine/ctl`
   ([design-system.md](design-system.md#a-sessions-request)); and erXos's own `i`, `domains`, `source`, `trace`,
   `attach`, `mount` and `umount` ([Interfaces](#interfaces)), and `load`, which loads code
   into a domain through the session's install or code facet
   ([design-live.md](design-live.md#one-load-three-routes)), none of
   which has a FreeBSD counterpart;
3. a **program command**: one of toybox's applets or another program of
   the boot image, each of which the session's export also lists in
   `/bin` ([design-programs.md](design-programs.md#what-a-program-can-start)).

`reboot` and `halt` are one module under two names, as FreeBSD's halt is
a link to reboot, and the name picks the end: `reboot` resets the
machine and `halt` powers it off, since erXos has no end that halts
without turning the machine off. `reboot -p` powers off too. `-q` and
`-l` are accepted and ask for the same end: the ordered end stops no
service, so there is nothing for `-q` to skip, and its log line,
`rebooted by P` or `powered off by P` at `critical`, is the system's,
one per end whoever asked. Every other flag of FreeBSD's command is a
usage error. Either command asks for the ordered end of
[design-system.md](design-system.md#shutting-down), which says who may
ask for it; a command whose request is refused prints `reboot: ` (or
`halt: `) and the error's text, as FreeBSD's `err(1, NULL)` does, and
fails.

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
another error; a crash is an error whose diagnostic and status say only
`crashed`, or `killed` past its heap limit, since its reason may carry
the shell's variables. A
command declares the facets it uses (`-erx_needs([inspect])`), so one run
without them fails with `no_facet` before it starts, and its help says
what it needs. The shell reads the session's facets for each command,
never once at its start: a grant to a session may arrive after the shell
starts, when its server comes up later or restarts. A facet installed
meanwhile serves the next command; until then a command that needs it
fails with `no_facet`.

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

* between two processes of the session's domain, two Erlang commands or
  an SSH job's relay and its `rc`, each write is one message holding its
  bytes, with at most 64 KiB in flight to the reader, the size of a
  pipe's first ring
  ([design-pipes.md](design-pipes.md#the-objects-of-a-pipe)); the reader
  sees the end of the stream once every writer has closed its end or
  ended and every write has been read, and a writer whose reader has
  ended stops with the status `sigpipe`, as a program would;
* wherever a program takes part, the stages are joined by pipes
  ([design-pipes.md](design-pipes.md)); the session's pipe server makes
  each end for the stage that uses it, so every end has one holder and
  the session knows them all
  ([design-pipes.md](design-pipes.md#making-a-pipe));
* a redirection hands a stage a file the shell opened, and a stream with
  neither a pipe nor a redirection is the session's terminal: an open of
  the session's tty, which the terminal relay serves for an Erlang
  command as it serves a program's ([Job control](#job-control)), so a
  command reads the terminal, sets its modes and asks its size
  through it ([Interfaces](#interfaces)). In an SSH job, which has no
  terminal, such a stream is the job's own ([rc as a
  program](#rc-as-a-program)). The system shell's terminal
  is the console's, which runs no line discipline
  ([design-live.md](design-live.md#the-tty)): there a command's output
  streams are the console's writes and its standard input is empty.

A command reads its standard input through `erx_cmd` alone, whatever is
at the other end ([Interfaces](#interfaces)). `io`'s input functions are
no route to it: the command's group leader is the command shell's group,
which answers them `{error, enotsup}`
([The terminal relay's protocol](#the-terminal-relays-protocol)).

A command's output is bytes, as a program's is, and the tty passes it
unchanged ([The tty](design-live.md#the-tty)). Where FreeBSD's command
looks at whether its output is a terminal, as `ls` does to choose columns
and to hide characters that do not print, the Erlang command asks
`erx_cmd:isatty/2`; nothing else in a command depends on what is at the
other end. The answer is the same in the session's domain and in a
command domain, whose startup message names a stream that is the
terminal `{relayed, write, tty}`
([design-programs.md](design-programs.md#what-a-program-can-start)), so
a script's `ls` hides a hostile file name's escape sequences there too. So Erlang commands, programs, files and the terminal combine
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
number with its reporter named, `Mem (root pool): 118M Total, 74M Free` ([Text commands](#text-commands)).

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

**A command's heap.** A command module may declare a larger heap than the
default with `-erx_heap(MiB)`, beside its `-erx_needs` declaration, `MiB` a
whole number from 5 to 16; `vi` declares 16
([design-vi.md](design-vi.md#bounds)). The release build reads it with the
command's other metadata and refuses any other value, as a live load of
a command module does
([design-generation.md](design-generation.md#configuration-and-command-catalogs)),
so the catalog entry carries a figure already checked and nothing checks
it again. A command starts in a stage admitted at the default; when its
entry declares more, the command's start, the one place where the shell
checks an entry's binding before invoking it, takes the difference from
the stage allowance and raises the stage's `max_heap_size` to the
declared figure before `run/2` runs. That growth is admitted at once or
the command fails with `too many stages`; it never waits, since the
stages it would wait for may be the command's own pipeline. Since the
growth is made at the command's start, a function or a computed name
that runs `vi` gets its heap as a literal `vi` does; the stage gives the
whole figure back when it ends. 16 MiB is half the
stage allowance at the default budget, so an editor and an ordinary
pipeline fit beside each other.

### Text commands

The Erlang commands named like FreeBSD utilities offer a small core of
each utility's options, enough for the common idioms, and behave as
FreeBSD 15.1's do for those: the same bytes on standard output, FreeBSD's
diagnostics on standard error, as `NAME: ...`, and FreeBSD's exit
statuses (S-R4). An option a command does not offer is a usage error;
more options are later additions, each with its oracle test. Text
compares as bytes, as FreeBSD's tools compare it under `LC_ALL=C`, the
locale the oracle runs in. `ps`, `top` and `ls`, below, show the session's
processes and files; `cat`,
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

**`ps`** lists the session's own process table: its Erlang processes and
its programs, the latter from the command server's process table and
each program's handler
([design-programs.md](design-programs.md#the-command-server)), so a session sees
its programs without an inspect facet, as a UNIX user sees their own
processes. It prints FreeBSD's default columns, `PID`, `TT`, `STAT`,
`TIME` and `COMMAND` (`bin/ps/ps.c:156`), under FreeBSD's header line,
and cuts the last column at the terminal's width when its output is a
terminal, as FreeBSD's does (`bin/ps/ps.c:748-755`). `-o` takes a
comma-separated list of FreeBSD's keywords in place of the default
columns: `pid`, `tt`, `state` (or `stat`), `time`, `pcpu` (or `%cpu`),
`rss`, `comm` and `command` (or `args`). An unknown keyword is reported
as `ps: KEY: keyword not found` and left out, and `ps` ends with status 1,
as FreeBSD's does (`bin/ps/keyword.c:440-444`). Each column, for the two
kinds of process:

| Keyword (header) | An Erlang process | A program |
| --- | --- | --- |
| `pid` (`PID`) | its pid, `<D.N.S>` | its process id |
| `tt` (`TT`) | the terminal of the session's tty whose group is its group leader, else `-` | its controlling terminal: the terminal of the session's tty its job was started on, while it holds an open of that tty, else `-` |
| `state` (`STAT`) | `R` when running, runnable or collecting garbage; `S` when waiting in `receive`; `T` when its job is stopped; `RE` when exiting; then `+` when it belongs to the foreground job | `R` when a thread runs or is runnable, `S` when every thread waits, `T` when paused; then `+` when it belongs to the foreground job |
| `time` (`TIME`) | `-`: the runtime keeps no CPU time per process | its group's CPU time as `getrusage` reports it, as `M:SS.hh` (`bin/ps/print.c:500-520`) |
| `pcpu` (`%CPU`) | `-`, for the same reason | its CPU time over the time since it started, as a percentage to one decimal |
| `rss` (`RSS`) | its memory as `process_info/2` reports it, in KiB, rounded up | its sub-space's charges, in KiB |
| `comm` (`COMMAND`) | its registered name, else its `proc_lib` label, else the function it started in, as the `Ctrl-T` line names it | its name |
| `command` (`COMMAND`) | as `comm` | its arguments, joined by spaces |

The terminal's name is abbreviated as FreeBSD abbreviates it
(`bin/ps/print.c:345-364`). A value the session's table does not have,
because the reporter could not answer, answered late or the process ended
while it was read, prints `-` in its column, as FreeBSD's `ps` prints a
column with no value (`bin/ps/ps.c:757-759`); so does a value erXos does
not measure at all, such as an Erlang process's CPU time. No column ever
shows a number for a value it does not have, and every row keeps its
columns, so `ps -o pid,pcpu,comm | sort -rn -k2 | head` works as on
FreeBSD: the header and the rows without a value sort among the zeros. A
process's name and arguments are written through the field escape, as
FreeBSD writes them through `strvis(3)`
([Pipelines](#pipelines)).

Rows come in FreeBSD's default order: processes without a terminal
first, then by `PID`, programs by their process ids and then Erlang
processes by the numbers of their pids. `-r` orders by `pcpu` and `-m` by
`rss`, largest first, as FreeBSD's `-r` and `-m` do
(`bin/ps/ps.c:1394-1419`); rows with equal values keep the default order.
A row with no value for the key comes after every row that has one, still
in the default order, which is where FreeBSD's `ps`, which counts a
`%CPU` it cannot read as zero (`bin/ps/print.c:622-634`), puts it. So `ps -r` lists a session's
busiest programs first and its Erlang processes after them; the busiest
Erlang processes, by reductions, are `erx:ps()`'s to show. FreeBSD's `-m`
orders by text, data and stack size, which erXos does not split, so its
`-m` orders by the memory `rss` shows.

**`top [-bn] [-d count] [-s time] [number]`** shows the table `ps` reads
as FreeBSD's `top` (`usr.bin/top`) shows a machine's, display after
display. A display is a header and a process table. The header has
FreeBSD's lines where they map, each figure read through the
session's inspect facet, at its scope
([System values](design-live.md#system-values-one-tree-many-views)):

* `run queue: 0;  up 0+00:05:12    10:15:37`: the run queue of the
  domain `top` runs in (its domain record's `run_queue`, the processes
  and ports its runtime has ready and waiting for a scheduler), where FreeBSD's first line
  has the last pid and the load averages; then the machine's `uptime` as
  FreeBSD's `i_uptime()` writes it, `D+HH:MM:SS`, and the time of day,
  last, so a terminal narrower than the line cuts it, where FreeBSD's
  screen keeps it at the right edge. The
  run queue is an instant's count of one runtime and is labelled as
  such, never as a load average, which erXos does not keep.
* A count of the processes and of those running, sleeping and stopped,
  `57 processes:  2 running, 55 sleeping`, from the `STAT` `ps` shows
  (`R`, `S`, `T`).
* `Mem: 1906M Total, 1500M Free`: the machine's `memory_total` and
  `memory_free`, as FreeBSD's `format_k()` writes a size.
* `Domain 4 budget: 812K Used, 1024M Guarantee, 2048M Cap`: the `used`,
  `guarantee` and `cap` of the budget of the domain `top` runs in,
  labelled as that domain's, so a figure of one domain never reads as
  the machine's. The domain is the one the inspector names for `top`'s
  own process.

A figure the inspector answers `ok` prints its number. A partial
figure prints its number with its reporter named by the inspection
schema's label, through the line escape: when every number of a line
is partial under one reporter, the line's label names it once, and
otherwise each partial figure names its own after it, so an `ok`
number beside it never reads as partial. On the Fiasco kernel the
memory figures and `used` are the `liberx` pool's partial counts, so
the header reads `Mem (root pool): 118M Total, 74M Free` and `Domain
4 budget (root pool): 44M Used, - Guarantee [unsupported], - Cap
[unsupported]`; on erXos's
kernel, which reports them whole, it reads `Mem: 118M Total, 74M
Free`. A line with partial figures of two reporters reads `Mem: 118M
Total (kernel), 74M Free (root pool)`. Any other figure prints `-`
and says why in brackets: its status as `erx_render` writes it
(`[unknown]`, `[unsupported]`, `[timeout 500]`, `[error]`), `[not
reported]` for a figure its record does not hold, or the inspector's
refusal of its path, `[not in scope]`, `[no inspect facet]`,
`[inspector busy]` or `[failed]`. When every figure of a line is
missing for one reason, the line's label says it once, `Domain 8
budget [not in scope]: - Used, - Guarantee, - Cap`. So the header
never shows as exact a number nobody reported whole, and no `-` hides
why it is there. Naming a reporter and a reason is the
header's alone, the one exception to the command shell's rule for
values it does not have
(SH3): the header's
figures are rounded for a person to read, while a column of the
table, like `ps`'s, keeps `-`, since a stage of a pipeline reads a
column's number with nothing to say it is partial. The table has the
columns of FreeBSD's that
the table has values for: `PID`, `RES` (`rss`, as FreeBSD's
`format_k()` writes a size, at most four digits and a unit), `STATE`
(`RUN`, `SLEEP` or `STOP`), `TIME` (`time`, as FreeBSD's
`format_time()` writes it, `M:SS`), `WCPU` and `COMMAND` (`comm`,
through the field escape as `ps` writes it). FreeBSD's
`USERNAME`, `THR`, `PRI`, `NICE`, `SIZE` and `C` are left out: every row
is the session's own, and the rest have no value for an Erlang process.
A row's `WCPU` is its share of a CPU over the last interval: the growth
of its CPU time from the previous display's sample to this one, over the
time between them, as a percentage to two decimals. For a process the
previous display did not have, and on the first display, it is `pcpu`,
its share since it started. FreeBSD's kernel keeps a decaying average
for `WCPU`; erXos keeps none, and two samples give a recent share without
one. A value the table lacks prints `-`, so an Erlang process's `TIME`
and `WCPU` do. Rows are ordered by `WCPU`, largest first, and the rows
without one follow in `ps`'s order, as under `ps -r`.

At a terminal, without `-b` or `-n`, `top` starts each display with the
terminal's home and clear sequences, written as its own output, and
shows one every `time` seconds (`-s`, 2 by default) until it has shown
`count` (`-d`, no limit by default) or `Ctrl-C` ends it, as it ends any
command. `time` is a decimal number with an optional fraction, as
`strtod(3)` reads one without an exponent, taken to the whole
millisecond and at least 1 ms. It changes no terminal state, no mode,
scrolling region or alternate screen, so an interrupt at any point
leaves nothing to restore. The table has as many rows as fit the
terminal's height under the header, with the last line left for the
cursor so that nothing scrolls on a terminal of five lines or more:
`LINES` when it is a positive number, as FreeBSD's termcap takes it,
else the height the terminal reports, else 24. Each line is cut one column short of the terminal's width, as
FreeBSD's screen is (`usr.bin/top/screen.c`), and never inside a UTF-8
sequence. `top` takes no keys, so `Ctrl-C` ends it as it ends any
command. FreeBSD's interactive commands, `q` among them, read the keyboard
in the line discipline's non-canonical mode, which an Erlang command sets
through `erx_cmd:tty/2` as `vi` does
([design-vi.md](design-vi.md)); `top` does not offer them.

With `-b` or `-n`, or when its output is not a terminal, `top` writes
`count` displays, one by default, each after the first following a blank
line, with no control sequence and nothing cut, and each shows at most
18 processes, FreeBSD's `Nominal_TOPN` for output it cannot draw on.
`number` caps the processes a display shows; `all`, `infinity`,
`maximum` or a prefix of one shows them all, as FreeBSD's `atoiwi()`
reads it. A `count` of 0 or none, a `time` that is not a positive number
and a negative `number` are each reported with FreeBSD's warning, such as
`top: warning: display count should be positive -- option ignored`, and
ignored, and `top` runs on; any other option is a usage error. A display
costs one read of the table, as `ps` does, and `top` sleeps between
displays, so it loads the session as one `ps` per `time` does.

**`ls [-1al] [file ...]`** lists a file by the name given and a directory
by the names it holds, sorted byte by byte, without those that start with
`.` unless `-a` is given, as FreeBSD's `ls` does. At a terminal it writes
the names in columns across the terminal's width, sorted down the
columns; elsewhere, or under `-1`, one name a line (`bin/ls/ls.c:247-256`).
With more than one operand, files come first, and each directory's names
follow an empty line and a line with its name and `:`. `-l`
writes FreeBSD's long format: a `total` line for each directory, then for
each name its mode, link count, owner, group, size, modification time
and name, the time as FreeBSD formats it, with the hour and minute for
a time within six months of now and the year otherwise. A value the file server does not report, such
as an owner on a file system that keeps none, prints `-` in its column,
so every line keeps its columns. A name is written through the line
escape at a terminal and as its bytes elsewhere
([Pipelines](#pipelines)).

**`dmesg [-a]`** writes the kernel's message buffer, as FreeBSD's
`dmesg` writes `kern.msgbuf`: erXos's buffer is the kernel log, and
`dmesg` writes `/proc/kernel/log` unchanged, its lines from the oldest
the ring still holds, each through the field escape, with `[missing N]`
where records are missing
([design-live.md](design-live.md#the-proc-tree)). `-a`, FreeBSD's
"syslog records and console output too", then writes the system log,
`/var/log/messages`, each line through the same escape
([design-log.md](design-log.md#interfaces)). `-c`, which clears the
buffer, is a usage error, since nothing in user space clears the kernel
log, as are `-M` and `-N`, which read a crash dump's buffer, and an
argument; the usage line is FreeBSD's, `usage: dmesg [-ac] [-M core [-N
system]]`. `dmesg` reads only what its namespace's `/proc` and
`/var/log` show, so it shows the kernel's lines only where the tree's
facet has scope `all`, and `-a` the system log only where the namespace
mounts `/var/log`; a file it cannot read fails as `cat` fails on it.

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
  hello show it, which init's `-erx_record build` gives every domain of the
  image; it plays the part of FreeBSD's `kern.build_id`;
* the source revision is the one the image was built from, in
  FreeBSD's `newvers.sh` form without its branch,
  `[n<count>-]<hash>[-dirty]`: the count of first-parent commits,
  left out in a shallow clone, the commit's first 12 hex digits, and
  `-dirty` when a tracked file differs from the commit or an untracked file
  that git's ignore rules do not exclude exists;
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
writes them into each release of the image, the system release and the
domain release, as a small file at `build_facts_path` of `abi/erx_abi.txt`
under the release's root, one `name value` line per fact, so every domain
shows the same facts; its receipt names
the code that writes it, as a compiled file's names its sources. Only the
commit's facts come from the build host. `erx_build` reads the file back,
refuses it whole unless every line is in its place with a value of its
field's shape, and `uname` writes each value through the field escape.

A value the command's domain cannot know is written `unknown`, as GNU's
`uname` writes a field it cannot tell: the host name of a runtime that is
not a node, the build identifier where init was given none, every build
fact of a hosted runtime, whose release has no such file, and
the revision and the date of an image built from a tree that is not a git
checkout. FreeBSD's `-U` (the userland's `__FreeBSD_version`) has no
erXos value and is not offered, nor are the `UNAME_x` environment
variables that override a field. The values are erXos's own, so the
FreeBSD oracle has
no `uname` case; its tests pin the order, the layout and the values.

**`date [-jnu] [[[[[cc]yy]mm]dd]HH]MM[.SS] [+format]`** writes the wall
time through a strftime(3) format, or sets it, as FreeBSD's `date` does,
in UTC, the only zone erXos has. Setting needs the `clock` grant, which
root's session holds; its forms, conversions and failure paths are
[design-time.md](design-time.md#setting-the-clock-by-hand)'s.

**`ntpctl step [server ...]`** sets the clock once, with the same
`clock` grant `date` uses, from the servers named or, with none named,
from ntpd's last sample, and says which; **`ntpctl -s status|peers`**
writes ntpd's own words from `/svc/ntpd/status`. Its sources, exchange, checks and
lines are
[design-time.md](design-time.md#setting-the-clock-from-a-server-once)'s.

**`ifconfig [-a] [interface]`** writes an interface in FreeBSD's layout,
flags, netmask in hex and broadcast included, selects one by name and
refuses an unknown one; a configuring argument or a bad flag is a usage
error. **`ping`** takes FreeBSD's options with their diagnostics and
writes FreeBSD's reply lines and statistics. Its pure core counts a reply
only for a sequence number it sent and remembers, marks and counts a
duplicate, and takes each round-trip time from its own send record, never
from the reply's data, since a reply is data any host on the path can
forge.

**`host name [server]`** looks a name or an address up in the DNS, as
FreeBSD's `host` does, through `inet_res` and the domain's name servers
([design-network-stack.md](design-network-stack.md#name-resolution)), or
only `server` when one is given, which a `Using domain server:` header
names. An address is looked up by its pointer name, a name for its A and
then its AAAA records, with the search list tried as `res_search(3)`
tries it. The lines are FreeBSD's: `has address`, `has IPv6 address`,
`is an alias for`, `domain name pointer`, `Host name not found:
3(NXDOMAIN)` and `;; connection timed out; no servers could be
reached`, a failure ending the command with a failure status. Every
name in a line comes from a reply any host on the path can forge, so
each passes the field escape.

### Starting programs

The stage that names a program starts it, as any session process does,
with `erx_prog_handler:start/1`, and its monitor of the program's
handler brings it the program's end; the command server gives the
program its process id and records it in the stage's job
([design-programs.md](design-programs.md#the-command-server)). The shell derives each
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
([design-programs.md](design-programs.md#the-terminal)). A stream that
is a message pipe, as between Erlang stages or in an SSH job, reaches a
program as a pipe of the pipe server whose other end the starter holds,
with a pump that feeds it from the message pipe or drains it into one,
so the program reads end of file when the message pipe ends and meets
`EPIPE` when its reader is gone.

### rc as a program

`rc` is also a program command, in `/bin` with toybox's applets, so a
program can run a script: `system` and `popen` run `rc -c` with their
command
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

* **On a tty.** `rc -c` on a tty's channel (an SSH exec) runs its command
  as one job, started as the command shell starts a job's evaluator, so
  every process the command starts, `&` jobs included, ends with it: at
  Ctrl-C, which ends it by `SIGINT`, as FreeBSD's `sh -c` dies of the
  signal, so the client hears SSH's `exit-signal`, not status 130
  ([design-ssh.md](design-ssh.md#sessions-ttys-and-shells)), at the
  tty's hangup, and when the command ends, as a UNIX session's processes
  end with its terminal.
* **In a job.** `rc -c` on a channel with no tty (an SSH exec without
  `-t`) runs its command as one job in the same way, with standard
  input, output and error on the job's message pipes, which the job's
  relay fills and drains, and the relay's group as its group leader; it ends
  when the command ends or at the channel's hangup
  ([design-ssh.md](design-ssh.md#sessions-ttys-and-shells)).

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
and `kill %N` sends a job `SIGTERM`, or the signal it names, which ends
the job only when that signal's default action is to terminate ("`kill`
of a job", below).

**The terminal relay** is the process of the session's domain that owns
the session's tty ([design-live.md](design-live.md#the-tty)) and serves
the session's `/dev/tty`: the opens that the session's programs hold on it,
their standard streams among them
([design-programs.md](design-programs.md#the-terminal)), and the opens that
are the terminal streams of the Erlang commands the session's own domain
runs. It holds the
`termios`, runs the line discipline, drives the group of the session's shell
and talks to the tty's master. It is the only process that reads terminal
input for programs and commands, it takes requests only through the
programs' handlers, which never wait on a program, and from the commands'
own opens, and it never waits on either itself, so a busy
or hostile program delays none of its work. A command domain holds no open
of the session's: its stream relay copies bytes
([design-programs.md](design-programs.md#what-a-program-can-start)) and
never reads the terminal, so a command there has no terminal to set or
read. Its messages, and the rule for who
holds the terminal, are [The terminal relay's
protocol](#the-terminal-relays-protocol):

* **Input.** Bytes from the master go through the line discipline into the
  tty, and wait there until a reader of the holder takes them: the console,
  for the shell's group, while the shell prompts, reading only when `edlin`
  wants a key, one byte at a time, and otherwise the foreground job, whose opens
  may compete, as on UNIX, with the relay serving their reads one at a time. In
  cooked mode the line discipline collects a line and the relay answers the
  foreground job's pending read with it, newline included, when the line
  ends. `Ctrl-D` at the start of a line answers that read with the end of
  file, which the command reads as the end of its input; its later reads go
  on, as on a UNIX terminal. The job's readers are its Erlang commands;
  its programs read the terminal only under the signal handshake of [A
  reader the signal ends](#the-terminal-relays-protocol). The relay
  handles input before output, so `Ctrl-C` and `Ctrl-Z` act however much
  output waits.
* **Output.** What any program writes to the terminal goes through the line
  discipline's output and to the master as `{tty_output, N, Bytes}`, in the
  order the writes arrive, so one program's output and error streams
  interleave as it wrote them and two programs' as they arrive. The relay
  holds at most 4 KiB for the master, `erx_tty:master_room/0`, the line
  discipline's one record of it, and a write takes only what room there
  is. The line discipline's echo takes the same room, and is dropped when
  there is none, as FreeBSD drops echo its output queue cannot take
  ([design-live.md](design-live.md#the-tty)). A program that writes faster than the terminal, or to a session that is
  not connected, waits for room with no request outstanding, so a signal
  interrupts it as on a UNIX terminal
  ([design-programs.md](design-programs.md#the-terminal)), and nothing piles up
  in the session. A background job's write goes through as well; `TOSTOP`
  comes with process groups, in the second tier, and follows POSIX there.
* **Interrupts.** With `ISIG`, `Ctrl-C` and `Ctrl-Z` reach the relay's
  line discipline as input. The tty discards the input and the output it
  holds at that moment, as a terminal flushes both on an interrupt, and
  the relay tells the holder: the shell, naming the job that holds the
  terminal, or at the prompt the console, which ends the line being
  edited. A job's reads take nothing from the key on until the shell has
  acted on it, so the keys typed after `Ctrl-C` wait in the tty for
  whoever reads next ([A signal suspends a job's
  input](#the-terminal-relays-protocol)). For `Ctrl-C`
  the shell asks the handler of every program of that job to send it
  `SIGINT` and ends the job's Erlang processes by marking its tag
  `{ending, interrupt}`; for `Ctrl-Z` it stops the job.
* **Size.** When the master reports a size that differs from the one the
  tty holds, the line discipline returns `winch`, and the relay passes it
  to the shell, which delivers it to the foreground job
  ([Window size](#window-size)).
* **Modes across jobs.** A foreground job starts with the session's
  cooked `termios`, a stopped job keeps its own for its `fg`, and the
  console takes the terminal back in its editing setting when the job ends
  or stops, as a UNIX shell does. Each of these changes is one
  `foreground` request, which hands the terminal over and sets the new
  holder's `termios` together. Each time the console takes the terminal
  back, the cooked `termios` takes in what the job left, by the rule
  FreeBSD's `sh` gets from libedit: a setting counts only when it is
  canonical, and `ECHO`, `ISIG` and `ICRNL` are among the flags it forces
  on ([The foreground rule](#the-terminal-relays-protocol)). So `stty
  status ^X` lasts beyond `stty`, and a command killed in raw mode leaves
  nothing in the `termios`. A command that sets the `termios` sets back
  the one it found when it returns or fails, as a FreeBSD program
  restores its terminal before it exits, so the next command of the line
  starts as it would have.

**Jobs and their tags.** A job is the set of its stages and of every
program they started, which the command server records at each spawn
([design-programs.md](design-programs.md#job-control)). Its Erlang
processes are those that carry its **job tag**, a runtime attribute that
every process takes from the process that spawns it, at its creation, and
never changes, so a stage's helpers belong to its job however they are
spawned. The shell makes the tag when it starts the job's evaluator with
`erx_job:spawn/1`, which starts a process under a tag no other process
carries ([design-runtime.md](design-runtime.md#scheduling)). The group
leader, which a process may change, decides nothing about a job: a job's
processes inherit the shell's, the command shell's group, which writes
what they print through `io` and refuses their input requests ([One
reader for the command shell's group](#the-terminal-relays-protocol)). A
program's handler is not among the job's processes:
the command server spawns it, outside every job, and the job reaches
the program through the server's row
([design-programs.md](design-programs.md#the-handler)), so a stopped
job's handlers still carry out its pause and answer for its programs. The runtime acts on a tag at the one point
where its schedulers pick a process to run: a process of a stopped job is
set aside there instead of running, and one of an ending job exits there,
so a process spawned at any moment is stopped or ended with its job, and
no list of members is kept or raced
([design-runtime.md](design-runtime.md)).

**When a job is over.** A job is over when its evaluator has ended and
so has every program of the job, as a UNIX shell waits for every
process of a job's pipeline. The shell monitors the evaluator, and once
that has ended it asks the command server `{await, Tag}`, which answers
when no row of the job's tag remains
([design-programs.md](design-programs.md#the-command-server)). So the
wait for a job's programs is held outside its tag: an evaluator that
waits for a program carries the tag and ends with it, but the program's
row lasts until the program ends, kept by the command server, which
belongs to no job, and the program's tree ends with the program
([design-programs.md](design-programs.md#a-programs-end)). `Ctrl-C`
therefore needs no exception: marking the tag ending ends every Erlang
process of the job at once, the evaluators that wait for programs and
any helpers they spawned among them, while each program takes `SIGINT`
from its handler and ends or not as it chooses. Until the job is over
it keeps its place: a foreground job keeps the terminal and the shell
prints no prompt, so a program that catches `SIGINT`, as an editor
does, goes on in the foreground as on UNIX, and `jobs` shows a
background job running while its evaluator or any of its programs
lives.

**Ending a job** signals its programs through their handlers and ends its
tag's processes. It also reaches members that wait in `receive`: it marks
the job ending and then wakes each member it finds among the runtime's
processes, and each spawn checks its job after the new process exists, so
a process spawned while the search runs is either found by it or ended by
its spawner.

**`kill` of a job** acts by the default action of the signal it sends,
as the signal table of [design-programs.md](design-programs.md#signal-numbers)
gives it, so no signal is listed here. FreeBSD's `sh` sends the signal
to the job's process group and leaves the rest to what each process
does with it (`bin/sh/jobs.c:719-736`, at commit `95719d8a`); erXos
makes the job table do what that leaves the processes doing:

* A signal whose action is to terminate, `SIGTERM` by default and among
  others `SIGHUP`, `SIGINT`, `SIGKILL` and `SIGUSR1`, ends the job, as
  above. Of a stopped job it then resumes the programs, so each takes
  the signal. Here erXos differs from FreeBSD, whose kernel runs a
  stopped process only for `SIGKILL` and leaves any other signal pending
  until the process is continued (`sys/kern/kern_sig.c:2419-2432`,
  `:2500-2515`), so that `sh`'s `kill %1` of a stopped job leaves it
  stopped: ending a job ends its Erlang members at once, and a program
  left paused would have no job left to continue it.
* `SIGCONT` continues the whole job as `bg` does, below, and leaves it
  in the background, as `sh`'s `bg` continues a job by sending its
  process group `SIGCONT` (`bin/sh/jobs.c:287-303`).
* A stop signal, `SIGTSTP`, `SIGSTOP`, `SIGTTIN` or `SIGTTOU`, stops the
  job as `Ctrl-Z` does, except that the terminal stays with its holder;
  a job already stopped is left as it is, as FreeBSD's kernel discards
  a stop signal sent to a stopped process (`kern_sig.c:2482-2497`).
* A signal whose action is to ignore it ends nothing. `SIGINFO` delivers
  the info request ([`Ctrl-T`](#ctrl-t-status-and-the-info-request))
  and `SIGWINCH` the window-size delivery
  ([Window size](#window-size)), each with its effect on the job's
  programs and on the Erlang processes that opted in; `SIGURG`,
  `SIGCHLD` and `SIGIO` go to each of the job's programs through its
  handler, and its Erlang processes take nothing, as a signal reaches an
  Erlang command only as an event it opted into.

A signal that neither ends nor continues a stopped job leaves it
stopped; a program of it takes the signal, and an Erlang process its
event, once it runs again, as FreeBSD leaves a signal pending on a
stopped process (`kern_sig.c:2500-2515`).

**Stopping and continuing.** Stopping a job pauses its programs, through
the port driver's pause of each program's image, and marks its tag
stopped; a program that a paused member starts or forks, or that the
shell starts for the stopped job, starts paused. `fg`, `bg` and
`kill -s CONT %N` continue the whole job: they clear the mark, lift the
`job` cause from every program of the job and then have each program's
handler send it `SIGCONT`. A `SIGCONT` that reaches one program of a
stopped job from elsewhere, under the `kill` rules, lifts the `job`
cause from that program alone and makes the job table show the job
running in the background, while its other members, its Erlang
processes among them, stay held until `fg` or `bg`, as a UNIX job's
other processes stay stopped
([design-programs.md](design-programs.md#job-control)). So `fg` and
`bg` do the same whatever the entry shows: clearing a mark that is not
set and lifting a cause a program does not hold change nothing, and the
table needs no state for a job that is partly held. On Fiasco,
which pauses no space, stopping a job stops only its Erlang commands: the
shell reports those stopped and names the job's programs, which run on, so
the job table never shows a running program as stopped
([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)).

**A stop keeps its answers.** A job's entry in the job table is in the
foreground, in the background or stopped, and only a stopped entry holds the answers its stop owes: one
to each process that asked for the stop with `erx_cmd:stop/1`, and one to
each program's handler that asked for it with `{stop, sigtstp}` or
`{stop, sigttou}` ([design-programs.md](design-programs.md#the-terminal),
"Stopping itself"). One step of the table's core takes an entry out of
stopped, whichever request causes it, among them `fg`, `bg`,
`kill -s CONT %N`, the resume that follows the signal of `kill %N`, and
a handler's report that a `SIGCONT` from elsewhere continued one of the
job's programs. That step makes the request's resume, the whole job's
or, for the report, that one program's, and then gives every kept
answer. Apart from its state, an entry keeps the `termios` the job left
when a stop last took the terminal from it, or none when no stop has,
as for a job started with `&` that has not stopped; `fg` gives the job
that `termios`, or the cooked one when it keeps none ("The holder
follows the job table", below), whichever state the entry is in. The answers exist only inside the stopped entry, so no way of
continuing a job can leave one behind, and the step keeps no list of
the ways: a new way of continuing a job is one more caller of it. A job that ends while stopped drops
its answers with its entry, and its requesters end with it. A requester
whose own hold outlives the step, a member of the job that a `SIGCONT`
for another program left stopped, takes its answer only once it runs
again.

**A command stops its own job** with `erx_cmd:stop/1`, as a program
raises `SIGTSTP`: a command that has cleared `ISIG` reads `Ctrl-Z` as a
key, and `vi` does this on it. The call asks the job table for the stop
`Ctrl-Z` makes, and the table keeps the caller's answer in the stopped
entry, so the call returns only after the job is continued, however it
is continued and whichever scheduler the shell and the caller run on: no
answer exists before. In a command domain, which reaches no job table,
`stop/1` fails with `enotsup`.

**Reading in the background.** Only the foreground job reads the
terminal; a background job that reads it waits until it is brought to the
foreground, its wait parked in the relay
([The terminal relay's protocol](#the-terminal-relays-protocol)). A
process of a job that is over, one its evaluator spawned and that
outlived it, never holds the terminal again, so its read waits until the
session ends, where FreeBSD answers a read from an orphaned process group
with `EIO` (`sys/kern/tty.c:471-475`, FreeBSD 15.1). It takes no key and
costs one parked wait, and ends with the session.

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
stopping signal's name as rc names one (`sigtstp`), and the rest of the
line goes on holding the terminal, unless `Ctrl-C` ended the job, which
interrupts the line too
([The terminal relay's protocol](#the-terminal-relays-protocol)). `kill` takes FreeBSD
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
`info`. The relay passes `info` to the shell, which alone knows its jobs,
naming the job that held the terminal when the key was typed
([The terminal relay's protocol](#the-terminal-relays-protocol)). The
job table answers with one effect, `{info, Tags}`. `Tags` holds that job,
the one `Ctrl-C` would have ended, or nothing once the job is over.
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
* **A job that is over.** The table answers `{info, []}`, and the line
  ends with FreeBSD's text for that case, below; no request goes out.
* **At the prompt.** While the shell prompts, the tty is in the
  console's editing setting, with `ICANON` clear, so `VSTATUS` makes no
  event and `Ctrl-T` is a key for `edlin`, which transposes two
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
source of its `ps` ([Text commands](#text-commands)), so no
inspect facet is needed:

| Field | An Erlang process | A program |
| --- | --- | --- |
| `NAME` | its registered name, else its `proc_lib` label when that is an atom or a binary, else the function it started in. Each stage's first process is labelled with its command's name, and the line's process with `rc` | its name, as `ps` shows it |
| `PID` | its pid as `ps` prints it, `<D.N.S>` | its process id |
| `STATE` | `running` (status `running` or `garbage_collecting`), `runnable`, `suspended` or `exiting`; while it waits in `receive`, the function it waits in, `M:F/A`, which stands where FreeBSD shows the wait channel | the chosen thread's state as the kernel reports it: `running`, `runnable` or its wait kind; `suspended` when the program is paused |
| `R` | time since the shell started it, for the line's process and a stage's first process; left out for any other, since the runtime keeps no start time | time since it started, from the command server's table |
| `U`, `S` | unsupported, so left out: the runtime keeps no CPU time per process | `U` is its group's CPU time, as `getrusage` reports it ([design-programs.md](design-programs.md#the-posix-lite-personality)); `S` is unsupported and left out, since the kernel does not split the two |
| `P` | unsupported, so left out: the runtime keeps no CPU time per process | its `pcpu` as `ps` prints it, its CPU time over the time since it started ([Text commands](#text-commands)) |
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
`tty.c:2057-2062`). It also returns nothing when the room is less than the
whole line, so a line is never cut. A dropped line is not an error, and
the requests still go out.

When the job the event names has no member left, the line is `empty
foreground process group`, FreeBSD's text (`tty_info.c:311-324`), without
the load field. FreeBSD's `no foreground process group` has no case on
the session's tty, which always has a holder, and whose editing setting,
with `ICANON` clear, makes no `info` while the console holds it.

**The info request.**

* **Programs.** The shell asks each program's handler to send it
  `SIGINFO`, as it asks for `SIGINT` at `Ctrl-C`
  ([design-programs.md](design-programs.md#the-terminal)). A program that
  does not catch it runs on.
* **Erlang commands opt in**, as a program catches `SIGINFO`. A process
  calls `erx_cmd:catch_events(Events)`, with `Events` a list of `info`
  and `winch` ([Window size](#window-size)), which sets the key
  `'$erx_events'` in its own dictionary to that list. The shell reads
  that key in the same `process_info/2` call that reads the member's
  values. It sends `{erx_cmd, info}` to each member whose list holds
  `info`, and sends nothing to any other member. A
  spawned helper inherits nothing: each process that wants requests opts
  in. `erx_cmd:requested(info)` takes every pending request without
  waiting and returns whether there was one, so requests coalesce as a
  pending signal does. A process that waits in `receive` matches
  `{erx_cmd, info}` itself. The request does not go to the group leader:
  the command shell's group leads every job and is only the route of what
  they print, and passing requests on would make it keep a list of who
  asked. It does not go to
  every process either: an unexpected message lengthens the queue of a
  process that never reads it, and `gen_server` logs it.
* **What answers.** The Erlang commands answer as FreeBSD's tools do. `cp`
  opens its target itself, copies in pieces of 64 KiB, checks for a
  request between pieces, and writes `from -> to  N%` to its standard
  error, the percent three columns wide; it reports a failed close of the
  target as it reports a failed write, since a server may refuse at the close what it took write
  by write, as `/apps` refuses a package that fails its check
  ([design-packaging.md](design-packaging.md#installing-updating-and-removing)). `rm` writes the path it removed last to its standard output. `wc`
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
command shell's group passes `info` to the shell while it serves no
request; while it reads the shell's line, the only request it serves,
`Ctrl-T` is `edlin`'s key.
The Erlang shell's group gets it as the key. The console's output column
is unknown, so the line always starts with a newline there.

#### Window size

A full-screen command or program redraws when its terminal's size
changes, as FreeBSD's programs do on `SIGWINCH`. The change takes the
path `Ctrl-T`'s info request takes, with no status line:

* **Seen once.** The master reports a size as `{tty_size, Rows, Columns}`
  ([design-live.md](design-live.md#the-tty)). `erx_tty:size/3` returns
  `winch` only when the size differs from the one the tty holds, so a
  repeated report of the same size, such as the resend of a lost answer,
  sends nothing.
* **Delivered to the foreground job.** The relay passes `winch` to the
  shell, naming the job that holds the terminal, as it passes `info`. The
  job table answers `{winch, Tags}` for that job, as it answers
  `{info, Tags}`, and the shell, in a short-lived process,
  delivers it: each program's handler sends the program `SIGWINCH`, whose
  default action is to ignore it, and each Erlang process whose
  `'$erx_events'` holds `winch` gets `{erx_cmd, winch}`. A job that is
  over by then has no member to send to. While the console holds the
  terminal the event goes to the console, which has the size already as
  `erx_console_size`.
* **Bursts merge, job by job.** The shell runs one delivery at a time. A
  `winch` that arrives while one runs marks the job it names for one more
  delivery, and a job already marked stays marked once; when a delivery
  ends, the next marked job's runs, in the order the jobs were marked. So
  however fast the master reports, one delivery runs and at most one waits
  for each job, and every job that held the terminal at a change gets a
  delivery that starts after the change. Each delivery sends a subscriber one
  message, so a subscriber that does not receive for a while, as one
  waiting on a slow file does, finds one message for each delivery made
  meanwhile, each a two-element tuple; they are bounded by the
  deliveries, not by the reports. Neither the signal nor the message
  carries the size: a receiver asks for it (`erx_cmd:tty/2` with
  `winsize`, or `TIOCGWINSZ`), so a merged report loses nothing, and
  `erx_cmd:requested(winch)` takes the messages that wait.
* **A stopped job** gets no report, since it is not in the foreground; it
  asks the size when it is continued, as `vi` does
  ([design-vi.md](design-vi.md#the-command-at-the-edge)).

So a program on the session's own tty gets `SIGWINCH` in the first tier,
as on a pseudo-terminal of the second
([design-programs.md](design-programs.md#the-terminal)).

#### The terminal relay's protocol

The relay is a `gen_server`, one for each tty of the session: the
console's tty, the domain's line, and each tty a master of the session's
own domain opens (`erx_session_tty:open/1`, for a terminal window). The
relay of the domain's line alone is registered, as `erx_tty_owner`, the
name the runtime's own output looks for ([design-runtime.md](design-runtime.md),
"A process waits on its tty's owner"), since in the session's domain that
relay is the tty's owner. A registered name has one holder, so the other
relays hold none: each is reached by its pid, which its console holds as
its driver, and every open names the relay that made it, so the parties
below that hold an open reach its relay through it. Its construction is one
value: **the terminal has one holder at a time, the console or one job,
and the holder's `termios` goes with it; typed input waits only in the
tty, and leaves it only by a read from a reader of the holder; a job
reads only once its shell has acted on every signal its keys made,
whoever took the key; and a read takes bytes only on a ready report the
relay sent after the last signal it made.**
Each event the line discipline makes goes to the holder of that moment.
FreeBSD's terminal is built the same way: it has one foreground process
group, against which a read or a change of the `termios` is checked
(`sys/kern/tty.c:456-461`), its input queue is the one place typed bytes
wait, which `sh`'s line editor reads as any foreground process does, and
a key's signal reaches the group that is in the foreground when the key
arrives (`tty.c:1544-1550`), before the next byte is taken
(`sys/kern/tty_ttydisc.c:1124-1133`). Every open belongs to a holder:
the console's to `console`, and a program handler's for its program, a
stream relay's for its command and an Erlang process's own, made by
`erx_cmd`, to their job. Every open is made with its **mode**, `read`
or `write`, and the relay answers every read on a write-only open, and
every watch of a read there, `{error, ebadf}`, as it answers a request
naming an open it did not make. Only two kinds of open are made for
reading: the console's, through which each of the console's groups
reads, and `erx_cmd`'s. A handler's open and a stream relay's are
write-only, so they carry writes, controls and watches of `in` and
`out` and no read ([A reader the signal
ends](#the-terminal-relays-protocol)). An open **may
read** while its holder holds the
terminal and, if the holder is a job, the shell that gave it the
terminal has acted on every signal counted for that shell
([A signal suspends a job's input](#the-terminal-relays-protocol)); only
such an open's wait reaches the line discipline and gets a ready
report, and only its read takes bytes, on a report sent since the last
signal, and only if it was made for reading. A write-only open that may
read gets the reports of its watches of `in`, so a program's `poll` for
input works as on any terminal, and takes no byte. The
shell changes the holder and the `termios` in one request. Each rule
that would otherwise be a case of its own follows from that value:

* the console reads only while it holds the terminal, and then only the
  bytes its group's line editor asks for, one at a time, and the command
  shell's group reads only for the shell, which asks for another line only
  once it has acted on the last, and so only after a command that line
  started has had the terminal
  ([The console reads on demand](#the-terminal-relays-protocol)), so every
  byte the editor has not used is still in the tty when the next holder
  reads, and nothing is ever given back;
* no reader of a job takes a key typed after a `Ctrl-C`, `Ctrl-Z` or
  `Ctrl-\` before the signal has been carried out on it, whether the
  key reached the job or, as a line starts, the console
  ([A signal suspends a job's input](#the-terminal-relays-protocol),
  [A reader the signal ends](#the-terminal-relays-protocol));
* `Ctrl-C` discards all typed input that waits, unless `NOFLSH` is set,
  since it all waits in the tty, and the tty's 4 KiB bound on unread
  input bounds all of it ([design-live.md](design-live.md#the-tty)); the
  console's group holds no more than the line it is editing, at most
  65,536 codepoints, past which a typed character is dropped with a bell
  as the tty drops a byte that finds its queue full
  ([design-runtime.md](design-runtime.md), edit 73);
* a background job's read waits until `fg` brings the job back
  ([Reading in the background](#job-control));
* a background job's `tcsetattr` changes nothing and is answered
  `{background, false}`: `tty/2` then stops the job
  ([Interfaces](#interfaces)), and so does a program's `liberx` unless the
  thread ignores or blocks `SIGTTOU`
  ([design-programs.md](design-programs.md#the-terminal)), as FreeBSD's
  terminal stops a background job of `sh` until it is in the foreground
  (`tty.c:486-497`);
* a key reaches the holder that held the terminal when it was typed,
  never a job that took the terminal after it, nor a group that took the
  console after it, however late the shell or the console acts on it;
* the tty is in the console's editing setting for the first prompt
  because the console holds it from the start;
* the shell never has to order a `termios` change against a change of
  who reads.

**Its core.** The relay's decisions are one pure state machine,
`erx_session_relay_core`, beside the `erx_session_relay` server, which hands
it every request and message and carries out the actions it returns once it
has answered the request. The core holds the line discipline's state and
`erx_tty_link`'s, the tty's side of the master's messages
([design-live.md](design-live.md#the-tty)), and gives `input/3` the room it
derives from what `erx_tty_link` holds, so no part of the relay counts echo
or held bytes. A signal's `flush_output` empties what `erx_tty_link` holds
but the output outstanding at the master, and drops the writers' messages
not yet through `output/3`, which are answered then. Every step ends in
one place: there every `read` and `in` wait is armed in the line discipline
exactly when its open may read and parked otherwise, so no rule lists the
steps that park or arm, and what the step left in `erx_tty_link` goes to
the master, once. A step's calls only fill what `erx_tty_link` holds, so
nothing a signal's flush drops, echo typed before the key or output held
while output was stopped, reaches the master before the flush, as FreeBSD
wakes the device once, after a step's input
(`ttydisc_rint_done`, `sys/kern/tty_ttydisc.c:1293-1305`). Output stopped
is `erx_tty_link`'s alone; writes fill what it holds while output is
stopped, as FreeBSD's do.

**Its parties.**

* The master speaks the seven messages of
  [design-live.md](design-live.md#the-tty) ("Between domains").
* The console of the session role reads through an open of its own, as
  every reader does. The relay is that console's line driver for the rest:
  it takes the console's writes and sends it the size, as the console's
  driver messages ([design-runtime.md](design-runtime.md), "`erx_stdio`,
  hosted mode's console driver"), and it sends the console no input. At
  the master's hangup it sends the console `erx_console_eof`, once, the
  permanent end of the line, whether or not a read is outstanding, before
  the waits the hangup readies; the console ends every shell on the line
  at it. A read's `eof` is that read's end of file and never the hangup.
* The runtime's writers reach the relay of the domain's line through
  `erx_tty_owner`: `erlang:display_string/2`, `erlang:display/1`,
  `standard_error` and a normal halt.
* The program handlers, the Erlang commands through `erx_cmd`, the
  console and the shell make requests.

Every party but the master is a process of the session's own domain. A
process of another domain cannot reach the relay. Its messages arrive as
`{erx_origin, D, Msg}`, and the relay takes those only from its master's
domain, so a plain message comes from its own domain by construction.

**Requests.** A request is a call, `gen_server:call(Relay, Request,
infinity)`, made by a client function of `erx_session_relay`, which
takes the relay from the open the request names, which names its
relay, or as its pid where the request names no open. An open is an
opaque type of that module, which only it builds or takes apart, as
Dialyzer would flag. Build checks guard against a slip that names
`erx_tty_owner` outside it (the runtime's writers aside) or builds the
request for an open made for reading as a literal tuple ("Only
`erx_cmd`'s and the console's opens read", below);
no check stops a module that holds a relay's pid from building any
other request by hand. The relay answers a request in the step that
takes it.
The relay
calls no one and waits on no one, so no cycle of waits passes through
it, and a caller waits for one step of the relay at most. The
request shapes of the program protocol are the relay's own
([design-programs.md](design-programs.md#the-program-protocol)): a handler
passes on a program's `{tty, Open, Request}`, `{watch, Open, Events}`
and terminal read with the relay's open in place of its own. It passes
the relay's report `{ready, RelayOpen, Events, N}` back as the program
protocol's `{ready, Open, Events}`, its own open in place of the
relay's, and keeps `N` with the open, naming it in the read it passes
on ([design-programs.md](design-programs.md#the-terminal)). The opens are
made by the relay module's two client functions:
`erx_session_relay:open_reader(Relay, Holder)` asks Relay for an open
made for reading and `open_writer(Relay, Holder)` for a write-only one. Reads and writes carry bytes, at most 4 KiB, as 9P2000.L's
`read` and `write` do. The program protocol carries data-area slots
instead, and the handler copies between the two.

| Request | Sent by | Answer | What follows the answer |
| --- | --- | --- | --- |
| `{open, Holder, Mode}`, `Mode` being `read` or `write` | with `write`, through `open_writer/2`: a program's handler, for each terminal open of its program, `Holder` being the job its row names ([design-programs.md](design-programs.md#the-terminal)), and a command domain's stream relay, `Holder` being the job of its command's row ([design-programs.md](design-programs.md#what-a-program-can-start)); with `read`, through `open_reader/2`: `erx_cmd`, in the calling process at its first terminal call, under the caller's own job tag, kept in the caller's dictionary, and the console of the session role, once at its start, with `Holder` `console` | `{ok, Open}`, `Open` an opaque value naming the relay and a new reference | the relay monitors the caller and closes the open when the caller ends |
| `{close, Open}` | a process given the open | `ok` | the open's waits end, and no report for it is sent after the close is taken |
| `{tty, Open, tcgetattr}` | a process given the open | `{ok, Termios}` | nothing |
| `{tty, Open, {tcsetattr, Termios}}` | a process given the open | `ok`; `{error, einval}` when `erx_tty:set/2` refuses `Termios` or `TOSTOP` is set; `{background, false}` when the open's holder does not hold the terminal, with nothing changed | on `ok`, the line discipline's waits are checked again under the new `termios` ([design-live.md](design-live.md#the-tty)) |
| `{tty, Open, {tcsetattr, Termios, sigttou_ignored}}` | a program's handler, for a thread that ignores or blocks `SIGTTOU` ([design-programs.md](design-programs.md#the-terminal)) | as `{tcsetattr, Termios}`, but never `{background, Orphaned}`: the change is made whichever holder holds the terminal | as for `{tcsetattr, Termios}` |
| `{tty, Open, winsize}` | a process given the open | `{ok, {Rows, Columns}}`, the size the master last reported | nothing |
| `{watch, Open, [Kind]}`, `Kind` being `{read, Count}`, `in` or `out`, `Count` from 1 to 4,096 the bytes the read will ask for | a process given the open | `ok`; `{error, ebadf}` for `{read, Count}` on a write-only open | one `{ready, Open, [Kind], N}` to the caller, `N` the relay's signal number when it sends the report ([A reader the signal ends](#the-terminal-relays-protocol)), when `read_wait`, `poll_wait` or room in the output says so; a read's wait is ready at `Count` bytes when `Count` is fewer than `VMIN`, as FreeBSD's read returns once its buffer is full (`sys/kern/tty_ttydisc.c:290`, `:331`, `:384`) |
| `{tty_read, Open, Max, N}`, `Max` from 0 to 4,096, `N` the number of the report the reader received | a process given the open | `{error, ebadf}` on a write-only open, whatever `N`; otherwise `{ok, Bytes}`, each loss of input given as one NUL ([design-live.md](design-live.md#lost-input)); `eof` for the end of file, `Ctrl-D` at the start of a cooked line or any read that finds no bytes after a hangup; `{ok, <<>>}` for a raw read whose time ended with nothing; `eagain` when another reader took the bytes, the open may not read, or `N` is not the relay's signal number; a read of 0 bytes that passes those checks is answered `{ok, <<>>}` and waits for nothing | nothing |
| `{tty_read_input, Open, N}`, `N` as for `tty_read` | a process given the open; the console of the session role reads with it, and every other reader with `tty_read` | as `{tty_read, Open, 1, N}`, but `lost` where that read would give a loss as NUL ([design-live.md](design-live.md#lost-input)) | nothing |
| `{write, Open, Bytes}` | a process given the open | `{ok, N}`, the count `output/3` took; `eagain` when it took none, or bytes wait ahead of it | nothing |
| `{console_group, Group}` | the console of the session role, at its start and in each step that changes its current group | `ok` | the events made while the console holds the terminal carry `Group` from this step on, and its `interrupt` and `suspend` count for `Group` ([Terminal events](#the-terminal-relays-protocol)) |
| `{status, Line}` | the shell's report process ([`Ctrl-T`](#ctrl-t-status-and-the-info-request)) | `ok`, whether `status/3` takes the line or drops it | nothing |
| `{foreground, console, Signals}`, `{foreground, Tag, cooked, Signals}`, `{foreground, Tag, Termios, Signals}` or `{foreground, Tag, current, Signals}`, `Tag` being a job's tag and `Signals` being `{Group, Seen}`: the shell's own group and the number of signals the shell has carried out, 0 before the first | the shell | `{ok, Left, Sent}`, `Left` being the `termios` the previous holder left and `Sent` the number of signals made for `Group` ([One count per shell](#the-terminal-relays-protocol)); `{error, einval}` when `erx_tty:set/2` refuses `Termios`, `current` names a job that does not hold the terminal, or `Seen` is above the count of signals made for `Group`, with nothing changed; with `current`, which changes neither the holder nor the `termios`, `Left` is the `termios` of the moment | where the new holder's opens may read, their parked waits are armed and report at once where input waits; while the job `Tag` holds, the caller is the process its events go to and its signals count for `Group` |

Any other request is answered `{error, einval}`, and a request that names
an open the relay did not make, or has closed, is answered
`{error, ebadf}`. `tcgetpgrp` and `tcsetpgrp` belong to the second tier,
where `{background, Orphaned}` can also be `true`, for an orphaned group,
and answers a write under `TOSTOP` too
([design-programs.md](design-programs.md#the-terminal)).

**The writers' messages.** The console's writes and the runtime's are
messages, not calls. Each is answered later, once its bytes are in, and
the relay waits on none of them:

| Message | Sent by | Answer |
| --- | --- | --- |
| `{erx_console_output, From, Bytes}` | the console | `{erx_console_written, From}`, once every byte has passed `output/3` into what the relay holds for the master, or a flush or a hangup has dropped it |
| `{tty_write, From, Ref, Bytes}` | `erx_output:write/2`, for a process of the session's domain | `{Ref, ok}`, on the same condition |
| `{tty_drain, From, Ref}` | `erx_output:halt/2`, at a normal halt | `{Ref, ok}`, once nothing waits to be written and the master has answered every byte the relay holds, or at once while output is stopped, the relay has no master or the line has hung up, since nothing would take the bytes; a relay started with no master, as a session's tty may have none, sends nothing for one, holds its output as it does while output is stopped and drops any message as from a master; the relay of the domain's line gives up `erx_tty_owner` as it answers, so a second call of `erlang:halt/2` goes straight on; a request by name after it exits in its caller, and the runtime is halting |

These bytes join the one output queue with the opens' writes, in the
order they arrive ([Job control](#job-control), "Output"). Each writer
has one write waiting at most, since it waits for the answer.

**One watch per kind.** A watch names one kind, and `{read, Count}` is
one kind whatever its count. A `poll` for input and output sends two
watches, and a second watch of the same open and kind replaces the
first, as the line discipline replaces a wait
([design-live.md](design-live.md#the-tty)). A watch of `read` or `in`
from an open that may not read is answered `ok` and parked: the relay
keeps it, with its caller, outside the line discipline, so no `VTIME`
timer runs for it. A watch of `out` is never parked, since a background
job's writes go through in the first tier. It is reported once no writer's
message waits and the room free for the master fits one more byte's
widest rendering, a tab under `TAB3` (`erx_tty:widest_rendering/0`),
so the write a report lets go takes at least its first byte; output
stopped does not matter, as it does not to FreeBSD's `poll`. This departs
from FreeBSD, whose `poll` reports `POLLOUT` at one free byte
(`ttydev_poll`, `sys/kern/tty.c`): a line discipline never splits a
byte's rendering, so a program whose next byte renders wider, a newline
under `ONLCR` with one byte free, would spin between `poll` and `EAGAIN`
until the master takes output. FreeBSD's blocked writer does not spin,
since it waits for the low-water mark (`TF_HIWAT_OUT`,
`sys/kern/tty_ttydisc.c`) and blocking writers go one at a time
(`TF_BUSY_OUT`, `sys/kern/tty.c`). The relay's writers' messages are not
serialised with its `out` waits, so such a mark would be state that a
writer adding between the master's takes keeps from clearing; the rule
depends on the room alone, so nothing holds a watch off while the room
is there.

**The ordering rule.** The answer goes before anything the request sets
off. A watch whose condition already holds is answered `ok` and then
reported, and a `foreground` is answered before the reports of the waits
it arms. So a caller always sees the answer to its request first.
Messages from the relay reach one process in the order it sends them,
so a caller that closes an open gets every report made for it before
the close's answer, and none after.

**The foreground rule.**

* The relay keeps the session's **cooked `termios`**, the setting
  commands run under, which starts as the tty's defaults.
  `{foreground, Tag, cooked}` gives the terminal to the job `Tag` with
  the cooked `termios`, `{foreground, Tag, Termios}` with `Termios` as
  given, and `{foreground, Tag, current, Signals}` changes neither the
  holder nor the `termios` and only tells the relay what the shell has
  acted on ([A signal suspends a job's
  input](#the-terminal-relays-protocol)). `{foreground, console,
  Signals}` gives it to the console with its
  **editing setting**: the cooked `termios` less `ICANON`, `ECHO` and
  `OPOST`, with `VMIN` 1 and `VTIME` 0, so its line editor takes each key
  as it is typed and writes its own CR-LF, while `ISIG` and `ICRNL` stay
  set. libedit's editing setting keeps the same two flags and sets the
  same `VMIN` and `VTIME` (`contrib/libedit/tty.c:79-88`, `:108-116`)
  ([design-live.md](design-live.md#the-tty), "A shell's line editor is a
  program on a raw tty").
* **Each time the console takes the terminal, the cooked `termios` takes
  in what the previous holder left, by libedit's rule.** libedit reads
  the terminal's setting each time it starts to edit a line and always
  follows its speed. Only when that setting has `ICANON` set does it take
  its flags and special characters as the setting commands run under,
  through masks that keep `ISIG`, `ICANON`, `ECHO`, `ECHOE`, `ECHOCTL`,
  `IEXTEN`, `ICRNL`, `OPOST` and `ONLCR` set and `NOFLSH`, `ECHONL`,
  `EXTPROC`, `FLUSHO`, `INLCR`, `IGNCR` and `ONLRET` clear; it never
  looks at how the command ended (`contrib/libedit/tty.c:71-78`,
  `:957-979`, `:1005-1063`, at FreeBSD commit `95719d8a`, release
  15.1.0-p6). The relay applies the same rule to `Left` in the step that
  gives the console the terminal, before it makes the editing setting,
  through two pure functions of `erx_tty_modes`: `adopt(Cooked, Left)`,
  the rule, and `editing(Cooked)`, the editing setting. So `stty status
  ^X` survives `stty`'s return and `stty -echo` does not, a job that left
  the tty raw for any reason leaves nothing, and the editing setting
  follows every change that lasts.
* A `foreground` checks `Termios` whole and `Seen` first, and changes
  nothing if a check fails. It then takes the armed waits of the opens that lose
  the terminal out of the line discipline, timers included, and parks
  them. It sets the new holder's `termios`, records `Seen` for the
  named group, and arms the parked waits of the new holder's opens if
  they may read. Input typed and not yet read stays in
  the tty and goes to the next holder's reader, as typed-ahead input does
  on UNIX; under a cooked `termios` it joins the readable bytes, in which
  a read looks for a line's end, as FreeBSD's tty does after a change of
  `ICANON` (`tty.c:1800-1808`).
* The relay starts with the console holding the terminal, in the editing
  setting made from the tty's defaults, so the first prompt edits before
  the shell has sent anything.
* **The holder follows the job table.** The table's foreground is the
  line the shell runs and, while that line's `fg` waits, the job `fg`
  brought back. The terminal goes to the innermost of them, and to the
  console when there is neither or while `erl` runs, since the Erlang
  shell's group reads through the console. So the shell sends
  `foreground`, each with its `Signals`:
  * before a line starts, `{foreground, Line, cooked, Signals}`;
  * at `fg`, `{foreground, Job, Kept, Signals}`, `Kept` being the
    `termios` the job's entry keeps, whether the entry is stopped or in
    the background, and `{foreground, Job, cooked, Signals}` when it
    keeps none, as for a job started with `&` that has not stopped,
    which began under the cooked `termios` its line held
    ([Job control](#job-control), "A stop keeps its answers");
  * when the job `fg` waits for stops or ends, `{foreground, Line,
    cooked, Signals}`, so the rest of the line reads the terminal, as
    FreeBSD's `sh` takes the terminal back for itself when the job its
    `fg` waits for is done (`bin/sh/jobs.c:1095-1097`); `fg` then returns
    ([Numbers, names and reports](#job-control));
  * when the line itself stops or ends, `{foreground, console, Signals}`;
  * when `erl` starts, `{foreground, console, Signals}`, and when it
    returns, `{foreground, Line, cooked, Signals}`;
  * once it has carried out a signal, the relay's event or its group's
    interrupt or suspend, `{foreground, F, current, Signals}` when the
    table's foreground after the signal is a job `F` that holds the
    terminal, whichever job the signal named; when the signal stopped or
    ended `F`, the bullet of that change applies instead, and when the
    console holds the terminal the shell sends nothing.

  At each stop that takes the terminal from a job the shell keeps `Left`
  in the job's entry for its `fg`. Its own
  requests are never refused, since `cooked` and a kept `termios` are
  the relay's own, it sends `current` only for the job it gave the
  terminal, and it counts no signal the relay has not counted. So a
  refusal is a fault of the shell or the relay, and the shell treats it
  as one: it ends, with the request and the answer in its exit reason,
  as at any crash of the shell ([Context](#context)). Ignoring it would
  leave every later `foreground` refused for as long as the shell lives.
  When the job `fg` waits for ends by `Ctrl-C`, its last stage being a
  program that `SIGINT` ended or an Erlang command that the interrupt
  ended, the shell interrupts the line as well, as FreeBSD's `sh` raises
  `SIGINT` in itself after such a job (`jobs.c:1117-1123`), so
  `fg %1; cat` does not go on to `cat`. It does so in the step that sees
  the job's end, before it sends any `foreground`, and then sends the one
  the table gives after both: `{foreground, console, Signals}` when the
  line is over after the interrupt's effects, and `{foreground, Line,
  cooked, Signals}` when it is not, so no reader of the line reads between
  the job's end and the line's interrupt.
* Only the shell sends `foreground`. Any process of the session's domain
  could send it, but such a process holds the session's authority anyway
  (SH1). A command domain cannot reach the relay at all.

**The console reads on demand.** The console is a reader like any
other, and reads as libedit does: one byte at a time
(`contrib/libedit/read.c:289`, at FreeBSD commit `95719d8a`), and only
while its line editor waits for a key. So the editor alone decides where
a line ends, as libedit's `el_wgets` takes one key at a time and ends
the line at whichever key its map binds to a newline (`read.c:521`,
`:581`), and no list of the keys that end a line exists outside the
editor. At its start the console makes one open, with
`open_reader(console)`, and
reads through it with the requests every reader uses. Only the console
opens for `console`; any process of the session's domain could, but
holds the session's authority anyway (SH1).

* **One reader for the command shell's group.** The command shell's
  group serves input to one process, its shell, as FreeBSD's `sh` is the
  only process of its own process group: each job there is a process
  group of its own, which has the terminal before its code runs
  (`bin/sh/jobs.c:918-934`, at commit `95719d8a`).
  * *The guard.* The group takes an input request, and a `setopts`, only
    from the process it started as its shell, and answers any other
    process `{error, enotsup}`, changing nothing
    ([design-runtime.md](design-runtime.md), edit 74 of "The edits
    outside `sys/erxos`"). An input request or a `setopts` inside
    `requests` is answered `{error, request}` in every group, from any
    process, by the same edit: stock's output dispatcher hands such an
    entry to a fallback (`lib/kernel/src/group.erl:671-672`) whose value
    its caller does not match (`:608-614`), so the group crashes and
    takes its shell with it. The guard sits where requests enter the
    group, so a job's process, a helper that inherited the shell's group
    and one that made the group its leader with `group_leader/2` get the
    refusal from the `io` calls they would use on stock OTP, and none of
    them takes a key meant for the shell or turns its echo off by
    mistake. It is not a security boundary: a process of the session's
    domain can name the shell as a request's sender, or ask the group
    for its driver and send the group what the driver would, but it
    holds the session's authority anyway (SH1), as for `{open,
    console}`. A command reads its standard input, the terminal
    included, through `erx_cmd` ([Interfaces](#interfaces)).
  * *One line at a time.* The shell has one line request outstanding at
    most, and makes the next only once it has acted on the line it got:
    a whole unit runs as a line, which it gives the terminal with
    `{foreground, Line, cooked, Signals}` before the line starts. So once the
    group has answered a line it serves no request (`group.erl:557-560`)
    and makes no ask until the shell asks for its next line, as `sh`
    reads nothing until it calls `el_gets` for its next line
    (`bin/sh/input.c:138`). A nested request, whose state the group
    pushes and resumes with a read of its own (`group.erl:396-397`,
    `:439`), never arises in it.
  * *The Erlang shell's group stays stock*, but for the refusal inside
    `requests`. It serves its shell and every
    process of its evaluations, nested requests included; no job takes
    the terminal while it runs, so whichever of them reads next takes
    the next key.
* **The ask.** The console's current group asks it for input with
  `{self(), read, Ref}`, `Ref` a new reference, and has one ask
  outstanding at most: it asks only when its line editor waits for more
  and no ask of its is outstanding, and an ask stays outstanding until
  the answer that carries its reference arrives
  ([design-runtime.md](design-runtime.md), edit 72 of "The edits outside
  `sys/erxos`"; stock's group asks its driver only in its raw `noshell`
  state, `lib/kernel/src/group.erl:342`, `:346`). The ask belongs to the
  group, not to the request being read, so it outlives the request that
  made it: the blink timer's second pass over the line, a nested request
  of an Erlang shell's group, and the next request after an interrupt or
  an error, are each served by the ask already outstanding, and none of
  them makes another. An answer that arrives while the group serves no
  request waits in the group for the next (`group.erl:259-261`); in the
  command shell's group that is the shell's next line request, at the
  same prompt, since an interrupt or an error there changes no holder. An
  interrupt that finds the group serving no request goes to its shell and
  leaves that answer waiting (`group.erl:519-522`), so a key typed
  between two `Ctrl-C`, within one round trip of the shell, survives the
  second and appears in the next line. The key is drawn there, so it is
  seen before anything runs, and both groups keep stock's behaviour
  here.
* **The read.** On an ask, the console watches `in`, which is ready once a
  unit waits whatever `VMIN` and `VTIME` are, so the termios a program leaves
  cannot make it ready at once, and at the
  report `{ready, Open, [in], N}` calls `{tty_read_input, Open, N}`,
  as it makes its other requests,
  noting the group it reads for, and watches again only after the
  answer, so it has one watch or one read outstanding, never both. The
  console takes the relay's events in the order the keys were typed. An
  event made before the report is ahead of the report in the console's
  queue, since the relay's events and reports come from one process,
  whose signals to one process arrive in the order sent
  (`system/doc/reference_manual/ref_man_processes.md:507-511`), and a
  `gen_server` takes its messages in the order they arrive
  (`gen_server.erl:2320-2323`), so the console has taken it before it
  reads. A signal made after the report changes the relay's signal
  number, which makes the read's answer `eagain` ([A reader the signal
  ends](#the-terminal-relays-protocol)), so the call's receive, which takes its answer past messages
  queued before it (`gen.erl:253-262`), never takes bytes typed after an
  event it passed over. So a newline typed after `Ctrl-C` reaches the
  group after the interrupt that discarded the line it would have ended.
  The console delivers both to the group in that order, an exit signal
  and a message from one process, which the group, a `gen_statem`, takes
  in the order they arrive, as it takes stock's data and interrupt
  (`lib/kernel/src/group.erl:472`, `:519-525`).
* **The answer.** The console passes the byte through its UTF-8 decoder
  ([design-runtime.md](design-runtime.md), "Which input bytes mean
  something") together with the bytes it holds for the group it read
  for, the leading bytes of a character not yet complete. What the
  decoder completes goes to that group's ask as `{Console, {read, Ref,
  Chars}}`, which ends the ask, and what it leaves incomplete stays held
  for the group's next ask. One byte can do both: after `C3`, an `E2`
  makes `C3` latin-1 `Ã`, which is answered, and starts `€`, which waits
  held, as libedit keeps the last byte of an invalid sequence to start
  the next character (`read.c:325-331`). When the byte completes
  nothing, as for the first byte of `é`, the ask stays outstanding and
  the console watches again. A read answered `lost` drops what the
  console holds for the group, the start of a character the loss cut,
  and answers the group's ask `{Console, {read, Ref, lost}}`
  ([design-live.md](design-live.md#lost-input)). A read
  answered `eagain` sends it back to watching. An end of file, which a
  read finds when a background program has set `ICANON` and `VEOF` is
  typed at a line's start, or after a hangup before the console has
  taken the notice, is that read's end and never the hangup,
  which the relay tells with `erx_console_eof`: the console takes it as
  a read that found nothing, answers no ask, drops what it holds for
  the group and watches again, so no group sees an end of file and no
  shell ends at it. Each of the line discipline's signals that names
  a group, `interrupt`, `suspend` and `quit` alike, drops what the
  console holds for that group, since the signal flushed the tty's input
  typed with it, and leaves the ask outstanding, as libedit's
  `read_char` keeps a character's bytes only within one read, which a
  signal interrupts (`read.c:278-345`). The console keeps one ask and one
  set of held bytes per group, reads only for its current group's ask,
  delivers an answer to the group it read for, and forgets a group's ask
  and held bytes when the group ends; so bytes read for one group never
  join a character of another's. A report that finds its current group
  without an ask is left alone, and the byte stays in the tty.
* **A key of several bytes.** An arrow's `ESC [ A` or Delete's
  `ESC [ 3 ~` reaches the group a byte per answer. The editor's answer
  for a key depends on the key's bytes alone, never on where its input
  was cut ([design-runtime.md](design-runtime.md), edit 73): the end of
  its input only makes it wait, a key ends at the byte that completes it
  and looks at no byte after it, a byte that cannot continue a sequence
  ends it and is read again, after any prefix, so `ESC O` and then Enter
  ends the line, and a key that a mode hands to another mode is read
  there again whole. libedit's `read_getcmd` likewise reads on
  through `keymacro_get` while what it has read leads a bound sequence
  (`read.c:255-270`). So `edlin` gives every key the same action, in
  every mode, whether its bytes arrive together or one at a time, and a
  `shell_keymap` entry that no stream of bytes could match whole, such as
  `ESC [ H ~`, which reads as Home and then `~`, is refused when the
  keymap is read, with stock's diagnostic
  (`lib/stdlib/src/edlin_key.erl:124-133`). The group's clauses for a
  history key that finds a line and for the end of a search drop what
  follows the key in
  the same call (`lib/kernel/src/group.erl:890-923`, `:1022-1056`).
  A session's console never gives them anything to drop: it answers one
  character at a time, or two when a byte that belongs to no character
  is answered with the character after it, and that first character is
  a history or search key only under a `shell_keymap` that binds a
  character from U+0080 to U+00FF to one. The system console reads its
  own tty on demand the same way ([design-live.md](design-live.md#lost-input)),
  so it has nothing to drop either.

Each property follows:

* **Typed-ahead input stays in the tty.** `cat` and a line meant for
  `cat`, typed or pasted in one burst, wait in the tty together. The
  console reads `cat` and the key that ends it a byte at a time, its
  group returns the line, the shell gives the line the terminal, and
  `cat` reads the rest. This holds for every key the editor ends a line
  at, a `shell_keymap` that binds `^X` to `new_line_finish` included
  (`lib/stdlib/src/edlin.erl:32-50`, `:378-381`): the answer that ends
  the line ends with the character of the byte just read, and the group,
  which serves only the shell, asks again only once the shell asks for
  another line. The bytes `cat` reads arrived under the editing setting,
  with `ECHO` clear, and are not echoed, as FreeBSD's tty echoes a byte
  once, when it arrives, under the setting of that moment.
* **No input is in flight.** The console takes a byte only by a read
  made for the ask of its current group at that moment, and at the read's
  answer passes the byte on to that group, or holds it for that group. An
  ask ends only at an answer made from a read's answer, and the console
  has one read outstanding at most, so a command shell's group that has
  returned a line has no ask and no read outstanding, and no request to
  make another ask. So no byte is on its way to a group that has stopped
  reading, and a change of holder needs no message to the console, no
  drain and no order between the console's messages and the shell's. Only
  a group killed while it waits for a key can lose a byte: the one the
  console read for it before it took the group's end.
* **Nothing is held.** The console holds for each group the leading
  bytes of one character at most. A key that ends a line is a character
  its last byte completes, which leaves nothing incomplete after it, so
  after a line's last answer the console holds nothing for that group.
  The one exception needs a `shell_keymap` that ends a line at a
  character from U+0080 to U+00FF, typed as a byte that belongs to no
  character and followed by the first byte of another: that byte stays
  held for the group's next line. The group holds at most the part of the
  line it is editing. So when the console loses the terminal, which the
  shell gives away only once its group has returned a line, the console
  and its group hold none of the input that follows. The Erlang shell's
  group may keep the rest of a line after an expression it returned,
  `q().` among them; that rest goes with the Erlang shell when it ends, as
  with stock OTP.
* **Keys reach the console whether or not it reads.** The editing
  setting keeps `ISIG`, as libedit's does (`contrib/libedit/tty.c:83`),
  so `Ctrl-C`, `Ctrl-Z` and `Ctrl-\` are the line discipline's signals
  while the console holds the terminal: at the prompt, and while the
  Erlang shell evaluates and its group reads nothing. Each flushes the
  tty's input and output, as at FreeBSD's `sh` prompt
  (`sys/kern/tty_ttydisc.c:1129-1130`), since the editing setting's
  `NOFLSH` is clear as the cooked `termios`'s always is, and reaches the
  console as an event, below.

The editing setting keeps `ICRNL`, as libedit's does
(`contrib/libedit/tty.c:80`), so an Enter typed while the prompt holds
the terminal is a newline in the tty, and a line typed ahead of a command
ends the command's cooked read.

**Terminal events.** The relay compares holders to gate reads, but acts
on no job. Each signal and event the line discipline returns, but for
`lost`, which goes to the console alone (below), goes to the
holder of the moment it is made, as `{erx_tty_event, Tag, Event}`, named
with what it was made for: while a job holds the terminal, to the
process that gave it the terminal, the shell, `Tag` being the job's tag;
while the console holds it, to the console, `Tag` being the group the
console last named with `{console_group, Group}`, or `none` before it
has named one. The console names its current group at its start and in
every step that changes it, as when a shell started from a shell takes
the console or gives it back to the group below
([design-runtime.md](design-runtime.md), "A shell started from a shell
takes the console on a group of its own"). The relay takes the name in
one step, so an event carries the group the console had named when the
key was typed, however late the console takes the event, as a job's
event carries its job:

| The line discipline's action | `Event` |
| --- | --- |
| `{signal, sigint}` | `interrupt` |
| `{signal, sigtstp}` | `suspend` |
| `{signal, sigquit}` | `quit` |
| `flushed_loss`, before the signal whose flush dropped a loss, only while the console holds | `lost` ([design-live.md](design-live.md#lost-input)) |
| `info` | `info` |
| `winch` | `winch` |

The shell carries an event out on the job `Tag` names as it would on its
foreground job, whatever that job is doing by then, over the members the
job has when it carries the effect out: `interrupt` is `Ctrl-C`'s ending
of the job ([Job control](#job-control)), `suspend` stops it, `quit` is
`kill -s QUIT` of it with no status line, and `info` and `winch` are the
deliveries of [`Ctrl-T`](#ctrl-t-status-and-the-info-request) and
[Window size](#window-size). A job that is over has no member, so
`interrupt`, `suspend`, `quit` and `winch` then reach no one, and `info`
writes FreeBSD's line for an empty group and sends no request. So a key
typed for one job never reaches the job that took the terminal after it,
as a signal from FreeBSD's terminal reaches the group that was in the
foreground when the key arrived (`tty.c:1544-1550`).

The relay sends `lost` only to the console, the one holder that reads lines for
groups, ahead of the signal it belongs to; a shell never gets it, because
no line read of the console's is in progress while a job holds. Under the
cooked `termios` a job's edited line is the tty's own, which the flush
drops whole with its loss. Under a raw one the line is the program's, and
erXos gives the program what FreeBSD gives it: a NUL where it reads a
loss, and nothing for a loss a signal key flushes, so a raw-mode program
editing its own line is not protected from a loss just before a signal
key ([design-live.md](design-live.md#lost-input)).

The console carries `interrupt` and `suspend` out on the group `Tag`
names, in the state that group is in when the console takes the event,
as it carries out `Ctrl-C` and `Ctrl-Z` on the system console's line
([design-runtime.md](design-runtime.md), "Which input bytes mean
something"): `interrupt` ends the line that group is editing or its
Erlang shell's evaluation, and `suspend` reaches its command shell,
which at the prompt finds no job to stop. A group that has ended, and
`none`, name no group, so the event then reaches no one, as a signal for
a process group with no member reaches no process. So a `Ctrl-C` typed
as an Erlang shell ends by `q().` never interrupts the command shell
below it, nor the rest of that shell's line. The console drops `quit`, as FreeBSD's `sh`
catches `SIGQUIT` and does nothing with it at the prompt
(`bin/sh/trap.c:269-275`, `:370-391`, at commit `95719d8a`); `winch`,
since the relay sends it the size as `erx_console_size` at every change,
whoever holds; and `info`, which the editing setting, with `ICANON`
clear, does not make. Unless `NOFLSH` is set, a signal comes with
the line discipline's `flush_output`, and the relay drops what it holds
for the master, so `Ctrl-C` discards waiting output before the shell or
the console has acted.

**A signal suspends a job's input.** `erx_tty:input/3` stops after a key
that makes a signal and returns, beside what to do, the bytes it did not
take ([design-live.md](design-live.md#the-tty)), as FreeBSD's
`ttydisc_rint` takes one byte per call and, at a signal's key, flushes,
echoes and signals the foreground group before it returns
(`sys/kern/tty_ttydisc.c:1012`, `:1124-1133`, FreeBSD 15.1). The relay
carries out such a stop in the step that took the input, in this order:

1. It counts the signal for the shell it is made for, below, and while
   a job holds the terminal it parks the job's armed `read` and `in`
   waits.
2. It sends the event as above.
3. It passes the bytes after the key to `input/3` again, with the room
   `input/3` returned, which is the room it derives from what
   `erx_tty_link` holds once the actions are carried out, until none is left. They wait in the tty. That room
   is what the echo left, of the whole room less the output the master
   has not taken when the signal's `flush_output` emptied the rest of
   what the relay holds for the master
   ([design-live.md](design-live.md#the-tty)), so the relay counts no
   echo itself.

With `NOFLSH` set, `input/3` can report a wait in the same call after the
signal, for bytes typed before the key; a wait that step 1 parked gets no
report from it.

**One count per shell.** A signal's key reaches a command shell by one
of two routes, and the relay counts it on either. While a job holds the
terminal, the relay sends the event to the shell that gave the job the
terminal. While the console holds it, the relay sends `interrupt` and
`suspend` to the console, which passes each to the group the event
names, and that command shell's group passes it to its shell: an
interrupt as `{error, interrupted}` to the line request it serves, or as
the exit signal `interrupt` when it serves none (`group.erl:519-526`),
and a suspend as `{Group, suspend}` (`group.erl:255-258`, `:528-533`).
The relay keeps two numbers for each group: `Sent`, the signals made for
the group's shell, and `Seen`, the number the shell's last `foreground`
carried. An `interrupt`, `suspend` or `quit` sent to a shell counts for
the `Group` of the `foreground` that gave the holder the terminal; an
`interrupt` or `suspend` sent to the console counts for the group the
event names. A `quit`, `info` or `winch` made while the console holds,
which the console passes to no group, and an event for `none`, count for
no group. Both numbers start at 0 the first time the relay meets a group,
in a `console_group` or a `foreground`, so a `foreground` naming a group
the relay has not met passes only with `Seen` 0; the relay monitors the
group from then on and forgets its numbers when it ends. A command shell has a group
of its own, which ends with it (`group.erl:538-543`), so a shell started
from a shell starts at 0, and one shell's signals never touch another
shell's numbers. An Erlang shell's group gets numbers that no
`foreground` reads.

The shell keeps the other end of the count. It adds one to its own
number each time it carries out a signal that reached it, the relay's
`interrupt`, `suspend` or `quit`, or its group's `{error, interrupted}`,
exit signal `interrupt` or `{Group, suspend}`, whatever the signal does,
and sends that number as `Seen` in every `foreground`. Each signal the
relay counts for a command shell's group reaches that shell once, by the
route it was counted on, and is counted before it is sent, so a shell's
`Seen` never passes `Sent`, and a `foreground` whose `Seen` does is
refused ([Requests](#the-terminal-relays-protocol)), which ends the
shell that sent it. The two are equal exactly when the shell has carried
out every signal made for it, in whichever order the two routes
delivered them. A job's opens may read only while the `Seen` and `Sent`
of the group named by the `foreground` that gave the job the terminal
are equal. So a job's reads are suspended exactly while its shell has a
signal it has not acted on; no flag records it, and no number travels
with an event.

After each signal it carries out, the shell sends `{foreground, F,
current, Signals}` for the job `F` that is the table's foreground and
holds the terminal, unless the signal stopped or ended it ([The
foreground rule](#the-terminal-relays-protocol)). So a `foreground` ends
a suspension only once the shell has acted on every signal made for it,
and one sent for an earlier signal carries a smaller number and ends
nothing: with `Ctrl-C`, `Ctrl-Z` and `bg` typed within one round trip of
the shell to a job `A` that catches `SIGINT`, the `current` after the
interrupt carries 1 while `Sent` is 2, A's reads stay suspended, and
the shell stops A and gives the terminal to the console, which reads
`bg`. A `foreground` that gives the terminal to another job while
`Seen` lags `Sent` leaves that job's reads suspended until the shell's
`current` for it, and `current` for a job that does not hold the
terminal is refused, so it never moves the terminal. While suspended,
the job keeps the terminal for everything but reading: its parked waits
get no report, its reads are answered `eagain`, and so is a read on a
report delivered before the key, which the signal made stale ([A reader
the signal ends](#the-terminal-relays-protocol)); its writes,
`tcgetattr`, `tcsetattr` and `winsize` go on, since a program's `SIGINT`
handler that restores the terminal's modes would otherwise be answered
`{background, false}` and stopped. A reader of the job that goes on
after the signal reads the keys typed after it one round trip of the
shell later, nothing lost or reordered, and otherwise the next holder's
reader takes them, so the reader of a key typed after `Ctrl-C` is chosen
by the job table after it has acted on the interrupt. `info` and `winch`
count for no one and suspend nothing.
The console never waits on the numbers: it reads only for its group's
ask and takes an event before the answer to any read made after the key
([The console reads on demand](#the-terminal-relays-protocol)).

**A line that starts after a signal the console took.** The two routes
make one rule, whichever takes the key. `rm -i f` and Enter, then
`Ctrl-C` and `y` and Enter, are typed within one round trip of the
shell. The console reads the line a byte at a time, and its group
returns it to the shell and asks for nothing more. The console still
holds the terminal when the `Ctrl-C` arrives, so the relay counts it for
the shell's group `G`, which makes `Sent` 1, flushes the input typed
before it, and sends the event to the console, which passes it to `G`.
`G` serves no request and passes it to the shell as an exit signal. `y`
and its Enter wait in the tty, since no reader has an ask or a read for
them. The shell has meanwhile sent `{foreground, Line, cooked, {G, 0}}`
and started the line, but `rm`'s read finds the line's opens suspended,
0 not being 1. When the interrupt arrives the shell counts it, ends the
line and sends `{foreground, console, {G, 1}}`, and the console reads
`y` into the next line, where it is seen before anything runs. With
`Ctrl-Z` the group sends `{G, suspend}`, the shell stops the line, and
`y` goes the same way. Had the `Ctrl-C` arrived after the `foreground`,
the relay would have sent it to the shell as the line's event and
counted it the same, so `rm` reads `y` in neither case.

**Four places agree on what counts.** The relay's rule above, the
console's passing of `interrupt` and `suspend` to a group
([design-runtime.md](design-runtime.md), "Which input bytes mean
something"), the group's three messages for them
(`lib/kernel/src/group.erl:255-258`, `:519-533`) and the signals the
shell counts must name the same signals, and a disagreement is a fault
that does not heal. A shell that counts a signal the relay did not
counts one too many, and its next `foreground` is refused, which ends
the shell ([The foreground rule](#the-terminal-relays-protocol)). A
signal the relay counts and the shell never takes leaves `Seen` one
short for as long as the shell lives: every later job's reads stay
suspended, while the console still reads. The shell reports that fault
instead of leaving it silent. Each `foreground` answer carries the
relay's `Sent`, and when that is above the shell's own count, which is
normal while a signal is on its way to the shell, the shell's job table
arms one check a second later, unless one is armed; if the count is
still below that `Sent` when the check comes, the shell prints one line,
`rc: N terminal signals not received; commands cannot read the terminal;
exit starts a new shell`, through its group, and logs it. The line
states what was measured, so a signal held up past the second under
load makes it say nothing false, and a shell whose count catches up
reads on as before. `exit` at the prompt starts a fresh shell, whose
numbers start at 0. The test "Each console signal counted once" runs
the four together ([Verification](#verification-and-testing)).

**A reader the signal ends.** The relay gives a job its reads back when
the shell has carried the signal out: for an Erlang command, once the
shell has marked the job's tag, and for a program, once the command
server has passed the signal to its handler. Neither yet means the
reader has stopped. A process of the job that runs when its tag is
marked runs on to the end of its slice
([design-runtime.md](design-runtime.md#scheduling), "Job tags"), and
nothing orders a handler's report of the signal to its program before
the relay's ready report. A reader that took bytes and then exited at
its pick would lose them, and they were meant for whoever reads after
the signal: in `prog | cmd`, `prog` a program that catches `SIGINT` and
`cmd` an Erlang command reading the terminal, `Ctrl-C` ends `cmd`, the
job keeps the terminal for `prog`, and the `y` typed after the
interrupt must still be in the tty when `cmd` is gone. So bytes leave
the tty only for a reader that has passed a scheduler pick since its
shell carried out every signal made for it before the bytes were typed,
which three rules give:

* **A read takes bytes only on a fresh report.** The relay numbers the
  signals its line discipline makes, `{signal, S}` alone, from 0 at its
  start, its **signal number**. Every ready report carries the number
  of the moment it is sent, `{ready, Open, [Kind], N}`, and a read names
  the number of the report it follows, `{tty_read, Open, Max, N}`. The
  relay answers the read with bytes, `eof` or an empty timed read only
  while `N` is its signal number; otherwise it answers `eagain` and
  takes nothing. A report of `read` or `in` goes only to an open that
  may read, so only after a `foreground` whose `Seen` counts every
  signal made for the job's shell before it, which the shell sends only
  after it has carried each out. The number travels with the report
  rather than staying in the relay, because only a report the reader
  has received comes before its pick: a number the relay kept would
  also match a report sent after the reader's pick, in the step before
  the relay took its read.
* **`erx_cmd` passes a pick between the report and the read.** Its read
  sends the number of a report the calling process has received, and
  calls `erlang:yield/0` after receiving it and before it sends
  `tty_read`. A yield always ends the slice and returns to the scheduler
  (`erts/emulator/beam/emu/trace_instrs.tab:112-122`, and
  `beam/jit/arm/instr_common.cpp:3121-3124` in the JIT), so the
  scheduler picks the process again and reads its tag there
  ([design-runtime.md](design-runtime.md#scheduling), "Job tags"). The
  report was sent after the shell had marked the tag for every signal
  made for its shell before the report, so a process that one of them
  ended exits at that pick, having sent nothing. A signal made after the
  report makes the read `eagain`, whenever the relay takes it. The bytes a read takes were
  therefore typed after every signal the reader has survived and before
  any it has not.
* **Only `erx_cmd`'s and the console's opens read.** An open's mode is
  fixed when it is made, and the relay answers a read on a write-only
  open, or a watch of a read there, `{error, ebadf}` whatever the
  request carries, so what a process outside every job can take follows
  from the open it holds, not from which requests its code sends. A
  program's handler and a command domain's stream relay, each outside
  every job, open the terminal write-only: a program's `read` fails with
  `EBADF` ([design-programs.md](design-programs.md#the-terminal)), and
  a command domain's startup message names its terminal stream `write`,
  and `erx_cmd` there ends a command that reads it with status `ebadf`
  ([design-programs.md](design-programs.md#what-a-program-can-start)).
  The console belongs to no job, so no mark ends it. Two source checks
  over the runtime's Erlang under `otp/` and `erlang/`, of the form the
  tree's Erlang chokepoint rules take
  (`tools/lib/erx/chokepoint_rules/relay.rb`), with comments blanked,
  fail on any of three sites. One is a call of
  `erx_session_relay:open_reader`, of any arity, from any module but `erx_cmd` and
  `erx_console`, in any form that names the function outside a string:
  a remote call, a fun, an `apply/3`, a variable or macro module, an
  import from `erx_session_relay` or a macro defined as either name.
  Another is the atom `erx_tty_owner`, the registered name of the
  relay of the domain's line,
  bare, quoted or in a string, from which `list_to_atom/1` could make
  it, in any module but `erx_session_relay`,
  whose client functions make every request to the relay, `erx_output`,
  the runtime's writers' one sender of `tty_write` and `tty_drain`,
  which every owner serves, and the two modules that hold the name in
  other domains, `erx_console` in the system domain and `erx_log_h`,
  whose proxy holds it in a domain with no terminal
  ([design-runtime.md](design-runtime.md#the-console-and-standard-io)).
  A registered name is an argument, not a call, so the second check
  looks for the name wherever it appears. So a handler that
  builds the open request itself and sends it by name is a site, as
  one that calls `open_reader` is
  ([design.md](design.md#chokepoint-checks)). The third is the request
  for an open made for reading, `{open, Holder, read}`, outside
  `erx_session_relay`, so a module that holds the pid of a relay with no
  name, and sends it that request, is a site too; a request whose mode is
  a variable passes it. Test modules lie outside
  `otp/` and `erlang/`, so the relay's own cases, which open for
  reading from the test process, are not sites; the checks' seeds are
  modules under `erlang/apps`. It is a guard against a slip, not the
  boundary: a module that builds the name or the function at run time,
  from pieces or through a computed `apply/3`, passes it,
  and the mode is what keeps a write-only open from reading. A program's terminal reads,
  and through them a command domain's, need a handshake in which each
  handler answers the shell once its program has taken the signal, and
  the shell sends `current` only after every answer; that handshake is
  open work, and with it the handler and the stream relay open for
  reading ([TODO.md](../TODO.md)).

The window that remains is UNIX's. A reader whose read the relay
answered before a signal was made may be ended by that signal before it
returns the bytes, as a process killed after `read(2)` returns loses
what it read. Those bytes were typed before the signal, while the job
held the terminal, so they were the job's and no later reader's, and
the signal discards the input typed with them unless `NOFLSH` is set.

**Failure.** The relay is its console's line and ends with it, and the
console of the session role ends when the line hangs up, told by the
relay's `erx_console_eof` whether or not a read is outstanding, and
every shell on it ends too. A call to a relay that has ended exits
in the caller, whose job ends with the shell. An open whose maker ends is
closed at its monitor's `'DOWN'`. So a command ended by `Ctrl-C` leaves
no wait behind it, and no caller has to close an open on every path.
After a hangup, the tty drops the input it holds, as FreeBSD's carrier
loss flushes both queues (`sys/kern/tty_ttydisc.c:713-714`), every armed
wait is ready, and every later read that finds no bytes reads the end
of file
([design-live.md](design-live.md#the-tty)). A parked wait gets no report,
since its job ends with the session's shell.

A job holds the terminal only while the group its `foreground` named
lives. When a group the relay monitors ends while a job given the
terminal under it holds, the relay gives the terminal to the console in
that step, as `{foreground, console, Signals}` would, the cooked
`termios` taking in what the job left: the group's shell has ended with
it, its jobs end with their shell, and no other shell would give the
terminal back. So when a command shell started from the Erlang shell
crashes or is killed while its line holds the terminal, the Erlang
shell's group, to which the console returns its input, reads at once,
and its `Ctrl-C` goes to the console; no rule needs to list the ways a
shell can end.

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
streams and capabilities: its grants and its facets, each by its name,
from which `erx_cmd:facet(Ctx, Name)` returns the facet or
`{error, no_facet}`. A module declares the facets it needs with
`-erx_needs(Names)`, which the shell checks before it runs the command,
and a heap larger than the default with `-erx_heap(MiB)`
([Pipelines](#pipelines)).
A session's facets are its domain's (`erx:caps/0`):
each facet the domain service minted for the domain, a pid by its name,
the inspect facet among them. A session's inspector
queries, of its own domain's paths included, go through that one facet,
whose scope, its principal's domains or `root`'s `all` in a development
build, the domain service fixed when it minted the facet and the session
never states ([design-live.md](design-live.md#the-inspect-service)); a
domain that holds no inspect facet gets no inspector answer, and its
runtime makes up no scope of its own. Its own process and port tables
are not inspector queries: `ps` and the `Ctrl-T` line read them in the
session's runtime, with or without the facet. The system domain's session, handed none,
reads at scope `all` in its own runtime and holds, for each service of
the system domain that runs in that domain, the value `local`: the
service is the domain's own, and the entry only meets the command's
`-erx_needs`. A command reaches a `files` service by one path in every
session, the system shell's included, and never looks at the value of
its entry: each `files` service of the system domain mounts one grant
of its tree, bound to the system domain, in the system domain's own
namespace, at the point where a session mounts its facet of the
service, as `/proc` and `/dev` are mounted there. Both mounts take the
point from one table of `erx_ns`, its places (`erx_ns:mount_facets/1`
for a session's facets, `erx_ns:mount_own/2` for the system domain's own
grants). So `reboot`
writes `/machine/ctl` and `service` writes the start service's `ctl`
in the system shell as in root's session. It never holds
`net`, since the system domain holds no `net` grant
([design-system.md](design-system.md#the-manifest), property 15), so
the network utilities run in a session that holds it, root's at the
UART in a development build, and not in the system shell. A command
that names a module of a service, or a path under the point where its
tree mounts, declares that service's facet, `ifconfig`, `ping` and
`host` the network stack's `net` and `reboot` the `machine`, and no
other module of the command shell's application names one, which a
build check proves (SH1), so in a session without the facet, the
system shell among them, the command fails with `ifconfig: no_facet`
before it starts. The check is a guard
against a slip, not the boundary: what a session reaches rests on its
domain, whose release ships no service's own modules and whose network
client answers `eacces` without the `net` facet. `ps` lists the
session's own table and `dmesg` reads its namespace's `/proc`, so
neither declares a facet.
`erx_cmd:write/2` writes bytes to standard output, waiting while 64 KiB
are in flight to a neighbouring Erlang stage, while a pipe has no room or
while the tty has none ([design-live.md](design-live.md#the-tty));
`erx_cmd:read/1` takes the next bytes or `eof` from standard input, and
`erx_cmd:read_line/1` the next line, at most 64 KiB, or `eof`; these
are a command's only reads of its standard input, and `io:get_line/1`,
`io:get_chars/2`, `io:get_password/0`, `io:read/1`, `io:fread/2` and
`io:setopts/1` through the group leader answer `{error, enotsup}`
([Compatibility](#compatibility-and-migration));
`erx_cmd:isatty/2` says whether a standard stream is the terminal
([Pipelines](#pipelines)), and `erx_cmd:columns/1` and `erx_cmd:rows/1`
give the terminal's width and height, `COLUMNS` and `LINES` first, as
FreeBSD's `ls`, `ps` and termcap read them, then the size the session's
tty holds when a standard stream is the terminal, else `unknown`; in a
command domain, which no terminal call leaves, only `COLUMNS` and
`LINES` ([design-runtime.md](design-runtime.md#native-programs)).
`erx_cmd:catch_events/1` opts the calling process in to `Ctrl-T`'s info
request and to size reports, and `erx_cmd:requested/1` takes the reports
of one kind pending for it
([`Ctrl-T`](#ctrl-t-status-and-the-info-request), [Window
size](#window-size)).

A command's terminal is its standard input when that is an open of the
session's tty ([Pipelines](#pipelines)), and four calls reach it:

```erlang
-spec tty(ctx(), tcgetattr | {tcsetattr, erx_tty:termios()} | winsize) ->
          {ok, erx_tty:termios()} | ok | {ok, {Rows, Columns}} |
          {error, enotty}.
-spec watch(ctx()) -> {ok, reference()} | {error, enotty}.
-spec read(ctx(), {ready, reference(), [{read, 4096}], non_neg_integer()}) ->
          binary() | eof.
-spec stop(ctx()) -> ok | {error, enotsup}.
```

* `tty/2` sends the relay the `{tty, Open, Request}` a program's handler
  sends for a program ([design-programs.md](design-programs.md#the-terminal)):
  `tcgetattr` and `tcsetattr` read and set the tty's `termios`, which
  `erx_tty:set/2` checks whole, and `winsize` answers the size the master
  last reported. A `tcsetattr` from a job that is not in the foreground
  stops the job, as `stop/1` does, and is made once `fg` brings the job
  back: the relay answers it `{background, false}` and changes nothing,
  and `tty/2` calls `stop/1` and sends it again when that returns, as
  FreeBSD's terminal stops a background process group that sets it with
  `SIGTTOU` and makes the change once the group is in the foreground
  (`sys/kern/tty.c:570-607`, `:480-496`); a job continued by `bg` stops
  again at its next `tcsetattr`. An Erlang command has no signal state to
  ignore `SIGTTOU` with, so this is its only path. Standard input redirected from a file, a pipe or
  `/dev/null` answers `enotty`, and so does every call in a command
  domain, whose stream relay only copies bytes, and in the system shell,
  whose console has no tty: a call never reaches the session's terminal
  through a stream that is not it.
* `read/1` on the terminal reads with the relay's requests
  ([The terminal relay's protocol](#the-terminal-relays-protocol)): it
  asks the relay for one ready report, the line discipline's
  `read_wait` with the 4 KiB it will read as its count, receives the
  report, calls `erlang:yield/0`, and sends `tty_read` with the report's
  signal number, which the relay answers at once through `read/3`; with
  `VTIME` set, the line discipline's `timer` ends the wait. The yield
  between the report and the read lets a process that a signal has ended
  exit before it takes a byte ([A reader the signal
  ends](#the-terminal-relays-protocol)). `VMIN` and `VTIME` mean what
  `erx_tty` makes them mean ([design-live.md](design-live.md#the-tty)).
  In cooked mode a line is read, and `Ctrl-D` at the start of a line
  gives `eof`, from the relay's `eof`. In raw mode a timed read that ends
  with no bytes returns `<<>>`, from the relay's `{ok, <<>>}`, never
  `eof`. A read answered `eagain`, because another reader of the job beat
  it to the bytes or a signal came since its report, waits for the next
  report. In a command domain the startup message names a standard input
  that is the terminal `write`, since the stream relay's open of the
  terminal is write-only
  ([design-runtime.md](design-runtime.md#native-programs)), and a read of
  it ends the command with status `ebadf` without leaving the domain, as
  a line over 64 KiB ends it with `line too long` ([A reader the signal
  ends](#the-terminal-relays-protocol)).
* `watch/1` arms that ready report and returns at once with the open's
  reference `Open`. The report arrives as the relay sends it, `{ready,
  Open, [{read, 4096}], N}`, which the caller's `receive` matches with
  `Open` bound and hands whole to `read/2`. `read/2` makes one read on
  that report, after the same yield, and never waits: it returns the
  bytes, `eof`, or `<<>>` when the relay answers `eagain` or a timed read
  ended with nothing, and the caller arms the next report with
  `watch/1`. So a command's one `receive` takes keys, size reports and
  its own timers together, as `vi`'s does
  ([design-vi.md](design-vi.md#the-command-at-the-edge)), arming the
  first report before its loop starts.
* `stop/1` stops the command's own job ([Job control](#job-control)).

No other source of authority exists for a
command: the system domain's services are reached only through facets in
the context and through the trees its session's namespace mounts, a
grant's in a session and the system domain's own in the system shell.

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

**The shell's first variables.** The terminal a shell starts on may carry
`vars`, variables in the evaluator's own form, each name with a list of
words of at most 256 bytes together (`erx_shell_script:first_vars/1`, which
checks them once as they arrive). The shell sets them once, as it starts,
over its own defaults (`$prompt`, `$*`), and never reads `vars` again;
`rc -c` on a tty takes the same map through the same check. The code that builds the
terminal chooses every value: a tty of an SSH channel sets only `TERM`,
to a name `abi/terminal.txt` lists, `vt100` for any other the client
asked for ([design-ssh.md](design-ssh.md#sessions-ttys-and-shells)), so
no byte a peer sends becomes a variable.

**Interaction with other subsystems.** The console carries the bytes of
the session's tty
([design-live.md](design-live.md#the-tty)); each program's handler
starts it through the spawn path, the command server gives it its
process id and keeps the process table, and the port
driver creates, pauses and ends their sub-spaces
([design-programs.md](design-programs.md),
[design-runtime.md](design-runtime.md#programs-as-ports)); `/proc`, the
inspector and the code store are reached through Erlang commands with the
facets in their context ([design-live.md](design-live.md)); and `mount`
and `umount` change the session domain's namespace
([design-files.md](design-files.md#building-binding-and-mounting)):

* `mount`, with no argument, prints one line for each entry of the
  namespace table, `SOURCE on POINT (TYPE, OPTIONS)`, as FreeBSD's does.
* `mount [-r] SOURCE DIR`, SOURCE a directory the session already
  reaches, such as `/media/disk0/s1`, places that tree at `DIR` too,
  over `erx_ns:bind/2`, or `bind/3` with `[ro]` for `-r`. `-r` makes a
  read-only view: writes through `DIR` answer `erofs`, while what the
  entry reaches stays as its server serves it and other entries may
  still write it, which is weaker than a read-only file system
  ([design-drives.md](design-drives.md#placing-a-volume)).
* `mount FILE DIR`, FILE a package file of `/apps`, mounts its EROFS
  image read-only at `DIR`, with the layout of the header the `apps`
  tree served, read through the same open as the image, and answers
  `einval` for any other file
  ([design-packaging.md](design-packaging.md#apps)).
* `umount DIR` removes the entry at `DIR`, over `erx_ns:unmount/1`; it
  flushes nothing and ejects nothing.

"Mount" here is the session's act, placing a tree in its namespace, as
on an NFS client; a server's mounting of its own media, such as the
media domain's of a drive's volumes, is the server's. The names are
FreeBSD's and promise less: there is no device argument and no `-t`,
since a session holds no device and a server names its own formats. A
SOURCE under `/dev`, or a `-t` option, is refused with a message naming
`mount [-r] /media/diskN/sN DIR`, and `umount` of a path that is no
entry with one naming `echo eject > /media/diskN/ctl`.

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
* **A command's `io` input is refused.** In a command run by the command
  shell, `io:get_line/1` and every other `io` input function, and
  `io:setopts/1`, return `{error, enotsup}`, where stock OTP would read
  the terminal through the shell's group: a command reads its standard
  input with `erx_cmd:read/1` and `erx_cmd:read_line/1`, which follow its
  pipe or redirection, and reaches the terminal with `erx_cmd:tty/2`
  ([Interfaces](#interfaces)). Code that prompts through its group leader
  works under `erl`, whose group is stock's.
* **Two limitations at the terminal**: a key typed
  between two `Ctrl-C` within one round trip of the shell appears in the
  next line, where it is seen before anything runs
  ([The ask](#the-terminal-relays-protocol)); and a process left running
  by a finished job that reads the terminal waits until the session ends,
  where FreeBSD fails the read with `EIO` ([Reading in the
  background](#job-control)).

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
| A command in a command domain reads a standard input that is the session's terminal | `erx_cmd` there, from the stream's mode `write` in the startup message, without sending the read | nothing of that stage; the typed input stays in the tty for the next reader | the stage ends | its stage's status is `ebadf` |
| Signals the relay counted for a shell have not reached it a second after a `foreground` answer showed them | the job table's check ([Four places agree on what counts](#the-terminal-relays-protocol)) | the shell and its jobs; the jobs' terminal reads stay suspended | the user, with `exit`, which starts a fresh shell | one line, `rc: N terminal signals not received; commands cannot read the terminal; exit starts a new shell` |
| The relay refuses a `foreground` | the shell, from the answer | nothing of the shell: it ends with the request and the answer in its exit reason | the console, which starts a fresh shell, as at any crash of the shell | the new shell's banner |
| An evaluator's Erlang stages do not fit the stage allowance | the shell, before it starts them | nothing: no stage runs | none | a foreground line waits for running stages to end, and fails with `too many stages` when it could never fit; a background job, a substitution or a pipeline inside a stage fails with `too many stages` at once |
| A program cannot start: no such command, a quota, a pipe's read ends, the session's budget, the spent process ids | the stage, from `start/1`'s answer | nothing: the ends made for the program are gone, so the line's other stages see the end of their pipes | the spawn path, which undoes each step it took ([design-programs.md](design-programs.md#starting-a-program)) | the reason as the stage's status, such as `not found`, `permission denied` or `quota` |
| A stage crashes or faults | the shell's monitor on an Erlang stage; a program's exit or fault record, through its handler's exit, which the stage that started it monitors | nothing: a crashed stage's pipe ends close with it, and a program's with its image | the session's pipe server, and the port driver for a program ([design-programs.md](design-programs.md#a-programs-end)) | the neighbouring stages see the end of the stream or a broken pipe; `$status` lists the crash or the signal |

**Diagnostics.** `jobs` lists each job's stages, programs and state; the
inspector shows the session's processes and its programs as ports under
the session. A crashed stage's `$status` is `crashed`, and one its heap
limit or its job's end killed is `killed`, never the crash's reason: a
reason and its stack carry the shell's variables, which must not reach a
status, a diagnostic or a log. Every process that evaluates the shell's
source or runs what it calls, a line, a job, a stage, a subshell, a
backquote, an `&` block, an Erlang command or a program's starter, starts
through one funnel, `erx_shell_runner:spawn_evaluator/3`, which sets its
heap limit with no report, ends a crash with a fixed reason, and reads
any other end, the exit of a linked pump included, as `crashed`, or
`killed` when the end was a kill; the
chokepoint check `evaluator-spawns` refuses any other spawn in the
evaluator's modules.

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

The tests below name each area's oracle and harness once, and list with
each area the seeded faults that must make its tests fail; areas with no
seeded fault list none.

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
* **Interaction**, through a scripted terminal: line editing, history,
  completion and job control (`Ctrl-Z`, `fg`, `bg`, `Ctrl-C`, `kill %N`)
  on jobs of Erlang commands, of programs, of both and of programs three
  generations deep, including on Fiasco a stopped mixed job whose
  programs run on; helpers that a stop holds and that none survives the
  end; output and error streams kept in order; a flood stopped by
  `Ctrl-C` within a second at 115,200 baud; a program that stops draining
  its channel without making the relay unresponsive; and `SIGCONT` from
  another program of the POSIX session. Seeded: a shell that reads on
  when the evaluator ends, which prints the prompt while a program that
  catches `SIGINT` still runs; and a `Ctrl-C` that ends only the stages'
  evaluators by exit signal, which lets an unlinked helper's file grow.
* **`Ctrl-T`** ([`Ctrl-T`](#ctrl-t-status-and-the-info-request)):
  * `erx_tty`'s exploration, run differentially against a host
    pseudo-terminal with `NOKERNINFO` set, since macOS's tty takes
    `VSTATUS` as FreeBSD's does. Seeded: dropping the `IEXTEN` condition,
    or echoing the key.
  * `status/3`'s leading newline and its 256-byte room rule. Seeded:
    removing either rule.
  * `erx_tty_info`'s choice of member, checked exhaustively over small
    sets against a model of the five rules, and golden lines with each
    field in turn `unknown`, `partial`, `timeout` and `unsupported`.
    Seeded: swapping rules 1 and 2; a formatter that prints a missing
    value as 0 or prints a status token; bypassing the line escape for a
    name holding `ESC ] 8 ;`, a newline and a bidirectional override.
  * The job table's `info/1` for an event whose job has ended. Seeded: a
    table that answers with its current foreground.
  * Erlang commands (`cp` from a test server that delays each piece).
    Seeded: a `cp` that does not call `catch_events`; a report that sends
    the requests before it writes the line.
  * Programs (FreeBSD's `sleep` as a test program). Seeded: making
    `SIGINFO`'s default action end the program.
  * The prompt and `erl`, where `Ctrl-T` transposes. Seeded: a console
    that maps the key to `info` while the shell's own line is read.
  * FreeBSD as the oracle: the FreeBSD 15.1 oracle guest
    ([design-network-stack.md](design-network-stack.md)) runs `sleep 30`,
    `cp` of a large file and `cat | cat` on a pseudo-terminal, sends `^T`
    mid-line and at column 0, and the lines erXos gives are compared with
    every number masked: fields, the two spaces before `cmd:`, the
    leading newline and the no-job texts, and `cp`'s and `sleep`'s own
    reports byte for byte. Seeded: a one-space separator.
* **The terminal relay's protocol**
  ([The terminal relay's protocol](#the-terminal-relays-protocol)):
  EUnit cases of `erx_session_relay` against a fake master and a fake
  console, with the test process acting as one shell. Seeded, each
  failing its case:
  * a relay that sends a watch's report before its answer;
  * one that arms every wait whatever its holder, so a background job is
    reported before `foreground`;
  * a console open that is never parked, which takes a job's line;
  * one that sends the console input as it arrives, and a read that
    ignores its `Max`, which hands `cat\nsecret\n` to the console's first
    one-byte read;
  * an editing setting with `ISIG` clear, which returns `Ctrl-C` as a
    byte with no event;
  * for libedit's rule on `foreground, console`: a `Left` that is the new
    `termios`; a holder changed before the check; an `adopt/2` without its
    masks; one that ignores `ICANON`; an editing setting that keeps the
    cooked `VMIN`; one that clears `ICRNL`;
  * a relay that does not check the open's holder on `tcsetattr`, and one
    that refuses `sigttou_ignored`;
  * a read wait that ignores its count under `VMIN` 10;
  * a relay that does not monitor an open's maker;
  * for the events: `sigtstp` mapped to `interrupt`; the console's events
    sent to the shell; a relay that keeps the first group the console
    named; one that counts `info` as a signal;
  * for a signal's suspension of a job's reads: a suspension that also
    refuses `tcsetattr`; a `current` that sets the cooked `termios`; a
    suspension that only parks waits, so a delivered report still reads;
    a relay that ignores the read's number;
  * a single suspension flag that any `foreground` naming the holder
    clears, which lets a job read `bg\n` typed after `Ctrl-Z`;
  * a relay that counts no signal it sends the console, and one that
    counts the console's `quit`;
  * one that counts a console signal for the group of the last
    `foreground`, which breaks the return from `erl`;
  * one that keeps any `Seen`, and one that takes `current` from any job;
  * an answer that carries the `Seen` it was sent in place of `Sent`;
  * a relay that answers the end of file `{ok, <<>>}`;
  * one count for the whole relay, which leaves a second shell's job
    suspended;
  * a relay that does not monitor the shell's group, which leaves the
    console without the terminal when the shell ends;
  * a relay that also registers a second name;
  * a relay that ignores an open's mode, whose write-only open reads;
  * modules that call `open_reader/2`, or send `{open, Job, read}` by
    name or to a relay's pid, each reported by the reader chokepoint
    checks (seeded in `test/host/chokepoints_test.rb`);
  * a `tty_write` answered when it arrives while output is stopped, and a
    drain answered when the queue empties, before the master's answer.

  `erx_session_tty:open/1`'s extra ttys run beside the domain's line,
  whose relay alone keeps `erx_tty_owner`.
* **The console on demand**: EUnit cases of `erx_console` of the session
  role, with its group and relay, against a fake master and a test shell
  that counts the signals reaching it. The cases trace `rm -i` with
  `Ctrl-C` and `y\n` typed before the shell acts, typed-ahead lines, the
  guard, UTF-8 held across asks, an interrupt queued before a read, keys
  of several bytes, unbounded input, late events and hangups. Seeded,
  each failing its case:
  * a relay that counts no signal it sends the console, whose job reads
    `y\n` as `rm` would and removes the file;
  * with the job table's core counting: a relay that counts the console's
    `quit`; a table that does not count `{G, suspend}`; a relay that
    counts a size change made while the console holds; a table that
    counts `{error, interrupted}` twice, which ends the shell;
  * a group without edit 72, which never asks; a console that reads
    4,096 bytes for an ask; one that reads up to the first CR or NL,
    which defeats a `shell_keymap` binding `^X` to `new_line_finish`;
  * a group without edit 74, on which a job's request takes the shell's
    line; the shell-only refusal applied to every group, which breaks the
    Erlang shell's evaluations; stock's fallback for an unknown entry of
    `requests` (`group.erl:671-672`), which crashes the group;
  * a console that keeps reading after it answers; one that ends the ask
    at every read; one that keeps what it holds at a signal; one that
    holds one set of bytes for every group; one that drops what it holds
    with each answer, which splits `C3 E2 82 AC`;
  * a relay that ignores the read's number, so a queued interrupt is
    passed over and the shell gets `ls\n`;
  * a group that asks at every `more_chars` and `blink`, and one that
    forgets its ask at an interrupt;
  * a property test of `edlin:edit_line/3` in each mode, over keymap
    sequences, prefixes and text given whole, a character per call and
    cut at random, which must give the same line and actions. Seeded,
    each restoring one of stock's answers that edit 72 removes: the key
    ended at `ESC [ 3`; no clause for a character that cannot continue
    `ESC [ 3`; a `~` taken after a complete key; `tab_expand` left at an
    escape prefix; a key `tab_expand` hands to `normal` read again from
    the start of the last input; stock's reversal at `new_line`
    (`edlin.erl:375-377`);
  * NL after each escape prefix, which the property test cannot see.
    Seeded: stock's clause after `ESC O` (`edlin_key.erl:82`) kept beside
    edit 73;
  * the bounds on unbounded input, measured on the whole group: edit 73
    without its bound on a sequence's digits; edit 73 without its
    seventh part, under which the group grows with a line that never
    ends; a seventh part that takes the count from the line at each key,
    whose reductions grow with the line; one that counts `edlin`'s
    elements, and one without the 32-codepoint cluster bound;
  * a console that carries an event out on its current group, and one
    that names its group only at its start;
  * an editing setting with `ISIG` clear, under which `Ctrl-C` does not
    interrupt `timer:sleep(infinity)` in `erl`;
  * a relay that sends the console no `erx_console_eof`, whose shells
    outlive a hangup; a console that takes a read's `eof` as the hangup.
* **The job table and the terminal**: EUnit cases of the job table's
  core, which returns the `foreground` requests and job effects it
  decides, in order. Seeded, each failing its case:
  * a table that acts on its current foreground for an event naming an
    ended job, and one that gives `current` only for the job the event
    named;
  * a table that gives `{foreground, A, cooked}` after a signal's
    effects, resetting the program's modes; one that gives no
    `foreground` after them; one that gives `current` for a job that is
    over; one that gives `current` for the named job whether or not it is
    the foreground;
  * a table that counts only the relay's events, so the next job's reads
    stay suspended for ever;
  * a shell that ignores a refused `foreground` and lives on;
  * one waiting window-size delivery for every job, and a table that
    delivers every `winch`;
  * for `stop/1`: a table that answers the caller when it marks the tag;
  * one that answers only at `fg` and `bg`; one whose `SIGCONT` report
    continues the whole job; one whose `bg` acts only on a stopped entry;
  * a table that drops the kept `termios` when the entry leaves stopped;
  * a `kill` builtin that ends the job for every named signal, and one
    that resumes a stopped job after every signal;
  * a table that ignores `Sent`, and one that prints the lost-signal line
    at the answer;
  * for `fg %1; cat`: a table that gives the terminal to the console when
    `fg`'s job ends; one that does not interrupt the line; one that gives
    `{foreground, Line, cooked}` before the line's interrupt.
* **A command at the terminal**, through `erx_cmd`. Seeded, each failing
  its case:
  * the editing setting not set at `{foreground, console, Signals}`, after
    a raw `tty/2`; a `tty/2` that falls back to the session's tty for a
    redirected stream;
  * a raw read under `VMIN` 0 and `VTIME` 1 that returns `eof`; a
    `read/2` that waits for the next report when another reader took the
    bytes;
  * a `read/2` without the yield before its read, which takes `y\n` from
    an ending job; an `erx_cmd` that reads a stream named `write`; a
    stream relay that opens the terminal for reading;
  * a background `tcsetattr` that goes through;
  * `size/3` that returns `winch` for an unchanged size; a shell that
    sends two messages for one delivery;
  * a `stop/1` that returns before `fg`.
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
  S-R4). The oracle is the FreeBSD 15.1 oracle guest
  ([design-network-stack.md](design-network-stack.md)): each case of the
  commands' corpus runs there with `LC_ALL=C` over the same input files,
  and erXos's output, standard error and exit status must match byte for
  byte. The corpus covers each option each command offers, alone and
  combined; `ps` lines compare with every number masked, and `ps -r`,
  `-m` and `-o` run over a fixed process table so the order is exact.
  Missing values (SH3) print `-` and keep the column count; names pass
  the terminal and field escapes. Seeded, each failing its case:
  * a `sort -n` that orders a non-number apart from zero, a `grep` that
    exits 0 on no match, an `ls` that heads a single directory;
  * an `ls` that ignores `erx_cmd:isatty/2`, where `ps` and `ls` are
    checked against the guest on a pseudo-terminal and in a pipe;
  * a `ps` formatter that prints 0 for a missing value or drops the
    column;
  * bypassing the terminal escape in `ls` or the field escape in `ps`;
  * a stream relay that names the terminal `{relayed, write}` without
    `tty`, under which a command domain's `ls` sends raw escape bytes to
    the master;
  * a writer between Erlang stages that sends without waiting, which
    exceeds 64 KiB in flight;
  * a `uname` selection in the order of the flags;
  * a `ping` that matches a reply of any sequence number;
  * a `host` reply line written unescaped;
  * a `grep` translator that passes `\d` through to `re`, against a
    table of `regcomp(3)` results taken from the guest. The translator
    has a fuzz target with its 4 KiB bound checked both ways.

  The network device suite runs `ifconfig`, `ping -c 3 10.0.2.2` and
  `host` on QEMU, and the production image's boot runs `uname -a`,
  `uname -i` and `uname -K` at the command shell.
* **Programs from the shell:** pipelines of toybox applets and Erlang
  commands in every order, redirections, `within` and narrowed
  namespaces; `ps`, `watch ps` and `xargs kill` through the facet the
  system domain makes for a command domain, with and without the right
  (`no_facet`, `ESRCH`), and the session's own `inspect` facet refused to
  that command domain (`badarg`); an executable reached only through an
  `rw` grant, which gives `permission denied`; and a program that starts
  200 children writing to one pipe whose reader is paused, every one of
  which starts.

## Performance

The command shell adds little to what it runs: parsing a line is
microseconds, a write between two Erlang stages is one message, and
a program's start, budgeted at 1 ms under HVF, dominates a line that
runs programs ([design-programs.md](design-programs.md#performance)).

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
estimate); and erXos chose rc's language, with a shell compatible with
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

**Ending the console's reading at each answer of its group.** The group
would tell the console when it answers a request, and the console would
read nothing more until the shell gave it the terminal again. It loses:
the group's word to the console, the group's answer to the shell and the
shell's next `foreground` are messages of three senders, which no process
orders, so each grant would need a name that the end of the grant
repeats; and an Erlang shell's group, which reads on with no shell to
grant it anything, would need an exception. Giving the command shell's
group one reader removes the read that the grant would have stopped
([The console reads on demand](#the-terminal-relays-protocol)).

**A reader of the job's own for `io` input.** Each job would get a group
leader that answers its processes' `io` input requests by reading the
terminal through an open of the job. It loses: the leader is a second
I/O server, which needs its own rules for encodings, prompts, options,
password echo, `get_until` callbacks, a line bound, cancellation and its
own end; a job has one leader but each stage its own standard input, so
`echo x | cmd` with `io:get_line/1` in `cmd` would read the terminal;
and no command needs it, since commands read through `erx_cmd`. The
guard of the command shell's group replaces it with one refusal
([The terminal relay's protocol](#the-terminal-relays-protocol)).

**Reads that stop only when the requester ends.** A job's reads would go
on after a signal's key, checked only against whether the process that
asked still lives. It loses: the process the signal is for lives until
the shell has acted, so it takes the keys typed after the key. Suspending
the job's reads in the step that makes the signal closes that gap with
one rule ([A signal suspends a job's input](#the-terminal-relays-protocol)).

**A suspension flag on the holder.** A signal would set a flag on the
job holding the terminal, and the shell's next `foreground` would clear
it. It loses: a `foreground` the shell sent for one signal clears the
flag a later signal set, so with `Ctrl-C`, `Ctrl-Z` and `bg` typed
together a job that catches `SIGINT` reads `bg`. Comparing the count of
signals sent with the count the shell has acted on keeps no flag, and a
`foreground` for an earlier signal ends nothing
([A signal suspends a job's input](#the-terminal-relays-protocol)).

**Counting only the signals the relay sends the shell.** The relay would
count the events it sends a shell and leave out those it sends the
console. It loses: a `Ctrl-C` the console takes after its group has
returned a line reaches the shell through the group, after the shell
has given the line the terminal, so the line reads the keys typed after
it, and `rm -i f`, Enter, `Ctrl-C` and `y` removes the file. Counting the
signal on both routes, and the shell counting what reaches it on both,
closes that with no extra message
([A signal suspends a job's input](#the-terminal-relays-protocol)).

**One sender for the console's signals.** The shell would name its
group to the relay at its start, the relay would send it every signal
the console takes for that group, as it sends a job's events, and the
shell would count only the relay's events and take its group's
`{error, interrupted}` only as the end of the line being edited. One
sender and one receiver would need no list of what counts. It loses:
the relay's event can reach the shell before the line the group is
still returning. `rm -i f` and Enter are read; the group returns the
line through the console, and before that message reaches the shell
the relay takes `Ctrl-C` and sends its event straight to the shell,
which still waits for a line, takes the key for its prompt and drops
it, then gets the line and gives it the terminal with the count
matched, so `rm` reads the `y` typed after the `Ctrl-C`. Only the
group knows whether a key came before or after the line it returned:
it answers the line request `{error, interrupted}` in the first case
and sends the exit signal `interrupt` in the second, in order with the
line (`lib/kernel/src/group.erl:519-526`). The relay sees the
console's reads, not where the editor ended a line, so it cannot tag
the event with that, and one process's messages to another keep their
order only from one sender
(`system/doc/reference_manual/ref_man_processes.md:507-511`).

**Learning the count with a call.** The shell, on its group's interrupt
or suspend, would ask the relay for the count and send it back as
`Seen`. It loses: the answer counts every signal made so far, including
one still on its way through the console and the group and a relay event
still waiting in the shell's queue, so it marks them carried out before
the shell has seen them. With two `Ctrl-C` typed at the console as a
line starts, the first one's call answers 2, and the line reads the keys
typed after the second. A count of what has reached the shell cannot run
ahead of it.

**Carrying the number through the console and the group.** The relay
would number the events it sends the console, and the console and the
group would pass the number on to the shell. It loses: stock's group
delivers an interrupt as the exit signal `interrupt` or as `{error,
interrupted}` (`lib/kernel/src/group.erl:519-526`), which the Erlang
shell's evaluator also takes, so the number needs a new reason or
message in every group and an edit to `erx_console`, and the shell must
still merge it with the numbers of its own events, which arrive by
another route in another order. Counting on both ends carries nothing.

**Counting by the shell's process.** The relay would key the numbers by
the process the events go to. It loses: a key the console takes names a
group, and stock's group tells no one which process is its shell, while
such a key can arrive before the shell has made any request. The group
is the one name both routes already carry, and each command shell has a
group of its own, so a count per group is a count per shell.

**A yield after the read.** `erx_cmd` would yield after the relay's
answer, so a reader that a signal ended exits before the command sees
the bytes. It loses: the bytes have left the tty by then, so the reader
the job table chooses after the signal never sees them, and in `prog |
cmd` the `y` typed after `Ctrl-C` is gone. The relay must refuse the
read before it takes anything, which the signal number in the report
and the read does ([A reader the signal
ends](#the-terminal-relays-protocol)).

**The relay keeping each open's report number.** The relay would record
the signal number when it sends a report and check it at the read, with
no number on the wire. It loses: a reader may read before its newest
report has arrived, and the relay's record then names a report sent
after the reader's pick, which may follow the mark that ends it. Only a
number the reader received is known to precede its pick.

**The relay asking whether the reader's job is ending.** The relay would
read the mark of the reader's tag at each read and refuse a read for an
ending job. It loses: no call reads another process's tag
([design-runtime.md](design-runtime.md#scheduling)), so this needs a new
runtime call, and a program's handler open carries the same job, whose
program may outlive `SIGINT` and must go on reading once the handshake
exists. The pick the reader passes is a check the runtime already makes.

**The console reading with `send_request/2`.** The console would send
its reads asynchronously and take each answer in its main loop, in
order with the relay's events, so that a call's receive does not take
the answer past a queued event. It loses: the signal number already
refuses a read made across a signal, so no answer can carry a byte typed
after an event the console passed over, and the console's read is a call
like its other requests.

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

Its language, its editing and its toolbox are decided, and a
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
* **What the shell does when signals do not arrive.** A disagreement
  among the four places that count signals is a bug; when it leaves the
  shell short, the shell prints one line and lives on
  ([Four places agree on what counts](#the-terminal-relays-protocol)).
  It could instead end, as it does at a refused `foreground`, and the
  console would start a fresh shell. Ending loses the user's jobs on a
  check that a signal held up past a second under heavy load could also
  trip; the line says only what was measured and harms nothing.
  Recommended: print the line, and revisit if the fault is ever seen in
  use.

## References

* T. Duff, "Rc - The Plan 9 Shell", Plan 9 Programmer's Manual, AT&T
  Bell Laboratories, 1990; plan9port at `1f139691`, Byron Rakitzis's rc
  and tcsh, as checked in
  [research-boards-storage.md](research-boards-storage.md#the-command-shells-oracle).
* Erlang/OTP 29.1.2: `lib/stdlib/src/edlin.erl`, the line editor whose
  editing, history and expansion hook the shell uses.
