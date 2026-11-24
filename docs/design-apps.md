# Apps: the start table

An **app** is code that runs for no person: a kiosk's screen, a
dashboard, a network service, a developer's experiment. This document
says what authority an app's code runs with, and what starts it and
starts it again. It adds one thing, the start table, because the system
already has every other part: an app is a principal, its code is the
release of that principal's session template, its authority is the
facet rows granted to that template, and its code runs in a session of
that principal. How an app built outside erXos's tree reaches an image
or a running machine, as a package, is
[design-packaging.md](design-packaging.md)'s; this document is the seam
it plugs into ([Packaging](#packaging)).
The architecture is in [design.md](design.md); the manifest, the boot
and the system services in [design-system.md](design-system.md);
principals, sessions and facets in [design-domains.md](design-domains.md);
file trees in [design-files.md](design-files.md); displays in
[design-display.md](design-display.md).

Decisions every reader of this document needs:

* **An app is a principal with a session template.** The manifest
  names the principal, its template and the facet rows granted to the
  template. The template's release is the app's code, and the facet
  rows are its authority. Everything the system keeps apart per
  principal is kept apart per app with no rule of its own: its directory
  on the data partition, what its inspect facet shows, its sessions'
  names. An app's code runs in a session of its own principal, never in
  the session of the person who started it.
* **The start table is the one place that says what starts without a
  person.** Each row names a principal, whether the row is enabled,
  optionally a display, a restart intensity, and the start flags its
  session is handed, text only the app reads, as a daemon reads
  FreeBSD's `NAME_flags`. The manifest's `start` rows, and the start
  row of each admitted package, declare what may start and give each
  row's defaults, as FreeBSD's `rc.d` scripts and
  `/etc/defaults/rc.conf` do; `/etc/start.conf`, an ordinary file of
  the data partition in rc.conf(5)'s assignment syntax, holds the
  machine's own settings of those rows. The start service reads it,
  judging every line, at boot for every row and at each `service`
  command for that row, so an edit changes nothing until the row's own
  command or the next boot. A kiosk is an enabled row that names an app
  and a display.
* **The table keys on a principal, and on nothing about where the
  principal came from.** A principal of the manifest and the principal
  of a package's app start the same way ([Packaging](#packaging)).
* **Nothing starts because it exists.** A principal's session starts
  without a person only from an enabled row, at boot or by its own
  `service NAME start`, or once by `onestart`; `service NAME enable`
  makes it start at boot and starts nothing now, as on FreeBSD.
  Installing or updating a package starts nothing either: its row
  enters the table without the file applied, and the new version runs
  at its own `service NAME start` or `restart`, or at the next boot, as
  FreeBSD's `pkg upgrade` leaves services alone
  ([Packaging](#packaging)).

**Is there one place that says when and where everything starts?** Yes,
in the manifest, the packages' declarations and one file. The
manifest's `domain` rows start the system's services, in the order the
build computes, and the start table, the declared `start` rows with
`/etc/start.conf` over them, starts everything else. `service -e`
prints both, and `cat /etc/start.conf` every setting this machine has
changed. Many machines share a configuration through their image, and
the file holds one machine's departures from it
([Seeing and copying everything](#the-start-table)).

**Where do I add my kiosk app?** In a package of its own, which
`tools/erx pack --app` adds to an image and `cp NAME.app /apps/`
installs on a running machine, within the `apps` row the board's
manifest declares
([design-packaging.md](design-packaging.md)). An app that is part of the
board itself may instead be rows of the board's manifest: a principal, its
session template naming the app's release, a facet row granting the
template the display, and a `start` row that names the app and the
display. On a running machine whose start table holds the row,
`service thermostat enable display=display` enables it in
`/etc/start.conf`, and `service thermostat start` starts it.

## Context

The system already says how most things start:

* **The manifest** is the machine's one configuration, a checked-in text
  file per board and build kind (`config/manifest/`), which the build
  checks and packs into the boot image. Its `domain` rows are the
  system's services; the domain service starts them in the boot order
  the check computes and restarts each within its row's intensity
  ([design-system.md](design-system.md#the-manifest),
  [Boot](design-system.md#boot)).
* **A session template**, a manifest record keyed by a principal, names
  the release, runtime, limits, arguments and environment from which
  the domain service makes each session of that principal. Its
  `release` names a boot script of the boot image's one domain release,
  whose release file lists the applications the session boots, and the
  domain service binds it as the runtime's `-boot` argument, which no
  request can change
  ([design-domains.md](design-domains.md#erlang-interface)). Facet rows
  that name the template as grantee are granted to each of its sessions.
  A template is not a domain: the boot order never reaches one, and it
  carries no restart intensity (property 14).
* **A session starts on request**: a login at a console line, a login
  through the web, the menu of a line. Whoever asked starts it again:
  the console logs `root` in again in a development build.
* **Inside a domain**, an OTP release and its supervisors start and
  restart everything.

What is missing is one place that starts a principal's session with no
person, and starts it again.

**What other systems teach.**

| System | What erXos takes | What it leaves |
| --- | --- | --- |
| Fuchsia | A product names its session, which the session manager starts at boot. | The component framework, its routing language and resolvers: facets and the manifest already do that work. |
| Android | A user id per app makes the kernel's existing separation between users the separation between apps. | Permission prompts at run time, and the broadcast and intent machinery. |
| macOS | A launchd job is a declarative description, apart from the program, of when it runs and whether it is kept alive. | launchd's own activation mechanisms (sockets, Mach ports, paths). |
| FreeBSD | `rc.d` and `rc.conf`: what may start is declared beside the system, one file of the administrator's says whether each starts, shipped defaults lie beneath local settings, and adding a program starts nothing. `service` and `service -e` are the interface. | Shell scripts as the description of a service. |
| QNX | The image builder's one buildfile says what the image starts, and the system launch monitor describes services and their restarts declaratively. | A second description language beside the manifest. |

## Requirements

* **AP-R1.** One place says what starts at boot and where, and it is the
  same place for every app.
* **AP-R2.** An app runs with its template's grants, and with nothing of
  the person who started it.
* **AP-R3.** No row of the start table carries authority: the security
  properties the build proved over the manifest hold whatever the
  table holds.
* **AP-R4.** A kiosk's app is an app like any other: it holds its
  template's grants, the display's among them, and no other client
  takes its screen, while either its session or the display domain
  restarts.
* **AP-R5.** Nothing in this design assumes the board's manifest is the
  only source of principals: apps added at run time join later,
  through the seam of [Packaging](#packaging).
* **AP-R6.** `start.conf`, which administrators edit by hand, and
  everything else read back from the data partition are untrusted
  input.
* **AP-R7.** The interface feels like FreeBSD's `service`.

Outside this design: packages, their format, signatures, installing,
updating and removing an app at run time, and every per-app mechanism
they need ([Packaging](#packaging)); prompts that ask a person to
approve a grant; passing one of a person's files to an app; apps that
serve facets to other apps, while an app's own tree, which it serves to
the sessions that may command it, is
[design-app-trees.md](design-app-trees.md)'s; starting an app at a person's login, which
belongs to the login design
([design-display.md](design-display.md#risks-and-decisions), 14); and
drivers, which are processes of a configured domain that holds the
device ([design-system.md](design-system.md#devices)).

## Overview

```text
 the build                               the machine
 ---------                               -----------
 manifest: principal clock, its           system domain
   session template (release               erx_starter merges the `start` rows with start.conf,
   @artifact.clock), facet rows                |       one supervisor and keeper per kept row;
   granting the template, `start` rows         |       reads /etc/start.conf, serves /etc/start/ctl
 the boot image's domain release:              |  erx_domain:start_session(clock, Start)
   clock's applications and its                v
   boot script bin/clock.boot             domain service: a session of clock's template,
                                          named clock_1, granted the template's rows
                                               |
                                               v
                                          session clock_1@erxos boots /bin/clock:
                                          clock's applications start
```

**An app's life, end to end.** The image's builder writes a principal
`clock`, its session template, whose `release` names the boot script of
`clock`'s applications, the facet rows that grant the template what the
app needs, and a `start` row for `clock`. At boot, once the system domain's
namespace is in place
([design-system.md](design-system.md#a-session-takes-the-console)), the
start service, `erx_starter`, merges the manifest's
`start` rows with `start.conf` and starts a supervisor for each enabled
row it admits; the row's supervisor starts its keeper, a process that asks the
domain service for a session of `clock`. The domain service makes the
session from `clock`'s template, as it makes any session, and grants it
the template's facet rows. The session's runtime boots `clock`'s script,
which starts its applications. When the session ends, the row's
supervisor starts the keeper again within the row's intensity.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **AP1.** Enabling, disabling or starting a row changes nothing the manifest check proved | a row carries a principal, a flag, a display, an intensity and start flags, and no limit, grant, device, service or code; the start flags are opaque data, bounded printable bytes that reach the session only as the value of one environment variable, `ERX_START_FLAGS`, which no shell, runtime or ERTS option parser reads ([The start table](#the-start-table)); the keeper's session is planned by `erx_dom_plan_session` from its principal's template index as every session is, and its facets pass the domain service's one funnel, which installs only rows of the manifest; so the manifest stays the only source of every domain row, device holder, service, budget, share, quota, limit and grant ([design-system.md](design-system.md#invariants), A10) | a row field that names a grant, a limit or a release; start flags delivered as runtime arguments or in a variable ERTS parses, such as `ERL_FLAGS`; a keeper that creates a domain by any call but `start_session/2` | a source check that `erx_starter`, the table and its keepers, every module of the start service's application but packaging's own (`erx_pkg*`, which [design-packaging.md](design-packaging.md#invariants) bounds), reaches the domain service only through `erx_domain:start_session/2`, `erx_domain:stop/2`, `erx_domain:system_namespace/0` (the wait before its first read of `start.conf`) and `erx_domain:server_settled/1` (the wait a keeper makes before it asks for a session on a display), both of which change nothing, reading a handle with `erx_domain:id/1` and `erx_domain:pid/1`, which reach nothing, with a seeded call of `erx_domain:create/1` |
| **AP2.** A session exists without a person only by a row of the start table | the keepers of `erx_starter` are the only callers of `erx_domain:start_session/2` besides the console and the web login, and a keeper exists only for a row the boot or the row's own `start` or `restart` admitted, or for one `onestart`; a publication of the package set after the boot's admits no row ([When the file is read](#the-start-table)) | another boot-time starter | a source check that only `erx_console`, the web login and `erx_starter_keeper` call `erx_domain:start_session/2`, with a seeded call from another module; the source check of AP1; a QEMU test that boots a manifest with no `start` row and finds no session but the console's |
| **AP3.** The table names only principals the manifest or an admitted package declares startable | a row exists only for a manifest `start` row or the start row of an admitted package ([design-packaging.md](design-packaging.md#the-start-tables-rows)); a `start.conf` line or a `ctl` command for a name with no such row is skipped or refused, so the data partition, the `etc` grant and the `start` grant only enable, disable or set the display, intensity and start flags of a declared row | a local line that adds a row | the merge's host test, a line for an unknown name skipped; seeded: a merge that adds a row for a principal with a template but no `start` row |
| **AP4.** A display's session is the session of the row kept on it, and no other, across a restart of either domain | at most one kept row names each display: a row's supervisor starts only after the one admission ([The start table](#the-start-table)) finds no other kept row on its display, and the table's process admits one row at a time; only a row's keeper names a display with `display`; the domain service fixes the session mark in the record of that session's grant on the display and every mint of the record carries it ([design-system.md](design-system.md#facets-a-configured-domain-serves)) | an admission judged against the rows the file enables rather than the rows kept; a mark set by whichever session opens a window first; a re-mint that drops the mark | the merge's host test with two enabled rows on one display, the second refused; the judgement's test of a `start` on a kept row's display, refused, and on a stopped row's, admitted; the kiosk tests of [Verification and testing](#verification-and-testing), the display domain's restart among them |
| **AP5.** A row whose display its principal cannot draw on never starts | the admission refuses a row whose display is not a `windows` service granted to its principal's template: at boot with `{no_grant, Display}` at `/proc/apps`, and at a `start` of a row a local setting gave such a display with `eperm`; the manifest check refuses such a manifest row (property 17) | a reserved display that stays blank because its session holds no grant there | the merge's host test; the judgement's host test; the QEMU test of a local line naming such a display |

## Data model

### An app

An app is three kinds of manifest rows, each of which the manifest
already has, and its code in the boot image:

```text
principal clock
  memory 33554432
  grant @share.users
  domains 2
  names 4
  default_limits @limits.app
  ceiling_limits @limits.app
session clock
  limits @limits.app
  runtime @artifact.emu
  release @artifact.clock
facet clock_display
  name "display"
  grantee @session.clock
  service @service.display
  ...
```

* **The principal** pays for the app's sessions: its budget, its group
  under `users` and its `domains` and `names` quotas. The manifest check
  sums the budget and the two quotas with every other principal's, and
  holds the group within `users` as a cap, not a share of it (property 4).
* **The template** says what each session of the app is. Its `release`
  names `bin/clock.boot` in the boot image's domain release, a boot
  script whose release file lists `clock`'s applications beside
  `kernel`, `stdlib` and the erXos applications every session boots,
  so the app's code reaches its session as every session's code does:
  from the release slice, read-only, which the domain library maps
  into every domain ([design-system.md](design-system.md#creating-a-domain)).
  A native program of the app ships in one of its applications' `priv`
  directories and is started by that application through the session's
  program handler, as `erx_ui_lvgl` starts `erx-lvgl`
  ([design-display.md](design-display.md#the-widget-server)).
* **The facet rows** are the app's authority: a session holds every
  grant of its template and nothing more. An app is offered a display
  by a row of that display's `windows` service, with the grant's quotas
  as the row's parameters, and the network by a row of `net`. Its files
  are its user's home, `/home/clock`, through the `home` row the build
  derives for every session template but the app template
  ([design-files.md](design-files.md#building-binding-and-mounting), "A
  user's home"), as a package app's are its own directory,
  `apps/NAME/SIGNER/`
  ([design-packaging.md](design-packaging.md#where-an-apps-files-lie));
  no source row grants it `data`, the whole volume, which property 19
  leaves to root's template alone.

An app's principal is an ordinary principal, so the principal service
knows it as it knows every principal of the manifest, and its sessions'
names are drawn from its own name pool, `clock_1`, within its `names`
quota ([design-system.md](design-system.md#identifiers)). An app holds
no device: a device belongs to the configured domain the manifest gives
it to, and an app reaches it through a facet of that domain's service,
if its template is granted one.

### The start table

A **start row** says that a principal's session exists without a
person:

| Field | Meaning | Default |
| --- | --- | --- |
| principal | whose session: a principal of the manifest with a session template | |
| `enable` | whether the row starts at boot | `YES` |
| `display` | the display the session starts on, whose session it becomes ([design-display.md](design-display.md#a-displays-session)); a `windows` service granted to the principal's template | none |
| `restarts`, `restart_period_s` | the intensity: more ends than `restarts` within the period leave the row down; at most `start_restarts_max`, 100, within at most `start_period_max_s`, a day (`abi/manifest.txt`), which the packer, the manifest reader and the table's parser each hold to | 5 in 600 s |
| `flags` | the start flags, opaque text the session reads from the environment variable `ERX_START_FLAGS` ([Start flags](#start-flags)); at most `start_flags_max`, 1,024, bytes from 0x20 to 0x7e other than `"`, `\`, `$` and `` ` `` (`abi/manifest.txt`), which the packer, the manifest reader and the table's parser each hold to | empty |

The manifest's `start` rows declare every row the table can hold, with
its defaults; this one declares `clock` and leaves it off:

```text
start clock
  enable NO
  display @service.display
  restarts 5
  restart_period_s 600
```

`/etc/start.conf` holds this machine's own settings of those rows and
nothing else, one variable per line, in the assignment syntax of
FreeBSD's rc.conf(5):

```text
# the panel shows the clock; network time from the site's servers
clock_enable="YES"
clock_display="display"
ntpd_enable="YES"
ntpd_flags="0.pool.example ntp.example.net"
```

It is not FreeBSD's `rc.conf`, and is not named so: FreeBSD's file is
`sh` that `rc.subr` sources, which may set any variable and run any
command, and whose per-service variables, such as `NAME_user`,
`NAME_chroot` and `NAME_env`, change a daemon's identity and authority
(rc.conf(5), "name=value assignments that use sh(1) syntax",
`share/man/man5/rc.conf.5:111-115`). `/etc/start.conf` borrows only
the syntax of an assignment, and sets only the five fields of declared
rows.

A variable is a row's **variable name**, `_`, and the field it sets:
`enable`, `display`, `restarts`, `restart_period_s` or `flags`. A
row's variable name is its principal's name with each `-` replaced by
`_`, since a system identifier may hold `-`
([design-system.md](design-system.md#identifiers)) and an `sh`
variable's name may not: the app `my-app` is set by `my_app_enable`.
FreeBSD's `rc.subr` maps nothing: it builds every variable from the
script's `name` as it stands, and a `-` there breaks its `eval`
(`libexec/rc/rc.subr:1123`, `1134-1136`); the mapping is erXos's, so that a
row keeps its principal's name. Two rows must not share a variable
name, and a variable name must not begin with a digit, which a system
identifier may and an `sh` variable's name may not: the manifest
check refuses a `start` row whose principal's name begins with a digit
or maps to another `start` row's variable name, `my-app` beside
`my_app` (property 17), and package admission refuses an app name
that begins with a digit or whose variable name is that of a manifest
`start` row, an image package or an app the boot's registry holds
([design-packaging.md](design-packaging.md#admission)). No field name
is the end of another after a `_`, so the field a variable sets is the
one whose name ends it, and the rest must be the variable name of a
row the table holds; `a_b_enable` sets `enable` of the row `a_b`, or of
`a-b`, whichever the table holds, and `x_restart_period_s` sets
`restart_period_s` of the row `x`. Wherever a problem or a check names
a variable, `/proc/apps` and `service -c` show the row's own name
beside it, `my_app_enable (my-app)`. A setting
replaces the manifest's default for that field of that row,
`NAME_display=""` clears the row's display, and `NAME_flags=""` its
flags. As in `sh`, the last line that sets a variable is the one that
counts. A field the file does not set keeps its declared default, so
deleting a line returns that field to its default, and an empty or
absent file is a machine with no settings of its own.

**The file's syntax.** The reader, `erx_start_conf:read/1`, takes from the file only what
`sh` would read as a literal assignment, and nothing that `sh` would
expand or run. A line is one of:

* empty, or blanks alone;
* a comment: optional blanks, `#`, and anything after it;
* an assignment: optional blanks, `NAME=VALUE`, and then optional
  blanks, or blanks and a comment, where NAME is
  `[A-Za-z_][A-Za-z0-9_]*` and VALUE is one of
  * nothing, the empty value;
  * a double-quoted string, `"` bytes `"`, whose bytes are from 0x20 to
    0x7e other than `"`, `\`, `$` and `` ` ``, the four that `sh` treats
    specially within double quotes, so the value is those bytes;
  * a single-quoted string, `'` bytes `'`, whose bytes are from 0x20 to
    0x7e other than `'`;
  * a word of the bytes `A-Za-z0-9._,:/@%+-`, which `sh` takes as they
    stand.

Blanks are spaces and tabs. Every other line is a **problem** of the
file: a command, a second assignment on the line, `export`, `+=`, a
`$` or `` ` `` outside single quotes, an escape, a line that continues
on the next, a byte that is not ASCII. It is reported and skipped,
never executed. The rest of the file stands, so a file with problems
can mean something else to `sh`: in `if false; then` /
`clock_enable=YES` / `fi` the reader skips the two control lines and
takes the assignment, which `sh` never runs, and a quotation or a
here-document that spans lines does the same. Only a file with no
problems reads alike: for it, `sh -c '. /etc/start.conf; echo
"$VAR"'` gives every variable the value the reader gives it, which a
host test checks over fixtures with no problems. A file with problems
is not `sh` that erXos runs differently but text with lines erXos
refused, each reported with its line. The reader takes at most `start_conf_max`, 64 KiB,
and lines of at most 4,096 bytes. This section is the only one that
depends on the syntax: the reader turns the text into lines of
`{Line, Variable, Value}` and problems, and everything after it works
on those.

**Judging the file.** The file is untrusted input, whoever wrote it, so
every read judges it. One pure function,
`erx_start_settings:judge(Text, Names)`, reads a text with the reader and
judges each assignment against the names of the rows the table holds.
It returns the fields the file sets for each row and the **problems**
it finds, each with its line: the reader's problems; a variable that
ends with no field name, or whose rest is the variable name of no row
of the table; and a value of the wrong kind or out of its bound, such
as `enable` other than `YES` or `NO`, `restarts` past 100, or a
`display` that is not a system identifier. A problem sets nothing: its
line is skipped, and the rest of the file stands, so the file sets what
the declarations declared and adds nothing. A read's problems are in
the log and at `/proc/apps`. Whether a row's principal may draw on the
display a line gives it is not the file's to judge but the admission's,
the one place a row's display meets its principal's grants: a line
naming a display the principal may not draw on sets the field, and the
admission refuses the row, so it never starts (AP5). A line for a
removed app's name is a problem like any other until the app is
installed again, when it applies to the app as before; no command
removes it, and the administrator deletes such lines with an editor,
as `service -c` reports them.

**Admitting a row.** One judgement applies `start.conf` to a row, and
nothing else applies it. The row is made from its declaration with the
file's settings for it over the declared defaults; a row that is then
not enabled is disabled, and an enabled one is

1. refused with `{no_grant, Display}` when its display is not one of
   its principal's `windows` services;
2. refused with `{display_held, Name}` when the row `Name`, kept,
   names its display;
3. otherwise admitted: the start service starts its supervisor, and
   the row is **kept** until it is stopped or down.

A row is kept while its supervisor runs, its session running, starting
or started again within its intensity. Only a kept row holds its
display; a row that is stopped, down, disabled or refused holds none.
The principal's `windows` services are those its sessions will hold:
its template's grants, or for a package's app the `windows` services
its admission kept, never every row the `apps` row offers.

The judgement is applied by two pure functions. **The merge**,
`erx_start_table:merge(Rows, Local, Grants, Kept)`, folds it over the
rows the boot applies, against the rows kept: over the manifest's rows
in its order and then the rows of the boot's package set, the image
packages' and then the installed packages', each group in name order
([design-packaging.md](design-packaging.md#the-start-tables-rows)), in
one fold when the set has arrived by then, with none kept before them,
and otherwise over the set's rows when it arrives, against the rows the
first fold kept, so the rows kept when a row is judged are those kept
before and the earlier rows the fold admitted. `erx_start_table:command/3` applies it to the one row a
command names, against the rows kept when the command's read answers
([How a command is judged](#how-a-command-is-judged)). A row the boot
refuses keeps its reason, which `/proc/apps` shows, so a setting that
cannot take effect is visible rather than a blank screen; a command
refused the same way answers its errno and changes nothing.
The manifest's own rows and those of the image's packages pass both
checks at build (properties 17 and 19), so only a local setting or an
installed package's row is ever refused.

**Where the file is.** `start.conf` is `/etc/start.conf`, an ordinary file.
It lies in the data partition's `etc` tree, a service directory of the
data partition's storage service, as the `packages` tree is
([design-storage.md](design-storage.md#interfaces)), which holds the
machine's own settings files and nothing of any principal. Its facet,
`etc`, is granted read-write to the system domain, whose start service
reads the file and writes it for `enable` and `disable`, and to every session template the manifest
grants the start service's tree, `start`, read-write where that grant
is read-write and read-only otherwise: the build derives both rows
from the manifest's `start` grants, as it derives the `apps` rows
([design-packaging.md](design-packaging.md#the-apps-row)), so whoever
may command the start table, through a writable `start` grant, may edit
its settings, whoever may only read the table reads them, and no one
else writes them.
The manifest check holds the build to that: property 17 accepts a
writable grant of `etc`, whichever row gave it, to two kinds of
grantee alone, the system domain, whose start service is the file's
writer for `enable` and `disable`, and a session template that holds
a writable `start`, and refuses a resolved manifest that gives one to any other
template or configured domain; property 19 keeps
`etc` out of what an app may need
([design-system.md](design-system.md#the-manifest),
[design-packaging.md](design-packaging.md#the-builds-check)). A
session holding the facet mounts it at `/etc`, with its grant's rights, and the
start service's tree at `/etc/start` within it. Until the `etc` grant
exists, the file lies in the volume's `etc/` directory, at
`/data/etc/start.conf`, through the `data` grants of the system domain
and root's session. The file is at most `start_conf_max`,
64 KiB; a longer one, which only another tool can write, since the
start service refuses an edit whose result would be one ([Who writes
it](#the-start-table)), is reported at `/proc/apps` and read as holding
no settings. The table is at most
`start_rows_max`, 256 rows.

A program of such a session reaches `/etc` as it reaches `/dev`, which
an administrator's session also mounts from a grant
([design-files.md](design-files.md#building-binding-and-mounting)):
the session's export answers its own names there, `/etc/passwd`,
`/etc/group`, `/dev/null`, `/dev/zero`, `/dev/urandom` and `/dev/tty`,
and passes every other name to the session's grant, within the roots
and rights the program's namespace was narrowed to, so a native
program rewrites `/etc/start.conf` and its listing of `/etc` shows both
([design-files.md](design-files.md#narrowing-for-a-program)).

**When the file is read.** The start service reads `start.conf` at boot,
for every row the boot's table holds, and at each command for a row,
and applies what it read to those rows and to no other. The boot's
table is the manifest's rows and the rows of **the boot's package
set**, the first set the package process publishes in the boot, which
its recovery builds from the image's packages and those the data
partition held at boot
([design-packaging.md](design-packaging.md#boot-and-recovery)): the
boot reads the file and applies it to the manifest's rows once the
system domain's namespace is in place, together with the set's rows if
the set has arrived, and otherwise reads it again for the set's rows
when the set arrives. So an installed app the file enables starts at
every boot, and no manifest row waits for the package process. A row that a later
publication adds, an install's or an update's, enters the table with
no record, and shows **installed**, with its package's declared
settings, no setting of the file applied and nothing started, until
its own command or the next boot applies the file to it and records it
([design-packaging.md](design-packaging.md#the-start-tables-rows)).
FreeBSD's `pkg` likewise starts no service at an install or an upgrade
([design-packaging.md](design-packaging.md#what-other-systems-teach)).
Each command written to `ctl` reads
the file before it is judged, and the command's row is the only row it
may change ([How a command is judged](#how-a-command-is-judged)). So
an edit changes nothing until the row's own command or the next boot, as on
FreeBSD, where each `rc.d` script loads `rc.conf` as it runs
(`load_rc_config`, `libexec/rc/rc.subr:1960-2000`) and its variable
decides that script's command alone (`rc.subr:1320-1352`):
`service clock enable` starts nothing, at its own command or at
another row's, and `clock_enable="NO"` written under a running `clock`
leaves it running, kept by its supervisor, until `service clock stop`
or the next boot. A restart of the table's process reads the file
only for a row of the boot's table that the boot had not yet recorded
([Concurrency](#concurrency)).

**A read that cannot read the file.** A read that fails, or finds a
file over the bound, gives no settings, and the failure is in the log
and at `/proc/apps`. The boot, its package set's rows included, reads
it as a file that holds no settings: the rows it is for take their declared
defaults, which the build proved, since no administrator's command
waits on a boot to be refused, and a machine whose storage domain is
down still starts what its manifest enables, as a session does not
wait for a restart either
([design-system.md](design-system.md#a-session-takes-the-console)). A
command does not: one that needs the file to know what to start,
`start`, `restart`, `onestart` or `onerestart`, answers `eio` and
changes nothing, since the declared defaults could start a row the
administrator disabled or put it on a display the file moved it from,
and `enable` and `disable` answer `eio` and write nothing, since they
would write over a file they could not read; `stop` and `onestop` need
no setting, so they are judged on the row as
it was last applied and on what runs, and an administrator can always
stop a running row ([How a command is judged](#how-a-command-is-judged)).

**Who writes it.** Anyone who may command the start table may edit it
with any tool: an editor, whether it writes in place or saves a new
file and renames it, `cp` or a shell's `>`. `service NAME enable` and
`disable` edit it as FreeBSD's `rc.subr` and `sysrc` do, but through
the start service, which takes them one at a time: `service` writes
`enable NAME` or `disable NAME` to `ctl`, and the start service reads
the file as it stands, replaces every line that sets one of the row's
variables it was given, or appends `NAME_FIELD="VALUE"` where none
does, as `rc.subr`'s `write_rcvar` and `sysrc`'s `f_sysrc_set` do
(`libexec/rc/rc.subr:2782-2810`,
`usr.sbin/bsdconfig/share/sysrc.subr:524-650`), with one pure
function, `erx_start_settings:set/3`, which keeps every other byte. A
new text longer than `start_conf_max` is refused with `efbig` before
anything is written, and the file stays as it was: written, it would be
a file every later read takes as holding no settings, which would undo
every other line at the next boot. Otherwise the start service
writes the whole new text to a new file in `/etc`, created exclusively
under a name of its own, syncs it and renames it over `start.conf`, so
a reader finds the old text or the new one whole, as `sysrc` writes a
temporary file and moves it over the file. A rename becomes durable
only later, so it then syncs the file again, under its new name and
through the descriptor it wrote, and answers only once that sync has
answered; a failed sync answers `eio`, and the file holds the old text
or the new one, whole. The data partition's storage services make the
rename durable at that sync: erXos's F2FS waits for a checkpoint for a
sync of a file renamed since the last one
([design-f2fs.md](design-f2fs.md#what-is-durable-when)), and under
littlefs a rename is a metadata commit that ends with the block
device's sync (`lfs_dir_commitcrc`, `littlefs/lfs.c:1771-1777`,
v2.11.3), and a client's sync then flushes the medium
([design-storage.md](design-storage.md#read-write-storage)). So a
power cut after `enable` or `disable` has reported success never undoes
it. A command is refused, and writes nothing, when a value it was given
is a problem, `einval` for a value of the wrong kind or out of bounds,
as the judgement would skip its line. A display is checked for its form
alone: whether the row may take it is the admission's, at the row's
`start` or the next boot, as for a line an editor wrote. `enable` and `disable` do nothing more, as
FreeBSD's only write the variable (`rc.subr:1451-1459`): they start and
stop nothing, and `service NAME start` is what starts the row now.

**Writers at once.** Nothing locks the file, as nothing locks it on
FreeBSD. The start service takes `enable` and `disable` one at a time,
each reading the file afresh, so two `service` commands never undo each
other, and none undoes an edit saved before it. An editor that saves at
the same moment as a command, or that saves a copy it read before the
command, replaces the whole file with its own text: the last whole
write wins, as for any file. An editor that checks a file's identity,
size and modification time before it writes over it, as erXos's `vi`
does ([design-vi.md](design-vi.md#the-command-at-the-edge)), warns its
user instead of writing over a change made since it read the file.
The start service's serial order protects its own commands from each
other and nothing more: an editor's save between a command's read and
its rename is lost, and that race is accepted, as on FreeBSD.

An editor that writes in place can be read part-written by a command
run meanwhile, and the command acts on the text as it stands, as `sh`
would read it. A field whose line is not yet written takes its
declared default for that read: a `start` of a row declared `YES`,
whose `NAME_enable="NO"` is not yet written, starts the row, and one
declared `NO` whose `NAME_enable="YES"` is not yet written answers
`enotsup`. A line cut inside a quotation is a problem and sets nothing,
but a bare value cut short is still a value: `clock_restarts=10` cut
to `clock_restarts=1` sets 1. Only the command's own row changes, and
the row's next command after the editor's write reads the whole text.
erXos's `vi` writes in place, truncating the file first
([design-vi.md](design-vi.md#the-command-at-the-edge)), so a command
in the window of its write may read a part-written file this way; an
editor that saves a new file and renames it over the old one is never
read part-written.

**Checking before it counts.** `service -c [FILE]` judges
`/etc/start.conf`, or FILE, with `erx_start_settings:judge/2`, prints
each problem with its line, the row's own name beside its variable, and
exits with status 1 if there is one and 0 otherwise, as `visudo -c`
checks a sudoers file. The judgement needs only the names of the
table's rows, which the command takes from `/proc/apps`, where the
caller's inspection reaches `[apps]`: in the system domain's shell and
in every session whose template holds `start`, in a release build as
in a development one, since the inspect facet of such a session
reaches the start table's tree
([design-live.md](design-live.md#the-inspect-service)). A session
without `start` may still run it on a FILE it can read; there it
passes `any` for the names, which takes the rest of every variable as
a row's, and so checks all the rest, the syntax, the field names and
each value's kind and bound, and prints `row names not checked:
/proc/apps is not readable here` before its result, so a line for a
name with no row passes there unreported. FreeBSD's `service` takes no `-c`
(`usr.sbin/service/service.sh:54`), so the flag means nothing else
there, and a row named `check` stays a row.

**Seeing and copying everything.** `cat /etc/start.conf` shows every
setting this machine has changed; `service -e` every row that starts at
boot; and `/proc/apps` each row as it was last applied, the last read's
problems, and what runs. The image is the configuration machines share:
the manifest's `start` rows and the packages' declarations are what
every machine booting the image starts with, and `/etc/start.conf`
holds only one machine's departures from them. Copying the file to
another machine of the image copies those departures, and a line for a
row that machine lacks is a problem there, skipped and reported.

The configured domains are not rows of the table: they are the system
itself, their order is computed, and their place is the manifest alone.
`service -e` prints both, the configured domains in boot order and then
the table, so one command shows everything that starts.

### Start flags

A row's `flags` hand its app the administrator's own settings, as
FreeBSD's `NAME_flags` hands a daemon its arguments; network time's
servers are `ntpd_flags`
([design-time.md](design-time.md#configuration)). They are data for the
app and nothing else:

* **Bounded.** At most `start_flags_max`, 1,024, bytes from 0x20 to
  0x7e other than `"`, `\`, `$` and `` ` ``, so a line of
  `/etc/start.conf` holds them in double quotes, as `sysrc` writes a
  value (`sysrc.subr:568`). A line whose value breaks the rule is a
  problem, skipped and reported as any other; a manifest `start` row or
  a package declaration whose default `flags` break it is refused by
  the packer and by the manifest reader or the package reader
  ([design-packaging.md](design-packaging.md#the-declaration)).
* **Opaque.** The start table never splits or reads them. A keeper
  passes its row's flags to `erx_domain:start_session/2` as `Start`'s
  `flags`, and so does `onestart`, and the session's environment is
  its template's with `ERX_START_FLAGS` set to them, empty for a row
  with none; no other session has the variable. A package's native app
  gets the same value as the one entry of its program's environment
  ([design-packaging.md](design-packaging.md#starting-an-app)). They are never shell
  input, never a runtime argument, and never a variable that ERTS
  parses as options, such as `ERL_FLAGS`, `ERL_AFLAGS`, `ERL_ZFLAGS`
  and `ERL_OTP29_FLAGS` (`otp/erts/etc/common/erlexec.c`,
  `build_args_from_env`). They carry no limit, grant or code, so they
  change nothing the manifest check proved (AP1).
* **One source.** The domain library's boot view refuses a session
  template whose environment sets `ERX_START_FLAGS`, as it refuses a
  display domain's row that sets a key of its display record, so the
  value a session reads is its row's alone. It admits a session
  template only when its arguments and environment leave room in the
  boot page's strings for the variable at its longest, its key,
  `start_flags_max` bytes and a NUL, beside what it reserves there
  already ([design-fiasco.md](design-fiasco.md#boot-information)),
  so no session's start fails on its flags.
* **Read at start.** A session sees the flags of its row as the row was
  last applied, by the boot or the row's own command, and a restart
  within the intensity starts it with the same; an edit of
  `NAME_flags` takes effect at the row's next command or the next boot,
  as every setting does, and as on FreeBSD, where an `rc.d` script
  takes `NAME_flags` from the `rc.conf` it loaded when it runs
  (`rc.subr:1193-1197`).

## Algorithms and behavior

### Starting a session

Every session a row keeps is started by a **keeper**, a process of
`erx_starter`, with `erx_domain:start_session(Principal, Start)`. `Start`
gives the row's start flags as `flags` ([Start flags](#start-flags)),
and names the display in one of two ways: `#{display => D}` from an enabled
row's keeper, which makes the session the display's session, or
`#{default_display => D}` from `onestart NAME display=D` on a row that
is not enabled, which only sets the session's `display` variable. A row
or command that names no display gets, from the start service, the one display
its template is granted, where it is granted exactly one, as its
`default_display` ([design-display.md](design-display.md#choosing-a-display)):
the start table is the one place a template's displays are worked out, and
a start that names no display, a console login's, gets none. The domain service:

1. plans the session from the principal's template, with the name
   `<principal>_<n>`, as it plans any session, and with
   `ERX_START_FLAGS` set to `Start`'s `flags`, and with the `principal`
   variable, the principal's number, which the session's `/etc/passwd`
   names ([design-programs.md](design-programs.md#the-posix-lite-personality)),
   and the `display` variable, the display `Start` names, its default
   display, in its environment after the template's own words; the boot
   view refuses a template that sets either variable; the library charges the
   principal, and refuses the start with `quota` or `no_memory` when the
   principal has no room;
2. at the session's ready report, starts the facets of the system
   domain's services and adds a grant record for each of the template's
   rows of configured domains' services
   ([design-system.md](design-system.md#facets-a-configured-domain-serves)),
   with the session mark set in the record of the grant on the display
   `Start` names with `display`, and in no other;
3. answers the keeper once each `files` grant of the session has
   settled, as it answers a console's start
   ([design-system.md](design-system.md#a-session-takes-the-console)).

The session's runtime boots its template's script, so its applications
start as any release's do. It has no console line and no terminal: what
its programs write to their standard streams, and what its logger
prints, are log records under the session's name
([design-live.md](design-live.md#attributed-text)). A session that holds no
console facet has no console tty: its `user` is `erx_log_user`, an io server
that makes a record of level notice of each line written to it, its text the
line without its newline, and sends it where the domain's logger events go,
so the log service escapes it, tab and newline included, and names the
session. An empty line makes no record, as the blank lines around each of
Elixir's formatted log lines would otherwise; a line not yet ended waits for
its newline, and one longer than a record's text (`log_write_text_max`) goes
as several records, each ending at a character's end, so the server holds
no more than one record's text. A read finds no input: it is answered
`{error, enotsup}` at once. The session ends
when a permanent application of its release ends, and that end is the
domain's, with its reason in the death record.

### Keeping a session

A keeper holds one session. It starts the session and links to its
domain pid, and exits when the session ends or its start is refused.
The link also ends the session with its keeper, for any end of the
keeper, a kill included, as a web login's sessions end with the web
login service. Each kept row has a supervisor of its own in
`erx_starter`, with the row's intensity and the keeper as its one
permanent child, so OTP's supervisor is the restart policy and no other
exists:

* a session that ends, for any reason, is started again, with the
  settings the row was admitted with, whatever `start.conf` has come to
  say since: an edit reaches a kept row only at its own command or the
  next boot;
* more than `restarts` ends within `restart_period_s` end the row's
  supervisor. The row is then **down**, shown so at `/proc/apps`, holds
  no display, and stays down until `service NAME start` or `restart`,
  or the next boot;
* one row's failure touches no other row, since each has its own
  supervisor under a parent that restarts none of them.

The boot starts the table at step 5 of
[Boot](design-system.md#boot): once the configured domains of the boot
order run, `erx_starter` reads `start.conf`, merges the table and starts
the supervisor of each row the merge admitted, and does the same for
the rows of the boot's package set when it arrives
([When the file is read](#the-start-table)). The keeper of a row that
names a display waits, before each start of its session, until that
display's server has settled: reported ready, or no longer starting
(`erx_domain:server_settled/1`,
[design-system.md](design-system.md#a-session-takes-the-console)). So
the row is kept, and holds its display, from its admission on, while
its session waits. The rescue configuration starts no row.

A session started with `service NAME onestart` has a keeper under no
supervisor: it is started once and nobody starts it again.

**A display's session** is the session of the row kept on the
display. Its restart policy therefore lives in that row, beside
every other row's. When the display domain restarts, the session keeps
running, and the domain service mints its grant on the display's new
incarnation from the same record, with the same mark, so the new
incarnation knows it as the display's session.

**The reset count.** The reset count grows by one at every boot and is
cleared at an ordered end and at the first login, typed or automatic
([design-system.md](design-system.md#boot)). The first session a start
row keeps that reports ready clears it too, as an automatic login does,
so a kiosk that sees no login and is switched off at its power does not
fall into the rescue configuration at its fifth boot.

### How a command is judged

Whether a command acts is decided by the start service after its read
of `start.conf`, never by its caller, which cannot know what the file says
until that read: an administrator who has just set `clock_enable="YES"`
in an editor expects `service clock start` to start the row. `ctl`
therefore carries the caller's intent, an ordinary command or its `one`
form, as rc.subr(8) takes `start` and `onestart`, and one pure
function, `erx_start_table:command/3`, judges it from the row the read
makes of the file, the rows kept and the row's state when the read
answers, as rc.subr judges a command from the rcvar it has just loaded
and the pid it has just found (`rc.subr:1320-1352`). It returns the
answer and, for a command that acts, the action and the row's new
record. A command changes its own row and no other, and it either acts
or is refused: a refused command changes nothing, and one that acts
records its row as the read made it, or, for a stop whose read could
not read the file, as it was last applied.

A row **runs** while a session of it stands: the one its supervisor
keeps, starting included, or the one a `onestart` started. A row that
is down runs nothing.

| Command | On a row the read finds enabled | On a row the read finds not enabled | When the read cannot read the file |
| --- | --- | --- | --- |
| `start` | `ealready` if the row runs; otherwise the row is admitted ([The start table](#the-start-table)) and its supervisor starts, whether the row was stopped, down, disabled, refused or installed; a refused admission answers `ebusy` or `eperm` | `enotsup`, whether or not the row runs, and nothing changes, as rc.subr answers "Cannot 'start'" whatever runs (`rc.subr:1335-1342`) | `eio`, whether or not the row runs, and nothing changes |
| `stop` | ends the session that runs, and the row is stopped; `esrch` if it runs nothing | ends the session that runs, kept or started once, since rc.subr judges a stop's rcvar only for a service that is not running (`rc.subr:1329-1333`), and the row is disabled; `enotsup` if it runs nothing | judged on the row as it was last applied, its record, in place of the read's: by the first column for a row applied enabled and by the second for one applied not enabled; the row keeps the settings it was applied with |
| `restart` | the row is admitted against the other rows kept; then the session that runs, if one does, ends, and the row's supervisor starts, as rc.subr's `restart` is a `stop` and then a `start` (`rc.subr:1617-1632`); a refused admission ends nothing | `enotsup`, and nothing changes | `eio`, and nothing changes |
| `onestart`, `onestop`, `onerestart` | as `start`, `stop` and `restart`, since rc.subr's `one` prefix sets the rcvar to `YES` (`rc.subr:1109-1114`) | `onestart` starts one session that no supervisor keeps, `ealready` if the row runs; `onestop` ends the session that runs, kept or started once, `esrch` if it runs nothing; `onerestart` ends the session that runs, if one does, and starts one that no supervisor keeps; each leaves the row disabled | `onestart` and `onerestart` answer `eio` and change nothing; `onestop` is judged on the row as it was last applied, as `stop` is |

Since the judgement follows the read and reaches one row, after a
manual edit from `NO` to `YES` an ordinary `start` starts a kept row,
and after one from `YES` to `NO` the kept session runs on: `start`
answers `enotsup` and changes nothing, and `stop` ends the session and
leaves the row disabled. No command for another row changes either.
A `start` refused for its display leaves the row as it was, with the
reason in the log and in its errno; `/proc/apps` shows a refusal only
for a row the boot refused. The caller decides nothing from `/proc/apps`:
what it shows is each row as it was last applied. While the file
cannot be read, an administrator can stop every row that runs, and no
command starts a row on settings the file may contradict.

### Developers

* **Build.** An app built outside the tree is a package, made with the
  SDK and added to an image or installed
  ([design-packaging.md](design-packaging.md#building-and-packing)). An
  app of the board itself is its principal, its template, its facet rows
  and its `start` row in the manifest, and its applications in the boot
  image's domain release with a boot script of their own.
* **Iterate.** With the app running, `tools/erx watch DIR --domain
  clock_1` loads each changed module into the session through its code
  facet, as for any domain ([design-live.md](design-live.md#the-code-store)).
* **A development build** gives `root`'s session the `start` grant, so
  `service` works at its shell. Its banner says what such a build is:
  `development build: trusted code only`.

### Packaging

The start table keys on a principal with a session template and a
`start` row, and on nothing else. A package's app is a principal
registered within the manifest's `apps` row, its template is the one
that row gives every app, and every admitted package has a start row,
so the table, its keepers, the domain service and the display treat it
as they treat an app of the manifest. Before a package is removed or
replaced, the package process publishes a package set without it, and
the start service answers only once that app's sessions have ended
([design-packaging.md](design-packaging.md#installing-updating-and-removing)).
A publication applies nothing of `start.conf`: the boot applies the file
to the rows of its package set as to the manifest's, and a row a later
publication adds is installed until its own command or the next boot
([When the file is read](#the-start-table)). So publishing an app only
replaces its files: an install starts nothing, and an update, whose
sessions end before its package's name changes, leaves the app stopped
until `service NAME start` or `restart` runs the new version, or the
next boot does. The old session does not run on across the update,
since it reads its code from its package, whose name then holds
another
([design-packaging.md](design-packaging.md#invariants), PK7 and PK12).
How a package declares what it needs, which of the `apps` row's
services it may take and which GATT services it handles, one app to a
service, how it is authenticated, added to an image,
installed and removed, and what that does to its data, is
[design-packaging.md](design-packaging.md).

## Interfaces

**Commands**, Erlang commands of the command shell
([design-shell.md](design-shell.md#commands)), each declaring
`-erx_needs([start])`. A line the table below writes to `ctl` takes one
path in every session: in the system domain's command shell the tree is
the system domain's own grant of it, which the start service mounts in
that domain's namespace at the point where a session mounts its grant
([design-shell.md](design-shell.md#interfaces)):

| Command | Does |
| --- | --- |
| `service NAME enable [display=D] [restarts=N] [restart_period_s=S]` | writes `enable NAME` and the settings given to `ctl`, and the start service sets `NAME_enable="YES"` and those settings in `/etc/start.conf`, as [Who writes it](#the-start-table) says; it answers `NAME enabled in /etc/start.conf`, as FreeBSD's does (`rc.subr:1451-1454`), or the errno of `ctl`'s write: `enoent` for a name with no row, `einval` for a value that is a problem, `efbig` for an edit that would make the file longer than `start_conf_max`; it starts nothing, so the row starts at the next boot or at `service NAME start`, and no command for another row starts it. A display that the admission refuses, one a kept row holds or one not among the principal's `windows` services (for a package's app, those its admission kept), stays in the file: a `start` of the row answers `ebusy` or `eperm` and changes nothing, and the next boot leaves the row `refused` with its reason at `/proc/apps` |
| `service NAME disable` | writes `disable NAME` to `ctl`, which sets `NAME_enable="NO"` in `/etc/start.conf`, and answers `NAME disabled in /etc/start.conf` (`rc.subr:1456-1459`); a row that runs runs on, kept by its supervisor, until `service NAME stop` or the next boot |
| `service NAME start`, `stop`, `restart` | writes its line to `ctl` and answers from the write's errno alone, as [How a command is judged](#how-a-command-is-judged) decides it: `enotsup` as rc.subr(8) does, `Cannot 'start' NAME. Set NAME_enable to YES in /etc/start.conf or use 'onestart' instead of 'start'.`, with the command's own name for `stop` and `restart`, and status 0 (`rc.subr:1335-1342`); `ealready` as `NAME already running?` and `esrch` as `NAME not running?`, each with status 1; `enoent` as `NAME is configured in the system manifest` for a configured domain of `/proc/apps`'s boot order, and `NAME does not exist in the system manifest` otherwise. It makes no decision from what `/proc/apps` shows of the row |
| `service NAME onestart [display=D]`, `onestop`, `onerestart` | writes the `one` form to `ctl`, which acts on a row whether or not it is enabled, and answers its errno as above |
| `service NAME status`, `onestatus` | shows the row's state and reason from `/proc/apps`, the row as the boot or its own last command applied it, or `installed`; a session `onestart` started belongs to no row and is not shown; then, while a session of the row serves its tree, kept or started by `onestart`, the app's own words, the lines of `/svc/NAME/status` its parser accepts, as a FreeBSD script's `status_postcmd` adds its own, read at a deadline ([design-app-trees.md](design-app-trees.md#what-the-commands-show)); the exit status is the row's |
| `service NAME CMD [ARG ...]`, for any other CMD | refuses, with its usage line, a word that carries an rc.subr prefix (`fast`, `force`, `one`, `quiet`) or is an rc.subr keyword (`rcvar`, `enabled`, `delete`, `describe`, `extracommands`, `poll`) and is not one of its own verbs; otherwise, for a row whose session serves its tree, kept or started by `onestart`, writes `CMD ARG ...` to the app's own `/svc/NAME/ctl`, as a FreeBSD script's `extra_commands` run its own verbs, and answers from that write alone, status 0 when it succeeds and 1 otherwise ([design-app-trees.md](design-app-trees.md#what-the-commands-show)) |
| `service -e` | prints the configured domains in boot order, then each row of the table whose `NAME_enable` is `YES` in `/etc/start.conf` as the command reads it, judged by `erx_start_settings:judge/2`, or whose declared default is `YES` where the file sets none: the configured state, as FreeBSD's `service -e` loads each script's variable from `rc.conf` itself (`usr.sbin/service/service.sh:148-160`); `/proc/apps` shows the applied state, each row as the boot or its own last command applied it, and what runs |
| `service -c [FILE]` | judges `/etc/start.conf`, or FILE, prints each problem with its line and the row's own name beside its variable, and exits 1 if there is one and 0 otherwise; it checks row names only where `/proc/apps` lists the rows and says so where it does not ([Checking before it counts](#the-start-table)) |
| `service NAME purge` | removes the data of a name that no installed package holds, admitted or refused, so a name a refused package holds keeps its data until `rm` removes the package, every signer's but the image's own, `apps/NAME/image`, which no purge removes; for a name of the image's packages, the data of every installed package the name held, shadowed or not: purging a shadowed package's name removes its data while the package itself stays on the data partition until it is removed ([design-packaging.md](design-packaging.md#where-an-apps-files-lie)) |

For a configured domain, `service` answers every request that it is
configured in the system manifest; its state is at `[domains, Id]`.

**The start service's tree**, the service `start` of the system domain
and an instance of `files`, which `erx_starter` serves with `erx_fs` and a
session mounts at `/etc/start`, so that `/apps` holds apps alone
([design-packaging.md](design-packaging.md#apps)). It holds one file,
for the actions that are not settings; the settings are `/etc/start.conf`:

| File | Read | Write |
| --- | --- | --- |
| `ctl` | nothing | one command a write, a line of at most 4,096 bytes: `start NAME`, `stop NAME`, `restart NAME`, `onestart NAME [display=D]`, `onestop NAME` and `onerestart NAME`, which the start service judges after its read of `start.conf`; `enable NAME [display=D] [restarts=N] [restart_period_s=S]` and `disable NAME`, which it carries out on the file as [Who writes it](#the-start-table) says, one at a time ([How a command is judged](#how-a-command-is-judged)), and `purge NAME`, which the package process carries out ([design-packaging.md](design-packaging.md#where-an-apps-files-lie)): the write's callback, in the writer's grant, hands it to the package process and awaits the answer itself, and the table never takes it ([Concurrency](#concurrency)). The line carries the caller's intent and nothing the caller judged: an ordinary `start` or `restart` acts on a row the read finds enabled, an ordinary `stop` on a row that runs or that the read finds enabled, and a `one` form on any row; each acts on the row it names alone. The write succeeds when the command does; a 9P write carries no text back, so a refusal answers an errno: `einval` for a line that does not parse, a value an `enable` gives that the judgement would skip, or a `display=` on a `onestart` of a row the read finds enabled; `enoent` for a name with no row; `efbig` for an `enable` or `disable` whose new text would be longer than `start_conf_max`, which leaves the file as it was; `enotsup` for an ordinary `start` or `restart` of a row the read finds not enabled, or an ordinary `stop` of one that runs nothing; `ealready` for a start of a row that runs; `esrch` for a stop of a row that runs nothing; `ebusy` for a display a kept row holds; `eperm` for a display the template is not granted; `eagain` until the boot has made the table; and `eio` for a failed start, for a `start`, `restart`, `onestart`, `onerestart`, `enable` or `disable` whose read cannot read `start.conf`, for an edit whose write or sync fails, or for a start service that ended during the command; a purge answers the package process's errno ([design-packaging.md](design-packaging.md#interfaces)). The reason goes to the log; a refused command changes nothing, so `/proc/apps` shows the row as it was |

Which templates hold the `start` grant is the manifest's: `root`'s in a
development build, an administrator's in a release build; the build
gives each of them the `etc` grant too, and the `apps` grant when the
manifest has an `apps` row
([design-packaging.md](design-packaging.md#the-apps-row)). A session
whose template holds no `start` grant has no `/etc/start`, no
`/etc/start.conf` and no `/apps` at all.

**Inspection**, in `abi/inspection.txt`, reported by the start service
and shown at `/proc/apps`, to an inspect facet of scope `all` and to
that of every session template that holds `start`, whose scope adds
the start table's tree and nothing else, so whoever may command the
table sees it in a release build too, and no machine-wide inspection
is widened ([design-live.md](design-live.md#the-inspect-service)): `[apps]`,
of kind `start_table`, gives `boot_order`, the configured domains in
boot order, and `start_conf`, how the last read of `start.conf` answered:
`unread` before the boot's, `read`, `failed` with its reason, or
`too_long`; `problems`, that read's problems, the first 100 and their
count, each its line number, a reason from a closed set and, where the
line names them, its variable and the row's own name, never the value;
and it lists the rows by principal. `[apps, Name]` gives
`state`, `reason`, `domain`, `enabled`, the `enable` the row was last
applied with, `declared_enable`, the `enable` its manifest row or
package declares, which `service -e` reads where `start.conf` sets none,
`display`, which of its settings came from `start.conf` when it was
applied, and the ends within the row's period. These are the applied
state: each row as the boot or its own last command applied it, or as
its package declares it while it is installed, which
can differ from the file row by row until that row's command or the
next boot, while `service -e` shows the configured state, read from
the file. The state is derived, the keepers' branch first: `starting`
while the row's keeper waits for its display or for its session's
answer, `running` once the session stands, `down` once the row's
supervisor has ended at its intensity; and for a row no supervisor
keeps, its record: `stopped` for a row applied enabled, kept no longer
since a `stop`, `disabled`, or `refused` with its refusal as the
reason; and `installed` for a row of an admitted package that has no
record, one a publication added after the boot's package set, to
which no boot or command of its own has applied the file yet. A session `onestart` started belongs to no row and is not
shown. An app's sessions are domains like any other at
`[domains, Id]`. This is what the system observes of an app; what the
app says about itself, and the commands it takes, are in its own tree at
`/svc/NAME` ([design-app-trees.md](design-app-trees.md)).

**Manifest rows**: `start`. Its packed record and the reader's bounds
are in `abi/manifest.txt`. The start service reads the `start` rows,
the session templates and their `windows` grants through `erx_manifest`.

**The ABI source**: the limits `start_rows_max`, `start_restarts_max`,
`start_period_max_s` and `start_flags_max`, and the `start` row's
default flags in its packed record.

**Erlang**: `erx_domain:start_session/2`, whose second argument may
name a display and give start flags.

**The session's environment**: `ERX_START_FLAGS`, a row's start flags,
in every session a row or a `onestart` starts.

### Other subsystems

| Subsystem | Interaction |
| --- | --- |
| the domain service | makes a row's session from its principal's template; fixes the session mark in the record of the grant on the display a keeper's start names, and carries it in every mint of that record |
| the storage service | serves the `etc` tree, which holds `start.conf`, read-write to the system domain and read-write to the templates that hold `start`; roots an app's `data` grant at the app's own directory and a session's `home` grant at its user's home |
| the display | serves every session that holds its grant, and under the single policy shows the windows of the display's session alone ([design-display.md](design-display.md#a-displays-session)) |

## Concurrency
The start service is one process that owns the table. It does no file
operation itself: every read of `start.conf` runs, one at a time, in a
process of its own, `erx_starter_rc`, which answers each read when it
is done, so a slow storage domain delays the commands waiting for it,
not the table's answers. The table takes commands and publications of
the package set one at a time. A command, and the boot's application
of the file to its rows, are judged when their read answers; a later
publication reads nothing and judges nothing: it adds each row with no
record, so the row shows `installed`, and ends the sessions of each
row it drops and drops its record. So no two
admissions overlap and the rows kept are the same from a judgement to
its act. Reads of `/proc/apps` are answered from the
table's own state. The start service writes the file only for `enable` and `disable`,
through `erx_starter_rc`, which does every read and write in the order
asked and reads the file afresh for each edit, so its own writes are
ordered against its reads, and a restarted table's first read follows
every write the old table asked for.

**Nothing the table waits for waits on the table.** A command, the
boot or a publication waits only for `erx_starter_rc`'s read, the
records process, the keepers' branch and the domain service, none of
which calls the table. The package process does call it: each publication
waits for the table, and the package process takes one close, removal
or purge at a time, so a publication is the last step of an install,
update or removal it has begun
([design-packaging.md](design-packaging.md#concurrency)). The table
therefore never waits for the package process. `purge NAME` is not one
of the table's operations: the `ctl` write's callback, which runs in
the writer's grant, one request of that client at a time
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)),
hands the purge to the package process and awaits its answer itself,
so a purge that waits behind an update waits while the table takes the
update's publication, and a `ctl` command the same client writes after
the purge waits for it, as its grant's later requests do. A
restarted table asks the package process for nothing: it takes the
last package set from the records process below.

The keepers are a separate branch of the application's supervision
tree, so a crash of the table's process restarts it and no session ends.
The keepers' branch also holds what the table must not forget. Each
kept row's supervisor is a transient child, which OTP keeps as a spec
with no pid once it ends at its intensity: the spec holds what the
row's session is kept with, and its missing pid is a row that is down.
The rest is held by one plain process in the branch, the records
process (`erx_starter_records`): each row's record, the row as the
boot or its own last command applied it, with its refusal if it was
refused, each replaced in one step; and the **boot mark**, set in the
same step as the rows' records of the boot's package set, which says
that the boot has applied the file to every row of its table. It also
holds the last package set the table took, recorded before the table
stops a row the set drops, so a table that ends between the two leaves
a held row its successor has no row for, which it stops, and never a
dropped row it could start again. A restored set stands until the
package process publishes again, which it does at once when the
table's end cut its publication short, since that ends its lifetime. A row a
publication adds gets no record: `installed` is what a row of an
admitted package shows while it has none, a label derived from that
absence, with its package's declared settings, so no flag or copy of
the defaults is kept for it, and a publication that drops a row drops
its record with it. The records and the branch's children are the only
store of the rows' state; the table's process keeps none of its own.

**Losing that store resets the machine.** The records process is a
temporary significant child of the keepers' branch, and the branch a
temporary significant child of the start service's application's top
supervisor; each supervisor shuts itself down when such a child ends,
for any reason (`auto_shutdown => any_significant`,
`lib/stdlib/src/supervisor.erl:140-143`). So an end of the records
process, or of the branch at its own intensity, ends the application,
which the system release holds permanent, and with it the system
domain, which resets the machine, as an end of `erx_pkg_io` does
([design-packaging.md](design-packaging.md#the-package-lifetime)). The
boot that follows applies the file to every row of its table. Nothing
restarts with the store lost: a table that applied the file again
would start every enabled row that an install or update had left
`installed`, or a `stop` stopped, with no command of its own. An end
of the store is a bug of the system domain like any other: the records
process parses nothing.

Beside the table's process and the keepers' branch, the top supervisor
holds packaging's two processes
([design-packaging.md](design-packaging.md#the-package-lifetime)):
`erx_pkg_io`, whose end ends the application, and after it
`erx_pkg_sup`, the package process's own supervisor, a temporary child
that is not significant. The package process's `init` returns at once
and its recovery runs after it, so even at boot a crash of the recovery
is a restart under `erx_pkg_sup`, not a failed start of the
application. So a package process that ends past its intensity ends no
row, no keeper and no other child: the table keeps the last package set
it took, and `/apps` answers `eio`.

Nothing compares the table with the file. A row changes only when it
enters the table and at its own command, so no record has to hold a
row back from a later read: a stopped or installed row stays so
because only its own command or the boot starts a row, and a row whose
settings the file has changed since stays as it was
applied because only its own command reads the file for it. A command, and the boot, record a row before
they start its supervisor, so a table that ends between the two leaves
the row stopped, shown so, until its next command or the next boot,
and the command answers `eio`; a command that ends a session records
the row first too, and the session it had not yet ended still shows
`running`, since the keepers' branch decides the state before the
record. `service NAME enable` and `disable` only edit the file and
change no record, so no command both writes the file and changes a
record.

A restarted table takes its rows and the last package set from the
records process and their states from the keepers' branch. A row of
the set it holds no
record for is either one the boot had yet to apply when the table
ended, or one a publication added, and the boot mark tells which.
Without the mark the boot is not done: no publication can have followed
the boot's package set, so the set the records process holds is that
set; if it holds none yet, the boot's set arrives as a publication.
Either way the table finishes the boot, reading `start.conf` and applying it
as the boot does to every row of the manifest and of the set that has
no record, and sets the mark with the set's records. With the mark, it
does nothing to such a row, which shows `installed` as it did before
the restart. So a restart starts and stops no row that was applied,
and starts a row of an install or an update only by its own command.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | What happens |
| --- | --- | --- |
| the storage domain is down at boot, ends before it reports ready, or does not make the system domain's grant within the mint core's deadline | the first read of `start.conf`, which follows the system domain's namespace being in place ([design-system.md](design-system.md#a-session-takes-the-console)), fails, since the system domain's `data` grant is absent | the read counts as a file with no settings: the merge applies the declared defaults, the rows they enable start, and `/proc/apps` shows `start_conf` as `failed` with its reason; nothing reads the file again for those rows, and each row takes its local settings at its own command, whose read succeeds once the storage domain serves, or at the next boot |
| the principal has no room | the domain library's plan | the start is refused with `quota` or `no_memory`; a kept row counts it as an end |
| a session ends more often than its row allows | the row's supervisor | the row is down, with the last reason at `/proc/apps`, until `service NAME start` or the next boot |
| a local setting names a display the template is not granted, or one a kept row holds | the admission | at boot the row is `refused` with `{no_grant, D}` or `{display_held, Name}` at `/proc/apps` and starts nothing; at a `start` or `restart` the command answers `eperm` or `ebusy`, with the reason in the log, and changes nothing |
| `start.conf` is damaged, holds `sh` the reader does not take, or names a row the table does not hold | the settings judgement, at every read | each problem line is skipped and shown at `/proc/apps` with its line, and the rest stands; `service -c` prints them |
| `start.conf` is longer than 64 KiB | the table's reader | reported at `/proc/apps` as `too_long` and handled as a read that fails: as a file with no settings at boot, for the boot's package set's rows too, as in the first row, and as in the next row at a command |
| an `enable` or `disable` whose new text would be longer than `start_conf_max` | the start service, before it writes | `efbig`; the file is left as it was, so no edit of the start service ever makes a file every later read takes as `too_long` |
| a read of `start.conf` fails at a command | `erx_starter_rc`'s answer | `start`, `restart`, `onestart` and `onerestart` answer `eio` and change nothing; `stop` and `onestop` are judged on the row as it was last applied and end the session that runs ([How a command is judged](#how-a-command-is-judged)); no other row changes, and the failure is logged and shown at `/proc/apps` |
| a purge arrives while the package process carries out an install, update or removal | nothing: it is the order the package process takes them in | the `ctl` write's callback waits in the writer's grant for the purge's answer while the table takes the operation's publication; the purge is carried out after it, and a later `ctl` write of the same client waits for the purge |
| an edit is lost to a concurrent one | nothing: the last writer wins | the next read takes the last writer's text whole; `/proc/apps` shows which of each row's settings came from the file when it was applied |
| the display domain restarts under a display's session | the domain service's grant record | the grant is minted again on the new incarnation, with the session mark |
| the start service crashes | its supervisor | it restarts with the rows and the last package set the keepers' branch recorded; it reads `start.conf` only to finish a boot the boot mark says is not done, and leaves any other row with no record `installed`; kept sessions go on, and stopped, down and installed rows stay so |
| the records process ends, or the keepers' branch passes its intensity | the keepers' branch and the application's top supervisor, each shutting down at its significant child's end | the start service's application ends, and with it the system domain: the machine resets, and the next boot applies `start.conf` to every row |

Every state above, and every reason the boot finds,
is an attribute at `/proc/apps`; a command's refusal is its errno; and
every refusal is a log line that names the row or the line. Nothing is shown
as running that the domain service does not list.

## Security

**What is trusted.** The manifest, with its principals, templates,
facet rows and `start` rows, as part of the boot image; the start
service and the domain service, in the system domain; the boot image's
domain release, the app's applications among it.

**What is not.** An app's code, which runs with its template's grants
and no more; the data partition, and so `start.conf`; the storage domain.

* **The system domain parses two small texts.** A `ctl` line and
  `start.conf` have bounded grammars with fuzz targets; `start.conf`'s
  reader takes only literal assignments and executes nothing. The system domain
  loads no code of an app
  ([design-live.md](design-live.md#invariants), V5).
* **Why a principal for each app.** An app that ran in the session of
  the person who started it would hold every facet that person holds,
  their whole directory and their keys at the vault: UNIX's ambient
  authority. In a session of its own principal it holds its own
  directory and its template's grants, and the boundary is a domain's,
  which the kernel and the domain's own runtime enforce
  ([design.md](design.md#trust-placement)).
* **A hostile app** can spend its session's budget and CPU grant, which
  are its principal's limits; fill its own directory to its quota; use
  each grant within that grant's limits; and end. It binds names of its
  own `names` quota only. It cannot change the start table, since it
  holds no `start` grant unless its template was deliberately granted
  one, and it cannot reach `start.conf`, which only the `etc` grant
  reaches, held read-write by the system domain and by the
  templates that hold `start`.
* **Who may edit `start.conf`** is who may command the start table: the
  `etc` grant goes with `start`, so an edit gives no authority `ctl`
  does not, and the file still only sets rows the manifest declares
  (AP3). The build checks it on the resolved manifest: a writable grant
  of `etc` held by anyone but the system domain and the templates that
  hold `start` fails property 17,
  whichever row gave it, and no app may need `etc` (property 19).
* **A crafted data partition, or a storage domain it has taken over,**
  can rewrite `start.conf` to enable or disable rows the manifest declares,
  to move a display between rows whose templates are granted it, and to
  change a row's start flags, which reach only that row's session, as
  data its app checks; and it can read or destroy every app's data. It cannot start a principal
  that has no `start` row, widen a grant, or put a session on a display
  its template cannot draw on.
* **Who may start without a person** is the image builder's to say: a
  principal starts without a login only if the manifest gives it a
  `start` row, a person's principal included, which makes that person's
  session at a display a login nobody typed
  ([design-display.md](design-display.md#a-displays-session)). Whether a
  principal a start row names can also be enrolled and logged in to at a
  console line is the login design's; the gap is recorded in `TODO.md`.

## Verification and testing

Each test is paired with a seeded fault that proves it runs the code it
guards; the faults below are the ones each test must catch.

**The approach.** The merge, the settings judgement and the command
judgement are pure functions, tested on the host; the command judgement
exhaustively, every command of
[How a command is judged](#how-a-command-is-judged) against every row
state, the table's last column, a read that fails, included. The
reader's oracle is the host's `sh`: for each fixture of a corpus of
files with no problems, every variable must give the value `sh` prints
for it after sourcing the fixture; files with problems (`x="$(reboot)"`,
`x=$y`, `x=a; reboot`, `export x=1`, `x+=1`, `x=a#b`, a line ending in
`\`, an `if` around an assignment) are checked against an expected list
without `sh`, and nothing runs. The start service runs whole over a
fixture `etc` tree, with a stub domain service and, for its races with
the package process, a stub `erx_pkg_io` that holds a request; an edit's
durability runs over the storage power-cut harness's simulated medium
([design-storage.md](design-storage.md#read-write-storage)).

**Host tests and their seeded faults.**

* the merge: one that adds a row for an undeclared principal; the
  display rule dropped; the grant check dropped; a judgement that skips a
  line naming a display the principal is not granted, which starts that
  row on its declared display where it must be refused;
* `start.conf`'s names: a split at the last `_`, which reads
  `x_restart_period_s` as the field `s` of a row `x_restart_period`; a
  judgement that does not check the field name, which applies
  `x_colour`; one that compares the variable with the row's name
  unmapped, which skips `my_app_enable` for the row `my-app`;
* `start.conf`'s flags: an off-by-one bound, which accepts a 1,025-byte
  value; a parser that splits the value at spaces, which changes a
  1,024-byte value that must be kept byte for byte;
* the reader: one that accepts `$` inside double quotes, which accepts
  `x=$y`; one that refuses a last line with no newline, which skips
  `clock_restarts=1`; one that ends a bare value at `#` with no blank
  before it, which reads `x=a#b` as `a` where `sh` reads `a#b`;
* `service -c`: a check that prints the problems and exits 0; one that,
  refused `[apps]`, judges against no rows, which reports every line as
  a name with no row where it must print `row names not checked`;
* a keeper's flags: a keeper that passes `flags` only at the first
  start, which restarts the session without them;
* the edit, `erx_start_settings:set/3`: one that replaces only the first
  line that sets the variable, which leaves a later one standing;
* an edit at the bound: the size check dropped, which writes a file the
  next read takes as `too_long`; an off-by-one bound, which refuses an
  edit whose result is exactly `start_conf_max`;
* a part-written file: a command that takes a field the file does not
  set from the row's last applied record rather than its declaration;
  a reader that refuses a last line with no newline, which keeps the
  declared intensity;
* `service NAME disable` across a power cut, which must find the old
  text or the new one whole, and the new one once the command has
  reported: the command without its final sync;
* one row for each command: a command that applies the whole file,
  which ends and starts other rows at one row's `restart`; a command that
  acts without reading the file, which answers `enotsup` to a start the
  file has enabled;
* a row's supervisor: a keeper that does not link to its session; a
  keeper that asks `server_settled/1` only before its first start;
* judging a command: a judgement made from the table before the read;
  `one` forms judged as ordinary ones, which refuse `onestart` of a
  disabled row; a display check that counts the row itself, which
  refuses its `restart`; holders taken from the rows recorded enabled
  rather than the rows kept, which refuses a start on a stopped row's
  display; an unreadable file judged as a file with no settings, which
  starts a row declared `enable YES` whose record is disabled; the `eio`
  refusal applied to every command, which refuses the `stop` of a kept
  row;
* a read that fails at a command: a command that reads the failure as a
  file with no settings, which starts a row the file disabled; a start
  service that answers `eio` to every command whose read fails, which
  cannot stop a running row;
* a purge while an update approaches its publication: a table that
  takes `purge` among its commands and calls the package process, which
  leaves the publication and the purge each waiting for the other;
* a restart of the table's process: a restarted table that applies the
  file as a boot does; one that calls the package process for its set,
  which deadlocks behind a held install; one that ignores the boot mark
  and applies the file to every row it holds no record for;
* publications: a publication that applies the file to the rows it
  adds, which starts an app at its install and its update; the boot's
  set taken as a later publication, which leaves an enabled installed
  app `installed` after the boot;
* losing the store: a keepers' branch its top supervisor restarts,
  which applies the file again and starts a row no command started;
* a manual edit to `YES` and to `NO`: the shell's check of `/proc/apps`
  before writing `ctl`, which refuses a start the file has since
  enabled, or answers `already running?` from its cached state; a start
  service that ends the kept session of a row its read finds disabled.

**The manifest check.** One seeded manifest for each clause of property
17: a `start` row for a principal with no template; rows for
principals named `my-app` and `my_app`, whose variable names are one;
a row for a principal named `9lives`, whose variable name begins with
a digit; two rows for one principal; two enabled rows for one display;
a row whose display its template is not granted; enabled rows whose
sessions do not fit beside the configured domains; a board source
granting `etc` read-write to a template that holds no `start`, and one
granting it to a configured domain other than the system domain; and
an `apps` row naming `etc` under a property 19 without its exclusion,
whose derived grant this clause still refuses. Its passing case is a
fixture manifest holding a `start` row for a principal named
with a `-`, the system domain's read-write grant of `etc` and the
derived grants to the templates that hold `start`; seeded: a check
that compares principals' names unmapped, which admits `my-app` beside
`my_app`; a check that admits a writable `etc` grant only to templates
holding `start`, which refuses the system domain's; and one that
admits it to any domain, which admits the configured domain's. For start flags: a `start` row whose `flags` hold 1,025
bytes, or a `"`, which the packer and the manifest reader refuse; a
session template whose environment sets `ERX_START_FLAGS`; and one
whose arguments and environment leave room for every word the boot
view reserved before but not for the variable at its longest, which the
boot view refuses; seeded: a boot view that does not
look for the key in a template's environment, which admits the second, and the
variable left out of the reserve, which admits the third.

**QEMU tests**, in the suites of the tracks that bring the parts:

* a manifest with an app and an enabled row boots to that app's
  session, with no login, holding exactly its template's grants;
  seeded: the row disabled;
* a kiosk: its UI returns after its session is killed while a second
  session on the display stays hidden, and the row is down past its
  intensity; with the display domain killed, the kiosk's session gets
  its grant again and its UI returns; seeded: a domain service whose
  re-mint drops the session mark;
* `service enable` and `disable` change `/etc/start.conf` and start and
  stop nothing until the row's own command or a reboot, refusals of a
  held or ungranted display appear at the row's `start` and after a
  reboot, an editor's change waits for the row's command, and a native
  program can rewrite and list `/etc`; seeded: the merge's grant check
  removed, which starts a session that shows nothing; `enable` writing
  `start NAME` to `ctl`; a start service that applies the whole file at
  each command;
* a session whose template holds no `start` grant finds no
  `/etc/start`, no `/etc/start.conf` and no `/apps`, and its
  `erx:cap(start)` is undefined;
* the rescue configuration starts no row;
* a kiosk booted five times without an ordered end, its app reaching
  ready each time, never reaches the rescue configuration; seeded: a
  keeper that does not clear the count;
* the states the inspector shows, each with a test: `refused` with its
  reason, `down`, `disabled`, `stopped`, `installed`, and `start_conf`
  `failed` on a machine with no data partition, where the manifest's
  enabled rows still run; seeded: a boot that refuses as a command does,
  which starts no row.

**Fuzz targets**, each landing with its parser: the `ctl` line grammar,
and `start.conf`'s reader with the settings judgement over it, checking
that it never crashes and that every setting it gives is within its
bounds and names a row.

**Chokepoints**, each a build check with a seeded violation:

* `erx_starter` reaches the domain service only through the calls
  AP1 lists;
* only `erx_starter` passes `display`, `default_display` or `flags` to
  `start_session/2`;
* only `erx_console`, the web login and `erx_starter_keeper` call
  `start_session/2` (AP2);
* only `erx_starter_rc` writes, creates or renames a file on the `etc`
  grant, and only to carry out `enable` and `disable`.

## Performance

Starting an app is starting a session and booting its release.
`tools/erx bench app-start` measures it from the keeper's request to
the release's last application started, on the image's kiosk manifest,
and its number is stated with host, accelerator, QEMU version,
compiler, flags, workload and baseline.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| **App classes** for the manifest's own apps | [design-packaging.md](design-packaging.md#alternatives-considered) weighs classes for packages too and takes one `apps` row instead. For apps of the manifest a principal and a template of their own give per-app identity, authority and accounting with no mechanism beyond what principals already have |
| **Local rows for any principal with a template** | A crafted data partition could then start a person's session at a display without a login, or start any app. Declaring the rows in the manifest, as FreeBSD declares its services in `rc.d`, leaves the data partition able only to set what the builder declared |
| **Apps run in the session of whoever starts them**, as programs do | The app holds the person's whole authority; see [Security](#security). Programs keep that model, deliberately: a tool a person runs acts for that person |
| **An app is a configured domain** | A configured domain is part of the system: it sits in the boot order, its group is a child of `system`, it may hold devices, and its restarts are the domain service's. An app is a principal's code, charged to that principal under `users` |
| **A starter of its own**, with unit files, dependencies and socket activation | The domain service orders the system's services, OTP supervisors restart, and a session is already how a principal's code starts. A row and a keeper are what was missing |
| **Restarts by the domain service** | It would give sessions a second owner. The keeper is to its session what the console is to a login's |
| **A settings file the start service serves**, judged whole at each write and stored by it | It is not a real file: its text changes only at a sync or a close, an editor that saves by renaming fails, and each departure from a file's behaviour must be documented and tested. A plain file that any tool edits, and that every read judges, needs none of that |
| **FreeBSD's `/etc/rc.conf` itself**, by name | FreeBSD's file is `sh` that may set any variable and run any command, and its per-service variables carry authority (rc.conf(5)); erXos must refuse all of that (AP1), so the name would promise what the file does not do. The file borrows the assignment syntax and takes its own name |
| **The manifest's own `start` syntax** for the file | An invented syntax: rc.conf(5)'s assignments are a standard that FreeBSD users, `sysrc` and editors already know |
| **TOML**, one table per row, for the file | A standard with typed values and no `sh` look-alike, but one FreeBSD administrators do not use for service settings and `sysrc` does not edit. rc.conf(5)'s assignments are what they know; the cost is the field-name match and the literal `sh` subset of [The file's syntax](#the-start-table) |
| **Refusing a start row whose name holds `-`** | An app's name would then depend on whether it starts without a person, and a package whose name holds `-`, which an identifier allows, could not be installed. Mapping `-` to `_` in the variable keeps every identifier, at the cost of one rule both checks hold: no two rows share a variable name |
| **`service NAME purge` removing the name's lines from `start.conf`** | It would make the purge a second writer of the file and give it two resources to fail between, the app's data and the file. A line for a name with no row sets nothing and is reported at `/proc/apps` and by `service -c`, so the administrator deletes it with an editor |
| **One file for each setting**, `/etc/start/NAME/FIELD` | Seeing or copying a machine's configuration would take a walk of a tree; one file is read with `cat` and copied with `cp` |
| **One-shot rows**, which run once at boot and are not restarted | No consumer: `onestart` runs a row once now; the display's wait is the keeper's (`server_settled/1`); the restart intensity bounds a row that ends; and work a first boot must do belongs to the component that owns it. A restart kind on the row, OTP's `temporary` or `transient`, is the form to add when a consumer appears |
| **Ordering between rows** | No consumer: the configured domains are the system and their order is computed by the build; an app that needs a service waits on, or retries, the facet it uses, within its supervisor's intensity. A dependency graph would be a second boot order |
| **The whole of `start.conf` applied at every command**, so that after each command what runs is what a boot would start | An `enable` would start its row at the next command for any row, and an edit to `NO` would end a running row at another row's command, where on FreeBSD a variable decides only its own script's command and the boot (`rc.subr:1320-1352`). It needs a comparison of every row with the file at each read, a stopped mark for each row a command stopped so the comparison does not start it again, and a restart of each running row whose settings changed. Judging the display against the rows kept, rather than against every row the file enables, keeps the display rule one admission without it |
| **A lock around `start.conf`'s edits** | FreeBSD's `sysrc` takes none; two administrators editing at once is rare, and a lost change shows in `service -e` at once and at `/proc/apps` after the row's next command |
| **The start service watching `start.conf` for changes** | It would act on an editor's half-written file, and FreeBSD reads the file only when a service acts |

## Risks and decisions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| an app's ready report comes before its applications have done any work, so a system fault soon after that point does not count toward rescue | medium | a machine that faults soon after every boot never reaches the rescue configuration | recorded in `TODO.md`; a later ready point is the change |
| every app in the manifest makes the board's manifest long | medium | adding an app of the manifest is a manifest edit and a rebuild | packages ([design-packaging.md](design-packaging.md)), which add apps without either |

Decisions:

1. **A kiosk's app is an app like any other**: it runs with whatever
   privileges its app holds and a grant of the display, and renders to
   the display.
2. **erXos is a distribution to which users and developers add apps**,
   so nothing here assumes the manifest is the only source of
   principals, and packaging joins at the seam of
   [Packaging](#packaging).
3. **A kept session counts as a login for the reset count**: the first
   session a start row keeps that reports ready clears the count, as an
   automatic login does ([Keeping a session](#keeping-a-session)).
4. **A start row for a person's principal is the image builder's**,
   until the login design says what an automatic login at a display is.
5. **`start.conf` is an ordinary file, `/etc/start.conf`**, in rc.conf(5)'s
   assignment syntax, which the start service reads and judges at boot,
   for the rows of the boot's table, and at each command, for that
   command's row, and writes only to carry out `enable` and `disable`; a row a later
   publication adds enters the table with no read;
   `service NAME enable` and `disable` edit it through the start
   service as `sysrc` does, one at a time, and `ctl` also takes
   `start`, `stop`, `restart`, their `one` forms, and `purge`.
6. **The start service judges every command after its read**, and
   `ctl` carries the caller's ordinary or `one` intent, so the shell's
   `service` decides nothing from `/proc/apps`
   ([How a command is judged](#how-a-command-is-judged)).
7. **`service NAME enable` and `disable` only edit `start.conf`**, as
   FreeBSD's do (`rc.subr:1451-1459`), reading it afresh each time, and
   `start` is explicit;
   `service -e` shows the configured state, read from the file, and
   `/proc/apps` the applied and running state.
8. **At `/etc` and `/dev` a program's namespace joins the session's
   export and the session's grant**: the export answers its own names,
   `/dev/zero` and `/dev/urandom` among them, and every other name
   reaches the grant within the program's narrowed roots and rights;
   a listing and a walk agree, and no file of the grant replaces one
   of the export's names
   ([design-files.md](design-files.md#narrowing-for-a-program)).
9. **The file is applied only at boot and at a row's own command**:
   at boot to every row of the boot's table, the manifest's and those of
   the boot's package set, and at each command to its one row. Nothing
   compares the table with the file, and only a kept row holds its
   display ([When the file is read](#the-start-table),
   [Concurrency](#concurrency)).
10. **A command whose read cannot read `start.conf` starts nothing**:
    `start`, `restart`, `onestart` and `onerestart` answer `eio`, while
    `enable` and `disable` answer `eio` and write nothing, and `stop` and
    `onestop` are judged on the row as it was last applied, so an
    administrator can always stop a running row; the boot reads
    the failure as a file with no settings, so a machine whose storage
    domain is down starts what its build proved
    ([A read that cannot read the file](#the-start-table)).
11. **The table never waits for the package process**, which waits for
    the table at each publication: a `ctl` write's callback awaits a purge,
    and a restarted table takes the last set from its records process
    ([Concurrency](#concurrency)).
12. **Publishing an app applies nothing of `start.conf`**: an install or an
    update only replaces the app's files, and its row is installed until
    `service NAME start` or `restart`, or the next boot, as FreeBSD's
    `pkg upgrade` leaves services alone. Since an update ends the app's
    sessions before its package's name changes, an updated app stays
    stopped until one of those runs it; the boot mark tells a restarted
    table whether a row with no record is the boot's to apply or a
    publication's, `installed` until its own command
    ([Packaging](#packaging), [Concurrency](#concurrency)).
13. **`installed` is derived**: a row of an admitted package with no
    record shows it, and nothing keeps it as a state of its own.
14. **An end of the records process or of the keepers' branch resets
    the machine**, as an end of `erx_pkg_io` does, since a table that
    applied the file again could start an installed or stopped row
    without its command ([Concurrency](#concurrency)).
15. **Many machines share a configuration through their image**: the
    manifest's `start` rows and the packages' declarations are what every
    machine of an image shares, and `/etc/start.conf` holds one machine's
    departures; copying the file copies them.
16. **The file's syntax is rc.conf(5)'s assignments**, the literal
    subset of [The file's syntax](#the-start-table), and nothing in the
    file is executed. Only that section and the reader depend on it.
17. **No one-shot rows and no ordering between rows** until a consumer
    needs them ([Alternatives considered](#alternatives-considered)).

## References

* Fuchsia: components and the session framework. <https://fuchsia.dev/fuchsia-src/concepts/components/v2>
* Android: application sandbox. <https://source.android.com/docs/security/app-sandbox>
* Apple: `launchd.plist(5)`.
* FreeBSD: `rc(8)`, `rc.conf(5)`, `service(8)`, `sysrc(8)`. Read for
  this design at `release/15.1.0`: `libexec/rc/rc.subr` (SHA-256
  `f934e89957223f4816821a3ccf2e8f476d28d906358cdf06cfd6db65ab44cbb1`),
  `usr.sbin/bsdconfig/share/sysrc.subr` (SHA-256
  `c1bdbc1b665f938a6aa1439e1793287df32210fb386993136e9b0e0867f64e48`),
  `usr.sbin/service/service.sh` (SHA-256
  `144174bc3d03109787cd7ea3a3f8f21f350a19b968bf584bf479c874012b5995`),
  `share/man/man5/rc.conf.5` (SHA-256
  `bebf785c43ef4e943b247994335766c9fbd762e1e81f99da0a4f2e11028e8044`)
  and `usr.sbin/sysrc/sysrc.8` (SHA-256
  `c339389dcc551975bf88077c7dd279824d30653a2fbcde9c9040b2efbc2fbce9`).
* QNX Neutrino: `mkifs` buildfiles and the System Launch and Monitor.
