# Shared code: one copy of loaded Erlang code for every interpreter domain

Every domain that runs ERTS loads its own copy of the modules its release
uses: each prepares the same `lists`, `gen_server` and `erx_*` modules from
the same files, into its own memory, charged to its own budget. On a
160 MiB machine that copy is the largest single part of a domain's runtime
once its tables are sized to its limits. This document makes the loaded
code of the modules every domain release ships one copy for the whole
machine, for the domains that run the interpreter image `runtimes/emu`:
the code, the literals, and the atoms, exports and funs that the code
names. The ERTS executable's own text and read-only data are shared by a
separate mechanism of the image loader; the two fit together as [The
executable's own pages](#the-executables-own-pages) explains, and neither
depends on the other.

Decisions every reader needs:

* **The image is what loading produces, at the same addresses
  everywhere, and the build makes it.** The build runs `runtimes/emu`
  itself under QEMU, at the addresses every domain runs it at, and lets
  ERTS load the image's modules into three ranges at fixed addresses. It
  writes the result into the boot image as one more file, hashed and
  checked like every other. A domain granted the image has it mapped
  read-only at the same addresses. Nothing is relocated, so every page of
  it stays shared.
* **The image holds the preloaded modules and the applications every
  domain release ships**: `kernel`, `stdlib`, `erx` and `erx_files`
  (`ReleaseFiles::DOMAIN_BASE`, `tools/lib/erx/release_files.rb:68`).
  A module whose literals name an identity or hold a reference-counted
  binary, or that has an `on_load` function, is left out and loads
  privately, as today.
* **The system domain neither builds nor uses the image.** Its ERTS is a
  different executable, linked at the root task's place, so threaded code
  loaded there names handler addresses no domain shares.
* **Every name the code embeds is the same in every domain.** Atoms and
  catch labels are indices: the image's atoms and catches are a prefix of
  every domain's tables. Exports and fun entries are addresses: they are
  **cells**, records at a fixed address in a per-domain area that each
  domain builds itself. Everything else the code points at lies inside
  the image or in the ERTS executable, which is at the same address in
  every domain that runs `runtimes/emu`; the build proves that by building
  twice with everything else displaced.
* **Where a module's memory came from is its address.** A module whose
  code lies in the image's code range, or a literal area in the image's
  literal part, is the image's, whatever has happened to it since; the
  release rules of purging follow from the address alone.
* **Nothing writes the image.** Every write ERTS makes to loaded code goes
  through one preparation interface, which gives the domain private
  pages, at the same address and with the same bytes, before the first
  write to a module, and which a module that needs no write never reaches.
  The interface's handle is the only way to call OTP's code-write funnel.
* **Granted or not, and adopted or failed.** Whether a domain gets the
  image is a pure decision; a domain not granted it loads its code
  privately. A granted domain that cannot adopt it ends its start with a
  diagnostic; it never falls back.
* **BeamAsm domains share nothing of this.** Which domains run the
  interpreter is the open decision at the end of this document.

## The problem and its evidence

The owner's question was why ERTS code is not shared between domains to
save memory, with the constraint that the machine stays small: 160 MiB for
the development machine, and "we can't be eating 512M of ram" for an
embedded system.

**What a domain's runtime holds.** The system domain at the Erlang shell
(85 processes, 213 modules; Apple M3 Max, HVF, QEMU 11.1.3, Homebrew clang
23.1.3, 4 guest CPUs, interactive development image, one boot) reports
from `erlang:memory()`: total 16,021,056 bytes, of which `code` 7,972,341
and `atom` 343,161, and `literal_alloc` holds 2,050,008 bytes in use. These
are the runs behind commit 932db011, after ERTS's tables were sized from
the boot page's limits; the same domain held 9,268 `liberx` pool pages
(36.2 MiB) in that commit's own run. So loaded code and its literals are
about 10 MB of the 16 MB ERTS accounts for. The system domain is the one
ERTS domain measured at a shell so far; a session, which runs the same
applications' code under the domain interpreter image, has the same shape.

**What the image's contents cost in one domain.** `erlang:memory(code)` is
the module table, the export table and entries, the fun table and entries,
the code ranges and the loaded code itself
(`otp/erts/emulator/beam/erl_alloc.c:2492-2499`). A stock OTP 29.1.2
interpreter (`build/oracle/emu`, Apple clang 21.0.0, `-O2`,
`--disable-jit`, macOS on the Apple Silicon development host, measured
2026-11-10) that starts with `erl -noshell` and then loads every module
of erXos's built `kernel`, `stdlib`, `erx` and `erx_files` (243 of their
250 modules; the other seven have `on_load` functions that load NIFs and
fail on the host; 266 modules loaded in all, preloaded ones included)
reports from `erlang:system_info(allocated_areas)` and the literal
allocator's block sizes:

| Part | Bytes | Count |
| --- | --- | --- |
| loaded code | 9,858,951 | 266 modules |
| literal allocator blocks | 2,750,384 | |
| export entries + export table | 1,189,440 + 270,780 | |
| fun entries + fun table | 282,744 + 98,739 | |
| module table | 165,768 | |
| atom space + atom table | 244,544 + 278,665 | 18,364 atoms |

Loaded code and literals are 12.6 MB of it; everything else together is
2.5 MB. The research record of BeamAsm's first measurement agrees in
shape: a domain booting `kernel` and `stdlib` in embedded mode (244
modules) reports `code` 11,938,778 bytes under the interpreter
([research-g5-beamasm.md](research-g5-beamasm.md#footprint)).

**Literal binaries.** Of the 275 beam files of the preloaded modules and
those four applications, 14 hold literal binaries over 64 bytes, which
ERTS makes reference-counted (`ERL_ONHEAP_BINARY_LIMIT`,
`otp/erts/emulator/beam/erl_bits.h:167`): 49 binaries, 9,954 bytes in all
(measured from the beam files' `LitT` chunks, the same day). The modules
are `init`, `prim_tty`, `erl_erts_errors`, `erl_kernel_errors`,
`erl_stdlib_errors`, `c`, `epp`, `erl_lint`, `erl_tar`, `man_docs`,
`peer`, `shell`, `shell_docs` and `erx_schema`. The twelve other than
`init` and `prim_tty` load 1,022,010 bytes of code on the same stock
interpreter, `erl_lint` 316,899 of it; `init`'s and `prim_tty`'s beam
files are 69,796 and 64,856 bytes.

**What the code does today.** Each domain's loader prepares every module
itself. `beam_load_finalize_code` (`otp/erts/emulator/beam/emu/emu_load.c:560`)
allocates the code with `ERTS_ALC_T_CODE` and the literal area with
`ERTS_ALC_T_LITERAL` (`emu_load.c:70`, `:280`, `:324`), so both are the
domain's memory. Every domain other than the system domain runs one of
two runtime images of the boot archive, each linked at the same fixed
address (`liberx/backend/fiasco/task.ld:24`): the interpreter's,
`runtimes/emu`, which a domain row names as `runtime @artifact.emu`, and
BeamAsm's, `runtimes/jit` (`tools/lib/erx/production_image.rb:107-116`,
`tools/lib/erx/native_root.rb:152-171`). Sessions and command domains run
the interpreter's. The system domain runs an interpreter ERTS too, but
linked with the root task's own code at the root's place
(`liberx/backend/fiasco/root.ld:22`, `native_root.rb:76-80`), so its
handlers are at other addresses than any domain's. Releases come from
slices of the boot image, whose index records for each file the BLAKE3
hash of its file run, the file's bytes and the zeros after them to the
next page boundary (`abi/erx_abi.txt:231-239`,
[design-kernel.md](design-kernel.md#the-boot-image)).

**What sharing must overcome.** Interpreted code is threaded code: each
instruction word is the address of its handler in the emulator's text
(`otp/erts/emulator/beam/erl_vm.h:289`), and the operands hold absolute
pointers. Finalizing a module writes, into the code, the address of the
export entry of every function it imports (`emu_load.c:604-627`), of every
fun entry it creates (`:671-680`), of every literal (`:329-336`), and the
index of every catch label in the runtime's catch table (`:589-601`,
`otp/erts/emulator/beam/beam_catches.c:107-145`). Literal funs hold
pointers to fun entries (`emu_load.c:663`) and `fun M:F/A` literals are
the export entry's own external fun, a global literal
(`otp/erts/emulator/beam/external.c:5037-5038`, `export.c:44-57`). The
loader keeps global literals such as the empty tuple as pointers instead
of copying them into a module's literal area
(`otp/erts/emulator/beam/beam_file.c:1449-1459`), and every line table's
implicit file name ends in the global `".erl"` suffix (`beam_file.c:546`).
Atoms appear as tagged indices into the runtime's atom table. Export
entries are written on every code load, because staging copies each
entry's active address into the staging index
(`otp/erts/emulator/beam/erl_code_staged.h:392-416`, `export.c:102-107`).
Tracing and NIF loading write the code itself.

## Requirements

From the owner and from the working agreement, quoted where they are
rules:

1. Save memory per domain on a machine of 160 MiB, without giving up
   behaviour.
2. "erXos's Erlang behaves like stock OTP": OTP's suites on erXos are
   compared with stock OTP 29.1.2, and every difference is a bug, a
   documented difference with a test, or an upstream bug.
3. "copy-on-write shares only immutable pages: a child's parent can never
   be written."
4. "no mapping is ever writable and executable at once, and the kernel
   writes no machine code", and "the right to make code follows from the
   image": neither the system domain's image nor `runtimes/emu` makes code.
5. "every kernel allocation is charged to a budget carved from its
   parent's ... what must outlive a party is charged to a budget that
   outlives it."
6. "a pid is a name, not an authority", and the system domain's atom table
   grows only within bounds its own policy sets.
7. A loaded module that a domain replaces by hot loading is replaced for
   that domain alone; tracing, breakpoints and NIF loading in one domain
   are invisible to every other.
8. An image that does not match a domain's runtime is refused with a
   diagnostic, never misread.
9. No domain can write a page another domain runs, and no domain learns
   another's state through shared code.

## When this is built

The design is ready; its implementation waits for the system to need it.

* **The trigger.** Implementation starts when a real manifest runs three
  or more interpreter domains at once, which 1b-E reaches: the system
  domain, root's session, and the storage and network domains of
  [plan.md](plan.md); or earlier, when the start time of command domains
  needs it. The system domain never adopts the image, so of those four
  the adopters are root's session and the storage and network domains if
  they run the interpreter, which is open decision 1 below.
* **What comes first.** Each of these is cheaper and helps every domain,
  whether or not it adopts an image: ERTS's table sizing; the shared image
  segments of [The executable's own pages](#the-executables-own-pages);
  the JIT's first block as a per-image limit instead of 64 MiB in every
  BeamAsm domain (`TODO.md:337-342`); shrinking what each domain loads;
  and a measurement of a session's pages at its prompt, which replaces the
  estimates of [Memory saved and what it costs](#memory-saved-and-what-it-costs).
* **What it saves.** Measured: a domain at a shell holds about 10.4 MB of
  code, literals and atoms (the system domain above). Estimated, until
  the benchmark below runs: an image of about 12 MB, resident once; about
  7 MB saved per adopting domain at a shell, 5 to 7 MB for a session's
  release; so the image costs about 5 MB more than it saves with one
  adopting domain, about breaks even with two, and saves about 7 MB for
  each one after that.

## The image

### The central construction

Loaded interpreter code is position-dependent but contains no relocation
that differs between domains, provided four things hold in every domain
that uses it:

* the code and its literals are at the same addresses;
* the ERTS executable is the same, at the same address, which every domain
  that runs `runtimes/emu` has by `task.ld`;
* the atoms and catch labels the code names have the same indices;
* the export and fun entries the code names, and the global literals it
  points at, are at the same addresses.

The image makes all four hold by placement, never by relocation or
indirection. The build runs `runtimes/emu`, the same file every adopting
domain runs, at its own addresses, and while ERTS starts it serves every
allocation that loaded code can reach from three ranges whose bases are
constants of the runtime's address-space layout: code from the code range,
literals of every kind from the image's part of the literal range, export
and fun entries from the cell range. Every other allocation comes from
ERTS's ordinary allocators. A domain granted the image has the immutable
part, the code and literals, mapped read-only at the same addresses, and
rebuilds the mutable part, the atom prefix, the catch prefix and the
cells, from the image's lists with ERTS's own constructors. The image
therefore contains no snapshot of any mutable ERTS structure: no hash
table, lock or allocator state, which is what made Emacs's `unexec`
fragile. It contains immutable bytes and lists.

Pointer ownership is a checked property of the build, not a list to keep
complete: the build runs twice, the second time with every ordinary
allocation displaced, and requires byte-identical images. A word of the
image that points at anything outside the three ranges and the
executable's fixed segments differs between the two builds, whichever
loader path wrote it. So a pointer the design did not foresee fails the
build instead of reaching a domain.

Every requirement follows from that:

* sharing holds because the immutable part is never relocated, so its
  pages are the same in every domain (requirement 1);
* nothing writes the image because every mutable record the code reaches
  is private, and the one preparation interface privatises before any
  write to code (requirements 3, 7, 9);
* behaviour is stock because each domain's tables, cells and code are
  what a stock loader would have built, at different addresses only for
  the image's part (requirement 2);
* a mismatch is refused because the image is valid for one runtime file,
  whose hash the image records and the grant and the runtime check
  (requirement 8).

### What loaded code points at

`beam_load_finalize_code` (`emu_load.c:560-760`) and the emit step before
it produce every word of a module's code. Each kind of pointer is
same-in-every-domain for one reason in this table, and the displaced
build checks that no other kind exists.

| What the code embeds | Where it points | Same in every domain because |
| --- | --- | --- |
| instruction words | handlers in the emulator's text (`erl_vm.h:289`) | the executable is at one address |
| BIF function pointers and `bif_table` entries (`emu_load.c:137`, `:711-713`) | the executable's text and data | the executable is at one address |
| labels, strings, line table, function table (`emu_load.c:470-520`) | inside the module's code chunk | the chunk is at one address |
| the NIF vector `are_nifs` of a module that declares `-nifs` (`emu_load.c:1437-1446`) | inside the module's code chunk | finalizing copies it into the chunk, in every module, imaged or not |
| literals (`emu_load.c:329-336`) | the module's literal area | the literal area is in the image's literal part |
| global literals: the empty tuple, the `".erl"` suffix, the other `ERTS_GLOBAL_LIT_*` singletons (`otp/erts/emulator/beam/erl_global_literals.h:34-38`), and every export's external fun | ERTS's global literal chunks | every literal allocation of the build is in the image's literal part, and an adopting domain takes the singletons' values from the image |
| atoms | indices into the atom table | the image's atoms are a prefix of the table |
| catch labels (`emu_load.c:589-601`) | indices into the catch table | the image's catches are a prefix of the table |
| imports (`emu_load.c:604-627`) | export entries | export entries are cells |
| fun creation (`emu_load.c:671-680`) and literal funs (`:663`) | fun entries | fun entries are cells |

`are_nifs` is the one field of the interpreter's code header
(`otp/erts/emulator/beam/beam_code.h:59-85`) allocated apart from the
chunk: the loader allocates it from `ERTS_ALC_T_PREPARED_CODE` while it
prepares `op_nif_start`, and the purge frees it
(`beam_bif_load.c:2275-2278`). ERTS on erXos stores it at the end of the
code chunk instead, one byte per function, so it lives and dies with the
code in every module and the purge frees nothing for it. It is never
written after loading; `check_is_nifable` only reads it
(`otp/erts/emulator/beam/erl_nif.c:4700-4704`).

Record entries (`otp/erts/emulator/beam/erl_record.h:31-39`) are not on
the list: the code looks them up by module and name, and binding a module
registers its records as finalizing does (`emu_load.c:730-740`).

### Layout

Three ranges, each reserved in every interpreter domain at a base that is
a constant of the runtime's address-space layout, declared once in
`abi/erx_abi.txt` with the image's record layouts and generated into ERTS,
`liberx`, the domain library and the build's tools. All three lie above
the placement base, where fixed images and fixed mappings go
([design-kernel.md](design-kernel.md#virtual-memory)).

* **The code range** begins with the image's header and lists, followed
  by each module's code chunk, each starting on a page boundary and padded
  to the next one. Page-aligned modules let one domain privatise one
  module without touching a page of another; the padding costs about half
  a page per module, once for the machine.
* **The literal range** is ERTS's literal range itself. ERTS recognises a
  literal by its address alone on erXos, since `liberx` reserves and
  commits separately (`otp/erts/emulator/sys/common/erl_mmap.h:44`), which
  selects the range check (`otp/erts/emulator/beam/erl_alloc.h:193-196`,
  `:337-349`); literal pointers are tagged only in debug builds
  (`otp/erts/emulator/beam/erl_term.h:57-63`). The range, 1 GiB
  (`erl_mmap.h:65`), starts at the fixed base in every domain instead of
  where the literal mmapper places it (`otp/erts/emulator/sys/common/erl_mmap.c:2237`).
  Its first part, the **literal part**, holds everything the build
  allocated as a literal: the modules' literal areas and ERTS's global
  literal chunks. The literal allocator manages the rest for the domain's
  own literals. So shared literals are literals to the garbage collector,
  the copier and `erts_debug`, by the same check as any other.
* **The cell range** holds two areas, export cells and fun cells. Each
  kind of cell has one size, a property of the runtime build, so cell *i*
  is at its area's base plus *i* times that size.

The image is one file of the boot image, `runtimes/emu.code`, holding in
order the header and lists, the code chunks and the literal part, each
starting on a page boundary of the file, so that its pages map straight
to the code range and the literal part.

### The header and the lists

Every layout below is declared in `abi/erx_abi.txt` and read through its
generated bounded reader ([design-abi.md](design-abi.md)).

* **Header**: magic, format version, the BLAKE3 hash of the file run of
  the `runtimes/emu` entry the build ran, which is the `file_hash` the
  boot index records for that entry (`abi/erx_abi.txt:239`); the loader
  options it was built with (line tables on, debugger support off); the
  three bases and the lengths of the image's parts; the export and fun
  cell sizes; the count and offset of every list; and the value of each
  `ERTS_GLOBAL_LIT_*` variable, a list generated from the declarations of
  `erl_global_literals.h`, so a singleton OTP adds is carried without
  anyone remembering it.
* **Atoms**: every atom of the build's table beyond ERTS's built-in
  ones, in index order, as length and UTF-8 text.
* **Export cells**, in index order: module, function and arity as atom
  indices, and the address of the cell's external fun in the literal
  part.
* **Fun cells**, in index order: module, index, old unique number, old
  index, the module's MD5 and arity, which are `erts_fun_entry_put`'s
  arguments (`otp/erts/emulator/beam/erl_fun.c:287`).
* **Catches**, in index order: the code address of each.
* **Modules**: module atom, code header address, code length, page range,
  head of its catch chain, its export cells with their code addresses, its
  fun cells with their code addresses, its records (name atom and
  definition literal), whether it is preloaded, and for a module of an
  application its path within a release and the BLAKE3 hash of that
  file's file run, the value the boot index records for the file in every
  release that ships it.
* **Exclusions**: each module the build left out, with its reason.

The image needs no hash of its own: the boot index's `file_hash` for
`runtimes/emu.code` covers every byte of it, and the boot validator and
the file check at its first slice verify it
([design-kernel.md](design-kernel.md#the-boot-image)).

## Building the image

**What is shared.** The machine record of the system manifest sets
`shared_code_memory`, the largest image the build may pack; zero packs
none, and every domain then loads its code privately. The image holds
the preloaded modules and every module of `DOMAIN_BASE`, in a fixed
order, minus the exclusions below. Every domain release ships
`DOMAIN_BASE` (`release_files.rb:68-83`), so there is no per-release
choice of what is shared.

**The build run.** The build boots a build-only image under QEMU, with
TCG in deterministic mode (`erx.det=1`), on the build host. It holds the
stopgap kernel, a small native root that links `liberx`'s domain library,
as the `native_domain` suite's root does
(`tools/lib/erx/native_domain.rb`, `test/guest/native_domain/guest.c`),
the `runtimes/emu` file the boot image will carry, and a release of
`DOMAIN_BASE`. The root creates one **builder domain** with a fixed
argument vector and a boot information page that marks it as building.
The builder's ERTS builds the image on its one start-up thread, before
any scheduler or Erlang process exists, and halts. The root then writes
the image's bytes, raw, to the second UART, which the build connects to a
file of the build tree, and prints the image's length and BLAKE3 hash on
the console; the build accepts the file only when both agree.

This is the target's own loader running on the target's own executable,
at the target's addresses. There is no second loader on the host to keep
in step with ERTS, and nothing about the image depends on the machine
that later boots it.

**The build**, in the builder's ERTS start:

1. From `init_global_literals` (`otp/erts/emulator/beam/erl_init.c:264`)
   until the report, every `ERTS_ALC_T_LITERAL` allocation comes from the
   literal part, which places ERTS's global literal chunks there,
   singletons and export funs included
   (`otp/erts/emulator/beam/erl_global_literals.c:93-117`); export and fun
   entries come from the cell areas in creation order; code chunks come
   from the code range one page-aligned module at a time. The three ranges
   are the builder's own memory, mapped writable at their fixed bases.
   The code range allocator lets the module being loaded grow and shrink
   its last block, as the loader's `erts_realloc` requires
   (`emu_load.c:41`, `:280`).
2. At the point where ERTS loads its preloaded modules (`erl_init.c:511`,
   called at `:2530`), the build loads every module of the image's list
   in order, through the same prepare and finish steps that preloading
   uses, reading each file from the builder's release slice. Decoding a
   module's literals with a build-only flag of `erts_decode_ext` refuses
   the external term format's identity encodings, `PID_EXT`,
   `NEW_PID_EXT`, `PORT_EXT`, `NEW_PORT_EXT`, `V4_PORT_EXT`,
   `REFERENCE_EXT`, `NEW_REFERENCE_EXT` and `NEWER_REFERENCE_EXT`
   (`otp/erts/emulator/beam/external.h:41-64`), local and external
   alike. A module is excluded, and its prepared code and literals are
   given back so that none of its bytes reach the image, when it has an
   `on_load` function, when it fails to prepare, when its literals use an
   identity encoding, or when its literal area holds any off-heap object,
   which once identities are refused is a reference-counted binary.
3. The build writes the lists from its own tables and the header at the
   start of the code range, and hands the three ranges to the root, which
   lays them out as the image file.

**The displaced build.** The build runs twice. In the second run the root
reserves an extra range at the bottom of the builder's space before it
starts, so that every ordinary allocation of ERTS, `liberx` and musl lands
at another address, while the executable and the three ranges stay where
they are. The two images must be byte-identical; when they are not, the
build fails and names the first differing offset, the part of the image
it lies in and, in a code chunk or literal area, the module. Both runs are
deterministic, so any difference is a pointer into displaced memory.

**Packing.** The packer adds the image to the boot image as the file
`runtimes/emu.code`, without the system mark, and refuses it, failing the
build with a diagnostic, when its header's runtime hash is not the
`file_hash` of the `runtimes/emu` entry it packs, or when it is larger
than `shared_code_memory`. The image is a generated file: it lives in the
build tree and is never checked in. The build runs the step again only
when one of its inputs changes: the runtime file, the image's module
files, or the layout constants.

## Adopting the image

**The grant**, in the domain library, when it plans a domain: a domain is
granted the image when the boot image holds one, its runtime entry's
`file_hash` is the image header's runtime hash, its specification does not
set `shared_code none`, and its atom limit is at least the image's atom
count plus ERTS's built-in atoms. The decision is a pure function of the
specification, the runtime entry and the image's header. A granted
domain's creation plan maps the image's slice into the domain's space,
read-only, at the code range and the literal part, and marks the boot
information page; nothing about the image changes in a domain not
granted it, which loads its code privately, as today.

**Preflight**, in a granted domain's ERTS, at the start of `erl_init`
before `init_global_literals`: ERTS checks the header through the
generated reader (magic and format version, its own runtime entry's hash,
which the boot page carries, against the header's, its own loader
options, the bases, lengths and cell sizes against the layout constants
it was built with, and every list's offset and count against the image's
length, with checked arithmetic). It then computes the modules it binds:
every preloaded module of the image, and every module whose path within
the release and file hash appear in its own release slice's index.
Release paths in the archive carry each release's prefix
(`domains/<name>/`), so the agreement compares the path after it. The
check and the agreement are pure functions of the bytes they read and
build for the host. Last, ERTS commits the cell range's pages, the one
allocation adoption makes. Everything that can fail on input or on
resources fails here, before anything of the runtime has changed.

**The stages**, at the points where ERTS creates the corresponding state.
Past preflight, adoption only constructs; a stage that finds its
postcondition broken ends the start.

* **Globals**, at `init_global_literals` (`erl_init.c:264`): each
  `ERTS_GLOBAL_LIT_*` variable takes the header's value instead of a new
  literal, and the literal allocator starts after the literal part.
  `beamfile_init` (`beam_file.c:2065-2075`) and `erts_bif_info_init`'s
  literals (`otp/erts/emulator/beam/erl_bif_info.c:6398-6417`) take theirs
  the same way. So `{}` is one term in a domain, whether it came from
  image code or from `list_to_tuple([])`, as on stock OTP, where
  `is_zero_sized` compares it by address (`erl_term.h:192`).
* **Atoms**, right after the built-in atoms are created
  (`erl_init.c:287`): the stage requires that the table hold exactly the
  built-in atoms, then inserts the image's atoms in order with
  `erts_atom_put_index` (`otp/erts/emulator/beam/atom.c:231`) and
  requires each to land at the built-in count plus its position. Atoms
  ERTS creates later, its own or the domain's, come after the prefix, or
  find their name already in it.
* **Cells**, where the export and fun tables exist and are still empty:
  the stage requires both empty, then creates every export cell at its
  address with the initialiser that creates any export (`export.c:73`),
  except that the external fun is the image's instead of a new one; every
  fun cell with the fun table's initialiser (`erl_fun.c:87`); and the
  catch table's prefix, cons'ed in order so each lands at its index. Every
  cell starts as an unloaded function, as an import of a module not yet
  loaded does on stock OTP. When ERTS's own start then creates its BIF
  exports, `erts_export_put` finds the cells and initialises them as it
  would its own.
* **Binding**, at the point where ERTS loads its preloaded modules: for
  each module it binds, the stage creates the module table entry with the
  image's code header as the current instance, both its regions set to
  that header as finalizing does (`emu_load.c:574-575`), its catch chain
  and the **read-only mark**, which says only that the instance's pages
  are still the image's; it points the module's export cells and fun cells
  at its code in every code index, registers its records and code range,
  and adds its size to the total code size. ERTS then loads the preloaded
  modules the image does not hold, as today. The binding runs under the
  code staging protocol the preloading path uses.

**The code server** learns the bound modules from `init`. A BIF returns
the bound modules of applications with their paths; `init` adds them to
the list `init:fetch_loaded/0` returns (`otp/erts/preloaded/src/init.erl:459-461`),
which the code server reads at its start
(`otp/lib/kernel/src/code_server.erl:96-101`), and `init`'s `primLoad`
step skips a module that is already loaded (`init.erl:1387-1423`). So
`code:which/1` names the file, sticky directories stay sticky, and an
embedded boot loads nothing twice.

**What the domain owns.** Its atom table, catch table, module table, code
ranges, export and fun tables with their cells, its own global literals,
and every module it loads or privatises. **What it shares.** The bound
modules' code and literals, the external funs of its export cells, and
the global literals the image carries.

## Loading, purging and patching

**Hot loading** is stock: loading a new version of a bound module
prepares a private module in the domain's own memory, makes the image's
instance old and points the module's export cells at the new code. Every
other module, imaged or not, reaches the module through those cells, so
the domain runs the new version and no other domain notices. A module
loaded again with the image's very bytes is an ordinary private load; a
domain never re-binds an image module.

**Purging** is stock in what it decides and reports: `erlang:purge_module/1`
and `code:soft_purge/1` check processes against the old instance as they
do for any module. What the release block of `erts_internal:purge_module/2`
(`otp/erts/emulator/beam/beam_bif_load.c:2253-2296`) gives back follows
from addresses, by two rules:

* **Code backing.** An instance whose code header lies in the image's code
  range is released by releasing the module's page range from the
  domain's space, whatever backs it, the image's pages or the private
  copy a preparation made; it is never passed to `erts_free` (`:2283`).
  Any other instance is freed as on stock OTP.
* **Literal ownership.** A literal area that lies in the image's literal
  part is never queued for release (`:2322-2324`): it stays mapped until
  the domain ends, so terms that point into it stay valid and nothing has
  to copy them out. Any other literal area is released as on stock OTP.

Neither rule reads the read-only mark, so a module that was traced, then
hot-loaded over and purged, is released by the same rules as one never
touched. Cells are never freed: export entries are never removed, fun
entries stay in place after a purge (`erl_fun.c:224-241`), and staged
entries are freed only when an aborted staging erases what it added
(`erl_code_staged.h:312-330`), which never includes the oldest entries.

**Writes to code.** OTP routes every write to loaded code through one
funnel, because BeamAsm's executable mapping is read-only:
`erts_unseal_module`, `erts_writable_code_ptr` and `erts_seal_module`
(`otp/erts/emulator/beam/module.c:177-246`, declared at `module.h:59-76`).
Breakpoints of every kind, the breakpoint data a function's code info
points at, NIF stubs and the end of an `on_load` are written through it
(`beam_bp.c:404`, `:610`, `:699`, `:881`, `:1762`, `:1787`, `:2097`;
`erl_nif.c:5058`, `:5141`, `:5213`; `beam_bif_load.c:904`).

ERTS on erXos puts **one preparation interface** in front of that funnel,
`erx_code_prepare`, in the runtime's erXos layer. It takes a module
instance and an intent:

* **`write`** returns a **writable handle** for the instance. For an
  instance with the read-only mark it first privatises it: it prepares
  and funds a private copy of the module's pages, then, with thread
  progress blocked, puts the copy in place of the image's pages at the
  same addresses and clears the mark. When it cannot get the memory it
  fails and changes nothing. It runs only where blocking thread progress
  is allowed and a refusal can still be returned, which it asserts.
* **`clear`** returns a handle for a private instance and none for an
  instance with the read-only mark. An instance that was never prepared
  holds no breakpoint, no breakpoint data and no NIF stub, because adding
  any of them needs a `write` handle, so there is nothing in it to undo
  and the caller skips it.

The funnel takes the handle, not an instance: `erts_unseal_module`,
`erts_writable_code_ptr` and `erts_seal_module` cannot be called on an
instance that was not prepared, and the mechanical edit of their call
sites is checked by the compiler. The handle's type is opaque outside the
interface's file, and the build check described in
[Verification](#build-checks) fails the build on any other file that
makes one. Behind both, the image is mapped read-only, so a write that
bypasses them faults in the domain that made it.

The callers are few because the matchers already collect what a write
covers. `erts_bp_match_functions` (`beam_bp.c:185`) asks for `write` when
its caller sets breakpoints, from `erts_set_trace_pattern`
(`otp/erts/emulator/beam/erl_bif_trace.c:2634`) and
`erts_debug:breakpoint/2` (`otp/erts/emulator/beam/beam_debug.c:324`),
and `clear` when it clears them, as a trace session's end does for every
function (`erl_bif_trace.c:1380`, `:2767`), whether the session ends by
`trace:session_destroy/1` or because its owner is gone, and as global
tracing's removal does (`:2898`); it keeps the handle with the functions
it matched and drops the functions of an instance it gets none for.
`erl_debugger:breakpoint/3` (`otp/erts/emulator/beam/erl_debugger.c:292`)
and `load_nif/2` (`erl_nif.c:4622`) ask for `write` on their one module.
`erts_clear_module_break`, a NIF library's unload and upgrade, and the end
of an `on_load` ask for `clear`, `write` and `write`: the first two reach
only instances that already hold breakpoints or stubs, and a module with
`on_load` is never in the image. A new writer of code in OTP cannot reach
the funnel without a handle, so the question of which callers privatise
first has no list to keep.

If the domain's budget refuses the pages, the requesting BIF fails as it
fails for any resource it cannot get, `system_limit` for the three
breakpoint BIFs and `{error, {load_failed, Text}}` for `load_nif/2`, with
no breakpoint set and no stub written; the modules prepared so far stay
private. `erlang:trace_pattern/3` may match many modules at once: tracing
every local function of the image would privatise about 9 MB.

Global call tracing that is set leaves loaded code alone: its breakpoints
live in the export entry (`beam_bp.c:2181-2199`), which is a cell. A pure
read of a bound instance needs nothing: `module_info/0,1`,
`erlang:fun_info/2`, `erts_debug:df/1` and stack traces read the code.

**Garbage collection and copying** need nothing: shared literals are in
the literal range, and the collector and the copier skip literals
(`otp/erts/emulator/beam/copy.c:105-132`, `otp/erts/emulator/beam/erl_gc.c:2013`).
No literal of the image is reference-counted, since a module with such a
literal is excluded, so no copy of a literal into ETS, a port or a purge's
literal collection writes a count in the image.

## Behaviour against stock OTP

Everything Erlang code can observe of a bound module is what a stock node
shows for a module it loaded at boot: `code:which/1`, `module_info/0,1`
and its MD5, `erlang:fun_info/2`, `erlang:phash2/1` of funs, external fun
equality, the identity of `{}`, hot loading, `code:purge/1`,
`code:soft_purge/1`, `code:delete/1`, `erlang:check_process_code/2`,
tracing of every kind, NIF loading, ETS and message copies of literals.
Excluded modules load privately and behave exactly as today.

Documented differences, each with its own test:

* **Bound modules are loaded from the start.** In embedded mode the boot
  loads them anyway, so nothing differs. In interactive mode
  `erlang:module_loaded/1`, `code:is_loaded/1`, `code:all_loaded/0` and
  `erlang:loaded/0` show them before their first call.
* **Every atom of the image exists from the start**, in every domain that
  adopts it, so `list_to_existing_atom/1` and `binary_to_existing_atom/2`
  succeed for them and `erlang:system_info(atom_count)` is higher.
* **Every export and fun of the image has an entry**, unloaded where its
  module is not bound, visible only in the table sizes of
  `erlang:system_info(info)`.
* **`erlang:memory/0`** counts bound code in `code` and `total`, as OTP's
  BeamAsm build counts code that lives outside ERTS's allocators
  (`erl_alloc.c:2508-2513`), and bound literals in `system` and `total`,
  so a domain's figures read as a stock node's with the same modules
  loaded. What is shared and what is private is the inspector's to say.

## Charging and inspection

The image's pages are boot-image pages: resident from boot, never changed
and never freed ([design-kernel.md](design-kernel.md#the-boot-image)),
counted where the boot image is counted and in no domain's budget. The
domain library's one slice of `runtimes/emu.code` is charged to the root's
budget. A mapping charges the mapping space only its records and
translation tables, however many spaces map the image
([design-kernel.md](design-kernel.md#virtual-memory)). A domain's cells,
its share of the tables, its privatised modules and its own modules are
charged to its own budget. Nothing is charged at boot for building, since
the build ran on the build host.

The inspector shows, for the machine: whether the boot image holds an
image, its size by part (header and lists, code, literals), its module,
atom and cell counts, and its exclusions with their reasons, read from
the image; and its `file_hash` from the boot index. For each domain:
whether it was granted the image and the reason when not, the number of
bound modules, the privatised modules, and its cell bytes. A value the
stopgap cannot measure, such as a domain's resident shared pages, is
shown as unsupported with its reporter named.

## Concurrency

The build runs on the builder's one start-up thread on the build host,
and nothing at boot writes the image. Adoption runs on a domain's one
start-up thread, before ERTS creates a scheduler or any Erlang process
(`erl_init.c:264-312`, `:2530`), so it meets no other thread of its
runtime; the image was mapped by the domain library before that thread
started.

After start, cells are export and fun entries, written under ERTS's
existing staging lock and code permissions as any entry is. A `write`
preparation runs in the requesting BIF, under code modification
permission, with thread progress blocked for the swap, as loading over a
traced module blocks it (`beam_bif_load.c:462-472`). No managed scheduler
runs code during the swap. A thread that is not a managed scheduler never
runs threaded code of a module that still has the read-only mark: dirty
schedulers enter a module's code only through a NIF stub, and a NIF stub
exists only once its module is prepared. The purge's release of an
image instance runs under code modification permission, after the purge
has established that no process runs the instance, as stock OTP's
`erts_free` of the same code does.

## Failure handling, refusals and error results

**The build.** A module with `on_load` is excluded with reason `on_load`;
one that fails to prepare with reason `load_error` and the loader's error,
and fails the same way when a domain loads it privately; one whose
literals use an identity encoding with reason `literal_identity`; one
whose literal area holds a reference-counted binary with reason
`literal_binary`. Exclusions are not failures. The build fails, with a
diagnostic and no boot image, when the build run ends without an image or
misses its deadline, when the two runs' images differ, when the transfer's
length or hash disagrees with the console's, when the image's runtime
hash is not the packed runtime's, and when the image is larger than
`shared_code_memory`.

**The grant.** A domain is not granted the image when the boot image holds
none, its runtime entry is not the image's (a BeamAsm domain among them),
its specification sets `shared_code none`, or its atom limit is below the
image's atoms plus ERTS's built-in atoms. The domain library records which
reason, the inspector shows it, and the domain loads privately. This is a
decision, not a failure.

**Adoption.** A granted domain that cannot adopt the image ends its start
with a diagnostic naming the reason, from a closed set declared in the
ABI: `format`, `runtime`, `loader_options` and `layout` from the header
check, `memory` when the cell range's commit is refused, and
`postcondition` when a stage finds a table not empty or an atom or catch
at the wrong index. The domain library takes the failed start as it takes
any, and the domain's supervisor in the system domain decides what
follows. A granted domain never falls back to loading privately: a
failure here means a damaged boot image, a build defect or a budget sized
without the cells, and each is a bug to see, not a mode to run in.

**After start.** A BIF that must privatise and cannot get the pages fails
with no breakpoint set and no stub written: `system_limit` from the three
breakpoint BIFs, `{error, {load_failed, Text}}` from `load_nif/2`. On the
stopgap only, a refusal after the image's pages are released and before
the copy is in place ends the domain with a diagnostic
([Phase 1](#phase-1-on-the-stopgap)). The purge of an image instance
reports as usual.

## Security

**The image is part of the trusted boot image.** It is made by the build
that makes the runtime it runs on, from the same installed files each
domain would otherwise load, and it is one file of the boot image, under
the same `file_hash`, boot validator and file check as the runtime
executable itself ([design-kernel.md](design-kernel.md#the-boot-image)).
Whoever could change it could change `runtimes/emu`. An adopting domain
verifies nothing beyond what boot verification did; its header check and
the image reader's bounds guard against a malformed artifact, as every
reader of a boot file does, not against a forged one. No party at boot
builds, supplies or seals anything, so the image adds no party to any
domain's trusted base.

**No domain writes a page another domain uses.** The image's pages are a
slice of the boot image, which no mapping can write
([design-kernel.md](design-kernel.md#memory)). The domain library maps
it with read permission only, so the mapping's ceiling admits neither
write nor execute (K4, K8), and no domain holds a capability to the image
from which to make another mapping. Every write a domain's runtime makes
on behalf of loaded code goes to its cells or to pages it privatised, in
its own space.

**The image holds no authority.** Its contents are a pure function of the
runtime file, its loader options and the installed files of
`DOMAIN_BASE`; the build ran with a fixed argument vector, before any
domain exists, and no domain's actions change the image. Its literals
hold no pid, port or reference of any kind, local or external, because
the build refuses those encodings and leaves the module out, and it holds
no capability.

**The atom bound.** The image's atoms come from installed modules, count
against each adopting domain's atoms limit, which the grant checks, and
are inserted at the domain's start, not from any frame. The system
domain's atom table gains none of them.

**Residual: shared pages and timing.** The interpreter reads threaded
code as data, and user mode may clean and invalidate cache lines by
address ([design-runtime.md](design-runtime.md#beamasm)), so one domain
can time access to a page it shares with another and learn when the other
ran code on it, and can slow the other by evicting it. The image's pages
and the ERTS executable's shared pages ([below](#the-executables-own-pages))
both open this channel, through any ERTS path, not only the code a
secret's handling runs; general cache and scheduling channels remain
besides. This is one residual for both kinds of page, settled at the
security closure. A domain's specification can set `shared_code none`,
which leaves the image unmapped in it; its executable pages stay shared.

## Memory saved and what it costs

Estimates, from the measurements above; the benchmark below replaces
them.

* **The image** holds about 8.8 MB of code (the 9.9 MB measured, less
  about 1.1 MB for the excluded modules) and about 2.8 MB of literals,
  plus about 0.5 MB of page padding and under 1 MB of lists: about 12 MB,
  resident once in the boot image. Its literal part also holds the
  build's global literal names of atoms, about 0.25 MB, which no domain
  reads.
* **Each adopting domain** builds cells and tables for every export and
  fun of the image, about 1.5 MB and 0.4 MB, a module table entry per
  bound module, at most 0.17 MB, and the atom prefix, about 0.5 MB: about
  2.5 MB. It also loads privately whichever excluded modules it uses, at
  most about 1.2 MB of code.
* **A domain at a shell**, of the shape measured in the system domain,
  holds today about 8.0 MB of `code`, 2.0 MB of literals and 0.3 MB of
  atoms, about 10.4 MB; with the image it holds about 3 to 3.5 MB, a
  saving of about 7 MB. A session's release saves 5 to 7 MB, depending on
  how many of the image's modules it reaches.
* **Machine-wide**, the system domain's own use is unchanged. With one
  adopting domain the image costs about 5 MB more than today; with two the
  costs are about even, and each further adopting domain saves about
  7 MB. Four sessions or command domains would hold about 26 MB instead of
  about 42 MB.

**Start-up.** Boot carries nothing for the image: no domain is created
for it and nothing is copied. Each adopting domain inserts about 18,000
atoms and 9,000 cells and has its image mapped, instead of preparing its
modules, which the same research measured at 92 ms for a 244-module
embedded boot ([research-g5-beamasm.md](research-g5-beamasm.md)).

**Build time.** The build run is two ERTS starts to the point of
preloading, under TCG in deterministic mode, each preparing about 240
modules, and a transfer of about 12 MB over the second UART. Neither cost
is measured; both go on the performance watch list, and a transfer too
slow for the UART moves to the virtio-console transport that
[design-live.md](design-live.md#performance) names for the host link.

**Per call.** Nothing: the code and cells are what a private load
produces, and the interpreter's path is unchanged.

**Privatising** costs a copy of the module's pages and one blocking of
thread progress, once per module per domain, on the first local trace,
breakpoint or NIF load.

The benchmark that settles these, `tools/erx bench shared-code`, beside
G5's (`tools/lib/erx/bench_g5.rb`), boots the development image with one,
two and four sessions, with the image and with `shared_code_memory` set
to zero, on HVF, QEMU 11.1.3, 4 CPUs, one boot each way, and records each
domain's pool pages and `erlang:memory()`, the image's size by part, the
boot time to the prompt, each domain's start time, the time to set a
local trace pattern on one imaged module, and `erx_otp_bench`'s
call-heavy cases with and without the image; and on the build host, the
build run's duration and the transfer's. Adoption's cost, privatising's
cost and the per-domain cells belong on the performance watch list until
it runs.

## Phase 1, on the stopgap

The stopgap backend has what the image needs. `erx_vm_map` of a slice
maps the archive's own pages read-only with `l4_task_map` from the root
(`docs/design-stopgap.md:519`), so every domain that maps the image shares
its frames, and the physical saving is real on the stopgap.

**One mapping per module is the stopgap's shape.** The stopgap cannot map
over a mapping or cut one (`docs/design-stopgap.md:517`), so the domain
library maps the header and lists with one mapping, each module's code
chunk with one mapping of its own, and the literal part with one: about
250 mapping records for the image, well under the 65,536 a space allows
([design-kernel.md](design-kernel.md#memory)). On erXos's kernel the code
part and the literal part are two mappings, and a range call cuts what it
needs.

**Privatising.** On erXos's kernel the swap is one `ERX_VM_FIXED` mapping
of the prepared copy over the module's page range, which replaces the
image's pages there or fails and leaves them, since a range call is
planned whole, its allocations made and its charge taken before anything
changes ([design-kernel.md](design-kernel.md#overview), the row for range
calls). On the
stopgap the copy is a memory object of the domain's budget, created and
filled through a scratch mapping before the swap, so it is funded before
anything is released; the swap then releases the module's mapping,
reserves its range again and maps the object there. A refusal at either
of the last two steps leaves live code unmapped and cannot be undone in
user mode, so the runtime ends the domain with a diagnostic naming the
module. That is a residual of the stopgap, recorded and not worked
around; erXos's kernel has no step between.

**Purging.** Releasing an image instance's page range is releasing the
module's whole mapping on the stopgap, and a range release on erXos's
kernel.

The stopgap's pool reports a domain's use as partial, with its reporter
named, and the inspector shows it so.

## The executable's own pages

The image loader shares the ERTS executable itself by a separate
mechanism: for an image entry such as `runtimes/emu`, `erx_image_map`
maps the read-only and read-execute segments from the boot archive's own
pages, through one slice per entry that the root keeps, charged to the
root, and copies only the writable segments into each space. That is the
`erx_image_slice` and `erx_image_map` row of
[design-stopgap.md](design-stopgap.md) as the shared image segments change
(branch `shared-segments`) writes it; the row on master copies every
segment. This section depends on that change for the executable's pages
being shared; nothing else in this design does. Every domain that runs
`runtimes/emu` then holds one physical copy of its text and read-only
data.

The two fit together without touching:

* **This design needs only the executable's addresses.** Loaded code
  points into the executable's text and data, which `task.ld` places at
  one address in every domain whether its pages are shared or copied. So
  the image works with or without shared executable pages, and they work
  with or without the image.
* **They share no memory or range.** Both are archive pages, never written
  by anyone; the executable's are at `task.ld`'s program range, the
  image's at the ranges above the placement base. Neither maps into the
  other's range.
* **Nothing written crosses between them.** Privatising copies loaded
  Erlang code, which is data to the interpreter, in the image's code
  range; it never touches the executable's text. The executable's
  writable segment, which holds ERTS's own variables, is private in each
  space either way.
* **They name the runtime the same way.** The grant compares a domain's
  runtime entry with the image's by the entry's BLAKE3 `file_hash`, the
  same entry whose pages the loader shares; one boot image cannot hold
  two different executables under one entry, so a domain whose executable
  pages are the shared ones is exactly a domain the image matches.

Together, an adopting domain holds privately only the executable's
writable segment, its own tables and cells, and the code it loads or
privatises itself. The residual of [Security](#security) covers both
kinds of shared page.

## What is not shared, and why

* **BeamAsm's code.** It is machine code in each domain's JIT objects, which
  never leave the space that made them (K8). Sharing it needs translation
  ahead of time with relocatable output, the third option of
  [design-runtime.md](design-runtime.md#running-erlang-code-the-options),
  a design of its own.
* **Literals alone for BeamAsm domains.** About 2 MB per domain, but it
  needs the atom prefix and the cells anyway, and a JIT loader that reads
  prepared literals. Not worth it now.
* **The atom table itself.** Sharing its entries would save about 0.5 MB
  per domain, but a hash table's growth rewrites every entry's chain.
* **The system domain's loaded code.** Its ERTS is linked with the root
  task at the root's place, so its threaded code names handlers at
  addresses no other domain has. Sharing with it would need the system
  domain to run `runtimes/emu` at `task.ld`'s addresses, which would make
  the root a task program; the saving, one domain's code, does not pay
  for that.
* **Excluded modules**, applications outside `DOMAIN_BASE`, files of
  another version than the image's, and modules a domain reads later from
  an EROFS image: they load privately.

## Verification

### Host tests

The functional core builds for the host: the image reader and header
check, the agreement between an image's modules and a release index, and
the grant decision.

* **Header check.** A valid header passes; each field corrupted in turn
  (magic, version, runtime hash, loader options, each base, each cell
  size, each list's offset and count, an offset plus count that overflows)
  is refused with its reason. Seeded fault: the bound on one list's offset
  removed; the case with that offset past the image's end then fails, and
  ASan reports the read.
* **Agreement.** Same path and file hash binds; same path with another
  hash, another path, or a module absent from the release does not; a
  preloaded module always binds; a path under another release's prefix
  binds when the path within the release and the hash agree. Seeded fault:
  comparing paths only; the other-hash case then binds and fails.
* **Grant.** A domain that runs the image's runtime entry, with
  `shared_code default` and enough atoms, is granted; one that runs
  `runtimes/jit`, one with `shared_code none`, and one whose atom limit is
  one below the image's count plus the built-in atoms are not, each with
  its reason. Seeded fault: the runtime entry comparison dropped; the
  BeamAsm case is then granted and fails.
* **Fuzz target.** The image reader, the header check and the agreement,
  over arbitrary image bytes and release indexes, run by
  `make check-fuzz`, since they parse a boot file.

### Build checks

* **The displaced build.** Every image build runs it. Seeded fault:
  `are_nifs` allocated from `ERTS_ALC_T_PREPARED_CODE` again instead of in
  the chunk; the image of a module that declares `-nifs` then differs
  between the two runs and the build fails naming that module.
* **Exclusions.** A fixture release beside `DOMAIN_BASE` holds four
  modules, one each with a local pid literal, an external reference
  literal, a literal binary of 1 KiB and an `on_load` function, built
  from hand-made beam files where the compiler cannot produce them. The
  image's exclusion list names each with its reason and its module list
  holds none of them. Seeded fault: the identity refusal dropped from the
  build's decoder; the pid module is then in the image and the check
  fails.
* **One preparation interface.** The check fails the build on any file
  other than the interface's own that defines the writable handle's type
  or casts to it, and on any call of the funnel whose argument is not a
  handle. Seeded faults: a cast of a module instance to the handle in
  `beam_bp.c`, and a call of `erts_unseal_module` on `&modp->curr`; each
  fails the check.
* **Packing.** The packer refuses an image whose runtime hash is not the
  packed runtime's. Seeded fault: the comparison dropped, with an image
  built from a runtime that differs in one byte; the boot image then
  packs, and the check fails.

### QEMU tests

Sessions under the development image, each test in its own domains so
its seeds stay local.

* **The image is adopted and bound.** The inspector shows two sessions
  granted the image, both bound to the image's module count less its
  exclusions, and the image's pages in neither domain's budget. Seeded
  fault: the binding stage skips the last module; the bound count then
  differs and the test fails.
* **A granted domain that cannot adopt ends its start.** A test hook makes
  one domain's boot page carry another runtime hash: that domain's start
  ends with the `runtime` diagnostic, the inspector shows the failed start,
  and the other session reaches its prompt. Seeded fault: adoption falling
  back to private loading on refusal; the domain then reaches its prompt
  and the test fails.
* **A domain not granted loads privately.** A domain with `shared_code
  none` reaches its prompt with no image mapped and the reason shown.
  Seeded fault: the grant ignoring the specification; the domain then
  adopts and the test fails.
* **The image is mapped read-only and never executable.** The inspector
  shows every image mapping of a session with read permission only, and a
  test hook's store to an image page ends that session with a fault while
  the other keeps running. Seeded fault: the domain library maps the image
  with read and execute; the inspector then shows execute and the test
  fails. That a slice is never writable is the slice calls' own property
  on both kernels (on the stopgap, a write right on a slice is
  `ERX_ERIGHTS`, `docs/design-stopgap.md:519`), tested with them, not
  here.
* **Tracing is private and stock.** Domain A sets a local trace pattern on
  a function of an imaged module that a looping process in A calls
  locally; A receives the trace messages, the inspector lists the module
  as privatised in A, and domain B, calling the same function, receives
  none and still shows it read-only. Seeded fault: `write` returns its
  handle without privatising; the breakpoint's store then faults on the
  image page, A ends, and the test fails.
* **Every writer prepares.** In A, `erts_debug:breakpoint/2`,
  `erl_debugger:breakpoint/3` and `load_nif/2` from an imaged module that
  declares `-nifs` each succeed, and the inspector lists the three modules
  privatised in A and none in B. The same seeded fault as above fails each.
* **Clearing writes nothing to read-only modules.** In A, with every
  imaged module read-only: a trace session created and destroyed empty, a
  session whose owner process exits, global call tracing set and removed
  on an imaged export, and `erlang:trace_pattern({'_', '_', '_'}, false,
  [local])`; A keeps running and the inspector lists no module
  privatised. Seeded fault: `clear` returning a handle for a read-only
  instance; the first cleanup's store then faults and the test fails.
* **A refused preparation sets nothing.** A domain with little budget to
  spare matches every local function: `trace_pattern` raises
  `system_limit`, `erlang:trace_info/2` shows no breakpoint on any
  function it matched, and the domain keeps running. Seeded fault: the
  preparation run after staging instead of before; breakpoints on the
  modules prepared before the refusal are then set and the test fails.
* **A failed swap.** A test hook refuses the swap's mapping. On erXos's
  kernel `trace_pattern` raises `system_limit` and the module stays
  read-only and runs; on the stopgap the domain ends with the diagnostic
  naming the module, and B runs on. Seeded fault: the runtime returning
  `system_limit` and resuming on the stopgap; the next call into the
  module then faults without the diagnostic and the test fails.
* **Hot loading is private.** A probe module of `DOMAIN_BASE`'s test build
  returns 1; A loads a version returning 2, B still gets 1. Seeded fault:
  the cell range mapped from one shared object into both domains; B then
  gets 2 and the test fails.
* **Trace, hot load, purge.** In A, a process keeps a literal of the probe
  module; A sets a local trace pattern on the probe, loads a new version
  and purges the old one: `code:purge/1` returns `true`, the process still
  reads its literal, A keeps loading and running, and the inspector shows
  the probe's private copy released. Seeded faults: the purge deciding by
  the read-only mark instead of the address, so the privatised instance
  reaches `erts_free` and A crashes; and the image's literal area queued
  for release, so the kept literal's area is freed. Each fails the test.
* **Global literals are one term.** An imaged module returns `{}` and
  `{{}}`: in A, `erts_debug:same/2` of the first and `list_to_tuple([])`,
  and of the second's element and the same, is `true`, and
  `erts_debug:size/1` of each is what it is on stock OTP; a stack trace
  through the module names `"probe.erl"`. Seeded fault: the adopter making
  its own empty tuple; `erts_debug:same/2` then returns `false` and the
  test fails.
* **The atom prefix holds.** An imaged module's function returns an atom
  literal and `M:module_info(module)` is `M` in every domain. Seeded fault:
  two image atoms inserted in swapped order; the stage's postcondition
  then ends the start and the test fails.
* **The documented differences.** Each item of [Behaviour against stock
  OTP](#behaviour-against-stock-otp) has a case that shows it.

### The oracle

`make check-oracle` runs OTP's suites in an interpreter test domain with
the image and compares them case by case with the stock interpreter build
at `build/oracle/emu`. The suites that exercise this design most are
`erts/emulator/test`'s `trace_SUITE`, `trace_local_SUITE`,
`trace_call_count_SUITE`, `trace_call_time_SUITE`, `call_trace_SUITE`,
`trace_session_SUITE`, `code_SUITE`, `fun_SUITE`, `nif_SUITE`,
`erts_debug_SUITE`, `persistent_term_SUITE`, `process_SUITE` and
`bif_SUITE`, with `literal_area_collector_test`, and `kernel`'s
`code_SUITE`. A difference that disappears with `shared_code_memory` set
to zero is this design's, and is a bug or one of the documented
differences.

## Interfaces

* **ABI** (`abi/erx_abi.txt`): the three bases and spans; the header, list
  and module record layouts; the format version; the grant's reasons, the
  adoption failure reasons and the exclusion reasons; the boot information
  page's entry for the image (whether the domain builds, adopts or has no
  image); the inspector's records for the image and for a domain.
* **System manifest**: the machine record's `shared_code_memory`; each
  domain specification's `shared_code`, `default` or `none`.
* **The build**: the build run's native root and its manifest; the
  displaced second run; the transfer over the second UART; the packer's
  checks and the `runtimes/emu.code` entry.
* **ERTS**: the build, preflight, the stages, `erx_code_prepare` and its
  handle in one erXos file of the runtime's `sys/erxos` layer, around the
  pure header check and agreement; the placement of literals, cells and
  code during the build in `erl_global_literals.c`, `export.c`,
  `erl_fun.c`, `erl_code_staged.h` and the code allocator; `are_nifs` in
  the chunk in `emu_load.c` and the purge; the decoder's identity flag in
  `external.c`; the stage calls in `erl_init.c`, `beam_file.c` and
  `erl_bif_info.c`; the funnel's handle in `module.c` and its call sites
  in `beam_bp.c`, `erl_nif.c` and `beam_bif_load.c`; the matcher's intent
  in `beam_bp.c` and its callers in `erl_bif_trace.c` and `beam_debug.c`;
  the purge's two release rules in `beam_bif_load.c`; the literal range's
  fixed base in `erl_mmap.c`; the memory figures in `erl_alloc.c`; and in
  `init.erl`, the bound modules in `fetch_loaded/0` and the `primLoad`
  skip.
* **`liberx`**: the swap of one module's pages for a prepared private
  copy, as one fixed mapping on erXos's kernel and as release, reserve and
  map on the stopgap.
* **The domain library**: the grant decision; one slice of the image; and
  mapping it read-only into a granted domain's space in its creation plan.

## Alternatives considered

* **Indirection instead of placement.** A per-domain import table at a
  fixed address, as a global offset table or .NET ReadyToRun's indirection
  cells do, would leave the code free of export addresses, but every
  external call would load one more word, the interpreter's call
  instructions would change, and literal funs would still hold entry
  pointers. AtomVM, which runs BEAM files in place from flash, translates
  each module's atom indices through a table of its own; placement keeps
  the interpreter's instructions as they are, and sharing code without
  relocation by other means is not worth that change.
* **Relocation at mapping time**, as the JVM's class data sharing does when
  its archive cannot map at the requested address, or Emacs's portable
  dumper always does: every page holding a relocation becomes private, so
  little code would stay shared.
* **Copy-on-write children of the image, or a zygote.** The kernel's child
  copies a page into itself at its first read as well as its first write,
  and never maps the parent's page
  ([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces)),
  so a child of the image, or a domain forked from a started one, shares
  nothing it touches. A zygote would also carry hash tables, locks and
  allocator state across runtimes, which is what broke `unexec`.
  Privatising is the runtime's own copy-on-patch, at the granularity of a
  module.
* **Building at boot, in a builder domain.** It needs a protocol between
  the builder and the domain service, an image object that outlives the
  builder, a boot-time peak of the builder's runtime, its build memory and
  the image together, and it makes the builder's output part of every
  adopter's trusted base. Building at build time removes all four.
* **Building on the host with a host-side loader**, as CDS archives and
  Android's boot image are built by a host tool: the threaded code is
  valid only for the target executable, so a host tool would be a second
  loader that must agree with ERTS's word for word. Running ERTS itself
  under QEMU has no second loader.
* **Cells for literal binaries.** A per-domain cell per reference-counted
  literal binary, allocated at its final address while the build decodes
  it so that every bitstring's cached base already points there, would
  keep the 14 excluded modules in the image, about 1.2 MB of code. It
  costs a third kind of cell, a list and an adoption step. Trigger: the
  benchmark showing those modules' private copies as a large part of an
  adopting domain.
* **Binding on first load**, by matching a loaded file's hash against the
  image, as stock interactive mode loads on first call: it removes the
  first documented difference and the cells' cost for unbound modules, but
  every load path consults the image, the code server depends on it, and
  the atoms must still all exist at start. Trigger: a suite or user that
  depends on interactive-mode loading order.
* **Cells only for what a domain binds**, from per-module reference lists:
  saves about 1 MB in a domain that binds a small part of the image, for
  lists, sparse commits and a check that the lists are complete. Trigger:
  the benchmark showing cells as a large part of small domains.
* **Larger or layered images**, adding applications some releases ship,
  as CDS's dynamic archives and Android's app images do: `DOMAIN_BASE` is
  what every domain shares today. Trigger: several domains sharing
  applications outside it.
* **A per-domain breakpoint table** consulted by the interpreter instead of
  patched code: it changes the interpreter's hot path, which privatising
  avoids.

Other prior art that this design follows: Plan 9 shares a program's text
between processes and gives each its own data and bss at fixed addresses,
which is the image and its cells; V8 shares its read-only heap and
embedded builtins between isolates and deserialises the rest per isolate;
L4Re's dataspaces and Zircon's virtual memory objects are read-only memory
mapped by many tasks, the role the boot image's slice plays here; OTP's
own literal areas and `persistent_term` keep immutable terms outside
process heaps, which is what lets shared literals need no change to the
collector.

## Open decisions

1. **Which domains run the interpreter image.** Sessions and command
   domains run `runtimes/emu`; every other ERTS domain except the system
   domain runs BeamAsm unless its specification chooses the interpreter
   ([design-runtime.md](design-runtime.md#beamasm)). The choice turns on
   BeamAsm's 64 MiB first JIT block, which every BeamAsm domain commits
   before it loads a module (`TODO.md:337-342`), not on this image, which
   saves an interpreter domain about 7 MB against that 64 MiB.
   Recommendation: make the first block a per-image limit first, then
   measure a BeamAsm domain with that limit against an interpreter domain,
   and default to the interpreter for every domain whose measurement does
   not show the interpreter limiting it. This decision constrains several
   subsystems and belongs in [design.md](design.md) once made.
2. **Interactive-mode loading.** Recommendation: accept that bound modules
   are loaded from the start, as documented and tested, and keep binding
   on first load as the alternative above.

## References

* [design.md](design.md): the architecture and the "by construction" list.
* [design-runtime.md](design-runtime.md): the interpreter and BeamAsm
  images, running Erlang code, code in the system domain, the root-task
  entry, files.
* [design-domains.md](design-domains.md): domain specifications and the
  domain library's plan.
* [design-kernel.md](design-kernel.md): the boot image and its slices,
  virtual memory, copy-on-write children, K4 and K8.
* [design-stopgap.md](design-stopgap.md): the call table of Phase 1, and
  `erx_image_map`, which shares the executable's read-only segments.
* [design-live.md](design-live.md): the host link and its transports.
* [plan.md](plan.md): 1b-E, the trigger's milestone.
* [research-g5-beamasm.md](research-g5-beamasm.md): the interpreter's load
  times and footprint.
* `otp/erts/emulator/beam/emu/emu_load.c`, `module.c`, `beam_bp.c`,
  `beam_bif_load.c`, `export.c`, `erl_fun.c`, `erl_code_staged.h`,
  `beam_catches.c`, `beam_file.c`, `erl_global_literals.c`, `external.c`,
  `erl_init.c`, `erl_bif_trace.c`, `beam_debug.c`, `erl_debugger.c`,
  `erl_nif.c`: the loader, global literals, the code-write funnel and its
  callers, breakpoints, purge, entries and start-up, as cited above.
