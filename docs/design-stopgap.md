# Stopgaps no other design carries

Each component here is a stopgap: the roadmap replaces it, and CLAUDE.md's rule for what a
stopgap promises binds it. 0.2 ships littlefs in its NIF form, under [its release contract](#release-contract), whatever M13's
gate G13 decides; a drive's littlefs volumes are served only by development builds and test images
([littlefs on a drive](#littlefs-on-a-drive)), and a release ships no other stopgap of this document. The kernel the first release runs on,
Fiasco, and `liberx`'s backend over it are [design-fiasco.md](design-fiasco.md)'s, and the
sections of that backend named below are there.

## littlefs in the storage domain

**The port** is littlefs's target placement, which replaces the NIF form below and which no release ships
([TODO.md](../TODO.md), stopgap replacements). Where a storage domain holds the data window, littlefs is that domain's sub-space port, as
[design-storage.md](design-storage.md) places it: a sub-space the storage domain creates, with a channel to it, its block
requests to the storage domain's block service over the channel and its end at the storage domain's fault gate. Each of
those is a row of the Fiasco backend ([Spaces, parents and exit records](design-fiasco.md#spaces-parents-and-exit-records), [Passing a
handle](design-fiasco.md#passing-a-handle), [Fault gates](design-fiasco.md#fault-gates)), so the port and `design-storage.md`'s remount rule run unchanged.
A crash injected into littlefs ends only its port, since a fault ends nothing but its space once its gate's server stops
it. A port that bypasses `liberx` reaches only what the storage domain placed in its space, as any sub-space does ([design-fiasco.md](design-fiasco.md#who-holds-what)).

**The NIF form.** Phase 1 and 0.2 run littlefs as a NIF behind the `erx_fs` callback module, the seam the design names, in the
domain that holds the data window: the storage domain, which the development manifest configures as an interpreter service
domain with the `block` unit and runs `erx_blk` and `erx_storage` (`erx_blk_sup` and `erx_lfs_sup` under `erx_storage_sup`). The system
release ships neither application, so a manifest that leaves the `block` unit with the system domain runs no block
driver and serves no `/data`. The Erlang side is the
port's, and only the glue below differs. The storage domain serves the tree as the `data` service, of the `files`
interface, whose facets the manifest grants to the system domain and to root's session template: each grant is
read-write over the whole of `/data`, so every session of root's principal reads and writes all of it, which a
development build's trusted code allows and a release does not ([Release contract](#release-contract)) (property 16 of [design-system.md](design-system.md) holds both ends to the
protocol's frame floor).

A process running a dirty NIF cannot run its receive loop, so two share the work. The **owner** takes clients' requests, one at a time, and never
blocks. The **worker**, linked to it, alone calls the littlefs NIF, on a dirty I/O scheduler, one operation at a time.

littlefs reads and programs whole sectors. Its `erase` returns success with no request, since a block device erases nothing. **One block request**,
from a read, program or sync callback:

1. The callback allocates a NIF resource holding a state word, starting *pending*, a result and a buffer. A program copies its bytes into the buffer.
2. It posts `{erx_lfs_block, Op, Sector, Count, Ref}` to the owner with `enif_send`, where `Ref` is the resource term and `Sector` is `(Block * BlockSize + Off)
   / SectorSize`. If `enif_send` reports the owner dead, it fails at once.
3. It waits on the request's condition variable, under its mutex, until the state leaves *pending* or the deadline passes;
   the mutex and condition variable are musl's, over `erx_umtx_wait` and `erx_umtx_wake`.
4. The owner translates `Op` into the [block service's request](design-storage.md#interfaces): `{read, Sector, Count}`; `{write, Sector, Bytes}`, with
   `Bytes = payload(Ref)`, a short NIF returning the buffer as a binary; or `flush`. It sends with a monitor and a reply tag, remembers the one
   outstanding `{Tag, Ref}`, and returns to its receive. The resource stays private to the owner.
5. On the answer it calls `complete(Ref, Result)`, a short NIF that copies any read bytes into the buffer, stores `ok` or `error`, under the mutex moves the state from
   *pending* to *done*, and signals the condition variable.
6. The callback, on *done*, copies a read's bytes into littlefs's buffer and returns 0, or `LFS_ERR_IO` for `error`.

**No dirty-scheduler deadlock.** Steps 4 and 5 and `erx_device` run on normal schedulers, and interrupts arrive by the dispatcher. One operation holds
one dirty thread, and nothing it waits for needs a second. To keep that true, the owner makes no synchronous call; the owner and driver use no file
operation, and no `logger` handler writes to `/data`; `complete` and `payload` are not dirty NIFs.

**Failure has one answer: the storage domain ends.** Any block failure (an error answer, a request the owner refuses, or a deadline: the callback
moves the state from *pending* to *ended*, and a lost swap means the request is done) breaks the NIF's volume, so the operation and every later one
answer `{error, eio}`. The NIF's flag is the one record of it: the worker reads it (`broken/1`) after each operation and ends when it is set. The
worker's end, the window's, or a mount that fails ends the owner. `erx_lfs_sup` and `erx_storage_sup` restart nothing (their children are permanent
and their restart intensity is 0), so the end escalates to `erx_storage`, a permanent application, and ends the node and the domain. Every queued
request answers `{error, eio}`, and nothing in the domain replays or remounts. The block driver's failures end the domain the same way, whether or
not a request is in flight: `erx_blk_sup` restarts nothing either, so the end of its device or partition process, by a crash or by the shutdown
with which its device process, `erx_blk_virtio`, ends on a broken queue, ends `erx_storage_sup`, whose first child it is, and so the domain; the driver never
restarts on its own under a mounted volume, and a broken queue never resets the device in place, since nothing promises that a reset keeps
writes the device's volatile cache holds and has already answered `ok`. A stop, start or restart through `storage_ctl` is the system domain's, and the supervisor counts no
restart for it, so it does not end the domain itself. Each window of the block service is bound to the device process it first reached
(`erx_blk_window`), calls it by pid and monitors it, and once that process has ended answers `{error, eio}` to every request that would reach
the device, even after a new device process has reset the device: the windows the volume mounted on never vouch for a write across a reset.
So a stop, start or restart breaks the volume at its next block request, which ends the domain, and a
start whose device refuses the reset answers `{error, failed}` and leaves the domain up without a driver until littlefs's next request fails.
The domain service restarts the domain within its row's intensity
(`restarts 5`, `restart_period_s 600`): creation gives it the device again, the driver resets it, and littlefs mounts the volume afresh. The owner
answers its start only once the volume has mounted, so `/data` is mounted, and the domain reports ready, only over a mounted volume, and a mount that
fails fails the domain's boot. A delayed old write cannot race a newer one, since none outlives the domain that issued it, and littlefs's power-loss
design handles the cut. A late `complete` loses its swap and does nothing; the term keeps the buffer alive. `design-storage.md`'s rule, which remounts
once every outstanding request is answered, belongs to the port.

**`/data` for other domains.** The volume is also the files service `data`, which the manifest grants to the system domain and to root's session
([design-files.md](design-files.md)). Its mint, an `erx_fs_mint`, the module of every files service mint of the storage domain, is the third child of `erx_lfs_sup`, after the owner and the local grant, and names
itself the service's mint before the domain reports ready. It takes only a mint request in the system domain's envelope and drops anything else. For
each one it starts an `erx_fs` grant of the volume's tree, read-write, whose client is the grantee's domain id, so the grant takes frames only in that
domain's envelope and with that domain's names. The grant exports itself to the grantee, with `send` alone, before its start returns, so no answer
names a grant the grantee cannot reach; a refused export is the mint's answer, and no grant is left. A grant for any domain but the system domain
monitors this domain's connection to the grantee (`erx_connections:connection/1`) before the export and ends with it: a grantee's restart is a new
domain id over a new connection, and no grant of the old incarnation remains to take its frames. The system domain's grant lives as long as the
storage domain. The grants are temporary children of a supervisor linked to the mint, so a grant's end, by its connection or its heap bound, ends
nothing else, while the volume's end ends the mint and every grant, and the domain's restart answers new mint requests over the new volume. Of the
facet row's limits a grant applies three: `in_flight`, the most requests it holds at once (at most `erx_fs_grant`'s 64); `max_request`, the largest
message size it agrees to at `version`, which it advertises but does not check against each frame (at most 9P's 65,560; a row below 9P's least, 4,096, is refused with `{error, einval}`); and `max_heap_size`,
its process's heap bound in words, shared binaries included. `reductions` and `period_ns` bind no grant, as they bind no facet yet. The grantee's
namespace reads its `data` grant at each lookup, so the mint keeps no record of what it handed out. The volume's `packages/` directory is
the files service `packages` ([design-packaging.md](design-packaging.md#where-a-package-lies)), with a mint of its own beside `data`'s that
works the same way: each of its grants roots at `packages/`, or at `packages/installed/` when its row states `tree installed`, as the
app template's does (`erx_lfs:subtree/3`), and takes no `.` or `..` as a name, which the grammar refuses in every walk, so it reaches nothing else
of the volume, and the mount makes both directories when the volume lacks them. Only a domain the manifest grants `data`
mounts its `data` facet at `/data`, read-write and on the tree `data`, with `erx_ns:mount_facets/1` ([design-files.md](design-files.md), "A
facet's mount"): the system domain's domain service once it has read the manifest, and a session domain as `erx_session` starts
(`erx_session_app`), from the names of its granted facets its ready answer carries. The mount names the facet, never a grant, so every lookup
under `/data` goes to the grant the domain's facet registry holds for `data` at that moment. Before the first grant arrives and while the storage
domain is down, `/data` answers `eio`; once the restarted storage domain's mint has installed a new grant, the next open reaches the volume
again, while a descriptor opened before the restart keeps failing with `eio` and its writer opens the file again. A domain the manifest grants
no `data`, such as every domain of a board with no storage driver, has no `/data` mount, and finds the root's empty, read-only `/data`
directory there.

## Verification

| Case | Seeded failure, and what it shows |
| --- | --- |
| **littlefs**: a file operation under `+SDio 1` with a block read in the callback completes | `complete` made a dirty NIF: the deadline fires |
| littlefs: an injected block error fails that operation as unknown, and the next is `{error, eio}`; the driver killed under load: no later writes reach it, and after a reboot a file synced earlier is there; a littlefs worker killed ends the storage domain, whose restart mounts `/data` afresh with a file written earlier (the driver_domains suite); a block device process killed or shut down ends `erx_blk_sup`, and `storage_ctl`'s stop, start and restart do not (`erx_driver_ctl_tests`, on the host) | the error swallowed: success claimed. The owner resends: a later write is counted. Sync skipped: the file is lost. The driver restarted in place: `erx_blk_sup` outlives the kill |

## Release contract

0.2 ships littlefs as the read-write file system of the data partition and of the vault's partition; a drive's
littlefs volumes are no part of it ([littlefs on a drive](#littlefs-on-a-drive)). Beyond what CLAUDE.md's
rule for a stopgap promises, a release commits to this for every domain, trusted or not, and no more; a gap that breaks it
blocks the release, and every other gap is a published downside below. Each row names its test, which is [Verification](#verification)'s, the fuzz
campaign's or its own.

| Commitment | What a release does | Test, and the seeded failure that proves it ran |
| --- | --- | --- |
| **Placement** | littlefs runs as the NIF of [The NIF form](#littlefs-in-the-storage-domain), in the runtime of the storage domain that holds the partition's window, and the NIF in no other domain, a drive's volumes reaching littlefs only as [the port](#littlefs-on-a-drive), and only in development builds and test images: the system domain's release names neither `erx_blk` nor `erx_storage`, so no release manifest runs littlefs in the system domain. Its C code shares that runtime's memory, which [Published downsides](#release-contract) states | the release build's check refuses a system release that names `erx_storage`, the application whose `erx_littlefs` loads the NIF; a system release that names it fails it |
| **Input** | the partition's bytes are untrusted, read only through littlefs's own bounds checks and checksums, and a mount that fails never writes or formats the partition ([A mount never formats](design-storage.md#read-write-storage)) | `tools/fuzz/lfs_image_fuzz.c`, built with the NIF's configuration (geometry, cache and lookahead sizes, name length), runs at its full `check-fuzz` budget under AddressSanitizer with no open finding before the release; a seeded bound removed from littlefs's directory-entry read makes it report |
| **Requests** | what a client sends through its grant (paths, sizes, offsets, and the order of its operations) is untrusted; it reaches littlefs's C code only through the NIF's argument decoding, `get_path` of `otp/erts/emulator/nifs/erxos/erx_littlefs_nif.c` and the size and offset reads beside it, which bounds every path, size and offset before littlefs sees it. `get_path` bounds a path's length (`ERX_LFS_PATH_MAX`), not a name's; littlefs refuses a name longer than its `name_max` itself. The NIF builds littlefs with `erx_lfs_config` of `otp/erts/emulator/nifs/erxos/erx_littlefs.h`, which the image fuzz target already shares | `tools/fuzz/lfs_request_fuzz.c`, with its seed generator `tools/fuzz/lfs_request_target.rb` beside `lfs_image_target.rb`, drives sequences of operations (open, read, write, seek, truncate, rename, remove, sync, directory reads) through that decoder, under a shim of the `enif_*` calls it makes, into littlefs built with `erx_lfs_config`, over an image the sequence starts from, and runs its full `check-fuzz` budget under AddressSanitizer with no open finding before the release; seeded failure: `bin.size >= len` deleted from `get_path`, which AddressSanitizer reports as a write past the path buffer |
| **Failure** | a littlefs crash, a block failure and a littlefs assertion each end the storage domain, which the domain service restarts within its row's intensity (`restarts 5`, `restart_period_s 600`), and the restarted domain mounts the volume afresh; until then every request answers `{error, eio}`, nothing replays a request, and nothing resets the device in place ([Verification](#verification), [design-storage.md](design-storage.md)'s failure table). Every request answers: a walk of littlefs's directory list meets the cycle check a mount already runs over the list it walks (`lfs_tortoise_detectcycles`, `littlefs/lfs.c`), applied to the walks of `lfs_dir_find` and `lfs_dir_read` (whose walk spans calls, so its check's state lives in the open directory), so a crafted image whose directory tail points back at itself fails that request with `LFS_ERR_CORRUPT`, which the NIF answers as `{error, eio}`, instead of looping on a dirty I/O thread | a seed image of `lfs_image_target.rb` whose directory tail, off the list a mount walks, points back at itself: a lookup and a listing past it answer `{error, eio}` and the volume answers the next request; the check left out of `lfs_dir_find`, so the host test's lookup passes its deadline, fails it. The storage domain ended six times within 600 seconds is restarted five times and then stays down, reported by the domain service; the intensity not applied, so the sixth end is restarted, fails it. The littlefs and block-failure cases of [Verification](#verification) |
| **Durability** | a file synced before a driver kill or a power cut is present after the reboot; a write not yet synced may be lost | the driver killed under load ([Verification](#verification)); sync skipped loses the file. The power-cut tests of [M6](plan.md#m6-immutable-code-lasting-data) on QEMU and of [1b-I](plan.md#1b-i-the-raspberry-pi-4-on-fiasco) on the Raspberry Pi 4 |
| **Grants** | the data partition's services grant each client one tree: each session but an app's its user's home through the `home` service, `/root` for root and `/home/NAME` for any other user, an app's at `apps/NAME/SIGNER/` and the `packages` service's at `packages/` ([design-storage.md](design-storage.md), "The storage services and the FAT server"; [design-files.md](design-files.md#building-binding-and-mounting), "A user's home"; [design-packaging.md](design-packaging.md#where-a-package-lies)); every one of those grants, every non-app session's `home` grant among them, carries requests into littlefs (Requests); the read-write grant over the whole volume to every session of root's principal is a development build's alone | `erx_littlefs_tests`'s `a_home_reaches_only_its_own`: a home grant reaches only its user's home, and a home rooted at the volume's root fails it; a session of a second user opens a file of the first user's home and gets `enoent`; a grant minted at the volume's root fails |
| **Keys** | the vault's files are sealed under keys the storage domain never holds, so a crafted partition that only damages files reveals no key; a memory defect in littlefs reaches what the storage domain reaches, the whole machine where it holds an unconfined DMA-capable device ([Published downsides](#release-contract); [design.md](design.md#residual-risks), "littlefs serves the vault's partition") | the vault's files read raw from the partition hold no key in the clear; a file written unsealed fails ([design-system.md](design-system.md#the-vault)) |

**Published downsides.** A release states them with its notes:

* a crafted or corrupt partition can end the storage domain, and leaves its files unavailable; a partition that fails
  every mount stays unavailable and is never formatted. An assertion of littlefs's on disk state (`LFS_ASSERT`, live in the
  NIF's build) that a damaged image reaches aborts the storage domain's runtime, and one reached at mount does so at every
  restart, until the restart intensity leaves the domain down;
* a defect in littlefs can lose files, a vault key file among them, which leaves that principal's vault `unavailable`;
* a memory error in littlefs corrupts the storage domain's runtime, since littlefs's C code runs there as a NIF. A memory error
  that crashes that runtime ends the storage domain, and its restart mounts the volume afresh; one that a crafted partition or
  a client's requests can steer reaches whatever that runtime holds: every grant of the volume, so every principal's files on
  it, with no grant or principal check between the defect and the volume, and, in the default configuration, the block driver
  and every window on the medium. The block device masters DMA and no device of 0.2's platforms is confined
  ([design-fiasco.md](design-fiasco.md#devices), FD12), so through it that runtime reads and writes all of memory: every
  domain's, and the vault's live keys. The image and request fuzz targets running their full budgets clean before the release
  are the defence. Only a configuration that gives the block device a domain that runs no littlefs bounds such an error to the
  volume; no 0.2 manifest names one;
* any block error, deadline or driver restart ends the storage domain, and `/data` is unavailable until its restart has mounted the
  volume again.

### littlefs on a drive

Development builds and test images serve a drive's littlefs volumes
([design-drives.md](design-drives.md#littlefs-through-its-port)), so
the drives' tests can mount littlefs sticks; no release does. A
release build's media domain carries no `erx_lfs` and no littlefs
port, which its release check proves, so its probe names a littlefs
volume and refuses it as not served. littlefs on a drive is therefore
no part of any release contract, and only CLAUDE.md's rule for a
stopgap binds it, for the trusted workloads a development build runs.

Its placement is still the port, never the NIF form, so that a drive
ends only its own volume's mount: littlefs's assertions and crashes in
the NIF would end the whole media domain and every drive's mounts, and
a memory error would reach every drive it serves. The port's owner
places every block request in the volume and answers a program or an
erase only while the volume may be written. What a crafted littlefs
stick can still do in a development build, beyond failing or damaging
its own volume, is steer a memory error in littlefs, which runs in the
port's sub-space and reaches its channel, its own volume through its
owner's checks, the kernel's calls and the CPU; that is a residual of
development builds, recorded in [todo-storage.md](todo-storage.md),
and of no release.
