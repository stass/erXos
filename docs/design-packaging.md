# Apps: packages and the SDK

A **package** is one file that carries an app built outside erXos's tree:
a short declaration of what the app is and needs, and a read-only image
of its code and data. This document says how a third party builds one
with erXos's SDK, how an image builder adds it to an image, how an
administrator installs, updates and removes it on a running machine, and
what the app may take.

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

**What an administrator types.** Installing is a copy, removing a
deletion, as an app is installed on macOS by copying it into
`/Applications`:

```text
cp dashboard.pkg /apps/pkg/
service dashboard enable
rm /apps/pkg/dashboard.pkg
```

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
package, the app principal and the SDK. The architecture is in
[design.md](design.md); the manifest and its check in
[design-system.md](design-system.md#the-manifest); principals and
sessions in
[design-domains.md](design-domains.md#principals-sessions-and-quotas);
budgets in [design-kernel.md](design-kernel.md#budgets); read-only
images in [design-storage.md](design-storage.md#reading-erofs-images);
the file protocol in [design-files.md](design-files.md); native programs
in [design-programs.md](design-programs.md); windows in
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
* **The code is an EROFS image under a hash tree, read by the app's own
  session.** The session mounts its package's image at `/app` through
  the hash-checking reader, against the root hash of a header the system
  domain authenticated: by the hash the manifest records, for a package
  in the image, or by the signature of a key the boot image carries, for
  one installed at run time. The system domain reads only the header.
* **One package, two ways onto a machine.** `tools/erx pack --app` adds a
  package to an image; copying it into `/apps/pkg/` installs the same
  file on a running machine. Both run the same admission and give the
  same session.
* **Installing is a file operation.** `/apps/pkg/` is a directory the
  system domain serves. A file copied into it is checked when it is
  closed and published under its name only if it is whole and admitted;
  deleting it removes the app and keeps the app's data.
* **The start service decides whether an app runs.** Its keepers are the
  only starters of an app's sessions. Before an app's package changes,
  the package process publishes a package set without the app, and the
  start service answers that publication only once the app's sessions
  have ended. Nothing starts because it was installed: the image builder
  enables a row of the image's packages, and the administrator an
  installed one with `service NAME enable`, as on FreeBSD.
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
`NAME.pkg`, signed with the SDK's development key unless `--key FILE`
names another ([Building and packing](#building-and-packing)).

**How does it reach an image?** `tools/erx pack --app DIR` builds and
packs the app, checks it against the image's manifest and adds it;
`--enable NAME` makes it start at boot. The board's manifest is not
edited.

**How does it reach a running machine?** `cp dashboard.pkg /apps/pkg/`
at the shell of a session that holds the `apps` grant, then `service
dashboard enable` if it should start at boot. Copying a newer
`dashboard.pkg` over it updates it; `rm /apps/pkg/dashboard.pkg` removes
it and keeps its data; `ls /apps/pkg` lists every package, and
`/proc/packages` shows each one's state.

**What may it take?** The services of the `apps` row that it names, the
memory it declares out of the row's budget, and nothing of the person
who installed or started it.

## Context

### What exists

An app is a principal with a session template, whose release is its code
and whose facet rows are its authority, and the start table starts and
keeps its session ([design-apps.md](design-apps.md#an-app)). Built:
the `start` rows, `erx_start_table`, `erx_starter` with its keepers, the
`apps` tree and `erx_domain:start_session/2` (TODO.md, the design-apps.md
item). The EROFS reader `erx_erofs` and its block funnel `erx_verity`
read images through a block window
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
owner, and the tree's `clunk` callback answers only `ok`
(`erlang/apps/erx_files/src/erx_fs_grant.erl:229-244`,
[design-files.md](design-files.md#serving-the-erx_fs-behaviour)). A
`remove` reaches the tree's `unlink` callback, which answers `ok` or an
errno. The shell's `cp` copies with `file:copy/2` between two names
(`erlang/apps/erx_shell/src/erx_cmd_cp.erl`), which stock OTP runs in
`file_server`, whose copy closes the target and drops the close's answer
(`otp/lib/kernel/src/file_server.erl:177-193`). Installing by copy needs
both to change ([Other subsystems](#other-subsystems)).

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
| a crashed session's restart was refused with `no_memory` while the ended domain's budget was still held | Doom 10 | an app principal's cap holds a session beside the outer budget of one that ended ([An app's principal](#an-apps-principal)) |
| `bin/erx-lvgl` reached only the programs suite's test image (`tools/lib/erx/production_image.rb:95-99`) | kiosk | the toolkit's programs ship with the toolkit in every image |
| the host test used toolkit internals (`erx_ui:start/1`, `erx_ui_lvgl`'s `open` and `present` funs) | kiosk | `erx_ui_host`, the public host stand-in for a display |

### What other systems teach

These are taken from each system's published descriptions, not re-read
for this design.

| System | What erXos takes | What it leaves |
| --- | --- | --- |
| macOS | an app installed by copying it into `/Applications` and removed by deleting it; the app's data kept when the app is deleted | the app bundle's own layout and its signing format |
| Android | a user id per app, so the separation between users is the separation between apps; a package signed by its author, and updates only from the same key | permissions granted one by one at run time; apps that grant each other services |
| Android APEX and Fuchsia packages | code as a read-only image checked block by block against a hash a signed header names | their package managers and resolvers |
| FreeBSD `pkg` | signature checks against keys the system trusts; a user's files kept when a package is deleted; an installed service starts only once `rc.conf` enables it | `pkg add`, `pkg delete` and `pkg info` as commands of their own; repositories and fetching by name |
| Flatpak | an app built against a published runtime and SDK, with the runtime shipped by the system, not the app | runtimes as packages of their own |

## Requirements

* **PK-R1.** A third party builds an app outside erXos's tree, with the
  SDK alone, and the app reaches no list, script or manifest of erXos's.
* **PK-R2.** An app added to an image or installed at run time holds no
  authority the `apps` row does not offer, and takes nothing the build
  proved for the board's own domains.
* **PK-R3.** Every byte of an app's code and data its session reads
  matches what its author packed, whatever the storage domain does.
* **PK-R4.** Two apps never read each other's files or see each other's
  domains.
* **PK-R5.** The same package and declaration serve the image builder
  and the administrator; the board's manifest is never edited to add an
  app.
* **PK-R6.** Install, update and removal survive a power cut at any
  point, writes reordered between flushes included: a package's name
  holds the old package or the new one, whole, or none.
* **PK-R7.** The system domain's atoms, tables, memory and work stay
  within bounds the build set, however many packages come and go in a
  boot and whatever the package directory holds.
* **PK-R8.** Every package byte, header and declaration, and every entry
  of the package directory, is untrusted input to the system domain and
  to the build host.
* **PK-R9.** No copyleft package enters an image erXos distributes.
* **PK-R10.** An app author, a machine's builder and an administrator do
  as little as the first two requirements allow: every declaration field
  but the name and the code, and every `apps` field but the memory, has a
  default; installing is copying a file into a directory, and removing is
  deleting it.

Outside this design: fetching packages by name (a fetcher is a command
in a person's session that holds `net` and copies the file into
`/apps/pkg/`); prompts that ask a person to approve a grant; apps that
serve facets to other apps; keys at the vault for an app; packages of
system services or drivers, which are configured domains of the
manifest.

## Overview

```text
 the developer's host                 the image builder               the machine
 --------------------                 -----------------               -----------
 DIR/app.txt  lib/ or bin/  share/    tools/erx pack --app DIR       system domain
      |                                 --enable NAME                  erx_pkg: authenticates each
      | erx-app pack (SDK)                |                              header, admits it against the
      v                                   | admission on the host        apps row (erx_app_admit),
 NAME.pkg: header (declaration,           | against the manifest         registers the app's principal,
   arch, root hash, signer,               v                              publishes the package set to
   signature) + EROFS image          image: the manifest's apps row,     the start service
   + hash tree                       a `package` row per app,                  |
      |                              the package on the slot                   | start_session(app, Start)
      | cp NAME.pkg /apps/pkg/ (administrator)                                 v
      +---------------------------------------------------------------> domain service: a session of
                                                                       the app template, as the app's
                                                                       principal, with the services
                                                                       it named and its package at /app
                                                                               |
                                                                       session dashboard_1: erx_app
                                                                       starts the app's applications
                                                                       from /app/lib, or its program
                                                                       from /app/bin
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
`erx_dashboard`, which opens its window with `erx_ui:open/1`. Later an
administrator copies a newer `dashboard.pkg` into `/apps/pkg/`. When the
copy closes, the package process authenticates and admits it, publishes
a package set without `dashboard`, so the start service ends its
session, renames the new file into place, and publishes the set with
`dashboard` again; the start service starts the row, with the app's data
where it was.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **PK1.** An app holds no grant the `apps` row does not offer, and its memory comes only from the row's budget | the declaration grammar names services and one amount of memory; admission keeps a need only if it is one of the row's services; the session's facets are the `packages` grant and the kept needs, both rows of the manifest, through the domain service's one funnel (A10); the app's principal budget is a child of the `apps` budget, so every session it starts is carved there or refused | a declaration field that carries a parameter or a grant; an admission that keeps a need the row lacks; a session plan that grants a row the app did not name; an app budget carved from the root | admission's corpus with a seeded admission that drops the subset test; the session plan's host test with a seeded plan that grants every row of the template |
| **PK2.** The build's proof for the board's own domains holds with every app present | property 19 counts the app template as `max` principals in every sum that counts a principal or a template's rows (display pixel areas and connections, domain slots, start rows, principal table, name atoms), each holding every service of the row | a sum that counts the app template once; a service an app may take that no sum counts | the seeded violations of [The build's check](#the-builds-check) |
| **PK3.** Every block of `/app` a session reads matched the root hash of a header the system domain authenticated | `erx_app` mounts `/app` only through `erx_verity`, with the root hash, salt and tree layout the domain service hands it in the ready answer; the domain service takes them only from a header `erx_pkg_header:verify/2` accepted | a mount whose root hash comes from the session's own read of the header; a read path around `erx_verity` | a QEMU test that flips one byte of an installed package's image and finds the read refused; the build check that only `erx_erofs` reads through `erx_verity` (`Erx::ErofsReads`) |
| **PK4.** Two apps see nothing of each other | each is its own principal; the domain service computes every scope from the session's principal, the app's; the storage service roots each app's `data` grant at its own directory | a scope, storage root or name pool derived from the template's key; two apps registered under one principal | a QEMU test with two apps; seeded: the mint's scope taken from the template's key |
| **PK5.** The system domain parses a package's header alone, through the generated reader, and loads no app code | the package process reads the header's bytes and hands them to `erx_pkg_header:verify/2`; the image is mounted only by the app's own session | a system-domain module that mounts or reads a package's image | a source check over the system release that no module but the package's reader names a package's bytes, with a seeded call of `erx_verity` from `erx_pkg` |
| **PK6.** A package's name holds a whole package, admitted when it was published | a copy is written into a temporary file that no open can reach by name; at its close the package process checks that the file's length is exactly the header's, authenticates and admits it, makes the file durable, and only then renames it over `NAME.pkg`, one step; a removal is one durable deletion; boot and the package process's restart delete every temporary file before any admission | a rename before the file is durable; a temporary file reachable by a name another open can write; a length check that accepts a short file | the planners' crash test over every write, with writes reordered between flushes; the close's host test of a short, a long and a misnamed file |
| **PK7.** No session of an app runs while its package file changes | the start service's keepers are the only starters of an app's sessions (AP2: an app principal has no credentials, so no login starts one); before the package process renames or deletes an app's file it publishes a package set without the app, which the start service answers only once the app's sessions have ended, and the start service starts none until a set with the app arrives | a second starter of app sessions; a publication answered before the sessions end | the start table's host test of a publication that drops a running app; a QEMU test that updates a running app and finds no session of the old version after the first publication's answer |
| **PK8.** A removal or a purge reaches only what belongs to an app | a removal deletes one `NAME.pkg` inside the package directory, after a publication that drops only that package's row; a purge sends the storage service's `remove_app`, which reaches only the directory of app directories; a name that fails the app-name rule is refused before any effect | a removal that stops domains by principal name; a data removal through a grant wider than the app directories | the purge's host test with names `root`, a configured domain and a manifest principal, each refused with nothing stopped or deleted |
| **PK9.** The system domain's atoms, tables and recovery work stay within the build's bounds | an app principal lives for the boot in one of `max` entries, which removal does not free until the next boot; its sessions take pooled names within its `names` quota; at most `max` copies are open at once; recovery reads at most `pkg_scan_max` entries | an unregister that frees an entry within the boot; a recovery that reads the directory unbounded | a host test that installs and removes `max` + 1 distinct names in one boot and finds the last refused with `apps_full`; the recovery's fuzz target over listings past the bound |
| **PK10.** A package of the image and one installed at run time give the same session | both pass `erx_app_admit:admit/3` and the same session plan; only what authenticates the header differs | a second admission or plan for one of them | the session plan's host test over one header admitted both ways |

## Data model

### The `apps` row

The board's manifest has at most one `apps` row. Without one, the
machine takes no packages. Its fields:

| Field | Meaning | Default |
| --- | --- | --- |
| `memory` | the budget all apps share, in bytes; property 4 counts it within `root_memory` as it counts a principal's budget | none: required |
| `services` | the services an app may name in `needs`, each a service of the manifest | none, so an app holds only its `packages` grant |
| `max` | how many apps a boot can hold, 1 to `apps_max_limit`, 64 | 8 |

From the row the build derives, as rows of the image's manifest that the
board's source does not hold and the build record lists:

* **the app template**, a session template whose runtime is the
  system's interpreter, whose release boots the domain release's `app`
  script (the base every session boots, the client side of the display,
  `erx_memdraw`, `erx_win` and `erx_ui`, and `erx_app`), and whose limits
  are a session's defaults with `SPACES` (property 14);
* **one facet row for each service of `services`**, granted to the app
  template, named as the service is, with the parameters the service's
  ABI file gives as its defaults. A service may be named in `services`
  only if its ABI file declares a default for every parameter its rows
  take: `abi/services/windows.txt` declares `windows_default` and
  `windows_pixels_default`, and `files` and `net` declare no parameter.
  A row of the data partition's storage service carries the parameter
  `tree apps`, which roots its grants among the app directories ([Where
  an app's files lie](#where-an-apps-files-lie));
* **the `packages` rows**: the system domain's grant of the `packages`
  service, read-write, and the app template's, read-only.

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
   `packages`, which every app holds already, and `apps`, which would let
   an app install packages and command the start table; when it names
   `inspect`, the scope `erx_domain_core:inspect_scope/3` gives an app
   principal is its own, never `all`, which would show an app the other
   apps' domains;
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
5. every `package` row's package passes admission on the host against
   this manifest ([Admission](#admission)); the declared memory and the
   session's outer budget, as the resource policy sizes it, of every
   enabled package sum within the `apps` budget, so the image's enabled
   apps all start; and the row of an enabled one meets property 17's
   display and planning clauses as a manifest `start` row does;
6. every `signer` row holds a 32-byte Ed25519 public key under a unique
   name;
7. no facet row of the board's source is granted to the app template or
   carries `tree apps`: only the rows the build derives do.

Each clause has a seeded violation: a check that counts the app template
once in property 18, which admits a row whose apps together pass the
display's budget; an `apps` row whose `max` plus the manifest's start
rows pass 256; `apps` in `services`; a service in `services` whose ABI
file gives a parameter no default; two enabled packages whose memory
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

A package is one file, `NAME.pkg`, of three parts, each starting at a
4 KiB boundary:

| Part | Holds |
| --- | --- |
| header, at most `pkg_header_max`, 64 KiB | the magic `ERXPKG`, the format version, the header's length, the `ERX_ABI_VERSION` and the target architecture (an architecture name of `abi/arch/`) the package was built for, the packed declaration, the image's length in blocks, the hash tree's length, salt and root hash (SHA-256, dm-verity format version 1, as [design-storage.md](design-storage.md#data-model) lays read-only images), the signer's Ed25519 public key, and the Ed25519 signature over every byte of the header before it |
| image | an EROFS image of 4 KiB blocks in the layouts `erx_erofs` reads, whose root holds `lib/APP/ebin` and `lib/APP/priv` for each application, `bin/` for programs and `share/` for data |
| hash tree | the image's dm-verity tree |

The file's length must be exactly the header's length plus the image's
and the tree's, with checked arithmetic. The image's entries carry fixed
owner, mode and time, so the same inputs give the same bytes and no host
metadata leaks into a package. The image names no device, socket or link
leaving it.

`erx_pkg_header:verify(Bytes, Authority)` is the one entry that reads a
header. It checks the magic, version and lengths and decodes the
declaration with the generated reader, then authenticates the header by
one of two means, which `Authority` names:

* `{hash, Sha256}`, for a package of the image: the header's SHA-256 must
  equal the one its `package` row records. The signer and signature
  fields are not read, so a package someone else signed is added to an
  image without the machine trusting its signer, and the app's signer is
  `image`;
* `{signers, Keys}`, for a package installed at run time: the header's
  signer must be one of `Keys` and its signature valid. The app's signer
  is the key's `signer` row name, or `development`.

It answers `{ok, Header}` with the signer named, or `{error, Reason}`.
It is pure but for the signature check, which the small Ed25519 verifier
of [design.md](design.md#dependencies) makes, as for an update's
manifest.

### Where a package lies

| | The image builder's packages | Installed packages |
| --- | --- | --- |
| placed by | `tools/erx pack --app` | a copy into `/apps/pkg/` |
| lies | in the system slot, in the package image, an EROFS image of package files that the manifest's `image` row records like the release's; the storage service serves its files read-only under `packages/image/` | in the data partition's `packages/` directory, which the storage service serves |
| header authenticated by | its SHA-256, which the manifest's `package` row records | a key of the manifest's `signer` rows, or in a development build the development key |
| changes | with a system update, as the slot does | by a copy into, or a deletion from, `/apps/pkg/` |

A machine trusts only the signer keys the boot image carries: the
manifest's `signer` rows, and in a development build the SDK's
development key. Trust therefore changes only with a system update, and
no record a storage domain could rewrite adds a signer.

Either way the system domain and the app's session reach the file
through the `packages` service, an instance of `files` that the storage
domain serves at a service directory of its own: the system domain reads
and writes it, and the app template reads it. Since `erx_verity`
checks every block against the root hash of the authenticated header,
no property of a package rests on the storage domain but its presence:
a storage domain can withhold a package or put back an older one of the
same signer, never change one. Every app can read every package's bytes:
a package holds what its author ships, not anyone's secrets, and keeping
each package to its own app would need a grant per package.

**On the stopgap**, where the storage service does not yet serve a slot's
image, the image builder's packages lie in the boot image's domain
release at `pkg/NAME.pkg`, and their sessions read them through `/`,
the release slice. They enlarge the boot image and the memory it holds,
and every domain can read them (Phase 1).

### Where an app's files lie

The data partition's storage service keeps every app's directory under
one directory of its own, `apps/`, apart from the directories of the
manifest's principals and services. A grant from a facet row that
carries `tree apps` is rooted at `apps/PRINCIPAL/`, where `PRINCIPAL` is
the grantee's principal as the mint names it, the app's; property 19
lets only the rows the build derives for the app template carry it.

Removing a package keeps its app's directory, as deleting an app keeps
its data on macOS and deleting a package keeps a user's files on
FreeBSD, so a package copied in again finds its data where it was. An
administrator removes the directory on purpose with a purge, `echo purge
NAME > /apps/ctl`, which the package process carries out with the
storage service's `remove_app` request on the durability facet, which
only the system domain holds and which reaches nothing outside `apps/`
([design-storage.md](design-storage.md#interfaces)): it removes
`apps/NAME` whole, NAME one identifier, answers `ok` once a completed
checkpoint holds the removal and every write the service acknowledged
before it, and answers `ok` for a directory already absent. The package
process refuses a purge of a name that is not an app name, a name of
the image's packages, or a name installed now, before any request.

### An app's principal

The principal service registers an app's principal with
`erx_principal:register_app/2`, which only the package process calls,
in a free entry of the `max` the domain library's principal table holds
for apps. Its record holds the app's name, its signer (`image` for one of
the image's) and its declared memory. A principal of an app has no
credentials: no one logs in as one. Its directory, its inspect scope and
its name pool are those of any principal, keyed by its name. It is never
unregistered within a boot: a removed app's principal keeps its entry and
name, with nothing to run, until the machine reboots, so its atoms and
its table entry stay within the build's count (PK9). Installing the name
again in that boot takes the same entry, with the same signer only.

Its budget is a child of the `apps` budget. Every principal of the
manifest has a wall, a budget whose cap is its guarantee; an app's is
**elastic** ([design-kernel.md](design-kernel.md#budgets)), with no
guarantee and a cap of its declared memory plus twice the outer budget
the resource policy sizes for its session, so a session fits beside the
outer budget of one that ended and has not retired. Each session's own
and outer budgets are walls carved from it, as every domain's are, so
once a session runs, its memory depends on nothing outside it; what the
kernel judges against the `apps` budget is only whether a session can
start. An update that changes the declared memory changes the record and
the cap the domain library gives the next session's plan; it carves
nothing.

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
  the app's record: the place of the package's file (`packages/...`, or
  `/pkg/NAME.pkg` in the release on the stopgap), the header's image
  offset, root hash, salt and tree layout, and its applications or its
  program with its arguments and whether it has a window.

The record comes only after the session's grants are added, the
`packages` grant among them, so the app's code never starts before its
grants exist and its package is readable when it starts. `erx_app`
mounts `/app`, `rx`, with `erx_ns:mount({erofs, {file, Place, Image}},
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
the authenticated header, the manifest as `erx_manifest` reads it, and
the boot's registry of app principals. It answers `{ok, Admitted}`, the
principal's entry (the name's existing one or a new one), the indices of
the facet rows kept and the start row, or `{error, Reason}`, the first
of these that fails:

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
judge when the session starts. The packer runs the same module on the
host, under the stock OTP 29.1.2 the build compiles with, over the packed
manifest and each package's header bytes, so one implementation decides
at build and on the machine.

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
  It then parses `app.txt`, checks that each application has its `.app`
  file or that the program exists and passes `erx_elf_plan` with the
  SDK's ABI version, writes the image from an mtree manifest with
  `fsimg`, computes the hash tree with a salt derived from the image's
  contents, writes the header with the SDK's ABI version and target,
  signs it with FILE's key or else the SDK's development key, and writes
  `NAME.pkg` with its build record beside it. It follows no link out of
  `DIR` and refuses any other kind of file. Packing runs the app's own
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
3. runs the manifest check, property 19's admission and memory clause
   included;
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
   with a window on the session's default display when the app needs a
   `windows` service, whose `/dev/draw`, `/dev/kbd`, `/dev/mouse` and
   `/dev/wctl` the handler binds
   ([design-display.md](design-display.md#the-window-tree)); without,
   with standard input null and its output to the session's log. Its
   namespace is the session's. Its end ends `erx_app` with
   `{program_exit, Status}`.

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

### Installing, updating and removing

The package process, `erx_pkg`, owns the package set; `erx_pkg_io` makes
every file operation on `packages`; `erx_pkg_plan` decides each step as a
pure function of the package set, the directory's state and the
admission, and the package process applies its result. A step is
**durable** once the data partition's storage service has answered a
checkpoint on the durability facet requested after it: that answer comes
only when a completed checkpoint holds every write the service
acknowledged, the file's bytes and the directory's entries alike
([design-storage.md](design-storage.md#interfaces)).

**`/apps/pkg/`** is a directory of the `apps` tree, which the system
domain serves and a session holding the `apps` grant mounts at `/apps`
([design-apps.md](design-apps.md#interfaces)). It lists one `NAME.pkg`
for every package of the image, read-only, and for every package in the
data partition's `packages/` directory, admitted or refused. A read of a
file gives the package's bytes. Only a session holding the `apps` grant
writes here, and only the system domain writes the storage service's
`packages/` directory, so the package process is the one writer of the
package directory.

**Publishing.** The package process tells the start service which apps
exist with `erx_starter:packages(Set)`. The call answers once the start
service holds the set's rows and every session of an app the set no
longer holds, its row's keeper and a `onestart` one alike, has ended.
Since an app principal has no credentials, the start service's keepers
are its only starters (AP2 of
[design-apps.md](design-apps.md#invariants)), so once a set without an
app is answered, no session of that app runs or can start until a set
with it is published. Every change of a package's file sits between two
publications.

**Installing or updating**, `cp dashboard.pkg /apps/pkg/`:

| Step | Why it must exist |
| --- | --- |
| 1. the shell opens `/apps/pkg/dashboard.pkg` for writing. The `apps` tree accepts a name `NAME.pkg` with NAME an identifier and not a name of the image's packages, and opens a fresh, empty temporary file in the data partition's `packages/` directory, named `tmp.K` for the first of `max` slots that is free; the published package, if any, is untouched | copies land on the same file system as their final name, so the rename is atomic; a temporary file has no name in `/apps/pkg/`, so no other open can write it |
| 2. the shell writes the bytes; the tree passes each write to the temporary file through the system domain's grant, at most `pkg_bytes_max` bytes in all | |
| 3. the shell closes the file, and the close waits for the steps below. The writing open has ended, so nothing writes the file from here on | the bytes checked are the bytes published |
| 4. the package process checks that the file's length is exactly the header's length plus the image's and the tree's, and that the header names the app the file is named for; it verifies the header with `{signers, Keys}` | a copy cut short or run on never gets a published name; only a trusted signer's package runs |
| 5. it admits it ([Admission](#admission)) and plans the install; a name installed already needs its signer | the authority check; signer continuity |
| 6. it registers the app's principal, the name's entry again for an update | the principal must exist before its row; this is the step the entry bound limits |
| 7. it makes the temporary file durable | the rename must never publish a name whose bytes are not on the medium |
| 8. for an update, it publishes the package set without the name | no session reads the file being replaced, and no keeper restarts old code |
| 9. it renames `tmp.K` over `NAME.pkg` and makes the directory durable | the one commit point; durable before the close answers |
| 10. it publishes the package set with the package admitted, and the close answers `ok`; a row `rc.conf` enables starts, with the app's directory as it was | the start service resumes the app |

A refusal at any step deletes the temporary file and the close answers
the refusal's errno ([Interfaces](#interfaces)), with the reason in the
log; for an update refused before step 8 the old package stays
published and its app runs on. A crash before step 9's rename leaves the
old package or none, and the temporary file, which the next recovery
deletes; a crash after it leaves the new package, which the next scan
admits. One file per name, replaced by one rename, means no crash brings
back an older version. A session that ends with a copy open has its open
closed by the file service, and the close takes the same steps: a file
cut short fails step 4's length check and is deleted, so a half-copied
file never gets a published name.

**Removing**, `rm /apps/pkg/dashboard.pkg`, reaches the tree as the
protocol's `remove`:

| Step | Why it must exist |
| --- | --- |
| 1. the package process publishes the package set without the name | no session runs while its file goes |
| 2. it deletes `packages/NAME.pkg`, makes that durable, and the `remove` answers `ok` | one durable deletion is the whole removal |

A crash before the deletion is durable leaves the package, which the
next recovery admits again; a crash after it leaves none. The app's
directory stays ([Where an app's files lie](#where-an-apps-files-lie));
its principal keeps its entry until reboot. `rc.conf` lines naming the
app stay, are reported as naming no row, and apply again if the app is
installed again, as on FreeBSD.

A removal reaches nothing but what belongs to an app (PK8). The
publication drops only the package's row; the deletion is inside the
package directory; a purge reaches only the app directories. No step
looks up domains by principal name, so even a name that slipped past the
app-name rule could not stop a configured domain or a person's session,
or delete a manifest principal's files.

### Boot and recovery

The package process starts with the start service. It registers the
image's packages from the manifest's `package` rows, reading each header
through the `packages` grant (from the release on the stopgap) and
verifying it with `{hash, H}`. Once the `packages` grant is in place,
which it waits for as the start table waits for `rc.conf`, it runs the
**recovery**, `erx_pkg_plan:recover/2`, over the listing of `packages/`
and the manifest:

1. `erx_pkg_io` reads at most `pkg_scan_max`, 1,024, entries, one bounded
   read at a time, and reports whether more remain. A valid directory
   holds at most `max` packages, `max` temporary files and `image/`,
   which property 19 keeps well under the bound;
2. when the directory holds more, the recovery acts on nothing in it: no
   installed package is admitted, every write and removal in
   `/apps/pkg/` answers `eio`, and `/proc/packages` shows `scan` as
   `overflow` with the count read. Image packages are unaffected;
3. otherwise, each temporary file `tmp.K` is deleted, and each `NAME.pkg`
   whose NAME is an app name is read, verified with `{signers, Keys}` and
   admitted, in name order; a package refused stays on the medium, shown
   `refused` with its reason at `/proc/packages`, and its refusal is
   logged;
4. an entry of no recognized form, or whose name is not an app name, is
   left as it is, with a log line. No entry's name becomes an atom:
   names stay binaries until a registration, which takes one of the
   `max` entries;
5. the package process publishes the package set; the start service
   reconciles.

The recovery reads at most `pkg_scan_max` names and headers of at most
64 KiB each, one at a time, and keeps one record for each entry it
admits or refuses, whatever the directory holds (PK9). The same recovery
runs when the package process restarts after a crash, so there is one
path from any state of the directory to the package set.

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
`{no_grant, D}` and a display another enabled row holds, and `service
NAME enable display=D` checks the same set; an installed app never takes
a display from a row of the manifest or of the image. Each publication
of the package set changes the rows, and the table reconciles as it does
after a change of `rc.conf`.

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
* **`examples/doom/`** holds `ORIGIN.md` beside `doom/`, a git submodule
  pinned by its gitlink, as `display/lvgl/lvgl` is
  ([design.md](design.md#dependencies)). Its repository holds
  doomgeneric, under GPL-2.0, the erXos glue, its `app.txt` and a
  `Makefile` over the SDK's `sdk.mk`, and a list of pinned downloads in
  `deps.lock`'s form, for Freedoom's WAD. erXos's tree holds no file of
  it: a submodule is a commit id. `git clone` does not check it out and
  `tools/erx fetch` fetches it, and its downloads against their SHA-256,
  only with `--example doom`; no part of `make check`, the landing gate
  or the milestone gate builds it; `tools/erx app run examples/doom/doom`
  runs it on request. Its license keeps it out of every image erXos
  distributes (step 4 of [Adding an app to an image](#adding-an-app-to-an-image)).
  No erXos code includes or links it, so working on erXos never needs
  reading it.

To the packer both are app directories with an `app.txt`, as is a
third party's anywhere on disk. The landing gate exports the SDK, packs
and host-tests `examples/dashboard` with nothing but the SDK on its
paths, and checks that every call the example makes into erXos's
modules is one of `public.txt`'s functions, so a change that breaks the
boundary fails there.

## Interfaces

An administrator installs, updates, lists and removes packages with the
shell's own `cp`, `ls` and `rm` on `/apps/pkg/`, and reads their state
with `cat` under `/proc/packages`; there is no command of packaging's
own.

**The `apps` tree** gains `pkg/` and one `ctl` command:

| Name | Read | Write |
| --- | --- | --- |
| `pkg/NAME.pkg` | the package's bytes | an open for writing, of a new name or an existing one, starts an empty file that is published only at its close ([Installing, updating and removing](#installing-updating-and-removing)); an open for reading and writing at once answers `einval`. Errnos at the open: `einval` for a name not of the form `NAME.pkg` with NAME an identifier; `eacces` for a package of the image, which is read-only; `enospc` while `max` copies are open; `eagain` while the `packages` grant is not in place; `eio` while the directory is past the scan bound. A write past `pkg_bytes_max`, 1 GiB, answers `efbig`. Errnos at the close: `einval` for a file whose length is not exactly the header's, whose header fails its checks or names another app, or whose name is not an app name; `eacces` for a header that names no trusted signer or carries a bad signature; `eperm` for an admission refused by `no_apps`, ABI, architecture, memory or need; `eexist` for a name of the manifest or of the image, or one another signer holds; `enospc` for no free entry; `eio` for a failed read, write or checkpoint of `packages` |
| `pkg/NAME.pkg`, removed | | `remove` deletes an installed package and answers `ok`; `enoent` for no package of the name; `eperm` for a package of the image; `eio` for a failed deletion or checkpoint, or a directory past the scan bound |
| `ctl` | | `purge NAME` removes the directory of an app that is not installed. Errnos: `einval` for a name that is not an app name; `ebusy` for a name installed now or of the image; `eio` for a failed `remove_app` |

The reason of every refusal goes to the log. Who holds the `apps` grant
is the manifest's ([design-apps.md](design-apps.md#interfaces)).

**The start service** gains `erx_starter:packages/1`, by which the
package process publishes the package set; it answers once every session
of an app the set drops has ended. It is a call of the package process
alone.

**Inspection**, in `abi/inspection.txt`, reported by the package process
and shown at `/proc/packages` to an inspect facet of scope `all`:
`[packages]`, of kind `packages`, gives `scan` (`ok` or `overflow`, with
the entries read), `room`, the `apps` budget left as the kernel reports
it, and lists the packages by name; `[packages, Name]` gives `version`,
`memory`, `place` (`image` or `installed`), `signer` (a `signer` row's
name, `development`, `image`, or `unchecked` where Phase 1 checks none),
`state` (`admitted` or `refused`), `reason`, `needs` and `license`. An
app's start row is at `[apps, Name]` and its sessions at `[domains, Id]`,
as any row's and any session's.

**Manifest rows**: `apps`, as in [The `apps` row](#the-apps-row);
`package`, with `input` naming the package's artifact and `enable`,
whose header hash the packer records; `signer`, with `key`. Their
packed records and the readers' bounds are in `abi/manifest.txt`; the
facet parameter `tree` is in the storage service's schema.

**The ABI source**: `abi/formats/package.txt`, the header and the packed
declaration; the limits `apps_max_limit`, `app_memory_default`,
`app_memory_min`, `pkg_header_max`, `pkg_needs_max`, `pkg_args_max`,
`pkg_bytes_max` and `pkg_scan_max`.

**Erlang**: `erx_pkg_header:verify/2`, `erx_app_admit:admit/3`,
`erx_pkg_plan:install/3`, `remove/2` and `recover/2`,
`erx_principal:register_app/2`; in a session, `erx_app`.

### Other subsystems

| Subsystem | Its part |
| --- | --- |
| the manifest check ([design-system.md](design-system.md#the-manifest)) | the `apps`, `package` and `signer` rows and the rows derived from `apps`; property 19; A10 holds, since an app selects among rows the manifest set |
| the root task and the resource policy | the `apps` budget carved from the root at boot, the apps group under `users`; app principals' elastic budgets under it |
| the domain library | the principal table sized for the manifest's principals and `max` apps; `erx_dom_plan_session` taking an app principal with the app template |
| the domain service | the app's session: the kept rows, and the app's record, with its package's place and image facts, in the ready answer |
| the principal service | `register_app/2`; no app principal is unregistered within a boot |
| the start service ([design-apps.md](design-apps.md#the-start-table)) | the package rows after the manifest's; `packages/1`, answered once the dropped apps' sessions have ended; the merge's grants for an app from its admission; the `apps` tree's `pkg/` and `purge` |
| the file service ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)) | a tree's `clunk` answers `ok` or `{error, Errno}`, and `erx_fs` answers the client's clunk with it once the file's owner has run it, after every request sent before it; the fid ends whatever the answer, as clunk(5) says |
| the shell ([design-shell.md](design-shell.md#commands)) | `cp` opens its target itself, copies in pieces as its info report needs, and reports a failed close of the target as it reports a failed write |
| the storage service ([design-storage.md](design-storage.md#interfaces)) | the `packages` tree: the data partition's directory and the slot's package image read-only; `apps/` and `tree apps`; `remove_app` on the durability facet |
| the runtime and the EROFS reader | `erx_verity` reading an image from a file at an offset through the domain's namespace, as well as from a block window; the `/app` mount |
| programs ([design-programs.md](design-programs.md)) | an executable file from `/app/bin`; `open` through the handler; `erx_prog_handler:start/1` with a window |
| the display ([design-display.md](design-display.md#the-window-tree)) | a program started with a window; `erx-lvgl` in every image whose release holds `erx_ui` |
| live code ([design-live.md](design-live.md#the-code-store)) | an app principal's overlays live in memory only |

## Concurrency

The package process, `erx_pkg`, a process of the start service's
application, owns the package set: each package's name, header,
admission and state. It takes one close, removal or purge at a time, in
the order they arrive, so two copies of one name closed together each
run whole and the later one is what stays published. It does no file
operation itself: every read, write, rename, deletion and checkpoint
request on `packages` and every `remove_app` runs, one at a time, in
`erx_pkg_io`, which answers each request when it is done, so a slow
storage domain delays a close or a removal, not the package set's
answers or the start table. The `apps` tree's file owner for a copy
waits for the package process's answer before it answers the close, as
any tree's owner runs a file's requests in turn
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).

The start service owns whether an app may run: the rows are part of the
package set it was last given, kept with its rows' run records. A crash
of the package process ends no session; it restarts and runs the
recovery, which rebuilds the set from the manifest and the directory and
publishes it. A crash between a publication without an app and the
rename leaves the app stopped only until the recovery's publication,
which brings the app back with whichever file the directory holds. A crash of the start
service's table process loses nothing the package process holds: on its
restart it asks the package process for the set, as it reads `rc.conf`.
The registry of app principals belongs to the principal service and only
grows within a boot, so a register that a crashed install left behind is
an app principal with no package, as after a removal.

## Compatibility and migration

The package format, `app.txt`'s grammar and the `apps`, `package` and
`signer` rows owe nothing to earlier forms
([design.md](design.md#decisions), "No backward compatibility in
development"). A package built for another `ERX_ABI_VERSION` or another
architecture, after a system update or before it, is refused with `{abi,
Have, Want}` or `{arch, Have, Want}` and shown so; it stays on the
medium until the administrator copies a rebuilt one over it or deletes
it. A package whose need an update's `apps` row no longer offers is
refused with `{not_offered, S}`, and its data stays.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | What happens |
| --- | --- | --- |
| a header fails its checks, its hash differs from its `package` row, or it names no trusted signer | `erx_pkg_header:verify/2`, the package process | a copy's close answers its errno and nothing is published; a package found on the medium is `refused` with the reason at `/proc/packages`; an image package refused at boot leaves its row out of the table |
| admission refuses | `erx_app_admit:admit/3` | as above, with the reason |
| a copy cut short or run on | the close's length check | the close answers `einval`, the temporary file is deleted, and no name is published |
| an app's session does not fit what is left of the `apps` budget | the kernel's carve, through the domain library | the start answers `no_memory` naming the `apps` budget; the keeper counts an end, and the row goes down past its intensity, with the reason at `/proc/apps` |
| a block of the image fails its hash | `erx_verity` in the app's session | the read answers `eio` with a log line naming the image and block; the code load or file read fails, the session ends, and the row counts an end, with the reason at `/proc/apps` |
| the image does not mount | `erx_app` | the session ends at its start with the reader's reason |
| a missing application or a refused program | `erx_app` | `erx_app` ends with the application's start error or `{program, Reason}`, and the session with it |
| the storage domain is down at boot | the package process's read through `packages` | the image's packages wait for it, as `rc.conf` does, as do the installed ones; their rows are absent until the recovery runs; on the stopgap the image's packages, in the release, do not wait |
| a power cut inside an install or a removal | the recovery | temporary files are deleted; each name holds its old package or its new one, or none |
| the package directory holds more than the scan bound | the recovery | no installed package is admitted; `scan` is `overflow` at `/proc/packages`; writes and removals in `/apps/pkg/` answer `eio` |
| no free entry | admission | `apps_full`, until a reboot frees the entries of removed apps |

Every state above is an attribute at `/proc/packages` or `/proc/apps`,
or an errno and a log line naming the package and the reason. Nothing is
shown as admitted that the package process did not admit.

## Security

**What is trusted.** The manifest, with its `apps` row, `package` rows,
`signer` rows and the image's package hashes, as part of the boot image;
the package process, the principal service, the start service and the
domain service, in the system domain; the small Ed25519 verifier; each
app's own runtime, for that app alone.

**What is not.** Every package byte, header and declaration; the copied
bytes; every entry of the package directory; the data partition and the
storage domain; an app's code; an app directory on the build host.

* **The system domain reads a header, never an image.** The header is at
  most 64 KiB, read through a generated reader with a fuzz target over the
  whole verification entry, locating the declaration, key and signature
  in bytes an attacker wrote, truncated at each field and with every
  length out of bounds. The image is parsed only by the app's own
  session, whose failure is its own.
* **A package cannot widen its authority**: the grammar names services,
  admission keeps only the row's, the build counted the row at its worst
  (PK1, PK2). What the administrator approves by copying is which of the
  row's services the app takes and how much of its budget, with no
  prompt. Every app may take every service the row offers; a builder who
  wants a service for some apps only gives the machine no row for it, or
  signs only the apps that may have it.
* **Who installs.** Only a session whose template holds the `apps` grant
  sees `/apps`, so only it can copy into `/apps/pkg/`, delete there or
  purge; the manifest grants it to `root`'s template in a development
  build and to an administrator's in a release build.
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
* **A crafted data partition, or a storage domain it took over,** can
  withhold or delete packages, put back an older package of the same
  signer, and swap an installed package for another package of the same
  name that a trusted signer signed, which then runs with that app's
  data. Since it can already read and destroy every app's data, that
  gains it what copying and deleting would. It cannot run code no
  trusted signer signed, change a byte of an image, widen a grant, start
  an app with no start row, steer a purge at anything that is not an app
  (PK8), or make the recovery spend past its bound (PK9). Refusing an
  older package needs a counter the platform's trust root keeps, as for
  system updates ([design-storage.md](design-storage.md#system-updates)).
* **The bytes checked are the bytes published.** Verification runs at the
  close, when the writing open has ended, on a temporary file that no
  open can reach by name, so the administrator's session cannot change
  the bytes between the check and the rename. A storage domain that
  changed them could change only bytes the hash tree then refuses, since
  the session's root hash is the one the package process verified.
* **Signer continuity, and a residual.** An update needs the installed
  signer, and within a boot a removed name keeps its principal and its
  signer, so another signer's package of that name is refused
  `signer_changed` until a reboot. Removal keeps the app's data, so after
  a reboot a package of the same name from a second trusted signer is
  admitted and finds the first app's directory. Every signer is a key
  the deployer put in the boot image; a deployer who trusts more than one
  purges a removed app's directory before another signer's app of that
  name arrives. This is a security residual in `TODO.md`.
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
* **Text from a package.** A package's name, version and license reach
  `/proc/packages`, the log and the host through each sink's escaping
  function, as all text attributed to a source does
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
| rooting `data` grants by principal, `apps/` and `tree apps` | principals' directories (M10) | apps can reach each other's directories, the residual design-apps.md records; the directory half of PK4's test waits, its `/proc` half runs |
| `purge` with `remove_app` | the same | `purge` answers `enotsup` |
| the image builder's packages on the system slot | the storage service serving a slot's image | they lie in the boot image's domain release, readable by every domain, enlarging the boot image and the memory it holds; a large one needs a larger root place on the stopgap |
| checking an installed package's signature | the small verifier in the build ([plan.md](plan.md#m11-security-closure)) | a development build installs packages whose signature it cannot check and shows them `unchecked`; a release build installs none |

## Verification and testing

Each test is paired with the seeded fault that proves it runs the code
it guards.

**Host tests.**

| Test | Passing case | Seeded fault |
| --- | --- | --- |
| the declaration's parser (Ruby, in the packer) | the two examples above pack to their expected records, the three-line one with every default; a declaration with both `applications` and `program`, and one with neither, refused; each bound of the table refuses one past it, naming the line | the bound on `needs` removed, which packs seventeen needs |
| `erx_pkg_header:verify/2` | a package signed by a trusted key, one of an untrusted key, a flipped signature byte, a header cut at each field, lengths that overflow; under `{hash, H}`, a package signed by an unknown key and matching H accepted, and one byte off refused | a verify that skips the signature check, which accepts the flipped byte; a verify that reads the signer under `{hash, H}`, which refuses the unknown key |
| admission, one corpus run by the machine's module and by the packer's host run | each refusal of [Admission](#admission) and its accepting neighbour, the names `root`, `root_1`, a configured domain's and a service's among the refused | the subset test of step 6 dropped, which admits a need the row lacks; `root` dropped from the reserved names |
| the close's checks | a file one byte short and one byte long of its header's lengths, and a file named for another app than its header's, each refused `einval` with nothing published and the temporary file gone | the length check made "at least", which publishes the long file |
| the install, removal and recovery planners | a simulated directory records every write, cuts power after each and reorders the writes between checkpoints, as [design-storage.md](design-storage.md#read-write-storage)'s harness does; every resulting state recovers with each name holding its old package or its new one, whole, or none, and no temporary file | an install that renames before the temporary file is durable, after which a reordered cut leaves a published name with missing bytes |
| purge targets | `purge` of `root`, a configured domain, a manifest principal, an image package's name and an installed app refused, with no `remove_app` | the app-name rule skipped, which sends `remove_app root` |
| the recovery's bounds | a listing of `pkg_scan_max` + 1 entries gives `overflow` and no admission | the bound check removed, which reads the whole listing |
| a publication that drops an app | the app's keeper and `onestart` session end before `packages/1` answers; `service NAME start` is refused until a set with the app arrives | a publication answered before the sessions end, which the test catches with a session still alive |
| the start table's grants for an app | an `rc.conf` line naming a display of the row the app did not need is refused `{no_grant, D}` | the merge given the app template's whole grant set, which accepts it |
| the app session's plan in `erx_domain_core` | the session's rows are `packages` and the rows its needs name; every minted scope names the app's principal; the session's memory is the declared one; one header admitted as an image package and as an installed one gives the same plan (PK10) | a plan that grants every row of the template; a scope computed from the template's key; a plan that grants an image package the template's whole row set, which the comparison catches |
| `erx_app` over a fixture `/app` | the declared applications start; a fixture app that ships a module of the release's name leaves the release's module loaded, and only the app fails | the app's paths added at the front of the code path, which loads the app's module |
| entries | `max` + 1 distinct names installed and removed in one boot, the last refused with `apps_full`; a name installed again takes its entry again | a removal that frees the entry |
| the build's check | each clause of property 19 | each seeded violation of [The build's check](#the-builds-check) |
| `examples/dashboard` through the SDK | its frame through `erx_ui_host` matches its reference, and a click on Pause changes only the status line and buttons | a status line one pixel taller |
| the SDK's boundary | the example compiles, and xref finds every call it makes into erXos's modules in `public.txt`, by module, function and arity | the example calling `erx_ui:start/1`, exported by a public module but not public, which the check refuses |
| no list names an example | a source check over `tools/lib/erx`, `config/manifest` and the test lists finds no path under `examples/` | `erx_dashboard` added to `ErlangApps::APPLICATIONS` |

**QEMU tests**, in the suites of the plan's parts that bring them:

* a kiosk image with `examples/dashboard` added by `tools/erx pack --app
  --enable dashboard` boots to its UI on the display, whose screendump
  matches the host test's reference; seeded: `--enable` dropped, and the
  screen stays blank;
* two apps: neither's `/proc` shows the other's domains; once `data`
  grants are rooted by principal, neither reads the other's `/data`;
* a test program packaged with a display need draws through `/dev/draw`
  and changes its picture at a key that QMP sends; seeded: the program
  started without a window, which ends with its open of `/dev/draw`
  failing;
* run-time install: `cp dashboard.pkg /apps/pkg/` succeeds and
  `/proc/packages` shows it `admitted`; `service dashboard enable`
  starts it; a reboot keeps it; copying a newer build over the running
  app runs the new code with the app's files kept, and no session of the
  old version exists once the first publication has answered; a copy
  whose session is killed halfway publishes no name; one byte of an
  installed image flipped on the medium gives `eio` and the row `down`
  with the reason; a copy one byte short fails its `cp` with `EINVAL`
  and publishes nothing; seeded: the update without
  the first publication, after which the old version's keeper restarts
  it during the rename;
* removal: `rm /apps/pkg/dashboard.pkg` leaves no package or row and the
  app's directory in place; `ls /apps/pkg` lists the image's packages and
  `rm` of one answers `EPERM`;
* from M10, `purge` removes the directory; from M11, a package of an
  untrusted signer, and one whose header has a byte flipped, fails its
  `cp` with `EACCES`, and an installed header flipped on the medium is
  `refused` at the next boot;
* the states the inspector shows, each with a test: `admitted`,
  `refused` with its reason, `overflow`, and `unchecked` in Phase 1.

**Fuzz targets**, each landing with its parser: the declaration's text
parser on the host; `erx_pkg_header:verify/2` as a whole, over a
generated corpus of headers; `erx_pkg_plan:recover/2` over generated
directory listings, with names of every form, temporary files, reserved
and manifest names, and listings past the bound; the names the `apps`
tree's `pkg/` takes, and `ctl`'s grammar with `purge`.

**Chokepoints**, each a build check with a seeded violation:

* only `erx_pkg_header` reads a package's bytes in the system domain,
  and no system-domain module reaches `erx_verity` or `erx_erofs` for a
  package (PK5);
* only `erx_pkg_io` writes the `packages` tree and sends `remove_app`;
* only `erx_pkg` calls `erx_principal:register_app/2` and
  `erx_starter:packages/1`;
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
bytes of a copy into `/apps/pkg/` through the system domain's `apps`
tree. An install asks for two checkpoints and a removal for one;
installs are rare enough that this is not on the list.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| **Classes**: the manifest declares named classes, each a session template with its facet rows, a principal's shape and a count of places; an app joins one class and selects among its rows, and each place reserves its class's memory | Rejected as inflexible: an app that needs something between two classes needs a new class from the builder, every class reserves memory for places nobody fills, and an app author has to learn a concept that exists only for the proof. One `apps` row gives the same proof with the app naming what it needs |
| **`pkg add`, `pkg delete` and `pkg info` commands over `install` and `remove` commands of the `apps` tree's `ctl`**, with a staging file per install | Each is a command, a grammar and an errno table for what a copy, a deletion and a listing already say, and staging adds a visible half-installed state with its own cleanup. A directory the system domain serves keeps the one writer and makes the close the commit, as copying an app into `/Applications` is on macOS |
| **An app chooses its facet parameters within the row's bounds**, or the builder overrides the derived rows | The build counts every row at its own parameters whatever the app picks, so a lower value saves the machine nothing and adds a rule per parameter to admission and to the mint. A builder who wants other values for every app sets them where the service's defaults live; one who wants them per app makes the app part of the manifest |
| **An app declares a guarantee and a cap** | Each session's budgets are walls, as every domain's are, so a session's memory is one figure; the elasticity is between apps, in the `apps` budget, where the kernel already provides it |
| **A sum of installed apps' memory checked at install** | It judges again what the kernel judges at every start, and it promises less than it seems: which apps run at once depends on what is enabled and started, not on what is installed. It also made recovery order matter, since the sum admitted packages in name order until the budget ran out. The build sums the image's enabled packages, and the kernel judges the rest |
| **An app principal's budget a wall carved at install** | An update that changes the memory would resize a wall while the old session's outer budget may not have retired, and a removal would have to wait for every retire before giving the memory back. An elastic budget under the `apps` wall needs neither |
| **A pool**: one principal pays for many apps, and each domain record names both the app it acts for and the pool that pays | Every reader of a principal must then choose the right one of two fields; the inspect scope and the grant records each chose wrong in the review of that design. Each app here is a whole principal, so every reader stays as it is |
| **A package carries an OTP release with its own boot script** | A boot script pins the versions of the release's applications, so every system update would break every package. `erx_app` starts the app's applications over the `app` release |
| **An environment field in the declaration** | Its one use was naming the UI renderer, which `erx_ui:open/1` takes as an option; anything else an app wants it can set itself |
| **A check that refuses an app whose module names clash with the release's** | The app's paths come after the release's, so a clash breaks only the app that brought it; the check would be one more refusal to keep in step with the release |
| **A version an update may not lower, with a flag to override it** | Against the administrator it only adds a flag; against a storage domain that puts back an older file it holds nothing without a counter the trust root keeps. The version is shown, not judged |
| **Packages unpacked into a directory of the data partition** | Their integrity would rest on the storage domain. An EROFS image under a hash tree, checked by the reader, makes it rest on the header alone |
| **The image builder's packages in the boot image** | The boot image is held in memory and bounded by the root place; Doom's 28 MiB WAD made the image 88 MiB. On the slot they are read on demand and still change only with the system |
| **Every package ships its own `erx-lvgl`** | One copy per app, a wire between toolkit and renderer that each app's build could skew, and LVGL's notices in every package |
| **A launcher in Erlang for each native app** | The display already starts a program with a window and binds its draw and input files; `program` reaches that for every native app |
| **A native window app draws into its buffer and presents through a pipe protocol, as `erx-lvgl` does** | It would be a second public path to the screen. `/dev/draw` is the designed one; the measurement on the watch list decides whether a faster one is needed |
| **Signers trusted on first install, or added at run time** | The record of who is trusted would lie where the storage domain can rewrite it. Keys in the boot image cannot be |
| **Unsigned packages in development builds** | A second mode in the header, the verifier and the inspector, for nothing: the packer signs with the development key by default, which costs a developer nothing, and development builds trust that key |
| **The package process stops an app's domains itself** | A keeper restarts a session after every end, so old code could start again during the rename, and a removal would steer a lookup by principal name. The start service, the only starter of app sessions, ending the sessions of an app the published set drops removes both |
| **Removing an app's data with its package** | Deleting a package file would destroy what the app wrote, which macOS and FreeBSD do not do, and a removal of two things needs a durable marker and a recovery to finish it. A purge is a separate, explicit act |
| **App data removed through a system-domain grant over the whole data partition** | The system domain would hold write access to every principal's files for one operation, and a wrong name would reach them. `remove_app` reaches only `apps/` |
| **The administrator's session writes packages straight into the storage domain** | It needs a writable grant on part of the package tree and lets an administrator's session change installed files behind the package process. Copying through the `apps` tree keeps one writer |
| **Rows generated into the manifest for each app, a principal and template of its own, with the sums grown** | Doom's `run.rb` did that. It grows the board's sums with each app and is a second path beside run-time install; the `apps` row makes one path |

## Risks and decisions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| the build counts `max` apps each holding every service, so a large `max` with a display in `services` reserves the display's memory for pixel areas few apps use | medium | a display domain sized larger than its use | the builder sizes `max` to what the machine expects |
| installed apps together want more than the `apps` budget | medium | the last one started is refused `no_memory` and its row goes down | the builder sizes `memory`; `room` at `/proc/packages` and the row's reason at `/proc/apps` show it |
| a full-window frame through `/dev/draw` is too slow for a game | medium | Doom runs below its frame rate | the watch-list measurement; a faster path is a design change of the display's, if needed |
| the app's code reads slowly through the file protocol and the hash check | medium | slow app starts | `tools/erx bench app-start`; the shared code design maps prepared code later ([design-shared-code.md](design-shared-code.md)) |
| a restart while the `apps` budget is full waits for the ended session's outer budget to retire | low | one refused restart, counted against the row's intensity | the app's cap holds a session beside one outer budget not yet retired |

Decisions:

1. **An app is a principal of its own**, made from its declaration and
   bounded by one `apps` row; no app joins a class or a pool.
2. **Memory is shared through one elastic level**: app principals'
   budgets are elastic under the `apps` wall; each session is walled;
   the build sums the image's enabled packages, and the kernel judges
   every start.
3. **A machine trusts only the signer keys its boot image carries**:
   the manifest's `signer` rows, and the development key in a development
   build. Every package is signed.
4. **Every app may read every package's bytes**, as stated in
   [Where a package lies](#where-a-package-lies).
5. **Installing is a copy into `/apps/pkg/` and enables nothing**; the
   image builder enables a row of the image's packages, the administrator
   an installed one.
6. **One file per name**, replaced by rename at the close that wrote it.
7. **A name the image holds is the image's**: it is not installed over
   or removed at run time, and changes with a system update.
8. **Removing a package keeps its data**; `purge` removes it; no prompt
   asks a person to approve grants; no fetch by name.

Questions for the owner, each with a recommendation:

1. **A close that answers an errno.** Installing by copy reports a
   refused package through the copy's close, which needs the file
   service to pass a tree's answer to a clunk back to the client
   ([Other subsystems](#other-subsystems)); today `erx_fs_grant` answers
   a clunk itself and the tree's callback answers only `ok`.
   Recommended: every tree's `clunk` answers `ok` or an errno, and the
   grant answers the client with it once the file's owner has run it,
   which costs a close the wait for the writes sent before it, as POSIX's
   `close` already may with `EIO`. The alternative keeps the file
   service as it is: a close always answers `ok`, and an administrator
   learns of a refusal only from the log and `/proc/packages`.
2. **The shipped manifests' `apps` rows.** Recommended: the development
   manifests declare one `apps` row with `max 8`, `services display data
   net`, and a `memory` that holds eight apps at the default 64 MiB; a
   kiosk board's manifest `max 1` and `services display data`.
3. **The program launcher's needs of `erx_prog_handler`.** The handler
   being built takes pipe ends and a window's buffer; a native app with a
   display need needs it to start a program with a window as
   [design-display.md](design-display.md#the-window-tree) says.
   Recommended: that option lands with the handler, so no second launcher
   exists.
4. **The Doom submodule's row in the dependency table.** Doom and
   Freedoom are fetched only on request and enter no distributed image.
   Recommended: a row marked `example`, neither `permanent` nor
   `stopgap`, naming GPL-2.0 and the rule that keeps it out of
   distributed images.
5. **A policy per signer.** The `apps` row offers its services to every
   app. Recommended: no per-signer policy until a machine needs one; the
   builder's lever is which keys it trusts.

## References

* FreeBSD: `pkg-delete(8)`, `pkg.conf(5)` (signature checking against
  trusted fingerprints), `rc.conf(5)`.
* Android: application signing and the application sandbox.
  <https://source.android.com/docs/security/features/apksigning>,
  <https://source.android.com/docs/security/app-sandbox>
* Android: APEX file format. <https://source.android.com/docs/core/ota/apex>
* Linux: dm-verity's hash tree format, as design-storage.md uses it.
* Plan 9: `draw(3)`, `rio(4)`, `clunk(5)`, `remove(5)`.
