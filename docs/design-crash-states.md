# Crash states

A file system promises that what a flush acknowledged survives a power
cut, and that whatever else the cut leaves still mounts. Neither promise
can be checked by cutting power a few times: the states a cut can leave
are many, and the bad ones are rare. This document is how erXos checks
them all, within a stated bound. It records the exact stream of block
writes and flushes the real storage code issues, derives from it every
disk image a crash could leave under a stated model of the device,
mounts each image, runs `fsck_fat`'s checker over it, and compares what
it finds with a model of what each acknowledged flush promised.

It is the generator and recorder behind the crash cases of
[design-recovery.md](design-recovery.md#fault-injection-and-tests)
("nothing answered lost") and behind the FAT power-cut harness of
[design-storage.md](design-storage.md#verification-and-testing), whose
rules for what a cut FAT image may hold it checks.

Decisions every reader needs:

* **A crash state is one choice per sector.** The trace is cut into
  epochs at each acknowledged flush. The image before an epoch is
  durable; a crash inside the epoch leaves each sector the epoch wrote
  either as it was or as any version the epoch wrote to it. Every
  crash state is such a choice, so cuts after each write, writes
  reordered between flushes and a volatile cache lost at a reset are
  not separate cases ([The construction](#the-construction)).
* **One crash point per epoch.** The states a crash could leave
  earlier in an epoch are all among those at its end, so the generator
  enumerates only there.
* **Recorders at two seams, the window first.** A recording block
  window on the host gives fast, exhaustive runs over the real file
  system code; a recording NBD server, in Ruby, serving a QEMU guest's
  disk puts the virtio-blk driver's ordering in the trace
  ([Recorders](#recorders)).
* **No existing tool runs against erXos's code.** ALICE, CrashMonkey,
  eXplode and dm-log-writes need a Linux kernel or Linux programs;
  nbdkit's log filter records no data; FreeBSD's gnop and fsx record
  nothing. erXos takes their methods ([Tools](#existing-tools)).
* **The oracle is a model and two readers.** A pure model of what each
  persistence point promised, which the property-based tests
  (method 2) share as their model, plus `erx_fat:check/1` and
  `fsck_fat`'s checker ([The oracle](#the-oracle)).

## Context

### The problem

The FAT server writes each batch as a plan of steps, each step's writes
followed by a flush (`erx_media_volume.erl:690-700`), and its safety
across a cut rests on that order and on the device honouring the flush
([design-storage.md](design-storage.md#removable-media-fat)). littlefs
maps its sync callback to the window's flush
([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)).
`fsck_fat`'s repair claims that a cut after any step, or after any
subset of a step's sectors, loses nothing
([design-fsck-fat.md](design-fsck-fat.md#why-a-cut-loses-nothing),
FK-R3). Each claim is a statement about every image a crash can leave.
A dropped flush or a write moved across one leaves the code passing
every test that does not crash, and corrupts a volume only on the cut
that lands in the gap.

### Existing tools

| Tool | What it records | Layer | OS | License | Usable by erXos |
| --- | --- | --- | --- | --- | --- |
| ALICE (Pillai et al., OSDI 2014) | the system calls of an application, through a modified strace | the application over a file system | Linux; Python 2.7 and libunwind | MIT for its own files; `alice-strace` under strace's terms | method only |
| CrashMonkey and Ace (Mohan et al., OSDI 2018) | every block request a Linux file system issues, through a wrapper block device, and snapshots through a copy-on-write RAM disk | the block layer under a Linux file system | Linux kernels 3.12 to 5.6 | Apache-2.0 for the repository; its kernel modules were not read | method only |
| eXplode (Yang et al., OSDI 2006) | crash states of a storage system driven from inside, through a modified RAM disk | the block layer and the checked system's own choice points | Linux | unverified: the paper was not fetched, and whether its code was published is unverified | method only |
| dm-log-writes with its replay tool | every write, with its data, every flush and FUA, and marks set from user space | a Linux device-mapper target | Linux | the target is Linux's; the replay tool is xfstests' (GPL), not read | method only |
| nbdkit's log filter | every NBD request's kind, offset, count, FUA flag, id and result; no data | an NBD server on the host | Linux, macOS, FreeBSD | BSD-3-Clause | could serve a QEMU disk, but cannot rebuild a crash state |
| FreeBSD gnop | nothing: it delays and fails requests with set probabilities | a GEOM class in FreeBSD's kernel | FreeBSD | BSD-2-Clause | method of design-recovery's layer 2 already |
| FreeBSD fsx | nothing on disk: random file operations checked against an in-memory copy | the file interface | FreeBSD and others | APSL-2.0 | a method-2 tool, not a method-1 one |

**ALICE** traces an application's system calls with its own strace
(its README, chapter 1) and replays them under a model of what a file
system may reorder, to find where an application's update protocol
depends on more than the file system promises. It checks applications,
not file systems, and it traces Linux processes. erXos's file systems
are Erlang processes inside erXos domains; no erXos system call is
traced by strace. Its method fits a later question, whether an erXos
service that keeps state in files (the Bluetooth bonding store, the
vault) depends on more than littlefs promises, and is recorded in
[Open decisions](#open-decisions) as out of this document.

**CrashMonkey** loads two Linux kernel modules, a block device that
logs the bios a file system sends to it and a copy-on-write RAM disk,
runs a workload on a Linux file system mounted over them, and replays
the log into crash states: "Skipping this flag allows CrashMonkey to
permute block IOs within barrier operations ... The default is to test
10K states" (`docs/CrashMonkey.md`). **Ace** generates its workloads
exhaustively within bounds: sequences of one to three operations from
`creat`, `mkdir`, `write`, `link`, `unlink`, `rename`, `truncate`,
`fsync` and others, over four directories with two files each, with
persistence operations `sync`, `fsync`, `fdatasync` or none inserted
(`docs/Ace.md`, "Bounds used by Ace"). The modules see only bios that a
Linux file system driver sends through Linux's block layer. erXos's FAT
server and littlefs port never run in a Linux kernel, and a Linux
kernel's own `msdos` driver is not the code under test. What erXos takes
is the method: bounded exhaustive workloads, persistence points as the
moments to check, permutation within barriers, a state budget.

**eXplode** checks storage systems by running them under a controller
that explores every choice point, crashes included. This document rests
on no detail of it beyond that, since the paper was not fetched;
erXos's layer-1 explorers
([design-recovery.md](design-recovery.md#four-places-to-inject)) already
work that way.

**dm-log-writes** is a device-mapper target. Its documentation fixes
the ordering rule this design uses: "Only completed WRITEs, at the time
the REQ_PREFLUSH is issued, are added" before the flush in the log;
"Any REQ_FUA requests bypass this flushing mechanism and are logged as
soon as they complete"; discards are logged as writes; and a mark can
name a point in the log, so a replay stops at a persistence point
(`log-writes.rst`, "Log Ordering" and "Example usage"). It needs a
Linux kernel below the file system under test. Its on-disk log format
is not described in that document, only in GPL code, which this design
did not read.

**nbdkit** serves a disk over NBD, and its log filter "logs all
transactions" (`nbdkit-log-filter.pod`). A write is logged as
`offset=0x%x count=0x%x fua=%d` (`filters/log/log.c:323-325`): the
bytes are not logged, so the log alone cannot rebuild any image but the
last. Its `sh` plugin could hand each write's bytes to a script on
standard input (`plugins/sh/nbdkit-sh-plugin.pod`), at one process per
request. Homebrew has no `nbdkit` formula on the development host
(`brew info nbdkit`: "No available formula"); its README says it
"works on macOS and is mostly feature complete", tested with MacPorts.
A pinned source build would be one more autotools build out of the
tree for a recorder that still needs a script per write.

**gnop** passes requests through a GEOM provider and delays or fails
them with set probabilities (`gnop.8`: `-d delaymsec`, `-r rfailprob`,
`-w wfailprob`, `-q`, `-x`). It records nothing and runs in FreeBSD's
kernel; its fault modes are already design-recovery's fault plan.
**fsx** applies random operations to a file and checks every read
against a copy in memory. Its license is the Apple Public Source
License 2.0 (`fsx.c:2-20`), not BSD. It has no crashes in it; it is the
shape of method 2.

Two tools in the pinned QEMU matter to the second recorder. Its block
drivers include `nbd` and `blklogwrites` (`qemu-img --help`, "Supported
formats", QEMU 11.1.3 on the development host). `blklogwrites` is
reported to write a dm-log-writes log of the writes QEMU's block layer
issues; that is unverified, since QEMU's documentation was not fetched
and its source is off limits, and its log format is known only from GPL
code. It is [Alternatives considered](#alternatives-considered).

### What the code does today

* The fake window proxy, `proxy/2` in
  `test/erlang/erx_media_volume_tests.erl:27-62`, answers `info`, one
  sector's `read` and `flush` from a medium held as one binary, and
  sends the test `{flushed, Pid}` at each flush. It answers no write.
* `erx_fault_plan` (`test/erlang/erx_fault_plan.erl`, on the
  `fault-harness` branch) holds design-recovery's fault plans, and the
  fake stick takes its faults from it; moving the window proxies onto
  it is a `docs/todo-build.md` item there.
* The FAT server writes one sector per window write and a flush after
  each step (`erx_media_volume.erl:690-705`); `erx_fat_dir:commit/1`
  answers the steps (`erx_fat_dir.erl`, module documentation, "Steps").
* `erx_fat:check/1` is the ownership check a writable mount runs
  (`erx_fat.erl:42-52`); `erx_fat_check:check/2` is `fsck_fat`'s
  checker, on the `fsck-fat-check` branch, and
  [design-fsck-fat.md](design-fsck-fat.md) is on the
  `design-fsck-msdosfs` branch.
* The window answers one request at a time, in order, and a flush is
  the whole medium's (`erx_blk_window.erl:13-20`). The virtio-blk
  driver requires `VIRTIO_BLK_F_FLUSH` and does not reset the device
  itself, since nothing promises a reset keeps the volatile cache
  (`erx_blk_virtio.erl:16-33`).
* littlefs's port turns a program into a window write and a sync into a
  flush ([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain));
  no host test runs the port.
* design-storage's FAT power-cut harness and `Erx::FatVolume` are
  designed and not built; no crash-state generator exists.

## Requirements

* **CS1. Every crash state, within a stated bound.** For a recorded
  trace and a device model, the generator produces every image a crash
  could leave, or, past the bound, a stated family plus a sample whose
  seed is recorded.
* **CS2. The real code writes the trace.** The trace is what the FAT
  server, littlefs's port, `fsck_fat`'s repair and, end to end, the
  block driver actually sent, recorded below them; nothing is
  re-derived from a description of what they should send.
* **CS3. What was acknowledged is there.** In every state, everything a
  persistence point acknowledged before the crash reads back exactly;
  what was in flight obeys the file system's own stated rule.
* **CS4. Every state mounts or is refused cleanly, and checks.** No
  state crashes the mount; on a sector-atomic medium every state passes
  `erx_fat:check/1`; `fsck_fat`'s checker finds only what a cut may
  leave and its repair keeps everything promised.
* **CS5. A failure replays.** A failing state is named by its workload,
  epoch and choice, and rebuilding it from those gives the same image.
* **CS6. The landing gate stays fast.** The landing gate runs only the
  hosted recorder over the smallest workloads; the rest is milestone
  work.

## The construction

A trace is the list of requests the medium answered, in the order it
answered them: `{write, Sector, Bytes}`, `flush`, and, from the NBD
recorder only, `{write_fua, Sector, Bytes}`. Each write covers whole
512-byte sectors. A flush answered `ok` makes durable every write
answered before the flush was sent; a FUA write is durable when it is
answered.

**Epochs.** The answered flushes cut the trace into epochs. Let `D_k` be
the image after epoch `k` with every write of epochs `1..k` applied in
order: the durable image. Epoch `k+1` touches a set of sectors; for
each such sector `s`, let `V(s)` be the versions epoch `k+1` wrote to
it, in order, and `D_k[s]` its durable value.

**A crash state** inside epoch `k+1` is `D_k` with each touched sector
`s` replaced by one choice from `{D_k[s]} ∪ V(s)`. A FUA write fixes its
sector to its own version, or a later one in the epoch. Nothing else
varies. The number of states in the epoch is the product over its
sectors of `|V(s)| + 1`.

Each kind of cut a harness might list is one of these choices:

* **A cut after the j-th write** is the choice that takes, for each
  sector, its last version among writes `1..j` and the durable value
  elsewhere.
* **Writes reordered between flushes** are the other choices.
* **A volatile cache dropped at a reset** is the choice of `D_k`
  everywhere, or any subset, for the epoch the reset fell in.
* **An unanswered or failed write** is still a version of its sector in
  the open epoch: it may have landed.
* **One crash point per epoch suffices.** A crash after a prefix of the
  epoch's requests allows, for each sector, a subset of the versions it
  allows at the epoch's end, so its states are among the end's. The
  generator enumerates at the end of each epoch, just before its flush
  is answered, and once at the end of the trace, where the only state
  is the durable image.
* **Overlapping writes need no rule.** A sector written twice in one
  epoch has two versions to choose from; which of them a real device
  keeps is one of the choices.

Per sector and not per write: a multi-sector write may land in part,
which is what a device that splits a request does.

At the window seam, every write is answered before the next request is
sent (`erx_blk_window.erl:19-20`), so "answered before the flush was
sent" is the trace's own order. At the NBD seam the recorder decides the
order of its answers, which is how it exposes a driver that answers too
early ([The NBD recorder](#the-nbd-recorder)).

## Recorders

### The window recorder

The first recorder is a stand-in block window on the host. It is the
fake window proxy moved into its own module, `erx_crash_window` in
`test/erlang`, which is the move design-recovery already plans for
`erx_fault_plan` ([design-recovery.md](design-recovery.md#four-places-to-inject),
the "block window" row); the module serves the same requests as the
window (`info`, `{read, Sector, Count}`, `{write, Sector, Bytes}`,
`flush`), takes faults from a fault plan, and appends each request it
answers to its trace. With no plan and the trace unread it is the
proxy the volume tests use, so they change only their import.

The code under test is the code that runs on erXos: `erx_media_volume`
and `erx_fat_dir` over the window for FAT, `erx_fat_check`'s repair for
`fsck_fat`, and, once its NIF builds for the host, littlefs's owner and
worker ([Targets](#targets)). All of it runs in the host's stock OTP,
with each crash state an Erlang binary, so a run takes no QEMU, no
image file and no subprocess, and the generator is exhaustive at the
bounds below.

What it does not see: the block driver, the virtio queue and QEMU. A
driver that answers a write before the device completes it, or posts a
flush that overtakes the writes it should cover, is invisible here.

### The NBD recorder

The second recorder puts the block driver in the trace. A QEMU guest
boots its own image as usual and takes the disk under test, a scratch
FAT medium or the data partition, from QEMU's `nbd` block driver over a
UNIX-domain socket that a Ruby module, `Erx::NbdRecorder`
(`tools/lib/erx/nbd_recorder.rb`), serves. It implements the part of
the NBD protocol a QEMU client uses: the handshake, `READ`, `WRITE`
with its FUA flag, `FLUSH` and `DISC`, refusing every other command
with an error. It keeps the disk in memory and writes the trace to a
file in the build tree: per request one tag byte (`W`, `U` for a FUA
write, `F`), the sector as eight bytes and the sector count as four,
big-endian, then the bytes of a write. The generator's Erlang reader of
that file bounds-checks each record and refuses a trace that ends
inside one.

It answers in an order of its choosing, and the choice is what makes
it useful: it reads every request already waiting on the socket before
answering any, answers a flush only after the writes it read before
the flush, and records a write as answered when it sends the answer.
A write read in the same batch as a later flush is answered after that
flush, so the flush does not cover it, which is NBD's rule for a flush
(it covers writes the server completed before it). A driver that tells
its window `ok` for a write whose device request has not completed
then has a flush that does not cover the write, and the oracle finds
the write missing from a state in which the window's caller was told it
was flushed. That is the one class of error this recorder exists to
catch beyond the window recorder's.

Why not nbdkit: its log carries no data, so it would need a script per
write as well, and a pinned out-of-tree build on macOS. The Ruby server
is our own code in the language of the harness, writes the trace in
the form the generator reads, and needs no build. Its cost is the NBD
protocol's handshake and three commands, read from the protocol's
specification when the package is written; the specification was not
read for this design, so the command set above is unverified until
then.

Unverified until a probe cell records it on the pinned QEMU: that the
`nbd` driver connects to a UNIX-domain socket; that with a write-back
cache configured the guest's virtio-blk device offers
`VIRTIO_BLK_F_FLUSH`; and that a guest flush reaches the server as one
`FLUSH`, after the writes the guest completed. The probe boots a guest
whose disk is the recorder's, writes three sectors and flushes, and
checks the trace reads `W W W F`. Until it passes, the cell is refused
with a message naming the probe.

The states of an NBD trace are checked on the host with the same oracle
as the window recorder's; no guest boots per state. At the milestone a
sample of states also boots, each as the guest's disk, and the guest's
own mount must agree with the host's verdict.

### Which comes first

The window recorder: it finds the file-system errors, which are the
most likely, in seconds and on every landing; it needs only the window
proxy that design-recovery already moves. The NBD recorder follows, for
the drivers, at the milestone gate.

## The device model

A model states what a flush and a FUA write promise and how a sector
can land. The trace and the construction carry the first two; the third
is a choice of two modes.

| Mode | A sector lands as | Used for |
| --- | --- | --- |
| `atomic` | its durable value or one whole version | every guarantee a design states |
| `torn` | as `atomic`, or, for at most one sector of the epoch, unreadable or split: the bytes before a 32-byte boundary from one value and the rest from the other | the robustness checks below |

A 32-byte boundary is the size of a FAT directory entry, and every FAT
entry and directory entry lies within a sector
([design-fsck-fat.md](design-fsck-fat.md#why-a-cut-loses-nothing)), so
a split at each boundary reaches every way a cut could mix two
versions of an entry. One torn sector per state models a cut that
interrupts the sector being programmed; more than one is outside the
model.

| Medium | What it promises, as read | Model |
| --- | --- | --- |
| virtio-blk on QEMU | the driver requires a flush command and assumes a volatile cache (`erx_blk_virtio.erl:16-33`); whether a sector write is atomic is not stated in anything read for this design | `atomic`, reordering within an epoch |
| an SD card | no sector atomicity and no flush semantics are taken from the SD specification, which was not read; design-storage's guarantees hold "on a medium that writes a sector atomically and honours a flush, as an SD card does not promise" ([design-storage.md](design-storage.md#invariants)) | `atomic` for the guarantees, `torn` at the milestone |
| a USB stick over Bulk-Only | a flush is SCSI's SYNCHRONIZE CACHE; whether a stick honours it, and whether it tears sectors, is unverified | `atomic` for the guarantees, `torn` at the milestone |

Outside every model, and so outside what a passing run shows: a device
that answers a flush without making anything durable, and a cut that
damages sectors no request of the epoch named (flash pages shared with
older data). Both are design-storage's residual risk of an SD card that
loses an acknowledged write ([design-storage.md](design-storage.md#risks-and-open-questions)).

In `torn` mode the guarantees of CS3 are not expected to hold: no FAT
design promises them over a torn sector. What `torn` checks is CS4's
robustness half: every state mounts or is refused with a diagnostic,
never a crash; `fsck_fat`'s checker answers within its bounds; and after
its repair `erx_fat:check/1` answers `ok` and every file whose sectors
the tear did not touch reads back as promised.

## The generator

### Workloads

A workload is a short sequence of file operations, bounded as Ace
bounds them. For FAT: `create`, `write` (within a file, extending it,
and past its end), `truncate` (shorter and longer), `remove`, `rename`
(to a new name and onto an existing one, across directories), `mkdir`
and `rmdir`, over a file set of two directories with two files each
and one nested directory, on a FAT16 and a FAT32 image made by fsimg.
A persistence point follows each operation whose answer the volume's
design names durable
([design-drives.md](design-drives.md)): an `fsync`, a commit, the
finish at eject; the generator inserts one after the last operation of
every workload, so each workload ends acknowledged. `seq-N` is every
sequence of N operations over the file set, with every placement of
persistence points between them.

The enumeration is a pure Erlang module, `erx_crash_workloads`, whose
count for each `seq-N` it prints with the run. It writes no workload to
disk; a workload is named by its position in the enumeration and the
enumeration's own version, which is the module's hash, so a name read
back after the module changed is refused, not misread.

### States

`erx_crash_states` is a pure module: from a trace, a device mode and a
bound it answers the crash states of each epoch, each as the
durable image plus its choice, a map from sector to version index (`0`
for the durable value) or tear. Each epoch with at most `Bound` states
is enumerated whole. A larger one gives, in order:

1. the in-order cuts: the state after each prefix of the epoch's
   writes, as a device that writes in order leaves it;
2. every state with exactly one sector left at its durable value and
   the rest at their last version;
3. states drawn at random from the rest, without repeats, until the
   epoch has `Bound` states, from a seed derived from the run's seed
   and the epoch's index.

The first two families are the states most likely to break a step
order: a missing flush shows as a later step landed without an earlier
one, which family 2 always holds. The run reports each epoch as
`exhaustive` or as `sampled N of M`, with the seed. `torn` adds, over
family 1, each split and the unreadable form of the sector the next
write would have changed: `31 × n` states for an epoch of `n` writes.

| Gate | Bound per epoch | Workloads | Mode |
| --- | --- | --- | --- |
| landing | 4,096 | FAT `seq-1` whole, and a fixed sample of `seq-2` with a fixed seed | `atomic` |
| milestone | 65,536 | FAT `seq-2` whole, `seq-3` over a narrowed operation set (Ace's guidance), littlefs `seq-2` | `atomic` and `torn` |

The landing gate's target is under a minute on the development host;
the sample's size is fixed to meet it once the first package measures
the cost of a state, and the run prints its time.

## The oracle

### The model

`erx_fs_model` (`test/erlang`) is a pure model of a file tree: a map
from path to a directory or a file's bytes, the operations above as
functions on it, and a persistence point as a function that records
the tree it acknowledges. Method 2's property-based tests, under
PropEr as an out-of-tree tool, take it as their model's next-state
function; it depends on nothing of PropEr, so method 1 runs without it.

For each crash state the model gives two things: the **promised** tree,
the one the last persistence point acknowledged before the epoch's
end; and the **in-flight** operations since. A file system supplies the
rule for what its in-flight operations may leave:

* **FAT**, design-storage's rule for a cut batch: files hold old or new
  bytes block by block within old or new sizes, and names are whole,
  missing or under their short name alone
  ([design-storage.md](design-storage.md#verification-and-testing),
  "FAT").
* **littlefs**, its own: each operation is atomic, and a file's bytes
  are those of its last sync or of a later state of it
  ([research-boards-storage.md](research-boards-storage.md) quotes the
  upstream statement that "remove and rename, are atomic, even in event
  of power-loss").

### The checks of one state

In order, each a step whose failure names the state and the step:

1. **Mount.** `erx_fat:mount/2` over the state either mounts it or
   refuses with a reason; any exception fails the state.
2. **Ownership.** In `atomic` mode, `erx_fat:check/1` answers `ok`, which
   is design-storage's structural rule for every cut image (no cluster
   in two chains or under two names, no name or chain reaching a free
   cluster, every `..` naming its parent).
3. **Promised and in flight.** The tree read through `erx_fat` equals
   the promised tree with in-flight changes the rule allows, and every
   promised file's bytes are exact.
4. **`fsck_fat`'s checker.** `erx_fat_check:check/2` finds only the
   findings a cut may leave (the dirty flag, lost chains, a chain longer
   than its file's size); its repair, written to a copy, leaves a second
   check finding nothing but kept lost chains, and step 3 holds again on
   the repaired copy, so a repair never loses what was promised.
5. **Independent readers, at the milestone.** `Erx::FatVolume` and
   fsimg's verify, as design-storage states them, over every state of
   the milestone run, and macOS's `fsck_msdos` as a second opinion that
   fails nothing.

Steps 1 to 4 run in the generator's process on the host; step 5 needs
subprocesses and an image file per state, so it stays off the landing
gate.

`fsck_fat`'s own repair is a target too: the trace of its repair of
each damaged image of [design-fsck-fat.md](design-fsck-fat.md#damaged-images)
yields crash states, each checked by FK-R3's rule (it reads dirty,
keeps every allocated cluster allocated, adds no name to a free cluster,
and a second run meets FK-R2). That is FK-R3's "cut after every step and
after every subset of a step's sectors", made by this generator.

## Targets

**FAT first.** It is the file system erXos wrote, on media a user pulls
without warning, and its oracle rules are written.

**littlefs next.** Its owner and worker need a host build of the NIF,
which the tree does not have; that build is the target's first step.
Upstream littlefs tests its own power-loss handling: its test runner
cuts power after a chosen number of erases or programs, linearly,
logarithmically or exhaustively (`runners/test_runner.c`,
`run_powerloss_linear`, `run_powerloss_log`,
`run_powerloss_exhaustive_layer`), over an emulated block device whose
programs are either atomic or written out of order by block
(`bd/lfs_emubd.h:48-51`). Those tests check `lfs.c` under littlefs's own
device model. They do not check erXos's port: the mapping of programs
and syncs onto a window, a device that reorders sectors between
flushes, and what the owner answers its clients. erXos runs both: the
upstream runner, fetched at the pinned release and built out of the tree
against the tree's `lfs.c`, at the milestone gate, which catches an
erXos edit to `lfs.c` that breaks its power-loss handling; and this
generator over the port.

**EROFS** is never written and has no crash states. **F2FS** has its
own power-cut harness in [design-f2fs.md](design-f2fs.md), whose cuts
this generator produces once F2FS's writer exists.

## Where it runs and what it reports

The landing gate runs the window recorder's FAT suite as an EUnit
module in `make check`, within the table's bounds. Everything else, the
NBD cells, littlefs, `torn`, `seq-2` whole and up, and the independent
readers, runs at the milestone gate.

A run reports, per target and gate: the workloads run and their count;
per epoch, `exhaustive` or `sampled N of M` with its seed; the number of
states checked; and each failure, as its workload name, epoch, choice
and first failing step with its reason. A state whose check passed its
deadline is reported `timed_out`, and a probe-gated cell that did not
run is reported `not_run` with the probe's name; neither counts as a
pass. A name or byte string read from a crash image is untrusted text
and reaches the host terminal only through its one escaping function.

For a failure, the run writes the trace and the failing image under the
build tree, never into the repository; the workload name, epoch and
choice rebuild the same image from the same trace (CS5), which a test
checks.

## Concurrency and failure

The generator and the model are pure. Each state is an independent
binary, so states are checked in parallel processes, one per scheduler,
with nothing shared; a check that crashes or passes its deadline fails
that state alone, and the run goes on to report the rest. The window
recorder is one process serving one client, in order, as the window
does. The NBD recorder serves one connection; a second is refused, and
a connection that ends inside a request ends the trace there, which
the reader refuses as cut short.

## Refusals and error results

* A trace that ends inside a record, or carries a tag other than `W`,
  `U`, `F`, is refused with the record's offset.
* A workload name whose enumeration version differs from the module's
  is refused, naming both versions.
* An NBD command outside the set is answered with an error and logged;
  a cell whose probe has no passing record for the pinned QEMU is
  refused before QEMU starts, naming the probe.
* A run with `torn` asked of a target whose guarantees the table does
  not test in that mode runs only the robustness checks, and says so.

## Security

Crash images are untrusted input to code that already treats every
medium as untrusted: `erx_fat` and `erx_fat_check` have fuzz targets,
and this generator adds valid-looking images, not a new parser of
untrusted input. The trace reader reads files our own recorder wrote
and is bounds-checked, but is not a trust boundary. The NBD recorder
listens on a UNIX-domain socket in the build tree, not on the network,
and the guest gets no network device for it. Text from images is
escaped as above.

## Tests

Each passing case is paired with a seeded fault that must make it fail.

| Case | Seeded fault that must fail it |
| --- | --- |
| a FAT `seq-1` run over FAT16 and FAT32 finds no failing state | the flush after `erx_fat_dir`'s `preparation` step dropped from `erx_media_volume`'s applied plan: a state with a published name whose chain reaches a free cluster fails step 2 |
| the same run | a publication write sent before the preparation step's flush: a state holding the new name over a zeroed directory cluster fails step 3 |
| a `fsck_fat` repair of the cross-linked image leaves no failing state | the dirty mark merged into the first repair step: a state that reads clean with half a repair fails FK-R3's rule |
| an epoch of three writes to distinct sectors gives exactly eight states, and two writes to one sector and one to another give six | a generator that yields only the in-order cuts: four states, and the misordered-write seed above passes |
| the window recorder's epochs: a flush covers every write answered before it | a write answered after the flush counted into the flushed epoch: the dropped-flush seed passes |
| a failing state rebuilt from its workload, epoch and choice is byte-identical | the choice applied to `D_{k+1}` instead of `D_k`: the rebuilt image differs |
| an NBD trace of `W W W F` from the probe guest, and a driver that answers on completion, give no failing state | the virtio-blk driver answering a write when it posts it: the recorder answers the flush first, and a state lacks a write its window was told was flushed |
| `torn` over FAT `seq-1`: every state mounts or is refused, and `fsck_fat` converges | `erx_fat`'s directory read without its sector-length check: an unreadable sector crashes the mount |
| a sampled epoch reports `sampled N of M` and its seed, and a deadline reports `timed_out` | the sampled count reported as `exhaustive` |

The generator's own unit tests check the state count formula on small
epochs, the FUA rule (a FUA write's sector never takes its durable
value), and that every state at an earlier crash point is among the
epoch end's, over every prefix of random epochs.

## Packages

1. **The window recorder and FAT.** `erx_crash_window` (the proxy moved
   out, with writes, the fault plan and the trace),
   `erx_crash_states`, `erx_crash_workloads`, `erx_fs_model` with FAT's
   rule, checks 1 to 3, the landing-gate suite and the first, second,
   fourth, fifth and sixth seeds of [Tests](#tests). Check 4 and its
   seed join with `erx_fat_check`.
2. **The NBD recorder**, its trace reader, the probe cell and the
   driver seed.
3. **littlefs**: the NIF's host build, its rule in `erx_fs_model`, and
   the upstream runner out of the tree.
4. **`torn` and the milestone readers**: the tear states, step 5, and
   the milestone wiring.

## Alternatives considered

* **QEMU's `blklogwrites` as the end-to-end recorder.** No server to
  write, and it records below the virtio-blk device as the NBD server
  does. Its log format is dm-log-writes', known only from GPL code, so
  a reader needs a facts record written by a separate agent under the
  clean-room rule, and its behaviour is unverified without QEMU's
  documentation; it also records what QEMU completed, not an order the
  recorder chooses, so it cannot widen the window in which a driver
  that answers early is caught. The NBD server is smaller in total and
  catches more.
* **Cut after every write and permute only within a step**, listed
  as two families of cuts. Every such state
  is one of the construction's choices; listing the cuts and the
  permutations separately is the enumeration the construction removes.
* **Boot a guest per crash state.** The guest's mount is the same
  Erlang code the host runs; the host run is thousands of times
  cheaper. A milestone sample keeps the guest honest.
* **Generate workloads with PropEr.** Random generation finds deep
  sequences that exhaustive bounds miss, which is method 2's job; method
  1's claim is completeness within a bound, which random generation
  cannot make.

## Open decisions

1. **The NBD protocol specification as a source.** The NBD recorder
   needs the wire format of the handshake and three commands. The
   protocol's specification is a document in the NBD project, whose
   code is GPL; nbdkit's BSD-licensed documentation does not give the
   wire format. Recommendation: read the specification as
   documentation, as the clean-room rule allows for papers and
   documentation, recording its commit and SHA-256; failing that, a
   facts record of the wire format by a separate agent.
2. **Torn sectors as a guarantee.** FAT's guarantees are stated for a
   sector-atomic medium, which SD cards and USB sticks do not promise.
   Recommendation: keep the guarantees as stated and check only
   robustness under `torn`; making FAT survive a torn sector would need
   a journal FAT does not have.
3. **Application-level crash checks.** ALICE's method would check
   services that keep state in littlefs files (the Bluetooth bonding
   store, the vault) against what littlefs promises. Recommendation:
   leave it out of this document and add a `TODO.md` item once
   littlefs's target runs, since its oracle is each service's own
   update protocol.

## References

Sources read for this design, each fetched over HTTPS into
`~/erxos-scratch/sources-bsd/`:

| Source | Version | File | SHA-256 |
| --- | --- | --- | --- |
| nbdkit | 1.48.1 release archive | `nbdkit-1.48.1.tar.gz` | `21ddcdd0bb3cd49ec47aa2d7ca3e69941426e991932b44dc34a856d063f41ead` |
| nbdkit | 1.48.1 | `filters/log/nbdkit-log-filter.pod` | `2433559ec6f8a0337a6a10b73bacc6a8ccddcacdf07097a90f7034b2e2f70e12` |
| nbdkit | 1.48.1 | `filters/log/log.c` | `239b780225c1ff7273aa19e2c0f44a1ed3e7639addc0cf9385ca1ad871b555b7` |
| nbdkit | 1.48.1 | `docs/nbdkit-plugin.pod` | `0aed479ee10e3c0f8f6521cca224d1331ad2ac5ddeeb8ba804ea6013d44fdcbb` |
| nbdkit | 1.48.1 | `README.md` | `46411d3102dc9954977df04b9cb7f51be68e0e0dc427f664fb20d14f6d300357` |
| nbdkit | 1.48.1 | `LICENSE` | `5272951766f1f381d4d23cf936d1735e5768fb4dd0aa82c28d3ef52902c5fbd8` |
| ALICE | commit `6afda210b96baa2b0b277505d72742420ba89b68` | `README.md` | `6a1721ea5ae5ed69d2f32cba325b583046df59720a97cea71c1be891e98437b3` |
| ALICE | same | `LICENSE.md` | `5879358617112cb4f6d40ee0f31183d7c5331e8d9c147dee75a3bc24f8cda7c0` |
| CrashMonkey | commit `27ca57f8cf2760d5d4855e03b8d01f8e5de1628c` | `README.md` | `653e487d783bcf74b8d40c8d50989ee44dd91b080b39c6394a761b5ae77394ba` |
| CrashMonkey | same | `LICENSE` | `b40930bbcf80744c86c46a12bc9da056641d722716c378f5659b9e555ef833e1` |
| CrashMonkey | same | `docs/CrashMonkey.md` | `bb72df28e384fccd23320fe6063bf73c0f81637e9b5be257deb3431764f3cb2a` |
| CrashMonkey | same | `docs/Ace.md` | `1cc3b4e54c4fe022df694c405ef325451b2f93056f7a7e8252177e23ea534e95` |
| Linux documentation | tag `v6.12` | `Documentation/admin-guide/device-mapper/log-writes.rst` | `99a9eab97386d9a372f5f8467f4c6ff1486ad7d5de030f00c02a23543159cb35` |
| FreeBSD | `release/15.0.0` | `tools/regression/fsx/fsx.c` | `b064208bec8519e80038ee1da8cb9c0f7c512a3242bbf4c06809a88ce15ae019` |
| FreeBSD | same | `lib/geom/nop/gnop.8` | `e9d25350f729953d8a50d8add21229253eabde45b8dcf0dad2714a003dbae70e` |
| FreeBSD | same | `sys/geom/nop/g_nop.c` | `b5a74e55724a87b56f57c33f9f4ff3aa70ce52132145720e94b77ca9f3e1deb7` |
| littlefs | v2.11.3 (`6cb4e86540eca0d9ba62500a298385c9d863c8be`) | `bd/lfs_emubd.h` | `9bfa7b73ab748c767495ad7f6039d8790f72d18f622af9f20c08b651ccc1190e` |
| littlefs | same | `runners/test_runner.c` | `5c28f45b123ab9ec748186aa963931ddc61ef9576566ba95d68056a61b3623dc` |

Papers cited for their methods and not fetched: T. S. Pillai et al.,
"All File Systems Are Not Created Equal: On the Complexity of Crafting
Crash-Consistent Applications", OSDI 2014; J. Mohan et al., "Finding
Crash-Consistency Bugs with Bounded Black-Box Crash Testing", OSDI
2018; J. Yang, C. Sar and D. Engler, "eXplode: a Lightweight, General
System for Finding Serious Storage System Errors", OSDI 2006.

Tools checked on the development host: `brew info nbdkit` (no formula);
`qemu-img --help` of QEMU 11.1.3, whose supported formats include
`nbd`, `blkdebug`, `blkverify` and `blklogwrites`.
