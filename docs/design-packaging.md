# Apps: packages and the SDK

A **package** is one file that carries an app built outside erXos's tree:
a declaration of what the app is and needs, and a read-only image of its
code and data. This document says how a third party builds one with
erXos's SDK, how an image builder adds it to an image, how an
administrator installs, updates and removes it on a running machine, and
what the app may take. Its central construction is the **class**: the
manifest declares, once, a session template with its facet rows and a
principal's shape, and says how many apps it holds; each app of a package
fills one of those places with a principal of its own and takes a subset
of the class's rows. The build proves every sum for the class, so every
app of every package stays inside what the build proved, and admitting a
package is a check that one set lies inside another. The start table,
principals, session templates and facets are those of
[design-apps.md](design-apps.md); this document adds the class, the
package, the place a package lies and the SDK. The architecture is in
[design.md](design.md); the manifest and its check in
[design-system.md](design-system.md#the-manifest); principals and
sessions in
[design-domains.md](design-domains.md#principals-sessions-and-quotas);
read-only images in
[design-storage.md](design-storage.md#reading-erofs-images); native
programs in [design-programs.md](design-programs.md); windows in
[design-display.md](design-display.md).

Decisions every reader of this document needs:

* **An app of a package is a principal, made from its class.** A class
  of `apps N` is N principal places of one shape: memory, share of
  `users`, `domains` and `names` quotas, limits. Registering an app fills
  a free place with the app's own name for the rest of the boot. Every
  rule that keeps principals apart, its directory, its inspect scope, its
  session names, its death records, keeps apps apart with no rule of its
  own, and no domain ever runs as a class.
* **A package selects; it never adds.** The declaration names a class,
  the services of that class's rows it needs, its code and an optional
  start row. It has no field for a limit, a budget, a quota, a facet
  parameter or a grant, so nothing an app declares can reach past its
  class. Admission is set inclusion, one pure Erlang function that the
  build runs on the host and the system domain runs on the machine.
* **The code is an EROFS image under a hash tree, read by the app's own
  session.** The app's session mounts its package's image at `/app`
  through the hash-checking reader, against the root hash of a header the
  system domain authenticated: by a hash the manifest records for a
  package of the image builder's, by a trusted signer's signature for one
  installed at run time. The system domain reads only the header.
* **One package, two ways onto a machine.** `tools/erx pack --app` adds a
  package to an image; `pkg add` installs the same file on a running
  machine. Both run the same admission and give the same session.
* **Nothing starts because it was installed.** A package declares a start
  row; the image builder enables a row of the image's packages, and the
  administrator enables an installed one with `service NAME enable`, as on
  FreeBSD.
* **The toolkit's programs ship with the toolkit.** `erx-lvgl` lies in the
  domain release's `bin/` of every image whose release holds `erx_ui`; no
  package carries it.
* **The SDK is the boundary.** An app compiles against the SDK alone: a
  sysroot with musl's headers, liberx's program layer and its link, the
  public Erlang applications, a host stand-in for a display, and the
  packer. The in-tree examples build through the SDK alone, so a break in
  the boundary fails the landing gate.

**How do I make an app?** Write `app.txt`, put the app's OTP
applications under `lib/` and its native programs under `bin/`, and run
`erx-app pack DIR`, which writes `NAME-VERSION.pkg`
([Building and packing](#building-and-packing)).

**How does it reach an image?** `tools/erx pack --app DIR` builds and
packs the app, checks it against the image's manifest and adds it;
`--enable NAME` makes its start row start at boot. The board's manifest
is not edited.

**How does it reach a running machine?** `pkg add NAME-1.pkg` at the
shell of a session that holds the `apps` grant, then `service NAME
enable` if it should start at boot.

**What may it take?** What its class's template is granted, filtered to
the services its declaration names, with its class's limits, and nothing
of the person who installed or started it.

## Context

### What exists

An app is a principal with a session template, whose release is its code
and whose facet rows are its authority, and the start table starts and
keeps its session ([design-apps.md](design-apps.md#an-app)). Built today:
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

### What two demo apps found

Two apps were built the way a third party would build them, to find
where the app boundary is missing. The kiosk dashboard (`erx_dashboard`,
branch `lvglscreen`, commit `82b02f4ff`) and Doom (the repository
`erxos-doom`, gaps marked `BOUNDARY GAP` in `run.rb` and listed in its
`README.md`) each reached past what an app should need:

| Finding | Where it came from | What answers it here |
| --- | --- | --- |
| the app's application had to join `ErlangApps::APPLICATIONS` (`tools/lib/erx/erlang_apps.rb:25`), a release script (`tools/lib/erx/release_files.rb`, `RELEASE_SCRIPTS`), because `check_released` refuses an application no release holds, and `release_files_test`'s list | kiosk | an app's applications are in its package and never in a release file; its class's template boots the system's `app` script, whose `erx_app` starts them from `/app` |
| Doom's launcher had to be one `-eval` expression, since `ReleaseFiles.domain_boot` admits only applications erXos's runtime builds | Doom 2 | the same; a native app needs no Erlang at all: its declaration names its program and asks for a window |
| manifest rows per app, and machine-wide sums grown by hand: display outer budget and connections, the system principal's memory, `root_memory`, `max_domains`, `max_connections` | kiosk, Doom 3 | the class: the board declares its rows and sums once, for all its apps |
| no SDK: the build drove `tools/lib/erx` internals (`NativeRoot`, `ProductionImage`, `Programs::PROGRAM_PREFIX`) | Doom 1 | [The SDK](#the-sdk) |
| the program joined the one domain release's `bin/`, seen by every session | Doom 5 | the program is `/app/bin/NAME`, an executable file run through `erx_exec` |
| app code in the boot image made it 88 MiB, past the stopgap's 64 MiB root place | Doom 6 | the image builder's packages lie on the system slot, outside the boot image ([Where a package lies](#where-a-package-lies)) |
| no `open()` in a native program: `liberx/program/fd.h:37-41` has null, pipe and mem objects, and the C library seam answers every unlisted call `ENOSYS` (`musl/src/internal/erxos/syscall.c:536-537`), so the WAD was linked in | Doom 4 | designed, not built: [Descriptors and files](design-programs.md#descriptors-and-files) gives a program files through its handler; a package's data is `/app/share`, its writable files `/data` |
| the launcher invented a pid, parent, group, directory and masks for `erx_program:start/1` | Doom 7 | programs start through `erx_prog_handler`, which assigns them |
| presents on a 100 ms timer, no keyboard | Doom 8, 11 | a program started with a window draws through `/dev/draw`, flushes when its frame is done, and reads `/dev/kbd` |
| `erx_win:open/2` answered `{error, none}` until the display's grant arrived, so the launcher polled | Doom 9 | `erx_app` starts the app's code only once the session's ready answer has come, after its grants |
| a crashed session's restart was refused with `no_memory` while the ended domain's budget was still held | Doom 10 | the class check plans a restart beside an ended session's outer budget ([The class check](#the-class-check)) |
| `bin/erx-lvgl` reached only the programs suite's test image (`tools/lib/erx/production_image.rb:95-99`) | kiosk | the toolkit's programs ship with the toolkit in every image |
| the host test used toolkit internals (`erx_ui:start/1`, `erx_ui_lvgl`'s `open` and `present` funs) | kiosk | `erx_ui_host`, the public host stand-in for a display |

### What other systems teach

These are taken from each system's published descriptions, not re-read
for this design.

| System | What erXos takes | What it leaves |
| --- | --- | --- |
| Android | a user id per app, so the separation between users is the separation between apps; a package signed by its author, and updates only from the same key | permissions granted one by one at run time; apps that grant each other services |
| Android APEX and Fuchsia packages | code as a read-only image checked block by block against a hash a signed header names | their package managers and resolvers |
| FreeBSD `pkg` | `pkg add`, `pkg delete` and `pkg info`; signature checks against keys the system trusts; an installed service starts only once `rc.conf` enables it | repositories and fetching by name |
| Flatpak | an app built against a published runtime and SDK, with the runtime shipped by the system, not the app | runtimes as packages of their own |

## Requirements

* **PK-R1.** A third party builds an app outside erXos's tree, with the
  SDK alone, and the app reaches no list, script or manifest of erXos's.
* **PK-R2.** An app added to an image or installed at run time holds no
  authority, limit or memory the build did not prove for its class.
* **PK-R3.** Every byte of an app's code and data its session reads
  matches what its author packed, whatever the storage domain does.
* **PK-R4.** Two apps never read each other's files or see each other's
  domains, whatever class they share.
* **PK-R5.** The same package and declaration serve the image builder
  and the administrator; the board's manifest is never edited to add an
  app.
* **PK-R6.** Install, update and removal survive a power cut at any
  point: a package is wholly installed or wholly absent, and a removal
  finishes.
* **PK-R7.** The system domain's atoms, tables and memory stay within
  bounds the build set, however many packages come and go in a boot.
* **PK-R8.** Every package byte, header and declaration is untrusted
  input to the system domain and to the build host.
* **PK-R9.** No copyleft package enters an image erXos distributes.

Outside this design: fetching packages by name (a fetcher is a command
in a person's session that holds `net` and hands the file to `pkg add`);
prompts that ask a person to approve a grant; apps that serve facets to
other apps; keys at the vault for an app; packages of system services or
drivers, which are configured domains of the manifest.

## Overview

```text
 the developer's host                 the image builder               the machine
 --------------------                 -----------------               -----------
 DIR/app.txt  lib/  bin/  share/      tools/erx pack --app DIR       system domain
      |                                 --enable NAME                  erx_pkg: authenticates each
      | erx-app pack (SDK)                |                              header, admits it against its
      v                                   | admission on the host        class (erx_app_admit), registers
 NAME-V.pkg: header (declaration,         | against the manifest         the app's principal in a free
   root hash, signer, signature)          v                              place of the class, hands the
   + EROFS image + hash tree         image: the manifest's class         start table its start row
      |                              rows, a `package` row per app,            |
      | pkg add (administrator)      the package on the slot                   | start_session(app, Start)
      +---------------------------------------------------------------> domain service: a session of
                                                                       the class's template, as the
                                                                       app's principal, with the rows
                                                                       its declaration names and its
                                                                       package at /app
                                                                               |
                                                                       session app_1: erx_app starts
                                                                       the app's applications from
                                                                       /app/lib, or its program from
                                                                       /app/bin, in a window
```

**An app's life, end to end.** A developer writes `app.txt` for
`dashboard`, in class `kiosk`, needing `display` and `data`, with a start
row on `display`, and packs it with the SDK. The image builder runs
`tools/erx pack --app DIR --enable dashboard`; the build checks the
package against the board's `kiosk` class and records it in the image's
manifest. At boot the system domain's package process reads the
package's header, checks it against the manifest's record, admits it,
and registers the principal `dashboard` in one of `kiosk`'s places. The
start table starts the row; the domain service makes a session of
`kiosk`'s template as `dashboard`, named `dashboard_1`, holding the
template's `display` and `data` rows and nothing else of it. Once the
session's grants are in place, `erx_app` mounts the package's image at
`/app`, puts `/app/lib/*/ebin` on the code path and starts
`erx_dashboard`, which opens its window with `erx_ui:open/1`. Later an
administrator copies `dashboard-2.pkg` to the machine and runs `pkg add`:
the package process authenticates it by its signer, stops the app's
session, replaces the file and lets the table start the row again, with
its data where it was.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **PK1.** An app holds no grant, limit or memory its class does not have | the declaration grammar has fields for names only; admission keeps a need only if a row of the class's template serves it; the app's principal is a place of its class, with the class's shape, which the build counted `apps` times in every sum | a declaration field that carries a limit or a parameter; an admission that grants a row the declaration did not name, or a service the class lacks; a check that counts a class once | admission's host corpus with a seeded admission that drops the inclusion test; the session plan's host test with a seeded plan that grants every row of the template; the class check's seeded violations |
| **PK2.** Every block of `/app` a session reads matched the root hash of a header the system domain authenticated | `erx_app` mounts `/app` only through `erx_verity`, with the root hash, salt and tree layout the domain service hands it in the ready answer; the domain service takes them only from a header that matched its manifest hash or its trusted signer | a mount whose root hash comes from the session's own read of the header; a read path around `erx_verity` | a QEMU test that flips one byte of an installed package's image and finds the read refused; the build check that only `erx_erofs` reads through `erx_verity` (`Erx::ErofsReads`) |
| **PK3.** Two apps see nothing of each other | each is its own principal; the domain service computes every scope from the session's principal, the app's; a class is no principal, so no domain record names one and a scope computed from it would hold nothing | a scope, storage root or name pool derived from the template's key; two apps registered under one place | a QEMU test with two apps of one class; seeded: the mint's scope taken from the template's key |
| **PK4.** The system domain parses a package's header alone, through the generated reader, and loads no app code | the package process reads the header's bytes and hands them to `erx_pkg_header:verify/2`; the image is mounted only by the app's own session | a system-domain module that mounts or reads a package's image | a source check over the system release that no module but the package's reader names a package's bytes, with a seeded call of `erx_verity` from `erx_pkg` |
| **PK5.** A package is wholly installed or wholly absent, and a begun removal finishes | install writes the staged file, syncs it, renames it over the name's one file and syncs the directory; removal writes its mark first and deletes it last; boot and the package process's restart run the same recovery before any admission | a second file per name; a mark written after a deletion | the planners' host test over every crash point; a QEMU test that resets the machine inside a removal |
| **PK6.** The system domain's atoms and tables from apps stay within the build's bound | an app principal lives for the boot in one of its class's places, which removal does not free until the next boot; its sessions take pooled names within its class's `names` quota | an unregister that frees a place within the boot; a session name outside the pool | a host test that installs and removes `apps` + 1 distinct names in one boot and finds the last refused with `class_full` |
| **PK7.** A package of the image and one installed at run time give the same session | both pass `erx_app_admit:admit/3` and the same session plan; only what authenticates the header differs | a second admission or plan for one of them | a QEMU test that runs one package both ways and compares the session's grants and `/app` |

## Data model

### A class

A **class** is a manifest row with a principal's fields and one more,
`apps`, the number of apps it holds. Its session template is the
`session` row of its name, and the facet rows that name that template as
grantee are what its apps may take:

```text
class kiosk
  memory 67108864
  grant @share.users
  domains 1
  names 4
  default_limits @limits.app
  ceiling_limits @limits.app
  apps 4
session kiosk
  limits @limits.app
  runtime @artifact.emu
  release @artifact.app
facet kiosk_display
  name "display"
  grantee @session.kiosk
  service @service.display
  parameter pixels 8388608
  ...
facet kiosk_data
  name "data"
  grantee @session.kiosk
  service @service.data
  ...
facet kiosk_packages
  name "packages"
  grantee @session.kiosk
  service @service.packages
  ...
```

* **A class is no principal.** It is a row of its own table, so nothing
  that reads principals, the principal service, logins, start rows and
  `start_session/2`, can reach one: no domain runs as a class, no one logs
  in as one, and a `start` row cannot name one.
* **Its places are principals.** A class of `apps 4` gives the machine
  four principal places of its shape. The domain library's principal
  table holds the manifest's principals and then every class's places,
  sized at boot from the manifest. A place is empty until an app is
  registered in it, and once filled it holds that app's name until the
  machine reboots.
* **Its template is any session template whose release boots
  `erx_app`.** The domain release's `app` boot script holds the base every
  session boots, the client side of the display (`erx_memdraw`, `erx_win`,
  `erx_ui`) and `erx_app`; a class whose apps need other system
  applications names another script that holds `erx_app` too.
* **Its rows are a menu.** An app takes those of the rows it names, by the
  name its grantee holds each under; the rows' parameters, the pixel
  area's size and the rest, are the class's and the app cannot change them.

A board's manifest declares its classes: a kiosk board one class sized
for its one app, a general machine an `app` class with the display, data
and network rows that most apps need and enough places for the apps it
expects. Two apps that need more than a class offers belong in another
class, which the builder declares.

#### The class check

The manifest check gains one property, property 19, **classes and
packages are well formed**, beside the eighteen of
[design-system.md](design-system.md#the-manifest):

1. a class's name is an identifier distinct from every principal,
   configured domain and service, and its `apps` is from 1 to
   `class_apps_max`, 64;
2. a class has exactly one session template, whose limits enable
   `SPACES` (property 14), whose release boots `erx_app`, and which a
   facet row of the `packages` service grants read-only;
3. wherever properties 4, 17 and 18 count a principal, a class counts as
   `apps` principals of its shape: its memory, share, `domains` and
   `names` quotas, and its template's display rows `apps` times its
   `domains` quota times, so the display's budget, the root's memory, the
   domain table and the names the system domain makes atoms of hold every
   place filled;
4. the planner of property 12 plans, for each class, one session of its
   template beside the outer budget of one that ended and has not
   retired, so a class whose memory admits a session but not its restart
   fails the build;
5. every `package` row's package passes admission on the host against
   this manifest ([Admission](#admission)), and the start row of an
   enabled one meets property 17's display and planning clauses as a
   manifest `start` row does;
6. every `signer` row holds a 32-byte Ed25519 public key under a unique
   name.

Each clause has a seeded violation: a class counted once in property 18,
which admits a class whose apps together pass the display's budget; a
template with no `packages` row; a template whose release lacks
`erx_app`; a class whose memory holds one session but no restart; a
`package` row whose declaration needs a service its class lacks.

### The declaration

`app.txt` is written in the syntax of the manifest's source and the ABI
files (`ABI::Syntax`: ASCII, rows at column 0, two-space fields, quoted
strings), at most 16 KiB. It holds a format line, one `app` row and at
most one `start` row of the same name:

```text
package 1
app dashboard
  class kiosk
  version 3
  license "BSD-2-Clause"
  needs display data
  applications erx_dashboard
  env "ui_renderer=lvgl"
start dashboard
  display display
  restarts 5
  restart_period_s 600
```

A native app with a window needs no Erlang:

```text
package 1
app doom
  class games
  version 1
  license "GPL-2.0-only"
  needs display data
  program "bin/doom" "-iwad" "/app/share/freedoom1.wad"
  window yes
start doom
  display display
```

| Field | Value | Bound |
| --- | --- | --- |
| `app NAME` | the app's name, which is its principal's | an identifier ([design-system.md](design-system.md#identifiers)) that stays one with `_` and the digits of its class's `names` quota appended |
| `class` | the class it joins | an identifier |
| `version` | a decimal number that each update raises | 1 to 2^32 - 1 |
| `license` | the package's SPDX license expression | at most 256 bytes, in the grammar `LicenseExpression` reads |
| `needs` | the services of its class's rows it takes, by the name its grantee holds each under | at most `pkg_needs_max`, 16, identifiers, none twice; none at all is allowed |
| `applications` | the OTP applications `erx_app` starts | at most 16 names of the form `[a-z][a-z0-9_]*`, 63 bytes each |
| `program` | a path under `bin/` of the image, then its arguments | the path at most 255 bytes of plain names; at most `pkg_args_max`, 32, arguments, 16 KiB together |
| `window` | `yes` to start the program with a window | only with `program`; `no` by default |
| `env` | `NAME=value` strings the session's environment gets | at most `pkg_env_max`, 16, each at most 1,024 bytes, the name `[A-Za-z_][A-Za-z0-9_]*` |
| `start NAME`: `display`, `restarts`, `restart_period_s` | the start row ([design-apps.md](design-apps.md#the-start-table)) | the bounds of `abi/manifest.txt`; `display` must be one of `needs`; no `enable` field |

An app has `applications`, `program` or both; with both, `erx_app` starts
the applications first. A declaration names no limit, quota, budget,
parameter or grant, and there is no field through which it could: the
illegal declaration is one the grammar cannot write.

The packer parses the text on the host and writes the declaration into
the package's header as a packed record of `abi/formats/package.txt`.
The machine never parses the text: the system domain reads the packed
record through the reader the generator produces from that file, which
checks every count, length and offset before it reads a field.

### The package

A package is one file, `NAME-VERSION.pkg`, of three parts, each starting
at a 4 KiB boundary:

| Part | Holds |
| --- | --- |
| header, at most `pkg_header_max`, 64 KiB | the magic `ERXPKG`, the format version, the header's length, the `ERX_ABI_VERSION` the package was built for, the packed declaration, the image's length in blocks, the hash tree's length, salt and root hash (SHA-256, dm-verity format version 1, as [design-storage.md](design-storage.md#data-model) lays read-only images), the signer's Ed25519 public key or zeros, and the Ed25519 signature over every byte of the header before it, or zeros |
| image | an EROFS image of 4 KiB blocks in the layouts `erx_erofs` reads, whose root holds `lib/APP/ebin` and `lib/APP/priv` for each application, `bin/` for programs and `share/` for data |
| hash tree | the image's dm-verity tree |

The file's length must be exactly the header's length plus the image's
and the tree's, with checked arithmetic. The image's entries carry fixed
owner, mode and time, so the same inputs give the same bytes and no host
metadata leaks into a package. The image names no device, socket or link
leaving it.

`erx_pkg_header:verify(Bytes, Signers)` is the one entry that reads a
header: it checks the magic, version and lengths, decodes the declaration
with the generated reader, and checks the signature when the header
names a signer, which must be one of `Signers`. It answers
`{ok, Header}`, with the header's signer named or `unsigned`, or
`{error, Reason}`. It is pure but for the signature check, which the
small Ed25519 verifier of [design.md](design.md#dependencies) makes, as
for an update's manifest.

### Where a package lies

| | The image builder's packages | Installed packages |
| --- | --- | --- |
| placed by | `tools/erx pack --app`, or a `package` row of the board's manifest | `pkg add` |
| lies | in the system slot, in the package image, an EROFS image of package files that the manifest's `image` row records like the release's; the storage service serves its files read-only under `packages/image/` | in the data partition's `packages/` directory, which the storage service serves |
| header authenticated by | the SHA-256 of the header, which the manifest's `package` row records; no signature is needed | a signer of the manifest's `signer` rows; in a development build also the build's development key |
| changes | with a system update, as the slot does | by `pkg add` and `pkg delete` |

Either way the system domain and the app's session reach the file
through the `packages` service, an instance of `files` that the storage
domain serves at a service directory of its own: the system domain reads
and writes it, and each class's template reads it. Since `erx_verity`
checks every block against the root hash of the authenticated header,
no property of a package rests on the storage domain but its presence:
a storage domain can withhold a package or put back an older one of the
same signer, never change one.

**On the stopgap**, where the storage service does not yet serve a slot's
image, the image builder's packages lie in the boot image's domain
release at `pkg/NAME.pkg`, and their sessions read them through `/`,
the release slice. They enlarge the boot image and the memory it holds,
and every domain can read them (Phase 1).

### An app's principal

The principal service registers an app's principal with
`erx_principal:register_app/1`, which only the package process calls, in
a free place of its class; its record holds the app's name, its class,
its signer (or `unsigned` for one of the image's) and its place. A
principal of an app has its class's memory, share and quotas, and no
credentials: no one logs in as an app. Its directory on the data
partition, its inspect scope and its name pool are those of any
principal, keyed by its name. It is never unregistered within a boot: a
removed app's principal keeps its place and name, with nothing to run,
until the machine reboots, so its atoms and its table entry stay within
the class's count (PK6).

### An app's session

`erx_domain:start_session(App, Start)` makes an app's session as it makes
any session, with three differences, all decided by the domain service
from the app's admitted record:

* the domain library's plan takes the class's template and the app's
  place as its principal: `erx_dom_plan_session` accepts a principal
  that is the template's own or a place of the template's class, and no
  other, so a session is still its template's, run as one of the
  principals the template serves;
* its facets are the template's rows that the admission kept, and no
  others; each mint computes its parameters from the session's
  principal, the app's, as every mint does
  ([design-system.md](design-system.md#facets-a-configured-domain-serves));
* the ready answer, which hands the session its default display
  ([design-apps.md](design-apps.md#starting-a-session)), also hands it
  the app's record: the place of the package's file (`packages/...`, or
  `/pkg/NAME.pkg` in the release on the stopgap), the header's image
  offset, root hash, salt and tree layout, its applications, its program
  with its arguments and `window`, and its environment.

The record comes only after the template's grants are added, the
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
class, the place (the name's existing one or a new one), the indices of
the template rows kept and the start row, or `{error, Reason}`, the first
of these that fails:

1. the header's ABI version is the image's: `{abi, Have, Want}`;
2. the class exists: `{no_class, C}`;
3. the name, with `_` and the digits of the class's `names` quota, is an
   identifier, not of a pooled name's form, and not the name of a
   principal, class, configured domain or service of the manifest:
   `{bad_name, N}` or `{name_taken, N}`;
4. a name the registry holds belongs to the same class and the same
   signer, `{name_taken, N}` or `{signer_changed, N}`; a new name finds a
   free place, `{class_full, C}`;
5. each need is a service a row of the class's template serves, under
   that name: `{not_in_class, S}`;
6. a start row's display is one of the needs and a `windows` service:
   `{start_display, D}`.

Nothing else is judged: a declaration can only name what the class
offers, so the build's proof over the class is the proof over the app.
The packer runs the same module on the host, under the stock OTP 29.1.2
the build compiles with, over the packed manifest and each package's
header bytes, so one implementation decides at build and on the machine.

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

* `erx-app build DIR` compiles each `lib/APP/src` with the host's stock
  OTP 29.1.2 `erlc`, `+deterministic`, against the SDK's public
  applications, and, when `DIR/Makefile` exists, runs `make` there with
  the SDK's variables. Building runs the app's own build steps, its parse
  transforms and its makefile, on the host: build only sources you trust.
* `erx-app pack DIR [--key FILE]` parses `app.txt`, checks that each
  application has its `.app` file and that the program exists and passes
  `erx_elf_plan` with the SDK's ABI version, writes the image from an
  mtree manifest with `fsimg`, computes the hash tree with a salt derived
  from the image's contents, writes the header, signs it with the key when
  one is given, and writes `NAME-VERSION.pkg` with its build record
  beside it. It follows no link out of `DIR` and refuses any other kind of
  file.
* `erx-app test DIR` runs the app's EUnit and Common Test suites on the
  host with the SDK's public applications and `erx_ui_host` on the code
  path.

### Adding an app to an image

`tools/erx pack --app X [--enable NAME] [--signer FILE]` takes an app
directory, which it builds and packs with the SDK the tree exports, or a
package file, which it takes as it is and builds nothing; a package from
someone else is added as a file. For each package the build:

1. places it in the slot's package image (the boot image's domain
   release on the stopgap);
2. adds a `package NAME` row with `input` naming it and `enable YES` when
   `--enable` names it, `NO` otherwise; the packer records the header's
   SHA-256 in the row, as it records an image's root hash;
3. runs the manifest check, property 19's admission clause included;
4. judges the package's license as it judges an archive's, so a package
   whose license is not permissive enters only a local test image built
   to allow restricted inputs, never a production image or an image the
   website offers.

`--signer FILE` adds a `signer` row, so a deployer's machine trusts the
deployer's own key for packages installed later. The board's manifest
source is unchanged: the rows are the build's, recorded in the image's
build record with each package's SHA-256. `tools/erx app run DIR` builds
a development image with the app added and enabled, boots it under QEMU
with a display, and saves screendumps, as Doom's `run.rb boot` did.

### Starting an app

`erx_app`, an application of the class's release, does nothing until the
ready answer brings the app's record. Then it:

1. mounts `/app` from the record ([An app's session](#an-apps-session));
2. sets each variable of the record's environment that the session's
   environment does not already hold, so the system's own variables, the
   default display among them, win;
3. adds each `/app/lib/*/ebin` at the end of the code path, so no module
   of the app shadows one of the release;
4. refuses to go on when a module that a declared application's `.app`
   lists is already on the path: `{module_clash, M}`;
5. starts each declared application with
   `application:ensure_all_started(App, permanent)`, its dependencies on
   the release's applications resolved from the release;
6. with `program`, starts it with `erx_prog_handler:start/1`: with
   `window yes`, with a window on the session's default display, whose
   `/dev/draw`, `/dev/kbd`, `/dev/mouse` and `/dev/wctl` the handler binds
   ([design-display.md](design-display.md#the-window-tree)); without, with
   standard input null and its output to the session's log. Its namespace
   is the session's. Its end ends `erx_app` with `{program_exit,
   Status}`.

`erx_app` is permanent, so its end, a declared application's end and a
program's end each end the session, and the start row's keeper starts it
again within its intensity. A native app draws with Plan 9's draw
protocol and flushes when its frame is done, so no frame shows half drawn,
and reads its keys from `/dev/kbd`.

### Installing, updating and removing

The administrator's commands reach the package process through the
`apps` tree ([Interfaces](#interfaces)). Installing a file:

1. `pkg add FILE` copies FILE into `/apps/pkg/NAME` and writes `install
   NAME` to `/apps/ctl`; the apps tree writes the bytes into
   `packages/staging/` through the system domain's grant, sequentially,
   at most `pkg_bytes_max` bytes;
2. the package process reads the staged file's header and verifies it:
   an installed package must name a trusted signer;
3. it plans the install with `erx_pkg_plan:install/3`, a pure function of
   the package set, the header and the admission: a name held by the
   image's packages is refused with `{in_image, N}`; a name already
   installed needs the same signer and a higher version, or `install -f`;
4. it registers the principal, the name's place again for an update;
5. for an update, it stops every domain of the app's principal with
   `erx_domain:stop/2`, so no session reads the file it replaces;
6. it syncs the staged file, renames it over `packages/NAME.pkg` and syncs
   the directory;
7. it publishes the new package to the start table, which reconciles: a
   row `rc.conf` enables starts, with the app's directory as it was.

A crash before step 6 leaves the old package or none, and the staged
file, which the next recovery removes; a crash after it leaves the new
package, which the next scan admits. One file per name, replaced by one
rename, means no crash can bring back an older version.

Removing, `pkg delete NAME`, writes `remove NAME` to `/apps/ctl`:

1. the package process writes `packages/NAME.remove`, a mark, and syncs it;
2. it stops every domain of the app's principal, and drops its start row;
3. it deletes `packages/NAME.pkg`;
4. it has the storage service remove the principal's directory;
5. it deletes the mark.

Each step is idempotent, and the recovery repeats them all for every
mark it finds before it admits anything, so a removal that a power cut
interrupted finishes at the next boot, and the name stays held by its
principal until then (PK5, PK6). A removal deletes the app's data, as
`pkg delete` decided; `rc.conf` lines naming the app stay, are reported
as naming no row, and apply again if the app is installed again, as on
FreeBSD.

### Boot and recovery

The package process starts with the start service. It registers the
image's packages from the manifest's `package` rows, reading each header
through the `packages` grant (from the release on the stopgap) and
checking it against the row's hash. Once the `packages` grant is in
place, which it waits for as the start table waits for `rc.conf`, it
runs the **recovery**, `erx_pkg_plan:recover/1` over the directory's
listing: it finishes each removal a mark records, deletes every staged
file, then reads, verifies and admits each `NAME.pkg` in name order. A refused package stays on the
medium and is shown with its reason. The same recovery runs when the
package process restarts after a crash, so there is one path from any
state of the directory to the package set.

### The start table's rows

The start table's rows are the manifest's `start` rows, in its order,
then the start rows of the admitted packages, in name order: an image
package's with its `package` row's `enable` as its default, an installed
package's with `NO`. `rc.conf` sets them as it sets any row, and the
merge refuses a display another enabled row holds, so an installed app
never takes a display from a row of the manifest or of the image
([design-apps.md](design-apps.md#the-start-table)). A package's install,
update and removal each change the rows, and the table reconciles as it
does after a change of `rc.conf`.

## The SDK

`tools/erx sdk export DIR` writes the SDK from a built tree:

| Part | Holds |
| --- | --- |
| `SDK.txt` | the erXos commit, `ERX_ABI_VERSION`, the OTP release (29.1.2), the minimum LLVM, the target, `fsimg`'s version |
| `sysroot/<arch>/include` | musl's headers as erXos ships them; the draw protocol's message layouts, generated from `abi/formats/draw.txt` |
| `sysroot/<arch>/lib` | `libc.a`; `liberx_program.a`, liberx's program layer and entry, prebuilt; the compiler's builtins; the program link script |
| `share/erxos/sdk.mk` | make variables: the compiler and flags erXos's own programs build with, and the link line |
| `erlang/` | the public Erlang applications as `.app`, `.beam` and `include/` files, a list of the public modules, and `erx_ui_host` |
| `host/bin/` | `erx-app`, the packer, and `fsimg`; `erx-lvgl` built for the host, for `erx_ui_host` |

**What is public.** A package built with an SDK runs on an image of the
same `ERX_ABI_VERSION`; admission refuses any other, and so does the
loader's ELF note check for a program
([design-programs.md](design-programs.md#what-a-program-can-start)).
Until a release promises compatibility, nothing below owes anything to
its earlier forms:

| Public | Not public |
| --- | --- |
| the POSIX-lite personality, musl's functions as [design-programs.md](design-programs.md#the-posix-lite-personality) defines them | liberx's kernel calls and every `erx_*` C function |
| a program's `main`, its standard descriptors, and a program that draws: `/dev/draw` with the draw protocol, `/dev/kbd`, `/dev/mouse`, `/dev/wctl` | the channel, the program protocol and the startup message |
| `app.txt`'s grammar and the package format | the boot image, the manifest and its rows |
| Erlang: `erx_ui`'s `open/1`, `tree/2`, `close/1`, its messages and the widget schema of `abi/formats/ui.txt`; `erx_win` and `erx_draw` for an app that draws itself; `erx_prog_handler:start/1`; stock OTP 29.1.2 | every other module of erXos, `erx_ui_lvgl` and `erx_ui_model` among them |

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
third party's anywhere on disk. The landing gate exports the SDK, builds,
packs and host-tests `examples/dashboard` with nothing but the SDK on its
paths, and checks that the example calls only public modules, so a
change that breaks the boundary fails there.

## Interfaces

**Commands**, Erlang commands of the command shell
([design-shell.md](design-shell.md#commands)), each declaring
`-erx_needs([apps])`:

| Command | Does |
| --- | --- |
| `pkg add [-f] FILE` | stages FILE and installs it; with `-f` an update needs no higher version; prints the result `/proc/packages` shows |
| `pkg delete NAME` | removes the installed app, its start row and its data |
| `pkg info [NAME]` | prints the package set, or one package: version, class, place, signer, state and reason, needs, license |

**The `apps` tree** gains `pkg/`, a directory of staged files, and three
`ctl` commands:

| Name | Read | Write |
| --- | --- | --- |
| `pkg/NAME` | nothing | created by the writer, NAME an identifier; written from offset 0 in order, at most `pkg_bytes_max`, 1 GiB; at most `pkg_staged_max`, 4, staged at once; an out-of-order write answers `einval`, a full staging area `enospc` |
| `ctl` | | `install [-f] NAME`, `discard NAME`, `remove NAME`. Errnos: `einval` for a line that does not parse; `enoent` for no staged file or no installed app of the name; `eacces` for a header that fails verification or names no trusted signer; `eperm` for an admission refused by ABI, class, need or start display; `eexist` for a name of the image, of the manifest or of another signer, and for a version not higher without `-f`; `enospc` for a full class; `ebusy` while the name is being installed or removed; `eagain` while the `packages` grant is not in place; `eio` for a failed write. The reason goes to the log and to `/proc/packages` |

**Inspection**, in `abi/inspection.txt`, reported by the package process
and shown at `/proc/packages` to an inspect facet of scope `all`:
`[packages]`, of kind `packages`, lists the packages by name;
`[packages, Name]` gives `version`, `class`, `place` (`image` or
`installed`), `signer` (a `signer` row's name, `unsigned`, or
`unchecked` where Phase 1 checks none), `state` (`admitted`, `refused`,
`removing`), `reason`, `needs`, `license` and whether it has a start
row. An app's start row is at `[apps, Name]` and its sessions at
`[domains, Id]`, as any row's and any session's.

**Manifest rows**: `class`, as in [A class](#a-class); `package`, with
`input` naming the package's artifact and `enable`, whose header hash the
packer records; `signer`, with `key`. Their packed records and the
readers' bounds are in `abi/manifest.txt`.

**The ABI source**: `abi/formats/package.txt`, the header and the packed
declaration; the limits `class_apps_max`, `pkg_header_max`,
`pkg_needs_max`, `pkg_args_max`, `pkg_env_max`, `pkg_staged_max` and
`pkg_bytes_max`.

**Erlang**: `erx_pkg_header:verify/2`, `erx_app_admit:admit/3`,
`erx_pkg_plan:install/3` and `recover/1`, `erx_principal:register_app/1`;
in a session, `erx_app`.

### Other subsystems

| Subsystem | Its part |
| --- | --- |
| the manifest check ([design-system.md](design-system.md#the-manifest)) | the `class`, `package` and `signer` rows; property 19; A10 holds, since a package selects among rows the manifest set |
| the domain library | the principal table sized for every class's places; `erx_dom_plan_session` taking a place of the template's class as principal |
| the domain service | the app's session: the kept rows, and the app's record, with its package's place and image facts, in the ready answer |
| the principal service | `register_app/1`; no app principal is unregistered within a boot |
| the storage service ([design-storage.md](design-storage.md#interfaces)) | the `packages` tree: the data partition's directory and the slot's package image read-only; removing a principal's directory at the system domain's request |
| the runtime and the EROFS reader | `erx_verity` reading an image from a file at an offset through the domain's namespace, as well as from a block window; the `/app` mount |
| programs ([design-programs.md](design-programs.md)) | an executable file from `/app/bin`; `open` through the handler; `erx_prog_handler:start/1` with a window |
| the display ([design-display.md](design-display.md#the-window-tree)) | a program started with a window; `erx-lvgl` in every image whose release holds `erx_ui` |
| live code ([design-live.md](design-live.md#the-code-store)) | an app principal's overlays live in memory only |
| the start table ([design-apps.md](design-apps.md#the-start-table)) | the package rows after the manifest's; reconciling on each change of the package set |

## Concurrency

The package process, `erx_pkg`, a process of the start service's
application, owns the package set: each package's name, place, header,
admission and state. It does no file operation itself: every read,
write, sync, rename and deletion on `packages` runs, one at a time, in
`erx_pkg_io`, which answers each request when it is done, so a slow
storage domain delays installs, not the package set's answers or the
start table. It takes one install or removal at a time and answers
`ebusy` to a second one for the same name while the first runs. The
registry of app principals belongs to the principal service, which only
grows within a boot, so a register that a crashed install left behind is
an app principal with no package, as after a removal. A crash of the
package process ends no session; it restarts and runs the recovery,
which rebuilds the set from the manifest and the directory, and hands
the start table the same rows. A crash of the start table leaves the
package set.

## Compatibility and migration

The package format, `app.txt`'s grammar and the `class`, `package` and
`signer` rows owe nothing to earlier forms
([design.md](design.md#decisions), "No backward compatibility in
development"). A package built for another `ERX_ABI_VERSION`, after a
system update or before it, is refused with `{abi, Have, Want}` and
shown so; it stays on the medium until the administrator installs a
rebuilt one or deletes it. A package whose class an update removed is
refused with `{no_class, C}`, and its data stays until it is deleted.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | What happens |
| --- | --- | --- |
| a header fails its checks, its hash differs from its `package` row, or it names no trusted signer | `erx_pkg_header:verify/2`, the package process | the package is `refused` with the reason at `/proc/packages`; an install answers its errno; an image package refused at boot leaves its row out of the table |
| admission refuses | `erx_app_admit:admit/3` | as above, with the admission's reason |
| a block of the image fails its hash | `erx_verity` in the app's session | the read answers `eio` with a log line naming the image and block; the code load or file read fails, the session ends, and the row counts an end, with the reason at `/proc/apps` |
| the image does not mount | `erx_app` | the session ends at its start with the reader's reason |
| a module clash, a missing application or a refused program | `erx_app` | `erx_app` ends with `{module_clash, M}`, the application's start error or `{program, Reason}`, and the session with it |
| the storage domain is down at boot | the package process's read through `packages` | the image's packages wait for it, as `rc.conf` does, as do the installed ones; their rows are absent until the recovery runs; on the stopgap the image's packages, in the release, do not wait |
| a power cut inside an install or a removal | the recovery | the staged file is deleted; a marked removal finishes; the set is what the directory holds |
| a class is full | admission | `{class_full, C}`, until a reboot frees the places of removed apps |

Every state above is an attribute at `/proc/packages` or `/proc/apps`,
and every refusal is a log line naming the package and the reason.
Nothing is shown as admitted that the package process did not admit.

## Security

**What is trusted.** The manifest, with its classes, `package` rows,
`signer` rows and the image's package hashes, as part of the boot image;
the package process, the principal service and the domain service, in
the system domain; the small Ed25519 verifier; each app's own runtime,
for that app alone.

**What is not.** Every package byte, header and declaration; the staged
bytes; the data partition and the storage domain; an app's code; an app
directory on the build host.

* **The system domain reads a header, never an image.** The header is at
  most 64 KiB, read through a generated reader with a fuzz target over the
  whole verification entry, locating the declaration, key and signature
  in bytes an attacker wrote, truncated at each field and with every
  length out of bounds. The image is parsed only by the app's own
  session, whose failure is its own.
* **A package cannot widen its authority**: the grammar names, the
  admission includes, the build counted (PK1). What the administrator
  approves by installing is which of a class's rows the app takes, within
  what the build proved, with no prompt.
* **A hostile app** can spend its principal's memory and CPU, fill its
  directory, use its rows within their limits, end, and read the bytes of
  other packages through `packages`, which holds code and data an app
  ships, not anyone's secrets. It cannot write a package, install one,
  reach another app's directory or domains, or change the start table.
* **A crafted data partition, or a storage domain it took over,** can
  withhold or delete packages, put back an older package of the same
  signer, and swap an installed package for another package of the same
  name that a trusted signer signed, which then runs with that app's data
  and its class's rows. Since it can already read and destroy every
  app's data, that gains it what installing would; it cannot run code no
  trusted signer signed, change a byte of an image, widen a grant, or
  start an app with no start row. A version floor holds for `pkg add`,
  not against a storage domain that puts back an older file: refusing
  that needs a counter the platform's trust root keeps, as for system
  updates ([design-storage.md](design-storage.md#system-updates)).
* **Signer continuity.** An update needs the installed signer; a
  different signer needs `pkg delete`, which deletes the app's data, so a
  name never passes to another signer with the first one's data through
  the installer.
* **An app's durable code is its package**: its principal's overlays stay
  in memory, so a storage domain cannot make an app run code its signer
  did not sign.
* **The atoms an app costs the system domain** are those of its place:
  its pooled session names within its class's `names` quota, in a place
  that removal frees only at reboot (PK6).
* **The build host.** Building an app runs its compile steps, its parse
  transforms and its makefile, so an image builder builds only sources
  they trust and adds anyone else's app as a package file, which builds
  nothing. The packer follows no link out of an app directory and writes
  no host metadata into an image. Diagnostics quote a declaration's bytes
  through the host terminal's escaper.
* **Text from a package.** A package's name, version and license reach
  `/proc/packages`, the log and the host through each sink's escaping
  function, as all text attributed to a source does
  ([design-live.md](design-live.md#attributed-text)).
* **Licenses.** A package's license is judged where an archive's is, so
  a copyleft package reaches only a local test image (PK-R9).

## Phase 1

Phase 1 runs trusted code, and a development build says so in its
banner. It builds this design against its target interfaces and defers
what rests on parts that arrive later, reporting each as it is:

| Deferred | Until | Meanwhile |
| --- | --- | --- |
| isolation between apps' domains, and budgets and quotas as limits | erXos's kernel | as for every domain ([design-apps.md](design-apps.md#phase-1)) |
| rooting `data` grants by principal | facet parameters and principals' directories | apps of one class can reach each other's directories, the residual design-apps.md records; the directory half of PK3's test waits, its `/proc` half runs |
| the image builder's packages on the system slot | the storage service serving a slot's image | they lie in the boot image's domain release, readable by every domain, enlarging the boot image and the memory it holds; a large one needs a larger root place on the stopgap |
| checking an installed package's signature | the small verifier in the build ([plan.md](plan.md#m11-security-closure)) | a development build installs packages whose signature it cannot check and shows them `unchecked`; a release build installs none |
| removing a principal's directory | the storage service's removal at the system domain's request | `pkg delete` leaves the directory and says so at `/proc/packages` |

## Verification and testing

Each test is paired with the seeded fault that proves it runs the code
it guards.

**Host tests.**

| Test | Passing case | Seeded fault |
| --- | --- | --- |
| the declaration's parser (Ruby, in the packer) | the two examples above pack to their expected records; each bound of the table refuses one past it, naming the line | the bound on `needs` removed, which packs seventeen needs |
| `erx_pkg_header:verify/2` | a signed package, an unsigned one, one of an untrusted key, a flipped signature byte, a header cut at each field, lengths that overflow | a verify that skips the signature when a signer is named, which accepts the flipped byte |
| admission, one corpus run by the machine's module and by the packer's host run | each refusal of [Admission](#admission) and its accepting neighbour | the inclusion test of step 5 dropped, which admits a need the class lacks |
| the install, removal and recovery planners | after every crash point between effects, the recovery leaves each package wholly present or wholly absent and a removed app's directory gone | a removal that deletes the package before writing its mark, after which a crash leaves a package with no data |
| the app session's plan in `erx_domain_core` | the session's rows are the template's rows its needs name; every minted scope names the app's principal | a plan that grants every row of the template; a scope computed from the template's key |
| `erx_app` over a fixture `/app` | the declared applications start; a clash is refused; a declared variable does not replace one the session holds | the app's paths added at the front, which lets an app module shadow a release module unseen |
| places | `apps` + 1 distinct names installed and removed in one boot, the last refused with `class_full`; a name installed again takes its place again | a removal that frees the place |
| the class check | each clause of property 19 | each seeded violation of [The class check](#the-class-check) |
| `examples/dashboard` through the SDK | its frame through `erx_ui_host` matches its reference, and a click on Pause changes only the status line and buttons | a status line one pixel taller |
| the SDK's boundary | the example compiles and passes xref against the SDK's public modules alone | the example calling `erx_ui_model`, which the check refuses |
| no list names an example | a source check over `tools/lib/erx`, `config/manifest` and the test lists finds no path under `examples/` | `erx_dashboard` added to `ErlangApps::APPLICATIONS` |

**QEMU tests**, in the suites of the plan's parts that bring them:

* a kiosk image with `examples/dashboard` added by `tools/erx pack --app
  --enable dashboard` boots to its UI on the display, whose screendump
  matches the host test's reference; seeded: `--enable` dropped, and the
  screen stays blank;
* two apps of one class: neither's `/proc` shows the other's domains;
  once `data` grants are rooted by principal, neither reads the other's
  `/data`;
* a test program packaged with `window yes` draws through `/dev/draw`
  and changes its picture at a key that QMP sends; seeded: the program
  started without a window, which ends with its open of `/dev/draw`
  failing;
* one package added to the image and the same file installed on another
  machine give sessions with the same grants and the same `/app` (PK7);
* run-time install: `pkg add` shows the package `admitted`; `service NAME
  enable` starts it; a reboot keeps it; `pkg add` of a higher version
  runs the new code with the app's files kept; `pkg delete` leaves no
  package, row or directory; a machine reset between a removal's mark and
  its end finishes the removal at the next boot; one byte of an
  installed image flipped on the medium gives `eio` and the row `down`
  with the reason; one byte of a header flipped gives `refused`; a
  package of an untrusted signer answers `eacces`; seeded: the recovery
  skipping marks, which leaves a half-removed app;
* the states the inspector shows, each with a test: `admitted`,
  `refused` with its reason, `removing`, and `unchecked` in Phase 1.

**Fuzz targets**, each landing with its parser: the declaration's text
parser on the host; `erx_pkg_header:verify/2` as a whole, over a
generated corpus of headers; the `apps` tree's `ctl` grammar with its
new commands, and the staged files' names.

**Chokepoints**, each a build check with a seeded violation:

* only `erx_pkg_header` reads a package's bytes in the system domain,
  and no system-domain module reaches `erx_verity` or `erx_erofs` for a
  package (PK4);
* only `erx_pkg_io` writes the `packages` tree;
* only `erx_pkg` calls `erx_principal:register_app/1`;
* no list of the build names a path under `examples/`, and the examples
  call only the SDK's public modules.

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
bytes of `pkg add` through the system domain's `apps` tree.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| **A pool**: a class's principal pays for every app of the class, and each domain record names both the app it acts for and the pool that pays | Every reader of a principal must then choose the right one of two fields, and the earlier review of that design found two that chose wrong: the inspect scope and the grant records. A place of the class's shape is a whole principal, so every reader stays as it is; the cost is that each place reserves its class's memory, as every principal does |
| **An app declares its limits and grants, and the machine checks they fit** | A checker on the machine would re-prove sums the build proves, field by field, and each new field would need its own rule. Naming rows of a class leaves only an inclusion |
| **A package carries an OTP release with its own boot script** | A boot script pins the versions of the release's applications, so every system update would break every package. `erx_app` starts the app's applications over the class's release |
| **Packages unpacked into a directory of the data partition** | Their integrity would rest on the storage domain. An EROFS image under a hash tree, checked by the reader, makes it rest on the header alone |
| **The image builder's packages in the boot image** | The boot image is held in memory and bounded by the root place; Doom's 28 MiB WAD made the image 88 MiB. On the slot they are read on demand and still change only with the system |
| **Every package ships its own `erx-lvgl`** | One copy per app, a wire between toolkit and renderer that each app's build could skew, and LVGL's notices in every package |
| **A launcher in Erlang for each native app** | The display already starts a program with a window and binds its draw and input files; `program` and `window yes` reach that for every native app |
| **A native window app draws into its buffer and presents through a pipe protocol, as `erx-lvgl` does** | It would be a second public path to the screen. `/dev/draw` is the designed one; the measurement on the watch list decides whether a faster one is needed |
| **Signers trusted on first install** | The record of who signed first would lie where the storage domain can rewrite it. Keys in the boot image cannot be |
| **The administrator's session writes packages straight into the storage domain** | It needs a writable grant on part of the package tree and lets an administrator's session change installed files behind the package process. Staging through the `apps` tree keeps one writer |
| **Rows generated into the manifest for each app, a principal and template of its own, with the sums grown** | Doom's `run.rb` did that. It grows the board's sums with each app and is a second path beside run-time install; the class makes one path |

## Risks and decisions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| a class's places reserve memory whether or not an app fills them | high | a general machine with many places holds memory idle | the builder sizes `apps` to what the machine expects; a pool is the alternative if a measured machine needs it |
| a full-window frame through `/dev/draw` is too slow for a game | medium | Doom runs below its frame rate | the watch-list measurement; a faster path is a design change of the display's, if needed |
| the app's code reads slowly through the file protocol and the hash check | medium | slow app starts | `tools/erx bench app-start`; the shared code design maps prepared code later ([design-shared-code.md](design-shared-code.md)) |

Decisions:

1. **A class's place is a whole principal**, not a share of a pool.
2. **Installing enables nothing**; the image builder enables a row of
   the image's packages, the administrator an installed one.
3. **One file per name**, replaced by rename; downgrade only with
   `install -f`.
4. **A name the image holds is the image's**: it is not installed over
   or removed at run time, and changes with a system update.
5. **`pkg delete` removes the app's data**; no prompt asks a person to
   approve grants; no fetch by name.

Questions for the owner, each with a recommendation:

1. **Which signers a machine trusts.** Recommended: only the keys the
   boot image carries (`signer` rows, and the development key in a
   development build), so trust changes with a system update. The
   alternative, adding a signer at run time, puts the record where the
   storage domain can rewrite it.
2. **Places or a pool.** Recommended: places, as above, until a measured
   machine shows the reserved memory matters.
3. **Whether `pkg add -f` may downgrade.** Recommended: yes, as an
   administrator's explicit act.
4. **Whether packages' code is readable by every app.** Recommended:
   accept it and say so: a package holds what its author ships, and
   keeping each package to its own app needs a grant per package.
5. **The classes of the shipped manifests.** Recommended: the development
   manifest declares `kiosk` (one place, the display, data and packages)
   and `app` (eight places, the display, data, net and packages), which
   the examples use.
6. **The program launcher's needs of `erx_prog_handler`.** The handler
   being built takes pipe ends and a window's buffer; `window yes` needs
   it to start a program with a window as
   [design-display.md](design-display.md#the-window-tree) says.
   Recommended: that option lands with the handler, so no second launcher
   exists.

## References

* FreeBSD: `pkg-add(8)`, `pkg-delete(8)`, `pkg-info(8)`, `pkg.conf(5)`
  (signature checking against trusted fingerprints), `rc.conf(5)`.
* Android: application signing and the application sandbox.
  <https://source.android.com/docs/security/features/apksigning>,
  <https://source.android.com/docs/security/app-sandbox>
* Android: APEX file format. <https://source.android.com/docs/core/ota/apex>
* Linux: dm-verity's hash tree format, as design-storage.md uses it.
* Plan 9: `draw(3)`, `rio(4)`.
