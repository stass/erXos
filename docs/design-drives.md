# Drives: every medium, every format

A **drive** is a place that holds at most one medium at a time: a USB
stick, an SD card in a USB reader, or the medium of a block device the
manifest gives to no file system of its own, such as a second virtio
disk. Every drive reaches files by one path. The domain that drives the
medium's transport serves the medium **whole**, as one window, and
parses none of it. One domain of its own, the
**media domain**, which holds no device, reads the medium's partition
table and mounts each partition, a **volume**, behind one process,
which names the volume's file system from its contents and parses it;
it serves every drive's volumes as files at `/media/diskN/sN`, and a
session places any of them wherever it likes in its own namespace with
`mount`. A release
serves FAT16, FAT32 and EROFS volumes; development builds and test
images serve littlefs volumes too; erXos's F2FS joins as one row of the
same format table. The key idea is that everything a medium's bytes
reach, the table reader, each volume's process and littlefs's C code in
its sub-space, is a child of that medium's supervisor and ends with the
medium's window, and that a medium's earlier mount is gone before a
later one starts, so a crafted medium ends at most its own mounts, no state of one medium reaches the
next, and "any format on any drive" is the product of one drive path and
one format table rather than a matrix of cases.

Decisions every reader needs:

* **A drive serves its medium whole.** The USB domain, or the domain
  that drives a block device of the drive role, runs a transport and one
  window covering the medium, and hands that window out through the
  drive's grant. It reads no table, so nothing a medium holds is parsed
  in a domain that holds a device. Asked again, after a restart in the
  media domain, the grant first ends and restarts the medium's block
  service, so an earlier mount's requests are gone before a new mount
  starts and no medium is mounted twice at once.
* **The row is the grant.** A drive's window row is itself the grant
  that carries the drive to the media domain: the domain service mints,
  through the drive's serving domain, a facet whose one request asks for
  the medium's window, as it mints any configured domain's service for
  its grantee, and again for each new incarnation of either domain
  ([How the grant reaches the media domain](#how-the-grant-reaches-the-media-domain)).
* **One media domain holds every drive.** It holds no device, no window
  of the boot medium and nothing but the drives' grants, and it serves
  one files service, `media`, which sessions mount at `/media`.
* **Detected, never declared.** The table decides where volumes lie;
  each volume's format is what its own bytes say, by a probe that
  follows FreeBSD's `fstyp`. No manifest row, table type byte or user
  names a format.
* **A volume's failure ends its mount.** Each volume's probe and parser
  run in that volume's own process under a memory bound, and littlefs's
  C in a sub-space with a budget of its own, so a crash, an exhausted
  allowance or a memory error ends only that volume and never costs the
  media domain a restart; a crafted table ends that medium's mounts, and
  only volumes that together exhaust the media domain's memory end more
  ([Time and memory](#time-and-memory)).
* **Written only as what it is.** A volume is written only when its
  selected format is one erXos writes, no other format the build writes
  has its signature on it, the medium flushes, and the format's own state
  allows it; otherwise it is read-only, and a medium whose flush fails is
  refused.
* **Two acts called mounting.** The media domain mounts each volume,
  starting its file system, at the first walk of its drive after the
  medium arrives. A session mounts trees: the shell's `mount` places
  `/media`, or any volume under it, anywhere in the session's namespace,
  and `umount` removes the entry, as an NFS client mounts what a server
  exports ([Placing a volume](#placing-a-volume)).
* **One finish for eject and for the machine's end.** A volume's last
  request closes it, writes what it holds and flushes, so a write it
  acknowledged survives `eject` and an ordered end on a medium that
  flushes.
* **EROFS from a drive is unauthenticated, and kept apart.** The EROFS
  decoder is shared. The system's images reach it only through
  `erx_erofs:mount/2`, which takes only a hash-checked image; a drive's
  reach it only through the media application's own frontend and block
  source, which only the media domain's release holds. E1 holds for the
  system's own images as it stands.
* **littlefs from a drive is for development and tests, as its port.**
  No release serves it. Where it is served, each littlefs volume has its
  own sub-space that holds its channel and data area alone, and its
  owner checks every block it asks for against the volume and every
  write against the volume's right to be written.

## Context

### What is matched

FreeBSD's partition and file-system detection, from the FreeBSD source
at commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`
([References](#references)):

* **An MBR, or a boot sector.** GEOM's MBR scheme takes sector 0 as a
  table when it ends in `0x55 0xAA` and every entry's status byte is
  `0x00` or `0x80`, unless all four entries are zero and the sector
  holds a plausible BIOS parameter block, a bytes-per-sector field that
  is a power of two from 512 to 4096 and a sectors-per-cluster field
  that is a power of two from 1 to 128, in which case the sector is a
  boot sector and the medium has no table (`g_part_mbr.c:176-191`,
  `:413-469`). It skips an entry of type `0x00` or `0xEE` and one whose
  start or length is 0 (`:505-508`).
* **A GPT.** GEOM's GPT scheme wins over the MBR when sector 0 holds an
  entry of type `0xEE` and sector 1 holds the header's signature, or,
  with no signature there, the medium's last sector does
  (`g_part_gpt.c:861-926`, the `0xEE` test at `:899-905`, which looks at
  the signature and the type bytes alone, the backup's at `:919-926`). It reads both headers, the backup at the sector the
  primary names as its alternate when the primary passed, and at the
  medium's last sector otherwise (`gpt_read_hdr`, `:441-542`, the
  choice at `:454-462`). A header is taken only if its CRC-32 checks,
  its revision is at least `GPT_HDR_REVISION` (`:487`), its usable area
  lies after sector 1 and before the last sector (`:500-504`), and its
  entry array's first and last sectors lie inside the medium and outside
  the usable area (`:512-524`); an entry array only if its CRC-32 checks
  and it is at most 4,096 entries of at most 1,024 bytes (`gpt_read_tbl`,
  `:544-604`; `:150`, `:159`). The primary copy is used unless its array
  failed, when the backup is (`g_part_gpt_read`, `:930-1092`, the
  choice at `:1000-1043`).
* **Integrity.** A table with an entry that starts before the first
  usable sector, ends past the last, ends before it starts, or overlaps
  another entry is refused whole, by default (`g_part.c:143-147`,
  `g_part_check_integrity`, `:325-436`, called at `:2034`).
* **The file system's name.** `fstyp` reports the file system a provider
  holds by trying each format's header in a fixed order, the header at
  the largest offset first, since a volume formatted one way and then
  another may keep the first format's header (`fstyp.c:57-109`). Its FAT
  test is the `0x55 0xAA` signature, or the Raspberry Pi Pico
  bootloader's zero signature behind its jump bytes, and then a non-zero
  16-bit FAT size with `FAT` at the FAT12 and FAT16 type field, or a
  non-zero 32-bit FAT size with `FAT` at FAT32's (`msdosfs.c:48-60`,
  `:77-115`). Its NTFS test is the system id `NTFS    ` at byte 3 of
  sector 0 alone (`ntfs.c:146-147`).
* **`/media`.** FreeBSD's automounter mounts removable media at
  `/media/KEY`, KEY the volume's label or its device name, mounting each
  format by `fstyp`'s name and refusing, with a log line naming it, a
  format it cannot mount (`special_media:7-31`, `:34-69`); the map is
  commented out of the default `auto_master`, with the options
  `nosuid,noatime,autoro` (`auto_master:5`).

erXos keeps the table tests, the whole-table refusal, the probe's order
and its names. It differs where its model differs, each difference
stated where it is made: a volume lies at `/media/diskN/sN`, numbered
as macOS numbers disks and partitions, since `diskN` names a drive
already ([design-usb.md](design-usb.md#mass-storage-reaches-the-file-servers));
a volume's label is shown, not used as a path; links on a drive are not
followed; no extended partition's chain is followed; a GPT is read only
behind its protective entry, and behind one it is the only reading; and
a GPT's usable area must lie apart from every metadata sector the reader
knows, where FreeBSD checks only the array's two ends.

littlefs v2.11.3, the tree's copy (`littlefs/ORIGIN.md`), mounts a
volume only when the superblock's block size equals the configuration's
(`lfs.c:4618-4622`) and its block count equals the configuration's
unless that is 0 (`:4608-4616`). Its specification at the same commit
puts the superblock first in the metadata pair of blocks 0 and 1 and its
name tag first in the pair, so the string `littlefs` lies at byte 8 of
a valid superblock block (`SPEC.md:444-447`); the mount itself finds
the superblock by matching tags, not by offset (`lfs.c:4496-4520`).

### What it builds on

* The block service's transport contract and windows, the write path
  and its trial rule U4, and the deadlines each layer keeps
  ([design-storage.md](design-storage.md#data-model)).
* USB media and their lifetimes: a medium is a fresh reference from its
  unit's readiness to its end, every request carries it, and its block
  service ends with it; drives are places numbered across the machine
  ([design-usb.md](design-usb.md#media-and-drives),
  [design-usb.md](design-usb.md#mass-storage-reaches-the-file-servers)).
* Windows reach their holders as grants of the domain that serves them,
  again after that domain's restart
  ([design-system.md](design-system.md#devices), "Partition windows").
* The grant records of a configured domain's services: the domain
  service introduces the grantee to the server, asks the server's mint
  for a facet bound to the grantee and installs it in the grantee's
  registry, again for each new incarnation of either
  ([design-system.md](design-system.md#facets-a-configured-domain-serves));
  a facet admits only its grantee's requests of the operations its
  interface lists ([design-domains.md](design-domains.md#facets)); a
  pid reaches another domain only in a frame its own domain sends, which
  exports it there with `send` alone
  ([design-domains.md](design-domains.md#exports)); and a facet may
  start processes of its own domain that act for its grantee alone,
  each running the facet's admission path and charging its account
  ([design-domains.md](design-domains.md#facets), "Processes a facet
  starts").
* `erx_fs`, its grants and its keepers, which answer a waiting read or
  write later and answer `eio` when they end, and its freezing
  checkpoint, which closes mutation admission at every grant
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
* The ordered end, which freezes every service on its durability facet
  under one deadline ([design-system.md](design-system.md#shutting-down)).
* A facet's mount, read at each lookup against the facet registry;
  `erx_ns:bind/2,3` and `erx_ns:unmount/1`, which place and remove a
  namespace entry; and the resolver's rule that follows no link in a
  tree it reached through `{facets, svc}`
  ([design-files.md](design-files.md#building-binding-and-mounting),
  [design-app-trees.md](design-app-trees.md#links)).
* The `status` and `ctl` files of a tree its owner serves
  ([design-app-trees.md](design-app-trees.md#a-status-line),
  [design-app-trees.md](design-app-trees.md#commanding-ctl)).
* The FAT server's format rules
  ([design-storage.md](design-storage.md#removable-media-fat)); the EROFS reader
  and E1 ([design-storage.md](design-storage.md#reading-erofs-images));
  littlefs's sub-space port and its owner's deadline
  ([design-storage.md](design-storage.md#read-write-storage),
  [design-programs.md](design-programs.md#a-program-is-a-port)), and
  littlefs's stopgap rules
  ([design-stopgap.md](design-stopgap.md#littlefs-on-a-drive)).

## Requirements

* **DR-R1. Any drive, any served format.** Every drive serves FAT16,
  FAT32 and EROFS volumes, and in development builds and test images
  littlefs volumes, on a medium with an MBR, a GPT or no table; every
  other format, FAT12 among them, is named and refused. A new format is
  one row of the format table and a new kind of drive one transport.
* **DR-R2. Confinement.** A crafted volume ends at most its own mount,
  and a crafted table its own medium's: never another drive's media, the
  domain that serves its transport or the boot medium's storage, and the
  media domain only by exhausting its memory, which its restart recovers
  ([Time and memory](#time-and-memory)). No C parser of a medium runs where it can reach a
  device, a window or another volume. What any code can still reach
  through the kernel, the CPU and a device's DMA is stated in
  [Security](#security).
* **DR-R3. The authenticated path intact.** E1 holds for the system
  partition and every package as it stands: no byte of a drive reaches
  the EROFS decoder in a runtime that mounts a package or serves the
  `system` tree.
* **DR-R4. A medium's state dies with it, and it is never mounted twice
  at once.** No process, sub-space or cache holding a medium's state
  outlives the medium's mount; an open file of an ended mount answers
  `eio`; a new mount of a medium starts only after every request of its
  earlier mount is answered or refused, and a new medium mounts afresh.
* **DR-R5. Never written by a misreading, never lost by an orderly
  end.** A volume is written only when erXos writes its selected format,
  no other format the build writes claims it, and the medium flushes; every other volume
  is read-only or refused, with the reason shown. On a medium that
  flushes, every write a volume acknowledged before an `eject` or an
  ordered end that finished is on the medium.
* **DR-R6. Untrusted input.** Every parser of a medium's bytes is
  bounded and has a fuzz target; text a medium supplies reaches a sink
  only through its escape; a link on a drive is never followed.
* **DR-R7. No new mechanism.** Drives reach their files through windows,
  grants, one files service, `erx_fs` keepers and its freeze, the
  littlefs port and a `status` and `ctl` pair, each named here; a
  drive's grant reaches the media domain through the grant records,
  mints and facets every configured domain's service uses, and its
  window through a process its facet starts.
* **DR-R8. Authority.** Which domains see the drives is the manifest's
  `media` facet rows' and nothing else's: a domain granted `media` sees
  every drive, with its row's rights, and a domain not granted it sees
  none. No grant narrower than every drive exists.
* **DR-R9. Placing.** A session places the media tree, or any volume of
  it, wherever it likes in its own namespace, and removes it, with the
  shell's `mount` and `umount`, over namespace calls that exist.

Non-goals: FAT12, exFAT, NTFS, ext2, UFS, HFS+, APFS and ISO 9660, each
named by the probe and refused; littlefs volumes in a release; logical
partitions inside an MBR's extended partition; repairing a table or a
volume; media whose blocks are not 512 bytes; device nodes for drives
or volumes, and any session's access to a medium's sectors; booting,
updating or loading code from a drive.

## The construction

### One path from medium to files

```text
 the transport's domain (the USB domain, or a block device's driver domain)
   medium ---> one window, the medium whole ---> drive grant, diskN
                                                      |
 the media domain                                     v
   drive process (one per drive; parses nothing)
     on the first walk of diskN after a medium arrives:
       medium supervisor (one per medium; ends when the window ends)
         reader: table (MBR | GPT | none) -> volumes s1..sN, then ends
         one volume process per volume: probe, then mount:
           msdosfs (the FAT server) | erofs | littlefs (owner + port sub-space)
   media tree, /media: each request on a volume goes to its volume process
```

1. **The medium.** The transport's domain runs, for each medium, the
   transport and one window covering every sector of it, and the drive's
   grant answers that window's pid; the drive's facet hands the media
   domain a proxy of the window, which takes the window's requests under
   the grant's limits. That domain reads no sector of the medium on its
   own behalf.
2. **The volumes.** In the media domain, a reader process under the
   medium's supervisor reads the table with `erx_media_table`, a pure
   function of the sectors it asks for, which answers the volumes and
   where each lies, or refuses the table whole
   ([The table](#the-table)), and starts one volume process for each
   volume.
3. **The formats.** Each volume process reads a fixed set of its own
   sectors and names its format with `erx_media_probe`, a pure function
   over them ([The probe](#the-probe)).
4. **The mounts.** A volume whose format the format table serves mounts,
   read-write or read-only by one rule
   ([The writable rule](#the-writable-rule)); one it does not serve
   stays, unmounted, to say why.
5. **The files.** The media tree routes every request on a volume to its
   volume process and serves the rest itself, and a session places the
   tree, or any volume of it, in its namespace
   ([The media tree](#the-media-tree)).
6. **The finish.** `eject` and the machine's ordered end give each
   volume its last request, which closes it, writes what it holds and
   flushes ([Finishing a volume](#finishing-a-volume)).
7. **The end.** When the medium's window ends, or its mount is finished,
   the drive process ends the medium's supervisor, and with it every
   volume process and every littlefs port; a node a fid holds names its
   volume process, so every later request on it answers `eio`.

### How each requirement follows

* **DR-R1.** Steps 2 to 7 do not depend on the transport: a medium is a
  window, whoever serves it. They do not depend on the format either: a
  volume is a range of sectors and a format name, and the format table
  maps the name to a volume module. FAT, EROFS and littlefs are its
  rows; F2FS is one more ([F2FS](#f2fs-when-it-joins)).
* **DR-R2.** Every byte of the medium is parsed in the media domain,
  which holds no device. The table runs in the medium's reader, each
  volume's probe and format in its own volume process, both under a
  memory bound, and littlefs's C in its own sub-space under a budget of
  its own, whose block requests its owner checks against the volume; the
  medium's supervisor and the volume processes are temporary children,
  so no failure of theirs is counted against any restart intensity, and
  the drive process, which touches no byte of the medium, is the only
  process of a drive the media domain's supervisor restarts; what memory
  volumes can still take from the domain is
  [Time and memory](#time-and-memory)'s.
* **DR-R3.** The decoder's source entry is called only by the
  authenticated frontend and by the media application's frontend, whose
  block source no release but the media domain's holds
  ([EROFS, unauthenticated](#erofs-unauthenticated)).
* **DR-R4.** Step 7: the supervisor is the medium's, so its end takes
  every holder of the medium's state with it, the EROFS block cache and
  the littlefs port included. Asked for a window it already answered, the
  grant ends and restarts the medium's block service through the one
  process that issues the medium's commands, so every request of the
  earlier mount is answered or refused before the new mount sends its
  first ([A drive and its medium](#a-drive-and-its-medium)).
* **DR-R5.** The writable rule is the one place that decides writing,
  from the probe's answer, the mount's flush and the format's state. The finish is the one way a volume is closed while its
  medium stays, and every request reaches the volume through its
  process, so the finish is its one admission barrier.
* **DR-R6.** The table reader, the probe and each format have fuzz
  targets ([Fuzz targets](#fuzz-targets)); labels and names reach the
  `status` file through the field escape; the resolver follows no link
  in the `media` tree.
* **DR-R7.** [The mechanisms used](#what-it-builds-on) are all
  existing. The names this design adds are a window role, `drive`; the
  grant's restart of a block service asked twice, and the medium
  reference that `erx_blk`'s device process checks for it, USB's rule;
  the interface `drive`, one grant of it for each drive window row, its
  mint, its facet and the facet's window proxy ([How the grant reaches the media
  domain](#how-the-grant-reaches-the-media-domain)); one service, `media`,
  with its durability facet, and its mount point and `nofollow` mark in
  `erx_ns`'s table of facets; the decoder's source entry, `erx_erofs:mount_source/2`; the
  probe's table, `abi/formats/probe.txt`; two limits, `media_volumes_max`
  and `media_volume_bytes`; one statfs type, `media`; the
  argument forms of the shell's `mount` and `umount`; and the modules of
  `erx_media`.
* **DR-R8.** A session reaches `/media` only through a `media` facet
  the manifest grants it, and the tree it serves holds every drive. The
  media domain holds the drives because each drive's window row names
  it, and no other row grants `drive`
  ([How the grant reaches the media domain](#how-the-grant-reaches-the-media-domain)).
* **DR-R9.** `mount` and `umount` are `erx_ns:bind/2,3` and
  `erx_ns:unmount/1` ([Placing a volume](#placing-a-volume)).

### What disappears

* The window row per partition of a drive, its partition number, the
  drive grant's `no_partition`, and the partition process in the USB
  domain: a drive's grant is the medium whole, and the medium's table is
  read where nothing else of value lies.
* The FAT server's own mounting on each walk, its unmount on a window's
  end, and its retry of a refused mount at the next walk: a volume
  process is the mount, and the medium's supervisor ends it.
* A record of mounted media that must survive a restart: asking again
  restarts the medium's block service.
* A handover of its own for drive grants, and a manifest row to declare
  each: a drive window row is a grant, carried by the grant records,
  mints and facets every configured domain's service uses.
* A second-signature condition in a release: a release writes one
  format, so no other format it writes can be found.
* A placement rule per format: every format runs in its volume's
  process, and the one exception, C, runs in its volume's sub-space.
* The `fat` window role and the exchange partition of the boot medium: a
  medium to exchange files on is a drive, whatever its format.
* The hash-checking reader's `unchecked` mode, which only tests used:
  the tests read images through the media domain's block source, so
  every handle of `erx_verity` has a tree.
* A tree of stable names for media: a volume's label and serial number
  are lines of its drive's `status` file.

## Drives

### A drive and its medium

A drive is a place the manifest names, `diskN`, served by the domain
that drives its medium's transport:

* **A USB drive** is one of the drives the manifest names on a USB
  domain's controllers. A unit's medium, once ready, takes the lowest
  free of them, and frees it when it ends
  ([design-usb.md](design-usb.md#media-and-drives)).
* **A block device's drive** is a block device whose one window row has
  the `drive` role: its medium is the device's, present for as long as
  the device's driver runs. The domain that holds the device runs
  `erx_blk` with that device's transport and serves its medium as the
  drive instead of reading the boot medium's layout. Such a domain holds
  that device's unit, no other unit and no window, and nothing else but
  what the list of [Manifest rows](#manifest-rows) admits, so property 9
  of [design-system.md](design-system.md#the-manifest) holds for an
  unconfined one.

The serving domain learns its drives when it is created, as it learns
its devices: the domain library writes it one `-erx_record drive ROLE N`
for each drive window on a device it holds, ROLE that device's role,
`usb` or `block`, and N the drive's number
([design-fiasco.md](design-fiasco.md#drive-records)). The USB domain's
`usb` records are its drives; a block device's driver that finds a
`block` record serves its medium as that drive, and one that finds none
reads the medium's layout.

For each medium, the serving domain runs the transport the storage
design defines and one window process whose sectors are the medium's
whole capacity ([design-storage.md](design-storage.md#data-model)),
writable unless the boot is a trial, when the write path refuses every
write to it with `erofs` (U4). The drive's grant, `erx_blk_drive`,
answers one request, `window`: `{ok, Window}`, the pid of the medium's
window, or `{error, no_medium}` while the drive holds none. It learns of
each window as the medium's block service starts it, and forgets it when
the window ends ([design-usb.md](design-usb.md#concurrency)). Holding
the grant is holding whatever medium the drive holds, whole. The grant
and the window are processes of the serving domain that serve their
own domain alone; the media domain reaches the window only through a
proxy the drive's facet starts for it
([How the grant reaches the media domain](#how-the-grant-reaches-the-media-domain)).

**One occupant.** The grant is the drive's one record of which medium
it holds, and it takes a medium only from a serve whose issuer is the
drive's **occupant**, the one process that may land media in it. A
drive without an occupant takes none. The two kinds of drive differ only
in how long an occupation lasts:

* **A USB drive is a place.** Its grant lives as long as the USB domain.
  The function of a unit whose medium becomes ready occupies it with
  `occupy/2`, which answers `taken` unless the drive has no occupant and
  holds no medium, and holds it for that one medium: until the medium's
  window ends, or until the function ends first.
* **A block drive is its device.** Its grant is started by the device
  process, linked to it, and occupied by it from its start for its whole
  life, so the occupation does not lapse between one block service and
  the next under a fresh reference, and every serve the grant takes is
  that process's. The grant ends with the device process, as the
  window does; the device's next process, after a restart through its
  driver-control facet or the domain's own, starts a fresh grant, whose
  first ask answers its first window. Nothing of the earlier mount
  reaches the device by then: its window ended with the old process,
  and the device is reset before the next one posts anything
  ([design-system.md](design-system.md#drivers), "Resets").

So a serve that arrives after its occupation ended, from a function that
ended before its medium was served or from a medium that no longer holds
the drive, finds no occupant of its issuer and is dropped, and the drive
it named is free at once rather than held by a window that is ending.
Who may send a serve at all is the serving domain's own processes: the
grant serves its own domain alone
([How the grant reaches the media domain](#how-the-grant-reaches-the-media-domain)).

The first ask for a medium's window answers the window its block
service started. A later ask comes only from a drive process or a media
domain that restarted, or whose proxy of the window ended, and so lost
the window, whose earlier mount may still
have requests on their way. The grant therefore first **ends the
medium's block service**, holds the ask until the old window has ended,
so the earlier mount can have no further effect, and only then answers.
Both transports end a medium
the same way, through the **medium reference** every request of the
medium carries, which the one process that issues the medium's commands
checks at the head of its queue:

1. **The reference ends.** The issuing process makes the medium's
   reference stale in one step. From then every request that carries
   it, queued there or arriving later from the old window, whichever
   process forwarded it and however late, is answered
   `{error, {device, gone}}` and never issued. The old window's
   admission is closed where commands are issued, so no race between
   senders passes it.
2. **The issued requests finish.** A request already issued to the
   device completes, or fails at its in-flight bound, before the issuing
   process takes anything queued behind the step; a failure at the bound
   ends the device process, and with it every window, as any such
   failure does.
3. **The old block service ends**, its windows with it, and the grant
   waits for their end.
4. **The grant answers the held ask** when it sees the old window end:
   with the window of the medium's next block service, under a fresh
   reference, if one has started by then, and `{error, no_medium}`
   otherwise. The holder's next walk asks again and finds the medium
   once its new window has started.

On USB this is the end a UNIT ATTENTION already makes: the engine is
the issuing process, the reference is the BOT function's own, and the
medium becomes ready again only through commands queued behind the
step ([design-usb.md](design-usb.md#media-and-drives)), which wait for
the engine's next poll of the unit, so a held ask on USB is answered
`{error, no_medium}` and the next walk finds the medium; it may come
back as another free drive, as a stick put back may. On a block device the
issuing process is `erx_blk`'s device process, and the medium reference
is the one thing a drive adds to it: USB's rule, so that both transports
share one handoff.

So an earlier mount's requests are answered, or refused unissued, before
a new mount sends its first, and no medium is mounted twice at once, by
the order of the one issuing process rather than by a record of what was
mounted; a fixed drive, such as a second virtio disk, mounts again after
any restart with nothing taken out, at the walk that asked or the next.
An eject a restart cuts short never
answers `ok`: its answer comes only from the drive process after every
finish, and that drive process has ended, so the writer of `eject` gets
`eio`; a finish whose flush was refused `gone` leaves its FAT volume
`ro dirty` at the next mount.

### How the grant reaches the media domain

A drive's grant is a process of its **serving domain**, the configured
domain whose units hold the drive's device: the USB domain, or a block
drive's holder. The media domain is another domain, and a process
reaches a process of another domain only through a name that domain's
own runtime handed out: the system domain cannot hand the media domain
a pid of the USB domain's, since a pid it encodes is not its own and
exports nothing ([design-domains.md](design-domains.md#exports)). So
the grant needs the route every service of a configured domain already
takes to its grantees, and the construction is that **a drive window
row is a grant, and every request of its grantee passes the grant's
admission**:

```text
 manifest:       window diskN, role drive, device D, holder media
                   |  the domain service reads it as a grant of `drive`
                   v
 system domain:  grant record: grantee media, service drive, installed as {drive, N}
                   introduce -> mint -> install
                   |
 serving domain:   drive mint ---> facet for the media domain, one operation: window
                                     |  at each window: ends its proxy, starts the next
                                     v
                                   window proxy ---- window ----> drive grant (occupied as above)
                                     |  read, write, flush, info:
                                     |  admitted, charged to the facet's account
                                     v
                                   the medium's window
                   |
 media domain:   registry {drive, N} = the facet;  {ok, Proxy}, exported to it alone
```

1. **The row is the grant.** The domain service reads each window row
   of the `drive` role as one grant
   ([design-system.md](design-system.md#facets-a-configured-domain-serves),
   "A drive window as a grant"): of the interface `drive`, from the
   serving domain to the row's holder, the media domain, installed in
   the media domain's registry under the name `{drive, N}`, N the row's
   drive number, taken from the manifest and never from a report. The
   grant's record keeps the two names apart: its **service** is
   `drive`, the name the serving domain's ready report gives a mint for
   and the mint request carries, and its **installed name** is
   `{drive, N}`, which keys the record beside its grantee and names the
   facet in the media domain's registry, so the several drives of one
   serving domain are separate records that one mint serves
   ([design-system.md](design-system.md#facets-a-configured-domain-serves),
   "One operation per grant"). No service or facet row names the grant,
   as no row names a session's lines: the window row already says which
   device serves the drive, and so which domain, and who holds it, and a
   second row would be a copy that has to agree with it. The grant's
   record moves through the states every configured domain's grant
   does: the two domains are introduced, the serving domain's mint is
   asked for a facet, the facet is installed, and the record starts
   again for each new incarnation of either domain, under the same
   deadline and with the same `failed` state.
2. **The facet asks for the window and nothing else.** The serving
   domain names one mint for `drive`, `erx_blk_drive:start_mint/1`,
   before it reports ready. The USB domain's places start it as a child
   after their drive grants; a block drive's holder starts it in
   `erx_blk_sup` before the device process, so it outlives a restart of
   the driver, since a mint's end ends its domain
   ([design-system.md](design-system.md#facets-a-configured-domain-serves),
   "Providers"). A mint request carries the drive's number in its
   limits, `drive => N`, beside the interface's one operation, `window`,
   as the operations the grant lists, and the five quantities
   `abi/services/drive.txt` declares for every grant of `drive`, as a
   session line's interface declares its own
   ([design-system.md](design-system.md#a-sessions-lines)):
   * `max_request`, 65,536: the smallest power of two not below the
     largest request the proxy takes, a `write` of a USB transport's
     `max_sectors`, 32 KiB, in its call's envelope, with its caller's
     pid and alias of a 255-character node name;
   * `in_flight`, 8, `media_volumes_max`: one for each volume of a
     medium, each of which sends one request at a time
     ([Volumes](#volumes)), so the media domain's own volumes never meet
     `busy`; the facet's own `window` asks never come near it, since
     each ends the proxy of the one before;
   * `reductions`, 1,000,000, and `period_ns`, one second: the share of
     the serving domain's grant that the media domain's requests may
     spend, sized for a medium read at full speed and to be measured
     ([todo-performance.md](todo-performance.md));
   * `max_heap_size`, 131,072 words, 1 MiB on a 64-bit runtime: room for
     `in_flight` requests of `max_request` and the binaries of their
     replies, with the process's own state. The facet and its proxy each
     run with it.

   The mint refuses a number its domain's own drive records do not name
   ([design-fiasco.md](design-fiasco.md#drive-records)), which leaves
   the grant `failed`, and otherwise starts a facet, an `erx_facet`
   bound to the media domain and ending with its connection, whose
   callback is `erx_blk_drive_facet` and whose interface lists one
   operation, `window`. At each `window` the facet ends the proxy it
   has, if any, finds the drive's grant as it is at that ask, among the
   places' grants for a USB drive, from the device process for a block
   drive, starts a **window proxy** for it, `erx_blk_drive_proxy`, and
   forwards the ask to the proxy. While the drive has no grant, as while
   a block driver is stopped, the facet answers `{error, no_medium}`
   itself and starts nothing. It never holds a grant's pid between
   asks, so a block driver's restart, which starts a fresh grant,
   changes nothing for the facet. Every other request the behaviour
   refuses before the callback sees it
   ([design-domains.md](design-domains.md#facets)).
3. **The proxy carries the window's requests across.** The proxy is a
   process of the serving domain that acts for the media domain alone,
   as every process a facet starts does
   ([design-domains.md](design-domains.md#facets), "Processes a facet
   starts"). It asks the grant for the window. On `{ok, Window}` it
   monitors the window and answers `{ok, Proxy}`, its own pid, which the
   facet's reply carries to the media domain, so the serving domain's
   runtime exports it toward the media domain with `send` alone, and
   toward no other domain; on any other answer it passes that answer
   on and ends, and if the grant ends before it answers, the proxy ends
   too, which the facet answers `{error, failed}`, as it answers any
   forward whose service ended. From then the proxy takes the window's
   requests, `{read, Sector, Count}`, `{write, Sector, Bytes}`, `flush`
   and `info` ([design-storage.md](design-storage.md#data-model)), and
   admits each through the admission path the facet runs: the request's
   origin is the media domain, its caller's pid and alias are the media
   domain's, and its size is within `max_request`, or it is dropped and
   counted, unanswered; a call that names none of the four is answered
   `{error, einval}`, as the window answers one; and one past `in_flight`
   requests forwarded and unanswered is answered `{error, busy}`. The
   proxy forwards each admitted request as it takes it to its window,
   the one the grant answered it, and to no other, and passes the
   window's answer to its caller; so a proxy that outlives its turn
   reaches only a window the grant has ended or is ending. It charges the facet's
   account with the reductions of each of its steps and, while the share
   is spent, pauses until the period turns, as every process a facet
   starts does. It ends when its window ends, when the facet ends, which
   it monitors, or when it passes its `max_heap_size`, with off-heap
   binaries counted; its end ends nothing of the window or the medium.

What follows from the construction:

* **The holder reaches only `window` and the window's requests.** The
  media domain holds the facet's pid and its proxies', never the
  grant's or a window's. The grant and the windows are servers of their
  own domain alone, started without `{erx_serve, any}`, so a call that
  reached either from another domain would arrive in its envelope and
  be dropped as an unknown message. `occupy/2` and `serve/3` are calls
  of the serving domain's own processes, and a holder cannot keep media
  off its drives by serving its own pid.
* **What the media domain can make the serving domain spend is the
  grant's.** Every request of the media domain's reaches the serving
  domain at a facet or a proxy, under the grant's admission, and
  nothing else of that domain takes one. For each drive, the memory it
  can make the serving domain hold is the facet's and its one proxy's
  `max_heap_size`, the frames queued on them counted, and the window's
  queue, which holds at most the proxy's `in_flight` requests; the work
  of the facet and the proxy is charged to the facet's account. What
  the window and the transport do for a request, a place check and one
  transport request of at most `max_sectors`, is bounded per request
  and done one request at a time, and each request costs the proxy's
  account the reductions of taking and forwarding it, so the share
  bounds how many reach them in a period. A media domain that sends past
  its limits slows or ends only its own proxy, and with it its own
  mounts of that medium, which its next walk mounts afresh.
* **Restarts need nothing new.** A restarted media domain is a new
  incarnation, for which the record mints a new facet. Its first ask
  reaches the grant that answered the old incarnation, so the grant
  ends the medium's block service first ([A drive and its
  medium](#a-drive-and-its-medium)). The old incarnation's facet ended
  with its connection, and its proxy with the facet, and that proxy
  reaches only the old window, so whatever of the old mount it forwards
  the medium reference answers or refuses. A
  restarted serving domain starts fresh grants and a fresh mint, its old
  windows and proxies having ended with it; the record mints its
  facets again for the media domain at its ready report. A restarted
  drive process in a running media domain asks through the facet its
  domain already holds, which ends the proxy it had started for the
  drive process's predecessor before it starts the next.
* **The media domain's drives are its registry's.** The media domain
  learns of no drive any other way: it gets no drive record
  ([design-fiasco.md](design-fiasco.md#drive-records)), and the root of
  `/media` lists the `{drive, N}` names its registry holds at the
  request ([Paths](#paths)). A drive whose serving domain is restarting,
  or whose grant failed, is not listed until its facet is installed
  again.
* **Authority is the manifest's.** The drives are held by their window
  rows' holder, which the manifest check holds to the media domain, and
  served by the domain the manifest places their devices in. Nothing
  else grants `drive`: the manifest check refuses a service row and a
  facet row of the interface, and the domain service's facet funnel,
  which takes only the manifest's service names, refuses a spec that
  names `{drive, N}`, so the media domain hands no drive on
  ([design-domains.md](design-domains.md#facets), "The facet table").
* **What it costs.** One connection carries every drive of one serving
  domain: it takes one of the media domain's `connections`, one of the
  serving domain's and one of the machine's `max_connections`, as a
  facet row's grant does. A `window` crosses the facet once for each
  walk that finds a new medium, and starts one proxy; a sector request
  crosses once, to the proxy, and takes one local hop more, to the
  window. Its reply carries at most the transport's `max_sectors`,
  32 KiB on USB and 4 KiB on virtio, which the serving domain's and the
  media domain's `max_frame` must carry: the USB and media domains' are
  128 KiB on QEMU `virt`.

The facet and its proxy cost two processes per drive and media domain
incarnation, and one local hop per request. They buy what the grant
and the window would otherwise need code of their own for: the export
toward the media domain alone, the end with the media domain's
connection, the operation check, the request limits and the account,
each the facet behaviour's or its admission path's, so the grant and
the window stay what they are for the serving domain's own clients.

### Manifest rows

A drive is one window row: role `drive`, no partition, the drive's
number in its `drive` field, on the row of a `usb` device or of a
`block` device, the media domain as its holder, and rights
`read,write`. The packed row
carries `mf_none` in its `partition` field, since the window covers
whatever medium the drive holds, whole, and every window of another role
carries `mf_none` in its `drive` field. The media domain is the
configured domain that serves the service named `media`; the manifest
names it no other way.

A drive's rights are always `read,write`, because nothing would read a
narrower right from the row: which sessions may write a drive is the
rights of their `media` facet rows (DR-R8), and whether a volume is
written is the writable rule's ([The writable rule](#the-writable-rule)).
A read-only drive, a medium that the media domain itself may not write,
has no consumer, so a row with rights `read` is refused rather than
accepted and served writable
([Open decisions](#open-decisions)).

What the media domain and a block device's drive holder may hold is an
allow-list, as for the domain `pcie` (the check of
[design-fiasco.md](design-fiasco.md#the-phase-1-manifest-check)): every row of the
manifest that names the domain must be one the list admits, so a table
the manifest gains later names it only once its list admits it.

* **The media domain's list:** its drive windows; the one service it
  serves, `media`, and the service of its durability facet
  ([Finishing a volume](#finishing-a-volume)); its facets of the system
  domain's service `log` ([design-log.md](design-log.md#the-log-facet));
  and its place in the
  boot order. It holds no unit and no other window, and no facet of any
  other service, the system domain's `start` and `machine` trees and
  every storage domain's tree among them. Its drives' grants are its
  drive windows themselves, each a grant of the interface `drive`
  ([How the grant reaches the media domain](#how-the-grant-reaches-the-media-domain)),
  never a service or facet row.
* **A block drive holder's list:** the one unit that places the drive's
  device and no other device; the one driver-control service it serves
  the system domain, as every unit's holder does
  ([design-system.md](design-system.md#the-holders-driver-control-facet)),
  whose facets only the system domain holds; its `pci` facet, of the
  system domain's service `pci` ([design-pcie.md](design-pcie.md#facets)),
  which the manifest check admits exactly when the holder's units hold a
  PCIe function, so only when the drive's device is one, as an NVMe or a
  virtio-blk-pci drive's is; its facets of the system domain's `log`;
  and its place in the boot order. It also serves its drive's grant,
  which the drive's window row makes, and no row of its own. It is a
  configured domain, and it
  holds no window and serves no other service, so the domain that
  drives the device parses nothing a medium holds and nothing else of
  the machine sits with the device
  ([A drive and its medium](#a-drive-and-its-medium)).

The manifest check refuses:

* a `drive` window with a partition, without a drive number, or with
  rights other than `read,write`; a drive number on a window of another
  role;
* a drive number named twice;
* a `block` device with a `drive` window and any other window;
* a drive window held by a domain other than the media domain, or two
  domains holding drive windows;
* a `media` service served by the system domain, and a row naming the
  media domain that its list does not admit;
* a drive's device held by the system domain, whose boot carries no
  drive record, and a row naming a block drive's holder that the
  holder's list does not admit;
* more drives on one USB domain's controllers than `usb_drives_max`;
* a `media` facet row with rights `rx`;
* a `service` row or a `facet` row of the interface `drive`, whose only
  grants are the drive windows.

The media domain's row allows it no sub-spaces (`spaces none`), since
FAT and EROFS run in its own processes; a row that serves littlefs
volumes allows the sub-spaces of their ports. The row serves the one service `media`, and gives the system domain its
durability facet ([Finishing a volume](#finishing-a-volume)). The
release check refuses a release other than the media domain's that names
`erx_media`; a media domain's release that names `erx_storage`, whose
`erx_littlefs` loads the NIF, or `erx_blk`, the block driver; and, in a
release build, a media domain's release that names `erx_lfs` or carries
the littlefs port. FAT's read core, `erx_fat_read`, lies in `erx_fat`,
the FAT server's application, a library application with no `mod` that
depends on neither, so the media domain's release and the storage
domain's both name it and `erx_media` depends on it, never on
`erx_storage`.

## Reading a medium

### The table

`erx_media_table:read(Capacity, Sectors)` is pure: it names the sectors
it needs, sector 0, then a GPT's headers and arrays, and the reader
process reads them through the window and hands them back. Its answer is
`{Scheme, Volumes}`, the scheme `mbr`, `gpt` or `none` and each volume's
number, first sector and length, with the entries it serves not, or
`{refused, Finding}`. Every field is read by binary matching on a
sector of exactly 512 bytes, and every sum is an Erlang integer, so no
crafted field wraps.

1. **A GPT**, when sector 0 ends in `0x55 0xAA` and any of its four
   entries has type `0xEE`, whatever its status bytes and other fields
   hold, as FreeBSD's GPT probe tests (`g_part_gpt.c:899-905`). Such a
   medium is read as a GPT or its table is refused: no later rule reads
   it, so neither its MBR entries nor the medium as one volume is ever
   served from it. It has two copies, each a header and its entry array.
   The primary header is read at sector 1, and the backup header at the
   sector the primary names as its alternate when the primary's header
   passed, and at the medium's last sector otherwise. A header passes
   when it begins with `EFI PART`, its size is 92 to 512 bytes, its
   CRC-32 over that size with its own field zeroed checks, its revision
   is at least FreeBSD's `GPT_HDR_REVISION`, it names the sector it was
   read from as its own and another sector inside the medium as its
   alternate, its usable area's first sector is at least 2 and at most
   its last, which lies before the medium's last sector, as FreeBSD
   bounds it (`:500-504`), and its entry array holds at least one entry,
   of at least 128 bytes and a multiple of 8, is at most 16 KiB, room
   for 128 entries of 128 bytes, starts at sector 2 or later, ends
   before the medium's last sector, and has neither its first nor its
   last sector inside the usable area, as FreeBSD places it
   (`:513-524`), so a copy whose array lies in its own usable area
   fails and the other copy is tried; an array
   passes when its CRC-32 checks. The primary copy is taken when its
   header and its array pass, and the backup otherwise; when neither
   passes, the table is refused, naming the primary's finding. Neither
   copy is ever written. An entry whose type GUID is all zero is unused;
   each other entry is volume N, N its index from 1, with its name, 36
   UTF-16 code units, and its unique GUID kept for the `status` file.
2. **A GPT's metadata.** The taken copy's usable area must lie apart
   from every sector the reader knows the GPT to occupy: sector 0, both
   headers' sectors, the taken copy's array and, when the other copy's
   header passed, its array. Each array is compared as a range, so an
   array that encloses the usable area is caught, which an array's ends
   alone would miss. A usable area that meets any of them refuses the
   table. An array the reader could not validate is not known to it, and
   nothing is claimed of its sectors.
3. **An MBR**, otherwise, as FreeBSD's MBR probe judges one: sector 0
   ends in `0x55 0xAA` and every status byte is `0x00` or `0x80`, and
   the four entries are not all zero over a sector whose
   bytes-per-sector and sectors-per-cluster fields are plausible. A
   sector that is not one is no table.
4. **An MBR's entries**: an entry of type `0x00`, and one whose start or
   length is 0, is skipped; one of an extended type, `0x05`, `0x0F` or
   `0x85`, is listed as `extended` and not served, since no chain of
   extended boot records is followed; each other entry is volume N, N
   its place from 1 to 4.
5. **No table**: the medium is one volume, number 1, from sector 0 to
   its end, as FreeBSD mounts `da0` itself. A stick's files therefore
   lie at `s1` whether or not its maker wrote a table.
6. **Integrity**, as FreeBSD checks it by default: every entry the
   scheme lists, extended ones included, must run forward, its last
   sector at or after its first, start at or after the first usable
   sector (sector 1 for an MBR, the usable area's first for a GPT), end
   within the medium (for a GPT, within its usable area), and overlap no
   other. One that breaks it refuses the table whole, naming the
   entries. So no two volumes share a sector, whatever order the entries
   come in, no volume covers sector 0, and no GPT volume covers a header
   or a known array.
7. **A bound**: at most `media_volumes_max` volumes are served, 8, the
   first in entry order; the `status` file counts the rest as not
   served.

Volume N is the directory `sN` of its drive's tree. A sector request of
a volume, from any format, is placed by one pure function,
`erx_media_table:place/3`, which adds the volume's first sector and
refuses with `erange` a request that reaches past its length, so no
format reaches a sector outside its volume.

### The probe

`erx_media_probe:format(Read, Length, Written)` runs in the volume's own
process and reads, through the volume's placement, a fixed set of the
sectors below Length, the volume's length; a failed read of any of them
fails the probe, since a signature it could not read is not known to be
absent. It
answers the first format in the order below whose signature it finds,
which **selects** the volume's format, and, of the other formats the
build writes, those whose signature it also finds, for the writable
rule. The order is `fstyp`'s, the header at the largest
offset first, with erXos's formats placed by where their headers lie:

| Order | Name | Served | Signature, from |
| --- | --- | --- | --- |
| 1 | `ufs` | no | UFS1 or UFS2 magic in a superblock at 65,536, 8,192, 0 or 262,144 bytes (`sys/ufs/ffs/fs.h:68-76`, `:457-458`) |
| 2 | `cd9660` | no | the volume descriptor's `CD001` at 32,768 bytes (`fstyp/cd9660.c:38-50`) |
| 3 | `hfs+` | no | `H+` or `HX` at 1,024 bytes (`fstyp/hfsplus.c:42`, `:106-112`) |
| 4 | `ext2fs` | no | the ext2 magic in the superblock at 1,024 bytes (`fstyp/ext2fs.c:39-63`) |
| 5 | `f2fs` | when it joins | F2FS's magic at 1,024 bytes (`abi/formats/f2fs.txt`) |
| 6 | `erofs` | yes | EROFS's magic at 1,024 bytes (`abi/formats/erofs.txt`) |
| 7 | `littlefs` | in development builds and test images | `littlefs` at byte 8 of block 0 or of block 1, 4 KiB blocks, where littlefs's specification puts the superblock's name (`SPEC.md:444-447`) |
| 8 | `apfs` | no | `NXSB` in the container superblock at byte 0 (`fstyp/apfs.c:77-93`) |
| 9 | `exfat` | no | `EXFAT   ` as the boot sector's file-system name (`fstyp/exfat.c:333`) |
| 10 | `msdosfs` | FAT16 and FAT32 | `fstyp`'s FAT test (`fstyp/msdosfs.c:48-115`), and the FAT type from the volume's count of clusters |
| 11 | `ntfs` | no | `NTFS    ` as the boot sector's system id (`fstyp/ntfs.c:146-147`) |

The signatures, each with its offset, bytes and source, are the rows of
one checked-in table, `abi/formats/probe.txt`, from which the build
generates the probe's constants. FAT's row is code, since it reads
fields, not one string: the FAT server's boot-sector decoder, which
gives the probe both the test and the type, so the type has one source.
A FAT12 volume is refused by name there: `sN msdosfs`, `sN_fat 12`,
`sN_mount none format`, since FAT12's entries of a byte and a half
would need a decoder and a write rule of their own. littlefs's row is
the specification's statement, which the host tests check on volumes
formatted, modified, compacted and cut mid-commit
([Host tests](#host-tests)); littlefs's own mount, in its port, stays
the test of whether a volume is one. A volume where none matches is
`unknown`. A volume too short for a signature's sector simply lacks
that signature.

The selected format is the volume's only reading. A volume whose
selected format is not served is refused by that name, as FreeBSD's
automounter refuses a format it has no program for: `s1 exfat`,
`s1_mount none format`. A volume whose selected format fails its mount
is `none failed`, and nothing falls through to another format: a
format that fails its own checks says the bytes are not what its header
claims, and reading them as the next format is the misreading DR-R5
forbids.

## Volumes

Each volume has one process, `erx_media_volume`, a temporary child of
its medium's supervisor, under the memory bound of
[Time and memory](#time-and-memory). It probes its volume, then holds
its format's state and runs its format's operations one at a time, in
the order they arrive: the FAT server's state, the EROFS reader's mount
and cache, or littlefs's owner and its port. Its process is the
volume's mount: the mount is made when it starts, and ends when it ends.

| Format | Module | Writes | Served by |
| --- | --- | --- | --- |
| `msdosfs` | `erx_fat`, the FAT server ([design-storage.md](design-storage.md#removable-media-fat)) | FAT16 and FAT32 | every build |
| `erofs` | `erx_media_erofs` over the EROFS decoder ([EROFS, unauthenticated](#erofs-unauthenticated)) | never | every build |
| `littlefs` | `erx_lfs`'s owner over the littlefs port ([littlefs, through its port](#littlefs-through-its-port)) | yes | development builds and test images |

### The writable rule

A volume mounts **writable** exactly when all of these hold, and
otherwise **read-only**, naming in its `status` line the first that
does not:

1. its format is one erXos writes on a drive (`format`): FAT16, FAT32 or
   littlefs, not EROFS;
2. the probe found on it no signature of another format the build
   writes (`also NAME`), since a medium formatted twice may keep the
   first format's header, and writing the wrong one destroys the other's
   files. The formats the build writes are the format table's rows that
   write: in a release, FAT alone, so the condition never holds and no
   `also` is shown; in a development build, FAT and littlefs, so a FAT
   volume that kept an old littlefs superblock is read as littlefs and
   written as neither;
3. its mount's one flush, sent before anything is written, answered `ok`
   (`flush` when it answered `enotsup`, a medium that cannot flush);
4. its format's own state allows it: a FAT volume's dirty flag is clear
   (`dirty`).

A flush that answers anything else, `eio` or the window's end, **refuses**
the mount, with nothing written: the volume shows `none flush` with the
answer, and every request on it answers `eio`. A refusal is not a
read-only mount, since a flush that fails says that this flush failed,
not that the medium cannot flush, and a read-only mount would show a
failing medium as a working one. Each outcome holds for the mount, and
the medium's next mount, when it is put back, tries again. A grant whose rights are not `rw` refuses every write
before it reaches a volume, whatever the rule decides (F5 of
[design-files.md](design-files.md#invariants)).

### FAT

The FAT server serves one FAT16 or FAT32 volume as the storage design
defines FAT's names, attributes, durability and bounds
([design-storage.md](design-storage.md#removable-media-fat)), with sector reads,
writes and flushes through its volume's placement. Its mount decodes the
boot sector with the decoder the probe used, and shows the type as
`sN_fat`, `16` or `32`. The volume label, from the boot sector or the
root directory's label entry, and the volume serial number are shown as
`sN_label` and `sN_serial`, so a script finds one stick again by them
whatever drive it lands in.

### EROFS, unauthenticated

A drive's EROFS volume is a stranger's image: no hash tree the boot
image pins covers it, and a root hash the medium carries would
authenticate nothing. The media domain reads it unauthenticated, through
the shared decoder and a frontend and block source of its own:

* **The decoder.** `erx_erofs` decodes an image from blocks it reads
  through its mount's source, a function from a block range to the
  blocks or `{error, eio}`, and checks every field it reads, as the
  storage design states. `erx_erofs:mount_source/2` mounts over such a
  function. `erx_erofs:mount/2`, E1's entry, takes only an
  `erx_verity` handle and mounts over that handle's reads; it is the
  decoder's one caller in the system's runtimes.
* **The source.** `erx_media_blocks`, a module of `erx_media`, reads an
  image's 4 KiB blocks, eight sectors each from the volume's start,
  through the volume's placement, with the per-call bound and the
  answer handling of the hash-checking reader and no hash.
* **The frontend.** `erx_media_erofs`, the volume module, mounts the
  volume with `erx_erofs:mount_source/2` over `erx_media_blocks` and
  serves it from its root with the same `erx_fs` callbacks over the
  decoder that serve the `system` tree, one module, `erx_erofs_tree`,
  rooted at `apps/` for the `system` tree and at the image's root for a
  volume. Its reads run in the volume's process, not the client's grant,
  so a structure the decoder cannot decode fails that operation, and
  anything worse ends that volume.
* **The separation.** Two facts keep a drive's bytes from the system's
  runtimes. Placement: the source and the frontend lie in `erx_media`,
  which no release but the media domain's holds (the release check,
  [Manifest rows](#manifest-rows)), and the media domain holds no window
  of the boot medium, so its source never reads a system partition
  (PW1). Calls: only `erx_erofs:mount/2` and `erx_media_erofs` call
  `mount_source/2`, by name, as a function reference or through `apply`
  with literal names, and `mount/2` builds its source only over
  `erx_verity:read/3`: a chokepoint check, since Erlang has no visibility
  between modules short of export. It binds the tree's code at build
  time, not a domain's own code at run time, which E1 leaves to harm
  only that domain; so in the system domain, the
  storage domain that serves `system` and every session that mounts a
  package, every block the decoder reads came through `erx_verity`,
  whose every handle has a tree.

Every structure the decoder reads is checked as the storage design
states, an offset, a size or an inode number outside the image failing
the operation with `eio`; on a drive those checks are the defence they
were written to be, and the reader's fuzz target is the test of it.
**Uncompressed images only.** What the decoder implements is what fsimg
writes: 4 KiB blocks, no incompatible feature, compact and extended
inodes, the plain and inline layouts, no compression. A drive's EROFS
volume is served when it is made that way, an image Linux's
`mkfs.erofs` writes included; whether its default options make one is
unverified, and a black-box run in the Linux oracle guest settles it
([Verification](#verification)). Everything else is refused by name,
and never read as something else:

* **compression**: a superblock that declares a compression feature,
  one of the bits `abi/formats/erofs.txt` names from `erofs_fs.h` as
  compression's, fails the mount with `erofs: compressed images are not
  supported` in `sN_mount`; a compressed inode in an image that declares
  none answers `enotsup` when it is reached, its diagnostic saying the
  same;
* **any other incompatible feature**, another block size, or extended
  superblock slots fail the mount with the bits or the size named, as
  the reader names them now;
* **a chunked inode** answers `enotsup` when it is reached.

Decompression is not part of this design: LZ4, and LZMA, DEFLATE and
Zstandard, the other algorithms EROFS defines, are a later item in
[todo-storage.md](todo-storage.md). LZ4 is also the decompressor the
storage design names for the slots' system images should the media
lack room ([design-storage.md](design-storage.md#data-model)), so one
primitive would serve both; on a drive it would parse a stranger's
compressed bytes in C in the media domain's runtime, where a defect in
it reaches every drive's volumes, which its design must weigh.

The image's label and UUID, from its superblock, are shown as
`sN_label` and `sN_serial`. A drive's EROFS tree serves its links as
links; the resolver does not follow them ([Links and
rights](#links-and-rights)).

### littlefs, through its port

littlefs volumes are served by development builds and test images, so
the drives' tests can mount littlefs sticks; no release serves them, and
a release's probe names a littlefs volume and refuses it as not served
([design-stopgap.md](design-stopgap.md#littlefs-on-a-drive)). littlefs
is C, so where it is served it runs only in its target placement, the
**port**: a sub-space of the media domain for each littlefs volume,
holding its channel and its data area and nothing else, with the shape
of a program and a budget of its own
([design-storage.md](design-storage.md#read-write-storage),
"littlefs, the stopgap"; [design-programs.md](design-programs.md#a-program-is-a-port);
[Time and memory](#time-and-memory)). The volume process is the port's
owner, `erx_lfs`: it sends the volume's operations on the channel and
serves the port's block requests itself, checking each against two
things the volume holds:

* **its sectors**: a request is placed in the volume, and one that
  reaches past it is refused with an error answer;
* **its right to be written**: a program or an erase is answered only
  while the owner carries out an operation that may change the volume,
  a write, a create, a remove, a rename, a sync or the finish, on a
  volume the writable rule admitted. During the mount and every other
  operation, on a read-only volume, and after the finish, each is
  refused with an error answer, which littlefs takes as an I/O error. So
  looking at a littlefs volume writes nothing, whatever its port asks,
  and a port whose code a crafted volume has taken over writes only
  inside an operation a client asked for, and only on its own volume. A
  littlefs whose mount wrote would fail every mount; whether the tree's
  littlefs mount writes is unverified, and the owner's host test over it
  settles that.

So:

* a crash, a littlefs assertion or the port's exit ends the port, which
  the owner sees as `{exit_status, N}` and ends with it: the volume is
  `none failed`, its requests answer `eio`, and nothing else ends; a port
  that stops answering is ended at its owner's deadline, the same way;
* a memory error that a crafted volume steers reaches the port's
  sub-space, its channel, and through its owner's checks the sectors of
  its own volume, as far as the volume may be written, and the answers
  to its own volume's requests, which the owner decodes as untrusted
  input; it reaches no window, no other volume, no device and no runtime;
* the port ends with its volume's process, which ends with the medium,
  so no littlefs code that read one medium runs when the next arrives.

The port is built with `erx_lfs_config`, the geometry of the data
partition's volumes and of the fuzz targets: 4 KiB blocks, 512-byte
reads and programs, and a block count equal to the volume's length in
blocks. A volume of another geometry fails its mount with littlefs's
own check, shown as `geometry` in `sN_mount`, so no geometry is taken
from the medium at run time and the fuzz targets cover exactly what
mounts. littlefs volumes are read-write: littlefs's copy-on-write
commits leave a removed stick at its last commit, as a power cut does,
which FAT's batches only approach. No drive volume reaches the NIF
form: the media domain's release holds no `erx_littlefs`
([Manifest rows](#manifest-rows)).

### F2FS, when it joins

erXos's F2FS joins as the format table's `f2fs` row once its read path,
the walk, node, directory and replay steps with their fuzz targets, is
built ([design-f2fs.md](design-f2fs.md)). Until then the probe names it
and refuses it. Joining takes:

* **A volume module** that runs F2FS's volume process as the volume's
  process: a volume that fails ends its mount alone, where on the data
  partition it ends the storage domain;
* **read-only first**, with the in-memory replay of a read-only mount
  (F2-R5), and read-write once F2-R1 to F2-R3 hold, under the writable
  rule, since F2FS was made for flash media and the rule is the only
  gate;
* **its mount allowance** taken from `media_volume_bytes`, so a volume
  larger than the allowance admits answers `enomem`, refused by name;
* **qid paths drawn per mount**, as FAT's and littlefs's are, since its
  own 64-bit path does not fit beside the mount's number
  ([Identity](#identity));
* **a finish**, its checkpoint, as every writable format has
  ([Finishing a volume](#finishing-a-volume));
* the clean room's legal review before any distribution, as for the
  data partition.

### Finishing a volume

A volume is closed while its medium stays only by **finish**, a request
of its process that is its last. The process answers every request it
holds or was sent before it, as it answers any; then, for a writable
volume, it writes what it has not yet written, FAT's last batch with its
dirty flag cleared or every open littlefs file synced, and has the
window flush. From then the volume is closed: every later request on it
answers `eio` without reaching its format, and a littlefs owner refuses
its port's programs and erases. The finish answers `ok`, or the first
failure of its writes or its flush. Every request reaches a volume only
through its process, which takes them one at a time, so the finish is
the volume's one admission barrier: a write answered before it is in
what its flush made durable, and none is answered after it.

Two things finish volumes:

* **Eject**, written to a drive's `ctl`: the drive process, which takes
  the drive's requests one at a time, sends every volume of the medium
  its finish at once and waits for each answer, walks of the drive
  waiting behind it; then it ends the medium's supervisor and shows the
  medium `idle ejected`.
  The write answers `ok` when every finish answered `ok`, `eio` when one
  did not or its volume had already ended, the medium being ended
  either way, and `enxio` when the drive holds no mounted medium, as a
  second `eject` then finds. The drive process mounts an ejected medium
  again only once it has ended: taking the stick out and putting it back
  makes a new one, and a fixed drive's medium stays idle until the media
  domain or its driver's domain restarts. A restart of the drive process
  forgets an eject, and the medium mounts again at the next walk. The word promises what macOS's and FreeBSD's ejects
  promise of a stick, that it may be pulled without loss; nothing moves,
  since no command of the SCSI subset ejects a medium
  ([design-usb.md](design-usb.md#the-scsi-subset)).
* **The ordered end.** The media service takes the freezing checkpoint
  on its durability facet, which only the system domain holds, as the
  storage services do ([design-storage.md](design-storage.md#interfaces)):
  `erx_fs` closes mutation admission at every `media` grant and lets
  each finish the writes it admitted
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
  "Freezing"); the media tree then finishes every mounted volume of
  every drive at once and answers when all have; and every later write
  answers `erofs`. It offers no checkpoint without a freeze, which only
  the vault uses. The ordered end's deadline, and its record of each
  outcome, are the coordinator's
  ([design-system.md](design-system.md#shutting-down)); a medium that
  cannot finish within them loses what its volumes had not written, as
  on a power cut, and its FAT volumes show `dirty` at their next mount.
  A trial reads no drive, so the media service's outcome is recorded
  and logged and does not decide between a trial and a reset.

### Time and memory

* **Memory.** Each volume's process, and the medium's reader, runs with
  a `max_heap_size` whose `size` is `media_volume_bytes` in words, with
  `kill` and `include_shared_binaries` set, so a volume whose heap,
  stack and the binaries it holds pass that at a garbage collection is
  ended alone (`erlang.erl:8120-8165`, `process_flag(max_heap_size,
  ...)`). A littlefs port's budget is a wall of `media_volume_bytes`
  carved from the media domain's, so the port draws on nothing the
  runtime was promised, and a carve the domain cannot promise fails that
  mount with `enomem`. Neither bounds all a volume makes the runtime
  hold: a heap is checked only at its collections, so it may pass the
  bound between them, and the decoder's block cache, which lives in ETS,
  and the queues between processes are outside every heap. Volumes that
  together exhaust the media domain's memory therefore end the media
  domain, and with it every drive's mounts, until the domain service
  restarts it; that is the one way a crafted volume reaches past its
  own mount, and it fails with a restart, never with a write.
* **Time.** Every operation of an Erlang format does bounded work: each
  loop is bounded by the size of the structure it walks, as the FAT
  server's and the EROFS reader's designs state, and each of its sector
  requests by the window's deadline, 35 s
  ([design-storage.md](design-storage.md#data-model)). littlefs's port
  is C and may spin without asking for a sector, so its owner keeps the
  deadline the storage design gives it, 60 s (`DEADLINE_MS` in
  `erx_lfs.erl`), and ends a port that misses it: the volume is
  `failed timeout`. Until then the port runs in its own group, under
  the media domain's sub-space group, and shares the domain's CPU with
  its runtime and its other volumes. The tree's requests to a volume
  carry no timer of their own: they end when the volume answers or
  ends.

## The media tree

### Paths

The media domain serves the files service `media`, whose grants each
session the manifest grants it mounts at `/media`:

```text
/media/
  disk0/          one directory for each drive the media domain holds
    status        what the drive holds (read)
    ctl           commands (write)
    s1/           volume 1's files, while its medium is mounted
    s2/ ...
  disk1/
```

The root lists every drive whose grant the media domain's registry holds
at the request, `{drive, N}` as `diskN`, whether or not it holds a
medium, so `ls /media` shows the machine's drives, but for one whose
serving domain is restarting or whose grant failed
([How the grant reaches the media domain](#how-the-grant-reaches-the-media-domain)).
A walk of `diskN`
asks the drive process for the drive's medium; when the drive's grant
answers a window, the drive process starts that medium's supervisor and
waits for the reader to have read the table and started the volume
processes, so the listing that follows names every volume. With no
medium, or while the medium is idle, `diskN` holds `status` and `ctl`
alone. Walking into `sN` waits for that volume's probe and mount, and
reaches its root while it is mounted; a volume whose outcome is `none`
answers `eio` there and shows why in `status`.

Every request on a volume's node goes to its volume process. Reads and
writes are waiting requests whose keeper is the volume process
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests"), so a slow medium delays only requests on it; the
other operations, walks, attributes, listings, creates and renames, are
calls the grant waits for as a local file system's grant waits for its
disk, within the volume's bounds ([Time and memory](#time-and-memory)),
so a slow medium delays the other requests of that session's `media`
grant for that long. A call to a volume process that has ended answers
`eio` at once.

### Status

`status` is one attribute a line, `NAME <tab> VALUE`, in the form an
app's `status` file takes, with each value through the field escape
([design-app-trees.md](design-app-trees.md#a-status-line)), so one
parser reads both:

| Name | Value |
| --- | --- |
| `medium` | `none`, no medium; `ready`, its volumes served; or `idle REASON`, present and not served: `ejected`, `table` when the table was refused, or `failed` with why its reading ended |
| `transport`, `sectors`, `flush` | the transport's name, the medium's capacity, and `yes` or `no` |
| `table` | `mbr`, `gpt`, `none` or `refused FINDING` |
| `sN` | volume N's format, a name of the probe's table or `unknown`; `extended` for an MBR's extended entry |
| `sN_mount` | one of three outcomes: `rw`; `ro REASON`, the writable rule's `format`, `also NAME`, `flush` or `dirty`; or `none REASON`, no files: `format` for a format not served, FAT12 among them, `unknown`, `extended`, `flush` with the flush's answer, or `failed` with why the volume ended |
| `sN_sectors` | its length |
| `sN_fat` | FAT's type, `12`, `16` or `32` |
| `sN_label`, `sN_serial` | the volume's label and serial number, or a GPT entry's name and unique GUID, as the medium gives them |
| `unserved` | how many volumes past `media_volumes_max` the table lists |

A value the medium supplies, a label, a name or a GUID, is text from an
untrusted source and is escaped as any such text is
([CLAUDE.md](../CLAUDE.md), "Text from untrusted sources").

### Commands

A write to `ctl` is one command, as the `ctl` of an app's tree takes
one ([design-app-trees.md](design-app-trees.md#commanding-ctl)). The one
command is `eject`, compared as bytes, its trailing newline optional,
which finishes the drive's medium
([Finishing a volume](#finishing-a-volume)); any other answers
`einval`.

### Identity

A file's qid path is its volume's mount number, drawn from the media
domain's counter at each mount, in its high 24 bits, and the path its
format gives it within the volume in its low 40: EROFS's inode number,
bounded by the image's length, and FAT's and littlefs's paths drawn per
mount as the storage design draws them
([design-storage.md](design-storage.md#read-write-storage), "File
identity and version"). The root, each `diskN`, `status` and `ctl` take
fixed paths of mount number 0. So no path names two files while the
media domain lives, and a medium mounted again is another set of files.
A mount past the 24 bits' last number fails with `enfile`.

### Links and rights

The resolver follows no link that lies in the `media` tree, as it
follows none in an app's tree: where it would follow one, it answers
`eacces`, as FreeBSD's `nosymfollow` mount does, and an operation on the
link itself acts on it
([design-app-trees.md](design-app-trees.md#links)). The rule belongs to
the provider: `erx_ns` derives the mark from the provider of a facet
named `media` whenever it builds or resolves that provider, never from
an option a mount names, so it is not one of the options `place/1`
gives `media` with its mount point. Every mount of a `media` facet
therefore carries the mark, wherever it is mounted and whatever
options it names, and every bind of `/media` or of a volume under
it, and every program's table that takes its entries, keeps it. The
resolver keeps one rule, to follow no link in a tree whose provider
carries the mark
([design-files.md](design-files.md#building-binding-and-mounting)). A
drive is a stranger's bytes: a link there to `/root/.ssh/authorized_keys`
must not make a copy onto the stick write root's keys. No `media` grant
is `rx`, so nothing runs from a drive; a program on a stick is copied
off and run from where its user may run it.

The mark lies in the namespace because the namespace alone can apply it.
`abi/services` declares interfaces, and `media` is an instance of
`files`, whose other instances follow links. A mark on the manifest's
`media` service row would need a field the service row lacks and a path
that carries it to every grantee's runtime, which learns its facets by
name alone (`erx:caps/0`, `erx:granted/0`). The manifest check's entry
for the well-known service `media` is the build's and never reaches a
runtime.

The tree is one grant over many volumes, so the media tree keeps apart
what the namespace's own `exdev` rule cannot see: a rename or a link
whose two directories lie on two volumes answers `exdev`, the tree
comparing the volume each node names before it asks either volume, as
between two UNIX file systems. A create, remove or rename of an entry of
`/media` or of a drive's directory, a volume's root, `status` and `ctl`
among them, answers `eacces`.

### Mounting it

"Mount" names two acts here, as on an NFS client, whose server mounts
its disks and whose client mounts what the server exports. The media
domain **mounts a volume**: it starts the volume's file system, at the
first walk of its drive after the medium arrives. A session **mounts a
tree**: it adds an entry to its own namespace. The shell's `mount` and
`umount` are the second act alone.

`erx_ns`'s table of mount points gives `media` the point `/media`, read
at `erx_ns:mount_facets/1`, so a session granted `media` mounts it there
and a session granted none sees the release's empty, read-only `/media`
directory, as for `/data`
([design-files.md](design-files.md#building-binding-and-mounting), "A
facet's mount"). `mount` prints it as `PID:/media on /media (media)`,
whatever the drives hold, since it shows the session's entries and not
the media domain's volumes; a statfs anywhere in the tree answers the
tree's own, type `media`, whose value in `abi/protocols/9p.txt` is
`0x6964656d`, "medi", the first four bytes of its name read as a
little-endian word; what each volume is, and how large, is its
drive's `status`.

Reading `/media/disk0/status` is itself a walk of `disk0`, so looking at
a drive mounts its medium. That writes nothing: a writable FAT volume
writes nothing before its first change
([design-storage.md](design-storage.md#removable-media-fat)), and a
littlefs volume's mount is held to the same by its owner's write
admission ([littlefs, through its port](#littlefs-through-its-port)).

### Placing a volume

A session places the media tree, or any part of it, wherever it likes
in its own namespace with the shell's `mount`, and removes the entry
with `umount` ([design-shell.md](design-shell.md#interfaces)):

```text
mount /media/disk0/s1 /mnt        the volume's files also at /mnt
mount -r /media/disk0/s1 /mnt     the same, read-only through /mnt
umount /mnt                       the entry gone; nothing flushed, nothing ejected
echo eject > /media/disk0/ctl     the stick safe to pull
```

`mount SOURCE DIR` is `erx_ns:bind/2`, and `mount -r` its `bind/3` with
`[ro]`: the entry at DIR is the same `media` grant, rooted at
`disk0/s1`, so it names the place, keeps the `nofollow` mark, and
reaches whatever volume `s1` of `disk0` is at each lookup, the next
stick's after a replug. `-r` is a read-only view: writes through DIR
answer `erofs`, while the volume stays as the media domain mounted it
and other entries may still write it, which is weaker than a read-only
file system, the writable rule's alone. `umount DIR` is
`erx_ns:unmount/1`: it removes the entry, and flushes and ejects
nothing. A placement lasts as long as the session's namespace, as every
entry does.

The names are FreeBSD's and promise less than FreeBSD's: no device
argument and no `-t`, since a session never holds a medium's sectors
and the media domain names each format. A SOURCE under `/dev`, or a
`-t` option, is refused with a message naming the form that works,
`mount [-r] /media/diskN/sN DIR`; `umount` of a path that is no entry
is refused with one naming `echo eject > /media/diskN/ctl`, so the user
who meant FreeBSD's `umount` of a stick learns the step that makes it
safe to pull.

## Where each parser runs

| Parser | Runs in | A failure ends | A memory error reaches |
| --- | --- | --- | --- |
| the table (MBR, GPT) | the medium's reader, Erlang | that medium's mounts: `table refused` or `medium failed`, no volume | nothing: Erlang code writes only its own heap |
| the probe | the volume's process, Erlang | that volume | nothing |
| FAT | the volume's process, Erlang | that volume | nothing |
| EROFS | the volume's process, Erlang | that volume | nothing |
| littlefs, in development builds and test images | the volume's port, C, in its own sub-space | that volume | the port's sub-space and channel; its volume's sectors, as far as the volume may be written, and its answers, through its owner's checks; the kernel's call surface and, on Fiasco, the CPU's branch predictors, as any sub-space's code does ([design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel), FD24, FD32) |
| F2FS, when it joins | the volume's process, Erlang | that volume | nothing |

Nothing of a medium is parsed in the USB domain or a block device's
driver domain, which move sectors; the media domain's own code, which
parses nothing of a medium outside these processes, is the only code of
it whose failure the domain's restart intensity counts.

## Concurrency

* **The drive process** takes the tree's requests for its drive and its
  medium's events one at a time. It never reads a sector: it asks the
  drive's grant for the window, through the facet it reads from the
  registry at that ask, monitors the proxy the facet answers, starts
  and ends the medium's supervisor, finishes its volumes at an eject,
  and holds each volume's pid and outcome. Two sessions walking a new
  medium at once both wait for the one reading, and the second finds it
  done. Its ask waits at most the grant's 60 s; any answer but
  `{ok, Proxy}`, the facet's `{error, busy}` and `{error, failed}`
  among them, is no medium at that walk. The proxy's end is the
  medium's end for it, whether the window ended or the proxy did.
* **The drive's facet** ends its proxy and starts the next at each ask,
  so at most one ask of its grantee waits at the grant and one proxy
  serves it; an ask whose proxy ended before the grant answered is
  answered `{error, failed}`. A grant answers a held ask with the
  window it holds when the old window ends; an ask whose proxy has
  ended is answered to an alias that has ended, which delivers nothing.
  The grant takes a serve and an ask in the order they reach it, and a
  serve only from its occupant
  ([A drive and its medium](#a-drive-and-its-medium), "One occupant").
* **The window proxy** takes its grantee's requests in the order they
  arrive, forwards each it admits to the window at once and answers
  each as the window answers it, so the window, which answers one
  request at a time in order, sees the media domain's requests in the
  order the proxy took them. At most `in_flight` requests wait at the
  window; one past them is answered `{error, busy}` at once and reaches
  nothing. While the facet's share is spent, the proxy takes only its
  resume and the `'DOWN'` of its monitors, and its grantee's requests
  wait in its queue and then in the media domain's lane.
* **The medium's reader** reads the table, starts the volume processes
  and ends. Each volume process probes and mounts in its own time; a
  walk into a volume still mounting waits for it.
* **Volume processes** run concurrently and share only the proxy and
  its window, whose requests the serving domain answers one at a time in
  order. A volume's writes reach the window in the order its process
  makes them, since the proxy forwards in the order it takes; a volume
  that ends leaves its sent requests to complete or fail at the window,
  and a later mount of the medium starts only after the grant has
  restarted its block service, which answers or refuses them first.
* **A finish** reaches each volume as a request behind those it holds,
  so the volume completes what it was given first and admits nothing
  after it; a request that arrives after it, or after the medium's end,
  answers `eio`. Each volume finishes on its own, and a write to one
  volume that is still open while another has finished is answered by
  that volume's own finish, never left between two.
* **A medium's end** and a walk cross only in the drive process: the
  window's end is a message to it, and the next walk after it finds no
  medium, or the next one.
* **A restarted drive process**, after a defect of its own, has ended
  its medium's supervisor with it, since the two are linked; its next
  walk asks the grant again, which ends the medium's block service
  first and answers `{error, no_medium}` unless the next block service
  has started by the old window's end, so the medium mounts afresh, at
  that walk or the next, with no earlier request outstanding. A
  restarted media domain mounts every medium present the same way.

## Failure handling

| Failure | Detected by | What ends | What the user sees |
| --- | --- | --- | --- |
| a table refused | `erx_media_table` | nothing mounts on that medium | `medium idle table`, `table refused FINDING`; `diskN` holds `status` and `ctl` |
| a format not served, or none found | the probe | that volume is not mounted | `sN NAME`, `sN_mount none format` or `none unknown`; `eio` in `sN` |
| the selected format's mount fails: a structure check, its allowance, its geometry | the format's mount | that volume; no other format is tried | `sN_mount none failed REASON`; `eio` in `sN` |
| a mount's flush fails | the writable rule | that volume's mount, with nothing written | `sN_mount none flush eio`; out and in again to retry |
| a volume's process crashes or passes its memory bound | its supervisor's link, temporary | that volume; its requests answer `eio` | `sN_mount none failed`; the drive's other volumes go on |
| a littlefs port exits, asserts, faults, passes its budget or misses its owner's deadline | the owner's `{exit_status, N}`, its allocation's refusal, its deadline | that volume | as above, with `timeout` for the deadline |
| the medium removed, changed or failing | the window's end ([design-usb.md](design-usb.md#media-and-drives)) | the medium's supervisor: every volume and port of it | open files answer `eio`; `diskN` empty but for `status` and `ctl`; the next medium mounts at the next walk |
| a finish whose writes or flush fail | its answer | the medium, as an eject ends it | `eject` answers `eio`; FAT volumes show `dirty` at the next mount |
| a write on a trial boot | the write path (U4) | that write, `erofs` | a FAT write answers `erofs`; a littlefs volume, whose block write failed, ends |
| a FAT volume removed while written | its next mount: the dirty flag | nothing | that volume read-only, `ro dirty`, until repaired on another machine |
| the drive process ends | `erx_media_sup` | that drive's medium mounts | `eio` on its open files; the next walk mounts the medium afresh, its block service restarted first |
| the media domain ends | the domain service | every drive's mounts | `/media` answers `eio` until the restarted domain's re-grant; open files keep answering `eio`; each medium mounts afresh at its next walk |
| the serving domain ends (the USB domain, a block device's driver domain) | the proxies' end, seen as `noconnection` | that domain's drives' media, its facets and proxies with its connection | as a removal, and its drives leave the `/media` listing; the restarted domain's ready report has its drives' facets minted again, and they return, with fresh windows |
| a drive's proxy ends on its own: past its `max_heap_size`, or its facet ended | the proxy's `'DOWN'` in the drive process | that drive's medium mounts | as a removal; the next walk asks again, the grant restarts the medium's block service, and the medium mounts afresh |
| a block drive's driver stopped or restarted through its driver-control facet | the window's end, with the device process | that drive's medium mounts, and its grant | `medium none` while it is stopped, the facet answering `no_medium`; after its start the next walk mounts the medium afresh from the fresh grant's first window |
| a drive's grant fails: the mint refuses it, or the introduction, mint or installation passes its deadline | the domain service's grant record, which logs it | nothing of a medium | the drive is not listed at `/media` until either domain's next incarnation makes the record afresh |

## Refusals and error results

| Call or input | Answer | When |
| --- | --- | --- |
| a drive grant's `window` | `{error, no_medium}` | the drive holds no ready medium |
| the drive's facet's `window` | `{error, no_medium}`; `{error, busy}`; `{error, failed}` | the drive has no grant now, a block driver being stopped, or the grant answered it so; its limit in flight is reached; the grant, or the ask's proxy, ended before it answered, a later ask having ended that proxy among them |
| any other request to the drive's facet | `{error, badarg}`, or dropped unanswered | it names no operation of `drive`, before the callback sees it; it is no call of the grantee's ([design-domains.md](design-domains.md#facets)) |
| a request to a window proxy | dropped and counted, unanswered; `{error, einval}`; `{error, busy}`; paused | it is no call of the grantee's, or passes `max_request`; it names none of `read`, `write`, `flush` and `info`; `in_flight` requests wait at the window; the facet's share is spent, until the period turns |
| a request of the window's, through a proxy | the window's answers: `einval`, `erange`, `erofs`, `eio` ([design-storage.md](design-storage.md#data-model)) | as the window answers it; `eio` too when the proxy has ended |
| a mint request for `drive` | refused, the grant `failed` | it names a drive the serving domain's drive records do not name |
| a ready report that provides `drive` | refused, logged and counted | no drive window lies on the reporting domain's devices |
| a create spec that names `{drive, N}` | `{error, {bad_spec, facets}}` | always: `drive` is no manifest service's name |
| a `serve/3` to a drive grant | dropped, its window's monitor forgotten | its issuer is not the drive's occupant, or the drive has none |
| `erx_media_table:read/2` | `{refused, Finding}`: `gpt header`, `gpt array`, `gpt metadata`, `past the end`, `overlap`, `backwards`, `before the first usable sector` | the scheme's checks; each finding names the copy or the entries |
| `erx_media_table:place/3` | `{error, erange}` | a request that reaches past its volume |
| a littlefs port's program or erase | an error answer | the volume is read-only or finished |
| a walk into `sN` | `eio` | the volume's outcome is `none`, or it is finished or ended |
| a write on a read-only volume | `erofs` | the writable rule mounted it read-only |
| a write on a grant that is not `rw` | `erofs` | before any callback (F5) |
| a write after the ordered end's freeze | `erofs` | at the grant (`erx_fs`'s freeze) |
| a rename or link between two volumes | `exdev` | before either volume is asked |
| `mount` with a SOURCE under `/dev`, or with `-t` | `einval`, naming `mount [-r] /media/diskN/sN DIR` | always: no device argument, no type |
| `umount DIR` | `einval`, naming `echo eject > /media/diskN/ctl` | DIR is no namespace entry |
| a write to `ctl` | `einval` | anything but `eject` |
| `eject` | `enxio`; `eio` | no mounted medium; a finish failed or its volume had ended |
| a write to `status` | `eacces` | always |
| a create, remove or rename of an entry of `/media` or `diskN` | `eacces` | always |
| following a link in `/media` | `eacces` | always (nosymfollow) |
| an EROFS volume's mount | `{error, enotsup, Text}`, `Text` `erofs: compressed images are not supported` for a compression feature, and naming the bits or the size otherwise | a compression feature, any other incompatible feature, another block size, extended superblock slots |
| a compressed or chunked EROFS inode | `enotsup` | when it is reached |
| the manifest check | the build fails | each rule of [Manifest rows](#manifest-rows) |
| the release check | the build fails | `erx_media` in another release; `erx_storage` or `erx_blk` in the media domain's; `erx_lfs` or the littlefs port in a release build's media domain |
| the EROFS calls check | the build fails | `erx_erofs:mount_source/2` called by any module but `erx_erofs` and `erx_media_erofs`; an `unchecked` form in `erx_verity` |

## Security

Every byte of a drive is a stranger's, and the design places every
parser of it so that a crafted volume ends at most its own mount and a
crafted table its own medium's, and reaches nothing else of the system
through anything erXos parses. The transport's domain, which holds a
DMA-capable controller, moves sectors and parses none of the medium.
The media domain holds no device and no window of the boot medium, so
neither an Erlang defect in a parser nor littlefs's port reaches a
device, the data partition, the vault or the slots. Erlang parsers fail
processes, not memory, and each runs under its own heap bound; volumes
that together exhaust the media domain's memory end the media domain,
which its restart recovers ([Time and memory](#time-and-memory)). The
media domain reaches a serving domain only through each drive's facet,
whose one operation is `window`, and the proxy each `window` answers,
which takes the window's requests under the grant's admission and
account and reaches a medium's sectors and nothing else of that domain;
what its requests can make that domain hold and spend is the grant's
declared limits
([How the grant reaches the media domain](#how-the-grant-reaches-the-media-domain)).

Three things lie outside what this design can confine, and qualify every
statement above:

* **littlefs's port**, in the development builds and test images that
  serve littlefs: littlefs's C is confined to a sub-space per volume,
  whose every block request its owner places in that volume and every
  write its owner checks against the volume's right to be written. What
  remains is what any code in a sub-space can do: call the kernel and
  run on the CPU. On Fiasco that is FD24's system-call surface and
  FD32's branch predictors, which a crafted littlefs volume reaches only
  through a memory error in littlefs that it can steer; the image and
  request fuzz targets are the defence, and a release serves no littlefs
  volume.
* **The transport's DMA**: where no IOMMU confines the controller, the
  media domain's sectors pass through a domain that can write any memory
  (FD12), as every medium's do.
* **The hardware**: a device fault the hardware reports too late to
  attribute, and on Fiasco what FD33 leaves open of a device's errors,
  are the platform's, not a drive's.

E1's guarantee is unchanged for what it protects: the system partition
and packages are decoded only after their trees check, in runtimes where
every block the decoder reads came through `erx_verity`. A drive's
EROFS image is decoded unauthenticated, in the media domain, and served
as files no session runs.

A stick can carry names, labels and links chosen to mislead. Names
reach a session as file names, which every sink escapes; labels reach
`status` through the field escape; links are not followed, so a write
through `/media` lands on the stick or fails. A volume on which the probe
finds a second format the build writes is never written. Who reads which drives is the manifest's: on
a machine whose sessions all hold `media`, every logged-in user reads
every stick, as on a desktop.

## Verification

Each passing case is paired with a seeded fault that must make it fail,
so a pass shows the code under test ran.

### Host tests

| Test | Seeded fault that must fail it |
| --- | --- |
| `erx_media_table` over written cases of each rule: an MBR with one and with four entries; a FAT boot sector with zero entries and a plausible BPB, read as no table; a boot sector whose status bytes are not 0 or `0x80`, read as no table; entries of type `0x00` and of start or length 0 skipped; an extended entry listed and not served; an entry past the end, one that runs backwards and two overlapping entries, each refusing the table, the overlap in both orders | the status-byte test dropped, so a boot sector with code is read as a table; the overlap check made order-dependent, so the second order passes; the backwards check dropped |
| the GPT cases: a GPT behind its protective entry; a primary header that fails its signature, its CRC, its usable area's bounds, an area past the medium's end among them, and its array's bounds in turn, each read from the backup at the last sector; a primary header that passes over an array that fails its CRC, read from the backup at the primary's alternate sector, which is not the last; both copies failing, refused and never read as an MBR or as no table; a signed sector 0 with an `0xEE` entry and a status byte neither `0x00` nor `0x80` over an otherwise mountable FAT boot sector, refused and never mounted whole; an array of 17 KiB; nine used entries, eight served; a primary array that starts at sector 0, one that starts and one that ends inside the usable area, each read from the backup, and one that ends on the last sector, where the backup header is then read, refused; both arrays inside their usable areas, refused `gpt header`; a usable area that meets a header, the other copy's array, and an array that encloses the usable area, each refused `gpt metadata` | a missing primary signature taken as no GPT, so the medium falls back to no table; the status-byte test made before the `0xEE` test, so the protective sector's FAT mounts whole; the usable area's bounds dropped, so the primary whose area lies past the end is taken and the backup never read; the backup read at the last sector after a passing header, so the alternate copy is missed; the array compared by its ends alone, so the enclosing array passes; the other copy's array left out of the metadata set; the array bound removed; the array's place bounded by the medium alone, so the array at sector 0 is taken |
| the table as a property test: for every MBR and GPT the generator writes, the served volumes lie inside the medium, pairwise apart and apart from every metadata sector, and `place/3` never answers a sector outside its volume | the end check written `<` for `=<` |
| `erx_media_probe` on a seed of each table row; on a FAT32 volume holding EROFS's magic at 1,024 bytes, which selects `erofs`; on a FAT32 volume that kept a littlefs superblock in block 1, which selects `littlefs` with `msdosfs` also found, mounting `ro also msdosfs` in a development build and `none format` in a release, which serves no littlefs; and on a FAT12 volume fsimg writes, refused `none format` | the order reversed, so the first volume selects `msdosfs`; the written-formats check dropped, so the littlefs volume is found alone; the FAT type left to the mount, so the FAT12 volume is selected and mounted |
| littlefs's signature over volumes the tree's littlefs writes with `erx_lfs_config`: freshly formatted, after many commits, after compactions of the root pair that leave its current superblock in block 1, and cut mid-commit and mounted again, each found by the probe and mounted | the signature read in block 0 alone, so the compacted volume is `unknown` |
| the writable rule over every combination of format, written formats also found, flush answer and dirty flag | the `also` condition removed, so the doubly formatted volume mounts writable; every flush answer but `ok` taken as `enotsup` |
| a selected format whose mount fails: the FAT32 volume holding EROFS's magic is `none failed` and nothing is written | a fall-through to the next format found, which mounts it as FAT |
| the drive process and the media tree, under `erx_media_sup` against a fake drive grant and window: a medium's mount, a listing, a read; the window's end, after which an open fid answers `eio` and `diskN` lists `status` and `ctl`; a new window, mounted at the next walk; a volume process killed, the others still served; a volume past its memory bound; the drive process killed with a write outstanding, after which the next walk mounts the medium afresh and the outstanding write is answered before the new mount's first read | the drive process not monitoring the window, so the open fid reads after the end; a volume process started as a permanent child, so the kill restarts it; `max_heap_size` given `media_volume_bytes` as words unconverted, so a volume eight times its allowance is not ended; the grant answering the old window again without its restart, so the old write reaches the window after the new mount's read |
| the drive grant's occupant, over `erx_blk_drive:step/2` by name: a place with no occupant drops a serve; a function that occupied a place and ended before its serve leaves it free, its late serve dropped and the next function's `occupy/2` answered `ok`; a block grant occupied by its device process takes that process's serve of a second window, under a fresh reference, after its first window ended, and takes it before that end is seen, its held asks answered from the second window | the clause that lets a grant with no occupant take any serve restored, so the late serve lands and the next `occupy/2` answers `taken`; a block grant's occupation freed at its window's end, so the second serve is dropped and the disk is never mounted again |
| the drive mint and facet, `erx_blk_drive:start_mint/1` and `erx_blk_drive_facet`, over fake grants in one domain and a grantee stand-in: a mint for a recorded drive answers a facet whose `window` reaches that drive's grant and answers a proxy of its window, through which the stand-in reads and writes the fake window; a request other than `window` refused `badarg` with nothing reaching the grant; a mint for a drive the records do not name refused; a block drive's grant ended and started again, after which the facet's next `window` reaches the new grant; while none runs, `no_medium` | the facet keeping the grant's pid from its mint, so after the restart every ask answers `failed`; the facet forwarding every request, so `{occupy, Pid}` reaches the grant; the mint taking any number, so a drive of another domain is minted |
| the window proxy, `erx_blk_drive_proxy`, over a fake window that holds its answers and a grantee stand-in: nine reads sent at once, eight reaching the window and the ninth answered `busy` without reaching it; a request from a second stand-in domain, and one past `max_request`, dropped and counted; a call naming no window request answered `einval`; a flood past the share pausing the proxy until the period turns, with the account's spent count past the share by at most one step; the window's end ending the proxy; the facet's end ending it with the window running; a second `window` ask ending the first proxy before the second starts | the facet answering the grant's `{ok, Window}` unchanged, so the ninth read reaches the window and is not refused `busy`; the proxy forwarding without charging the account, so the flood is never paused; the facet starting the next proxy without ending the one it has, so the first proxy still forwards after the second ask |
| the domain service's grant records, `erx_domain_mints`, over a manifest with two USB drives and a block drive: three records, each served by the domain that holds its drive's device, installed under `{drive, N}` in the media domain's registry, with the service `drive` in its mint request, and `drive => N`, the operation `window` and the five quantities of `abi/services/drive.txt` in its limits; each minted again at the media domain's next incarnation and at its serving domain's; a ready report that provides `drive` from a domain no drive window lies on refused | the server keyed on the window's holder, so the media domain is asked to mint its own drive; the provider admission skipped for `drive`, so the refused report is taken; the provider looked up by the installed name, so no `{drive, N}` record finds the serving domain's mint and all three stay `idle`; the record keyed by the service alone, so the two USB drives share one record and one of them is never installed |
| the restart handoff over `erx_blk`'s device process and a fake device: a request the old window forwards after the reference ended is answered `gone` and never issued; a write issued before the restart completes before the new window's first request; an `eject` whose last finish's flush races the restart answers `eio` and the FAT volume mounts next `ro dirty` or clean, never torn | the reference check removed, so the late request is issued; the restart taken while a write is issued, so the new window's read is issued before it; `eject` answering `ok` after its drive process ended |
| `eject` over two FAT volumes and a littlefs volume of one medium, with writers on every volume running through it: every write answered `ok` before the eject is on the fake window before its last flush, every write after a volume's finish answers `eio`, and the FAT images pass fsimg's verify | the finish not closing its volume, so a write to an already finished volume is answered `ok` and never flushed; `eject` answering before the last finish's flush |
| the media service's freezing checkpoint with writers on two drives: it answers once every volume has finished, later writes answer `erofs` | the media tree answering the checkpoint before its volumes' finishes |
| `erx_erofs:mount_source/2` over `erx_media_blocks` on fsimg images and on the reader's existing cases, which leave `erx_verity`'s `unchecked` mode; an fsimg image with a compression feature bit set refused with `erofs: compressed images are not supported`, and one with a compressed inode answering `enotsup` there | `erx_media_blocks` reading past its volume, which a fixture image at a partition's start shows; the compression bits taken as any other incompatible bit, so the refusal names bits instead of compression |
| the EROFS calls check: no module but `erx_erofs` and `erx_media_erofs` calls `mount_source/2`; `erx_verity` has no `unchecked` | each with a seeded violation: `erx_ns` calling `mount_source/2`; `unchecked` restored |
| the manifest check's drive rules and the release check | each rule with a seeded manifest or release that breaks it alone |
| the littlefs owner over a fake port on the host: a block request past the volume refused; a program and an erase during the mount of a writable volume, during a read, on a read-only volume and after the finish each refused with the fake window's sectors unchanged, and during a write on a writable volume answered; the port's exit, and its silence past the deadline, ending the volume | the placement check removed; the write admission removed, so the read-only volume's fake window receives the program |
| the media tree's renames: a rename between two volumes answers `exdev` with neither volume asked, one inside a volume reaches it | the volume comparison dropped, so the rename reaches the source volume |
| `mount` and `umount`: `mount /media/disk0/s1 /mnt` reads the volume at `/mnt`, `mount -r` refuses a write through `/mnt` with `erofs` while `/media/disk0/s1` still writes, `umount /mnt` removes the entry, a `/dev` source and `-t` are refused naming the working form, `umount` of a path that is no entry names `eject` | `-r` dropped, so the write through `/mnt` succeeds; `umount` that ejects, so `/media/disk0/s1` ends |

### Fuzz targets

Each lands with its parser and builds the same sources for the host:

* `erx_media_table`, MBR and GPT, seeded from the host tests' cases;
  every served volume lies inside the medium and holds none of the
  sectors the reader read, and a copy without the end check, or
  without the metadata rule, must fail;
* `erx_media_probe`, seeded from one volume of each format;
* the FAT server's decoders, already a target of the storage design;
* the EROFS decoder, through `erx_media_blocks`, the reader's existing
  target moved off `unchecked`;
* littlefs's image target and its request target, built with
  `erx_lfs_config` as now, and the port's channel decoder on each side,
  landing with the port.

### QEMU cases

Each runs in the `usb` suite on QEMU `virt`, over its stick plumbing
(`tools/lib/erx/usb_boot.rb`'s stick, `QemuPlan::Pcie` with a disk,
`Qmp#eject` and `Qmp#device_del`), with the media domain added to the
suite's manifest. The harness writes each stick from a declared tree of
files and keeps the SHA-256 of each; a line at the media domain lists
the volume and reads each file through `/media`, and the case passes
when the names and hashes equal the harness's.

| Case | Seeded fault that must fail it |
| --- | --- |
| a FAT16 and a FAT32 stick on an MBR, a FAT32 stick with no table and a FAT32 stick on a GPT, each listed and read | the no-table rule dropped, so the bare stick shows no volume; the drive's facet answering the window's own pid, which takes no call from another domain, so the media domain's first read of a stick times out and it shows `medium idle failed` |
| a FAT12 stick fsimg writes, refused `none format` with `sN_fat 12`, its bytes unchanged | the probe's FAT type dropped, so the stick mounts |
| an EROFS stick, uncompressed, fsimg's | the volume module mounting with `erx_erofs:mount/2`, which no layout opens |
| a littlefs stick of erXos's geometry, written by the harness's littlefs tool, on a development build | the owner's placement check removed, while the port asks for a block past the volume |
| a stick of each refused name (an exFAT, an NTFS and an ext2 signature, each the format's header alone) refused by name, its bytes unchanged | the probe answering `unknown` for every unserved format |
| a FAT32 stick that also holds EROFS's magic at 1,024 bytes: `none failed`, its bytes unchanged | a fall-through to the next format found |
| a FAT32 and, on a development build, a littlefs stick written, synced, ejected through `ctl`, read again after the stick is put back; the FAT image passes fsimg's verify after the run | the finish's flush skipped, so the FAT image is dirty |
| a FAT32 stick written without a sync, then the machine ended by an ordered `off`; the stick, read on the host, holds every write and passes fsimg's verify | the media service left out of the ordered end, so the stick is dirty |
| a file open on a stick when QMP ejects its medium: the next read answers `eio`, `ls /media/disk0` shows `status` and `ctl`; the medium put back through QMP mounts again and reads equal | the volume's node naming the drive rather than the volume process, so the old fid reads the new medium |
| `device_del` mid-write, then `device_add`: the stick mounts again, FAT read-only `dirty` | the dirty flag ignored at mount |
| a session's `mount /media/disk0/s1 /mnt`, the stick's files read through `/mnt` and their hashes equal, then `umount /mnt`, after which `/mnt` is gone and `/media/disk0/s1` still reads | `mount` binding the drive's directory instead of the volume, so `/mnt` lists `status` and `ctl` |
| a second virtio disk of the `drive` role, served by a block driver domain of its own, listed and read | the block service reading the boot layout on a `drive` device |
| the same virtio disk read again after the media domain is restarted, with nothing detached | the grant answering every ask after the first `no_medium`, so the disk is not mounted again |
| the same virtio disk read again after its driver is restarted through `/dev`'s `ctl`, with the media domain running | the facet holding the grant it found at its mint, so every later ask answers `failed` and the disk is not mounted again |
| a stick read, then the USB domain restarted: an open file answers `eio`, `disk0` leaves the `/media` listing and comes back once the restarted domain reports ready, and the stick reads equal | the grant record not following the serving domain's new incarnation, so `disk0` never comes back |
At the milestone gate, images that the FreeBSD oracle guest's
`newfs_msdos` and `gpart`, and the Linux oracle guest's `mkfs.fat`,
`mkfs.erofs` and `sgdisk`, write, each treated as hostile, are read
the same way, and the run records which of `mkfs.erofs`'s outputs the
reader serves and which it refuses by name. Whether `erlang:crc32/1`
computes the GPT's CRC-32 is unverified until those images' tables are
read.

## Alternatives considered

**A window per partition, the table read in the USB domain.** The
storage design's first form: the domain that holds the controller reads
the table and serves each partition as its own window, and each file
server holds one partition. It loses: the table, a stranger's bytes, is
parsed in the one domain that holds a DMA-capable device; the manifest
must name partitions before any medium is seen; and the isolation it
buys between partitions of one stick protects a stranger's volumes from
each other. The whole medium as one window moves the parse out and
deletes the rows.

**One domain per drive, or per medium.** A domain per drive would give
each drive a runtime of its own, and a domain incarnation per medium
would end every state of a medium with its domain. It loses: Erlang
parsers already fail only their processes and littlefs's C is already in
a sub-space per volume, so the extra runtimes buy nothing, and an
incarnation per medium would spend the domain's restart intensity on
every stick pulled out and add a restart to every insertion.

**Probing in the medium's reader.** One process would probe every
volume before any mounts. It loses: a probe defect a volume's bytes
trigger would end its siblings' mounts too, and each volume's process
reads its own sectors anyway.

**Volumes as device nodes under `/dev`.** `/dev/disk0/p1`, or
`/dev/disk0/1`, would hold a volume's files. It loses: a directory
named like a device node promises what a device node does, `dd`,
`newfs` and `mount` working on it, and gives `EISDIR` to all three;
and it would join a third server at `/dev`, where a program's
namespace joins two
([design-files.md](design-files.md#building-binding-and-mounting)).
`/media` is the media service's tree and says so.

**An explicit mount of each volume, with a lifetime of its own.** A
session would ask the media domain to start one volume's file system,
in a mode it chose, at a path it chose, and the volume would live
while any attachment did. It loses for the release: a state per volume
(mounted or not), a lifetime to keep across every session's entries,
and a remount path, where mounting at the first walk in a domain that
holds nothing else buys the same safety, and the session's own
`mount` already chooses the path. Its one gain, a read-only volume by
request rather than a read-only view, has no consumer yet.

**Raw access to a medium, later.** No release consumer needs a
medium's sectors: exchanging files does not, and updates have the slot
writer. When one does, the shape is a file `data` in the drive's
directory, `/media/diskN/data`, the medium whole, served by the media
domain, which alone holds the window; reached only through an
administrator's facet that serves the same tree with `data` added, as
the device service's control facet adds `ctl`
([design-system.md](design-system.md#drivers), "The `/dev` tree"), so an ordinary
`media` grant never lists it; and opened only while the medium is
idle, no volume process existing then, `ebusy` otherwise, decided by
the drive process, the drive's one owner. FreeBSD's `newfs_msdos` and
`fsck_msdosfs` would then be plain programs over `data`, and a dirty
stick would be repaired on erXos.

**A grant that answers each window once.** It would keep a medium from
being mounted twice by refusing a second ask until the medium ended. It
loses: a fixed drive, which cannot be taken out, would stay unusable
after any restart of the media domain, and every user would replug
after one. Restarting the block service on a second ask gives the same
order with nothing to replug.

**No grant across domains: the media domain holds the drives'
devices.** It would need no route between domains. It loses DR-R2
outright: every parser of a stranger's bytes would run beside a
DMA-capable controller, and the USB domain's HID functions and hubs
with them.

**An introduction of the device service's own that hands each grant
over.** The device service would connect the media domain to each
serving domain and pass it the grant's pid. It loses: the system domain
cannot pass another domain's pid on, since only the pid's own domain
exports it, and what is left, introducing, minting, installing, a
deadline and a fresh start for each incarnation, is the grant record
every configured domain's service already has.

**A service row and a facet row for each drive.** The serving domain's
`service` row of `drive` and a `facet` row granting it to the media
domain would put drives through the grant records with no rule of their
own. It loses to deriving them: both rows restate the window row, which
already names the device, and so the server, and the holder, and a
check that the three agree would be a list of places to keep in step.

**The grant's own pid handed over, the grant unwrapping `window`.** The
grant would serve other domains itself and take only `window` from
them. It loses: the export toward the grantee alone, the end with the
grantee's connection, the operation check and the request limits would
be the grant's own code rather than the facet behaviour's, and
`occupy/2` and `serve/3` would sit one unwrap away from the holder.

**The facet as the grant.** Each mint would start the drive's grant
itself. It loses: the grant's memory that it answered a window must
outlive the media domain's incarnation, whose restart is the case that
memory exists for.

**The medium as a file of the serving domain's tree.** As the USB
domain's input tree serves `hid0`, it would serve `disk0` as a file,
granted by a facet row, and the media domain would read sectors as file
reads. It loses: every sector request would pass a file grant and its
framing in the serving domain on top of the window, the restart's order
would still need the medium reference, and the window's protocol
already crosses domains. A stream of records is a file's natural shape;
a medium's sectors are the block service's.

**A token from `occupy/2` that every serve carries.** It loses: the
issuer's pid already names the occupation, so a token closes no case
the pid leaves open, and a block drive would still need an occupation
that outlives each of its windows.

**The window itself handed over.** The facet's reply would carry the
window's pid, exported toward the media domain, and the window would
be started with `{erx_serve, any}` to take its calls. It loses: the
facet's limits would bound only the asks for a window, and every sector
request would reach the serving domain outside any admission, so what
the media domain could make it hold and spend would be bounded by
nothing the grant declares. Teaching the window the facet's admission
and account instead would put a second kind of window, bound to a
facet, into the block service that every storage client shares, and
the window would still have to outlive or end with a facet it did not
start. The proxy is the one kind of process the facet design already
has for this, and the window stays what the serving domain's own
clients see.

**The facet forwarding the sector requests itself.** The facet would
take `read`, `write`, `flush` and `info` beside `window`, each naming
the medium by a number the facet issued, and forward each to that
medium's window. It needs no proxy, but loses: the media domain could
then monitor nothing that ends with a medium, so the drive process
would learn of a medium's end only from a failed request or a request
of its own made for the purpose, and each sector request would carry a
number for the facet to look up.

**Read-only drives.** A drive row's `read` right would reach the
proxy, which would refuse every `write`, and the writable rule would
gain a condition, so a volume on such a drive mounts read-only. It
loses for now: no manifest or board needs a medium that the media
domain itself may not write, and what users may write is already the
rights of each session's `media` facet row. It stays a small change if
a consumer appears ([Open decisions](#open-decisions)).

**A tree per volume.** Each volume its own tree and grant would make
the namespace's own `exdev`, statfs and qid rules apply and give
`mount` a line per volume. It loses: grants of another domain reach a
session only through the system domain's introduction, and facets are
fixed by the manifest, so every insertion would cross into the system
domain. One tree over every drive costs the media tree's own `exdev`
rule, the mount number in each qid, a slow volume delaying its
session's other calls into the tree, and one `mount` line whatever is
plugged in.

**littlefs's NIF in the media domain.** It loses: an assertion or crash
would end the media domain and every drive's mounts, a stick that fails
at every mount would use up its restarts, and a memory error would reach
every drive it serves and the next medium in its own drive.

**The `unchecked` mode of `erx_verity` for drives.** It loses: the
funnel E1 rests on would carry a form that checks nothing, held apart
only by a rule on who may name it, in every runtime; the storage design
rejected the same exception for the system partition's directory
([design-storage.md](design-storage.md#alternatives-considered)). A
source that only the media domain's release contains needs no exception
in the funnel, and deleting `unchecked` leaves the funnel with none.

**A second kind of source inside the EROFS reader.** The reader would
take either a hash-checked handle or the media domain's, with a clause
for each. It loses to a decoder over a source function: the shared
reader would name an application module that most runtimes do not hold,
and carry an unchecked branch of its own.

**A format declared by the manifest, the table's type byte or the
user.** It loses: the manifest is written before any medium exists,
type bytes are often wrong, and a declaration that disagrees with the
bytes either fails or writes the wrong format; FreeBSD's automounter
asks the bytes.

**Mounting at `/media/LABEL`.** FreeBSD's automounter keys a volume by
its label. It loses here: a label is a stranger's text, two sticks may
share one, and a path that changes with a label breaks scripts in the
same way a drive number would; the label is a `status` line instead.

**Mounting on a medium's arrival rather than at the first walk.** It
would need the drive grant to announce media, a message of its own, and
would parse every medium plugged in whether or not anyone reads it. The
first walk is FreeBSD's automounter's moment too.

**Following an MBR's extended partition.** It would serve logical
partitions, an erXos card's system and data partitions in a USB reader
among them. Not needed for any medium the scope names; a bounded walk of
the chain can be added as the table's next rule.

## Open decisions

A release serves FAT16, FAT32 and EROFS volumes from drives; littlefs
volumes are served only by development builds and test images, and
littlefs stays a stopgap; FAT12 is refused by name. One decision is
open:

* **Read-only drives.** Whether a manifest may name a drive the media
  domain itself may not write, a stick that no session can change
  whatever its `media` rights, as a kiosk or an evidence reader might
  want. The design refuses a drive row whose rights are not
  `read,write` ([Manifest rows](#manifest-rows)). Recommendation: keep
  the refusal until a board or a user asks for one; then the row's
  `read` right becomes the grant's, the proxy answers every `write`
  `{error, erofs}`, and the writable rule mounts each volume of such a
  drive read-only, naming `drive` in its `status` line
  ([Read-only drives](#alternatives-considered)).

## References

* [design-storage.md](design-storage.md): the block service, windows,
  FAT, EROFS, littlefs's port, the durability facet.
* [design-usb.md](design-usb.md): media, drives, the SCSI subset.
* [design-files.md](design-files.md), [design-app-trees.md](design-app-trees.md):
  `erx_fs`, keepers, its freeze, facet mounts, links, `status` and
  `ctl`.
* [design-system.md](design-system.md#shutting-down): the ordered end.
* [design-stopgap.md](design-stopgap.md#littlefs-on-a-drive): littlefs
  on a drive.
* [design-f2fs.md](design-f2fs.md): F2FS.
* FreeBSD src, commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`, read
  from a local clone with `git show`; SHA-256 of each file:
  * `sys/geom/part/g_part_mbr.c`,
    `c26b2a7467a59e46a1253741a603e609035e48e6e0840e4631bfde4432e1f28b`;
  * `sys/geom/part/g_part_gpt.c`,
    `e6aa9bcbf92e0e07cca5f48589dd5c3fbb80b088e9086fc2001a1d5dd45fc42b`;
  * `sys/sys/disk/gpt.h`,
    `b941378450760804b8f7d829040d85d08e9cb55a095fdaf1dc2fdcd0bdeb6201`;
  * `sys/geom/part/g_part.c`,
    `936eac38d5c7a71f3b9643839972e1871301f600792a9a6b0d41fe76384c85bf`;
  * `sys/ufs/ffs/fs.h`,
    `977d6f15bac9eeccb6512a31d479af91a588bf331ca2f718d1e1c8cfdc70aea1`;
  * `usr.sbin/fstyp/fstyp.c`,
    `5c2eee079cf60baa7af5ad25f5dbff1e7a4be62a8a6cbf418a2197464bac77ac`;
  * `usr.sbin/fstyp/msdosfs.h`,
    `8b47c04c2ddad4c3ef6141fef64ef125283e8a7d61431ccdf1630123f92d4058`;
  * `usr.sbin/fstyp/msdosfs.c`,
    `9f8909ef88cfff0800b79ba2c20f7698d811af746771355e3fcc5b964507b48d`;
  * `usr.sbin/fstyp/cd9660.c`,
    `8525db2fe2d22960afab018190a091b470182b02dd916240d7c531863416bf20`;
  * `usr.sbin/fstyp/hfsplus.c`,
    `ad51bb044d91a8477e46220bbdf1f49243960c877ee53f99b93a33c3737ae744`;
  * `usr.sbin/fstyp/ext2fs.c`,
    `f988d57b6786daf121e2110e61be9240d2d7b158ba3d0c48db4cf4dea9d70841`;
  * `usr.sbin/fstyp/apfs.c`,
    `b1552cdf48c878d6655c46e20f38bb6b58c5f7fd95089d0af119011bf80a3319`;
  * `usr.sbin/fstyp/exfat.c`,
    `13077baef8584384c36fd6a76c704450294583a0468a6f79045664525a650ad2`;
  * `usr.sbin/fstyp/ntfs.c`,
    `c6ab3a1a859b3ab9c57ef3100e2e62f920730ab5f757a082c90f20d778cdff69`;
  * `usr.sbin/autofs/autofs/special_media`,
    `b642eab511c6bc5de8c093253a9339b31d04307d0b893717163d87d426e15465`;
  * `usr.sbin/autofs/auto_master`,
    `cc7437b63261d3e3640e4ae0af02be0920a4da7be6ac19fa86ede121fafda509`.
* littlefs v2.11.3, `littlefs/lfs.c` in the tree
  ([littlefs/ORIGIN.md](../littlefs/ORIGIN.md)), and its `SPEC.md` at
  the same commit, `6cb4e86540eca0d9ba62500a298385c9d863c8be`, fetched
  from `https://raw.githubusercontent.com/littlefs-project/littlefs/`,
  SHA-256 `6dd74dfc58ac93589f8e002bb73c0830a59206912cfe8c951c07eb2bd5fccad0`.
