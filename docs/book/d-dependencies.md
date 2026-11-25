# Appendix D. Dependencies and Licenses

> **Status.** Built: the pins of `deps.lock` and their check at fetch;
> an `ORIGIN.md` beside every import, with the change-notice check that
> `make check` runs; the packer's refusal of any file of unknown
> provenance; the license rule `LicenseCheck` and its closed table; and
> the `NOTICES` file that every packed system image carries as
> `system/NOTICES`. Designed: a copy of `NOTICES` beside the boot image
> in each slot's boot partition, the removal of Fiasco's kernel debugger
> with its GPL file, and the rows below marked as designed.

erXos is a small amount of new code standing on a large amount of old
code. Its Erlang runs on OTP, its native programs link musl, its kernel
is Fiasco, its file system on `/data` is littlefs, and its widgets come
from LVGL. Every image it packs carries files written by many
people under many licenses, and each license asks something: keep
this notice, mark that change, offer the source. A system that ships
images has to answer those requests for every file, every time,
without anyone keeping a list.

Code erXos changes lives in its tree, each directory keeping its
license and copyright notices. Two things make the answer mechanical:
a record of every imported file's hash, so a changed file cannot hide,
and a packer that refuses to put into an image any file whose origin
and license it cannot name.

This appendix covers the rules a dependency must meet (D.1), the two
ways outside code enters the build (D.2), the components and why each
pays for itself (D.3), and how licenses and notices travel with every
image (D.4). The authority is the dependency table of
[design.md, Dependencies](../design.md#dependencies).

## D.1 What a dependency must pay

A component erXos takes from outside must pay for itself: it saves more
work, or buys more correctness, than it costs in size, review and
license obligations. The project prefers mature, maintained
components with a C or Erlang interface under a permissive license:
ISC, BSD, MIT or Apache-2.0. A copyleft dependency needs explicit
agreement; the Pi 4's device tree is the one accepted (D.3.2). OFL-1.1
is allowed for font data only.

Tools and test data never enter an image the system ships.

## D.2 Two ways in

Outside code enters the build in one of two ways, and which one
depends on whether erXos changes it.

**Code erXos changes lives in the tree.** OTP's source in
`otp/`, musl in `musl/`, the Fiasco parts in `fiasco/`, OpenSSL,
littlefs, Monocypher, ctaes, the BLAKE3, ChaCha20 and SHA-256 cores and
`libmemdraw`, among others, are ordinary directories of the
repository, changed by ordinary commits. Upstream is not merged: erXos owns their fixes,
and Fiasco's upstream is reviewed each month for security fixes to
backport. Beside each sits an `ORIGIN.md`, the import's
**origin record**: the repository, the release or commit, the
archive's SHA-256 and, for every file, its original hash and license ([design-build.md, Sources and imports](../design-build.md#sources-and-imports)).
LVGL is the one part of the system that is a git submodule instead,
of erXos's own fork, pinned by
its gitlink, with its `ORIGIN.md` at `display/lvgl/ORIGIN.md`.

**Code erXos uses unchanged is fetched.** Everything else (the test
oracles, the firmware, the device trees, LLVM's runtime libraries) is
pinned in `deps.lock` by URL, version and SHA-256, with its
license, fetched by `make fetch` alone and built out of
tree ([Appendix C](c-building.md#c2-fetching-pinned-sources)). The web
client's npm packages are pinned the same way, by the integrity hashes
of `web/pnpm-lock.yaml`, with install scripts off.

Why two ways? A pristine copy in the tree is bytes nobody reads, and
a fetched component with patches kept elsewhere hides the patches.
Each way puts the bytes where the work on them happens.

## D.3 The components

The table has about sixty rows, in a few groups.

### D.3.1 The runtime and its libraries

| Component | License | Why it pays |
| --- | --- | --- |
| Erlang/OTP: ERTS and the shipped applications, with asmjit, PCRE2, zlib, zstd and Ryu inside | Apache-2.0; the parts inside under Zlib, BSD-3-Clause (PCRE2's with its exception) and Apache-2.0 | The language, its runtime and decades of supervision, distribution and libraries; erXos is built around it ([chapter 3](03-erlang.md)). asmjit, the JIT's assembler, is never in the system domain's image. |
| musl | MIT | A small, readable C library for every runtime and native program, whose seam under ERTS erXos owns ([chapter 9](09-processes.md#96-the-c-library-seam-and-hosted-mode)). |
| OpenSSL 3.5 | Apache-2.0 | OTP's `crypto`, `ssl` and `ssh`, and the vault's key derivation and encryption; a long-term-support series. It never enters the system domain's image. |
| LLVM libc++, libc++abi and compiler-rt builtins | Apache-2.0 with the LLVM exception | BeamAsm's C++ runtime, and the compiler's helper routines. |

### D.3.2 The kernel and the boot

| Component | License | Why it pays |
| --- | --- | --- |
| Fiasco, with `bootstrap`, `sigma0`, `l4sys` and `mk` | MIT, with exceptions below | The kernel, an L4 microkernel with decades of use, behind erXos's interface `liberx` ([chapter 8](08-kernel-interface.md)). |
| `drivers-frst`, its PL011 UART part | MIT | `bootstrap`'s console while Fiasco starts. |
| libfdt | BSD-2-Clause (dual GPL-2.0-or-later) | Reading the device tree, the board's description. |
| TF-A's BL31 for the Pi 4 | BSD-3-Clause | The firmware calls that start CPUs and end the machine. |
| Raspberry Pi firmware | Broadcom's binary license | Starts the board and loads the kernel. |
| The boards' device trees, from Linux | Pi 4 GPL-2.0; Pi 5 GPL-2.0 OR MIT | Describe each board. The Pi 4's is the one copyleft dependency the system accepts, shipped as a file of its own beside its edited source and Linux's GPL-2.0 text. |

What the system builds from Fiasco is MIT, with two files to note.
Fiasco's own `kobject_rpc.h` is GPL-2.0, and the tree holds instead
erXos's MIT replacement, written from a description by someone who
never read the original. The kernel debugger's `jdb_object.cpp` is
GPL-2.0 too. Only a kernel built with the debugger compiles it, and
the license rule takes it only in development builds. The images the
website offers carry it and go out with a link to their source. The
design takes Fiasco's debugger out of the tree, this file with it, and
reads a stopped machine from the host instead
([chapter 21](21-live-machine.md#2154-reading-a-stopped-machine)), after
which no kernel build compiles a GPL file. That removal is **Designed**.

Fiasco's imported tree leaves out the copyleft parts no build uses: Fiasco's own
tests, a coverage module and a checksumming console stream that erXos
never configures, the start code of boards and processors erXos does
not run on, the build system's test plug-ins, and GCC's C++ library,
libstdc++. Each tree's import record lists every part left out and
why. What `l4re-core` keeps is `sigma0` and, of the libraries it and
`bootstrap` are built from, only the files those builds compile,
include or install, with their license files, and the whole of
`l4sys`'s generic and arm64 headers, the system-call API erXos's
Fiasco backend is written against. The GPL files that remain are
`jdb_object.cpp` and the configuration tool of the kernel and the
build system, which runs on the development host while a build is
configured and is compiled into nothing a boot image carries. The
`kobject_rpc.h` every kernel build includes is not one of them: it
is the MIT replacement, at the original's path. The
release build's check reads every executable a boot image carries,
for every board: the kernel,
`bootstrap`, `sigma0`, and the Raspberry Pi 4's own `bootstrap`. It
fails if any file compiled or linked into one of them, headers
included, has a license that is not permissive, apart from
`jdb_object.cpp` in a kernel with the debugger.

### D.3.3 Storage, cryptography and small cores

| Component | License | Why it pays |
| --- | --- | --- |
| littlefs | BSD-3-Clause | A small file system that survives a power cut, for `/data` and the vault, run as a NIF in the storage domain ([chapter 16](16-storage.md#163-littlefs-in-the-storage-domain)). |
| BLAKE3, the official C implementation | Apache-2.0 with the LLVM exception | The boot image's hashes and the entropy generator's mixing. |
| FreeBSD's SHA-256 and ChaCha20 | BSD-2-Clause; public domain | The entropy generator and the C SHA-256 primitive. |
| Monocypher's Ed25519 | BSD-2-Clause | A small verifier of update and package signatures, without OpenSSL in the system domain. |
| ctaes | MIT | Constant-time AES, also without OpenSSL in the system domain. |
| Root certificates | none needed: facts, not a creative work | The trust store of every HTTPS client. |

Monocypher and ctaes show the cost side of the rule: OpenSSL would do
their jobs, but in the trusted base a small library is cheaper to
review.

### D.3.4 Display and type

| Component | License | Why it pays |
| --- | --- | --- |
| LVGL 9 | MIT; its fonts Inter's, OFL-1.1 | The widget renderer, a program in the app's own session ([chapter 22](22-display.md)). |
| Plan 9's `libmemdraw`, from 9front | MIT | The per-byte pixel primitives behind `erx_memdraw`, from the system whose draw protocol erXos speaks. |
| plan9port's `fixed` fonts | public domain | The terminal's glyphs. |
| Inter | OFL-1.1, font data only | The desktop theme's type; the glyph files generated from it carry OFL-1.1, their generators BSD-2-Clause. |
| FreeType | the FreeType License, chosen over its GPL-2.0 option | The glyph step of the host program that rasterizes the theme's type; it binds no image. |

### D.3.5 The browser client, and rows for designed parts

React, under MIT, renders the browser client that `tools/erx web`
serves, which is built; TypeScript and esbuild check and bundle it on
the host. Other rows name a dependency for a part that is designed and
not built. toybox, under 0BSD, with `wak` as its awk, is designed to
provide the UNIX commands not written in Erlang
([chapter 13](13-native-programs.md#1373-toybox-and-the-file-utilities)).
cowboy, cowlib and ranch, under ISC, are designed as the HTTP,
WebSocket and TLS server of the web's network front end. The Pi 4's
WiFi and Bluetooth chips run Cypress's firmware, under binary licenses
that allow only unmodified object code for Cypress chips; driving
either radio on the board is designed ([chapter 18](18-wifi.md),
[chapter 19](19-bluetooth.md)).

### D.3.6 References that are translated, never linked

FreeBSD's `netinet`, `netinet6`, `net` and `cc` are the source of the
decisions erXos's TCP/IP stack makes, redesigned as Erlang
([chapter 17](17-network.md)). None of their C is compiled into an
image; the translation is erXos's code and keeps the BSD notices of
every file it derives from, per Erlang module and in
`erlang/apps/erx_net/NOTICE-freebsd`. Two FreeBSD files are never
translated: `netinet/in_cksum.c`, whose four-clause license keeps the
advertising clause, and `tcp_stacks/tailq_hash.c`, which carries no
license at all.

### D.3.7 Tools, oracles and a demo

Most rows never reach an image. They build the system or check it:

* **Host tools**: LLVM, GNU make, QEMU, `dtc`, Ruby, Perl, Node.js and
  pnpm, a host OTP of the same release, fsimg (which writes the EROFS images), the
  TLA+ tools, CBMC and herdtools7's `herd7`.
* **Oracles**: stock OTP in an offline Linux container, musl's
  `libc-test`, plan9port's `rc`, libvterm and `vttest` for the
  terminal, 9front's `libdraw` for the display, a FreeBSD guest for the commands
  that share FreeBSD's names, and a FreeBSD test host for the network
  stack. Some are GPL, such as the Linux guests
  that test erXos's F2FS, and Genode, under AGPL-3.0, which runs the
  benchmark comparison's program rows; they run only as black boxes in
  a guest and are never linked.
* **A demo program**, never part of the system: doomgeneric under GPL-2.0-or-later with Freedoom's
  data file under BSD-3-Clause, as `/bin/doom` on the images the
  website offers. Its source is erXos's fork, a submodule that no file
  of erXos's tree comes from.
* **The website**: v64 and xterm.js, the in-browser console.

An oracle pays for itself differently: it saves no code, but catches
code that is wrong.

## D.4 How licenses and notices travel

Two mechanisms carry the conditions of every third-party license into
what erXos ships, and neither depends on anyone keeping a list
([design.md, Licenses and notices](../design.md#licenses-and-notices)).

### D.4.1 Changed files say so

Apache-2.0, the license of OTP, and the Zlib license require a changed
file to say it was changed. The origin record holds the hash of every
file as imported, so `make check` compares each file under a directory
with an `ORIGIN.md` against its row. A file that differs must carry
erXos's change notice in its header comment. A file added to an import
must carry erXos's own notice. A file the record lists cannot vanish
unless the record names it as removed, with a reason. A changed file
that cannot hold a comment, such as a regenerated `.beam`, is named in
its `ORIGIN.md` instead.

Suppose a fix changes a C file of musl. Its hash no longer matches
its row in `musl/ORIGIN.md`, so `make check` fails, naming the file,
until its header carries the change notice. The rule covers every
import whatever its license.

### D.4.2 Every image carries the notices of what it holds

Every file the packer puts into an image has a recorded origin and
license. A file erXos wrote carries `SPDX-License-Identifier:
BSD-2-Clause`. A file of an import is in its `ORIGIN.md`. A fetched
artifact has its `deps.lock` entry. A generated file takes the origin
of the inputs its build rule records. The packer learns what an image
holds from three sources: the linker's map of what each program
links, the compiler's dependency files, and its own list of the rest,
such as BEAM files, data and the contents of each EROFS image.
It fails on any file it cannot place.

From that closure it writes **`NOTICES`**, the file of every license
and copyright notice an image holds, as `system/NOTICES` in the system
image. Each distinct header comment once, under the files that carry it,
with their license; then each license text once. A license that
thousands of files share costs one copy. The design also puts the same
`NOTICES`, with the firmware's and device trees' licenses, beside the
boot image in each slot's boot partition; that copy is designed and
not built.

### D.4.3 One rule for which licenses a build takes

A permissive license enters every build. A license that is not
permissive enters only through one closed table, `LicenseCheck::TABLE`
in `tools/lib/erx/license_check.rb`, whose every row names one input:
its exact license, where the build reads it and which
kinds of build take it. The table has two rows:

1. Doom's archive, a demo program that is never part of the system,
   in development builds only;
2. Fiasco's `jdb_object.cpp`, in development builds only, a row the
   designed removal of Fiasco's debugger deletes (D.3.2).

The design admits a few more files by name and place, outside every
program and EROFS image: the Pi 4's device tree, with its source
beside it; the Raspberry Pi firmware in a board's boot partition; and
Cypress's firmware files as data. Test images, never distributed, get
an allowlist of their own for their test tools.

So a copyleft file that comes back into any other image fails the
build, naming the file and its license. The only images that leave the
project carrying copyleft code are the ones the website offers, served
with a link to the source they were built from.

## Summary

erXos takes outside code when it pays for itself, prefers permissive
licenses, and records each component, with what it does and its
license, in one table. Code it changes lives in the tree with an
`ORIGIN.md` that records every file's hash and license; code it uses
unchanged is pinned in `deps.lock`. Small libraries such as Monocypher
and ctaes keep OpenSSL out of the trusted base. A changed import file
without a change notice fails `make check`. The packer refuses a file
of unknown origin, writes `NOTICES` from the linker's own maps, and
admits a license that is not permissive only through one closed table
of two rows.

## Where to read next

* [design.md, Dependencies](../design.md#dependencies): the full
  table, with each row's origin.
* [design.md, Licenses and notices](../design.md#licenses-and-notices):
  the rules this appendix explains.
* [design-build.md, Sources and imports](../design-build.md#sources-and-imports):
  `deps.lock`, the fetch and the origin records.
* [design-fiasco.md](../design-fiasco.md): which parts of Fiasco the
  system builds, and the clean-room `kobject_rpc.h`.
* [design-network-stack.md, Provenance and notices](../design-network-stack.md#provenance-and-notices):
  how translated FreeBSD code keeps its notices.
