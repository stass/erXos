# Storage and system updates

Storage in erXos is a few services in Erlang domains of their own, above
the block driver, an Erlang process over the device NIF, and reached
through facets like every other service: read-only releases in EROFS
images, checked block by block where they are consumed; read-write files
on the data partition, in erXos's F2FS, with littlefs as the stopgap
behind the same interface; FAT partitions for removable media and for
exchanging files with other machines; and system updates written to the
spare of two slots and committed only after a healthy trial boot. This
document is the medium's layout and formats, the block driver, the storage
services, and the update path. The key idea is that every rule rests on
facts a party reads for itself: a domain reaches only the partition
windows it was granted, a block is trusted only after its hash checks in
the domain that uses it, and the slot writer derives what it may write
from the medium's record and the boot value the kernel reports, never from
anything a service tells it. Every file system and the driver are Erlang,
so every open file, every window and the driver itself are processes that
can be inspected, traced, supervised and upgraded live, and a parsing bug
in a file system or in the driver crashes a supervised process instead of
corrupting memory; the work done once per byte, hashing and checksums,
runs in a few C primitives of the runtime.
The architecture is in [design.md](design.md); the kernel's machine page,
lease and trial end in [design-kernel.md](design-kernel.md); the device
service and the driver table in [design-system.md](design-system.md#devices);
the device NIF in [design-runtime.md](design-runtime.md#the-device-nif);
the file protocol the storage services speak in
[design-files.md](design-files.md); the primitives in
[design-runtime.md](design-runtime.md#per-byte-primitives).

Decisions every reader of this document needs:

* **Partitions are windows.** A domain reaches only the sectors of the
  windows granted to it, and each file system runs in a domain that holds
  a window on its own partition and nothing of the medium beyond it.
* **One format per job.** The boot image holds what booting needs, EROFS
  images hold the rest of a release, read-only and hash-checked where
  consumed, the data partition holds what changes, and FAT holds what is
  exchanged with other machines.
* **File systems and the driver are Erlang.** The
  block driver, the EROFS reader, erXos's F2FS, the FAT server and the
  slot writer are Erlang; the driver touches its device through the
  device NIF, and hashing and checksums are C primitives
  ([design.md](design.md#decisions)). littlefs, the stopgap, is C in a
  sub-space port of the storage domain.
* **The block driver lives where the configuration puts the device.** In
  the default configuration the block device belongs to the storage
  domain and the driver runs there; on a board whose storage controller
  is unconfined, the release configuration gives the device a domain of
  its own ([design-system.md](design-system.md#devices)). The driver's
  windows, seen from their clients, are the **block service**: a client
  reaches a window by the window's pid, local or exported, so the storage
  service and every other client have one code path in both
  configurations.
* **F2FS from a clean room.** erXos implements F2FS, in Erlang, from a
  specification written in its own words, with Linux as the oracle and a
  legal review before any distribution; littlefs
  is the stopgap.
* **A/B slots with trials, and the record is the whole state.** An update
  goes to the spare slot, boots once as a trial that writes nothing but
  the boot-selection record, and is committed only from that trial, when
  healthy; whether the spare is complete is checked against its manifest,
  never recorded (U1 to U5).
* **No conversion.** Nothing erXos stores is
  converted: the data partition and the vault's partition, which littlefs
  serves until erXos's F2FS, are created afresh by the installation that
  brings erXos's F2FS, and an update never changes a partition's format.

## Context

A machine needs a read-only system that a fault cannot corrupt, files that
survive power cuts, updates that never leave it unbootable, and a way to
move files to and from other machines, and every byte a medium returns is
untrusted input. Storage sits on the block driver and the device service,
which gives the block device to one domain and names which domain holds
which partition's window ([design-system.md](design-system.md#devices));
on the kernel, which reports the boot value in the machine page and takes
a lease over a trial
([design-kernel.md](design-kernel.md#console-log-and-panic)); on the
runtime's file layer, whose EROFS reader is preloaded in every runtime
([design-runtime.md](design-runtime.md#files)); on the runtime's per-byte
primitives ([design-runtime.md](design-runtime.md#per-byte-primitives))
and the device NIF
([design-runtime.md](design-runtime.md#the-device-nif)); and on the file
protocol, 9P2000.L, whose operations the storage services implement
through `erx_fs` ([design-files.md](design-files.md)). erXos decided that system code is Erlang wherever that costs too little performance to
matter, drivers included, with C for the per-byte primitives and the
device shim beneath a driver ([design.md](design.md#decisions)). The
choices rest on the research into file systems and boot selection
([research](research-boards-storage.md#file-systems)), and
[plan.md](plan.md#m6-immutable-code-lasting-data) and
[plan.md](plan.md#m12-storage-networking-boards) schedule them.

## Requirements

* **ST-R1.** Read-only releases verified where they are consumed, so no
  storage domain or driver is trusted with their integrity.
* **ST-R2.** Durable read-write files per principal, with quotas, that
  survive a power cut at any write.
* **ST-R3.** Updates that never leave the machine unbootable: whatever
  ends an update or a trial, the machine boots a complete system.
* **ST-R4.** A crafted medium or file system image damages at most its
  own partition and the domain that parses it.
* **ST-R5.** Reproducible images: the same inputs give the same slot
  image, byte for byte.
* **ST-R6.** FAT partitions served as files, for removable media and for
  exchanging files with other machines, under the same confinement as
  every other file system.

Non-goals: converting a data partition or the vault's partition, in
place or by an update, since an installation creates them afresh;
compressed EROFS images
unless the media lack room; Linux's file-system code in the tree; exFAT; booting or updating from anything a domain parses as
FAT.

## Overview

```text
  medium:  [ record ][ slot A: boot image + EROFS ][ slot B ][ vault ][ data ]
                |              |                                 |       |
           slot writer    window per EROFS image            a storage domain
           (Erlang; the   -> EROFS reader (Erlang)          for each, in
            only writer      in each domain, on blocks      Erlang: the vault's
            of slots and     the hash-checking reader       serves the vault
            the record)      checked against the tree)      alone; both run
                ^                                           erXos's F2FS,
                |                                           littlefs as stopgap
           update service (system domain), trial and commit

  block driver (Erlang, over the device NIF, in the storage domain by
  default): one window process per partition and client; a window's pid
  is local to the storage service and exported to every other client

  removable medium or exchange partition:  [ FAT ] -> FAT server (Erlang)
```

The block driver serves each partition as a window. The firmware boots the
slot the record names, or the spare once as a trial. Each domain whose
release lives in an EROFS image reads that image through its own window
and checks every block. Principals' files live in the storage domain over
the data partition. The vault's sealed key files and the machine keys
live on the vault's partition, served by a storage domain of its own
whose only client is the vault, so no principal's request reaches them;
it runs the same release as the data partition's
([design-system.md](design-system.md#the-vault)). A FAT partition is
served by a FAT server in a domain of its own. The update service writes
an update into the spare through the slot writer, requests a trial, and
commits by rewriting the record only once the trial is healthy.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **PW1.** A file system reaches the medium only through a window on its own partition, and no window but the slot writer's covers a slot or the record | a window is a process of the block driver that checks every request against the sectors the device service named for it; the device service derives windows from the medium layout of the ABI file and the system configuration's roles, and names slot and record windows for the slot writer alone; a file system holds a window's pid and nothing of the device, since only the block driver's modules call the device NIF, a build check; native code that parses a file system runs in a sub-space holding only its channel, so it reaches no window and no device | a window named by sectors from anything but the layout; a parser that calls the device NIF or holds another window; native file-system code in the driver's domain | a host test of the device service's derivation: no domain but a storage domain or the slot writer receives a window on a data, FAT, vault's or slot partition, each receives one partition's, and only the storage domain that serves the vault receives the vault's ([design.md](design.md#chokepoint-checks)); the build check that only the block driver's modules reference `erx_device`, with a seeded violation; a test that every other request for those windows fails |
| **E1.** A domain parses only EROFS blocks that passed its image's hash tree | the EROFS reader receives an image's bytes only from the hash-checking reader, `erx_verity`, the only module that holds an EROFS window's pid: it receives each block as a binary in the domain's own memory, checks it against the image's tree with the SHA-256 primitive, whose root comes from the boot image, and returns the binary only if it matches | a read path around the hash-checking reader; a check on a copy the driver still holds rather than the domain's | a cross-reference check that no module but `erx_verity` sends to an EROFS window and that the reader's modules reach an image only through `erx_verity:read/3`; a test with a flipped bit in each block |
| **U1.** The slot the machine runs from, and the slot a failed trial falls back to, are never written | the slot writer allows a slot write only on `normal(C)` with the record naming `C`, and only to the other slot | a slot write allowed on any other boot value, or from a service's word | the exhaustive model of the update path |
| **U2.** The record names only the slot first installed or a slot that passed a healthy trial | the slot writer rewrites the record only on `trial(S)` with the record naming the other slot, naming `S`, and the update service asks for that only once the trial is healthy; no other boot value, a firmware's fallback boot included, allows a record write | a record write on a normal boot | the exhaustive model, with every boot value against every record |
| **U3.** After a power cut, a crash or a hang at any point, the machine boots the committed slot, or the spare once as a requested trial | the record changes only by one sector, the trial's request is one-shot, and a hang during a trial ends in the watchdog's reset; the firmware runs the watchdog from power-on on a board configured as [design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record) describes, and on a board without that configuration a trial whose firmware stage hangs, before the kernel's first decision, needs a power cycle | a multi-sector record; a request that survives the trial | the model with a power cut after every write; runs on each board |
| **U4.** A trial boot writes nothing but the record and the reset count | the block driver's write path, `erx_blk_write`, is the one module that hands a controller anything to do, a virtio request or an SD command, and its one trial check refuses every write but the record window's and the reset count's while the boot value is `trial(_)`, reading the boot value from the machine page through its runtime | a second write path in the driver: a module other than `erx_blk_write` that posts a virtio request or issues an SD command | the device NIF's ownership of the SD command register, which `erx_device:write/3` refuses, so a command is issued only by `erx_device:command/2`; the build check that no driver module but `erx_blk_write` names `erx_device:post/4` or `erx_device:command/2`, holds `erx_device` as a value or makes an atom from data ([design.md](design.md#chokepoint-checks)), with a seeded violation of each kind; a QEMU test of every client's writes on a trial boot; a host test of the SD write function on a trial boot value |
| **U5.** Only a complete spare is ever tried | the update service asks for a trial only after the spare has passed the check against the update manifest in its manifest window, which runs at each normal boot and after each write and records nothing; the manifest is written last, so a spare whose write was cut short has no manifest that matches it | a recorded "complete" state; a trial requested from a service's word | the model with a power cut after every write of the spare; a QEMU test that cuts a spare's write short and finds no trial requested |

U1 to U5 hold on a medium that writes a sector atomically and honours a
flush, as an SD card does not promise
([design.md](design.md#residual-risks)), and none depends on anything the
update service remembers: each follows from the record, the boot value
and the spare's bytes, which a party reads for itself.

## Data model

**The block driver.** The driver is an Erlang application under a
supervisor, `erx_blk_sup`, in the domain that holds the block device. It
has two layers. The **transport** is one **device process**, registered
as `erx_blk`, which owns the controller through the device NIF, receives
its interrupts as messages and acknowledges them
([design-runtime.md](design-runtime.md#the-device-nif)), and moves
sectors: `erx_blk_virtio` drives a virtio-mmio block device through its
ring, posting descriptors from a pool of DMA buffers the domain holds,
and `erx_blk_sd` drives an SD card through an SD host controller
([The SD host controller](#the-sd-host-controller)). The **service**
above it names no controller: a **partition process**, which reads and
parses the partition table with binary matching and checked bounds,
fuzzed on the host; and one **window process** per window. Between
them is the **write path**, `erx_blk_write`, a module the device
processes call for every request they hand a controller, so the trial
rule sits below every transport. A window receives `{read, Sector, Count}`,
`{write, Sector, Bytes}` and `flush` from its one client, checks each
against its sectors, and hands it to the device process. A read
completes with a fresh binary: on virtio the bytes the device NIF copied
out of the pool at completion, on the SD controller the words the device
process read from the controller's data port. So no binary aliases
memory a controller can still write; a reply to a client in another
domain crosses that client's lane as a frame.
The device NIF parses nothing a device wrote: the Erlang processes do,
with binary matching in supervised processes, so a malicious controller
corrupts no memory.

**The transport contract.** Every device process answers the same four
calls, so nothing above it depends on the controller:

* `erx_blk:read(Sector, Count)`: `{ok, Bytes}`, `Count` sectors from
  `Sector`;
* `erx_blk:write(Sector, Bytes)`: `ok` once the controller reports the
  sectors written to the medium;
* `erx_blk:flush()`: `ok` once every write answered before it is
  durable on the medium: on virtio a flush request
  (`virtio_blk_t_flush` of `abi/formats/virtio.txt`), whose feature the
  device process's start requires of the device, and on the SD
  controller a status check ([The SD host controller](#the-sd-host-controller)).
  A transport whose medium has no way to flush, which it learns before
  any write, answers `{error, no_flush}` and never `ok`: a USB medium
  that refuses SYNCHRONIZE CACHE
  ([design-usb.md](design-usb.md#the-scsi-subset)); virtio and the SD
  controller never answer it;
* `erx_blk:info()`: `{ok, #{transport, capacity, max_sectors, detail}}`,
  the transport's name (`virtio_mmio` or `sdhci`), the medium's length
  in sectors of 512 bytes, the most sectors one request moves, and a map
  of what the transport reports about itself for the log and the
  inspector (virtio's version and features; the card's type, bus width
  and clock).

Each answers with one closed set of errors: `{error, bad_count}` for
bytes that are not whole sectors or a count above `max_sectors`, and
`{error, out_of_range}` for sectors past the capacity, both before the
controller is touched; `{error, erofs}` from the write path on a trial
boot (U4); `{error, busy}` when the device process's backlog is full;
`{error, no_device}` when no device process runs; `{error, no_flush}`
from `flush()` on a medium that cannot flush; and
`{error, {device, Detail}}` for a request the controller or the medium
failed, where `Detail` is built from fixed atoms and integers for the
driver's log line, never from a controller's bytes, and never reaches a
client. A window answers its client `einval` for `bad_count`, `erofs` for
`erofs`, `enotsup` for `no_flush`, so a file system can tell a medium
that cannot flush from one whose flush failed, and `eio` for every other
error. The maximum request is the
transport's: 8 sectors on virtio, the sectors one pool buffer holds
beside its header and status byte; 64 sectors on the SD controller,
32 KiB, the most whose write a card within its specification finishes
inside the in-flight bound below. The
block service reads it from `info/0` when it starts a window, and the
window refuses a larger request with `einval`. A device process serves
its requests one after another in the order they arrive, holding a
bounded backlog while the controller is busy.

**Every request is answered within 28 s of its acceptance**, so a
device process never writes for a caller that has given up. The device
process stamps each request with the time it accepted it. It issues a
request only within 10 s of that stamp, the wait limit, and answers one
still in the backlog after it `{error, {device, deadline}}` without
touching the controller; the controller and the medium are as the last
request left them, so this is no failure of the device process. An
issued request that is not complete 18 s after it was issued, the
in-flight bound, is a failure: the device process ends
([Failure](#the-sd-host-controller)) and issues nothing more, and the
request's sectors are unknown, as for any failed write. The callers' deadlines sit above that sum, each
longer than the one below it, so each layer answers before its caller
gives up: `erx_blk`'s calls wait 30 s (`CALL_TIMEOUT` in `erx_blk.erl`), a window
35 s (`CALL_TIMEOUT` in `erx_blk_window.erl`) and littlefs's port 60 s
(`DEADLINE_MS` in `erx_lfs.erl`). The SD controller's in-flight bound covers its
largest request at the specification's own limits: 64 blocks written at
250 ms of busy each, the last up to 500 ms (Physical Layer 4.6.2.2,
p.95), is 16.25 s, and a read of 64 blocks at 100 ms each (4.6.2.1,
p.95) 6.4 s.

**Choosing the transport.** `erx_blk:start_link/0` reads the domain's
device records (`erx_device_record`) and starts the device process of
the one record whose role is `block`, chosen by the record's CMSIS-SVD
peripheral from a two-row table: `virtio_blk` starts `erx_blk_virtio`,
`sdhci` starts `erx_blk_sd`. A new controller is one row and one module.
The record's peripheral comes from the device-kinds table
(`include/erx/device_kinds.h`), which maps a manifest device's role and
compatible string to its record: `virtio,mmio` to `block virtio_blk`,
and `brcm,bcm2711-emmc2` to `block sdhci`. A domain with no block record
has no device process and no line in the log, since a machine without a
disk is a configuration, not a fault. A domain with more than one is
refused with one line naming them and has no device process, since the
manifest gives a storage domain one block device. Every start and
restart of a device process runs its transport's whole start sequence,
which resets the controller, so a restarted process finds nothing its
predecessor left half done.

**The write path.** All of the driver's writes to the medium go through
the write path, which applies the trial rule (U4). What makes a
controller act is a single act per transport: on virtio-mmio, posting a
request with `erx_device:post/4`, whose header's type says whether the
device reads or writes; on an SD host controller, writing the command
register, `cmdtm`, the transfer-mode and command halves of the
controller's word at offset `0x0C`, written as one 32-bit word, which
issues one command to the card. The device NIF owns both acts: it alone
writes a virtio queue's doorbell, in `erx_device:post/4`, and it alone
writes the SD command register, in `erx_device:command/2`, since the
SVD source marks the register `ownedByNif` and `erx_device:write/3`
refuses it ([design-runtime.md](design-runtime.md#the-device-nif)).
The NIF posts reads and writes alike, and the command register issues
reads and writes alike, so the write path holds by construction: one
module, `erx_blk_write`, performs both acts. It builds every virtio
header and every SD command word itself, from CMD0 at a card's
initialisation to CMD13 at a flush, from the generated fields of the
SVD source; a device process names what it wants: `{read, Sector,
Count}`, `{write, Sector, Data}`, `flush`, or a card-identification step
of `erx_blk_sd_card`, `{cmd | acmd, Index, Argument}` with the data
block it moves, never a request type or a command word. One place
decides which commands reach the card: `erx_blk_write`'s SD table, an
allowlist of exactly the identification's commands (CMD0, 2, 3, 7, 8,
9, 16, 48, 49 and 55; ACMD6, 13, 41 and 51), each with its response
type and the block it moves, refuses every other index and any step
whose data disagrees with its row; and only its read, write and flush
functions build CMD17 and CMD18, CMD24 and CMD25, and CMD13 (SEND_STATUS). Only its
write functions, one per transport, build a type or a command that
writes the medium (virtio's `OUT`; SD's CMD24 and CMD25), and each
calls the one trial check first.
On the Raspberry Pi 4 it also issues the commands of the legacy
controller's SDIO card, from a second table, CMD3, 5, 7, 52 and 53, built
only by its SDIO builders and issued only on a record of kind `sdio`, as
the SD table's commands are issued only on a `block` record
([design-wifi.md](design-wifi.md#commands-go-through-erx_blk_write)).
No SDIO command writes a medium, so none passes the trial check.
The transfer-mode half of every command word it builds leaves DMA off,
and `erx_device:command/2` refuses a word that turns it on, so no
command starts a DMA transfer. DMA through the controller's ADMA2 tables
is [design-device-dma.md](design-device-dma.md#the-three-descriptor-forms)'s,
for a later mode of this driver.

Since the NIF refuses the register to `write/3`, a module that holds
the register's name, in a map, a table or a message, still cannot issue
a command; what remains is to keep the two issuing calls in
`erx_blk_write`. The build check over the driver applications' Erlang
sources that holds `erx_device:post/4` there
(`tools/lib/erx/chokepoint_rules/device.rb`) holds `erx_device:command/2` the
same way, and makes the only way to reach either a call it can see:
outside comments and strings, in every driver module but the issuing
sites, it fails on

* `erx_device:post` or `erx_device:command`, as a call, a fun or an
  import;
* `erx_device` anywhere but as the module of a remote call whose
  function is a literal name, `erx_device:read(...)`, so the name is
  never a value: not an argument of `apply/3`, `erlang:apply/3`,
  `spawn/3` or any other function that calls a module it is handed, not
  in a variable, a macro, a fun, a map or a record, and a call whose
  function is a variable, `erx_device:F(...)`, fails too; and
* `list_to_atom/1`, `list_to_existing_atom/1`, `binary_to_atom/1,2`,
  `binary_to_existing_atom/1,2` and `binary_to_term/1,2`, the functions
  that make an atom from data, which a driver module has no use for.

With the module's name never a value and never made from data, a
driver module reaches `erx_device` only by literal calls, and the first
rule sees every one that issues. Outside the driver applications no
module names `erx_device` at all (`tools/lib/erx/chokepoint_rules/device.rb`).
Like the source checks it extends, this one catches a slip between
trusted modules, not a module that builds the name from pieces outside
the driver applications and hands it in; what keeps a device from
other domains is that its capability is installed only in its driver's
domain.

**The block service.** The window processes are the driver's face to
every client, and together they are the block service: one window per
client and partition, or per client and EROFS image, each a grant whose
pid the system domain hands the client when it introduces the two domains
([design-system.md](design-system.md#creating-a-domain)), or which the
storage domain's own file system holds as a local pid. A read's blocks
travel to a client in another domain in the window's reply frame on the
client's connection, as a file server's reply does: the client's runtime
copies the frame out of its lane once, into its own memory, and the
storage domain supplies no memory beyond the lane the client's budget
paid for ([design-domains.md](design-domains.md#connections)). A client
in the driver's own domain receives the NIF's binary itself, with no copy
beyond the NIF's one. A window answers one request at a time per client in
order, so a client's own requests in flight bound what the service holds
for it, and a client that stops reading its lane blocks only its own
window.

**Where the driver runs.** The block device goes to exactly one domain,
named by the system configuration, whose creation gives it
([design-system.md](design-system.md#devices)): by default the storage
domain that serves the data partition, so the common case costs no connection;
on a board whose storage controller's DMA is unconfined, a domain of its
own, so the domain that parses a hostile data partition never holds a
device whose DMA reaches the whole machine. In both the driver is the same
application and a window is the same process; what differs is whether a
client's window pid is local or exported over a connection the system domain
created when it introduced the client's domain to the driver's
([design-domains.md](design-domains.md#connections)). The storage service, the
EROFS reader, the FAT server and the slot writer each send to a pid and
do not care which.

**Partitions are windows.** A client reaches only the sectors of the
windows the device service named for it, and the window checks every
request against them. The device service names the windows from the
medium layout of the ABI file and the system configuration's roles when
it gives the device, and again for each domain it introduces to the
driver's; the driver starts a window process for each and the pid reaches
the client as any grant does. Each file system runs in a domain that holds
a window on its own partition and nothing of the device, so a crafted file
system can damage only its own partition, and no domain that parses a file
system can write a slot or the boot-selection record of [System
updates](#system-updates) (PW1).

**The boot medium's table.** It is a master boot record laid out by the
medium layout of the ABI file:

| Entry | Partition | Read by |
| --- | --- | --- |
| 1 | the boot-selection record's partition | the firmware and the slot writer |
| 2, 3 | slot A, slot B | the firmware, and the slot writer, which alone writes them |
| 4 | an extended partition holding the two logical partitions below, each described by an extended boot record at a sector the layout fixes | the block driver, which reads exactly those two records |
| 4, first logical | the vault's partition | the vault's storage domain alone |
| 4, second logical | the data partition, last on the medium | the principals' storage domain |

The driver admits the table before it serves any window: it must equal
the layout entry for entry, but for the data partition's length, or the
driver serves none of it and reports the medium. It follows no chain of
extended boot records beyond the two, so no crafted table leads it
anywhere the layout does not name. That one length, and the extended
partition's with it, may be anything from the layout's minimum to the
medium's end, so one image fits media of every size and its installer may
give the data partition the whole rest of the medium.

**Removable media** have no fixed layout: the driver serves only primary
entries that lie within the medium and overlap no other entry it serves,
so no crafted table makes two windows share a sector.

**One source.** Where each partition lies, and each slot's signature
window (below), comes from the medium layout of the ABI file alone, which
the kernel, the packer, the QEMU harness and the device service share: the
device service derives the slot writer's windows from it, and the system
configuration assigns data, FAT and the vault's partitions to storage
domains by their role in it, never by sectors.

**What each format holds.** Three formats on the boot medium, and FAT for
exchange:

* The **boot image** (`ERXPACK`) holds everything the machine needs to
  boot: the kernel, the runtime images, the system release and the
  releases of the domains started at boot. The firmware loads it whole,
  and only the kernel parses it.
* **EROFS images** hold the read-only rest. Each release installed with
  the system that no boot needs lives in an image of its own, after the
  boot image in the slot. A domain whose release lives there starts from a
  small release in the boot image, holds a read-only window on that
  image's sectors alone, its hash tree included, and mounts it in its
  runtime's file layer, where the **EROFS reader** parses it
  ([Reading EROFS images](#reading-erofs-images)). The tree has
  dm-verity's on-disk format (version 1, SHA-256), and its root hash and
  salt come from the boot image, so the check happens where the blocks are
  consumed, no storage domain or driver is trusted with it, a block cannot
  change between its check and its use, and the reader parses only blocks
  that passed it. The device service names a window on an image only
  inside the slot that the boot value names, so when the boot value is
  `unknown` it names none, and that boot runs only the releases in the
  boot image. The system domain never loads code from an EROFS image
  ([design-live.md](design-live.md#invariants) V5).

  The packer writes each image with fsimg, the project's own tool
  ([references](#references)), a host tool at a pinned commit that
  `tools/erx build fsimg` builds for the host out of tree, refused at any
  other version and run as a subprocess by argument vector. The packer
  describes the image to fsimg as an mtree manifest, with no staging
  tree: each file with `uid=0 gid=0`, mode 0644 (0755 for a directory),
  its size, its SHA-256 digest and the path of its contents. It runs
  `fsimg cW -F erofs -R -e 0 -o cluster=4096 -o compression=none
  -o uuid=UUID`, which gives 4096-byte blocks (the same on every host,
  whatever its page size), every time fixed at 0, every file owned by
  root, no extended attributes (so a host's own attributes never reach an
  image or make two builds differ), no compression, a UUID that is a
  version 4 UUID derived from the SHA-256 of the image's sorted paths and
  file digests, and the same bytes for the same inputs (`-R`). The `W`
  of `cW` makes fsimg verify the staged image in a second worker before it
  publishes it, so a failed verification publishes nothing: that
  verification is the check every build makes of every image. The packer
  then computes the image's hash tree itself and writes it after the
  image; `make check-reproducible` compares the images' bytes across two
  builds. fsimg is BSD-2-Clause, never linked and never part of an image.
  The reader is erXos's own Erlang, written from the format's
  documentation and its MIT-licensed on-disk header, `erofs_fs.h`, never
  from Linux's GPL driver. The writer and the reader therefore share no
  code, so a misreading of the format on either side shows as a
  disagreement between them: fsimg's verification checks every image
  the packer writes against fsimg's own reading of the format, and the
  reader is checked against fsimg's images through its tests over
  fixture images and its fuzz target. No third implementation checks
  either. erXos's EROFS images need not be readable by Linux, and
  no Linux tool checks them. Images are uncompressed: the boards' media
  have room for uncompressed slots, an estimate that a
  decision gate of [plan.md](plan.md#decision-gates) checks against the
  slot images' sizes, and LZ4's decompressor, whose library is
  BSD-2-Clause, would join the per-byte primitives if they do not.
* The **data partition** holds what changes: the files of principals and
  services, in a read-write file system, and in each principal's own
  directory that principal's hot-loaded blobs and the overlays of its
  supervised specifications, so code loaded into a domain survives a
  reboot until a system update changes the release beneath it
  ([design-live.md](design-live.md#the-code-store)). The code of the
  system domain and of every specification of the system manifest
  becomes durable only inside a release, through a system update, and
  neither ever loads code from the data partition
  ([design-live.md](design-live.md#invariants) V5). A user
  domain may load code it reads from its own files, with its own
  authority and nobody else's.
* The **vault's partition** holds the vault's files, each principal's
  sealed keys and credential slots and the machine's keys, in erXos's
  F2FS, with littlefs as its stopgap as on the data partition, through a
  storage domain whose only client is the vault
  ([design-system.md](design-system.md#the-vault)).
* **FAT partitions** hold files to exchange with other machines: a
  removable medium's partition, or a partition that the system
  configuration gives the exchange role, such as a FAT image attached to a
  QEMU guest as a second disk. No boot and no update reads one. The
  slots' boot partitions are FAT too, for the firmware, but no domain
  parses them: only the slot writer holds their windows, and it writes
  slot images raw (PW1).

A medium holds the **boot-selection record**, two **slots**, the vault's
partition and the data partition. Each slot holds a system: a boot
image, the EROFS images whose root hashes that boot image carries, and in
its **manifest window**, a run of sectors that the medium layout of the
ABI file fixes inside the slot, the update manifest that the slot image
was installed from. The record names the **committed** slot `C` and is
rewritten only at a commit; the other slot is the **spare**. A **trial**
boots the spare once, by a one-shot request that the firmware clears as
the trial starts, so whatever ends a trial, the next boot is the
committed slot's. The update therefore has two states, and nothing else:

* **`normal(C)`**, the record with no trial request: the firmware boots
  `C`, and the spare may be written;
* **`trial(S)`**, the record together with the firmware's one-shot trial
  request for the spare `S`: the firmware boots `S` once, and the next
  boot returns to `C` unless the trial commits by rewriting the record to
  name `S`.

An update is **committed** when the record names its slot, and **failed**
when a trial of it has ended and the record still names `C`. Whether the
spare holds a complete system is recorded nowhere: it is the result of
checking the spare against the manifest in its manifest window, which the
update service repeats at each normal boot, so a spare whose write was
cut short is not bootable and needs no state of its own (U5).

The update path acts on two durable facts and the spare's own bytes:

* the **record**, which the slot writer reads from the medium;
* the **boot value**, `unknown`, `normal(slot)` or `trial(slot)`, which the
  firmware reports and the kernel passes on in the machine page; it is
  `unknown` on every platform without a trial request.

**Manifests.** The update service checks an update's signature over the
manifest's raw bytes before decoding them. The manifest binds the format
version, the platform, the build kind (development or release), the slot
image's size and its hash with the signature and manifest windows read as
zeros (below),
the boot image's build identifier, the EROFS images' root hashes, the
storage formats its release reads, and a security version that the running
system refuses to go below; a release system refuses a development image,
and every system refuses an update whose storage formats differ from its
own, since that update's trial could not read the partitions, and names an
installation as the way to it. The update service writes the manifest's
raw bytes into the spare's manifest window last, after the slot image,
so a spare holds a manifest only once every byte the manifest hashes is
written; a check of the spare verifies that manifest's signature, as at
install, and the slot image's hash with the signature and manifest
windows read as zeros. The signature is Ed25519, checked by the
small verifier of [Dependencies](design.md#dependencies) against the
public key that the running boot image carries:

* in a release build, the release key, whose custody belongs to the
  release process ([plan.md](plan.md#beyond-the-plan));
* in a development build, a development key that the build tree generates
  and keeps outside the repository. The host tool signs every update it
  sends through the host link with that key, so a spare is checked one
  way in every build, and the Raspberry Pi 5, which has no host link,
  updates over the network, signed with the same key.

**Trust in a boot, and rollback.** A manifest's signature guards what an
update writes; what guards a boot is the platform's trust root, which
decides how far the boot image, and with it the root hashes of the EROFS
images it carries, can be believed
([design-platforms.md](design-platforms.md#trust-in-the-boot)): on QEMU
`virt` the host; on a board with secure boot the firmware, which checks
the slot's boot image against the board's key before the kernel runs; on a
board without it nothing, so whoever writes the medium controls the
machine. On a board with secure boot, each slot also carries the board
owner's signature of its `boot.img`, which the packer makes on the owner's
host with a key it is given and never keeps
([design-platforms.md](design-platforms.md#trust-in-the-boot)). The
signature, `boot.sig`, lies in the slot's **signature window**, a run of
sectors that the medium layout of the ABI file fixes inside the slot,
holding the file's bytes at the fixed length its directory entry gives,
and the release process publishes the window as zeros. A release's
manifest hashes the slot image with the signature and manifest windows
read as zeros, so the
release key covers every byte of the slot but the windows, and the owner's
signing writes the window alone, which the board's firmware checks against
`boot.img` before the kernel runs. An update for such a board passes
through its owner, who signs the slot image the release process published
and sends it on; the update service checks the manifest's signature and
the slot image's hash with the window zeroed, and a slot image without a
valid signature fails the firmware's check at its trial, which falls back
to the committed slot. The rollback policy follows the same split. An
update never installs below the running system's security version, which
therefore rises only when an update commits, and a failed trial falls back
to the committed slot, which passed the same check when it was installed;
nothing on the boot path checks a version, so whoever can write the medium
can put back any image the trust root accepts, an older signed one
included. Refusing that at boot needs a monotonic counter that the
platform's trust root keeps and checks before the kernel runs, which
neither the Pi 4's firmware nor the Pi 5's documents offer; on a board
that offers one, the counter takes the committed slot's security version
at each commit, and the spare, which the next update overwrites, may lie
below it.

## Algorithms and behavior

### The SD host controller

`erx_blk_sd` drives one SD memory card through a controller with the
register set of the SD Host Controller Specification's version 3.00, on
the card protocol of the Physical Layer Specification. Its first mode
moves data by programmed I/O through the controller's data port at
default speed, and nothing below turns DMA on; a later mode moves data
through ADMA2 tables as
[design-device-dma.md](design-device-dma.md#the-three-descriptor-forms)
describes, when the controller's record carries DMA memory, which it
does on both kernels when the device tree the firmware hands over gives
EMMC2 a range ([design-device-tree.md](design-device-tree.md)), and the
controller's capabilities offer ADMA2.
The specifications are cited by version, section and printed page:
"Physical Layer" is the Physical Layer Simplified Specification,
version 9.10, and "Host Controller" the SD Host Controller Simplified
Specification, version 4.20, whose version 3.00 register set this
driver uses. Citations of the form `file:line` are to the sources
pinned under [References](#references): FreeBSD's SD stack, the board's
device tree and QEMU's model. Facts about the BCM2711's integration
that those do not give come from the clean-room facts record,
[research-sdhci-bcm2711.md](research-sdhci-bcm2711.md), cited by its
section. What none of them settles is marked *to be settled by the
board probe*, and [the board probe](#the-board-probe) below lists those
items.

**What it drives.**

* Signalling at 3.3 V only: no UHS-I mode and no switch to 1.8 V. The
  card's supply and its I/O voltage are regulators on the firmware's GPIO
  expander, lines 6 and 4, the second giving 1.8 V when high
  (`bcm2711-rpi-4-b.dts:26-48`; facts record, "The controller on the
  board"), and no domain reaches the firmware
  ([design-platforms.md](design-platforms.md#invariants), PL2), so the
  driver can neither power-cycle the card nor move its signalling. A card
  switched to 1.8 V stays there across CMD0, and only a power cycle
  returns it to 3.3 V (Physical Layer Figure 3-16, p.22). The
  controller's 1.8 V signalling enable in host control 2 is the only
  trace of such a switch the driver can read, and a reset for all clears
  it (Host Controller p.53), so the start sequence reads it
  before its reset and refuses, with one line saying the card needs a
  power cycle, a controller whose enable is set. A card left at 1.8 V
  behind a clear enable fails identification or its transfers with
  timeouts or CRC errors, and the refusal's line says the same. Whether
  the firmware ever leaves either is *to be settled by the board
  probe*.
* A 4-bit bus at default speed, at most 25 MHz (`SD_SDR12_MAX`,
  `mmcreg.h:531`). A card whose SCR does not offer the 4-bit bus is
  refused, so every path the driver runs is one its suites run. High
  speed is not offered; when it is, it needs both the host's capability,
  the capabilities register's high-speed bit (`SDHCI_CAN_DO_HISPD`,
  `sdhci.h:284`), as FreeBSD derives it (`sdhci.c:974-975`;
  `mmc.c:1536-1537`), and the card's, its SCR's version, command class
  10 and the switch function's answer.
* Cards whose CSD is structure 0, standard capacity, addressed in bytes,
  and structure 1, high and extended capacity, addressed in 512-byte
  blocks, admitted only as *Admitting a card* below
  allows. Any other structure, SDUC's included, is refused.
* One card, the boot medium, present for the machine's life. The tree
  marks the slot's card detect broken (`broken-cd`,
  `bcm2711-rpi-4-b.dts:194`), so the driver never reads the controller's
  card-detect state, and sets host control's card-detect test bits
  (`SDHCI_CTRL_CARD_DET`, `SDHCI_CTRL_FORCE_CARD`, `sdhci.h:172-173`) so
  the controller treats the card as inserted whatever its detect input
  says. Whether that input tracks the card on the Pi 4 is *to be settled
  by the board probe*; with the bits set, the driver does not depend on
  it.

**Registers.** `hw/svd/sdhci/sdhci.svd` describes the controller in
32-bit words, each named for the 8- and 16-bit registers it holds:
`dma_address` (`0x00`), `blksizecnt` (block size and count, `0x04`),
`arg` (`0x08`), `cmdtm` (transfer mode and command, `0x0C`), `resp0` to
`resp3` (`0x10` to `0x1C`), `data` (the buffer data port, `0x20`),
`present` (`0x24`), `control0` (host control 1, power, block gap and
wakeup, `0x28`), `control1` (clock control, timeout and software reset,
`0x2C`), `interrupt` (normal and error status, `0x30`), `irpt_mask`
(status enable, `0x34`), `irpt_en` (signal enable, `0x38`), `control2`
(Auto CMD12 error status and host control 2, `0x3C`), `capabilities`
(`0x40`), `adma_address` (`0x58`) and `slotisr_ver` (slot interrupt
status and host version, `0xFC`) (offsets, `sdhci.h:102-332`). The
controller takes 32-bit accesses only: a narrower register is changed by
reading its word, replacing its part and writing the word back (facts
record, "Register access: width and spacing", point 1;
`bcm2835_sdhci.c:431-563`). Writing the word at `0x0C` issues the
command, so the transfer mode is only ever written with its command, and
`blksizecnt` is written just before it (points 2 and 3). The device NIF
owns `dma_address`, `adma_address` and `cmdtm`: a programmed-I/O driver
never writes the first two, and the third only through
`erx_device:command/2` ([The write path](#data-model)). It owns the stop
at block gap and continue requests in `control0` always, and while an
ADMA2 transfer is in flight `blksizecnt` and the transfer's end in
`interrupt` and `irpt_mask` too
([design-device-dma.md](design-device-dma.md#register-ownership)). The driver keeps
the version 3.00 register set on a later controller: host version 4
enable and preset value enable stay clear, as the reset for all leaves
them (Host Controller p.96-100), so `0x00` stays the SDMA
address and `0x06` the 16-bit block count.

Two register writes that reach this controller family within two card
clock periods of each other can lose the first; the data port is exempt
(point 4). The driver takes the simplest rule the three projects of the
facts record use, U-Boot's: at least 6 us between any two writes other
than to `data`, at every clock, which is two periods of the 400 kHz
identification clock and a microsecond. One function,
`erx_blk_sd_regs:spaced/2`, makes every such write: it waits, spinning
on Erlang's monotonic clock, until 6 us have passed since the last write
it made, makes the one write the fun it is given makes, and returns the
time of this one in the register handle that the device process and
`erx_blk_write` pass along. `erx_blk_sd_regs:write/3` is `spaced/2`
around `erx_device:write/3`, and `erx_blk_write` passes it a fun around
`erx_device:command/2`, so the command is spaced like every other write
and named in `erx_blk_write` alone (U4). Whether the spacing is needed
above 400 kHz, where a shorter rule would save a few microseconds a
block, is *to be settled by the board probe* and measured by
`tools/erx bench blk`.

**The functional core.** Three pure parts, built and tested on the host:

* `erx_blk_sd_card`, the card: its identification as a state machine,
  `step(State, Event) -> {Actions, State}`, whose events are a response,
  a command timeout or an error and whose actions are the next step to
  issue, a line reset, a wait, a clock or bus change, the identified card
  or a refusal; and the parsers of what the card sends: R1 (card
  status), R2 (CID and CSD, 136 bits), R3 (OCR), R6 (relative card
  address), R7 (interface condition), CSD structures 0 and 1, the SCR,
  the 64-byte SD status, and the extension registers' General
  Information and Performance Enhancement register set. The controller
  stores a 136-bit response without its CRC, so its four response words
  hold the response's bits 127 to 8 in their bits 119 to 0, and the R2
  parser shifts them one byte before reading any field, as FreeBSD does
  (`sdhci.c:1899-1912`; facts record, "Issuing a command", step 8).
* `erx_blk_sd_host`, the controller: the decode of the `interrupt` word
  into a closed set of events (command complete, buffer read ready,
  buffer write ready, transfer complete, and each error bit), the
  divider, and one request's transfer as a state machine over those
  events.
* `erx_blk_write`'s SD builders, which make plans: an opaque `sd_plan()`
  holds one command's argument, its `cmdtm` word, its `blksizecnt`, its
  response type and its data phase, and only the builders make one.
  `sd_plan/1` admits an identification step only if the SD table lists
  its command and the step's data agrees with its row; the argument rule
  fixes CMD16's argument to 512 and lets CMD49 make only the cache rule's
  two one-byte writes, Flush Cache (byte 261) to 1 and Cache Enable (byte
  260) to 0, with MIO and the mask clear and the rest of the block zero.
  `sd_read_plan/3`, `sd_write_plan/3` and `sd_status_plan/1` are the only
  builders of CMD17 and CMD18, CMD24 and CMD25, and CMD13. `sd_issue/2`
  issues a plan and nothing else; `sd_feed/3` writes block `Index` of a
  write plan's own checked bytes to the data port and refuses an index
  outside the plan; and `sd_shape/1` gives the device process the
  plan's response and data phase, so the count it transfers is the
  plan's, never one it computes.

`erx_blk_sd` is the effect layer around them: register reads and writes,
the interrupt messages and the deadlines' timers.

**Issuing a command.** `erx_blk_write` issues every command the same way
(facts record, "Issuing a command"): it reads `present` and refuses with
`{device, inhibit}` when command inhibit is still set after 10 ms, or data inhibit for a
command that uses the data lines or answers with busy (`SDHCI_CMD_INHIBIT`,
`SDHCI_DAT_INHIBIT`, `sdhci.h:148-149`); it writes `interrupt`'s
one-to-clear bits, so no status an earlier command left before the
issue reaches this command (one it raises later still can, which no
source or probe has shown); for a data command it writes `blksizecnt`; it writes `arg`;
and it issues the `cmdtm` word with
`erx_device:command/2`: the transfer mode (block count enabled, multiple
blocks and Auto CMD12 for more than one block, the direction, DMA off)
and the command (index, response type, CRC and index checks as the type
requires, data present). The device process then gives each
`interrupt` word to the command's wait, `erx_blk_sd_host:command/1`,
which keeps two tracks as FreeBSD keeps `cmd_done` and `data_done`
(`sdhci.c:1878, 1921-1923, 2047, 2057-2059`): command complete, at
which the response is read; and the data track, transfer complete for
a command that answers with busy, such as CMD7, or a buffer event for
each data block, one for identification's commands and up to 511 for
the SDIO host's block-mode CMD53
([design-wifi.md](design-wifi.md#one-controller-core)), and then transfer
complete. The tracks advance in either
order, since a controller may raise transfer complete before command
complete (`sdhci.c:2026-2033`), and the command is answered once both
are done. An error bit fails the command before the rest of its word
acts, data error bits included where FreeBSD ignores them for a command
with neither data nor busy; that command's other data events are not
its own and are ignored, as FreeBSD ignores them (`sdhci.c:2242-2249`); any
other event out of its track's order fails the command, a buffer event
of a busy command included (`sdhci.c:2254-2260`). FreeBSD sources read
at `release/15.1.0`: `sys/dev/sdhci/sdhci.c` (SHA-256
`4551b7d7842dfb2ffcdc2a565686a6dad5d6aa74606abd9cdc647e98d29eb500`),
`sys/dev/sdhci/sdhci.h`
(`363ed505d9ec77603b1b0d46e689da80600e72ce5948d5b2efe70571059b2b78`)
and `sys/arm/broadcom/bcm2835/bcm2835_sdhci.c`
(`28c9af6fa2f549dbfc5bd239b0edd592da2df83833e021f76ff599826d8de56f`),
whose BCM2711 configuration carries no quirk (`bcm2835_sdhci.c:129-135`).

**The start sequence.** Every start and every restart runs it whole:

1. The device record, `erx_device:open/1` and `erx_irq_line:attach/2`
   on the record's line, which on the Pi 4 is shared and so joins the
   line's owner ([below](#the-sd-host-controller)); `control2` read and
   a set 1.8 V signalling enable refused. Then `present` is polled, for
   at most 1 s, until DAT0 reads high (`present` bit 20, Host Controller
   p.53-57): a card still programming holds DAT0 low (Physical Layer
   p.51), and the CMD0 below ends its programming and may destroy
   the data. A DAT0 still low after 1 s is past every bound the
   specification gives a card's busy; the start goes on and its line
   says so.
2. The controller's reset for all (`SDHCI_RESET_ALL`, `sdhci.h:200-201`),
   polled until the bit clears, for at most 100 ms (facts record,
   "Reset"). The reset also turns the controller's bus power and card
   clock off (the same section). A version below 3.00 in `slotisr_ver` is
   refused, and the base clock is read from `capabilities` (below).
3. Power: power control cleared, 3.3 V selected (`SDHCI_POWER_330`,
   `sdhci.h:179`), then written again with bus power on, which must read
   back as on, then a wait of 1 ms (facts record, "Power and signalling
   voltage"; FreeBSD's waits, `mmc.c:659-684`). A 1-bit bus at normal
   speed and the card-detect test bits in `control0`; the card clock at
   400 kHz, never below the SoC's 200 kHz floor (facts record, "Quirks of
   the BCM2711 integration"), set as the controller's clock below
   describes, then a wait of 2 ms before the first command; the data
   timeout counter at `0xE`, its largest valid value, 2^27 periods of
   the timeout clock, since `0xF` is reserved (Host Controller
   p.73); and one mask of every normal and error status written to both
   `irpt_mask` and `irpt_en` (facts record, "Interrupts"): the statuses
   the transfer acts on, command complete, the buffer events, transfer
   complete and every error. Block gap, DMA and card insertion and removal
   stay disabled, since the driver arms no DMA and forces the card present,
   and card interrupt, INT_A to INT_C and re-tuning follow their sources
   and cannot be cleared (Host Controller 2.2.18, p.76-81).
4. The card's identification, in FreeBSD's order (`mmc.c:2052-2108`):
   CMD0, then a wait of 1 ms (`mmc.c:563-585`); CMD8 with `0x1AA`, supply
   2.7 to 3.6 V and check pattern `0xAA` (`mmc.c:642-656`; Physical
   Layer 4.3.13, p.90), where an R7 that echoes the argument marks a
   card that may be high capacity, a command timeout a card that is
   standard capacity (*The expected timeout* below),
   and any other answer a refusal; ACMD41, as CMD55 with argument 0 then
   ACMD41, with argument 0, which asks the card's voltage window without
   starting its initialisation (Physical Layer 4.2.3.1, p.45), and a
   window without 3.2 to 3.4 V (`MMC_OCR_320_330`, `MMC_OCR_330_340`,
   `mmcreg.h:638-639`) refused; CMD0 and CMD8 again; then ACMD41
   offering 3.2 to 3.4 V and, after an echoed CMD8, high capacity
   (`MMC_OCR_CCS`, `mmcreg.h:649`), repeated every 10 ms until the
   answer's busy bit says ready (`MMC_OCR_CARD_BUSY`, `mmcreg.h:650`),
   for at most FreeBSD's 1000 tries (`mmc.c:598-607`), above the
   specification's 1 s for a card's initialisation (Physical Layer
   4.2.3, p.43). The answer's capacity bit, valid once the busy bit is
   set (p.45), chooses the addressing. ACMD41's argument leaves XPC
   clear, so an extended-capacity card limits itself to 0.36 W and may
   report speed class 0 (p.45); the driver asks no more of it.
5. CMD2, whose CID goes only to `info/0`'s detail; CMD3, whose R6 gives
   the card's address; CMD9, whose CSD the card's admission below reads
   with the OCR; CMD7, selecting the card, whose R1 must not say the card
   is locked (bit 25, Physical Layer Table 4-42, p.120-122), since the
   driver offers no CMD42 to unlock it; CMD16 with 512 on a
   standard-capacity card (`mmc.c:1918`; Physical Layer 4.3.2, p.52);
   ACMD51, the 8-byte SCR, read through the data port; and ACMD6 with
   argument 2, the 4-bit bus, then the 4-bit bit in `control0` (facts
   record, "Card initialisation", steps 14 and 17), and the card clock at
   default speed, at most 25 MHz.
6. The card's cache turned off, as *The card's cache* below
   describes.
7. One line in the log: the card's type, capacity, bus width and clock.

The sequence begins with CMD0 whatever an earlier stage left, as
FreeBSD's discovery does (`mmc.c:2052`), so it is the same whether the
firmware, an earlier device process or nothing touched the card. CMD0
returns a card to the idle state from every state but the inactive one
(Physical Layer p.41; Figure 4-1, p.42), a card left selected or
in the middle of a transfer included, which the recovery test on the
model checks. A card in the inactive state, where a supply outside its
range puts it, ignores CMD0 until it is power-cycled, which the driver
cannot do, so it fails identification and stays refused. A refusal at
any step ends the start with one line and no device process: `init/1`
returns `ignore`, so the boot goes on, as with a virtio device that
fails its start.

**The expected timeout.** A card of the Physical Layer's version 1.x
does not know CMD8 and does not answer it, and neither does a card that
does not take the offered supply (Physical Layer 4.3.13, p.90), so a
command timeout on CMD8 is the one timeout in the protocol that is an
answer, not a failure. It is a transition of `erx_blk_sd_card` like any
other: in the state that issued CMD8, the event `timeout` returns the
actions `{reset, cmd}`, `{reset, dat}` and the next step, CMD55 of the
inquiry ACMD41. The controller needs the resets: a command timeout is
a response error (Host Controller p.30), and from version 4.10
the controller holds command inhibit set after one until its software
reset for the command line (p.28), so the next command could not issue.
The device process performs each reset as it performs the reset for
all, the bit set in `control1` and polled until it clears for at most
100 ms (`SDHCI_RESET_CMD`, `SDHCI_RESET_DATA`, `sdhci.h:202-203`;
`sdhci.c:1294-1306`), command line first, then data line, as FreeBSD
resets both after every command error (`sdhci.c:1892-1893`) and the
specification's recovery orders them (Host Controller 3.10.1,
p.184-186). A card that did not know CMD8 reports it as an illegal
command in the next R1, CMD55's, since that bit belongs to the previous
command (Physical Layer 4.6.1, p.95; Table 4-42's clear condition B,
p.120), so that one R1's illegal-command bit is not an error. Every
other timeout, CMD8's in any other state and every timeout outside
identification, is an error that fails the start or the request as
[Failure](#the-sd-host-controller) below describes; a reset that does
not clear within its bound fails the start.

**Admitting a card.** The OCR's capacity bit chooses the addressing and
the CSD gives the capacity, so the card's admission, a pure function of
the two, requires that they agree and that the capacity it reports is
one the addressing reaches:

* structure 0 with the capacity bit clear, standard capacity addressed in
  bytes, and structure 1 with it set, addressed in 512-byte blocks;
  either other pairing is refused;
* on structure 0, `READ_BL_LEN` of 9, 10 or 11, the only block lengths
  the specification defines (Physical Layer Table 5-8, p.228), and the
  capacity `(C_SIZE + 1) * 2^(C_SIZE_MULT + 2) * 2^READ_BL_LEN` bytes
  (p.229);
* on structure 1, `READ_BL_LEN` of 9, which the structure fixes, and the
  capacity `(C_SIZE + 1) * 512 KiB` from the 22-bit `C_SIZE` of bits 69
  to 48 (Physical Layer 5.3.3, p.233-235).

These bounds are what make every address the driver sends fit the
command's 32-bit argument, so no other check is needed: structure 0's
largest coded capacity is 4096 * 512 * 2048 bytes, 4 GiB, so its last
sector's byte address is below 2^32, and structure 1's is 2^22 * 1024
sectors, 2^32, so its last sector's number is below 2^32. Every capacity
the rule admits is a whole number of 512-byte sectors, since each block
length is a multiple of 512. `info/0` reports the capacity in sectors,
`(capacity in bytes) / 512`.

**The card's cache.** A card may keep written data in a volatile cache,
which is off until a host turns it on (Physical Layer 3.12, p.30;
4.17, p.179), and the specification does not say whether CMD0 or a
power cycle turns it off. The start therefore establishes it itself, on
every start: after the 4-bit bus, ACMD13 reads the 64-byte SD status,
whose bit 330 says the card supports a cache (Physical Layer 4.10.2.14,
Table 4.10.2-2, p.133), and the SCR's bit 34 says whether it takes CMD48
and CMD49, the reads and writes of its extension registers (Table 5-23,
p.245). A card with neither has no cache the driver can reach, and the
start goes on. A card with the cache bit set must take CMD48 and CMD49,
and a card without them is refused. On a card with both, CMD48 reads the
General Information at function 0, page 0 (Physical Layer 5.7.3,
p.256-257; the command, 5.7.2.1, p.247), whose list of extensions,
parsed within the length its header gives and at most 1024 bytes, names
the Performance Enhancement function by its standard function code
`0002h` (Table 5-27, p.261) and its register set's address. CMD48 then
reads that register set, whose byte 260 holds Cache Enable in bit 0
(Table 5-30, p.268-269). With the bit set, the start writes Flush Cache,
byte 261 bit 0, with CMD49 (5.7.2.2, p.249), waits for DAT0 to rise,
reads byte 261 with CMD48 until the card clears the bit, for at most the
1 s the specification gives a flush (4.17, p.179), writes Cache Enable
0 with CMD49, and reads byte 260 back: a card whose cache still reads
enabled is refused. A General Information that names no Performance
Enhancement function, or that does not parse, is refused on a card whose
cache bit is set. So every card the driver writes to has its cache off,
whatever an earlier system did, and a write the card has finished
programming is on the medium.

**The controller's clock.** The tree gives EMMC2 the SoC clock manager's
EMMC2 clock, `<&clocks BCM2711_CLOCK_EMMC2>`, with no frequency
(`bcm2711.dtsi:426-432`), and the firmware, which sets the rate, is
reached only by the kernel (PL2). The projects disagree on the divider's
input (facts record, "Clocks"): Linux takes the clock framework's rate,
U-Boot the firmware's, and FreeBSD, for EMMC2, the base-clock field of
the capabilities register, since the firmware rate it asks for
(`bcm2835_sdhci.c:244-257`) goes only into a capability word its SDHCI
core reads under `SDHCI_QUIRK_MISSING_CAPS`, which EMMC2's configuration
does not set (`bcm2835_sdhci.c:129-135, 312-318`; `sdhci.c:886-916`).
The device process takes FreeBSD's one source, bits 15 to 8 of
`capabilities` in MHz (`SDHCI_CLOCK_V3_BASE_MASK`, `sdhci.h:278`), read
at every start. A field of zero means the platform supplies the rate by
another means (Host Controller p.110), and the device process
then takes the `clock` of the SD unit's entry in the platform record,
as the UART entries carry one, and refuses the controller if the entry
has none, rather than guess as FreeBSD does (`sdhci.c:922-927`). Whether
the field is right is *to be settled by the board probe*: the probe
reads a fixed number of blocks at the 400 kHz identification clock on a
1-bit bus, where the time on the bus dominates, times them with the
generic timer, and compares the time with the one the field predicts. If
they disagree, the entry carries a `clock`, which the device process
then takes in place of the field. The divider is SDHCI 3.00's 10-bit
divided clock: the base clock itself when the target is at least the
base, otherwise the smallest even divisor up to 2046 whose quotient is
at most the target, written as half the divisor, its low 8 bits in bits
15 to 8 of the clock control and its high 2 bits in bits 7 and 6
(`sdhci.c:463-484`; `sdhci.h:186-190`; Host Controller p.68-69).
A clock change stops the card clock, writes the divider, enables the
internal clock, polls it stable for at most the 150 ms the
specification gives the loop (Host Controller 3.2.1, p.153-154; 3.2.3,
p.155), and starts the card clock (facts record, "Clocks";
`sdhci.c:487-497`).

**Reads and writes.** The device process runs one request at a time. A
read is CMD17 for one sector and CMD18 for more; a write is CMD24 or
CMD25; the argument is the sector, times 512 on a standard-capacity card,
and Auto CMD12 ends a transfer of more than one block, as FreeBSD builds
the transfer mode (`sdhci.c:1730-1743`) on a controller whose
configuration has none of the quirks that turn Auto CMD12 off
(`bcm2835_sdhci.c:129-135`). The R1 errors are the bits the
specification types as errors: 31 to 26, 24 to 19, 16, 15 and 3
(Physical Layer Table 4-42, p.120-122). At command complete the device
process checks the R1; at each buffer-ready event it moves one block,
128 words with the first byte in the low byte of the first word, through
`data` (facts record, "PIO data transfer"); at transfer complete the data
phase is done, and on a transfer of more than one block the device
process checks the R1 of Auto CMD12, which the controller leaves in
`resp3` (Host Controller p.48). A read by CMD18 that ends at the
card's last sector may report out of range there, which the host is to
ignore (Physical Layer 4.3.3, p.52), so that bit alone, on that read
alone, is not an error. FreeBSD finishes a data command and a command
with busy alike at transfer complete (`sdhci.c:1932, 2243, 2326-2331`),
so a write's transfer complete follows the card's release of busy, the
end of its programming (Physical Layer p.51; Host Controller
p.57, p.79). A write then issues CMD13, which the controller takes
while the data lines are busy (Host Controller p.58), and answers `ok`
only if its R1 has no error bit and the card is in the transfer state
and ready for data (`mmcreg.h:145, 155`; Physical Layer p.54),
so an error the card reports after programming fails that write and not
the next request; FreeBSD answers at transfer complete
(`mmcsd.c:1162-1233`). A flush is the same CMD13 alone: every write
before it has already waited for its programming, and the start turned
the card's cache off (*The card's cache* above), so a programmed write
is durable. FreeBSD turns a cache on only on eMMC cards, never on SD
(`mmcsd.c:304-318, 1510-1531`), and the driver turns none on.

**Deadlines and interrupts.** A request keeps the transport contract's
wait limit and in-flight bound ([Data model](#data-model)) with one
timer. Each command of the start sequence and its data has a deadline
of 1 s, above the 100 ms the specification gives a read and the 250 ms
it gives a card's busy (Physical Layer 4.6.2.1, 4.6.2.2, p.95); the
cache flush its 1 s (4.17, p.179); and ACMD41's loop its count. An
interrupt is handled as on virtio: the device process reads `interrupt`
once; a word of zero or of all ones is not this controller's (facts
record, "Interrupts"), and it answers the line as done with nothing
handed on; otherwise it writes back the bits of the word that are
cleared by writing ones (`erx_blk_sd_host:ack_mask/0`, every
one-to-clear field of INTERRUPT in the SVD source), acknowledges with
`erx_irq_line:ack/1` and hands the word to the transfer's state
machine. An event with no request in flight is dropped.

**The SD controller's line.** On the Raspberry Pi 4, EMMC2 shares its
interrupt line with the SoC's legacy SD controller, `&sdhci`
(`bcm2711.dtsi:429, 1147-1149`), so by the unit rule the two are one
unit, given whole to the storage domain
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)),
and the record marks the line shared. The device process attaches through
the line's owner, `erx_irq_line`, of which it is the one member, as every
driver on a shared line does
([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain)).
The legacy controller's driver, the SDIO host `erx_sdio_host`, which
serves the WiFi card to the WiFi domain, never joins the line: it holds
the controller's signal enable, `irpt_en`, at zero and polls, so the
legacy controller never raises the line and no round waits on a WiFi
transfer
([design-wifi.md](design-wifi.md#transactions-and-the-card-interrupt-are-polled)).
`erx_blk_sup` starts the owner before the device process, `rest_for_one`,
from `erx_irq_line:owners/1` over the records, and the SDIO host's
supervisor after them as a `temporary` child, so the SDIO host's end
never ends the storage domain and, since it never signalled, leaves
nothing on the line. A delivery is a hint to look, and the device
process answers a round whose `interrupt` is empty done.

**Failure.** Outside the expected timeout above, any error bit in
`interrupt`, an error bit in an R1, an inhibit that does not clear, a
card not ready after a write, a missed in-flight bound or step deadline
or a response that disagrees answers the request in flight
`{error, {device, Detail}}`, and every request in the backlog the same;
the device process ends with one line naming the step and the bits.
`erx_blk_sup` restarts nothing, so its end ends the storage domain, and
the domain service restarts the domain within its row's intensity
([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)),
whose new device process runs the start sequence: it waits for a card
still programming, its reset for all brings the controller back from
whatever state the error left, its CMD0 returns the card to idle, and
littlefs mounts `/data` afresh. FreeBSD and Linux reset the
controller's command and data lines in place after an operational error
(`sdhci.c:1892-1893, 2052-2053`; facts record, "Error recovery"); the
driver does not, because the start sequence covers every state those
resets cover and more, so there is one recovery path for errors and no
recovery state. Its cost is the storage domain's restart and a card
identification, at worst the ACMD41 bound, after an error a healthy
card makes rarely. A write that fails leaves its sectors unknown, as an
unacknowledged write does for the file system above.

#### The board probe

Before the board pass counts, the probe reads and records, with no
command sent to the card, the items the facts record leaves to the board
("What only the board can settle"): the host controller version and both
capabilities words (base clock, timeout clock, voltages, high speed,
SDMA, ADMA2, 64-bit, UHS); the state the firmware leaves in power
control, clock control, host control 1 and 2 and present state, the
1.8 V signalling enable and DAT0's level above all; and whether present
state's card-inserted bits follow the card. It then reads the card's
Performance Enhancement register set as the firmware left it and again
after a CMD0, recording whether Cache Enable is set in either; issues
CMD8 offering a supply the card does not take (Physical Layer 4.3.13,
p.90), so that it times out, and records command inhibit before and
after the software reset for the command line; runs the start sequence
on the card as the firmware left it, and again after a restart in the
middle of a write; times the slow read that settles the base clock; and
runs the card at 25 MHz with the 6 us spacing and once without it,
verifying every block read against what was written; and records whether
anything else answers inside EMMC2's 4 KiB page. The SoC's core clock,
the firmware's expander calls and the `dma-ranges` the firmware passes
are recorded for DMA (the root prints the range it read, [design-device-tree.md](design-device-tree.md#facts-into-records)) and for a driver that would power-cycle
the card, which this one never does. The probe's results go into the
board pass's research record, and a result that contradicts this
section is a change to it before the board pass counts.

### Reading EROFS images

The EROFS reader, `erx_erofs`, is Erlang, preloaded in the runtime image
beside `prim_file`, so every domain has it and reads code from an EROFS
image as early as from its release slice, without a release having to
carry it. `erx_path` resolves a path to an EROFS mount, an entry whose
provider is `{erofs, Image}`, with the reader answering its walks and
link reads; the reader then serves the operation of the resolver's last
action in the calling process, as `erx_file_remote` serves a grant
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)),
so a slow read delays only its caller and reads of one image run in
parallel.

1. **Mounting.** The runtime opens the image's window inside the
   hash-checking reader, `erx_verity`, with the pid of the block service's
   window on the image and the root hash, salt and tree layout that the
   boot image records, which arrive with the domain's other grants at its
   creation ([design-system.md](design-system.md#creating-a-domain)), and
   the reader reads block 0 through it. It checks the superblock's magic, its
   4 KiB block size, and its incompatible feature bits, and refuses an
   image with a feature it does not implement, naming the bits; with the
   superblock-checksum feature it checks the CRC-32C with the primitive.
   It implements compact and extended inodes, the plain and inline data
   layouts, directories, symbolic links and no compression, the layouts
   the packer's options produce.
2. **Walking.** For each name it reads the directory's inode, then its
   blocks: each block holds directory entries sorted by name, so a binary
   search over the blocks' first names and then within the block finds
   the name in O(log b) block reads for a directory of b blocks. A walk is
   a loop over the path's names, at most 256, and recurses nowhere; a
   symbolic link ends it, and the client resolves the link's text through
   its own namespace, as for every provider
   ([design-files.md](design-files.md#resolving-a-path)).
3. **Reading.** A file's data blocks come from `erx_verity:read(Image,
   Block, Count)`, at most 16 blocks a call, as binaries in the domain's
   memory that matched the tree (E1). `erx_verity` is Erlang running in
   the calling process: it answers from its cache when it holds every
   block it needs, checked; otherwise it sends the reads to the image's
   window at the block service, waits for the reply, which arrives as a
   message, and hands each block with its tree blocks to
   `erx_verity:check/3`, the runtime's pure check of a supplied block
   against the tree with the SHA-256 primitive
   ([design-runtime.md](design-runtime.md#per-byte-primitives)); it keeps
   the tree's blocks in its cache and returns the data blocks, or
   `{error, eio}`. Only the caller waits, in Erlang, so no scheduler
   blocks and no unchecked byte reaches the reader. Whole-file reads
   return the joined binary; positioned reads return the requested range.
4. **Caching.** Verified metadata blocks (the superblock, inode and
   directory blocks) are kept in an ETS table per image, at most 256 of
   them (1 MiB, a default), evicting the oldest first. An image never
   changes, so the cache is always coherent, and a miss costs one checked
   read.

Every structure is decoded by binary matching with checked bounds: an
inode number, an offset or a size that points outside the image, a
directory entry whose name runs past its block, or a name over 255 bytes
fails the operation with `{error, eio}` and a log line naming the image
and the block, inside the reader's own `try`, so a malformed image fails
the operation, not the caller. An image that passed its tree is what the
packer wrote; the checks are there because the reader's fuzz target feeds
it images that did not.

Every domain that mounts an image reads and checks its blocks for itself:
N domains over one image hold N copies of the blocks they use and hash
them N times, which is the price of trusting no storage domain with a
release's integrity (ST-R1). The block service is in the storage domain,
which needs no EROFS image to start: the system release and the small
release every domain starts from live in the boot image, whose slices
the kernel maps, so the boot path reads no block through the service and
nothing the service serves is needed to reach it.

A block read through the service costs one connection round trip to the
window, two copies of the blocks (into the window's lane and out of it at
the client) and the SHA-256 of each block in the client; `erx_verity`
asks for up to 16 blocks a call, so a 64 KiB read pays the round trip
once ([Performance](#performance)).

### Read-write storage

Read-write storage is F2FS, implemented by erXos in Erlang from its
on-disk format. littlefs is the current implementation behind the same
file interface, a stopgap whose limits on large media (files of at most
2 GiB, a design for microcontrollers) are accepted for it. erXos's F2FS:

* **Structure.** An Erlang application in the storage domain: a callback
  module of `erx_fs`, so every grant and every open file is a process of
  its own ([design-files.md](design-files.md#serving-the-erx_fs-behaviour));
  a volume process that owns the checkpoint, the node address table, the
  segment information and the current segments, and orders every update
  to them; a cleaner process; and the block client, `erx_block_client`,
  which sends to the volume's window pid and receives completions as
  messages. The
  format's decisions (where a block goes, what a checkpoint holds, which
  segment the cleaner takes) are pure functions over the volume's state,
  and the volume process applies their results as block writes and
  flushes, so the core is tested on the host without a medium. Checkpoints
  and other checksummed structures use F2FS's CRC-32, which ERTS's own
  `erlang:crc32/2` computes once its seed and result are inverted, since
  zlib's convention inverts both and Linux's does not.
* **Clean room.** Linux's F2FS is GPL-2.0, and none of its code enters the
  tree. One author writes a specification of the format and of the
  cleaner's policies, in erXos's words, from Linux's documentation and
  sources, and implements none of it; the implementers work from that
  specification and the ABI file alone. Implementers that are models
  trained on public code, Linux's included, weaken the separation. A legal
  review of the clean room weighs this, and the user requires that review
  before any distribution includes erXos's F2FS.
* **Linux as the oracle.** Linux's F2FS driver and `fsck.f2fs`, run in a
  Linux guest under QEMU on the host, check every image erXos's F2FS writes
  and every state the power-cut harness produces, and the guest mounts
  erXos's images for differential tests of file semantics.
* **Explicit features.** It mounts only images whose superblock feature
  bits it implements, and refuses the rest with a diagnostic naming them.
  The design refuses `ENCRYPT`, `COMPRESSION` and `ATOMIC_WRITE` among
  them: an image that carries any of the three is not mounted, read-only
  or otherwise, and erXos's F2FS never sets them.
* **Power cuts, proven.** A host harness runs the file system's core on
  the host's stock OTP over a simulated medium that records every write,
  cuts power after every write and reorders the writes between flushes;
  every resulting state must mount at the last completed checkpoint, with
  every acknowledged `fsync` recovered, and pass `fsck.f2fs`.
* **Hostile media.** An image is untrusted input: every structure is
  decoded by binary matching with checked bounds and has a fuzz target,
  run on the host's stock OTP. F2FS checksums its checkpoints and, with
  the matching features, its superblock and inodes; file data carries a
  checksum only in files made read-only under its verity feature. A
  checksum catches corruption, not a crafted image, so a crafted data
  partition can make its file system's process fail, which its supervisor
  restarts, serve wrong data from that partition or damage it, and nothing
  more: Erlang code cannot write outside its own heap.
* **The cleaner**, which reclaims segments, is the hard part; the
  specification describes the policies it implements.
* **Parity.** It replaces littlefs only at parity over the file-semantics
  test corpus, as every stopgap's replacement does.

In Phase 1 littlefs instead runs as a NIF in the storage domain, behind the
same `erx_fs` interface; its design is the littlefs section of
[design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain), and
the port below is the target.

**littlefs, the stopgap**, runs in the same storage domain behind the same
`erx_fs` interface, as a **sub-space port** of the storage domain, with
the shape of a program
([design-programs.md](design-programs.md#a-program-is-a-port)):
single-threaded C under `liberx`, in a sub-space that holds its channel, a
data area the storage domain maps into it, and nothing else. One owner
process of the storage domain holds the port and sends it the volume's
operations as terms on the channel; littlefs's block callbacks become
requests back on the channel, which the owner sends to the volume's
window, and the bytes of both directions move through the data area. So
littlefs's C code holds no window and no device, a crash in it ends the
port and not the domain that runs the block driver, and the owner's
supervisor restarts the port, which mounts the volume afresh. The storage
domain is therefore one Erlang release whatever file system it serves, and
replacing littlefs changes one callback module. littlefs writes a file's
data to the medium only at the file's sync or close (`lfs.h`), so a
client's `fsync` is `lfs_file_sync` on that file followed by a flush of
the medium, and a checkpoint syncs every file open in the volume and then
flushes ([Interfaces](#interfaces)). The one owner runs the volume's
operations one at a time, whichever client asked, so under littlefs a
request waits for the volume's queue, which each client's grant bounds by
its requests in flight and its fid pool; erXos's F2FS, whose open files
have owners of their own, has no such queue. A port that crashes
mid-operation leaves the operation's outcome unknown, as its protocol
specifies; writes it had already sent to the window complete or fail at
the window as any write does, and the owner mounts the volume again only
after the window has answered every request the port had outstanding, so
no newer write races an older one. littlefs states that it has no
unbounded recursion ([research](research-boards-storage.md#file-systems)).
littlefs keeps no links and no device nodes, so its callback module
answers `symlink`, `link` and `mknod` with `eperm`.

**A mount never formats.** Only installation makes a volume. The step
that writes a medium formats its data partition once, with the in-tree
littlefs built for the development host (`tools/host/lfs_format.c`, with
the geometry the guest mounts with, `erx_littlefs.h`), and places the
volume's first blocks at the partition's start; every other block of a
fresh volume is zeros. The release medium, the test suites' media and the
website's disk are all written this way. The guest has no format
operation: a mount that finds no volume, or a volume whose metadata fails
its checks, fails with `eintegrity`, writes nothing and ends the storage
domain. The domain service restarts the domain within its row's restart
intensity, each restart's mount fails the same way, and the domain then
stays ended with its death record. The files stay on the medium for a
repair, and a corrupt volume never comes back as an empty `/data`.

**Shared mappings.** A file that programs map shared is served by their
session, which fills its own object with ordinary reads and writes it
back with ordinary writes
([design-files.md](design-files.md#shared-mappings)), so a storage service
sees a mapped file only as reads and writes, and erXos's F2FS, littlefs
and FAT need nothing of their own for it. A write-back is an ordinary
write, so the power-cut harness's rule covers it: an `fsync` or `msync`
that returned is recovered.

**Accounting.** The storage services account per client for space and
admit per client for work. Each principal has a quota and a reserve on the
data partition, so no domain can fill the partition for others. A storage
service runs on its own group's grant, sized by policy for the domains it
serves ([design-system.md](design-system.md#resource-policy)); what it
spends for one client is bounded by that client's grant process, its heap
limit, its fid pool and its requests in flight, and by the client's lane,
which a flooding client fills and then waits on in its own runtime.
Per-client CPU is a statistic the service's processes report to the
inspector, not an enforcement.

**File identity and version.** A file's identity is its server's domain,
its tree and its qid path, and its version is `getattr`'s
`data_version`, which the server draws from its domain's one counter
when it first meets a file and at every change to it
([design-files.md](design-files.md#identity-and-version)). Every server
keeps qid paths unique within a tree and never gives a path to a second
file while its domain lives. The path depends on what the format offers:

* **erXos's F2FS**: the inode's node number in the low 32 bits and its
  `i_generation` in the high 32, so a node number the volume reuses for
  another file makes another path.
* **EROFS**, served through a domain's export: the inode's number; an
  image never changes, so a file's version changes only when the export
  first meets it.
* **littlefs and FAT**, which keep no stable file numbers: a path drawn,
  the first time the server meets a file, from a counter of the domain's
  runtime, kept across the server's restarts as the version counter is,
  so no path is drawn twice while the domain lives. The server keeps the
  path in a table keyed by where the file's entry lies (littlefs's
  metadata pair and id, FAT's directory cluster and index), which a
  rename or a move of the entry updates, for as long as any fid names
  the file, and so as long as any session maps it, since a mapping's
  open holds fids ([design-files.md](design-files.md#shared-mappings)).
  The table holds at most 65,536 entries and never evicts one: when it
  is full, a walk or a create that would add an entry fails with
  `enfile`. A file that no fid names leaves the table, so a file closed
  and opened again may get a new path, which costs a client's cache a
  miss: a documented limitation of these formats, which store no file
  numbers.

So `cc -o t t.c && ./t`, run twice within one FAT timestamp's two seconds,
runs the second build: its write drew a new version, which no file object
of the first build's matches.

### Removable media: FAT

The **FAT server**, `erx_fat`, serves one FAT partition as files, in a
storage domain of its own that holds only that partition's window (PW1),
as an `erx_fs` callback module. It reads FAT12, FAT16
and FAT32 as Microsoft's specification describes them, the type following
from the volume's count of clusters, with long names, and writes FAT16 and
FAT32, mounting FAT12 read-only (Durability, below); exFAT is not
designed. It maps the format onto the file protocol as follows:

* **Names.** A long name is UTF-16 on the medium and UTF-8 in the
  protocol; the server converts between them and refuses with `einval` a
  name holding a character the specification forbids in long names (`"`,
  `*`, `/`, `:`, `<`, `>`, `?`, `\`, `|` and the controls below 0x20), and
  a name that starts or ends with a space or ends with a period, which the
  specification has readers ignore. FAT matches names without regard to
  case, as Windows does: the server compares long names after mapping each
  UTF-16 code unit of the Basic Multilingual Plane to its simple uppercase
  form, from a case table generated from one pinned version of Unicode's
  character database, and leaves each code unit of a surrogate pair as it
  is. So a name that differs from an existing one only in the case of a
  letter of that plane, accented ones included, is the same name, while
  names that differ only in the case of a letter beyond it, such as
  Deseret's, are different names; the server refuses an `lcreate` or
  `mkdir` that matches an existing name with `eexist`, and reports each
  name as stored. A short name is decoded as code page 437, the IBM PC's
  original OEM code page, which maps every byte to one character, so every
  short name has a UTF-8 form. A name that would need more than 255 bytes
  of UTF-8, or that is not valid UTF-16, is listed and walked under its
  short name. Every file the server creates gets a short name too,
  generated as the specification describes from ASCII letters, digits and
  the symbols it allows, so other systems that read only short names find
  it under the same name in every OEM code page.
* **Attributes.** FAT has no owners and no permission bits: a file reports
  mode `0644`, or `0444` with the read-only attribute, and a directory
  `0755`; `setattr` of `mode` sets the read-only attribute exactly when the
  owner's write bit is clear and changes nothing else. Times are read and
  written as UTC, with the modification time's two-second resolution. A
  file holds at most 4 GiB less one byte, and a write beyond fails with
  `efbig`; a directory holds at most 65,536 entries, as the specification
  bounds it, and an `lcreate` or `mkdir` beyond fails with `enospc`.
  There are no symbolic links, hard links, device nodes or extended
  attributes: `symlink` and `link` fail with `enotsup` (FreeBSD's `EOPNOTSUPP`,
  the same number) and `mknod` with `einval`, as FreeBSD's `msdosfs`
  answers them, and `xattrcreate`
  with `enotsup`.
* **Durability.** FAT keeps no journal, so the server orders its writes
  with flushes, which the block driver passes to the medium, and relies on
  a sector being written whole, which a medium that tears a write breaks
  ([Risks and open questions](#risks-and-open-questions)). Before the
  first change after a mount, it sets the volume's dirty flag, which FAT16
  and FAT32 carry in the FAT's second entry, and flushes. It then commits
  changes in **batches**, at `fsync`, at unmount and every 5 s while
  changes wait, each batch in five steps with a flush after each, so no
  write of a step reaches the medium before every write of the steps
  before it:
  1. **Data**: the files' data, and every cluster that grows a directory
     or holds a new directory's first entries, written whole with its
     entries or zeroes.
  2. **Allocation**: the FAT entries of every cluster the batch
     allocates, each new run written whole as a chain of its own that
     ends in an end-of-chain mark, which no name and no live chain
     reaches yet.
  3. **Removal**: the directory entries that remove names.
  4. **Publication**: what makes the new runs reachable and cuts the old
     ones: the FAT entry that links a file's old last cluster to its new
     run, the directory entries that add or change names, a renamed
     file's new entry among them, and the end-of-chain marks that cut a
     shrinking file's chain.
  5. **Release**: the FAT entries that free clusters, which since step 4
     no live chain and no name reaches.

  Each FAT entry goes to every copy of the FAT in the same step, the first
  copy first. A cluster freed in a batch is allocated again only in a
  following batch, after this batch's last flush, so a cut before the
  frees reach the medium leaves every old entry naming only its own data.
  A clean unmount clears the dirty flag after the last batch and flushes
  once more. So a power cut or a removal at any point leaves names and
  chains that reach only allocated clusters holding written data, with no
  cluster in two chains or under two names; loses at most the batch being
  committed, whose files may hold old or new bytes block by block; and
  leaves at most lost clusters; and a volume whose flag is clear has no
  change half made. FAT16's and FAT32's entries, two and four bytes at
  aligned offsets, never straddle a sector, so each entry's write is
  whole; a FAT12 entry, a byte and a half, can straddle two sectors, and a
  cut between them makes another valid cluster number, and FAT12 has no
  dirty flag, so the server mounts a FAT12 volume read-only. A volume
  found dirty mounts read-only and reports it, so the files can be copied
  off and the volume repaired on another machine, never by a guess on
  erXos. Every guarantee above rests on the medium's flushes, so the
  server sends one flush as it mounts, before it writes anything, and
  that answer alone admits the mount: `ok` lets the volume mount
  writable, which a FAT12 or a dirty volume still does not; `enotsup`,
  a medium that cannot flush, as a USB medium that refuses SYNCHRONIZE
  CACHE is, mounts it read-only with `no flush: read-only` in the
  mount's inspection record
  ([design-usb.md](design-usb.md#the-scsi-subset)); and any other
  answer, `eio` for a failed flush or the transport's deadline, or the
  window's end before it answers, refuses the mount with nothing
  written and the failure in the mount's inspection record; a client's
  request on the refused mount fails with `eio`, and the next mount
  tries again, as a drive's next walk does
  ([design-usb.md](design-usb.md#mass-storage-reaches-the-file-servers)).
  A refusal and not a
  read-only mount, because such a failure says only that this flush
  failed, not that the medium cannot flush, and a medium whose flush
  fails with no write outstanding is failing or gone: a read-only mount
  would show it as a working volume for as long as the window lasts,
  while a refusal is tried again and adds no state.

A FAT image is untrusted input like any other: the boot sector, the FATs,
the directories and the long-name chains are decoded with checked bounds,
a cluster chain is followed at most as many steps as the volume has
clusters, so a loop ends with `{error, eio}`, and the decoders have a fuzz
target on the host's stock OTP. fsimg, the FAT server's oracle, creates
FAT images for the server to read and checks every image the server
writes with its verify (`fsimg W`).

### System updates

**A trial writes nothing but the record and the reset count.** On a
trial boot the block driver's write path refuses every write except to
the record's window and the reset count's, and every file system mounts
read-only without recovery: F2FS without
roll-forward, as Linux's `norecovery` mounts it
([research](research-boards-storage.md#file-systems)), littlefs and FAT
without writes. Writers get `{error, erofs}`, which a release's health
checks tolerate. The block driver reads the boot value from the machine
page through its runtime, so the rule holds whatever the storage services
and the system domain do. A failed trial therefore leaves the data
partition and the vault's partition as the committed system left them,
with nothing to undo.

**The slot writer** is one domain of its own, running a small Erlang
release from the boot image. It holds the only writable windows on the
slots and the only window on the record, each a window process of the
block driver exported to it, and the update service in the system domain
holds its only facet. Before every write it reads the record from the
medium and the boot value from the machine page, and decides what it
allows by one pure function over the two, from facts it reads itself.
The update service decides what it asks for by the same two facts and
the check of the spare. The update has two rows:

| State | Boot value and record | The slot writer allows | The update service |
| --- | --- | --- | --- |
| `normal(C)` | `normal(C)`, the record naming `C` | writes to the other slot, the spare | checks the spare against its manifest and reports it as bootable or not; to install an update, writes the slot image into the spare and its manifest into the manifest window last, checks the spare whole, and only then asks the system domain for an ordered end with `trial`, whose freezing checkpoints put every write the services acknowledged in a completed checkpoint that a mount without roll-forward reads ([design-system.md](design-system.md#shutting-down)) |
| `trial(S)` | `trial(S)`, the record naming the other slot | one commit, rewriting the record to name `S` | once the trial is healthy, with at least 60 s of the lease left, asks the slot writer for the commit, then asks the system domain for an ordered end with `reset` |

Every other pair of boot value and record allows nothing and asks for
nothing: an `unknown` boot value, an unreadable record, and a boot value
that names a slot the record does not, as when a firmware falls back to a
complete spare and boots it normally while the record names `C`. A commit
therefore applies only from the trial state, so no boot commits a slot
that has not passed a healthy trial, whatever the firmware boots (U2).

The table decides writes alone: a read of a slot or of the record and a
flush change nothing, and are always allowed. A **commit** is one request
that rewrites the record, flushes it and reads it back, so the flush and
the read-back belong to the write the table allowed and need no row of
their own; it answers `ok` when the record reads back as written. A
rewrite is never repeated: once the record names `S`, a trial of `S`
matches no row that allows a write to the record. Nothing records an
update's progress: a commit is the record naming `S`, a failure the
record still naming `C` after the trial, and a spare whose write was cut
short fails its check and is written again by the next install. The
update service starts a trial only when asked to install, so a failed
update is never retried on its own.

**The reset count.** Beside the record lies the **reset count**: the
number of consecutive boots that ended unordered, by a fault of the
system domain, its halt outside an ordered shutdown or a missed watchdog
deadline. An unordered end leaves no time to write, so the count is kept
from the boot's side: the update service has the slot writer add one to
it early in every boot, before the network domain or any user domain
exists, and set it to zero at an ordered end and at the first successful
login at any line, typed or automatic, a development build's automatic
logins of `root` at the UART and the host link included. A count past three when it is read makes the system release boot
its rescue configuration, the console, a login and the services a login
needs, with no user domain and no network
([design-system.md](design-system.md#boot)). The slot writer alone
writes the count, as it alone writes the record; it saturates at its
largest value, and a count that does not read as one of its encodings is
taken as past three, so a torn count errs toward rescue. The count lies
in a sector of its own, which no firmware reads, so the update's table,
which decides writes that choose a boot, does not govern it: the slot
writer writes the count on every boot whose value is `normal` or
`trial`, a trial's included, since it changes no slot and names no slot
to boot.

**A trial is supervised from the kernel's first decision.** The kernel
takes a machine lease of `erx.trial_deadline` at its early device-tree
pass, as soon as it knows the boot is a trial
([design-kernel.md](design-kernel.md#console-log-and-panic)), and holds it
until the machine ends. While the lease is held, every end of the machine
is a reset (K19): a panic, a call of `halt/0`, a request for another trial
and the deadline all reset the machine, which then boots the slot the
record names. The kernel's watchdog, which the system domain's runtime
pets, runs on a trial as on every boot, so a hung system runtime resets
too, and on a board with a hardware watchdog the platform layer reloads it
from the kernel's own timer for as long as the kernel runs, so a hung
kernel resets as well ([design-kernel.md](design-kernel.md#the-watchdog),
[design-platforms.md](design-platforms.md#the-watchdog)); on a board
without one, the harness's deadline catches a hung kernel under QEMU. A
fault of the system domain during a trial is a machine reset like any
other, and the reset boots the committed slot. A trial is **healthy** when
the slot it runs from passes its check against its manifest, the system
release is ready, its health checks pass, and the update path itself
works: the slot writer answers and the update service reaches its source,
so a committed system can always be updated again. Read-only health checks
do not establish that a release's write path works: the release's
acceptance suite exercises its writes, flushes and recovery on a
disposable volume before it is installed. The trial never writes the live
data or vault partitions to test them. The update service starts a commit
only while at least 60 s of the lease remain, which the machine page
shows, so a medium that responds normally finishes the record's rewrite
before the deadline; a medium that stalls past it leaves a torn record,
which the risks cover. After the commit the update service resets the
machine, and the committed system's first normal boot mounts the data
partition read-write.

**No conversion.** Nothing erXos stores is
converted, and no release reads an earlier release's storage format. The
data partition and the vault's partition hold littlefs until erXos's
F2FS, and erXos's F2FS arrives by an installation, which writes the medium
afresh and creates both partitions with it; nothing littlefs wrote is
carried across ([plan.md](plan.md#m13-erxoss-f2fs)). An update cannot
bring it: its trial boots a release that cannot read the partitions, so
its health checks fail and it commits nothing, and the update service
refuses such an update before writing it, from its manifest's storage
formats. A fresh installation on a machine that had one has
three one-time consequences: every principal starts with no file and
enrols at the console's UART, where the installer is; the machine's keys are
made afresh, so its SSH host key changes once; and under `tpm` the TPM
keeps the lockout authorization the earlier installation set, which the
vault reports at the console and provisions again by clearing the TPM,
as [design-system.md](design-system.md#the-vault) describes.

**Each platform's record and request.** The rules above are the same on
every platform; what holds the record and the request is the platform's
firmware, or the harness that plays it, as
[design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)
describes for each platform. Every platform meets one contract:

* the record's selection is one sector with exactly two encodings, byte
  for byte, one for each committed slot, placed alone in an
  erase-unit-aligned region; the slot writer commits only after reading
  the sector back as the encoding it wrote; a sector that reads as
  neither is an unreadable record, which allows nothing; its reset count
  is a sector of its own in the next such region, which the firmware
  never reads;
* each slot is one partition holding what the firmware loads, the kernel
  and the boot image, followed by the EROFS images at offsets that the
  boot image records with their hash trees' layouts; the packer starts the
  first image at a fixed offset of the slot, 128 MiB, beyond room for the
  bootable file, and each next one at the next MiB after it, so the
  offsets depend on the images alone and are known before the boot image
  that records them is packed; and its signature
  and manifest windows at offsets the medium layout fixes, so a slot image is
  the same bytes in either slot, the update writes it raw, and no domain
  on the target parses the slot's file system to boot or to update;
* the request is one-shot: the firmware clears it as the trial starts,
  `ERX_END_TRIAL` alone sets it, and the firmware reports the slot it
  booted and whether it was a trial in the device tree's `/chosen` node,
  which the kernel turns into the machine page's boot value
  ([design-platforms.md](design-platforms.md#data-model));
* a board whose firmware can run a watchdog from power-on is configured to
  run it and hand it to the kernel, so a trial whose firmware stage hangs
  resets too.

The record's selection is written only at a commit, when both slots hold
complete systems, so a write that tears it leaves either slot a complete
system to fall back to. An unreadable record allows no write and no
commit, since a repair on a normal boot could name a spare that never
passed a trial; the update service reports it, the machine runs what the
firmware booted, and an installation writes the record afresh. What each
board's firmware does with an unreadable record is checked by its port
([risks](#risks-and-open-questions)).

An update whose preparation for the trial fails never sets the trial
flag. Its normal reset boots the committed slot, whose usual file-system
recovery runs, and the update service reports the spare, which still
passes its check, as an update not yet tried. No incomplete freeze is
reported as a durable checkpoint.

## Interfaces

* **The block service.** A window process of the block driver takes
  `{read, Sector, Count}`,
  answered `{ok, Blocks}`, fresh binaries no controller can still write;
  `{write, Sector, Bytes}`, answered `ok`; and `flush`, answered `ok` once
  the medium acknowledged it; each may answer `{error, eio}` for a device
  error, `{error, einval}` for a request that names no whole sectors or
  more than the transport's maximum, `{error, erange}` for sectors
  outside the window,
  `{error, erofs}` for a write on a trial boot outside the record's window,
  and, for `flush` alone, `{error, enotsup}` when the medium cannot flush.
  A window's pid reaches its client at the client domain's creation, with
  its other grants, or locally in the driver's own domain.
* **The transport.** Beneath the windows is the device process registered
  as `erx_blk`, whatever the controller: `read/2`, `write/2`, `flush/0`
  and `info/0` with the closed error set of [the transport
  contract](#data-model), which only the block driver's own modules
  call. Beneath it is the device NIF, `erx_device`
  ([design-runtime.md](design-runtime.md#the-device-nif)), which only the
  driver's modules call, and of whose calls only `erx_blk_write` posts or
  issues an SD command, with `erx_device:command/2` (U4).
* **The storage services and the FAT server** implement 9P2000.L's
  operations through `erx_fs` and facets, one grant per client, rooted at
  a principal's directory or a service's
  ([design-files.md](design-files.md#the-file-protocol)); a grant whose
  facet row carries `tree apps` is rooted at `apps/NAME/SIGNER/`, the
  app's name and its signer as the mint names them, among the app
  directories, which no other grant reaches
  ([design-packaging.md](design-packaging.md#where-an-apps-files-lie)).
  Each answers the operations its format cannot store, links, nodes or
  extended attributes, with the protocol's error; a client over its quota gets
  `{error, enospc}`. The data partition's service also serves the
  `packages` tree, a service directory of its own holding installed app
  packages, with the slot's package image read-only under `image/`:
  read-write to the system domain's grant and read-only to the app
  template's ([design-packaging.md](design-packaging.md#where-a-package-lies)),
  and the `etc` tree, a service directory of its own holding the
  machine's own settings files, `rc.conf` among them: read-only to the
  system domain's grant and read-write to the grants of the session
  templates that hold `start`
  ([design-apps.md](design-apps.md#the-start-table)). On a board with
  WiFi it also serves the `wifi_etc` tree, a service directory of its
  own holding the WiFi configuration and no secret: read-only to the
  WiFi domain's grant and read-write to the grants of the session
  templates that hold the WiFi domain's `wifi` tree
  ([design-wifi.md](design-wifi.md#the-wifi-domain)).
* **The EROFS reader**, `erx_erofs`, serves `prim_file`'s operations on an
  EROFS mount in the calling process
  ([design-runtime.md](design-runtime.md#files)); it reads through
  `erx_verity:read(Image, Block, Count)`, which returns `{ok, Blocks}`,
  each a binary that matched the tree, or `{error, eio}` when a block did
  not match or the window failed, after a log line naming it ([Reading
  EROFS images](#reading-erofs-images)).
* **The slot writer's facet**, which only the update service holds, takes
  four requests: write a range of the spare slot; read a range of a slot
  or the record back; flush; and commit, which rewrites the record naming
  a slot, flushes it and reads it back, and answers `ok` when the record
  reads back as written, `{error, eio}` when it does not, and
  `{error, etimedout}`, its outcome unknown, when the medium does not
  answer within the lease. The slot writer's table, from the facts it
  reads itself, allows or refuses each write and each commit; a read or a
  flush changes nothing and is always allowed.
* **The data partition's and the vault's storage services** take a
  **checkpoint** request on the **durability facet**, which only the
  system domain holds, answered once a completed checkpoint holds
  every write the service acknowledged, so a mount without roll-forward
  reads them, which may also **freeze** the service, so that it answers
  every later write `{error, erofs}` until the machine ends. A freeze is
  final; there is no thaw request. The system domain's ordered end freezes
  every storage service and selects a trial only after every preparation
  succeeds; a failed preparation selects a normal reset to the committed
  slot instead
  ([design-system.md](design-system.md#shutting-down)). The vault, the only
  client of its storage service, may also ask that service for a
  checkpoint without a freeze, so a change the vault publishes is durable
  before the vault answers it
  ([design-system.md](design-system.md#the-vault)). The data
  partition's service also takes **remove_app** `Name`, `Name` one
  identifier, which removes `apps/Name` whole, every signer's directory
  of the name with it, and reaches nothing outside
  `apps/`, and answers `ok` once a completed checkpoint holds the removal
  and every write the service acknowledged before it, or at once for a
  directory already absent; the system domain's package process alone
  sends it, for an administrator's purge of an app that is not installed
  ([design-packaging.md](design-packaging.md#where-an-apps-files-lie)).
  Under littlefs a
  checkpoint syncs every file open in the volume, then has the block
  driver flush the medium, and answers only then. Before a freezing
  checkpoint reaches that module, `erx_fs` closes mutation admission at
  every grant and each open file's owner finishes the writes it admitted;
  the module's checkpoint and the block flush follow those completions,
  and no later write or successful `fsync` is admitted. A session's
  write-back after the freeze is a write like any other, answered
  `{error, erofs}`. A failed drain or flush fails preparation, and a
  freeze is reported only after every stage succeeded
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
* **The update service** takes an update from the host link or the
  network service through its install facet, reports what it is doing and
  whether the spare passes its check, and asks the system domain for an
  ordered end with `trial` or `reset`
  ([design-system.md](design-system.md#shutting-down)).
* **The kernel** reports the boot value in the machine page, holds a trial's
  lease, and sets the firmware's trial request only through `ERX_END_TRIAL`
  ([design-kernel.md](design-kernel.md#console-log-and-panic)).
* **The device service** gives the block device to its domain and names
  the partition windows from the medium layout of the ABI file and the
  system configuration's roles
  ([design-system.md](design-system.md#devices)).
* **The runtime's primitives**: the hash-checking reader's SHA-256 and
  CRC-32C, and the device NIF's buffer pool
  ([design-runtime.md](design-runtime.md#per-byte-primitives)).

## Compatibility and migration

Every format carries its version and is refused when it is not one the
reader implements: F2FS's superblock feature bits, the EROFS images'
feature bits and block size and dm-verity's tree (version 1, SHA-256), a
FAT32 volume's file-system version (0.0, the only one the specification
defines), an update manifest's format version and storage formats, and
the record's two encodings. Nothing erXos stores owes compatibility to an
earlier release's form ([design.md](design.md#compatibility)): no release
reads an earlier release's storage format, no partition is converted, and
an update whose release reads other storage formats is refused, so a
change of format arrives by an installation that writes the medium
afresh, as erXos's F2FS does ([System updates](#system-updates)). A
manifest's security version is one the running system refuses to go
below, so an update can never install an older, vulnerable system; that
is a rule against rollback, not compatibility. FAT, an exchange format
that other machines write, is read as its specification defines it.

On a FAT partition, files behave as FAT gives them, each difference with a
test: names match without regard to case for the letters of Unicode's
Basic Multilingual Plane, as on Windows, and names that differ only in the
case of a letter beyond it are different names; a long name that does not
fit erXos's names appears under its short name, permission bits map to the
read-only attribute alone, times are UTC with two-second modification
times, files stop at 4 GiB less one byte, a FAT12 volume is read-only, and
a file closed and opened again may get a new qid path
([File identity and version](#read-write-storage)).

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A trial is unhealthy, hangs or panics | the health checks; the lease's deadline; the watchdog | the spare as written; the data partition as the committed system left it (U4) | the reset boots the committed slot, whose record still names it | the update reported failed by the record still naming the committed slot; never retried, since only an install starts a trial |
| A trial request's preparation fails or times out | the ordered-end coordinator | the verified spare and whatever checkpoints completed; no trial flag | a normal reset boots the committed slot and ordinary filesystem recovery runs | preparation failure and incomplete durability; never a successful trial preparation |
| Power cut while the spare is written | the spare's check against its manifest, at the next normal boot | a spare without a matching manifest, never tried (U5) | the next install writes the spare again | the spare reported not bootable |
| The firmware falls back and boots a complete spare normally while the record names the committed slot | the slot writer, from the boot value and the record | both slots as they are; the record unchanged | none: the pair matches no row, so no slot write and no commit (U1, U2) | the update service reports the mismatch and accepts no update until the machine boots the committed slot |
| A torn or unreadable record | the slot writer's read of the record | both slots complete | none on the machine: no row allows a write; an installation writes the record afresh | the update service reports the record and accepts no update |
| An EROFS block fails its hash check | the hash-checking reader | the mount, read-only | none needed | `{error, eio}` for the read, and a log line naming the image and block |
| A verified EROFS block holds a malformed structure | the reader's bounds checks | the mount | none needed | `{error, eio}` for the operation, and a log line naming the image and block |
| A crafted or corrupt data partition | the file system's bounds checks and checksums | that partition, which a mount that fails never writes | the failing process ends and the storage domain with it; the domain service starts it again from its specification within its restart intensity, and a volume that fails every mount leaves it ended, never formatted ([A mount never formats](#read-write-storage)) | the domain's death record; that partition's files unavailable |
| littlefs's C code crashes | the port's sub-space faults, and its owner sees `{exit_status, N}` | the partition as littlefs left it; an unacknowledged operation has an unknown outcome | the owner's supervisor restarts the port once the window has answered the port's outstanding requests, and the port mounts the volume afresh | affected operations fail with `eio`; the partition unavailable until the remount |
| The block device reports an error, or the controller stops answering | the device process's completions and its deadline | the request's buffer, quarantined until the device is reset ([design-runtime.md](design-runtime.md#the-device-nif)) | the device process reports to the device service, which resets the device by starting a new device process; a window is bound to the life of the device process it first reached and answers `{error, eio}` once that process has ended, since a reset may drop writes the device's volatile cache held and had answered `ok`, so a reset by any route breaks the volumes over the device, which remount through their own restart | `{error, eio}` on the request, and on every later request of a volume mounted before the reset; the inspector's device record |
| The SD card or its controller reports an error, or misses a deadline | the device process's interrupt decode, the card's R1 status, Auto CMD12's R1, and the request's in-flight bound or the start step's deadline ([The SD host controller](#the-sd-host-controller)) | the failed write's sectors unknown; no buffer, since programmed I/O lends the controller no memory | the device process ends, which ends the storage domain, since `erx_blk_sup` restarts nothing; the domain service restarts the domain, whose device process's start waits for a card still programming, resets the controller and returns the card to idle with CMD0 | `{error, eio}` on the request in flight and on the backlog; one log line naming the step and the status bits |
| The domain that runs the block driver ends | the domain service | every window dead; every client's reads and writes fail | the domain service starts the domain again from its specification, whose creation gives it the device again, the device service names its windows, and each client receives its window anew as a grant | `eio` on every file of every storage service until the windows return; the domain's death record |
| A FAT volume found dirty, or a removal while mounted | the volume's dirty flag; the window's errors | the volume, read-only | none on erXos; the volume is repaired on another machine | a report naming the volume; `{error, erofs}` for writes, `{error, eio}` after a removal |
| An update's signature or manifest fails its check | the verifier, before decoding | nothing written | none needed | the update refused, with the reason |

**Diagnostics.** The inspector shows the boot value, the record, the
spare's check, each storage domain's state and the block
driver's windows and counters; every grant, window and open file of a
storage service is a process the inspector and the tracer show like any
other; the kernel's final line on every end of the machine names the end
it takes.

## Security

Every byte from a medium is untrusted, and so is every update until its
signature checks. EROFS blocks are checked against their tree in the
domain that consumes them (E1); file system images are parsed only in the
domain over their own partition, with bounds checks and fuzz targets
(PW1); the partition table is parsed by the driver's Erlang partition
process the same way. The parsers and the driver are Erlang, whose code
cannot write outside its own heap, so a parsing bug fails a process
instead of corrupting memory; the C that remains is the device shim
beneath the driver, which parses nothing, the per-byte primitives, and
littlefs, the stopgap, in a sub-space that holds nothing but its channel
and data area, each small and each with a fuzz target. An update's
signature is checked over the manifest's raw bytes before decoding,
against the key the running boot image carries, and a release system
refuses development images and lower security versions. Only the slot
writer can write a slot or the record, and it derives what it may do from
facts it reads itself (U1, U2). In the default configuration the storage
domain holds the block device, so a logic bug in its Erlang file system
could in principle call the device NIF; the build check that only the
driver's modules reference it closes that path for code in the tree, and
a release configuration for a board whose controller is unconfined
separates the two domains. The residual risks, a medium that tears an
acknowledged write and a crafted data or FAT partition that damages its
own files, are recorded in [design.md](design.md#residual-risks).

## Verification and testing

The block driver: a host test of the device service's window derivation
(PW1); a QEMU test that every window refuses sectors outside it with
`erange`; the build check that only the driver's modules reference
`erx_device`, and the one that only the driver's write path names the
NIF's two issuing calls, each with a seeded violation that it catches:
a test module that calls `erx_device:command/2` directly, one that
passes `erx_device` and `command` to `erlang:apply/3`, one that calls
`M:command/2` with `M` bound to `erx_device`, and one that makes the
module's name with `list_to_existing_atom/1`; the device NIF's test that
`erx_device:write/3` answers `badarg` for `cmdtm` taken from a map, and
that `erx_device:command/2` answers `badarg` for a word that turns DMA
on, whose seeded faults drop the `ownedByNif` mark and the DMA check; a
host test of the device process's deadline decision, in which a request
past its wait limit is answered `{error, {device, deadline}}` with no
register touched and an issued one past its in-flight bound ends the
process, with the seeded fault of timing the wait from the issue rather
than the acceptance, and a check that the wait limit and the in-flight
bound together stay below the timeout of `erx_blk`'s calls, that below the
window's and that below littlefs's port's; a QEMU test that a trial boot's driver refuses every write but
the record's, whatever its clients ask; a test of the same storage
service against a local window and against one exported from a driver
domain of its own, which must pass both unchanged; a controller that
returns a malformed completion, whose device process fails and ends the
storage domain, since `erx_blk_sup` restarts nothing, after which the
domain service restarts the domain and the driver drives the device
again ([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain));
and a kill of the driver's domain
while clients hold windows, after which every client sees `eio`, the
domain service restarts the domain, and the clients' windows return.

The transport split: QEMU `virt`'s block suites pass unchanged on
`erx_blk_virtio`, and fail with a seeded fault that swaps the
`virtio_blk` and `sdhci` rows of the transport table, which leaves the
virtio disk undriven; a virtio flush posts a flush request through
`erx_blk_write`, and the block suite's start fails on a device that does
not offer the flush feature.

The SD controller, each test paired with the fault that proves it ran:

* The identification state machine, a protocol state machine, is tested
  on the host exhaustively over every state and every event (each
  response, a command timeout, each error). CMD8's timeout returns the
  command-line reset, the data-line reset and CMD55, in that order, and
  CMD55's R1 with the illegal-command bit set is accepted after it and
  refused anywhere else; a timeout in every other state is a refusal.
  The seeded faults treat CMD8's timeout as a refusal, and the
  standard-capacity path's cases fail; and drop the resets from its
  actions, and its case fails.
* The expected timeout on QEMU's `raspi4b` model, with the medium on a
  card of the model's specification version 1 (`sd-card`'s
  `spec_version=1`, which QEMU 11.1.3's `-device sd-card,help` lists)
  on a 1 GiB image: the device process identifies a standard-capacity
  card, its `info/0` detail records CMD8's timeout, and a file written
  and synced to `/data` reads back after the storage domain restarts.
  The seeded fault handles CMD8's timeout as an operational failure, and
  the boot has no device process. Whether the reset is what lets the
  next command issue on the board's controller, which holds command
  inhibit from version 4.10, the board probe records.
* The admission of a card, a property test over every structure,
  capacity bit, `READ_BL_LEN`, `C_SIZE` and `C_SIZE_MULT`: a pair is
  admitted exactly when the rule of *Admitting a card* allows it, and
  every admitted card's capacity is the specification's formula, a whole
  number of sectors, with its last sector's byte address below 2^32
  when addressed in bytes and its last sector's number below 2^32 when
  addressed in blocks. The seeded faults accept any `READ_BL_LEN`, and
  the property fails at 15, a 64 GiB card addressed in bytes; and drop
  the agreement check, and it fails at structure 0 with the capacity bit
  set.
* The parsers on known values: a CSD of each structure gives the
  capacity QEMU's model reports for a 2 GiB and a 4 GiB image, and an
  SCR, an SD status, a General Information naming the Performance
  Enhancement function and a Performance Enhancement register set give
  their fields; the seeded fault drops the R2 parser's one-byte shift,
  and every CSD case fails.
* The cache step on the host, over scripted answers: a card whose SD
  status lacks bit 330 skips it; one with bit 330 and no CMD48 in its
  SCR is refused; one whose Cache Enable reads set is flushed, written
  clear and read back; and one whose Cache Enable still reads set after
  the write is refused. The seeded fault skips the read-back, and the
  last case is admitted.
* The divider, a property test: for every base clock and target the
  chosen clock is at most the target and the next smaller divisor would
  exceed it; the seeded fault compares with `<` in place of `=<`, and
  the property fails at the targets the base divides exactly.
* The register spacing on the host, against a recording stand-in for the
  device NIF: no two writes other than to `data` are less than 6 us
  apart, the command's included, and writes to `data` are not delayed;
  the seeded fault sets the spacing to zero, and the test fails.
* The 1.8 V check on the host: a `control2` word with 1.8 V signalling
  enabled refuses the start before any reset or command; the seeded
  fault drops the check, and the test sees the reset written.
* The identification command's wait on the host: command complete and
  the data track in either order, in one word or several; a data end on
  a command with neither data nor busy ignored; an out-of-order event,
  a second command complete and a busy command's buffer event failing
  it; every decoded word ending in continue, done or fail. Over the
  recording stand-in, identification passes CMD7 with its transfer
  complete in the word before its command complete, and with a data
  end in CMD9's word. The seeded fault holds the data track until
  command complete, and both tests fail, each under its own fault.
* The transfer's checks on the host: an Auto CMD12 R1 with an error bit
  fails a multi-block read or write, and one with only out of range
  fails it unless it is a CMD18 that ended at the card's last sector;
  the seeded fault ignores out of range on every transfer, and the
  write case passes where it must fail.
* The write path on the host: every word `erx_blk_write`'s SD table
  builds outside its write function is one of CMD0, 2, 3, 7, 8, 9, 12,
  13, 16, 17, 18, 48, 49 and 55 and ACMD6, 13, 41 and 51, CMD49 writing
  only the card's Performance Enhancement register and no sector; the
  seeded fault adds CMD24 to the table under an initialisation step, and
  the test fails. On a trial boot value the SD write function answers
  `erofs` and touches no register; the seeded fault removes the trial
  check, and the test fails.
* The issuing of a plan on the host, against the same recording stand-in
  for the device NIF: `sd_issue/2` writes `interrupt`'s one-to-clear
  bits, `blksizecnt` (for a data command only), `arg` and the command
  in that order, refuses with `{device, inhibit}` once inhibit
  has stayed set for 10 ms, and keeps the spacing across consecutive
  issues; `sd_feed/3` writes exactly the plan's checked bytes of the
  block it names; and the argument rule admits CMD16 only with 512 and
  CMD49 only with the cache rule's two writes. The seeded faults leave
  CMD49's argument unchecked, let a feed run past the plan's blocks and
  skip the wait for inhibit, and each fails its test.
* On QEMU's `raspi4b` model (programmed I/O only: its capabilities offer
  no DMA, [design-platforms.md](design-platforms.md#bring-up-under-qemu)),
  booted with the medium as EMMC2's card: the device process identifies
  the card, the partition process reads the table, littlefs mounts at
  `/data`, and a file written and synced is read back after the storage
  domain is killed and restarted. It runs on a 4 GiB image, a
  high-capacity card, and on a 2 GiB image, which the model presents as
  standard capacity
  ([research-sdhci-qemu-model.md](research-sdhci-qemu-model.md#qemus-sd-card-model-how-it-sizes-a-medium)). The seeded fault boots the model
  with a medium whose data partition holds a different known file, and
  the read-back check fails, which shows the bytes came from the card.
* Recovery on the model: the device process is killed while a write load
  runs; clients see `eio`, the storage domain ends and the domain service
  restarts it, the new device process identifies the card from the
  transfer state the model's card was left in, and the load resumes; the
  seeded fault leaves CMD0 out of the start sequence, and the restart
  fails to identify the card.
* Fuzz targets, one per parser of what the card or the controller
  writes: the R1, R3, R6 and R7 words, the R2 words with the CSD, the
  SCR, the SD status, the General Information, the Performance
  Enhancement register set and the `interrupt` decode. Each returns a
  value or a refusal for every input and never raises, and the CSD and
  OCR target checks the admission's properties above on every pair it
  admits. The seeded fault accepts any `READ_BL_LEN`, and the target
  finds an admitted card whose last byte address does not fit 32 bits.
* On the board, by hand: the card identifies at default speed, `/data`
  mounts, and the power-cut checklist of
  [plan.md](plan.md#1b-i-the-raspberry-pi-4-on-the-stopgap) passes; the
  [board probe](#the-board-probe) records its items and its timed slow
  read settles the base clock.

The littlefs port: a crash injected into littlefs mid-write, after which
the port restarts, the block driver and every other window live on, the
volume mounts, and littlefs's own mount check finds a consistent volume
whose last acknowledged `fsync` is present; a port that stops answering,
ended at the owner's deadline with the same outcome.

An independent TLA+ model checked with TLC covers the update protocol
and the slot writer's rules. Abstract operations and the mechanism's
persistence steps have explicit scopes, targeted broken configurations
and reachability witnesses. Each invariant maps to an implementation
check; [Protocol verification](design-verification.md) defines the suite
and the mapping discipline. The model records firmware and medium
assumptions without substituting them for board conformance.

The actual update state machine and the slot writer's rules are explored
exhaustively on the host against an independent oracle, with a power cut
after every write and every reset, writes lost from the medium's volatile
cache, a torn record sector,
an unreadable record, a torn reset count, a flag set but never used, a
firmware that boots either slot normally whatever the record names, a
spare cut short at every write, and a deadline that passes at every step,
checking that a commit happens only from the trial state and only after
a healthy trial; the reset count reaches rescue
after exactly the fourth unordered end in a row, from every interleaving
of ends, ordered ends and logins, and a torn count errs toward rescue.
A QEMU test acknowledges a write, prepares a trial, cuts the power before
any later checkpoint, and checks that the trial's mount without
roll-forward finds the write; one cuts a spare's write short and finds the
spare reported not bootable and no trial requested; and the commit's
three answers are
each driven by a medium that writes, refuses and stalls. The driver's
admission is tested with a boot medium whose table differs from the
layout in one field, which it refuses, boot media of two sizes, whose data
partitions run to each one's end, which it admits, and removable media
whose entries overlap or pass the end, which it serves without them.

Preparation tests fail or time out each vault and storage reply, including
one storage service after another has frozen, and deliver replies after
the deadline. The selected end is always a normal reset on failure, no
trial flag is written, and no service resumes between preparation and
reset. Successful preparation alone permits a trial. Forced ordinary
shutdown reports incomplete durability, while successful `fsync` and vault
checkpoint operations retain their specified recovery guarantees.
They also acknowledge a write, close its fid and freeze: the normal
recovery and the trial's read-only mount both find that write, and no
write reaches the medium after the freeze acknowledgement.

Admission tests flood a storage service from one client while another
reads, and find the second client's latency bounded by the service's
scheduling and the first client blocked on its own lane; the service's
group alone is charged for both, and the inspector's per-client statistic
attributes the work.

The FAT server has a power-cut harness of its own, which cuts after every
write and every flush, and around both changes of the dirty flag, reorders
the writes between flushes, as F2FS's harness does, and checks each image
with fsimg's verify (`fsimg W`): a clean flag never comes with a change half made, no name
and no chain reaches a cluster the FAT does not allocate, no cluster lies
in two chains or under two names, and no file that an earlier batch
committed changes, but for the files of the batch being committed, whose
bytes may be old or new block by block. Its layouts include files whose
old last cluster's entry and new run's entries lie in different sectors of
the FAT, a chain that grows and one that shrinks in one batch, and a FAT12
volume, which mounts read-only. A test also checks littlefs's checkpoint:
a write acknowledged through a file still open, a checkpoint, and a power
cut leave the write on the medium. Its name matching is compared with
Windows' rules over cases that include letters of the Basic Multilingual
Plane with and without simple uppercase forms and Deseret letters in both
cases.

erXos's F2FS is checked by Linux's F2FS driver and `fsck.f2fs` in a Linux
guest and by the power-cut harness ([Read-write
storage](#read-write-storage)). The EROFS images are written and checked
by fsimg: its verification runs on every image the packer writes, and
`test/host/release_medium_test.rb` reads the release image back out of
the medium with fsimg (`fsimg xf --offset=`). The EROFS reader is checked
by its EUnit tests over fixture images that `tools/erofs_fixtures.rb`
writes with fsimg, from a tree it declares: `compact.img` (fsimg's
default, compact inodes), `extended.img` (every entry but the root owned
by uid and gid 70000, which makes fsimg write their inodes extended) and `lz4.img`
(`-o compression=lz4`, which the reader refuses with `enotsup`); by its
fuzz target, `tools/fuzz/erx_erofs.rb`; and by running on the host's
stock OTP over an image's file and in a domain under QEMU. The FAT server
is checked by fsimg, which creates the images it reads and verifies the
images it writes. Nothing of EROFS or FAT is checked against Linux.

Fuzz targets cover the partition table with its two extended
boot records, EROFS, F2FS, FAT and littlefs images, the hash-checking
reader, the driver's completion decoder, update manifests, the
boot-selection record and the QEMU harness's slot parser, each built for
the host (`make check-fuzz`): the Erlang decoders run on the host's stock
OTP, the C parsers natively. Runs on the boards check what QEMU cannot:
each board's trial request across its reset, a damaged record, and the
firmware's watchdog settings
([design-platforms.md](design-platforms.md#trial-requests),
[plan.md](plan.md#m12-storage-networking-boards)).

## Performance

Reading an EROFS block costs a read from the medium, a copy into the
domain and a SHA-256 of the block, which dominates once the block is in
memory: an estimated 4 to 20 us for 4 KiB at the 200 MB/s to 1 GB/s of
portable C (an estimate from the cost model of
[design-live.md](design-live.md#performance)), the only path on the
Raspberry Pi 4, whose cores have CRC instructions but no SHA-256
instructions, and an estimated 2 to 4 us on the Raspberry Pi 5, whose
cores have them, at an estimated 1 to 2 GB/s (the boards' CPU features
are in [design-platforms.md](design-platforms.md#references)). The
reader's Erlang work
per lookup, a binary search over cached directory blocks, is an estimated
1 to 5 us under BeamAsm. Writes to the data partition and to FAT are
bounded by the medium: an SD card's 20 to 100 MB/s is 40 to 200 us per
4 KiB block (an estimate from the cards' rated speeds), against an
estimated few microseconds of Erlang per block. The driver's cost per
request is an Erlang message to the window, the NIF's descriptor post and
one interrupt delivered through the runtime's event loop, so
interrupt-to-completion latency includes the runtime's scheduling; gate G9
measures it per device class and decides the completion batching
([design-system.md](design-system.md#the-driver-table)). A block that
crosses a connection costs one more copy, out of the lane at the client.
`tools/erx bench fs` measures sequential and random reads of an EROFS
image, the data partition and a FAT image, and a `find` over 10,000 files,
on QEMU under HVF and on both boards, against the same operations on the
release file system in the same run, as the baseline, and `tools/erx bench
blk` the driver's throughput and latency against the device's rated
figures. Uncompressed slots fit the boards' media, an estimate that a
decision gate of [plan.md](plan.md#decision-gates) checks against the slot
images' sizes.

The SD controller's programmed I/O moves each 512-byte block as 128
register accesses through `data` and takes one interrupt per block, all
on the device process's core; a 4-bit bus at default speed's 25 MHz
carries at most 12.5 MB/s. Whether the device process keeps up is
unmeasured: `tools/erx bench blk` on the board measures it, and a C bulk copy of the data port, a per-byte primitive of the
device NIF, is the measured exception row of the driver table if it does
not, before DMA replaces the copy altogether.

## Portability

The rules are the same on every platform; the record and the trial request
are each platform's, under one contract ([System
updates](#system-updates),
[design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)),
and a platform without a trial request reports the boot value `unknown`
and takes no update. The driver's device process is the part that differs
per controller: `erx_blk_virtio` for virtio-blk on QEMU, `erx_blk_sd` for
an SD host controller with SDHCI's register set, which the Raspberry Pi
4's EMMC2 is and which another board's SDHCI controller reuses with a row
of the device-kinds table. Each is an Erlang module over the same device
NIF, answering the same transport contract, with the controller's
registers named from its CMSIS-SVD description
([design-platforms.md](design-platforms.md)); a new controller is a
module, a row of the transport table and its builder in `erx_blk_write`,
and nothing above the transport moves. Which domain holds the
device is each board's configuration. The primitives' use of a CPU's CRC
and SHA-256 instructions sits behind the architecture layer, with portable
C beside it ([design-runtime.md](design-runtime.md#per-byte-primitives)).

## Dependencies

No dependency beyond those in the dependency table of
[design.md](design.md#dependencies): littlefs as the stopgap for
read-write storage, the Raspberry Pi firmware, and the small verifier of
update signatures; fsimg, which writes and verifies the EROFS images and is
the FAT server's oracle, and the Linux oracle guest's F2FS tools, as host
tools invoked as subprocesses and never part of an image; LZ4's decompressor is the option if the media lack room for
uncompressed images. The block driver, the EROFS reader, erXos's F2FS,
the FAT server and the slot writer are erXos's own Erlang.

## Alternatives considered

**One storage domain with the whole medium.** A single domain would parse
the partition table and the file systems, verify the EROFS images and
write the slots. A crafted data partition that broke its file system
would then reach the slots, the boot-selection record and every
principal's files, and survive updates. Partitions as windows, a slot
writer of its own and hash checks where blocks are consumed confine each
parser to its own partition ([Invariants](#invariants), PW1).

**A native block driver in a domain of its own.** The driver would be C
in a domain that serves windows to every storage domain over a kernel
gate. Rejected by the decision that drivers are Erlang: the
Erlang driver's partition parser and completion decoder fail a process
instead of corrupting memory, its windows are processes the inspector and
tracer show, and it needs no native runtime of its own. A domain of its
own for the device remains the configuration for a board whose controller
is unconfined, with the same driver.

**littlefs as a NIF in the storage domain.** littlefs's C would run on a
dirty scheduler of the storage domain's runtime. It loses: in the default
configuration that runtime also runs the block driver, so a memory bug in
the stopgap could reach the device and every window on the medium, and a
crash in it would end every storage service's windows at once. A
sub-space port confines the C to its channel and data area, by
construction, and its crash ends one volume's port.

**Converting the partitions.** A conversion from littlefs to F2FS, in
place or by an update whose release reads both, would keep files and
keys across the change. Rejected: a conversion needs a proof
of its own, and no release owes compatibility to an earlier one's
storage while erXos is in development, so an installation creates both
partitions afresh.

**File systems in C.** erofs-utils' library as the EROFS reader in every
runtime, and erXos's F2FS in C in a native storage domain. Rejected by the
decision that system code is Erlang: an Erlang file system's grants
and open files are processes that can be inspected, traced, supervised and
upgraded live, and its parsing bugs fail processes instead of corrupting
memory. The cost is per block, where the medium and the hash dominate
([Performance](#performance)), and the per-byte work stays in C.

**An EROFS writer in the Ruby packer.** The packer would write EROFS images
itself. It loses: fsimg writes reproducible, uncompressed images and
verifies them, and as a host tool it costs nothing on the target and
shares no code with erXos's reader, which strengthens the check of the
reader. The packer takes the job over only if fsimg stops being
reproducible.

**The hash tree checked in the driver.** The block driver would check
each EROFS block against the tree before handing it out, once for every
client. It loses: the check is the funnel E1 rests on, and it must happen
in the domain that consumes the block, on the domain's own copy, or a
driver's bug or compromise would be trusted with every release's
integrity (ST-R1); N copies and N hashes for N domains are the price.

**Per-file hash trees.** fs-verity and Fuchsia's blobfs keep one tree
per file. The EROFS metadata the reader parses (superblock, inodes,
directories) then needs a tree of its own, as composefs and Apple's
signed system volume both add, and erXos updates whole slots, so sharing
files between images gains nothing. One tree per image covers metadata
and data with one root hash.

**Whole-file fingerprints.** FreeBSD's and NetBSD's veriexec hash a
whole file before it is used, which reads a multi-gigabyte file before
its first page and cannot report one bad block.

**An HMAC per sector.** FreeBSD's `geli -a` authenticates each sector,
which needs a secret on the device and gives no protection against
replaying an old sector.

**Install-time checks only.** OSTree, Nix and OpenBSD's signify verify
content when it is installed. They give nothing against a medium swapped
later or against bit rot, which the tree catches at read time as `eio`.

The manifest names each image as Android's AVB hashtree descriptor does:
root hash, salt, block size, hash algorithm and data-block count, all
fields of the `image` record
([design-abi.md](design-abi.md)).

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| erXos's F2FS, written from a specification of a GPL implementation's format, is challenged as derived from it | low | high | a clean room: the specification's author implements none of it and the implementers see only the specification; a legal review of the clean room before any distribution includes it |
| An SD card loses or tears an acknowledged write, the one-sector rewrite of the boot-selection record included | medium | high | the record changes only at a commit; the power-cut harness covers lost and reordered writes between flushes; each board's port tests what its firmware does with a damaged record; a torn record needs an installation, since no normal boot may rewrite it |
| On a board, the trial request does not survive the reset that ends a trial, or an unreadable record stops the firmware instead of falling back ([design-platforms.md](design-platforms.md#trial-requests)) | medium | high | each board's port tests the trial path before it accepts updates: a requested trial boots the spare once, a crash or hang in it boots the committed slot, and a damaged record is tried in place; a dropped request shows as a failed trial |
| A board firmware's watchdog settings do not behave as documented, or are missing ([design-platforms.md](design-platforms.md#the-watchdog)) | medium | medium | each board's port tests a trial whose firmware stage hangs; without them, such a trial needs a power cycle, as U3 states |
| The Erlang block driver misses the controller's timing or costs too much of its throughput | medium | slow storage on the boards | `tools/erx bench blk` at gate G9 per controller; completion batching; a per-byte C primitive for the ring work as a measured exception row in the driver table ([design-system.md](design-system.md#the-driver-table)) |
| The default configuration puts the block device and the data partition's file system in one domain | low | a logic bug in the Erlang file system that reaches the device NIF, or a storage-domain restart that drops every window on the medium | the build check that only the driver's modules reference the NIF; Erlang's memory safety; the native stopgap in a sub-space port; the configuration that gives the device a domain of its own, required where the controller is unconfined and available elsewhere |
| Erlang file systems are slower than the boards need, on the Raspberry Pi 4 above all, which has no SHA-256 instructions | medium | medium | `tools/erx bench fs` on both boards; metadata caching in the reader; the per-byte work already in C; G12 and G13 measure before littlefs is replaced |
| A parser bug in the EROFS reader | low | low | it parses only blocks that passed the hash tree, whose root comes from the boot image; a malformed structure fails the operation with `eio`; its fuzz target; fsimg's images as its oracle |
| A FAT volume removed or cut off while written loses files or clusters | high, for removable media | low | the dirty flag set and flushed before the first change; batches of five flushed steps, new chains allocated before they are linked and chains cut before they are freed; clusters freed in a batch allocated only in a following one; FAT12 read-only; a harness that reorders writes between flushes; a dirty volume mounts read-only; repair on another machine |
| The SD controller's base clock in the capabilities register is wrong on the board | low: FreeBSD runs EMMC2 on it | a card clock too fast fails identification or transfers with CRC errors; too slow costs throughput | the board probe's timed slow read; the platform record's `clock` for the SD unit if the probe disagrees |
| A fact the SD design leaves to the board probe (1.8 V signalling at hand-over, card detect, write spacing above 400 kHz, the base clock, command inhibit after a timeout, a cache the firmware left on) proves different on the board | medium | the card fails identification, or a step fails its deadline; a card the firmware left at 1.8 V cannot be driven, since only the firmware switches its regulator | each is a line in the log and no device process, never a wrong answer; [the board probe](#the-board-probe) settles each before the board pass counts |

No open question remains for storage beyond the SD controller's board
probe above: the clean room's legal review, the
refusal to convert either partition, and the custody of the release key
outside this design are decided
([plan.md](plan.md#beyond-the-plan)).

## References

* [research-boards-storage.md](research-boards-storage.md): file systems
  (the EROFS format's documentation and licenses, erofs-utils' licenses
  file by file, F2FS's feature bits and mount options, dm-verity's
  format, littlefs), booting a chosen partition on the Raspberry Pi, and
  cryptography libraries, each dated, with its sources.
* Linux's dm-verity on-disk format (version 1, SHA-256), as the research
  record checks it.
* The SD controller's sources ([The SD host controller](#the-sd-host-controller)).
  The authority is the SD Association's Physical Layer Simplified
  Specification, version 9.10 (1 December 2023), for the card's
  commands, responses, CSD, SCR, SD status, extension registers, cache
  and identification, and its SD Host Controller Simplified
  Specification, version 4.20, for the controller's registers, resets,
  recovery, divider and data port, of which the driver uses the version
  3.00 register set. Neither is vendored into the tree, whose
  redistribution their terms do not grant; each fact taken from them is
  cited by version, section where it has one, and printed page, beside
  the BSD-licensed code below where that code encodes the same fact. GPL drivers (Linux's,
  U-Boot's) are used only through the facts record,
  [research-sdhci-bcm2711.md](research-sdhci-bcm2711.md), facts and
  working principles without code, written by an agent that writes no
  erXos code for this driver. The facts record cites FreeBSD
  14.3.0-RELEASE at `8c9ce319fef765890ce518cab85d3a470b669849`, while this design cites `release/15.1.0`,
  below; both were fetched and compared for this design. The files either cites differ only
  in build interfaces (headers, `DEVICE_UNIT_ANY`, `bus_attach_children`), sysctl
  types, a quirks sysctl, two early returns for SPI-mode buses in `mmc.c` and a
  local renamed in `mmcsd.c`'s `mmcsd_task` (lines 1425-1482), which no citation reaches; no
  fact this design or the record cites differs, though line numbers shift by a
  few lines. The 14.3.0 hashes: `sdhci.c` `f610ce62058120de45448333be459373e992d753c4a384d8222839459b3b1abc`, `sdhci_fdt.c`
  `71439ab0aafdf17b5249d87f56fa1a0f3d66e29672d199b27fd960bd0fcd59e8`, `mmc.c` `738725016981e017ed31497938b4fd7744246c7046ba6a2962005931e4ba5dfa`, `mmcreg.h` `74ff2ab498265ad51188205858899a0122089a47c9924e61a3002808deb47829`,
  `mmcsd.c` `896acbb6e1e7689a006e1232f2c2ec6371b64af3931dba5c57916c5aa1c5557d`, `bcm2835_sdhci.c` `2928861d93c34d42a5cde74bf523e5f1018ee68de3c5c35f33620d2059952a92`, and `sdhci.h`
  identical; `sdhci_fdt.c`, which neither cites for EMMC2, was reworked. The code reference is FreeBSD's SD stack
  at `release/15.1.0`,
  fetched from github.com/freebsd/freebsd-src and read as data:
  `sys/dev/sdhci/sdhci.c` (SHA-256
  `4551b7d7842dfb2ffcdc2a565686a6dad5d6aa74606abd9cdc647e98d29eb500`),
  `sys/dev/sdhci/sdhci.h`
  (`363ed505d9ec77603b1b0d46e689da80600e72ce5948d5b2efe70571059b2b78`),
  `sys/dev/sdhci/sdhci_fdt.c`
  (`22c3d06cb2f3b31f9d37c0e4c92e8eef802b11804e369a5f2e4d37ccea1a5686`),
  `sys/dev/mmc/mmc.c`
  (`b4a93cfcc403f2ded40f951ba175bfabe88d5a97a863cc6fc4a23a9ac5965468`),
  `sys/dev/mmc/mmcreg.h`
  (`1e782e73c04e8cd570a433b2cadc585237e5f8593c3b5a3c8fef92e57a2c7353`),
  `sys/dev/mmc/mmcsd.c`
  (`ae9a8d2796dda8e075cf06e66f8ee728abd04428585cb1431dcf16ccf600aae6`)
  and `sys/arm/broadcom/bcm2835/bcm2835_sdhci.c`
  (`28c9af6fa2f549dbfc5bd239b0edd592da2df83833e021f76ff599826d8de56f`),
  whose compatible table drives `brcm,bcm2711-emmc2`
  (`bcm2835_sdhci.c:137-144`). The board's device tree is Linux 6.18's,
  the version `deps.lock` pins as `linux-dts`, read for hardware facts
  alone: `arch/arm/boot/dts/broadcom/bcm2711.dtsi`
  (`b33a898bd3d841552699a90ca85153c32778dfd76e46ead50ee191c9e3f67520`)
  and `bcm2711-rpi-4-b.dts`
  (`6bc587c46e263bf096ee5f402669bd985d95a6048f77991ffd96bf7a7e6c6d86`),
  fetched from git.kernel.org at tag `v6.18`. QEMU 11.1.3's model is the
  test oracle, never a reference for behaviour: `hw/sd/sdhci.c`
  (`c7d5ade66c15e6ba732ff86892b20f31d59a3577b13c9236704bd8814a1b84c4`),
  `hw/sd/sd.c`
  (`5dbc570c20b8b2b935de0fc5a15d65e740b08d375fc9e42a1dcabb53d0b50fcc`),
  `hw/sd/sdhci-internal.h`
  (`baaf34e8ea459ab0837a36c6793e542b98231cd426676b3dee0769ea9c8750fd`),
  `hw/arm/bcm2838_peripherals.c`
  (`4383259a2266d44ede842b4203d635a95c36f8b2305a5f5261e31c3617a8088f`)
  and `hw/arm/bcm2838.c`
  (`a81db2b2fda5403e7a71daeb4760c3f2f003237cfadba3540d5e7ad375c58299`),
  fetched from github.com/qemu/qemu at tag `v11.1.3`.
* fsimg, https://github.com/stass/fsimg (BSD-2-Clause), at commit
  `807cd027ad99b06cc1f53cecc2890f90d4158470`, which `deps.lock` pins; its
  manual, `docs/fsimg.1`, defines the options the packer passes (`c`, `W`,
  `-F`, `-R`, `-e`, `-o cluster=`, `-o compression=`, `-o uuid=`, `-C`)
  and the mtree keywords of the manifest.
* Microsoft, "FAT32 File System Specification, FAT: General Overview of
  On-Disk Format", version 1.03, 6 December 2000: FAT type determination,
  long directory entries, name limits and character sets, name matching,
  and the 65,536-entry bound on a directory.
* Unicode Standard Annex #44, "Unicode Character Database", Unicode
  18.0.0, revision 38: field 12 of `UnicodeData.txt`,
  `Simple_Uppercase_Mapping`, https://www.unicode.org/reports/tr44/
  (read 2026-10-31).
* "cp437_DOSLatinUS to Unicode table", table version 2.00, which maps each
  of the 256 bytes to one character,
  https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/PC/CP437.TXT
  (read 2026-10-31).
