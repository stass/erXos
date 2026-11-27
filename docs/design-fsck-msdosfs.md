# fsck_msdosfs: checking and repairing FAT volumes

A FAT volume on a drive can be damaged: a stick pulled while it was
written, a medium that dropped a write it had acknowledged, or another
system's bug. erXos mounts such a volume read-only, since its FAT server
writes safely only on a volume that starts consistent
([design-drives.md](design-drives.md#the-writable-rule)). This design
lets erXos repair it. `fsck_msdosfs` and `fsck -t msdosfs` behave as
FreeBSD's do, and the check itself runs in the media domain, as the
volume's own process, so no session ever holds a medium's sectors.

The key idea is that **a check is a remount**. The drive process
finishes the volume's mount and starts the volume's process again with a
check order. That process runs one pure function over the volume, which
answers the findings, in FreeBSD's words, and a whole repair plan. It
writes the plan through the volume's one write path, in an order that
keeps the volume marked dirty until the last write, and then mounts the
volume by the writable rule, as any volume mounts. Exclusive access,
crash safety, the report and the volume coming back writable all follow
from that one construction, and none of them needs a mechanism of its
own.

Decisions every reader needs:

* **FreeBSD 15.1's fsck_msdosfs is the contract.** The same findings,
  the same repairs, the same answers under `-n`, `-y` and `-p`, the same
  messages and exit statuses, except for the departures listed in
  [Where erXos differs](#where-erxos-differs).
* **Nothing is written until the whole check has run.** The checker
  decides every repair over an in-memory view of the volume, then writes
  the plan in one go: dirty flag first, references taken away before new
  ones are added, clusters freed last, the flag cleared at the very end.
  A cut at any write leaves a volume that reads dirty and loses nothing
  the finished repair would keep; running the check again finishes it.
* **A repaired volume mounts writable.** FreeBSD's repairs already
  satisfy the FAT server's ownership check, but for a directory named
  twice, where FreeBSD's source reaches an assertion. erXos repairs that
  case, and adds two repairs no checker should still fault (FAT copies
  that differ, loops of lost clusters), so after `fsck_msdosfs -y` the
  volume comes back `rw`.
* **The surface is a `ctl` command and a report file.** The commands
  write `fsck sN` with FreeBSD's flags to the drive's `ctl` and print the
  volume's report, `/media/diskN/sN.fsck`. Both are kinds of file the
  media tree already serves.

## Context

### The problem

A FAT32 stick used on a Raspberry Pi 4 showed, when the host's FAT
checker read it, live long-name entries whose short entry's slot had
been taken by a later name: a long-name run with no short entry of its
own, followed by another name's run. erXos mounts a volume like that
writable as long as its dirty flag is clear, since nothing in the
writable rule looks at long-name runs. A volume whose flag is set mounts
read-only with `dirty`, and the storage design leaves its repair to
"another machine" ([design-storage.md](design-storage.md#removable-media-fat),
"Durability"). erXos can check a FAT image only on the development host,
with fsimg's verify. A user with only an erXos machine cannot repair a
stick, and a stick erXos itself left dirty stays read-only on erXos for
good.

### What is matched

FreeBSD `src`, tag `release/15.1.0`, the FreeBSD release whose utilities
erXos's Erlang commands follow ([design-shell.md](design-shell.md),
S-R4). The files are byte-identical at commit
`95719d8a895bf8170851e9844d9b4092b1d2b6fe`, which
[design-drives.md](design-drives.md#what-is-matched) reads. Files and
hashes are under [References](#references). What the source shows:

* **Options and answers.** `-n` answers "no" to every question, opens
  the device read-only (`check.c:58`) and so writes nothing. `-y`
  answers "yes". Of the two, the one given later wins (`main.c:89-96`).
  `-p` (preen) asks nothing: each question takes its default, or the
  answer `-n` or `-y` forces; a "yes" is made and printed as `FIXED`, and
  a "no" is left without a word (`main.c:130-145`).
  With none of these flags, each question is asked on the terminal as
  `PROMPT? [yn] `, and end of input counts as "no" (`main.c:149-161`).
  `-f` makes preen check a volume whose flags read clean, which preen
  otherwise skips with `FILESYSTEM CLEAN; SKIPPING CHECKS`
  (`check.c:85-90`). `-B` and `-C` are ignored, `-M` turns off `mmap`,
  and `-F` exits 5 at once, so that `fsck(8)` learns FAT cannot be
  checked in the background (`main.c:71-104`).
* **Messages.** `pwarn` prefixes the device's name while preening;
  `pfatal` while preening also prints
  `DEV: UNEXPECTED INCONSISTENCY; RUN fsck_msdosfs MANUALLY.` and exits
  8 (`fsutil.c:109-125`).
* **Exit statuses.** 0 when no finding is left unrepaired, repaired
  volumes included; 8 when one is left, when the volume is left marked
  dirty, or on a fatal error (`check.c:52-190`); 1 for a usage error
  (`main.c:57-60`); 5 for `-F`.
* **Phases.** The boot sector and FSInfo (`boot.c`); phase 1 reads the
  first FAT and walks every entry once in cluster order (`fat.c:806-1024`);
  phase 2 walks the directories from the root, each subdirectory
  pushed on a stack as it is found, so the last one found in a
  directory is walked first, with all of its subtree before the next
  (`dir.c:1045-1076`); phase 3 handles lost chains in cluster order,
  then the FSInfo hints (`fat.c:1256-1337`); last, "Update FATs" and
  "MARK FILE SYSTEM CLEAN" (`check.c:122-175`). The findings, their
  repairs and their defaults are tabled in
  [Findings and repairs](#findings-and-repairs).
* **What it does not check.** It reads only the first FAT and ignores
  FAT32's mirroring flags (`boot.c:165` sets `ValidFat`, which nothing
  reads). It never compares the FAT copies; it copies the first over the
  others only when it changed the first (`fat.c:1199-1250`). It checks
  neither the characters of names nor duplicate names. A loop of lost
  clusters that no cluster outside the loop links into has no head, so
  phase 3 never meets it.
* **How it writes.** FreeBSD maps the first FAT shared, so its changes
  reach the medium whenever the kernel writes them back
  (`fat.c:712-720`). It writes a directory cluster as soon as it has
  changed it (`dir.c:1012-1021`), writes LOST.DIR entries and the FSInfo
  sector during phase 3, writes the FATs at the end, and never sets the
  dirty flag first. An interrupted run can therefore leave a volume that
  reads clean with half a repair on it, which a later preen then skips.
* **Two assertions a crafted volume can reach.** A directory named by
  two entries is pushed twice, and its second walk calls `checkchain`
  on a head already visited, which asserts that it is still a head
  (`fat.c:1056-1057`); clearing an already clear bit asserts too
  (`fat.c:93`). Whether FreeBSD's release build keeps these assertions
  is unverified here; the oracle records what FreeBSD does on that
  image.

### What erXos does today

* A volume's process mounts it read-only for `dirty`, `hard error`,
  `mirror`, `too large` or `tree`, the last after the ownership check:
  two passes over the FAT and one walk of the directories, which find a
  cluster linked to twice, a link that is no cluster, a first cluster
  named twice or linked to, a wrong `.` or `..`, and a reached cluster
  that is free or bad (`erx_fat:check/1`,
  [design-storage.md](design-storage.md#removable-media-fat)).
* A writable volume's changes are written as plans,
  `[{Step, [{Sector, Bytes}]}]`, by `erx_media_volume:applied/2`, which
  writes each step's sectors and then flushes
  (`erlang/apps/erx_media/src/erx_media_volume.erl:695-699`). That is
  the volume's one write path. `erx_fat_alloc` builds the FAT side of a
  plan, every entry going to every copy, and `erx_fat_dir` builds the
  directory side as one image of each sector for each step.
* Nothing on erXos repairs a volume. [design-drives.md](design-drives.md)
  lists volume repair as a non-goal and sketches raw sector access as a
  later alternative ([Alternatives considered](#alternatives-considered)).

### Can erXos's own batches leave a long-name run without its short entry?

Yes, under a cut. `erx_fat_dir:unnamed/2` marks every slot of a removed
name deleted in `preparation` (`erx_fat_dir.erl:616-618`), and `place/5`
writes every entry of a new name in `publication` (`:515-530`).
`merged/2` lists a step's sectors in sector order with no flush between
them (`:176-177`), and `applied/2` flushes once per step. A name's
entries lie in two sectors whenever its run crosses a 16-entry boundary,
a cluster's end included. The storage design orders writes only by
flushes and relies only on each sector being written whole, so a cut can
land any subset of one step's sectors. A cut that lands the short
entry's sector of a removal, but not the long entries' sector, leaves
the long entries live before a deleted slot. One that lands the long
entries' sector of a creation, but not the short entry's, leaves them
live before a free slot. The storage design says a name the cut batch
touches may be "found whole, missing or under their short name alone";
that holds for the name, but a missing name can leave its long-name
entries live.

erXos's reader ignores such a run, since a long name counts only when
its entries run in order and carry the checksum of the short entry that
follows them (`erx_fat.erl` module doc), and the writable rule does not
look at runs. But the volume is dirty after such a cut and mounts
read-only, so erXos itself writes after the orphan only once something
has cleared the flag: a repair elsewhere that kept the orphan, or a
medium that acknowledged a flush and then dropped an earlier write. From
then on `place/5` can put a new name's run in the deleted slot right
after the orphan, because it checks the entry before a run only for a
name stored as its short entry alone (`:524`). That gives exactly the
pattern found on the stick. This reading found no path that leaves an
orphan without a cut. Whether the stick came to its state this way is
not established, since its history was not recorded. The repair here
removes such runs; making `place/5` refuse every run that starts right
after a live long-name entry is
[open decision 4](#open-decisions).

## Requirements

* **FK-R1. FreeBSD's behaviour.** On every FAT16 or FAT32 volume of
  512-byte sectors whose FATs are mirrored and which lies within the
  check's bounds, `fsck_msdosfs` with any of FreeBSD's flags gives
  FreeBSD 15.1's findings, repairs, messages and exit status, except for
  the departures listed in [Where erXos differs](#where-erxos-differs).
* **FK-R2. A repaired volume is writable.** After a run that leaves no
  finding unrepaired, the volume meets the writable rule's FAT
  conditions: the dirty flag clear, no hard error recorded, and the
  ownership check passed.
* **FK-R3. An interrupted repair leaves the volume no worse.** A cut at
  any write of a repair leaves a volume that reads dirty, on which no
  cluster that a name reaches is free, no two names reach one cluster
  unless two already did before the repair, and every cluster that the
  finished repair keeps in a file is still allocated. A second run then
  meets FK-R2.
* **FK-R4. Confinement holds.** Every byte of the volume is parsed in
  the media domain, under the volume's memory bound (DR-R2 of
  [design-drives.md](design-drives.md#requirements)), and no session
  reads or writes a medium's sectors.
* **FK-R5. Exclusive.** No request of a mount reaches a volume while it
  is being checked, and a check never runs alongside a mount of the same
  volume.
* **FK-R6. Untrusted input.** The checker is bounded in memory and time,
  has a fuzz target, and never crashes on a volume; text taken from the
  medium reaches the report only through the field escape.
* **FK-R7. No new mechanism.** The design uses a drive's `ctl`, a file
  of the media tree, the volume's process and its one write path, and
  two Erlang commands, each named below.

Non-goals: FAT12 (which the drives refuse by name); exFAT; volumes
whose FATs are not mirrored; repairing a partition table; making a file
system (`newfs_msdos`); a check of a volume while it stays mounted;
creating or growing `LOST.DIR`, which FreeBSD does not do either
(`dir.c:1097-1131`).

## The construction

### A check is a remount

```text
session                   media domain
fsck_msdosfs -y PATH
  write "fsck s1 -y T" -> drive process (takes the drive's requests one at a time)
  to /media/disk0/ctl       1. finish s1's volume process, as eject finishes it
                            2. start s1's volume process again, order {check, "-y", T}
                                 probe; erx_fat_check: read-only view -> findings + plan
                                 write the plan by applied/2 (dirty ... clean)
                                 mount by the writable rule, as every volume mounts
  write answers ok <------- the check's keeper answers once the plan is written
  read /media/disk0/s1.fsck <- the report, held by the new volume process
  print it; exit 0 or 8
```

1. **The order.** The drive process takes the `ctl` command in its turn.
   It sends the volume's process its finish, which writes what a
   writable mount still holds and clears its dirty flag, exactly as
   `eject` does for each volume
   ([design-drives.md](design-drives.md#finishing-a-volume)). It then
   ends that process and starts the volume's process again, under the
   medium's supervisor, with the check order. The new process draws a
   new mount number, so every fid of the old mount answers `eio`. The
   drive process then takes its next request; the drive's other volumes
   are not held up.
2. **The check.** The new process probes the volume as any volume
   process does. It answers no request of a mount until it has mounted,
   as every volume process waits for its mount, so nothing reaches the
   volume during the check (FK-R5). It runs
   `erx_fat_check:check/2` (below) over a read function on its
   placement. The function is pure: it reads sectors and answers the
   report and a plan, and writes nothing.
3. **The repair.** The process writes the plan through `applied/2`,
   step by step with a flush after each, in the order of
   [Writing a repair](#writing-a-repair).
4. **The mount.** The process applies the writable rule and mounts,
   `rw` when the repair left the volume consistent and the medium
   flushes. It keeps the report for the volume's `sN.fsck` until it ends.
5. **The answer.** The `ctl` write is a waiting request whose keeper is
   the new volume process. It answers `ok` once step 3 has finished, or
   `eio` if the process ended first
   ([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
   "Waiting requests"). A long check therefore delays nothing else of
   the session's `media` grant.

### How each requirement follows

* **FK-R1.** One pure function decides every finding and repair, with
  FreeBSD's order of examination and defaults
  ([The checker](#the-checker)), so agreement can be tested on the host
  and against FreeBSD over the same images.
* **FK-R2.** FreeBSD's `-y` repairs leave no finding of the ownership
  check, as the table's last column shows, but for a directory named
  twice, which erXos repairs as its departures state. The final step
  clears both flags.
* **FK-R3.** Nothing is written until the plan is whole, and the plan's
  order is chosen so that every prefix of it is safe
  ([Why a cut leaves the volume no worse](#why-a-cut-leaves-the-volume-no-worse)).
* **FK-R4.** The check runs in the volume's process, which is already
  where the volume is parsed, under the same memory bound. The session
  sends a line and reads text back.
* **FK-R5.** The volume has one process, the mount has ended before the
  process starts again, and that process mounts only after its check.
* **FK-R6.** The bounds of [Bounds](#bounds) and the fuzz target of
  [Verification](#verification).
* **FK-R7.** The names this design adds: the `ctl` command `fsck`; the
  file `sN.fsck`; the volume
  process's check order; the module `erx_fat_check`; `erx_fat_alloc:cut/2`;
  an entry-level change in `erx_fat_dir`; and the Erlang commands
  `fsck_msdosfs` and `fsck`.

### What this does not add

No raw sector file, no administrator facet, no rule for opening a medium
while it is idle, no second writer of a volume and no lock: the volume's
process is already the one owner of its sectors. No remount command
either: the check's process is the next mount.

## The checker

`erx_fat_check:check(Read, Flags)`, in the `erx_fat` application, takes
a function that reads one 512-byte sector of the volume and FreeBSD's
flags as `main.c` leaves them: the answer forced, `yes`, `no` or none;
whether it preens; and whether `-f` was given. It answers
`{Report, Result, Plan}`: the report's lines, the result
([The report](#the-report)), and the plan, which is empty when the
answer is `no`. Each question is answered as `ask()` answers it, its
default under preen unless an answer is forced. It works over a
**view**: the medium as read, with every repair
decided so far laid over it, so each later decision sees the earlier
ones, as FreeBSD sees its own changes. Directory changes are kept as
`erx_fat_dir`'s per-step sector images, and FAT changes as
`erx_fat_alloc`'s overlay, so the view is `erx_fat_dir:view/1` of the
two.

### Order of examination

The checker examines the volume in FreeBSD's order, because which of two
claimants a repair cuts depends on it: the boot sector; the first
entries of the FAT; every FAT entry in cluster order; the directories,
the root first, then depth first, with the last subdirectory found in a
directory walked first, each directory's entries in order; lost chains
in the order of their first clusters; the FSInfo hints. When preening
without `-f`, a volume whose first FAT entries are well-formed, whose
clean bit is set and that records no hard error is skipped
(`fat.c:580-640`).

The walk keeps a stack of frames, one per directory on the current path,
each holding the directory's first cluster, the place of its entry, and
the subdirectories found in it and not yet walked. A finding's path is
rebuilt from the frames by reading each ancestor's entry again, so no
name is held for long.

### Findings and repairs

The message is FreeBSD's; the default is the answer under `-p` alone.
Under `-y` every repair is made and under `-n` none, with or without
`-p`. "Cut" sets an
end-of-chain mark, and "free" frees a chain from a cluster on. The last
column names the ownership-check finding (`erx_fat:check/1`) the repair
removes.

| Finding (FreeBSD's message) | Source | Repair | Default | Ownership finding removed |
| --- | --- | --- | --- | --- |
| a malformed boot sector or FAT geometry (signature, cluster size, reserved sectors, FAT count, sector counts, exFAT, version, FSInfo sector 0, data area, cluster count, root cluster, FAT size) | `boot.c:56-318` | none: fatal | n/a | |
| `Invalid signature in fsinfo block` | `boot.c:216-236` | write the signatures | no | |
| `FAT starts with odd byte sequence (...)` | `fat.c:865-943` | write the first two entries in their usual form, the media byte from the boot sector, both flags set | yes | |
| the first entries in the dirty form | `fat.c:873-886` | `MARK FILE SYSTEM CLEAN` at the end | yes | |
| `Cluster N continues with out of range cluster number M` | `fat.c:994-1001` | cut at N | no | a link that is no cluster |
| `Cluster N crossed another chain at M` | `fat.c:1003-1012` | cut at N, the later of the two linking entries | no | a cluster linked to twice |
| `Root directory doesn't start a cluster chain` | `dir.c:251-255` | none: fatal | n/a | |
| `Cluster chain starting at N ends with cluster marked TYPE`, `... out of range (M)` | `fat.c:1101-1123` | cut before the bad link, or free the chain when nothing of it is valid | no | a reached cluster that is free or bad |
| `PATH has entries after end of directory` | `dir.c:633-660` | "Extend": mark the end markers before the entry deleted, so the entries after them are read; declined, "Truncate": delete what follows | yes; Truncate no | |
| `Invalid long filename entry for NAME`, `... at end of directory PATH`, `... for volume label` | `dir.c:348-380` | delete the run's entries | no | |
| `invalid long name`, `long filename too long`, `long filename record cluster start != 0` | `dir.c:686-745` | mark the run invalid, removed as above | as above | |
| `PATH starts with cluster out of range(N)`, `PATH doesn't start a new cluster chain` | `dir.c:846-880` | a directory's entry deleted; a file's first cluster and size set to 0 | directory no; file yes | a first cluster that is no cluster, named twice or linked to; a subdirectory at cluster 0 |
| `Directory PATH has size != 0` | `dir.c:886-896` | size set to 0 | yes | |
| `` `.' entry in PATH has incorrect start cluster `` | `dir.c:900-911` | set it to the directory's own | yes | a wrong `.` |
| `` `..' entry in PATH has non-zero start cluster ``, `` ... incorrect start cluster `` | `dir.c:913-941` | set it to 0 under the root, else to the parent's | yes | a wrong `..` |
| `NAME entry in PATH has incorrect start cluster` (a subdirectory naming its own parent) | `dir.c:947-962` | delete the entry | yes | a first cluster named twice |
| `check_subdirectory: Incorrect `.' for NAME.`, `... `..' ...` | `dir.c:475-538`, `:964-976` | delete the entry | yes | |
| `Directory entry PATH of size N referencing invalid cluster M` | `dir.c:400-417` | first cluster and size set to 0 | yes | as for the file case above |
| `size of PATH is N, should at most be M` | `dir.c:434-445` | size set to the chain's | yes | |
| `PATH has too many clusters allocated` | `dir.c:446-460` | cut after the size's last cluster, free the rest | yes | |
| `Lost cluster chain at cluster N` / `M Cluster(s) lost` | `fat.c:1285-1300` | "Reconnect": a file `N` in the root's `LOST.DIR`, sized to the chain | yes | |
| `No LOST.DIR directory`, `No space in LOST.DIR` | `dir.c:1095-1131` | "Clear": free the chain | no | |
| `Free space in FSInfo block (N) not correct (M)`, `Next free cluster in FSInfo block (N) invalid` / `not free` | `fat.c:1307-1334` | "Fix": see [Where erXos differs](#where-erxos-differs) | yes | |
| any FAT change made | `check.c:122-130` | `Update FATs`; declined, the volume is left unrepaired | yes | |
| the volume dirty, nothing left unrepaired | `check.c:161-174` | `MARK FILE SYSTEM CLEAN`; declined, `***** FILE SYSTEM IS LEFT MARKED AS DIRTY *****` | yes | |

The summary line, `N files, SIZE free (N clusters)`, with `SIZE bad (N
clusters)` added when there are bad clusters, counts files and free
clusters as FreeBSD counts them (`check.c:132-158`), and formats the
sizes as `humanize_number(3)` does with `HN_AUTOSCALE`, `HN_DECIMAL`
and `HN_IEC_PREFIXES`. The exact bytes that function gives are
unverified here, and the oracle settles them. `***** FILE SYSTEM WAS
MODIFIED *****` ends a run that changed a directory or a FAT
(`check.c:187-188`).

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

### Where erXos differs

| Difference | FreeBSD | erXos, and why |
| --- | --- | --- |
| what is named | a device special file | a path that names a volume's root through a `media` grant, `/media/diskN/sN` or a session's bind of it; the report names the volume `/media/diskN/sN`. A session holds no device of a volume ([design-drives.md](design-drives.md#placing-a-volume)). A `/dev` path is refused, with a message naming the form that works |
| FAT12, sectors other than 512 bytes, mirroring off | checked | refused, nothing read past the boot sector. The FAT server serves none of them, and repairing a volume of one live FAT from the first copy, as FreeBSD does, would write from a FAT that may be stale |
| when writing starts | as it goes, from an `mmap` of the first FAT, with no dirty flag set | after the whole check, through one plan that sets the dirty flag first and clears it last (FK-R3) |
| FAT copies | never compared | an extra finding, `FAT N differs from FAT 0`, repaired by copying the first FAT's differing sectors, default yes. The FAT server keeps the copies equal on a clean volume, and fsimg's verify refuses a clean one whose copies disagree, so clearing the flag over differing copies would make a volume both refuse |
| a loop of lost clusters | never found | an extra finding, `Cluster N closes a loop of lost clusters`, at the loop's lowest cluster. Cutting the link into that cluster makes the loop a lost chain from it, which is then handled as FreeBSD handles lost chains. Default no, as for FreeBSD's cuts |
| a directory named by two entries | the second walk reaches an assertion (`fat.c:1056-1057`) | `PATH doesn't start a new cluster chain` at the second entry, which is deleted on the answer to "Remove", default no, as FreeBSD's directory case |
| a `LOST.DIR` entry whose name already exists | a second entry of that name (`dir.c:1144`, "Ensure uniqueness ... XXX") | the chain is handled as `No space in LOST.DIR` |
| FSInfo "Fix" | exact hints written | both hints written unknown, as the FAT server's dirty step writes them; every reader recounts, and fsimg and FreeBSD accept unknown |
| the report | every line | at most 1,000 finding lines, then `... N more findings`, so the report stays within the volume's memory bound |
| no `-n`, `-y` or `-p` | one question per repair | one question for the whole repair, after the findings ([open decision 2](#open-decisions)) |
| `-M` | turns off `mmap` | accepted and ignored: nothing is mapped |
| the volume during the check | checked as it lies, mounted or not | unmounted for the check and mounted again afterwards; its open files answer `eio`, as after `eject` |
| `-n` on a volume the session reaches read-only | allowed | refused with `erofs`, since every `ctl` write needs a `rw` grant (F5 of [design-files.md](design-files.md#invariants)); only root's session holds `media`, `rw` |

Every other finding, its message, its default and the exit status are
FreeBSD's.

### Bounds

* **Clusters.** Two sets of one bit per cluster: the clusters some
  entry links to, and the clusters a walk has reached. Phase 1 builds
  the first and detects cross-links. Phases 2 and 3 build the second,
  and a third pass over the FAT finds loops: allocated clusters that no
  walk reached. These are the ownership check's two sets, at the same
  limit, 4,194,304 clusters within half of `media_volume_bytes`; a
  larger volume is `refused too large` before any FAT sector is read.
* **Directories.** The frames and the subdirectories they wait on take
  the ownership check's stack bound, 16,384; a deeper or wider walk is
  `refused too large`.
* **The plan.** It is measured as a batch is measured, `erx_fat_dir:held/1`
  of its images with `erx_fat_alloc:held/1` of its overlay, each chain
  waiting to be freed counting as one sector, and is held within a
  quarter of `media_volume_bytes`. A repair that would pass the bound is
  `refused too many repairs` and writes nothing. Freeing a long chain
  takes only its first cluster.
* **Time.** Each chain is followed once, each step to a cluster not
  reached before, through a cache of FAT sectors, so FAT reads grow with
  the clusters; the FAT is read three times end to end; every directory
  cluster is read once in the walk, and once more for each finding's
  path. Each read is bounded by the window's deadline.

What the process allocates beyond these is bounded by its
`max_heap_size`; a volume that passes the bound ends the process, which
writes nothing during the check ([Failure handling](#failure-handling)).

## Writing a repair

### The repair order

The plan's steps, each with a flush after it:

1. **`dirty`, `dirty_mirrors`**: `erx_fat_alloc:dirty/1`. The clean bit
   is cleared in the first FAT, then in the other copies, and the FSInfo
   hints are written unknown.
2. **`cutting`**: every end-of-chain mark that a repair sets (a
   cross-link, an out-of-range link, a link to a free, bad or reserved
   cluster, a loop, a file's superfluous tail) and the media byte of the
   first entry, through `erx_fat_alloc:cut/2`, each entry going to every
   copy, the first copy first. A cut takes a link away and frees
   nothing: what it cuts off becomes lost.
3. **`preparation`**: directory sectors whose entries now reach less:
   entries deleted (invalid long-name runs, bad subdirectory entries), a
   file's first cluster and size set to 0, sizes shrunk, a directory's
   size set to 0, and any fix to an entry that lies after an end marker
   and is not yet read.
4. **`publication`**: directory sectors whose entries now reach more or
   are corrected: `LOST.DIR` entries, the end markers "Extend" turns
   into deleted entries, and the `.` and `..` fixes. These are the same
   two steps, with the same per-step images, as the FAT server's batches,
   through an entry-level change in `erx_fat_dir`.
5. **`release`**: chains freed (lost chains cleared, superfluous
   tails), by `erx_fat_alloc`'s release in as many commits as it needs,
   each ending in a flush. Each of these chains ends in an end-of-chain
   mark in the view, so the release meets no loop.
6. **`fsinfo`**: the FSInfo signatures, when "Fix" was answered yes.
7. **`mirrors`**: the sectors of FATs 1 to N that differ from the first
   FAT, in commits of at most 1,024 sectors.
8. **`clean_mirrors`, `clean`**: the second FAT entry, in the other
   copies first and in the first FAT last, as `erx_fat_alloc:finish/1`
   writes it. `finish/1` takes the value to write: for the FAT server,
   the clean bit set and the hard-error bit as read; for a repair, every
   bit of the entry's value set, the clean and no-hard-error bits among
   them, which is what FreeBSD's "Correct" of an odd first entry writes.

Steps with nothing to write are skipped. Under `-n`, and whenever every
answer is "no", the plan is empty and nothing is written. A plan that
holds any repair starts with step 1. When a finding is left unrepaired,
step 8 is left out, so the volume stays dirty even if it read clean
before; FreeBSD, which never sets the flag, would leave such a volume
reading clean.

### Why a cut leaves the volume no worse

* **It reads dirty.** The first FAT loses its clean bit in step 1,
  before any other write, and gets it back in the very last write.
* **No reached cluster is free.** Nothing is freed before step 5, and
  step 5 frees only chains that no name reaches once steps 3 and 4 have
  landed, after their flushes.
* **No new sharing.** Step 2 only takes links away and step 3 only takes
  names away. Step 4 adds names only to lost chains, each named once,
  after step 3's flush, and an entry that "Extend" brings into view has
  already had its own fixes written in step 3, while it was still out of
  view.
* **Kept data stays allocated.** A cluster the finished repair keeps in
  a file is never freed, and a tail cut off in step 2 that step 4 names
  in `LOST.DIR` is lost, and allocated, until it is named.
* **A second run finishes it.** Every finding is derived again from the
  medium. The partial state is one that the checker's findings cover:
  cut chains, removed names, sizes not yet shrunk, `LOST.DIR` entries
  not yet written, chains not yet freed, copies not yet equal. All of
  these are rows of the table.

FAT16 and FAT32 entries never straddle a sector, and each directory
entry lies within one sector, so every entry a step writes lands whole
or not at all.

## The surface

### The media tree

**`ctl`.** Beside `eject`, a drive's `ctl` takes one check per write,
in the form every `ctl` takes
([design-app-trees.md](design-app-trees.md#commanding-ctl)), compared
as bytes:

```text
fsck sN -FLAGS TAG
echo fsck s1 -n mine > /media/disk0/ctl     check, write nothing
echo fsck s1 -y mine > /media/disk0/ctl     check and make every repair
echo fsck s1 -pf mine > /media/disk0/ctl    preen, a clean volume too
```

`sN` names a volume of the drive's medium. `FLAGS` are `fsck_msdosfs`'s
`f`, `n`, `p` and `y`, read in the order given as `main.c` reads them,
and must include `n`, `y` or `p`, since the media domain asks no
questions. `TAG`, 1 to 32 bytes of letters, digits, `.`, `_` and `-`, is
the caller's and comes back in the report. The flags carry FreeBSD's
meaning unchanged, so there is no table from commands to modes to keep
in step. The write answers `ok` once the check has run, whatever it found;
`einval` for a malformed line; `enxio` when the drive holds no mounted
medium; `enoent` for a volume the medium does not have; and `eio` when
the volume ended during the check.

**`sN.fsck`.** A read-only file beside `sN`, present once the volume's
current process has run a check, holding the report. A write to it
answers `eacces`, as a create, remove or rename in a drive's directory
does. Like `status` and `ctl`, it takes a fixed path of mount number 0
([design-drives.md](design-drives.md#identity)). A replugged medium
starts with no report.

### The report

```text
run TAG -y
** /media/disk0/s1
** Phase 1 - Read FAT and checking connectivity
** Phase 2 - Checking Directories
Invalid long filename entry for /DCIM/IMG_0001.JPG
Remove? yes
...
3 files, SIZE free (459000 clusters)
MARK FILE SYSTEM CLEAN? yes
MARKING FILE SYSTEM CLEAN

***** FILE SYSTEM WAS MODIFIED *****
result repaired
```

The first line names the run's tag and flags; the lines between are
FreeBSD's output for those flags: `PROMPT? yes` or `PROMPT? no` under
`-y` and `-n`, and when preening the volume's path before each warning
and `FIXED` after each repair. The last line is the result:

| Result | Meaning | Exit status |
| --- | --- | --- |
| `clean` | no finding | 0 |
| `skipped` | preen of a volume that reads clean | 0 |
| `repaired` | every finding repaired | 0 |
| `unrepaired` | a finding left, or the volume left dirty | 8 |
| `fatal` | a finding that stops the check, FreeBSD's `pfatal`; nothing written | 8 |
| `refused REASON` | `format NAME`, `fat12`, `sector size`, `mirror`, `too large` or `too many repairs`; nothing written | 8 |
| `failed WHY` | a read, write or flush of the window failed | 8 |

Names taken from the medium go through the field escape
([design-app-trees.md](design-app-trees.md#a-status-line)) when the
report is built, so the report is safe to print.

### `fsck_msdosfs`

An Erlang command of the command shell's release, after FreeBSD's
synopsis:

```text
fsck_msdosfs -p [-BCfM] volume ...
fsck_msdosfs [-BCfMny] volume ...
```

For each volume in turn, it resolves the path through the session's
namespace to a `media` grant and a path `diskN/sN` within it, and
refuses one that does not resolve that way with
`fsck_msdosfs: PATH: not a volume of /media`. It writes `fsck sN` with
its `-f`, `-n`, `-p` and `-y` in the order given, and a fresh tag, to
`diskN/ctl`. When the write answers, it reads `diskN/sN.fsck`,
checks that the first line carries its tag, and prints the report
without its first and last lines. A different tag means another check
of the volume has run since; the command then prints
`fsck_msdosfs: PATH: another check ran meanwhile; see diskN/sN.fsck`
and counts the volume as status 8. The exit status is the largest of the
volumes' statuses. A usage error exits 1, and `-F` exits 5 at once, as
FreeBSD's do.

With none of `-n`, `-y` and `-p`, it runs the check with `-n`, prints
the findings and, when there are any to repair, prints `REPAIR? [yn] `
and reads one line from standard input: `y` or `Y` runs it again with
`-y` and prints that report, and anything else, or end of input, keeps
the first result.
`yes | fsck_msdosfs PATH` therefore repairs, as it does on FreeBSD.
Interrupting the command does not stop the check: it runs in the media
domain, so it finishes, and the volume mounts again.

### `fsck`

`fsck [-Cfnpy] [-t msdosfs] volume ...` runs `fsck_msdosfs` with the
same `-f`, `-n`, `-p` and `-y` for each volume. Without `-t`, it takes
the format from the drive's `status` (`sN msdosfs`); a volume of another
format prints `fsck: PATH: no checker for NAME volumes` and counts as
status 8. `-C` is passed on and ignored, as `fsck_msdosfs` ignores it.
With no volume named, `fsck` refuses with
`fsck: name a volume; erXos keeps no fstab`, since FreeBSD's form without
arguments checks `/etc/fstab`'s file systems. `-B`, `-F`, `-T`, `-c`,
`-d`, `-v` and `-l` are usage errors.

## Concurrency

The drive process takes a drive's requests one at a time
([design-drives.md](design-drives.md#finishing-a-volume)). A check holds
it only for the old process's finish and the new process's start; walks
of the drive's other volumes go on during the check. A walk of the
checked volume, and every request on it, waits for the new process's
mount, as requests wait for any mount. A second check command for the
same volume finishes the checking process, whose finish waits behind its
check, then checks again; the tags keep the two reports apart. `eject`
sends the checking process its finish, which waits until the repair has
been written, so an eject never cuts a repair. Pulling the medium, or a
failed read or write, ends the volume's process: that is a cut (FK-R3),
and the `ctl` write answers `eio`. The ordered end's freeze finishes
every volume, a checking one when its repair is written, within the
coordinator's deadline; a repair the deadline cuts leaves the volume
dirty ([design-system.md](design-system.md#shutting-down)).

## Failure handling

| Failure | Detected by | What is left | Recovery | Reported |
| --- | --- | --- | --- | --- |
| the volume passes its memory bound during the check | `max_heap_size` | the medium as it was: nothing is written before the plan is whole | the medium put back, or another check, which starts the volume's process afresh | the `ctl` write `eio`; the volume `none failed`, as any volume past its bound |
| a read fails during the check | the read function | the medium as it was | as above | `result failed read` |
| a write or flush fails during the repair | `applied/2` | a cut (FK-R3) | `fsck_msdosfs -y` again after the medium is back | `ctl` `eio`; the volume mounts read-only `dirty` at its next mount |
| the medium is pulled during the repair | the medium's supervisor | a cut | the same | the same |
| the checker's code fails | the volume's process ends | the medium as it was, or a cut | the same | the same; a bug |

No recovery machinery is added. A volume process that ends stays ended,
as any volume process does: the volume shows `none failed` until the
medium is put back, or until another check starts its process again.

## Refusals and error results

* `ctl`: `einval` (malformed, or no `n`, `y` or `p` among the flags), `enxio` (no medium), `enoent` (no such
  volume), `erofs` (a grant that is not `rw`), `eio` (the volume ended).
* The report's refusals, each with nothing written: `format NAME` for a
  volume that is not FAT16 or FAT32, `fat12`, `sector size`, `mirror`,
  `too large`, `too many repairs`.
* The commands: usage (exit 1), `-F` (exit 5), a path not under a
  `media` grant, a `/dev` path (both exit 8, as FreeBSD's "Can't open"
  is), and a check whose tag does not come back.

## Security

The check runs where the volume is already parsed, with the same
authority: the volume's sectors through its placement, so it can read
and write nothing outside the volume. Its decoders are Erlang, so a
crafted volume can end the check, by its bound or a failure, but cannot
reach memory. The `ctl` grammar is untrusted input to the media domain
and has a fuzz target of its own. Only a session holding a `media` grant
with rights `rw`, which the board manifests give root's session alone
([design-drives.md](design-drives.md#how-each-requirement-follows),
DR-R8), can start a check. The
report is text from the medium after the field escape, so printing it
cannot drive the operator's terminal. A repair writes a stranger's
medium only when the user asks for it, with `-y`, `-p` or a "y" answer.

## What is reused and what is new

Reused: `erx_fat_read:boot_sector/1` and `erx_fat`'s admission rules,
so the boot sector has one decoder; `erx_fat_entry:decode/1`,
with the checker reading a long-name entry's cluster field itself, since
`decode/1` also answers `bad_long` for a non-zero type byte, which
FreeBSD does not check; `erx_fat_name:checksum/1`; `erx_fat:layout/1`
and `cluster_sectors/2`; `erx_fat_alloc`'s `dirty/1`, `free/2`,
`commit/1`, `finish/1`, its overlay and its per-copy writes;
`erx_fat_dir`'s per-step sector images and `view/1`;
`erx_media_volume`'s probe, writable rule, mount and `applied/2`; the
drive process's finish; `erx_cmd`.

New: `erx_fat_check`, the pure checker; a reason with each admission
refusal of `erx_fat`, naming the rule that failed, which the checker
prints as FreeBSD's message for it; `erx_fat_alloc:cut/2`, which
ends a chain at a cluster without queuing what follows for release (what
follows may be another chain's, which `shrink/3` would free);
`erx_fat_dir:edit/4`, which sets an entry's bytes at a slot from a step
on; `finish/1`'s value for the second entry; the volume process's check
order and its report; the drive process's check request; the media
tree's `ctl` grammar and `sN.fsck` node; the commands `fsck_msdosfs` and
`fsck`; and the test generator of damaged images.

`erx_fat_alloc` and `erx_fat_dir` assume a volume whose ownership check
passed. The checker uses them only for chains that end in an
end-of-chain mark in the view and that no other chain shares, which its
cuts guarantee before any release, so that assumption holds for
everything they are given.

## Verification

Each passing case is paired with a seeded fault that must make it fail,
so a pass shows the code under test ran.

### Damaged images

A host generator, `test/erlang/erx_fat_damage.erl`, writes each class of
damage into a FAT16 or FAT32 image that fsimg or the FAT server's host
build made: for each row of the findings table and each row of
[Where erXos differs](#where-erxos-differs), it changes the bytes a
declared case names (a FAT entry, an entry's field, a run's order
number), so one image carries one class, and some carry several. The
images, and the stick's pattern (an orphan run followed by a later
name's run in its short entry's slot), are generated in the build tree
and never committed; each case declares the findings, the result and the
tree (names, sizes, content hashes) the repair must give.

### Host tests

| Test | Seeded fault that must fail it |
| --- | --- |
| each class under `-n`: the declared findings, `result unrepaired` or `fatal`, and no write reaching the fake window | a forced "no" that still answers "MARK FILE SYSTEM CLEAN" with its default, so a dirty image is written |
| each class under `-y`: the declared tree, `result repaired`, then a second `-n` run giving `clean`, `erx_fat:check/1` answering `ok` and the writable rule allowing `rw` (FK-R2) | each repair removed in turn (cross-link cut, loop cut, copy sync, `..` fix): a second check then finds it, or `check/1` answers `tree` |
| each class under `-p`: yes-default repairs made, no-default ones left with `unrepaired`; a clean image `skipped` and untouched; `-pf` checks it; `-py` repairs everything and `-pn` nothing | preen answering every question yes when no answer is forced, so the cross-linked image is repaired under `-p` |
| the order of examination: two files sharing a tail, and a file and a directory naming one chain, repaired as FreeBSD chooses (the later linking entry cut; the second claimant truncated or removed) | the FAT walk run from the last cluster down, so the other file is cut |
| crash consistency (FK-R3): for each class's plan on a small image, a cut after every step and after every subset of the last step's sectors; each result reads dirty, keeps every kept cluster allocated, holds no newly shared cluster, and is brought to FK-R2 by a second `-y` run | the release step placed before `preparation`, so a cut leaves a name on a freed cluster; the dirty step left out, so a cut leaves a half repair that reads clean |
| the FAT server's own cut: `erx_fat_dir`'s removal of a name whose run crosses a sector boundary, cut between the two sectors of its `preparation`, leaves an orphan run, which `-n` reports and `-y` removes | the deleted-entry rule ending a run, so the orphan is read as the next name's |
| bounds: an image of 4,194,305 clusters and one of 16,385 pending directories `refused too large` with nothing read past the boot sector and FAT, and a repair past the plan bound `refused too many repairs` with nothing written | the plan measured without its directory images, so the large repair is written |
| refusals: FAT12, 1,024-byte sectors, mirroring off and an EROFS volume each refused, with no write | the mirror test dropped, so the active FAT 1 volume is repaired from FAT 0 |
| the media tree: `fsck sN` with each flag string, the later of `n` and `y` winning, a line without `n`, `y` or `p`, and each refusal; after `-y`, an old fid answers `eio`, `sN.fsck` holds the tagged report, and the volume shows `rw`; an `eject` during a check waits for the repair; the fake window ended mid-repair answers the `ctl` write `eio` and leaves the image dirty | the check started without finishing the old mount, so the old process's last batch lands after the repair's first step; the report kept by the drive process, so it survives the medium |
| the commands: each flag and their order passed through, usage (1), `-F` (5), `fsck -t msdosfs`, `fsck` with no volume, a `/dev` path, a bind at `/mnt` resolving to its volume; the question answered `y`, `n` and with end of input; a report whose tag is another run's | the exit status taken from the `ctl` write instead of the report's result, so `unrepaired` exits 0 |

### Fuzz targets

* `erx_fat_check` over mutated images, seeded from every damaged image:
  no crash, the bounds kept, and, when the result is `repaired`, the
  plan applied to the image followed by a `-n` run gives `clean`. A copy
  whose chain walk drops its reached-set test must fail by passing its
  time bound on a looped image.
* The `ctl` grammar of a drive, seeded from the commands above
  ([design-app-trees.md](design-app-trees.md#commanding-ctl)).

### The oracle

The FreeBSD 15.1 oracle guest that the command shell's tests use
([design-shell.md](design-shell.md#verification-and-testing)), in QEMU
without a network device, gets each damaged image as a disk of its own,
a fresh copy for each run, and runs `fsck_msdosfs` under `-n`, `-p`, `-pf`
and `-y`. Per image and flags, the run passes when the exit status is equal,
the report's middle lines equal FreeBSD's output byte for byte
(the device's name replaced by the volume's path), and, for `-y`,
FreeBSD's `-n` exits 0 on erXos's repaired image, erXos's `-n` gives
`clean` on FreeBSD's, and both images read back, through `erx_fat` on
the host, to the same names, sizes, contents and free cluster count.
Classes in [Where erXos differs](#where-erxos-differs) are compared only
in their other findings. It runs at the milestone gate. Seeded fault:
the default of "Reconnect" flipped to no makes the preen comparison on
the lost-chain image fail.

### QEMU case

In the `usb` suite: a FAT32 stick carrying the stick's pattern, a
cross-linked file and its dirty flag set mounts read-only with `dirty`.
`fsck_msdosfs -n /media/disk0/s1` exits 8 and leaves the stick's bytes
unchanged; `fsck_msdosfs -y /media/disk0/s1` exits 0, the volume shows
`sN_mount rw`, every kept file reads with the harness's hashes, and the
stick, read on the host after `eject`, passes fsimg's verify. A second
stick is detached with `device_del` during its repair, comes back
read-only `dirty`, and a second `-y` repairs it to the same check.
Seeded faults: the remount after the check left out, so the volume stays
read-only; the dirty step left out, so the detached stick mounts `rw`
with half a repair.

How long a check of a full 32 GiB FAT32 stick takes over USB on the
Raspberry Pi 4 is unmeasured, and goes on the performance watch list.

## Alternatives considered

**A program over the medium's raw sectors.** The shape
[design-drives.md](design-drives.md#alternatives-considered) sketches: a
`data` file of an idle medium, behind an administrator's facet, with
`fsck_msdosfs` as an ordinary program over it. It would give FreeBSD's
per-question prompts for free, and `newfs_msdos` later. It loses here:
it parses a stranger's volume in the session's runtime instead of in
the media domain (DR-R2), and needs a second interface or rights level
for the facet, a rule for opening a medium only while it is idle, a way
back from an ejected medium to a mounted one, and the partition table
read again in the program. The remount needs none of these. If
`newfs_msdos` is wanted, that shape remains its home.

**FreeBSD's C as a program or a NIF.** It would match FreeBSD by
construction. It loses on principle 1, puts C over untrusted bytes, and
keeps FreeBSD's write-as-you-go order, which is not crash safe. The
Erlang checker reuses the FAT server's decoders and its write path.

**Repair as you go, as FreeBSD does.** Simpler to write, but a cut
leaves half a repair on a volume that may read clean. Plan first, write
after costs one view, which the FAT server's batches already have.

**Only an orphan-run cleaner.** It would fix the stick and nothing else.
Sticks come from cameras, Windows and macOS too, and FreeBSD's whole set
is what a user of `fsck_msdosfs` expects.

**A per-question conversation.** A file that is written and read on one
fid could carry FreeBSD's questions one at a time. It is a live
conversation, which needs a declared protocol of its own, and nothing
here needs it ([open decision 2](#open-decisions)).

## Open decisions

1. **Where the check runs.** (a) In the volume's process, by remount, as
   designed; (b) in a session program over a raw `data` file.
   Recommendation: (a). It keeps every byte of a medium in the media
   domain and adds no facet or idle rule; (b) waits for a consumer such
   as `newfs_msdos`.
2. **The form with no `-n`, `-y` or `-p`.** (a) One question for the
   whole repair, after the findings, as designed; (b) refuse it, naming
   `-n` and `-y`; (c) one question per repair, through a declared
   conversation protocol. Recommendation: (a). It asks before writing,
   as FreeBSD promises, and `yes |` works; (c) costs a protocol for a
   form scripts do not use.
3. **Preen when a dirty volume mounts.** FreeBSD preens its file
   systems from `/etc/rc` before mounting them (`fsck_msdosfs.8`,
   DESCRIPTION). erXos could have the volume's process run the check with
   `-p` when the writable rule finds `dirty`. Recommendation: not now.
   A repair should write a stranger's medium only when asked, and
   preen's default-yes repairs include deleting entries. Revisit once
   the check has run on real sticks.
4. **The FAT server's orphan runs.** (a) `place/5` refuses every run
   that starts right after a live long-name entry, extending the rule
   that already holds for names stored as a short entry alone, so erXos
   never turns an orphan into the stick's overlap; (b) also give a
   name's short entry a step of its own, so a cut never leaves an orphan
   (two more flushes for a batch that removes or adds a long name).
   Recommendation: (a) only. A cut already leaves the volume dirty, so
   the repair removes the orphan before erXos writes there again, and
   (a) costs no flush. This is a change to
   [design-storage.md](design-storage.md#removable-media-fat), filed in
   [TODO](todo-storage.md#bugs-by-subsystem).

## References

* [design-drives.md](design-drives.md): volumes, the writable rule,
  finishing, the media tree, `ctl`, `status`, identity.
* [design-storage.md](design-storage.md#removable-media-fat): the FAT
  server, its batches and steps, the ownership check.
* [design-app-trees.md](design-app-trees.md): `ctl`, status lines and
  the field escape.
* [design-files.md](design-files.md): waiting requests and keepers;
  rights.
* [design-shell.md](design-shell.md): Erlang commands, S-R4, the FreeBSD
  15.1 oracle guest.
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
