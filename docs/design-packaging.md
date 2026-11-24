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
`/Applications`:

```text
cp dashboard.app /apps/          install it
ls /apps                         every app, installed or the image's, which are read-only
service dashboard enable         start it at every boot
service dashboard start          start it now
cp dashboard.app /apps/          update it: the old one runs until the new one passes its checks,
                                 then stops
service dashboard restart        run the new version now
mount /apps/dashboard.app /mnt   look inside it, read-only, at /mnt; unmount /mnt to end
rm /apps/dashboard.app           remove it; its data stays
service dashboard purge          remove its data as well
```

`/apps` holds every app, installed or of the image, each `NAME.app` a
plain file, the package itself, so `cp`, `rm`, `ls` and `cat` treat it as
they treat any file. An app of the image is read-only there: a copy over
it or a removal of it answers `EROFS`, so an installed app never takes
its name and one name never means two packages. Within `/apps` only
names ending in `.app` are apps, and the tree reserves every other name.

The central construction is that **an app is a principal of its own,
made from its declaration and checked against that one row**. Its
grants are those of the row's services it names; its memory comes out
of the row's budget; the row's `max` (8 by default) is how many apps a
boot can hold. The build proves the machine can afford the row at its
worst, every app present and holding every service the row offers, so
whatever apps arrive, the board's own domains keep what the build
proved for them, and admitting an app is a check that its needs are a
subset of the row's services. The declaration has no field for a facet
parameter, a quota, a grant or a limit, so nothing an app declares
reaches past the row; on Fiasco an app's session also has thread, object
and mapping limits (FD14 of
[design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel)),
which come from the manifest's `limits session` record, as every other
limit of the session does. Every rule that keeps principals apart, its
directory, its inspect scope, its session names, its death records,
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

## Context

### What the clients send

The clients decide what `/apps` must answer. On a writable grant,
`erx_file_remote` opens a file for writing with one `lcreate`, which
creates the file or opens the one already there in one step, and a
write without append or read carries `O_TRUNC`, so a copy over an
installed package reaches the tree as a truncating create of the same
name. The shell's `rm` of a file is `file:delete/1`, which `prim_file`
sends as one unlink. A native program overwrites a file as FreeBSD's
`cp` does, which opens an existing destination `O_WRONLY | O_TRUNC`
without `O_CREAT` (`bin/cp/utils.c:189-199`, FreeBSD 15.1.0), and the
program's handler sends an open without `O_CREAT` as a walk to the file
and an `lopen`
([design-programs.md](design-programs.md#descriptors-and-files)), so
the same update reaches the tree as a truncating, write-only `lopen` of
the installed package. A refusal reaches the copier through the close:
every tree's `clunk` answers `ok` or an errno, which the file service
passes back once the owner has run it
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)), and
the shell's `cp` opens its target itself and reports a failed close
([design-shell.md](design-shell.md#commands)). A look inside a package
is the namespace's one EROFS mount, `erx_ns:mount({erofs, Source}, To,
Options)`, read through `erx_verity`
([design-files.md](design-files.md#building-binding-and-mounting)),
which the shell's `mount` and `umount` make and end.

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
| app code in the boot image made it 88 MiB, which stays in RAM for the whole boot, out of the room `root_memory` leaves | Doom 6 | the image builder's packages lie in the slot's system partition, outside the boot image ([Where a package lies](#where-a-package-lies)) |
| no `open()` in a native program: `liberx/program/fd.h:37-41` has null, pipe and mem objects, and the C library seam answers every unlisted call `ENOSYS` (`musl/src/internal/erxos/syscall.c:536-537`), so the WAD was linked in | Doom 4 | a program opens files through its handler ([Descriptors and files](design-programs.md#descriptors-and-files)); a package's data is `/app/share`, its writable files `/data` |
| the launcher invented a pid, parent, group, directory and masks for `erx_program:start/1` | Doom 7 | programs start through `erx_prog_handler`, which assigns them |
| presents on a 100 ms timer, no keyboard | Doom 8, 11 | a program started with a window draws through `/dev/draw`, flushes when its frame is done, and reads `/dev/kbd` |
| `erx_win:open/2` answered `{error, none}` until the display's grant arrived, so the launcher polled | Doom 9 | `erx_app` starts the app's code only once the app's record has come, after its grants |
| a crashed session's restart was refused with `no_memory` while the ended domain's budget was still held | Doom 10 | a restart carves a principal's wall of its own beside the ended session's, and property 19 makes the `apps` budget hold a session beside the wall of one that ended ([An app's principal](#an-apps-principal)) |
| `bin/erx-lvgl` reached only the programs suite's test image (`tools/lib/erx/production_image.rb:95-99`) | kiosk | the toolkit's programs ship with the toolkit in every image |
| the host test used toolkit internals (`erx_ui:start/1`, `erx_ui_lvgl`'s `open` and `present` funs) | kiosk | `erx_ui_host`, the public host stand-in for a display |

### What other systems teach

These are taken from each system's published descriptions, not re-read
for this design.

| System | What erXos takes | What it leaves |
| --- | --- | --- |
| macOS | an app installed by copying it into `/Applications` and removed by deleting it, each app named `NAME.app`; the app's data kept when the app is deleted | the system's apps in a directory apart, `/System/Applications`; the app bundle as a directory, its layout and its signing format; the disk image (DMG) as the container ([Alternatives considered](#alternatives-considered)) |
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
  of the package directory and of the `system` tree, is
  untrusted input to the system domain and
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
`data` grants and the `packages` and `system` grants every app holds,
both `rx`, which write nothing. Once the
session's grants are in place, `erx_app` mounts the package's image at
`/app`, puts `/app/lib/*/ebin` at the end of the code path and starts
`erx_dashboard`, which opens its window with `erx_ui:open/1`. An
administrator's `ls /apps` shows `dashboard.app`, and `mount
/apps/dashboard.app /mnt` shows its `lib/` and `share/` at
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
| **PK1.** An app holds no grant the `apps` row does not offer, and its memory comes only from the row's budget | the declaration grammar names services, GATT services and one amount of memory; admission keeps a need only if it is one of the row's services, and a GATT service only if the row's `gatt` offers it; the session's facets are the `packages` and `system` grants and the kept needs, all rows of the manifest, and the `code_objects` facet the domain service grants every session, which reaches only the session's own budget, through the domain service's one funnel (A10); the app's principal budget is a child of the `apps` budget, so every session it starts is carved there or refused | a declaration field that carries a parameter or a grant; an admission that keeps a need the row lacks; a session plan that grants a row the app did not name; an app budget carved from the root | admission's corpus with a seeded admission that drops the subset test; the session plan's host test with a seeded plan that grants every row of the template |
| **PK2.** The build's proof for the board's own domains holds with every app present | property 19 counts the app template as `max` principals in every sum that counts a principal or a template's rows (display pixel areas and connections, domain slots, start rows, principal table, name atoms), each holding every service of the row | a sum that counts the app template once; a service an app may take that no sum counts | the seeded violations of [The build's check](#the-builds-check) |
| **PK3.** Every block of a package's image that a session reads, at `/app` or at a mount of a file of `/apps`, matched the root hash of a header the system domain authenticated | every package mount is the one EROFS mount, through `erx_verity`, and takes no layout from its caller: for `/app`, `erx_ns`'s process takes the root hash, salt and tree layout from the app's record, which the domain service fills only from a header the file check accepted; for the shell's `mount`, from the header bytes that `erx_verity:header/1` reads through the same open as the image, which it takes only for a file it reached through the `apps` grant, and the `apps` tree serves header bytes only once their SHA-256 is the one it recorded when the file check accepted them | a form of the mount that takes a layout or a root hash from its caller; a `header` mount of a file reached through any grant but `apps`; a header read the tree answers without its hash check; a mount that reads the header and the image through two opens; a read path around `erx_verity` | a QEMU test that flips one byte of an installed package's image and finds the read refused at `/app` and at a mount of it; the `apps` tree's host test of a header changed on the medium after the check, answered `eio`; a test that a `header` mount of a file of `/tmp` or `/data` is refused with `einval`; E1's build check, `Erx::ErofsReads` ([design-storage.md](design-storage.md#invariants)): no module but `erx_verity` reads a file mount's fid or the `system` window, the reader reaches a block only through `erx_verity:read/3`, and no module but `erx_ns` and `erx_storage_system` opens an image in it |
| **PK4.** Two apps see nothing of each other, and two signers' apps of one name share no directory | each is its own principal; the domain service computes every scope from the session's principal, the app's; the storage service roots each app's `data` grant at `apps/NAME/SIGNER/`, both parts from the principal's record | a scope, storage root or name pool derived from the template's key; a data root that leaves out the signer; two apps registered under one principal | a QEMU test with two apps; the mint's host test of one name under two signers, two roots; seeded: the mint's scope taken from the template's key, and a root of the name alone |
| **PK5.** The system domain parses a package's header alone, through the generated reader, and loads no app code | the package process reads at most `pkg_header_max` bytes of a file and hands them to the file check; the image is parsed only in a session, the app's own at `/app` or a person's that mounted it | a system-domain module that mounts or reads a package's image | a source check over the system release that no module but the file check names a package's bytes, and that no system-release module calls `erx_verity` or `erx_erofs` on a package, with a seeded call from `erx_pkg` |
| **PK6.** A package's name holds a whole package that the file check accepted and admission admitted | a copy is written into a temporary file that no open can reach by name; at its close the package process runs the file check (name agreement, exact length, size bound, header) and admission, makes the file durable, and only then renames it to `NAME.app`, over the package the name held if it held one, in one atomic rename; the recovery runs the same file check on every `NAME.app` before it admits one | a rename before the file is durable; an update that deletes the old package before its rename; a recovery that admits without the file check; a length check that accepts a short file | the planners' crash test over every write of an install and an update, with writes reordered between flushes; the file check's host test of a short, a long, an oversized and a misnamed file, run through the close and through the recovery |
| **PK7.** No session of an app runs while its package's name changes, by a removal or an update, or while its principal's record changes, so every live session holds the grants its principal's record gives | the start service's keepers are the only starters of an app's sessions (AP2: an app principal has no credentials, so no login starts one); before the package process deletes an app's file or renames another over it, and before it registers a record that differs from the one the registry holds, it publishes a package set without the app, which the start service answers only once the app's sessions have ended, and it starts none until a set with the app arrives: an update at its step 7, a recovery before its first registration ([Boot and recovery](#boot-and-recovery)); a fresh install's app is in no set | a second starter of app sessions; a publication answered before the sessions end; an update that renames over a published package; a recovery that registers before that publication, or leaves running an app whose record it changes or whose package it no longer admits | the start table's host test of a publication that drops a running app; the recovery planner's host test of a directory changed under running sessions ([Verification and testing](#verification-and-testing)); a QEMU test that removes a running app and one that updates it, each finding no session of it once the publication has answered; the build check that only `erx_starter_keeper` calls `erx_domain:start_app/2` (`app-starters`, `tools/lib/erx/chokepoint_rules/apps.rb`) |
| **PK8.** A removal or a purge reaches only what belongs to an app | a removal deletes one `NAME.app` inside the package directory, after a publication that drops only that package's row; a purge sends the storage service's `remove_app`, which reaches only the directory of app directories; a name that fails the app-name rule is refused before any effect | a removal that stops domains by principal name; a data removal through a grant wider than the app directories | the purge's host test with names `root`, a configured domain and a manifest principal, each refused with nothing stopped or deleted |
| **PK9.** The system domain's atoms, tables and recovery work stay within the build's bounds | an app principal lives for the boot in one of `max` entries, which removal does not free until the next boot; its sessions take pooled names within its `names` quota; at most `max` copies are open at once and each holds its temporary file until its close is decided or its lifetime ends; the directory holds at most `max` installed packages, admitted, refused or shadowed, so a directory the package process wrote fits the recovery's bound, and recovery reads at most `pkg_scan_max` entries; the package process keeps a header's SHA-256, not its bytes | an unregister that frees an entry within the boot; a slot freed before its file is deleted; an install bound that counts admitted packages alone; a recovery that reads the directory unbounded | a host test that installs and removes `max` + 1 distinct names in one boot and finds the last refused with `apps_full`; the host test of `max` packages left refused by an ABI change; the recovery's fuzz target over listings past the bound |
| **PK10.** A package of the image and one installed at run time give the same session | both pass the file check, `erx_app_admit:admit/4` and the same session plan; only what authenticates the header differs | a second admission or plan for one of them | the session plan's host test over one header admitted both ways |
| **PK11.** No effect of an ended package lifetime happens once the next lifetime's recovery has begun | a lifetime is one run of `erx_pkg`; `erx_pkg_io` takes every file operation on `packages` and the start service every publication, each one at a time, finishing the one it began before taking the next, and each refuses an effect whose lifetime has ended; the recovery's first request is taken after every earlier one; copy handles name their lifetime, so they end with it; `erx_pkg_io` is never restarted: its end resets the machine | an executor that takes a request without checking its lifetime; a restarted `erx_pkg_io` while a request of its predecessor may be in flight; a copy handle that outlives its lifetime | the lifetime's host test: a package process killed with two copies writing and a close queued, after which no request of the ended lifetime reaches the simulated storage after the recovery's listing; seeded: an `erx_pkg_io` without the lifetime check |
| **PK12.** An open of a package of `/apps`, and a mount over one, reads that package's bytes or `eio`, never another package's | the `apps` tree gives each package it publishes or admits a qid path drawn from the system domain's file version counter, which no restart of the tree resets, so no path names a second file while the system domain runs, as every server keeps its paths ([design-files.md](design-files.md#identity-and-version)); an open records the path of the package it opened, and `erx_pkg_io` serves a read only while its path table holds that path for the name, checked as it takes the read; it drops the name's entry as it takes the rename over the name or its deletion, and records a new entry only from the checkpoint request that makes the rename durable, when that checkpoint succeeds, or from the recovery's `path_entry` requests, all in its one-at-a-time order, in which the tree's walks and opens also learn their paths; a mount reads only through its one fid, one open of the tree; the session's export names each mount's tree when it is mounted, so a program's file table never joins a file of an old mount to one of a new mount at the same point ([design-files.md](design-files.md#narrowing-for-a-program)) | a qid path drawn from the name, the listing's order or a counter the tree's restart resets; a read that reopens the name instead of checking the open's package; a path taken out after the rename is sent, or checked before the read is taken; a `path_entry` request sent apart from the checkpoint; a path table that a second process writes or copies; a mount that reopens the name; an export tree named by its mount point | the `apps` tree's host tests of an open across an update and across a removal and reinstall, and of an old open's read queued around the rename; the export's host test of a point mounted again with an image whose inode numbers repeat |
| **PK13.** Each GATT service is handled through at most one grant at a time: no two admitted apps declare one, and none declares one a configured domain's `ble` row names | the build derives one `ble` row for the app template, whose `services` is the `apps` row's `gatt`, and `ble_grant` refuses a service two rows name; admission keeps a package's `gatt` only within that row's set and apart from every other admitted app's (steps 7 and 8), at install, at boot and in the build's run over the `package` rows alike; the session plan narrows the row to the intersection of its set and the app's record; an app runs one session at a time; a record changes only while no session of its app runs (PK7), so no live session holds a service its record no longer gives, after a recovery that read a changed directory as after an update; and the Bluetooth domain makes a service's state its handler's, so a handler's end leaves nothing of it for the next ([design-bluetooth.md](design-bluetooth.md#a-service-belongs-to-its-handler)) | an admission that checks `Held` against the registry, which keeps a removed app's services, or not at all; a step 8 that counts the app's own name, refusing every update; a session plan that passes the row's set whole; a source `ble` row granted to another template; a recovery that registers a changed record while the app's session runs | admission's corpus with each step seeded out; the session plan's host test ([design-bluetooth.md](design-bluetooth.md#host-tests-of-the-cores)); the manifest check's seeded rows; the recovery planner's seeded registration before its first publication; the registry's and the link's host tests of a change of owner ([design-bluetooth.md](design-bluetooth.md#host-tests-of-the-cores)); the Bluetooth suite's two-package cases ([design-bluetooth.md](design-bluetooth.md#on-qemu-against-bumble)) |

## Data model

### The `apps` row

The board's manifest has at most one `apps` row. Without one, the
machine takes no packages. Its fields:

| Field | Meaning | Default |
| --- | --- | --- |
| `memory` | the budget all apps share, in bytes; property 4 counts it within `root_memory` as it counts a principal's budget | none: required |
| `services` | the services an app may name in `needs`, each a service of the manifest | none, so an app holds only its `packages` and `system` grants |
| `max` | how many apps a boot can hold, the image's and the installed ones together, 1 to `apps_max_limit`, 64 | 8 |
| `gatt` | the GATT services of `abi/gatt` that apps may handle, when `services` names `ble` ([design-bluetooth.md](design-bluetooth.md#the-ble-facet)) | none; required exactly when `services` names `ble` |

From the row the build derives, as rows of the image's manifest that the
board's source does not hold and the build record lists:

* **the app template**, a session template whose runtime is the
  interpreter image, which links `crypto`
  ([design-crypto.md](design-crypto.md#three-runtime-images-and-openssl-in-two-of-them)),
  whose release boots the domain release's `app`
  script (the base every session boots, which holds `erx_session` and
  the command shell it depends on
  ([design-programs.md](design-programs.md#the-command-server)), the
  client side of the display,
  `erx_memdraw`, `erx_win` and `erx_ui`, the network client
  `erx_net_client`, `erx_app`, and OTP applications it only loads:
  `compiler`, which an application an app ships may name, as Elixir's
  `elixir` does, and `asn1`, `crypto`, `public_key`, `ssl` and `inets`,
  for an app's HTTPS requests
  ([design-crypto.md](design-crypto.md#https-clients))),
  and whose limits are the manifest's `limits session` record, the
  defaults every session template takes, which enables `SPACES`
  (property 14), the template's sessions drawing their memory from the
  row's `memory` and running, on Fiasco, in the `app` band whatever the
  record names ([An app's session](#an-apps-session)); a manifest with an `apps` row and no `limits session`
  record is refused. Its words are one fixed recipe,
  `DomainStartup::APP_TEMPLATE` in `tools/lib/erx/domain_startup.rb`,
  which the release scripts also take the `app` script's name from: the
  interpreter runtime, the `app` release, no environment, and the arguments every session template
  gives init, the network client's `-erx_net_client grant` flag and
  `-eval ok=application:start(erx_session,permanent),ok=application:start(erx_app,permanent)`,
  since `erx_app` depends on `erx_session`. Since the template names no
  principal, no source row can name it: a facet's `@session.NAME`
  resolves through a principal, and the template is the session row
  whose principal is `mf_none`, last among the sessions;
* **one facet row for each service of `services`**, which never holds
  `packages`, `system`, `start`, `apps` or `etc` (property 19), granted to the app
  template, named as the service is. **Parameters and quantities**: the
  row states no parameter, so each takes the default its service's ABI
  file gives it, and it takes `max_request`, `in_flight`, `reductions`,
  `period_ns` and `max_heap_size` from the service's `quantity` lines
  ([design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas)),
  and `queue` from the machine's `system_queue`, as a source row that
  states none does. A service may be named in `services` only if its ABI
  file gives every parameter its rows take a default and declares every
  quantity: `abi/services/windows.txt` declares `windows_default` and
  `windows_pixels_default`, `abi/services/files.txt` gives `rights` the
  default `rw`, `net` declares no parameter, and each of the three
  declares the five quantities. A service of the files interface is
  refused until the data partition's storage service roots a grant at
  `tree apps`, since without it its grant would reach the whole tree
  rather than the app's own directory.
  The default rule's one exception is `ble`, whose `services` has none: its row
  carries `services` with the names of the `apps` row's `gatt`, the
  services apps may handle, so `ble_grant` checks it as it checks every
  `ble` row, and each app's session holds it narrowed to the services
  its own package declares ([An app's session](#an-apps-session)).
  A row of the data partition's storage service carries the parameter
  `tree apps`, which roots its grants among the app directories ([Where
  an app's files lie](#where-an-apps-files-lie));
* **the `packages` rows**: the system domain's grant of the service
  named `packages_service` (`abi/manifest.txt`), `rights rw`, and the
  app template's, `rights rx` and `tree installed`, each with the files
  interface's quantities. The system domain's grant is rooted at the
  tree's root, the data partition's `packages/`, which holds two
  directories: `new/`, where an upload's temporary file lies until its
  checks pass, and `installed/`, where the package process renames it
  once they have ([Installing, updating and removing](#installing-updating-and-removing)).
  The app template's grant is rooted at `installed/`, so it reaches
  only packages the file check accepted, the unchecked bytes of an
  upload in progress lying where no grant but the system domain's
  reaches;
* **the `system` rows**: the system domain's grant of the service named
  `system_service` (`abi/manifest.txt`), the `system` tree, `rights ro`,
  and the app template's, `rights rx`, each with the files interface's
  quantities; a manifest with an `apps` row holds that service, and so a
  `system` window (property 19), so every app's session holds its
  `system` row. The app template's two grants are `rx` because its
  session runs its package's code from `/app`, which is mounted through
  one of them, and an EROFS mount is `rx` only through an `rx` grant,
  which writes nothing
  ([design-files.md](design-files.md#invariants) F6); the service's server must be the holder of the manifest's
  `system` window, which property 19 checks, and the tree's root is the
  system partition's `apps/`, so neither grant reaches anything else the
  partition might hold
  ([design-storage.md](design-storage.md#the-system-tree));
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
([design-fiasco.md](design-fiasco.md#the-phase-1-manifest-check)), since the site manifest has
no display domain for `services` to name and the site machine's 256 MiB
no room for the row's memory. The Raspberry Pi 4's card, the medium of a
board the firmware boots from a boot partition, is the other image the
website offers, and boots to the kiosk: it keeps the board's row and
carries one package, `examples/dashboard`, enabled, which its own build
packs from the tree as the kiosk suite does (`ImageApps.packed_kiosk`)
and the row binds by its header's hash. Until a release signer exists it
carries no signer row and no development key, so the card trusts that
one package by its hash and no key, and no downloaded card ever trusts
its builder's development key: the build refuses a card whose admitted
manifest trusts a key (`ProductionImage.check_published_trust`), and refuses
a package, signer or `--local` of its builder's
(`ProductionImage.check_medium`), so what the card holds follows from
the tree it was built from. A medium's builder states its kind
(`ProductionImage::MediumKind`), which nothing infers from the other
options: *development*, a builder's own medium (`tools/erx pack
--medium`, and every harness); *published*, the one the website offers
(`tools/erx pack --published`, `make pack`); and *test*, a QEMU cell's
development medium with test roots or programs added and marked as test
code. QEMU's release medium, the page's QEMU virt
download ([design-ssh.md](design-ssh.md#the-ssh-domain)), is the
published kind: it carries the same kiosk, enabled, takes no app of its
builder's, and its build refuses the same trust. A published
medium's build also packs each switched row's `published_enable`, where
it has one, in its `enable`'s place, so a service its builder runs at
boot, such as `bleuart`, ships off
([design-apps.md](design-apps.md#switched-services)). A card is the website's
whatever its kind, so a development card carries the kiosk alone too;
only the published kind carries the Doom example
([Examples](#examples)). Since a package of the image is
authenticated by its hash and its signer and signature fields are not
read ([The package](#the-package)), the kiosk is sealed by the
*published package key*, an Ed25519 key whose seed is the SHA-256 of a
phrase in the tree (`Erx::PackageKey.published`), not by its builder's
development key: anyone may seal with it, and every builder of a commit
packs the same kiosk bytes, so no builder's key makes two builders'
cards of one commit differ. The published key is never a trust root:
the manifest check (property 19) refuses it as the key of a `signer` row
of any source and as the build's development key, so no image, release
or development, trusts a package for its seal; `--signer` refuses it
before the check runs.
The row's size follows from how the build counts it:

* `max` is reserved in full: property 19 counts the app template as
  `max` principals, each holding every service of `services`, in the
  display's pixel areas and connections, the domain and principal
  tables, the session-name atoms and every server's connections, whether
  or not an app ever arrives. So `max` is the number of apps a developer
  keeps installed in one boot, not a bound to be generous with. A
  development manifest takes the default, 8, and lowers it only if the
  board's own sums then fail, or to the packages its build adds where
  the board's image trusts no key that could install another. The sums are the packer's room check
  (`RootStartup.check_archive`): the archive and `root_memory` together
  fit in RAM less `fiasco_reserve` and what the boot keeps, and the row
  adds to `root_memory` its `memory` and, in the display's outer budget,
  `max` pixel areas of `windows_pixels_default`, 8 MiB each, and a 4 KiB
  lane for each grant. The shipped manifests size it so:
  * QEMU `virt`'s development machine sets `max` 4: with the default 8,
    the row's reserve leaves the archive less room than the development
    image's archive needs.
  * The Raspberry Pi 4 sets `max` 1: its card, the only medium a
    Raspberry Pi 4 image takes packages on, trusts no key
    ([The shipped manifests](#the-apps-row)), so it holds only the one
    package its build adds, the dashboard, and the display pays for one
    pixel area.

  When the archive grows past the room `max` leaves it, the packer
  refuses the image, and the board's `max` is lowered then; a `max` set
  from the archive's size would change with every build.
* `services` is `display net`: the display and the network, which both
  boards serve and the examples need. Neither row offers `ble`: QEMU
  `virt`'s development machine has no Bluetooth, and the Raspberry Pi
  4's Nordic UART service, `nus`, is `bleuart`'s, the console over the
  radio, a switched configured domain that runs on a builder's own card
  and is off on the published one
  ([design-bluetooth.md](design-bluetooth.md#the-console)), and a
  service has one holder (PK13). `data` waits for `tree apps`,
  since a files service is refused until then.
* `memory` is not multiplied by `max`: it is one wall, carved from
  `root_memory` and counted by property 4, that the apps running at
  once share, and the kernel refuses a start that does not fit. So it is
  sized for the apps that run together, not for every app the row can
  hold: two at the default 64 MiB, each with its session's outer budget
  of 1 MiB, 130 MiB, which the two-app tests of
  [Verification and testing](#verification-and-testing) need and which
  clause 4 needs for a running app beside the principal's wall of one
  that has ended and not yet retired; the row's 131 MiB (137,363,456
  bytes) holds them.
  `root_memory` grows by it, and the packer's check of each board's
  development machine proves that the RAM left beside it still holds
  the archive.

An app principal's group is a child of the apps group, whose share of
`users` is what the principals' shares leave of it, each app an equal
share of that. An app principal's quotas are a principal's defaults, but
`domains`, which is 1: an app runs one session at a time.

#### The build's check

The manifest check gains one property, property 19, **the `apps` row and
the packages are well formed**, beside those of
[design-system.md](design-system.md#the-manifest):

1. at most one `apps` row; each name of `services` is a service of the
   manifest whose ABI file gives every parameter a default, or `ble`,
   whose row takes `services` from `gatt`; `gatt` is present exactly
   when `services` names `ble`, so no row offers apps a `ble` grant that
   names nothing and no `gatt` is written that no row carries, and
   `ble_grant` checks the derived row as any `ble` row: each name
   declared in `abi/gatt`, none named by another row, a configured
   domain's included, at most 8, and the advertising data still fitting
   ([design-bluetooth.md](design-bluetooth.md#declarations-abigatt)); other than
   `packages` and `system`, which every app holds already, and `start`, `apps`, `etc`
   and `machine`, which would let an app command the start table, install
   packages, rewrite `/etc/start.conf` and end the machine
   ([design-system.md](design-system.md#a-sessions-request)); property
   17 checks the resolved
   manifest for the last whatever the rows' source, since every writable
   grant of the `etc` tree must belong to the system domain or to a
   template that holds a writable `start`
   ([design-system.md](design-system.md#the-manifest));
   when it names `inspect`, the scope `erx_domain_core:inspect_scope/4`
   gives an app principal is its own, with no machine tree, never `all`,
   which would show an app the other apps' domains;
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
   beside the principal's wall of one that ended and has not retired,
   which holds that session's default memory and outer budget;
5. every `package` row's package passes the file check and admission on
   the host against this manifest ([Admission](#admission)), in the
   order the recovery admits them, each against the GATT services the
   packages before it declare, so no two image packages declare one; the
   `package` rows number at most `max`; the declared memory and the
   session's outer budget, as the resource policy sizes it, of every
   enabled package sum within the `apps` budget, so the image's enabled
   apps all start; and the row of an enabled one meets property 17's
   display and planning clauses as a manifest `start` row does;
6. every `signer` row holds a 32-byte Ed25519 public key under a unique
   name;
7. no facet row of the board's source is granted to the app template,
   carries `tree apps` or `tree installed`, or names the `apps` service
   or the service named `home_service`: only the rows the build derives
   do, a `home` row among them for every session template but the app
   template
   ([design-files.md](design-files.md#building-binding-and-mounting),
   "A user's home");
8. the manifest holds one service named `system_service`, of the files
   interface, exactly when it has a `system` window, and its server is
   the holder of that window
   ([design-storage.md](design-storage.md#the-system-tree)), so the
   domain that mints the tree's grants is the one whose block driver
   serves its partition; a manifest with an `apps` row holds the service,
   so the build derives the `system` rows every app's session mounts its
   image package through; no facet row of the board's source names it,
   since only the derived `system` rows do;
9. on Fiasco, the root's machine-wide tables hold every domain the image
   can run at once, with the configured domains' shares reserved: for
   each table [design-fiasco.md](design-fiasco.md#table-sizes) names as
   shared out among domains (the page index's 4,096 labels for tasks and
   memory objects, the task table's 1,024 rows, shared by object limits,
   and the threads' share of the root's slot pool, by thread limits) and
   for the root's own
   kernel memory, the configured domains' shares, which their limits
   records' thread, object and mapping limits fix, plus `max` times the
   app template's share, plus every other session template's share times
   its principals' `domains` quotas, sum within the table. The domain
   service admits a session only from what lies outside the configured
   domains' shares, so apps and sessions, however many run, never take
   what a configured domain's restart needs. The clause goes with Fiasco:
   erXos's kernel has no table of the root's (FD30);
10. a facet row of the service named `data_service` that states no
    tree, the data volume whole, is granted to the system domain or, in
    a development manifest only, to root's template, the system
    principal's, and to no other grantee, configured domain or template,
    since a user's one place on the volume is its home
    ([design-files.md](design-files.md#building-binding-and-mounting),
    "A user's home"); a row with `tree apps` is rooted below the volume
    and is not this clause's.

Each clause has a seeded violation: a check that counts the app template
once in property 18, which admits a row whose apps together pass the
display's budget; an `apps` row whose `max` plus the manifest's start
rows pass 256; `apps` in `services`; `etc` in `services`; a service
in `services` whose ABI file gives a parameter no default; `ble` in `services` with no `gatt`; a `gatt` with no `ble` in `services`; a `gatt` naming the service a configured domain's `ble` row names; two `package` rows whose declarations name one GATT service; two enabled packages whose memory
passes the `apps` budget; a `package` row whose declaration needs a
service the row lacks; a configured domain's `data` row carrying `tree
apps`; an `apps` row in a manifest with no `system_service`; a
`system_service` served by a domain that does not hold the `system`
window; a source facet row of `system_service`; a source facet row of
`home_service`; a `data_service` row granted to the template of a
principal other than the system principal; one granted to a configured
domain; one granted to root's template in a release manifest; an `apps`
row
whose `max` times the app template's object limit, beside the configured
domains' object limits, passes the page index's 4,096 labels; and
configured domains whose thread limits together pass the threads' share
of the root's slot pool.

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

An app that handles a phone's serial line names the GATT service it
handles, which the board's `apps` row must offer:

```text
app echo
  gatt nus
  applications erx_echo
```

| Field | Value | Default and bound |
| --- | --- | --- |
| `app NAME` | the app's name, which is its principal's | required; an app name ([Admission](#admission)) |
| `applications` | the OTP applications `erx_app` starts | at most `pkg_applications_max`, 16, names of the form `[a-z][a-z0-9_]*`, 63 bytes each |
| `program` | a path under `bin/` of the image, then its arguments | the path at most `pkg_program_max`, 255, bytes of plain names; at most `pkg_args_max`, 32, arguments, `pkg_args_bytes_max`, 16 KiB, together |
| `needs` | the services of the `apps` row it takes | none; at most `pkg_needs_max`, 16, identifiers, none twice |
| `gatt` | the GATT services the app handles, through its own `ble` grant ([design-bluetooth.md](design-bluetooth.md#the-ble-facet)) | none; names of `abi/gatt`, none twice, at most as many as the `ble` interface's `services` set holds, 8, the bound the generator takes from `abi/services/ble.txt` |
| `serves` | `svc`: the app's sessions serve its own tree at `/svc/NAME` ([design-app-trees.md](design-app-trees.md#the-declaration)) | none; `svc` is the field's one value, and only with `applications` |
| `memory` | what its session's own budget holds, in bytes | `app_memory_default`, 64 MiB; at least `app_memory_min`, 4 MiB |
| `version` | a decimal number the inspector shows, which decides nothing | 1; 1 to 2^32 - 1 |
| `flags` | the default start flags of the app's start row, which its session reads from `ERX_START_FLAGS` | empty; a quoted string of at most `start_flags_max`, 1,024, bytes from 0x20 to 0x7e other than `"`, `\`, `$` and `` ` ``, which the packer and the package reader refuse beyond |
| `license` | the package's SPDX license expression | none, which no image erXos distributes takes; at most `pkg_license_max`, 256, bytes, in the grammar `LicenseExpression` reads |

A declaration has exactly one of `applications` and `program`. An Erlang
app that needs a native helper starts it itself with
`erx_prog_handler:start/1`. A program starts with a window on the
session's default display whenever the session has one, and otherwise
without one. A declaration names no facet parameter, quota,
CPU share, environment or grant, and there is no field through which it
could: the illegal declaration is one the grammar cannot write. `gatt`
is no parameter either: it chooses among the names the `apps` row's
`gatt` offers, as `needs` chooses among the row's services, and it is
how an app takes `ble`: admission keeps the app template's `ble` row
for an app whose declaration names `gatt`, and `needs` never names
`ble`, which the packer and admission refuse, so no app holds a `ble`
grant that names nothing. `serves
svc` grants the app nothing: it lets the sessions that may command the
start table read and command the app's tree, and the domain service
derives its grants ([design-system.md](design-system.md#facets-a-configured-domain-serves),
"A session as provider"). An app
that wants the LVGL renderer says so where it opens its UI, with
`erx_ui:open(#{renderer => lvgl})`
([design-display.md](design-display.md)).

Every admitted package has a start row named for its app, disabled
until the image builder or the administrator enables it, on its one
`windows` need if it has exactly one and on none otherwise, with the
start table's default intensity and the declaration's `flags` as its
start flags. `/etc/start.conf` sets it, its `NAME_flags` included, as
it sets any row ([design-apps.md](design-apps.md#the-start-table)).
The `flags` are data for the app, delivered only as `ERX_START_FLAGS`,
and carry no authority ([design-apps.md](design-apps.md#start-flags),
AP1).

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
| header, at most `pkg_header_max`, 64 KiB | the magic `ERXPKG`, the format version, the header's length, the `ERX_ABI_VERSION` and the target architecture (an architecture name of `abi/arch/`) the package was built for, the packed declaration, the image's length in blocks, the hash tree's length, its 32-byte salt and root hash (SHA-256, dm-verity format version 1, as [design-storage.md](design-storage.md#data-model) lays read-only images), the signer's Ed25519 public key, and the Ed25519 signature over every byte of the header before it |
| image | an uncompressed EROFS image of 4 KiB blocks, whose root holds `lib/APP/ebin` and `lib/APP/priv` for each application, `bin/` for programs and `share/` for data |
| hash tree | the image's dm-verity tree, over the image's blocks as they lie in the file, its levels top first; an image of one block has no level, its block's hash being the root hash |

The image uses only the layouts the EROFS reader implements: compact and
extended inodes, the plain and inline data layouts, regular files and
directories, and no compression
([design-storage.md](design-storage.md#reading-erofs-images)). They are
the layouts `fsimg` writes with the options every erXos image is made
with, `-o cluster=4096 -o compression=none`
([design-storage.md](design-storage.md#data-model)), which the packer
uses too. The file check reads only the header, so an image another tool
made in another layout is admitted and fails where the reader meets it:
the mount refuses an incompatible feature bit, and an inode of a
compressed or chunked layout answers `enotsup` when it is reached, in the
reading session alone. **A package holds no links.** The packer writes
none, and on a package mount, `{erofs, app}` or `{erofs, {header,
Path}}`, the reader answers a symbolic-link inode with `enotsup` wherever
it reaches one, as it answers an inode of a layout it does not
implement, so a walk, a `readlink` and an open through a link all fail
and no path beneath `/app` leads out of the package: a program the
header names, and every file a program of the package opens there, is
the package's own. The image's entries carry fixed owner, mode and
time, so the same inputs give the same bytes and no host metadata leaks
into a package. The image names no device or socket.

**The decoder**, `erx_pkg_header:decode(Length, Bytes)`, is the one
parser of a package file's structure, whatever the file's origin and
whoever authenticated it. `Length` is the file's length and `Bytes` its
first bytes, at least `min(Length, pkg_header_max)` of them; the decoder
reads that many, copied, so a caller that hands it more keeps none of the
rest alive. It checks, with checked arithmetic throughout, the first
failure answering:

1. the length is at most `pkg_bytes_max`, 1 GiB: `{too_large, L}`; and
   `Bytes` holds `min(Length, pkg_header_max)` bytes, which a read cut
   short does not: `{header, short}`, the tag of step 3's file cut short
   of its boundary, since either way the bytes before the image are not
   all there;
2. the header, through the generated reader: its magic, its version and
   its length, at most `pkg_header_max` and within `Bytes`, every field
   and the packed declaration inside that length, and the signer's key
   and the signature ending it, as `abi/formats/package.txt` lays them:
   `{header, Reason}`, `Reason` the reader's error;
3. the next 4 KiB boundary at or after the header's end lies within
   `Bytes`, `{header, short}`, which it does for every file at least
   that long, since `pkg_header_max` is a multiple of 4 KiB; and
   the bytes from the header's end to that boundary are zeros, so every
   byte before the image is fixed by the header: `{header, padding}`;
4. the parts lie end to end: the image from that boundary, for its
   length in blocks, and the hash tree from the image's end, of the
   length in blocks that `erx_verity_tree:blocks/1`, the tree's layout,
   gives for the image's block count, which the header's tree length must
   equal: `{header, {tree, Have, Want}}`; and the file ends exactly where
   the tree does: `{length, Have, Want}`, `Have` the file's length.

The tree's layout, `erx_verity_tree`, is pure arithmetic in a module of
its own, preloaded beside the hash check rather than inside it: it gives
the blocks of each level, the decoder their sum and `erx_verity`'s check
of each block their places, from one source, and owns the one type of a
layout, where an image and its tree lie, that the decoder and the boot
record's reader make and the hash check opens, while no module but the
EROFS reader names `erx_verity`
([design-storage.md](design-storage.md#reading-erofs-images)).

It answers `{ok, Decoded}`, the header's fields and the layout of its
image (the image's offset and length, the hash tree's offset, length and
salt, and the root hash), or `{error, Reason}`. Since each part starts
where the one before it ends, by lengths the header states, no two parts
overlap and none reaches past the file.

**The file check**, `erx_pkg_header:check_file(File, Authority)`, is the
one entry that judges a package file, at a copy's close, at recovery and
for the image's packages at boot and at build. `File` is the file's name
in the directory, its length and its first bytes, at most
`pkg_header_max`. It runs the decoder, and then checks, the first
failure answering:

1. the name is `NAME.app` with NAME the declaration's app name:
   `{name, File, App}`;
2. the header is authenticated by the means `Authority` names:
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
Authentication follows the decoder and never stands in for it.
The layout in the answer is the decoder's: the image's offset and length
and its tree's offset, length, salt and root hash. No mount takes a
layout from its caller
([design-files.md](design-files.md#building-binding-and-mounting)), so
where a layout comes from is fixed by the system domain, not by the
code that asks for a mount: the domain service puts the one the file
check built in the app's record, from which `erx_ns`'s process mounts
`/app`, and for the shell's `mount` of a file of `/apps`
([Looking inside a package](#apps)) `erx_ns`'s process runs the decoder
over the header bytes the `apps` tree served, which are those the file
check accepted (PK3) ([design-storage.md](design-storage.md#invariants)
E1). `erx_app` decodes nothing.

### Where a package lies

| | The image builder's packages | Installed packages |
| --- | --- | --- |
| placed by | `tools/erx pack --app` | `cp NAME.app /apps/` |
| lies | at `apps/NAME.app` in the slot's system partition, which the storage service serves read-only as the `system` tree ([design-storage.md](design-storage.md#the-system-tree)) | at `installed/NAME.app` in the data partition's `packages/` directory, which the storage service serves as the `packages` tree; an upload's temporary file lies in its `new/` directory until it is installed |
| shown at | `/apps/NAME.app`, read-only | `/apps/NAME.app` |
| header authenticated by | its SHA-256, which the manifest's `package` row records | a key of the manifest's `signer` rows, or in a development build its builder's development package key |
| changes | with a system update, as the slot does | by a copy into `/apps` or over a package there, or a removal there |

A machine trusts only the signer keys the boot image carries: the
manifest's `signer` rows, and in a development build the public half of
the development package key of the host that built it
([The SDK](#the-sdk)). Trust therefore changes only with a system update, and
no record a storage domain could rewrite adds a signer.

The system domain and the app's session reach an installed package
through the `packages` service, an instance of `files` that the storage
domain serves at a service directory of its own: the system domain reads
and writes it, and the app template reads it. They reach a package of
the image through the `system` tree, which both read and nothing
writes; the storage domain that serves it checks every block of the
partition against the root hash the manifest records, and the file
check authenticates each header there against its `package` row's
hash, so a package listed under another's name, or a file that is not
a package, is refused. The system domain mounts its `packages` grant
at `/packages`, so the installed packages lie there at
`/packages/installed/`. That mount point is a place of the system
domain's alone (`erx_ns:packages_place/0`), which no session's
`erx_ns:mount_facets/1` mounts; a path reaches only a grant its own
domain holds, so an app's session reaches the tree only through its own
grant. Since `erx_verity` checks
every block against the root hash of the authenticated header, no
property of a package rests on the storage domain but its presence: a
storage domain can withhold a package, put back an older one of the same
signer, or across a reboot put another trusted signer's package of the
name in its place, never change one; a package of the image, whose header
its hash pins, it can only withhold. Every app can read every package's
bytes: a package holds what its author ships, not anyone's secrets, and
keeping each package to its own app would need a grant per package.

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
| `NAME.app`, a name of the image's packages | the image package's bytes, which the tree reads through its `system` grant | none: a create, a write, an open for writing and a remove answer `erofs` |
| `.NAME.app`, NAME a name of the image's packages | the installed package of the name, which the image package shadows ([Boot and recovery](#boot-and-recovery)) | a remove (`unlinkat`) removes it; a create, a write and an open for writing answer `erofs` |

It lists one `NAME.app`, a regular file, for every package of the image
and every installed package, admitted or refused, that no image package
shadows, and one `.NAME.app`, a dot file that `ls` shows only with `-a`,
for each installed package that one does; the two sets of `NAME.app`
names are disjoint, since a create of an image package's name answers
`erofs`.
A name that does not end in `.app` is the tree's own: it lists none, and
a create of one answers `einval`. A
create of `NAME.app` opens the file write-only and truncates it, as
`cp` and every open for writing without append does, since a copy
starts empty: one that appends or also reads answers `einval`, and one
with `O_EXCL` of a name the tree holds answers `eexist`. While a copy is
written, the name goes on holding the package it held, and that package
goes on running.

**Refused packages** are of two kinds, told apart by whether the file
check accepted them. A package the file check accepted and admission
refused, for its ABI, its architecture, its name, its signer's
continuity, its memory or a need, has a header the system domain
authenticated: it is read and mounted as an admitted package is, its
header served against the hash the file check recorded, so an
administrator can look inside a package a system update left refused. A
package the file check refused, for its size, its structure, its name
or its signature, has no authenticated header: it is listed with its
length, every read of it answers `eio`, so a mount of it is refused, and
`rm` removes it. Reading its bytes at the recovery authenticates
nothing. Both kinds count against the directory's `max` installed
packages ([Installing, updating and removing](#installing-updating-and-removing)).

An `lopen` of an installed `NAME.app` that is write-only and truncating
is the same act as that create: it starts a copy of its own, in a slot
of its own, whose close answers as a create's copy does, so a native
`cp` over a package updates it as the shell's does. Every other writing
`lopen`, one without truncation, or that appends or also reads, answers
`einval`, and an `lopen` of a node whose name holds another package
since its walk, or none, answers `eio` whatever its mode, since the path
its walk recorded is not the one `erx_pkg_io`'s table holds when the
open asks it, as a read of an open of it does ([Identity](#apps));
neither touches the installed package. An `lopen` for reading reads, as
any open does.

**Reads.** The `apps` tree's `read` callback, in the reader's grant, sends each read
to `erx_pkg_io`, naming the qid path of the package the open recorded
([Identity](#apps)). `erx_pkg_io`, as it takes the read, answers `eio`
and sends nothing unless its path table holds that path for the name;
otherwise it reads through a fid it walks and opens for the read and
clunks after. It takes reads in turn with every rename and deletion of
`packages`, so a read reads the package the name held when the read was
taken, and never meets a file being deleted or renamed over. A read
that reaches into the bytes before the image is answered from the
header, which the read reads whole, served only if its SHA-256 is the
one the table holds for the name, and otherwise answers `eio`; the
padding after the header, to the end of the header's extent, is
answered as the zeros the decoder found. So every byte before the image
that a reader gets is one the system domain authenticated, and the rest
of the file is bytes the hash tree checks.

**Identity.** Each package the tree lists, at a copy's close or at the
recovery, gets a qid path of its own, drawn from the system domain's
file version counter, the one counter of the runtime that no server's
restart resets ([design-files.md](design-files.md#identity-and-version)),
so no path is given to a second package while the system domain runs,
which is the whole boot, since its end resets the machine, however often
the package process and its tree restart; its version is drawn from the
same counter, as every server draws one.

`erx_pkg_io` keeps the **path table**, the one store of each listed
name's entry: its qid path and, for a package the file check accepted,
its header's SHA-256 and extent, the bytes before the image. A shadowed
package's entry is held under the name the tree lists it by, its dot
name `.NAME.app`, with the header hash its file check recorded, so its
reads are checked as any package's are. Only
`erx_pkg_io` changes it, as it takes a request, and the tree's file
processes learn an entry only by a request in that same order: a
`readdir`, and the walk, `getattr` or open of a `NAME.app`, the last of
which keeps the path that a later read names. The package process sends
each entry in a `path_entry` request: at the recovery, one for every package
it lists, as the file check judges it; and at a copy's close, inside the
checkpoint request that makes the rename durable, which applies the
entry only when the checkpoint succeeds. As it takes the recovery's
listing, `erx_pkg_io` holds every listed name without an entry; as it
takes the rename over a name, it keeps the name and drops its entry; as
it takes a deletion, it drops the name. It empties the table as it takes
the first request of each lifetime, the recovery's
([The package lifetime](#the-package-lifetime)). Two copies of the names
exist, each authoritative for its own reader: the path table for every
walk, open and read of the tree, and the package set `erx_pkg` publishes
for the start service.

So, since `erx_pkg_io` takes one request at a time, a read it took
before the rename read the old package, and every read it takes after
the rename answers `eio`. A name held without an entry answers `eio` on
a walk, a `getattr` and an open, until its `path_entry` request is taken; a
name the table does not hold answers `enoent`; once the entry is taken,
a new open of the name reaches the new package under its new path. A
package the file check refused has an entry with no header hash, so it
is listed with its length, and every read of it answers `eio`. What a
client already holds stays the old package's bytes: an open's read-ahead
buffer
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote))
and a mount's cache of checked blocks. So an open reads the package it
opened or `eio`, no client caches one package's bytes under another's
identity, and no open reads a mix of two packages. FreeBSD differs:
there an open file stays readable after its name is removed or
replaced, and here the tree keeps no file without its name.

**Looking inside a package.** `mount /apps/NAME.app DIR` mounts the
package's image read-only at `DIR` in the session's namespace, and
`umount DIR` ends it. It is the namespace's EROFS mount,
`erx_ns:mount({erofs, {header, Path}}, DIR, [ro])`
([design-files.md](design-files.md#building-binding-and-mounting)), the
mount `erx_app` makes of `/app` with `app` instead of `{header, Path}`
([An app's session](#an-apps-session)).
`erx_ns`'s process, which makes every mount, walks `Path` once to a fid
of its own, opens it for reading, and clunks it at the unmount; the
mount holds that grant and fid, never an OTP file descriptor, which only
its opening process may use
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)).
Every process of the session that reads below `DIR` runs the EROFS
reader in itself, and `erx_verity` sends that process's positioned
reads, at the layout's offsets, on the mount's fid, as any process of a
domain may use the domain's fids
([design-files.md](design-files.md#fid-owners)), and checks every block
against the layout's root hash. For `/app` the layout is the one in the
app's record, which the file check built. For `{header, Path}`,
`erx_ns`'s process takes only a file it reached through the `apps`
grant and refuses any other with `einval`: it has
`erx_verity:header/1` read the file's length and its first
`pkg_header_max` bytes through the same fid, so no module but
`erx_verity` reads it ([design-storage.md](design-storage.md#invariants)
E1), and decodes them with `erx_pkg_header:decode/2`. The `apps` grant is `rw`, so the
mount is `ro`, and one asked for `rx` is refused with `eacces`
([design-files.md](design-files.md#invariants) F6). The `header` form is
refused in a command's domain too, since a command of the shell sees
`/apps` through its session's export and holds no `apps` grant of its
own ([design-shell.md](design-shell.md#invariants) SH1). Those bytes are the ones the `apps`
tree authenticated, and header and image come through one fid, one open
of the tree, so they belong to one package (PK3). A package file
elsewhere, under `/tmp` or `/data`, is not mounted: nothing has
authenticated its header, and a mount against the file's own header
would show only that the file agrees with itself. Every block the mount reads comes through that one
open, so once the package is removed or replaced, a block the mount must
read again answers `eio`, what its cache holds stays the old package's
checked bytes, and no read at `DIR` returns a byte of the replacement
(PK12); mounting the name again mounts the new package. The
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
mounted to be read. It differs from a file of a file server in three
ways, each on purpose: a copy into it takes effect whole at its close or
not at all, only a write-only, truncating open writes it, and an open of
it stops reading once its name holds another package.

### Where an app's files lie

The data partition's storage service keeps every app's directory under
one directory of its own, `apps/`, apart from the users' homes,
`root/` and `home/`, and the services' trees. A grant from a facet row that
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
`purge NAME`; that write's callback, in the writer's grant, hands it to the package process and
awaits the answer itself, outside the start table
([design-apps.md](design-apps.md#concurrency)). The package process
carries it out with the storage service's `remove_app` request on the
durability facet, which only the system domain holds and which reaches
nothing outside `apps/`
([design-storage.md](design-storage.md#interfaces)): it removes every
signer's directory of the name, each `apps/NAME/S` with S other than
`image`, NAME one identifier, answers `ok` once a completed checkpoint
holds the removal and every write the service acknowledged before it,
and answers `ok` for directories already absent. The package process
refuses a purge of a name that is not an app name, or that an installed
package holds and no image package shadows, before any request, so no
running app's directory is removed under it; on a trial boot it answers
every purge with `erofs` before any request ([Boot and
recovery](#boot-and-recovery)). A name of the image's packages is purged
like any other: the purge removes the directories of every signer whose
installed package the name held, shadowed now or removed earlier, and
the image app's own directory, `apps/NAME/image`, stays, since no purge
removes it. So the data an image app wrote stays as long as the data
partition does, even once an update drops the app from the image.

### An app's principal

The principal service registers an app's principal with
`erx_principal:register_app/1`, which only the package process calls, in
a free entry of the `max` the domain library's principal table holds for
apps. Its record holds the app's name, its signer (`image` for one of
the image's), its declared memory and the app template's facet rows its
admission kept, which its sessions hold, with the GATT services its
`gatt` declares, to which they hold the `ble` row narrowed, and it is
written only when a
package of the name is committed: at an install or an update, once the
rename is durable, and at the recovery, for each package it admits. A
refused or failed install or update leaves the record as it was. A
principal of an app has no credentials: no one logs in as one. Its
directory, its inspect scope and its name pool are those of any
principal, keyed by its name, and its data directory by its name and
signer. It is never unregistered within a boot: a removed app's
principal keeps its entry and name, with nothing to run, until the
machine reboots, so its atoms and its table entry stay within the
build's count (PK9). Installing the name again in that boot, or updating
it, takes the same entry, with the same signer only, and writes the
record again. The registry is a value the domain service keeps, since it
names and starts every session from its principal, and
`erx_principal:register_app/1` and `erx_principal:app_registry/0`, the
registry admission reads, reach it there.

`max` has one source: the app entries the domain library's boot view
places (`erx_dom_apps_place`) from the packed `apps` row and the app
template, the session template that names no principal and comes last.
The row and the template come together, since the build derives the
template from the row, and the view refuses a manifest with one and not
the other, so the library holds app entries exactly when the manifest
has the row.

**The template's rows by index.** The build packs, in the `apps` row,
the index of the app template among the sessions (`app_template`) and of
its `packages` and `system` facet rows (`packages_facet`,
`system_facet`), and in each `app_services`
row the index of the facet row granted to the template for that service
(`facet`), the rows it derived; the generated reader checks each index
against its table. The boot view checks once, as it reads an untrusted
manifest, that `app_template` is the session row naming no principal, the
last, and that each of those facet rows is granted to that template for
its service, `packages_facet` for the service named `packages_service`
and `system_facet` for the one named `system_service`, and that the
template holds no other facet row, so an app's session
reaches only the services the `apps` row names.
`erx_pkg_manifest` reads the indices and searches for nothing, so the
packer's host check and the boot cannot disagree about which session is
the template or which rows are its grants, and a manifest the view
refuses boots no package process. `erx_domain_lib:apps/0` answers them; the domain service
bounds the registry by their `max`, and the package process gives
admission the same `max`, so admission and registration cannot disagree
about how many entries there are.

Its budget is a child of the `apps` budget and, as every budget of a
principal is, a wall, a budget whose cap is its guarantee
([design-kernel.md](design-kernel.md#budgets)), on either kernel. It
exists only while a session of the app does: the domain service carves
it from the `apps` budget, through the domain library, as it starts the
app's session, at the
memory the record holds when the session starts plus that session's
outer budget as the resource policy sizes it, and destroys it once the
session has retired, which returns the reservation to `apps`. The
session's own and outer budgets are walls carved from it, as every
domain's are, so once a session runs, its memory depends on nothing
outside it, and what the kernel judges against the `apps` budget is
only whether the principal's wall can be carved: a carve the `apps`
budget cannot hold refuses the start with `no_memory`. A session that ended keeps its principal's wall until it
retires, its outer budget waiting for its peers' disconnects inside it,
so a restart carves a second wall for the new session beside it, and
for that moment the principal has two. A package of the name installed
again or updated with another `memory` changes the record and so the
next session's wall, and no budget is resized. No budget under `apps`
is elastic: the sharing between apps is the `apps` wall itself, carved
for each app that runs and returned when it stops.

### An app's session

`erx_domain:start_app(Name, Start)`, which only the start service's keepers call (PK7), makes an app's session as it makes
any session, with three differences, all decided by the domain service:
the first two from the app's entry in its registry, which
`erx_domain_core:app_session/4` turns into the session's plan, and the
third from the package the entry was registered from:

* the domain library's plan takes the app template and the app's
  principal: `erx_dom_plan_app_session` plans the app template under the
  app's entry, with the template's limits but the `memory` its record
  carries and, on Fiasco, the `app` band, below every interactive domain
  ([design-fiasco.md](design-fiasco.md#bands)), and plans no other
  template; `erx_dom_plan_session` plans a
  template under its own principal only, and the app template names none,
  so it refuses that template, and neither entry can pair an app
  principal with another template or the app template with another
  principal;
* its facets are the template's `packages` and `system` rows, the
  rows the admission kept, and the `code_objects` facet the domain
  service grants every session by its own policy, with no row
  ([design-system.md](design-system.md#creating-a-domain), "The
  `code_objects` facet"), and no others; each mint computes its parameters from
  the session's principal, the app's, as every mint does
  ([design-system.md](design-system.md#facets-a-configured-domain-serves)),
  and the plan gives the `ble` row, when the admission kept it, with its
  `services` replaced by the intersection of the row's set and the GATT
  services the record holds, so an app's grant never names a service the
  row does not offer, whatever a record holds, and names only the
  services admission gave that app
  ([design-bluetooth.md](design-bluetooth.md#the-ble-facet));
* its environment holds its default display, which its planning sets,
  and `serves=svc` when the app's entry records that its package
  declares it ([design-app-trees.md](design-app-trees.md#serving-erx_svc)),
  ([design-apps.md](design-apps.md#starting-a-session)), and the domain
  service sends it the app's record, in a message of its own after the
  ready answer: the place of the package's file, `{Facet, Names}`, the
  facet whose grant holds it and its names below that facet's tree
  (`{packages, [NAME.app]}`, at the root of the `packages` grant, or, for
  a package of the image, `{system, [apps, NAME.app]}` on the `system`
  grant; neither service has a mount point in the
  session's namespace, and what the session reaches through either
  grant, by `erx:cap/1` or by any entry its code puts in its table, is
  what the grant reaches: the `packages` grant, packages of
  `installed/`, each accepted by the file check, and never an upload's
  temporary file in `new/` ([The `apps` row](#the-apps-row)); the
  `system` grant, the system partition's packages, every block of which
  matched the root hash the boot image's manifest records
  ([design-storage.md](design-storage.md#the-system-tree)). Both hold
  nothing secret, and a package file begins with its header, not an
  executable's), the
  header's layout, which the file check built, and its
  applications or its program with its arguments; the record holds no
  window of its own, since `erx_app` starts a program with a window
  whenever the session has a default display.

The record comes only once the session's namespace is in place, each of
its grants of a files service settled, the `packages` and `system`
grants among them
([design-system.md](design-system.md#a-session-takes-the-console)),
and before the session's start is answered, so the app's code never
starts before its grants exist and its package is readable when it
starts. The session's connection agent keeps the record, which the
domain pid sends it as `{erx_app, App}`
([design-domains.md](design-domains.md#messages-between-the-domain-service-and-a-runtime)),
and `erx_app` asks the agent for it (`erx:app/0`), which answers at once
if it holds the record and else once it comes, so the record reaches
`erx_app` whichever comes first. `erx_app` mounts `/app` with
`erx_ns:mount({erofs, app}, "/app", [rx])`, and `erx_ns`'s process takes
the place and the layout from the record the agent keeps; a mount the
reader refuses ends the session with the reason. The root hash is the
domain service's and `rx` is the grant's, so nothing the session's code
passes chooses what `/app` holds or whether it runs. The
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

`erx_app_admit:admit(Checked, Manifest, Registry, Held)` is a pure function
of the file check's answer, a header it accepted with the signer it
named; what it
reads of the manifest through `erx_manifest`: the `apps` row with the
indices of the app template's `packages` and `system` rows and of the
facet row of each of its services, the names of the manifest's principals,
configured domains, services and facet rows, and the names of the
image's packages; the boot's registry of app principals, each
name's entry and signer; and `Held`, the GATT services each admitted
package declares, by its app's name, which the package process keeps
from the admissions it has committed and drops for a package it
removes, refuses or replaces. It reserves no entry and answers none:
registration takes the entry the same rule (`erx_app_admit:entry/4`)
gives the name when the package is committed, the one check 4 found,
since the package process alone admits and registers, one package at a
time. It answers `{ok, Admitted}`, the indices of the facet rows kept
whole, the `packages` and `system` rows and one for each need; for a
declaration that names `gatt`, the `ble` row and the GATT services it
names, held apart from the kept rows as `ble`, so the `ble` row reaches
a session only narrowed to those services, through the one clause of
`erx_domain_core:app_session/4` that grants it, and never whole through
the kept rows ([An app's session](#an-apps-session)); the start row's
display, the declared memory, its `serves`, which the registry entry
keeps for the session's plan
([design-app-trees.md](design-app-trees.md#serving-erx_svc)), and the
signer, which registration records
for check 4 to compare, or `{error, Reason}`, the first of these that fails:

1. the manifest has an `apps` row: `no_apps`;
2. the header's ABI version and architecture are the image's: `{abi,
   Have, Want}`, `{arch, Have, Want}`;
3. the name is an **app name**: a system identifier
   ([design-system.md](design-system.md#identifiers)) that stays one with
   `_` and the digits of the `names` quota appended, not of a pooled
   name's form, not `root`, and not the name of a principal, configured
   domain, service or facet row of the manifest, nor of a package of the
   image when the header is an installed one's, which is property 5's
   reservation rule applied to the app's name; and one that
   `/etc/start.conf` can name: it begins with a letter, and its
   **variable name**, the name with each `-` replaced by `_`, is not that
   of a manifest `start` row, an image package or an app the registry
   holds under another name, so `my-app` is admitted and sets
   `my_app_enable`, and `my_app` beside it is refused
   ([design-apps.md](design-apps.md#the-start-table)):
   `{bad_name, N}`, `{name_taken, N}` or `{variable_taken, N, Other}`;
4. a name the registry holds has the same signer, `{signer_changed, N}`;
   a new name finds a free entry, `apps_full`;
5. the memory is a whole number of pages, at least `app_memory_min` and
   at most the `apps` budget: `{memory, M}`; the domain library's plan of
   the app's session refuses memory that is not page-aligned, so admission
   refuses it first;
6. each need is a service of the `apps` row other than `ble`, which
   only `gatt` takes: `{not_offered, S}`;
7. each name of `gatt` is one the `apps` row's `gatt` offers, which
   leaves out every service a configured domain's row names, since
   `ble_grant` refuses a service two rows name: `{gatt_not_offered, S}`;
8. no name of `gatt` is held by the admitted package of another app,
   `Other`: `{gatt_taken, S, Other}`. The app's own name is left out,
   so an update keeps the services its package held.

Nothing else is judged: a declaration can only name what the row
offers, so the build's proof over the row is the proof over the app.
Step 8 is the one judgment that depends on other apps, and its input
is the package process's own record of what it admitted, not the
registry, whose entries outlive a removal: a removed app's services are
free at once, and no session of it starts to use them (PK7).
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

* `erx-app pack DIR [--key FILE] [--output OUT]` compiles each `lib/APP/src` afresh,
  into a new `lib/APP/ebin` that replaces the old one whole, with the host's stock OTP 29.1.2
  `erlc`, `+deterministic`, against the SDK's public applications, and,
  when `DIR/Makefile` exists, runs `make` there with the SDK's variables.
  It then parses `app.txt`, checks that each application has its OTP
  application resource file, `lib/APP/ebin/APP.app`, or that the program
  exists and passes `erx_elf_plan` with the SDK's ABI version as a
  position-independent executable, as `erx_exec` takes it ([design-programs.md](design-programs.md#what-a-program-can-start)), writes the
  image from an mtree manifest with `fsimg`, computes the hash tree with
  the image's SHA-256 as its salt, writes the header with the
  SDK's ABI version and target, signs it with FILE's key or else the
  host's development package key, which it makes the first time it needs
  one ([The SDK](#the-sdk)), writes `NAME.app` in `OUT`, the current directory
  by default, with its build record beside it, and runs the file check on
  what it wrote, under the signing key, before the package replaces any
  `OUT/NAME.app`. A program is someone else's bytes, built outside the
  packer, by the app's makefile or by any build of the app's own: `erx_elf_plan`'s
  host build, the one reader of executable headers, plans it as the loader
  will, for the SDK's ABI version and the target's architecture, with the
  app's `memory` as the most its image may take, and the packer never runs
  it. The image holds the files below `bin/`, `share/` and each
  `lib/APP/ebin` and `lib/APP/priv`, but for names starting with `.`, which
  it leaves out, so a host's own files (`.DS_Store`, `._NAME`) never enter
  a package; it refuses a link or any file there that is neither a regular
  file nor a directory. Packing runs the app's own
  build steps, its parse transforms and its makefile, on the host: pack
  only sources you trust.
* `erx-app test DIR` runs the app's EUnit and Common Test suites on the
  host with the SDK's public applications and `erx_ui_host` on the code
  path.

### Adding an app to an image

`tools/erx pack --app X [--enable NAME] [--signer FILE]` takes an app
directory, which it packs with the SDK the tree exports into the build
tree, running that SDK's own `host/bin/erx-app`, so the exported packer
is the one path by which the tree packs an app, as it is a third party's;
or a package file, which it takes as it is and builds nothing; a package from
someone else is added as a file, and needs no trust in its signer. For
each package the build:

1. places it at `apps/NAME.app` in the slot's system partition, never in
   the boot image, which the packer's check of the boot image refuses
   ([design-storage.md](design-storage.md#data-model));
2. adds a `package NAME` row with `input` naming it and `enable YES` when
   `--enable` names it, `NO` otherwise; the packer records the header's
   SHA-256 in the row, as it records an image's root hash;
3. runs the manifest check, property 19's file check, admission and
   memory clause included;
4. judges the package's license as it judges an archive's: the package is
   attributed whole under the license its header declares, and registered
   as `permanent`, so a package whose license is not permissive is refused
   and one that names no license enters no image at all.

**A local test image** is the one exception: `tools/erx pack --app X
--local` builds an image that takes a package whose license is not
permissive, for its builder's own tests, such as the Doom demo on QEMU.
Such a package is registered as `package-local` in place of `permanent`,
and only a development build accepts a `package-local` license, so a
release build refuses it whatever asked for it. The image is marked
local in its build facts, whose configuration reads
`qemu-virt/development-local` and which `uname -i` shows; the kernel's
banner names the archive's flags, and no flag says local. A local image
never leaves the host that built it, and nothing distributes it: the
website's build (`tools/build_site.rb`) has no `--local`, and the images
it offers are made by builds that take no package of their builder's: the website's image
by `tools/erx boot --without-web`, and the card by the card build, which
refuses `--local` and every package of its builder's and adds only the
kiosk ([The shipped manifests](#the-apps-row)).
The site build takes the card only with the card's build record, which
names its commit, built with no changes, and takes the website's image
only with its build record, `image.boot.receipt.json`, which the
website's image build alone writes beside its `image.boot`, and only when
the tree did not move during the build: the image's SHA-256, the commit
it was built from and whether the tree had changes,
its build facts as its build-facts file holds them, and the packages it
carries. The site build refuses an image with no record, a record of
another image or commit or of a tree with changes, one whose
configuration is local, and one that lists a package. The record is not
signed: it keeps a local image off the site by mistake, and whoever
publishes the site is trusted not to forge one.

A development image also trusts, as its `development` signer, the public
half of the development package key of the host that builds it, the key
with which that host's packer signs by default, so packages the image's
builder packs install on it and no other developer's development key is
trusted. The key is no `signer` row: the build hands it to the manifest
check as a field of its context, which admits it only when the build
kind is development and packs it as the manifest's `development_key`
record, which the reader accepts in a development manifest alone. A
source row naming `development` as a signer is refused, so no board
source or added row stands in for the builder's key, and a release image
carries none. Neither a `signer` row nor the development key may be the
published package key ([The `apps` row](#the-apps-row)).

`--signer FILE` adds a `signer` row, so a deployer's machine trusts the
deployer's own key for packages installed later. The board's manifest
source is unchanged: the rows are the build's, recorded in the image's
build record with each package's SHA-256. `tools/erx app run DIR` builds
a development image with the app added and enabled, boots it under QEMU
with a display, and saves screendumps, as Doom's `run.rb boot` does.

### Starting an app

`erx_app`, an application of the `app` release, does nothing until the
app's record has come ([An app's session](#an-apps-session)): it asks
the connection agent for the record (`erx:app/0`), which answers once
the record has come. It depends
on `erx_session`, whose
command server starts a native app's program, so it starts only once
that server serves. Once the record has come, it:

1. mounts `/app` from the record ([An app's session](#an-apps-session));
2. for an Erlang app, adds each `/app/lib/*/ebin` at the end of the code
   path and starts each declared application with
   `application:ensure_all_started(App, permanent)`, its dependencies on
   the release's applications resolved from the release;
3. for a native app, starts its program with `erx_prog_handler:start/1`:
   the image `/app/` and the header's `program`, a `relative_path` the
   package reader checks, so it names a file of the image and nothing
   outside it; that path as `argv[0]`, the declared arguments after it,
   an environment of one entry, `ERX_START_FLAGS`, whose value is the
   session's own `ERX_START_FLAGS` copied as one string, never split or
   read, and empty where the session has none
   ([design-apps.md](design-apps.md#start-flags)), so a native app
   reads its start flags with `getenv` as an Erlang app reads them with
   `os:getenv/1`; `/` as its working directory and no right to
   start commands; and the spec's `window` option naming the session's
   default display, the environment's `display`, whenever the session
   has one, so the handler opens the
   window and binds its `/dev/draw`, `/dev/kbd`, `/dev/mouse` and
   `/dev/wctl` ([design-programs.md](design-programs.md#the-handler),
   [design-display.md](design-display.md#the-window-tree)); without,
   with standard input null and its output to the session's log. Its
   namespace is the session's. The start answers `{ok, Handler, Monitor,
   []}`, and the monitor's `'DOWN'` is the program's end:
   `{shutdown, {program_exit, Status}}` ends `erx_app` with
   `{program_exit, Status}`, and any other reason, the handler's own
   end, ends it with that reason.

An app's application environment is what its applications' own `.app`
files say, as on stock OTP with no `sys.config`: a package carries no
`sys.config` and `erx_app` sets no environment. Mix writes a project's
`application/0` `env` into its `.app` file, so a Mix project's defaults
for its own application arrive; what its `config/*.exs` files say about
any application does not, because Mix delivers that only through a
release's `sys.config` or `mix run`'s own loading. An app that needs a
value another application reads at its start sets it in that
application's `.app` file, which it ships, or changes it from its own
code once that application has started.

Elixir's `logger` needs nothing configured. Its start removes the
`default` handler, which in a session is `erx_log_h`, and adds
`logger_std_h` on `standard_io` with Elixir's formatter
(`lib/logger/lib/logger/app.ex:133-160` of Elixir 1.20.5), and
`logger_std_h` writes to `user` (`logger_std_h.erl:680`). A session has
no terminal, so what is written to `user` there becomes log records
under the session's name
([design-apps.md](design-apps.md#starting-a-session),
[design-live.md](design-live.md#attributed-text)): an Elixir app's log
lines reach the log as a UNIX daemon's output with no terminal does.
They arrive as text, with the timestamp and level Elixir's formatter
wrote into them; an app that wants its events' levels kept as the log
service's levels replaces the `default` handler from its own start with
one of module `erx_log_h`.

The app's paths come after the release's, so a module the app ships
under a name the release already uses is never the one the code server
finds first: a clash breaks only the app that brought it. A session's
code server runs in interactive mode, which loads a module from the
first directory of the path that holds it; `erx_app`'s host test, run
in that mode, checks it.

`erx_app` is permanent, so its end, a declared application's end and a
program's end each end the session, and the start row's keeper starts it
again within its intensity. A native app draws with Plan 9's draw
protocol and flushes when its frame is done, so no frame shows half drawn,
and reads its keys from `/dev/kbd`.

### The package lifetime

A **lifetime** is one run of the package process, `erx_pkg`. It owns the
packages' state and the package set it publishes from it, the slots of
the temporary files and the copies being written. Its effects are
carried out by two processes, each the one taker of its kind of effect:

* `erx_pkg_io` takes every read, write, create, rename, deletion and
  checkpoint request on `packages`, and every `remove_app`, and sends
  each to the storage service itself, and keeps the path table that
  the tree's walks, opens and reads are answered from, which the
  package process's `path_entry` requests fill ([Identity](#apps));
* the start service takes every publication of the package set,
  `erx_starter:packages/2`.

Each request names the lifetime it is for, the `erx_pkg` pid. Each taker
takes one request at a time and finishes the one it has begun before it
takes another, and refuses with `eio`, doing nothing, a request whose
lifetime has ended, which it tells with `erlang:is_process_alive/1`,
since `erx_pkg`, `erx_pkg_io`, the start service and the `apps` tree's
grants all run in the system domain's one runtime. A **copy
handle**, the handle of the `apps` tree's open of a copy, is the
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
whether a request of its predecessor was still on its way to the storage
service. The reset this costs is kept on purpose: restarting a process
does not withdraw a storage request it has already sent, so after an
abrupt end of `erx_pkg_io` only a boot's recovery starts from a
directory that nothing earlier still changes, while a restart of
`erx_pkg` alone needs no reset, since `erx_pkg_io` outlives it and takes
the recovery's requests after its predecessor's. It is a permanent child
with no restarts in the start service's application, which the system
release holds permanent, so its end ends the system domain and resets
the machine, and the boot's recovery, which no earlier lifetime
precedes, is the one that follows. It parses nothing but the storage
service's answers, which `erx_file_remote` checks, and every answer, an
error and a down storage domain included, is an answer it passes on, so
its end is a bug of the system domain like any other.

**A failed change ends the lifetime.** A request that fails while it
changes the directory, a rename, a deletion or a checkpoint, or a
temporary file's deletion, leaves a directory the package set may no
longer describe. The package process answers the request that caused it
with `eio` and ends its lifetime, so the next lifetime's recovery
reconciles the directory, the registry, the path table and the package
set, and the start service, which still holds the last set, starts no
session of an app that set dropped until the recovery publishes. A
failed read or write of a temporary file fails only its copy.

**Where the package process is supervised.** `erx_pkg` and the
processes its lifetime starts sit under a supervisor of their own,
`erx_pkg_sup`, which restarts `erx_pkg` within its intensity. That
supervisor is a temporary child of the start service's application's
top supervisor, and not a significant one
([design-apps.md](design-apps.md#concurrency)), so its end past its
intensity is not restarted and does not end the application.
`erx_pkg_io` is not under it: it is a child of the top supervisor, as
above, started before `erx_pkg_sup`. `erx_pkg`'s `init` returns at
once, and the recovery runs after it, one action per message, so a
recovery that crashes is a restart of `erx_pkg` within `erx_pkg_sup`'s
intensity, never a failed start of the application: a crash that a
restart can absorb never resets the machine, at boot as later. Past
that intensity the package process stays down: the `apps` tree answers
every request `eio`, and the start service keeps the last set it was
given and goes on running its rows.

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
| 1. the shell's `cp` creates `/apps/clock.app`, write-only and truncating, or a native `cp` opens the installed `clock.app` the same way with `lopen`; the `apps` tree accepts a name `NAME.app` with NAME an identifier that is not a name of the image's packages, and opens a fresh, empty temporary file in `packages/new/`, named `tmp.K` for the first of `max` slots that is free. An installed `clock.app` stays as it is, published and running | copies land on the same file system as their final name, so the rename is atomic; a temporary file has no name in `/apps`, so no other open can write it, and lies outside `installed/`, the one directory the app template's grant reaches, so no app reads or runs a byte the file check has not accepted; an update changes nothing until it has passed |
| 2. `cp` writes the bytes; each write is a request of the copy's handle to `erx_pkg_io`, at most `pkg_bytes_max` bytes in all | |
| 3. `cp` closes the file, and the close waits for the steps below. The writing open has ended, so nothing writes the file from here on | the bytes checked are the bytes published |
| 4. the package process runs the file check on the temporary file, its length and its first `pkg_header_max` bytes, under the name `clock.app` and with `{signers, Keys}` | a copy cut short, run on, too large or misnamed never gets a published name; only a trusted signer's package runs |
| 5. it admits the header ([Admission](#admission)); a name the registry holds needs its signer; a name the directory does not hold needs fewer than `max` installed packages there, admitted, refused or shadowed, or answers `enospc` | the authority check; signer continuity within a boot; the directory never holds more than `max` installed packages, so it always fits the recovery's bound |
| 6. it makes the temporary file durable | the rename must never publish a name whose bytes are not on the medium |
| 7. when the name holds an admitted package, it publishes the package set without the app, which answers once the app's sessions have ended | no session runs while its package's name changes (PK7); the old package ran until the new one had passed every check |
| 8. it renames `new/tmp.K` to `installed/clock.app`, one rename on one file system through its one grant, over the old package if there is one, visible at once, which `erx_pkg_io` takes after dropping the old package's entry from its path table, and makes the directories durable with a checkpoint request that carries the new package's `path_entry` request, which `erx_pkg_io` applies only when the checkpoint succeeds | the one commit point: the name holds the old package or the new, whole; the close answers only after it is durable; no read of an old open reads the new package ([Identity](#apps)) |
| 9. it registers the app's principal with its record, in the entry admission found | the record changes only with a committed package; the principal must exist before its row; the entry is still the one admission found, since only the package process registers and it decides one close at a time |
| 10. it publishes the package set with the app, and the close answers `ok`; the app's row enters the start table installed, with nothing of `start.conf` applied and nothing started ([design-apps.md](design-apps.md#the-start-table)) | the start service learns of the app, or of its new package |

A refusal at steps 1 to 6 deletes the temporary file, frees the slot,
and the close answers the refusal's errno ([Interfaces](#interfaces)),
with the reason in the log; nothing was published, the registry is as it
was, and an installed package of the name goes on running. A failure at
step 7, 8, 9 or 10, the publication, the rename, its checkpoint or the
registration, answers the close `eio` and ends the lifetime: the
recovery then admits whichever package `clock.app` holds, the new one if
the rename reached the directory and the old one or none if it did not,
registers its principal from that committed file, deletes the temporary
file, and publishes, so the app's row is installed again on the package
the name holds, stopped until its own `start`, and `cp`'s `EIO` means
the outcome is the one `ls -l /apps` and `/proc/packages` show. A power
cut before the rename leaves what the name held before, the old package
or nothing, and a temporary file, which the next recovery deletes; after
the rename and before its checkpoint, either what the name held before
or the new package, each whole; after the checkpoint, the new package,
which the next recovery admits. A session that ends with a copy open has
its open closed by the file service, and the close takes the same steps:
a file cut short fails the file check's length and is deleted, so a
half-copied file never gets a published name and never replaces one.

A registration applies a record the admission of a committed file
derived and occupies a preallocated entry, one of the table the domain
library sized at boot, so it allocates nothing and makes no atom that
the build did not count, and registering the same record again leaves
the entry as it was. It fails only as a call fails, when the principal
service does not answer. So
whatever ends a lifetime between the rename's checkpoint and the close's
answer, before the registration, after it and before its reply, or
before the final publication, the recovery's admission and registration
of the file the name holds leave the record and the package set that a
completed install would have left. A registration of the recovery's
that fails ends that lifetime too, as any failed change does, and the
next recovery registers again; past the supervisor's intensity the
package process stays down ([The package lifetime](#the-package-lifetime)).

Two copies of one name are two slots, and the package process decides
their closes in turn: each that passes replaces the package before it,
so the name holds the package of the last close decided. An update
stops the app: its sessions, the row's and a `onestart` one alike, end
at step 7, and at step 10 its row is installed on the new package and
starts nothing, whatever `start.conf` says, until `service NAME start` or
`restart` runs it, or the next boot does. Its data and its `start.conf`
settings stay as they were.

**Removing**, `rm /apps/clock.app`, reaches the `apps` tree as the
protocol's `unlinkat` of `clock.app`:

| Step | Why it must exist |
| --- | --- |
| 1. when the package is admitted, the package process publishes the package set without it | no session runs while its file goes |
| 2. it deletes `installed/clock.app`, which `erx_pkg_io` takes after dropping the name from its path table, visible at once, makes that durable, and the `unlinkat` answers `ok` | one durable deletion is the whole removal; no open reads past it |

A failed deletion or checkpoint answers `eio` and ends the lifetime, and
the recovery admits the package again if its file is still there. A
power cut before the deletion's checkpoint leaves either the package,
which the next recovery admits again, or none; after it, none. The app's
directory stays ([Where an app's files lie](#where-an-apps-files-lie));
its principal keeps its entry until reboot. `start.conf` lines naming the
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
packages from the manifest's `package` rows, reading each header at
`NAME.app` of the `system` tree through the `system` grant, which it
waits for as it waits for `packages`, and running the file check with
`{hash, H}`; an `unknown` boot serves no `system` tree, so it registers
none of them. Which names are the image's follows from the manifest's
`package` rows alone, not from what the `system` tree serves, so on an
`unknown` boot each such name is still listed, its reads answering
`eio`, a create of it answers `erofs`, and an installed package of it
stays shadowed, as on any boot. On a trial boot the block driver refuses every write but
the record's and the reset count's
([design-storage.md](design-storage.md#invariants) U4), so the recovery
is read-only there: it deletes no temporary file, which waits for the
next normal boot's recovery, and changes no shadowed package, and the
`apps` tree answers every create, write and remove, and the package
process every purge, with `erofs` before any request, so nothing of the
boot's package set changes and no lifetime ends on a write the trial
refuses. The package process reads the boot value as the update service
does ([design-storage.md](design-storage.md#system-updates)).
Once the `packages` grant is in place, which
it waits for as the start table waits for `start.conf`, it removes each
temporary file `new/tmp.K`, for each of the `max` slots, by its name,
an absent one answering `enoent`, so it lists nothing of `new/`, and
reads the listing of `installed/` and acts on it:

1. `erx_pkg_io` reads at most `pkg_scan_max`, 1,024, entries, one bounded
   read at a time, and reports whether more remain. A directory the
   package process wrote holds at most `max` installed packages,
   admitted, refused or shadowed (step 5 of an install),
   which property 19 keeps well under the bound;
2. when the directory holds more, the recovery acts on nothing in it: no
   installed package is admitted, every create and remove in `/apps`
   answers `eio`, and `/proc/packages` shows `scan` as `overflow` with
   the count read. Image packages are unaffected. Since no lifetime
   writes past those counts, the partition holds entries something else
   wrote: the administrator takes the medium to another machine and
   deletes the entries of `installed/` that are not `NAME.app`, as erXos repairs no data partition on the
   machine itself
   ([design-f2fs.md](design-f2fs.md#failure-handling));
3. otherwise, each
   `NAME.app` whose NAME is an identifier gets its length and its first
   `pkg_header_max` bytes read, the file check with `{signers, Keys}` and
   admission, in name order, each against the GATT services the image's
   packages and the installed ones admitted before it declare, a `path_entry` request for each package it lists, as
   the file check judges it; a package refused stays on the medium, listed in `/apps`,
   removable there and shown `refused` with its reason at
   `/proc/packages`, and its refusal is logged; an installed package
   whose name a system update gave to a package of the image is
   **shadowed**: it gets the file check, for its signer, but neither
   admission nor a registration, stays on the data partition as it is,
   and is listed in `/apps` as `.NAME.app`, a dot file, which an
   administrator may read and remove, and at `/proc/packages` as
   `shadowed`, with its signer; nothing deletes it but that removal, so a
   system update never loses an administrator's file, and once a later
   update drops the image's package of the name, the next recovery
   admits the installed one as any other; its app's directory stays;
4. an entry of no recognized form is left as it is, with a log line. No
   entry's name becomes an atom: names stay binaries until a
   registration, which takes one of the `max` entries;
5. when the registry already holds records, which only a recovery
   after the boot's first can find, it publishes the set of the
   admitted packages whose record the registry holds as it is. That
   set leaves out each app whose record a registration would change
   and each app whose package the recovery no longer admits, refused,
   shadowed or gone, so its answer comes once their sessions have
   ended, before any record changes (PK7). The directory may have
   changed under running sessions: a crafted storage domain can put
   back an older package of the same signer that declares other
   needs or GATT services ([Security](#security)), and a session
   whose grants were minted from an app's old record would otherwise
   run beside one minted from another app's new record, both naming one
   GATT service. At the boot's first recovery the
   registry is empty and no app's session runs, so nothing is
   published here;
6. it registers each admitted package; a record the registry holds as
   it is stays as it was;
7. the package process publishes the package set. The first set of a
   boot is the boot's package set, whose rows the start service's boot
   applies `start.conf` to as it applies it to the manifest's rows; a later
   recovery's set, after a crash or a failed change, adds the rows it
   adds with no record, so they show `installed`, and ends the sessions
   of each row it drops.

The recovery's publications are its lifetime's first, and the package
process takes no close, removal or purge until the last is answered, so the
first set of a boot holds what the image and the data partition held at
boot and nothing an install of that boot added.

A listing of `installed/` that cannot be read, the `packages` grant not
yet in place or the storage domain's error, leaves the scan `unknown`
and stops nothing: the boot's package set holds the image's packages,
which are published first. Installed apps that a late grant brings come
in a later set with no record, and `start.conf` does not enable them until
the next boot.

The recovery reads at most `pkg_scan_max` names and headers of at most
64 KiB each, one at a time, and keeps one record for each entry it
admits or refuses, whatever the directory holds (PK9). Boot, a crash of
the package process and a failed change all reach the directory through
this one path.

### The start table's rows

The start table's rows are in three groups, each after the one before:
the manifest's `start` rows, in its order; then the start rows of the
admitted image packages, in name order, each with its `package` row's
`enable` as its default; then those of the admitted installed packages,
in name order, each with `NO`. The order is the merge's, so where two
enabled rows name one display, the row of the earlier group takes it
whatever the names, and an installed app named `aaa` never takes a
display from an image app named `kiosk`. `start.conf` sets them as it sets any row
([design-apps.md](design-apps.md#the-start-table)). The merge's `Grants`
argument gives, for each row's principal, the `windows` services its
sessions will hold: a manifest principal's template's, and for an app
the `windows` services its admission kept, never the whole of the `apps`
row. So the merge refuses a display an app did not name with
`{no_grant, D}` and a display a kept row holds, whether the setting
came from `service NAME enable display=D` or from an edit of
`/etc/start.conf`; at boot an installed app never takes a display from a
row of the manifest or of the image, whose rows come first, and at run
time it takes none that a kept row holds. The boot's package set is
applied with the boot: `start.conf` sets its rows as it sets the
manifest's, and the rows the file enables start
([design-apps.md](design-apps.md#the-start-table)). Any later
publication changes only the rows it adds and drops, and applies
nothing of `start.conf`: it adds each row with no record, starting
nothing, so the row shows `installed`, with its package's declared
settings; and it ends the sessions of each row it drops and drops the
row's record; every other row stays as it was applied. An installed row takes
its settings from the file at its own `service NAME start`, `restart`
or `one` command, or at the next boot.

## The SDK

`tools/erx sdk export DIR` writes the SDK from a built tree:

| Part | Holds |
| --- | --- |
| `SDK.txt` | the erXos commit, `ERX_ABI_VERSION`, the target architecture, the OTP release (29.1.2), the minimum LLVM, `fsimg`'s version |
| `sysroot/<arch>/include` | musl's headers as erXos ships them; `erx/draw.h`, the draw protocol's message layouts, generated from `abi/formats/draw.txt`, with `erxdraw_put16` and `erxdraw_put32`, which store a field little-endian |
| `sysroot/<arch>/lib` | `libc.a`; `liberx_program.a`, liberx's program layer and entry, prebuilt, with the archives of the backend under `liberx` beside it ([design-programs.md](design-programs.md#what-a-program-can-start)); the compiler's builtins, each built once, position-independent, as the boot image's programs use them; the task link script, with its base 0, which lays a static position-independent executable out as the boot image's programs are laid out ([design-programs.md](design-programs.md#what-a-program-can-start), "The executable's link") |
| `share/erxos/sdk.mk` | make variables: the compiler and flags erXos's own programs build with, position-independent, and the link line, which links a static position-independent executable with no musl start file, `-pie --no-dynamic-linker -static -z norelro -z max-page-size=4096 --orphan-handling=error`, and never `-z pack-relative-relocs` |
| `share/licenses/LIB/` | the license notices of each library of `sysroot/<arch>/lib` |
| `erlang/` | the public Erlang applications as `.app`, `.beam` and `include/` files, `public.txt`, the list of public functions as `Module:Function/Arity`, and `erx_ui_host` |
| `host/bin/` | `erx-app`, the packer, and `fsimg`; `erx-lvgl` built for the host, for `erx_ui_host` |
| `host/erlang/ebin` | `erx_bytes` for stock OTP 29.1.2, a model of the per-byte primitives that stock lacks, with which the packer runs the file check on the host |

**The development package key.** No private key enters an SDK, which is
handed to others. The packer makes its own development package key, an
Ed25519 key, the first time it signs without `--key`: one per user and
host, in `~/.erxos/package-key/development.key`, a file of mode 0600 in a
directory of mode 0700, made in a fresh directory that is renamed into
place, so no half-made key is ever in place. It is a key of its own,
apart from the development login key
([design-ssh.md](design-ssh.md#login-keys)) and the development update
key ([design-storage.md](design-storage.md#system-updates)), so a
package's seal stands for nothing else. A development image trusts the
public half of its builder's key ([Adding an app to an
image](#adding-an-app-to-an-image)), so a third party's packages are
trusted only by the images that party builds, and the tree packs with the
same key, since `tools/erx pack --app` runs the exported packer; only the
card's kiosk is sealed by the published package key instead
([The `apps` row](#the-apps-row)).

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
| a program's `main`, its standard descriptors, and a program that draws: `/dev/draw` with the draw protocol and `erx/draw.h`'s layouts and `erxdraw_*` stores, `/dev/kbd`, `/dev/mouse`, `/dev/wctl` | the channel, the program protocol and the startup message |
| `app.txt`'s grammar and the package format | the boot image, the manifest and its rows |
| Erlang, for an app whose package declares `gatt` ([design-bluetooth.md](design-bluetooth.md#the-client)): the behaviour `erx_gatt_service`, its `start_link/3` and `call/2` and its callbacks `init/1`, `handle_write/4`, `handle_event/2`, `handle_call/3` and `handle_info/2`, with the events `handle_event/2` receives (`connected`, `mtu`, `subscribed`, `disconnected`) and the answers a write's reply may be; `erx_gatt:set/3`, `notify/4` and `indicate/4`, called from those callbacks, with their answers and the exit `{not_attached, Service}`; `erx_gatt_serial:start_link/2` and `send/2`, with the `{serial, Conn, Bytes}` messages and events it sends its owner | `erx_gatt:attach/1` and `reply/2`, which the behaviour makes; the `ble` facet's operations as messages, the envelope `erx_gatt` takes off, and the modules of the Bluetooth domain |
| Erlang: `erx_ui:open/1`, `tree/2` and `close/1`, its messages and the widget schema of `abi/formats/ui.txt`, whose properties and bounds `erx_ui_schema:property/1` gives as [design-display.md](design-display.md#widget-trees) states, with the types its spec names, and its trees, of type `erx_ui_schema:tree()`; `erx_win` and `erx_draw`'s exported functions, for an app that draws itself; `erx_prog_handler:start/1`; stock OTP 29.1.2 | every other function of erXos, `erx_ui:start/1` and the modules `erx_ui_lvgl` and `erx_ui_model` among them |

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

`examples/` holds app directories that are not part of erXos: no
release script, application list, manifest or test list names one, and
erXos's own build compiles none into the system. A file of the build's tools, the board manifests or the host
tests' build fixtures names an example only if it is one of the few
that fetch, pack or build one, each listed with the design text that
names it (`ExampleLists::EXEMPT`; `make check` refuses the name in any
other): the fetch step below, the card's kiosk and the kiosk suite's,
and Doom's build for the published media. An app example is packed as
a third party packs one, through the SDK, which is how the gates pack
and test `examples/dashboard` and how the card and the kiosk suite
carry it; Doom alone is compiled by the published build itself, as a
program of the domain release, and no gate builds it (below).
A name is not source: the build names an example's directory and the
files it compiles, and no line of an example's source enters the
tree.

* **`examples/dashboard/`**, the kiosk dashboard, erXos's own code under
  its license: `app.txt`, `lib/erx_dashboard/` and its host test, which
  checks a frame through `erx_ui_host` against
  `test/display/reference/dashboard`. It shows the clock, the date and
  live quotes: its `app.txt` needs `display net`, and the modules
  `erx_quotes` and `erx_quotes_{table,core,http,extract,view}` of
  `lib/erx_dashboard/` fetch the quotes from the sources `erx_quotes_table`
  names; the live quotes' host tests, run through
  `test/host/erx_quotes_test.rb`, and their fuzz target, which the landing
  gate runs at a small budget and `make check-fuzz` at its configured one
  ([its README](../examples/dashboard/README.md)).
* **`examples/doom/`**, the Doom demo, structured as a separate app:
  `ORIGIN.md` beside `doom/`, a git submodule pinned by its gitlink, as
  `display/lvgl/lvgl` is ([design.md](design.md#dependencies)). The
  submodule's repository is erXos's fork of doomgeneric, under
  GPL-2.0-or-later: upstream's history, then erXos's commits. They hold
  the platform layer, in `doomgeneric/` beside upstream's own platform
  layers; the app's `app.txt`; a `Makefile` over the SDK's `sdk.mk`; and
  a list of pinned downloads in `deps.lock`'s form, for Freedoom's WAD.
  erXos's tree holds only the gitlink, a commit id, so no GPL code
  enters the tree. `git clone` does not check it out, and `tools/erx
  fetch` fetches it, and its downloads against their SHA-256, only with
  `--example doom`, which clones the submodule with no history and
  publishes the downloads, parsed and verified as `deps.lock`'s sources
  are, under `build/examples/doom`, a root of their own, and takes only
  file, tar and zip downloads; no part of
  `make check`, the landing gate or the milestone gate builds it. 0.1's
  published media carry it as `/bin/doom`, a program of the domain
  release, not as a package: the published build, `tools/erx pack
  --published` (the published kind of [the shipped
  manifests](#the-apps-row), the only kind that carries it), compiles
  the fork's sources with Freedoom's WAD linked in
  (`tools/lib/erx/doom_program.rb`, which names the files it compiles).
  A builder's `tools/erx pack --medium` and every harness pack a medium
  without it, and need nothing of the fork. The media offer the gitlink's
  commit as their source, so the build refuses a fork that is missing
  or does not hold that commit, and compiles a snapshot of the commit
  written from its blobs under `build/`, never the checkout's working
  files, which can differ from the commit where `git status` does not
  show it. Where the checkout stands is no part of the build, and the
  tree's source revision (`uname -v`, the image record) leaves the fork
  out, so git never runs a status in it under its own configuration. Its row in the
  dependency table has the status `example`, which the image build accepts
  for its archive alone ([design.md](design.md#dependencies)); every
  other package that is not permissive stays out of every image but a
  local one (step 4 of [Adding an app to an
  image](#adding-an-app-to-an-image)).
  No erXos code includes it; only the published build compiles and
  links it, so working on erXos needs reading it only for that build.

To the packer each app example is an app directory with an `app.txt`,
as is a third party's anywhere on disk. The landing gate exports the SDK, packs
and host-tests `examples/dashboard` with nothing
but the SDK on their paths, and checks that every call each example makes into erXos's
modules is one of `public.txt`'s functions, so a change that breaks the
boundary fails there.

## Interfaces

An administrator installs, updates, lists and removes apps with the
shell's own `cp`, `ls`, `cat` and `rm` in `/apps`, looks inside one with
`mount` and `umount`, enables, disables and purges them with `service`,
and reads their state with `cat` under `/proc/packages`; there is no
command of packaging's own. `/proc` is read-only, as all of it is
([design.md](design.md#decisions)): it shows what an app's state is, and
takes no command.

**`/apps`**, the `apps` tree ([`/apps`](#apps)), as the shell sees it:

| Operation | Result |
| --- | --- |
| `cp NAME.app /apps/` | installs, or updates the installed app of the name, whether `cp` creates the name (`lcreate`), as the shell's does, or opens the installed package write-only and truncating (`lopen`), as a native FreeBSD `cp` does. Errnos at the create or the open: `einval` for a name not of the form `NAME.app` with NAME an identifier, or an open that appends, also reads or, at an `lopen`, does not truncate; `eio` at an `lopen` of a node whose name holds another package since its walk, or none; `erofs` for a name of the image, and for every name on a trial boot; `eexist` for an exclusive create of a name `/apps` holds; `enospc` while `max` copies are open; `eagain` while the `packages` grant is not in place; `eio` while the directory is past the scan bound. A write past `pkg_bytes_max`, 1 GiB, answers `efbig`. Errnos at the close: `efbig` for a file past the size bound; `einval` for a file the file check refuses for its header, its length or its name, or whose name is not an app name; `eacces` for a header that names no trusted signer or carries a bad signature; `eperm` for an admission refused by `no_apps`, ABI, architecture, memory, need or a GATT service the row does not offer; `eexist` for a name of the manifest, or one another signer holds in this boot, or a GATT service another admitted app declares; `enospc` for no free entry, or for a new name while `/apps` holds `max` installed packages, admitted, refused or shadowed; `eio` for a failed read, write, publication, rename or checkpoint of `packages`, or a lifetime that ended. After every refusal the installed package of the name, if any, is published and running as before |
| `rm /apps/NAME.app`, `rm /apps/.NAME.app` | removes the installed package, or the installed package of the name that an image package shadows, and answers `ok`; `enoent` for no package of the name; `erofs` for a package of the image, and on a trial boot; `eio` for a failed deletion or checkpoint, a directory past the scan bound, or a lifetime that ended |
| `ls /apps` | every package, installed or of the image, admitted or refused, each a regular file; with `-a`, each shadowed package too, as `.NAME.app` |
| `cat`, `cp` from `/apps/NAME.app` | the package's bytes; `eio` for a header changed on the medium since its check, for every read of a package the file check refused, or once the name holds another package or none since the open, for every read that reaches the tree |
| `mount /apps/NAME.app DIR`, `umount DIR` | mounts the package's image read-only at `DIR`, and ends the mount; the mount is refused with the reader's answer for a header that does not decode or an image the reader refuses, and `eio` for a header the tree refuses; below `DIR`, `eio` for a block that fails its hash, and once the package is removed or replaced, the old package's bytes from the mount's cache and `eio` for every block it reads again, never a byte of the replacement; `enotsup` for an inode of a layout the reader lacks |

The reason of every refusal goes to the log. Who holds `start`, and so
`apps`, is the manifest's ([design-apps.md](design-apps.md#interfaces)).

**The `apps` tree**, in the system domain, takes `lcreate`, `lopen`, `write`,
`clunk`, `read`, `getattr`, `readdir` and `unlinkat` as [`/apps`](#apps)
says, with the same errnos. Its `clunk` answers the copy's verdict,
which the file service passes back to the client once the grant
has run it
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).

**The start service** gains `erx_starter:packages/2`, by which the
package process publishes the package set; it answers once every session
of an app the set drops has ended, and refuses a publication whose
lifetime has ended. It is a call of the package process alone. Its `ctl`,
at `/etc/start/ctl`, takes `purge NAME`, which `service NAME purge`
writes; its errnos are `einval` for a name that is not an app name,
`ebusy` for a name an installed package holds that no image package
shadows, `erofs` on a trial boot, and `eio` for a failed `remove_app`
([design-apps.md](design-apps.md#interfaces)).

**Inspection**, in `abi/inspection.txt`, reported by the package process
and shown at `/proc/packages` to an inspect facet of scope `all`:
`[packages]`, of kind `packages`, gives `scan` (`ok` or `overflow`, with
the entries read), `room`, the `apps` budget left as the kernel reports
it, and lists the packages by name; `[packages, Name]` gives `version`,
`memory`, `place` (`system` or `installed`), `signer` (a `signer` row's
name, `development` or `image`),
`state` (`admitted` or `refused`), `reason`, `needs` and `license` of
the package `/apps/NAME.app` shows, and `[packages, Name, shadowed]` the
same fields, with `state` `shadowed`, of the installed package of the
name that an image package shadows, listed in `/apps` as `.NAME.app`,
so each path names one package. An
app's start row, with whether it is enabled, is at `[apps, Name]` and
its sessions at `[domains, Id]`, as any row's and any session's.

**Manifest rows**: `apps`, as in [The `apps` row](#the-apps-row);
`package`, with `input` naming the package's artifact and `enable`,
whose header hash the packer records; `signer`, with `key`, written
`hex:` and 64 hexadecimal digits, under any name but `development`. Their packed records, the
`development_key` record and the readers' bounds are in `abi/manifest.txt`, with the limits `apps_max_limit`,
`apps_max_default` (8) and `signer_key_bytes` (32), and the names
`packages_service` and `system_service` of the services the `packages`
and `system` rows grant; the facet parameter
`tree` is in the storage service's schema. `erx_pkg_manifest:system_config/1` is the one
Erlang reader of them, through the generated manifest reader, and of what
admission reads beside them: the app template, the one session template
naming no principal; its `packages` and `system` rows and each service's row, the facet
rows granted to that template's sessions; and the reserved names. It
refuses an `apps` row without exactly one of each, as the domain library
places no app entries without the template.

**The ABI source**: `abi/formats/package.txt`, the header and the packed
declaration; the limits `app_memory_default`, `app_memory_min`,
`pkg_version`, `pkg_header_max`, `pkg_needs_max`,
`pkg_applications_max`, `pkg_program_max`, `pkg_args_max`,
`pkg_args_bytes_max`, `pkg_license_max`,
`pkg_bytes_max` and `pkg_scan_max`.

**Erlang**: `erx_pkg_header:decode/2` and `check_file/2`,
`erx_verity_tree:blocks/1`,
`erx_app_admit:admit/4`, `erx_pkg_plan:install/3`, `remove/2` and
`recover/2`, `erx_principal:register_app/1` and `app_registry/0`, the
boot's registry of app principals that admission reads; in a session, `erx_app`,
and `erx_ns:mount/3` with `{erofs, app}`, the session's own package from
its record, or `{erofs, {header, Path}}`, only for a file reached
through the `apps` grant; neither takes a layout.

### Other subsystems

| Subsystem | Its part |
| --- | --- |
| the manifest check ([design-system.md](design-system.md#the-manifest)) | the `apps`, `package` and `signer` rows and the rows derived from `apps`; property 19; A10 holds, since an app selects among rows the manifest set |
| the root task and the resource policy | the `apps` budget carved from the root at boot as a wall, the apps group under `users`; an app principal's wall carved under it for each of its sessions, at the declared memory and the session's outer budget, and destroyed at that session's retire |
| the domain library | the principal table sized for the manifest's principals and `max` apps, whose app entries `erx_dom_apps_place` puts after the manifest's principals, with no budget at boot; `erx_dom_plan_app_session` planning an app principal's session from the app template, which `erx_dom_plan_session` refuses |
| the domain service | the app's session: its principal's wall, carved from the `apps` budget at the start and destroyed at the retire; the kept rows, and the app's record, with its package's place and layout, sent once the session's namespace is in place |
| the principal service | `register_app/1`, which takes the committed package, called at a committed install or update and at recovery; `app_registry/0`, the registry admission reads; no app principal is unregistered within a boot |
| the start service ([design-apps.md](design-apps.md#the-start-table)) | its tree at `/etc/start`, holding `ctl`; the package rows after the manifest's; `packages/2`, answered once the dropped apps' sessions have ended and refused for an ended lifetime; the merge's grants for an app from its admission; `purge` in its `ctl` |
| the file service ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)) | a tree's `clunk` answers `ok` or `{error, Errno}`, and `erx_fs` answers the client's clunk with it once the grant has run it, after every request sent before it through the fid; the fid ends whatever the answer, as clunk(5) says; the `apps` facet mounted at `/apps` as any facet with a mount point; a session's export naming each local provider's tree when it is mounted ([design-files.md](design-files.md#narrowing-for-a-program)) |
| the shell ([design-shell.md](design-shell.md#commands)) | `cp` opens its target itself, copies in pieces as its info report needs, and reports a failed close of the target as it reports a failed write; `mount FILE DIR`, the EROFS mount `{header, FILE}` of a package file of `/apps`, `ro`, `einval` for any other file; `service NAME purge` |
| the storage service ([design-storage.md](design-storage.md#interfaces)) | the `packages` tree, the data partition's directory, with `new/` and `installed/` and `tree installed` rooted at `installed/`; the `system` tree, the booted slot's system partition's `apps/`, read-only, from the storage domain that serves `system`; `apps/` and `tree apps`, rooted at `apps/NAME/SIGNER/`; `remove_app` on the durability facet |
| the EROFS reader | `erx_verity` reading an image from one fid of a file, which `erx_ns`'s process opens and owns and every reading process of the session sends its reads on, at an offset, with a layout `erx_ns`'s process took itself, from the app's record for `/app` or from the header the `apps` tree served through the same fid for the shell's `mount`, at rights no wider than that fid's grant's; and, in the storage domain that serves `system`, the system partition's own image, read through `erx_verity` over its window against the root hash of that domain's boot record ([design-storage.md](design-storage.md#the-system-tree)) |
| programs ([design-programs.md](design-programs.md)) | an executable file from `/app/bin`; `open` through the handler; `erx_prog_handler:start/1` with a window |
| the display ([design-display.md](design-display.md#the-window-tree)) | a program started with a window; `erx-lvgl` in every image whose release holds `erx_ui` |
| live code ([design-live.md](design-live.md#the-code-store)) | an app principal's overlays live in memory only |

## Concurrency

The package process, `erx_pkg`, a process of the start service's
application, owns each package's name, layout, admission and state, and
publishes the package set from them; each listed package's qid path,
header hash and header extent are held only in `erx_pkg_io`'s path table
([Identity](#apps)). It takes one close, removal or purge at a time, in
the order they arrive, so two copies of one name closed together are
decided in turn, and the later one, if it passes, replaces the earlier.
It does no file operation itself: every request on `packages` and every
`remove_app` runs, one at a time, in `erx_pkg_io`, which answers each
request when it is done, so a slow storage domain delays a close, a
removal or a walk, `getattr` or read of `/apps`, each of which waits
behind a slow checkpoint `erx_pkg_io` has begun, but not the package
set's answers or the start table. The `apps` tree's `clunk` of a copy
waits, in the closing client's grant, for the package process's answer
before the grant answers the close, as a callback waits for its tree's
processes ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)). The
package process waits for the start table at each publication, and the
table never waits for the package process, so the two never wait on each
other: a purge is awaited by the `ctl` write's callback in the writer's
grant, not by the table, and the package process takes it in turn with its closes
and removals, after the publication of the one it is carrying out
([design-apps.md](design-apps.md#concurrency)).

A lifetime's effects are taken only while it is alive, by `erx_pkg_io`
and the start service, each one at a time
([The package lifetime](#the-package-lifetime)). A crash of the package
process ends no session but those of the apps whose record the next
lifetime's recovery changes or whose package it no longer admits, which
its first publication ends before it registers anything
([Boot and recovery](#boot-and-recovery), step 5); the recovery rebuilds the set
from the manifest and the directory and publishes it, and until then the
start service keeps the last set it took. A crash between a publication
without an app and its deletion, or the rename of its update, leaves the
app stopped; the recovery's publication brings its row back with no
record, `installed`, on whichever package its name then holds, and its
own `start` runs it. A crash of the start service's table process loses
nothing the package process holds: on its restart it takes the last set
it took from its records process, and applies `start.conf` to the rows it
holds no
record for only when the boot mark says the boot is not done, and
otherwise leaves them with no record, `installed`
([design-apps.md](design-apps.md#concurrency)).
The registry of app principals belongs to the
principal service and only grows within a boot, and the package process
writes a record only for a committed package, so a crash leaves no
record of a package that was never committed.

A mount of a package is an entry of the session's namespace like any
other, changed only by `erx_ns`'s process
([design-files.md](design-files.md#building-binding-and-mounting)): it
holds one fid of the package file, which `erx_ns`'s process owns, from
`mount` until `umount` or the session's end, and every process of the
session that reads below its point sends its reads on that fid, in its
own process, as every EROFS mount is read
([Looking inside a package](#apps)). No reading process owns the fid or
shares an OTP file descriptor, so two processes read at once, and a
reader's end clunks nothing. An unmount clunks the fid; a read still on
its way then meets no fid and answers `ebadf`, which `erx_verity`
answers as `eio`. Nothing in the system domain follows mounts.

## Compatibility and migration

The package format, `app.txt`'s grammar and the `apps`, `package` and
`signer` rows owe nothing to earlier forms
([design.md](design.md#decisions)). A package built for another
`ERX_ABI_VERSION` or another architecture, after a system update or
before it, is refused with `{abi, Have, Want}` or `{arch, Have, Want}`
and shown so; it stays on the medium, counted among the directory's
`max` installed packages, until the administrator removes it and copies
in a rebuilt one. A package whose need an update's `apps` row no longer
offers is refused with `{not_offered, S}`, and one whose GATT service
it no longer offers with `{gatt_not_offered, S}`; its data stays.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | What happens |
| --- | --- | --- |
| a file fails the file check: its size, header, length, name or signer, or its hash differs from its `package` row | `erx_pkg_header:check_file/2`, the package process | a copy's close answers its errno and nothing is published, and an installed package of the name goes on running; a package found on the medium is `refused` with the reason at `/proc/packages`; an image package refused at boot leaves its row out of the table |
| admission refuses | `erx_app_admit:admit/4` | as above, with the reason |
| an app's session does not fit what is left of the `apps` budget | the kernel's carve, through the domain library | the start answers `no_memory` naming the `apps` budget; the keeper counts an end, and the row goes down past its intensity, with the reason at `/proc/apps` |
| a block of the image fails its hash | `erx_verity` in the reading session | the read answers `eio` with a log line naming the image and block; in the app's session the code load or file read fails, the session ends, and the row counts an end, with the reason at `/proc/apps`; at a mount of a package the `ls` or `cat` fails |
| a header changed on the medium after the file check | the `apps` tree's hash check | reads of the header answer `eio`, so a `mount` of it is refused; the app's own session holds the layout from the record and fails at its first block |
| the image does not mount | `erx_app`, the shell's `mount` | the app's session ends at its start with the reader's reason; `mount` answers the reader's refusal and changes no namespace |
| an inode of a layout the reader lacks, compressed or chunked | `erx_erofs` in the reading session | that file answers `enotsup` where it is reached; in the app's session as any failed load or read |
| a package removed or replaced under an open or a mount | `erx_pkg_io`, by the qid path the open recorded, which its path table no longer holds | reads that reach the tree answer `eio` until the file is closed or the mount ended, while a read-ahead buffer or a mount's cache answers the old package's bytes; a new open or mount reaches the new package |
| a missing application or a refused program | `erx_app` | `erx_app` ends with the application's start error or `{program, Reason}`, and the session with it |
| the storage domain that serves `system`, or the data partition's, is down at boot | the package process's reads through `system` and `packages` | the image's packages wait for the first, the installed ones for the second; their rows are absent until the recovery runs |
| a failed publication, rename, deletion or checkpoint | `erx_pkg_io`'s or the start service's answer | the request answers `eio`, the lifetime ends, and the recovery reconciles the directory, the registry and the set; an app stopped for an update is installed again on the package its name holds, stopped until its own `start` |
| a crash of the package process | its supervisor | open copies answer `eio` at their next write or close and publish nothing; the recovery deletes their temporary files, stops each app whose record it changes or whose package it no longer admits before it registers, and publishes the set, those apps' rows `installed` and stopped; past the supervisor's intensity the package process stays down and `/apps` answers `eio` |
| an end of `erx_pkg_io` | the start service's application | the system domain ends and the machine resets; the boot's recovery follows |
| a power cut inside an install, an update or a removal | the recovery | temporary files are deleted; each name holds one package whole, the old or the new, or none |
| the package directory holds more than the scan bound, which only entries no lifetime wrote can make | the recovery | no installed package is admitted; `scan` is `overflow` at `/proc/packages`; creates and removals in `/apps` answer `eio`; the partition is repaired on another machine |
| no free entry | admission | `apps_full`, until a reboot frees the entries of removed apps |
| `max` installed packages, admitted, refused or shadowed, and a copy of a new name | the package process, at the close | `enospc`, until a package is removed |

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
  most 64 KiB, read through a generated reader with fuzz targets over
  the decoder and the whole file check, locating the declaration, key
  and signature in bytes an attacker wrote, truncated at each field and
  with every length out of bounds. The image is parsed only by a
  session, the app's own or a person's that mounted it, whose failure is
  its own: a crafted image fails reads at the EROFS reader's checks, and
  a directory it lists, which the reader reads whole, costs the listing
  process memory within the package's size and that process's heap
  limit, never anything of the system domain.
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
  of other packages through `packages` and `system`, which hold nothing
  secret: a package holds what its author ships, the app template's
  `packages` grant reaches only `installed/`, and the `system` tree's
  grants reach only its packages. It cannot write a package, read or
  run an upload in progress, install one, reach another app's directory or domains, or change the
  start table.
* **Code against a crafted data partition, or a storage domain it took
  over.** It can withhold or delete packages, put back an older package
  of the same signer, and swap an installed package for another package
  of the same name and signer. Across a reboot it can also put another
  trusted signer's package of an installed name in its place, which the
  next boot admits and starts by the name's `start.conf` settings, with a
  data directory of its own: trusted keys authorize packages in general,
  and a name stays bound to its signer only within a boot. It cannot run
  code no trusted signer signed, change a byte of an image any session
  reads, widen a grant, make a running session keep a grant its app's new
  record does not give, and so two live sessions hold one GATT service
  (PK7, PK13), start an app with no start row, steer a purge at
  anything that is not an app (PK8), or make the recovery spend past its
  bound (PK9). Refusing an older package needs a counter the platform's
  trust root keeps, as for system updates
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
* **Development builds** trust their builder's development package key,
  which no tool copies off the building host, so a package another developer
  packed is trusted only by the images that developer builds; they run
  trusted code only, and say so in their banner. The Raspberry Pi 4's
  card, which the website offers, trusts no key, and its kiosk is sealed
  by the published package key, which nothing trusts
  ([The `apps` row](#the-apps-row)).
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

## Verification and testing

Each test is paired with a seeded fault that proves it runs the code it
guards; the faults below are the ones each test must catch.

**The approach.** Admission is one pure function, so one corpus runs
through the machine's module and through the packer's host run, and the
build and the machine cannot disagree on a package (PK10). The install,
update, removal and recovery planners run against a simulated package
directory that records every write, cuts power after each and reorders
the writes between checkpoints, as
[design-storage.md](design-storage.md#read-write-storage)'s harness
does; it separately answers `eio` to each publication, rename, deletion,
checkpoint, registration, read and write in turn, and ends the lifetime
of an update before its registration, after its registration and before
its reply, and before its final publication. Every resulting state must
recover with each name holding one package whole, the old or the new, or
none, no temporary file, a package set that matches the directory, a
principal record that matches the package its name holds, and no session
of a dropped app started between the failure and the recovery's
publication (PK6, PK11). The `apps` tree is tested through the real
client, the shell's `cp`, `rm` and `mount`, and through a write-only,
truncating `lopen` as a native `cp` sends it; the start service and the
package process run together, over a stub `erx_pkg_io` that can hold a
request, for the races between a publication and a command.

**Host tests and their seeded faults.**

* the declaration's parser: the bound on `needs` removed, which packs
  seventeen needs;
* the decoder, reached through `check_file/2` and through the `header`
  mount alike, which must refuse with the same reason: a decoder that
  takes the header's tree length as written, which accepts a tree one
  block off; a `header` mount that skips the decoder's checks for bytes
  the tree authenticated, which accepts nonzero padding through it alone;
* the file check: one that skips the signature, which accepts a flipped
  byte; one that reads the signer under `{hash, H}`, which refuses an
  unknown key whose package matches H; the length check made "at least",
  which accepts a file one byte too long; at the close and at the recovery, a
  recovery that admits without the file check, which admits a misnamed
  and a short file;
* admission: the subset test of step 6 dropped, which admits a need the
  row lacks; `root` dropped from the reserved names; the variable names
  compared unmapped, which admits `my-app` beside `my_app`; the
  registry's own entry for the name counted as another's, which refuses
  an update; over an `apps` row offering `nus` and `nusb`, with the
  admitted package `a` holding `nus`: the subset test of step 7
  dropped, which admits a package declaring `nv`; step 8 dropped, which
  admits `b` declaring `nus`; step 8's own name counted, which refuses
  `a`'s update declaring `nus` and `nusb`; `Held` taken from the
  registry, which refuses `b` declaring `nus` after `a`'s removal;
  `needs ble` admitted, which keeps a `ble` row naming nothing;
* the planners: an install that renames before the temporary file is
  durable, after which a reordered cut leaves a published name with
  missing bytes; an update that deletes the old package before its
  rename, after which a cut between the two leaves no package; a removal
  whose failed deletion answers `eio` without ending the lifetime, after
  which the set and the directory disagree; a failed registration that
  goes on to publish, after which the published row runs with the
  earlier package's memory;
* the package lifetime, with two copies writing and a close waiting when
  the package process is killed: an `erx_pkg_io` that takes a request
  without checking its lifetime, after which the waiting close's rename
  lands after the recovery's listing; a slot freed at the crash, before
  the recovery's deletion, after which a new copy takes a slot whose file
  is still on the medium;
* the package process past its intensity, after which the start
  service's application, its keepers' sessions and `erx_pkg_io` live on
  and every request to `/apps` answers `eio`: `erx_pkg_sup` made a
  permanent or a significant child, which ends the application and the
  running sessions;
* the principal's record, across an install and an update refused at the
  file check, at admission and at the checkpoint: a registration before
  the rename is durable, which writes the refused memory;
* an update of a running app: an update that renames before it publishes
  the set without the app, which leaves the old session alive across the
  rename; a publication that applies `start.conf` to the row it adds,
  which starts the new session at the update;
* a publication that drops an app: one answered before the app's
  sessions end;
* purge targets: the app-name rule skipped, which sends `remove_app
  root`; a `remove_app` that removes `apps/NAME` whole, which removes the
  image app's directory `apps/NAME/image` that must stay; a purge that
  sends `remove_app` on a trial boot, where it answers `erofs`;
* the recovery's bound: the bound check removed, which reads a listing
  of `pkg_scan_max` + 1 entries whole;
* the GATT services the package process holds, over an image package
  and an installed one that both declare `nus`, as a system update can
  leave them: a recovery that admits the installed packages first, which
  refuses the image's; a removal that leaves its package in `Held`,
  which refuses another app's install of `nus` until the next boot;
* a recovery after the boot's over a directory changed under running
  sessions, the registry holding `a` with `gatt nus`, `b` with `gatt
  nusb` and `c` with none, each running, and the directory holding
  packages of the same signers that give `a` no `gatt`, `b` `gatt nus`
  and `c` its record as it is: the plan publishes a set holding `c`
  and neither `a` nor `b` before any registration, then registers `a`
  and `b`, then publishes all three, `c` running throughout; seeded: the
  registrations before the first publication, which registers `b`
  with `nus` while `a`'s session runs on it; the first publication
  leaving out only refused packages, which keeps `a` running; every
  installed app left out, which stops `c`; the first publication made
  at the boot's first recovery too, which gives the boot an empty first
  set to apply `start.conf` to;
* entries and the directory's bound: a removal that frees the entry,
  which lets `max` + 1 names install in one boot; a bound that counts
  admitted packages alone, which installs a new name beside `max`
  packages an ABI change left refused;
* the start table's grants and order: the merge given the app template's
  whole grant set, which accepts a `start.conf` display the app did not
  need; the package rows sorted by name alone, which gives a display an
  image app `kiosk` and an installed app `aaa` both claim to `aaa`, where
  the image app takes it and a manifest row takes it from both;
* the app session's plan in `erx_domain_core`: a plan that grants every
  row of the template; a scope computed from the template's key; a plan
  that grants an image package the template's whole row set, which the
  comparison of one header admitted both ways catches (PK10);
* the storage mint's root: a root of the name alone, where one name under
  two signers and as an image package gives three roots, `apps/N/<hex>`,
  `apps/N/<hex2>` and `apps/N/image`;
* the `apps` tree's header reads: the hash check removed, which serves a
  header changed on the medium after the check;
* the package mounts in `erx_ns`: a mount that takes its rights from its
  options, which mounts the `/apps` file `rx`; one whose rights are only
  bounded by the grant's, which mounts it `rw`; the app template's grant
  rooted at `packages/` rather than `installed/`, which walks to an
  upload's `tmp.K`; a `header` mount that judges the path's first name
  rather than the grant its fid came through, which mounts a `/tmp` file
  once the session binds `/tmp` at `/apps`;
* refused packages: a tree that serves a package the file check refused
  from the bytes the recovery read, which answers its header, where such
  a package is listed with its length, its reads answer `eio` and its
  mount is refused;
* the `apps` tree's names and identity: an `lopen` passed to the default
  open, which truncates the installed package in place; a check of the
  node's name alone, which opens a replaced node; a qid path drawn from
  the name, which gives a reinstalled package its predecessor's path; a
  counter of the tree's own, which a restart resets; a read that reopens
  the name, which serves the new package to an old open;
* identity around a rename, with a test hook that holds the gap between
  the rename request and its checkpoint request: the entry dropped after
  `erx_pkg_io` sends the rename, or at the publication, which serves the
  new package's bytes to the old open; an entry applied apart from its
  checkpoint, which serves the new package to an open made in the gap; a
  recovery that adds names only with their entries, which answers
  `enoent` for a listed name;
* the shell's `mount` over a fixture `apps` tree: a mount that reads the
  header and the image through two opens, which a fixture that replaces
  the package between them catches with old layout over new bytes; one
  that hands its readers an OTP file descriptor, whose read from a second
  process raises `not_on_controlling_process`; one that reopens the name
  for each read, which serves the new package's bytes;
* the session's export: a tree named by its mount point, which joins a
  second program's open after a remount to the first's file-table entry;
* `erx_app`: the app's paths added at the front of the code path, which
  loads an app module that shadows the release's; a native app's start
  flags, which reach the program as exactly one environment entry,
  `ERX_START_FLAGS`, unchanged and present when empty: an `erx_app` that
  passes an empty environment, and one that splits the value into
  arguments;
* the build's check: each seeded violation of
  [The build's check](#the-builds-check);
* `examples/dashboard` through the SDK, its frame through `erx_ui_host`
  against its reference: a status line one pixel taller;
* the SDK's boundary, where xref must find every call the example makes
  into erXos's modules in `public.txt` and answers a call through a
  variable module or fun apart, which the app's check pins to a reviewed
  list: the example calling `erx_ui:start/1`, exported but not public;
  the example calling through a variable module;
* the BLE client's boundary: the Bluetooth suite's `echo_a` and `echo_b`
  ([design-bluetooth.md](design-bluetooth.md#on-qemu-against-bumble))
  are packed through the exported SDK, with nothing but the SDK on
  their paths, and the same xref check finds every call they make into
  erXos's modules in `public.txt` and their callback module complete
  against `erx_gatt_service`'s callbacks, under `warnings_as_errors`;
  seeded: `erx_gatt_service:start_link/3` left out of `public.txt`,
  which fails the packing; the test app calling `erx_gatt:attach/1`,
  which the check refuses as not public; `handle_write/4` dropped from
  the test app, which the compile refuses;
* no list names an example, outside the kiosk cell's harness
  (`tools/lib/erx/kiosk.rb` and its suite) and its one packing recipe
  (`ImageApps.packed_kiosk`), which pack one through the SDK:
  `erx_dashboard` added to `ErlangApps::APPLICATIONS`; a path under
  `examples/` in a tools file.

**QEMU tests**, in the suites of the plan's parts that bring them:

* the kiosk cell (`tools/lib/erx/kiosk.rb`, suite `kiosk`): the
  production image of the development machine with `examples/dashboard`
  packed, sealed and enabled as the Raspberry Pi 4's card packs it
  ([The `apps` row](#the-apps-row)) boots with a display, the harness
  playing the firmware; its screendump must equal the dashboard as the
  host's erx-lvgl draws it with the sample board. Seeded: one bit of the
  header's root hash flipped and the package row bound to the altered
  header, so the build's file check never sees it, after which the
  `/app` mount is refused and nothing is shown; `--enable` dropped,
  which leaves the screen blank;
* two apps, neither of which sees the other's domains, or, once each
  app's `data` grant is rooted at its own directory, its files;
* the principal's wall, on both kernels: two apps fit the `apps` budget
  and a third is refused `no_memory`; an app whose session retired
  starts again. Seeded: the wall not destroyed at the retire, and a
  principal's budget carved with no guarantee;
* a packaged program with a display need draws through `/dev/draw` and
  answers a key QMP sends; seeded: the program started without a window;
* run-time install, update and removal through the shell: the package
  admitted at `/proc/packages`, mounted and read; `enable` starting
  nothing and `start` starting it; a copy cut halfway or one byte short
  publishing nothing; an update by the shell's `cp` and by a native
  `cp`, `O_WRONLY | O_TRUNC` without `O_CREAT`, stopping the app and
  leaving its files; reads at an old mount answering the old bytes or
  `EIO`; `rm` and `cp` of an image package answering `EROFS`. Seeded:
  the update without the publication, after which the old session runs
  across the rename; a tree whose `lopen` answers `einval` to every
  writing open, after which the native copy fails and the old version
  runs on; the removal without the publication, after which the app's
  keeper restarts it during the deletion;
* `service NAME purge` removing the app's directory, an untrusted signer's or a flipped header's
  `cp` failing with `EACCES`, an installed header flipped on the medium
  `refused` at the next boot, and an image block flipped giving `eio` at
  `/app` and at a mount of it;
* the states the inspector shows, each with a test: `admitted`,
  `refused` with its reason, and `overflow`.

**Fuzz targets**, each landing with its parser: the declaration's text
parser on the host; `erx_pkg_header:decode/2`, over unsigned headers
malformed at each field, cut short, with padding not zero and with image
and tree lengths that disagree or overflow; `erx_pkg_header:check_file/2`
as a whole, over a generated corpus of headers, lengths and names; the
EROFS mount of a file, `{header, Path}`, over generated package
files through a fixture `apps` grant that also answers short reads, so
the decoder meets every header before the reader; `erx_pkg_plan:recover/2`
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
* only `erx_pkg` calls `erx_principal:register_app/1` and
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
| **Preinstalled apps at `/sysapps`** | A second top-level place for apps, where one flat `/apps` shows every app under one name |
| **The image's apps at `/apps/system`**, as macOS keeps `/System/Applications` next to `/Applications` | A level and a reserved name that say only where a package lies, which its read-only answers already show; and an installed app could then share an image app's name, so one name in `/apps` would mean two packages |
| **`/apps/user` and `/apps/system`** | The common path, installing, grows by a level for everyone |
| **Packages copied into `/apps/pkg/` and shown elsewhere** | Two places for one thing. Installing where the app then shows is the whole of the model |
| **Each `NAME.app` shown as a read-only directory of its contents**, by a file server in each session over the `apps` tree | `rm -r` reached the removal only because OTP's `file:del_dir_r/1` passes over each inner failure, where FreeBSD's `rm -r` reports each one and exits with status 1 (`bin/rm/rm.c:296-317`, FreeBSD 15.1); a copy over an installed app could not open a directory for writing, so an update was a removal and a copy, which left no app while the new copy was checked and none if it was refused; and the view needed qid identity of its own, mounts taken and released as fids were walked, and a paged listing. A plain file and an explicit `mount` need none of that |
| **Every package mounted at a place beside `/apps` by itself** | Each session would have to follow installs, updates and removals to keep its mounts. A mount made when someone asks follows nothing, and ends with `unmount` |
| **The system domain serving packages' contents** | The EROFS reader would join the trusted base, and a crafted image would reach the system domain. A session reads its own |
| **A `ctl` file in `/apps`**, for installs, removals, enabling and purges | `/apps` would mix apps with a control file. Installing and removing are file operations; enabling and disabling are settings in `/etc/start.conf`, which `service` edits; a purge is an action, a line of the start service's `ctl` that `service` writes |
| **Commands written into `/proc`** | `/proc` is one read-only tree ([design.md](design.md#decisions)): it shows an app's state, and no command reaches the system through it |
| **Purge as `rm -r` of the app's directory through a grant over `apps/`** | Every administrator's session would hold a grant over every app's data, with a mount point of its own, and a purge could then remove the directory of a running app, whose grant's root would vanish under it, which the storage design does not define. `service NAME purge` uses the start service's `ctl` that `service` already writes and `remove_app`, which refuses a running app's name before any request |
| **A recorded signer beside each app's directory, with a different signer refused until a purge** | It needs a record the system domain writes among the app directories, read at every admission and removed with the data, with its own crash ordering. Naming the directory for the signer gives the same separation with no record and no refusal |
| **An app principal's budget made at boot, elastic under `apps`, with no guarantee** | Fiasco has no elastic budget, and a factory of size 0 is refused, so that budget would be a wall of nothing there and no session could be carved from it; keeping it on erXos's kernel alone would put a backend difference above `liberx`. A wall carved at each session's start needs no elasticity on either kernel and holds memory only while the app runs |
| **An update as `rm` and then `cp`** | It leaves no app while the new copy is checked, and none if it is refused. A copy over the installed one keeps the old package until the new one has passed, at the cost of one more publication than an install |
| **Renaming the new package over the old while the app runs, and restarting it after** | The running session reads its package through an open at the storage service, and whether an open file outlives a rename over its name there is the storage format's to say; a keeper that restarted the session between the rename and the publication would start it with the old layout over the new bytes. Ending the sessions before the rename makes neither matter |
| **An update that starts its app again when `start.conf` enables it** | One rule would then apply the file at every row's entry into the table, boot or publication, and an updated app would be down for one restart only. But an install would start an app whose lines an earlier install left in the file, an update would start a row the administrator had stopped, and a recovery after a crash would start whatever its set added, so what runs would follow the package process's history instead of the administrator's commands. Applying the file only at boot and at a row's own command, as FreeBSD's `pkg` starts no service, keeps one source of what runs |
| **Opens of a replaced package kept readable, as on FreeBSD** | The `apps` tree would have to keep a package file without its name until its last open closed, and recovery would have to find and delete such files. `eio` to an open whose package is gone costs a reopen |
| **`pkg add`, `pkg delete` and `pkg info` commands** | Each is a command, a grammar and an errno table for what a copy, a removal and a listing already say. A tree the system domain serves keeps the one writer and makes the close the commit, as copying an app into `/Applications` is on macOS |
| **An app chooses its facet parameters within the row's bounds**, or the builder overrides the derived rows | The build counts every row at its own parameters whatever the app picks, so a lower value saves the machine nothing and adds a rule per parameter to admission and to the mint. A builder who wants other values for every app sets them where the service's defaults live; one who wants them per app makes the app part of the manifest |
| **An app declares a guarantee and a cap** | Each session's budgets are walls, as every domain's are, so a session's memory is one figure; the sharing is between apps, in the `apps` wall each running app's wall is carved from |
| **A sum of installed apps' memory checked at install** | It judges again what the kernel judges at every start, and it promises less than it seems: which apps run at once depends on what is enabled and started, not on what is installed. It also made recovery order matter, since the sum admitted packages in name order until the budget ran out. The build sums the image's enabled packages, and the kernel judges the rest |
| **An app principal's budget a wall carved at install** | It holds memory for every installed app, running or not, so fewer apps fit, and a removal would have to wait for every retire before giving the memory back. A wall carved at a session's start holds memory only while the app runs |
| **A pool**: one principal pays for many apps, and each domain record names both the app it acts for and the pool that pays | Every reader of a principal must then choose the right one of two fields; the inspect scope and the grant records each chose wrong in the review of that design. Each app here is a whole principal, so every reader stays as it is |
| **A package carries an OTP release with its own boot script** | A boot script pins the versions of the release's applications, so every system update would break every package. `erx_app` starts the app's applications over the `app` release |
| **An environment field in the declaration** | Its one use was naming the UI renderer, which `erx_ui:open/1` takes as an option; anything else an app wants it can set itself |
| **A check that refuses an app whose module names clash with the release's** | The app's paths come after the release's, so a clash breaks only the app that brought it; the check would be one more refusal to keep in step with the release |
| **A version an install may not lower, with a flag to override it** | Against the administrator it only adds a flag; against a storage domain that puts back an older file it holds nothing without a counter the trust root keeps. The version is shown, not judged |
| **Packages unpacked into a directory of the data partition** | Their integrity would rest on the storage domain. An EROFS image under a hash tree, checked by the reader, makes it rest on the header alone |
| **The image builder's packages in the boot image** | The boot image stays in RAM for the whole boot, and every MiB of it comes out of the room `root_memory` leaves, which an `apps` row cuts to about 74 MiB on QEMU; Doom's 28 MiB WAD made the image 88 MiB. On the slot they are read on demand and still change only with the system |
| **Every package ships its own `erx-lvgl`** | One copy per app, a wire between toolkit and renderer that each app's build could skew, and LVGL's notices in every package |
| **A launcher in Erlang for each native app** | The display already starts a program with a window and binds its draw and input files; `program` reaches that for every native app |
| **A native window app draws into its buffer and presents through a pipe protocol, as `erx-lvgl` does** | It would be a second public path to the screen. `/dev/draw` is the designed one; the measurement on the watch list decides whether a faster one is needed |
| **Signers trusted on first install, or added at run time** | The record of who is trusted would lie where the storage domain can rewrite it. Keys in the boot image cannot be |
| **Unsigned packages in development builds** | A second mode in the header, the file check and the inspector, for nothing: the packer signs with the host's development package key by default, which costs a developer nothing, and the development builds that host makes trust that key |
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
| a restart while the `apps` budget is full waits for the ended session's principal's wall to retire | low | one refused restart, counted against the row's intensity | property 19 makes the `apps` budget hold a session beside one principal's wall not yet retired |
| a package's suffix, `.app`, is also the suffix of an OTP application resource file | low | a reader confuses `/apps/dashboard.app` with `lib/erx_dashboard/ebin/erx_dashboard.app` | the two never share a directory; the SDK's documentation names both |
| an author who signs a new version with a new key finds the app's data gone | low | the data lies under the old key's directory | `/proc/packages` shows the signer; a purge removes the old directory, and the author keeps the key |

Decisions:

1. **An app is a principal of its own**, made from its declaration and
   bounded by one `apps` row; no app joins a class or a pool.
2. **Memory is shared through one wall**: an app principal's budget is
   a wall carved from the `apps` wall when its session starts and
   destroyed when that session retires, never resized; each session is
   walled inside it; the build sums the image's enabled packages, and
   the kernel judges every start.
3. **A machine trusts only the signer keys its boot image carries**:
   the manifest's `signer` rows, and in a development build its builder's
   development package key. Every package is signed.
4. **Every app may read every package's bytes**, as stated in
   [Where a package lies](#where-a-package-lies).
5. **Every app is `/apps/NAME.app`, the image's read-only**, each a
   plain file, the package itself;
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
10. **Publishing an app applies nothing of `/etc/start.conf`**: an install
    or an update only replaces the app's files, and the new version runs
    at the next boot or at `service NAME start` or `restart`, as
    FreeBSD's `pkg upgrade` leaves services alone; an update therefore
    leaves its app stopped ([The start table's rows](#the-start-tables-rows),
    [design-apps.md](design-apps.md#the-start-table)).
11. **Both development manifests carry an `apps` row**, sized as
    [The shipped manifests](#the-apps-row) says; the website's image
    carries none, and the Raspberry Pi 4's card carries the kiosk alone,
    trusted by its hash, and trusts no key until a release signer exists.
12. **A native app starts through `erx_prog_handler`'s `window`
    option**, and the handler's start returns a monitor whose `'DOWN'`
    is the program's one end report, so no second launcher and no second
    end message exist ([design-programs.md](design-programs.md#the-handler)).
13. **Doom is a demo app under `examples/`**, a submodule whose gitlink
    is all the tree holds; 0.1's published media carry it as `/bin/doom`
    under the dependency status `example`, with its source offered
    ([Examples](#examples)).
14. **No policy per signer**: the `apps` row offers its services to every
    app, and the builder's lever is which signer keys the image trusts.
15. **A package carries no `sys.config`**
    ([Starting an app](#starting-an-app)). The one consumer found, an
    Elixir app whose log reached nothing, is served by a session's
    `user` writing log records, which needs no configuration; a
    declaration field and a reader in every session would serve no app
    that exists. Open: whether to add one when a ported Mix or rebar3
    project needs another application's environment at its start. Its
    smallest form, recommended if it is wanted: a file `sys.config` at
    the package's root, in stock `sys.config` syntax, one list of
    `{Application, [{Key, Value}]}`, at most 64 KiB, naming only
    applications under the package's `lib/`, with no file-name entries;
    the packer checks it on the host, and `erx_app` reads it with
    `file:consult/1` before step 2 and applies it with
    `application:set_env/2` and `persistent`, so loading the `.app` file
    does not override it. It is the app's own input read in the app's
    own session, whose atom table and code are already the app's, so a
    bad file ends only that session, with `{bad_config, Reason}` naming
    the line; its reader has a fuzz target, and its tests are a value
    that reaches the application and a file naming a release
    application, which the packer and `erx_app` refuse, seeded by
    removing that check.

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
