# How systems let people add and run programs

A point-in-time research record, written 2026-11-25. It asks how
other operating systems let a developer or user build a program
elsewhere, put it on a running machine and run it; run it with the
user's ordinary rights; restrict or widen what it may do; make it a
service started at boot; bound its memory and CPU; add or update it
without rebuilding the system image; and install third-party apps that
declare what they need. For each system it counts the concepts a
newcomer meets before a program runs. It ends with what erXos could
take from them.

It decides nothing. erXos's design documents stay the architecture;
this record is input to a discussion of the app model.

**Method and sources.** Every statement about another system cites a
published document read on 2026-11-25 through a web fetch: manual
pages, vendor documentation, the Genode Foundations book and Sculpt OS
articles, and papers. No GPL, LGPL, AGPL or CDDL source was read, and
nothing about Fuchsia or Zircon. Genode and L4Re were read only through
their published documentation. The documents were read as fetched web
pages, not downloaded into files, so no SHA-256 is recorded; the
version or date each page shows is in [Sources](#sources). A few
facts came only from search-engine excerpts of an official page, not
from the page itself; they are marked "(excerpt)". Statements no source
read in this task supports are marked **unverified**. The concept
counts are this record's own estimate, not a measurement.

## Contents

* [erXos's current model](#erxoss-current-model)
* [QNX](#qnx)
* [FreeBSD](#freebsd)
* [L4Re](#l4re)
* [Genode and Sculpt OS](#genode-and-sculpt-os)
* [Plan 9](#plan-9)
* [OpenBSD pledge and unveil](#openbsd-pledge-and-unveil)
* [macOS](#macos)
* [Android](#android)
* [Flatpak](#flatpak)
* [systemd units](#systemd-units)
* [WASI](#wasi)
* [Redox OS](#redox-os)
* [Zephyr](#zephyr)
* [Comparison](#comparison)
* [What erXos could learn](#what-erxos-could-learn)
* [A sketch of a simpler model](#a-sketch-of-a-simpler-model)
* [Sources](#sources)

## erXos's current model

Read from the tree at commit `76540b79d`.

**Packaged apps.** An app built outside the tree is one file,
`NAME.app`: a declaration (`app.txt`) and a read-only EROFS image with
a hash tree, signed
([design-packaging.md](design-packaging.md), opening and
[The declaration](design-packaging.md#the-declaration)). A three-line
declaration names the app, the services it `needs` and its OTP
applications or one native `program` under `bin/`; memory defaults to
64 MiB. Installing is `cp NAME.app /apps/`, starting at boot is
`service NAME enable`. The board's manifest carries one `apps` row:
the memory all apps share, the services an app may ask for, and `max`
(8 by default), how many apps a boot holds. The build proves the board
can afford the row at its worst, every app present and holding every
offered service (invariant PK2), and admission checks that an app's
needs are a subset of the row (PK1). A machine trusts only signer keys
the boot image carries, or in a development build its builder's
development key ([Where a package lies](design-packaging.md#where-a-package-lies)).
Each app is a principal of its own, with its own budget carved from
the `apps` budget. Packages of system services or drivers are out of
scope: those are configured domains of the system manifest
([Requirements](design-packaging.md#requirements)), so adding or
changing one means a new image.

**Native programs in a session.** A program gets its starter's whole
namespace by default, narrowed where the starter asks
([Narrowing for a program](design-files.md#narrowing-for-a-program)).
Starting a command is itself a right (`spawn => true`) that the shell
gives with `/bin`
([What a program can start](design-programs.md#what-a-program-can-start)).
A path that no `rx` grant reaches fails with `EACCES`.

**Write and execute.** Invariant F6 of
[design-files.md](design-files.md#invariants) says no grant carries
write and execute together: a grant's rights are one of `ro`, `rw` and
`rx`, a type with no value for both. Its own test is that a file a
session wrote into its `data` grant and then mounted `rx` still fails
with `EACCES`. So a binary copied onto the machine with `scp` or `cp`
into a home, `/tmp` or `/data` can never be run; the only way to run
new native code is a signed package in `/apps`, or a new image. The
memory-level rule is separate: a program's code comes only from
sealed code objects with an execute ceiling, created by the system
domain and filled from a file read through an `rx` grant
([File objects](design-programs.md#file-objects); P10 and K8). A
running program cannot change its own code whatever F6 says, because
the code object is a sealed copy.

**Memory.** Every domain's budget is a wall whose cap equals its
guarantee, so a domain is admitted or refused at its own budget alone
(CLAUDE.md, "by construction" list; FD25 on Fiasco). A principal has a
budget, a CPU group, a domain-slot quota and a names quota, and a
session template carries limits with defaults and ceilings
([Principals, sessions and quotas](design-domains.md#principals-sessions-and-quotas)).
An app's memory is a reservation taken from the `apps` row at
admission.

**Erlang code.** In a development build, modules can be loaded from
the host into any domain without a new image, and the system domain
loads only installed code
([loading-code.md](guide/loading-code.md)).

**Concepts a newcomer meets** before a third-party native program runs:
package, declaration, `needs`, the `apps` row, signer key, admission,
principal, session, grant, `rx`, memory reservation, `/apps`,
`service`. Thirteen, and two of them (the `apps` row and the signer
key) live in the boot image, so a machine whose image lacks them cannot
take the program at all.

## QNX

QNX OS 8.0 documentation.

* **Copy and run.** The Momentics IDE uploads the executable to the
  target and runs it, or runs one already there ("Use executable on
  target") (excerpt, IDE launch configuration and Programmer's Guide).
  Beyond that, a QNX program is a POSIX executable started by `spawn`
  or `exec`; the user's own rights apply. That QNX honours the execute
  bit and has a `noexec` mount option is **unverified** here.
* **Name space.** Services are resource managers, user processes that
  attach a pathname prefix with the process manager; the process
  manager resolves an open to the owning manager, which keeps POSIX
  `open`/`read`/`write` while letting a small system leave services
  out. Attaching a prefix needs the `PROCMGR_AID_PATHSPACE` ability
  (Pathname management, System Architecture, 8.0; excerpt). The name
  space is one per machine; no per-process name space is described.
* **Restrict or grant.** Two layers. `procmgr_ability()` lets a
  process started as root keep chosen abilities, drop the rest and
  then change uid; each entry is an ability id, an operation
  (`PROCMGR_AOP_ALLOW`, `DENY`, `LOCK`, `SUBRANGE`) and a domain
  (`PROCMGR_ADN_ROOT` or `NONROOT`), and changes are not inherited
  across `spawn`/`exec` unless `PROCMGR_AOP_INHERIT_YES` is given. The
  page itself says "Using a security policy is more secure and less
  error-prone than calling procmgr_ability()". The **security policy**
  gives each process a type (`on -T slogger2_t slogger2`, or the
  launcher `slm`) and rules such as `allow_attach random_t /dev/random;`
  and `allow random_t devb_t : channel connect;`. The policy is
  generated by running the system with `secpolgenerate`, compiled on
  the host with `secpolcompile -o secpol.bin policy`, placed in the
  boot image and pushed at startup; changes mean rebuilding the image
  and rebooting. "There is no default policy", and every process still
  running after startup should have a type (Using security policies;
  Security policy maintenance).
* **Service at boot.** Started from the boot image's startup script or
  by `slm` (Using security policies). Details of `slm` were not read.
* **Limits.** Adaptive partitioning is not supported on QNX OS 8.0
  (excerpt, IDE launch configuration). POSIX `setrlimit` is
  **unverified** for 8.0 here.
* **Image vs run time.** A program can be copied and run at run time;
  the security policy is fixed in the image.
* **Concepts before a program runs**, without a policy: executable,
  user, path. With a security policy: add type, rule, policy
  generation, compile, image rebuild. Three, then about eight.

**Lesson.** QNX's general path is UNIX: copy and run. Its fine-grained
policy is image-baked, and QNX treats that as the price of a fixed
embedded product, with a learning mode (`secpolgenerate`) so nobody
writes the policy by hand.

## FreeBSD

FreeBSD 15.0-RELEASE manual pages.

* **Copy and run.** `scp prog host:`, `chmod +x`, `./prog`. Runs with
  the user's uid.
* **noexec.** `mount -o noexec`: "Do not allow execution of any
  binaries on the mounted file system." The page warns: "This option
  was not designed as a security feature and no guarantee is made that
  it will prevent malicious code execution", and "it is still possible
  to execute scripts which reside on a noexec mounted partition."
  `nosuid` stops setuid bits and is set automatically for a non-root
  mount (mount(8)).
* **Restrict.** Capsicum: `cap_enter` puts a process into capability
  mode, where global name spaces (file system, process ids) are cut
  off and the process acts only through descriptors it holds; the mode
  is inherited and cannot be left; `openat` still works beneath a held
  directory; `cap_rights_limit` narrows a descriptor; libcasper offers
  services such as opening files for a sandboxed program (capsicum(4)).
  It is a program change, not something a user applies from outside.
  Jails confine a process tree to a directory with its own host name,
  configured in `jail.conf` with `path`, `host.hostname`, `exec.start`,
  `mount.devfs` and boolean `allow.*` parameters (jail.conf(5)).
  mac(4) was not read.
* **Limits.** rctl(8): rules `subject:subject-id:resource:action=amount/per`,
  subjects process, user, login class and jail; resources such as
  `memoryuse`, `vmemoryuse`, `pcpu`, `maxproc`, `openfiles`; actions
  `deny`, `log`, `devctl`, `sig*`, `throttle`. `rctl -a
  user:joe:vmemoryuse:deny=1g` takes effect at once on running and
  future processes. Limits are caps, not reservations.
* **Service at boot.** An rc.d script of about ten lines (`name`,
  `rcvar`, `command`, `load_rc_config`, `run_rc_command`), in
  `/usr/local/etc/rc.d` for added software, ordered by
  `# PROVIDE:`/`# REQUIRE:` comments, enabled with `sysrc NAME_enable=YES`
  and started with `service NAME start` (rc-scripting article).
  rc.subr(8) gives each script `NAME_user`, `NAME_chroot`,
  `NAME_login_class` and `NAME_limits` (arguments to limits(1)), so
  identity, confinement and limits are rc.conf variables beside the
  enable switch.
* **Image vs run time.** Everything outside the base system is added at
  run time; pkg(8) was not read for this record.
* **Concepts before a program runs**: executable, execute bit, user,
  path. Four. A service adds rc.d script and `rc.conf`.

## L4Re

L4Re published documentation (doxygen pages, no release number shown).

* **Start.** Ned, the init process, is a Lua interpreter with L4Re and
  ELF-loader bindings. A program starts with
  `L4.default_loader:start({ caps = { jdb = L4.Env.jdb }}, "rom/example")`;
  the table may also give `log`, `scheduler`, `factory` and `mem`,
  which default to Ned's own. Programs are named in the `rom`
  capability's name space, which Ned inserts if the table omits it
  (Ned page).
* **Authority.** A program starts with an initial environment: named
  capabilities to application objects, a memory allocator and a
  factory (concepts page). Ned assigns "minimal rights" by default and
  cannot raise rights it does not hold; `:m("rw")` and `:svr()` choose
  the rights each side of a channel gets (Ned page; concepts page).
  The pages read do not say in so many words that a program has no
  authority beyond its environment.
* **Run time.** A `ned-prompt` program connected to a command channel
  lets an operator run Lua statements in Ned at run time, so new
  programs can be started; `-e` runs a statement from the command line
  (Ned page). New binaries must be reachable through a name space Ned
  holds; how one is copied onto a running system was not found in the
  pages read.
* **Limits.** Memory comes from the `mem` allocator and kernel objects
  from the `factory` given at start. On Fiasco a task's kernel
  allocations charge its factory's quota (erXos's own record,
  [design-fiasco.md](design-fiasco.md)); the L4Re pages read do not
  describe quota syntax in Ned.
* **Concepts before a program runs**: Ned script, Lua, `rom` name
  space, capability table, rights, loader, boot modules list. About
  seven, and a program not in the boot modules needs a file server in
  Ned's name space.

## Genode and Sculpt OS

Genode Foundations 26.05 (HTML) and the Sculpt OS 26.04 article.

* **Static composition.** Init's configuration has a `start` node per
  child, each with a RAM and capability quota (`ram: 1M | caps: 100`),
  the services it `provides` and a `route` per service it uses, to
  `parent` or to a `child`; `any-service` is a wildcard. "The routing
  tables act effectively as a white list of services the child is
  allowed to use"; a request with no route is denied; a default route
  can be given once (The init component, Session routing). "Each start
  node must be equipped with a declaration of the amount of RAM", and
  init keeps a small preserved amount for itself (Resource assignment).
* **Resource trading.** A parent transfers RAM quota from its own
  account to a child's; a client pays for a server's session state by
  donating session quota, returned at close; a child may send its
  parent a resource request, and a parent may ask a child to yield
  (Resource trading).
* **Adding at run time (Sculpt).** "The gateway for installing and
  starting individual components is the unassuming + button";
  "Install" downloads the package and its dependencies, then "Whenever
  adding a new component via the + menu, one has to define how to
  connect the component with the rest of the system" in a dialog that
  picks, for example, which GUI and which file system. The deploy file
  holds a node per running component naming its package, its
  resources and its connections. Packages come from providers whose
  archives are signed; with a URL but no public key Sculpt cannot
  verify them. Changes become permanent by copying the model files to
  `/config/<VERSION>/` on a disk (Sculpt OS 26.04).
* **Limits for users.** The Sculpt article read does not cover RAM
  quotas; a mailing-list answer (not an official document) says there
  is no user interface to change a deployed component's RAM or
  capability quota (excerpt).
* **Concepts before a program runs** on Sculpt: package, depot,
  provider, public key, component, session, route, RAM quota,
  capability quota, deploy file. About ten. Writing init's
  configuration by hand adds `parent-provides` and the route syntax.

**Lesson.** Genode is the system nearest erXos's design, and its users
meet the same friction: every child needs an explicit RAM amount and a
route for every service. Sculpt's answer is a dialog that asks only
the questions a package's requirements raise, with defaults.

## Plan 9

Pike, Presotto, Thompson, Trickey, Winterbottom, "The Use of Name
Spaces in Plan 9", 1992/1993.

* Each process builds "a private view of the system by constructing a
  file name space". `mount` attaches a service's file tree after
  authenticating the user; `bind` makes part of the existing name
  space visible elsewhere. `rfork` chooses whether the name space is
  shared with or copied to the child.
* Programs live in a per-architecture directory bound onto `/bin`, and
  "A directory of private binaries is usually unioned with /bin". So a
  user's own built program runs from their `bin` with no
  administrator involved.
* Restriction is building a smaller name space for the child before it
  runs; the paper does not frame it as a security mechanism.
* **Concepts before a program runs**: executable, name space, `/bin`
  union. Three.

## OpenBSD pledge and unveil

OpenBSD-current manual pages, 2026.

* `pledge(promises, execpromises)`: a space-separated list such as
  `"stdio rpath inet"`; anything not promised becomes unavailable, and
  most violations kill the process with an uncatchable `SIGABRT`.
  `execpromises` sets the promises a program `execve`s into; without
  them the new program runs unpledged (pledge(2)).
* `unveil(path, permissions)` with letters `r`, `w`, `x`, `c`: the first
  call hides the rest of the file system; `unveil(NULL, NULL)` locks
  it; unveils are not inherited across `execve` (unveil(2)).
* Both are self-restriction by the program's author, in the program,
  in one line each. Nothing is declared outside the binary.
* **Concepts**: none extra to run; two calls to restrict.

## macOS

* **Bundles and signing.** Gatekeeper checks software from outside the
  App Store for a developer identity, notarization and alteration, and
  asks the user at first launch (excerpt, Apple Platform Security and
  deployment guides). A command-line binary a developer builds and
  copies runs as on UNIX; whether Gatekeeper prompts for one copied
  with `scp` is **unverified**.
* **Sandbox.** App Sandbox is required for the App Store; a new Xcode
  app gets the sandbox entitlement and default capabilities; the app
  gets a container directory with unrestricted read and write and no
  unrestricted access to the home folder; an embedded command-line
  tool inherits its app's sandbox (Protecting user data with App
  Sandbox). The entitlement is visible with
  `codesign -dvvv --entitlements -`. That access to a file the user
  picks in an open panel is granted to the app (the "powerbox") is
  **unverified** from Apple's pages here; Flatpak documents the same
  pattern below.
* **Services.** A launchd job is one property list in
  `/Library/LaunchDaemons` or `~/Library/LaunchAgents` with `Label`,
  `ProgramArguments`, `RunAtLoad`, `KeepAlive`, `UserName` and
  `SoftResourceLimits`/`HardResourceLimits`, loaded with `launchctl`
  (launchd.plist(5), 2019).
* **Concepts**: for a tool, executable and path; for an App Store app,
  bundle, signing identity, entitlement, container, notarization. Two,
  or about six.

## Android

Android developer guide, permissions overview.

* An app declares permissions in its manifest. Install-time
  permissions ("normal" and "signature") are granted at install and
  shown in the store; runtime ("dangerous") permissions are asked for
  at the moment of use, and the app must check before each access;
  special permissions are toggles in system settings. Signature
  permissions go only to apps signed with the same certificate as the
  definer. Guidance: "Request permissions as late into the flow of
  your app's use cases as possible."
* That each app runs under its own UID is **unverified** from the page
  read.
* **Concepts**: APK, manifest, permission, protection level, runtime
  request. About five; a developer cannot run a bare binary as an app.

## Flatpak

Flatpak documentation, sandbox permissions.

* By default an app has "No access to the network", host files only
  for its runtime, itself and its own directories, and no host
  services such as X11 or the system D-Bus.
* Grants are `finish-args` in the manifest: `--share=network`,
  `--socket=wayland`, `--device=dri`, `--filesystem=home`. Narrower
  filesystem grants are recommended.
* Portals give access outside the sandbox; picking a file in the file
  chooser grants the app access to that one file. Users can change
  grants with `flatpak override`.
* **Concepts**: app id, runtime, manifest, `finish-args`, portal. Five.

## systemd units

systemd 262, systemd.exec(5). systemd's documentation only; its source
was not read.

* One unit file per service carries identity, confinement and limits:
  `DynamicUser=` allocates a user and group for the unit's lifetime;
  `ProtectSystem=` mounts `/usr` and the boot directories read-only;
  `ProtectHome=` hides `/home`, `/root` and `/run/user`; `PrivateTmp=`
  gives a private `/tmp`; `NoExecPaths=` makes paths non-executable
  even where file permissions allow, with `ExecPaths=` nested inside
  to re-allow; `ReadWritePaths=` allow-lists writes under
  `ProtectSystem=strict`. Memory: `MemoryMax=` (referenced from
  systemd.resource-control).
* **Lesson.** Per-service noexec is a path list in the one file that
  starts the service, not a property of the file system type.

## WASI

wasi.dev, Security.

* "Code running under WASI has no ambient authority". A WASI 0.1
  module acts only on "the resources the runtime hands them at
  startup, chiefly preopened file descriptors". "Capability granting
  happens at runtime invocation, not in the module binary." In WASI
  0.2 "Each capability (filesystem access, networking, environment,
  clocks, randomness) is a separate import".
* From the command line: `wasmtime --dir . foo.wasm` gives the module
  the current directory (wasmtime CLI options).
* **Lesson.** The person running the program grants, at the moment of
  running, with one flag per resource; the binary declares nothing.

## Redox OS

Redox book (excerpts; the book's site refused the direct fetch).

* A scheme is a named service provided by a driver or daemon; paths
  not under `/scheme/` go to the file scheme. A name space is a list
  of schemes, inherited from the parent, which may restrict it for a
  child. A process in the null name space can open nothing by name and
  uses only descriptors it already holds. The book says Redox
  currently starts all processes in the root name space, with
  sandboxing of user programs planned.

## Zephyr

Zephyr Project documentation, user mode overview (updated 2025-12-16).

* User threads have no access to memory beyond their stack, program
  text, read-only data and their memory domain's partitions, and "no
  permission to access any kernel object or driver other than their
  own thread object"; a supervisor thread grants more. Kernel objects,
  thread stacks and driver instances used from user mode "must be
  defined at build time"; run-time needs draw from predefined pools.
* **Lesson.** A fully static, build-time model fits a microcontroller
  image where every program is known when the firmware is built. It
  is the model erXos's `apps` row resembles.

## Comparison

"Concepts" counts what a newcomer must understand before a first
third-party program runs on the default path; this record's estimate.

| System | Copy and run a built binary | Default rights | Restrict | Grant more | Service at boot | Memory and CPU | Added without new image | Concepts |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| erXos (current) | no: only a signed `.app` | the `apps` row's services the app names | declaration's `needs`; spawn narrowing | edit the `apps` row: new image | `service NAME enable` (apps); manifest (services) | reservation per app from the row; walls | apps yes, if the image trusts the signer; services no | about 13 |
| QNX 8.0 | yes | user's | abilities; security policy types | policy rules | startup script, `slm` | APS not on 8.0 | programs yes; policy no | 3, or about 8 with policy |
| FreeBSD 15.0 | yes; `noexec` mounts refuse | user's | capsicum (in program), jail | user, groups, jail params | rc.d script + `rc.conf` | rctl caps, limits(1) | everything outside base | 4 |
| L4Re | via Ned's name spaces | capabilities in `caps` | omit a capability, lower rights | add to `caps` | Ned Lua script | `mem`, `factory` at start | via `ned-prompt` | about 7 |
| Genode / Sculpt | install a package | routes chosen | fewer routes | more routes | deploy file | explicit RAM and caps per child, traded down | yes, from signed depots | about 10 |
| Plan 9 | yes, from own `bin` | name space | smaller name space | bind or mount more | profile | none described | yes | 3 |
| OpenBSD | yes | user's | `pledge`, `unveil` in program | none | rc.d | login class | yes | 0 extra |
| macOS | tools yes; apps signed | user's; sandbox for apps | entitlements | entitlements, user choice | launchd plist | plist rlimits | yes | 2, or about 6 |
| Android | no: an APK | manifest permissions | omit permission | runtime prompt | n/a | system-managed | yes | about 5 |
| Flatpak | no: a Flatpak | sandbox | default | `finish-args`, portal, `override` | n/a | not described | yes | 5 |
| systemd | yes | unit's user | `Protect*`, `NoExecPaths=` | `ReadWritePaths=`, `ExecPaths=` | the unit | `MemoryMax=` | yes | 1 file |
| WASI | yes | nothing | default | `--dir`, imports | n/a | runtime flags | yes | 2 |
| Zephyr | no: firmware image | nothing | default | supervisor grants, build time | image | build time | no | n/a |

Three groups show up:

1. **General-purpose systems** (FreeBSD, QNX's default path, Plan 9,
   macOS tools, OpenBSD) run a copied binary with the user's rights,
   restrict from outside with mounts, jails or name spaces, and bound
   resources with caps set at run time.
2. **App platforms** (Android, Flatpak, macOS App Store, Sculpt) put
   third-party apps in a package with declared needs, default-deny,
   and grant at install or at first use, all at run time and never by
   rebuilding the system.
3. **Fixed-function images** (QNX security policy, Zephyr, Genode's
   static init) decide authority and resources when the image is
   built. They fit a product whose software is known up front, and
   they offer a learning tool (`secpolgenerate`) or a dialog (Sculpt)
   because writing the policy by hand is hard.

erXos's current app model is group 3 dressed as group 2: the package
and `cp` to `/apps` feel like an app platform, but what an app may
receive, how many apps fit and which signers count are fixed by the
image, and there is no group 1 path at all for native code.

## What erXos could learn

Each pattern names the systems that show it and what it costs.

1. **Inherit by default, narrow on request.** A started program has
   its starter's authority; the starter takes things away. Shown by
   FreeBSD, QNX, Plan 9 (`rfork` copying the name space), Redox and
   erXos's own spawn narrowing. Cost: a program run without narrowing
   holds everything its user holds, as on UNIX. erXos already has the
   mechanism; what is missing is a default path that uses it for
   copied binaries.

2. **Capabilities at start as the only authority.** The starter hands
   the program its name space and handles, and nothing else exists for
   it to reach. Shown by L4Re (`caps`), WASI (preopens), capsicum and
   Redox's null name space. erXos's session namespaces and facets
   already are this. Cost: none extra; it is the base the other
   patterns sit on.

3. **Executability is a property of where a file is mounted, not of a
   rights type.** `noexec` mounts (FreeBSD mount(8)), `NoExecPaths=`
   (systemd), `unveil`'s `x` letter (OpenBSD). The agreed
   direction: a copied binary can be made executable and run, and the
   restriction is a `noexec` mount. For erXos this means grants carry
   `r`, `w` and `x` as independent bits bounded by the server's and
   the mount's, instead of F6's three-value type. What F6 protects
   today, a program running a file it or another program can rewrite,
   becomes a property of the mounts a session makes `noexec` (for
   example `/tmp`), as on FreeBSD. The memory-level rule (P10, K8: code
   only from sealed code objects, never writable and executable) is
   untouched, because a code object is a sealed copy taken at exec.
   Costs: FreeBSD's own page says `noexec` "was not designed as a
   security feature" and scripts still run from such a mount; an
   attacker who can write a file the user can execute gets the user's
   rights, as on UNIX. The trusted base (the system domain, signed
   images) keeps its own rule that it runs only installed code.

4. **One declarative file per service, at run time.** FreeBSD rc.d
   plus `rc.conf` (with `NAME_user`, `NAME_chroot`, `NAME_limits`),
   launchd plists, systemd units, Sculpt's deploy file. Identity,
   confinement and limits live beside the enable switch, and adding a
   service never needs a new system image. erXos's `service NAME
   enable` already has the shape for apps; system services and drivers
   remain image-only. Cost: the file must be checked at run time
   rather than proved at build time.

5. **Limits are caps, not reservations, except where a guarantee is
   the point.** rctl rules, `MemoryMax=`, launchd rlimits and
   `limits(1)` cap use and take effect at once; nothing is set aside.
   Genode makes every child declare RAM and trades quota down the
   tree, and its users meet exactly the friction this discussion
   started from (Sculpt has no quota interface, per a mailing-list
   answer). erXos's walls (cap equals guarantee) and the `apps` row's
   worst-case proof are Genode-style. Cost of caps: a domain that
   needs memory can be refused when others have taken it; that is the
   right trade for a user's programs and the wrong one for the system
   domain, storage or a display driver, which keep walls.

6. **Grant at the moment of use, or by user choice.** Android runtime
   permissions, Flatpak portals, macOS open panels (unverified here)
   and Sculpt's connect-on-install dialog ask only when a need arises,
   with the person present. erXos's packaging design leaves "prompts
   that ask a person to approve a grant" outside scope. Cost: a prompt
   path and a place to remember answers; it fits apps, not services.

7. **Policy learned, not written.** QNX's `secpolgenerate` records what
   a running system used and proposes the rules. If erXos keeps any
   image-level policy, a learning mode beats asking people to write it.
   Cost: a recorder, and a review step so a learned rule is not
   blindly trusted.

8. **Signing is about distribution, not about running your own code.**
   Android, macOS and Sculpt check signatures on what comes from a
   store or provider; a developer's own build on their own machine runs
   unsigned (macOS tools, every UNIX). erXos ties running any
   installed code to a signer key in the boot image. Cost of relaxing:
   the machine's administrator, not the image builder, decides which
   code runs, which is the UNIX model this discussion asked for.

## A sketch of a simpler model

For discussion only; any change goes through a design document and the
advisors.

* **Layer 1, a user's own program (UNIX).** Copy a native binary into
  any directory the session can write, mark it executable, run it. It
  runs as a sub-space of the session with the session's namespace and
  rights (pattern 1), its memory charged to the session's budget as a
  cap. `/tmp` and removable media mount `noexec` by default; a user
  narrows a run with the shell's existing namespace narrowing
  (pattern 2). Concepts: executable, execute bit, path; `noexec` when
  it bites.
* **Layer 2, a service (rc.d).** One file under a run-time directory
  names the program or OTP application, the user it runs as, the
  services it may use (a subset of that user's) and optional caps;
  `service NAME enable` starts it at boot. No image rebuild. Concepts:
  service file, `service`.
* **Layer 3, a third-party app (app platform).** The existing `.app`
  package keeps its declaration, its hash-checked image and its own
  principal, but its needs are checked against what the installing
  administrator allows at install time, with a prompt or a flag,
  instead of an image-baked `apps` row and signer list; memory is a cap
  unless the declaration asks for a guarantee the machine can grant.
* **What stays image-level.** The system domain, the drivers and the
  domains whose guarantees the build proves (walls), and the trusted
  signer keys for the system partition.

What it would remove: the `apps` row as a build-time gate, the
worst-case proof's app term (PK2), F6's three-value rights type, and
the signer requirement for code the administrator copies in. What it
would cost: the build no longer proves the machine can afford every
app at its worst, so a user's programs and apps can be refused memory
at run time; and running code a user can write is back, bounded by
`noexec` mounts and session narrowing as on FreeBSD.

## Sources

All read on 2026-11-25. Versions or dates are as each page shows them.

| Source | URL | Version or date shown |
| --- | --- | --- |
| QNX `procmgr_ability()` | https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/p/procmgr_ability.html | QNX SDP 8.0 |
| QNX Using security policies | https://www.qnx.com/developers/docs/8.0/com.qnx.doc.security.system/topic/manual/using_security_policies.html | QNX SDP 8.0, updated 2026-11-05 |
| QNX Security policy maintenance | https://qnx.com/developers/docs/8.0/com.qnx.doc.security.system/topic/manual/security_policy_maintenance.html | QNX SDP 8.0, updated 2026-11-05 |
| QNX Pathname management (excerpt) | https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.sys_arch/topic/proc_PATHMAN.html | QNX 8.0 |
| QNX IDE launch configuration (excerpt) | https://qnx.com/developers/docs/8.0/com.qnx.doc.ide.userguide/topic/launch_configuration_properties.html | QNX 8.0 |
| FreeBSD mount(8) | https://man.freebsd.org/cgi/man.cgi?query=mount&sektion=8&manpath=FreeBSD+15.0-RELEASE | 15.0, 2025-07-16 |
| FreeBSD rctl(8) | https://man.freebsd.org/cgi/man.cgi?query=rctl&sektion=8&manpath=FreeBSD+15.0-RELEASE | 15.0, 2018-02-26 |
| FreeBSD capsicum(4) | https://man.freebsd.org/cgi/man.cgi?query=capsicum&sektion=4&manpath=FreeBSD+15.0-RELEASE | 15.0, 2025-06-17 |
| FreeBSD jail.conf(5) | https://man.freebsd.org/cgi/man.cgi?query=jail.conf&sektion=5&manpath=FreeBSD+15.0-RELEASE | 15.0, 2024-09-21 |
| FreeBSD rc.subr(8) | https://man.freebsd.org/cgi/man.cgi?query=rc.subr&sektion=8&manpath=FreeBSD+15.0-RELEASE | 15.0, 2024-10-23 |
| FreeBSD Practical rc.d scripting | https://docs.freebsd.org/en/articles/rc-scripting/ | modified 2026-10-28 |
| L4Re Ned | https://l4re.org/doc/l4re_servers_ned.html | doxygen 1.15.0, no date |
| L4Re initial environment | https://l4re.org/doc/l4re_concepts_env_and_start.html | doxygen 1.15.0, no date |
| Genode Foundations, The init component | https://genode.org/documentation/genode-foundations/26.05/system_configuration/The_init_component.html | 26.05 edition |
| Genode Foundations, Resource trading | https://genode.org/documentation/genode-foundations/26.05/architecture/Resource_trading.html | 26.05 edition |
| Sculpt Operating System 26.04 | https://genode.org/documentation/articles/sculpt-26-04 | 26.04 |
| Genode users list on quotas (excerpt, not official) | https://lists.genode.org/mailman3/hyperkitty/list/users@lists.genode.org/thread/TTS4ABU2KTGBSXFVXA3RF7PSTSZR7KYY | mailing list |
| The Use of Name Spaces in Plan 9 | https://9p.io/sys/doc/names.html | OSR 27(2), April 1993 |
| OpenBSD pledge(2) | https://man.openbsd.org/pledge.2 | OpenBSD-current, 2026-09-10 |
| OpenBSD unveil(2) | https://man.openbsd.org/unveil.2 | OpenBSD-current, 2026-07-20 |
| Apple, Protecting user data with App Sandbox | https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox.md | 2026 |
| Apple Platform Security, Gatekeeper (excerpt) | https://support.apple.com/guide/security/secf826eff27/web | no date |
| launchd.plist(5) | https://keith.github.io/xcode-man-pages/launchd.plist.5.html | 2019-07-30 |
| Android permissions overview | https://developer.android.com/guide/topics/permissions/overview | no date |
| Flatpak sandbox permissions | https://docs.flatpak.org/en/latest/sandbox-permissions.html | latest (covers 1.17.0) |
| systemd.exec(5) | https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html | systemd 262 |
| WASI security | https://wasi.dev/security | no date |
| Wasmtime CLI options | https://docs.wasmtime.dev/cli-options.html | no version shown |
| Redox book, security and scheme operation (excerpt) | https://doc.redox-os.org/book/ch04-10-security.html | no version shown |
| Zephyr user mode overview | https://docs.zephyrproject.org/latest/kernel/usermode/overview.html | latest, updated 2025-12-16 |

Not read: Apple's App Sandbox reference pages (the fetch returned no
body), the Redox book directly (HTTP 403), FreeBSD pkg(8) and mac(4),
QNX `slm` and rlimit pages, and Android's sandbox and UID pages. No
document needed accepting terms or signing in.
