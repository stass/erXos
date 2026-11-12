# Apps: the start table

An **app** is code that runs for no person: a kiosk's screen, a
dashboard, a network service, a developer's experiment. This document
says what authority an app's code runs with, and what starts it and
starts it again. It adds one thing, the start table, because the system
already has every other part: an app is a principal, its code is the
release of that principal's session template, its authority is the
facet rows granted to that template, and its code runs in a session of
that principal. How an app reaches a machine after the image is built,
as a package someone installs, is a later design's
([Packaging](#packaging)); this one keeps the seam it plugs into open.
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
  optionally a display, and a restart intensity. The manifest's `start`
  rows declare what may start and give each row's defaults, as
  FreeBSD's `rc.d` scripts and `/etc/defaults/rc.conf` do;
  `/apps/rc.conf` holds the machine's own settings of those rows, as
  `/etc/rc.conf` does. A kiosk is an enabled row that names an app and a
  display.
* **The table keys on a principal, and on nothing about where the
  principal came from.** The manifest is the only source of principals
  today; principals added at run time, by packaging, start the same way
  ([Packaging](#packaging)).
* **Nothing starts because it exists.** A principal's session starts
  without a person only from an enabled row, or once by a command;
  `service NAME enable` starts it at boot, as on FreeBSD.

**Is there one place that says when and where everything starts?** Yes,
in two parts of one manifest and one file. The manifest's `domain` rows
start the system's services, in the order the build computes, and the
start table, the manifest's `start` rows with `/apps/rc.conf` over them,
starts everything else. `service -e` prints both.

**Where do I add my kiosk app?** In the board's manifest: a principal
for the app, its session template naming the app's release, a facet row
granting the template the display, and a `start` row that names the app
and the display. On a running machine whose manifest declares the row,
`service thermostat enable display=display` enables it.

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
* **AP-R6.** `rc.conf` and everything else read back from the data
  partition are untrusted input.
* **AP-R7.** The interface feels like FreeBSD's `service`.

Outside this design: packages, their format, signatures, installing,
updating and removing an app at run time, and every per-app mechanism
they need ([Packaging](#packaging)); prompts that ask a person to
approve a grant; passing one of a person's files to an app; apps that
serve facets to other apps; starting an app at a person's login, which
belongs to the login design
([design-display.md](design-display.md#risks-and-decisions), 14); and
drivers, which are processes of a configured domain that holds the
device ([design-system.md](design-system.md#devices)).

## Overview

```text
 the build                               the machine
 ---------                               -----------
 manifest: principal clock, its           system domain
   session template (release               erx_starter merges the `start` rows with rc.conf,
   @artifact.clock), facet rows                |       one supervisor and keeper per enabled
   granting the template, `start` rows         |       row; serves /apps (ctl, rc.conf)
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
app needs, and a `start` row for `clock`. At boot, once the configured
domains run, the start service, `erx_starter`, merges the manifest's
`start` rows with `rc.conf` and starts a supervisor for each enabled
row; the row's supervisor starts its keeper, a process that asks the
domain service for a session of `clock`. The domain service makes the
session from `clock`'s template, as it makes any session, and grants it
the template's facet rows. The session's runtime boots `clock`'s script,
which starts its applications. When the session ends, the row's
supervisor starts the keeper again within the row's intensity.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **AP1.** Enabling, disabling or starting a row changes nothing the manifest check proved | a row carries a principal, a flag, a display and an intensity, and no limit, grant, device, service or code; the keeper's session is planned by `erx_dom_plan_session` from its principal's template index as every session is, and its facets pass the domain service's one funnel, which installs only rows of the manifest; so the manifest stays the only source of every domain row, device holder, service, budget, share, quota, limit and grant ([design-system.md](design-system.md#invariants), A10) | a row field that names a grant, a limit or a release; a keeper that creates a domain by any call but `start_session/2` | a source check that `erx_starter` reaches the domain service only through `erx_domain:start_session/2` and `erx_domain:stop/2`, reading a handle with `erx_domain:id/1` and `erx_domain:pid/1`, which reach nothing, with a seeded call of `erx_domain:create/1` |
| **AP2.** A session exists without a person only by a row of the start table | the keepers of `erx_starter` are the only callers of `erx_domain:start_session/2` besides the console and the web login, and a keeper exists only for an enabled row or one `start` command on a row | another boot-time starter | a source check that only `erx_console`, the web login and `erx_starter_keeper` call `erx_domain:start_session/2`, with a seeded call from another module; the source check of AP1; a QEMU test that boots a manifest with no `start` row and finds no session but the console's |
| **AP3.** The table names only principals the manifest declares startable | a row exists only for a manifest `start` row; an `rc.conf` line or a `ctl` command for a name with no such row is skipped or refused, so the data partition and the `apps` grant only enable, disable or set the display and intensity of a declared row | a local line that adds a row | the merge's host test, a line for an unknown name skipped; seeded: a merge that adds a row for a principal with a template but no `start` row |
| **AP4.** A display's session is the session its enabled row keeps, and no other, across a restart of either domain | the merged table holds at most one enabled row for each display; only a row's keeper names a display with `display`; the domain service fixes the session mark in the record of that session's grant on the display and every mint of the record carries it ([design-system.md](design-system.md#facets-a-configured-domain-serves)) | two enabled rows on one display; a mark set by whichever session opens a window first; a re-mint that drops the mark | the table's host test with two enabled rows on one display, the second refused; the kiosk tests of [Verification and testing](#verification-and-testing), the display domain's restart among them |
| **AP5.** A row whose display its principal cannot draw on never starts | the merge refuses a row whose display is not a `windows` service granted to its principal's template, with `{no_grant, Display}` at `/proc/apps`; the manifest check refuses such a manifest row (property 17) and `service enable` such a command | a reserved display that stays blank because its session holds no grant there | the merge's host test; the QEMU test of a local line naming such a display |

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
facet clock_data
  name "data"
  grantee @session.clock
  service @service.data
  ...
```

* **The principal** pays for the app's sessions: its budget, its group
  under `users` and its `domains` and `names` quotas, which the manifest
  check sums with every other principal's (property 4).
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
  as the row's parameters, the network by a row of `net`, and files of
  its own by a row of `data`, which the storage service roots at the
  principal's directory.

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

The manifest's `start` rows declare every row the table can hold, with
its defaults; this one declares `clock` and leaves it off:

```text
start clock
  enable NO
  display @service.display
  restarts 5
  restart_period_s 600
```

`/apps/rc.conf` holds the machine's own settings of those rows, in
rc.conf(5)'s form, one variable per line:

```text
clock_enable="YES"
clock_display="display"
clock_restarts="5"
clock_period="600"
```

A variable's name is a row's principal, `_`, and one of `enable`,
`display`, `restarts` and `period`, split at its last `_`. A setting
replaces the manifest's default for that field of that row, and
`NAME_display=""` clears the row's display. A line for a principal that
has no manifest `start` row, or that does not parse, is skipped and
reported, and the rest of the file stands, so the file sets what the
manifest declared and adds nothing.

**The merge** is one pure function, `erx_start_table:merge(Rows, Local,
Grants)`, over the manifest's rows, the parsed `rc.conf` and each
template's `windows` grants. It applies the settings and then takes the
enabled rows in the manifest's order:

1. a row whose display is not a `windows` service granted to its
   principal's template is refused with `{no_grant, Display}`;
2. a row whose display an earlier enabled row holds is refused with
   `{display_held, Name}`;
3. every other enabled row is the table's.

Each refused row keeps its reason, which `/proc/apps` shows, so a
setting that cannot take effect is visible rather than a blank screen.
The manifest's own rows pass both checks at build (property 17), so
only a local setting is ever refused.

**Where the file is.** `rc.conf` is `start/rc.conf` in the system
domain's own directory of the data partition, the root of the system
domain's `data` grant, which the start service reads and writes. Every
other grant of `data` is rooted at its own principal's or service's
directory ([design-storage.md](design-storage.md#interfaces)), none of
which is the system domain's, so no other domain reaches the file. The `apps` tree shows it read-only at `/apps/rc.conf`. The file is
at most 64 KiB, and the table at most `start_rows_max`, 256 rows.

The configured domains are not rows of the table: they are the system
itself, their order is computed, and their place is the manifest alone.
`service -e` prints both, the configured domains in boot order and then
the table, so one command shows everything that starts.

## Algorithms and behavior

### Starting a session

Every session a row keeps is started by a **keeper**, a process of
`erx_starter`, with `erx_domain:start_session(Principal, Start)`. `Start`
names the display in one of two ways: `#{display => D}` from an enabled
row's keeper, which makes the session the display's session, or
`#{default_display => D}` from `onestart` and `start APP display=D` on a
row that is not enabled, which only sets the session's `display`
variable. The domain service:

1. plans the session from the principal's template, with the name
   `<principal>_<n>`, as it plans any session; the library charges the
   principal, and refuses the start with `quota` or `no_memory` when the
   principal has no room;
2. at the session's ready report, starts the facets of the system
   domain's services and adds a grant record for each of the template's
   rows of configured domains' services
   ([design-system.md](design-system.md#facets-a-configured-domain-serves)),
   with the session mark set in the record of the grant on the display
   `Start` names with `display`, and in no other;
3. hands the session its default display with the ready answer: the
   display `Start` names, or else the one display the session holds,
   where it holds exactly one
   ([design-display.md](design-display.md#choosing-a-display));
4. answers the keeper once each `files` grant of the session has
   settled, as it answers a console's start
   ([design-system.md](design-system.md#a-session-takes-the-console)).

The session's runtime boots its template's script, so its applications
start as any release's do. It has no console line and no terminal: what
its programs write to their standard streams, and what its logger
prints, are log records under the session's name
([design-live.md](design-live.md#attributed-text)). The session ends
when a permanent application of its release ends, and that end is the
domain's, with its reason in the death record.

### Keeping a session

A keeper holds one session. It starts the session and links to its
domain pid, and exits when the session ends or its start is refused.
The link also ends the session with its keeper, for any end of the
keeper, a kill included, as a web login's sessions end with the web
login service. Each enabled row has a supervisor of its own in
`erx_starter`, with the row's intensity and the keeper as its one
permanent child, so OTP's supervisor is the restart policy and no other
exists:

* a session that ends, for any reason, is started again;
* more than `restarts` ends within `restart_period_s` end the row's
  supervisor. The row is then **down**, shown so at `/proc/apps`, and
  stays down, whatever `rc.conf` then sets, until `service NAME start`,
  `service NAME enable` or the next boot;
* one row's failure touches no other row, since each has its own
  supervisor under a parent that restarts none of them.

The boot starts the table at step 5 of
[Boot](design-system.md#boot): once the configured domains of the boot
order run, `erx_starter` merges the table and starts each enabled row's
supervisor, a row that names a display once that display's domain has
reported ready. The rescue configuration starts no row.

A session started with `service NAME onestart` has a keeper under no
supervisor: it is started once and nobody starts it again.

**A display's session** is the session of the enabled row that names
the display. Its restart policy therefore lives in that row, beside
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

### Developers

* **Build.** An app is its principal, its template, its facet rows and
  its `start` row in the manifest, and its applications in the boot
  image's domain release with a boot script of their own, which the
  build packs as it packs every release's.
* **Iterate.** With the app running, `tools/erx watch DIR --domain
  clock_1` loads each changed module into the session through its code
  facet, as for any domain ([design-live.md](design-live.md#the-code-store)).
* **A development build** gives `root`'s session the `apps` grant, so
  `service` works at its shell. Its banner says what such a build is:
  `development build: trusted code only`.

### Packaging

The start table keys on a principal with a session template and a
`start` row, and on nothing else. The manifest is the only source of
these today. An app added to a running machine, as a file a person or a
developer installs, becomes a principal with a template and a `start`
row the same way, so the table, its keepers, the domain service and the
display treat it as they treat an app of the manifest, and nothing in
this design changes for it. How a package declares those rows, which
grants it may take within what the build proved, how it is signed,
installed, updated and removed, and what it does to an app's data, is
the packaging design's, written when track A reaches it
([plan.md](plan.md#track-a-apps)). Its inputs are recorded in `TODO.md`.

## Interfaces

**Commands**, Erlang commands of the command shell
([design-shell.md](design-shell.md#commands)), each declaring
`-erx_needs([apps])`:

| Command | Does |
| --- | --- |
| `service NAME enable [display=D] [restarts=N] [period=S]` | sets the row's settings in `rc.conf`, enables it and starts it; refused for a name with no manifest row, a display another enabled row holds (with that row's name), and a display the principal's template is not granted |
| `service NAME disable` | stops the row and sets it disabled |
| `service NAME start`, `stop`, `restart`, `status` | acts on an enabled row; on a row that is not enabled each answers as rc.subr(8) does, names its `one` form and does nothing |
| `service NAME onestart [display=D]`, `onestop`, `onerestart`, `onestatus` | as above on any row: `onestart` starts the row's principal once, with no supervisor, and `onestop` stops it |
| `service -e` | prints the configured domains in boot order, then the enabled rows that are not refused |

For a configured domain, `service` answers every request that it is
configured in the system manifest; its state is at `[domains, Id]`.

**The `apps` tree**, a service of the system domain and an instance of
`files`, which `erx_starter` serves with `erx_fs` and a session mounts at
`/apps`:

| File | Read | Write |
| --- | --- | --- |
| `ctl` | nothing | one command a write, a line of at most 4,096 bytes: `enable NAME [display=D] [restarts=N] [period=S]`, `disable NAME`, `start NAME [display=D]`, which starts a row that is stopped or down, or, for a row that is not enabled, one session that no supervisor keeps, and `stop NAME`. The write succeeds when the command does; a 9P write carries no text back, so a refusal answers an errno: `einval` for a line that does not parse, a name with no manifest row or any other refused command, `ebusy` for a display another enabled row holds, `eperm` for a display the template is not granted, `eagain` while `rc.conf` is unread, and `eio` for a failed write of `rc.conf` or start, or a start service that ended during the command. The reason goes to the log, and a row's own reason is shown at `/proc/apps` |
| `rc.conf` | the machine's settings | nothing |

Which templates hold the `apps` grant is the manifest's: `root`'s in a
development build, an administrator's in a release build. A session
whose template holds no `apps` grant has no `/apps` at all.

**Inspection**, in `abi/inspection.txt`, reported by the start service
and shown at `/proc/apps`, to an inspect facet of scope `all`: `[apps]`,
of kind `start_table`, gives `boot_order`, the configured domains in
boot order, and `rc_conf`, whether `rc.conf` has been read, and lists
the rows by principal; `[apps, Name]` gives `state`, `reason`, `domain`,
`enabled`, `display`, which settings come from `rc.conf`, and the ends
within the row's period. The state is `refused`, with its refusal as the
reason, `disabled`, or for an enabled row where the keepers' branch says
its session stands: `running`, `down`, `stopped`, marked so by `service
NAME stop`, or `starting`, neither kept nor marked, which the table
starts when it next reconciles. A session `onestart` started belongs to
no row and is not shown. An app's sessions are domains like any other at
`[domains, Id]`.

**Manifest rows**: `start`. Its packed record and the reader's bounds
are in `abi/manifest.txt`. The start service reads the `start` rows,
the session templates and their `windows` grants through `erx_manifest`.

**The ABI source**: the limits `start_rows_max`, `start_restarts_max`
and `start_period_max_s`.

**Erlang**: `erx_domain:start_session/2`, whose second argument may
name a display.

### Other subsystems

| Subsystem | Interaction |
| --- | --- |
| the domain service | makes a row's session from its principal's template; fixes the session mark in the record of the grant on the display a keeper's start names, and carries it in every mint of that record |
| the storage service | holds `rc.conf` in the system domain's directory; roots every other `data` grant at its principal's directory |
| the display | serves every session that holds its grant, and under the single policy shows the windows of the display's session alone ([design-display.md](design-display.md#a-displays-session)) |

## Concurrency

The start service is one process that owns the merged table. It does no
file operation itself: a change of `rc.conf` runs in a worker and hands
the service the finished result to commit, so a slow storage domain
delays that one command and nothing else. Reads of `/proc/apps` and
`rc.conf` are answered from the process's own state.

The keepers are a separate branch of the application's supervision
tree, so a crash of the table's process restarts it and no session ends.
The keepers' branch also holds what the table must not forget, as child
specs OTP keeps without a process: each enabled row's supervisor spec,
with what its session is kept with, whose missing pid is a row that is
down; a stopped mark, a bare name, for each row `service NAME stop`
stopped while it was enabled; and the text of `rc.conf` the table was
last made from. These records are the only store of the rows' run
state; the table's process keeps none of its own.

Each time the table is made from `rc.conf`'s text, a pure decision
(`erx_start_table:reconcile/3`) compares every row's record with the
row the text makes: a held row that is marked stopped or no longer
enabled stops, a running row whose settings changed is restarted, and
an enabled row that is neither held nor marked starts. A row that is down or stopped stays so whatever its settings, as on
FreeBSD, where editing `rc.conf` starts no service that is not running:
only `service NAME start` or `enable`, which starts its row, clears the
mark and runs it again. Disabling a row that is down drops its record,
so the row is then simply not enabled.
`stop` and `start` write their record before the act it records, so a
table that ends between the two leaves the intent behind: `stop` marks
the row before it ends it, and `start` clears the mark before it starts
it. `enable` writes `rc.conf` first, then clears the mark and the record
of a row that is down, and only then makes the table from the new text,
which starts the row: a table that ends after the clear finds the row
enabled, unmarked and not held, and starts it once its own read answers;
one that ends while the write is in progress leaves the mark, so the row
stays stopped and the command answers an error (TODO.md).
The text of `rc.conf` is recorded under a generation: the new text is
added under the next one before the old is dropped, so a table that ends
mid-record finds the old text or the new, takes the newest, and never
finds none.

A restarted table makes its table from the recorded text and changes no
keeper until its own read of `rc.conf` answers, so a row `rc.conf`
enabled is not stopped because the file cannot be read. A crash of the
keepers' branch ends every session it kept, drops its records, stopped
marks included, and makes the table again as at boot.

## Compatibility and migration

The `start` row and `rc.conf`'s grammar owe nothing to earlier forms
([design.md](design.md#decisions), "No backward compatibility in
development"). `rc.conf` lines the grammar does not hold are skipped and
reported.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | What happens |
| --- | --- | --- |
| the storage domain is down at boot | the system domain's `data` grant is absent | the manifest's enabled rows start; the local settings wait for `rc.conf`, which is read again after a backoff that grows to a minute and never gives up, since no notice tells the system domain that its grant arrived; a running row they change is stopped and started again, one they disable stops, and until the read answers `/proc/apps` says `rc.conf` is unread |
| the principal has no room | the domain library's plan | the start is refused with `quota` or `no_memory`; a kept row counts it as an end |
| a session ends more often than its row allows | the row's supervisor | the row is down, with the last reason at `/proc/apps`, until `service NAME start` or `enable` |
| a local setting names a display the template is not granted, or one another enabled row holds | the merge | the row is `refused` with `{no_grant, D}` or `{display_held, Name}` at `/proc/apps`, and starts nothing |
| `rc.conf` is damaged, or names a row the manifest does not declare | the table's parser | bad lines are skipped and reported; the manifest's rows stand |
| the display domain restarts under a display's session | the domain service's grant record | the grant is minted again on the new incarnation, with the session mark |
| the start service crashes | its supervisor | it restarts with the table the keepers' branch recorded and reads `rc.conf` again; kept sessions go on, and stopped and down rows stay so |

Every state and reason above is an attribute at `/proc/apps`, and every
refusal is a log line that names the row or the line. Nothing is shown
as running that the domain service does not list.

## Security

**What is trusted.** The manifest, with its principals, templates,
facet rows and `start` rows, as part of the boot image; the start
service and the domain service, in the system domain; the boot image's
domain release, the app's applications among it.

**What is not.** An app's code, which runs with its template's grants
and no more; the data partition, and so `rc.conf`; the storage domain.

* **The system domain parses two small texts.** A `ctl` line and
  `rc.conf` have bounded grammars with fuzz targets. The system domain
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
  holds no `apps` grant unless its template was deliberately granted
  one, and it cannot reach `rc.conf`, which lies outside every grant but
  the system domain's.
* **A crafted data partition, or a storage domain it has taken over,**
  can rewrite `rc.conf` to enable or disable rows the manifest declares,
  and to move a display between rows whose templates are granted it,
  and read or destroy every app's data. It cannot start a principal
  that has no `start` row, widen a grant, or put a session on a display
  its template cannot draw on.
* **Who may start without a person** is the image builder's to say: a
  principal starts without a login only if the manifest gives it a
  `start` row, a person's principal included, which makes that person's
  session at a display a login nobody typed
  ([design-display.md](design-display.md#a-displays-session)). Whether a
  principal a start row names can also be enrolled and logged in to at a
  console line is the login design's; the gap is recorded in `TODO.md`.

## Phase 1

Phase 1 runs trusted code, and builds this design against its target
interfaces. It defers enforcement that rests on parts that arrive
later, and reports each as it is:

| Deferred | Until | Meanwhile |
| --- | --- | --- |
| rooting `data` grants by principal | facet parameters and principals' directories | each grant covers the whole tree, so every domain holding `data` can rewrite `rc.conf` and reach every app's directory: a security residual in `TODO.md` |
| budgets and quotas as limits | erXos's kernel | they are records the build checked |

## Verification and testing

Each test is paired with the seeded fault that proves it runs the code
it guards.

**Host tests.**

| Test | Passing case | Seeded fault |
| --- | --- | --- |
| the merge | settings replace defaults; `NO` disables; a bad line and a line for an undeclared name are skipped and reported; a second enabled row on one display is refused with the first's name; a row whose display its template is not granted is refused with `{no_grant, D}` | a merge that adds a row for an undeclared principal; the display rule dropped; the grant check dropped |
| `rc.conf`'s names | `a_b_enable` sets `enable` of the row `a_b` | a split at the first `_` |
| a row's supervisor | with a stub domain service: an ended session is started again; one end more than the intensity leaves the row down and the other rows up | a keeper that does not link to its session |

**The manifest check.** One seeded manifest for each clause of property
17: a `start` row for a principal with no template; two rows for one
principal; two enabled rows for one display; a row whose display its
template is not granted; enabled rows whose sessions do not fit beside
the configured domains.

**QEMU tests**, in the suites of the tracks that bring the parts:

* a manifest with an app and an enabled row boots to that app's
  session, with no login, holding exactly its template's grants;
  seeded: the row disabled, and the test finds no session;
* a kiosk manifest: the app's UI is on the display's screenshot after
  boot; the session is killed and the UI returns, while a second
  session holding a grant on the display stays hidden; killed past its
  intensity, `/proc/apps` shows the row down;
* a kiosk with its display domain killed: the display domain restarts,
  the kiosk's session, still running, gets its grant again and its UI
  returns on the screenshot, while the second session's window stays
  hidden; seeded: a domain service whose re-mint drops the session
  mark, which leaves the background;
* `service enable` and `disable` change `rc.conf` and survive a reboot;
  an enable on a display another row holds, and one on a display the
  template is not granted, are refused; an `rc.conf` line written
  directly that names such a display leaves the row `refused` with its
  reason at `/proc/apps` and starts nothing; seeded: the merge's grant
  check removed, which starts a session that shows nothing;
* a session whose template holds no `apps` grant finds no `/apps`, and
  its `erx:cap(apps)` is undefined;
* the rescue configuration starts no row;
* a kiosk booted five times without an ordered end, its app reaching
  ready each time, never reaches the rescue configuration; seeded: a
  keeper that does not clear the count;
* the states the inspector shows, each with a test: a row that is
  `refused` with its reason, `down`, and `disabled`.

Once `data` grants are rooted by principal, a session holding `data`
finds no `start/rc.conf` under its `/data`; until then the gap is the
Phase 1 residual above, and no test claims it.

**Fuzz targets**, each landing with its parser: the `ctl` line grammar
and `rc.conf`'s grammar.

**Chokepoints**, each a build check with a seeded violation:

* `erx_starter` reaches the domain service only through
  `start_session/2` and `stop/2`;
* only `erx_starter` passes `display` or `default_display` to
  `start_session/2`;
* only `erx_console`, the web login and `erx_starter_keeper` call
  `start_session/2` (AP2).

## Performance

Starting an app is starting a session and booting its release.
`tools/erx bench app-start` measures it from the keeper's request to
the release's last application started, on the image's kiosk manifest,
and its number is stated with host, accelerator, QEMU version,
compiler, flags, workload and baseline.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| **App classes**: a template and a principal shared by many apps as their pool, each app a principal of its own with a subset of the class's grants, admitted by a check on the machine | It is what apps installed at run time need, so it belongs to the packaging design, which has those apps in view. For apps of the manifest a principal and a template of their own give per-app identity, authority and accounting with no mechanism beyond what principals already have; its earlier design is an input of the packaging design in `TODO.md` |
| **Local rows for any principal with a template** | A crafted data partition could then start a person's session at a display without a login, or start any app. Declaring the rows in the manifest, as FreeBSD declares its services in `rc.d`, leaves the data partition able only to set what the builder declared |
| **Apps run in the session of whoever starts them**, as programs do | The app holds the person's whole authority; see [Security](#security). Programs keep that model, deliberately: a tool a person runs acts for that person |
| **An app is a configured domain** | A configured domain is part of the system: it sits in the boot order, its group is a child of `system`, it may hold devices, and its restarts are the domain service's. An app is a principal's code, charged to that principal under `users` |
| **A starter of its own**, with unit files, dependencies and socket activation | The domain service orders the system's services, OTP supervisors restart, and a session is already how a principal's code starts. A row and a keeper are what was missing |
| **Restarts by the domain service** | It would give sessions a second owner. The keeper is to its session what the console is to a login's |

## Risks and decisions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| an app's ready report comes before its applications have done any work, so a system fault soon after that point does not count toward rescue | medium | a machine that faults soon after every boot never reaches the rescue configuration | recorded in `TODO.md`; a later ready point is the change |
| every app in the manifest makes the board's manifest long | medium | adding an app is a manifest edit and a rebuild until packaging | the packaging design, which adds apps without either |

Decisions taken with the owner:

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

## References

* Fuchsia: components and the session framework. <https://fuchsia.dev/fuchsia-src/concepts/components/v2>
* Android: application sandbox. <https://source.android.com/docs/security/app-sandbox>
* Apple: `launchd.plist(5)`.
* FreeBSD: `rc(8)`, `rc.conf(5)`, `service(8)`, `sysrc(8)`.
* QNX Neutrino: `mkifs` buildfiles and the System Launch and Monitor.
