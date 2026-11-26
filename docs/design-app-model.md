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
* **A setting on the data partition cannot add authority**, because no
  link below the declaration has a field that names a service, a grant
  or a user. A storage domain that rewrites every setting can enable,
  disable and lift a denial, and can offer any package a trusted key
  signed, but gives no app more than its sealed declaration asked for
  within the board's offer.
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
  data partition gives an app a service, a grant or a user that the
  boot image and a sealed declaration do not, and no setting creates
  authority outside that ceiling.
* **AM-R5.** The board's own domains keep what the build proved for
  them whatever programs and apps run, and a person can log in at a
  console line, and root over SSH where the manifest reserves it,
  however much memory the apps have taken.
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
| **AM1.** Configuration only narrows: an app's session holds a service only if the board offers it, the app asks for it and the machine's settings do not deny it | the app's **requested services** are one set, its declaration's `needs` and `ble` when it names `gatt`; the session's plan is that set intersected with the offer, less `deny`; the declaration's grammar names services and one amount of memory; a start row's settings name services only in `deny`; the session's own trees and its `code_objects` facet are not services, and no setting names them | a settings field that names a service to add; a plan that takes the union; a `deny` judged against `needs` alone, so `ble` cannot be denied; a declaration field that carries a parameter | the plan's property test over generated offers, needs, `gatt` and denials; seeded: a plan that ignores `deny`, a denial judged against `needs` alone, and a judgement that reads a `NAME_needs` line |
| **AM2.** A program starts or maps a file as code only through an entry of its own table that allows execution, and only if the file's mode has an execute bit | an entry's rights never exceed its grant's, bit by bit, and a grant allows execution only where its manifest row is marked; the handler's image check reads the entry the path resolved through and the file's mode before a code object is made or found, for a spawn, an `exec` and a code `map` alike | a resolution that keeps the rights a mount asked; a code object handed over without the check; a cache hit that skips it | a file run from a home, from `/tmp` and from a `noexec` bind of a home; a file without an execute bit; seeded: a check that ignores the entry, one that ignores the mode, and a lowering that takes either side's bit |
| **AM3.** A tree is writable and executable at once only where the manifest marks a user's home so, and never for an app | the manifest check admits `exec` on a row that is `ro`, or on the `home` row the build derives for a session template whose `home` field says `exec`; every row of the app template is derived, and of those only `packages` and `system`, both `ro`, are marked | a source row with `rw` and `exec`; an `exec` mark on the app template's `data` row | the manifest check's seeded rows; a QEMU test that a native app's program cannot start or map a file it wrote to `/data` |
| **AM4.** No file of a data partition gives an app a service, a grant or a user beyond its sealed declaration and the board's offer, or, in a release build, adds a signer | the start table holds a row only for a manifest row or an admitted package (AP3 of [design-apps.md](design-apps.md#invariants)); settings have no adding field (AM1); a package's needs are sealed under a key the boot image trusts | a local line that adds a row; a signer read from the data partition in a release build | the merge's host test of unknown rows and fields; the signer tests of [design-packaging.md](design-packaging.md#invariants) |
| **AM5.** The board's own domains keep their memory, and each reserved login its own, whatever runs for users | the root budget has two children that are walls: the system's, at the sum the build proves, and `users`, the remainder; at boot, before any app starts, each reserved login (each console line, and root's SSH login where the manifest reserves it) takes a wall from `users` that it holds for the boot, and its logins are carved inside it; every other session, app and command domain is carved from what remains of `users` | a slice carved from the root; a `users` budget that borrows; a console or SSH login carved from `users` directly | a QEMU test that fills `users` with apps, finds every configured domain's budget as the build planned it, and logs in at the console and as root over SSH; seeded: a carve from the root budget, a console login carved from `users`, and an SSH login carved from `users` |
| **AM6.** Every app is a package, and an image's package and an installed one give the same session | one admission and one session plan (PK10 of [design-packaging.md](design-packaging.md#invariants)); the manifest's `app` row and the facet rows granted to it add to the offer for a named package of the image and create no session template | a session template whose release is an app's own; a second starter of app sessions | a build check that no release script is named for an app; the session plan's host test over one header admitted both ways |
| **AM7.** A script's interpreter runs exactly the bytes the handler read and checked, and never opens the script by path | the handler reads the script once into a sealed data object keyed by its version; an Erlang interpreter is handed the object's bytes in its start frame, and a native one a read-only descriptor of the object, named `/dev/fd/N` on its command line; no path to the script reaches the interpreter as the thing to run | an interpreter handed the script's path; a descriptor opened on the file's server rather than over the sealed object | the `within` and replaced-script cases for `rc` and for `awk`; seeded: an interpreter handed the path |

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
| an app's `/data` | yes | no | an app's programs start and map as code only files of its package and of the image (AM3) |
| `/data`, the whole volume in a development build | yes | no | the same files run through the home's entry |
| `/apps`, the package files | yes | no | a package is installed, not run from there |
| `/proc`, `/svc`, `/dev`, `/etc` | as each is | no | state and control, not programs |

`noexec` means what FreeBSD's means and no more: the handler refuses
to start a file, or to map one as code, through the entry. A file read
as data is not run, so an interpreter given a file as its argument
(`rc file`) reads it whatever the mount says, and a session's own
runtime loads what it chooses
([What `noexec` does not promise](#what-noexec-does-not-promise)).

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
`faccessat` answer `X_OK` for a file from the entry and the mode
together, so `test -x` predicts what a start does, and for a directory
from any entry, as they do now: a directory is searched, not run, so
`/tmp` and every other `noexec` tree stay searchable
([design-programs.md](design-programs.md#the-posix-lite-personality),
"Users and files").

The read and write bits are recorded and shown and gate nothing: what
a session reads and writes is what its grants reach
([design-files.md](design-files.md#alternatives-considered), "One
machine-wide tree with permission bits"). `chown` fails with `EPERM`
unless it changes nothing, and no file is set-user-id, since a program
never holds more than its starter.

### Scripts

A file that begins with `#!` names an interpreter, and the construction
is that **a script is read once, as an executable is, into a sealed
copy, and its interpreter is handed that copy, never a path to open
again**. The handler's resolve step resolves the script through the
caller's table, before any narrowing, checks its entry and execute bit
as it checks an executable's, and reads it whole, at most `script_max`
bytes, into a data object keyed by the file's version
([design-programs.md](design-programs.md#file-objects)), so a file that
changes during the read answers `ETXTBSY`. It parses the first line as
an interpreter path and at most one argument, and starts the
interpreter with that argument, the script, the script's name and the
caller's arguments. How the interpreter is handed the script depends
only on what kind of command the interpreter is:

| Interpreter | It is handed | The script's name it sees |
| --- | --- | --- |
| an Erlang command of `/bin`, such as `rc` or `escript` | the copy's bytes, in its start frame | the script's path (`$0`, `escript:script_name/0`) |
| a native executable, such as toybox's awk, `wak`, or later toybox's `sh` | the copy as a read-only descriptor of the program's table | `/dev/fd/N`, the name of that descriptor |

Two consequences follow with no rule of their own, for both kinds:
`within /root/in -- /root/job` runs `job` although the narrowed
interpreter could not open it, as a narrowed executable runs, and a
script replaced after the read does not change what runs.

The interpreter is resolved through the caller's table, and its entry
and execute bit are checked as for any start. A script on the line
answers `ENOEXEC`, as FreeBSD's image activator refuses a script as the
interpreter of a script. As on FreeBSD, an interpreter given a file as
an argument (`rc file`, `awk -f file`) reads it as data whatever the
mount says.

* `#!/bin/rc` runs an rc script.
* `#!/bin/escript` runs an Erlang script: `escript` is an Erlang
  command that runs OTP's `escript` on the bytes, its `main/1` taking
  the arguments and its exit status the one stock `escript` gives.
* `#!/bin/awk -f` runs an awk program: the handler starts `/bin/awk`
  with the arguments `-f /dev/fd/N` and the caller's, and `wak` reads
  its program from the descriptor.

**A native interpreter's descriptor.** FreeBSD names a script by its
descriptor when an image started from one with `fexecve`: its shell
image activator passes `/dev/fd/N` in place of the path
(`sys/kern/imgact_shell.c`, lines 172-180, FreeBSD 14.3.0). Whether
FreeBSD does the same for a set-user-id script is unverified; erXos has
none. erXos hands every native interpreter its script that way, which
needs two small things that its descriptors do not have yet:

* **A sealed-file descriptor**, one more kind in the closed set of
  [design-programs.md](design-programs.md#descriptors-and-files): the
  script's data object and its length, which the startup message names
  in its `descriptor` union. The handler places it at the lowest number
  above the descriptors the start passes, without `FD_CLOEXEC`. `liberx`
  maps the object read-only and serves `read`, `pread`, `lseek` and
  `fstat`, a regular file of the copy's length with mode 0444, from the
  mapping; `mmap` of it is the file's `data` map; `write` fails with
  `EBADF`, since the descriptor was opened read-only. The object has no
  right to write, it was sealed when the read filled it, and nothing
  else names it, so the descriptor holds exactly the bytes the handler
  checked. It is charged to the interpreter's program as its data
  objects are, and goes with the last descriptor that refers to it. An
  `exec` keeps it and a child inherits it as any descriptor without
  `FD_CLOEXEC`, so an interpreter that starts another, as `env` does,
  passes the script on.
* **`/dev/fd/N`**, a name `liberx` serves for the program's own
  descriptors, as FreeBSD's `fdescfs` does: `open` of `/dev/fd/N` with a
  mode the descriptor allows is `fcntl(N, F_DUPFD, 0)`, the other flags
  ignored, and `stat` reports the descriptor's object, which is all
  fdescfs(5) of FreeBSD 14.3.0 promises without `nodup`. A mode the
  descriptor does not allow fails with `EACCES`, and a number that is
  not open with `ENOENT`; FreeBSD's errors for these cases were not
  read. `liberx` answers the absolute spelling alone, so the name
  reaches no handler and the program needs no grant: whatever is
  mounted at `/dev`, `/dev/fd` stays `liberx`'s, as `/dev/null` stays
  the export's. `/dev/fd` itself is no directory: opening or listing it
  fails with `ENOENT`, and so does a relative path that would reach it
  through `/dev`, a documented difference with a test, since no
  consumer lists descriptors through it.

The descriptor gives the interpreter nothing it did not have: the
bytes are those of a file its starter could read, and a program reaches
its own descriptors with or without the name.

Erlang interpreters run as every Erlang command of a program runs, in a command
domain ([design-programs.md](design-programs.md#what-a-program-can-start),
"An Erlang command"), holding the program's table and no more, so a
script's code never loads into the session's own runtime, where the
shell and the terminal relay run. An emulator flag on a `%%!` line
that a running command domain cannot apply is refused by name. A
command domain counts against its principal's `domains` quota, so in an
app's session, whose principal holds one domain, its session, a script
with an Erlang interpreter, or an Erlang command, started by one of its
programs is refused as a spawn past a quota is, with `EAGAIN`
([design-programs.md](design-programs.md#starting-a-program)). A
native interpreter is a program of the session like any other and
takes no domain, so an app's program may run an awk script. An app's
own program is never a script ([One way to be an app](#one-way-to-be-an-app)).

The line's reader is a parser of untrusted input, with a fuzz target.
Its grammar is FreeBSD's (`sys/kern/imgact_shell.c`, lines 136-168,
FreeBSD 14.3.0): the interpreter's name runs from the first character
after `#!` and any blanks and tabs to the next blank, tab, newline or
NUL; the rest of the line, less leading and trailing blanks and tabs, is
one argument, which the interpreter parses itself; an empty name answers
`ENOEXEC`, a name of `PATH_MAX` bytes or more `ENAMETOOLONG` (`MAXINTERP`
is `PATH_MAX`, `sys/sys/param.h` line 128), and a line that does not end
within `interp_line_max` `ENOEXEC`. `interp_line_max` is one page, as
FreeBSD's `MAXSHELLCMDLEN` is at most one page by the assertion at lines
51-53. FreeBSD's tests for `execve` of scripts are the oracle's cases.
`script_max` is one bound for both kinds of interpreter, within the
start frame that carries the bytes to a command domain.

### Narrowing

`within PATH... -- COMMAND` starts the command holding only the named
paths, read-only, and nothing else
([design-shell.md](design-shell.md#starting-programs)). An entry it
makes keeps the execute fact of the entry it narrows, and `-f` names a
right beyond files:

| Right | What it allows |
| --- | --- |
| `inspect`, `signal` | as [design-programs.md](design-programs.md#facets) states |
| `net` | creating a socket: the handler refuses `socket` with `EACCES` for a program without the right |

A program started without `within` holds its starter's network as it
holds its starter's files; `within` hands over only what it names, so
`within /tmp -- ./hello` cannot open a socket and `within -f net /tmp
-- ./hello` can. `net` is the right to make sockets, as Capsicum's
capability mode on FreeBSD takes away opening and keeps what is open:
a socket the program already holds, inherited as a descriptor or
passed to it with `SCM_RIGHTS`, works on, since a socket belongs to
the session and its programs share it as any open-file description
([design-network-stack.md](design-network-stack.md#the-interface-towards-posix-programs)). Whoever narrows
a run and wants it without the network closes its sockets first, as
on FreeBSD. A command domain that a program without the right starts
gets no network facet, since it holds a facet only for each right the
program holds
([design-programs.md](design-programs.md#what-a-program-can-start),
"An Erlang command"). `-m BYTES` gives the program's budget that cap, in place
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

`erx-app pack FILE`, given one executable, writes the declaration
itself: the file's name as the app's, the file as its `program`, no
`needs`, the default memory. So the step from a native program to a
service is one command, and a declaration is written only when the app
needs something. The packer's check of `program` stays what it is, an
executable `erx_elf_plan` accepts
([design-packaging.md](design-packaging.md#building-and-packing)), and
it refuses a script by name, so an app's program is always an
executable the packer checked: a script whose interpreter is an Erlang
command would need a command domain, which an app's one domain cannot
hold ([Scripts](#scripts)), and an Erlang service is a package of OTP applications that its session runs in its
own runtime, `erx-app pack DIR` with `applications`:

```text
app hello
  needs net data
  program "bin/hello"
```

`tools/erx app run`, which builds and boots a development image with
the app under QEMU
([design-packaging.md](design-packaging.md#adding-an-app-to-an-image)),
takes one executable as it takes a directory.

No app is rows of the manifest. A board's own app is a package the
build adds to the image, and the manifest's part is one `app` row
([The board is the manifest](#the-board-is-the-manifest)).

### What an app holds

```text
held = (the board's offer) intersected with (the app's requested services), less (the machine's deny)
```

with its own package and the image's `system` tree, read-only and
executable, and its `code_objects` facet, which every app's session
holds and which are not services, so no setting names or denies them
([design-packaging.md](design-packaging.md#an-apps-session)).

* **The offer** is the `apps` row's `services`, for every app, and for
  a named package of the image the facet rows its manifest grants that
  package ([The offer to apps](#the-offer-to-apps)). A development
  manifest offers every service an app can safely hold.
* **The requested services** are the declaration's `needs`, sealed in
  the package's header, and `ble` when it names `gatt`, since `gatt` is
  how an app takes `ble`
  ([design-packaging.md](design-packaging.md#the-declaration)). To give
  an app more, its author adds a word to `needs` and packs again;
  copying the package over the installed one updates it.
* **The deny** is the machine's own, below, judged against the
  requested services, so `bleuart_deny="ble"` takes away what `gatt`
  asked for.

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
| `deny` | services of the app's requested services that this machine withholds | none |
| `memory` | the bytes of the app's session's own budget, at least `app_memory_min` | the declaration's |

```text
hello_enable="YES"
hello_deny="net"
hello_memory="134217728"
```

`service` writes them as it writes `display`
([design-apps.md](design-apps.md#interfaces)). A setting takes effect
at the row's next start, as every setting does, so a running session
keeps the grants and the memory it started with. A `deny` that names a
service the app does not request, a `memory` below the least, and any
field that is not one of the seven are skipped and reported at every
read, as a line for an unknown row is.

`memory` may raise as well as lower. The slice `users` is judged at is
the session's whole wall: that own budget and the outer budget the
domain service derives for its connections, never the own budget
alone. A raised slice moves inside the part of `users` that apps and
other logins share ([Memory](#memory)), and reaches nothing the build
proved for the board's own domains and no reserved login's wall; and
whoever can rewrite the file can already keep any app from running, by
disabling its row.

### Who may install

Whoever may command the start table may copy into `/apps`
([design-packaging.md](design-packaging.md#the-apps-row)). The package
must be sealed by a key the machine trusts: a `signer` row of the boot
image, or in a development build the development package key of the
host that built the image
([design-packaging.md](design-packaging.md#where-a-package-lies)).
A development build also trusts the keys of a `package_keys` file its
medium carries, so that a downloaded image takes its user's apps, and
the storage domain that serves them is accepted as a package-signing
authority for that boot (decision 20 of [Decisions](#decisions)).

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
  enable YES
  flags "pool.ntp.org"
facet ntpd_clock
  name "clock"
  grantee @app.ntpd
  service @service.clock
  operations sample
facet ntpd_net
  name "net"
  grantee @app.ntpd
  service @service.net
  operations none
  parameter sockets 2
  parameter buffers 131072
```

* **`apps`** offers `services` to every app, each at the defaults its
  ABI file gives, and bounds how many apps a boot holds. It states no
  memory.
* **`app NAME`** names a package the board itself ships. The build
  packs it from the tree and adds it to the image, as it packs the
  card's kiosk, and the row gives its start row its defaults
  (`enable`, `published_enable`, `display`, `flags`). It applies to
  the image's package of that name alone, which its header's hash
  authenticates, and the build refuses an `app` row with no package.
* **A facet row granted to `@app.NAME`** is the board's offer to that
  one package, written as any facet row is, with its operations and
  parameters, and checked by the rules that already hold every facet
  row: each service's parameter checks and, for `login`, the holder
  table of [design-login.md](design-login.md#who-holds-it), whose
  `bleuart` holder is the image's package `bleuart`. The package takes
  a row only for a service its needs name, as it takes the `apps`
  row's offer, and a row for a service the `apps` row also offers
  replaces that offer for this package. No package installed at run
  time is ever such a grantee, so what an installed app may hold stays
  the `apps` row's defaults.

So the board's own apps keep the exact grants their configuration
needs, `clock.sample` alone, a network bounded to two sockets, a login
grant of `root_line` alone on `tty_line` with one row, and the
integrator writes them in the one form the integrator already writes
for every domain.

The build counts every place of `max` at the whole `apps` offer, and
each facet row granted to a package of the image once more, since only
that package can take it. An image package that storage withholds at
boot leaves a place an installed app may take at the whole offer,
which is what that place was counted at, so no withheld header can
make the tables, connections or pixel areas fall short.

### What the build derives

| The manifest does not state | The build derives it from |
| --- | --- |
| `root_memory` | the system's sum and the least size of `users` ([Memory](#memory)) |
| `max_domains`, `max_connections` and each server's connections | the domains, the templates' quotas, `max`, and each grant's grantee and server |
| the display domain's outer budget | the pixel areas and lanes property 18 sums |
| a facet row's `max_request`, `in_flight`, `reductions`, `period_ns` and `max_heap_size` | its service's `quantity` lines, unless the row states another |
| a session template's argument line | the template's recipe, as the app template's is derived |
| a principal, a session template, a `start` row and a release script for each app of the board | its `app` row, the facet rows granted to it and the package's declaration |

A manifest that states a value the build derives is refused, so no
number is written by hand and then checked for agreement. No principal
states `memory`: a principal is an identity with quotas, and
the memory its domains hold is their slices ([Memory](#memory)).

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
each reserved login's wall, the slices of the image's enabled packages
and one ended slice not yet retired, or the machine record's
`users_min` if that is more. A machine with less ends at boot with a
crash record, as it does for a `root_memory` it cannot meet
([design-system.md](design-system.md#the-root-task)); a machine with
more gives all of it to `users`.

### Slices

Every domain that runs for a user is a wall carved when it starts and
destroyed when it retires, which is how an app's wall is carved and
destroyed ([design-packaging.md](design-packaging.md#an-apps-principal)),
for every domain a user starts. A slice is the domain's whole wall:
its own budget and the outer budget the domain service derives for its
connections.

| Domain | Its slice | Carved from |
| --- | --- | --- |
| an app's session | the declaration's `memory`, 64 MiB when it states none, or the row's `memory` setting | `users` |
| a login session at a console line, or root's first login over SSH where the manifest reserves one | its template's `memory`; or, when the template states `share N` and that is more, one Nth of `users` as sized at boot | its reserved login's wall |
| any other login session | the same | `users` |
| a command domain | its limits record's `memory` | `users` |

**A console line holds its login's wall for the boot.** At boot,
before the start service starts any app, the console takes from
`users` one wall per line it serves (the UART, and the host link's
`console` line where the machine has one), each the size of the
slice its login's template gives, and carves each login's session at
that line inside it. A session at the line that ends retires inside
the line's wall, and the line offers its next login once it has
retired, so the line never needs more than its wall and an app can
never take what the next login at the console needs. So the person
who administers the machine can always log in at its console and stop
an app, however much the apps have taken; what that person's programs
start beyond the session, a command domain, an escript, comes from
`users` as anyone's does.

**Root's SSH login may hold one too.** A board without a screen is
reached over SSH, so the manifest may reserve a wall for root's login
over SSH, by a field of root's session template that `abi/manifest.txt`
names with the `users` pool. It is a reserved login as a console line
is, with the same words and the same mechanism: at boot, before any app
starts, a wall the size of the slice root's template gives is taken
from `users` and held for the boot; root's login over SSH while no
session of root's holds it is carved inside it, and the wall is offered
again once that session has retired. A second concurrent root login
over SSH, and every other user's, comes from `users` as any login's
does. It is the manifest's choice per board: the development manifests
reserve it, and a board with a screen may leave it out. Where the SSH
server runs does not change: in 0.2 it is a configured domain in the
system's part, and before then it runs in root's session
([design-ssh.md](design-ssh.md)); the wall holds root's session, not the
server.

A start that `users` cannot hold is refused with `no_memory`, and the
row's reason at `/proc/apps` says so. Nothing else is promised to a
domain that is not running, so the apps that are installed and the
people who could log in elsewhere cost nothing.

**A principal has no memory of its own.** A principal is an identity
with quotas, and its domains' walls are their slices, carved from
`users` or, for the board's configured domains, part of the system's
sum. What one principal can hold at once is bounded by its `domains`
quota, each a slice of a size its template, its limits records or its
app's row fixes; so a principal has no separate memory ceiling to
judge a start against, and no ceiling to disagree with a `share` that
grows with the machine. What an ended domain keeps until it retires is
bounded by its survivors' `connections` quotas, as
[design-domains.md](design-domains.md#principals-sessions-and-quotas)
and its connection rules state.

A program has no slice. It lives in its session's pool for programs
and draws on what its siblings do not use
([design-system.md](design-system.md#resource-policy), "Budgets").
`share` is what lets a copied program run on a board with memory to
spare: the development manifests give root's session an eighth of
`users`, 36 MiB at the least. It sizes one session; it promises
neither fairness among people nor room for a login anywhere but at a
console line.

Three sentences are the whole of what a user knows: the machine's
memory is the system's and everyone else's; each app and each login
takes a fixed amount of everyone else's when it starts, and the
console always has room for one login per line, as SSH has for root
where the board reserves it; a start that does not fit is refused.

### On Fiasco

Every budget on Fiasco is a wall (FD25 of
[design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel)),
and this design asks for nothing else: `users` is a wall sized at
boot, each reserved login's a wall carved from it at boot, and each
slice a wall carved at a start, from `users` or from its reserved
login's wall, each a
budget record of its parent with `used + carved <= wall`
([design-fiasco.md](design-fiasco.md#budgets-and-groups-as-records)).
More memory does not enlarge Fiasco's fixed kernel-memory shares or
tables, and does not make a program's cap enforceable. The remainder sizes the
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
the row on an app principal's budget elastic under `apps`).
The gate that chooses the kernel decides it (decision 17 of
[Decisions](#decisions)).

## What the build proves, and what is judged later

| When | Who | What |
| --- | --- | --- |
| build | the manifest check | every device has one holder; the board's own domains fit the system's sum; `max` places at the whole `apps` offer, and each facet row granted to an image package once more, fit every table, connection quota and pixel area; every facet row's parameter and holder checks, those granted to an app included; the `exec` marks (AM3); the image's packages pass admission; `root_memory` |
| boot | the root task, the console and root's SSH login | the root budget is at least `root_memory`; `users` is the remainder; each console line's wall, and root's SSH login's where the manifest reserves it, is carved before any app starts |
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
| withhold a package, put back an older one of the same signer ([design-packaging.md](design-packaging.md#where-a-package-lies)), or offer any package a trusted key signed, which admission then registers as an app of its own with its start row | change a byte of a package that a session reads |
| enable or disable declared rows, move a display among rows that may draw on it, change start flags | start a user that no manifest row or admitted package declares |
| deny an app a service it requests, or lift a denial the machine had set | give an app a service its declaration does not request, or one the board does not offer |
| set an app's `memory`, so that it or another app is refused its start | take memory from the board's own domains, from a reserved login's wall, or from a running domain |
| read or destroy every user's files | make an app's program start or map as code a file it wrote, since its writable trees are `noexec` |
| on a board whose manifest marks homes `exec`: replace a program in a home, which then runs with a person's rights when that person runs it | start anything without a person or a declared row; add a signer in a release build |

The last row on the left is the price of copy and run, and it is the
one FreeBSD and QNX pay: a machine that runs files from a disk trusts
the disk. It is the manifest's choice, one field per session template.
A board whose templates do not say `home exec` removes that direct
route: no program then starts a file the storage domain can replace.
It does not make every byte that runs come from the image or a sealed
package, for the reasons the next section gives.

### What `noexec` does not promise

`noexec`, and a home left unmarked, stop the handler from starting or
mapping a file as code through the entry, and no more:

* **Interpreted input is data.** An interpreter reads what it is given
  as data, whatever the tree: `rc /data/job`, an escript that reads a
  file and evaluates it, or a native program that interprets bytes it
  read. So a file on a `noexec` tree still decides what such a program
  does, within what that program holds.
* **A session supplies its own code.** A session fills code objects
  from any bytes and loads Erlang modules from any source
  ([design-system.md](design-system.md#creating-a-domain), "Code
  objects for a session"), an app's session as much as a person's.
  Nothing below the session checks where they came from, and nothing
  above it needs to: what runs holds only the session's grants.

Neither is narrowed here; an interpreter that refused files of a
`noexec` tree would be a rule that every interpreter must remember and
that the next one forgets. What holds whatever runs is the ceiling of
authenticated authority: a session holds its plan's grants, which no
file of the data partition widens (AM1, AM4).

## Concurrency and failure

* **A file that changes while it starts.** The code object is a sealed
  copy keyed by the file's version, so a program runs the bytes that
  were read, and a file that keeps changing during the read answers
  `ETXTBSY` ([design-programs.md](design-programs.md#file-objects)). A
  script is read the same way, and its interpreter runs the bytes the
  handler read, so a script replaced after the read changes nothing
  that runs. Clearing the execute bit, or remounting `noexec`, stops the
  next start and not a running program.
* **A setting changed while its app runs** takes effect at the row's
  next start. The start service reads the file at boot and at each
  row's own command, as it does for every field.
* **`users` full.** A start is refused with `no_memory` and counted
  against the row's intensity, and nothing that runs is touched: no
  slice is shrunk for another, and nothing is killed. A console line's
  login still starts, inside its line's wall, as does root's login over
  SSH where its wall is reserved, and from it `service NAME stop` frees
  what that app held once its session retires.
* **A login at a console line after a logout.** The line offers its
  next login once the ended session has retired inside the line's
  wall, so a login never waits on memory an app holds and never finds
  the wall short. Root's reserved SSH login does the same.
* **An image package withheld at boot or recovery.** Its place of
  `max` is free, and an installed app that takes it is counted at the
  whole offer, as the build counted that place; its facet rows go
  unused until the package returns.
* **A script's interpreter that is missing or itself a script**
  refuses the start before anything is reserved.

## Refusals

| What was tried | Answer |
| --- | --- |
| a file through a `noexec` entry, or without an execute bit | `EACCES`, the shell's `permission denied` |
| a file that is neither an executable `erx_elf_plan` accepts nor a script | `ENOEXEC` |
| a `#!` line with no interpreter name or past `interp_line_max`, a script past `script_max`, or an interpreter that is itself a script | `ENOEXEC` |
| a `#!` interpreter name of `PATH_MAX` bytes or more | `ENAMETOOLONG` |
| a `#!` interpreter that names nothing | `ENOENT` |
| `open` of `/dev/fd/N` with a mode descriptor N does not allow | `EACCES` |
| `open` of `/dev/fd/N` for a number that is not open, or of `/dev/fd` itself | `ENOENT` |
| a script with an Erlang interpreter, or an Erlang command, started by a program of an app's session | `EAGAIN`: the app's principal holds one domain |
| a mount asking for execution beneath an entry without it | `eacces`, before the table changes |
| `socket` in a program narrowed without `-f net` | `EACCES`; a socket it already holds works on |
| `within -m` on Fiasco | refused as unsupported |
| `erx-app pack` of a script | refused by the packer, naming the file: an app is an executable or OTP applications |
| a package whose needs pass the offer, or whose signer is not trusted | the copy's close fails with admission's or the file check's reason ([design-packaging.md](design-packaging.md#admission)) |
| a `deny` of a service the app does not request, a `memory` below the least, an unknown field | the line is skipped and reported |
| a start that `users` cannot hold | `no_memory`, shown at `/proc/apps` |
| a manifest that states a derived value, an `app` row without its package, a facet row granted to an app the image does not hold, `rw` with `exec` outside a marked home | the build refuses the image, naming the row |

## Security

**What is trusted.** The boot image, with its manifest and the signer
keys it carries; the system domain; on a board whose manifest marks
homes `exec`, the storage domain for the programs people run from
their homes; and, in a development build that trusts package keys from
its medium, the storage domain that serves them, for which packages
may run (decision 20 of [Decisions](#decisions)).

**What is not.** A program, which holds what its starter gave it; an
app's code, which holds its plan's grants; the data partition and
every setting on it.

* **Running a file confers nothing.** A program holds at most its
  starter's table, there is no set-user-id, and no file's code is
  given a service. What a person risks by running a file is what they
  hold, as on UNIX, and `within` is how they risk less.
* **What a writable tree without execution keeps.** A native program
  that an attacker steered cannot start or map as code a file it
  wrote, wherever no writable entry runs: in every app, in every
  narrowed program whose table lacks the right to start commands, and
  on every board whose templates do not mark homes. In a person's
  session on a board that does, such a program can write a file and
  start it. It gains no authority by that, and no mapping is ever
  writable and executable in either case.
* **What it does not keep.** Interpreted input and the code a session
  loads itself are outside `noexec`
  ([What `noexec` does not promise](#what-noexec-does-not-promise)).
  The guarantee that holds for them is the ceiling: a session's code,
  whatever its origin, holds the session's plan and nothing more.
* **Settings and packages stay under the ceiling.** A rewritten
  `/etc/start.conf` can enable, disable, set memory and lift a denial;
  a storage domain can offer any package a trusted key signed, which
  admission registers with a principal and a start row of its own.
  Neither gives any app a service its sealed declaration does not
  request or the board does not offer.
* **A script with an Erlang interpreter runs in a domain of its own**,
  so user Erlang code cannot reach the session's shell, relay or
  handlers except as any command does. A native interpreter is a
  program like any other; its descriptor of the script grants nothing
  its starter could not read.
* **The console stays reachable.** Each console line's login, and
  root's over SSH where the manifest reserves it, is carved in a wall
  held from boot, so no app's memory, raised by a setting or not, keeps
  the person who administers the machine from logging in.
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
| a file in `/tmp`, in an app's `/data` and under `mount -o noexec` of a home fails with `EACCES`, and a code `map` of it fails too | a bind that keeps `exec` when `noexec` was asked; a lowering that takes either side's bit; a `map` path that skips the check |
| `test -x /tmp` and `test -x` of a directory in an app's `/data` succeed, `cd` into them works, and `test -x` of a file there fails | an `X_OK` that applies the file rule to a directory |
| a mount that asks for execution beneath a `noexec` grant is refused and leaves the table as it was | an entry whose rights come from its options alone |
| the manifest check refuses a source row with `rw` and `exec`, and `exec` on a row of the app template | each as a seeded row |
| `#!/bin/rc` and `#!/bin/escript` scripts run by path with their arguments; a script naming a script fails with `ENOEXEC`, and a name of `PATH_MAX` bytes with `ENAMETOOLONG`; the line reader's fuzz target, with FreeBSD's cases as its oracle | a reader without its bound; a resolve that follows a second line |
| `within /root/in -- /root/job` runs the script `job`; a script replaced between the handler's read and the interpreter's start runs the bytes that were read | an interpreter handed the path and opening it again, which both cases catch |
| a `#!/bin/awk -f` script runs by path with its arguments, and under `within /root/in --` from a path the narrowed program cannot open; a `write` to the descriptor fails with `EBADF` | the native interpreter handed the script's path instead, which the `within` case catches; a descriptor over a writable object, on which the `write` succeeds |
| a program opens `/dev/fd/0` read-only and reads its standard input through it; `/dev/fd/N` for a closed N and `/dev/fd` itself answer `ENOENT` | an `open` that sends the name to the handler, on which a program without a grant at `/dev` gets `ENOENT` for `/dev/fd/0` |
| a native app's program runs a `#!/bin/awk -f` script of its package | a native interpreter counted as a command domain, on which the start fails with `EAGAIN` |
| an `escript` run leaves the session's loaded modules as they were | an `escript` run in the session's domain |
| a native app's program that starts an `rc` script fails with `EAGAIN`, and `erx-app pack` of a script is refused naming it | a command domain created past the app principal's quota; a packer that accepts a script |
| `within /tmp -- prog` cannot open a socket and `within -f net /tmp -- prog` can; a connected socket handed to a narrowed child without `net` still carries data, and a command domain that child starts holds no network facet | a handler that serves `socket` without the right; a command domain given a network facet its program lacked |
| the session plan's property: for generated offers, needs, `gatt` and denials, the plan is the requested services intersected with the offer, less the denial; an app with `gatt nus` and `NAME_deny="ble"` holds no `ble` grant | a plan that ignores `deny`; a denial judged against `needs` alone; a judgement that grants what `deny` names |
| with `max 2`, one image package that needs no display and `display` offered: storage withholds the image package's header at boot and at recovery, and two installed display apps start with their pixel areas | a count that takes image packages at their needs, on which the second app's pixel area is short |
| `NAME_memory` above the declaration starts the app at that size, judged at its whole wall, and one above the pool refuses it with `no_memory` while every configured domain's budget stays as planned | a slice carved from the root budget; a judgement of the own budget alone |
| apps fill `users`; root logs in at the UART, runs `service NAME stop`, logs out and logs in again, and logs in once more while the ended session is still retiring | a console login carved from `users` directly, on which the first login fails |
| apps fill `users` on a development manifest; root logs in over SSH, logs out and logs in again, and a second concurrent root login over SSH is refused with `no_memory`; on a manifest that reserves no SSH wall the first is refused too | an SSH login carved from `users` directly, on which the first login fails; a reservation made whatever the manifest says, on which the last refusal does not come |
| `erx-app pack hello` gives a package whose session holds its package and nothing else | a synthesized declaration that names every offered service |
| each shipped manifest boots at exactly its derived `root_memory`, with every configured domain, reserved login and enabled package started (property 12's planner) | a derivation that leaves out the outer budgets or the reserved logins, on which the planner fails |
| a machine with more memory than `root_memory`, and one with sixteen times more, show `users` as the remainder, root's session at an eighth of it, and start two apps the least machine could not hold | a pool sized from `root_memory` on every machine; a principal ceiling left in the judgement, on which the larger machine's login is refused |
| `ntpd` and `bleuart` as packages of the image hold the grants their manifest rows gave them, compared plan against plan, `bleuart`'s login row passes the holder table, and the time suite passes | an app's facet row the plan ignores; a `login` row granted to another app, which the holder check refuses |
| a development build with a `package_keys` file of one key admits a package signed by it; a file with a malformed or partial blob trusts no key from it and reports it | a decoder that keeps the blobs before the malformed one |
| `within -m` on Fiasco reports unsupported | a backend that accepts the cap and enforces nothing |

## Compatibility and migration

Nothing is converted. A manifest in the old form is refused by the
build, and an installation re-creates what an earlier build wrote.

### Sections of other designs that change

| Document and section | What it says under this design |
| --- | --- |
| [design-files.md](design-files.md#invariants), F6 | replaced by AM2 and AM3: a program starts a file only through an entry that allows execution, and a tree writes and runs only as a marked home |
| [design-files.md](design-files.md#namespaces), `rights()` | two bits, `write` and `exec`; `rx` is gone |
| [design-files.md](design-files.md#building-binding-and-mounting), "Rights beneath an entry" and the EROFS mount | lowering is bit by bit, each of `write` and `exec` on its own; an image mounts with `exec` only through a grant marked `exec` |
| `abi/services/files.txt` | `files_rights` is `ro` and `rw`; a second parameter `exec` |
| [design-programs.md](design-programs.md#invariants), P10 | a program's image is never writable; it starts a file it wrote only through an entry that both writes and runs |
| [design-programs.md](design-programs.md#starting-a-program), step 4, and [What a program can start](design-programs.md#what-a-program-can-start) | the image check is the entry's `exec` and the file's mode, for a code `map` as for a start; a script is a fifth image, read whole into a sealed data object and handed to an Erlang interpreter as bytes and to a native one as a read-only descriptor named `/dev/fd/N`; `ENOEXEC` and `ENAMETOOLONG` as FreeBSD's activator answers |
| [design-programs.md](design-programs.md#descriptors-and-files) | a sealed-file descriptor, one more kind, which the startup message's `descriptor` union (`abi/protocols/prog.txt`) names; `liberx` serves `open` and `stat` of `/dev/fd/N` as a duplicate of descriptor N |
| [design-programs.md](design-programs.md#facets) | `net` is a right beyond files: creating a socket; held sockets work on |
| [design-programs.md](design-programs.md#the-posix-lite-personality), "Users and files" | `chmod`'s execute bit gates a start; `X_OK` reads the entry and the mode for a file and any entry for a directory |
| [design-shell.md](design-shell.md#commands) | a `#!` line is interpreted; `escript` |
| [design-shell.md](design-shell.md#starting-programs) and [Interfaces](design-shell.md#interfaces) | `within -f net`, `within -m`; `mount -o` |
| [design-system.md](design-system.md#the-manifest), property 4 and the machine record | the sums are derived; `users_min`; the `app` row and facet rows granted to an app; the `home` field; `share` on a session template; no principal states `memory` |
| [design-system.md](design-system.md#resource-policy), "Budgets" | the system's sum and `users`; each reserved login's wall carved at boot; every other user's domain carved at its start |
| [design-system.md](design-system.md#creating-a-domain), "Code objects for a session" | the `rx` rule's sentence becomes AM2's |
| [design-domains.md](design-domains.md#principals-sessions-and-quotas) | a principal has no budget and no memory quota: its domains' walls are their slices, and its `domains` quota bounds what it holds at once |
| [design-apps.md](design-apps.md#an-app) and its opening | an app is a package; the three kinds of manifest rows are deleted |
| [design-apps.md](design-apps.md#the-start-table), AP1 and [Security](design-apps.md#security) | seven fields; a row also carries `deny` and `memory`, which add nothing the manifest check proved |
| [design-packaging.md](design-packaging.md#the-apps-row) and [The build's check](design-packaging.md#the-builds-check) | no `memory`; the derived `packages` and `system` rows are `ro` with `exec`; clause 2 counts every place at the whole offer and each facet row granted to an image package once more; the build check takes facet rows granted to an app of the image; clauses 4 and 5 read `users` |
| [design-packaging.md](design-packaging.md#an-apps-principal) | the wall is carved from `users` |
| [design-packaging.md](design-packaging.md#the-sdk) and [Building and packing](design-packaging.md#building-and-packing) | `erx-cc`; `erx-app pack FILE` for one executable, the packer's `program` check unchanged and a script refused by name; `tools/erx app run` |
| [design-packaging.md](design-packaging.md#alternatives-considered) and decisions 2, 11 and 14 | the rows on elastic budgets, per-app rows and per-app parameters are restated against this document |
| design-time.md and design-bluetooth.md, where `ntpd` and `bleuart` are configured | each is a package of the image with an `app` row and the facet rows granted to it, with the operations and parameters its rows give today |
| [design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel), FD8 and FD25 | FD8 cites AM2 in F6's place; FD25's app sentence names `users` |
| [design.md](design.md#invariants) and [Decisions](design.md#decisions) | the row "No grant writes and runs a file together", the decision "A program starts what its `/bin` lists", the decision "An app is a principal with a session template" and the format row of `/etc/start.conf` |
| [design-login.md](design-login.md#who-holds-it) | the `bleuart` holder is the image's package `bleuart`, a grantee of the kind `app`, held to the same `line`, operations and `logins` |
| [design-live.md](design-live.md#the-console) | each console line holds its login's wall from boot and offers its next login once the ended session has retired |
| [design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium) | in a development build, the same tree serves `package_keys` beside root's keys |
| [design-ssh.md](design-ssh.md) | root's login over SSH is carved in its reserved wall where the manifest reserves one, and from `users` otherwise |
| the book, chapters 13, 14, 20 and 23, and the guide | follow each design edit in its own commit; the guide gains "Run your own program" and "Write an app" |

Deleted outright: the `rx` value and the rule that `rw` and `rx` meet
at `ro`; the principal, session and `start` rows, the release script
and the argument and environment strings of `ntpd` and `bleuart`,
whose facet rows are kept and granted to `@app.NAME`; `root_memory`,
every principal's `memory`, `max_domains`, `max_connections`, the
display's outer budget and the `apps` row's `memory` as written
values, with the comment blocks that reckon them; facet quantity lines
that repeat their service's.

### The working agreement's list

`CLAUDE.md` states two of these rules in its "by construction" list.
The wording that matches this design keeps three things apart: what
the handler refuses to run, the ceiling on authenticated authority, and
memory.

* in place of "no file grant carries write and execute together, so a
  program never runs what it could rewrite": **a program starts or
  maps a file as code only as a sealed copy, read through a namespace
  entry that allows execution and only if the file's execute bit is
  set; a files grant allows execution only where the manifest marks
  it, and writes and runs together only as a user's home the manifest
  marks so, never for an app, so no app's program starts or maps a file
  it could write; what an interpreter reads as data, and the code a
  session loads itself, are outside this rule and held only by the
  session's grants;**
* a new entry: **configuration only narrows: an app holds the services
  it requests in its sealed declaration, within what the board's
  manifest offers it, less what the machine's settings deny; no setting
  on a data partition has a field that names a service, a grant or a
  user, so tampered storage can withhold, enable, disable and choose
  among packages a trusted key signed, but never gives an app more
  than its declaration requests and the board offers;**
* the budgets entry stands as written: `users`, each reserved login's
  wall and every slice are walls.

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
   the handler's check for a start and a code `map`, `X_OK` for files
   and directories, `mount -o`, with AM2's and AM3's tests and seeds.
4. **Scripts.** `#!` in the handler's resolve step, with FreeBSD's
   grammar and its fuzz target, the bytes handed to `rc` and `escript`,
   the sealed-file descriptor and `/dev/fd/N` in `liberx` for `awk`,
   and the edits of design-shell.md and design-programs.md.
5. **The SDK's short path.** `erx-cc`, `erx-app pack FILE` for an
   executable, `tools/erx app run`, and the guide's two pages.
6. **Denials.** `deny` in `abi/manifest.txt`, judged against the
   requested services, the reader and the session plan, and the edits
   of design-apps.md and design-packaging.md.
7. **Derived sums, with no change of behaviour.** The build computes
   what the manifests state and the stated values are deleted; facet
   quantities default. Whether a source row may already omit its
   quantities is checked first.
8. **The board's apps as packages.** The `app` row and facet rows
   granted to `@app.NAME`, with the holder table's edit in
   design-login.md; `ntpd`, then `bleuart` in a change of its own,
   each passing the plan-against-plan test before its rows and release
   script are deleted; clause 2's count at the whole offer.
9. **The `users` pool.** The two parts at boot, the console lines'
   walls, slices for every user's domain, the principal's budget and
   memory quota deleted, `share`, `users_min`, and the edits of
   design-system.md, design-domains.md, design-live.md and
   design-packaging.md. Planned against property 12's planner, at the
   least machine and at a large one, before any code.
10. **Local memory.** The `memory` setting, judged at the whole wall
    inside `users`, which needs step 9.
11. **`within -f net` and `-m`**, with the program's sockets.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| **Keep F6 and package every program** | A program takes nothing of its own, so a package for it declares nothing, and F6 never stood between a session and code. It costs the tier every other general-purpose system has |
| **Three independent bits on every grant, enforced by servers** | A server cannot tell a read for code from another read, so `exec` enforced there would be a promise no server keeps. Two bits, with `exec` checked where code is made, is what the mechanism can honour |
| **Every tree executable unless mounted `noexec`**, FreeBSD's default | Authority is an allow-list: a tree nobody marked would run files. Marking homes gives the same first experience and leaves `/tmp`, media and app data out |
| **Interpreters that refuse files of a `noexec` tree**, so that `noexec` covers interpreted input | A rule every interpreter must remember, and the next one forgets; and it would still not cover a session's own code. `noexec` promises what the handler checks, and the ceiling covers the rest |
| **Read and write mode bits that gate** | A second authority beside grants, checked by every server ([design-files.md](design-files.md#alternatives-considered)). The execute bit gates only what the handler already checks |
| **A service as a file on the machine**, naming a program, a user and services, as an rc.d script does | It is a record on the data partition that names a user and services: whoever rewrites the partition would start code with a person's rights and nobody present (AP3). The package costs one command on the host and brings its own user, its sealed needs and its integrity |
| **Needs approved by the administrator at install**, in place of the board's offer | The approval would be a record where the storage domain can write it. The offer stays in the image; a development image offers everything safe |
| **A local setting that adds a service** | The same record. `deny` and `memory` are the two settings that cannot add |
| **Manifest rows for each of the board's apps** | A second way to be an app, with its own release script and argument line. An `app` row, the facet rows granted to it and a package give one |
| **Defaults alone for the board's own apps** | `ntpd` needs `clock.sample` alone and a network bounded to two sockets, and `bleuart` a login grant of `root_line` alone on `tty_line` with one row, which the login holder table requires exactly. Facet rows granted to the package keep those choices in the form every facet row has, and no installed app can be such a grantee |
| **Parameters in an app's declaration** | A rule for each parameter in admission and the mint, reachable by any signer. Installed apps take the `apps` row's defaults; the board's own apps take facet rows the integrator writes and the build checks |
| **Counting each image package at its needs** | A package that storage withholds frees a place an installed app can take at the whole offer, so the count falls short (PK2). Every place at the whole offer has no such case |
| **Reserving an image package's place by name**, so that its count at its needs holds when it is withheld | It keeps the saving but adds a reservation kept for a name whose header may never be read. The saving is in pixel areas only, and the whole offer is the existing count |
| **A pixel area charged to the app**, so that `max` costs only table places | The display reads the area and pays for it so that a client's end never takes memory the display still maps (D16 of [design-domains.md](design-domains.md#invariants); [design-display.md](design-display.md#the-pixel-area)) |
| **A command domain for each app**, so that an app may be a script or start Erlang commands | Each place of `max` would cost a second domain in every table, name pool, connection and Fiasco kernel-memory share property 19 sums. An Erlang service runs in its session's own runtime as OTP applications, which costs nothing more |
| **A separate pool for apps**, beside the logins' | A second number for the integrator to size and a split the machine's memory beyond the board's cannot cross. The reserved logins' walls keep the logins that must always work, and the rest shares one pool |
| **A principal's memory as a ceiling** | It is fixed while `share` grows with the machine, so on a large machine the two disagree. A principal's domains are slices of fixed sizes, and its `domains` quota bounds how many |
| **A session resized on request**, growing its pool when a start is refused | Elasticity rebuilt as policy, with a request path and a shrink path of its own. `share` sizes a session once, at its start |
| **`limits` or `ulimit` for a program's memory** | Their limits are of address space and data size; the cap is of a budget. `within` already means "run this within these bounds" |

## Risks and decisions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| a person runs a file a compromised storage domain replaced | low | their session's rights | `home exec` is the manifest's choice; stated in the release's known limits |
| an Erlang script costs a domain for each run | certain | slow, memory-heavy scripts | measured on the watch list ([todo-performance.md](todo-performance.md)); a command domain is kept while its program runs |
| apps fill `users`, so a login over the web, another person's, or a second root login over SSH is refused | medium | that login waits until an app stops | each console line, and root's SSH login where the manifest reserves it, always admits (decision 15) |
| the reserved logins' walls hold memory nobody is using | certain | on a large machine an eighth of `users` per wall | one wall per console line the machine serves, and root's SSH wall only where the manifest reserves it; `share` is the manifest's choice per template |
| `share` gives one login more than the next can have | medium | a second login refused with `no_memory` | the template's share is the manifest's; the refusal names the pool |
| `users` on the smallest board is tight once the board's apps are packages at the default 64 MiB | medium | an image that does not boot there | the board's apps declare their real memory; the build refuses the image, naming the sum |
| an app wants to run an Erlang script or an Erlang command | medium | refused with `EAGAIN` | its Erlang part is OTP applications in its session; a script with a native interpreter runs (decision 22) |

### Decisions

1. **Three kinds of thing run**: a program is a file, an app is a
   package, the board is the manifest.
2. **Authority only narrows down one chain**, and each person writes
   at one link of it.
3. **Execution is a fact of a namespace entry**, marked in the
   manifest and lowered by a mount, with the file's execute bit; `rx`
   is gone. `noexec` refuses starting and mapping a file as code, and
   no more.
4. **A tree writes and runs only as a user's home the manifest marks**,
   never for an app.
5. **Every app is a package**; a board's own app is an `app` row with
   the facet rows granted to it.
6. **Settings take away, and size memory inside `users`**; they add
   nothing.
7. **Memory has two parts**, the system's and `users`, both walls;
   each reserved login holds its wall from boot, and every other
   user's domain is a slice carved at its start. A principal has no
   memory of its own.
8. **The manifest states no derived number.**
9. **A script is read once and handed to its interpreter as a sealed
   copy.**
10. **The working agreement's list** carries the two entries
    [The working agreement's list](#the-working-agreements-list) gives,
    which keep what the handler refuses to run, the ceiling on
    authenticated authority and memory apart, and claim nothing about
    where code comes from.
11. **The image, a package and a marked home run files**; `/tmp` and
    removable media are `noexec`, as [Where execution is
    allowed](#where-execution-is-allowed) lists, and `noexec` means
    only what [What `noexec` does not promise](#what-noexec-does-not-promise)
    says. Authority is an allow-list, so a tree nobody marked runs
    nothing.
12. **Both development manifests mark homes `exec`.** A release's
    manifests decide it with that release's security closure, and the
    release's acceptance names the widening of trust it brings: the
    mark puts the storage domain in the trusted base for the code each
    person runs from a home.
13. **Only the execute bit gates.** A `chmod` that clears a read or
    write bit is recorded and gates nothing; `ls -l` shows the mode and
    the guide says that grants decide. Such a `chmod` is not refused,
    since `cp -p`, `tar` and `install -m 0444` set such modes as a
    matter of course. A storage service may refuse a write to a file
    without a write bit, as a server's own refusal.
14. **Apps and logins share `users`**, with each reserved login's wall
    beside them; there is no separate pool for apps. A large app, or
    many, can keep a login over the web, another person's login, a
    second root login over SSH and any command domain from starting,
    each refused with `no_memory` until memory is free; the person who
    administers the machine can always log in at its console, and over
    SSH where the board reserves it, and stop an app.
15. **Root's SSH login may hold a reserved wall**, as each console line
    does ([Slices](#slices)), carved from `users` at boot before any
    app starts. It is the manifest's choice per board: a board without
    a screen reserves it, one with a screen may leave it out, and the
    development manifests reserve it. The SSH server is not affected.
16. **A local `memory` may raise** an app's slice, bounded by `users`
    and judged at the whole wall, and it is introduced after `users`
    (step 10); with the reserved logins' walls it cannot keep anyone
    from the console.
17. **Walls under `users`**, not caps. Caps are decided at the gate
    that chooses the kernel, since Fiasco cannot tell the two apart
    ([Caps](#caps-the-alternative-that-changes-a-commitment)); FD25's
    reporting and the refusal of elastic budgets stay as they are.
18. **Root's login session takes an eighth of `users`** (`share 8`) in
    the development manifests, with no principal ceiling to disagree
    with it on a large machine. `share` gives neither fairness nor
    admission: admission at a reserved login comes from its wall.
19. **`net` is a right of `within`**: the right to create sockets,
    inherited without `within` and dropped by it unless named; sockets
    already held work on, and a command domain gets a network facet
    only when its program holds `net`.
20. **A development build also trusts the package keys of its
    medium**: a `package_keys` file beside root's `authorized_keys`,
    served the way root's medium keys are
    ([design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium)).
    The storage domain that serves `system` reads it through a
    read-only window, decodes at most 16 lines and serves only
    fixed-size Ed25519 key blobs, which the package process checks
    whole; a file with any malformed line trusts no key from it and is
    reported. That makes the storage domain a package-signing authority
    for that boot, which is accepted: in a development build the same
    domain already supplies root's login keys, which give more than a
    package can, since an app takes only the board's offer. A release
    build trusts the boot image's keys alone.
21. **A prebuilt SDK is published beside each published image**, from
    the same commit and for its ABI version, so that building a program
    does not need building erXos. It ships once the image license check
    covers the libraries of its `sysroot`.
22. **A script's interpreter is an Erlang command or a native
    executable**: an Erlang one is handed the bytes the handler read, a
    native one a read-only descriptor of them named `/dev/fd/N`
    ([Scripts](#scripts)), and an app's own program is never a script.
    An interpreter handed the path would break `within` and run bytes
    the handler did not check; a command domain for every app would
    cost a domain in every table for each place of `max`, so an app's
    Erlang stays in OTP applications.

### Open decisions

1. **`/usr/bin` in a session's namespace.** FreeBSD keeps `awk` and
   `env` in `/usr/bin`, so scripts written for it begin
   `#!/usr/bin/awk -f` or `#!/usr/bin/env NAME`. erXos's session export
   lists the image's programs in `/bin` alone
   ([design-shell.md](design-shell.md#commands)), so such a line names
   nothing and answers `ENOENT` until the script is edited to `/bin`.
   Recommended: the export also lists `/usr/bin` as a second name of
   the same directory, which costs one name in the export's tree and
   lets FreeBSD scripts run unchanged; it promises nothing `/bin` does
   not, so it is familiar where it is true. The other choice keeps one
   name and documents the edit. The slice this blocks is only that
   name; the tests of [Verification and testing](#verification-and-testing)
   use `/bin/awk`.

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
