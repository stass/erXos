# Fiasco boot-set link audit

The completed check below accepts the development image and rejects release
use. The initial partial measurement is retained for comparison.

## Initial measurement

This measurement was made on 2026-11-02 on the Apple Silicon macOS build
host. It covers the checked-in stopgap kernel and the pinned bootstrap and
sigma0 support set described in [the build design](design-build.md).

The detailed results are in `build/fiasco/link-audit.json`, produced by
`Erx::FiascoProvenance`. This is an **incomplete source report**; the packer
cannot accept it yet. The transformations below still need records of their
generators and inputs before source tracking is complete. Generated files
are not assigned a BSD or MIT licence without supporting records.

## Measured inputs

| Executable | SHA-256 | Allocated map contributions |
| --- | --- | ---: |
| Kernel `kernel/fiasco` | `ef5adafbab60dd88a073abbc8c997a4509d3add1ca5d7031785b19a5294aed9d` | 222 |
| Bootstrap `bootstrap.elf` | `dd6eba8a94a0a20ec83d374469dc05bef368aa3f9462f0370757019593fe4ff1` | 76 |
| Sigma0 `sigma0` | `5a15ea73fa1ece889ce0475fa7132e3b0943883a0e987349f1a17c1b7178d4d7` | 22 |

The report binds each executable and GNU linker map to its SHA-256. It reads
allocated input sections after the map's `Linker script and memory map`
marker. Discarded input sections, alignment fill and linker-script scalar
data are excluded. Other unsupported contributions fail closed.

Selected archive members are read with GNU ar from private snapshots of the
same bounded archive bytes whose digest is recorded. The tool is GNU ar
2.47.20260726, with executable SHA-256
`0bbdf8a971f2103621218de1e15c074b641fd9744f407b752e65965bc10e5b7f`.
Matching output bytes alone do not identify the originating compilation:
multiple candidates are unresolved unless the recorded archive input list
selects the object. The aggregate `libc_minimal_l4re.a` uses its evaluated
`OBJS_libc_minimal_l4re.a` list and the selected `.ofl` object lists.

Kernel compiler `.d` records include only the first rule's prerequisites;
compiler `-MP` empty rules may repeat those prerequisites but may introduce
neither an additional file nor another dependency. The inherited user build
retains its compiler inputs in `.object.o.cmd`. Only its literal
`savedcmd`, `source` and `deps` assignments are read; make/shell evaluation
is never used to interpret that record.

The kernel's generated `auto/` files are traced through `.Modules.deps` to
their original `.cpp` inputs. The build's recorded VPATH search list selects source
names in the inherited build's actual search order. Empty or ambiguous
source mappings remain unresolved. Derived physical source copies must
match their authoritative imported bytes, which are checked against their
authentic `ORIGIN.md` inventories.

## Licences

These executables include code covered by explicit GPL version 2 notices in
`src/kern/jdb_object.cpp` and `src/kern/kobject_rpc.h`. Their prose notices
take precedence over the kernel package's MIT default; both source files
retain their upstream notices. The origin inventory is generated from the
verified original kernel archive, preserving original source hashes.

The kernel also consumes the installed GCC 16.2.0 `stdbool.h`. The exact
header and retained GCC Runtime Library Exception notice are registered in
`config/provenance/gcc-16.2.0.json`. The header grants GPL-3.0-or-later with
GCC-exception-3.1. The Cellar's top-level `COPYING` is GPL version 2 and is
not evidence for a GPL version 3 grant. Full GPL version 3 text is retained
in the imported core's GCC source. GCC support objects and CRT objects in
the measured maps come from the imported support-source build; the compiler
executable itself is an external build tool, not linked code.

The stopgap remains restricted to use inside the project. Neither the
project's BSD licence nor a runtime exception turns the non-permissive
Fiasco code into a permissive dependency.

## Missing source records

Nine outputs remain explicitly blocked:

* Object transformations: kernel `bootstrap.fiasco.rel`, bootstrap
  `mbi_modules.o`, and the inherited `crti.o` and `crtn.o` objects.
* Generated kernel headers: `globalconfig.h`, `tcboffset.h` and `version.h`.
* Generated user-build headers: `include/l4/bid_config.h` and the embedded
  musl `bits/alltypes.h`.

The inherited generator rules for these outputs are identifiable. The
outstanding work is to record their exact inputs, configuration and generators,
then produce the packer's build records. The audit does not guess those inputs
from a directory, file suffix or assumed package licence.

## Verification

The host parser and audit suites passed: 29 tests and 70 assertions. The
compiler-record fuzz target exercised 62,944 inputs in two seconds with seed
1,234,567. Regressions were observed failing before their corresponding
fixes for GNU script scalars, compiler `-MP` output, compound cycles,
unregistered input reads, ambiguous archive ancestry, empty generated
source records, duplicate assignments, archive snapshot binding, repeated audit
snapshots and the explicit GPL prose grant.

Logs are under `/private/tmp/erx-fiasco-*`; the final source-closure refresh
is `/private/tmp/erx-fiasco-link-audit-final.log`. Existing native TCG/HVF
boot and deterministic image checks are separate evidence and do not
substitute for complete source tracking.

## Completed check: 2026-11-02

A subsequent build and source check on the same Apple Silicon host produced
`build/fiasco/receipt.json` and its canonical `build/fiasco/provenance.json`.
The record is complete: 1,462 source, header and generated-file records,
with no missing records. The packer checks 843 distinct copied-code files,
including both GPL-2.0-only kernel files.

All nine generated files listed above have fixed source records in
`config/provenance/fiasco-generation.json`. These bind the exact reviewed
recipes, templates, settings, tool inputs, object lists and generated bytes.
Text records normalize the project-root path and reject a literal reserved
marker. The expected inputs include host-generated tools and configuration;
changing those bytes requires reviewing the profile. Generator-only code
and configuration remain build information, separate from copied program
code and its licences.

The final-image check uses private copies of the actual linked kernel,
bootstrap and sigma0. It reproduces sigma0's installed strip/debug-link
step and checks the installed bytes. It then runs the reviewed Perl image
builder directly over those copies; it executes no generated Makefile.
The resulting complete ELF matches the built image byte-for-byte:

`bd97fe6a85748dcd7d5c6d0085f55aa044d584d0ddd5dbfbe53d8d7a491639bf`

The normal packer interface reads the fixed Fiasco build record, re-runs
these checks and compares the complete canonical record. Other artifact or
report paths, changed records, thin archives and changed generator inputs
are refused. No assertion in a supplied report substitutes for checking
the files.

`build/fiasco/NOTICES` contains 9,516,823 bytes. It includes the complete
GPL version 2 and version 3 texts and the GCC Runtime Library Exception,
in addition to the copied files' source notices. The upstream headers name
`COPYING-GPL-2`, which is absent from the import; the GPL version 2 text is
taken from the authentic, hash-pinned `kernel/tool/preprocess/COPYING`.
Legal notices are not counted as program sources. Release verification
rejects the image because it contains non-permissive stopgap code.

The host suites for this check passed: 52 tests and 126 assertions. The compiler-record
fuzz target passed 62,858 inputs in two seconds with seed 1,234,567. The
complete native build, fresh packer check, full licence-text checks and
release rejection are recorded in
`/private/tmp/erx-fiasco-complete-validation.log`. Independent code review
found no remaining high-severity issues after the fixes. The final ELF is
unchanged from the image already verified under TCG and HVF.

## Shared archive check: 2026-11-02, 22:18 UTC

Both source-checking backends use `Erx::ArchiveMember` to read archive
members. This one boundary rejects thin archives, copies the verified
normal-archive bytes into a private directory and passes `--` before
archive/member arguments. The member output is checked against a 64 MiB
limit after the tool exits; every call has a 30-second deadline.

The added regressions failed before the change and passed afterward.
GNU ar and the installed LLVM ar both returned an option-shaped member
name (`--plugin=not-a-plugin.o`) as literal data. Fresh verification of the
existing Fiasco build record passed with the same 843 copied-code files
and two GPL-2.0-only files. The combined host suites passed 54 tests and
132 assertions. Independent review found no remaining high-severity issues.
The direct tool checks are in `/private/tmp/erx-archive-real-check.log`;
the complete source check is in
`/private/tmp/erx-fiasco-shared-archive-check.log`.

## Foundation review follow-up: 2026-11-03

The aggregate support archive contains two different `namespace.o` members.
A selected name must therefore occur exactly once before its bytes can be
attributed. The reader lists all names from the same private archive copy,
rejects an ambiguous selection before extraction, and applies a hard child
file-size limit to both listing and printing. Filtering `ar t` by a name is
insufficient: the installed LLVM tool lists only its first occurrence. Real
duplicate-member fixtures confirm refusal while unrelated unique members
remain readable. The archive regressions pass in
`/private/tmp/erx-archive-duplicates-capped.log`.

Kernel and user builds consume one recorded private input tree. Its file
bytes are read-only, its directory/file/link table is checked, and repository
edits after capture invalidate publication. Kernel generated-source records
now name the captured files rather than a later repository view. The rebuilt
kernel and final image retain the hashes measured above. Source records name
the original repository location separately for inspection.

All 111 recorded embedded-musl sources explicitly reference the complete
package `COPYRIGHT` notice by path and hash. This reference belongs to those
source records; it is not attached to unrelated MIT packages.

The completed check still reports 1,462 source/generated-file records with
no missing records. Creating exact read permissions initially repeated whole
import checks: the core check alone took 104.65 seconds. Reusing each checked
immutable import once produced a complete audit in 126.35 seconds and a
source catalog in 95.84 seconds within the 300-second deadline, recorded in
`/private/tmp/erx-fiasco-catalog-optimized.log`. A further checked-observation
reuse removes re-opening and re-canonicalizing files already read by the
producer; its timing is recorded separately in
`/private/tmp/erx-fiasco-catalog-final.log`.

The shared output-directory checks require an explicit owner root, validate
every existing child ancestor before creating anything, and provide a
no-write check for complete output plans. Runner logs require that owner
explicitly. Linked output branches were observed creating outside files
before the fixes and are refused afterward. No system-path exceptions are
needed for explicitly trusted `/tmp` or `/var` root spellings.

The strict source verifier using the builder's opaque input catalog completed
successfully in 282.03 seconds within its 300-second deadline. It checked 843
copied-code files and asserted that the complete embedded-musl `COPYRIGHT`
text occurs in `NOTICES`. The resulting notice document contains 11,977,341
bytes, including the selected-grant notice documents. Evidence is in
`/private/tmp/erx-fiasco-strict-snapshot-verifier.log`.

The input owner retains its checked snapshot observations for the duration of
one check. Original unchanged import files can reuse the verified hash;
modified or added files still pass the ordinary notice and ASCII checks.
Exact catalogs reuse these observations and checked import inventories rather
than infer permission from report paths. The current native record remains
complete with 1,462 source/generated-file records, and all 111 embedded-musl
records name their package notice explicitly.
