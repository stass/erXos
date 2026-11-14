# Apps: packages and the SDK

A **package** is one file, `NAME.app`, that carries an app built outside
erXos's tree: a short declaration of what the app is and needs, and a
read-only image of its code and data. This document says how a third
party builds one with erXos's SDK, how an image builder adds it to an
image, how an administrator installs and removes it on a running
machine, and what the app may take.

**What an app author writes.** Three lines are a whole declaration:

```text
app dashboard
  needs display data
  applications erx_dashboard
```

The app is named `dashboard`, it wants the display and a directory of
its own, and its code is the OTP application `erx_dashboard`. Everything
else has a default: 64 MiB of memory, version 1, no license named.

**What a machine's builder writes.** One row of the board's manifest
says how much memory apps share and which services an app may ask for:

```text
apps
  memory 268435456
  services display data
```

**What an administrator types.** Installing is a copy and removing a
deletion, as on macOS, where an app is installed by copying it into
`/Applications` and the system's own apps lie apart in
`/System/Applications`:

```text
cp dashboard.app /apps/          install it
ls /apps                         dashboard.app  system
ls /apps/system                  the image's apps, read-only
service dashboard enable         start it at every boot
service dashboard start          start it now
cp dashboard.app /apps/          update it: the old one runs until the new one passes its checks,
                                 then stops
service dashboard restart        run the new version now
mount /apps/dashboard.app /mnt   look inside it, read-only, at /mnt; unmount /mnt to end
rm /apps/dashboard.app           remove it; its data stays
service dashboard purge          remove its data as well
```

`/apps` holds every installed app and `/apps/system` every app of the
image, each `NAME.app` a plain file, the package itself, so `cp`, `rm`,
`ls` and `cat` treat it as they treat any file. Within `/apps` and
`/apps/system` only names ending in `.app` are apps, and the tree
reserves every other name, so `system` is never an app's.

The central construction is that **an app is a principal of its own,
made from its declaration and checked against that one row**. Its
grants are those of the row's services it names; its memory comes out
of the row's budget; the row's `max` (8 by default) is how many apps a
boot can hold. The build proves the machine can afford the row at its
worst, every app present and holding every service the row offers, so
whatever apps arrive, the board's own domains keep what the build
proved for them, and admitting an app is a check that its needs are a
subset of the row's services. Every rule that keeps principals apart,
its directory, its inspect scope, its session names, its death records,
keeps apps apart with no rule of its own.

The start table, principals, session templates and facets are those of
[design-apps.md](design-apps.md); this document adds the `apps` row, the
package, `/apps`, the app principal and the SDK. The architecture is in
[design.md](design.md); the manifest and its check in
[design-system.md](design-system.md#the-manifest); principals and
sessions in
[design-domains.md](design-domains.md#principals-sessions-and-quotas);
budgets in [design-kernel.md](design-kernel.md#budgets); read-only
images in [design-storage.md](design-storage.md#reading-erofs-images);
the file protocol and namespaces in [design-files.md](design-files.md);
native programs in [design-programs.md](design-programs.md); windows in
[design-display.md](design-display.md).

Decisions every reader of this document needs:

* **An app names what it needs; the `apps` row bounds it.** The
  declaration names services, an amount of memory and its code. It has
  no field for a facet parameter, a quota or a grant, so nothing an app
  declares can reach past the row. Admission is one pure Erlang function
  that the build runs on the host and the system domain runs on the
  machine.
* **Memory is the kernel's to refuse.** All apps draw on one budget, the
  `apps` row's, which the build carves from the root like a principal's.
  Each app's sessions are carved from it as they start, and the kernel
  refuses what does not fit.
* **What an app makes another domain spend is counted at build.** The
  display's pixel areas, connections, domain slots, start rows and the
  atoms of session names are counted as `max` apps each holding every
  service of the row, so no app, however many arrive, takes what the
  build proved for the board's own domains.
* **The code is an EROFS image under a hash tree, read only by
  sessions.** The app's own session mounts its package's image at `/app`,
  and a person who wants to look inside a package mounts it with the
  shell's `mount`, each through the hash-checking reader in its own
  runtime, against the root hash of a header the system domain
  authenticated: by the hash the manifest records, for a package of the
  image, or by the signature of a key the boot image carries, for one
  installed at run time. The system domain reads only headers.
* **One package, two ways onto a machine.** `tools/erx pack --app` adds a
  package to an image, where it shows at `/apps/system/NAME.app`;
  `cp NAME.app /apps/` installs the same file on a running machine. Both
  run the same file check and admission and give the same session.
* **Installing, updating and removing are file operations.** The system
  domain serves the packages as files, and each session that may install
  mounts them at `/apps`. A file copied into `/apps` is checked when it
  is closed and published under its name only if it is whole and
  admitted; a copy over an installed app is checked the same way, and the
  old package stays published and running until the new one passes, and
  stays if it is refused. Removing the file removes the app and keeps the
  app's data.
* **One lifetime owns every change of the package directory.** A run of
  the package process owns the temporary files, the copies being written
  and the publications; the processes that carry out its file operations
  and its publications act only for a package process that is alive. So
  after a crash, nothing of the ended run happens once the next run's
  recovery has begun.
* **The start service decides whether an app runs.** Its keepers are the
  only starters of an app's sessions. Before an app's package goes or is
  replaced, the package process publishes a package set without the app,
  and the start service answers that publication only once the app's
  sessions have ended; an update then publishes the set with the new
  package, and the app's row is back in the table, installed and not
  running. A
  publication applies nothing of `/etc/rc.conf`, so nothing starts
  because it was installed or updated: the image builder enables a row
  of the image's packages, and the administrator an installed one with
  `service NAME enable`, which starts it at every boot, and `service
  NAME start` or `restart`, which runs the version installed now, as
  FreeBSD's `pkg upgrade` leaves services alone.
* **An app's data belongs to its name and its signer.** An app's
  directory is named for both, so two signers' apps of one name never
  share data, and removing a package keeps the directory for the next
  package of that name and signer.
* **The toolkit's programs ship with the toolkit.** `erx-lvgl` lies in the
  domain release's `bin/` of every image whose release holds `erx_ui`; no
  package carries it.
* **The SDK is the boundary.** An app compiles against the SDK alone: a
  sysroot with musl's headers, liberx's program layer and its link, the
  public Erlang applications, a host stand-in for a display, and the
  packer. The in-tree examples build through the SDK alone, so a break in
  the boundary fails the landing gate.

**How do I make an app?** Write `app.txt`, put the app's OTP
applications under `lib/` or its native program under `bin/`, and run
`erx-app pack DIR`, which builds what needs building and writes
`NAME.app`, signed with the SDK's development key unless `--key FILE`
names another ([Building and packing](#building-and-packing)).

**How does it reach an image?** `tools/erx pack --app DIR` builds and
packs the app, checks it against the image's manifest and adds it;
`--enable NAME` makes it start at boot. The board's manifest is not
edited.

**How does it reach a running machine?** `cp dashboard.app /apps/` at
the shell of a session that holds the `start` grant, then `service
dashboard enable` if it should start at boot and `service dashboard
start` to start it now. Copying a newer
`dashboard.app` over it updates it, with its data and its `/etc/rc.conf`
settings as they were, and stops it; `service dashboard restart`, or
the next boot, runs the new version. `rm /apps/dashboard.app` removes it and keeps
its data. `ls /apps` lists the installed apps, `mount
/apps/dashboard.app DIR` shows what one holds, and `/proc/packages`
shows each one's state.

**What may it take?** The services of the `apps` row that it names, the
memory it declares out of the row's budget, and nothing of the person
who installed or started it.

## Context

### What exists

An app is a principal with a session template, whose release is its code
and whose facet rows are its authority, and the start table starts and
keeps its session ([design-apps.md](design-apps.md#an-app)). Built:
the `start` rows, `erx_start_table`, `erx_starter` with its keepers, the
start service's tree (`erx_starter_fs`, with `ctl` and a read-only
`rc.conf`, which sessions mount at `/apps`; design-apps.md keeps only
`ctl` there, at `/etc/start/ctl`, and makes `rc.conf` the ordinary file
`/etc/rc.conf`, so that `/apps` holds apps alone) and
`erx_domain:start_session/2` (TODO.md, the design-apps.md items). The EROFS reader `erx_erofs` and
its block funnel `erx_verity` read images through a block window
(`otp/erts/preloaded/src/erx_verity.erl`, which checks no hash tree yet).
A native program runs either as a program of the boot image or as an
executable file that a grant with `rx` reaches, through the loader
`erx_exec` and a code object the domain service makes
([design-programs.md](design-programs.md#what-a-program-can-start),
[File objects](design-programs.md#file-objects)); a program that draws is
started with a window, whose `/dev/draw`, `/dev/kbd` and `/dev/mouse` its
handler binds ([design-display.md](design-display.md#the-window-tree),
"A program's `/dev`"). The session's program handler, `erx_prog_handler`,
is the one way a session's Erlang code starts a program; it assigns the
program's identity ([design-programs.md](design-programs.md#the-handler)).

The file service answers a client's `clunk`, the protocol's close,
itself: `erx_fs_grant` answers it when it hands the clunk to the file's
owner, and drops what the tree's `clunk` callback answers
(`erlang/apps/erx_files/src/erx_fs_grant.erl:229-244`), where
[design-files.md](design-files.md#serving-the-erx_fs-behaviour) has
every tree's clunk answer `ok` or an errno and the grant pass that answer
back once the owner has run it. The client already returns the clunk's
reply from `close`
(`otp/erts/preloaded/src/erx_file_remote.erl:487-492`). The shell's `cp`
copies with `file:copy/2` between two names
(`erlang/apps/erx_shell/src/erx_cmd_cp.erl`), which stock OTP runs in
`file_server`, whose copy closes the target and drops the close's answer
(`otp/lib/kernel/src/file_server.erl:177-193`); design-shell.md has `cp`
open its target itself and report a failed close.

Three facts of the clients decide what `/apps` must answer. On a writable
grant, `erx_file_remote` opens a file for writing with one `lcreate`,
which creates the file or opens the one already there in one step, and a
write without append or read carries `O_TRUNC`
(`otp/erts/preloaded/src/erx_file_remote.erl:349-392`, `:413-419`), so a
copy over an installed package reaches the tree as a truncating create
of the same name. And the shell's `rm` of a file is `file:delete/1`
(`erlang/apps/erx_shell/src/erx_cmd_rm.erl:37-48`), which `prim_file`
sends as one unlink (`otp/erts/preloaded/src/prim_file.erl:1231-1242`).
A native program overwrites a file as FreeBSD's `cp` does, which opens
an existing destination `O_WRONLY | O_TRUNC` without `O_CREAT`
(`bin/cp/utils.c:189-199`, FreeBSD 15.1.0), and the program's handler
sends an open without `O_CREAT` as a walk to the file and an `lopen`
([design-programs.md](design-programs.md#descriptors-and-files)), so
the same update reaches the tree as a truncating, write-only `lopen` of
the installed package.
The namespace already mounts an EROFS image read-only at a point,
`erx_ns:mount({erofs, Image}, To, Options)`, reading it through
`erx_verity` ([design-files.md](design-files.md#building-binding-and-mounting)),
and the shell's `mount` and `unmount` change the session's namespace
([design-shell.md](design-shell.md#commands)).

### What two demo apps found

Two apps were built the way a third party would build them, to find
where the app boundary is missing. The kiosk dashboard (`erx_dashboard`,
branch `lvglscreen`, commit `82b02f4ff`) and Doom (the repository
`erxos-doom`, gaps marked `BOUNDARY GAP` in `run.rb` and listed in its
`README.md`) each reached past what an app should need:

| Finding | Where it came from | What answers it here |
| --- | --- | --- |
| the app's application had to join `ErlangApps::APPLICATIONS` (`tools/lib/erx/erlang_apps.rb:25`), a release script (`tools/lib/erx/release_files.rb`, `RELEASE_SCRIPTS`), because `check_released` refuses an application no release holds, and `release_files_test`'s list | kiosk | an app's applications are in its package and never in a release file; the app template boots the system's `app` script, whose `erx_app` starts them from `/app` |
| Doom's launcher had to be one `-eval` expression, since `ReleaseFiles.domain_boot` admits only applications erXos's runtime builds | Doom 2 | the same; a native app needs no Erlang at all: its declaration names its program |
| manifest rows per app, and machine-wide sums grown by hand: display outer budget and connections, the system principal's memory, `root_memory`, `max_domains`, `max_connections` | kiosk, Doom 3 | the `apps` row: the board declares it once, and the build counts it for every app it can hold |
| no SDK: the build drove `tools/lib/erx` internals (`NativeRoot`, `ProductionImage`, `Programs::PROGRAM_PREFIX`) | Doom 1 | [The SDK](#the-sdk) |
| the program joined the one domain release's `bin/`, seen by every session | Doom 5 | the program is `/app/bin/NAME`, an executable file run through `erx_exec` |
| app code in the boot image made it 88 MiB, past the stopgap's 64 MiB root place | Doom 6 | the image builder's packages lie on the system slot, outside the boot image ([Where a package lies](#where-a-package-lies)) |
| no `open()` in a native program: `liberx/program/fd.h:37-41` has null, pipe and mem objects, and the C library seam answers every unlisted call `ENOSYS` (`musl/src/internal/erxos/syscall.c:536-537`), so the WAD was linked in | Doom 4 | designed, not built: [Descriptors and files](design-programs.md#descriptors-and-files) gives a program files through its handler; a package's data is `/app/share`, its writable files `/data` |
| the launcher invented a pid, parent, group, directory and masks for `erx_program:start/1` | Doom 7 | programs start through `erx_prog_handler`, which assigns them |
| presents on a 100 ms timer, no keyboard | Doom 8, 11 | a program started with a window draws through `/dev/draw`, flushes when its frame is done, and reads `/dev/kbd` |
| `erx_win:open/2` answered `{error, none}` until the display's grant arrived, so the launcher polled | Doom 9 | `erx_app` starts the app's code only once the session's ready answer has come, after its grants |
| a crashed session's restart was refused with `no_memory` while the ended domain's budget was still held | Doom 10 | an app principal's budget reaches the whole `apps` budget, and property 19 makes that budget hold a session beside the outer budget of one that ended ([An app's principal](#an-apps-principal)) |
| `bin/erx-lvgl` reached only the programs suite's test image (`tools/lib/erx/production_image.rb:95-99`) | kiosk | the toolkit's programs ship with the toolkit in every image |
| the host test used toolkit internals (`erx_ui:start/1`, `erx_ui_lvgl`'s `open` and `present` funs) | kiosk | `erx_ui_host`, the public host stand-in for a display |

### What other systems teach

These are taken from each system's published descriptions, not re-read
for this design.

| System | What erXos takes | What it leaves |
| --- | --- | --- |
| macOS | an app installed by copying it into `/Applications` and removed by deleting it, the system's apps apart in `/System/Applications`, each app named `NAME.app`; the app's data kept when the app is deleted | the app bundle as a directory, its layout and its signing format; the disk image (DMG) as the container ([Alternatives considered](#alternatives-considered)) |
| Android | a user id per app, so the separation between users is the separation between apps; a package signed by its author, whose data belongs to that signer | permissions granted one by one at run time; apps that grant each other services |
| Android APEX and Fuchsia packages | code as a read-only image checked block by block against a hash a signed header names | their package managers and resolvers |
| FreeBSD `pkg` | signature checks against keys the system trusts; a user's files kept when a package is deleted; an install or an upgrade starts no service, which starts at boot once `rc.conf` enables it or at its own `service` command | `pkg add`, `pkg delete` and `pkg info` as commands of their own; repositories and fetching by name |
| Flatpak | an app built against a published runtime and SDK, with the runtime shipped by the system, not the app | runtimes as packages of their own |

## Requirements

* **PK-R1.** A third party builds an app outside erXos's tree, with the
  SDK alone, and the app reaches no list, script or manifest of erXos's.
* **PK-R2.** An app added to an image or installed at run time holds no
  authority the `apps` row does not offer, and takes nothing the build
  proved for the board's own domains.
* **PK-R3.** Every byte of an installed or image package's code and
  data a session reads, the app's own or a person's through a mount of
  it, matches what its author packed, whatever the storage domain does.
* **PK-R4.** Two apps never see each other's domains, and, through a
  storage service that enforces its grants, never read each other's
  files, and two signers' apps of one name never share data.
* **PK-R5.** The same package and declaration serve the image builder
  and the administrator; the board's manifest is never edited to add an
  app.
* **PK-R6.** Install, update and removal survive a power cut, a crash
  and a failed write at any point, writes reordered between flushes
  included: a package's name holds one package whole, the old or the
  new, or none, and the published package set agrees with the directory
  once recovery has run.
* **PK-R7.** The system domain's atoms, tables, memory and work stay
  within bounds the build set, however many packages come and go in a
  boot and whatever the package directory holds.
* **PK-R8.** Every package byte, header and declaration, and every entry
  of the package directory, is untrusted input to the system domain and
  to the build host; a package's image is parsed only by a session.
* **PK-R9.** No copyleft package enters an image erXos distributes.
* **PK-R10.** An app author, a machine's builder and an administrator do
  as little as the first two requirements allow: every declaration field
  but the name and the code, and every `apps` field but the memory, has a
  default; installing is copying a file into `/apps`, updating is
  copying over it, removing is removing it, and an installed app is
  seen where it was copied.

Outside this design: a policy per signer, which would offer the apps
of one signer other services than the `apps` row offers every app (the
builder's lever is which signer keys the image trusts); fetching
packages by name (a fetcher is a command
in a person's session that holds `net` and copies the file into
`/apps`); prompts that ask a person to approve a grant; apps that serve
facets to other apps; keys at the vault for an app; packages of system
services or drivers, which are configured domains of the manifest.

## Overview

```text
 the developer's host              the image builder              the machine
 --------------------              -----------------              -----------
 DIR/app.txt  lib/ or bin/  share/ tools/erx pack --app DIR      system domain
      |                              --enable NAME                 erx_pkg: checks each package file
      | erx-app pack (SDK)             |                             and header, admits it against
      v                                | file check and admission    the apps row, registers the
 NAME.app: header (declaration,        | on the host                 app's principal, publishes the
   arch, root hash, signer,            v                             package set to the start service;
   signature) + EROFS image       image: the apps row, a            serves the packages as files
   + hash tree                    `package` row per app, the        (the `apps` tree)
      |                           package on the slot                   |                  ^
      | cp NAME.app /apps/ (administrator's session, which mounts       |                  | files
      | the apps tree at /apps as it mounts any facet)                  |                  |
      +-----------------------------------------------------------------+------------------+
                                                                        | start_session(app, Start)
                                                                        v
                                                                 domain service: a session of
                                                                 the app template, as the app's
                                                                 principal, with the services
                                                                 it named and its package at /app
```

**An app's life, end to end.** A developer writes `app.txt` for
`dashboard`, needing `display` and `data`, and packs it with the SDK.
The image builder runs `tools/erx pack --app DIR --enable dashboard`;
the build checks the package against the board's `apps` row and records
it in the image's manifest. At boot the system domain's package process
reads the package's header, checks it against the manifest's record,
admits it and registers the principal `dashboard`. The start table
starts its row; the domain service makes a session of the app template
as `dashboard`, named `dashboard_1`, holding the row's `display` and
`data` grants and the `packages` grant every app holds. Once the
session's grants are in place, `erx_app` mounts the package's image at
`/app`, puts `/app/lib/*/ebin` at the end of the code path and starts
`erx_dashboard`, which opens its window with `erx_ui:open/1`. An
administrator's `ls /apps/system` shows `dashboard.app`, and `mount
/apps/system/dashboard.app /mnt` shows its `lib/` and `share/` at
`/mnt`, read by the administrator's own session through the same hash
check.

Later the image builder ships a second app as a file, `clock.app`. The
administrator types `cp clock.app /apps/`. The copy lands in a
temporary file; when it closes, the package process checks the file and
its header, admits it, makes it durable, renames it to `clock.app`,
registers the principal `clock` and publishes the package set with it,
and `cp` succeeds. `service clock enable` makes it start at boot, and
`service clock start` starts it now. A newer build,
copied the same way over `clock.app`, lands in a temporary file too, and
`clock` runs on unchanged while it is checked; once it passes, the
package process publishes the set without `clock`, so the start service
ends its session, renames the new file over the old, and publishes the
set with it. `clock`'s row is back in the table, installed and not
running, and `service
clock restart` starts it on the new package. `rm
/apps/clock.app` has the package process publish the set without
`clock` and then delete the file; the app's data stays for the next
`clock.app` of the same signer.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **PK1.** An app holds no grant the `apps` row does not offer, and its memory comes only from the row's budget | the declaration grammar names services and one amount of memory; admission keeps a need only if it is one of the row's services; the session's facets are the `packages` grant and the kept needs, both rows of the manifest, through the domain service's one funnel (A10); the app's principal budget is a child of the `apps` budget, so every session it starts is carved there or refused | a declaration field that carries a parameter or a grant; an admission that keeps a need the row lacks; a session plan that grants a row the app did not name; an app budget carved from the root | admission's corpus with a seeded admission that drops the subset test; the session plan's host test with a seeded plan that grants every row of the template |
| **PK2.** The build's proof for the board's own domains holds with every app present | property 19 counts the app template as `max` principals in every sum that counts a principal or a template's rows (display pixel areas and connections, domain slots, start rows, principal table, name atoms), each holding every service of the row | a sum that counts the app template once; a service an app may take that no sum counts | the seeded violations of [The build's check](#the-builds-check) |
| **PK3.** Every block of a package's image that a session reads, at `/app` or at a mount of a file of `/apps`, matched the root hash of a header the system domain authenticated | `erx_app` mounts `/app` only through `erx_verity`, with the root hash, salt and tree layout the domain service hands it in the ready answer, which the domain service takes only from a header the file check accepted; the shell's `mount` mounts a package only through `erx_verity`, with the layout of the header bytes read through the same open as the image, and the `apps` tree serves header bytes only once their SHA-256 is the one it recorded when the file check accepted them | a mount whose root hash comes from the session's own read of `packages`; a header read the tree answers without its hash check; a mount that reads the header and the image through two opens; a read path around `erx_verity` | from M11, a QEMU test that flips one byte of an installed package's image and finds the read refused at `/app` and at a mount of it; the `apps` tree's host test of a header changed on the medium after the check, answered `eio`; the build check that only `erx_erofs` reads through `erx_verity` (`Erx::ErofsReads`) |
| **PK4.** Two apps see nothing of each other, and two signers' apps of one name share no directory | each is its own principal; the domain service computes every scope from the session's principal, the app's; the storage service roots each app's `data` grant at `apps/NAME/SIGNER/`, both parts from the principal's record | a scope, storage root or name pool derived from the template's key; a data root that leaves out the signer; two apps registered under one principal | a QEMU test with two apps; the mint's host test of one name under two signers, two roots; seeded: the mint's scope taken from the template's key, and a root of the name alone |
| **PK5.** The system domain parses a package's header alone, through the generated reader, and loads no app code | the package process reads at most `pkg_header_max` bytes of a file and hands them to the file check; the image is parsed only in a session, the app's own at `/app` or a person's that mounted it | a system-domain module that mounts or reads a package's image | a source check over the system release that no module but the file check names a package's bytes, and that no system-release module calls `erx_verity` or `erx_erofs` on a package, with a seeded call from `erx_pkg` |
| **PK6.** A package's name holds a whole package that the file check accepted and admission admitted | a copy is written into a temporary file that no open can reach by name; at its close the package process runs the file check (name agreement, exact length, size bound, header) and admission, makes the file durable, and only then renames it to `NAME.app`, over the package the name held if it held one, in one atomic rename; the recovery runs the same file check on every `NAME.app` before it admits one | a rename before the file is durable; an update that deletes the old package before its rename; a recovery that admits without the file check; a length check that accepts a short file | the planners' crash test over every write of an install and an update, with writes reordered between flushes; the file check's host test of a short, a long, an oversized and a misnamed file, run through the close and through the recovery |
| **PK7.** No session of an app runs while its package's name changes, by a removal or an update | the start service's keepers are the only starters of an app's sessions (AP2: an app principal has no credentials, so no login starts one); before the package process deletes an app's file or renames another over it, it publishes a package set without the app, which the start service answers only once the app's sessions have ended, and it starts none until a set with the app arrives | a second starter of app sessions; a publication answered before the sessions end; an update that renames over a published package | the start table's host test of a publication that drops a running app; a QEMU test that removes a running app and one that updates it, each finding no session of it once the publication has answered |
| **PK8.** A removal or a purge reaches only what belongs to an app | a removal deletes one `NAME.app` inside the package directory, after a publication that drops only that package's row; a purge sends the storage service's `remove_app`, which reaches only the directory of app directories; a name that fails the app-name rule is refused before any effect | a removal that stops domains by principal name; a data removal through a grant wider than the app directories | the purge's host test with names `root`, a configured domain and a manifest principal, each refused with nothing stopped or deleted |
| **PK9.** The system domain's atoms, tables and recovery work stay within the build's bounds | an app principal lives for the boot in one of `max` entries, which removal does not free until the next boot; its sessions take pooled names within its `names` quota; at most `max` copies are open at once and each holds its temporary file until its close is decided or its lifetime ends; recovery reads at most `pkg_scan_max` entries; the package process keeps a header's SHA-256, not its bytes | an unregister that frees an entry within the boot; a slot freed before its file is deleted; a recovery that reads the directory unbounded | a host test that installs and removes `max` + 1 distinct names in one boot and finds the last refused with `apps_full`; the recovery's fuzz target over listings past the bound |
| **PK10.** A package of the image and one installed at run time give the same session | both pass the file check, `erx_app_admit:admit/3` and the same session plan; only what authenticates the header differs | a second admission or plan for one of them | the session plan's host test over one header admitted both ways |
| **PK11.** No effect of an ended package lifetime happens once the next lifetime's recovery has begun | a lifetime is one run of `erx_pkg`; `erx_pkg_io` takes every file operation on `packages` and the start service every publication, each one at a time, finishing the one it began before taking the next, and each refuses an effect whose lifetime has ended; the recovery's first request is taken after every earlier one; copy handles name their lifetime, so they end with it; `erx_pkg_io` is never restarted: its end resets the machine | an executor that takes a request without checking its lifetime; a restarted `erx_pkg_io` while a request of its predecessor may be in flight; a copy handle that outlives its lifetime | the lifetime's host test: a package process killed with two copies writing and a close queued, after which no request of the ended lifetime reaches the simulated storage after the recovery's listing; seeded: an `erx_pkg_io` without the lifetime check |
| **PK12.** An open of a package of `/apps`, and a mount over one, reads that package's bytes or `eio`, never another package's | the `apps` tree gives each package it publishes or admits a qid path drawn from the system domain's file version counter, which no restart of the tree resets, so no path names a second file while the system domain runs, as every server keeps its paths ([design-files.md](design-files.md#identity-and-version)); an open records the package it opened, and once the name holds another package or none its reads answer `eio`; a mount reads only through its one open; the session's export names each mount's tree when it is mounted, so a program's file table never joins a file of an old mount to one of a new mount at the same point ([design-files.md](design-files.md#narrowing-for-a-program)) | a qid path drawn from the name, the listing's order or a counter the tree's restart resets; a read that reopens the name instead of checking the open's package; an export tree named by its mount point | the `apps` tree's host test of an open across an update and across a removal and reinstall; the export's host test of a point mounted again with an image whose inode numbers repeat |

## Data model

### The `apps` row

The board's manifest has at most one `apps` row. Without one, the
machine takes no packages. Its fields:

| Field | Meaning | Default |
| --- | --- | --- |
| `memory` | the budget all apps share, in bytes; property 4 counts it within `root_memory` as it counts a principal's budget | none: required |
| `services` | the services an app may name in `needs`, each a service of the manifest | none, so an app holds only its `packages` grant |
| `max` | how many apps a boot can hold, the image's and the installed ones together, 1 to `apps_max_limit`, 64 | 8 |

From the row the build derives, as rows of the image's manifest that the
board's source does not hold and the build record lists:

* **the app template**, a session template whose runtime is the
  system's interpreter, whose release boots the domain release's `app`
  script (the base every session boots, the client side of the display,
  `erx_memdraw`, `erx_win` and `erx_ui`, and `erx_app`), and whose limits
  are a session's defaults with `SPACES` (property 14);
* **one facet row for each service of `services`**, which never holds
  `packages`, `start`, `apps` or `etc` (property 19), granted to the app
  template, named as the service is, with the parameters the service's
  ABI file gives as its defaults. A service may be named in `services`
  only if its ABI file declares a default for every parameter its rows
  take: `abi/services/windows.txt` declares `windows_default` and
  `windows_pixels_default`, and `files` and `net` declare no parameter.
  A row of the data partition's storage service carries the parameter
  `tree apps`, which roots its grants among the app directories ([Where
  an app's files lie](#where-an-apps-files-lie));
* **the `packages` rows**: the system domain's grant of the `packages`
  service, read-write, and the app template's, read-only;
* **the `apps` rows**: the `apps` service, an instance of `files` that
  the system domain serves, and its facet row granted to every session
  template the manifest grants the start service's tree, `start`
  ([design-apps.md](design-apps.md#interfaces)), so whoever may run the
  start table may install, and no one else.

**The shipped manifests.** Both development manifests,
`config/manifest/qemu-virt-development.txt` and
`config/manifest/raspi4b-development.txt`, carry an `apps` row, so a
development build takes packages with no edit. The website's image
carries none: `Platform#site_manifest_source` leaves the row out of the
site manifest it makes from the development one, with the room it took,
as it leaves out the domains `site_leaves_out` names
([design-stopgap.md](design-stopgap.md#the-phase-1-manifest-check)), since the site manifest has
no display domain for `services` to name and the site machine's 256 MiB
no room for the row's memory. The row's size follows from how the build counts it:

* `max` is reserved in full: property 19 counts the app template as
  `max` principals, each holding every service of `services`, in the
  display's pixel areas and connections, the domain and principal
  tables, the session-name atoms and every server's connections, whether
  or not an app ever arrives. So `max` is the number of apps a developer
  keeps installed in one boot, not a bound to be generous with. The
  development manifests take the default, 8, and lower it only if the
  board's own sums then fail.
* `services` is `display data net`: the services both boards serve that
  the examples and a developer's apps need.
* `memory` is not multiplied by `max`: it is one wall, carved from
  `root_memory` and counted by property 4, that the apps running at
  once share, and the kernel refuses a start that does not fit. So it is
  sized for the apps that run together, not for every app the row can
  hold: two at the default 64 MiB, each with its session's outer budget
  of 1 MiB, and the outer budget of one that has ended and not yet
  retired, which clause 4 needs beside a running app, 131 MiB
  (137,363,456 bytes), which the two-app tests of
  [Verification and testing](#verification-and-testing) need.
  `root_memory` grows by it, and the packer's check of each board's
  development machine proves that the RAM left beside it still holds
  the archive.

An app principal's group is a child of the apps group, whose share of
`users` is what the principals' shares leave of it, each app an equal
share of that. An app principal's quotas are a principal's defaults, but
`domains`, which is 1: an app runs one session at a time.

#### The build's check

The manifest check gains one property, property 19, **the `apps` row and
the packages are well formed**, beside the eighteen of
[design-system.md](design-system.md#the-manifest):

1. at most one `apps` row; each name of `services` is a service of the
   manifest whose ABI file gives every parameter a default, other than
   `packages`, which every app holds already, and `start`, `apps` and
   `etc`, which would let an app command the start table, install
   packages and rewrite `/etc/rc.conf`; property 17 checks the resolved
   manifest for the last whatever the rows' source, since every writable
   grant of the `etc` tree must belong to a template that holds `start`
   ([design-system.md](design-system.md#the-manifest));
   when it names `inspect`, the scope `erx_domain_core:inspect_scope/3`
   gives an app principal is its own, never `all`, which would show an
   app the other apps' domains;
2. wherever properties 4, 5, 17 and 18 count a principal or a session
   template's rows, the app template counts as `max` principals with a
   `domains` quota of 1, each holding every facet row granted to it: the
   display's pixel areas and sides, the domain table and `max_domains`,
   the principal table, the atoms of session names, and each server's
   connections;
3. the manifest's `start` rows and `max` sum within `start_rows_max`, 256,
   since every app can bring one row;
4. the `apps` budget and the app template's limits let the planner of
   property 12 plan one session of the template at its default memory
   beside the outer budget of one that ended and has not retired;
5. every `package` row's package passes the file check and admission on
   the host against this manifest ([Admission](#admission)); the
   `package` rows number at most `max`; the declared memory and the
   session's outer budget, as the resource policy sizes it, of every
   enabled package sum within the `apps` budget, so the image's enabled
   apps all start; and the row of an enabled one meets property 17's
   display and planning clauses as a manifest `start` row does;
6. every `signer` row holds a 32-byte Ed25519 public key under a unique
   name;
7. no facet row of the board's source is granted to the app template,
   carries `tree apps` or names the `apps` service: only the rows the
   build derives do.

Each clause has a seeded violation: a check that counts the app template
once in property 18, which admits a row whose apps together pass the
display's budget; an `apps` row whose `max` plus the manifest's start
rows pass 256; `apps` in `services`; `etc` in `services`; a service
in `services` whose ABI file gives a parameter no default; two enabled packages whose memory
passes the `apps` budget; a `package` row whose declaration needs a
service the row lacks; a configured domain's `data` row carrying `tree
apps`.

### The declaration

`app.txt` is written in the syntax of the manifest's source and the ABI
files (`ABI::Syntax`: ASCII, rows at column 0, two-space fields, quoted
strings), at most 16 KiB, and holds one `app` row. An Erlang app names
its applications:

```text
app dashboard
  needs display data
  applications erx_dashboard
```

A native app needs no Erlang:

```text
app doom
  needs display data
  memory 134217728
  license "GPL-2.0-only"
  program "bin/doom" "-iwad" "/app/share/freedoom1.wad"
```

| Field | Value | Default and bound |
| --- | --- | --- |
| `app NAME` | the app's name, which is its principal's | required; an app name ([Admission](#admission)) |
| `applications` | the OTP applications `erx_app` starts | at most 16 names of the form `[a-z][a-z0-9_]*`, 63 bytes each |
| `program` | a path under `bin/` of the image, then its arguments | the path at most 255 bytes of plain names; at most `pkg_args_max`, 32, arguments, 16 KiB together |
| `needs` | the services of the `apps` row it takes | none; at most `pkg_needs_max`, 16, identifiers, none twice |
| `memory` | what its session's own budget holds, in bytes | `app_memory_default`, 64 MiB; at least `app_memory_min`, 4 MiB |
| `version` | a decimal number the inspector shows, which decides nothing | 1; 1 to 2^32 - 1 |
| `license` | the package's SPDX license expression | none, which no image erXos distributes takes; at most 256 bytes, in the grammar `LicenseExpression` reads |

A declaration has exactly one of `applications` and `program`. An Erlang
app that needs a native helper starts it itself with
`erx_prog_handler:start/1`. A program starts with a window on the
session's default display when the app needs a `windows` service, and
otherwise without one. A declaration names no facet parameter, quota,
CPU share, environment or grant, and there is no field through which it
could: the illegal declaration is one the grammar cannot write. An app
that wants the LVGL renderer says so where it opens its UI, with
`erx_ui:open(#{renderer => lvgl})`
([design-display.md](design-display.md)).

Every admitted package has a start row named for its app, disabled
until the image builder or the administrator enables it, on its one
`windows` need if it has exactly one and on none otherwise, with the
start table's default intensity. `rc.conf` sets it as it sets any row
([design-apps.md](design-apps.md#the-start-table)), so the declaration
carries no start settings.

The packer parses the text on the host and writes the declaration into
the package's header as a packed record of `abi/formats/package.txt`.
The machine never parses the text: the system domain reads the packed
record through the reader the generator produces from that file, which
checks every count, length and offset before it reads a field.

### The package

A package is one file, `NAME.app`, of three parts, each starting at a
4 KiB boundary:

| Part | Holds |
| --- | --- |
| header, at most `pkg_header_max`, 64 KiB | the magic `ERXPKG`, the format version, the header's length, the `ERX_ABI_VERSION` and the target architecture (an architecture name of `abi/arch/`) the package was built for, the packed declaration, the image's length in blocks, the hash tree's length, salt and root hash (SHA-256, dm-verity format version 1, as [design-storage.md](design-storage.md#data-model) lays read-only images), the signer's Ed25519 public key, and the Ed25519 signature over every byte of the header before it |
| image | an uncompressed EROFS image of 4 KiB blocks, whose root holds `lib/APP/ebin` and `lib/APP/priv` for each application, `bin/` for programs and `share/` for data |
| hash tree | the image's dm-verity tree, over the image's blocks as they lie in the file |

The image uses only the layouts the EROFS reader implements: compact and
extended inodes, the plain and inline data layouts, regular files,
directories and symbolic links, and no compression
([design-storage.md](design-storage.md#reading-erofs-images)). They are
the layouts `fsimg` writes with the options every erXos image is made
with, `-o cluster=4096 -o compression=none`
([design-storage.md](design-storage.md#data-model)), which the packer
uses too. The file check reads only the header, so an image another tool
made in another layout is admitted and fails where the reader meets it:
the mount refuses an incompatible feature bit, and an inode of a
compressed or chunked layout answers `enotsup` when it is reached, in the
reading session alone. The image's entries carry fixed owner, mode and
time, so the same inputs give the same bytes and no host metadata leaks
into a package. The image names no device, socket or link leaving it.

**The file check**, `erx_pkg_header:check_file(File, Authority)`, is the
one entry that judges a package file, at a copy's close, at recovery and
for the image's packages at boot and at build. `File` is the file's name
in the directory, its length and its first bytes, at most
`pkg_header_max`. It checks, the first failure answering:

1. the length is at most `pkg_bytes_max`, 1 GiB: `{too_large, L}`;
2. the header's magic, version and lengths, with the declaration decoded
   by the generated reader: `{header, Reason}`;
3. the file's length is exactly the header's length plus the image's and
   the tree's, with checked arithmetic: `{length, Have, Want}`;
4. the name is `NAME.app` with NAME the declaration's app name:
   `{name, File, App}`;
5. the header is authenticated by the means `Authority` names:
   * `{hash, Sha256}`, for a package of the image: the header's SHA-256
     must equal the one its `package` row records. The signer and
     signature fields are not read, so a package someone else signed is
     added to an image without the machine trusting its signer, and the
     app's signer is `image`;
   * `{signers, Keys}`, for a package installed at run time: the header's
     signer must be one of `Keys` and its signature valid. The app's
     signer is the key's `signer` row name, or `development`;
   `{untrusted, Reason}`.

It answers `{ok, Header}`, with the signer named, the header's SHA-256
and the layout of its image, or `{error, Reason}`. It is pure but for
the signature check, which the small Ed25519 verifier of
[design.md](design.md#dependencies) makes, as for an update's manifest.
`erx_pkg_header:layout/1` decodes the layout alone (the image's offset
and length, the hash tree's offset, length and salt, and the root hash)
from header bytes that some other party authenticated: `erx_app` on the
header the domain service hands it, and the EROFS mount of a file of
`/apps` on header bytes the `apps` tree authenticated; neither on bytes
read from `packages`.

### Where a package lies

| | The image builder's packages | Installed packages |
| --- | --- | --- |
| placed by | `tools/erx pack --app` | `cp NAME.app /apps/` |
| lies | in the system slot, in the package image, an EROFS image of package files that the manifest's `image` row records like the release's; the storage service serves its files read-only under `packages/image/` | in the data partition's `packages/` directory, which the storage service serves |
| shown at | `/apps/system/NAME.app` | `/apps/NAME.app` |
| header authenticated by | its SHA-256, which the manifest's `package` row records | a key of the manifest's `signer` rows, or in a development build the development key |
| changes | with a system update, as the slot does | by a copy into `/apps` or over a package there, or a removal there |

A machine trusts only the signer keys the boot image carries: the
manifest's `signer` rows, and in a development build the SDK's
development key. Trust therefore changes only with a system update, and
no record a storage domain could rewrite adds a signer.

The system domain and the app's session reach the file through the
`packages` service, an instance of `files` that the storage domain
serves at a service directory of its own: the system domain reads and
writes it, and the app template reads it. Since `erx_verity` checks
every block against the root hash of the authenticated header, no
property of a package rests on the storage domain but its presence: a
storage domain can withhold a package or put back an older one of the
same signer, never change one. Every app can read every package's bytes:
a package holds what its author ships, not anyone's secrets, and keeping
each package to its own app would need a grant per package.

**On the stopgap**, where the storage service does not yet serve a slot's
image, the image builder's packages lie in the boot image's domain
release at `pkg/NAME.app`, and their sessions read them through `/`,
the release slice. They enlarge the boot image and the memory it holds,
and every domain can read them (Phase 1).

### `/apps`

`/apps` is one tree, the **`apps` tree**: the packages as files. The
package application serves it in the system domain with `erx_fs`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)), and
the `apps` rows grant it to the templates that hold `start`. A session
holding the facet mounts it at `/apps`, read-write, as it mounts `data`
at `/data` ([design-files.md](design-files.md#building-binding-and-mounting),
"A facet's mount"), and a program of the session reaches it as it
reaches `/data`, through a fid its handler walks
([design-files.md](design-files.md#narrowing-for-a-program)).

| Name | Read | Create, write and remove |
| --- | --- | --- |
| `NAME.app` | the installed package's bytes | a create (`lcreate`) that truncates, of a name that is not one of the image's, or a write-only, truncating open (`lopen`) of the installed package, starts a copy, published at its close whether or not the name holds a package ([Installing, updating and removing](#installing-updating-and-removing)); a remove (`unlinkat`) removes the package |
| `system/NAME.app` | the image package's bytes | none: every change answers `erofs` |

It lists one `NAME.app`, a regular file, for every installed package,
admitted or refused, and in `system/` one for every package of the
image. A name that does not end in `.app`, but `system` at the root, is
the tree's own: it lists none, and a create of one answers `einval`. A
create of `NAME.app` opens the file write-only and truncates it, as
`cp` and every open for writing without append does, since a copy
starts empty: one that appends or also reads answers `einval`, and one
with `O_EXCL` of a name the tree holds answers `eexist`. While a copy is
written, the name goes on holding the package it held, and that package
goes on running.

An `lopen` of an installed `NAME.app` that is write-only and truncating
is the same act as that create: it starts a copy of its own, in a slot
of its own, whose close answers as a create's copy does, so a native
`cp` over a package updates it as the shell's does. Every other
writing `lopen`, one without truncation, or that appends or also
reads, answers `einval`, and an `lopen` of a node whose name holds
another package since its walk, or none, answers `eio` whatever its
mode, as a read of an open of it does ([Identity](#apps)); neither
touches the installed package. An `lopen` for reading reads, as any
open does.

**Reads.** A read that reaches into a package's header is answered from
the header the package process reads again from `packages`, and served
only if its SHA-256 is the one the file check recorded; otherwise it
answers `eio`. So every header byte a reader gets is one the system
domain authenticated, and the rest of the file is bytes the hash tree
checks. Reads run in `erx_pkg_io` in turn with the directory's changes,
each through a fid opened for it and clunked after, so no read meets a
file being deleted or renamed over.

**Identity.** Each package the tree publishes, at a copy's close or at
the recovery, gets a qid path of its own, drawn from the system domain's
file version counter, the one counter of the runtime that no server's
restart resets ([design-files.md](design-files.md#identity-and-version)),
so no path is given to a second package while the system domain runs,
which is the whole boot, since its end resets the machine, however often
the package process and its tree restart; its version is drawn from the
same counter, as every server draws one. An open
records the package it opened. Once its name holds another package, or
none, every read of the open answers `eio`, and a new open of the name
reaches the new package under its new qid path. So no client caches one
package's bytes under another's identity, and no open reads a mix of
two packages. FreeBSD differs: there an open file stays readable after
its name is removed or replaced, and here the tree keeps no file without
its name.

**Looking inside a package.** `mount /apps/NAME.app DIR` mounts the
package's image read-only at `DIR` in the session's namespace, and
`unmount DIR` ends it. It is the namespace's EROFS mount,
`erx_ns:mount({erofs, Image}, DIR, [ro])`
([design-files.md](design-files.md#building-binding-and-mounting)), with
the image read from a file, `Image = {file, Path, Layout}`, the form
`erx_app` mounts `/app` with ([An app's session](#an-apps-session)): the
mount opens `Path` once, for reading, and the EROFS reader reads the
image through that open, at the layout's offset, through `erx_verity`,
which checks every block against the layout's root hash. For `/app` the
layout is the one the domain service hands the session. The shell's
`mount` passes `header` instead, and the mount reads the first
`pkg_header_max` bytes through the same open and decodes them with
`erx_pkg_header:layout/1`. For a file of `/apps` those bytes are the
ones the `apps` tree authenticated, and header and image come through
one open, so they belong to one package (PK3); a package file elsewhere
mounts against its own header, which shows only that the file agrees
with itself. The mount reads only through its open, so once the package
is removed or replaced, its reads at `DIR` answer `eio` (PK12) until it
is unmounted, and mounting the name again mounts the new package. The
session's export names each mount's tree when it is mounted
([design-files.md](design-files.md#narrowing-for-a-program)), so a
program still holding a file of the old mount open shares no file-table
entry with one that opens the same path in the new. The image is parsed
by the EROFS reader of the session that mounted it, within the reader's
bounds ([design-storage.md](design-storage.md#reading-erofs-images)),
never in the system domain.

Since a package is a plain file, every file command means what it means
for any file: `cp` over it is an update, `rm` removes it, `cp
/apps/NAME.app X` copies the package itself, and `ls -l` shows its size.
Looking inside it is the one explicit act, a mount, as an image file is
mounted to be read.

### Where an app's files lie

The data partition's storage service keeps every app's directory under
one directory of its own, `apps/`, apart from the directories of the
manifest's principals and services. A grant from a facet row that
carries `tree apps` is rooted at `apps/NAME/SIGNER/`: `NAME` is the
grantee's principal as the mint names it, the app's, and `SIGNER` is the
signer its principal record holds, `image` for a package of the image
and otherwise the first 16 bytes of the SHA-256 of the signer's public
key, in hexadecimal. Property 19 lets only the rows the build derives
for the app template carry `tree apps`.

So the data belongs to the name and the signer together. A package of a
name signed by another key finds an empty directory of its own and never
the first signer's files, with no record to keep and no refusal to
judge, as an Android app signed by another key is another app. An
author who signs with a new key leaves the old key's directory behind,
which a purge removes.

Removing a package keeps its app's directory, as deleting an app keeps
its data on macOS and deleting a package keeps a user's files on
FreeBSD, so a package of the same name and signer copied in again finds
its data where it was. An administrator removes the data on purpose with
a purge, `service NAME purge`, which the start service's `ctl` takes as
`purge NAME`; that file's owner hands it to the package process and
awaits the answer itself, outside the start table
([design-apps.md](design-apps.md#concurrency)). The package process
carries it out with the storage service's `remove_app` request on the
durability facet, which only the system domain holds and which reaches
nothing outside `apps/`
([design-storage.md](design-storage.md#interfaces)): it removes
`apps/NAME` whole, every signer's directory of the name with it, NAME one
identifier, answers `ok` once a completed checkpoint holds the removal
and every write the service acknowledged before it, and answers `ok` for
a directory already absent. The package process refuses a purge of a
name that is not an app name, a name of the image's packages, or a name
installed now, before any request, so no running app's directory is
removed under it.

### An app's principal

The principal service registers an app's principal with
`erx_principal:register_app/2`, which only the package process calls,
in a free entry of the `max` the domain library's principal table holds
for apps. Its record holds the app's name, its signer (`image` for one of
the image's) and its declared memory, and it is written only when a
package of the name is committed: at an install or an update, once the
rename is durable, and at the recovery, for each package it admits. A
refused or failed install or update leaves the record as it was. A principal of an app has no
credentials: no one logs in as one. Its directory, its inspect scope and
its name pool are those of any principal, keyed by its name, and its
data directory by its name and signer. It is never unregistered within a
boot: a removed app's principal keeps its entry and name, with nothing to
run, until the machine reboots, so its atoms and its table entry stay
within the build's count (PK9). Installing the name again in that boot,
or updating it, takes the same entry, with the same signer only, and
writes the record again.

Its budget is a child of the `apps` budget. Every principal of the
manifest has a wall, a budget whose cap is its guarantee; an app's is
**elastic** ([design-kernel.md](design-kernel.md#budgets)), with no
guarantee and the `apps` budget's guarantee as its cap, fixed for the
boot. Each session's own and outer budgets are walls carved from it, as
every domain's are, at the memory the record holds when the session
starts, so once a session runs, its memory depends on nothing outside
it; what the kernel judges against the `apps` budget is only whether a
session can start. A package of the name installed again or updated
with another `memory` changes the record and so the next session's plan, and no
budget is resized.

### An app's session

`erx_domain:start_session(App, Start)` makes an app's session as it makes
any session, with three differences, all decided by the domain service
from the app's admitted record:

* the domain library's plan takes the app template and the app's
  principal: `erx_dom_plan_session` accepts a principal that is the
  template's own or an app principal when the template is the app
  template, and no other, and for an app principal takes the template's
  limits with the `memory` its record carries;
* its facets are the template's `packages` row and the rows the
  admission kept, and no others; each mint computes its parameters from
  the session's principal, the app's, as every mint does
  ([design-system.md](design-system.md#facets-a-configured-domain-serves));
* the ready answer, which hands the session its default display
  ([design-apps.md](design-apps.md#starting-a-session)), also hands it
  the app's record: the place of the package's file
  (`packages/NAME.app` or `packages/image/NAME.app`, or `/pkg/NAME.app`
  in the release on the stopgap), the header's layout, and its
  applications or its program with its arguments and whether it has a
  window.

The record comes only after the session's grants are added, the
`packages` grant among them, so the app's code never starts before its
grants exist and its package is readable when it starts. `erx_app`
mounts `/app`, `rx`, with `erx_ns:mount({erofs, {file, Place, Layout}},
"/app", ...)` from the record; a mount the reader refuses ends the
session with the reason. The root hash is the domain service's, so a
session that mounted anything else would harm only itself. The
session's name is drawn from the app's own pool, `dashboard_1`.

`/app` is the domain's like any mount, so the session's programs see it
through the session's export, and a program in `/app/bin` is an
executable file that an `rx` mount reaches
([design-programs.md](design-programs.md#what-a-program-can-start)).
An app principal's code overlays live in memory only, as those of the
system configuration's specifications do
([design-live.md](design-live.md#the-code-store)), so the code an app
runs after a reboot is exactly its package's.

## Algorithms and behavior

### Admission

`erx_app_admit:admit(Header, Manifest, Registry)` is a pure function of
a header the file check accepted, the manifest as `erx_manifest` reads
it, and the boot's registry of app principals. It answers `{ok,
Admitted}`, the principal's entry (the name's existing one or a free
one, which it reserves nothing in), the indices of the facet rows kept
and the start row, or `{error, Reason}`, the first of these that fails:

1. the manifest has an `apps` row: `no_apps`;
2. the header's ABI version and architecture are the image's: `{abi,
   Have, Want}`, `{arch, Have, Want}`;
3. the name is an **app name**: a system identifier
   ([design-system.md](design-system.md#identifiers)) that stays one with
   `_` and the digits of the `names` quota appended, not of a pooled
   name's form, not `root`, and not the name of a principal, configured
   domain, service or facet row of the manifest, nor of a package of the
   image when the header is an installed one's. This is the whole of
   property 5's reservation rule, applied to the app's name:
   `{bad_name, N}` or `{name_taken, N}`;
4. a name the registry holds has the same signer, `{signer_changed, N}`;
   a new name finds a free entry, `apps_full`;
5. the memory is at least `app_memory_min` and at most the `apps`
   budget: `{memory, M}`;
6. each need is a service of the `apps` row: `{not_offered, S}`.

Nothing else is judged: a declaration can only name what the row
offers, so the build's proof over the row is the proof over the app.
Whether an app's session fits beside the others' is the kernel's to
judge when the session starts. The packer runs the same modules, the
file check and admission, on the host, under the stock OTP 29.1.2 the
build compiles with, over the packed manifest and each package file, so
one implementation decides at build and on the machine.

### Building and packing

`erx-app`, the SDK's packer, works on an **app directory**:

```text
DIR/app.txt            the declaration
DIR/lib/APP/src/       an application's sources, or lib/APP/ebin/ already built
DIR/lib/APP/priv/      its private files
DIR/bin/               native programs, built with the SDK
DIR/share/             data the app reads at /app/share
DIR/Makefile           optional: builds bin/ with the SDK's make variables
```

* `erx-app pack DIR [--key FILE]` compiles each `lib/APP/src` whose
  sources are newer than their output with the host's stock OTP 29.1.2
  `erlc`, `+deterministic`, against the SDK's public applications, and,
  when `DIR/Makefile` exists, runs `make` there with the SDK's variables.
  It then parses `app.txt`, checks that each application has its OTP
  application resource file, `lib/APP/ebin/APP.app`, or that the program
  exists and passes `erx_elf_plan` with the SDK's ABI version, writes the
  image from an mtree manifest with `fsimg`, computes the hash tree with
  a salt derived from the image's contents, writes the header with the
  SDK's ABI version and target, signs it with FILE's key or else the
  SDK's development key, writes `NAME.app` with its build record beside
  it, and runs the file check on what it wrote. It follows no link out
  of `DIR` and refuses any other kind of file. Packing runs the app's own
  build steps, its parse transforms and its makefile, on the host: pack
  only sources you trust.
* `erx-app test DIR` runs the app's EUnit and Common Test suites on the
  host with the SDK's public applications and `erx_ui_host` on the code
  path.

### Adding an app to an image

`tools/erx pack --app X [--enable NAME] [--signer FILE]` takes an app
directory, which it packs with the SDK the tree exports, or a package
file, which it takes as it is and builds nothing; a package from
someone else is added as a file, and needs no trust in its signer. For
each package the build:

1. places it in the slot's package image (the boot image's domain
   release on the stopgap);
2. adds a `package NAME` row with `input` naming it and `enable YES` when
   `--enable` names it, `NO` otherwise; the packer records the header's
   SHA-256 in the row, as it records an image's root hash;
3. runs the manifest check, property 19's file check, admission and
   memory clause included;
4. judges the package's license as it judges an archive's, so a package
   whose license is absent or not permissive enters only a local test
   image built to allow restricted inputs, never a production image or an
   image the website offers.

`--signer FILE` adds a `signer` row, so a deployer's machine trusts the
deployer's own key for packages installed later. The board's manifest
source is unchanged: the rows are the build's, recorded in the image's
build record with each package's SHA-256. `tools/erx app run DIR` builds
a development image with the app added and enabled, boots it under QEMU
with a display, and saves screendumps, as Doom's `run.rb boot` did.

### Starting an app

`erx_app`, an application of the `app` release, does nothing until the
ready answer brings the app's record. Then it:

1. mounts `/app` from the record ([An app's session](#an-apps-session));
2. for an Erlang app, adds each `/app/lib/*/ebin` at the end of the code
   path and starts each declared application with
   `application:ensure_all_started(App, permanent)`, its dependencies on
   the release's applications resolved from the release;
3. for a native app, starts its program with `erx_prog_handler:start/1`:
   with the spec's `window` option naming the session's default display
   when the app needs a `windows` service, so the handler opens the
   window and binds its `/dev/draw`, `/dev/kbd`, `/dev/mouse` and
   `/dev/wctl` ([design-programs.md](design-programs.md#the-handler),
   [design-display.md](design-display.md#the-window-tree)); without,
   with standard input null and its output to the session's log. Its
   namespace is the session's. The start answers `{ok, Handler, Monitor,
   []}`, and the monitor's `'DOWN'` is the program's end:
   `{shutdown, {program_exit, Status}}` ends `erx_app` with
   `{program_exit, Status}`, and any other reason, the handler's own
   end, ends it with that reason.

The app's paths come after the release's, so a module the app ships
under a name the release already uses is never the one the code server
finds first: a clash breaks only the app that brought it. Whether the
code server in the session's embedded mode resolves a module by path
order in this way, rather than refusing or replacing it, is unverified;
`erx_app`'s host test, run in the session's code-server mode, settles it.

`erx_app` is permanent, so its end, a declared application's end and a
program's end each end the session, and the start row's keeper starts it
again within its intensity. A native app draws with Plan 9's draw
protocol and flushes when its frame is done, so no frame shows half drawn,
and reads its keys from `/dev/kbd`.

### The package lifetime

A **lifetime** is one run of the package process, `erx_pkg`. It owns the
package set, the slots of the temporary files and the copies being
written. Its effects are carried out by two processes, each the one
taker of its kind of effect:

* `erx_pkg_io` takes every read, write, create, rename, deletion and
  checkpoint request on `packages`, and every `remove_app`, and sends
  each to the storage service itself;
* the start service takes every publication of the package set,
  `erx_starter:packages/2`.

Each request names the lifetime it is for, the `erx_pkg` pid. Each taker
takes one request at a time and finishes the one it has begun before it
takes another, and refuses with `eio`, doing nothing, a request whose
lifetime has ended, which it tells with `erlang:is_process_alive/1`,
since `erx_pkg`, `erx_pkg_io`, the start service and the `apps` tree's
file processes all run in the system domain's one runtime. A **copy
handle**, which the `apps` tree's file process for a copy holds, is the
pair of a lifetime and a slot, so its writes and its close are requests
of that lifetime, refused once it has ended.

So when a lifetime ends, by a crash or on purpose, nothing of it begins
again: the request `erx_pkg_io` is carrying out finishes, and every later
one of the ended lifetime is refused. The next lifetime starts with the
recovery ([Boot and recovery](#boot-and-recovery)), whose first request
`erx_pkg_io` takes only after that, so the recovery starts from a
directory no earlier lifetime changes again, deletes every temporary
file, and only then hands out slots. A slot is the lifetime's from the
create that took it until its close is decided, the file published or
deleted, or until the lifetime ends; the next lifetime counts no slot as
free until the recovery has deleted its file. At most `max` temporary
files therefore lie on the medium at any time, and a copy of an ended
lifetime answers `eio` at its next write or its close, with nothing
published.

`erx_pkg_io` is never restarted, since a restarted one could not know
whether a request of its predecessor was still on its way to the
storage service. The reset this costs is kept on purpose: restarting a
process does not withdraw a storage request it has already sent, so
after an abrupt end of `erx_pkg_io` only a boot's recovery starts from a
directory that nothing earlier still changes, while a restart of
`erx_pkg` alone needs no reset, since `erx_pkg_io` outlives it and takes
the recovery's requests after its predecessor's. It is a permanent child with no restarts in the start
service's application, which the system release holds permanent, so its
end ends the system domain and resets the machine, and the boot's
recovery, which no earlier lifetime precedes, is the one that follows.
It parses nothing but the storage service's answers, which `erx_file_remote`
checks, and every answer, an error and a down storage domain included,
is an answer it passes on, so its end is a bug of the system domain like
any other.

**A failed change ends the lifetime.** A request that fails while it
changes the directory, a rename, a deletion or a checkpoint, or a
temporary file's deletion, leaves a directory the package set may no
longer describe. The package process answers the request that caused it
with `eio` and ends its lifetime, so the next lifetime's recovery
reconciles the directory, the registry and the package set, and the
start service, which still holds the last set, starts no session of an
app that set dropped until the recovery publishes. A failed read or
write of a temporary file fails only its copy. Past its supervisor's
intensity the package process stays down: the `apps` tree answers every
request `eio`, and the start service keeps the last set it was given.

### Installing, updating and removing

A step is **durable** once the data partition's storage service has
answered a checkpoint on the durability facet requested after it: that
answer comes only when a completed checkpoint holds every write the
service acknowledged, the file's bytes and the directory's entries alike
([design-storage.md](design-storage.md#interfaces)). A rename or a
deletion is **visible** at once and whole: before the checkpoint after
it answers, a power cut may leave either the state before it or the one
after, each whole.

**Publishing.** The package process tells the start service which apps
exist with `erx_starter:packages(Lifetime, Set)`. The call answers once
the start service holds the set's rows and every session of an app the
set no longer holds, its row's keeper and a `onestart` one alike, has
ended. Since an app principal has no credentials, the start service's
keepers are its only starters (AP2 of
[design-apps.md](design-apps.md#invariants)), so once a set without an
app is answered, no session of that app runs or can start until a set
with it is published. A package's name changes, by a deletion or by a
rename over it, only between two publications that drop and restore its
app.

**Installing and updating** are one path, `cp clock.app /apps/`, whether
or not `/apps` holds `clock.app`:

| Step | Why it must exist |
| --- | --- |
| 1. the shell's `cp` creates `/apps/clock.app`, write-only and truncating, or a native `cp` opens the installed `clock.app` the same way with `lopen`; the `apps` tree accepts a name `NAME.app` with NAME an identifier that is not a name of the image's packages, and opens a fresh, empty temporary file in `packages/`, named `tmp.K` for the first of `max` slots that is free. An installed `clock.app` stays as it is, published and running | copies land on the same file system as their final name, so the rename is atomic; a temporary file has no name in `/apps`, so no other open can write it; an update changes nothing until it has passed |
| 2. `cp` writes the bytes; each write is a request of the copy's handle to `erx_pkg_io`, at most `pkg_bytes_max` bytes in all | |
| 3. `cp` closes the file, and the close waits for the steps below. The writing open has ended, so nothing writes the file from here on | the bytes checked are the bytes published |
| 4. the package process runs the file check on the temporary file, its length and its first `pkg_header_max` bytes, under the name `clock.app` and with `{signers, Keys}` | a copy cut short, run on, too large or misnamed never gets a published name; only a trusted signer's package runs |
| 5. it admits the header ([Admission](#admission)); a name the registry holds needs its signer | the authority check; signer continuity within a boot |
| 6. it makes the temporary file durable | the rename must never publish a name whose bytes are not on the medium |
| 7. when the name holds an admitted package, it publishes the package set without the app, which answers once the app's sessions have ended | no session runs while its package's name changes (PK7); the old package ran until the new one had passed every check |
| 8. it renames `tmp.K` to `clock.app`, over the old package if there is one, visible at once, and makes the directory durable | the one commit point: the name holds the old package or the new, whole; the close answers only after it is durable |
| 9. it registers the app's principal with its record, in the entry admission found | the record changes only with a committed package; the principal must exist before its row |
| 10. it publishes the package set with the app, and the close answers `ok`; the app's row enters the start table installed, with nothing of `rc.conf` applied and nothing started ([design-apps.md](design-apps.md#the-start-table)) | the start service learns of the app, or of its new package |

A refusal at steps 1 to 6 deletes the temporary file, frees the slot,
and the close answers the refusal's errno ([Interfaces](#interfaces)),
with the reason in the log; nothing was published, the registry is as it
was, and an installed package of the name goes on running. A failure at
step 7, 8 or 10, the publication, the rename or its checkpoint, answers
the close `eio` and ends the lifetime: the recovery then admits whichever
package `clock.app` holds, the new one if the rename reached the
directory and the old one or none if it did not, deletes the temporary
file, and publishes, so the app's row is installed again on the package the
name holds, stopped until its own `start`, and `cp`'s `EIO` means the outcome is the one `ls -l /apps`
and `/proc/packages` show. A power cut before the rename leaves what the
name held before, the old package or nothing, and a temporary file,
which the next recovery deletes; after the rename and before its
checkpoint, either what the name held before or the new package, each
whole; after the checkpoint, the new package, which the next recovery
admits. A session
that ends with a copy open has its open closed by the file service, and
the close takes the same steps: a file cut short fails the file check's
length and is deleted, so a half-copied file never gets a published name
and never replaces one.

Two copies of one name are two slots, and the package process decides
their closes in turn: each that passes replaces the package before it,
so the name holds the package of the last close decided. An update
stops the app: its sessions, the row's and a `onestart` one alike, end
at step 7, and at step 10 its row is installed on the new package and
starts nothing, whatever `rc.conf` says, until `service NAME start` or
`restart` runs it, or the next boot does. Its data and its `rc.conf`
settings stay as they were.

**Removing**, `rm /apps/clock.app`, reaches the `apps` tree as the
protocol's `unlinkat` of `clock.app`:

| Step | Why it must exist |
| --- | --- |
| 1. when the package is admitted, the package process publishes the package set without it | no session runs while its file goes |
| 2. it deletes `packages/clock.app`, visible at once, makes that durable, and the `unlinkat` answers `ok` | one durable deletion is the whole removal |

A failed deletion or checkpoint answers `eio` and ends the lifetime, and
the recovery admits the package again if its file is still there. A
power cut before the deletion's checkpoint leaves either the package,
which the next recovery admits again, or none; after it, none. The app's
directory stays ([Where an app's files lie](#where-an-apps-files-lie));
its principal keeps its entry until reboot. `rc.conf` lines naming the
app stay, are reported as naming no row, and apply again if the app is
installed again, as on FreeBSD. A refused package is removed the same
way, with no publication.

A removal reaches nothing but what belongs to an app (PK8). The
publication drops only the package's row; the deletion is inside the
package directory; a purge reaches only the app directories. No step
looks up domains by principal name, so even a name that slipped past the
app-name rule could not stop a configured domain or a person's session,
or delete a manifest principal's files.

### Boot and recovery

The package process starts with the start service. A lifetime begins
with the **recovery**, `erx_pkg_plan:recover/2`, whose first request
`erx_pkg_io` takes after every request of an earlier lifetime
([The package lifetime](#the-package-lifetime)). It registers the image's
packages from the manifest's `package` rows, reading each header through
the `packages` grant (from the release on the stopgap) and running the
file check with `{hash, H}`. Once the `packages` grant is in place, which
it waits for as the start table waits for `rc.conf`, it reads the
listing of `packages/` and acts on it:

1. `erx_pkg_io` reads at most `pkg_scan_max`, 1,024, entries, one bounded
   read at a time, and reports whether more remain. A valid directory
   holds at most `max` packages, `max` temporary files and `image/`,
   which property 19 keeps well under the bound;
2. when the directory holds more, the recovery acts on nothing in it: no
   installed package is admitted, every create and remove in `/apps`
   answers `eio`, and `/proc/packages` shows `scan` as `overflow` with
   the count read. Image packages are unaffected;
3. otherwise, each temporary file `tmp.K` is deleted, and each
   `NAME.app` whose NAME is an app name gets its length and its first
   `pkg_header_max` bytes read, the file check with `{signers, Keys}` and
   admission, in name order, and the registration of each admitted
   package; a package refused stays on the medium, listed in `/apps` and
   shown `refused` with its reason at `/proc/packages`, and its refusal
   is logged;
4. an entry of no recognized form, or whose name is not an app name, is
   left as it is, with a log line. No entry's name becomes an atom:
   names stay binaries until a registration, which takes one of the
   `max` entries;
5. the package process publishes the package set. The first set of a
   boot is the boot's package set, whose rows the start service's boot
   applies `rc.conf` to as it applies it to the manifest's rows; a later
   recovery's set, after a crash or a failed change, adds the rows it
   adds installed, and ends the sessions of each row it drops.

The recovery's publication is its lifetime's first, and the package
process takes no close, removal or purge until it is answered, so the
first set of a boot holds what the image and the data partition held at
boot and nothing an install of that boot added.

The recovery reads at most `pkg_scan_max` names and headers of at most
64 KiB each, one at a time, and keeps one record for each entry it
admits or refuses, whatever the directory holds (PK9). Boot, a crash of
the package process and a failed change all reach the directory through
this one path.

### The start table's rows

The start table's rows are the manifest's `start` rows, in its order,
then the start rows of the admitted packages, in name order: an image
package's with its `package` row's `enable` as its default, an installed
package's with `NO`. `rc.conf` sets them as it sets any row
([design-apps.md](design-apps.md#the-start-table)). The merge's `Grants`
argument gives, for each row's principal, the `windows` services its
sessions will hold: a manifest principal's template's, and for an app
the `windows` services its admission kept, never the whole of the `apps`
row. So the merge refuses a display an app did not name with
`{no_grant, D}` and a display a kept row holds, whether the setting
came from `service NAME enable display=D` or from an edit of
`/etc/rc.conf`; at boot an installed app never takes a display from a
row of the manifest or of the image, whose rows come first, and at run
time it takes none that a kept row holds. The boot's package set is
applied with the boot: `rc.conf` sets its rows as it sets the
manifest's, and the rows the file enables start
([design-apps.md](design-apps.md#the-start-table)). Any later
publication changes only the rows it adds and drops, and applies
nothing of `rc.conf`: it adds each row installed, as its package
declares it, starting nothing, and ends the sessions of each row it
drops; every other row stays as it was applied. An installed row takes
its settings from the file at its own `service NAME start`, `restart`
or `one` command, or at the next boot.

## The SDK

`tools/erx sdk export DIR` writes the SDK from a built tree:

| Part | Holds |
| --- | --- |
| `SDK.txt` | the erXos commit, `ERX_ABI_VERSION`, the target architecture, the OTP release (29.1.2), the minimum LLVM, `fsimg`'s version |
| `sysroot/<arch>/include` | musl's headers as erXos ships them; the draw protocol's message layouts, generated from `abi/formats/draw.txt` |
| `sysroot/<arch>/lib` | `libc.a`; `liberx_program.a`, liberx's program layer and entry, prebuilt; the compiler's builtins; the program link script |
| `share/erxos/sdk.mk` | make variables: the compiler and flags erXos's own programs build with, and the link line |
| `share/erxos/development.key` | the development signing key, with which the packer signs by default and which only development builds trust |
| `erlang/` | the public Erlang applications as `.app`, `.beam` and `include/` files, `public.txt`, the list of public functions as `Module:Function/Arity`, and `erx_ui_host` |
| `host/bin/` | `erx-app`, the packer, and `fsimg`; `erx-lvgl` built for the host, for `erx_ui_host` |

**What is public, and what a package's compatibility key covers.**
Admission refuses a package whose `ERX_ABI_VERSION` or target
architecture differs from the image's, and so does the loader's ELF
check for a program
([design-programs.md](design-programs.md#what-a-program-can-start)).
`ERX_ABI_VERSION` is the version of the kernel interface and of every
fixed layout in `abi/` ([design.md](design.md#formats)), which covers a
package's native side: the C library seam under the POSIX-lite
personality, the draw protocol and the package format. It does not move
with the public Erlang functions or the widget schema. Until a release
promises compatibility, nothing below owes anything to its earlier forms,
so a package built against an earlier SDK whose Erlang calls changed is
admitted and fails when it runs: its session ends with the reason (an
`undef`, the widget validator's refusal), its row goes down within its
intensity, and `/proc/apps` shows why. A release that promises
compatibility gives the public Erlang surface a version of its own in the
header.

| Public | Not public |
| --- | --- |
| the POSIX-lite personality, musl's functions as [design-programs.md](design-programs.md#the-posix-lite-personality) defines them | liberx's kernel calls and every `erx_*` C function |
| a program's `main`, its standard descriptors, and a program that draws: `/dev/draw` with the draw protocol, `/dev/kbd`, `/dev/mouse`, `/dev/wctl` | the channel, the program protocol and the startup message |
| `app.txt`'s grammar and the package format | the boot image, the manifest and its rows |
| Erlang: `erx_ui:open/1`, `tree/2` and `close/1`, its messages and the widget schema of `abi/formats/ui.txt`; `erx_win` and `erx_draw`'s exported functions, for an app that draws itself; `erx_prog_handler:start/1`; stock OTP 29.1.2 | every other function of erXos, `erx_ui:start/1` and the modules `erx_ui_lvgl` and `erx_ui_model` among them |

**Erlang's host test entry.** `erx_ui_host` stands in for a display on
the host, under stock OTP 29.1.2:

* `erx_ui_host:start(#{width := W, height := H, renderer => erlang | lvgl})`
  answers `{ok, Host}`; while it runs, `erx_ui:open/1` in that node opens
  its window there, as on the default display;
* `erx_ui_host:frame(Host)` answers the last presented frame as `{ok, W, H,
  Pixels}`, `x8r8g8b8` rows from the top, or `none`;
* `erx_ui_host:input(Host, Event)` delivers one of the `input` forms of
  `abi/formats/ui.txt`: `{pointer, X, Y, Buttons}`, `{key, Down, Code,
  Rune}` or `{wheel, Steps}`;
* `erx_ui_host:stop(Host)`.

The widget server, the schema, the diff and the renderer are those the
session runs; only the window is a stand-in, a buffer in memory whose
presents record the frame, so a frame the Erlang renderer or `erx-lvgl`
draws on the host is the frame it draws on the board. No release lists
`erx_ui_host`, so no image carries it.

**Where the toolkit's programs live.** `erx-lvgl` is part of the widget
toolkit: `erx_ui_lvgl` and it agree on the binary form of
`abi/formats/ui.txt`, which one build generates for both, and its code
pages are shared by every session that runs it. It lies in the domain
release's `bin/` of every image whose release holds `erx_ui`, a
production image's included, and no package carries it. A package that
wants a renderer of its own ships it as its own program.

## Examples

`examples/` holds app directories that no list of erXos's names: no
release script, application list, manifest or test list. Each is built
only as a third party would build it, through the SDK.

* **`examples/dashboard/`**, the kiosk dashboard, erXos's own code under
  its license: `app.txt`, `lib/erx_dashboard/` and its host test, which
  checks a frame through `erx_ui_host` against
  `test/display/reference/dashboard`.
* **`examples/doom/`**, the Doom demo, structured as a separate app:
  `ORIGIN.md` beside `doom/`, a git submodule pinned by its gitlink, as
  `display/lvgl/lvgl` is ([design.md](design.md#dependencies)). The
  submodule's repository holds doomgeneric, under GPL-2.0, the erXos
  glue, its `app.txt` and a `Makefile` over the SDK's `sdk.mk`, and a
  list of pinned downloads in `deps.lock`'s form, for Freedoom's WAD.
  erXos's tree holds only the gitlink, a commit id, so no GPL code
  enters the tree. `git clone` does not check it out, and `tools/erx
  fetch` fetches it, and its downloads against their SHA-256, only with
  `--example doom`; no part of `make check`, the landing gate or the
  milestone gate builds it; `tools/erx app run examples/doom/doom` runs
  it on request. It never ships: its license keeps it out of every image
  erXos distributes (step 4 of [Adding an app to an
  image](#adding-an-app-to-an-image)). Nothing erXos builds, tests or
  distributes depends on it, so the dependency table has no row for it.
  No erXos code includes or links it, so working on erXos never needs
  reading it.

To the packer both are app directories with an `app.txt`, as is a
third party's anywhere on disk. The landing gate exports the SDK, packs
and host-tests `examples/dashboard` with nothing but the SDK on its
paths, and checks that every call the example makes into erXos's
modules is one of `public.txt`'s functions, so a change that breaks the
boundary fails there.

## Interfaces

An administrator installs, updates, lists and removes apps with the
shell's own `cp`, `ls`, `cat` and `rm` in `/apps`, looks inside one with
`mount` and `unmount`, enables, disables and purges them with `service`,
and reads their state with `cat` under `/proc/packages`; there is no
command of packaging's own. `/proc` is read-only, as all of it is
([design.md](design.md#decisions), "System values are one read-only
tree"): it shows what an app's state is, and takes no command.

**`/apps`**, the `apps` tree ([`/apps`](#apps)), as the shell sees it:

| Operation | Result |
| --- | --- |
| `cp NAME.app /apps/` | installs, or updates the installed app of the name, whether `cp` creates the name (`lcreate`), as the shell's does, or opens the installed package write-only and truncating (`lopen`), as a native FreeBSD `cp` does. Errnos at the create or the open: `einval` for a name not of the form `NAME.app` with NAME an identifier, or an open that appends, also reads or, at an `lopen`, does not truncate; `eio` at an `lopen` of a node whose name holds another package since its walk, or none; `eexist` for a name of the image, or an exclusive create of a name `/apps` holds; `enospc` while `max` copies are open; `eagain` while the `packages` grant is not in place; `eio` while the directory is past the scan bound. A write past `pkg_bytes_max`, 1 GiB, answers `efbig`. Errnos at the close: `efbig` for a file past the size bound; `einval` for a file the file check refuses for its header, its length or its name, or whose name is not an app name; `eacces` for a header that names no trusted signer or carries a bad signature; `eperm` for an admission refused by `no_apps`, ABI, architecture, memory or need; `eexist` for a name of the manifest, or one another signer holds in this boot; `enospc` for no free entry; `eio` for a failed read, write, publication, rename or checkpoint of `packages`, or a lifetime that ended. After every refusal the installed package of the name, if any, is published and running as before |
| `rm /apps/NAME.app` | removes the installed package and answers `ok`; `enoent` for no package of the name; `erofs` in `/apps/system`; `eio` for a failed deletion or checkpoint, a directory past the scan bound, or a lifetime that ended |
| `ls /apps`, `ls /apps/system` | every package, installed or of the image, admitted or refused, each a regular file |
| `cat`, `cp` from `/apps/NAME.app` | the package's bytes; `eio` for a header changed on the medium since its check, or once the name holds another package or none since the open |
| `mount /apps/NAME.app DIR`, `unmount DIR` | mounts the package's image read-only at `DIR`, and ends the mount; the mount is refused with the reader's answer for a header that does not decode or an image the reader refuses, and `eio` for a header the tree refuses; below `DIR`, `eio` for a block that fails its hash, or once the package is removed or replaced, and `enotsup` for an inode of a layout the reader lacks |

The reason of every refusal goes to the log. Who holds `start`, and so
`apps`, is the manifest's ([design-apps.md](design-apps.md#interfaces)).

**The `apps` tree**, in the system domain, takes `lcreate`, `lopen`, `write`,
`clunk`, `read`, `getattr`, `readdir` and `unlinkat` as [`/apps`](#apps)
says, with the same errnos. Its `clunk` answers the copy's verdict,
which the file service passes back to the client once the file's owner
has run it
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).

**The start service** gains `erx_starter:packages/2`, by which the
package process publishes the package set; it answers once every session
of an app the set drops has ended, and refuses a publication whose
lifetime has ended. It is a call of the package process alone. Its `ctl`,
at `/etc/start/ctl`, takes `purge NAME`, which `service NAME purge`
writes; its errnos are `einval` for a name that is not an app name,
`ebusy` for a name installed now or of the image, and `eio` for a failed
`remove_app` ([design-apps.md](design-apps.md#interfaces)).

**Inspection**, in `abi/inspection.txt`, reported by the package process
and shown at `/proc/packages` to an inspect facet of scope `all`:
`[packages]`, of kind `packages`, gives `scan` (`ok` or `overflow`, with
the entries read), `room`, the `apps` budget left as the kernel reports
it, and lists the packages by name; `[packages, Name]` gives `version`,
`memory`, `place` (`system` or `installed`), `signer` (a `signer` row's
name, `development`, `image`, or `unchecked` where Phase 1 checks none),
`state` (`admitted` or `refused`), `reason`, `needs` and `license`. An
app's start row, with whether it is enabled, is at `[apps, Name]` and
its sessions at `[domains, Id]`, as any row's and any session's.

**Manifest rows**: `apps`, as in [The `apps` row](#the-apps-row);
`package`, with `input` naming the package's artifact and `enable`,
whose header hash the packer records; `signer`, with `key`. Their
packed records and the readers' bounds are in `abi/manifest.txt`; the
facet parameter `tree` is in the storage service's schema.

**The ABI source**: `abi/formats/package.txt`, the header and the packed
declaration; the limits `apps_max_limit`, `app_memory_default`,
`app_memory_min`, `pkg_header_max`, `pkg_needs_max`, `pkg_args_max`,
`pkg_bytes_max` and `pkg_scan_max`.

**Erlang**: `erx_pkg_header:check_file/2` and `layout/1`,
`erx_app_admit:admit/3`, `erx_pkg_plan:install/3`, `remove/2` and
`recover/2`, `erx_principal:register_app/2`; in a session, `erx_app`,
and `erx_ns:mount/3` with an image `{file, Path, Layout}`, `Layout` an
authenticated layout or `header`.

### Other subsystems

| Subsystem | Its part |
| --- | --- |
| the manifest check ([design-system.md](design-system.md#the-manifest)) | the `apps`, `package` and `signer` rows and the rows derived from `apps`; property 19; A10 holds, since an app selects among rows the manifest set |
| the root task and the resource policy | the `apps` budget carved from the root at boot as a wall, the apps group under `users`; app principals' elastic budgets under it, with no guarantee and the `apps` budget's guarantee as cap |
| the domain library | the principal table sized for the manifest's principals and `max` apps; `erx_dom_principal` carving an app principal's elastic budget under the `apps` budget; `erx_dom_plan_session` taking an app principal with the app template |
| the domain service | the app's session: the kept rows, and the app's record, with its package's place and layout, in the ready answer |
| the principal service | `register_app/2`, called at a committed install or update and at recovery; no app principal is unregistered within a boot |
| the start service ([design-apps.md](design-apps.md#the-start-table)) | its tree at `/etc/start`, holding `ctl`; the package rows after the manifest's; `packages/2`, answered once the dropped apps' sessions have ended and refused for an ended lifetime; the merge's grants for an app from its admission; `purge` in its `ctl` |
| the file service ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)) | a tree's `clunk` answers `ok` or `{error, Errno}`, and `erx_fs` answers the client's clunk with it once the file's owner has run it, after every request sent before it; the fid ends whatever the answer, as clunk(5) says; the `apps` facet mounted at `/apps` as any facet with a mount point; a session's export naming each local provider's tree when it is mounted ([design-files.md](design-files.md#narrowing-for-a-program)) |
| the shell ([design-shell.md](design-shell.md#commands)) | `cp` opens its target itself, copies in pieces as its info report needs, and reports a failed close of the target as it reports a failed write; `mount FILE DIR`, the EROFS mount of a package file with the layout of its own header; `service NAME purge` |
| the storage service ([design-storage.md](design-storage.md#interfaces)) | the `packages` tree: the data partition's directory and the slot's package image read-only; `apps/` and `tree apps`, rooted at `apps/NAME/SIGNER/`; `remove_app` on the durability facet |
| the EROFS reader | `erx_verity` reading an image from one open file at an offset, with a layout given, for `/app`, or with the layout of the header read through the same open, for the shell's `mount`, as well as from a block window |
| programs ([design-programs.md](design-programs.md)) | an executable file from `/app/bin`; `open` through the handler; `erx_prog_handler:start/1` with a window |
| the display ([design-display.md](design-display.md#the-window-tree)) | a program started with a window; `erx-lvgl` in every image whose release holds `erx_ui` |
| live code ([design-live.md](design-live.md#the-code-store)) | an app principal's overlays live in memory only |

## Concurrency

The package process, `erx_pkg`, a process of the start service's
application, owns the package set: each package's name, header hash,
layout, admission and state. It takes one close, removal or purge at a
time, in the order they arrive, so two copies of one name closed
together are decided in turn, and the later one, if it passes, replaces
the earlier. It
does no file operation itself: every request on `packages` and every
`remove_app` runs, one at a time, in `erx_pkg_io`, which answers each
request when it is done, so a slow storage domain delays a close, a
removal or a read of `/apps`, not the package set's answers or the
start table. The `apps` tree's file owner for a copy waits for the
package process's answer before it answers the close, as any tree's
owner runs a file's requests in turn
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
The package process waits for the start table at each publication, and
the table never waits for the package process, so the two never wait
on each other: a purge is awaited by the start service's `ctl` file
owner, not by the table, and the package process takes it in turn with
its closes and removals, after the publication of the one it is
carrying out ([design-apps.md](design-apps.md#concurrency)).

A lifetime's effects are taken only while it is alive, by `erx_pkg_io`
and the start service, each one at a time
([The package lifetime](#the-package-lifetime)). A crash of the package
process ends no session: the next lifetime's recovery rebuilds the set
from the manifest and the directory and publishes it, and until then the
start service keeps the last set it took. A crash between a publication
without an app and its deletion, or the rename of its update, leaves the
app stopped; the recovery's publication brings its row back installed,
on whichever package its name then holds, and its own `start` runs it.
A crash of the start service's table process loses nothing the package
process holds: on its restart it asks the package process for the set
with a message and waits for no answer; the package process answers by
publishing its set, in turn with its closes, removals and purges, and
the table applies `rc.conf` only to a row of the boot's package set that
it holds no record for, and records any other such row installed
([design-apps.md](design-apps.md#concurrency)).
The registry of app principals belongs to the
principal service and only grows within a boot, and the package process
writes a record only for a committed package, so a crash leaves no
record of a package that was never committed.

A mount of a package is an entry of the session's namespace like any
other, changed only by `erx_ns`'s process
([design-files.md](design-files.md#building-binding-and-mounting)): it
holds its one open of the package from `mount` until `unmount` or the
session's end, and every process of the session that reads below its
point reads through that open, in its own process, as every EROFS mount
is read. Nothing in the system domain follows mounts.

## Compatibility and migration

The package format, `app.txt`'s grammar and the `apps`, `package` and
`signer` rows owe nothing to earlier forms
([design.md](design.md#decisions), "No backward compatibility in
development"). A package built for another `ERX_ABI_VERSION` or another
architecture, after a system update or before it, is refused with `{abi,
Have, Want}` or `{arch, Have, Want}` and shown so; it stays on the
medium until the administrator removes it and copies in a rebuilt one.
A package whose need an update's `apps` row no longer offers is refused
with `{not_offered, S}`, and its data stays.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | What happens |
| --- | --- | --- |
| a file fails the file check: its size, header, length, name or signer, or its hash differs from its `package` row | `erx_pkg_header:check_file/2`, the package process | a copy's close answers its errno and nothing is published, and an installed package of the name goes on running; a package found on the medium is `refused` with the reason at `/proc/packages`; an image package refused at boot leaves its row out of the table |
| admission refuses | `erx_app_admit:admit/3` | as above, with the reason |
| an app's session does not fit what is left of the `apps` budget | the kernel's carve, through the domain library | the start answers `no_memory` naming the `apps` budget; the keeper counts an end, and the row goes down past its intensity, with the reason at `/proc/apps` |
| a block of the image fails its hash | `erx_verity` in the reading session | the read answers `eio` with a log line naming the image and block; in the app's session the code load or file read fails, the session ends, and the row counts an end, with the reason at `/proc/apps`; at a mount of a package the `ls` or `cat` fails |
| a header changed on the medium after the file check | the `apps` tree's hash check | reads of the header answer `eio`, so a `mount` of it is refused; the app's own session holds the layout from the record and fails at its first block |
| the image does not mount | `erx_app`, the shell's `mount` | the app's session ends at its start with the reader's reason; `mount` answers the reader's refusal and changes no namespace |
| an inode of a layout the reader lacks, compressed or chunked | `erx_erofs` in the reading session | that file answers `enotsup` where it is reached; in the app's session as any failed load or read |
| a package removed or replaced under an open or a mount | the `apps` tree, by the open's recorded package | reads answer `eio` until the file is closed or the mount ended; a new open or mount reaches the new package |
| a missing application or a refused program | `erx_app` | `erx_app` ends with the application's start error or `{program, Reason}`, and the session with it |
| the storage domain is down at boot | the package process's read through `packages` | the image's packages wait for it, as do the installed ones; their rows are absent until the recovery runs; on the stopgap the image's packages, in the release, do not wait |
| a failed publication, rename, deletion or checkpoint | `erx_pkg_io`'s or the start service's answer | the request answers `eio`, the lifetime ends, and the recovery reconciles the directory, the registry and the set; an app stopped for an update is installed again on the package its name holds, stopped until its own `start` |
| a crash of the package process | its supervisor | open copies answer `eio` at their next write or close and publish nothing; the recovery deletes their temporary files and publishes the set; past the supervisor's intensity the package process stays down and `/apps` answers `eio` |
| an end of `erx_pkg_io` | the start service's application | the system domain ends and the machine resets; the boot's recovery follows |
| a power cut inside an install, an update or a removal | the recovery | temporary files are deleted; each name holds one package whole, the old or the new, or none |
| the package directory holds more than the scan bound | the recovery | no installed package is admitted; `scan` is `overflow` at `/proc/packages`; creates and removals in `/apps` answer `eio` |
| no free entry | admission | `apps_full`, until a reboot frees the entries of removed apps |

Every state above is an attribute at `/proc/packages` or `/proc/apps`,
or an errno and a log line naming the package and the reason. Nothing is
shown as admitted that the package process did not admit.

## Security

**What is trusted.** The manifest, with its `apps` row, `package` rows,
`signer` rows and the image's package hashes, as part of the boot image;
the package process, `erx_pkg_io`, the principal service, the start
service and the domain service, in the system domain; the small Ed25519
verifier; each session's own runtime, for that session alone.

**What is not.** Every package byte, header and declaration; the copied
bytes; every entry of the package directory; the data partition and the
storage domain; an app's code; an app directory on the build host.

* **The system domain reads a header, never an image.** The header is at
  most 64 KiB, read through a generated reader with a fuzz target over the
  whole file check, locating the declaration, key and signature in bytes
  an attacker wrote, truncated at each field and with every length out
  of bounds. The image is parsed only by a session, the app's own or a
  person's that mounted it, whose failure is its own: a crafted image
  fails reads at the EROFS reader's checks, and a directory it lists,
  which the reader reads whole, costs the listing process memory within
  the package's size and that process's heap limit, never anything of the
  system domain.
* **A package cannot widen its authority**: the grammar names services,
  admission keeps only the row's, the build counted the row at its worst
  (PK1, PK2). What the administrator approves by copying is which of the
  row's services the app takes and how much of its budget, with no
  prompt. Every app may take every service the row offers; a builder who
  wants a service for some apps only gives the machine no row for it, or
  signs only the apps that may have it.
* **Who installs.** Only a session whose template holds `start` holds
  `apps`, so only it has `/apps` and can copy into it, update or remove
  there, or purge; the manifest grants `start` to `root`'s template in a
  development build and to an administrator's in a release build.
* **Memory between apps.** All apps share the `apps` budget, so one app
  installed with a large `memory` leaves less for the others, and the
  kernel refuses a session that does not fit. No app can take memory from
  the board's own principals or domains: the `apps` budget is carved and
  counted like a principal's, and each session is walled once it runs.
* **A hostile app** can spend its own memory and CPU, fill its
  directory, use its grants within their limits, end, and read the bytes
  of other packages through `packages`. It cannot write a package,
  install one, reach another app's directory or domains, or change the
  start table.
* **Code against a crafted data partition, or a storage domain it took
  over.** It can withhold or delete packages, put back an older package
  of the same signer, and swap an installed package for another package
  of the same name and signer. It cannot run code no trusted signer
  signed, change a byte of an image any session reads, widen a grant,
  start an app with no start row, steer a purge at anything that is not
  an app (PK8), or make the recovery spend past its bound (PK9). Refusing
  an older package needs a counter the platform's trust root keeps, as
  for system updates
  ([design-storage.md](design-storage.md#system-updates)).
* **Data rests on the storage service enforcing its grants.** Apps'
  data is mutable and nothing authenticates it: the separation between
  two apps' directories, and between two signers' apps of one name, is
  the storage service rooting each grant at its own directory (PK4). A
  storage domain that is taken over reads and writes every app's data,
  can copy one app's files into another's directory, and can hand an
  app another's bytes through its correctly rooted grant. Keeping data
  apart from such a storage domain would need encryption under keys it
  never holds, which this design does not attempt; code stays protected
  against it by the hash tree, as the bullet above says.
* **The bytes checked are the bytes published.** The file check runs at
  the close, when the writing open has ended, on a temporary file that no
  open can reach by name, so the administrator's session cannot change
  the bytes between the check and the rename. A storage domain that
  changed them could change only bytes the hash tree then refuses, since
  every session's root hash is one the package process authenticated.
* **Data and signers.** An app's directory is named for its name and its
  signer, so through a storage service that enforces its grants a second
  trusted signer's app of a name never finds the first's data, after a
  reboot or within a boot; within a boot the
  principal's entry also keeps its signer, and admission refuses another
  with `signer_changed`. Signer continuity costs no record: the
  directory's name is the record.
* **Development builds** trust the SDK's development key, which every
  developer has; they run trusted code only, and say so in their banner.
  A release build trusts only its `signer` rows.
* **An app's durable code is its package**: its principal's overlays stay
  in memory, so a storage domain cannot make an app run code its signer
  did not sign.
* **The atoms an app costs the system domain** are its name, at its
  registration in one of `max` entries, and its pooled session names
  within its `names` quota; an entry is freed only at reboot, and the
  recovery makes no atom of a directory entry (PK9).
* **The build host.** Packing an app runs its compile steps, its parse
  transforms and its makefile, so an image builder packs only sources
  they trust and adds anyone else's app as a package file, which builds
  nothing. The packer follows no link out of an app directory and writes
  no host metadata into an image. Diagnostics quote a declaration's bytes
  through the host terminal's escaper.
* **Text from a package.** A package's name, version and license, and
  the names inside its image that `ls` shows at a mount of it, reach
  `/proc/packages`, the log, a terminal and the host through each sink's
  escaping function, as all text attributed to a source does
  ([design-live.md](design-live.md#attributed-text)).
* **Licenses.** A package's license is judged where an archive's is, so
  a copyleft package, or one that names no license, reaches only a local
  test image (PK-R9).

## Phase 1

Phase 1 runs trusted code, and a development build says so in its
banner. It builds this design against its target interfaces and defers
what rests on parts that arrive later, reporting each as it is:

| Deferred | Until | Meanwhile |
| --- | --- | --- |
| isolation between apps' domains, and budgets and quotas as limits | erXos's kernel | as for every domain ([design-apps.md](design-apps.md#phase-1)) |
| the hash check in `erx_verity` | the security closure, M11 ([plan.md](plan.md#m11-security-closure)) | `erx_verity` passes blocks through unchecked, as for every image, so a byte changed on the medium is read as it is; PK3's QEMU test waits for M11 |
| rooting `data` grants by principal, `apps/`, `tree apps` and the signer in an app's directory | principals' directories (M10) | apps can reach each other's directories, the residual design-apps.md records; the directory half of PK4's test waits, its `/proc` half runs |
| `purge` with `remove_app` | the same | `service NAME purge` answers `enotsup` |
| the image builder's packages on the system slot | the storage service serving a slot's image | they lie in the boot image's domain release, readable by every domain, enlarging the boot image and the memory it holds; a large one needs a larger root place on the stopgap |
| checking an installed package's signature | the small verifier in the build ([plan.md](plan.md#m11-security-closure)) | a development build installs packages whose signature it cannot check and shows them `unchecked`; a release build installs none |

## Verification and testing

Each test is paired with the seeded fault that proves it runs the code
it guards.

**Host tests.**

| Test | Passing case | Seeded fault |
| --- | --- | --- |
| the declaration's parser (Ruby, in the packer) | the two examples above pack to their expected records, the three-line one with every default; a declaration with both `applications` and `program`, and one with neither, refused; each bound of the table refuses one past it, naming the line | the bound on `needs` removed, which packs seventeen needs |
| the file check, `erx_pkg_header:check_file/2` | a package signed by a trusted key accepted, and refused: one of an untrusted key, a flipped signature byte, a header cut at each field, lengths that overflow, a file one byte short and one byte long, a file past `pkg_bytes_max`, and a file named for another app; under `{hash, H}`, a package signed by an unknown key and matching H accepted, and one byte off refused | a check that skips the signature, which accepts the flipped byte; one that reads the signer under `{hash, H}`, which refuses the unknown key; the length check made "at least", which accepts the long file |
| the file check at the close and at recovery | each refused file of the row above, copied in, fails its close with nothing published and the temporary file gone; placed on the simulated medium, it is `refused` by the recovery | a recovery that admits without the file check, which admits the misnamed and the short file |
| admission, one corpus run by the machine's module and by the packer's host run | each refusal of [Admission](#admission) and its accepting neighbour, the names `root`, `root_1`, a configured domain's and a service's among the refused | the subset test of step 6 dropped, which admits a need the row lacks; `root` dropped from the reserved names |
| the install, update, removal and recovery planners | a simulated directory records every write, cuts power after each and reorders the writes between checkpoints, as [design-storage.md](design-storage.md#read-write-storage)'s harness does, and separately answers `eio` to each publication, rename, deletion, checkpoint, read and write in turn; every resulting state recovers with each name holding one package whole, the old or the new, or none, no temporary file, a package set that matches the directory, and no session of a dropped app started between the failure and the recovery's publication | an install that renames before the temporary file is durable, after which a reordered cut leaves a published name with missing bytes; an update that deletes the old package before its rename, after which a cut between the two leaves no package; a removal whose failed deletion answers `eio` without ending the lifetime, after which the set and the directory disagree |
| the package lifetime | two copies writing and a third closed and waiting on a simulated storage that delays each request; the package process killed: both writers and the waiting close answer `eio`, the simulated storage's log holds no request of the ended lifetime after the recovery's listing, the recovery deletes the three temporary files before the first slot of the new lifetime is handed out, and a copy after the recovery installs | an `erx_pkg_io` that takes a request without checking its lifetime, after which the waiting close's rename lands after the listing; a slot freed at the crash, before the recovery's deletion, after which a fourth copy takes a slot whose file is still on the medium |
| the principal's record | an install refused at its file check, at admission and at its checkpoint, after an earlier install and removal of the name in the boot with another `memory`, and an update over a running app refused at the same three points: the record keeps the earlier memory | a registration before the rename is durable, which writes the refused memory |
| an update of a running app | a copy over an installed, running app refused at its file check: the old package stays published and its session never ends; a copy that passes, with `rc.conf` enabling the app: the session ends before the rename, the row is `installed` after the publication with the new layout in its record and no session, and `service NAME restart` starts one with the new layout | an update that renames before it publishes the set without the app, which the test catches with the old session alive across the rename; a publication that applies `rc.conf` to the row it adds, which starts the new session at the update |
| purge targets | `purge` of `root`, a configured domain, a manifest principal, an image package's name and an installed app refused, with no `remove_app` | the app-name rule skipped, which sends `remove_app root` |
| the recovery's bounds | a listing of `pkg_scan_max` + 1 entries gives `overflow` and no admission | the bound check removed, which reads the whole listing |
| a publication that drops an app | the app's keeper and `onestart` session end before `packages/2` answers; `service NAME start` is refused until a set with the app arrives; a publication from an ended lifetime is refused | a publication answered before the sessions end, which the test catches with a session still alive |
| the start table's grants for an app | an `rc.conf` line naming a display of the row the app did not need is refused `{no_grant, D}` | the merge given the app template's whole grant set, which accepts it |
| the app session's plan in `erx_domain_core` | the session's rows are `packages` and the rows its needs name; every minted scope names the app's principal; the session's memory is the declared one; one header admitted as an image package and as an installed one gives the same plan (PK10) | a plan that grants every row of the template; a scope computed from the template's key; a plan that grants an image package the template's whole row set, which the comparison catches |
| the storage mint's root for an app | one name under two signers and as an image package gives three roots, `apps/N/<hex>`, `apps/N/<hex2>` and `apps/N/image` | a root of the name alone, which gives one |
| the `apps` tree's header reads | a header read answers the authenticated bytes; the same header changed on the simulated medium after the check answers `eio` | the hash check removed, which serves the changed header |
| the `apps` tree's names and identity, through the real client | `cp` installs a new name and updates an installed one, and its close's errno reaches `cp`; a write-only, truncating `lopen` of an installed package, as a native `cp` sends it, takes a slot of its own, two such opens at once two slots, and its close publishes the new package or answers the same errno as a create's copy of the same bytes, the old package published and running after a refusal; an `lopen` without truncation, and one of a node replaced since its walk, answer `einval` and `eio` with the installed package unchanged; `rm` sends one `unlinkat`; a create of `ctl`, an appending open and a read-write open answer `einval`; creates and removes in `system/` answer `erofs`; an open held across an update, and one held across a removal and a reinstall of the same image, answer `eio`, and a new open of the name has a qid path that neither earlier package had, also after a restart of the package process between them | an `lopen` passed to the default open, which truncates the installed package in place and fails the old app's next read; a check of the node's name alone, which opens a replaced node; a qid path drawn from the name, which gives the reinstalled package its predecessor's path; a counter of the tree's own, which the restart resets; a read that reopens the name, which serves the new package to the old open |
| the shell's `mount` over a fixture `apps` tree | the mount lists the image at `DIR` and reads a file as the image holds it; after the package is replaced, reads at `DIR` answer `eio`, and a second mount reads the new package; a mount of a package whose header the tree answers `eio` is refused and the namespace is unchanged | a mount that reads the header and the image through two opens, which a fixture that replaces the package between them catches with old layout over new bytes |
| the session's export across a mount and a remount | a program holds a file of a mount open; the point is unmounted and mounted with another image whose inode numbers repeat; a second program's open of the same path gets a file-table entry of its own and the new bytes | an export that names a tree by its mount point, which joins the second open to the first's entry |
| `erx_app` over a fixture `/app` | the declared applications start; a fixture app that ships a module of the release's name leaves the release's module loaded, and only the app fails | the app's paths added at the front of the code path, which loads the app's module |
| entries | `max` + 1 distinct names installed and removed in one boot, the last refused with `apps_full`; a name installed again takes its entry again | a removal that frees the entry |
| the build's check | each clause of property 19 | each seeded violation of [The build's check](#the-builds-check) |
| `examples/dashboard` through the SDK | its frame through `erx_ui_host` matches its reference, and a click on Pause changes only the status line and buttons | a status line one pixel taller |
| the SDK's boundary | the example compiles, and xref finds every call it makes into erXos's modules in `public.txt`, by module, function and arity | the example calling `erx_ui:start/1`, exported by a public module but not public, which the check refuses |
| no list names an example | a source check over `tools/lib/erx`, `config/manifest` and the test lists finds no path under `examples/` | `erx_dashboard` added to `ErlangApps::APPLICATIONS` |

**QEMU tests**, in the suites of the plan's parts that bring them:

* a kiosk image with `examples/dashboard` added by `tools/erx pack --app
  --enable dashboard` boots to its UI on the display, whose screendump
  matches the host test's reference, and `ls /apps/system` shows
  `dashboard.app`; seeded: `--enable` dropped, and the screen stays
  blank;
* two apps: neither's `/proc` shows the other's domains; once `data`
  grants are rooted by principal, neither reads the other's `/data`;
* a test program packaged with a display need draws through `/dev/draw`
  and changes its picture at a key that QMP sends; seeded: the program
  started without a window, which ends with its open of `/dev/draw`
  failing;
* run-time install: `cp dashboard.app /apps/` succeeds, `/proc/packages`
  shows it `admitted`, `mount /apps/dashboard.app /mnt` and `ls
  /mnt/lib` list its application and `cat` of a file under it matches the
  app directory's; `service dashboard enable` starts nothing and
  `service dashboard start` starts it; a reboot keeps
  it; a copy whose session is killed halfway publishes no name; a copy
  one byte short fails its `cp` with `EINVAL` and publishes nothing;
* update: with the app running, a copy of a newer build over it, by the
  shell's `cp` and by a native test program that overwrites as FreeBSD's
  `cp` does, `O_WRONLY | O_TRUNC` without `O_CREAT`, stops it, with
  `/proc/packages` showing the new version and `/proc/apps` the row
  `installed`, and `service dashboard restart` then runs the new code
  with the app's files kept; a newer build one byte short fails either copy and leaves the
  old one running, its session never ended; reads at `/mnt` answer `EIO`
  after the update; seeded: the update without the publication, after
  which the old session runs across the rename; a tree whose `lopen`
  answers `einval` to every writing open, after which the native copy
  fails and the old version runs on;
* removal: `rm /apps/dashboard.app` leaves no package or row, no session
  of it once the publication has answered, and the app's directory in
  place; `rm` of a package in `/apps/system` answers `EROFS`; seeded: the removal
  without the publication, after which the app's keeper restarts it
  during the deletion;
* from M10, `service NAME purge` removes the directory; from M11, a
  package of an untrusted signer, and one whose header has a byte
  flipped, fails its `cp` with `EACCES`, an installed header flipped on
  the medium is `refused` at the next boot, and one byte of an installed
  image flipped on the medium gives `eio` at `/app`, with the row `down`
  and its reason, and at a mount of it;
* the states the inspector shows, each with a test: `admitted`,
  `refused` with its reason, `overflow`, and `unchecked` in Phase 1.

**Fuzz targets**, each landing with its parser: the declaration's text
parser on the host; `erx_pkg_header:check_file/2` as a whole, over a
generated corpus of headers, lengths and names; `erx_pkg_plan:recover/2`
over generated directory listings, with names of every form, temporary
files, reserved and manifest names, and listings past the bound; the
names and open flags the `apps` tree takes; the start service's `ctl`
grammar with `purge`.

**Chokepoints**, each a build check with a seeded violation:

* only `erx_pkg_header` reads a package's bytes in the system domain,
  and no system-release module reaches `erx_verity` or `erx_erofs` for a
  package (PK5);
* only `erx_pkg_io` sends requests on the `packages` grant and sends
  `remove_app`;
* only `erx_pkg` calls `erx_principal:register_app/2` and
  `erx_starter:packages/2`;
* `erx_pkg` and `erx_pkg_io` call no `erx_domain:stop/2`: an app's
  sessions end only through the start service;
* no list of the build names a path under `examples/`, and the examples
  call only the SDK's public functions.

## Performance

An app's start is a session's start and its release's boot
([design-apps.md](design-apps.md#performance)), plus the mount of `/app`
and its modules' loads through `erx_verity`, which reads blocks of a file
through the file protocol, hashes each, and for an installed package
crosses to the storage domain. `tools/erx bench app-start` measures a
packaged app beside the same app in the release, stated with host,
accelerator, QEMU version, compiler, flags, workload and baseline. Three
costs go on the watch list ([todo-performance.md](todo-performance.md)),
each with the measurement that settles it: code loading from an
installed package against the release; a full-window frame drawn by a
program through `/dev/draw`, which a game draws every frame; and the
bytes of a copy into `/apps`, and of a read at a mount of a package,
through the system domain's `apps` tree. An install or an update asks for
two checkpoints and a removal for one; installs are rare enough that
this is not on the list.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| **Classes**: the manifest declares named classes, each a session template with its facet rows, a principal's shape and a count of places; an app joins one class and selects among its rows, and each place reserves its class's memory | Rejected as inflexible: an app that needs something between two classes needs a new class from the builder, every class reserves memory for places nobody fills, and an app author has to learn a concept that exists only for the proof. One `apps` row gives the same proof with the app naming what it needs |
| **A disk image (DMG) as the package**, as macOS ships apps | `fsimg` can read and write DMG, but the machine would need a UDIF reader (an XML property list, zlib and bzip2) in every reading session, and a hash tree would have to check blocks beneath its decompression. A small header and an uncompressed EROFS image under a dm-verity tree need only the reader every domain already has |
| **A compressed EROFS image** | The EROFS reader implements no compressed layout ([design-storage.md](design-storage.md#reading-erofs-images)); compression would put a decompressor in every reading session and is a change of the reader's own design, which no package needs in order to work |
| **Preinstalled apps at `/sysapps`** | A second top-level place for apps. `/apps/system` keeps every app under one name, as macOS keeps `/System/Applications` next to `/Applications` |
| **`/apps/user` and `/apps/system`** | The common path, installing, grows by a level for everyone. Installed apps at the top of `/apps` and the image's under `system`, which the `.app` rule keeps from ever being an app's name, cost nothing |
| **Packages copied into `/apps/pkg/` and shown elsewhere** | Two places for one thing. Installing where the app then shows is the whole of the model |
| **Each `NAME.app` shown as a read-only directory of its contents**, by a file server in each session over the `apps` tree | `rm -r` reached the removal only because OTP's `file:del_dir_r/1` passes over each inner failure, where FreeBSD's `rm -r` reports each one and exits with status 1 (`bin/rm/rm.c:296-317`, FreeBSD 15.1); a copy over an installed app could not open a directory for writing, so an update was a removal and a copy, which left no app while the new copy was checked and none if it was refused; and the view needed qid identity of its own, mounts taken and released as fids were walked, and a paged listing. A plain file and an explicit `mount` need none of that |
| **Every package mounted at a place beside `/apps` by itself** | Each session would have to follow installs, updates and removals to keep its mounts. A mount made when someone asks follows nothing, and ends with `unmount` |
| **The system domain serving packages' contents** | The EROFS reader would join the trusted base, and a crafted image would reach the system domain. A session reads its own |
| **A `ctl` file in `/apps`**, for installs, removals, enabling and purges | `/apps` would mix apps with a control file. Installing and removing are file operations; enabling and disabling are settings in `/etc/rc.conf`, which `service` edits; a purge is an action, a line of the start service's `ctl` that `service` writes |
| **Commands written into `/proc`** | `/proc` is one read-only tree ([design.md](design.md#decisions)): it shows an app's state, and no command reaches the system through it |
| **Purge as `rm -r` of the app's directory through a grant over `apps/`** | Every administrator's session would hold a grant over every app's data, with a mount point of its own, and a purge could then remove the directory of a running app, whose grant's root would vanish under it, which the storage design does not define. `service NAME purge` uses the start service's `ctl` that `service` already writes and `remove_app`, which refuses a running app's name before any request |
| **A recorded signer beside each app's directory, with a different signer refused until a purge** | It needs a record the system domain writes among the app directories, read at every admission and removed with the data, with its own crash ordering. Naming the directory for the signer gives the same separation with no record and no refusal |
| **An app principal's cap sized from its declared memory** | A package installed again with another `memory` would need a resize of a budget whose ended session may not have retired. Each session is a wall at the declared memory already, so a cap of the whole `apps` budget bounds nothing less and is never resized |
| **An update as `rm` and then `cp`** | It leaves no app while the new copy is checked, and none if it is refused. A copy over the installed one keeps the old package until the new one has passed, at the cost of one more publication than an install |
| **Renaming the new package over the old while the app runs, and restarting it after** | The running session reads its package through an open at the storage service, and whether an open file outlives a rename over its name there is the storage format's to say; a keeper that restarted the session between the rename and the publication would start it with the old layout over the new bytes. Ending the sessions before the rename makes neither matter |
| **An update that starts its app again when `rc.conf` enables it** | One rule would then apply the file at every row's entry into the table, boot or publication, and an updated app would be down for one restart only. But an install would start an app whose lines an earlier install left in the file, an update would start a row the administrator had stopped, and a recovery after a crash would start whatever its set added, so what runs would follow the package process's history instead of the administrator's commands. Applying the file only at boot and at a row's own command, as FreeBSD's `pkg` starts no service, keeps one source of what runs |
| **Opens of a replaced package kept readable, as on FreeBSD** | The `apps` tree would have to keep a package file without its name until its last open closed, and recovery would have to find and delete such files. `eio` to an open whose package is gone costs a reopen |
| **`pkg add`, `pkg delete` and `pkg info` commands** | Each is a command, a grammar and an errno table for what a copy, a removal and a listing already say. A tree the system domain serves keeps the one writer and makes the close the commit, as copying an app into `/Applications` is on macOS |
| **An app chooses its facet parameters within the row's bounds**, or the builder overrides the derived rows | The build counts every row at its own parameters whatever the app picks, so a lower value saves the machine nothing and adds a rule per parameter to admission and to the mint. A builder who wants other values for every app sets them where the service's defaults live; one who wants them per app makes the app part of the manifest |
| **An app declares a guarantee and a cap** | Each session's budgets are walls, as every domain's are, so a session's memory is one figure; the elasticity is between apps, in the `apps` budget, where the kernel already provides it |
| **A sum of installed apps' memory checked at install** | It judges again what the kernel judges at every start, and it promises less than it seems: which apps run at once depends on what is enabled and started, not on what is installed. It also made recovery order matter, since the sum admitted packages in name order until the budget ran out. The build sums the image's enabled packages, and the kernel judges the rest |
| **An app principal's budget a wall carved at install** | A removal would have to wait for every retire before giving the memory back. An elastic budget under the `apps` wall needs no wait |
| **A pool**: one principal pays for many apps, and each domain record names both the app it acts for and the pool that pays | Every reader of a principal must then choose the right one of two fields; the inspect scope and the grant records each chose wrong in the review of that design. Each app here is a whole principal, so every reader stays as it is |
| **A package carries an OTP release with its own boot script** | A boot script pins the versions of the release's applications, so every system update would break every package. `erx_app` starts the app's applications over the `app` release |
| **An environment field in the declaration** | Its one use was naming the UI renderer, which `erx_ui:open/1` takes as an option; anything else an app wants it can set itself |
| **A check that refuses an app whose module names clash with the release's** | The app's paths come after the release's, so a clash breaks only the app that brought it; the check would be one more refusal to keep in step with the release |
| **A version an install may not lower, with a flag to override it** | Against the administrator it only adds a flag; against a storage domain that puts back an older file it holds nothing without a counter the trust root keeps. The version is shown, not judged |
| **Packages unpacked into a directory of the data partition** | Their integrity would rest on the storage domain. An EROFS image under a hash tree, checked by the reader, makes it rest on the header alone |
| **The image builder's packages in the boot image** | The boot image is held in memory and bounded by the root place; Doom's 28 MiB WAD made the image 88 MiB. On the slot they are read on demand and still change only with the system |
| **Every package ships its own `erx-lvgl`** | One copy per app, a wire between toolkit and renderer that each app's build could skew, and LVGL's notices in every package |
| **A launcher in Erlang for each native app** | The display already starts a program with a window and binds its draw and input files; `program` reaches that for every native app |
| **A native window app draws into its buffer and presents through a pipe protocol, as `erx-lvgl` does** | It would be a second public path to the screen. `/dev/draw` is the designed one; the measurement on the watch list decides whether a faster one is needed |
| **Signers trusted on first install, or added at run time** | The record of who is trusted would lie where the storage domain can rewrite it. Keys in the boot image cannot be |
| **Unsigned packages in development builds** | A second mode in the header, the file check and the inspector, for nothing: the packer signs with the development key by default, which costs a developer nothing, and development builds trust that key |
| **The package process stops an app's domains itself** | A keeper restarts a session after every end, so the app could start again during the deletion, and a removal would steer a lookup by principal name. The start service, the only starter of app sessions, ending the sessions of an app the published set drops removes both |
| **A restarted `erx_pkg_io`, or a recovery that deletes temporary files while copies may still act** | A request of the ended run could reach the storage service after the new recovery had listed the directory, and a late rename could publish a file the new run never checked. One lifetime whose effects are taken only while it lives, by takers that are never restarted, closes that by construction |
| **Removing an app's data with its package** | Deleting a package would destroy what the app wrote, which macOS and FreeBSD do not do, and a removal of two things needs a durable marker and a recovery to finish it. A purge is a separate, explicit act |
| **App data removed through a system-domain grant over the whole data partition** | The system domain would hold write access to every principal's files for one operation, and a wrong name would reach them. `remove_app` reaches only `apps/` |
| **The administrator's session writes packages straight into the storage domain** | It needs a writable grant on part of the package tree and lets an administrator's session change installed files behind the package process. Copying through the `apps` tree keeps one writer |
| **Rows generated into the manifest for each app, a principal and template of its own, with the sums grown** | Doom's `run.rb` did that. It grows the board's sums with each app and is a second path beside run-time install; the `apps` row makes one path |

## Risks and decisions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| the build counts `max` apps each holding every service, so a large `max` with a display in `services` reserves the display's memory for pixel areas few apps use | medium | a display domain sized larger than its use | the builder sizes `max` to what the machine expects |
| installed apps together want more than the `apps` budget | medium | the last one started is refused `no_memory` and its row goes down | the builder sizes `memory`; `room` at `/proc/packages` and the row's reason at `/proc/apps` show it |
| a full-window frame through `/dev/draw` is too slow for a game | medium | a game such as the Doom demo runs below its frame rate | the watch-list measurement; a faster path is a design change of the display's, if needed |
| the app's code reads slowly through the file protocol and the hash check | medium | slow app starts | `tools/erx bench app-start`; the shared code design maps prepared code later ([design-shared-code.md](design-shared-code.md)) |
| a mount of a package of `/apps` reads each block through the `apps` tree and the storage domain | medium | a slow `ls -R` or `cat` of a large package | the watch-list measurement; looking inside a package is rare and reads no app's hot path |
| a restart while the `apps` budget is full waits for the ended session's outer budget to retire | low | one refused restart, counted against the row's intensity | property 19 makes the `apps` budget hold a session beside one outer budget not yet retired |
| a package's suffix, `.app`, is also the suffix of an OTP application resource file | low | a reader confuses `/apps/dashboard.app` with `lib/erx_dashboard/ebin/erx_dashboard.app` | the two never share a directory; the SDK's documentation names both |
| an author who signs a new version with a new key finds the app's data gone | low | the data lies under the old key's directory | `/proc/packages` shows the signer; a purge removes the old directory, and the author keeps the key |

Decisions:

1. **An app is a principal of its own**, made from its declaration and
   bounded by one `apps` row; no app joins a class or a pool.
2. **Memory is shared through one elastic level**: app principals'
   budgets are elastic under the `apps` wall, each capped at the whole
   of it and never resized; each session is walled; the build sums the
   image's enabled packages, and the kernel judges every start.
3. **A machine trusts only the signer keys its boot image carries**:
   the manifest's `signer` rows, and the development key in a development
   build. Every package is signed.
4. **Every app may read every package's bytes**, as stated in
   [Where a package lies](#where-a-package-lies).
5. **Installed apps are `/apps/NAME.app` and the image's
   `/apps/system/NAME.app`**, each a plain file, the package itself;
   installing is a copy into `/apps` and enables nothing, updating a
   copy over an installed app, removing `rm`, and looking inside a
   package a read-only `mount` of it; the image builder enables a row of
   the image's packages, the administrator an installed one.
6. **A name changes only at a close or a removal**: a copy publishes its
   package by one rename at the close that wrote it, over the package
   the name held, between a publication without the app and one with it;
   until then the old package runs, and it stays if the copy is refused.
7. **A name the image holds is the image's**: it is not installed over
   or removed at run time, and changes with a system update.
8. **One lifetime owns every change of the package directory**, and
   its effects are taken only while it lives.
9. **An app's data belongs to its name and signer**; removing a package
   keeps it; `service NAME purge` removes it; no prompt asks a person to
   approve grants; no fetch by name.
10. **Publishing an app applies nothing of `/etc/rc.conf`**: an install
    or an update only replaces the app's files, and the new version runs
    at the next boot or at `service NAME start` or `restart`, as
    FreeBSD's `pkg upgrade` leaves services alone; an update therefore
    leaves its app stopped ([The start table's rows](#the-start-tables-rows),
    [design-apps.md](design-apps.md#the-start-table)).
11. **Both development manifests carry an `apps` row**, sized as
    [The shipped manifests](#the-apps-row) says; the website's image
    carries none.
12. **A native app starts through `erx_prog_handler`'s `window`
    option**, and the handler's start returns a monitor whose `'DOWN'`
    is the program's one end report, so no second launcher and no second
    end message exist ([design-programs.md](design-programs.md#the-handler)).
13. **Doom is a demo app under `examples/`**, a submodule whose gitlink
    is all the tree holds; it never ships, and since nothing in erXos
    depends on it, the dependency table has no row for it
    ([Examples](#examples)).
14. **No policy per signer**: the `apps` row offers its services to every
    app, and the builder's lever is which signer keys the image trusts.

## References

* FreeBSD: `pkg-delete(8)`, `pkg.conf(5)` (signature checking against
  trusted fingerprints), `rc.conf(5)`, `rm(1)`, `cp(1)`. Read for this
  design at `release/15.1.0`: `bin/cp/utils.c` (SHA-256
  `520f936042c8989d11e32788a8db34d4339f65834a12e25e6eb4382f24d16f2d`).
* Android: application signing and the application sandbox.
  <https://source.android.com/docs/security/features/apksigning>,
  <https://source.android.com/docs/security/app-sandbox>
* Android: APEX file format. <https://source.android.com/docs/core/ota/apex>
* Linux: dm-verity's hash tree format, as design-storage.md uses it.
* Plan 9: `draw(3)`, `rio(4)`, `clunk(5)`, `remove(5)`.
