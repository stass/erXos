# The system log

Every log event of the machine, the kernel's records and every domain's
logger events, reaches one service, the **log service**, `erx_syslog`,
in the system domain. It stamps each event, holds each domain to its
rate, escapes its text, and hands the resulting line to two consumers:
the console, which writes it on its lines, and the store, which appends
it to files. Everything else reads the files: the system domain serves
them at `/var/log` as an ordinary file tree, so `cat /var/log/messages`,
`tail -f /var/log/messages` and `grep` work as on UNIX. This document is
the contract: who writes, what a line is, where it is kept, who may
read what, what happens under load and failure, and how it is tested.

Decisions every reader needs:

* **Writing is one facet with one operation.** A domain's logger events
  go to its **log facet**, an instance of the `log` interface, whose one
  operation is `write`. The facet forwards each `write` to whichever
  `erx_syslog` is running, so a restart of the service ends no facet. A
  domain with no terminal still logs ([Writing](#writing)).
* **The line is the service's.** The service renders every line from the
  time it took it, the level, the grantee's id, principal and name, and
  the text through the line escape. Nothing a domain sends chooses its
  time, its source or an unescaped byte ([The line](#the-line)).
* **Reading is files.** `erx_logfs`, a read-only tree with fixed names,
  serves the stored bytes as they are at `/var/log`. There is no read
  operation and no log command: UNIX's tools are the readers
  ([The file tree](#the-file-tree)).
* **A consumer asks for each batch.** The console and the store's writer
  each receive lines only as the answer to their own request, so each
  holds at most one batch and the service keeps no record of a batch it
  has sent ([Consumers and backlogs](#consumers-and-backlogs)).
* **Each batch is written by a process of its own**, which opens the
  files as the namespace resolves them then, ends a cut last line,
  rotates, appends, syncs, closes and ends. Nothing is kept between
  batches, and a failed batch is counted and never repeated
  ([The writer](#the-writer)).
* **The kernel ring has one consumer.** The service is the only caller
  of `erx_log:take/0`, which moves the ring's one taken position that the
  early console also moves; the inspector reads without taking
  ([The kernel's records](#the-kernels-records)).
* **The kernel's lines are stored apart**, in a directory only the
  system domain's `/var/log` shows, as `/proc/kernel/log` answers only
  scope `all` ([The store](#the-store)).

## Context

The log stands on the kernel's 64 KiB ring, which the inspector reads
without taking (`erx_log_records.erl`) for `/proc/kernel/log` and
`dmesg`, and on the console's lines
([design-live.md](design-live.md#the-console), Logs). This design
keeps the ring and its two reads, `erx_log_h`'s formatting, the line
escape
`erx_text:escape_line/1`
([design-live.md](design-live.md#attributed-text)), facets, `erx_fs`
trees and littlefs at `/data`.

FreeBSD's syslog, read for this design at the `release/15.1.0` tag of
`freebsd-src`: `syslogd(8)` reads the kernel's messages from `/dev/klog`,
appends each message to the log files `syslog.conf` names, appending
only to files that exist unless `-C` is given, and takes a message's
time from the message itself unless `-T` is given; `newsyslog(8)`
rotates a file so that `logfile` is empty, `logfile.0` holds the last
period and so on up to a count; `newsyslog.conf` rotates
`/var/log/messages` when it reaches 1000 KB, and at the start of each
year, keeping 5 archives compressed with bzip2, mode 644, and notes that
some sites consider `messages` confidential and restrict it;
`newsyslog.conf(5)` says the count "does not consider the current log
file"; `dmesg(8)` says of `-a`: "Show all data in the message buffer.
This includes any syslog records and `/dev/console` output." Each file's
SHA-256 is in [References](#references).

## Requirements

1. **One writer facet.** A domain's log events reach the service through
   one declared facet with one operation, with or without a terminal,
   and the facet outlives a restart of the service.
2. **Attribution.** A line's time and source are the service's; a domain
   chooses only its own text.
3. **Escaping once.** A domain's text is escaped when the service renders
   its line, and the console and the store receive only rendered lines.
4. **Bounds.** A slow console line or a slow or failing medium never makes
   a writer wait; every drop is counted and shown; what the service keeps
   per domain is bounded by the domains that are logging.
5. **No line twice, none joined.** A stored line is written at most once,
   and a line cut by a failure or a power cut ends before the next begins.
6. **Files as the reading interface.** UNIX's tools read, follow and
   search `/var/log/messages`; `dmesg -a` adds it to the kernel's lines.
7. **Kernel lines stay where scope `all` reaches.** The kernel's lines are
   kept across reboots, and no tree a session holds reaches them.
8. **Retention without new storage.** The store is a directory of the
   data partition, or of the system domain's `/tmp` without one, rotated
   by size with a fixed count that fits the medium.
9. **The emergency path stays.** The kernel's early console and panic
   report, and the system domain's emergency output, do not depend on the
   service, and no crash of the service ends the machine.

## Overview

```text
 kernel log ring --take/0, every 100 ms--+
                                         v
 domain D: logger -> erx_log_h -> proxy --write--> D's log facet --+
                                                                   v
 system domain: logger -> erx_log_h ------------------------> erx_syslog
                                                     render, rate, escape
                                                   (erx_syslog_core, pure)
                                                       |            |
                                          console backlog      store backlog
                                                       ^            ^
                                              next batch|           |next batch
                                                       v            v
                                                 erx_console   erx_syslog_writer
                                                 its lines     a process per batch:
                                                               open, repair, rotate,
                                                               append, sync, close
                                                                    |
                                       store: /data/log or /tmp/log v
                                         messages, messages.0 ..
                                         kernel/messages, kernel/messages.0 ..
                                                                    |
            erx_logfs: the stored bytes, read-only, fixed names     |
              sessions' /var/log (`varlog`): the messages family <--+
              the system domain's /var/log: both families
```

`erx_syslog` is one `gen_server` under a supervisor of its own,
`erx_syslog_sup`. Its pure core, `erx_syslog_core`, decides the rate,
the line each record renders to, the backlogs, their drops and when a
waiting consumer's batch is due; the process does the effects, the
takes, the clock and the answers, and touches no file. The store's one
writer, `erx_syslog_writer`, hands each batch to a process of its own,
which makes the file calls its pure core, `erx_syslog_writer_core`,
plans. `erx_logfs` serves the store read-only. All run in the system
domain.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **L1.** A line's time and source are the service's | `write` carries a list of levels and texts and nothing else; the log facet's callback forwards it as `{write, Grantee, Records}`, with the grantee bound when the facet was minted, and the service takes the principal and name for that id from the domain service; the service reads the time when it takes the batch | a `write` with a source or time field; a facet that forwards a source from the request | a domain whose text imitates another domain's line head appears under its own id, principal and name; a seeded facet that copies a source from the request fails it |
| **L2.** No line holds a byte the line escape would not pass | `erx_syslog_core:line/5` is the one function that turns a domain's text into a line, and passes the name and the text through `erx_text:escape_line/1`; the kernel's lines arrive escaped by the kernel, as printable ASCII ([design-kernel.md](design-kernel.md#console-log-and-panic)); the console and the writer receive only lines the core made, and the writer stores nothing else | a second renderer; a consumer handed a record instead of a line | every C0 and C1 control, `Cf`, `Zl`, `Zp`, default-ignorable and invalid UTF-8 class, and every CSI, OSC, DCS, APC, PM and SOS form, as a record's text, reads as tokens on the console's line and in `/var/log/messages`; with the escape removed from `line/5` the test fails |
| **L3.** No writer waits on a consumer | a consumer receives a batch only as the answer to its own request for the next one, so it holds at most one; lines for it wait in its backlog, which is bounded by bytes and drops its oldest lines past the bound, counted; a `write` is answered when the service has taken it, never when a consumer has | a write answered after a consumer has written the lines; an unbounded backlog; a batch sent without a request | a console driver that never answers and a store that never answers, while domains write at their rate for a minute: every `write` answers within its facet's deadline and the service's heap stays within its bound; a seeded unbounded backlog fails on memory |
| **L4.** Each kernel record is taken once, by the log service | `erx_syslog` is the only caller of `erx_log:take/0`, which a build check holds; the take and the early console move the ring's one taken position, so a restarted service takes on from where the last take stopped and nothing the early console wrote is taken again ([design-stopgap.md](design-stopgap.md#the-console)) | a second caller of `take/0` | a serial transcript across the handoff holds each kernel record once; the service killed between takes doubles no kernel line on the console or in `kernel/messages`; the build check with a seeded caller in `erx_console` |
| **L5.** No session's tree reaches a kernel line | the writer appends kernel lines only to `kernel/messages` and the domains' lines only to `messages`; a session's grant of `erx_logfs` serves a fixed set of names, `messages` and its archives, and never lists the store, so `kernel` is not a name in it; only the system domain's own grant serves `kernel` ([The store](#the-store)) | the writer appending a kernel line to `messages`; a session's grant that serves the store's listing or `kernel` | a session's `ls /var/log` lists no `kernel` and its `grep -r . /var/log` finds no kernel line, while the system shell reads `/var/log/kernel/messages`; a seeded tree that serves the store's directory listing fails |
| **L6.** A failing medium costs only the stored files | `erx_syslog` calls no file operation; every file call is made by a process the writer starts for one step and waits for, whose failure, error or deadline, is a value to the writer, which counts the batch's lines and goes on; the store's backlog is bounded like the console's | a file call in `erx_syslog`; a writer that crashes on a file error | the data partition's server made to fail every request and then to stop answering, for ten minutes: the console lines go on, every `write` answers, the log holds one `failed` line of the writer's, and once the server answers again the store holds `writing again, N lines not stored` and a batch that begins with `lines missed` |
| **L7.** No line is written twice, and no line is joined to another | the writer hands each batch to one process, once; each batch's process opens the files afresh and appends a newline first when a file's last byte is not one; nothing of it outlives it | a writer that retries a failed batch; files kept open across batches; an append before the repair | a server stand-in that applies a write and drops its reply, one that fails a write part way and one that fails the sync: no line appears twice in the store and each cut line ends in a newline; a seeded writer that retries its batch fails on the duplicate, and a seeded batch process that skips the repair fails on the joined line |

## Data model

### The line

A domain's record renders as `erx_syslog_core:line/5` renders it, one line:

```text
SECONDS.MICROSECONDS LEVEL domain ID principal P NAME: TEXT
```

`SECONDS.MICROSECONDS` is the time the service took the batch, from the
monotonic clock; `LEVEL` one of the logger's eight levels; `ID` the
grantee's domain id; `P` its principal's number, or `unknown` for the
system domain's own records until the domain service has named the
system principal; `NAME` the domain's name and `TEXT` the record's text,
both through the line escape. Everything before `NAME` is the service's
own text and ASCII by construction. A record's text is at most
`log_write_text_max`, 4 KiB, before escaping, as `erx_log_facet` admits it.

A kernel record keeps the line the kernel's log core rendered:

```text
#SEQ SECONDS.MICROSECONDS LEVEL TEXT
```

with the kernel's own sequence number, so a gap in the numbers shows
where kernel records were lost. A `#` never begins a domain's line, so a
reader tells the two forms apart by the first character.

The core renders a line without its ending; the console ends it in
CR-LF, as it ends every log line, and the store in LF.

The service's and the writer's own lines are the system domain's
records ([Failure handling](#failure-handling-diagnostics-and-debuggability)).

### The store

The store is one directory, which `erx_syslog_writer:store/0` names from
the system domain's namespace, for the writer and `erx_logfs` alike. Both
start after the domain service has booted, which mounts `/data` in the
system domain exactly when the system manifest grants it the `data` facet
(`erx_domain_srv.erl`, `booted/1`, `erx_ns:mount_facets/1`), so whether
the namespace holds that mount is the manifest's answer, read where it
already is; lines logged before then wait in the service's backlog
([Consumers and backlogs](#consumers-and-backlogs)):

* `/data/log`, when the system manifest grants the system domain the
  `data` facet, so the store is on littlefs in the storage domain and
  survives reboots;
* `/tmp/log` otherwise, in the system domain's own RAM file system
  ([design-tmp.md](design-tmp.md)), so a machine without a data partition
  still has `/var/log`, which lasts until the machine ends.

It holds two families of files, each a sequence of lines:

| Path in the store | Holds | Shown at |
| --- | --- | --- |
| `messages` and its archives, `messages.0` upwards | the system domain's and every domain's lines | `/var/log` in a session that holds `varlog`, and in the system domain |
| `kernel/messages` and its archives | the kernel's lines | `/var/log/kernel` in the system domain only |

**Rotation.** Each family rotates as newsyslog rotates
`/var/log/messages`: when a batch would take the current file past the
**rotation size**, the batch's process removes the archive that would
pass the **archive count**, renames each older archive up one number
from the top down, `.3` to `.4` and so on to `.0` to `.1`, renames the
current file to `.0` and begins a new current file, each step ignoring a
name that is absent. A rotation cut short can cost one archive one
rotation early. The size and the count are constants of
`erx_syslog_writer_core`, one pair for each medium:

| Medium | Rotation size | Archives | At most, both families |
| --- | --- | --- | --- |
| `/data` | 1 MiB | 5 | 12 MiB |
| `/tmp` | 256 KiB | 3 | 2 MiB |

The `/data` pair is FreeBSD's for `messages`, without the yearly turn and
the compression. The `/tmp` pair keeps the store to half of the system
domain's 4 MiB `/tmp` in the default manifests
(`config/manifest/development.txt`, `runtime_limits system`,
`tmp 4194304`), its chunks charged at 4 KiB each
([design-tmp.md](design-tmp.md)), so other users of `/tmp` keep the rest.
A store batch is at most 64 KiB, less than either size, so rotating
before the batch keeps every file within its size. The writer never
lists the directory and removes only names it made.

**Across boots.** The files continue across boots, as syslogd appends to
`messages`; a reader finds a boot by its first line, `erx_syslog:
start`. Each batch's process appends a newline first to a file whose
last byte is not one, so a line cut by a power cut or a failed write
ends before the next. Lines written since the last sync are lost at a
power cut.

**Who reaches what.** Readers reach the store through `erx_logfs`
([The file tree](#the-file-tree)). Sessions hold `varlog`, whose names
are the `messages` family's (L5); the system domain's own grant also
serves `kernel`. That is the inspector's rule for the kernel's lines, by
construction: they are readable where an inspect facet of scope `all`
answers `/proc/kernel/log`, which in a release build is the system shell
at a secure line ([design-live.md](design-live.md#inspection), Scopes).

On the stopgap a development build's `data` grant to `root`'s sessions
covers the whole of `/data`, read-write
([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)),
so those sessions can also read `kernel/messages`, which their scope
`all` already allows, and rewrite or truncate either family at
`/data/log` (TODO.md, Security residuals). In the target design each
principal's data grant is rooted at its own directory
([design-storage.md](design-storage.md)), and none reaches the store.

### The log facet

`abi/services/log.txt` declares the interface, as every interface of
`abi/services` is declared
([design-domains.md](design-domains.md#facets), The facet table):

```text
service log 9
  operation write 1
limit log_write_max u32 16
limit log_write_text_max u32 4096
```

`write` takes a list of at most `log_write_max` pairs `{Level, Text}`,
each level one of the logger's eight and each text a binary of at most
`log_write_text_max` bytes, and answers `ok` once the service has taken the
batch. The facet's decoder refuses anything else with
`{error, badarg}`, counted. The facet row's `max_request` bounds a
request's encoding and its `in_flight` the requests at once, as for every
facet; the default manifests give 16 KiB and 2.

The system manifest declares the service once, served by the system
domain. The default manifests grant `log` to every configured domain and
session template; a created domain holds it when its specification's
`facets` map hands it on ([design-domains.md](design-domains.md#facets)).

The domain service mints each log facet with the callback
`erx_log_facet`, as it mints `erx_inspect_facet` for `inspect`
(`erlang/apps/erx_domain/src/erx_domain_srv.erl`, `system_facet/4`),
naming `erx_syslog_sup` with `erx_facet:serve/2`, so a log facet ends
with the grantee's domain or that supervisor, not with `erx_syslog`. The
callback's `admit/3` decodes the request, finds `erx_syslog` by its
registered name at that moment, and forwards `{write, Grantee, Records}`
to it. `erx_facet` sends the forward as a call whose reply target is the
alias of a monitor on that process, so a service that ends before it
answers answers the caller `{error, failed}`
(`erlang/apps/erx/src/erx_facet.erl`, `forward/4`); with no `erx_syslog`
registered the callback refuses with `{error, unavailable}`. So the
facet holds no state of the service's and needs no process in front of
it.

### The file tree

`erx_logfs` is an `erx_fs` callback module served by the system domain,
as `erx_starter_fs` serves `apps` ([design-apps.md](design-apps.md#interfaces)).
Its `start_link/0`, a child of `erx_domain`'s supervisor started after
the domain service ([The store](#the-store)), starts both kinds of grant:

* **`varlog`**, an instance of `files` whose facet rows grant it to
  session templates; the default manifests grant it to `root`'s template
  alone. Its names are `messages` and its archives. The grantee mounts it
  read-only at `/var/log` on its tree `varlog`, as `/data` is mounted,
  with `erx_ns:mount_facets/1`, and a created domain names it in its
  specification's `files` map
  ([design-files.md](design-files.md#building-binding-and-mounting)).
* **The system domain's own grant**, which `start_link/0` mints and
  mounts read-only at `/var/log` in the system domain, as
  `erx_procfs:start_link/0` mounts `/proc`'s grant
  (`erlang/apps/erx_files/src/erx_procfs.erl`) and `erx_ramfs_sup`
  mounts `/tmp`'s: the tree's own supervised child mounts it, so a
  restarted tree mounts itself again and the writer serves nothing. Its names are `varlog`'s and the directory `kernel` with the
  kernel family's names.

Every release slice has an empty `/var/log` directory, as it has `/data`,
so a domain without the grant lists an empty directory there.

Each name is shown only when the store holds it, so the tree is mounted
before the store exists. While the medium answers `eio`, as `/data` does
at boot until the storage domain has installed its grant
([design-files.md](design-files.md#building-binding-and-mounting)), so
does `/var/log`, as a file system whose disk is not there. A walk,
`getattr`, `open` and `read` of a name reach the same file of the store,
in the grant's file processes with `erx_fs`'s `helper` read mode
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)), so a
stalled medium holds up that reader alone. Bytes, sizes and offsets are
the stored file's, so a reader seeks, `tail -f` follows a growing file
and `tail -F` a rotation, and a fid opened before a rotation reads the
renamed file, as on UNIX.

## Algorithms and behavior

### Writing

**The handler.** `erx_log_h` formats each event inside the logging
domain, on one line, in the calling process
([design-live.md](design-live.md#the-console), Logs), printing
`{erx_secret, _}` as `[secret]` wherever it is nested
([design-live.md](design-live.md#attributed-text)). In the system domain
it sends the record to `erx_syslog` by its registered name. In every
other domain it sends it to the domain's **proxy**, the handler's
process.

**The proxy** sends the records it holds as one `write` of at most
`log_write_max` records and 16 KiB, one at a time, waiting for each
answer. It holds at most 200 events, `logger_olp`'s drop threshold, and
drops and counts past that, never making a logging process wait; its
next batch then begins with `erx_log_h: dropped N events`, at level
`warning`. A `write` answered with an error counts its records as
dropped too. The proxy is the domain's `erx_tty_owner` when the domain
has no terminal
([design-runtime.md](design-runtime.md#the-console-and-standard-io)), so
a daemon's `erlang:display/1`, `erlang:display_string/2` and
`standard_error` become records at level `notice`, one per line, UNIX's
rule that a daemon's output goes to the log. A program's log lines are
its session's, written by the session's proxy with the program's name
first in the text ([design-programs.md](design-programs.md)).

**Where there is no service.** A record that finds no log facet, no
proxy, or no `erx_syslog` in the system domain goes into the kernel's
ring with `erx_log:debug_text/1`, as `erx_log_h` does. It is then a
kernel line, labelled with the domain's space by the kernel, and
reaches the console and the kernel's stored files through the take.

**The rate** is the service's, decided by `erx_syslog_core`: at most 16 KiB of lines per second per domain, the
rate `erx_debug_log` allows a space, each record charged its whole line,
head and escaped text, so neither empty records nor text that the escape
lengthens write more than that. Past it the record is dropped and
counted. The core keeps one table, the current second's, with an entry
for each domain that wrote in it: the bytes charged and the records
dropped. A tick of the service's 100 ms take
([The kernel's records](#the-kernels-records)) that finds the clock in a
later second renders `erx_syslog: domain ID: N records dropped`, at
level `notice`, for each entry with drops, and empties the table. So
every drop is shown on a line of its own, a domain's that has since
ended included, and the table holds at most the domains of one second.
A second is as the ticks divide it: a write is charged to the table of the
last turn, so across a turn that comes late a domain can have up to twice
the rate stored under one second's time.

### The kernel's records

Every 100 ms `erx_syslog` calls `erx_log:take/0`, which answers the
lines nobody has taken, takes them, and reports how many records the
ring overwrote before they were taken and whether a record failed the
reader's checks; while a take fills its window it takes again at once.
Each line joins both backlogs as a kernel line. A loss adds the
service's line `erx_syslog: N kernel log records lost`, and a failed
check `erx_syslog: a kernel log record failed its checks`; the kernel's
stored file shows a loss as a gap in its sequence numbers. The records
the early console wrote, and took as it wrote them, before the first
take are on the serial line and in `/proc/kernel/log`, not in
`kernel/messages`.

**The handoff.** The first take is also the handoff of the UART: until
it, the early console writes every record on the UART, moving the taken
position as it does, and from it every record waits in the ring for the
next take. On the stopgap the root service writes the early console and
sets the sink to the ring at the first take
([design-stopgap.md](design-stopgap.md#the-console)); erXos's kernel
offers the same `erx_log_take`
([design-kernel.md](design-kernel.md#console-log-and-panic)). Since both
writers move one position, no record is written twice and none is
missed, on both kernels. The console driver's first write must follow
that take, so `kernel_sup` starts `erx_syslog_sup` right after the
watchdog and before `user_sup`, which starts `erx_console` and its
driver (an edit to `kernel.erl`), and `erx_syslog`'s `init` makes the
first take. The inspector's `[kernel, log]` reads with `erx_log:read/1`
from a cursor of its own, so `/proc/kernel/log` and `dmesg` are
unchanged.

### Consumers and backlogs

The service has two consumers, the console and the writer, each a
process of the system domain. For each, `erx_syslog_core` keeps a
**backlog** of lines and whether the consumer is waiting:

* **Asking.** A consumer asks for its next batch with
  `erx_syslog:next(Role)`, sent with `gen_server:send_request/2`, so it
  waits on nothing; `Role` is `console` or `store`. The service keeps the
  request, monitors its sender and answers it with a batch when one is
  due; a request from the role's consumer while one is kept replaces it,
  and a kept request's sender that ends is dropped. So the role's state
  is `idle` or `{waiting, From}`, and that is all the service knows of
  its consumers.
* **Lines.** A line joins every backlog it belongs to: every line the
  console's, and every line the store's, tagged with its family. Both
  backlogs exist from the service's start, so the lines of the boot
  before a consumer asks wait for it there.
* **Bounds.** A backlog holds at most 1 MiB of lines. Past that its
  oldest lines go, counted, and the consumer's next batch begins with the
  line `erx_syslog: N lines missed`, which joins that backlog alone.
* **Batches.** A waiting console is sent its whole backlog as soon as the
  backlog holds a line. A waiting writer is sent at most 64 KiB of its
  backlog, oldest first, once 64 KiB have gathered or one second after the
  oldest line joined, so the medium is written in batches.
* **Owning a batch.** Once sent, a batch is its consumer's. The console
  asks again when its driver has written the batch, the writer when the
  batch's process has ended. A consumer that ends holding a batch loses
  it, which its supervisor's crash report says.
* **Across the service's restart.** A new service starts with both roles
  `idle`, so nothing of the old one's consumers is stale in it. A consumer
  whose request the old service held receives its `DOWN` and asks again
  each second until an `erx_syslog` is registered; one holding a batch
  finishes it and asks the service registered then.

The console writes each line of a batch to its lines as one write, whole,
ending in CR-LF, between whatever else is written, as a kernel message
lands on a UNIX serial console ([design-live.md](design-live.md#the-console)).
Which lines receive log lines, and the menu, login prompt and notes the
console writes itself, are the console's, unchanged.

### The writer

`erx_syslog_writer` starts after `erx_ns` and `/tmp` in `kernel`'s safe
supervisor, beside `/proc`, and `erx_logfs` after it. It makes every
file call through a process it starts for one step and waits for, at
most 60 s, well above a batch with both families rotating, after which
it kills the process. It loops:

1. **Ready.** A process makes the store's directory and `kernel` beneath
   it where absent, again each second until it succeeds. Until then the
   writer does not ask, so lines wait in the store's backlog.
2. **Ask** for the next batch.
3. **Write.** A process, for each family with lines, opens the current
   file for append, creating it, as the namespace resolves it then;
   reads its size and last byte; and makes the calls that
   `erx_syslog_writer_core:plan/4` gives for the medium, the size, the
   last byte and the lines: a newline when the file is not empty and
   does not end in one; when the batch would pass the rotation size, the
   close, the rotation of [The store](#the-store) and an open of the new
   file; the append; the sync; the close. It stops at the first call
   that fails, and ends.
4. **Stored or given up.** A batch process that ends normally stored its
   batch, and the writer asks again. One that ends otherwise, or is
   killed, gave it up: the writer counts its lines as not stored and goes
   back to Ready.

Nothing is kept between batches. A process that ends, normally or
killed, has every fid it owned clunked by the grant, after every request
it sent ([design-files.md](design-files.md#fid-owners)), and a
descriptor is its opening process's alone
(`otp/erts/preloaded/src/erx_file_remote.erl`, `on_open/2`), which is
why the batch's own process opens the files and makes every call. So no
batch is sent twice (L7). A batch given up can leave some of its lines
in the file, the last perhaps cut, since a write past one request, or
one whose reply was lost, may have reached it; the next batch ends the
cut line first. Since each batch opens the store as the namespace
resolves it then, the next batch after a storage domain's restart
reaches the new grant
([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain),
"`/data` for other domains"), and a file root's grant truncated is read
at its new size; while `/data` answers `eio`, at boot before the storage
domain has installed its grant or while it restarts, the writer stays at
Ready.

The writer writes two records through `erx_log_h`:
`erx_syslog_writer: OPERATION failed: REASON` for the first batch given
up after a stored one or since its start, `deadline` being a killed
process's reason, and `erx_syslog_writer: writing again, N lines not
stored` for the next batch stored, `N` counting every line given up
since. A failed Ready step loses no line and writes nothing; what the
backlog drops meanwhile is its `lines missed`. On `/tmp` a write past
the cap answers `enospc` and gives the batch up.

### The emergency path

What must reach the operator before the service starts and after it dies
does not pass through it:

* **The kernel** writes its own records on the early console until the
  first take, and at a panic or the machine's end writes its report
  there after stopping the other CPUs
  ([design-kernel.md](design-kernel.md#console-log-and-panic)); on the
  stopgap its end path also writes the records nobody has taken
  ([design-stopgap.md](design-stopgap.md#the-end-path)).
* **The system domain's** `erlang:display/1`, `erlang:display_string/2`
  and `standard_error` go to its `erx_tty_owner`, `erx_console`, which
  writes their bytes to its driver unchanged
  ([design-runtime.md](design-runtime.md#the-console-and-standard-io)),
  with no dependency on `erx_syslog`; with `erx_console` gone they take
  the C path, `erx_output_write`, which on erXos's kernel makes them
  kernel records.

At the machine's end, lines taken but not yet on the console are not
shown, since a take is not a write; they are in the store after a reboot
when the writer synced them first.

### Service lifetime and restart

`erx_syslog_sup` is a `one_for_one` supervisor of `erx_syslog`, which
restarts it at most four times an hour, as `kernel_safe_sup` restarts
its children. It is a `temporary` child of `kernel_sup`, as `erx_console`
is through `user_sup`, so its end is neither restarted nor counted by
`kernel_sup` and ends no other service
(`otp/lib/stdlib/src/supervisor.erl:1441-1444`). The service's first
start in a boot writes `erx_syslog: start` and sets a `persistent_term`
key; a start that finds the key writes `erx_syslog: restarted` instead.

* **A crash** of `erx_syslog` loses the backlogs and the lines it had
  taken from the kernel's ring but not handed on; `erx_syslog:
  restarted` tells a reader that lines may be missing before it. A
  `write` the dead service held answers `{error, failed}`, one sent while
  none is registered `{error, unavailable}`, and the proxies count those
  records as dropped; the facets stay, and the consumers ask the new
  service. The take position is the ring's own, so no kernel record is
  taken twice.
* **Past the restart intensity** the supervisor ends, and with it every
  log facet, and the machine runs on without a log service, as it runs
  on without `erx_console`: a broken log is a reason to look, not to
  reset the machine. Every record then goes into the ring
  ([Writing](#writing), Where there is no service), which nobody takes,
  so the console shows no log lines and the store grows no more, while
  `/proc/kernel/log` and `dmesg` show the ring's last 64 KiB. Whether a
  release build should end the machine with a crash record instead is
  settled at the security closure (TODO.md).

A writer that crashes, which a file error does not make it do, is
restarted by its supervisor and begins again at Ready; the batch it held
is lost, as for any consumer.

## Interfaces

* **Erlang.** Logging is OTP's: `logger:warning/2` and `?LOG_ERROR` in
  any domain reach the log through `erx_log_h`. `erx_syslog:next/1` is
  for the two consumers alone.
* **The log facet**, `write` ([The log facet](#the-log-facet)), and the
  files of [The file tree](#the-file-tree).
* **`dmesg -a`** writes `/proc/kernel/log` and then `/var/log/messages`,
  as FreeBSD's `-a` adds the syslog records
  ([design-shell.md](design-shell.md#text-commands)).
* **The kernel ring.** `erx_log:take/0`, called by `erx_syslog` alone,
  and `erx_log:read/1`, called by the inspector; both unchanged.
* **OTP.** `kernel.erl` starts `erx_syslog_sup` after the watchdog and
  before `user_sup`. `erx_domain`'s supervisor starts
  `erx_syslog_writer` and then `erx_logfs` after the domain service,
  once `/tmp` (from `kernel`'s safe supervisor) and `/data` (from the
  domain service's boot) are in the system domain's namespace.

## Phase 1

Phase 1 runs on the stopgap, with other domains from M5
([plan.md](plan.md)). Everything here is Erlang in the system domain and
unchanged by erXos's kernel. The kernel ring is the stopgap's, polled
since it offers no signal; its rate is per space and its ring shared, so
one space can push every record out in seconds, which the `kernel log
records lost` lines and the sequence gaps show. Before the data
partition exists the store is in the system domain's `/tmp`.

## Failure handling, diagnostics and debuggability

Each failure is described with its mechanism and tested in
[Verification and testing](#verification-and-testing). Every loss shows
as one of these lines, the system domain's records:

| Line | Written when |
| --- | --- |
| `erx_syslog: start`, with the release and its build identifier | the service's first start in a boot |
| `erx_syslog: restarted` | every later start; lines before it may be missing |
| `erx_syslog: N kernel log records lost` | a take reports records the ring overwrote before they were taken |
| `erx_syslog: a kernel log record failed its checks` | a take reports a record that failed the reader's checks |
| `erx_syslog: domain ID: N records dropped` | the rate's second turns with that domain past its rate |
| `erx_syslog: N lines missed` | at the head of a consumer's batch, for the lines its backlog dropped; in that backlog alone |
| `erx_log_h: dropped N events` | at the head of a proxy's next `write`, for the events past its 200 or refused with an error; the domain's own record |
| `erx_syslog_writer: OPERATION failed: REASON` | the first batch given up after one stored, or since the writer's start |
| `erx_syslog_writer: writing again, N lines not stored` | the first batch stored after one given up |

A malformed `write` is counted in the facet's refusal counter
([design-live.md](design-live.md#paths)). Past the restart intensity
the supervisor's report is in the kernel ring, at `/proc/kernel/log`.

## Security

* **Attribution** is the service's (L1): a domain can lie only in its own
  text, after a head the service wrote.
* **Escaping** is once, when the line is rendered (L2), so no console
  line shows a raw control byte of a domain's text, and the writer stores
  only lines the core escaped. The boundary: `erx_logfs` serves the
  stored bytes as they are, and `cat`, `tail` and `grep` write them to a
  terminal unchanged, as a program's own output, so `/var/log` shows what
  the writer stored only while nothing else writes the store. A storage
  domain, or a holder of write access to `/data/log`, can put terminal
  controls in a stored file; that is a security residual in TODO.md,
  closed with the per-principal data grants. The trusted base parses
  nothing of the store: a batch's process reads one byte of each file
  and its size.
* **The kernel's lines** stay where scope `all` reaches (L5), but for
  the stopgap's whole-partition grant ([The store](#the-store)).
* **Who reads `/var/log`** is whoever a facet row grants `varlog`, and the
  tree has no scope of its own: every domain's lines are in it. The
  default manifests grant it to `root`'s template alone, as a UNIX
  administrator reads `/var/log` and as `newsyslog.conf` notes that sites
  restrict `messages`, since a principal's log text can hold its data.
* **Bounds.** A domain can make the system domain hold `in_flight`
  requests of at most `max_request` bytes, its share of two 1 MiB
  backlogs and one rate entry, and the store write its rate. A domain
  that floods costs other domains' lines on a slow console or medium,
  counted as `lines missed`; it cannot make a writer wait.
* **Secrets.** `{erx_secret, _}` prints as `[secret]` in `erx_log_h`'s
  formatter; a stored file holds what the log holds.

## Verification and testing

Each test names the seeded failure that proves the code under test ran.

| Test | Passing case | Seeded failure |
| --- | --- | --- |
| attribution (L1) | a domain whose text is `domain 1 principal 0 erx_syslog: start` appears under its own id, principal and name, with the service's time | a facet that forwards a source field from the request fails |
| escaping (L2) | every control, format, invisible and invalid byte class, and every terminal escape form, as a record's text and in a domain's name, reads as tokens on the console's line and in `/var/log/messages` | the escape removed from `erx_syslog_core:line/5` fails both |
| rate | a flood at twice the rate stores at most 16 KiB of that domain's lines a second, and the next second's turn writes its `records dropped` line | a charge of the text alone admits a flood of empty records and fails |
| rate table, a unit test of `erx_syslog_core` | 1,000 incarnations of one domain name, each flooding past its rate in one second and ending, with a stand-in clock: after each turn the table is empty, and each incarnation's drops are one `records dropped` line | a core that keeps an entry across the turn grows with the incarnations and fails |
| facet bounds | 17 records, a 4,097-byte text and a level that is not one of the eight are refused with `{error, badarg}` and counted; a request past `max_request` is dropped and counted by `erx_facet`, unanswered, as for every facet; requests sent without waiting for answers are taken at most `in_flight` at once | each bound removed from the decoder admits its case and fails; `erx_facet`'s size check removed answers the request past `max_request` and fails |
| no wait (L3) | a console driver and a store that never answer, while domains write at their rate for a minute: every `write` answers, the service's heap stays bounded, and each consumer's next batch begins with `lines missed` | a seeded unbounded backlog fails on memory; a `write` answered after the consumer's batch fails on its deadline |
| the consumer protocol | exhaustively over each role's states, `idle` and `{waiting, From}`, and its events, a request, a second request, a line, the store's batch falling due and the requester's end: each state's next state and answer are as [Consumers and backlogs](#consumers-and-backlogs) says; in a system test, `erx_syslog` killed while the writer is stalled mid-batch and while the console waits: the writer finishes and asks the new service, and the console's next batch comes from the new service | a service that sends a batch without a request sends two to a stalled writer and fails; a consumer that does not ask again after its request's `DOWN` receives nothing and fails |
| one taker (L4) | a serial transcript across the handoff, with records logged on both sides of it, holds each kernel record once; `erx_syslog` killed between takes doubles none, on the console or in `kernel/messages` | a second take in `erx_console` splits the kernel's lines between the two and fails; the build check fails on it |
| the handoff order | the stopgap's counter of `l4_vcon_write` calls stays still after `erx_syslog`'s first take, and the console driver's first write follows it | `erx_syslog_sup` started after `user_sup` lets the driver write first and fails |
| kernel lines apart (L5) | a session's `ls /var/log` lists `messages` and no `kernel`, and `grep '^#' /var/log/messages*` finds nothing; the system shell reads `/var/log/kernel/messages` with the boot's kernel lines | a writer that appends kernel lines to `messages` fails; a session's grant that serves the store's listing shows `kernel` and fails |
| files | `cat /var/log/messages` holds the lines the console showed, in order; `tail -f` shows a line within two seconds of its `write`; `tail -F` follows a rotation | a tree that reports the size of the open rather than the file's leaves `tail -f` silent and fails |
| rotation | a flood past the size rotates: `messages.0` holds the old lines and at most the count of archives remain | a rotation that keeps one archive too many fails the count |
| no line twice (L7) | server stand-ins that apply a write and drop its reply, fail a write part way, and fail the sync: no line appears twice in the store, each cut line ends in a newline, the next batch is appended whole, and `writing again, N lines not stored` counts the batch given up | a writer that retries its batch duplicates lines and fails; a batch process that skips the repair joins a cut line to the next and fails |
| across boots | after a reboot `messages` holds both boots, each beginning with `erx_syslog: start`; a file cut mid-line before the reboot gets a newline before the new boot's first line | the last-byte check removed joins the two lines and fails |
| a failing medium (L6) | the data partition's server failing every request and then silent for ten minutes: the console goes on, every `write` answers, the writer writes one `failed` line, and once the server answers again `writing again` and a batch beginning with `lines missed` are stored | a writer that writes a failure line per failed step floods the log and fails; a writer that crashes on `eio` restarts in a loop and fails |
| storage restart | the storage domain's littlefs worker killed, so the domain restarts ([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)): the writer's batches after the restart are in `messages` | a writer that keeps its files open across batches fails with `eio` on every batch after the restart and fails |
| boot before `/data` | lines logged before the storage domain installs the system domain's `data` grant are in `messages` after it, and the writer wrote no `failed` line | a writer that asks before its Ready step succeeds gives the boot's batches up and fails |
| no data partition | a manifest that grants the system domain no `data` facet: `/var/log/messages` is in `/tmp/log`, reads as above, and one rotation of each family on the default manifest's 4 MiB `/tmp`, with each current file then filled to its size, ends with no `enospc` | the `/data` constants on `/tmp` fill the whole of it and fail with `enospc` |
| restart | `erx_syslog` killed under load, and killed between the facet's forward and its answer: `erx_syslog: restarted` follows, the held `write` answers `{error, failed}`, the proxies count it, and the next `write` through the same facet reaches the new service | a facet whose callback forwards to the pid it found at its mint answers `failed` for good after the restart and fails |
| restart intensity | `erx_syslog` killed five times within an hour: the supervisor ends, the machine runs on, the log facets end, and a domain's next record is in `/proc/kernel/log` | a supervisor that is a permanent child of `kernel_sup` ends the machine and fails |
| emergency | `erx_syslog` killed: `erlang:display/1` in the system domain still reaches the UART | a display path routed through the service fails |
| `dmesg -a` | writes `/proc/kernel/log` and then `/var/log/messages` | an `-a` that changes nothing fails |
| the handler against stock | for each event kind (string, format and arguments, report with and without `report_cb`), `erx_log_h`'s line equals `logger_formatter`'s `single_line` output on stock OTP 29.1.2 | a changed template fails |

**Fuzz target**, landing with its parser: `erx_log_facet`'s `write`
decoder, built from the production module, admits only a list of at
most `log_write_max` pairs of a level and a text within `log_write_text_max`.
Nothing else here parses untrusted input: a batch's process reads one
byte and the size of each stored file, `erx_logfs` passes bytes through
uninterpreted, and `take/0`'s reader already has its target.

**Build check**, with a seeded violation: `erx_log:take/0` is referenced
only from `erx_syslog`, over the system release's call graph
([design.md](design.md#chokepoint-checks)).

## Performance

Logging is not on a hot path; one process renders and hands on. Items
for [todo-performance.md](todo-performance.md):

* the kernel ring's 100 ms poll on an idle machine;
* a flood at 256 domains' full rate, 4 MiB per second, through one
  process;
* the writer's sync per batch on littlefs over an SD card, at most once a
  second per family;
* a process per batch: about six file requests per family and batch
  (open, last byte, size, append, sync, close) where open files would
  need two, at most once a second per family.

## Prior art

| System | Taken | Left out, and why |
| --- | --- | --- |
| FreeBSD `syslogd`, `newsyslog`, `dmesg` | appending lines to `/var/log/messages`; size-and-count rotation with `.0` as the newest archive; appending across boots; `dmesg -a` adding the syslog records | the client-supplied tag, pid and time, which `syslogd` keeps unless `-T` and which forge attribution; kernel messages in `messages`, since erXos keeps kernel text where scope `all` reaches; `syslog.conf` routing, since there are two consumers and no destinations to choose; the yearly rotation and the archives' compression |
| OTP's logger | the API in every domain; handlers and formatters inside the domain; `logger_olp`'s drop threshold | `logger_olp`'s synchronous mode, since a logger never makes its caller wait |
| OTP's supervision | a supervisor of its own for the log service, a temporary child of `kernel_sup`, as `user_sup` is | `kernel_safe_sup`, which starts after `user_sup`, too late for the handoff |

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| the console as the sink | every other reader would need its own feed, and a domain without a console facet logs only into the kernel's ring |
| a `read` operation with cursors and filters on the facet, and a `log` command | files already give history, following and filtering to UNIX's tools; a read protocol duplicates them and needs its own bounds, scope and fuzz target |
| the domains' and the kernel's lines in one `messages`, as FreeBSD | every holder of `/var/log` would read kernel text, which the inspector shows only where scope `all` reaches |
| a RAM ring served as files | a ring that drops its oldest lines has no stable offsets, so seeks and `tail -f` fail; the store's files have them |
| the store in a domain of its own | the writer's file errors are values in one process that nothing waits on, which costs a failing disk only the stored files without another domain and its grants |
| the storage domain serving `/var/log` from its own grant | a machine without a data partition would have no `/var/log`, and the tree could not keep `kernel` out of a session's view without a grant rooted per directory |
| counter-numbered files, never renamed | `/var/log/messages` would need a name the tree maps to the newest file; FreeBSD's renames give the names a person looks for, at the cost of one archive one rotation early when a rotation is cut short |
| a writer that keeps its files open across batches | it must notice that the storage domain restarted, a file was truncated or a fid's grant ended, and keep a model of the store in step; a process per batch opens what the namespace resolves then, for about six requests a batch instead of two |
| a facet endpoint, a process in front of the service that relays each `write` | a relay that does not track each call leaves a request the dead service held without an answer, occupying the facet's limit in flight; resolving the service in the facet's callback lets `erx_facet`'s own forward answer it, with no process added |
| the service tracking each batch until its consumer acknowledges it | an acknowledgement can arrive at a service restarted since, which has no record of its batch; with the consumer asking for each batch, the service keeps nothing to go stale |
| retrying a failed append | a write past one request, or one whose reply is lost, may have reached the file, so a retry writes lines twice and can join a cut line to a whole one; giving the batch up and counting it loses at most that batch |
| checking each stored byte against the line escape as `/var/log` serves it | a classifier in every read, against a medium that in Phase 1 only trusted domains write; rooting each principal's data grant at its own directory closes the same gap where it opens |

## Open decisions

None.

## References

* erXos's designs, each linked where it is used: design-live.md,
  design-kernel.md, design-stopgap.md, design-runtime.md,
  design-domains.md, design-files.md, design-tmp.md and design-shell.md.
* erXos's tree: `erlang/apps/erx/src/erx_facet.erl` (forwarding and its
  failure answer), `erlang/apps/erx/src/erx_inspect_facet.erl`,
  `erlang/apps/erx_domain/src/erx_domain_srv.erl` (`system_facet/4`,
  `mint/5`), `erlang/apps/erx/src/erx_console.erl`,
  `erlang/apps/erx/src/erx_syslog_core.erl`,
  `erlang/apps/erx/src/erx_text.erl`,
  `erlang/apps/erx_files/src/erx_procfs.erl` (`start_link/0`, a tree that
  mounts its own grant), `otp/erts/preloaded/src/erx_file_remote.erl`
  (descriptors of their opening process, writes in requests of one unit).
* OTP 29.1.2: `lib/kernel/src/logger_olp.erl`, `logger_formatter.erl`,
  `kernel.erl` (`kernel_sup`'s flags and children), `user_sup.erl`,
  `lib/stdlib/src/supervisor.erl` (`do_restart/3`).
* FreeBSD `freebsd-src` at tag `release/15.1.0`, fetched over HTTPS from
  `raw.githubusercontent.com/freebsd/freebsd-src`:
  * `sbin/dmesg/dmesg.8`, SHA-256
    `7f3ee27d1b9d0583ad579d2407b224f6c24c210c67bbb510fdb71b9dff0148c4`;
  * `usr.sbin/syslogd/syslogd.8`, SHA-256
    `023e45d76b822e69ed23e399b612792e0b20ed7d4993abfe8d8addf749ede74a`;
  * `usr.sbin/newsyslog/newsyslog.8`, SHA-256
    `a77e7bae2e6d779555d20f4d67d4eb62f6a9e7e7074ea30ee4d017adca246715`;
  * `usr.sbin/newsyslog/newsyslog.conf`, SHA-256
    `ae6618a3158b990fd40878e5bc63b216bdebc310455bf620154e64b44f403ea2`;
  * `usr.sbin/newsyslog/newsyslog.conf.5`, SHA-256
    `94edf15bd3f3d12e38b567d195b4b3b005e151bd838859686403d10165bdeb33`.
