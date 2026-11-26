# Find and act: the palette, routes and bindings

**Find and act** is the layer of a person's desktop session above its
windows: a **palette**, one window in which the person finds any command
the session can run by typing part of its name, and in which a typed
value on the screen, a process in stats or a file in files, shows the
commands that take it, the usual one first. It adds no authority and no
second command system. Its central construction is one sentence: **an
act is a line of rc that the session's own shell runs as if the person
had typed it at a new shell of the session.** The table of commands is the session's command
namespace, which already carries each command's argument types; a
**route** is a rule that turns a typed value into such a line; the
palette, the context menu on a value, the Services-style "act on this"
entries, a bound key and the rc command `plumb` are only different ways
to build the line.

The architecture is [design.md](design.md); the command shell, its
command namespace, its catalogs and its evaluator are
[design-shell.md](design-shell.md); windows, presentations, the widget
toolkit, the terminal and the reserved chord are
[design-display.md](design-display.md); the desktop's own programs are
[design-desktop-programs.md](design-desktop-programs.md); apps and the
start service are [design-apps.md](design-apps.md); the inspector is
[design-live.md](design-live.md). The survey that asked for this layer
is [research-ui-synthesis.md](research-ui-synthesis.md), with its inputs
`~/erxos-history/docs-archive/research-ui-ux-ideas.md` (history commit `e38149b`) and
`~/erxos-history/docs-archive/research-ui-secure.md` (history commit `e38149b`).

Decisions every reader of this document needs:

* **An act is a line of rc run by the session's shell.** Whatever the
  person triggers, a palette entry, a value's offer, a bound key or
  `plumb`, becomes one unit of rc text run in a new evaluator of the
  session's shell, with the session's capabilities and the shell's
  per-command facet checks (design-shell's SH1), as a job of its own
  that ends whole. A value enters the line only as an rc variable,
  `$1`, which rc never splits or globs again, so it is always exactly
  one argument.
* **The table is the session's command namespace.** Commands, their
  help, the facets they need (`-erx_needs`) and the types of their
  arguments (`-erx_args`) come from the catalogs the session already
  builds ([design-shell.md](design-shell.md#commands)). Find and act
  keeps no registry of its own.
* **Routes are data the person keeps.** An ordered list of rules says
  which line a value of a type opens, which types the palette lists by
  name, and which keys run which lines. The person's file,
  `$home/lib/act`, comes before the defaults the release ships. Since
  its lines run with the session's authority, only the person's own
  sessions and the programs they give their whole namespace write it.
  Their meaning is fixed here; they are written as lines in rc's word
  syntax ([decision 1](#decisions)).
* **One window shows every way in.** The palette is a window of the
  person's session. Opened by a key it searches commands; opened on a
  value, at the pointer, it lists that value's offers, which is the
  context menu and the Services entry in one.
* **A value on the screen only opens the palette.** The terminal and
  the widget server hand a presentation to the act service and do
  nothing else; nothing runs until the person picks a line the palette
  shows beside the value it acts on.
* **The display keeps its one reserved chord.** The palette key is the
  session's own binding, taken in the session's own windows; it is not
  reserved and the display does not know it.
* **Nothing crosses a domain.** The act service is reached by a
  registered name, and registered names never leave their domain
  ([design-domains.md](design-domains.md#frames)). No app adds a
  command to a person's palette; an app is started only through the
  start service's own judgement.

## The problem and the evidence

The survey's verdict on erXos's desktop is that its plumbing is current
and its interaction layer is rio's: "a right-button menu, dragging a
rectangle to place a window, no launcher, no palette, no 'open this
with that'" ([research-ui-synthesis.md](research-ui-synthesis.md),
section 1, item 3). It places what erXos can do that no shipping desktop
does in "find and act, identity and inspection", and asks for one design
in which a table of typed commands, routes from presentation types, a
palette, a context menu and bindings are one mechanism, not a plumber
beside a command table (section 2.6, "Commands"; section 4). Decision D5
of that record, accepted on 2026-11-15, starts the design and puts its
code after stats, clock, month and files run on the desktop
(section 8).

The consumers, each a person at a desktop session:

* **Launching.** stats, clock, month, files and a terminal start only
  from a shell, and an installed app only by typing `service NAME
  onestart display=D` ([design-apps.md](design-apps.md#interfaces)).
  design-display already expects "a launcher's `start APP display=D`"
  ([design-display.md](design-display.md#a-displays-session), "An app a
  person starts").
* **Acting on what is shown.** A pid, a domain or a budget in stats or
  an inspector window is a presentation, typed and bound to its value
  ([design-display.md](design-display.md#presentations)); a click on it
  selects a row or inserts its text at a terminal, and offers nothing
  else.
* **Opening a file.** files previews text and otherwise says that the
  desktop has no viewer for the item: "Nothing is started: files starts
  no program and no app"
  ([design-desktop-programs.md](design-desktop-programs.md#what-it-reads-and-does)).
* **Every program's own plumbing.** Without one shared way, each
  program that wants "open this" or "inspect that" grows its own menu,
  and every later program copies it (synthesis, section 3, item 12).

What the systems the survey read teach, as that record reports them
(the archived `research-ui-ux-ideas.md`):

| System | What erXos takes | What it leaves |
| --- | --- | --- |
| Genera and CLIM | a command loop: acquire a command by menu, typed name or a clicked object; acquire its arguments, where visible objects of the right type can be clicked or typed with completion; run it ("Presentations and commands") | the single address space, in which a presentation was the object |
| Oberon | a command is a procedure `M.P`, not a program ("Presentations and commands") | running any clicked text: here only a line the person chose runs |
| NeXT Services | an application indicates only the types of data it uses, and the operations that take that type are offered ("Object and document desktops") | applications installing entries unasked, which clogged the menu |
| Plan 9's plumber | rules in the person's own `lib/plumbing` decide where a value goes, so the person does not carry data from program to program; `plumb start window acid $0` starts a command in a new window with the value as its argument (Pike, "Plumbing and Other Utilities", as fetched for that record, `plumb.txt`, lines 18, 145 and 219-226) | the message server and its ports, the classification of untyped text by regular expressions, delivery to a running program |
| Quicksilver, Raycast, VS Code | one keyboard-first search over every action; an object, an action and an argument ("Find and act") | each product's own registry, which knows nothing of the selection's type |
| Durden | every action is a path, so bindings and scripts reach all of them ("Current platforms") | a virtual file tree: here every act is already a line rc can type |

Plan 9's plumber spends most of its rule language turning untyped text
into a type: a pid is recognised by `data matches '[0-9][0-9]+'` and
`arg isdir /proc/$0`, and the text under the cursor is winnowed to the
match that touches it (`plumb.txt`, lines 186-190 and 221-229). erXos's
presentations arrive typed, so that half of the plumber is not needed
for them, and what remains of a plumb rule, "a value of this type goes
to that command", is a route over the typed table.

## What it builds on

* **A typed command table.** A command module declares its name and
  help, the facets it needs with `-erx_needs` and the presentation types
  of its arguments with `-erx_args([pid, ...])`; the build emits each
  release's catalog from them, and a session builds its command
  namespace from the catalogs of the releases it holds
  ([design-display.md](design-display.md#presentations);
  [design-shell.md](design-shell.md#interfaces),
  [design-generation.md](design-generation.md#configuration-and-command-catalogs)).
* **Half of CLIM's argument loop, inside a terminal.** While the shell
  edits a command whose argument types it knows, it writes an input
  context, and the terminal highlights the presentations of those types;
  a click inserts the value's text into the line
  ([design-display.md](design-display.md#the-terminal), "Presentations
  in a terminal").
* **G4, a presentation grants nothing.** The terminal's only actions on
  a presentation are inserting its text and highlighting; a widget's
  only action is `{select, Type, Value}` to its application; `erx_term`
  and `erx_ui_server` call no facet, which an xref check proves
  ([design-display.md](design-display.md#invariants), G4; Chokepoints).
* **What a link shows is not what it holds.** A program may write a
  link whose shown text differs from its URI; the click inserts the
  URI's text, which the command line shows before anything runs
  ([design-display.md](design-display.md#security), "Presentations
  grant nothing").
* **The keyboard moves only on the person's act.** A window takes the
  keyboard only by the person's click or the menu; a client's `wctl`
  `top` raises a window and gives it no keyboard, and a new window is
  current only once clicked
  ([design-display.md](design-display.md#windows-and-the-window-system),
  "The current window"; [Interfaces](design-display.md#interfaces)).
* **One reserved chord**, kept by the display's router before any
  policy, which reaches no window and opens nothing yet
  ([design-display.md](design-display.md#windows-and-the-window-system),
  "The reserved chord").
* **Registered names stay in their domain**
  ([design-domains.md](design-domains.md#frames), "Registered names
  stay inside their domain").

## Requirements

* **FA-R1.** From any window of a person's desktop session, the person
  finds and runs any command of the session's namespace that the
  session can run, by typing part of its name.
* **FA-R2.** A presentation on the screen, in a terminal or a widget,
  and a file or folder in files, can be acted on: the person sees the
  commands that take it, the default first, and runs one with the value
  as its argument.
* **FA-R3.** What runs is a line the person could have typed at a new
  shell of the session, with the same authority and the same facet
  checks. No value, rule or gesture adds authority, and a program the
  person narrowed cannot write a rule.
* **FA-R4.** Nothing runs from a value on the screen without the
  person's choice of a line, shown with the value before it runs.
* **FA-R5.** Which line a value of a type opens is data the person keeps
  and edits, over defaults the release ships.
* **FA-R6.** rc reaches the same routes.
* **FA-R7.** A key the person binds runs a line in the session's own
  windows, the palette key among them; the display keeps its one
  reserved chord, and no binding takes a key typed as text.
* **FA-R8.** No app, kiosk or other domain adds a command to a person's
  palette or reaches the act service.
* **FA-R9.** Every parser of untrusted input has a fuzz target, every
  buffer has a bound, and a failure ends at most one palette or one act.

Outside this design: handing a value to an app that runs as another
principal, which is the powerbox of
the archived `research-ui-secure.md` section 6.5 and needs a
design of its own; "what is this?" for any pixel and the reserved
chord's overlay, which are the identity and inspection designs of the
synthesis (section 3, items 13 and 14); notifications; the web client,
whose sessions have no display window to open a palette in; and
plumbing untyped text, which [Alternatives
considered](#alternatives-considered) explains.

## The construction

```text
 a person's desktop session: one domain, one runtime
+--------------------------------------------------------------------+
| erx_term: button 3 on a link ------------+                         |
| erx_ui_server: secondary press on a node +- {offer, Object, Where} |
|   that carries `present`                 |                         |
| files: "Open with" ----------------------+  erx_act:offer/2        |
| erx_win:kbd/1: a bound key ------------------ {bound, Line, Where} |
|                                          |                         |
|                                          v                         |
| erx_act: one process, registered in this runtime only              |
|   the rules: $home/lib/act, then the release's defaults            |
|   erx_act_core:offers/4 and entries/5, pure                        |
|   owns the ETS table erx_act_bindings, which erx_win:kbd/1 reads   |
|   one palette per display; runs a bound line itself                |
|                                          |                         |
|                                          v                         |
| the palette: a window of the session, a pure core and a process    |
|   shows offers or matching commands; on the person's choice:       |
|                                          |                         |
|                                          v                         |
| erx_act_run: a new evaluator of the session's shell, a job of its  |
|   own: run_source(Line), $1 the value, $display the display        |
|                                          |                         |
|                                          v                         |
| the command, through the session's command namespace and SH1       |
+--------------------------------------------------------------------+
  rc reaches the same routes: `act`, `plumb` and `window` are commands
```

### Acts

An **act** is a unit of rc text and the variables it runs with:

```erlang
-type act() :: #{line := binary(),                 % rc text, at most 4,096 bytes
                 vars := #{binary() => [binary()]}}. % the act's own: <<"*">> and <<"display">>
```

`erx_act_run` runs an act as a job of its own. It starts the act's
evaluator with `erx_job:spawn/1`, so the act has a job tag that every
process it spawns takes, its pipeline stages and `&` blocks included,
and every program it starts is a row of the command server under that
tag ([design-shell.md](design-shell.md#job-control), "Jobs and their
tags"). The evaluator is made with `erx_shell_eval:new(Vars, Runner,
State)`, whose runner state holds the command table the session's shell
uses, the session's facets read for each command, and a working
directory and standard streams its caller names, and then runs
`run_source(Line, Sh)`. The palette and a bound key name the person's
home, standard input at its end, and standard output and error to one
collector, which keeps the first 64 KiB the line writes and counts the
rest; `plumb` names its own working directory and streams. The act is
over when its job is, as design-shell defines it: its evaluator has
ended and so has every program of its tag ("When a job is over"). The
result is the status, as rc sets it, and what the collector kept.

**The act's environment** is that of a new shell of the session, with
the act's own variables over it. `Vars` is the variables a session's
shell starts with, `$home` among them ([design-shell.md](design-shell.md#the-language),
"Language"), and then `*`, which holds the value's text when the act
has a value, so `$1` is that text, and `display`, the name of the
display the act was started from. An act sees no variable and no
function that a person set in a running shell, and changes none: it
belongs to no terminal, and each act's evaluator is new.

**Ending an act** is design-shell's ending of a job ("Ending a job"):
its tag is marked ending, which ends every Erlang process of the act at
once, whoever spawned it, and each of its programs takes `SIGINT` from
its handler. A window an act opens outlives it: `window`, `files` and
the other desktop commands ask their application's supervisor for the
window and return once it is open
([design-desktop-programs.md](design-desktop-programs.md#shipping-and-starting)),
so the window's processes are the supervisor's children and carry no
job tag, and `service NAME onestart` hands its app to the start
service. A line that should outlast its palette opens a window or
starts a service; an `&` block of the act is the act's and ends with
it.

Everything find and act runs goes through this one function, and every
requirement on what runs follows from it:

* **Authority** is the session's, because the evaluator is the
  session's and its runner reads the session's facets for each command;
  a command whose `-erx_needs` the session does not meet fails with
  `no_facet` before it starts, as at the shell (FA-R3).
* **Only what the session's shell could run runs**, because rc resolves
  a name in the session's command namespace and starts a path only
  through an `rx` grant the session holds
  ([design-shell.md](design-shell.md#commands)) (FA-R3).
* **A value is one argument**, because it reaches the line only as a
  variable, whose text is `lit`, never split by `$ifs` and never globbed
  (`erx_shell_eval.erl:68-74`); a `$1` expands to literal text and one
  word (`:654-656`). A file named `a b; rm -rf $home` is one argument to
  `vi`, with no quoting step that could be wrong. The guarantee is that
  rc never rescans a value on its own; a line that hands `$1` to `eval`,
  which joins its arguments into source (`:393-394`), or to `rc -c`,
  parses it again, so a route's line is code the person trusts, as a
  line typed at the shell is.
* **What runs is what is shown**: the palette shows the act's line
  verbatim and the value beside it, and the evaluator runs exactly that
  line with exactly that value (FA-R4).
* **An act ends whole**, because ending it ends its tag, which every
  process and program of the act carries however it was started
  (FA10).

The evaluator's stages are admitted within the session's stage
allowance like a background job's: when the allowance is full the line
fails at once with `too many stages`, and never waits
([design-shell.md](design-shell.md#invariants), SH2).

### Objects

An **object** is a value find and act can act on:

```erlang
-type object() :: {Type :: atom(), Text :: binary()}.
%% Type: a presentation's name (erx_present:marks/0), or file, or folder.
%% Text: the presentation's canonical text, or the absolute path.
```

All objects enter through one funnel, `erx_act:offer(Input, Where)`,
whose input is one of two forms:

* `{Type, Text}`, a presentation's name and text as binaries, from a
  terminal link, a widget's `present` property or `act TYPE TEXT`. A
  widget's property names its type as an atom, which the widget server
  turns into its name with `atom_to_binary/1` before it sends, so every
  name enters as text and is read one way: with `erx_present:type/1`,
  which makes no atom, and the text with
  `erx_present:parse/2`, the presentation reader with its fuzz target;
  the object's text is then `erx_present:text(Type, Value)`, the
  canonical form. A text that does not parse makes no object. The text
  is parsed whoever sent it, so the one check sits at the one funnel.
* `{path, Path}`, an absolute path in the session's namespace, from
  files or from `plumb` and `act`, which resolve their argument against
  their working directory first. A worker reads the path's information
  with `file:read_file_info/1`, which follows a link, unlike
  `read_link_info/1` (`otp/lib/kernel/src/file.erl:823-826`), within one
  second:
  a directory makes a `folder` object and anything else a `file` object;
  a path that names nothing makes none. A path is at most 4,096 bytes
  and holds no NUL; its other bytes are kept as they are, since it
  reaches a command only as a variable and the screen only through the
  line escape.

`Where` names the display the gesture came from, the window it came
from when there is one, and, for a pointer gesture, the point on its
screen: `#{display := Name, window => Id, at => {X, Y}}`. The window is
the one a keyboard pass starts from ([decision 2](#decisions)).

`file` and `folder` are not presentations: design-display's decision 16
keeps presentations to inspector paths, and no window shows a file as
one. They are object types of this design alone, so a route can name
them; a file presentation, if design-display adds one, becomes an
object with no change here.

One presentation is added for launching: the inspection schema's
`apps *name` path is marked `present app`, over a segment type of its
own, `app_name`, since a presentation over the shared `name` type would
make every attribute of that type an app
([Presentations](design-display.md#presentations): the generator
refuses two such presentations over one type).

### Rules

The rules are one ordered list of statements of three kinds. Their
meaning, below, is this design's; how they are written is [decision
1](#decisions).

| Statement | Fields | Meaning |
| --- | --- | --- |
| route | a type; for `file` only, one or more name patterns; a label; a line | an object of the type, whose last path component matches one of the patterns when it is a file, is offered the line under the label, with `$1` its text |
| list | a type | the palette's search lists every member of the type by name, each with its first offer |
| bind | a key chord; a line | the chord, typed in a window of the session's Erlang clients, runs the line |

The fields' bounds and checks:

* a type is a presentation's name, `file` or `folder`; a `list` type is
  a presentation of one variable segment whose marked path lies under a
  listing path, such as `pid` under `processes` or `app` under `apps`,
  so its members can be listed;
* a name pattern is at most 255 bytes, with `*` for any run of bytes and
  `?` for one character, matched byte for byte against the last
  component, as FreeBSD's fnmatch(3) does without flags; the matcher
  runs in time linear in the name times the pattern, with no
  backtracking;
* a label is 1 to 64 bytes of UTF-8;
* a line is 1 to 4,096 bytes that rc's parser accepts whole;
* a chord is one **trigger** with one to three **held keys**. The held
  keys are `kctl`, `kalt`, `kmod4` and `kshift` of
  `abi/formats/input.txt`'s `input_rune`, and at least one of them is
  not `kshift`. The trigger is any other member of `input_rune`, such as
  `kf1` or `kup`, or one printable character in the unshifted form a
  `kbd` record carries, but not `kaltgr`, which types characters on
  layouts that have it, nor a lock key (`kcaps`, `knum`, `kscroll`). So
  no chord is a key typed as text: a key alone or with Shift, the
  characters of a password among them, is refused, and a chord with no
  trigger or two is refused;
* a file holds at most 256 statements in at most 64 KiB.

**The reader**, `erx_act_rules:read/1`, is a pure function from bytes
to rules or to the first error with its line. It fails the whole file at
its first error, so a file is used whole or not at all. The person's
file is input to the session from whichever of its writers below last
replaced it, read again at every start of `erx_act` and every `act -r`,
so the reader holds to four rules, which its
fuzz target checks:

* **No atom from input.** Every name is matched as a binary against a
  closed table: the three statement kinds, the object types through
  `erx_present:type/1` and the words `file` and `folder`, and the key
  names through a table generated from `input_rune`. Reading files any
  number of times, good or bad, leaves the runtime's atom count where it
  was.
* **Refusal before construction.** A token outside a statement's shape
  fails the file where it stands, before any value is built from it, so
  nothing in the input sizes an allocation but the input's own length.
* **Bounded depth.** A statement holds at most one list, and that list
  holds words; a line nests at most rc's 256 levels.
* **Bounded memory and time.** `erx_act` runs the reader in a worker
  whose heap is capped at 8 MiB, rc's parse heap, killed when it
  outgrows it, and given one second. The input is at most 64 KiB and the
  reader's work is linear in it, but for each line's parse, which rc's
  own bounds hold.

A statement is one
source line in rc's word syntax: its kind, its fields and, for `route`
and `bind`, the line, which is the rest of the source line. The reader
cuts the file at its newlines and reads each source line's tokens with
`erx_shell_lex`. A source line that holds only blanks or a comment is
skipped. A field is a word or a quoted word, a keyword being read as its
word; the name patterns of a `file` route and a chord are each a
parenthesised list of such words; any other token in a field, `$`, `^`,
`=`, `;`, `&`, a pipe or a redirection, fails the statement. The line is
the source's bytes from the offset of the first token after the last
field to the end of the source line, kept verbatim, and
`erx_shell_parse:next_bounded/3`, given that text as `final`, must accept
it as one whole unit, which a quote or a here document that runs past
the source line never is. So the line the person reads in the file is
byte for byte the line the palette shows and runs.

The rules in force are the person's file followed by the release's
defaults: routes and lists in that order, so the person's routes come
first and the first offer is theirs where they wrote one; a `bind` of
the person's replaces the defaults' `bind` of the same chord. The
person's file is `$home/lib/act`, as Plan 9's plumber reads
`lib/plumbing` in the person's home (`plumb.txt`, line 145); `$home`
here is the home the session starts with, a fixed path of the session,
not the variable, which a line may change. A file that is absent is the
ordinary case. One that fails to read, is too long or fails the reader
leaves the defaults alone in force, and its diagnostic, `lib/act:LINE:
REASON`, heads every palette until `act -r` reads a good file.

**Who writes the rules.** A rule's line runs with the session's
authority, so whoever can replace `$home/lib/act` can make the session
run any line it can, as whoever may write `/etc/start.conf` may command the
start table ([design-apps.md](design-apps.md#the-start-table), "Where
the file is"). The writers are held to those who already hold the
session's authority over its files:

* **The person's own sessions.** The data partition's `home` service
  roots each session's grant at its user's home
  ([design-files.md](design-files.md#building-binding-and-mounting),
  "A user's home"), and a principal
  has one session template
  ([design-system.md](design-system.md#the-manifest), property 14), so
  every session that can write the file holds the capabilities of the
  session that runs its lines.
* **A program started with the session's whole namespace**, the default
  of [design-files.md](design-files.md#narrowing-for-a-program). It holds
  the session's files, and with them what the session reaches through
  files, `/proc` and, where the session mounts it, `/svc/start`. It
  holds no right beyond files, such as `signal`, unless `within -f`
  names one ([design-programs.md](design-programs.md#facets)), and a
  rule it writes runs with those rights: that difference is the residual
  [Security](#security) records.
* **Never a program or command the person narrowed.** A narrowed
  namespace holds no writable root that lies within the session's `lib`
  directory, `$home/lib`, or contains it: when it derives a narrowed
  namespace, the session refuses such a root with `EACCES`, judging the
  path the root has on its grant, not the name the line used, so a bound
  second name for the same directory does not escape it. A narrowed
  program therefore cannot write the file, nor rename `lib` or a
  directory above it, since none lies within its roots, and an Erlang
  command it starts runs in a command domain that holds only the
  program's own grants (design-shell's SH1). Handing a program `$home`
  to write is handing it the whole namespace, or naming the directories
  under `$home` it needs.

The session's `lib` directory is where the session keeps what it runs
on its own; `lib/act` is the one such file this design adds, and the
rule is on the directory, so a later one needs no rule of its own.

The defaults are a file of the `erx_act` application,
`erlang/apps/erx_act/priv/rules`, checked in. The build reads it with
the same reader and fails on any error, and on a route or bind whose
line's first command is not in the catalog of the desktop session's
release. For example:

```text
# A process: the inspector first.
route pid Inspect i $1
# An app: started on this display, in a session of its own principal.
route app Start service $1 onestart 'display='$display
list app
# A folder opens in files; text opens in vi, in a terminal of its own.
route folder Open files $1
route file (*.txt *.md *.log *.conf *.erl *.hrl *.c *.h *.rb *.sh *.rc) Edit window vi $1
# The palette key: the logo key with Space.
bind (kmod4 ' ') act
```

The defaults carry no route that changes a file or a service on a
value alone: installing a package stays `cp NAME.app /apps/`, typed
([design-packaging.md](design-packaging.md)).

The palette key is the logo key with Space because the logo key types no
character, so the chord takes nothing a program in a terminal reads, and
the shipped layout makes both Meta keys `Kmod4`
(`abi/keymaps/us.txt:116-117`). It is a rule like any other, which a
person changes in their file.

### Offers

`erx_act_core:offers(Object, Rules, Table, Facets)` is a pure function
that lists what an object can be given to:

1. every route of the object's type whose patterns match, in rule order;
2. then, by name, every command of the table whose first `-erx_args`
   type is the object's type, as the route `NAME $1` labelled with its
   name, which is NeXT's Services drawn from the declarations commands
   already make;
3. keeping only an offer whose line's first command is one the table
   holds and whose `-erx_needs` the session's facets meet, or is a path,
   which the table cannot judge, and dropping an offer whose line an
   earlier one already has.

The first offer is the **default**. The filter in step 3 is a
convenience, so the palette shows what can run here; the gate is the
shell, which checks the facets again when the line runs.

`erx_act_core:entries(Query, Rules, Table, Facets, Members)` lists what
the palette's search shows before any object is chosen: every Erlang
command and program command of the table the session can run, labelled
with its name and the first line of its help, but no builtin or
function, which acts on a shell's own state while an act's evaluator is
new each time; and for each `list` type, each of its members, `Members`
being the listings the palette read, with the member's first offer. An
entry matches when the query's characters appear in its label in order,
ignoring ASCII case; matches rank prefix first, then those that match at
the start of a word, then the rest, each group by label. The palette
shows at most the first 256, the bound of a `list` widget.

### The palette

The palette is a program of the desktop session's release, built as
design-desktop-programs builds its programs: a pure core,
`erx_act_palette_core`, with `init`, `step` and `view`, a thin window
process that performs its effects, and a worker for each request in
flight ([design-desktop-programs.md](design-desktop-programs.md#the-construction)).
Its effects are a listing of a type's members through the session's
inspect facet, `{run, Tag, Act}`, `{end_act, Tag}`, the window's
placement, passing the keyboard from the window it was opened from
([decision 2](#decisions)) and `close`.

It opens in one of two ways, and is the same window either way:

* **On no object**, from `act` or the palette key, near the top of the
  screen: an input line and the matching entries. While the input holds
  one word, Return runs the selected entry: a command entry runs its
  name alone, a member entry runs the member's default offer. Once the
  input holds more, it is an rc line: the list shows the members of the
  type that the command's `-erx_args` gives the argument under the
  cursor, Tab inserts the selected member's text, and Return runs the
  line as typed. Arguments without a declared type complete nothing.
* **On an object**, from a gesture on a value or `act TYPE TEXT`, at the
  point `Where` names, with the object's text, which runs nothing, under
  the pointer and its offers below it: the default selected, and an
  input that filters the offers by label. Return, or a click on an
  offer, runs the selected offer.

Under the list the palette always shows the selected offer's line
verbatim, so the person sees what will run, `$1` and all, beside the
value `$1` will be. Every text it shows, labels, lines, object texts,
output and diagnostics, is a widget text property, which every renderer
draws through the line escape (design-display's G5).

**When a pick counts.** A pick runs only what the person has seen, so
the core takes a Return or a click as a pick only when:

* the window's first present has been answered: a Return or a click the
  palette read before that is dropped, so input queued while the palette
  was being made picks nothing, while the characters typed then still
  fill its input, since filtering runs nothing;
* for a click, the pointer moved onto that offer's row after the row
  last changed: the pick rule of pointer re-entry that synthesis D3
  accepted for windows (the archived `research-ui-secure.md`
  section 6.1), applied to the palette's own rows, so a row that appears or
  changes under a resting pointer takes no click until the pointer
  leaves it and comes back;
* for a Return, an offer is selected: when the list changes, as a
  listing answers or the filter narrows it, the selection stays on the
  same line, and when that line leaves the list nothing is selected and
  Return runs nothing until the person selects again.

When an act ends with an empty status and no output, the palette
closes. Otherwise it shows the status and the output, cut to 200 lines
of at most 4,096 bytes each, as files cuts a preview, with a note of how
many bytes the collector did not keep, until the person closes it.

**An act lives as long as its palette.** `erx_act_run` keeps one small
owner process for each act it starts, which starts the act's job,
monitors the palette that asked for it and, when the palette ends for
any reason, crash included, ends the act as [Acts](#acts) says. So
Escape, closing the window, a new palette replacing it and the end of
its display each end the act whole, its stages, `&` blocks and programs
with it; what the act already opened, a window or an app, stays. While
an act runs, the palette shows that it runs.

A session has at most one palette on each display: a new one replaces
the one open there. The palette ends on Escape, after an act that
needs nothing shown, when its window ends, and, while it runs no act,
when another window becomes current, which it learns from its window's
`wctl` record ([design-display.md](design-display.md#the-window-tree)). A palette that
runs an act or shows a result stays until the person ends it, so
clicking elsewhere while a line runs does not end the line.

A member listing runs in a worker with stock OTP's `max_heap_size` set
to 4 MiB, as files lists a folder
([design-desktop-programs.md](design-desktop-programs.md#bounds)), with
the inspector's one-second timeout. A listing that fails, times out or
outgrows the cap shows as a line in the list's place with its status,
`scope`, `timeout` or "too many to list", and nothing is made up in its
place.

### Bindings

A bound key is taken where every key of an Erlang client passes:
`erx_win:kbd/1`. After decoding a record, it consults the ETS table
`erx_act_bindings` of its own runtime, whose one row is the map from
chord to line. A chord fires on the `{down, Keys}` record whose set
equals it, which is the trigger's down: the held keys type nothing, so
their own downs pass to the caller as any key's do and give it nothing
to read as text. On that record `kbd/1` sends `{bound, Line, Where}` to
`erx_act`, with the window's display and the window as `Where`, and
takes the press: it drops that record and every record after it while
the trigger is held, the trigger's `{typed, _}` and its repeats, and the
records of any key pressed meanwhile, up to the first record whose set
lacks the trigger. That record is dropped too when it is an `{up, _}`,
the trigger's release. When it is a `{down, _}`, the release was lost to
the queue's bound, and the record is decided afresh: every `k` record
carries the whole set of keys held, and a key's down comes before the
character it types
([design-display.md](design-display.md#the-window-tree)). A caller may
then see the release of a key whose down it never saw, as after any
lost record, and the next set it reads is right.

A pure function, `erx_win_core:bind/3`, decides each record from the
table's map and the trigger held, if any. That one fact needs a home
between reads, and a `typed` record does not carry the keys held, so
`kbd/1` answers the next handle with each key, `{ok, Key, Window}`, as
`resized/1` already answers a new handle after a resize
(`erlang/apps/erx_win/src/erx_win.erl`), and the handle carries the
trigger held and the names of the display and the window it was opened
on. The one caller in the tree, `erx_ui_lvgl`'s key reader
(`erlang/apps/erx_ui/src/erx_ui_lvgl.erl:432`), threads the handle as
its pointer reader already does.

What follows by construction:

* **No binding takes a key typed as text.** A chord needs a held key
  other than Shift ([Rules](#rules)), so typing, a password at a prompt
  included, never forms one.
* **A press is taken whole or not at all.** The trigger held lives in
  the handle, not the table, so a reload or the end of `erx_act` in the
  middle of a press changes nothing of it: the press already taken is
  dropped to its release, and the next press is judged against the
  table as it then is. No two chords overlap, since a set equals at most
  one of them.
* **Every Erlang client of the session gets the bindings**, the
  terminal and every renderer of the widget toolkit, with no binding
  code in either, since both read their keys through `erx_win:kbd/1`. A
  full-screen program in a terminal, such as `vi`, reads its keys
  through the terminal, and so gets the terminal's bindings. A native
  program with a window of its own reads that window's `kbd` through
  fids its handler walked for it, so it keeps every key of its window.
* **Bindings live exactly as long as the act service.** The table is
  `erx_act`'s, so it dies with the process: while `erx_act` is down a
  bound key reaches its window as an ordinary key, and nothing beyond a
  press already taken is swallowed for a service that is gone.
* **An app's window gets every key.** An app's session runs no
  `erx_act`, so its runtime has no table and `kbd/1` takes nothing.
  The same holds on a kiosk, whose app's release runs no shell
  ([design-display.md](design-display.md#a-displays-session)), so no
  key at a kiosk reaches a command line.
* **The reserved chord is untouched.** The display's router keeps it
  before any window is asked
  ([design-display.md](design-display.md#the-input-router)), so it
  never reaches `kbd/1`.

`erx_act` runs a bound line as an act with `$display` set and no value,
its owner a temporary process under `erx_act`'s supervisor, so the act
ends when it does or when `erx_act` ends. When the act ends with a
non-empty status or with output, `erx_act` opens the palette on that
display showing the result, the one place results are shown. A line
that does not end runs until it does, as `cmd &` does at a shell.

### Gestures on a value

Two places hold presentations on the screen, a closed set that G4
already names, and each gains one action:

* **The terminal**: button 3 on a cell that carries a link sends `{offer,
  {Type, Text}, Where}` to `erx_act`, the type and text from
  `erx_vt:link_at/3`, which are the link's URI and never the cells'
  shown text. Button 3 inside a window is the client's; the overlapping
  policy's menu takes the right button only outside every window.
* **The widget server**: a renderer reports a secondary press on a node
  as `{act, NodeId}`, and the server, when the node carries a `present`
  property whose status is `ok` or `partial`, sends `{offer,
  {atom_to_binary(Type), erx_present:text(Type, Value)}, Where}` to
  `erx_act`. The report
  reaches no application, so the renderers' parity on application
  events is unchanged. The Erlang renderer reports button 3; the LVGL
  and browser renderers serve kiosks and the web, whose sessions run no
  act service, and report nothing.

Each sends only when a process is registered as `erx_act` in its
runtime, so in a session without find and act the gesture does nothing.
Neither calls a facet or the evaluator.

files has an "Open with" toolbar button, enabled while an item is
selected, which calls `erx_act:offer({path, Path}, Where)` with the
item's exact path from its core, never its shown name
([design-desktop-programs.md](design-desktop-programs.md#names-and-contents-are-untrusted)).
files itself still starts nothing: the palette runs what the person
picks.

### The commands

Three Erlang commands of the `erx_act` application, in the desktop
session's release; none declares a facet. `window` asks the terminal's
supervisor for the terminal, as the desktop commands ask theirs, so the
terminal outlives the act or shell that opened it. `act` started from
a terminal names that terminal's window in `Where`:

| Command | Does |
| --- | --- |
| `act` | opens the palette on `$display` with no object |
| `act TYPE TEXT`, `act PATH` | opens it on that object: a presentation, or the file or folder the path names |
| `act -r` | reads the rules again and prints the reader's diagnostic, or nothing when the file is good or absent |
| `plumb PATH`, `plumb TYPE TEXT` | runs the object's default offer as an act, in `plumb`'s own working directory and with its own standard streams, and ends with the act's status |
| `plumb -l PATH`, `plumb -l TYPE TEXT` | prints each offer, its label, a tab and its line, one a line, and runs nothing |
| `window` | opens a terminal of the session on `$display`, as Ctrl-Shift-N does, and returns once it is open |
| `window CMD [ARG ...]` | opens a terminal whose shell runs the words as one simple command, without parsing them again, and returns once it is open; the terminal ends when the command ends |

`plumb` is rc's way to the routes, as `open` is on macOS and `plumb` is
on Plan 9. `window` takes its name and its use in a route from rio's,
which the plumbing paper's `plumb start window acid $0` shows
(`plumb.txt`, lines 219-226). Whether FreeBSD 15.1 has a `window` in its
base system was not checked: unverified, to be settled before the name
is used, as design-desktop-programs checked its names.

## Homes, ownership and input

Each mechanism, the consumer that needs it, and the home design.md's
rule gives it
([design.md](design.md#decisions)).
That rule governs entry points between domains; inside one domain
processes call each other freely, so a mechanism that never leaves the
session needs no home, and none is added.

| Mechanism | Consumer | Home | Owner | Untrusted input it reads, and its fuzz target |
| --- | --- | --- | --- | --- |
| acts, `erx_act_run` | everything that runs | none: the session's own evaluator | the session; runs with its capabilities | rc text from the person's rules or typing: rc's parser, whose fuzz target exists ([design-shell.md](design-shell.md#verification-and-testing)) |
| the rules | which line a value opens; keys | bytes the person keeps: a file in the session's `lib` directory, which no narrowed namespace holds writable, and a file of the release | the person, through their sessions and the programs given their whole namespace; read by `erx_act` | the rules file: **new fuzz target**, `erx_act_rules:read/1` with the matcher, reloads and the bounds of [Rules](#rules) |
| objects | all gestures, `act`, `plumb` | none: an argument of `erx_act:offer/2` | `erx_act` | presentation texts from terminal links: `erx_present:parse/2`, whose fuzz target exists; paths: bounded and passed as data |
| `erx_act` | holds the rules, the bindings table, one palette per display | none: a local process, registered in its own runtime, serving no facet and no tree | the desktop session's release | messages from its own runtime only |
| the palette | launching, offers, results | a window through the session's display grant | the session | the person's typing, as rc text; inspector listings, as typed records; command output, as attributed text through the line escape |
| bindings | the palette key, lines on keys | the client library's key reader | `erx_act` owns the table; `erx_win` reads it | `kbd` records from the display, already decoded by `erx_win_core:kbd/1` |
| `act`, `plumb`, `window` | rc | commands of the namespace | the session | arguments: a path, or a type through `erx_present:type/1` and a text through `parse/2` |

No inspection path is added: nothing outside the session reads the act
service's state, and a person reads the rules with `cat` and their
diagnostic from `act -r` or the palette.

## Apps and other domains

* **An app adds no command to a person's palette.** The palette's table
  is the person's session's command namespace, which holds only the
  commands of releases that session holds
  ([design-shell.md](design-shell.md#data-model)); an app's commands run
  in the app's own session. There is no path by which a command of one
  principal is offered in another's session, so there is nothing to
  admit.
* **An app is reached by starting it.** The `app` presentation, its
  `list` statement and its route turn every row of the start table into
  a palette entry whose line is `service NAME onestart`, and the start
  service judges that command as it judges it from a shell
  ([design-apps.md](design-apps.md#how-a-command-is-judged)): the
  session needs the `start` grant, which `service` declares, so a
  session without it is offered no app at all. The members come from
  the `[svc]` listing, which only an inspect facet of scope `all`
  reads ([design-apps.md](design-apps.md#interfaces), "Inspection");
  [decision 3](#decisions) is what a release build's administrator
  sees.
* **Handing an app a value waits for the powerbox.** Opening a person's
  file in an app of another principal needs a grant from one session to
  another, a new cross-domain facet
  (the archived `research-ui-secure.md`, section 6.5). When
  that design adds a command to the session's namespace, routes reach it
  as they reach any command; nothing here changes.
* **An app's own presentations stay in the app.** An app's widget
  server is in the app's runtime, which has no `erx_act`, so a secondary
  press there does nothing; whatever an app draws, including a fake
  palette, runs with the app's authority and reaches nothing of the
  person's session.
* **No domain reaches `erx_act`.** It is reached only by its registered
  name, and a registered name of another domain cannot be addressed
  ([design-domains.md](design-domains.md#frames)); it encodes its pid
  into no frame, so no export entry ever names it.

## Concurrency and failure

`erx_act` is one `gen_server` under the `erx_act` application's
supervisor. It never waits: the rules are read by a worker with a
one-second timeout and an 8 MiB heap, path information by a worker,
offers are a pure computation, and palettes and acts are processes of
their own. A reload builds the new map and replaces the table's one
row, so a reader sees the old bindings or the new, never a mixture.
Palettes are linked to `erx_act` and monitored by it to keep the
one-per-display map. Each act has an owner process of `erx_act_run`,
which monitors the palette that asked for the act, or, for a bound
line, is a temporary child of `erx_act`'s supervisor, and ends the
act's job when that ends ([The palette](#the-palette)).

| Failure | What the person sees | What recovers it |
| --- | --- | --- |
| `erx_act` crashes | open palettes close and their acts end; bound keys reach windows as ordinary keys, but for the rest of a press already taken | its supervisor restarts it, which reads the rules and fills the table again |
| the rules file fails to read, times out, outgrows the reader's heap, is too long or fails the reader | the defaults alone; `lib/act:LINE: REASON` heads every palette | `act -r` after the file is fixed |
| a presentation's text does not parse | the palette, opened on the gesture, says that the text is not a value of the type, and offers nothing | none needed |
| a path names nothing | `act` and `plumb` fail with FreeBSD's `ENOENT` text | none needed |
| no offer for an object | the palette says no command takes it; `plumb` fails | a route in the person's file |
| a line fails or crashes | the palette shows the status and output | none needed |
| a line runs long | the palette shows that it runs | Escape or closing the palette ends the act, its stages, `&` blocks and programs |
| a line writes more than 64 KiB | the first 64 KiB and how many bytes were dropped | none needed |
| the stage allowance is full | the status `too many stages` at once | none needed |
| a member listing fails or outgrows its cap | its status in the list's place | typing the value |
| the palette's display ends | the palette and its act end with it | none needed |
| a key's release is lost to the queue's bound during a bound press | the next key's down is read as usual | none needed |
| the keyboard cannot be passed to the palette in time | the palette opens without it; a click picks it | none needed |

A failure ends at most one palette and the act it runs, or `erx_act`
and every open palette with it; the session, its shell and its other
windows are untouched.

## Refusals and error results

| Request | Result |
| --- | --- |
| `act` or `plumb` with a type `erx_present:type/1` does not know, other than `file` and `folder` | `act: TYPE: unknown type` or `plumb: ...`, status 1 |
| a text that does not parse as its type | `act: TEXT: not a TYPE` or `plumb: ...`, status 1; on a gesture, the palette's note |
| a path that names nothing | `act: PATH: No such file or directory` or `plumb: ...`, FreeBSD's text for `ENOENT`, status 1 |
| `plumb` on an object with no offer | `plumb: no route for TEXT`, status 1 |
| `act` with no display, or a display that refuses the window | `act: no display`, status 1, as `erx_ui:open/1` answers `{error, no_display}` |
| `act -r` on a bad file | the diagnostic on standard error, status 1; the defaults stay in force |
| a `bind` whose chord holds no key but Shift, or no trigger, or two | the file fails at that line: `lib/act:LINE: a chord needs Ctrl, Alt or the logo key and one other key` |
| a narrowed namespace with a writable root within the session's `lib` directory or containing it | refused with `EACCES` when the namespace is derived; the program or command does not start |
| an offer whose command the session cannot run | not shown; typed anyway, the line fails with `no_facet` at the shell's check |
| a Return or click the palette read before its first present was answered, or a click on a row that changed under the pointer | dropped; nothing runs |
| more than one palette on a display | the new one replaces the old, ending its act |

## Security

The threat model is the system's: development builds run trusted code
only ([design.md](design.md#decisions)), and what a hostile peer
could do here is stated, not engineered against.

* **No authority is added.** Every act is a line run by the session's
  own evaluator with the session's capabilities; find and act holds no
  facet, grant or capability of its own, serves none, and reaches no
  service but through commands (FA1).
* **Presentations still grant nothing.** A presentation reaches
  `erx_act` only as a type and a text, which the funnel parses; it
  opens a palette, and what runs then is a line the person chose (FA2).
  A program that writes a link labelled `a.txt` whose URI names
  `pid/3.45.0` gets a palette that shows `3.45.0` and the offers of a
  pid, since the object comes from the link's URI (FA4). The canonical
  object answers a misleading label, not a misleading palette: what
  keeps a pick to what the person saw is [When a pick
  counts](#the-palette).
* **No injection.** A value is a variable, which rc never rescans on its
  own, so no file name, process name or link text can become a second
  word or a command (FA3); a file's or folder's text is an absolute
  path, which begins with `/`, so no command takes it for an option. A
  line that hands `$1` to `eval` parses it again; lines are the person's
  code, as at the shell. Labels and lines come from the rules; output
  comes from commands; both are shown only through the line escape.
* **The rules are written only by holders of the session's files.**
  The person's sessions and the programs they give their whole
  namespace may replace `$home/lib/act`; a narrowed program or command
  never can, since no narrowed namespace holds the session's `lib`
  directory writable ([Rules](#rules), "Who writes the rules"; FA8).
  The residual: a program given the whole namespace holds no right
  beyond files unless `within -f` names one, yet a rule it writes runs
  with the session's; closing that needs a home for the rules that no
  program's namespace holds, and is recorded in `TODO.md`.
* **No binding reads typing.** A chord needs Ctrl, Alt or the logo key
  held, so no rule can take the keys of text, a password's among them,
  and run a line on each (FA9).
* **The palette is not a trusted surface.** It is a window of the
  person's session, drawn by its renderer. An app may draw a window
  that looks like it, and keys typed into that window are the app's;
  such a window can run nothing in the person's session. Telling the two
  apart is the reserved chord's overlay, the identity design of the
  synthesis (item 13). A client of the display may also raise a window
  of its own over the current palette with `wctl` `top`, which leaves
  the keyboard with the palette, so a person who types into what looks
  like the raised window types into the palette, and a Return runs its
  selected offer. Both are residuals, recorded in `TODO.md`.
* **The keyboard pass is the source window's to give.** Under
  decision 2, the keyboard moves only through the `wctl` of
  the window that has it, so a program confined to its own window's
  files can give away the keyboard it already has and can never take it
  from a sibling window of the same grant.
* **Bounds.** The rules file is 64 KiB and 256 statements, read with no
  atom made and in an 8 MiB worker; a line 4,096 bytes and 256 levels;
  an act's kept output 64 KiB; a listing worker 4 MiB; a session has one
  palette per display; an act's stages are within the session's
  allowance.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **FA1.** An act runs with the session's authority and no more | `erx_act_run` is the only way find and act runs anything, and it runs a line in the session's evaluator, whose runner reads the session's facets for each command; nothing in find and act holds or makes a capability | a palette or binding that calls a command's module directly; a runner state with facets of its own | a session without the inspect facet: the pid offers do not include `i`, and the line `i 3.45.0` typed into the palette fails with `no_facet`; the source check of FA2 |
| **FA2.** A gesture on a value only opens the palette | `erx_term` and `erx_ui_server` reach find and act only by sending `{offer, ...}` to `erx_act`; `erx_act` runs a line only on the palette's `run` effect, a bound key or `plumb` | a terminal or widget server that runs a default offer; an `erx_act` that runs on an offer | a test that right-clicks a pid and a file with a recording evaluator, which records no run; an xref check that `erx_term`, `erx_ui_server` and their callees reach neither a facet client nor `erx_act_run` |
| **FA3.** A value reaches a command as exactly one argument | the value is `$1`, a variable, whose text the evaluator holds as `lit` and never splits or globs | a line built by pasting the value's text into rc source | a recording command run by a route on files named with a space, `'`, `;`, `$`, `*`, `[`, a newline and a first `-`, which receives each path as one argument |
| **FA4.** The palette runs only what it showed | the object's text is the canonical text of the parsed value, from a link's URI, never from the shown cells; the offer's line is shown verbatim; both through the line escape; a pick counts only after the first present, on a row the pointer entered after its last change, or on a selection that stayed on its line | an object built from a window's shown text; a line shown after a rewrite; a pick taken from queued input or a row that changed under the pointer | a terminal link whose shown text differs from its URI, after which the palette's object text is the URI's; the pick tests of [Verification](#verification-and-testing) |
| **FA5.** Bindings exist only while `erx_act` lives, and only in its own runtime | the table is created and owned by `erx_act`, so it dies with it; `erx_win:kbd/1` reads only its own runtime's table | bindings kept in a persistent term or a table of another owner | kill `erx_act`: the bound chord then reaches the terminal's tty; an app session's window receives the chord as keys |
| **FA6.** A bound press reaches no caller | `erx_win_core:bind/3` drops the trigger's down and every record while the trigger is held, and its release; the trigger held lives in the handle | a funnel that drops only the down; the trigger held kept in the table | the chord typed in a terminal window: the palette opens and the tty receives none of its bytes, held long enough to repeat |
| **FA7.** Everything find and act keeps is bounded | the bounds of [Security](#security), each enforced where the data enters: the reader and its worker's heap flag, the collector, the listing worker's heap flag, the one-per-display map | a reader without its size check; a collector that keeps all output | the bound tests of [Verification](#verification-and-testing) |
| **FA8.** No narrowed program or command writes the rules | a narrowed namespace never holds a writable root within the session's `lib` directory or containing it, judged on the root's path on its grant; a narrowed program's commands hold only its grants | a narrowing that judges the name instead of the grant's path; a check on `lib/act` alone, which a rename of `lib` escapes | the narrowing tests of [Verification](#verification-and-testing) |
| **FA9.** No binding takes a key typed as text | the reader refuses a chord with no held key but Shift, and `bind/3` matches only a whole set | a chord check that accepts Shift as a held key | the chords test of [Verification](#verification-and-testing) |
| **FA10.** An act ends whole | an act is a job whose tag every process it spawns takes, and its owner ends the tag when the palette or `erx_act` ends | an act ended by a link to its evaluator, which `&` blocks and programs outlive | the ending test of [Verification](#verification-and-testing) |

## Verification and testing

Each test names the fault that must make it fail, so that a pass shows
the code under test ran. Host tests run the pure cores with no display;
hosted mode runs the session's applications with a display model; one
QEMU test runs the whole path.

| Test | Passes when | Seeded fault that must fail it |
| --- | --- | --- |
| offers, host | a pid object gets the person's route, then the defaults', then `-erx_args` commands by name, each once | offers that skip step 2 lose the derived commands; offers that skip the duplicate rule show `i $1` twice |
| needs filter, host | with facets lacking `inspect`, no offer starts with `i` | a filter that ignores `-erx_needs` |
| the shell is the gate, hosted | the line `i 3.45.0` from the palette in that session ends with `no_facet` | a runner state given a facet map of its own |
| no run on a gesture, hosted | right-click on a pid and "Open with" on a file open a palette and the recording evaluator records no run | an `erx_act` that runs the default offer on `offer` |
| one argument, hosted | a recording command receives each awkward file name of FA3 as exactly one argument, through a route and through `plumb` | an act built by splicing the path into the line's text |
| environment, hosted | a route's line `echo $home $display` prints the session's home and the palette's display; a function defined in a terminal's shell is not found by an act | an evaluator made with the act's variables alone, which prints an empty home |
| link spoof, hosted | a link shown as `a.txt` whose URI is `pid/3.45.0` opens a palette on the pid `3.45.0` | an object taken from the cells' text |
| unparsable text, host | links whose text is not a pid's syntax, `3.x.0`, `3.45` and `3.45.0.1`, make no object, and the palette says so; whether a well-formed pid names a live process is the command's and the inspector's to answer | a funnel that passes the raw text on |
| widget type, host | a widget's `present` of the atom type `pid` reaches the funnel as `<<"pid">>` and makes the object | a server that sends the atom, which `erx_present:type/1` refuses |
| rules reader, host | every example of this document reads, the line kept byte for byte; a bad line fails the file with its line number; an empty or absent file leaves the defaults; a field holding `$`, `;` or a redirection fails; a line whose quote runs past its end fails | a reader that keeps the statements before the bad one; a reader that rebuilds the line from its tokens |
| rules reader atoms, host | reading a thousand distinct bad files and a thousand reloads of a good one leaves `erlang:system_info(atom_count)` unchanged | a reader that makes an atom of a type or key name it does not know |
| rules bounds, host | a file of 64 KiB and one byte, a 257th statement, a 4,097-byte line, a line nested 257 levels, a 65-byte label and a chord of three held keys and two triggers are each refused; under (d), a binary such as `<<0:4294967295/unit:255>>` is refused before any allocation, with the worker's heap within its cap | each bound removed in turn; under (d), a reader built on `erl_parse:parse_term/1` |
| chords, host | `bind (a) x`, `bind (kshift a) x`, `bind (kctl) x` and `bind (kctl a b) x` are refused; `bind (kmod4 ' ') x` and `bind (kctl kshift n) x` read | a chord check that accepts Shift as a held key |
| rules order, host | the person's route for `pid` is the default; the person's `bind` of the default chord replaces it | a merge that puts the defaults first |
| matcher, host | `*` and `?` match as fnmatch(3) without flags on the cases of a table; a pattern of 255 `*` against a 255-byte name ends within a fixed step count | a backtracking matcher fails the step count |
| defaults check, build | the shipped defaults read, and every line's first command is in the desktop release's catalog | a seeded route to a command no release declares |
| narrowing, hosted | a program started with a writable root of `$home`, of `$home/lib`, of `$home/lib/x` and of `$home` under a second bound name is refused with `EACCES`; one with `$home/notes` writable starts and cannot open `$home/lib/act` for writing; the rules stay those `act -r` read before | a narrowing that judges the name the line used; one that checks `lib/act` alone, after which a program with `$home` writable renames `lib`, writes a new `lib/act`, and `act -r` puts its binding in force |
| bindings swallow, host | `erx_win_core:bind/3` over a record list: the trigger's down, its repeats, a second key pressed meanwhile and the trigger's release are dropped; a list whose release is missing passes the next key's down | a funnel that drops only the down record; one that keeps dropping until an up record |
| bindings swallow, hosted | the chord in a terminal window opens the palette and the tty receives no byte of it, held through repeats; the same with `vi` full-screen in that terminal | a funnel that drops only the down record |
| bindings mid-press, hosted | a reload, and a kill of `erx_act`, while the trigger is held: the rest of that press reaches no caller, and the next press of the chord reaches the tty while `erx_act` is down | the trigger held kept in the table, which a kill clears mid-press |
| bindings die with the service, hosted | after `erx_act` is killed the chord reaches the tty; after its restart it opens the palette again | the table kept in a persistent term |
| app windows, hosted | in an app session's window the chord arrives as keys | a funnel that reads a table of another runtime |
| widget gesture, host | a secondary press on a node with an `ok` or `partial` `present` sends an offer; on `unknown`, `timeout` or no `present`, none | a server that forwards every status |
| picks, host | over the palette core: a Return and a click read before the first present's answer run nothing while typed characters still filter; a click on a row that changed under a resting pointer runs nothing, and after the pointer leaves and re-enters it, runs that row's line; a listing that answers while an offer is selected keeps that line selected, and one that removes it leaves nothing selected | a core that accepts any Return; a core that arms clicks on the window rather than the row; a selection kept by index, under which the late listing moves Return onto another line |
| ending an act, hosted | Escape while `sleep 100 \| cat`, `{sleep 100} &` and a native program run as one act ends every process of the act's tag and gives the program its `SIGINT`; a `window vi $1` act that has returned leaves its terminal open after the palette closes | an act ended by a link to its evaluator, under which the `&` block and the program survive |
| output bound, hosted | a line that writes 1 MiB shows its first 64 KiB and the count of the rest, and the palette's heap stays within its bound | a collector without its cap |
| listing bound, hosted | completing a `pid` argument over a listing that outgrows 4 MiB shows "too many to list" | the worker spawned without its heap flag |
| never fabricate, host | a member listing answering `scope`, `timeout` and an error shows each as its status | a palette that shows an empty list for a failed listing |
| one palette per display, hosted | a second `act` on a display ends the first palette and its running act | a map that keeps both |
| `plumb`, hosted | `plumb notes.txt` runs `window vi` on the file and returns its status; `plumb -l` prints the offers; an unrouted file fails with status 1 | a `plumb` that ignores the person's file |
| the rules fuzz target | random bytes, mutations of the defaults, files at and over each bound, and repeated reloads read or fail with a diagnostic naming a line in the file, never raise, keep the worker within its heap and leave the atom count unchanged | a reader that makes an atom of each unknown word |
| the source checks | the FA2 xref check fails on a seeded call from `erx_term` to `erx_act_run` | none further |
| desktop, QEMU | on the desktop image, the palette key in the first terminal opens the palette; typing `files` and Return opens a files window | the default binding removed |
| keyboard pass, hosted | the palette opened by a key in a terminal is current at once. With two programs started from one session, a native program P with its own window and only that window's files, and a terminal T where the person types: P's `give` written to its own `wctl` while T is current fails with `EINVAL`; P, made current by a click and given a key, cannot give the keyboard to T, made before that click; a `give` more than 500 ms after the last key or button down fails | the rule judged on the grant, "the grant holds the current window", under which P's write takes the keyboard from T; the rule without its age check, under which P hands the person's typing to T's shell |

The palette's core is not a protocol state machine, so it is tested on
its cases, not exhaustively.

## Performance

Offers and entries are pure work over at most 256 rules and the
session's command table, done on a gesture and not on the key path;
their time is not measured. The key path gains one
ETS lookup for each `{down, _}` record in every Erlang client of a
session. The rules are read at `erx_act`'s start and at `act -r`, never
on a gesture. A member listing is one inspector query per argument, in a
worker.

The cost that matters is the palette's appearance: a window made, a
buffer allocated, a tree laid out and drawn, and the first present
answered, all after a key. It is unmeasured; the watch list holds it
([todo-performance.md](todo-performance.md)), to be settled with a
`tools/erx bench` workload from the bound key's down to the palette's
first present answer, under QEMU and on a Raspberry Pi 4.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| A plumber served as a file tree, `send` and ports, as Plan 9's | every caller is a process of the same session, which calls `erx_act` directly, and design.md's homes are for entry points between domains; rc reaches routes through `plumb`; no native program has asked to plumb. Ports deliver a message to a running program, and no erXos program reads one: every route starts a command |
| Classifying untyped text by patterns, Plan 9's `data matches` with the click offset | erXos's values arrive typed as presentations, and `ls` and `grep` output stays text by design ([design-shell.md](design-shell.md)); no first-desktop consumer needs it. When one does, it is a `text` object type and a pattern statement, which bears on [decision 1](#decisions), whose rejected Plan 9 grammar fits it best |
| A registry of palette contributions with titles and icons, as editors keep | a second table beside the catalogs, which every command would have to join; the catalog's names and help are the labels |
| A context menu drawn inside each window | every client would draw it, the terminal and three renderers, each in its own way; one palette window drawn by one program serves all of them |
| A global palette chord kept by the display, or the palette opened from the reserved chord's overlay | a second reserved chord is what the synthesis asks not to have (section 2.6, "Chords and overlays"); the overlay is the display's trusted surface, and opening the session's palette from it would need a channel from the display to the session that nothing else needs |
| Running the default offer on a single click, as Plan 9's plumbing does | a link's URI is chosen by whatever program wrote it, so a click could start a command on a value the person never saw; one more gesture in a window that shows the line is the price of FA2 |
| Building the line by quoting the value into rc text | correct only while the quoting is; a variable cannot be mis-quoted, because rc never rescans it |
| Ending an act by a link from the palette to its evaluator | the runner's subshells and isolated commands run under monitors and an `&` block unmonitored (`erx_shell_runner.erl:155-163`, `:279-283`), and programs are the command server's rows, so a link ends the evaluator and leaves the rest running; the job tag is the shell's one way to end everything a line started |
| The person's rules installed only through a command, kept where no program's namespace reaches, as crontab(1) installs a user's table (FreeBSD's not read in this task: unverified) | it would also keep the rules from programs given the whole namespace, the residual of [Security](#security), but needs a tree the session holds and never hands to a program, a kind of mount no design has, while `start.conf`, the precedent, is writable by such programs too; the narrowing rule closes the case the person chose to restrict |
| Apps offering commands in a person's palette | a command of one principal run in another's session, or a new cross-domain protocol, for no consumer; the powerbox is the design for handing an app a value |
| files' kind table as the source of routes | a kind is a guess at a file's content for its icon; a route is the person's choice of command; they need not change together, so they are not one fact |
| Ranking by use, hiding entries | no consumer yet: few commands declare `-erx_args`, so the Services lists are short; the rule order is the ranking |
| A click on a presentation in any window filling the palette's argument, CLIM's full loop | the act service would track every terminal's and widget server's context, a coordination of many participants; the palette's completion from the type's listing, and object-first offers, cover the cases |

## Decisions

Three decisions shape this design. Each gives its rationale and the
alternatives it rejects, with their reasons.

**1. The rules are written as lines in rc's word syntax.** The rules'
meaning is fixed above: a type, name patterns for files, a label and an
rc line for a route; a type for a list; a chord and an rc line for a
binding. Whatever the outer syntax, the line is rc, the shell's own
grammar, and no rule engine is needed: there is no join, recursion or
negation. The syntax is the one [Rules](#rules) gives, such as
`route file (*.txt) Edit window vi $1`. `erx_act_rules:read/1` reads it
with `erx_shell_lex`, whose tokens already make no atom, carry their
offsets, never raise and have a fuzz target, and parses each line, a byte
range of the source, with `erx_shell_parse:next_bounded/3` under rc's own
depth, size and heap bounds. The new code is the split of a source line
into a kind, its fields and the rest, and it has its own fuzz target.

The reasons: the reader must make no atom and refuse before it builds,
and this form reuses the tokenizer and parser the shell already has,
bounds and fuzz target included, and adds only the split of a line into
fields. The statement has one quoting rule, the line in the file is byte
for byte the line that runs, and the file reads like the shell, as
FreeBSD's `rc.conf` reads like sh. Because the rules are rc, the choice adds no
language to the system. The alternatives, each of which would hold to
the same four rules of [Rules](#rules):

| Rejected alternative | What it costs | What it would give |
| --- | --- | --- |
| Plan 9's plumbing language, the part that applies: `type is`, `plumb start`, with `name matches` for files | a reader of a grammar half of whose verbs (`plumb to`, `plumb client`, `src`, `wdir`, `attr`, the click attribute) mean nothing here, so it would look like Plan 9's without being it | familiarity to Plan 9 users; the best fit if untyped text is ever plumbed, since its regular expressions and winnowing are built for that. When untyped text plumbing becomes a goal, it is the better outer syntax for that day |
| awklog | a Datalog engine in AWK for rules with no join; on the target it would run under toybox's `wak` as a program, or the person's file would need a host step | nothing these rules use; awklog's place is a host-side check |
| Datalog, Soufflé or an engine in Erlang | Soufflé is a host C++ tool; an Erlang engine is a new module for the same nothing | nothing these rules use, as for awklog |
| Erlang terms, one tuple a statement | stock OTP's reader cannot be used: `erl_scan` makes an atom of every atom and variable name before any check, and atoms are never collected, so reloads of bad files grow the table without bound; `erl_parse:parse_term/1` builds a binary's value from its size fields, so a few bytes ask for any allocation (`otp/lib/stdlib/src/erl_scan.erl:788`; `otp/lib/stdlib/src/erl_parse.yrl:1497`, `:1960-1966`). It therefore needs a scanner and a parser of its own for a subset of Erlang's term syntax, with their own fuzz target, and the person writes Erlang's quoting around rc's | the system's own language for configuration; the term shapes as the format. Once the reader must make no atom and refuse before it builds, it is no longer "a shape check over terms" but a new scanner and parser with nothing to reuse |

**2. A bound key or a gesture hands the keyboard to the palette through
the source window's `wctl`, in a narrow form.** A new window is current
only once the person clicks it, and `wctl` `top` gives no keyboard
([design-display.md](design-display.md#windows-and-the-window-system)).
So a palette opened by a key could not be typed into, and one opened at
the pointer would take its first click as a pick, which the policy keeps
for itself; under the pointer re-entry rule synthesis D3 accepted, that
click picks the palette only after the pointer has left it and come
back. The decision is a `wctl` command `give N`, written to the `wctl`
of the window that has the keyboard, the **source**, naming a window `N`
of the same grant, the **target**. The policy admits it only when:

* the source is the current window;
* the display delivered a key or button down to the source within the
  last 500 ms, the user-traced act of the accepted clipboard rule
  (synthesis D3);
* the target is shown and was made after the source last became
  current.

It then picks the target, and refuses anything else with `EINVAL`. The
palette, opened from window S by a bound key or a gesture, writes
`give P` for its own window P to S's `wctl`, which the session's
processes reach through the grant.

The reasons: the keyboard still moves only on the person's act and only
out of the window that has it, so no writer gains a key it did not
already have. The authority is the source window's own control file. A
program confined to its own window's files
([design-programs.md](design-programs.md#the-handler)) can give away only
a keyboard it already has, never take it from a sibling window of the
same grant, since the display tells clients apart by grantee domain and
not by program (`erlang/apps/erx_display/src/erx_winfs.erl:269`). The
500 ms interval alone proves recency, not authority or intent; with the
source window's control file as the authority it proves the person just
acted in the source. The condition on the target keeps the keyboard from
being handed to an older window, such as the session's shell, so the
person's typing cannot be steered into it; it is one window id kept with
the pick, since window ids only grow. This changes the display's accepted
focus rule, which
[design-display.md](design-display.md#risks-and-decisions), decision 21,
states. The alternatives:

* **No change: the person clicks the palette before using it.** Rejected:
  the palette and the context menu each cost an extra click on every use,
  two under the re-entry rule.
* **The palette drawn inside the window the gesture came from.**
  Rejected under [Alternatives considered](#alternatives-considered).

**3. App names in a release build's palette follow design-apps'
visibility.** The palette lists apps from the `[svc]` listing, which
only an inspect facet of scope `all` reads; in a release build no session
holds one, so an administrator's palette, which may start apps, cannot
list them. Which sessions may read the start table's row names is a
question of who sees what in the inspector, and it belongs to
design-apps and the inspection schema, not to the palette. The palette
lists whatever the session's inspect facet shows and widens nothing. The
gap is wider than the palette: `service -e` reads a row's
`declared_enable` from `[svc, Name]`, which the same scope guards
([design-apps.md](design-apps.md#interfaces), "Inspection"), so one
visibility rule serves both. Until design-apps gives one, development
builds, where `root` holds scope `all`, list apps, and a release build's
administrator types `service NAME onestart`. The alternative, a
visibility class for the start table's row names declared here, readable
by a facet whose principal holds the `start` grant, is rejected: it
changes who sees what in the inspector, which design-apps owns, and the
palette follows whatever that design decides.

## References

* [research-ui-synthesis.md](research-ui-synthesis.md): sections 1, 2.4,
  2.6, 3 and 8; decision D5 as put for decision is in the full record,
  `~/erxos-history/docs-archive/research-ui-synthesis.md`, history
  commit `e38149b`.
* the archived `research-ui-ux-ideas.md`: "Presentations
  and commands", "Object and document desktops", "Find and act",
  "Current platforms", ranks 1, 2 and 10; its sources as fetched on
  2026-11-15, among them Rob Pike, "Plumbing and Other Utilities",
  `https://9p.io/sys/doc/plumb.html`, SHA-256
  `af88d34db2de942bd3a8226491807d9e10ccc7c43c0909908d3ca4e5251d2d15`,
  read as text at
  `~/erxos-scratch/sources/ui-survey/ux-ideas/txt/plumb.txt`.
* the archived `research-ui-secure.md`: sections 4.11, 4.12,
  6.2, 6.4 and 6.5.
* [design-display.md](design-display.md): Presentations, The terminal,
  Links and the input context, Windows and the window system, The
  widget server, Erlang clients, Interfaces, Security, G4 and
  Chokepoints.
* [design-shell.md](design-shell.md): Commands, rc as a program,
  Interfaces, SH1 and SH2.
* [design-desktop-programs.md](design-desktop-programs.md): The
  construction, files.
* [design-apps.md](design-apps.md): Interfaces, How a command is judged.
* [design-domains.md](design-domains.md): Frames, "Registered names
  stay inside their domain".
* FreeBSD fnmatch(3), for the name patterns' meaning without flags; not
  fetched in this task, to be read at the pinned FreeBSD release before
  the matcher is written.
