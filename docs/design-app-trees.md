# Service trees: `/svc/NAME`

A service that says something about itself, or takes commands, does so
in one file tree it serves, and a session finds every such tree it holds
at `/svc/NAME`, NAME being the service's name. This holds for every
kind of service: an installed or configured app, a service a configured
domain serves (`/svc/bluetooth`, `/svc/wifi`) and the system domain's own
(`/svc/start`, the start table's commands, and `/svc/machine`, the
machine's end). A tree holds a `status` file to read where the service
has words of its own, a `ctl` file for one-shot control where it takes
commands, and any other file its design serves, such as a pairing
window. `/proc` keeps only what the system itself observes, the start
table's record of each row at `/proc/svc` among it. A device's tree stays
under `/dev`, and stored files stay where their meaning fits.

One question then finds anything: is it something the system reports
(`/proc`), a service (`/svc/NAME`), a device (`/dev`), or a file?

This is the second of the three homes of [CLAUDE.md](../CLAUDE.md) ("No
new mechanism without a design that names it"): "what an app says about
itself, bytes someone keeps, or a thing someone commands is a file tree
its owner serves and the reader mounts, with a `status` file to read and
a `ctl` file for one-shot control", with its place: "Service control
trees are mounted at `/svc/NAME`; device trees stay under `/dev`; stored
files stay where their meaning fits." The decision row of
[design.md](design.md#decisions) states the same rule.

## Context

### What the design rests on

* **Where a control tree lies is a fact users have to find.** The
  three-homes rule fixes what a control tree is (a tree its owner
  serves, with `status` and `ctl`) and, with no rule for where it lies,
  each design picks a root of its own. A user then has to know, for each
  thing, whether it is an app, a system service, a drive or a device
  before knowing where its `ctl` is. This design makes the place follow
  from what the tree is, so no design chooses a mount point.
* **`/proc` shows only what the system observes, so a service's own
  words do not fit an inspection kind.** A kind at a machine path,
  reported by `runtime`, would be answered in the system domain's own
  runtime, where no app runs, so every attribute would read
  `unsupported`. Routing the path to an app's session would need the
  inspector to find an app's domain and an agent bound that admits a
  machine path, which no design names. And a status call into an app's
  main loop is answered only while the loop waits, so a read while the
  app is busy would time out.
* **The start table's record** is at `/proc/svc` and `/proc/svc/NAME`,
  reported by the start service and readable by an inspect facet whose
  session template holds `start`
  ([design-apps.md](design-apps.md#interfaces),
  [design-live.md](design-live.md#the-inspect-service)). It is what the
  system observes of a start row: its state, its reason, its domain. A
  session `onestart` started belongs to no row there, though the row
  runs it ([design-apps.md](design-apps.md#the-start-table)). A
  configured domain's record is at `/proc/domains/ID`, and `/proc/svc`
  does not repeat it.
* **A row runs at most one session.** Every session of a row, kept by
  its supervisor or started by `onestart`, is started by a keeper of the
  start service; a kept row's supervisor has one keeper, `onestart`
  answers `ealready` while the row runs, and `restart` ends the session
  that runs before it starts the next
  ([design-apps.md](design-apps.md#keeping-a-session)).
* **A configured domain's facet is installed under its service's
  name.** The manifest's `service` row names a service and its server,
  and its `facet` rows grant it; the domain service installs each grant
  in the grantee's capability registry under the service's name, and a
  facet row's own name names the row in the manifest alone. Service
  names are unique per server, not across the manifest
  ([design-system.md](design-system.md#facets-a-configured-domain-serves)).
  Apart from that, a session serves nothing to another domain, and
  [design-apps.md](design-apps.md#requirements) keeps apps that serve
  facets out of scope.
* **Every facet carries its service's interface number**, which the
  domain service sets and no server's reply does: from the manifest's
  row for a facet it installs, and from the live grant record of its
  source for a facet `erx_domain:grant/4` re-grants.
  `erx_facets:table/1` derives a rule of the namespace from it at each
  resolution, as it keeps a display's facet from a program
  ([design-files.md](design-files.md#narrowing-for-a-program)) and marks
  a drive's tree so that none of its links is followed
  ([design-drives.md](design-drives.md#links-and-rights)).
* **A link is resolved in the reader's namespace.** A file server follows
  no link; the reader's resolver reads the link's text and goes on from
  its own `/` ([design-files.md](design-files.md#resolving-a-path)), and
  an open for writing follows a last link
  ([design-files.md](design-files.md#resolving-a-path), "The last
  name's link"). A tree whose server parses a stranger's input, an app's
  or the Bluetooth domain's after a takeover from radio range, could
  therefore serve `ctl -> /etc/start.conf`, and `echo x > /svc/NAME/ctl`
  in root's session would write root's own file.
* **A file call waits for its reply or its server's end.** An Erlang
  client's request waits for the reply or for the grant's end, and a
  process that ends with a request in flight needs no cleanup: its fids
  are clunked when its end reaches the grant
  ([design-files.md](design-files.md#fid-owners),
  [design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)).
  `flush` is no deadline: erXos's servers answer a flush only after the
  flushed request is settled
  ([design-files.md](design-files.md#flush)), so a hung server answers
  neither. A request whose server ends before answering answers `eio`,
  which for a begun request says that what its effect did is not known
  ([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)).
  A grant holds at most 64 requests in flight, and a request beyond that
  waits in the client or fails `emfile`
  ([design-files.md](design-files.md#bounds)).
* **A directory lists the mount points below it.** A listing is its
  provider's entries plus one for every mount point directly below the
  directory ([design-files.md](design-files.md#resolving-a-path),
  "Listings across mounts").

### What FreeBSD does

FreeBSD releng/15.1 (References):

* `service NAME status` runs the script's `status` command, whose default
  prints `NAME is running as pid N.` or `NAME is not running.` and
  returns 1 (`libexec/rc/rc.subr`, `run_rc_command`, lines 1465-1474). A
  script adds its own words with `status_precmd` and `status_postcmd`, or
  replaces them with `status_cmd` (lines 1356-1359, 1178), and offers
  verbs of its own through `extra_commands` (lines 912, 1126). The run
  state is the system's, the rest the script's.
* `service` is not uniform across scripts: `status` is a keyword only of
  a script that names a process or sets `status_cmd`
  (`rc.subr`, lines 1168-1182), and a script that cannot stop says so by
  doing nothing, as `rc.d/root` (line 14) and `rc.d/dmesg` (line 17) set
  `stop_cmd=":"`. `service -e` lists the enabled scripts and `service -l`
  every script (`usr.sbin/service/service.8`, lines 86-87 and 101-103).
* `run_rc_command` reads its argument as an optional prefix and a
  keyword: it strips a leading `fast`, `force`, `one` or `quiet`
  (lines 1094-1121), and the keywords are `start`, `stop`, `restart`,
  `rcvar`, `enable`, `disable`, `delete`, `enabled`, `describe`,
  `extracommands`, the script's `extra_commands` (line 1126), and
  `status` and `poll` for a script with a process to check (line 1176).
  A prefix applies to every keyword, a script's own verbs included, so
  `forcereload` runs `reload` forced.
* `/media` holds "mount points for removable storage media" and `/mnt`
  is an "empty directory commonly used by system administrators as a
  temporary mount point" (`share/man/man7/hier.7`, lines 364-374).
  Neither is a place for a service's control.
* A mount with `nosymfollow` follows no symbolic link: "Do not follow
  symlinks on the mounted file system. [...] You can still create or
  remove symlinks, or read the value of a symbolic link"
  (`sbin/mount/mount.8`, lines 272-277). `vfs_lookup` refuses to follow a
  link that lies on such a mount with `EACCES` (`sys/kern/vfs_lookup.c`,
  lines 1396-1414).

`/svc` is erXos's own name for erXos's own thing: it is not FreeBSD's
`/var/run` (no pid files or sockets), nor Plan 9's `/srv` (no posted
channels to mount), nor the FHS `/srv` (no site data).

## Requirements

* **AT-R1.** `/proc` shows only what the system observes. No service's
  own words appear there, and no app adds a kind to the inspection
  schema.
* **AT-R2.** Every tree in which a service says something about itself
  or takes commands is at `/svc/NAME`, whatever serves it: an app's
  session, a configured domain or the system domain. A device's tree is
  under `/dev`, and no stored file is under `/svc`. A design that adds a
  service tree chooses no mount point.
* **AT-R3.** NAME is the service's name: an app's admitted name, or the
  name of the manifest's `service` row. No two trees share a name, no
  service speaks under another's name, and no tree is reachable under a
  name its server chose.
* **AT-R4.** Who holds a tree is decided as it is without `/svc`: the
  manifest's facet rows for a service of the manifest, the `start`
  grant's policy for an app. The server decides nothing about it, and a
  tree's place gives no one a grant.
* **AT-R5.** Nothing a tree's server serves makes a reader act outside
  the tree, run code, or show a control character under the service's
  name.
* **AT-R6.** No system command waits on a tree longer than the deadline
  it states, and a command whose answer is lost, at that deadline or by
  the server's end, is reported as of unknown outcome and never
  repeated. An interactive command, such as a pairing window, waits
  until `Ctrl-C`.
* **AT-R7.** After a tree's server restarts, no reader reaches the old
  tree, and no descriptor opened on it reaches the new one.
* **AT-R8.** It feels like FreeBSD: `service NAME status` gives the run
  state where the reader may see it, then the service's own words, as a
  script's `status_postcmd` does; `service NAME CMD` runs a service's own
  verb, as `extra_commands` do; and a verb a name does not take is
  refused in words.

Outside this design: a drive's `status` and `ctl`, which stay under
`/media/diskN` until a design of their own moves them (`TODO.md`); apps
that serve facets to other apps; a native app's tree (a declaration with
`program` serves none); app trees with directories or writable files
beyond `ctl`; and the grammar of any one service's commands, which is
that service's design.

## Overview

```text
 root's session root_1                     the session's capability registry
 ---------------------                     ---------------------------------
 /svc   provider {facets, svc}  ---------> each facet of interface svc, by name:
   ls /svc: bluetooth machine ntpd start     bluetooth  (facet row, server domain bt)
                                             machine    (facet row, server: system domain)
                                             start      (facet row, server: system domain)
                                             {svc, <<"ntpd">>} (domain service's policy,
                                                         server: ntpd's session)

 every entry that reaches one of them: no link followed (the interface's `links none`),
 rights ro or rw (the interface has no rx), each grant's own rights

 service NAME status  : the run state where the session may see it, then /svc/NAME/status
 service NAME CMD ... : CMD ... written to /svc/NAME/ctl
 both through erx_svc_client, which ends its call at the deadline its caller gives
```

**The construction.** One interface, `svc`, is the type of every service
tree, and one directory, `/svc`, lists every tree of that interface the
domain's registry holds:

1. **One interface.** `abi/services/svc.txt` declares `svc`: a tree that
   speaks 9P2000.L as `files` does, with `files`'s quantities, and one
   parameter, its rights, `ro` or `rw`, never `rx`. Its row carries the
   word `links none`, from which `erx_facets:table/1` marks every entry
   on a facet of the interface so that the resolver follows none of its
   links. `media` carries the same word, so the rule is one word of the
   interface's row and not a property of each interface.
2. **One directory.** Every domain's namespace has one entry at `/svc`,
   whose provider `{facets, svc}` lists, at each resolution, every facet
   of interface `svc` the domain's registry holds, each as a directory
   that is the root of that facet's grant.
3. **A tree is named by its service.** A facet's name in the registry is
   set by the domain service, never by the server: the service row's
   name for a grant of the manifest, the app's admitted name for an
   app's tree. So `/svc/NAME`, `service NAME` and the name `service -l`
   prints are one name.
4. **Grants stay where they are.** The interface says where a tree
   appears and how its links are treated, not who holds it: an app's
   tree is granted by the domain service's policy to every session whose
   template holds `start`, and a manifest service's tree by its facet
   rows.

From these the requirements follow with no table of mount points: a new
service tree is a `service` row of interface `svc` and appears at
`/svc/NAME` in every domain granted it (AT-R2); its name is its row's
(AT-R3); its holders are its rows' (AT-R4); the link and execute rules
come with its interface through every mount and bind (AT-R5); and
`service` reaches any tree by one path (AT-R8).

**An app's tree, end to end.** ntpd's template declares that its
sessions serve `svc`, so the domain service's plan of each of its
sessions sets `serves=svc` in the session's environment. When the start
service's keeper starts ntpd's session, the session's runtime starts
`erx_svc`, the SDK's tree server, before its ready report, and the
report names `erx_svc` as the mint of `svc`. The domain service accepts
it because the session runs ntpd's row, its plan serves `svc` and
`ntpd` is no name the manifest reserves for a service of its own; from
then on that session, the row's current one, is the provider of the name
`ntpd`. For every live session whose template holds `start`, the domain
service introduces the two sessions, asks `erx_svc` for a facet bound to
that session, and installs it in the session's registry as
`{svc, <<"ntpd">>}` with the `svc` interface's number, read-write if that
session's `start` grant is and read-only otherwise, so `/svc/ntpd`
appears. ntpd calls `erx_svc:set_status/1` after each change; `erx_svc`
keeps the rendered text and answers every read of `status` from it,
never from ntpd's own loop. When ntpd's session ends, its facets end
with it, so `/svc/ntpd` leaves every registry; the row's next session
provides again and is granted anew.

**A system service's tree, end to end.** The Bluetooth domain `bt`
serves the service `bluetooth`, whose manifest row names the interface
`svc`, and a facet row grants it to root's template. When a session of
root starts, the domain service asks `bt` for a grant bound to the
session and installs it under `bluetooth`, the service's name, with the
interface's number, as it installs every facet of a configured domain.
The session's `/svc` lists `bluetooth` from then on; `btpair` opens
`/svc/bluetooth/pair`, and `service bluetooth forget all` writes
`forget all` to `/svc/bluetooth/ctl`. The start service's `start` and the
domain service's `machine` reach root's sessions the same way, at
`/svc/start` and `/svc/machine`.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **AT1.** `/proc` holds no service's own words | a kind whose reporter is `runtime` is declared only at paths under a domain id or a process id, which the schema generator checks for every row of `abi/inspection.txt`, so a runtime can report only about its own domain, which [design-live.md](design-live.md#the-proc-tree) already enforces at the inspector ("What a runtime reports"); no other reporter is an app | a runtime-reported kind at a machine path, as `ntp` at `[ntp]` | the generator's check, with a seeded `kind` row reported by `runtime` at a machine path that fails the build |
| **AT2.** `/svc/NAME` is a tree of NAME's server and of no other | the registry name is set by the domain service: `{svc, Name}` from the providing session's principal, never from anything the session sends, and only for a session a keeper's start of NAME's row made, whose plan serves `svc`; a manifest grant under its service row's name; and no `svc` facet is re-granted, since `erx_domain:grant/4` and a create spec refuse one. NAME's app provider is the row's current session, and a row runs at most one; names are disjoint (AT9) | a report whose `provides` names the tree's name; a provide accepted from a session no keeper of the row started; a re-grant of an `svc` facet, which installs a facet of the system domain under a name the caller chose | the domain service's host tests of the provider rule and of `grant/4`, each refusal seeded; the QEMU tests below |
| **AT3.** No grant outlives its server or reaches a later one | every `svc` facet is a process of the serving domain, minted there, so it ends with that session or that incarnation; the registry removes a facet at its end; a descriptor keeps the grant it was opened on, which answers `eio` once ended (F10) | a facet hosted outside its server's domain, or a registry entry kept across the facet's end | the restart test of [Verification](#verification-and-testing) |
| **AT4.** No link in a service tree is followed | `erx_facets:table/1` marks every entry whose interface's row says `links none`, at each resolution, from the interface number of the facet the registry holds, or, for an own service's mount, from the generated service table's row for its name; `svc` says it, so the mark follows no name, no mount point and no option, and every entry that reaches a service tree (the `/svc` entry, a facet's mount, an own service's mount, a bind, a program's table) carries it ([Links](#links)) | a resolver that ignores the mark; an `svc` facet installed with another interface's number, such as an app's tree as `files`; an own service's mount that keeps no name | the link test and its seeded faults below; the resolver's fuzz target with marked entries |
| **AT5.** Nothing in a service tree runs | the interface's rights are `ro` or `rw`, with no `rx`; an app's grant takes its grantee's `start` grant's rights with anything but `rw` as `ro` ([The grant](#the-grant)); and no grant both writes and runs ([design-files.md](design-files.md#invariants), F6) | an `rx` member of `svc`'s rights; an app's grant copying an `rx` grant of `start` | `svc_rights` has no `rx`, so no row can state one; the grant's rights test |
| **AT6.** No system command waits on a service tree beyond the deadline it gives | every command reads, writes and opens under `/svc` only through `erx_svc_client`, whose `read/4` and `command/3` make the call in a process they end at the deadline their caller gives, ending its fids ([design-files.md](design-files.md#fid-owners)), and whose `open/3` opens in the caller's own process, a process of the foreground job, which `Ctrl-C` ends | a command that calls `file` on `/svc` in its own process; a non-interactive caller passing `infinity` | a chokepoint source check that only `erx_svc_client` names `/svc` among the shell's, the commands' and the start service's modules, with a seeded direct read; the hung-server test |
| **AT7.** A line shown under a service's name holds no control | `service` and `ntpctl` show a status line only after `erx_svc_status:parse/1` accepts it, an identifier, a tab and a field the field escape writes, which holds no character the line escape changes ([design-live.md](design-live.md#attributed-text)); any other line shows as `[invalid]` | a reader that prints a line it did not parse, or unescapes a value for display | the parser's fuzz target and properties; the escape test below |
| **AT8.** An app's tree is held only by sessions whose template holds `start`, with that grant's rights; a manifest service's tree only by its facet rows' grantees; the system domain holds no `svc` grant | the domain service derives an app tree's grantees and rights from the manifest's `start` grants, and an app's tree has no `service` row, so no facet row names it; the manifest check refuses a facet row that grants a service of interface `svc` to the system domain | an app tree granted to every session; an `rw` grant to a session whose `start` is read-only; a facet row granting `bluetooth` to the system domain | the domain service's host test; the manifest check with a seeded row; the rights test below |
| **AT9.** No two service trees share a name | the manifest check refuses a service of interface `svc` named like another such service or like a principal, which every start row's name is; admission refuses an app named like any principal, domain, service or facet row of the manifest ([design-packaging.md](design-packaging.md#admission)); the domain service refuses a session's provide of `svc` whose name is a service of interface `svc` of the running manifest, which a system update can add after the app was admitted | a manifest with two `svc` services of one name on two servers; an admitted app whose name a later manifest gives a service | the manifest check's seeded rows; the admission test; the provide test below |

## Data model

### The interface

`abi/services/svc.txt` declares the interface `svc`, served as a tree:
it speaks 9P2000.L as `files` does and declares no operation, carries
`files`'s quantities and floor, and has one parameter, the grant's
rights, of the enum `svc_rights`, whose values are `ro` and `rw`, `rw`
where a row states none. `files_grant` takes it as it takes a `files`
facet's rights. Its row carries `links none`, the word of an interface's
row that says no link in a grant of it is followed; `media` carries the
same word, and the generator derives from it the set of interfaces
`erx_facets:table/1` marks, so neither `media` nor `svc` is named in the
resolver. The same file declares the three bounds of a reader of a
service tree: `svc_wait_max`, 5,000 ms; `svc_status_max`, 65,536 bytes;
and `svc_ctl_max`, 4,096 bytes.

A service row names the interface as any row does:

```text
service bluetooth
  server @domain.bt
  interface svc
service start
  server system
  interface svc
```

### The name

A tree's name is the name its facet is installed under in the domain's
registry, which only the domain service sets:

| Tree | Its name | Who sets it |
| --- | --- | --- |
| a manifest service's (`start`, `machine`, `bluetooth`, `wifi`) | the `service` row's name, an atom | the domain service, from the manifest, as for every facet of a configured domain |
| an app's | `{svc, Name}`, Name the app's admitted name, a binary | the domain service, from the providing session's principal |

The listing writes an atom's text and a pair's binary alike, so the two
forms are one name space to a reader, and AT9 keeps them disjoint. A
session's registry makes no atom from an app's name. A name users type
is the service's, not its server's: the Bluetooth domain is `bt` and its
tree is `/svc/bluetooth`.

### The declaration

A session template declares that its sessions serve their tree with one
word, `serves svc`, in the manifest's source:

```text
session ntpd
  limits @limits.app
  runtime @artifact.emu
  release @artifact.ntpd
  serves svc
```

and a package declares the same in its `app.txt`
([design-packaging.md](design-packaging.md#the-declaration)):

```text
app dashboard
  needs display net
  serves svc
  applications erx_dashboard
```

The field's one value is `svc`, a closed set the grammar checks, so
nothing else can be declared served. It grants the app nothing: it lets
the sessions that may command apps read and command this one. It is
refused beside `program`, since a native app has no `erx_svc`. A start
row carries no service (AP1 of [design-apps.md](design-apps.md#invariants)),
so the declaration lives on the template or the package, where the
build's check and the admission see it.

### The tree

A manifest service's tree holds what its design serves: `start` a `ctl`
([design-apps.md](design-apps.md#interfaces)), `machine` a `ctl`
([design-system.md](design-system.md#a-sessions-request)), `bluetooth`
its pairing window, its bonds and a `ctl`. Each is served by its own
`erx_fs` callback module and follows the interface's rules; a `status`
is there where the service has words of its own.

An app's tree is the flat directory `erx_svc` serves:

| File | Read | Write |
| --- | --- | --- |
| `status` | the text the app last set with `erx_svc:set_status/1`, empty until then | refused, `eacces` |
| `ctl` | present only once the app has called `erx_svc:set_ctl/1`; reads as empty | one command a write, handed to the app ([Commanding](#commanding-ctl)) |
| any other name | the bytes the app set with `erx_svc:set_file/2` | refused, `eacces` |

Creating, removing or renaming a file answers `eacces`, as creating a
file in a directory its caller may not write answers on FreeBSD. A tree
whose app takes no commands has no `ctl`, so `ls /svc/ntpd` shows what
ntpd offers and nothing that refuses every write.

### A status line

`status`, in an app's tree and in a manifest service's tree that has
one, holds one attribute a line:

```text
NAME <tab> VALUE <newline>
```

NAME is a system identifier, `[a-z0-9][a-z0-9_-]*` of at most 63 bytes
([design.md](design.md#decisions)), at most once in a file. VALUE is text
the field escape writes, `erx_text:escape_field/1`
([design-live.md](design-live.md#attributed-text)): tab, newline and
backslash as `\t`, `\n` and `\\`, and every byte of a character a display
would escape as `\x` and two hexadecimal digits. This is the form of a
`/proc` `status` file's first two fields, so a program that reads one
reads the other, and `erx_text:unescape_field/1` recovers each value's
bytes. An attribute the service holds no value for is left out, and a
reader shows a missing attribute as `[unknown]`, never as a value.

The SDK writes it: `erx_svc:set_status([{Name, Value}])` takes
identifiers and text, escapes each value, renders the lines and keeps
them. One parser reads it, `erx_svc_status:parse(Bytes)`, which returns
each line as `{Name, Value}` with the value still escaped, or `invalid`
for a line that is not an identifier, one tab and a field
`unescape_field/1` accepts, for a repeated name and for a last line with
no newline. Its input is what `erx_svc_client:read/4` returns for a
`Max` of `svc_status_max`, which is at most one byte more
([Reading with a deadline](#reading-with-a-deadline)): input longer than
`svc_status_max` is a file that was cut, so the parser reads the lines
of its first `svc_status_max` bytes, drops what follows their last
newline, and ends with `partial`. A cut file is therefore never taken
for a whole one, wherever the cut falls.

### The grant

A manifest service's tree is granted by its facet rows, as every
service of a configured domain or of the system domain is
([design-system.md](design-system.md#facets-a-configured-domain-serves)),
with the rows' rights and quantities.

An app's tree is granted by the domain service's own policy. For each
live session `S` whose template holds `start` and each app name `NAME`
with a provider, the domain service keeps one grant record, keyed by `S`
and `{svc, NAME}`. It is the record of
[design-system.md](design-system.md#facets-a-configured-domain-serves)
("One operation per grant"), with no manifest row behind it, and each of
its fields has one source:

* its pair is NAME's provider ([Providing](#providing)) and `S`;
* its rights follow the `start` grant of `S`'s template: `rw` where
  that grant is `rw`, and `ro` otherwise. A session that may command the
  start table commands each app; one whose `start` grant is read-only
  reads each app's tree, and its writes to `ctl` are refused by the
  grant before `erx_svc`'s callback
  ([design-files.md](design-files.md#invariants), F5);
* its interface is `svc`, and its quantities are the interface's
  `quantity` lines, the ones every facet row the build derives takes
  ([design-packaging.md](design-packaging.md#the-apps-row)).

Like the `code_objects` facet, it is granted by the domain service's own
policy ([design-system.md](design-system.md#creating-a-domain)), and no
manifest row grants it.

### What the grants count

Each app grant record joins its two sessions by one connection, which
every other grant between the same two domains reuses
([design-system.md](design-system.md#facets-a-configured-domain-serves)),
and each connection counts against both domains' `connections` quotas.
The manifest check counts these connections wherever it counts a
server's and a grantee's connections
([design-packaging.md](design-packaging.md#the-apps-row)), as if the
build derived one facet row of the `svc` interface from every serving
template to every template that holds `start`:

* the serving templates are every template that declares `serves svc`
  and whose principal has a `start` row, and the app template when the
  manifest has an `apps` row, counted as `max` principals each with a
  `domains` quota of 1
  ([design-packaging.md](design-packaging.md#the-builds-check), property
  19, item 2), whether or not a package declares `serves svc`, since
  `max` is reserved in full;
* on both sides a session template counts as many times as its
  principal's `domains` quota lets sessions of it live at once, as
  property 18 counts a template's display grants
  ([design-system.md](design-system.md#the-manifest)), so an app's
  session holds a connection to every administrator session that can
  live at once, one for each of root's logins among them, and an
  administrator's session holds one to every app that can serve.

A manifest whose quotas cannot hold them fails the build. A manifest
service's tree is counted by its facet rows, as any facet is.

### The namespace entry

Every domain's namespace has one entry at `/svc`:

```erlang
#{point => [<<"svc">>],
  provider => {facets, svc},   % a directory of the registry's facets of
                               % interface svc, each by its name
  root => [],
  rights => rw}                % each grant's own rights decide
```

`{facets, svc}` is a provider kind of the namespace
([design-files.md](design-files.md#namespaces)): a directory whose
entries are the names of the facets of interface `svc` the domain's
registry holds at each resolution, each a directory that is the root of
that facet's grant. The entry's own rights are `rw`, and a resolution
lowers them to the rights of the grant it reaches, as for every facet's
entry, so a read-only grant of `bluetooth` beside a writable one of
`machine` gives each its own. A domain that holds no such facet sees an
empty directory.

The system domain holds no `svc` grant (AT8), so its `/svc` lists
nothing of its registry. It serves `start` and `machine` and mounts its
own grant of each at `/svc/start` and `/svc/machine` with
`erx_ns:mount_own/2`, so its command shell reaches each by the path a
session does, and its `ls /svc` shows the two as the mount points below
the directory. `mount_own/2` places a service of interface `svc` at
`/svc/NAME`, from the interface the generated service table gives the
name, and every other service at `place/1`'s point; `place/1` has no row
for a service tree, since a domain that holds one reaches it through
`/svc`. The entry `mount_own/2` makes keeps the service's name beside
its grant, as its provider `{own, Name}`, so the entry has an interface
as a facet's entry has one: `erx_facets:table/1` takes it from the
generated service table's row for `Name`, as it takes a facet's from the
registry ([Links](#links)).

### What /proc keeps

`/proc` keeps the kernel's, the system services', the configured
domains' and each runtime's records about its own processes. Of a start
row it keeps what the start service observes, at `/proc/svc/NAME`: the
row, its state, its reason, its domain and its settings
([design-apps.md](design-apps.md#interfaces)); and what any domain's
runtime reports of an app's session at `[domains, Id]` and its
processes. `/proc/svc` lists start rows alone; a configured domain's
state is its record at `/proc/domains/ID`, and `/proc/svc` does not
repeat it. The `ntp` kind, its path `[ntp]` and its value types
`ntp_servers`, `ntp_last` and `net_addresses` are not in the schema.

## Algorithms and behavior

### Serving: `erx_svc`

`erx_svc` is a module of the `erx` library application, which every
runtime carries. A session's runtime starts it before its ready report
when its environment holds `serves=svc`, and calls
`erx_facet:provide(svc, Pid)`, so the report names it
([design-system.md](design-system.md#facets-a-configured-domain-serves),
"Providers"). It is the mint and the tree's `erx_fs` server in one
process. Its end ends the session, as a mint's end ends its domain, and
the start table's keeper starts the next.

The domain service's plan of the session sets `serves=svc`, after the
template's own words as it sets `principal` and `display`
([design-system.md](design-system.md#the-domain-library)), and the boot
view refuses a template whose environment sets it:

* `erx_dom_plan_session` sets it from the template's `serves` field in
  the packed manifest;
* `erx_dom_plan_app_session` sets it from the app's registry entry,
  which records the admitted package's `serves` as it records its
  memory ([design-packaging.md](design-packaging.md#admission)).

The plan is the one source of the fact: the provider rule reads the
same plan ([Providing](#providing)), so a session's start and its
admission as a provider never disagree, and a package's declaration
reaches its session before its ready report, though the app's record
comes only after the ready answer
([design-packaging.md](design-packaging.md#an-apps-session)).

The app's processes set what the tree shows with `set_status/1`,
`set_file/2` and `set_ctl/1`, each a message to `erx_svc`. A read is
answered from what `erx_svc` holds, so no read waits on the app's own
loop. That is the honest app's property; a reader still bounds its wait,
since the session's runtime as a whole is untrusted
([Reading with a deadline](#reading-with-a-deadline)).

A manifest service's tree is served by its own design's module
(`erx_starter_fs`, `erx_machine_fs`, the Bluetooth domain's tree), which
the interface changes in nothing but the rules above.

### Providing

The domain service accepts `svc` in a session's ready report, under the
rules of "Providers" in
[design-system.md](design-system.md#facets-a-configured-domain-serves)
with a session in place of a configured domain's incarnation:

* the session runs its principal NAME's start row, from the manifest or
  an admitted package
  ([design-packaging.md](design-packaging.md#the-start-tables-rows)): a
  keeper of the start service started it, kept or by `onestart`, and the
  keeper's `Start` says so with `row => true`, which the domain service
  records with the session. Only `erx_starter_keeper` sets `row`, which
  AP2's source check ([design-apps.md](design-apps.md#invariants)), the
  one that names the keepers as the starters of a row's sessions, also
  checks;
* its plan serves `svc` ([Serving](#serving-erx_svc));
* NAME is no service of interface `svc` in the running manifest (AT9);
* the mint is a pid the session owns, node and creation both, as for a
  configured domain;
* `svc` and the session's lines
  ([design-system.md](design-system.md#a-sessions-lines)) are the only
  names a session may provide; a `provides` map naming any other is
  refused whole.

A report that provides `svc` otherwise is refused, logged and counted,
and the rest of the report stands: the app runs without a tree.

**NAME's provider is the row's current session**: the session the
domain service last made for a keeper's start of NAME's row, while it
stands and its report provided `svc`. The row runs at most one session
at a time ([What the design rests on](#what-the-design-rests-on)), and
the domain service makes the next only after the last one's facets have
ended: a keeper starts again only once the end reached it through its
link to the domain pid, which the domain service ends after it has taken
the domain's connections down, and with them its facets
([design-system.md](design-system.md#ending-a-domain), steps 1 and 2);
and a start for a principal one of whose domains is ending is held until
that domain is retired
([design-system.md](design-system.md#creating-a-domain)). So nothing
chooses among providers, since there is never more than one, and no
grant of an earlier session meets the current one's. Each registry
holds one facet under a name, so if an earlier session's facet were
still installed, the current one's installation replaces it and a new
open reaches only the current session.

The name is the principal's, which the domain service gave the session
when it made it. A session cannot choose another, and the admitted names
are unique, so no app squats another's name.

### Granting

A manifest service's tree is granted at the events every facet row's
grant follows
([design-system.md](design-system.md#facets-a-configured-domain-serves)).
A facet of interface `svc` is never passed on. AT8 names the domains
that may hold a service tree: the sessions whose template holds `start`,
for an app's tree, and a manifest service's facet rows' grantees, for
the service's. Each of them already holds the tree under its own record,
with its own rights, so a re-grant has no recipient that the rule admits
and lacks the tree. `erx_domain:grant/4`, and a create spec's `facets`
([design-domains.md](design-domains.md#interfaces)), therefore refuse a
facet of interface `svc` with `einval`, whatever the name and the
target. So every `svc` facet a registry holds is one the domain service
installed from its own record, minted by the serving domain itself, and
never a facet of the system domain in front of another's
([design-domains.md](design-domains.md#facets)): the node of the
facet's pid is its server's, which is what `service` reads a name's kind
from ([What the commands show](#what-the-commands-show)).

An app's grant records follow two more events:

* **a provider's ready report** adds a record `{S, {svc, NAME}}` for each
  live session `S` whose template holds `start`, and a provider's end
  moves each such record to `idle` and ends nothing the end did not;
* **a session's ready report**, for a template that holds `start`, adds a
  record for each name that has a provider; its end deletes its records.

Each record then runs the existing operation: introduce, mint, install,
under one deadline of 10 s, with a fresh tag, failing once for the pair
and logging. The mint's request carries the grantee's principal and the
record's rights, so `erx_svc` knows who holds each facet; it binds no
tree differently by principal. Its reply names its grant's tree, as
every mint's reply for a file tree does, and the installation sends
`{Pid, Tree, Rights}` with the `svc` interface's number
([design-files.md](design-files.md#building-binding-and-mounting), "The
tree beneath an entry").

The system domain holds no `svc` grant, so the trusted base reads no
bytes an app or a configured domain serves in its tree, and its command
shell shows an app's run state from `/proc/svc` alone.

### Mounting and resolving `/svc`

`erx_ns:mount_facets/1` mounts the `/svc` entry in every domain at its
start, whether or not it holds a service tree, so the domain's table
changes with no tree's coming or going.

A resolution that reaches `/svc`'s directory lists, after the release
slice's empty directory, one entry of kind `directory` for each facet of
interface `svc` the registry holds then, sorted by name, and then the
mount points below it, which only the system domain has. A walk of
`NAME` below it finds the facet of interface `svc` whose name's text is
NAME: one there gives its grant, and the walk goes on at that grant's
root; none answers `enoent`, which the reader's own registry gives
without reaching any server. So `/svc/NAME` exists exactly while a facet
for it is installed, and the table holds one entry however many trees
come and go, within `ns_mounts_max` (64) whatever the 256 start rows
`start_rows_max` allows.

### Links

The resolver follows no link that lies in a tree reached through an
entry the resolution marked, and `erx_facets:table/1` marks every entry
whose interface has a row that says `links none`, `svc` among them: the
interface of the facet the registry holds under the entry's name, or,
for a domain's own service tree, the one the generated service table
gives its name. Where it would follow one (a link before
the last name, a last link the operation's row of the table in
[design-files.md](design-files.md#resolving-a-path) follows, or a
trailing `/`), it answers `eacces`, as FreeBSD's `vfs_lookup` does on a
`nosymfollow` mount. An operation that acts on the link itself
(`read_link`, `read_link_info`, `delete`) acts on it, as FreeBSD's
mount(8) says.

The mark is taken from the facet's interface number at each resolution,
as a drive's is
([design-drives.md](design-drives.md#links-and-rights)), so it holds for
every entry that reaches a service tree, whoever made the entry:

* the `/svc` entry reaches only facets of interface `svc`;
* a bind and a program's table keep their source's provider
  ([design-files.md](design-files.md#narrowing-for-a-program)), and the
  facet they reach carries its interface, so a bind of `/svc/app` at
  `/mnt` is marked;
* a facet's mount, `erx_ns:mount({facet, Name}, To, Options)`, reaches
  the facet the registry holds under `Name` with its interface number;
* an own service's mount, `erx_ns:mount_own(Name, Grant)`, keeps `Name`,
  whose interface the generated service table gives, so the system
  domain's `/svc/start` and `/svc/machine`, and a bind of either, are
  marked;
* a grant's mount, `erx_ns:mount({Pid, Tree, Rights}, To, Options)`,
  takes only a process of the domain's own runtime and refuses any other
  pid with `einval`, and every service tree a domain does not serve is a
  process of another domain.

No mount option sets or clears the mark, so no code of a domain reaches
a service tree through any entry that follows its links.

### Reading with a deadline

`erx_svc_client` is the one way a system command reads, commands or
opens a file under `/svc`. Its callers name a service and a file of its
tree, never a path: `Name` is the service's name as `/svc` lists it, and
`File` a relative path within its tree, such as `<<"status">>`. The
client alone joins them into `/svc/Name/File`, so `/svc` is written in
one module, and it answers `{error, einval}`, reaching nothing, for a
`Name` that is not one name or a `File` that is absolute or holds a `.`
or `..` component, so no caller reaches outside the tree it names.
Each call that waits takes the deadline as a parameter, so a command
states how long it may wait:

* `read(Name, File, Max, Deadline)` spawns a process that opens the
  file, reads
  until end of file or `Max + 1` bytes, whichever comes first, and
  closes, and waits for it until `Deadline`, in milliseconds:
  `{ok, Bytes}`, `{error, Errno}`, `not_serving` or `timeout`. `Bytes`
  longer than `Max` say that the file is longer than `Max`, so its caller
  knows a cut file from a whole one. At the deadline it ends the process
  with `kill`. Its reply goes to an alias that ended with it, and its
  fids are clunked when its end reaches the grant
  ([design-files.md](design-files.md#fid-owners)); a hung server keeps
  the request, within its grant's 64 in flight, in its own memory, and
  answers the clunk when it settles it or never.
* `command(Name, Line, Deadline)` does the same with one write of `Line`
  to the tree's `ctl`, and
  answers `ok`, `{error, Errno}`, `not_serving` or `unknown`. `unknown`
  is the answer whenever the write may have reached the server and its
  answer is lost: the deadline passed, or the write failed `eio`, which
  the file protocol answers for a request whose handler, grant or server
  ended before answering ([Commanding](#commanding-ctl);
  [design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)).
  The command may have taken effect, may yet, or may not. An `eio` for
  a write that never left the reader is reported the same way, which is
  never wrong. The caller reports it as unknown and never writes again
  on its own.
* `open(Name, File, Modes)` opens the file in the calling process and returns
  its descriptor, for a command that holds a file open with a person,
  such as `btpair`'s pairing window. It sets no deadline: the caller is
  a process of the foreground job, and `Ctrl-C` ends it, which ends its
  fids.
* `not_serving` answers a `Name` that `/svc` does not hold, which
  the walk of NAME learns from the reader's own registry; an `enoent`
  from within the tree is `{error, enoent}`.

`service`, `ntpctl`, `reboot` and `halt` pass `svc_wait_max`. The start
service, which no `Ctrl-C` reaches, reads no service tree.

Interactive use of the files themselves needs no client.
`cat /svc/NAME/status` and `echo CMD > /svc/NAME/ctl` wait as a read or
a write of any file does, and `Ctrl-C` ends them: the shell ends every
Erlang process of the foreground job by marking its tag
([design-shell.md](design-shell.md#job-control)), and the file call's
process ends with it. A write that `Ctrl-C` cut off, or that failed
`EIO`, has an unknown outcome, as it has on UNIX.

### Commanding: `ctl`

A manifest service's `ctl` takes the grammar its design gives it.

A write to an app's `ctl` is one command: the bytes of one write at
offset 0, at most `svc_ctl_max` bytes, one line, its trailing newline
optional, as `/svc/start/ctl` takes them
([design-apps.md](design-apps.md#interfaces)). A write that breaks this
answers `einval` and reaches no handler. `erx_svc` sends the line,
without its newline, to the process the app named with `set_ctl/1`, in
the order the writes arrive, and the write waits for the answer:

* `ok` makes the write succeed with the bytes written;
* `{error, Errno}`, an errno of the file protocol
  ([design-files.md](design-files.md#errors)), fails the write with it;
* any other answer, or the handler's end, fails it with `eio`, the file
  protocol's answer for an effect that is not known: the handler may
  have acted before it ended.

A 9P write carries no text back, so a command's refusal is its errno,
and its reason goes to the server's log. The line is untrusted input to
the server: each grammar erXos defines for a `ctl` has a fuzz target of
its own, landing with it.

### Lifecycle

| Event | What follows |
| --- | --- |
| an app's session starts, kept by its row or by `onestart` | `erx_svc` before the ready report; the report provides `svc`; the domain service grants each live session that holds `start`; `/svc/NAME` appears in each as its installation is acknowledged |
| a session starts | one `/svc` entry at its start; at its ready report its facet rows' grants and, for a template that holds `start`, a record for each app provider, so it sees every tree it is granted |
| the app restarts | its session ends, and with it `erx_svc` and every facet it minted; registries drop `{svc, NAME}`, so `/svc/NAME` answers `enoent`, and a descriptor open on the old grant answers `eio` (F10); the row's next session provides and is granted anew. No old grant reaches the new session, since a facet is a process of the session that minted it |
| a configured domain that serves a tree restarts | its facets end with its incarnation, so `/svc/NAME` answers `enoent` and an open descriptor `eio`; the next incarnation's grants are installed and the directory is back ([design-system.md](design-system.md#facets-a-configured-domain-serves)) |
| `service NAME stop` of a row | the session ends, as above, and no successor provides |
| a session that holds trees ends | its records are deleted and the facets bound to it end |
| `service NAME purge`, a package removed | nothing of the tree is kept anywhere, so neither has anything to remove from it; a removed package has no row and so no provider |
| an introduction or mint fails | the record is `failed` for that pair and logged ([design-system.md](design-system.md#facets-a-configured-domain-serves)); `/svc/NAME` is absent in that session until either side restarts |

### What the commands show

**`service` takes three kinds of names.** A name is `system` when the
session holds a tree of that name served by the system domain, `domain`
when it holds one served by a configured domain or names a configured
domain itself, and `app` for a start row. `service` resolves NAME in
that order, the system's names first:

1. the trees of a manifest service that the domain's `/svc` lists: the
   facets of interface `svc` its registry holds under a service row's
   name, and, in the system domain, which holds none (AT8), the trees it
   serves itself and mounts there with `mount_own/2` from the generated
   service table, `start` and `machine`. A tree is `system` when the
   process serving it is of the system domain's node, as an own mount's
   always is, and `domain` otherwise; the node is its server's, since no
   `svc` facet is a facet in front of another ([Granting](#granting));
2. a start row at `/proc/svc/NAME`;
3. a configured domain of `/proc/svc`'s `boot_order`.

A name none of these give answers
`NAME: no service of that name in this session`, with status 1, true of
a session that cannot see a tree another holds. Since a system name
comes first, a line meant for the system's `wifi`, a passphrase among
its arguments, never goes to an app of that name; AT9 already refuses
such an app its tree.

**`service NAME purge`** resolves nothing: it is for a name that no
installed package holds any longer, which has no row and no tree. It
writes `purge NAME` to `/svc/start/ctl` through
`erx_svc_client:command/3` and answers from that write, as for a
service's verb below, and the package process alone judges the name
([design-packaging.md](design-packaging.md#where-an-apps-files-lie)):
it refuses one that is not an app name, or that an installed package
holds, with the errno the write answers.

`service` declares no blanket need. Each operation uses its own grant: a
line to the start table needs `start`, a system or domain name needs its
tree, and reading `/proc/svc` needs the inspect scope that shows it. An
operation whose grant the session lacks answers as for a name it does
not hold.

**`service -l`** prints every name the session can resolve, one a line,
each with its kind, sorted by kind and then by name: the system's and
the domains' trees its `/svc` holds, the start rows `/proc/svc` shows it,
and the configured domains of `boot_order`. A session that holds no
`start` and no inspect scope of the start table lists only its trees.
The kind tells a reader which trees the trusted base serves and which a
configured domain or an app does.

**`service NAME status`**:

* for an app's row, writes the row's state from `/proc/svc/NAME`, as
  [design-apps.md](design-apps.md#interfaces) says, and then the app's
  own words while a session of the row serves its tree, whether the row
  keeps it or `onestart` started it;
* for a system or domain name, writes `NAME is part of the system`, then
  the serving domain's state from its record at `/proc/domains/ID` where
  the session's inspect scope reaches that record and nothing about it
  where it does not, and then the tree's own words if it has a `status`;
  the exit status is 0 while the tree answers;
* for a configured domain's name with no tree, writes
  `NAME is part of the system` and its state where the scope reaches it.

The tree's own words are each line of `/svc/NAME/status` that
`erx_svc_status:parse/1` accepts, as it is written, NAME, a tab and the
escaped value, `[invalid]` for each line it does not, and `[partial]`
last where the file was longer than `svc_status_max`. A valid line holds
no character the line escape changes, so it is shown as written, never
unescaped. `not_serving` adds nothing. A read that fails writes
`service: /svc/NAME/status: ` and the errno's text, or `timed out`, to
standard error. For a row, the exit status is the run state's, as
FreeBSD's `status` returns, and a failed read of the app's words does
not change it.

**`service NAME start`, `stop`, `enable`, `disable`** and their `one`
forms act on start rows alone, through `/svc/start/ctl`
([design-apps.md](design-apps.md#interfaces)). For a system or domain
name, or a configured domain's, each answers
`NAME is part of the system: it starts at boot and is not started or stopped`,
with status 1, and writes nothing, as a FreeBSD script that cannot stop
offers no `stop` ([What FreeBSD does](#what-freebsd-does)). `restart`
answers the same: no design gives a holder of `start` the power to end
a configured domain.

**`ntpctl -s status`** and **`-s peers`** read `/svc/ntpd/status`, and
answer `not_serving` as `ntpctl: ntpd is not running`, so an ntpd that
`onestart` started is shown as one its row keeps
([design-time.md](design-time.md#what-ntpd-serves)).

**`service NAME CMD [ARG ...]`** reaches a service's own commands, as a
FreeBSD script's `extra_commands` run its own verbs. `service` reads CMD
as rc.subr reads its argument ([What FreeBSD does](#what-freebsd-does)):
an optional prefix, `fast`, `force`, `one` or `quiet`, then a verb. A
CMD with a prefix, or whose verb is one of rc.subr's keywords (`start`,
`stop`, `restart`, `rcvar`, `enable`, `disable`, `delete`, `enabled`,
`describe`, `extracommands`, `status` and `poll`) or `purge`, which
erXos's `service` offers for removed packages, is `service`'s own:
it runs it if it is one of the verbs `service` offers
([design-apps.md](design-apps.md#interfaces)), the `one` forms among
them, and refuses any other with its usage line and status 1, as
rc.subr refuses a word it does not know. A service's verbs are the other
words, so `forcereload` and `quietreload`, which rc.subr runs as
`reload` with a prefix, never reach a service, and no service takes a
word a FreeBSD user knows as rc.subr's. For a service's verb, `service`
writes the line `CMD ARG ...` to `/svc/NAME/ctl` through
`erx_svc_client:command/3` and answers from that write alone, for every
kind of name, and for a row whether the row keeps its session or
`onestart` started it: status 0 when it succeeds; `not_serving` as
`NAME not running?`; `enoent`, a tree with no `ctl`, as its usage line;
`unknown` as `service: NAME: CMD: outcome unknown`, since the server may
have run it; and any other errno as `service: NAME: CMD: ` and its
text; each failure with status 1 and on standard error. So
`service bluetooth forget all` writes `forget all` to
`/svc/bluetooth/ctl`, and `service machine reset` the line `reboot`
writes.

**`reboot`** and **`halt`** write the machine's end to
`/svc/machine/ctl` through `erx_svc_client:command/3`
([design-system.md](design-system.md#a-sessions-request)).

**`cat /svc/NAME/status`** writes the file's bytes unchanged, as `cat`
writes every file. An honest service's file holds only what the field
escape writes; a hostile app's may hold anything, and `cat` shows it as
it shows any file another principal wrote ([Security](#security)).

## Interfaces

* **Service definitions**: `abi/services/svc.txt`, the interface `svc`,
  its enum `svc_rights` (`ro`, `rw`), its row word `links none`, which
  `abi/services/media.txt` carries too, and the limits `svc_wait_max`
  5,000 ms, `svc_status_max` 65,536 bytes and `svc_ctl_max` 4,096 bytes.
* **Manifest**: the `start` and `machine` service rows, and every
  service tree of a configured domain (`bluetooth`, `wifi`), name
  `interface svc`. The manifest check refuses a service of interface
  `svc` named like another or like a principal, and a facet row granting
  one to the system domain.
* **Erlang, in an app's session**: `erx_svc:set_status/1`,
  `erx_svc:set_file/2`, `erx_svc:set_ctl/1` (a pid that takes
  `{erx_svc_ctl, From, Line}` and answers with `erx_svc:reply/2`).
* **Erlang, for readers**: `erx_svc_client:read(Name, File, Max,
  Deadline)`, answering `{ok, Bytes}`, `{error, Errno}`, `not_serving` or
  `timeout`; `erx_svc_client:command(Name, Line, Deadline)`, writing the
  tree's `ctl` and answering `ok`, `{error, Errno}`, `not_serving` or
  `unknown`; `erx_svc_client:open(Name, File, Modes)`; each answering
  `{error, einval}` for a `File` that leaves the tree;
  `erx_svc_status:parse/1`.
* **Namespace**: the provider kind `{facets, svc}`
  ([design-files.md](design-files.md#namespaces)), the `/svc` entry of
  every domain, and `erx_ns:mount_own/2` placing the system domain's own
  service trees at `/svc/NAME`.
* **Domain service**: the key `row => true` of a keeper's `Start`, the
  environment word `serves=svc` of a session's plan, the provide check
  of AT9, and `erx_domain:grant/4` and `erx_domain:create/1` refusing an
  `svc` facet.
* **Packages**: the template field `serves` and the `app.txt` field
  `serves`, each with the one value `svc`, in their packed records
  (`abi/manifest.txt`, `abi/formats/package.txt`), and the admitted
  package's `serves` in its registry entry.
* **The inspection schema**: the start table's path is `[svc]`, shown at
  `/proc/svc`; it has no `ntp` kind, path `[ntp]` or types
  `ntp_servers`, `ntp_last` and `net_addresses`, and its generator
  carries the check of AT1.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | Effect | Recovery |
| --- | --- | --- | --- |
| a tree's server hangs | `erx_svc_client`'s deadline | `service`, `ntpctl` and `reboot` write `timed out` and go on; the request stays at the server, within its grant's 64 in flight; a 65th waits in the client or fails `emfile`, still within the deadline; `cat` waits until `Ctrl-C` | the server's restart, which ends its grants |
| a server answers a command after the deadline | the deadline | the caller reports `unknown`; the command may have taken effect | the operator reads `status` and decides |
| a handler or server ends with a command in flight | the write's `eio` | the caller reports `unknown`, as at the deadline; the command may have taken effect | the operator reads `status` and decides |
| a status is longer than `svc_status_max` | the reader's extra byte | the lines of the first `svc_status_max` bytes show, then `[partial]` | the server's fix |
| a server writes a malformed status | `erx_svc_status:parse/1` | that line shows `[invalid]`; the others show | the server's fix |
| a server serves a link | the resolver | `eacces` for any operation that would follow it | none needed |
| a server ends | the facets' ends | `/svc/NAME` is gone; open descriptors answer `eio` | the keeper's or the domain service's restart |
| a session reports `svc` it may not provide, or under a name a service of the manifest holds | the provider rule | refused, logged and counted; the session runs on without a tree | the template's or package's declaration; the app's rename |
| an introduction is refused, the machine's `max_connections` reached | the introduction | the record fails for the pair and is logged; `/svc/NAME` is absent there | either side's restart; the build's count ([What the grants count](#what-the-grants-count)) keeps each domain's own quota from refusing it |

## Refusals

| Request | Answer |
| --- | --- |
| a path under `/svc` for a tree the domain does not hold | `enoent` |
| a write to `ctl` through a read-only grant | `eacces`, from the grant, before the server |
| an operation that would follow a link in a service tree | `eacces`, as FreeBSD's `nosymfollow` |
| a create, remove or rename in an app's tree | `eacces` |
| `service NAME start`, `stop`, `restart`, `enable`, `disable` or a `one` form, for a system or domain name or a configured domain | `NAME is part of the system: it starts at boot and is not started or stopped`, status 1, nothing written |
| `service NAME CMD` where `/svc/NAME` has no `ctl` | the usage line, status 1 |
| `service NAME ...` for a name the session cannot resolve | `NAME: no service of that name in this session`, status 1 |
| an app whose name is a principal's, a domain's, a service's or a facet row's | refused at admission |
| a session's provide of `svc` under a name a service of the manifest holds | refused, logged and counted |
| `erx_domain:grant/4` of an `svc` facet, or a create spec naming one | `einval` |
| a manifest with two services of interface `svc` of one name, one named like a principal, or a facet row granting one to the system domain | the manifest check fails the build |
| `/machine`, `/etc/start`, `/bluetooth`, `/net/wlan0` | `enoent`: no other path reaches a service tree |

## Security

* **Who may read and command.** Each tree's holders are its own: every
  session whose template holds `start`, and no other, holds each serving
  app's tree with the rights of its `start` grant (AT8); a manifest
  service's tree is held by its facet rows' grantees with their rows'
  rights. `/svc` is one directory over many grants, not a grant: holding
  `/svc/bluetooth` gives nothing on `/svc/machine`, and a session that
  holds no `machine` grant has no `/svc/machine` and learns nothing of
  who else holds one. Seeing `/svc/NAME` shows that the session reaches
  the tree, not that it may write its `ctl`. A pairing app whose
  template holds `bluetooth` and not `start` sees `/svc/bluetooth` and
  no app's tree.
* **Tree access is not inspection access.** A session's grant of a tree
  gives it the tree's files and nothing of `/proc`: `service NAME
  status` shows a serving domain's state only where the session's own
  inspect scope reaches its record
  ([design-live.md](design-live.md#the-inspect-service)), and
  `/proc/svc` lists start rows alone, so moving a tree to `/svc` widens
  no inspection.
* **What a grant gives an app.** The app sees the grantee's principal
  and rights in its mint request, the requests on its own tree and the
  lines written to its `ctl`. Each request also hands it two names of the
  reader's domain: the request's alias, which takes one reply and then
  ends, and its fid's owner, the process whose end clunks the fid
  ([design-files.md](design-files.md#fid-owners)). That owner is the
  reading process `erx_svc_client` spawns, the process of an Erlang
  program that opened the file, such as `cat`'s, or, for a native
  program, its open-file description's process or its handler, one per
  program. A name handed to another domain gives it `send` on the name
  and nothing more
  ([design-domains.md](design-domains.md#exports), "Handing out a name"): the app may
  message the process and monitor it, and cannot link to it, kill it or
  set its group leader. Every message it sends arrives as
  `{erx_origin, D, Msg}`, and no protocol of the reader's session admits
  one from an app but the file protocol's reply at a live alias, so a
  message acts on nothing. A flood waits in the target's queue until its
  queue quota pauses the app's own lane or its `max_heap_size` ends it
  ([design-domains.md](design-domains.md#security)), and each of these
  processes lives only as long as one read, one command, one open file
  or one program, so the most a hostile app does with them is end a
  program that reads its tree, which it can already do by never
  answering until `Ctrl-C`. A monitor tells the app when such a process
  ends, which its requests' clunks already tell it. The app reaches
  nothing of the reader's namespace and holds no capability of the
  reader's. This exposure is accepted: removing it would put a relay
  process of the reader's in front of every request, to protect
  processes that end with the read. A configured domain's tree hands its
  server the same names.
* **Names.** NAME is set by the domain service, never by a server: an
  app's admitted name or a service row's name (AT2), and no two trees
  share one (AT9). A tree that is not served has no directory, so
  nothing stands in its place; and since `service` resolves the
  system's names first, a line meant for a system tree never reaches an
  app of the same name.
* **Links.** A service tree cannot redirect a reader: no link in it is
  followed through any entry (AT4), so `echo x > /svc/NAME/ctl` writes
  the tree's `ctl` or fails, and never reaches `/etc/start.conf`. This
  holds for a configured domain whose server parses a stranger's input,
  as the Bluetooth domain's does, as it holds for an app.
* **Code.** Nothing in a service tree runs (AT5).
* **Old grants.** A grant ends with the server that minted it, so a
  restarted server's readers reach only the new tree, and only by a new
  open (AT3).
* **Waiting.** No system command waits on a tree beyond the deadline it
  gives (AT6). What a hung server holds is its own: the grant process,
  its requests and its fids are the serving domain's memory.
* **Text.** `service` and `ntpctl` show a tree's words only as lines the
  parser accepted, each one display-safe by the field escape's
  construction (AT7). `cat` passes a file's bytes unchanged, as on UNIX,
  where root's `cat` of a file another user wrote shows whatever it
  holds; a hostile app can send controls to the terminal of an
  administrator who `cat`s its file, as any principal can through a file
  in its home ([Decisions](#decisions), 2).
* **Trust at a glance.** `/svc` holds the trusted base's trees beside a
  radio-facing domain's and an app's; `service -l` prints each name's
  kind, so a reader knows which it is reading.
* **Cost an app imposes.** One connection to each administrator session,
  paid from both sessions' budgets
  ([design-domains.md](design-domains.md#introduction-and-connection-down))
  and counted against both sides' `connections` quotas by the build
  ([What the grants count](#what-the-grants-count)), and only for an app
  whose template or package declares `serves svc`.
* **The trusted base** reads no bytes of another domain's tree: the
  system domain holds no `svc` grant, and mounts only its own `start`
  and `machine`.

## Verification and testing

Each test is paired with the fault that proves the code ran.

* **The status format.** Host properties of `erx_svc_status`: every list
  of identifiers and binaries `set_status/1` renders parses back to
  itself; a raw tab or newline inside a value, a raw `0x1b`, `\x41`, a
  lone backslash, a name outside the identifier form, a repeated name and
  a last line without a newline each give `invalid`; an input of
  `svc_status_max` + 1 bytes ends with `partial`, and so does one whose
  byte `svc_status_max` follows a newline. Seeded: a parser that accepts
  a raw `0x1b` in a value; the property finds it.
* **Fuzz target** `erx_svc_status:parse/1`, landing with it, whose
  oracle is that every value it accepts is accepted by
  `erx_text:unescape_field/1` and holds no byte the line escape changes.
  Seeded: the same raw `0x1b`.
* **A cut status through the reader.** A test app sets a status of
  `svc_status_max` + 100 bytes whose first `svc_status_max` bytes end
  with a newline. `service app status` shows those lines and ends with
  `[partial]`. Seeded: `erx_svc_client:read/4` reading at most `Max`
  bytes; the output has no `[partial]`.
* **A link in a service tree is not followed.** In hosted mode and in
  the QEMU suite, a test app, and a stub configured domain whose service
  row names `svc`, each serve `ctl` as a link to a file of root's,
  `/tmp/target`. For each, `echo x > /svc/NAME/ctl` and
  `cat /svc/NAME/ctl` answer `eacces`, `/tmp/target` is unchanged, and
  `ls -l` shows the link. A bind of `/svc/NAME` at `/mnt` and a facet
  mount of the stub's facet at `/mnt/x` refuse the same, and a mount by
  the session's own code of the app grant's pid, taken from its
  registry, is refused with `einval`. Seeded: `svc.txt` without
  `links none`; the test finds `x` in `/tmp/target`. Seeded: the mark
  taken from the `/svc` provider instead of the interface; the bind and
  facet-mount cases follow the link. Seeded: a grant mount that takes any
  pid; the mount case follows the link.
* **An own service tree is marked.** A host test of `erx_facets:table/1`:
  an entry `mount_own/2` made for `machine`, and a bind of it at `/mnt`,
  are marked, and one made for `apps`, of interface `files`, is not. Seeded: `mount_own/2`
  mounting the grant as a plain `{Pid, Tree, Rights}` entry; the
  `machine` entry and its bind come out unmarked.
* **The listing shows what is held.** A session template granted
  `bluetooth` by a facet row and not `start` lists exactly `bluetooth`
  under `/svc`; one granted neither `machine` nor `bluetooth` finds
  `/svc/machine` `enoent`; root's lists `bluetooth`, `machine`, `start`
  and each serving app. Seeded: the provider listing facets whose name
  is a pair, the old rule; the first session lists nothing. Seeded: the
  provider listing the manifest's services instead of the registry's
  facets; the second finds `/svc/machine`.
* **Rights per grant.** A session holding `bluetooth` `ro` and `machine`
  `rw`: `echo forget all > /svc/bluetooth/ctl` answers `eacces` with the
  stub's count 0, and a write to `/svc/machine/ctl` in a stub coordinator
  reaches it. Seeded: the entry's rights taken from the session's
  `start` grant; the `machine` write is refused.
* **A stale grant after a restart.** A test app sets `status` to its
  session's name. The test opens `/svc/app/status`, restarts the app,
  reads the old descriptor (`eio`), opens again and reads the new
  session's name. Seeded: the domain service keeps the first session it
  accepted as provider instead of the row's current one; the test reads
  the old name, or the open fails.
* **A `onestart` session serves.** On a disabled row, `service app
  onestart`; `/svc/app/status` reads, `service app status` shows the
  row's record and then the app's words, and `service app ping` reaches
  the handler, whose count is 1. Seeded: `service` writing to `ctl` only
  for a row `/proc/svc` shows `running`; the command prints `app not
  running?` and the count stays 0.
* **A hung server does not hang `service NAME status`.** A test app,
  and a stub configured domain, each of whose servers stops answering
  after its first read. `service NAME status` returns within
  `svc_wait_max` plus 1 s, writes `timed out` to standard error and the
  rest to standard output; run 70 times, every run still returns within
  the bound. Seeded: `service` reading `/svc/NAME/status` in its own
  process; the test's deadline fails, and the chokepoint check of AT6
  fails on the source.
* **The chokepoint.** The source check that only `erx_svc_client` names
  `/svc` among the shell's, the commands' and the start service's
  modules. Seeded: `erx_cmd_reboot` writing `/svc/machine/ctl` with
  `file:write_file/2`; the check fails the build. A host test of the
  client: `read(<<"app">>, <<"../start/ctl">>, ...)`,
  `read(<<"app">>, <<"/etc/passwd">>, ...)` and
  `command(<<"a/b">>, ...)` answer `{error, einval}` and open nothing.
  Seeded: a client that joins `File` unchecked; the first call reads
  `/svc/start/ctl`.
* **A command cut off is not repeated.** A test app's handler sleeps past
  `svc_wait_max`, then counts the command. `erx_svc_client:command/3`
  answers `unknown`, and the count is 1 after the handler finishes.
  Seeded: a client that writes again after `timeout`; the count is 2.
* **A command whose handler acts and ends.** A test app's handler counts
  the command and exits without answering. `erx_svc_client:command/3`
  answers `unknown`, `service app ping` prints `outcome unknown` with
  status 1, and the count is 1. Seeded: a client that answers `eio` as
  `{error, eio}`; `service` prints the errno's text instead.
* **`service NAME CMD` answers from the write.** A test app whose
  handler answers `ok`, `{error, eperm}` and a sleep past
  `svc_wait_max`: `service` exits 0, prints `eperm`'s text, and prints
  `outcome unknown`, each failure with status 1; `service ntpd reload`,
  ntpd having no `ctl`, prints the usage line; `service NAME enabled`,
  `delete`, `poll`, `forcereload`, `quietreload` and `fastping` never
  reach the handler, whose count stays 0. Seeded: `service` forwarding
  every prefixed word; the count is 1.
* **Purge after removal.** In root's session, with a test package
  installed, serving a tree whose `ctl` handler counts, then removed:
  `service app purge` exits 0 and the app's data directory is gone;
  `service app purge` while the package is installed answers the
  package process's refusal with status 1, and the handler's count stays
  0 throughout. Seeded: `service` resolving the name before `purge`; the
  purge after removal prints `no service of that name`. Seeded: `purge`
  left out of `service`'s own verbs; with the package installed the
  handler's count is 1.
* **The system shell's own names.** In the system domain's command
  shell: `service -l` prints `start` and `machine` as `system`;
  `service start status` and `service machine status` write
  `start is part of the system` and `machine is part of the system`.
  Seeded: the resolver reading the registry alone; `service -l` prints
  neither and `service start status` answers `no service of that name`.
* **A system name's own verbs and refusals.** In root's session with a
  stub `bluetooth` tree: `service bluetooth forget all` writes
  `forget all` to `/svc/bluetooth/ctl`; `service bluetooth stop`,
  `restart`, `enable` and `onestart` print the refusal with status 1
  and write nothing to `/svc/start/ctl`, whose stub counts 0. Seeded:
  `service` taking a service's verbs for start rows only; the first case
  prints `bluetooth not running?`. Seeded: `service` writing a run verb
  for any name; the stub's count is 1.
* **`service` needs no `start`.** A session template granted
  `bluetooth` and neither `start` nor the start table's inspect scope:
  `service bluetooth status` writes `bluetooth is part of the system`
  and the tree's lines, and no domain state. Seeded: `service` declaring
  `-erx_needs([start])`; the command is refused before it runs. Seeded:
  `service` reading `/proc/domains/ID` without checking the answer; it
  prints a refusal as a state.
* **System names first.** A manifest with an svc service `wifi` and,
  after an update, an admitted app named `wifi` whose provide was
  refused: `service wifi scan` in root's session writes to the system
  tree's stub, and the app's handler counts 0. Seeded: `service`
  resolving start rows first; the app's handler would be asked, and the
  provide refusal removed makes it count 1.
* **Rights follow `start` for apps.** A session whose template's `start`
  grant is read-only: `/svc/app/status` reads, and
  `echo x > /svc/app/ctl` answers `eacces` with the handler's count 0.
  Seeded: the domain service granting `rw` to every holder of `start`;
  the count is 1.
* **`reboot` reaches `/svc/machine`.** In root's session, `reboot` ends
  the machine through `/svc/machine/ctl`; in a session without the grant
  it fails naming `enoent`. Seeded: `reboot` writing `/machine/ctl`; the
  first case fails.
* **The system domain's own trees.** The system domain's shell lists
  `machine` and `start` under `/svc`, and `service start status` and a
  write through `/svc/start/ctl` work there. Seeded: `mount_own/2`
  taking its point from `place/1`; the mount fails at boot.
* **Messages from an app to its readers.** A test app sends 10,000
  messages to, and monitors, each fid owner and alias its requests name,
  during `service app status`, `cat /svc/app/status` and a native
  program's read of the file. Each reader shows what it shows with no
  messages, and no other process of the reading session receives one.
  Seeded: an `erx_svc_client` reader that takes any `{erx_origin, _, _}`
  message as its reply; `service` shows the app's message.
* **The provider rule.** Host tests of the domain service: a report
  providing `svc` from a plan without `serves=svc`, from a session no
  keeper started for the row (a start without `row`), with a mint of
  another domain, naming another service, or under a name the running
  manifest gives a service of interface `svc`, is refused and counted.
  Seeded: the plan check removed; the first case installs `/svc/NAME`.
  Seeded: the reserved-name check removed; the last case installs it.
* **No service tree is passed on.** `erx_domain:grant/4` of a session's
  `bluetooth` facet to another domain, under `bluetooth` and under
  `machine`, and `erx_domain:create/1` with a spec whose `facets` names
  it, each answer `einval`, and the target's `/svc` lists nothing.
  Seeded: `grant/4` refusing only another name; the target lists
  `/svc/bluetooth`, and `service -l` there shows it as `system`.
* **A package's declaration reaches its session.** An image package
  declaring `serves svc` and one that does not: the first session's
  environment holds `serves=svc` and `/svc/NAME` appears; the second's
  does not and its report provides nothing. Seeded:
  `erx_dom_plan_app_session` leaving the word out; the first app has no
  tree.
* **The manifest checks.** A manifest with two services of interface
  `svc` named `wifi` on two servers, one with an svc service named like
  a principal, and one with a facet row granting `bluetooth` to the
  system domain each fail the build; a template that holds `start` with
  a `domains` quota of 4 beside a serving template whose `connections`
  quota holds 3 administrator sessions fails the build. Seeded: each
  check removed in turn; its manifest passes.
* **Admission.** A package named `bluetooth` on a manifest with that
  service is refused at admission. Seeded: the service rows left out of
  the reserved names; it is admitted.
* **Escape at display.** A test app whose status holds an invalid line
  with a raw `0x1b`: the captured output of `service app status` holds no
  `0x1b` and shows `[invalid]`. Seeded: `service` printing lines it did
  not parse.
* **AT1.** The schema generator refuses a seeded `kind` reported by
  `runtime` at a machine path, the `ntp` row as it stood.
* **ntpd.** The QEMU suite's ntpd case reads `/svc/ntpd/status` during a
  resolution that the test peer delays by 8 s, and gets an answer at
  once. Seeded: `erx_svc`'s read callback asking ntpd's loop; the read
  times out ([design-time.md](design-time.md#verification-and-testing)).

## Order of work

Each step lands with its tests and seeded faults above, none waits on a
later one, and none leaves a command that worked before it broken: a
path moves in the same step as every reader and writer of it.
[todo-apps.md](todo-apps.md) ("Service trees at `/svc`") tracks the
steps.

1. **The interface.** `abi/services/svc.txt` with `svc_rights` and the
   three limits; the row word `links none` in the services grammar, on
   `svc` and `media`, and `erx_facets:table/1` marking from the word
   instead of from the `media` interface.
2. **The manifest.** The `start` and `machine` service rows name
   `interface svc`; the manifest check's three refusals (AT8, AT9). The
   trees stay where `place/1` puts them until step 4.
3. **The client.** `erx_svc_client` with `read/4`, `command/3` and
   `open/3`, its refusal of a `File` that leaves the tree, and the
   chokepoint check of AT6. No command calls it yet.
4. **The paths, with their callers.** In one step: the `/svc` entry with
   `{facets, svc}` selecting by interface in every domain, in
   `erx_ns:mount_facets/1`; `place/1` loses its `start` and `machine`
   rows; `mount_own/2` places a service of interface `svc` at
   `/svc/NAME` and keeps its name as the entry's provider, and
   `erx_starter_fs` and `erx_machine_fs` keep calling it; and every
   writer of the old paths moves with them: `reboot` and `halt` write
   the machine's `ctl` through the client, `service` writes the start
   table's `ctl` through it, and the guide and README name
   `/svc/start` and `/svc/machine`.
5. **The inspection path, with its readers.** In one step:
   `abi/inspection.txt`'s start-table paths become `[svc]` and
   `[svc, Name]`, and every reader of `[apps]` (`service`, the start
   service's tests, the find-and-act palette) and the guide and README
   follow.
6. **`service`'s names.** `service` drops its blanket
   `-erx_needs([start])`, resolves names in the order above, the system
   domain's own mounts among them, shows system and domain names,
   refuses run verbs for them, takes `purge` as its own verb, and gains
   `-l`. Before this step, confirm how a tree's facet leads `service` to
   its serving domain's record at `/proc/domains/ID` (the facet's node and
   `boot_order`'s names); where nothing does, `status` of a system or
   domain name shows the tree's words alone.
7. **The domain service.** `erx_domain:grant/4` and a create spec's
   `facets` refuse an `svc` facet. The app trees (`erx_svc`,
   `erx_svc_status`, the provider rule with its reserved-name refusal,
   the grant records) are built by the item of
   [todo-apps.md](todo-apps.md) against this design, installing app trees
   with the `svc` interface's number.
8. **Other designs' trees.** The Bluetooth design places its control
   tree at `/svc/bluetooth` with `interface svc` and declares no
   interface of its own, and its controller's line moves from `/line` to
   `/dev/line` when that code is next touched; the WiFi domain's `wifi`
   tree is `/svc/wifi`; a drive's `status` and `ctl` move to
   `/svc/media` only by a design of their own (`TODO.md`).

## Alternatives considered

* **A root for each subsystem**: `/machine`, `/etc/start`,
  `/bluetooth`, `/net/wlan0`, each defensible alone. Together they make
  a user learn a place for each thing, and each new subsystem adds one.
* **Only move the mount points**: rows of `place/1` at `/svc/bluetooth`,
  `/svc/machine` and `/svc/start`, with no interface. It gives the same
  paths, but the table gains a row for every tree, the link rule still
  needs an interface for each tree a stranger can reach, and nothing ties
  a tree's name to its server.
* **Everything under `/dev`**, as QNX places a service's endpoint: a
  protocol stack or the start table is not a device, and a FreeBSD user
  would try `ioctl`, `dd` and `devctl` on what is there.
* **A `/sys`-like tree** of every object's readable and writable
  attributes: it would merge `/proc`, whose gate is the inspect scope and
  whose content the system vouches for, with trees whose gate is a grant
  and whose content is one party's word.
* **`/var/run/NAME`** or **`/srv`**: each wears a name that promises
  something else, pid files and sockets on FreeBSD, posted channels on
  Plan 9.
* **Run verbs for configured domains**, so `service bluetooth stop`
  stops the domain: no design gives a configured domain a stopped state,
  and every client of every domain would have to handle an absent server
  for good. A `restart` would add no state, since a fault already takes
  that path, but it would give whoever holds `start` the power to end the
  storage or display domain, which only a fault or `/svc/machine/ctl`
  has.
* **Configured domains under `/proc/svc`** beside start rows: a second
  path to each `/proc/domains/ID` record, with another field set and
  another visibility rule.
* **The read and write split**: an app's status as typed records under
  `/proc/svc/NAME/NODE` through the inspector, its commands in a tree
  of its own. The inspector would have to route a path to an app's
  runtime, which needs a way to find the app's domain and an agent bound
  that admits paths outside it, and install-time declarations of each
  app's nodes and types; an app's words would live in two places with
  two gates. Typed does not mean truthful: a record an app reports is
  its word whatever its type.
* **Typed app kinds in `abi/inspection.txt`**, as `ntp` is: every app
  would edit erXos's schema, which an app installed at run time cannot,
  and the routing above is still missing.
* **Service trees mounted under `/proc/svc/NAME/`**: `/proc` is a
  read-only view rendered in the reader's runtime, every field escaped;
  a served tree there would break both promises under the same name.
* **One mount per tree**: a table entry for each `/svc/NAME`, mounted and
  unmounted as facets come and go, against `ns_mounts_max` of 64 and up
  to 256 start rows. The `{facets, svc}` directory takes one entry and
  follows the registry with no table change.
* **`nosymfollow` as an entry option**, or as the `/svc` provider's
  rule: every other way to reach a tree, a facet's mount and a bind
  among them, would have to be listed and kept from dropping it. As the
  interface's word it comes with every grant.
* **Every service tree keyed as `{svc, Name}`**: commands name the
  manifest's facets by atom (`-erx_needs([machine])`), and the
  installation of a configured domain's facet under its service's name
  would gain a case. The listing writes both forms as one name.
* **The newest session as an app's provider**: a name could have two
  providers while an old session ends, and an older survivor would
  become provider again without reporting. The row's current session,
  which the start service already keeps one of, needs no choice.
* **Re-grants of a tree to domains AT8 admits**: every such domain
  already holds the tree under the domain service's own record, so a
  re-grant would only replace that facet with one of the system domain
  in front of it, whose node no longer tells `service` the tree's
  server. Refusing every `svc` facet in `grant/4` costs nothing a
  holder needs.
* **A client that takes paths**: every caller would build `/svc/...`
  itself, which the chokepoint forbids it to write, and could build a
  path outside the tree it means. Taking a service name and a file of
  its tree puts the one join, and its check, in the client.
* **A relay in the system domain** that reads service trees and serves
  checked text: puts an untrusted parser and a waiting hop in the trusted
  base, and still needs the deadline.
* **An app's own `erx_fs` callback module** as its tree: every read would
  run app code, so a busy app would stall its own `status`, as a call into
  an app's main loop stalls while the loop is busy, and each app would
  have to get the server's bounds right. The flat tree `erx_svc` serves
  from what the app set does neither.
* **`Tflush` as the deadline**: a server that hangs answers no flush
  ([design-files.md](design-files.md#flush)); ending the reading process
  is the bound that needs nothing from the server.

## Decisions

1. **One grant of an app's tree to every session that holds `start`,
   with that grant's rights.** Whoever may command the start table,
   through a writable `start` grant, both reads and commands every app's
   tree; a read-only `start` grant reads it. A wider set of readers would
   take a second grant record and a policy of who reads; a wider reader
   is a later consumer's to ask for.
2. **`cat` of a tree's file passes its bytes.** An app's controls reach
   the terminal of an administrator who `cat`s its file, as with any file
   another principal wrote, and the administrator's documentation says
   so; `service` and `ntpctl`, which show a service's words under its
   name, escape them ([What the commands show](#what-the-commands-show)).
   A tree whose reads are filtered on the reader's side would make `cat`
   lie about a file's bytes.
3. **`service NAME CMD` reaches a service's own commands.** As FreeBSD's
   `extra_commands` let `service NAME reload` run a script's own verb,
   `service` writes a verb that carries no rc.subr prefix and is none of
   rc.subr's keywords, with its arguments, to `/svc/NAME/ctl`, for every
   kind of name ([What the commands show](#what-the-commands-show)).
4. **App grants follow the ready reports.** Every session that holds
   `start` is introduced to every serving app by the two sessions' ready
   reports, one connection each from both budgets
   ([Granting](#granting)), which the build counts against both sides'
   quotas ([What the grants count](#what-the-grants-count)) and which
   needs no new request; a grant made at the first walk of `/svc/NAME`
   would need one, a request to the domain service. What the connections
   cost is a watch-list item ([todo-performance.md](todo-performance.md)).
5. **Every service tree is at `/svc/NAME`.** Apps', configured domains'
   and the system domain's alike, named after the service row, with
   `/proc/svc` listing start rows alone; configured domains take no run
   verb, and `restart` is not offered for them.

## References

* [CLAUDE.md](../CLAUDE.md), "No new mechanism without a design that
  names it".
* [design.md](design.md#decisions), the three homes.
* [design-live.md](design-live.md#the-proc-tree), [design-apps.md](design-apps.md#interfaces),
  [design-system.md](design-system.md#facets-a-configured-domain-serves),
  [design-files.md](design-files.md), [design-drives.md](design-drives.md#links-and-rights),
  [design-packaging.md](design-packaging.md#the-declaration),
  [design-time.md](design-time.md#what-ntpd-serves), [design-shell.md](design-shell.md),
  [design-domains.md](design-domains.md#exports).
* FreeBSD releng/15.1, commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`,
  from the project's GitHub mirror,
  `https://raw.githubusercontent.com/freebsd/freebsd-src/`:
  * `sbin/mount/mount.8`, SHA-256
    `a9f016233c54d5fb8b3c0e63f8b4af754101c375f4de60648326db29759dd689`;
  * `sys/kern/vfs_lookup.c`, SHA-256
    `d1e4ccd344058b5fe02f3d54b8c219848a6390d69b9a1bb4c4d6da899b354546`;
  * `libexec/rc/rc.subr`, SHA-256
    `f934e89957223f4816821a3ccf2e8f476d28d906358cdf06cfd6db65ab44cbb1`;
  * `libexec/rc/rc.d/root`, SHA-256
    `249896b31400d0ceafe06d48f5376469a6aba8b7bb3909295e2eddcebbe74362`;
  * `libexec/rc/rc.d/dmesg`, SHA-256
    `e50b47786fb8faaca5763e28ea86a80ba83cb18c56be72b5f98e04ba99ca7841`;
  * `usr.sbin/service/service.8`, SHA-256
    `2135a3079352a0af96c429ef3ffeb518c28b4107ee5d53ff94279d407787bd35`;
  * `share/man/man7/hier.7`, SHA-256
    `87f5a93566fd961f57da2eb24be443d00740d33bcdd6ddd5693e40e057580750`.
