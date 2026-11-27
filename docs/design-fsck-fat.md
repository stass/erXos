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
opens the volume's raw sectors, `/media/diskN/sN.data`, which the media
domain serves to a grant of rights `admin`
([design-drives.md](design-drives.md#raw-sectors)). It runs one pure
function from the FAT server's library over them. That function answers
every finding together with the whole repair plan. The command shows
the plan, asks once, and writes it through the FAT server's plan writer,
in an order that keeps the volume marked dirty until the last write.
Then it closes the file. Opening the file for writing takes the volume
out of service, and the last close returns it to the ordinary mount
rule, so the repaired volume mounts writable at its next walk. Any other
program, `dd`, a ported `newfs_msdos` or a user's own repairer, uses the
same file.

Decisions every reader needs:

* **FreeBSD's repairs, erXos's command.** What `-y` changes on a volume
  follows FreeBSD 15.1's `fsck_msdosfs`, the behavioural reference. The
  name follows erXos's own: erXos names the file-system type after the
  file system, `fat`, where FreeBSD says `msdosfs`, so the command is
  `fsck_fat` and `fsck -t fat` runs it. The options,
  the report and the question follow what erXos needs: `-n` and `-y`
  are kept, everything else is dropped, and the whole plan is shown
  before one question for all of it
  ([Options](#options)).
* **Nothing is written until the whole check has run.** The plan is
  decided over an in-memory view of the volume, then written in one go:
  the dirty flag first, references taken away before new ones are added,
  clusters freed last, the clean flag at the very end. A cut at any
  write leaves a volume that reads dirty and has lost nothing the
  finished repair would keep, and running the command again finishes
  the repair.
* **A repaired volume mounts writable.** After `-y` the volume passes the
  FAT server's ownership check. erXos adds three repairs to FreeBSD's
  so that nothing on the volume is still faulted or thrown away: FAT
  copies that differ are made equal, loops of lost clusters are found,
  and a missing `LOST.DIR` is created rather than lost chains freed.
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
hashes are under [References](#references). erXos matches FreeBSD's
repairs, what FreeBSD's `fsck_msdosfs -y` changes on a volume, and keeps the
sentence FreeBSD prints for each finding. What the source shows:

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
  so phase 3 never meets it. Without an existing `LOST.DIR` in the root
  it frees lost chains, and it never grows that directory
  (`dir.c:1097-1131`).
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
  twice or linked to, a wrong `.` or `..`, a reached cluster that is
  free or bad.
* A writable volume's changes are plans, `[{Step, [{Sector, Bytes}]}]`,
  which `erx_media_volume:applied/2` writes, each step's sectors and
  then a flush (`erlang/apps/erx_media/src/erx_media_volume.erl:695-699`).
  `erx_fat_alloc` builds a plan's FAT side, every entry going to every
  copy, and `erx_fat_dir` builds its directory side as one image of each
  sector for each step.
* Raw sectors are served as `data` and `sN.data`
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
`place/5` can put a new name's run in the deleted slot right after the
orphan, since it checks the entry before a run only for a name stored as
its short entry alone (`:524`). That gives exactly the stick's pattern.
This reading found no path to an orphan without a cut, and the stick's
history was not recorded. The repair here removes such runs;
[open decision 2](#open-decisions) is the server's side.

## Requirements

* **FK-R1. FreeBSD's repairs.** On every FAT16 or FAT32 volume of
  512-byte sectors whose FATs are mirrored and that lies within the
  bounds, `fsck_fat -y` finds what FreeBSD 15.1's `-y` run finds and
  leaves the volume as that run leaves it, except for the departures in
  [Where the repairs differ](#where-the-repairs-differ).
* **FK-R2. A repaired volume is writable.** After a run that applied its
  plan, the volume meets the writable rule's FAT conditions: the dirty
  flag clear, no hard error recorded, and the ownership check passed.
* **FK-R3. An interrupted repair leaves the volume no worse.** A cut at
  any write of a repair leaves a volume that reads dirty, on which no
  cluster that a name reaches is free, no two names reach one cluster
  unless two already did before the repair, and every cluster that the
  finished repair keeps in a file is still allocated. Running the
  command again then meets FK-R2.
* **FK-R4. Shown before it is changed.** Unless `-y` is given, nothing is
  written until the user has seen every finding and what its repair
  changes, and has said yes to all of it.
* **FK-R5. No other writer of the volume.** While the command can write,
  no mount of the volume exists, and it cannot start.
* **FK-R6. Untrusted input.** The checker is bounded in memory and time,
  has a fuzz target, and never crashes on a volume; text taken from the
  medium reaches the terminal only through the field escape.
* **FK-R7. No new mechanism.** The design uses the drive's raw sectors,
  the FAT server's library, an Erlang command and the session's
  namespace, each named below.

Non-goals: FAT12, which the drives refuse by name; exFAT; volumes whose
FATs are not mirrored; repairing a partition table; making a file
system; preening at boot, since erXos mounts no FAT volume at boot.

## The construction

### The checker is a library and the medium is a file

```text
session domain                                 media domain
fsck_fat /media/disk0/s1.data
  open s1.data for reading and writing  ---->  drive process: finish s1's mount,
                                               end its process, s1 shows "none raw"
  erx_fat_check:check(Read)  <-- pread ------  erx_media_raw -> window proxy
    -> findings + plan (pure; writes nothing)
  print every finding and its repair
  "Apply 5 repairs to /media/disk0/s1.data? [yn]"
  erx_fat_plan:apply(Plan, Write, Flush) ----> pwrite / fsync = the window's flush
  close  -------------------------------------> last writing close: s1 back under
                                               the mount rule; its next walk mounts it
```

1. **Open.** The command opens the file it is named. `-n` opens it for
   reading only, which disturbs no mount. Otherwise it opens it for
   reading and writing, and the drive process first finishes volume N's
   mount and ends its process, so the volume holds no batch and no other
   writer while the command runs (FK-R5).
2. **Check.** `erx_fat_check:check/1` runs over a function that reads one
   512-byte sector of the file. It is pure: it answers the findings and
   one plan that repairs all of them, or a fatal finding or a refusal,
   and writes nothing.
3. **Show and ask.** The command prints each finding with what its
   repair changes, then asks once whether to apply the plan
   ([The report](#the-report)).
4. **Write.** `erx_fat_plan:apply/3` writes the plan step by step,
   `pwrite` of each sector and then `fsync`, which is the window's flush,
   in the order of [Writing a repair](#writing-a-repair). The volume
   process's writes go through the same function, with the window
   proxy's write and flush, so a plan has one writer.
5. **Close.** At the last writing close the volume returns to the
   ordinary rule: its next walk starts its process, which probes it and
   mounts it by the writable rule, `rw` after a successful repair on a
   medium that flushes (FK-R2).

### How each requirement follows

* **FK-R1.** One pure function decides every finding and repair, with
  FreeBSD's order of examination and its `-y` choices, so agreement is
  tested on the host and against FreeBSD over the same images.
* **FK-R2.** FreeBSD's `-y` repairs leave no finding of the ownership
  check, except for a directory named twice, which erXos repairs; the
  last step clears both flags.
* **FK-R3.** Nothing is written until the plan is whole, and the plan's
  order makes every prefix of it safe
  ([Why a cut leaves the volume no worse](#why-a-cut-leaves-the-volume-no-worse)).
* **FK-R4.** The plan is complete before anything is printed, so what is
  shown is exactly what is written.
* **FK-R5.** The drive's writing open
  ([design-drives.md](design-drives.md#raw-sectors)).
* **FK-R6.** [Bounds](#bounds), and the fuzz target in
  [Verification](#verification).
* **FK-R7.** The names this design adds are the modules `erx_fat_check`
  and `erx_fat_plan`, `erx_fat_alloc:cut/2`, `erx_fat_dir:edit/4` and
  `adopt/5`, and the Erlang commands `fsck_fat` and `fsck`. The raw
  files are the drives design's.

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

`erx_fat_check:check(Read)`, in the `erx_fat` library application, takes
a function that reads one 512-byte sector of the volume. It answers
`{ok, Findings, Plan}`, where each finding is FreeBSD's sentence, the
paths it names, and the change its repair makes; or `{fatal, Finding}`;
or `{refused, Reason}`. It decides as if every repair were made, in
FreeBSD's order, over a **view**: the volume as read, with every repair
decided so far laid over it, so each later decision sees the earlier
ones. Directory changes are kept as `erx_fat_dir`'s per-step sector
images and FAT changes as `erx_fat_alloc`'s overlay, so the view is
`erx_fat_dir:view/1` of the two. There are no questions inside it: the
command applies the whole plan or none of it, so a declined repair can
never change what a later finding sees.

The directory walk keeps one frame per directory on the current path,
each holding the directory's first cluster, the place of its entry, and
the subdirectories found in it and not yet walked. A finding's path is
rebuilt from the frames by reading each ancestor's entry again, so no
name is held for long.

### Findings and repairs

The message is FreeBSD's, with its source. The last column names the
ownership-check finding the repair removes.

| Finding (FreeBSD's message) | Source | Repair | Ownership finding removed |
| --- | --- | --- | --- |
| a malformed boot sector or FAT geometry (signature, cluster size, reserved sectors, FAT count, sector counts, exFAT, version, FSInfo sector 0, data area, cluster count, root cluster, FAT size) | `boot.c:56-318` | none: fatal | |
| `Invalid signature in fsinfo block` | `boot.c:216-236` | write the signatures | |
| `FAT starts with odd byte sequence (...)` | `fat.c:865-943` | write the first two entries in their usual form, the media byte from the boot sector | |
| the first entries in the dirty form | `fat.c:873-886` | mark the volume clean at the end | |
| `Cluster N continues with out of range cluster number M` | `fat.c:994-1001` | end the chain at N | a link that is no cluster |
| `Cluster N crossed another chain at M` | `fat.c:1003-1012` | end the chain at N, the later of the two linking entries | a cluster linked to twice |
| `Root directory doesn't start a cluster chain` | `dir.c:251-255` | none: fatal | |
| `Cluster chain starting at N ends with cluster marked TYPE`, `... out of range (M)` | `fat.c:1101-1123` | end the chain before the bad link, or free it when nothing of it is valid | a reached cluster that is free or bad |
| `PATH has entries after end of directory` | `dir.c:633-660` | turn the end markers before those entries into deleted entries, so the entries are read | |
| `Invalid long filename entry for NAME`, `... at end of directory PATH`, `... for volume label` | `dir.c:348-380` | delete the run's entries | |
| `invalid long name`, `long filename too long`, `long filename record cluster start != 0` | `dir.c:686-745` | the run is invalid, deleted as above | |
| `PATH starts with cluster out of range(N)`, `PATH doesn't start a new cluster chain` | `dir.c:846-880` | a directory's entry deleted; a file's first cluster and size set to 0 | a first cluster that is no cluster, named twice or linked to; a subdirectory at cluster 0 |
| `Directory PATH has size != 0` | `dir.c:886-896` | size set to 0 | |
| `` `.' entry in PATH has incorrect start cluster `` | `dir.c:900-911` | set to the directory's own | a wrong `.` |
| `` `..' entry in PATH has non-zero start cluster ``, `` ... incorrect start cluster `` | `dir.c:913-941` | set to 0 under the root, else to the parent's | a wrong `..` |
| `NAME entry in PATH has incorrect start cluster` (a subdirectory naming its own parent) | `dir.c:947-962` | delete the entry | a first cluster named twice |
| `check_subdirectory: Incorrect `.' for NAME.`, `... `..' ...` | `dir.c:475-538`, `:964-976` | delete the entry | |
| `Directory entry PATH of size N referencing invalid cluster M` | `dir.c:400-417` | first cluster and size set to 0 | as for the file case above |
| `size of PATH is N, should at most be M` | `dir.c:434-445` | size set to the chain's | |
| `PATH has too many clusters allocated` | `dir.c:446-460` | end the chain after the size's last cluster, free the rest | |
| `Lost cluster chain at cluster N` / `M Cluster(s) lost` | `fat.c:1285-1300` | a file named `N` in the root's `LOST.DIR`, sized to the chain | |
| `Free space in FSInfo block (N) not correct (M)`, `Next free cluster in FSInfo block (N) invalid` / `not free` | `fat.c:1307-1334` | both hints written unknown | |
| the volume dirty | `check.c:161-174` | mark the volume clean at the end | |

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

### Where the repairs differ

| Case | FreeBSD | erXos, and why |
| --- | --- | --- |
| FAT12, sectors other than 512 bytes, mirroring off | checked | refused, nothing read past the boot sector: the FAT server serves none of them, and repairing a volume of one live FAT from the first copy would write from a FAT that may be stale |
| when writing starts | as it goes, the first FAT through `mmap`, no dirty flag set | after the whole check, in one plan that sets the dirty flag first and clears it last (FK-R3) |
| FAT copies | never compared | `FAT N differs from FAT 0`, repaired by copying the first FAT's differing sectors: the FAT server keeps the copies equal on a clean volume, and fsimg's verify refuses a clean one whose copies disagree |
| a loop of lost clusters | never found | `Cluster N closes a loop of lost clusters`, at its lowest cluster; cutting the link into that cluster makes the loop a lost chain, reconnected as any lost chain is |
| no `LOST.DIR`, or one that is full | the lost chain freed (`dir.c:1101-1131`) | `LOST.DIR` created in the root, or grown, through the FAT server's own directory code; a chain is freed only when the root or the volume has no room. A missing directory is no reason to throw a user's data away |
| a lost chain's name | the cluster number written into the short name's eleven bytes, unchecked for uniqueness (`dir.c:1144`) | the cluster number as a name placed by the FAT server's naming, a long name where it does not fit 8.3, unique in `LOST.DIR` |
| a directory named by two entries | an assertion (`fat.c:1056-1057`) | `PATH doesn't start a new cluster chain` at the second entry, which is deleted, as FreeBSD's directory case is |
| FSInfo hints | exact values | unknown, as the FAT server's dirty step writes them; every reader recounts, and fsimg and FreeBSD accept unknown |

### Bounds

* **Clusters.** Two sets of one bit per cluster: the clusters some entry
  links to, and the clusters a walk has reached. Phase 1 builds the
  first and finds cross-links; phases 2 and 3 build the second; a third
  pass over the FAT finds loops, allocated clusters that no walk
  reached. These are the ownership check's sets, at its limit of
  4,194,304 clusters; a larger volume is refused before any FAT sector
  is read.
* **Directories.** The frames and the subdirectories they wait on take
  the ownership check's stack bound, 16,384; a deeper or wider walk is
  refused.
* **The plan.** It is measured as a batch is measured (`erx_fat_dir:held/1`
  with `erx_fat_alloc:held/1`, a chain waiting to be freed counting as
  one sector) and held within a quarter of `media_volume_bytes`; a repair
  past that is refused with nothing written. Freeing a long chain takes
  only its first cluster.
* **Time.** Each chain is followed once, each step to a cluster not
  reached before, through a cache of FAT sectors; the FAT is read three
  times end to end; each directory cluster once in the walk and once
  more per finding's path.

What the command allocates beyond these is bounded by the `max_heap_size`
every Erlang command runs with ([design-shell.md](design-shell.md)); a
volume that passes it ends the command, which writes nothing during the
check.

## Writing a repair

### The repair order

The plan's steps, each followed by a flush:

1. **`dirty`, `dirty_mirrors`**: `erx_fat_alloc:dirty/1`. The clean bit
   is cleared in the first FAT, then in the other copies; the FSInfo
   hints are written unknown.
2. **`cutting`**: every end-of-chain mark a repair sets (a cross-link,
   an out-of-range link, a link to a free, bad or reserved cluster, a
   loop, a file's superfluous tail) and the media byte of the first
   entry, through `erx_fat_alloc:cut/2`, which ends a chain without
   queuing what follows for release, since what follows may be another
   chain's. Each entry goes to every copy, the first first. A cut frees
   nothing: what it cuts off becomes lost.
3. **`preparation`**: directory sectors whose entries now reach less
   (entries deleted, a file's first cluster and size set to 0, sizes
   shrunk, a directory's size set to 0, fixes to entries behind an end
   marker), and the allocation and zeroing of a new or grown `LOST.DIR`,
   as `erx_fat_dir`'s `mkdir` and growth write them.
4. **`linking`**: the link of a grown `LOST.DIR`'s new run, as the FAT
   server links a growing directory.
5. **`publication`**: directory sectors whose entries now reach more or
   are corrected: `LOST.DIR`'s own entry, the entries that name lost
   chains, the end markers turned into deleted entries, and the `.` and
   `..` fixes. Steps 3 to 5 are the FAT server's batch steps and images,
   reached through `erx_fat_dir:edit/4`, which sets an entry's bytes at
   a slot from a step on, and `adopt/5`, which places a name for an
   existing chain.
6. **`release`**: chains freed, by `erx_fat_alloc`'s release, in as many
   commits as it needs. Each ends in an end-of-chain mark in the view,
   so the release meets no loop.
7. **`fsinfo`**: the FSInfo signatures, when they were wrong.
8. **`mirrors`**: the sectors of FATs 1 to N that differ from the first,
   in commits of at most 1,024 sectors.
9. **`clean_mirrors`, `clean`**: the second FAT entry, in the other
   copies first and in the first FAT last, by `erx_fat_alloc:finish/1`.
   That function takes the value to write: for the FAT server, the clean
   bit set and the hard-error bit as read; for a repair, every bit of
   the entry's value set, the no-hard-error bit among them, as FreeBSD's
   "Correct" of an odd first entry writes it.

Steps with nothing to write are skipped. An empty plan writes nothing.

### Why a cut leaves the volume no worse

* **It reads dirty.** The first FAT loses its clean bit before any other
  write and gets it back in the very last.
* **No reached cluster is free.** Nothing is freed before step 6, which
  frees only chains that no name reaches once steps 3 to 5 have landed.
* **No new sharing.** Step 2 only takes links away and step 3 only takes
  names away. Step 5 adds names only to lost chains, each named once,
  after step 3's flush, and an entry that becomes readable again has
  had its own fixes written in step 3, while it was still out of view.
  The clusters a new `LOST.DIR` takes are free ones, allocated in step 3
  as a chain of their own that nothing reaches until step 5.
* **Kept data stays allocated.** A cluster the finished repair keeps in
  a file is never freed; a tail cut in step 2 and named in step 5 stays
  allocated, lost, in between.
* **Running again finishes it.** Every finding is derived again from the
  medium, and every partial state is a row of the table: cut chains,
  removed names, sizes not yet shrunk, lost chains not yet named, chains
  not yet freed, copies not yet equal, a volume marked dirty.

FAT entries never straddle a sector and each directory entry lies within
one, so every entry a step writes lands whole or not at all.

## The surface

### Options

Each option is kept only where it has a consumer and does what its name
says:

| Option | FreeBSD | erXos | Why |
| --- | --- | --- | --- |
| `-n` | answer no to every question; open read-only | check, print the plan, write nothing | a user looking before changing anything, and scripts; the file is opened for reading only, so the volume stays mounted |
| `-y` | answer yes to every question | apply the plan without asking | unattended repair |
| none | one terminal question per repair | print the whole plan, then one question: apply it all or nothing | FK-R4. Repairs depend on each other, so answering some and not others gives a half repair that leaves the volume dirty, which helps nobody. One plan shown whole and applied whole is what the user can judge |
| `-p`, `-f` | preen at boot; `-f` preens clean volumes too | dropped, a usage error | nothing preens: no FAT volume is mounted at boot, and the automounter mounts dirty volumes read-only ([open decision 1](#open-decisions)). Checking skips no volume because its flag reads clean, since the stick's damage was on one |
| `-B`, `-C`, `-M`, `-F` | ignored, ignored, no `mmap`, exit 5 | dropped, usage errors | they exist for FreeBSD's `fsck(8)` and its memory handling; nothing here uses them |

`-n` and `-y` together are a usage error, not "the later wins".

`fsck_fat [-n | -y] file ...` checks each file in turn. The file is a
volume's `sN.data`, or any file of 512-byte sectors holding a FAT
volume, an image in `/tmp` among them, as FreeBSD's checks an image as
readily as a disk. A directory, `/media/diskN/sN` itself, is refused
with `fsck_fat: PATH: a directory; the volume's sectors are
PATH.data`. A file it cannot open is `fsck_fat: PATH: CAUSE`. A
writing open whose finish fails is not retried read-only: the command
reports the failure and checks nothing, since a check that cannot write
must not look like a repair.

### Exit status

| Status | Meaning |
| --- | --- |
| 0 | nothing to repair, or the whole plan written |
| 8 | repairs needed and not made (`-n`, or the question answered no), a fatal finding, a refusal, or a read, write or flush that failed |
| 1 | a usage error |

0 and 8 are FreeBSD's, and the meanings scripts rely on: 0 means the
volume is now consistent and 8 means it is not. The status of several
files is the largest.

### The report

```text
/media/disk0/s1.data: FAT32, 1 FAT copy of 2 differs, dirty
1. Invalid long filename entry for /DCIM/IMG_0001.JPG
   delete 3 long-name entries in /DCIM; IMG_0001.JPG keeps its own name
2. Cluster 40213 crossed another chain at 40214
   end /notes.txt's chain at cluster 40213: it keeps 98304 of 131072 bytes
3. Lost cluster chain at cluster 51000, 4 Cluster(s) lost
   name it /LOST.DIR/51000, 131072 bytes (LOST.DIR created)
4. FAT 1 differs from FAT 0
   copy FAT 0 over FAT 1
5. the volume is marked dirty
   mark it clean
3 files, SIZE free (459000 clusters)
Apply 5 repairs to /media/disk0/s1.data? [yn] y
5 repairs written; /media/disk0/s1.data is consistent
```

Each finding is FreeBSD's sentence, and under it what the repair changes,
in terms of the files it touches and the bytes a file loses, so a repair
that costs data says so before it is made. Names and labels from the
medium pass through the field escape
([design-app-trees.md](design-app-trees.md#a-status-line)). At most
1,000 findings are listed, then `... N more findings`, and the plan
still covers them all. Under `-n` the question is replaced by
`5 repairs needed; fsck_fat -y applies them`. A fatal finding or a
refusal is one line, `PATH: MESSAGE`. The question reads one line from
standard input: `y` or `Y` applies the plan, and anything else, or end
of input, writes nothing.

A `-n` run through a reading open of a volume mounted `rw` reads the
medium beneath a live file system: it can report findings that the
volume's next batch removes. When the file is a drive's `sN.data` and the
drive's `status` shows `sN_mount rw`, the first line says `mounted rw`.

### `fsck`

`fsck [-n | -y] [-t fat] volume ...` names volumes as a user knows
them, `/media/diskN/sN`, and runs `fsck_fat` on each one's
`sN.data` with the same flag. Without `-t`, the format comes from the
drive's `status` (`sN fat`). A volume of another format, or of none
the probe knows, prints `fsck: PATH: no checker for NAME volumes` or
`fsck: PATH: unknown format; give -t`, and counts as status 8. With no
volume named, `fsck` refuses with `fsck: name a volume`, since erXos has
no fstab to take a list from. Other options are usage errors.

### Other programs

Any program may open the same files: a ported `dd` or `newfs_msdos`, a
FreeBSD tool brought over, or a user's own repairer, in Erlang or
native. What it needs:

* a namespace entry of a `media` grant with rights `admin`, which a
  session that holds one hands to the programs it starts. A starter
  should narrow the entry to `/media/diskN`, so the program reaches that
  drive alone ([design-drives.md](design-drives.md#raw-sectors));
* reads and writes at offsets and counts that are multiples of 512,
  within the file's size, which `stat` gives. erXos's POSIX layer offers
  no disk `ioctl`, so a port replaces FreeBSD's `DIOCGMEDIASIZE` and
  `DIOCGSECTORSIZE` with `stat` and 512;
* `fsync` wherever it needs order or durability, since that is the only
  flush;
* to treat what it reads as a stranger's bytes, and to expect `eio` when
  the medium leaves;
* to know that its writing open takes the volume, or for `data` the
  whole medium, out of service until its last close.

An Erlang program can reuse `erx_fat_check` and `erx_fat_plan` as
`fsck_fat` does. Nothing in the media domain knows which program
holds the file.

## Concurrency

The drive process takes a drive's requests one at a time, so a writing
open waits for the volume's finish and no mount starts while it lasts
([design-drives.md](design-drives.md#raw-sectors)). Walks of the drive's
other volumes go on. Another program writing the same file at the same
time is that user's doing: the checker assumes the volume does not
change between its reads and its writes, as FreeBSD's does. Interrupting
the command is a cut (FK-R3). `eject` during a repair ends the raw files
after a flush, which is a cut for the repair. The ordered end makes
further raw writes fail with `erofs`, which is also a cut.

## Failure handling

| Failure | Detected by | What is left | Recovery | Reported |
| --- | --- | --- | --- | --- |
| the command passes its heap bound, or is interrupted, during the check | the runtime | the medium as it was | the last close returns the volume | `killed` or the interrupt; status 8 |
| a read fails during the check | the read function | the medium as it was | the same | `PATH: read failed: CAUSE`; 8 |
| a write or flush fails, or the command is interrupted, during the repair | `erx_fat_plan:apply/3` | a cut (FK-R3) | run `-y` again; the volume mounts read-only `dirty` meanwhile | `PATH: write failed: CAUSE; run again`; 8 |
| the medium is pulled | `eio` | a cut, or nothing written | the same | the same |

No recovery machinery is added: an interrupted repair is finished by
running the command again.

## Refusals and error results

* Usage (exit 1): an unknown option, `-n` with `-y`, no file.
* Exit 8, nothing written: a directory or a file that cannot be opened;
  FAT12; sectors other than 512 bytes; FATs not mirrored; too many
  clusters or directories; too many repairs for one plan; a fatal
  finding.
* `fsck`: no volume named; a format with no checker; an unknown format
  without `-t`.

## Security

`fsck_fat` runs as an Erlang command in the session's domain, with
the session's authority, which the user typed it with
([design-shell.md](design-shell.md)). It parses a stranger's volume
there, by the user's choice: its decoders are Erlang under the command's
heap bound, so a crafted volume can end the command but cannot reach
memory. A user who wants less can run it in a domain of its own,
narrowed to the drive. The raw files reach only the drives an `admin`
grant names, and what a hostile holder can do is stated in
[design-drives.md](design-drives.md#raw-sectors). The report escapes
every name from the medium, so printing it cannot drive the user's
terminal. Nothing is written without `-y` or a "y".

## What is reused and what is new

Reused: `erx_fat_read:boot_sector/1` and `erx_fat`'s admission rules, so
the boot sector has one decoder; `erx_fat_entry:decode/1`, the checker
reading a long-name entry's cluster field itself, since `decode/1` also
answers `bad_long` for a non-zero type byte, which FreeBSD does not
check; `erx_fat_name:checksum/1` and its naming; `erx_fat:layout/1` and
`cluster_sectors/2`; `erx_fat_alloc`'s `dirty/1`, `grow/3`, `free/2`,
`commit/1`, `finish/1`, overlay and per-copy writes; `erx_fat_dir`'s
`mkdir`, growth, per-step images and `view/1`; `erx_cmd`; the drives'
raw files.

New: `erx_fat_check`; `erx_fat_plan:apply/3`, taken out of
`erx_media_volume:applied/2`, which then calls it; a reason with each
admission refusal of `erx_fat`, so the checker can print FreeBSD's
message for it; `erx_fat_alloc:cut/2`; `erx_fat_dir:edit/4` and
`adopt/5`; `finish/1`'s value for a repair; the commands `fsck_fat`
and `fsck`; and the test generator of damaged images.

`erx_fat_alloc` and `erx_fat_dir` assume a volume whose ownership check
passed. The checker hands them only chains that end in an end-of-chain
mark in the view and that no other chain shares, which its cuts
guarantee before any release.

## Verification

Each passing case is paired with a seeded fault that must make it fail,
so a pass shows the code under test ran.

### Damaged images

A host generator, `test/erlang/erx_fat_damage.erl`, writes each class of
damage into a FAT16 or FAT32 image that fsimg or the FAT server's host
build made. For each row of both tables above, it changes the bytes a
declared case names: a FAT entry, an entry's field, a run's order
number. The images, the stick's pattern among them, are generated in the
build tree and never committed. Each case declares its findings and the
tree, names, sizes and content hashes, that the repair must give.

### Host tests

| Test | Seeded fault that must fail it |
| --- | --- |
| each class through `erx_fat_check:check/1`: the declared findings and repairs; the plan applied, then a second check finding nothing, `erx_fat:check/1` answering `ok` and the writable rule allowing `rw` (FK-R2) | each repair removed in turn (cross-link cut, loop cut, copy sync, `..` fix): the second check finds it, or `check/1` answers `tree` |
| the order of examination: two files sharing a tail, and a file and a directory naming one chain, repaired as FreeBSD chooses | the FAT walk run from the last cluster down, so the other file is cut |
| crash consistency (FK-R3): for each class's plan on a small image, a cut after every step and after every subset of the last step's sectors; each result reads dirty, keeps every kept cluster allocated, shares no new cluster, and is brought to FK-R2 by a second run | the release step placed before `preparation`, so a cut leaves a name on a freed cluster; the dirty step left out, so a cut leaves a half repair that reads clean |
| the FAT server's own cut: `erx_fat_dir`'s removal of a name whose run crosses a sector boundary, cut between the two sectors of its `preparation`, leaves an orphan run that the check reports and the repair removes | a deleted entry ending a run, so the orphan is read as the next name's |
| `LOST.DIR`: missing, created; full, grown; FAT16's full root, the chain freed and the finding saying so; a name already there, another chosen | a missing `LOST.DIR` taken as no room, so the chain is freed |
| bounds: 4,194,305 clusters and 16,385 pending directories refused with nothing read past the boot sector and FAT, a repair past the plan bound refused with nothing written | the plan measured without its directory images, so the large repair is written |
| refusals: FAT12, 1,024-byte sectors, mirroring off, each with no write | the mirror test dropped, so a volume whose active FAT is 1 is repaired from FAT 0 |
| `fsck_fat` over a file and over a fake raw file: `-n` writes nothing and exits 8 on damage, 0 when clean; the question answered `y` writes the plan and exits 0, `n` and end of input write nothing and exit 8; `-y` asks nothing; `-p`, `-f`, `-n -y` and a directory are refused; the report lists every finding before the question | the plan written before the question; the exit status 0 after a declined plan |
| `fsck`: a volume path mapped to its `sN.data`, the format from `status`, `-t fat` on an unknown format, no volume named refused | the format read from the file's own boot sector instead of `status`, so an EROFS volume reaches `fsck_fat` |

### Fuzz target

`erx_fat_check` over mutated images, seeded from every damaged image: no
crash, the bounds kept, and wherever a plan is answered, the plan applied
to the image followed by a second check finds nothing. A copy whose
chain walk drops its reached-set test must fail by passing its time
bound on a looped image.

### The oracle

The FreeBSD 15.1 oracle guest that the command shell's tests use
([design-shell.md](design-shell.md#verification-and-testing)), in QEMU
without a network device, takes each damaged image as a disk of its own,
a fresh copy per run, and runs `fsck_msdosfs -n` and `fsck_msdosfs -y`.
For each image the run passes when `-n`'s exit status equals erXos's;
when the findings FreeBSD's `-y` run prints, matched by message, equal
erXos's findings; and when, after both `-y` runs, FreeBSD's `-n` exits 0
on erXos's image, erXos's check finds nothing on FreeBSD's, and both
read back, through `erx_fat` on the host, to the same names, sizes,
contents and free cluster count. A class in
[Where the repairs differ](#where-the-repairs-differ) is compared only in
its other findings. It runs at the milestone gate. Seeded fault: a
cross-link cut at the earlier entry instead of the later one makes the
comparison fail on the shared-tail image.

### QEMU case

In the `usb` suite: a FAT32 stick carrying the stick's pattern, a
cross-linked file and its dirty flag set mounts read-only `dirty`.
`fsck_fat -n /media/disk0/s1.data` exits 8 and leaves the stick's
bytes unchanged, and the volume stays mounted. `fsck_fat -y` exits
0; while it ran, `status` showed `s1_mount none raw`; afterwards the
volume shows `s1_mount rw`, every kept file reads with the harness's
hashes, and the stick, read on the host after `eject`, passes fsimg's
verify. A second stick is detached with `device_del` during its repair,
comes back read-only `dirty`, and a second `-y` repairs it to the same
result. Seeded faults: the last close not returning the volume, so it
stays `none raw`; the dirty step left out, so the detached stick mounts
`rw` with half a repair.

## Alternatives considered

**The check as a system service.** The volume's own process could run
the check by a remount, and report through a file of the media tree. It
would keep every byte of a medium in the media domain. It loses: there
would be one checker, the system's, and no user could run a better one,
`dd` or a formatter. The raw files give every program the same access,
and the checker stays reusable as a library.

**FreeBSD's per-question prompts and preen defaults.** They make sense
for a checker that writes as it goes. With the whole plan known before
anything is written, a partial answer only produces a partial repair, and
preen has no caller on erXos.

**FreeBSD's C as a native program.** Possible through the raw file, by
anyone. As erXos's own checker it would put C over a stranger's bytes,
keep the write-as-you-go order, and share nothing with the FAT server,
whose decoders and plan writer the Erlang checker reuses.

**Only an orphan-run cleaner.** It would fix this stick and nothing else.
Sticks come from cameras, Windows and macOS too.

## Open decisions

1. **Preen when a dirty volume mounts.** The volume's process could run
   the checker, and apply its repairs, when the writable rule finds
   `dirty`, so a stick pulled without `eject` comes back writable.
   Recommendation: not now. A repair should write a stranger's medium
   only when the user asks, and some repairs delete entries. Revisit once
   the command has run on real sticks.
2. **The FAT server's orphan runs.** (a) `place/5` refuses every run that
   starts right after a live long-name entry, extending the rule that
   already holds for names stored as a short entry alone, so erXos never
   turns an orphan into the stick's overlap; (b) also give a name's short
   entry a step of its own, so a cut never leaves an orphan, at two more
   flushes for a batch that removes or adds a long name. Recommendation:
   (a) alone. A cut already leaves the volume dirty, so a repair removes
   the orphan before erXos writes there again, and (a) costs no flush.
   This changes [design-storage.md](design-storage.md#removable-media-fat);
   it is filed in [TODO](todo-storage.md#bugs-by-subsystem).
3. **Raw access in a release.** Development board manifests grant root's
   session `admin`; whether a release's do too, or only where a row says
   so, decides whether a user of a released erXos can repair a stick at
   all. Recommendation: root's session in a release too, as root reaches
   its disks on FreeBSD. A hostile program reaches only the drives its
   starter hands it, and the stick's owner is the one asking.

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
  `erlang/apps/erx_media/src/erx_media_volume.erl`.
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
