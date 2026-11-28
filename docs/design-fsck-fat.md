# fsck_fat: checking and repairing FAT volumes

A FAT volume on a drive can be damaged: a stick pulled while it was
being written, a medium that dropped a write it had acknowledged, or
another system's bug. erXos mounts such a volume read-only, since its
FAT server writes safely only on a volume that starts consistent
([design-drives.md](design-drives.md#the-writable-rule)). This design
gives erXos `fsck_fat`, and `fsck -t fat` over it, to check and
repair such a volume.

The key idea is that **the checker is a library and the medium is a
file**. `fsck_fat` is an ordinary program, an Erlang command, that
opens the volume's raw sectors, `/media/raw/diskN/sN.data`, which the
media domain serves to the sessions a manifest grants its `media_raw`
service ([design-drives.md](design-drives.md#raw-sectors)). It runs one
pure function from the FAT server's library over them. That function
answers every finding together with the whole repair, a list of small
edits. The command shows the edits, asks once, and writes them in
ordered steps. Opening the file for writing takes the volume out of
service, and the last close returns it to the ordinary mount rule, so
the repaired volume mounts writable at its next walk. Any other program,
`dd`, a ported `newfs_msdos` or a user's own repairer, uses the same
file.

Decisions every reader needs:

* **A repair frees and allocates nothing.** It cuts chains, edits
  directory entries, and names lost chains in the root's existing
  `LOST.DIR`. A lost chain it cannot name stays allocated, and the
  report says so. So every cluster allocated before a repair is
  allocated after it, whether the repair finished or was cut, and
  running the command again after a cut keeps every file the finished
  repair would keep.
* **Each step is written from what the medium holds when its turn
  comes.** The whole check runs first and writes nothing. Then each step
  reads the sectors it changes, patches the bytes its edits name, writes
  them and flushes, after the step before it has been flushed. No step
  carries a copy of a sector made before an earlier step wrote it, so
  no step can undo another. The dirty flag is set first and cleared last.
* **A repaired volume mounts writable, by construction.** The checker
  answers a repair only if erXos's own ownership check
  (`erx_fat:check/1`) passes on the volume as the repair leaves it;
  otherwise it refuses and nothing is written. So success never leaves a
  volume that mounts read-only for `tree`.
* **FreeBSD's findings, erXos's command.** What the check finds, and in
  what order, follows FreeBSD 15.1's `fsck_msdosfs`, the behavioural
  reference, with erXos's departures listed in
  [Where the repairs differ](#where-the-repairs-differ). erXos names the
  file-system type after the file system, `fat`, so the command is
  `fsck_fat` and `fsck -t fat` runs it. `-n` and `-y` are kept, every
  other option is dropped, and the whole repair is shown before one
  question for all of it ([Options](#options)).
* **No system service owns the check.** The media domain serves sectors
  and decides when volumes are mounted, nothing more. Repair belongs to
  whatever program the user runs.

## Context

### The problem

A FAT32 stick used on a Raspberry Pi 4 showed, when the host's FAT
checker read it, live long-name entries whose short entry's slot had
been taken by a later name: a long-name run with no short entry of its
own, followed by another name's run. erXos mounts a volume like that
writable as long as its dirty flag is clear, since nothing in the
writable rule looks at long-name runs. A volume whose flag is set mounts
read-only with `dirty`, and the storage design left its repair to
another machine. erXos can check a FAT image only on the development
host, with fsimg's verify, so a user with only an erXos machine cannot
repair a stick.

### What is matched

FreeBSD `src`, tag `release/15.1.0`; the files are byte-identical at
commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`, which
[design-drives.md](design-drives.md#what-is-matched) reads. Files and
hashes are under [References](#references). erXos matches what FreeBSD's
`fsck_msdosfs` finds, the order in which it examines a volume, and the
sentence it prints for each finding. What the source shows:

* **Phases.** The boot sector and FSInfo (`boot.c`); phase 1 reads the
  first FAT and walks every entry once, in cluster order
  (`fat.c:806-1024`); phase 2 walks the directories from the root, each
  subdirectory pushed on a stack as it is found, so the last one found
  in a directory is walked first, its whole subtree before the next
  (`dir.c:1045-1076`); phase 3 handles lost chains in cluster order,
  then the FSInfo hints (`fat.c:1256-1337`); then "Update FATs" and
  "MARK FILE SYSTEM CLEAN" (`check.c:122-175`). Which of two claimants
  a repair cuts depends on this order.
* **Options.** `-n`, `-y`, `-p` (preen, answering each question with
  its default), `-f` (preen a volume that reads clean too), `-B` and
  `-C` (ignored), `-M` (no `mmap`), `-F` (exit 5, for `fsck(8)`'s probe
  for background checking), and with none of `-n`, `-y` or `-p`, one
  terminal question per repair (`main.c:71-104`, `:130-161`). Exit
  status 0 when nothing is left unrepaired, 8 otherwise or on a fatal
  error (`check.c:52-190`), 1 for a usage error (`main.c:57-60`).
* **What it does not check.** It reads only the first FAT and ignores
  FAT32's mirroring flags (`boot.c:165` sets `ValidFat`, which nothing
  reads); it never compares the FAT copies, and copies the first over
  the others only when it changed the first (`fat.c:1199-1250`); it
  checks neither the characters of names nor duplicate names. A loop of
  lost clusters that nothing outside the loop links into has no head,
  so phase 3 never meets it.
* **What it frees.** A lost chain is reconnected as a file in the root's
  `LOST.DIR` only when that directory exists and has a free slot in the
  clusters it already has; otherwise `-y` answers "Clear" and the chain
  is freed (`dir.c:1097-1131`, `fat.c:1285-1297`). The reconnected
  entry's size is the chain's length times the cluster size, stored in
  four bytes whatever its value (`dir.c:1145-1162`). A file's clusters
  past its size are freed (`dir.c:446-460`), and a chain with no valid
  cluster has its first entry written free (`fat.c:1113-1120`).
* **How it writes.** It maps the first FAT shared, so its changes reach
  the medium whenever the kernel writes them back (`fat.c:712-720`). It
  writes a directory cluster as soon as it has changed it
  (`dir.c:1012-1021`), and never sets the dirty flag first. An
  interrupted run can therefore leave a volume that reads clean with
  half a repair on it.
* **Two assertions a crafted volume can reach.** A directory named by
  two entries is walked twice, and the second walk asserts that its
  first cluster is still unvisited (`fat.c:1056-1057`); clearing an
  already clear bit asserts too (`fat.c:93`). Whether FreeBSD's release
  build keeps these assertions is unverified here.

### What erXos does today

* A volume's process mounts it read-only for `dirty`, `hard error`,
  `mirror`, `too large` or `tree`, the last after the ownership check
  (`erx_fat:check/1`,
  [design-storage.md](design-storage.md#removable-media-fat)): a cluster
  linked to twice, a link that is no cluster, a first cluster named
  twice or linked to, a `.` or `..` that is not the directory's first or
  second entry or names the wrong cluster (`erx_fat.erl:570-590`), a
  reached cluster that is free or bad. An allocated cluster no name
  reaches is not a finding of that check.
* A writable volume's changes are plans, `[{Step, [{Sector, Bytes}]}]`,
  which `erx_media_volume:applied/2` writes, each step's sectors and
  then a flush (`erlang/apps/erx_media/src/erx_media_volume.erl:695-699`).
  The FAT server builds each batch's images after the batch before it
  has been written, so an image never starts from a sector an earlier
  batch has since changed.
* Raw sectors are served as `/media/raw/diskN/data` and `sN.data`
  ([design-drives.md](design-drives.md#raw-sectors)).

### Can erXos's own batches leave a long-name run without its short entry?

Yes, under a cut. `erx_fat_dir:unnamed/2` marks every slot of a removed
name deleted in `preparation` (`erx_fat_dir.erl:616-618`), and `place/5`
writes every entry of a new name in `publication` (`:515-530`).
`merged/2` lists a step's sectors in sector order with no flush between
them (`:176-177`), and `applied/2` flushes once per step. A name's
entries lie in two sectors whenever its run crosses a 16-entry boundary,
a cluster's end included. The storage design orders writes only by
flushes, and relies only on each sector being written whole, so a cut
can land any subset of one step's sectors. A cut that lands the short
entry's sector of a removal, but not the long entries', leaves the long
entries live before a deleted slot. One that lands the long entries'
sector of a creation, but not the short entry's, leaves them live before
a free slot.

erXos's reader ignores such a run (a long name counts only when its
entries run in order and carry the checksum of the short entry that
follows them, `erx_fat.erl` module doc), and the writable rule does not
look at runs. The volume is dirty after the cut and mounts read-only, so
erXos itself writes after the orphan only once something has cleared the
flag: a repair elsewhere that kept the orphan, or a medium that
acknowledged a flush and then dropped an earlier write. From then on
`place/5` can put a new name's run after the orphan, with nothing or
only deleted slots between them, since it checks the entry before a run
only for a name stored as its short entry alone (`:524`). That gives
exactly the stick's pattern. This reading found no path to an orphan
without a cut, and the stick's history was not recorded. The repair here
removes such runs, and the FAT server avoids writing next to one
([The FAT server's side](#the-fat-servers-side)).

## Requirements

* **FK-R1. FreeBSD's findings.** On every FAT16 or FAT32 volume of
  512-byte sectors whose FATs are mirrored and that lies within the
  bounds, `fsck_fat` finds what FreeBSD 15.1's run finds, in the same
  order, and `-y` makes FreeBSD's repair for each, except for the
  departures in [Where the repairs differ](#where-the-repairs-differ).
* **FK-R2. A repaired volume is writable.** After a run that wrote its
  repair, the volume meets the writable rule's FAT conditions: the dirty
  flag clear, no hard error recorded, and the ownership check passed.
* **FK-R3. An interrupted repair loses nothing.** A cut at any write of
  a repair but its last leaves a volume that reads dirty, on which every
  cluster allocated before the repair is still allocated, no name
  reaches a free cluster that it did not reach before, and no cluster is
  reached by two names that were not both reaching it before. Running
  the command again then meets FK-R2 and keeps, at its path and with its
  contents, every file the uninterrupted repair keeps.
* **FK-R4. Shown before it is changed.** Unless `-y` is given, nothing is
  written until the user has seen every finding and what its repair
  changes, and has said yes to all of it. A check whose findings cannot
  all be shown is refused.
* **FK-R5. No other writer of the volume.** While the command can write
  a drive's volume, no mount of that volume exists, and none can start.
* **FK-R6. Untrusted input.** Every structure the checker builds has a
  bound checked before it grows; a volume that would pass one is refused
  with a diagnostic and nothing written, never by a crash or by the
  runtime's heap limit. Its work is bounded by the volume's geometry. It
  has a fuzz target. Text taken from the medium reaches the terminal
  only through the field escape.
* **FK-R7. No new mechanism.** The design uses the drive's raw sectors,
  the FAT server's library, an Erlang command and the session's
  namespace, each named below.

Non-goals: FAT12, which the drives refuse by name; exFAT; volumes whose
FATs are not mirrored; repairing a partition table; making a file
system; preening at boot, since erXos mounts no FAT volume at boot.

## The construction

### The checker is a library and the medium is a file

```text
session domain                                  media domain
fsck_fat /media/raw/disk0/s1.data
  stat: 2097152 sectors
  open for reading and writing  ------------->  drive process: finish s1's mount,
                                                end its process, flush; s1 shows
                                                "none raw"
  erx_fat_check:check(Read, Sectors)  <- pread  erx_media_raw -> window proxy
    -> findings + edits (pure; writes nothing)
  print every finding and its repair
  "Apply 5 repairs to /media/raw/disk0/s1.data? [yn]"
  fsync (refused if it fails) --------------->  the window's flush
  for each step: pread, patch, pwrite, fsync -> the window
  close  ------------------------------------>  last writing close: every raw request
                                                answered, flushed; s1 back under the
                                                mount rule; its next walk mounts it
```

1. **Open.** The command takes the file's length in 512-byte sectors
   from `stat`. `-n` opens the file for reading only, which disturbs no
   mount. Otherwise it opens it for reading and writing; for a drive's
   `sN.data` the drive process first finishes volume N's mount and ends
   its process, so the volume holds no batch and no other writer while
   the command runs (FK-R5), and admits the open only on a medium that
   flushes.
2. **Check.** `erx_fat_check:check(Read, Sectors)` runs over a function
   that reads one 512-byte sector of the file and the file's length. It
   is pure: it answers the findings and the repair, or a fatal finding,
   or a refusal, and writes nothing.
3. **Show and ask.** The command prints each finding with what its
   repair changes, then asks once whether to apply the repair
   ([The report](#the-report)).
4. **Write.** The command calls `fsync` once before any write, and
   refuses if it fails, with nothing written: without a working flush
   the steps' order means nothing. Then `erx_fat_check:write/4` writes
   the repair step by step, in the order of
   [Writing a repair](#writing-a-repair): it reads the sectors the step
   changes, patches them, and hands the images to `erx_fat_plan:apply/4`,
   which writes them and flushes. The FAT server's volume process writes
   each step of its batches through the same function, with the window
   proxy's write and flush, so a step has one writer.
5. **Close.** At the last writing close the volume returns to the
   ordinary rule: its next walk starts its process, which probes it and
   mounts it by the writable rule, `rw` after a successful repair
   (FK-R2).

### How each requirement follows

* **FK-R1.** One pure function decides every finding and repair, with
  FreeBSD's order of examination, so agreement is tested on the host and
  against FreeBSD over the same images.
* **FK-R2.** The checker answers a repair only when `erx_fat:check/1`
  passes over the volume as the repair leaves it, and the last step
  clears both flags.
* **FK-R3.** No edit writes a free value into the FAT or allocates a
  cluster, and the steps take references away before adding new ones
  ([Why a cut loses nothing](#why-a-cut-loses-nothing)).
* **FK-R4.** The repair is complete before anything is printed, so what
  is shown is exactly what is written, and the findings' bound refuses a
  report too large to show whole.
* **FK-R5.** The drive's writing open
  ([design-drives.md](design-drives.md#raw-sectors)).
* **FK-R6.** [Bounds](#bounds), and the fuzz target in
  [Verification](#verification).
* **FK-R7.** The names this design adds are the modules `erx_fat_check`
  and `erx_fat_plan`, and the Erlang commands `fsck_fat` and `fsck`. The
  raw files are the drives design's.

### A volume erXos does not mount

A volume whose boot sector the probe cannot read, whose format no row
serves, or whose mount failed still has its `sN.data`, so the command
simply runs: it reports the boot sector's fatal finding and exits 8,
writing nothing, as FreeBSD does. A user's own program can rewrite that
boot sector through the same file, from FAT32's backup boot sector for
instance. At its last close the volume is probed again. A medium whose
table is refused has `data` alone, through which a program can rewrite
the table; the medium is read afresh at that file's last writing close.

## The checker

`erx_fat_check:check(Read, Sectors)`, in the `erx_fat` library
application, takes a function that reads one 512-byte sector of the
volume and the volume file's length in sectors. It admits the boot
sector by `erx_fat`'s admission rules, given that length, so a volume
that claims more sectors than the file holds is refused before any FAT
sector is read, and every sector a repair writes lies within the file.
It answers `{ok, Findings, Repair}`, where each finding is FreeBSD's
sentence, the paths it names, and the change its repair makes; or
`{fatal, Finding}`; or `{refused, Reason}`.

A repair is a list of **edits**, each a few bytes at an offset in one
sector: a FAT entry of the first FAT, a 32-byte directory entry, the
FSInfo sector's signatures and hints, the first FAT's entry 0. Each edit belongs
to one step. The checker decides as if every repair were made, in
FreeBSD's order, over a **view**: the volume as read, with every edit
decided so far laid over it, so each later decision sees the earlier
ones. The view and the repair are the same list of edits, so they
cannot disagree. There are no questions inside the checker: the command
applies the whole repair or none of it, so a declined repair can never
change what a later finding sees.

When FreeBSD's order has run, the checker drops its own sets and runs
`erx_fat:check/1` over the view, through `erx_fat:with_read/2`. If that
answers anything but `ok`, the checker answers
`{refused, {not_writable, Finding}}`, naming the ownership finding the
repair would leave, and nothing is written. This is the one definition
of a writable volume, the FAT server's, applied once to the result; the
findings table below is how the checker gets there, and the final check
is what makes FK-R2 hold for any volume the table does not foresee.

The directory walk keeps one frame per directory on the current path,
each holding the directory's first cluster, its name and the
subdirectories found in it and not yet walked, each with its first
cluster and name. A finding's path is built when the finding is made,
from the frames' names, the nearest first, until the path's bound is
reached ([Bounds](#bounds)). The frames and the subdirectories waiting
in them count toward one bound with their names, so holding the names
costs no reread of an ancestor's entries.

Every walk ends by construction. Phase 1 ends one of every two chains
that link to one cluster, and a repair only ever writes an end of
chain, so no cluster is linked to twice; a walk starts only at a
cluster nothing links to, so it never meets a cluster twice and takes
at most as many steps as the volume has clusters. A cluster no walk
reached whose entry links on therefore lies on a loop of lost clusters.

### Findings and repairs

The message is FreeBSD's, with its source. The last column names the
ownership-check finding the repair removes.

| Finding (FreeBSD's message) | Source | Repair | Ownership finding removed |
| --- | --- | --- | --- |
| a malformed boot sector or FAT geometry (signature, cluster size, reserved sectors, FAT count, sector counts, exFAT, version, FSInfo sector 0, data area, cluster count, root cluster, FAT size) | `boot.c:56-318` | none: fatal | |
| `Invalid signature in fsinfo block` | `boot.c:206-236` | write the FSInfo sector's signatures, `RRaA` at 0, `rrAa` at `0x1e4`, `00 00 55 AA` at `0x1fc`, and both hints unknown, `FFFFFFFF` at `0x1e8` and `0x1ec` | |
| `FAT starts with odd byte sequence (...)` | `fat.c:865-940` | entry 0 written whole, as FreeBSD's "Correct" writes it: the boot sector's media byte, then `FF` on FAT16, `FF FF 0F` on FAT32; entry 1 written whole at the end (step `clean`) | |
| the first entries in the dirty form | `fat.c:873-886`, which compares FAT32's dirty form exactly; `fsck_fat` ignores its reserved top bits ([Where the repairs differ](#where-the-repairs-differ)) | mark the volume clean at the end | |
| `Cluster N continues with out of range cluster number M` | `fat.c:994-1001` | end the chain at N | a link that is no cluster |
| `Cluster N crossed another chain at M` | `fat.c:1003-1012` | end the chain at N, the later of the two linking entries | a cluster linked to twice |
| `Root directory doesn't start a cluster chain` | `dir.c:251-255` | none: fatal | |
| `Cluster chain starting at N ends with cluster marked TYPE` | `fat.c:1101-1123` | end the chain before the bad link; when no cluster of it is valid, the name's first cluster and size set to 0 | a reached cluster that is free or bad |
| `PATH has entries after end of directory` | `dir.c:633-660` | turn the end markers before those entries into deleted entries, so the entries are read | |
| `Invalid long filename entry for NAME`, `... at end of directory PATH`, `... for volume label` | `dir.c:348-380` | delete the run's entries | |
| `invalid long name`, `long filename too long`, `long filename record cluster start != 0` | `dir.c:686-745` | the run is invalid, deleted as above | |
| `PATH starts with cluster out of range(N)`, `PATH doesn't start a new cluster chain` | `dir.c:846-880` | a directory's entry deleted; a file's first cluster and size set to 0 | a first cluster that is no cluster, named twice or linked to; a subdirectory at cluster 0 |
| `Directory PATH has size != 0` | `dir.c:886-896` | size set to 0 | |
| `` `.' entry in PATH has incorrect start cluster `` | `dir.c:900-911` | set to the directory's own | a wrong `.` |
| `` `..' entry in PATH has non-zero start cluster ``, `` ... incorrect start cluster `` | `dir.c:913-941` | set to 0 under the root, else to the parent's | a wrong `..` |
| `check_subdirectory: Incorrect `.' for NAME.`, `... `..' ...` | `dir.c:475-538`, `:964-976` | delete the entry | |
| `Directory entry PATH of size N referencing invalid cluster M` | `dir.c:400-417` | first cluster and size set to 0 | as for the file case above |
| `size of PATH is N, should at most be M` | `dir.c:434-445` | size set to the chain's | |
| `PATH has too many clusters allocated` | `dir.c:446-460` | end the chain after the size's last cluster; the tail becomes a lost chain. An empty file holding a cluster, which FreeBSD finds here at every run, has its first cluster set to 0, so that cluster becomes a lost chain, named or kept | |
| `Lost cluster chain at cluster N` / `M Cluster(s) lost` | `fat.c:1285-1300` | named in `LOST.DIR`, or kept ([Lost chains](#lost-chains)) | |
| `Free space in FSInfo block (N) not correct (M)`, `Next free cluster in FSInfo block (N) invalid` / `not free` | `fat.c:1307-1334` | both hints written unknown | |
| the volume dirty | `check.c:161-174` | mark the volume clean at the end | |

Two of FreeBSD's messages cannot occur in its own order of examination,
so the checker has no finding for them: `Cluster chain starting at N
ends with cluster out of range (M)` (`fat.c:1112-1116`), since phase 1
has already ended every chain at a link out of range; and `NAME entry
in PATH has incorrect start cluster` (`dir.c:947-962`), since a
directory's own chain is walked before its entries are read, so an
entry naming that chain is found first as `PATH doesn't start a new
cluster chain`, or, at FAT16's root, whose first cluster is 0, as
`PATH starts with cluster out of range(0)`.

erXos adds three findings of its own, in [Where the repairs
differ](#where-the-repairs-differ): FAT copies that differ, loops of
lost clusters, and a `.` or `..` entry outside a directory's first two
slots, which is deleted, since the ownership check refuses it and
FreeBSD looks only at the first two.

A long-name run is invalid when a new last part (the first entry of a
run) starts before the earlier run reaches its short entry; when an
order number breaks the sequence, or a checksum differs inside the run;
when an order number is 0; when the name is too long; when the entry's
cluster field is not 0; when the short entry's checksum differs; when a
volume label follows the run; or when the directory ends first
(`dir.c:661-743`, `:765-790`, `:1022-1026`). A deleted entry does not
end a run (`dir.c:624-631`). So the stick's pattern is found: the
orphan's run is followed by the later name's last part, which starts a
new run before the orphan reaches a short entry. The orphan's entries
are deleted, and the later name keeps its long name.

### Lost chains

A lost chain is named as a file in the root's `LOST.DIR` when all of
these hold: the directory exists; one of the slots in the clusters it
already has is free (a deleted slot, or the end marker), and the nearest
entry before that slot that is not deleted is not a long-name entry, so
the new entry never ends another name's run; no entry there has the
chain's name; and the chain's length times the cluster size fits the
entry's four-byte size. The name is the chain's first cluster in
decimal, at most seven digits within the cluster bound, so it is always
a valid 8.3 name; the entry is FreeBSD's, attributes and dates 0, the
first cluster and the size set. A lost chain that fails any of these is
**kept**: it stays allocated, unnamed, and the finding says why
(`kept: no /LOST.DIR`, `kept: /LOST.DIR has no free slot`,
`kept: /LOST.DIR/51000 exists`, `kept: larger than 4 GiB`).

A kept chain is wasted space, not an inconsistency: the ownership check
does not look at clusters no name reaches, so the volume is marked clean
and mounts writable. To recover kept chains as files, the user makes the
directory (`mkdir /media/disk0/s1/LOST.DIR`, which the next report
suggests) and runs the command again; to reclaim the space, they delete
the recovered files.

A loop of lost clusters is cut at its lowest cluster and then handled as
any lost chain.

### Where the repairs differ

| Case | FreeBSD | erXos, and why |
| --- | --- | --- |
| FAT32's dirty form with entry 0's or entry 1's reserved top four bits set | `FAT starts with odd byte sequence` and its "Correct" (`fat.c:865-886`), since its dirty form is compared exactly | the dirty form, marked clean at the end: the reserved bits are ignored as both FreeBSD and `fsck_fat` ignore them in the clean form, since a FAT32 entry keeps its top bits on every write, the FAT server's dirty flag among them, so a volume formatted with them set reads dirty to the server and to `fsck_fat` alike |
| FAT12, sectors other than 512 bytes, mirroring off | checked | refused, nothing read past the boot sector: the FAT server serves none of them, and repairing a volume of one live FAT from the first copy would write from a FAT that may be stale |
| what a FAT volume and a long-name entry are | FreeBSD's own predicates: a long-name entry has attributes exactly `0x0f`; a boot sector by `boot.c`'s tests | the FAT server's decoders: a boot sector by `erx_fat_read:boot_sector/1`, a long-name entry by attributes `0x0f` under mask `0x3f` (`erx_fat_entry.erl:12`), an FSInfo sector outside the reserved area read as absent. The checker examines the volume erXos reads, so its verdict and the mount's agree; a volume that `erx_fat` does not admit is refused, naming the reason |
| when writing starts | as it goes, the first FAT through `mmap`, no dirty flag set | after the whole check; each step read, patched and written after the step before it was flushed; the dirty flag first, the clean flag last (FK-R3) |
| FAT copies | never compared | `FAT N differs from FAT 0`, repaired by making every copy equal to the first in the `mirrors` step: the FAT server keeps the copies equal on a clean volume, and fsimg's verify refuses a clean one whose copies disagree. Only the part of each FAT that holds the volume's entries is read and compared |
| a loop of lost clusters | never found | `Cluster N closes a loop of lost clusters`, at its lowest cluster; cutting the link into that cluster makes the loop a lost chain |
| `.` or `..` outside the first two slots | not examined | `` `.' entry in PATH outside the directory's first two slots ``, the entry deleted |
| a lost chain with no `LOST.DIR`, no free slot or a name taken | the chain freed | kept allocated and reported ([Lost chains](#lost-chains)). Freeing it throws away a user's data, and creating or growing `LOST.DIR` would allocate during a repair, which an interrupted run can turn into lost space that the rerun then lacks |
| a lost chain larger than 4 GiB | named, its size stored as the low 32 bits, so a later check sees too many clusters and frees most of it | kept allocated and reported |
| a file's clusters past its size | freed | the chain ended after the size's last cluster; the tail is a lost chain, named or kept, since it may hold data a cut write left there |
| a chain with no valid cluster | its first entry written free, a bad cluster among them | the name's first cluster and size set to 0; the FAT entry left as it reads |
| a directory named by two entries | an assertion (`fat.c:1056-1057`) | `PATH doesn't start a new cluster chain` at the second entry, which is deleted, as FreeBSD's directory case is |
| FSInfo hints | exact values | unknown, as the FAT server's dirty step writes them; every reader recounts, and fsimg and FreeBSD accept unknown |
| FSInfo signatures | checked and written through offset `0x3ff`, the last four bytes of the sector after FSInfo included | the FSInfo sector alone: the sector after it may be the first FAT's, which a signature written there would damage |
| `-n` over an odd FAT header or a bad FSInfo signature | the question declined: no error recorded, exit 0, and FSInfo then not checked | a finding not repaired: exit 8, and the hints are checked as for any volume |

### Bounds

Every bound is checked before the structure it limits grows past it. A
volume that would pass one is refused, naming the bound, with nothing
written. The command declares `-erx_heap(16)`
([design-shell.md](design-shell.md)), and the bounds keep what it holds
within a third of that, so the copying collector has room and the
runtime's heap limit is never what stops a check: a kill at that limit
is a bug, and the fuzz target fails on one.

| What is held | Bound | At most |
| --- | --- | --- |
| the clusters some entry links to, the clusters a walk has reached, and the numbers `LOST.DIR`'s entries are named | one bit per cluster each, the third made when the first lost chain is named, at most 4,194,304 clusters, the ownership check's limit; a larger volume is refused before any FAT sector is read but the one admission reads for the volume's flags | 1.5 MiB |
| the directory frames and the subdirectories they wait on, with their names | measured as 64 bytes each plus its name's bytes and six bytes for each slot of its entries, kept so a second name of it can be deleted, within 1 MiB: at most 16,384, the ownership check's stack bound, with short names, and about 2,300 with 255-byte long names; a volume past it is refused, with nothing written | 1 MiB |
| the FAT sector cache | 64 sectors | 32 KiB |
| edits, and the view's index of them by sector | 12,288 edits | 2 MiB |
| findings | measured as 64 bytes each plus its path's bytes, within 1 MiB; a path keeps at most its last 1,024 bytes, its earlier names shown as `...` | 1 MiB |
| the sectors of one commit of a repair, as read and as written; for `mirrors`, the copy's sectors and the first FAT's | 256 sectors each ([The repair order](#the-repair-order)) | 256 KiB |
| the final ownership check | its own sets and stack, after the checker's sets are dropped | as at a mount |

Text is escaped as each line of the report is written, and no escaped
copy is held.

**Work.** Every read is of a sector the geometry names, within the
file. The used part of the first FAT, the entries up to the last
cluster's, is read in order three times: phase 1, phase 3, and the loop
pass; a chain walk reads at most one FAT sector a step past the cache, so
the walks read at most a few sectors per cluster.
The used part of each other copy is read once, to compare it. Each
directory cluster is read once in the walk, and a finding's path reads
at most 512 more, the nearest ancestors' entries. The final ownership
check reads the FAT twice and every directory once, as at a mount.
Writing reads each sector it patches, and the `mirrors` step reads the
used part of every FAT once more. No part of a FAT past its last
cluster's entry is read or written. Each read and write is bounded by
the window's deadline, 35 s.

## Writing a repair

### The repair order

Each step is computed when its turn comes, from what the medium then
holds: `erx_fat_check:write/4` reads every sector the step's edits fall
in, patches the edited bytes, and writes the images through
`erx_fat_plan:apply/4`, which writes them and flushes. The steps:

1. **`dirty`, `dirty_mirrors`**: `erx_fat_alloc:dirty/1` over the
   medium as it reads: the clean bit cleared in the first FAT, then in
   the other copies; the FSInfo hints written unknown.
2. **`preparation`**: directory entries that come to reach less or that
   lie out of view: entries deleted (invalid long-name runs, a second
   name of a cluster, a subdirectory naming its parent, a `.` or `..`
   out of place, a bad `.` or `..` of a subdirectory), a first cluster
   and size set to 0, sizes shrunk, a directory's size set to 0, and any
   fix to an entry behind an end marker.
3. **`cutting`**: in the first FAT, every end-of-chain mark a repair
   sets (a cross-link, an out-of-range link, a link to a free, bad or
   reserved cluster, a loop, a file's tail past its size), and entry 0
   when the header is odd. A cut frees nothing: what it cuts off becomes
   lost. It follows `preparation`, because a cut makes the cluster after
   it the start of a chain, and a name that started there inside the
   chain (`PATH doesn't start a new cluster chain`) would take it on a
   run after a cut between the two; once `preparation` has removed that
   name, the cluster can only become a lost chain.
4. **`publication`**: directory entries that come to reach more or are
   corrected in place: the names of lost chains in `LOST.DIR`, the end
   markers turned into deleted entries, and the `.` and `..` fixes.
5. **`fsinfo`**: when the FSInfo sector's signatures were wrong, the
   signatures and both hints written unknown together. Step 1 writes
   the hints only into a sector whose signatures it accepts, so a
   sector that lacked them still holds whatever hints it held, and
   writing the signatures alone would make those stale hints valid.
6. **`mirrors`**: every copy made equal to the first FAT: each used
   sector of a copy that differs from the first FAT's is written with
   the first FAT's.
7. **`clean_mirrors`, `clean`**: entry 1, in the other copies first and
   in the first FAT last, by `erx_fat_alloc:finish/1`. That function
   takes the value to write: for the FAT server, the clean bit set and
   the hard-error bit as read; for a repair, FreeBSD's "Correct" value,
   `FFFF` on FAT16 and `0FFFFFFF` on FAT32, which sets the no-hard-error
   bit too.

Every step is written in **commits** of at most 256 sectors, 128 KiB,
each read and written in requests of at most a raw file's largest,
64 KiB, the file protocol's `p9_io_max`: a commit reads its sectors, writes their
patched images and flushes, and its images are dropped before the next
commit reads. A commit is a subset of its step's sectors made durable
early, a state the crash argument below already allows for any subset,
so splitting a step changes nothing it promises, and no step holds more
than one commit's sectors whatever the repair's size. Steps with
nothing to write are skipped. An empty repair writes nothing.

### Why a cut loses nothing

* **It reads dirty.** The first FAT loses its clean bit before any other
  write and gets it back in the very last.
* **Every allocated cluster stays allocated.** No step writes a free
  value into the first FAT: a cut writes an end-of-chain mark into an
  entry that was a link, and the copies only follow the first FAT. So a
  cluster's allocation, as every reader of a mirrored volume reads it
  from the first FAT, never changes.
* **No name newly reaches a free cluster.** Nothing is freed, and the
  only names added are those of lost chains, which are allocated.
* **No new sharing.** Step 2 only takes names away and step 3 only takes
  links away, after every name that started inside a chain is gone, so
  the cluster a cut makes the start of a chain is no name's. Step 4 adds
  names only to lost chains, each named once, after step 2's flush, so
  the name a chain had before is gone when its new one lands. An entry
  that becomes readable again had its own fixes written in step 2,
  while it was still out of view.
* **Running again keeps every kept file.** Every finding is derived
  again from the medium, and every partial state is a finding of the
  table: chains cut and their tails lost, names removed, sizes not yet
  shrunk, lost chains not yet named, copies not yet equal, a volume
  marked dirty. The rerun repairs each the way the uninterrupted run
  would have, and nothing the interrupted run wrote took away a cluster
  or a name that a kept file needs.
* **No step undoes another.** Each step reads its sectors after the step
  before it was flushed, so its images hold every earlier step's bytes:
  a cut in the first FAT's first sector keeps the dirty flag that step 1
  cleared there, and the `fsinfo` step writes the unknown hints with
  the signatures it repairs.

FAT entries never straddle a sector and each directory entry lies within
one, so every entry a step writes lands whole or not at all.

The checker assumes that the volume does not change between its reads
and its writes, as FreeBSD's does. On a drive, no mount writes it while
the command holds its writing open; another program writing the same
raw file at the same time is that user's doing.

### Clearing the flag at mount

A stick pulled without `eject` often holds nothing worse than its dirty
flag. The volume's process clears that flag itself when nothing else is
wrong ([design-drives.md](design-drives.md#the-writable-rule)): when
`dirty` is the only writable-rule condition that fails, it runs
`erx_fat_check` in its **first-finding mode**, which stops at the first
finding other than the dirty mark. If there is none, the process writes
a repair whose only steps are `clean_mirrors` and `clean`, through
`erx_fat_plan:apply/4`, and mounts the volume writable. Any other
finding, a bound, or a read, write or flush that fails keeps the volume
read-only `dirty`, and nothing more is written. A lost chain is a
finding, so a volume cut while a file was growing stays read-only for
`fsck_fat`.

The check repairs nothing, because some repairs delete entries or cut
files, and those are written to a stranger's medium only when the user
asks, by running `fsck_fat`. The mode holds no findings and no edits,
so its bounds are the ownership check's, which a mount already keeps.

### The FAT server's side

An orphan long-name run comes from a cut, and a cut leaves the volume
dirty, so a repair or the check at mount meets the orphan before erXos
writes there again. What remains is a volume whose flag another system
cleared without removing the orphan. For it, `place/5` takes no slot
whose nearest earlier entry that is not deleted is a live long-name
entry, for every name, extending the rule that already holds for a name
stored as its short entry alone. It looks past deleted slots, since a
deleted entry does not end a run
([design-storage.md](design-storage.md#removable-media-fat)). A name's
short entry gets no step of its own: that would keep a cut from ever
leaving an orphan, but at two more flushes for every batch that removes
or adds a long name, for a case the dirty flag already covers.

## The surface

### Options

Each option is kept only where it has a consumer and does what its name
says:

| Option | FreeBSD | erXos | Why |
| --- | --- | --- | --- |
| `-n` | answer no to every question; open read-only | check, print the repair, write nothing | a user looking before changing anything, and scripts; the file is opened for reading only, so the volume stays mounted |
| `-y` | answer yes to every question | apply the repair without asking | unattended repair |
| none | one terminal question per repair | print the whole repair, then one question: apply it all or nothing | FK-R4. Repairs depend on each other, so answering some and not others gives a half repair that leaves the volume dirty, which helps nobody. One repair shown whole and applied whole is what the user can judge |
| `-p`, `-f` | preen at boot; `-f` preens clean volumes too | dropped, a usage error | nothing preens: no FAT volume is mounted at boot, and a dirty volume's own mount clears its flag only when nothing else is wrong, repairing nothing ([Clearing the flag at mount](#clearing-the-flag-at-mount)). Checking skips no volume because its flag reads clean, since the stick's damage was on one |
| `-B`, `-C`, `-M`, `-F` | ignored, ignored, no `mmap`, exit 5 | dropped, usage errors | they exist for FreeBSD's `fsck(8)` and its memory handling; nothing here uses them |

`-n` and `-y` together are a usage error, not "the later wins".

`fsck_fat [-n | -y] file ...` checks each file in turn. The file is a
drive volume's `sN.data`, or any file of 512-byte sectors holding a FAT
volume, an image in `/tmp` among them, as FreeBSD's checks an image as
readily as a disk. A directory, `/media/diskN/sN` itself, is refused
with `fsck_fat: PATH: a directory; the volume's sectors are
/media/raw/diskN/sN.data`. A file it cannot open is
`fsck_fat: PATH: CAUSE`. A writing open the drive refuses, because a
finish failed or the medium cannot flush, is not retried read-only: the
command reports the refusal and checks nothing, since a check that
cannot write must not look like a repair.

### Exit status

| Status | Meaning |
| --- | --- |
| 0 | the run found nothing, or wrote a repair after which nothing it found is left |
| 8 | something the run found is left: repairs not made (`-n`, or the question answered no), lost chains kept, a fatal finding, a refusal, or a read, write or flush that failed |
| 1 | a usage error |

0 and 8 are FreeBSD's codes and keep their sense, "nothing left to
repair" and "something left", over what the run read. A `-n` run through
a reading open of a volume mounted `rw` reads a volume that can change
beneath it, so its 0 says only that what it read was consistent. An 8
after a failed read says that the run did not finish, not that the
volume is damaged. After lost chains are kept, the report's last line
says that the volume is writable and how to recover them. The status of
several files is the largest.

### The report

```text
/media/raw/disk0/s1.data: FAT32, 1 FAT copy of 2 differs, dirty
1. Invalid long filename entry for /DCIM/IMG_0001.JPG
   delete 3 long-name entries in /DCIM; IMG_0001.JPG keeps its own name
2. Cluster 40213 crossed another chain at 40214
   end /notes.txt's chain at cluster 40213: it keeps 98304 of 131072 bytes
3. Lost cluster chain at cluster 51000, 4 Cluster(s) lost
   name it /LOST.DIR/51000, 131072 bytes
4. FAT 1 differs from FAT 0
   copy FAT 0 over FAT 1
5. the volume is marked dirty
   mark it clean
3 files, SIZE free (459000 clusters)
Apply 5 repairs to /media/raw/disk0/s1.data? [yn] y
5 repairs written; nothing left to repair
```

Each finding is FreeBSD's sentence, and under it what the repair changes,
in terms of the files it touches and the bytes a file loses, so a repair
that costs data says so before it is made. Names and labels from the
medium pass through the field escape
([design-app-trees.md](design-app-trees.md#a-status-line)). Every
finding is listed: a check whose findings pass their bound is refused
instead ([Bounds](#bounds)). Under `-n` the question is replaced by
`5 repairs needed; fsck_fat -y applies them`. A fatal finding or a
refusal is one line, `PATH: MESSAGE`. The question reads one line from
standard input: `y` or `Y` applies the repair, and anything else, or end
of input, writes nothing.

When the file is a drive's `sN.data` and the drive's `status` shows
`sN_mount rw`, a `-n` run's first line says `mounted rw`, since its
reads can meet a batch half written, and its findings may be ones the
volume's next batch removes.

### `fsck`

`fsck [-n | -y] [-t fat] volume ...` names volumes as a user knows
them, `/media/diskN/sN`, and runs `fsck_fat` on each one's
`/media/raw/diskN/sN.data` with the same flag. Without `-t`, the format
comes from the drive's `status` (`sN fat`). A volume of another format,
or of none the probe knows, prints `fsck: PATH: no checker for NAME
volumes` or `fsck: PATH: unknown format; give -t`, and counts as status
8. A session that holds no `media_raw` grant has no
`/media/raw/diskN`, and `fsck` says so: `fsck: PATH: no raw sectors in
this session`. With no volume named, `fsck` refuses with `fsck: name a
volume`, since erXos has no fstab to take a list from. Other options are
usage errors.

### Other programs

Any program may open the same files: a ported `dd` or `newfs_msdos`, a
FreeBSD tool brought over, or a user's own repairer, in Erlang or
native. What it needs:

* a namespace entry on a `media_raw` grant, which a session that holds
  one hands to the programs it starts. A starter that hands a native
  program `/media/raw/diskN` hands it that drive alone, and `ro` lets it
  read the drive and write nothing
  ([design-drives.md](design-drives.md#raw-sectors)). No entry confines
  a program to one volume: an entry's root is a directory, and a drive's
  directory holds its `data`;
* offsets and counts that are multiples of 512, a count of at most
  64 KiB, the file protocol's `p9_io_max`, and writes within the file's size, which `stat` gives; a read
  that runs past the end answers the sectors up to it. erXos's POSIX
  layer offers no disk `ioctl`, so a port replaces FreeBSD's
  `DIOCGMEDIASIZE` and `DIOCGSECTORSIZE` with `stat` and 512;
* `fsync` wherever it needs order or durability, since that is the only
  flush;
* to treat what it reads as a stranger's bytes, and to expect `eio` when
  the medium leaves;
* to know that its writing open takes the volume, or for `data` the
  whole medium, out of service until its last close, and is refused on
  a medium that cannot flush.

An Erlang program can reuse `erx_fat_check` as `fsck_fat` does. Nothing
in the media domain knows which program holds the file.

## Concurrency

The drive process takes a drive's requests one at a time, so a writing
open waits for the volume's finish and no mount starts while it lasts
([design-drives.md](design-drives.md#raw-sectors)). Walks of the drive's
other volumes go on. The volume returns to service only once every raw
request sent before the last writing close has been answered and the
medium flushed, so the next mount reads nothing the command still has in
flight. Interrupting the command is a cut (FK-R3). `eject` during a
repair finishes the raw files as it finishes volumes: later raw requests
answer `eio`, and what was answered before the eject is flushed. That
too is a cut. The ordered end does the same, with later writes answering
`erofs`.

## Failure handling

| Failure | Detected by | What is left | Recovery | Reported |
| --- | --- | --- | --- | --- |
| a bound would be passed during the check | the bound's own test | the medium as it was | the last close returns the volume | `PATH: MESSAGE` naming the bound; status 8 |
| a read fails during the check | the read function | the medium as it was | the same | `PATH: read failed: CAUSE`; 8 |
| the first `fsync` fails | the command | the medium as it was | none needed | `PATH: cannot flush (CAUSE); nothing written`; 8 |
| a write or flush fails, or the command is interrupted, during the repair | `erx_fat_check:write/4` | a cut (FK-R3) | run `-y` again; the volume mounts read-only `dirty` meanwhile | `PATH: write failed: CAUSE; run again`; 8 |
| the medium is pulled | `eio` | a cut, or nothing written | the same | the same |
| the command passes its heap limit | the runtime | a cut, or nothing written | as above | `killed`; 8. A bug: the bounds are meant to make it impossible |

No recovery machinery is added: an interrupted repair is finished by
running the command again.

## Refusals and error results

* Usage (exit 1): an unknown option, `-n` with `-y`, no file.
* Exit 8, nothing written: a directory or a file that cannot be opened;
  a writing open the drive refuses; a volume `erx_fat` does not admit,
  with the reason, a volume longer than its file among them; FAT12;
  sectors other than 512 bytes; FATs not mirrored; any bound of
  [Bounds](#bounds); a repair after which the ownership check would
  still fail (`not_writable`); a first `fsync` that fails; a fatal
  finding.
* `fsck`: no volume named; a format with no checker; an unknown format
  without `-t`; no raw sectors in the session.

## Security

`fsck_fat` runs as an Erlang command in the session's domain, with
the session's authority, which the user typed it with
([design-shell.md](design-shell.md)). It parses a stranger's volume
there, by the user's choice: its decoders are Erlang within bounds
checked before every growth, so a crafted volume is refused, and cannot
reach memory. The raw files reach only the drives a `media_raw` grant
serves, which is every drive of the media domain; a native program
reaches what its starter's narrowing leaves it, and what a hostile
holder can do is stated in
[design-drives.md](design-drives.md#raw-sectors). The media domain
mints no grant narrower than every drive, so no Erlang code is confined
to one drive: an Erlang command holds its domain's grants whole. The
report escapes every name from the medium, so printing it cannot drive
the user's terminal. Nothing is written without `-y` or a "y".

**Raw access in a release.** Development board manifests grant root's
session `media_raw`. A release has no blanket grant: native programs
inherit the session's namespace unless their starter narrows it, so
every program root starts would reach every drive's sectors. A release
board manifest that promises local drive repair names `media_raw` for
root's session in a row of its own, and the manifest check refuses a
`media_raw` row to any grantee but the system domain and root's session
template, since a stick's owner repairing it is the consumer
([design-drives.md](design-drives.md#raw-sectors)).

## What is reused and what is new

Reused: `erx_fat_read:boot_sector/1` and `erx_fat`'s admission rules,
given the file's length, so the boot sector has one decoder;
`erx_fat_entry`'s `decode/1`, `encode/1`, `deleted/1`, `with_first/2`
and `with_size/2`, the checker reading a long-name entry's cluster field
itself, since `decode/1` also answers `bad_long` for a non-zero type
byte, which FreeBSD does not check; `erx_fat_name:checksum/1`;
`erx_fat:layout/1`, `cluster_sectors/2`, `with_read/2` and `check/1`;
`erx_fat_alloc:dirty/1` and `finish/1`; `erx_cmd`; the drives' raw
files.

New: `erx_fat_check`, which decides the findings and edits and writes
them step by step; `erx_fat_plan:apply/4`, the write of a plan's steps, each
step's sectors and then a flush, taken out of `erx_media_volume:applied/2`, which
then calls it with its plans; a reason with each admission refusal of
`erx_fat`, so the checker can print what is wrong; `finish/1`'s value
for a repair; the commands `fsck_fat` and `fsck`; and the test
generator of damaged images.

The checker needs nothing of `erx_fat_alloc`'s allocation or release and
nothing of `erx_fat_dir`'s placement, since a repair allocates and frees
nothing.

## Verification

Each passing case is paired with a seeded fault that must make it fail,
so a pass shows the code under test ran.

### Damaged images

A host generator, `test/erlang/erx_fat_damage.erl`, writes each class of
damage into a FAT16 or FAT32 image that fsimg or the FAT server's host
build made. For each row of both tables above, it changes the bytes a
declared case names: a FAT entry, an entry's field, a run's order
number. It writes only damage on which FreeBSD's predicates and erXos's
agree (textual `FAT` in the boot sector, long-name attributes exactly
`0x0f`, FSInfo within the reserved area), so the oracle compares like
with like. The images, the stick's pattern among them, are generated in
the build tree and never committed. Each case declares its findings and
the tree, names, sizes and content hashes, that the repair must give.

### Host tests

| Test | Seeded fault that must fail it |
| --- | --- |
| each class through `erx_fat_check:check/2`: the declared findings and repairs; the repair written, then a second check finding nothing but kept lost chains, `erx_fat:check/1` answering `ok` and the writable rule allowing `rw` (FK-R2) | each repair removed in turn (cross-link cut, loop cut, copy sync, `..` fix): the second check finds it, or `check/1` answers `tree` |
| the final ownership check: a directory with a second `.` in slot 5 is repaired; a checker built without that row refuses the volume with `not_writable` instead of answering a repair | the final check skipped, so the checker without the row answers a repair after which the volume mounts `ro tree` |
| the order of examination: two files sharing a tail, and a file and a directory naming one chain, repaired as FreeBSD chooses | the FAT walk run from the last cluster down, so the other file is cut |
| each step computed at its turn: a repair with a cut in the first FAT's first sector, the odd-header fix and an FSInfo signature fix, written over a fake medium that records every write; after each step the first FAT's entry 1 reads dirty, the FSInfo hints read unknown after the `fsinfo` step, a sector whose lead signature was damaged over stale hints among them, and only the last write sets the clean bit | the steps' images computed from the medium before the first write, so the `cutting` step writes back the clean bit the `dirty` step cleared; the `fsinfo` step writing the signatures alone, so the damaged sector's stale hints read valid |
| crash consistency (FK-R3): for each class's repair on a small image with sentinel sectors around the volume, a cut after every step and after every subset of a step's sectors; each result reads dirty unless the cut followed the last write, keeps every cluster allocated in the input allocated, adds no name to a free cluster and no second name to a cluster; then a second run meets FK-R2, every file the uninterrupted repair keeps reads at its path with its content hashes, and the sentinels and the file's length are unchanged | the `publication` step placed before `preparation`, so a cut leaves a lost chain named while its old name stands; the dirty step left out, so a cut leaves a half repair that reads clean; a file's tail freed instead of cut, so a cut and a rerun lose its clusters |
| clearing the flag at mount: a dirty volume with nothing else wrong mounts `rw` with only entry 1 of each FAT written; one with a lost chain, differing copies or a cross-link stays read-only `dirty` with nothing written | the first-finding mode answering after the dirty mark alone, so the volume with a cross-link mounts `rw` |
| the FAT server's own cut: `erx_fat_dir`'s removal of a name whose run crosses a sector boundary, cut between the two sectors of its `preparation`, leaves an orphan run that the check reports and the repair removes | a deleted entry ending a run, so the orphan is read as the next name's |
| lost chains: with a free slot in `LOST.DIR`, named; with no `LOST.DIR`, a full one, a name taken and a chain of 4 GiB, each kept, reported, the volume marked clean and status 8; a free slot after an orphan long-name run passed over | the size stored as its low 32 bits, so the 4 GiB chain is named with size 0 and the second check finds too many clusters |
| a truncated image: its boot sector claims more sectors than the file holds; refused before any write, the file's length unchanged | admission given the boot sector's count instead of the file's, so the image is checked and written |
| the first flush: a fake medium whose `fsync` answers `enotsup` is refused with nothing written | the first `fsync` dropped, so the dirty step lands before the failure |
| bounds: 4,194,305 clusters refused with nothing read but the boot sector and the FAT sector admission reads; directories past their bound refused; findings past their bound and edits past 12,288 refused with nothing written; a repair of 12,288 edits in distinct sectors written with the process's memory, its binaries included, never above a third of its heap; a path of 16,384 levels shown as its last 1,024 bytes | the findings' bound removed, so an image of 100,000 lost chains ends the command at its heap limit, which the test counts as a failure; a step's images built whole, so that repair's memory passes a third of the heap |
| refusals: FAT12, 1,024-byte sectors, mirroring off, each with no write | the mirror test dropped, so a volume whose active FAT is 1 is repaired from FAT 0 |
| `fsck_fat` over a file and over a fake raw file: `-n` writes nothing and exits 8 on damage, 0 when clean; the question answered `y` writes the repair and exits 0, `n` and end of input write nothing and exit 8; `-y` asks nothing; `-p`, `-f`, `-n -y` and a directory are refused; the report lists every finding before the question | the repair written before the question; the exit status 0 after a declined repair |
| `fsck`: a volume path mapped to its `sN.data`, the format from `status`, `-t fat` on an unknown format, no volume named refused, a session without `media_raw` told so | the format read from the file's own boot sector instead of `status`, so an EROFS volume reaches `fsck_fat` |

### Fuzz target

`erx_fat_check` over mutated images, seeded from every damaged image,
in a process whose heap limit is the command's: no crash and no kill,
every bound kept, and wherever a repair is answered, the repair written
to the image followed by a second check that finds nothing but kept
lost chains. Each round ends within a deadline and reads at most eight
times the volume's sectors. A copy whose phase 1 keeps a chain that
links to a cluster linked to before must fail on a looped image, its
walk following the loop past the deadline.

### The oracle

The FreeBSD 15.1 oracle guest that the command shell's tests use
([design-shell.md](design-shell.md#verification-and-testing)), in QEMU
without a network device, takes each damaged image as a disk of its own,
a fresh copy per run, and runs `fsck_msdosfs -n` and `fsck_msdosfs -y`.
For each image the run passes when `-n`'s exit status equals erXos's;
when the findings FreeBSD's `-y` run prints, matched by message, equal
erXos's findings, FreeBSD's two lines `Lost cluster chain at cluster N`
and `M Cluster(s) lost` matching erXos's one lost-chain finding; and when, after both `-y` runs, FreeBSD's `-n` exits 0
on erXos's image, erXos's check finds nothing on FreeBSD's, and both
read back, through `erx_fat` on the host, to the same names, sizes and
contents. A class in
[Where the repairs differ](#where-the-repairs-differ) is compared only in
its other findings, and the read-back comparison leaves out what that
class changes (kept or named lost chains, free cluster counts). It runs
at the milestone gate. Seeded fault: a cross-link cut at the earlier
entry instead of the later one makes the comparison fail on the
shared-tail image.

### QEMU case

In the `usb` suite: a FAT32 stick carrying the stick's pattern, a
cross-linked file, a lost chain, a `LOST.DIR` with a free slot and its
dirty flag set mounts read-only `dirty`.
`fsck_fat -n /media/raw/disk0/s1.data` exits 8 and leaves the stick's
bytes unchanged, and the volume stays mounted. `fsck_fat -y` exits 0;
while it ran, `status` showed `s1_mount none raw`; afterwards the volume
shows `s1_mount rw`, every kept file reads with the harness's hashes,
and the stick, read on the host after `eject`, passes fsimg's verify. A
second stick is detached with `device_del` during its repair, comes back
read-only `dirty`, and a second `-y` repairs it, every file the first
stick kept reading with the same hashes. Seeded faults: the last close
not returning the volume, so it stays `none raw`; the dirty step left
out, so the detached stick mounts `rw` with half a repair.

## Alternatives considered

**The check as a system service.** The volume's own process could run
the check by a remount, and report through a file of the media tree. It
would keep every byte of a medium in the media domain. It loses: there
would be one checker, the system's, and no user could run a better one,
`dd` or a formatter. The raw files give every program the same access,
and the checker stays reusable as a library.

**Precomputed sector images.** The checker could answer every step's
sector images up front, as `erx_fat_dir` answers a batch's. A later
step's image of a sector would then start from the medium as read, not
as the earlier steps left it, and could write back what they changed:
the clean bit, an entry, the FSInfo hints. Computing each step at its
turn from the medium is the FAT server's own order, and costs one read
of each sector written.

**Creating or growing `LOST.DIR`.** It would name lost chains on the
many sticks that have no `LOST.DIR`. It allocates during a repair, and
an interrupted run then leaves the new directory's clusters as one more
lost chain, which can take the last free cluster the rerun needed; a
rerun that then freed chains for want of room would lose data the
finished repair kept. Keeping a chain allocated and telling the user to
make the directory costs one command and loses nothing.

**FreeBSD's per-question prompts and preen defaults.** They make sense
for a checker that writes as it goes. With the whole repair known before
anything is written, a partial answer only produces a partial repair,
and preen has no caller on erXos.

**FreeBSD's C as a native program.** Possible through the raw file, by
anyone. As erXos's own checker it would put C over a stranger's bytes,
keep the write-as-you-go order, and share nothing with the FAT server,
whose decoders and ownership check the Erlang checker reuses.

**Only an orphan-run cleaner.** It would fix this stick and nothing else.
Sticks come from cameras, Windows and macOS too.

## Open decisions

None.

## References

* [design-drives.md](design-drives.md): volumes, the writable rule,
  finishing, raw sectors.
* [design-storage.md](design-storage.md#removable-media-fat): the FAT
  server, its batches and steps, the ownership check.
* [design-app-trees.md](design-app-trees.md): the field escape.
* [design-files.md](design-files.md): narrowing a namespace for a
  program.
* [design-shell.md](design-shell.md): Erlang commands and their heap
  bound, the FreeBSD 15.1 oracle guest.
* erXos sources read: `erlang/apps/erx_fat/src/erx_fat_dir.erl`,
  `erx_fat_alloc.erl`, `erx_fat.erl`, `erx_fat_entry.erl`;
  `erlang/apps/erx_media/src/erx_media_volume.erl`;
  `otp/erts/preloaded/src/erx_file_remote.erl`.
* FreeBSD `src`, tag `release/15.1.0`, fetched from
  `https://raw.githubusercontent.com/freebsd/freebsd-src/release/15.1.0/`;
  the same bytes at commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`.
  SHA-256 of each file:
  * `sbin/fsck_msdosfs/boot.c`,
    `1eba590b4b7aefe7a0614759f0ac59ebb5af6914c7919b1072191f9a323ed2c7`;
  * `sbin/fsck_msdosfs/check.c`,
    `736dae5e68cf69aafd1d9e73a392dcf1a301c7116913f73039c85332f46888b7`;
  * `sbin/fsck_msdosfs/dir.c`,
    `a6c4f6e4c33d0f47e9ba3df45d1f762f08ff08e769535e6fcc32e6f4fc55d056`;
  * `sbin/fsck_msdosfs/dosfs.h`,
    `3f875c223f631984e392ff86b9735ea057fd061f59109ab4a114bd862f200897`;
  * `sbin/fsck_msdosfs/ext.h`,
    `829198f3b2419c7f60c3b4db02ba2bc5e30e8c0f2b63d79cf79dd3c6d7bb6fd7`;
  * `sbin/fsck_msdosfs/fat.c`,
    `548d1c3a5bdb954e0dc1791bfe08297bf6a5d24a65ec07f52f88f176e0ed96bb`;
  * `sbin/fsck_msdosfs/main.c`,
    `71d7a02acdcc0709d45e95c658e79154a4fd5728b3b7979cde82c8a8e3c659de`;
  * `sbin/fsck_msdosfs/fsck_msdosfs.8`,
    `4da0df7a98607c84ff421c75a463594a995b97b1b342d6c45494a7f56719477c`;
  * `sbin/fsck/fsck.c`,
    `343b58b3a58de34555f6974a4c88503f773e0566a2ab6ffcc1b74f00fbb29931`;
  * `sbin/fsck/fsck.8`,
    `313da5320316d5e65dbb6836d3725ec50222fae8af45d26d5dff5059e5879d32`;
  * `sbin/fsck/fsutil.c`,
    `1d72a1d33726f1a4ec6fe91f050c378e5604e78354041aa4d10dc8212a100887`.
