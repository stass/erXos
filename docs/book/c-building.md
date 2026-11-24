# Appendix C. Building and Booting erXos

> **Status.** Built: everything this appendix tells you to run. The
> host setup on macOS and FreeBSD, `make fetch` against the pins of
> `deps.lock`, `make setup` and the oracle bootstrap, `make check` and
> the slower gates, `tools/erx boot` on QEMU, the QEMU medium and the
> Raspberry Pi 4 card from `make pack`, netbooting a board from a Mac,
> and hosted mode on macOS.

A clean clone of erXos holds no compiler output, no generated header
and no third-party archive. It refuses to build until it has fetched
what `deps.lock` names and checked every byte against its hash. Only
the fetch step (section C.2) reaches the network; every other command
runs offline, under a deadline, with its output in a log.

erXos builds with sources it does not keep in its tree, such as LLVM's runtime libraries, the Raspberry Pi firmware and
the boards' device trees, and it tests itself against programs it does
not ship, such as stock OTP. So it pins each one by URL and SHA-256.

This appendix walks the path from a fresh Mac to a running system:
the tools a host needs (C.1), fetching (C.2), the one-time setup and
oracle bootstrap (C.3), the everyday check and the slower gates (C.4),
booting in QEMU (C.5), a Raspberry Pi 4 card (C.6), and hosted mode
(C.7). Every command here is a target of the top-level `Makefile` or a
subcommand of `tools/erx`, the host tool written in Ruby
([design-build.md](../design-build.md)); README.md's
[Getting started](../../README.md#getting-started) and the sections
after it are their reference.

## C.1 The host

Apple Silicon macOS is the primary development host; FreeBSD on
x86-64 is a host too. A build needs these tools
([README.md, Host setup](../../README.md#host-setup)):

* Ruby, any version, with minitest and REXML, for `tools/erx` and the
  tests;
* GNU make, GNU sed, GNU timeout (`gtimeout`) and Perl;
* LLVM's clang, lld and binary tools, which build Fiasco and L4Re too;
* Autoconf, Automake, Libtool and a host C and C++ compiler, which
  build fsimg, the tool that writes the read-only EROFS images;
* QEMU 11.1, with its `virt-11.1` machine;
* Node.js and pnpm, for the browser client (`make web`);
* xz, which compresses the Raspberry Pi 4 card;
* a JVM, which runs TLC, the TLA+ model checker;
* Docker, a local engine or context, only for the full stock OTP
  suites.

On a Mac, Homebrew installs all of them. The build insists on LLVM,
not Apple's clang or GCC, for its own code and for Fiasco and L4Re. It uses clang as a cross
compiler (`--target`), links with lld and reads the input list lld
prints under `--trace` to learn which files went into each image, and admits into an image only
the LLVM headers `config/provenance/llvm.json` lists. You point the
build at the compiler with environment variables:

```sh
export ERX_CLANG=/opt/homebrew/opt/llvm/bin/clang
export ERX_LLD=/opt/homebrew/bin/ld.lld
export JAVA=/opt/homebrew/opt/openjdk/bin/java
export PATH=/opt/homebrew/bin:$PATH
```

The paths are Homebrew's on Apple Silicon; an Intel Mac uses
`/usr/local`, which `brew --prefix` prints. The tree is tested with
LLVM 23.1 and the build does not check the version, so a compiler that
is too old fails with its own errors. Published images are built with
exactly LLVM 23.1.3, and their hashes are published so anyone can
rebuild one and compare.

On FreeBSD the same tools come from packages (`llvm23`, `gmake`,
`coreutils` for `gtimeout`, `ruby` with its minitest and REXML gems
and the rest), and you run the
top-level targets with GNU make: `gmake check`. `make setup` finds the
newest `/usr/local/llvmNN` by itself when `ERX_CLANG` and `ERX_LLD` are
unset. Hosted mode (section C.7) builds only on macOS, so on FreeBSD
`make check` names the tests that need it as not run on this host.

## C.2 Fetching pinned sources

The file `deps.lock` at the root of the tree is the list of everything
the build takes from outside. Each entry is a **pin**: a source's
identifier, its exact URL, its version or full commit, the SHA-256 of
its archive, the root directory the archive must unpack to and its
license. The first entry reads, in part:

```json
{
  "id": "otp",
  "kind": "tar",
  "version": "29.1.2",
  "url": "https://github.com/erlang/otp/releases/download/OTP-29.1.2/otp_src_29.1.2.tar.gz",
  "sha256": "c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049",
  "directory": "otp_src_29.1.2",
  "license": "Apache-2.0"
}
```

Notice that nothing in the entry says where to unpack or what to run:
the build decides that, and the entry only says what the bytes must
be. All fetching goes through `tools/erx fetch`, and `make fetch`
runs it for everything the build needs:

```sh
make fetch DOCKER_CONTEXT=NAME
```

It downloads each source into `build/downloads/`, checks its SHA-256,
and unpacks it with the system `tar`, under a deadline, into an empty
private directory. Only then does it check the result: the expected
root directory, the kinds of file, where each link points, the file
count and the total size. A tree that passes moves into
`build/third_party/`; an interrupted or failed extraction leaves none
([design-build.md, Sources and imports](../design-build.md#sources-and-imports)).
A tree already unpacked from the same pin and unchanged is kept, so a
copied build directory keeps its sources. Naming a local Docker
context also pulls the oracle's Linux image, by its manifest digest.

Two kinds of source are not tarballs. LVGL, the widget renderer, is a
git submodule, `display/lvgl/lvgl`, of erXos's own fork, pinned by the
commit the tree's gitlink records; `make fetch` clones it when it is
missing, as does `git clone --recurse-submodules`. Doom, a demo
game that is never part of the system, is a submodule marked
`update = none`, and only
`tools/erx fetch --example doom` obtains it, with Freedoom's data file
checked against its own hash.

Why one fetch step and no other network access? A build that fetches
in the middle can be steered by whoever answers the request, and a
test that fetches can pass today and fail tomorrow on the same tree.
With all downloads in one step, every later failure is the tree's own.

The code erXos changes, OTP in `otp/`, musl in `musl/`, Fiasco in
`fiasco/` and the others, is not fetched: it lives in the tree, with an
`ORIGIN.md` beside each import that records where it came from
([Appendix D](d-dependencies.md#d2-two-ways-in)).

## C.3 Setup and the oracle bootstrap

An **oracle** is an independent program whose answers the system's own
must match. Examples are stock OTP for erXos's Erlang, musl's own tests for its C
library, plan9port's `rc` for the command shell
([chapter 6](06-construction.md) explains why the project trusts
agreement with an outside answer more than its own tests). Some
oracles must be built before `make check` can run, and a fresh
checkout or git worktree builds them once:

```sh
make setup
```

`make setup` runs `tools/erx setup`, which prepares every source the
fetch verified and then builds, in order: the web client's packages,
stock OTP 29.1.2 twice, fsimg, the hosted runtime (on macOS),
plan9port's `rc`, and a development login key. A step whose output is already valid is
skipped, so a second run does nothing. Each build runs under a
deadline, with its own log in `build/logs/`. Setup never downloads. To
reuse another checkout's downloads, name them, and setup copies each
archive only after its SHA-256 matches `deps.lock`:

```sh
ERX_SOURCE_CACHE=/path/to/other/checkout/build/downloads make setup
```

`make oracle-bootstrap` runs the smaller set: the two stock OTP builds
and fsimg. Stock OTP is built from the very archive the fetch
verified, with its own `configure`, offline. One build has the JIT,
and is the oracle OTP's test suites are compared against. The other is
the `emu` interpreter, which the hosted runtime's build runs as its
host OTP. Homebrew's OTP will not do: it is a different release and
cannot cross-build erXos's. To rebuild one oracle:

```sh
tools/erx oracle build --backend native --flavour jit --clean
```

## C.4 `make check` and the slower gates

```sh
make check
```

`make check` is the everyday gate, the one every change passes before
it lands. In order, it:

1. brings the generated files in `build/gen/` up to date, as every
   `tools/erx` command does first: the ABI headers, the hardware
   accessors, the system-register tables and the terminal tables, none
   of which is checked in ([chapter 7](07-one-source.md));
2. checks the source tree: every authored file is ASCII, and every
   file under an import matches its `ORIGIN.md` or carries a change
   notice (Appendix D, section D.4);
3. runs the build checks: architecture terms in the generic code and
   documents, the chokepoint checks and the stack proof of the C code
   erXos links into the kernel ([chapter 6](06-construction.md));
4. builds the web client and makes sure the `rc` oracle is current;
5. runs every host test in `test/host/` and the native integration
   tests in `test/integration/`, except the few that boot QEMU, need
   the hosted runtime or the stock suites' runtime, or build OpenSSL.

It prints `offline source, generation, host and native integration
checks passed` at the end. It never downloads and never boots a guest.

The slower gates run separately, when a change wants them:

| Command | What it checks |
| --- | --- |
| `make check-qemu` | every QEMU suite, each boot fresh: under HVF, and under TCG a deterministic transcript and a one-CPU boot |
| `make check-reproducible` | two clean builds of the QEMU medium, and of the Pi 4 card without its packages, are byte-identical |
| `make check-sanitizers` | the host C code under AddressSanitizer and UndefinedBehaviorSanitizer, the concurrency tests under ThreadSanitizer |
| `make check-fuzz` | the host fuzz targets, for their configured budgets |
| `make check-tla` | the TLA+ protocol models under TLC, each with its seeded defects |
| `make check-cbmc` | the bounded model checker, through the harnesses in `test/cbmc/`, over the C code in `kernel/core/` that erXos links into Fiasco |
| `make check-litmus` | the weak-memory litmus tests of `test/litmus/` under herd7 |
| `make check-oracle` | OTP's suites on erXos under QEMU against stock OTP, case by case, then musl's `libc-test` |

HVF is macOS's hardware virtualization: the guest's instructions run
on the Mac's own CPU, fast. TCG is QEMU's translator, which turns each
guest instruction into host code; it is slower, and with instruction
counting it makes a boot repeat exactly, which is what the
deterministic transcript needs. The QEMU suites are the files of
`tools/lib/erx/qemu_suites/`; `tools/erx check-qemu --suite NAME` runs
one. The Raspberry Pi 4 suite runs under TCG alone, because QEMU runs
that board's CPUs from a privilege level HVF cannot host.

`make check-oracle` is the longest: README.md gives six to seven hours
under HVF. It runs OTP's `emulator`, `kernel`, `stdlib` and `compiler`
suites in the system domain and on stock OTP on the host, and compares
them case by case against the tables of known differences in
`test/oracle/hosted_known_differences/`. Any other difference fails the
gate, and so does a listed one that no longer occurs.

Each command, slow or fast, starts its subprocesses through one runner
([design-build.md, Processes and evidence](../design-build.md#processes-and-evidence)):
an argument vector, never a shell, standard input closed, a process
group of its own, a log in `build/logs/` and a GNU timeout deadline.
A hung QEMU guest is killed at its deadline with its children, so
nothing waits forever. `tools/erx status` lists every
command recorded as running, with its age and deadline.

## C.5 Booting in QEMU

There are two ways to boot erXos in QEMU: the development image, which
the QEMU suites boot, and the medium, which is the system as a person
uses it.

### C.5.1 The development image

```sh
tools/erx boot
tools/erx boot --accel tcg --cpus 4
```

`tools/erx boot` builds the development boot image into
`build/production-image/interactive/` and runs it in QEMU, with the
guest's serial console on your terminal. The banner says
`development build: trusted code only`, and the Erlang shell's `1>`
prompt comes up. HVF is chosen when QEMU offers it, TCG otherwise;
`--accel` overrides the choice and `--cpus` sets the guest's CPUs, from
1 to 8. Ctrl-A then X quits QEMU. The first build of ERTS takes a while.

`--hostlink` also puts the guest's host link
([chapter 21](21-live-machine.md#2144-the-host-link)) on a UNIX socket in
`build/production-image/hostlink/`, and gives the guest a fresh data
medium for `/data`. The boot prints the `tools/erx web --socket PATH`
line to run in a second terminal, which serves the browser client.
`tools/erx load` sends compiled Erlang modules to the guest over the
same socket, and `tools/erx files` relays a local socket to the guest's
file stream.

### C.5.2 The medium

```sh
make pack PLATFORM=qemu-virt
tools/erx boot --medium build/production-image/qemu-virt/medium.img
```

The first command packs the **medium**: one disk image laid out as the
Raspberry Pi 4's card is, two slots, the vault's partition and `/data`,
with the system for QEMU `virt`, the kiosk and Doom
([chapter 16](16-storage.md#1611-the-medium-and-its-partitions)).
Because it carries Doom, `make pack` needs `tools/erx fetch --example
doom` first. `tools/erx pack --medium` packs a development medium
without Doom, which needs neither.

The second command boots it as a person uses it, on a 704 MiB
machine. The display is in QEMU's window, with the virtio keyboard and
tablet. User networking reaches your network, your host's port 2222
is forwarded to the guest's SSH port, and the serial console is on
your terminal. QEMU boots a copy,
`build/production-image/medium-copy/medium.img`, where the guest keeps
`/data` and its SSH host key. The copy survives from boot to boot and
is made again when the medium changes, so the medium itself stays as
`make pack` wrote it.
`tools/erx boot --medium FILE --print` prints the plain
`qemu-system-aarch64` command line instead of running it.

To log in over SSH, the medium's first FAT volume, labeled `ERXOS`,
needs a file `authorized_keys` with one `ssh-ed25519` key per line, as
on the card. Then:

```sh
ssh -p 2222 root@127.0.0.1
```

You get `rc`, the command shell of [chapter 20](20-shell.md). Port
2222, not 22, is where the system's SSH daemon listens. A few things to
try there: `date` shows the clock, and sets it with FreeBSD's syntax,
`date 202611161530`; `ps` and `top` list your session's processes; `erl`
starts an Erlang shell, where `erx:i()` prints the machine, its CPUs
and its processes.

## C.6 A Raspberry Pi 4 card

```sh
make pack PLATFORM=raspi4b
```

builds the Pi 4's production image and its card, offline, into
`build/production-image/raspi4b/`
([README.md, Raspberry Pi 4 SD card](../../README.md#raspberry-pi-4-sd-card)):

* `sdcard.img`, the card, 718 MiB;
* `sdcard.img.xz`, the same card compressed, to copy or publish;
* `boot/`, the boot partition's files as a directory, which also
  serves a board booting over the network;
* `sdcard.img.receipt.json`, the **build record**: the commit, whether
  the tree had changes, and the digests of what was built.

The same inputs give the same bytes, which `make check-reproducible`
proves by building twice. The website offers the same card as
`sdcard-DIGEST.img.xz`, where `DIGEST` is the first 16 hexadecimal
digits of the unpacked card's SHA-256, so you can check a download
before you write it:

```sh
xz -dc sdcard-DIGEST.img.xz | shasum -a 256
```

The line it prints starts with `DIGEST`, and the whole hash is the one
in the build record.

The board needs a bootloader dated 2022-12-01 or later, which can
choose between the card's two slots; an older one shows nothing on the
console. Raspberry Pi Imager writes a bootloader update to a spare card
([the Raspberry Pi 4 guide](../guide/raspberry-pi-4.md#update-the-bootloader-once)).

To write the card on macOS, find it with `diskutil list`; it is
`/dev/diskN`, marked `external, physical`. Writing to the wrong disk
destroys what is on it, your system disk included, so check the size
and the name twice:

```sh
diskutil unmountDisk /dev/diskN
xz -dc sdcard.img.xz | sudo dd of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

On FreeBSD, `geom disk list` finds it as `/dev/daN`, and
`xz -dc sdcard.img.xz | sudo dd of=/dev/daN bs=1m` writes it.
Raspberry Pi Imager writes the `.img.xz` as it is. For SSH, copy your
public key to the volume `ERXOS` as `authorized_keys` before the first
boot; the first boot copies the keys into `/root/.ssh/authorized_keys`,
and from then on SSH reads only that copy.

The console is a 3.3 V USB-serial adapter on the 40-pin header: ground
to pin 6, its receive line to pin 8, its transmit line to pin 10. Open
it at 115200 baud, 8N1:

```sh
screen -L /dev/cu.usbserial-XXXX 115200
```

Put the card in, connect Ethernet and a screen on the port labeled
HDMI0, and power the board. The console shows the firmware's banners,
erXos's banner with `development build: trusted code only`, and
within about a minute `rc: the command shell` and its `%` prompt. The screen shows the kiosk.
From another machine on the network, `ssh -p 2222 root@BOARD-ADDRESS`
logs in, with the address your router lists for the board. The
[Raspberry Pi 4 guide](../guide/raspberry-pi-4.md#first-boot) has the
full list of lines to expect and a checklist for the SD card and
Ethernet.

Writing a card for every build is slow. A development board can
instead boot over an Ethernet cable from the Mac: `tools/erx netboot`
copies `boot/` into the Mac's TFTP root and prints the TFTP server's
command line. A board booted this way lacks the card's packages; the
board's EEPROM setting and the Mac's Internet Sharing are in the guide
([Netbooting from a Mac](../guide/raspberry-pi-4.md#netbooting-from-a-mac)).
A board whose EEPROM boots over HTTP instead takes a signed FAT image of
the same files, which `tools/erx netboot`'s **HTTP form (designed)**
makes and a boot server hands out
([design-platforms.md](../design-platforms.md#the-http-form)).

## C.7 Hosted mode

A crash inside ERTS is slow to chase in QEMU. Hosted mode
([chapter 9](09-processes.md#962-hosted-mode)) builds the same runtime
as a macOS process on `liberx`'s hosted backend, where AddressSanitizer
and `lldb` work as on any Mac program. It builds only on macOS:

```sh
tools/erx build runtime
make check-runtime-hosted
```

The first command builds the hosted runtime into
`build/runtime/hosted/`; `make setup` already ran it once. The second
builds it and runs its integration tests, among them one that drives
a terminal to the `1>` prompt and evaluates Erlang there, then checks ERTS's imports against the one list in
`sys/erxos/imports.txt` (`tools/erx check-runtime-seam`).

No `tools/erx` command starts a hosted shell for you. The tests start
the emulator, `build/runtime/hosted/otp/bin/aarch64-hosted-erxos/beam.emu`,
with the release archive `build/runtime/hosted/release/system.pack` as
its one argument, on a terminal; you can do the same, or start it under
`lldb`. QEMU stays the authority: a test that passes only hosted is not
a pass.

`make check-oracle-hosted` uses the hosted runtime as the fast route of
the oracle: it runs a subset of OTP's suites on the hosted runtime and
on stock OTP, and compares them as `make check-oracle` does.

## Summary

A build of erXos takes every outside source from `deps.lock`, where
each is pinned by URL and SHA-256, and only the fetch step reaches the
network. `make setup` builds, once, the oracles the checks compare
against: stock OTP twice, fsimg, plan9port's `rc` and the hosted
runtime. `make check` is the everyday gate: source and provenance
checks, generation, build checks and host tests, offline and without a
guest; the QEMU suites, sanitizers, fuzzing, model checkers and the
OTP oracle are separate, slower gates. `tools/erx boot` runs the
development image in QEMU, and `tools/erx boot --medium` runs the
system as a person uses it. `make pack PLATFORM=raspi4b` writes a Pi 4
card whose bytes are reproducible and whose build record names its
hash. Every command runs under a deadline with its log in
`build/logs/`.

## Where to read next

* [README.md, Getting started](../../README.md#getting-started) and
  the sections after it: the reference for every command here.
* [design-build.md](../design-build.md): the runner, the fetch and
  import plans, generation, images and the oracle.
* [guide/raspberry-pi-4.md](../guide/raspberry-pi-4.md): the board,
  step by step, and what to do when it fails.
* [design-host-oracle.md](../design-host-oracle.md): the stock OTP
  oracle in its offline Linux container.
* [design-verification.md](../design-verification.md): what counts as
  evidence, and the model checkers' suites.
