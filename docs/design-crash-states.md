# Crash states

A file system promises that what a flush acknowledged survives a power
cut, and that whatever else the cut leaves still mounts. Neither promise
can be checked by cutting power a few times: the states a cut can leave
are many, and the bad ones are rare. This document is how erXos checks
them all, within a stated bound. It records the exact stream of block
writes and flushes the real FAT code issues, derives from it every disk
image a crash could leave under a conservative model of the device,
mounts each image, runs `fsck_fat`'s checker over it, and compares what
it finds with a model of what each acknowledged persistence point
promised.

It is the generator and recorder behind the crash cases of
[design-recovery.md](design-recovery.md#fault-injection-and-tests)
("nothing answered lost") and behind the FAT power-cut harness of
[design-storage.md](design-storage.md#verification-and-testing), whose
rules for what a cut FAT image may hold it checks.

Decisions every reader needs:

* **A crash state is one choice per sector.** The trace is cut into
  epochs at each flush answered `ok`. The image before an epoch is
  durable; a crash inside the epoch leaves each sector the epoch wrote
  at its durable value or at any value the epoch wrote to it. Every
  crash state is such a choice, so cuts after each write, writes
  reordered between flushes and a volatile cache lost at a reset are
  not separate cases ([The construction](#the-construction)).
* **States at one point per epoch, obligations at every moment.** The
  states a crash could leave earlier in an epoch are all among those at
  its end, so the generator enumerates only there; each state is then
  checked against what was promised at every moment it could have been
  left.
* **One recorder, at the window.** A recording block window on the host
  runs the real file system code, exhaustively at the landing gate's
  bounds. A recorder under a QEMU guest is deferred: what it adds
  depends on schedules it cannot force
  ([An end-to-end recorder, deferred](#an-end-to-end-recorder-deferred)).
* **No existing tool runs against erXos's code.** ALICE, CrashMonkey,
  eXplode and dm-log-writes need a Linux kernel or Linux programs;
  nbdkit's log filter records no data; FreeBSD's gnop and fsx record
  nothing. erXos takes their methods ([Tools](#existing-tools)).
* **The oracle is a model of acknowledgements and two readers.** A pure
  model of what each persistence point acknowledged, and of which later
  operations may change it, which the property-based tests (method 2)
  share as their model, plus `erx_fat:check/1` and `fsck_fat`'s checker
  ([The oracle](#the-oracle)).

## Context

### The problem

The FAT server writes each batch as a plan of steps, each step's writes
followed by a flush (`erx_fat_plan:apply/3`, through which
`erx_media_volume` writes), and its safety
across a cut rests on that order and on the device honouring the flush
([design-storage.md](design-storage.md#removable-media-fat)).
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
traced by strace.

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
server never runs in a Linux kernel, and a Linux kernel's own `msdos`
driver is not the code under test. What erXos takes is the method:
bounded exhaustive workloads, persistence points as the moments to
check, permutation within barriers, a state budget.

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

Two tools in the pinned QEMU matter to an end-to-end recorder. Its
block drivers include `nbd` and `blklogwrites` (`qemu-img --help`,
"Supported formats", QEMU 11.1.3 on the development host).
`blklogwrites` is reported to write a dm-log-writes log of the writes
QEMU's block layer issues; that is unverified, since QEMU's
documentation was not fetched and its source is off limits, and its
log format is known only from GPL code. It is
[Alternatives considered](#alternatives-considered).

### What the code does today

* The volume tests, the media tree's tests and this generator share one
  RAM window, `erx_ram_window` (`test/erlang/erx_ram_window.erl`): it
  answers `info`, `read`, `write` and `flush` from a base image held as
  one binary with the written sectors beside it, answers `eio` to every
  write after a chosen count, as a stick pulled out mid-batch, and, as
  the volume tests' read-only proxy, may answer every write `eio` and
  tell the test of each flush. The volume write tests' removal test
  cuts after every write count; another samples one cut in forty.
* `erx_fault_plan` (`test/erlang/erx_fault_plan.erl`, on the
  `fault-harness` branch) holds design-recovery's fault plans, and the
  fake stick takes its faults from it; moving the window proxies onto
  it is a `docs/todo-build.md` item there.
* The FAT server writes one sector per window write and a flush after
  each step (`erx_fat_plan:apply/3`, called from `erx_media_volume`'s
  `applied/2`), and ends the volume at the
  first request answered with an error (`answered/1`, beside them);
  `erx_fat_dir:commit/1` answers the steps (`erx_fat_dir.erl`, module
  documentation, "Steps").
* `erx_fat:check/1` is the ownership check a writable mount runs
  (`erx_fat.erl:42-52`); `erx_fat_check:check/2` is `fsck_fat`'s
  checker, which [design-fsck-fat.md](design-fsck-fat.md) designs.
* The window serves `read`, `write` and `flush`, with no write that is
  durable on its own; it answers one request at a time, in order, and a
  flush is the whole medium's (`erx_blk_window.erl:13-19`). The
  virtio-blk driver requires `VIRTIO_BLK_F_FLUSH` and does not reset the
  device itself, since nothing promises a reset keeps the volatile cache
  (`erx_blk_virtio.erl:16-33`).
* design-storage's FAT power-cut harness and `Erx::FatVolume` are
  designed and not built.

## Requirements

* **CS1. Every crash state, within a stated bound.** For a recorded
  trace and a device mode, the generator produces every image a crash
  could leave, or, past the bound, stated families plus a sample whose
  seed and generator version are recorded.
* **CS2. The real code writes the trace.** The trace is what the FAT
  server and `fsck_fat`'s repair actually sent to their window,
  recorded below them; nothing is re-derived from a description of what
  they should send.
* **CS3. What was acknowledged is there.** In every `atomic` state,
  every path a persistence point acknowledged before the crash reads
  back exactly, unless an operation begun before the crash changes it,
  in which case it obeys the file system's own rule for a cut
  operation.
* **CS4. Every state mounts or is refused cleanly.** No state crashes
  the mount. In `atomic` mode every state passes `erx_fat:check/1`,
  `fsck_fat`'s checker finds only what a cut may leave, and its repair
  keeps what CS3 keeps. In `torn` mode `fsck_fat` refuses or converges.
* **CS5. A failure replays.** A failure's record holds what rebuilds
  its image without the run that found it, and rebuilding gives the
  same bytes.
* **CS6. The landing gate stays fast.** The landing gate runs only the
  window recorder over the smallest workloads; the rest is milestone
  work.

## The construction

A **trace** is what the recorder saw, in order: each request the file
system sent its window, `{write, Sector, Bytes, Answer}` or
`{flush, Answer}`, where `Answer` is `ok` or `{error, Reason}`; and the
workload driver's marks, `{begin, I}` just before it calls operation
`I` and `{answered, I}` once that call has answered. Each write covers
whole 512-byte sectors. The window answers one request at a time and
its caller waits for each answer, so each request is answered before
the next is sent, and the trace's order is at once the order of
sending, of answering and of effect. The driver's marks reach the
recorder by calls too, so a mark falls after every request its
operation caused before answering and before every request a later
operation causes.

Three rules read the answers:

* a flush answered `ok` makes durable every write sent before it;
* a write is a value of its sectors whatever its answer: one answered
  `ok` may still sit in a volatile cache, and one that failed may have
  landed in part;
* a flush that failed makes nothing durable.

**Epochs.** The flushes answered `ok` cut the trace into epochs; the
last epoch runs to the end of the trace, closed by no flush. Let `D_k`
be the image after epoch `k` with every write of epochs `1..k` applied
in order: the durable image, with `D_0` the base image the run started
from. For each sector `s` that epoch `k+1` writes, `A(s)` is the list of
distinct byte strings among `D_k[s]` and the epoch's writes to `s`, the
durable value first and the rest in the order they were first written.

**A crash state** of epoch `k+1` is `D_k` with each sector the epoch
wrote set to one value of its `A(s)`. Nothing else varies. Since each
`A(s)` holds distinct values, distinct choices give distinct images,
and the epoch has `M`, the product of the `|A(s)|`, of them.

Each kind of cut a harness might list is one of these choices:

* **A cut after the j-th write** takes, for each sector, its last value
  among writes `1..j` and the durable value elsewhere.
* **Writes reordered between flushes** are the other choices.
* **A volatile cache dropped at a reset** is `D_k` everywhere, or any
  subset of it, for the epoch the reset fell in.
* **A failed write, and the write in progress at the cut,** are values
  of their sectors like any other: they may have landed.
* **A sector written twice in one epoch** has both values to choose
  from; which of them a device keeps is one of the choices.
* **A multi-sector write may land in part,** as a device that splits a
  request leaves it, because the choice is per sector.

**Where the states are enumerated.** A crash at any moment of an epoch
leaves each sector the epoch wrote at its durable value or at a value
written to it before that moment, or by the request in progress. So the
states of every moment are among those at the epoch's end, just before
its flush is answered, and the generator enumerates each epoch there
alone, the trace's open last epoch included; when the trace ends with
a flush answered `ok`, that last epoch is empty and its one state is
the durable image. This rests on nothing between two flushes narrowing
a sector's choices, which holds because the window has no write that is
durable on its own.

**A state's moments.** A state whose latest chosen write is at
position `t_S` of the trace (the epoch's start, when it chooses only
durable values) is a possible outcome of a crash at every moment from
`t_S` to the epoch's end, and of none before. What was promised changes
only at marks, so each state is checked against the obligations at
`t_S` and after each mark between `t_S` and the epoch's end
([The oracle](#the-oracle)). An operation the driver began after a
moment never excuses a state at that moment, and a promise answered
after a moment is not owed at it.

## Recorders

### The window recorder

The recorder is the volume write tests' RAM medium, `ram/2`, moved into
its own module, `erx_ram_window` in `test/erlang`, with the read-only
proxy of `erx_media_volume_tests.erl` folded into it. It is the block
window stand-in of
[design-recovery.md](design-recovery.md#four-places-to-inject), so one
module serves the volume tests, recovery's fault plans and this
document. It serves `info`, `{read, Sector, Count}`,
`{write, Sector, Bytes}` and `flush` from a base image held as one
binary with the written sectors beside it, keeps `ram/2`'s cut after a
count of writes, and, when asked to record, keeps the trace above:
each request with its bytes and its answer, and each mark the driver
sends it. The volume tests change only their import.

A recording run takes no fault plan, and the module refuses to start
with both. Recovery's `silent`, `{late, Ms}` and `gone` faults leave a
request unanswered when the caller moves on, so the trace could not
say whether that request came before the next; those faults, and the
deadlines and retries around them, are design-recovery's cases.

The code under test is the code that runs on erXos: `erx_media_volume`
and `erx_fat_dir` over the window for FAT, and `erx_fat_check`'s repair
for `fsck_fat`. All of it is Erlang and runs in the host's stock OTP,
with each crash state an Erlang binary, so a run takes no QEMU, no
image file and no subprocess, and the generator is exhaustive at the
landing gate's bounds.

What it does not see: the block driver, the virtio queue, QEMU and a
real card. A driver that answers its window `ok` for a write its device
has not completed is invisible here. That is a property of the
driver's pure core, an `ok` to a write following the device's
completion of it, whose place is the layer-1 explorer of each driver
core ([design-recovery.md](design-recovery.md#four-places-to-inject)),
which checks a property at every transition, independent of any
schedule.

### An end-to-end recorder, deferred

A recorder under a QEMU guest's disk, an NBD server in Ruby that QEMU's
`nbd` block driver connects to, would record the requests in the order
QEMU completed them, below the guest's virtio-blk driver. Checked by
the same oracle, such a trace would catch a driver that drops a flush
or changes a request's sector or bytes, and any difference between the
file system the host build runs and the boot image's.

It is deferred because the class it was meant to add, a driver that
answers a write before its device completes it, shows in such a trace
only when the guest's next flush reaches the server while that write is
still unanswered. A correct driver waits for the answer, so the server
must answer every write at some time, and whether a faulty driver's
flush arrives before then depends on the guest's and QEMU's schedules
and on whether QEMU's block layer passes a flush on while an earlier
write is outstanding, which is unverified and whose source is off
limits. A miss is silent. Completion delivery to the driver is also on
the guest's side of QEMU, out of the server's sight, and the trace says
nothing of an SD card's or a USB stick's ordering. The driver core's
explorer checks the class deterministically, and the window recorder
checks the file systems; what is left is a smoke test of the composed
path.

If it is built:

* the NBD wire format comes from a facts record that a separate agent
  writes, under the clean-room rule, from the NBD project's protocol
  document; no design or code agent reads that document;
* the driver's marks have to cross from guest to host, which the window
  recorder gets for free;
* NBD's FUA flag makes a write durable at its answer, which narrows its
  sector's choices inside an epoch, so a trace with FUA writes needs an
  enumeration point just before each FUA write is answered as well as
  at each epoch's end; the state count is the sum over those points,
  bounded by the number of FUA writes plus epochs.

It is not part of this design's plan: what it adds, a smoke test of
the composed path, does not pay for an NBD server, its facts record, a
probe of QEMU's behaviour and marks carried from guest to host. It is
reconsidered only if a storage fault escapes both a driver core's
explorer and the window recorder.

## The device model

The model is one abstraction for every medium: a write answered `ok`
is volatile until a flush answered `ok` makes it durable, the sectors of
an epoch land independently of each other, and a flush answered `ok`
is honest. It allows every state a medium that keeps its stated
contract can leave, and more where the contract is stronger, so it is
conservative: a pass under it holds for each medium below as far as the
medium keeps its contract, and says nothing of what a physical card or
stick does beyond it.

| Medium | Its stated contract | Against the model |
| --- | --- | --- |
| virtio-blk on QEMU | a volatile cache and a flush the driver requires (`erx_blk_virtio.erl:16-33`); whether a sector write is atomic is not stated in anything read for this design | the model is the contract, with sector atomicity assumed in `atomic` mode |
| an SD card under erXos's driver | the driver turns the card's cache off at start and answers a write only once the card has programmed it, so a write answered `ok` is durable ([design-storage.md](design-storage.md#the-sd-host-controller), "The card's cache") | stronger than the model: a completed write vanishing before the next flush is outside the contract, and a pass covers the contract with room to spare |
| a USB stick over Bulk-Only | a flush is SCSI's SYNCHRONIZE CACHE ([design-usb.md](design-usb.md)); whether a stick honours it, and whether it tears sectors, is unverified | the model assumes the flush honest |

Outside the model, and so outside what a passing run shows: a device
that answers a flush without making anything durable, a cut that
damages sectors no request of the epoch named (flash pages shared with
older data), and more than one torn sector. These are design-storage's
residual risk of an SD card that loses an acknowledged write
([design-storage.md](design-storage.md#risks-and-open-questions)).

The model has two modes:

| Mode | A sector the epoch wrote lands as | Used for |
| --- | --- | --- |
| `atomic` | one value of its `A(s)` | every guarantee a design states |
| `torn` | as `atomic`, or, for at most one sector of the state, unreadable or split: two distinct values of its `A(s)` joined at a 32-byte boundary, either value first | the robustness checks below |

A `torn` sector thus has `1 + 15 × |A(s)| × (|A(s)| − 1)` choices
beyond its `atomic` ones: the unreadable form, and fifteen interior
boundaries for each ordered pair of values. The epoch's count is `M`
plus, for each sector, those choices times `M / |A(s)|`.

The split's grain is 32 bytes, a FAT directory entry's size, and every
directory entry and every two- or four-byte FAT entry lies whole within
one aligned 32-byte piece, so a tear in this model mixes whole entries
of two versions within a sector and never splits an entry. A tear
inside an entry, and arbitrary bytes, are outside the model; the fuzz
targets of `erx_fat` (`test/erlang/erx_fat_fuzz.erl`,
`erx_fat_read_fuzz.erl`) and of `fsck_fat`'s checker
(`erx_fat_check_fuzz.erl`, on its branch) feed those. One torn sector
per state models a cut that interrupts the sector being programmed.

FAT's guarantees are stated for atomic sector writes, on "a medium that
writes a sector atomically and honours a flush, as an SD card does not
promise" ([design-storage.md](design-storage.md#invariants)); making
FAT survive a torn sector would need a journal FAT does not have. So
`torn` checks robustness only: every state mounts or is refused with a
diagnostic, never a crash; `fsck_fat`'s checker answers within its
bounds; and its repair either refuses with a diagnostic or leaves a
volume whose second check finds nothing but kept lost chains. No file
is promised to survive a tear: an unreadable directory or FAT sector
may lose files outright, and no obligation is checked in `torn` mode.

## The generator

### Workloads

A workload is a short sequence of file operations, bounded as Ace
bounds them: `create`, `write` (within a file, extending it, and past
its end, each at most two clusters long), `truncate` (shorter and
longer), `remove`, `rename` (to a new name and onto an existing one,
across directories), `mkdir` and `rmdir`, over the volume tests' tree
(`test/fixtures/fat_volumes.rb`): the root with two files, `sub` with
one file and the nested directory `sub/Deeper`, which holds one; on its
FAT16 and FAT32 images made by fsimg. A write is at most 1,024 bytes,
two of the FAT32 image's clusters. A persistence point is an operation
whose answer the volume's design names durable
([design-drives.md](design-drives.md)): an `fsync`, a commit, the
finish at eject. The workloads place `fsync` as their persistence
point, and the generator inserts one after the last operation of
every workload, so each workload ends acknowledged. `seq-N` is every
sequence of N operations over the file set, with every placement of
persistence points between them. The driver runs one operation at a
time, sending the recorder `{begin, I}` before each and `{answered, I}`
after it, and ends every workload with the finish an eject sends, so
the cut states of the last batches and of the clean bit are checked;
the finish changes no file and adds no mark.

The enumeration is a pure Erlang module, `erx_crash_workloads`, whose
count for each `seq-N` it prints with the run. It writes no workload to
disk; a workload is named by its position in the enumeration and the
enumeration's version, which is the module's hash, so a name read back
after the module changed is refused, not misread.

A gate runs a set of workloads whole, reported `all N of seq-1`, or a
sample of it, reported `sampled K of N of seq-2` with its seed. That is
reported apart from each epoch's state coverage: exhaustive states over
sampled workloads are sampled workloads.

### States

`erx_crash_states` is a pure module: from a trace, a device mode and a
bound it answers the crash states of each epoch, each as the durable
image plus its choice, a map from each sector not left at its durable
value to an index into `A(s)` (from 1, `0` being the durable value) or
a tear, with the state's earliest moment `t_S`. Leaving the durable
sectors out keeps a choice meaningful only over the image before its
epoch, so a rebuild over the wrong image shows. An epoch whose count is at most `Bound` is enumerated whole and
reported `exhaustive`. A larger one gives, in order:

1. the in-order cuts: the state after each prefix of the epoch's
   writes, as a device that writes in order leaves it;
2. every state with exactly one sector left at its durable value and
   the rest at their last value;
3. in `torn` mode, each in-order cut with the sector of the next write
   torn between its value there and that write's, or unreadable: the
   sector being programmed at the cut;
4. states drawn at random from the rest, without repeats, until the
   epoch has `Bound` states, from a seed derived from the run's seed
   and the epoch's index; none when families 1 to 3 already reach it.

Families 1 to 3 run whole whatever the bound: for an epoch of `n`
writes they hold at most `2n + 1` states and, in `torn` mode, `31n`
more, and the workloads bound `n`. The bound caps only family 4. The
first two families are the states most likely to break a step order: a
missing flush shows as a later step landed without an earlier one,
which family 2 always holds. A sampled epoch is reported
`sampled N of M`, with `M` its count, its seed and the generator's
version, the module's hash: the order of the families and of the draw
is the module's own, so the same version and seed give the same sample,
and a sample named under another version is refused.

| Gate | Bound per epoch | Workloads | Mode |
| --- | --- | --- | --- |
| landing | 4,096 | FAT `seq-1` whole, and a fixed sample of `seq-2` with a fixed seed | `atomic` |
| milestone | 65,536 | FAT `seq-2` whole, and `seq-3` over a narrowed operation set (Ace's guidance) | `atomic` and `torn` |

The landing gate's target is under a minute on the development host;
its `seq-2` sample is 400 workloads drawn with the seed 20261127, a
size the measured cost of a state fits well within it, and the run
prints its time.

## The oracle

### Acknowledgements and obligations

`erx_fs_model` (`test/erlang`) is a pure model of a file tree: a map
from path to a directory or a file's bytes, and the operations above as
functions on it. Method 2's property-based tests, under PropEr as an
out-of-tree tool, take it as their model's next-state function; it
depends on nothing of PropEr, so this generator runs without it.

Over a trace, the model follows the marks. At `{begin, I}` it applies
operation `I`. At `{answered, I}` of a persistence point it records the
value of every path the point acknowledges, as its file system scopes
an acknowledgement. The base image's tree counts as acknowledged at the
trace's start, since `D_0` is durable.

The **history** of a path at a moment is its last acknowledged value
before that moment, followed by its value after each later operation on
it that began before that moment. A path whose history has one entry
must read back exactly that: a file's bytes, a directory, or absence.
A longer history is judged by the file system's **rule for a cut
operation**. A file system plugs into the oracle by supplying two
things: the scope of its acknowledgements and that rule. FAT supplies
these:

* **Scope.** An `fsync`, a commit or the finish acknowledges the whole
  tree as it stood when the point began, since the server commits every
  waiting change in one batch at each of them
  ([design-storage.md](design-storage.md#removable-media-fat),
  "batches").
* **Rule.** design-storage's rule for a cut batch, in which files hold
  old or new bytes block by block within old or new sizes, and names
  are whole, missing or under their short name alone
  ([design-storage.md](design-storage.md#verification-and-testing),
  "FAT"), read over the whole history rather than its first and last
  entries: each 512-byte block of a file holds that block from some
  entry, its bytes past that entry's size being one other entry's bytes
  at those offsets, which the medium still holds when a size and a
  data block land apart; the size is some entry's; a file's bytes
  follow it across a rename, so a file found under its old name may
  hold what was written under its new one; and each name is whole under some
  entry, missing, or under its short name alone. The whole history
  counts because the server also commits every 5 s while changes wait,
  which can make a state between two persistence points durable before
  a later batch is cut.

A later file system plugs in the same way: F2FS's `fsync`, for one,
acknowledges its file, so writing two files and syncing one promises
nothing of the other. littlefs is a stopgap and is not a target of this
design; its release contract governs it
([design-stopgap.md](design-stopgap.md#release-contract)).

### The checks of one state

In order, each a step whose failure names the state and the step:

1. **Mount.** `erx_fat:mount/2` over the state either mounts it or
   refuses with a reason; any exception fails the state.
2. **Ownership.** In `atomic` mode, `erx_fat:check/1` answers `ok`, which
   is design-storage's structural rule for every cut image (no cluster
   in two chains or under two names, no name or chain reaching a free
   cluster, every `..` naming its parent).
3. **Obligations.** In `atomic` mode, the tree read through `erx_fat`
   meets every path's obligation at each of the state's moments.
4. **`fsck_fat`'s checker.** In `atomic` mode, `erx_fat_check:check/2`
   finds only what the write order of
   [design-storage.md](design-storage.md#removable-media-fat) lets a
   cut leave. Where the FAT the server reads is clean, that is nothing:
   the clean bit comes back only after every batch is committed, last
   in that FAT. Where it is dirty: the dirty flag; lost chains; a chain
   longer than its file's size; FAT copies that differ, since each FAT
   entry goes to every copy in one step, first copy first; and an
   invalid long-name run, or entries after a directory's end marker,
   since a long name can cross a sector boundary and its sectors land
   independently, so a cut may land the part past the old end marker
   without the part that overwrites it. Its repair, written to
   a copy, leaves a second check finding nothing but kept lost chains,
   and step 3 holds again on the repaired copy with the entries of
   `/LOST.DIR` left out of the comparison: the workloads never touch
   it, and the repair names lost chains there
   ([design-fsck-fat.md](design-fsck-fat.md#lost-chains)). A name whose
   invalid run the repair deleted is under its short name alone, which
   the rule allows.
5. **Independent readers, at the milestone.** `Erx::FatVolume` and
   fsimg's verify, as design-storage states them, over every state of
   the milestone run, and macOS's `fsck_msdos` as a second opinion that
   fails nothing.

In `torn` mode, steps 2 to 4 give way to the robustness checks of
[The device model](#the-device-model). Steps 1 to 4 run in the
generator's node on the host; step 5 needs image files and
subprocesses, so it stays off the landing gate.

`fsck_fat`'s own repair is a target too: the trace of its repair of
each damaged image of [design-fsck-fat.md](design-fsck-fat.md#damaged-images)
yields crash states, each checked by FK-R3's rule (it reads dirty,
keeps every allocated cluster allocated, adds no name to a free cluster,
and a second run meets FK-R2). That is FK-R3's "cut after every step and
after every subset of a step's sectors", made by this generator.

## Targets

**FAT.** It is the file system erXos wrote, on media a user pulls
without warning, and its oracle rules are written. `fsck_fat`'s repair
is checked with it.

**EROFS** is never written and has no crash states. **F2FS** has its
own power-cut harness in [design-f2fs.md](design-f2fs.md), whose cuts
this generator produces once F2FS's writer exists, with F2FS's scope
and rule plugged into the oracle.

## Where it runs and what it reports

The landing gate runs the window recorder's FAT suite as an EUnit
module, `erx_crash_fat_tests`, through `test/host/erx_crash_states_test.rb`
in `make check`, within the table's bounds. `erx_crash_run` records
each workload, runs the checks of one state and writes the failure
records; step 4 plugs into it as a checker of a state's sectors, which
`erx_fat_check` supplies when it joins. Everything else,
`torn`, `seq-2` whole and up, `fsck_fat`'s repair traces and the
independent readers, runs at the milestone gate.

A run reports, per gate: the workloads, as `all N` or `sampled K of N`
with the seed; per epoch, `exhaustive` or `sampled N of M` with its seed
and the generator's version; the number of states checked; and each
failure, as its workload name, epoch, choice and first failing step
with its reason. A state whose check passed its deadline is reported
`timed_out`, and neither it nor a cell that did not run counts as a
pass. A name or byte string read from a crash image is untrusted text
and reaches the host terminal only through its one escaping function.

For a failure, the run writes a record into the output directory it was
handed, never into the repository: the base image, once per run, named
by its SHA-256; and, for each of the run's first four failures (an image
is as large as its volume, and a broken step order fails hundreds of
states alike), the base's SHA-256, the trace with its bytes and marks,
the mode, the epoch, the choice and the failing image as the check read
it.
Rebuilding from the base, the trace, the epoch and the choice gives the
failing image byte for byte, without the workload enumeration or the
fixture build (CS5), which a test checks.

## Concurrency and failure

The generator and the model are pure. Each state is an independent
binary, so states are checked in parallel Erlang processes, one per
scheduler, with nothing shared; everything a check runs is Erlang, so a
check that crashes or passes its deadline is killed and fails that
state alone, and the run goes on to report the rest. The window
recorder is one process serving one volume and one driver, in order,
as the window does.

The run writes only into the output directory the build hands it, as
the build hands the volume tests their images, which the Ruby harness
prepares with `Erx::OutputDirectory.check`
(`tools/lib/erx/output_directory.rb`). File names there are made from
the workload's position, the epoch and the state's index, never from
anything read from an image. Step 5's readers run as subprocesses
started with an argument vector, each under a deadline and in a process
group of its own, ended with `Erx::ProcessGroup.terminate`
(`tools/lib/erx/process_group.rb`), and each works on its own copy of
the image, so a reader that writes, `fsck_msdos` among them, changes
only that copy.

## Refusals and error results

* An `erx_ram_window` asked to record and to follow a fault plan at
  once refuses to start, naming both.
* A workload name, a sample or a failure record made under another
  version of its module is refused, naming both versions.
* A failure record whose base image's SHA-256 does not match the stored
  base is refused, naming both hashes.
* A run with `torn` asked runs only the robustness checks in that mode,
  and says so.

## Security

Crash images are untrusted input to code that already treats every
medium as untrusted: `erx_fat` and `erx_fat_check` have fuzz targets,
and this generator adds valid-looking images, not a new parser of
untrusted input. A failure record is read back only by the replay, from
the run's own output directory, with `binary_to_term/2`'s `safe`
option; it is our own output, not a trust boundary. Host paths come
from the run, not from images, and text from images is escaped as
above.

## Tests

Each passing case is paired with a seeded fault that must make it fail.

| Case | Seeded fault that must fail it |
| --- | --- |
| a FAT `seq-1` run over FAT16 and FAT32 finds no failing state | the flush after `erx_fat_dir`'s `preparation` step dropped from `erx_fat_plan`'s step loop: a state with a published name whose chain reaches a free cluster fails step 2 |
| the same run | a publication write sent before the preparation step's flush: a state holding the new name over a zeroed directory cluster fails step 3 |
| a batch that grows a chain across both FAT copies and creates a long name across a sector boundary: states with differing copies under the dirty flag, and with an invalid long-name run, pass step 4 | the dirty flag cleared in the FAT the server reads before the other copies: a state whose copies differ while that FAT reads clean fails step 4 |
| the same `seq-1` run, each workload ended by the finish | the release step dropped from every plan: a state that reads clean with a lost chain fails step 4 |
| a `fsck_fat` repair of the cross-linked image leaves no failing state | the dirty mark merged into the first repair step: a state that reads clean with half a repair fails FK-R3's rule |
| a repair that names a lost chain passes step 4's comparison on the repaired copy | the repair naming the chain in the root directory instead of `/LOST.DIR`: an unpromised root name fails the comparison |
| a FAT file committed, then overwritten in a batch that is cut: states holding some of the overwrite's blocks pass step 3 | the model judging every path by its acknowledged value alone, ignoring operations begun since: those states fail |
| on a synthetic trace, a stray write to a committed file that only a later operation's bytes would excuse fails at its earliest moment | obligations taken only at the epoch's end: the stray state passes |
| an epoch of three writes to distinct sectors gives exactly eight states; two distinct writes to one sector and one to another give six; a sector rewritten with its durable bytes adds none | a generator that yields only the in-order cuts: four states, and the misordered-write seed above passes |
| the epochs: a flush answered `ok` covers every write sent before it, and one answered with an error ends no epoch, so a state lacking a write sent before the failed flush is generated | the failed flush counted as an epoch's end: that state is missing |
| in `torn` mode, writes A then B to two sectors give the state with A torn and B whole | tears drawn only over the in-order cuts: that state is missing |
| a failing state rebuilt from its record is byte-identical | the choice applied to `D_{k+1}` instead of `D_k`: the rebuilt image differs |
| `torn` over FAT `seq-1`: every state mounts or is refused, and `fsck_fat` refuses or converges | `erx_fat`'s directory read without its sector-length check: an unreadable sector crashes the mount |
| a sampled epoch reports `sampled N of M` with its seed and version, sampled workloads report apart, and a deadline reports `timed_out` | the sampled count reported as `exhaustive` |

The generator's own unit tests check the state count formulas of both
modes on small epochs, that the values of `A(s)` are distinct, and,
over every prefix of random epochs, that every state at an earlier
moment is among the epoch end's.

## Packages

1. **The window recorder and FAT.** `erx_ram_window` (`ram/2` moved out
   with the read-only proxy folded in, recording bytes, answers and
   marks), `erx_crash_states`, `erx_crash_workloads`, `erx_fs_model`
   with FAT's scope and rule, checks 1 to 3, the landing-gate suite, and
   the seeds of [Tests](#tests) for steps 2 and 3, the state counts, the
   epochs, the sampled report and the replay.
2. **`fsck_fat`.** Check 4, the repair traces of the damaged images and
   the seeds for step 4 and the repair, joining with `erx_fat_check`.
3. **`torn` and the milestone readers**: the tear states and their
   seeds, step 5 with its subprocesses, and the milestone wiring.

## Alternatives considered

* **An NBD recorder that orders its answers to expose a driver that
  answers early.** It would read every request waiting on its socket
  and answer a flush before writes read with it. A correct driver waits
  for each write's answer, so the recorder must answer every write at
  some time, and a faulty driver's flush arrives before or after that
  time as the guest and QEMU schedule it; whether QEMU passes a flush on
  while a write is outstanding is unverified. The property is
  deterministic in the driver's core
  ([The window recorder](#the-window-recorder)).
* **QEMU's `blklogwrites` as the end-to-end recorder.** No server to
  write, and it records below the virtio-blk device as an NBD server
  would. Its log format is dm-log-writes', known only from GPL code, so
  a reader needs a facts record written by a separate agent under the
  clean-room rule, and its behaviour is unverified without QEMU's
  documentation.
* **Cut after every write and permute only within a step**, listed
  as two families of cuts. Every such state is one of the
  construction's choices; listing the cuts and the permutations
  separately is the enumeration the construction removes.
* **Boot a guest per crash state.** The guest's mount is the same
  Erlang code the host runs; the host run is thousands of times
  cheaper.
* **Generate workloads with PropEr.** Random generation finds deep
  sequences that exhaustive bounds miss, which is method 2's job; method
  1's claim is completeness within a bound, which random generation
  cannot make.

## Open decisions

None.

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

Papers cited for their methods and not fetched: T. S. Pillai et al.,
"All File Systems Are Not Created Equal: On the Complexity of Crafting
Crash-Consistent Applications", OSDI 2014; J. Mohan et al., "Finding
Crash-Consistency Bugs with Bounded Black-Box Crash Testing", OSDI
2018; J. Yang, C. Sar and D. Engler, "eXplode: a Lightweight, General
System for Finding Serious Storage System Errors", OSDI 2006.

Tools checked on the development host: `brew info nbdkit` (no formula);
`qemu-img --help` of QEMU 11.1.3, whose supported formats include
`nbd`, `blkdebug`, `blkverify` and `blklogwrites`.
