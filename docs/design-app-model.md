# The app model: programs, apps and the board

This document says what a person does to get code running on erXos and
what they must understand first. Three kinds of thing run on a machine,
and each is written by a different person.

**A program is a file.** Whoever has the SDK builds it, copies it to a
running machine and runs it, as on FreeBSD and QNX:

```text
on the host      erx-cc -o hello hello.c       build it with the SDK
                 scp hello root@board:         copy it into your home
on the machine   chmod +x hello                if the copy did not keep the mode
                 ./hello                       it runs as you, in your session
                 within /root/in -- ./hello    the same, holding one directory and nothing else
```

**An app is a package.** Code that runs for no person, a service or
something on a screen, is one file made by one command, and it is added,
started, narrowed and removed on a running machine:

```text
on the host      erx-app pack hello            hello.app, from the one file
                 scp hello.app root@board:
on the machine   cp hello.app /apps/           install it
                 service hello enable          start it at every boot
                 service hello start           start it now
```

**The board is the manifest.** The devices, the drivers, the system's
own services and what apps may be offered are one checked text,
`config/manifest/BOARD.txt`, which a system integrator writes and the
build proves. Changing it is a new image, as changing a QNX buildfile
is, and nobody else ever edits it.

The central construction is that **authority runs down one chain, each
link selects from the link above it and can name nothing outside it,
and everything a person writes is written at exactly one link**:

```text
 the board's manifest        what exists on this machine and what an app may be offered
   |                         (the integrator writes it; the build proves it; it is in the boot image)
   v
 an app's declaration        which of the offer this app takes, and its memory
   |                         (its author writes it; it is sealed in the package)
   v
 the machine's settings      what this machine withholds from the app, and whether it starts
   |                         (/etc/start.conf, which `service` edits)
   v
 a session                   the app's own, or a person's from a login
   |
   v
 a program                   a file its starter runs; it holds what its starter holds, or less
   |                         (nothing is written)
   v
 `within`                    what one run is narrowed to
                             (typed on the command line)
```

Four things follow, and the rest of this document is their detail:

* **A program declares nothing.** It lies below a session and holds a
  part of what that session holds, so there is nothing for it to ask
  for, and running a file gives the file's code no authority its
  starter lacked.
* **An app's services are named in one place**, its declaration, and
  the board's offer is their ceiling. The settings below it have fields
  that take away and none that adds.
* **A record on the data partition cannot add authority**, because no
  link below the declaration has a field that names a service, a grant
  or a user. A storage domain that rewrites every such record gives an
  app back, at most, what its sealed declaration asked for.
* **The build's proof covers the top link alone** and holds whatever
  lies below it: the board's own domains keep their memory, CPU and
  devices whichever programs and apps arrive.

The mechanisms are those of the existing designs: programs and their
handlers in [design-programs.md](design-programs.md); namespaces,
grants and the file protocol in [design-files.md](design-files.md);
the shell and `within` in [design-shell.md](design-shell.md);
principals and sessions in
[design-domains.md](design-domains.md#principals-sessions-and-quotas);
the start table and `service` in [design-apps.md](design-apps.md); the
package, `/apps` and admission in
[design-packaging.md](design-packaging.md); the manifest, its check and
the resource policy in [design-system.md](design-system.md). This
document is the model across them. [Compatibility and
migration](#compatibility-and-migration) lists each section of another
design that it changes.

## Context

### What a developer meets

Read from the design documents and the shipped manifests.

| Task | What it takes |
| --- | --- |
| Run a C program you built | A file copied onto the machine never runs: a path command needs an `rx` grant ([design-shell.md](design-shell.md#commands)), a home is `rw`, and invariant F6 of [design-files.md](design-files.md#invariants) has a test that a file a session wrote and then mounted `rx` still fails with `EACCES`. `chmod` changes a mode that gates nothing ([design-programs.md](design-programs.md#the-posix-lite-personality), "Users and files"). The ways in are the boot image's `/bin` or a package |
| Run an Erlang program | No `#!` line is interpreted ([design-shell.md](design-shell.md#commands)) and there is no file form of an Erlang program; code that persists goes into a package or an image |
| Add a service to a board | `ntpd` is a principal, a session template with a hand-written ERTS argument line, two facet rows with five quantities each and a `start` row, nearly forty lines of `config/manifest/raspi4b-development.txt`, under a comment that reckons by hand what it adds to `root_memory`, `max_domains` and `max_connections` |
| Give an app more | An app takes only what the `apps` row's `services` offer, so anything beyond is a new image |
| Give a program memory | A program lives in half of its session's 36 MiB (`limits session` of `config/manifest/development.txt`; [design-system.md](design-system.md#resource-policy), "Budgets"), a size the manifest fixes whatever the board holds, so a larger program does not start on a board with gigabytes free |
| Size the machine | `root_memory`, the system principal's `memory`, the display's outer budget and the `apps` row's `memory` are sums written in the manifest and explained in its comments |

The app author's surface is already small, a three-line `app.txt`
([design-packaging.md](design-packaging.md#the-declaration)). The
difficulty lies elsewhere: there is no program tier at all, what an
app may be given is fixed by the image, and the image builder's path is
hand arithmetic over about twenty concepts.

### What other systems do

[research-app-model.md](research-app-model.md) reads thirteen systems
from their published documentation. They fall into three groups
([Comparison](research-app-model.md#comparison)):

| Group | Systems | What erXos takes |
| --- | --- | --- |
| general-purpose | FreeBSD, QNX's default path, Plan 9, OpenBSD | a copied binary runs with its user's rights; `noexec` is a property of a mount; a started program inherits and its starter narrows |
| app platforms | Android, Flatpak, macOS's sandbox, Sculpt | a package with declared needs, nothing held by default, added at run time and never by rebuilding the system |
| fixed images | QNX's security policy, Zephyr, Genode's static init | the board's own composition is decided when the image is built, and only that |

Two cautions come with them. FreeBSD's mount(8) says of `noexec` that
it "was not designed as a security feature" and that scripts on such a
mount still run through their interpreter
([FreeBSD](research-app-model.md#freebsd)); erXos's `noexec` promises
the same and no more. And Genode, the system nearest erXos, makes every
child declare its RAM, and a users-list answer that record cites says
Sculpt has no interface to change it
([Genode and Sculpt OS](research-app-model.md#genode-and-sculpt-os)),
which is the friction this design removes for programs and softens for
apps.

### What the existing design already holds

Five facts of the tree make this design a rearrangement, not new
machinery:

* **A session is the trusted supplier of its programs' code.** A
  session fills a code object with any bytes from any source, and
  nothing below it checks where they came from; the `rx` rule "is no
  check on the session itself"
  ([design-system.md](design-system.md#creating-a-domain), "Code
  objects for a session"). So F6 never stood between a session and
  code; it keeps a native program from starting a file it could write.
* **A program inherits and its starter narrows.** A program gets its
  starter's whole namespace unless the line narrows it
  ([design-files.md](design-files.md#narrowing-for-a-program)), and
  `within` names what one run holds
  ([design-shell.md](design-shell.md#starting-programs)).
* **A program's memory is already shared, not reserved.** A session
  carves a pool for its programs, and each program's budget draws on
  what its siblings do not use
  ([design-system.md](design-system.md#resource-policy), "Budgets").
* **An app's wall is carved when it starts** and destroyed when its
  session retires, from one pool
  ([design-packaging.md](design-packaging.md#an-apps-principal)).
* **CPU time already has the shape memory needs**: the group `users`
  is "the root group's remainder after `system`"
  ([design-system.md](design-system.md#resource-policy), "Grants").

## Requirements

* **AM-R1.** A person who built a program with the SDK copies the file
  to a running machine and runs it, with no package, no declaration and
  no new image.
* **AM-R2.** A program holds what its starter holds or less. Running a
  file confers nothing.
* **AM-R3.** An app is added, updated, enabled, narrowed and given
  memory on a running machine, with no new image, within what the
  board offers.
* **AM-R4.** Nothing below the manifest adds authority: no file of a
  data partition names a service, a grant, a user or a start that the
  boot image and a sealed declaration do not.
* **AM-R5.** The board's own domains keep what the build proved for
  them whatever programs and apps run.
* **AM-R6.** The manifest states no number the build can compute, and
  the machine's memory beyond the board's own is usable without an
  edit.
* **AM-R7.** There is one way to be each kind of thing: one way to run
  a file, one way to be an app.
* **AM-R8.** Every familiar name (`chmod`, `mount -o noexec`, `#!`,
  `escript`, `service`) does what a FreeBSD user expects of it or
  refuses with a clear error.
* **AM-R9.** A person meets about five concepts before a program runs,
  and an app's author about four.

Outside this design: adding or changing people's accounts on a running
machine, which stays the manifest's and the login design's; prompts
that ask a person to approve a grant; fetching packages by name; a
policy per signer; drivers and system services as packages; and a
grant handed to a running app for one boot, for which
`erx_domain:grant/4` exists
([design-system.md](design-system.md#granting-a-running-domain)) and
no consumer does.

## Overview

| | A program | An app | The board |
| --- | --- | --- | --- |
| is | a file with an execute bit | a package, `/apps/NAME.app` | the manifest in the boot image |
| written by | anyone with the SDK | the app's author | a system integrator |
| what they write | nothing | `app.txt`, or nothing for one program | `config/manifest/BOARD.txt` |
| added by | a copy | a copy into `/apps` | a new image |
| runs as | you, in your session | a user of its own, named for the app, in a session of its own | the system's domains |
| holds | what its starter holds, or less | the services its declaration names, within the board's offer, less what the machine denies | the manifest's rows |
| memory | inside its session's | a slice of its own | fixed by the build |
| lives | until it exits or its session ends | as its start row says | for the boot |
| narrowed by | `within`; a `noexec` mount | a word left out of `needs`; `NAME_deny` | the manifest check |
| a new image | never | only to raise what the board offers | always |

### The concepts each person meets

**Someone who uses or administers a machine: five.**

| Concept | What they know about it |
| --- | --- |
| a file | a program is a file with an execute bit; an app is a file in `/apps` |
| a mount | where a tree appears, and whether it writes and whether it runs; `mount` shows `ro` and `noexec` |
| a user | a program runs as you, with your rights; an app runs as a user of its own |
| a service | `service NAME enable`, `start`, `stop`, `status`; `/etc/start.conf` |
| memory | each session and each app has an amount; a start that does not fit is refused with `no memory` |

`within` is a command for narrowing one run, learned when it is wanted.

**Someone who writes an app: four.**

| Concept | What they know about it |
| --- | --- |
| the SDK | `erx-cc`, and the public functions |
| a package | `erx-app pack`, one file |
| the declaration | `needs`, the board's words for services (`display`, `net`, `data`); `memory` |
| a service | how the app starts, its start flags, its output in the log |

**A system integrator: about ten.** Domain, device, service, grant (a
facet row), user (a principal and its session template), CPU share,
limits record, the offer to apps, signer, start row. Lanes,
connections, outer budgets, mints, exports, quantities, the sums and
release scripts are the build's and the system domain's, and no
manifest names them.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **AM1.** Configuration only narrows: an app's session holds a service only if the board offers it, the app's declaration names it and the machine's settings do not deny it | the session's plan is `offered` intersected with `needs`, less `deny`; the declaration's grammar names services and one amount of memory; a start row's settings name services only in `deny` | a settings field that names a service to add; a plan that takes the union; a declaration field that carries a parameter | the plan's property test over generated offers, needs and denials; seeded: a plan that ignores `deny`, and a judgement that reads a `NAME_needs` line |
| **AM2.** A program starts a file only through an entry of its own table that allows execution, and only if the file's mode has an execute bit | an entry's rights never exceed its grant's, bit by bit, and a grant allows execution only where its manifest row is marked; the handler's image check reads the entry the path resolved through and the file's mode before a code object is made or found, for a spawn, an `exec` and a code `map` alike | a resolution that keeps the rights a mount asked; a code object handed over without the check; a cache hit that skips it | a file run from a home, from `/tmp` and from a `noexec` bind of a home; a file without an execute bit; seeded: a check that ignores the entry, one that ignores the mode, and a lowering that takes either side's bit |
| **AM3.** A tree is writable and executable at once only where the manifest marks a user's home so, and never for an app | the manifest check admits `exec` on a row that is `ro`, or on the `home` row the build derives for a session template whose `home` field says `exec`; every row of the app template is derived, and of those only `packages` and `system`, both `ro`, are marked | a source row with `rw` and `exec`; an `exec` mark on the app template's `data` row | the manifest check's seeded rows; a QEMU test that a native app's program cannot start a file it wrote to `/data` |
| **AM4.** No file of a data partition adds a service, a grant, a user, a start row or, in a release build, a signer | the start table holds a row only for a manifest row or an admitted package (AP3 of [design-apps.md](design-apps.md#invariants)); settings have no adding field (AM1); a package's needs are sealed under a key the boot image trusts | a local line that adds a row; a signer read from the data partition in a release build | the merge's host test of unknown rows and fields; the signer tests of [design-packaging.md](design-packaging.md#invariants) |
| **AM5.** The board's own domains keep their memory whatever runs for users | the root budget has two children that are walls: the system's, at the sum the build proves, and `users`, the remainder; every session, app and command domain is carved from `users` | a slice carved from the root; a `users` budget that borrows | a QEMU test that fills `users` and finds every configured domain's budget as the build planned it; seeded: a carve from the root budget |
| **AM6.** Every app is a package, and an image's package and an installed one give the same session | one admission and one session plan (PK10 of [design-packaging.md](design-packaging.md#invariants)); the manifest's `app` row adds to the offer for a named package of the image and creates no session template | a session template whose release is an app's own; a second starter of app sessions | a build check that no release script is named for an app; the session plan's host test over one header admitted both ways |

## A program is a file

### What runs, and as what

A path that names a file starts it as a program of the session, a
sub-space whose handler holds its table
([design-programs.md](design-programs.md#starting-a-program)). Two
kinds of file start:

* **an executable**, static and position-independent, as the SDK's
  link line makes it and `erx_elf_plan` accepts it
  ([design-programs.md](design-programs.md#what-a-program-can-start));
* **a script**, whose first line names its interpreter
  ([Scripts](#scripts)).

The program holds its starter's namespace, descriptors, directory,
environment and network, as a UNIX process does, and it ends with its
session (P9 of [design-programs.md](design-programs.md#invariants)).
It is charged to its session's memory and runs in its session's CPU
share. It has no identity of its own: the inspector shows it as a
process of the session, under the session's user.

### Where execution is allowed

Running a file is reading it into a sealed copy
([design-programs.md](design-programs.md#file-objects)), and no file
server can tell a read for code from any other read. So execution is
not a right a server enforces. It is a fact of the namespace entry the
path resolved through, which the session's handler checks, and an
entry's rights are two independent facts:

```erlang
-type rights() :: #{write := boolean(),   % false: the grant refuses every
                                          % writing operation (F5)
                    exec := boolean()}.   % false: no handler takes code
                                          % through this entry
```

An entry's rights never exceed those of the grant beneath it, each bit
on its own, and a mount, a bind or `within` only lowers them
(`erx_path:lesser/2` is the two bits' conjunction). A files facet row
carries `rights`, `ro` or `rw`, and `exec`, `no` or `yes`; a row that
states no `exec` is `no`, so a tree is `noexec` until the manifest
marks it. What each tree of a session is:

| Tree | Writes | Runs | Why |
| --- | --- | --- | --- |
| the release, and `/bin` | no | yes | the image's own programs |
| `/app`, an app's package | no | yes | checked block by block against a sealed header |
| a user's home, `/root` or `/home/NAME` | yes | where the session template says `home exec` | the place a person copies a program to; both development manifests say it |
| `/tmp` | yes | no | a session's own RAM, an eighth of its memory; nothing is kept there |
| `/media/...`, removable volumes | as the row says | no | a volume from outside the machine |
| an app's `/data` | yes | no | an app's programs run only its package's code (AM3) |
| `/data`, the whole volume in a development build | yes | no | the same files run through the home's entry |
| `/apps`, the package files | yes | no | a package is installed, not run from there |
| `/proc`, `/svc`, `/dev`, `/etc` | as each is | no | state and control, not programs |

`mount` shows each entry's options as FreeBSD's does, `ro` and
`noexec` among them. `mount -o noexec SOURCE DIR` places a tree
without execution and `-o ro`, which `-r` abbreviates, without writing
([design-shell.md](design-shell.md#interfaces)); a mount that asks for
execution beneath an entry that lacks it is refused with `eacces`.

### The execute bit

A file runs only if its mode has an execute bit, any of the three,
since grants and not owners decide access. `chmod +x` sets it and
`chmod -x` clears it, through the `setattr` a server already takes; a
server that records no mode reports no execute bit. `access` and
`faccessat` answer `X_OK` from the entry and the mode together, so
`test -x` predicts what a start does.

The read and write bits are recorded and shown and gate nothing: what
a session reads and writes is what its grants reach
([design-files.md](design-files.md#alternatives-considered), "One
machine-wide tree with permission bits"). `chown` fails with `EPERM`
unless it changes nothing, and no file is set-user-id, since a program
never holds more than its starter.

### Scripts

A file that begins with `#!` names an interpreter. The handler's
resolve step reads the line, bounded by `interp_line_max`, as a path
and at most one argument, and starts the interpreter with that
argument, the script's path and the caller's arguments. The
interpreter is resolved through the caller's table as any path is, and
must itself be a command of `/bin` or an executable, not a script: one
line is followed, and a second answers `ENOEXEC`. The script needs the
same entry and execute bit as an executable does. As on FreeBSD, an
interpreter given a file as an argument (`rc file`) reads it as data
whatever the mount says.

* `#!/bin/rc` runs an rc script.
* `#!/bin/escript` runs an Erlang script: `escript` is an Erlang
  command that runs OTP's `escript` on the file, its `main/1` taking
  the arguments and its exit status the one stock `escript` gives. It always
  runs in a command domain
  ([design-programs.md](design-programs.md#what-a-program-can-start),
  "An Erlang command"), holding the caller's table and no more, so a
  script's modules never load into the session's own runtime, where
  the shell and the terminal relay run. An emulator flag on a `%%!`
  line that a running command domain cannot apply is refused by name.

The line's reader is a parser of untrusted input, with a fuzz target.
The bound and the grammar follow FreeBSD's `execve`; no FreeBSD source
was read for this document, so both are pinned from
`sys/kern/imgact_shell.c` when the reader is written.

### Narrowing

`within PATH... -- COMMAND` starts the command holding only the named
paths, read-only, and nothing else
([design-shell.md](design-shell.md#starting-programs)). An entry it
makes keeps the execute fact of the entry it narrows, and `-f` names a
right beyond files:

| Right | What it allows |
| --- | --- |
| `inspect`, `signal` | as [design-programs.md](design-programs.md#facets) states |
| `net` | `socket`: the handler refuses it with `EACCES` for a program without the right |

A program started without `within` holds its starter's network as it
holds its starter's files; `within` hands over only what it names, so
`within /tmp -- ./hello` has no network and `within -f net /tmp --
./hello` has. `-m BYTES` gives the program's budget that cap, in place
of its session's whole pool. On Fiasco a program's budget is a record
that nothing enforces (FD25 of
[design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel)),
so `-m` is refused there as unsupported and never accepted and
ignored.

### What a program cannot do

* **Outlive its session.** A space never outlives its parent, so there
  is no `daemon`. What should run with nobody logged in is an app:
  `erx-app pack hello`, then `service hello enable`.
* **Hold more than its starter.** There is no set-user-id and no way to
  ask for a service.
* **Use more memory than its session has.** [Memory](#memory) says how
  much that is.

## An app is a package

An **app** is code that runs for no person, in a session of its own
and as a user of its own. A service is an app without a window; the
word is the command's.

### One way to be an app

Every app is a package
([design-packaging.md](design-packaging.md#the-package)), whoever made
it and however it arrived:

| Whose | How it arrives | What authenticates it |
| --- | --- | --- |
| a developer's own program | `erx-app pack FILE`, then a copy into `/apps` | a signer key the machine trusts |
| a third party's app | `erx-app pack DIR`, then a copy into `/apps` | the same |
| an image builder's addition | `tools/erx pack --app` | its header's hash in the image's manifest |
| the board's own apps, such as `ntpd` and `bleuart` | an `app` row of the manifest, packed from the tree by the build | the same |

`erx-app pack FILE`, given one executable or script, writes the
declaration itself: the file's name as the app's, the file as its
`program`, no `needs`, the default memory. So the step from a program
to a service is one command, and a declaration is written only when
the app needs something:

```text
app hello
  needs net data
  program "bin/hello"
```

`tools/erx app run`, which builds and boots a development image with
the app under QEMU
([design-packaging.md](design-packaging.md#adding-an-app-to-an-image)),
takes one file as it takes a directory.

No app is rows of the manifest. A board's own app is a package the
build adds to the image, and the manifest's part is one `app` row
([The board is the manifest](#the-board-is-the-manifest)).

### What an app holds

```text
held = (the board's offer) intersected with (the declaration's needs), less (the machine's deny)
```

with its own package, read-only and executable, which every app holds.

* **The offer** is the `apps` row's `services`, for every app, and for
  a named package of the image what its `app` row adds. A development
  manifest offers every service an app can safely hold.
* **The needs** are the declaration's, sealed in the package's header.
  To give an app more, its author adds a word to `needs` and packs
  again; copying the package over the installed one updates it.
* **The deny** is the machine's own, below.

By default an app holds nothing but its package: no network, no
display, no directory, 64 MiB, its output in the log. Its writable
directory, when it needs `data`, is its own and is `noexec`.

### The machine's settings

`/etc/start.conf` holds this machine's settings of the rows the
manifest and the admitted packages declare
([design-apps.md](design-apps.md#the-start-table)). A row has seven
fields; the last two are this design's:

| Field | Meaning | Default |
| --- | --- | --- |
| `enable`, `display`, `restarts`, `restart_period_s`, `flags` | as [design-apps.md](design-apps.md#the-start-table) states | |
| `deny` | services of the app's needs that this machine withholds | none |
| `memory` | the bytes of the app's slice, at least `app_memory_min` | the declaration's |

```text
hello_enable="YES"
hello_deny="net"
hello_memory="134217728"
```

`service` writes them as it writes `display`
([design-apps.md](design-apps.md#interfaces)). A setting takes effect
at the row's next start, as every setting does, so a running session
keeps the grants and the memory it started with. A `deny` that names a
service the app does not need, a `memory` below the least, and any
field that is not one of the seven are skipped and reported at every
read, as a line for an unknown row is.

`memory` may raise as well as lower. It moves an app's slice inside
the pool all users share ([Memory](#memory)) and reaches nothing the
build proved for the board's own domains; and whoever can rewrite the
file can already keep any app from running, by disabling its row.

### Who may install

Whoever may command the start table may copy into `/apps`
([design-packaging.md](design-packaging.md#the-apps-row)). The package
must be sealed by a key the machine trusts: a `signer` row of the boot
image, or in a development build the development package key of the
host that built the image
([design-packaging.md](design-packaging.md#where-a-package-lies)).
[Open decisions](#open-decisions) asks whether a development build
also trusts keys its medium carries, so that a downloaded image takes
its user's apps.

## The board is the manifest

The manifest describes the machine: its devices and their holders, the
configured domains and their drivers, the services, the people who log
in, and what apps may be offered. A system integrator writes it, the
build proves its properties
([design-system.md](design-system.md#the-manifest)) and it changes
only with a new image.

### The offer to apps

```text
apps
  max 8
  services display net data
app ntpd
  services clock
  enable YES
  flags "pool.ntp.org"
```

* **`apps`** offers `services` to every app and bounds how many apps a
  boot holds. It states no memory.
* **`app NAME`** names a package the board itself ships. The build
  packs it from the tree and adds it to the image, as it packs the
  card's kiosk; the row adds `services`, and GATT services with
  `gatt`, to what that one package may name in `needs`, and gives its
  start row its defaults (`enable`, `published_enable`, `display`,
  `flags`). It applies to the image's package of that name alone,
  which its header's hash authenticates, and the build refuses an
  `app` row with no package. Each service is taken at the defaults its
  ABI file gives, as the `apps` row's are; the row has no field for a
  parameter.

The build counts each package of the image at the needs it declares
and each remaining place of `max` at the whole offer, so a board's own
apps cost what they use and only the free places are counted at the
worst.

### What the build derives

| The manifest does not state | The build derives it from |
| --- | --- |
| `root_memory` | the system's sum and the least size of `users` ([Memory](#memory)) |
| the system principal's `memory` | its domains' walls |
| `max_domains`, `max_connections` and each server's connections | the domains, the templates' quotas, `max`, and each grant's grantee and server |
| the display domain's outer budget | the pixel areas and lanes property 18 sums |
| a facet row's `max_request`, `in_flight`, `reductions`, `period_ns` and `max_heap_size` | its service's `quantity` lines, unless the row states another |
| a session template's argument line | the template's recipe, as the app template's is derived |
| a principal, a session template, facet rows, a `start` row and a release script for each app of the board | one `app` row and the package's declaration |

A manifest that states a value the build derives is refused, so no
number is written by hand and then checked for agreement. The limits
record's field that names a CPU share is `share`, since `grant` also
names a facet's grant.

## Memory

### Two parts

The root budget has two children, as the root group has `system` and
`users` for CPU time:

* **the system's**, whose size is the sum the build proves for the
  board's own domains, the system domain's baseline and the devices'
  memory;
* **`users`**, the remainder of the machine, sized at boot.

Both are walls. The build derives `root_memory`, the least root budget
the image boots on, as the system's sum and the least `users` may be:
the slices of the image's enabled packages, one login session and one
ended slice not yet retired, or the machine record's `users_min` if
that is more. A machine with less ends at boot with a crash record, as
it does for a `root_memory` it cannot meet
([design-system.md](design-system.md#the-root-task)); a machine with
more gives all of it to `users`.

### Slices

Every domain that runs for a user is a wall carved from `users` when it
starts and destroyed when it retires, which is how an app's wall is
carved and destroyed
([design-packaging.md](design-packaging.md#an-apps-principal)), for
every domain a user starts:

| Domain | Its slice |
| --- | --- |
| an app's session | the declaration's `memory`, 64 MiB when it states none, or the row's `memory` setting |
| a login session | its template's `memory`; or, when the template states `share N` and that is more, one Nth of `users` as sized at boot |
| a command domain | its limits record's `memory` |

A start that `users` cannot hold is refused with `no_memory`, and the
row's reason at `/proc/apps` says so. Nothing is promised to a domain
that is not running, so the apps that are installed and the people who
could log in cost nothing. A person's principal keeps `memory` as a
ceiling the domain service judges each of its starts against; nothing
is reserved for it.

A program has no slice. It lives in its session's pool for programs
and draws on what its siblings do not use
([design-system.md](design-system.md#resource-policy), "Budgets").
`share` is what lets a copied program run on a board with memory to
spare: the development manifests give root's session an eighth of
`users`, 36 MiB at the least.

Three sentences are the whole of what a user knows: the machine's
memory is the system's and everyone else's; each app and each login
takes a fixed amount of everyone else's when it starts; a start that
does not fit is refused.

### On Fiasco

Every budget on Fiasco is a wall (FD25 of
[design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel)),
and this design asks for nothing else: `users` is a wall sized at
boot, and each slice a wall carved at a start. The remainder sizes the
pool's user pages; each domain's kernel memory stays the share its
limits record fixes, so how many domains run at once is still bounded
by the tables the build sums (clause 9 of
[The build's check](design-packaging.md#the-builds-check)). A
program's floor and cap are records there, as they are in
[design-programs.md](design-programs.md#starting-a-program).

### Caps: the alternative that changes a commitment

A budget under `users` could be elastic: a guarantee of what the
domain needs to start and to end, and a cap at its `memory`, so that
apps and sessions share `users` as programs share a session's pool,
and a start is refused only when the pool is full. Authors would then
state a ceiling, not a reservation.

It is not this design. It changes the commitment that a domain's
budgets are walls, so that a domain is admitted or refused at its own
budget alone: under caps a running app can be refused memory because
another took it. And Fiasco has no elastic budget, so on the kernel of
the first release every such budget would be a wall at its cap, which
is this design's behaviour exactly, with a backend difference above
`liberx` and nothing a user can see
([design-packaging.md](design-packaging.md#alternatives-considered),
"An app principal's budget made at boot, elastic under `apps`").
[Open decisions](#open-decisions) records it for the gate that chooses
the kernel.

## What the build proves, and what is judged later

| When | Who | What |
| --- | --- | --- |
| build | the manifest check | every device has one holder; the board's own domains fit the system's sum; `max` apps, each image package at its needs and each free place at the whole offer, fit every table, connection quota and pixel area; the `exec` marks (AM3); the image's packages pass admission; `root_memory` |
| boot | the root task | the root budget is at least `root_memory`; `users` is the remainder |
| install | the package process | the file check, the signature, admission: needs within the offer, GATT services apart, a free place of `max` |
| start | the start service and the kernel | the row's settings, judged; the slice carved from `users` or refused; the display free |
| run | the handler | the entry and the execute bit of every file started; the rights `within` left |

Nothing of authority moves from the build to a later step. What moves
is arithmetic: the size of `users` from the manifest's text to the
boot, and an app's memory from an edit of the image to a setting.

## What a tampered data partition can do

The data partition and the storage domain are not trusted
([design-apps.md](design-apps.md#security)). With every file of the
partition rewritten:

| It can | It cannot |
| --- | --- |
| withhold a package, or put back an older one of the same signer ([design-packaging.md](design-packaging.md#where-a-package-lies)) | change a byte of a package that a session reads |
| enable or disable declared rows, move a display among rows that may draw on it, change start flags | start a user that no manifest row or admitted package declares |
| deny an app a service it needs | give an app a service its declaration does not name, or one the board does not offer |
| set an app's `memory`, so that it or another app is refused its start | take memory from the board's own domains, or from a running domain |
| read or destroy every user's files | make a file run in an app's session, whose writable trees are `noexec` |
| on a board whose manifest marks homes `exec`: replace a program in a home, which then runs with a person's rights when that person runs it | start anything without a person or a declared row; add a signer in a release build |

The last row on the left is the price of copy and run, and it is the
one FreeBSD and QNX pay: a machine that runs files from a disk trusts
the disk. It is the manifest's choice, one field per session template,
and a board whose templates do not say `home exec` keeps the property
that every byte a program runs came from the image or a sealed
package.

## Concurrency and failure

* **A file that changes while it starts.** The code object is a sealed
  copy keyed by the file's version, so a program runs the bytes that
  were read, and a file that keeps changing during the read answers
  `ETXTBSY` ([design-programs.md](design-programs.md#file-objects)).
  Clearing the execute bit, or remounting `noexec`, stops the next
  start and not a running program.
* **A setting changed while its app runs** takes effect at the row's
  next start. The start service reads the file at boot and at each
  row's own command, as it does for every field.
* **`users` full.** A start is refused with `no_memory` and counted
  against the row's intensity, and nothing that runs is touched: no
  slice is shrunk for another, and nothing is killed.
* **A script's interpreter that is missing or is itself a script**
  refuses the start before anything is reserved.

## Refusals

| What was tried | Answer |
| --- | --- |
| a file through a `noexec` entry, or without an execute bit | `EACCES`, the shell's `permission denied` |
| a file that is neither an executable `erx_elf_plan` accepts nor a script | `ENOEXEC` |
| a `#!` line past `interp_line_max`, or an interpreter that is a script | `ENOEXEC` |
| a `#!` interpreter that names nothing | `ENOENT` |
| a mount asking for execution beneath an entry without it | `eacces`, before the table changes |
| `socket` in a program narrowed without `-f net` | `EACCES` |
| `within -m` on Fiasco | refused as unsupported |
| a package whose needs pass the offer, or whose signer is not trusted | the copy's close fails with admission's or the file check's reason ([design-packaging.md](design-packaging.md#admission)) |
| a `deny` of a service the app does not need, a `memory` below the least, an unknown field | the line is skipped and reported |
| a start that `users` cannot hold | `no_memory`, shown at `/proc/apps` |
| a manifest that states a derived value, an `app` row without its package, `rw` with `exec` outside a marked home | the build refuses the image, naming the row |

## Security

**What is trusted.** The boot image, with its manifest and the signer
keys it carries; the system domain; and, on a board whose manifest
marks homes `exec`, the storage domain for the programs people run
from their homes.

**What is not.** A program, which holds what its starter gave it; an
app's code, which holds its plan's grants; the data partition and
every setting on it.

* **Running a file confers nothing.** A program holds at most its
  starter's table, there is no set-user-id, and no file's code is
  given a service. What a person risks by running a file is what they
  hold, as on UNIX, and `within` is how they risk less.
* **What the old rule kept, and what remains.** With no writable tree
  executable, a native program that an attacker steered could not turn
  bytes it wrote into running code. That still holds wherever no
  writable entry runs: in every app, in every narrowed program whose
  table lacks the right to start commands, and on every board whose
  templates do not mark homes. In a person's session on a board that
  does, such a program can write a file and start it. It gains no
  authority by that, and no mapping is ever writable and executable in
  either case.
* **An Erlang app's code was never only its package's.** A session's
  own Erlang code may load modules and fill code objects from any
  bytes ([design-system.md](design-system.md#creating-a-domain), "Code
  objects for a session"). AM3 speaks of an app's native programs,
  which hold no such facet.
* **A script runs in a domain of its own**, so user Erlang code cannot
  reach the session's shell, relay or handlers except as any command
  does.
* **Text.** This design adds no sink that shows text: an app's name, a
  setting and a refusal's reason reach the log and `/proc` through the
  escaping those sinks already have.

## Verification and testing

Each passing case is paired with a seeded fault that proves the code
under test ran.

| Passing case | Seeded fault it catches |
| --- | --- |
| a static position-independent program built with the exported SDK, copied into root's home with mode 0755, runs under QEMU and prints | an image check that ignores the entry's `exec`, which the `/tmp` case catches |
| the same file with mode 0644 fails with `EACCES`, and `test -x` says so | a check that ignores the mode; an `X_OK` answered from the entry alone |
| a file in `/tmp`, in an app's `/data` and under `mount -o noexec` of a home fails with `EACCES` | a bind that keeps `exec` when `noexec` was asked; a lowering that takes either side's bit |
| a mount that asks for execution beneath a `noexec` grant is refused and leaves the table as it was | an entry whose rights come from its options alone |
| the manifest check refuses a source row with `rw` and `exec`, and `exec` on a row of the app template | each as a seeded row |
| `#!/bin/rc` and `#!/bin/escript` scripts run by path with their arguments; a script naming a script fails with `ENOEXEC`; the line reader's fuzz target | a reader without its bound; a resolve that follows a second line |
| an `escript` run leaves the session's loaded modules as they were | an `escript` run in the session's domain |
| `within /tmp -- prog` cannot open a socket and `within -f net /tmp -- prog` can | a handler that serves `socket` without the right |
| the session plan's property: for generated offers, needs and denials, the plan is the intersection less the denial | a plan that ignores `deny`; a judgement that grants what `deny` names |
| `NAME_memory` above the declaration starts the app at that size, and one above the pool refuses it with `no_memory` while every configured domain's budget stays as planned | a slice carved from the root budget |
| `erx-app pack hello` gives a package whose session holds its package and nothing else | a synthesized declaration that names every offered service |
| each shipped manifest boots at exactly its derived `root_memory`, with every configured domain and enabled package started (property 12's planner) | a derivation that leaves out the outer budgets, on which the planner fails |
| a machine with more memory than `root_memory` shows `users` as the remainder and starts two apps the least machine could not hold | a pool sized from `root_memory` on every machine |
| `ntpd` as a package of the image holds the grants its manifest rows gave it, compared plan against plan, and the time suite passes | an `app` row whose `services` the plan ignores |
| `within -m` on Fiasco reports unsupported | a backend that accepts the cap and enforces nothing |

## Compatibility and migration

Nothing is converted. A manifest in the old form is refused by the
build, and an installation re-creates what an earlier build wrote.

### Sections of other designs that change

| Document and section | What it says under this design |
| --- | --- |
| [design-files.md](design-files.md#invariants), F6 | replaced by AM2 and AM3: a program starts a file only through an entry that allows execution, and a tree writes and runs only as a marked home |
| [design-files.md](design-files.md#namespaces), `rights()` | two bits, `write` and `exec`; `rx` is gone |
| [design-files.md](design-files.md#building-binding-and-mounting), "Rights beneath an entry" and the EROFS mount | lowering is bit by bit, so `rw` and `rx` no longer meet at `ro`; an image mounts with `exec` only through a grant marked `exec` |
| `abi/services/files.txt` | `files_rights` is `ro` and `rw`; a second parameter `exec` |
| [design-programs.md](design-programs.md#invariants), P10 | a program's image is never writable; it starts a file it wrote only through an entry that both writes and runs |
| [design-programs.md](design-programs.md#starting-a-program), step 4, and [What a program can start](design-programs.md#what-a-program-can-start) | the image check is the entry's `exec` and the file's mode; a script is a fifth image; `ENOEXEC` |
| [design-programs.md](design-programs.md#facets) | `net` is a right beyond files |
| [design-programs.md](design-programs.md#the-posix-lite-personality), "Users and files" | `chmod`'s execute bit gates a start; `X_OK` reads both |
| [design-shell.md](design-shell.md#commands) | a `#!` line is interpreted; `escript` |
| [design-shell.md](design-shell.md#starting-programs) and [Interfaces](design-shell.md#interfaces) | `within -f net`, `within -m`; `mount -o` |
| [design-system.md](design-system.md#the-manifest), property 4 and the machine record | the sums are derived; `users_min`; the `app` row; the `home` field; `share` |
| [design-system.md](design-system.md#resource-policy), "Budgets" | the system's sum and `users`; every user's domain carved at its start |
| [design-system.md](design-system.md#creating-a-domain), "Code objects for a session" | the `rx` rule's sentence becomes AM2's |
| [design-domains.md](design-domains.md#principals-sessions-and-quotas) | a person's `memory` is a ceiling, not a reservation |
| [design-apps.md](design-apps.md#an-app) and its opening | an app is a package; the three kinds of manifest rows are deleted |
| [design-apps.md](design-apps.md#the-start-table), AP1 and [Security](design-apps.md#security) | seven fields; a row also carries `deny` and `memory`, which add nothing the manifest check proved |
| [design-packaging.md](design-packaging.md#the-apps-row) and [The build's check](design-packaging.md#the-builds-check) | no `memory`; the derived `packages` and `system` rows are `ro` with `exec`; clause 2 counts image packages at their needs; clauses 4 and 5 read `users` |
| [design-packaging.md](design-packaging.md#an-apps-principal) | the wall is carved from `users` |
| [design-packaging.md](design-packaging.md#the-sdk) and [Building and packing](design-packaging.md#building-and-packing) | `erx-cc`; `erx-app pack FILE`; `tools/erx app run` |
| [design-packaging.md](design-packaging.md#alternatives-considered) and decisions 2, 11 and 14 | the rows on elastic budgets, per-app rows and per-app parameters are restated against this document |
| design-time.md and design-bluetooth.md, where `ntpd` and `bleuart` are configured | each is a package of the image with an `app` row |
| [design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel), FD8 and FD25 | FD8 cites AM2 in F6's place; FD25's app sentence names `users` |
| [design.md](design.md#invariants) and [Decisions](design.md#decisions) | the row "No grant writes and runs a file together", the decision "A program starts what its `/bin` lists", the decision "An app is a principal with a session template" and the format row of `/etc/start.conf` |
| the book, chapters 13, 14, 20 and 23, and the guide | follow each design edit in its own commit; the guide gains "Run your own program" and "Write an app" |

Deleted outright: the `rx` value and the rule that `rw` and `rx` meet
at `ro`; the principal, session, facet and `start` rows, the release
script and the argument and environment strings of `ntpd` and
`bleuart`; `root_memory`, the system principal's `memory`,
`max_domains`, `max_connections`, the display's outer budget and the
`apps` row's `memory` as written values, with the comment blocks that
reckon them; facet quantity lines that repeat their service's.

### The working agreement's list

`CLAUDE.md` states two of these rules in its "by construction" list.
The wording that matches this design:

* in place of "no file grant carries write and execute together, so a
  program never runs what it could rewrite": **a program runs only a
  sealed copy of a file whose execute bit is set, taken through a
  namespace entry that allows execution; a files grant allows it only
  where the manifest marks it, and writes and runs together only as a
  user's home the manifest marks so, never for an app, so a native
  app's programs run only its package's code;**
* a new entry: **configuration only narrows: an app holds what its
  sealed declaration names within what the board's manifest offers,
  and no record on a data partition names a service, a grant, a user
  or a start, so tampered storage gives an app at most what its
  declaration asked for;**
* the budgets entry stands as written. `users` and every slice are
  walls.

Its list of parsers with fuzz targets gains the interpreter line of a
script. Unchanged: no mapping is writable and executable; the right to
make code follows from the image; a path never reaches a server the
domain does not hold; a space never outlives its parent; only
`erx_exec` copies code into a program and only the loader maps it.

### Order of work

Each step is one change with its tests, small enough for one review.
Installing at run time comes first: without it every change to an app
is a new image.

1. **Installing at run time**, as
   [design-packaging.md](design-packaging.md#installing-updating-and-removing)
   states it and [plan.md](plan.md#track-a-apps) splits it. This
   document changes nothing in it.
2. **Execution, in the designs.** The rows above for design-files.md,
   design-programs.md's P10, step 4 and "Users and files",
   design-system.md's code objects, design.md and `files.txt`'s
   comment, with book chapters 13 and 14.
3. **Execution, in the code.** The rights type and its lowering, the
   `exec` parameter and the manifest check's rule, the `home` field,
   the handler's check, `X_OK`, `mount -o`, with AM2's and AM3's tests
   and seeds.
4. **Scripts.** `#!` in the handler's resolve step with its fuzz
   target, `escript`, and the edits of design-shell.md and
   design-programs.md.
5. **The SDK's short path.** `erx-cc`, `erx-app pack FILE`,
   `tools/erx app run`, and the guide's two pages.
6. **Settings.** `deny` and `memory` in `abi/manifest.txt`, the
   reader and the judgement, the session plan, and the edits of
   design-apps.md and design-packaging.md.
7. **Derived sums, with no change of behaviour.** The build computes
   what the manifests state and the stated values are deleted; facet
   quantities default. Whether a source row may already omit its
   quantities is checked first.
8. **The board's apps as packages.** The `app` row; `ntpd`, then
   `bleuart` in a change of its own; their rows and release scripts
   deleted. It stops and reports if either needs a parameter no ABI
   default gives.
9. **The `users` pool.** The two parts at boot, slices for every
   user's domain, `share`, `users_min`, and the edits of
   design-system.md and design-packaging.md. Planned against property
   12's planner before any code.
10. **`within -f net` and `-m`**, with the program's sockets.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| **Keep F6 and package every program** | A program takes nothing of its own, so a package for it declares nothing, and F6 never stood between a session and code. It costs the tier every other general-purpose system has |
| **Three independent bits on every grant, enforced by servers** | A server cannot tell a read for code from another read, so `exec` enforced there would be a promise no server keeps. Two bits, with `exec` checked where code is made, is what the mechanism can honour |
| **Every tree executable unless mounted `noexec`**, FreeBSD's default | Authority is an allow-list: a tree nobody marked would run files. Marking homes gives the same first experience and leaves `/tmp`, media and app data out |
| **Read and write mode bits that gate** | A second authority beside grants, checked by every server ([design-files.md](design-files.md#alternatives-considered)). The execute bit gates only what the handler already checks |
| **A service as a file on the machine**, naming a program, a user and services, as an rc.d script does | It is a record on the data partition that names a user and services: whoever rewrites the partition would start code with a person's rights and nobody present (AP3). The package costs one command on the host and brings its own user, its sealed needs and its integrity |
| **Needs approved by the administrator at install**, in place of the board's offer | The approval would be a record where the storage domain can write it. The offer stays in the image; a development image offers everything safe |
| **A local setting that adds a service** | The same record. `deny` and `memory` are the two settings that cannot add |
| **Manifest rows for each of the board's apps** | A second way to be an app, with its own release script and argument line ([design-packaging.md](design-packaging.md#alternatives-considered), "Rows generated into the manifest for each app"). An `app` row and a package give one |
| **Parameters on an `app` row** | A rule for each parameter in admission and the mint. Defaults serve the apps that exist; the first app they do not serve is the evidence to add them on |
| **A pixel area charged to the app**, so that `max` costs only table places | The display reads the area and pays for it so that a client's end never takes memory the display still maps (D16 of [design-domains.md](design-domains.md#invariants); [design-display.md](design-display.md#the-pixel-area)). Counting image packages at their needs removes most of the cost with no change there |
| **A session resized on request**, growing its pool when a start is refused | Elasticity rebuilt as policy, with a request path and a shrink path of its own. `share` sizes a session once, at its start |
| **`limits` or `ulimit` for a program's memory** | Their limits are of address space and data size; the cap is of a budget. `within` already means "run this within these bounds" |

## Risks and decisions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| a person runs a file a compromised storage domain replaced | low | their session's rights | `home exec` is the manifest's choice; stated in the release's known limits |
| an Erlang script costs a domain for each run | certain | slow, memory-heavy scripts | measured on the watch list ([todo-performance.md](todo-performance.md)); a command domain is kept while its program runs |
| a board's app needs a parameter no default gives, such as a port below 1024 | medium | that app stays out of the model | step 8 stops and reports; parameters on an `app` row are the change it would justify |
| `share` gives one login more than the next can have | medium | a second login refused with `no_memory` | the template's share and its principal's ceiling are the manifest's; the refusal names the pool |
| `users` on the smallest board is tight once the board's apps are packages at the default 64 MiB | medium | an image that does not boot there | the board's apps declare their real memory; the build refuses the image, naming the sum |

Decisions:

1. **Three kinds of thing run**: a program is a file, an app is a
   package, the board is the manifest.
2. **Authority only narrows down one chain**, and each person writes
   at one link of it.
3. **Execution is a fact of a namespace entry**, marked in the
   manifest and lowered by a mount, with the file's execute bit; `rx`
   is gone.
4. **A tree writes and runs only as a user's home the manifest marks**,
   never for an app.
5. **Every app is a package**; a board's own app is an `app` row.
6. **Settings take away, and size memory inside `users`**; they add
   nothing.
7. **Memory has two parts**, the system's and `users`, both walls;
   every user's domain is a slice carved at its start.
8. **The manifest states no derived number.**

### Open decisions

Each has a recommendation.

1. **The wording of the working agreement's list**, as [The working
   agreement's list](#the-working-agreements-list) gives it.
   Recommended: adopt both entries with step 2.
2. **Which trees run files.** Recommended: the table of [Where
   execution is allowed](#where-execution-is-allowed): the image, a
   package and a marked home, with `/tmp` and removable media
   `noexec`. The other choice is FreeBSD's, where `/tmp` runs files:
   one constant, cheap to reverse.
3. **Whether a release manifest marks homes `exec`.** Recommended:
   both development manifests do; a release's manifests are decided
   with that release's security closure, since the mark puts the
   storage domain in the trusted base of every person who runs a file.
4. **Read and write bits.** Recommended: only the execute bit gates. A
   storage service may later refuse a write to a file without a write
   bit, as a server's own refusal; nothing here needs it.
5. **A local `memory` that raises.** Recommended: allowed, bounded by
   `users`, for the reason in [The machine's
   settings](#the-machines-settings).
6. **Walls or caps under `users`.** Recommended: walls, with caps
   decided at the gate that chooses the kernel, since Fiasco cannot
   tell the two apart ([Caps](#caps-the-alternative-that-changes-a-commitment)).
7. **A login session's `share`.** Recommended: an eighth of `users`
   for root's session in the development manifests. Stating bytes
   alone is the other choice, and leaves a larger board's memory
   unused by programs.
8. **The network as a right of `within`.** Recommended: `net`,
   inherited without `within` and dropped by it unless named.
9. **Package keys on a development medium.** A downloaded development
   image trusts no key its user holds, so it takes none of their apps
   without a rebuild. Recommended: a development build also trusts the
   keys of a `package_keys` file that whoever prepares the medium
   writes beside root's `authorized_keys`
   ([design-ssh.md](design-ssh.md#login-keys)), with the limitation
   that file already has: in a development build, whoever writes the
   medium decides. A release build trusts the boot image's keys alone.
   Which domain serves that partition at each boot was not read for
   this document and is checked before the change.
10. **A prebuilt SDK.** Recommended: publish one beside each published
    image, from the same commit, so that building a program does not
    need building erXos. It ships once the image license check covers
    the libraries of its `sysroot`.

## References

* [research-app-model.md](research-app-model.md): how thirteen systems
  add, run, restrict and bound programs.
* [design-programs.md](design-programs.md),
  [design-files.md](design-files.md),
  [design-shell.md](design-shell.md),
  [design-apps.md](design-apps.md),
  [design-packaging.md](design-packaging.md),
  [design-system.md](design-system.md),
  [design-domains.md](design-domains.md),
  [design-kernel.md](design-kernel.md#budgets),
  [design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel).
* FreeBSD 15.0 mount(8), rc.subr(8) and rctl(8), and QNX OS 8.0's
  security policy pages, as [research-app-model.md](research-app-model.md#sources)
  records them.
