# Build and host tooling

`tools/erx` is the host entry point. The top-level Makefile supplies short
names for its commands. Ruby implements orchestration; inherited build
systems run as subprocesses in private directories below `build/`.

The orchestration core constructs immutable plans from checked inputs:
source identities, import selections, commands, output paths and expected
evidence. Planning reads no network and executes no imported code. The
effect layer validates the complete plan, creates private work directories
and applies it through the command runner. A failed step publishes no
successful build record or partially usable output. Completed reports keep
the inputs and tool identities needed to judge and reproduce their result.

## Processes and evidence

One runner starts every external command by argument vector, with closed
standard input, a private process group, a log, and a GNU timeout deadline.
Cancellation and completion terminate the entire group, including children
that outlive their parent. This contains trusted build tools that retain
their process group; it is not a sandbox for programs that create sessions.
A failed or expired command fails its caller.
The runner reports progress after thirty seconds and records the command,
start time, elapsed time, deadline and exit status alongside its log.

Every entry point uses this runner, including fetch tools, inherited
configure and make invocations, the oracle, benchmarks, compiler probes
and TLC. Commands select explicit working directories and environment
values; arguments never pass through a shell. Diagnostics pass through the
host terminal escaper, while raw subprocess bytes remain in logs. The
status command reports every running command's age and deadline. Missing
tools, cancellation, timeouts and nonzero exits remain distinct outcomes.

## Sources and imports

`deps.lock` is a checked data file, with unique source identifiers, exact
source URLs, versions or full commit identities, SHA-256 digests, archive
root names, licences and dependency status. Unknown fields and malformed
identities fail before fetching. Fetch is the only network operation. A
local archive can seed the cache only after the same hash verification as
a downloaded archive; a local path never changes the accepted identity.
Extraction uses a private archive snapshot verified against that digest.
The system `tar` runs through the deadline runner into an empty private
staging directory, with its path protections intact and `TAR_OPTIONS` and
`TAR_READER_OPTIONS` cleared. After extraction, validation checks the
expected root, filesystem types, link destinations, file count and total
file size before publishing the tree beneath `build/third_party/`.
File-count and expanded-size limits are acceptance checks on the extracted
tree; they are not a disk quota during extraction. The process deadline
bounds extraction time. An interrupted or failed extraction publishes no
source tree. Builds and checks require verified sources already present
and never fetch them implicitly.

The import plan names the pinned archive and the selected files, retaining
their relative paths and licence texts. OTP enters `otp/`, musl enters
`musl/`, and the frozen stopgap set enters `fiasco/`. Each imported part's
`ORIGIN.md` contains its repository, release or full commit, archive digest,
import selection and a machine-readable inventory of the imported payload.
Each file entry records its original hash, SPDX expression and attribution
source: its own header, its package's licence declaration or an explicitly
reviewed attribution. A missing header is not evidence of a permissive
licence. The origin document itself is erXos's metadata and is not included
in its own digest inventory.

The change-notice check compares the current path set and bytes with this
inventory. A modified text file carries erXos's change notice in its header;
an added file carries erXos's own notice and copyright line, mentions no
other licence declaration or copyright holder, does not restore a path the
import excluded, and is attributed from that header as erXos's code rather
than the import's. A copy of an imported file is upstream text and keeps its
notices, so it is not an addition: it has its own inventory row, which repeats
the source file's row and adds `copied_from`, and the check treats it as an
imported file, so a changed copy carries the change notice. It may not sit at an
excluded path. Nothing relates a changed copy's bytes to its source, which is a
matter for code review, and a copy that erXos deletes loses its row. The check refuses a third-party file as it arrives; it
cannot detect one whose notices someone rewrote, which is a matter for code
review. A changed binary or another file that cannot hold a comment has an explicit
change entry in its origin document. Every recorded file must remain present with its recorded file
type; deleting one fails the check. Import selection removes excluded files
before creating the inventory.
The check discovers changed files from the comparison rather than a
separate list of expected modifications. The ASCII check covers
erXos-authored source, generated output and erXos-authored additions to
imports. Upstream copyright names, notices and comments retain their
original text. The origin inventory supplies the imported baseline;
an imported directory is not a blanket exemption for additions.

Link maps identify the object files and archive members that contribute
to an executable; compiler dependency files identify their source/header
closure. Build records bind generated objects to those inputs and their
tool identities. Recording an archive's name alone cannot establish the
licences of its selected members. Every closure member resolves to an
origin inventory, a pinned fetched artifact or an erXos source notice;
unknown provenance fails. The packer combines that closure with the files
it packs, checks the appropriate licence allowlist and emits `NOTICES`.
It refuses a release image containing non-permissive stopgap code,
including the Fiasco kernel, as
[Licences and notices](design.md#licences-and-notices) requires.
Permissive stopgaps pass the same licence allowlist as permanent dependencies.

The trusted builder supplies an immutable input catalog alongside its build
record. The catalog names the exact source files, notice documents, dependency
files, maps and outputs that the builder consumed or produced, with their
canonical paths, sizes and hashes. A record may reference those entries; it
cannot register another file or change an expected hash. Project and build
directories locate and label files, but grant no general permission to read
their contents. A record naming an unrelated project configuration file is
refused before any content read or hash calculation.

An explicitly registered import grants its validated `ORIGIN.md` and the
finite files named by that inventory and its reviewed change entries. The
existing change-notice and imported-byte checks still apply. Reviewed notice
profiles register exact, hash-bound documents, including nested packages;
licence filenames carry no inferred meaning. External files and their notices
require exact registrations. These catalogs are constructed by build/import
owners, not decoded from an artifact-supplied record.

Host parser executables follow the same ownership rule. `PackTools.build`
returns an opaque helper handle containing the complete compiler-observed
project inputs, compiler metadata and executable identity. `ElfPlanner`
accepts that handle and checks its retained input hashes before execution.
The JSON build record is audit output and cannot create a helper handle or
replace its expected inputs. A bare executable path and a matching sidecar
file do not establish that the executable came from the trusted builder.

## The frozen stopgap build

Output directories have an explicit owner root. The shared directory guard
resolves that trusted root, checks every existing child component for links
or non-directories, and only then creates missing directories. A system
alias used to spell the trusted root is accepted; a linked descendant never
grants authority. Process logs require the same explicit owner root. An
invalid output branch leaves outside directories untouched.

The imported set and exclusions are owned by
[the kernel design](design-kernel.md#the-current-implementation-the-modified-fiasco).
The build uses the inherited Fiasco and `mk` machinery behind
`tools/erx build fiasco`; no L4Re application stack is a host-facing build
interface. Imported source trees stay unchanged by builds. Kernel objects,
user objects, configuration, generated build files and final images have
separate directories below `build/fiasco/`.

One private input tree under `build/fiasco/inputs/` owns the source bytes
and platform configuration consumed by this build. Its file table and
identity are recorded before compilation. The kernel builds directly from
that tree of read-only files; the inherited user-source layout is a derived copy of
the same inputs. Source checking verifies this recorded tree, including its
path set, and uses it for generated-source ancestry and recipe execution.
Repository changes after capture invalidate the build record instead of
being attributed to existing objects. Copied code and notice documents are
read from the recorded tree when the image is packed.

The kernel configuration runs in kernel mode, with `CONFIG_CPU_VIRT`
disabled, device-tree discovery and the interrupt controllers required by
QEMU `virt` enabled. Configuration inputs are checked in; the resolved
configuration is recorded with the executable. The stopgap uses the
documented cross GCC/binutils toolchain as subprocesses. erXos's own C17
code continues to use its LLVM build. Both record compiler identity,
effective flags, linker maps and dependency files.

`bootstrap`'s direct library requirements are `drivers_uart`, `libfdt`,
`libc_minimal`, `cxx_base` and `cxx_io`. Only the pinned `drivers-frst`
PL011 UART and its required headers and build support enter the tree.
Its configuration disables the all-drivers selection and enables the
PL011 driver. Other drivers cannot re-enter through an inherited default.

`sigma0` requires `libc_minimal`, `cxx_util`, `cxx_io`, `cxx_base` and
`libc_minimal_l4re`. The last library collects `l4sys`, `l4util`, `l4re`,
`l4re-util`, `l4re_c`, `l4re_c-util` and `libc_be_minimal_log_io`;
the relevant headers, startup objects, linker scripts, compiler-runtime
support and minimal-libc source selection belong to the same recorded
build closure. These libraries serve the two boot executables only. They
are not a runtime or application interface above `liberx`. The imported
package selection and final linker evidence must agree, with no `moe`,
`ned`, application loader or unrelated driver in either one.

The inherited `sigma0` link mode also adds the selected compiler runtime.
With the stopgap's GCC configuration, `bootstrap` uses
`compiler-rt-pure`, resolved to `libgcc_eh-pure` and `libgcc-pure`, while
`sigma0` uses `compiler-rt`, resolved to `libgcc_eh` and `libgcc`. Their
headers and retained source notices are part of the closure. The minimal
libc uses the pinned `l4re-core` source selection and its bundled libc
inputs; erXos's `musl/` is not silently substituted into that boot build.
The import records the effective licences of these support files along
with the two executables' linker evidence.

erXos's bootable file is `bootstrap` alone, built as a flat image, with the
archive that erXos's packer appends
([design-stopgap.md](design-stopgap.md#boot-handoff)); `bootstrap` carries no
Fiasco modules. Starting `liberx`'s root-task entry is the root startup's;
until it lands, `tools/lib/erx/boot_image.rb` packs the kernel and `sigma0`,
and a guest test's root task, as files bootstrap places, over the structural
fixture's unadmitted manifest. The banner image has no root to place, so
Fiasco starts `sigma0` and returns without creating a root task when its root
entry is zero, and the harness ends this guest at its named banner checkpoint.

## Generation

The ABI generator reads the complete declaration closure before emitting
anything. Names and numeric identifiers are unique in their namespaces;
layouts have explicit typed fields, sizes and alignment. References and
all bounds are validated before output construction. Generated output is
ASCII and deterministic. A checked inventory owns the output paths; drift
checking compares both the path set and every byte, including missing and
orphaned outputs. Parsers have production-entry fuzz targets and independent
negative fixtures.

The source inventory includes the neutral ABI root, explicit fragments,
the architecture binding, hardware register sources and escape rules.
The output inventory declares each generator's owned paths and generated
documentation regions. Generation stages all outputs before publication;
drift checking writes to a private temporary tree and never repairs the
working tree. An unknown declaration, output path collision or unsupported
layout fails before an output changes. Later service schemas land with
their consumers, under [Generated interfaces and representations](design-generation.md).

## Images and guests

The packer constructs ERXPACK from a validated whole-image plan. Paths,
release marks, executable manifests and provenance are checked before any
image is published, and every executable's load segments pass the ELF
planner, which refuses a segment whose address or file offset is not
page-aligned. Sorted paths, page padding and a content-derived build
identifier make equal inputs produce identical bytes. The packer computes
each file's BLAKE3 hash and then the index's through one host program
built from erXos's copy of BLAKE3's C implementation, with its SIMD paths,
run as a subprocess, since Ruby's standard library has no BLAKE3; the
same sources, built portable, are the kernel's. It then writes the
bootable file
([design-kernel.md](design-kernel.md#the-bootable-file)): by default the
single file, the first stage with its locator and declared size written
and the archive appended; with `--two-file`, the first stage unchanged
and the archive beside it, for the QEMU harness alone. The single file
is a pure function of the first stage's bytes and the archive's, so both
forms are as reproducible as the archive. The freestanding C17
validator checks the same format independently and runs on the host under
sanitizers and a fuzzer.

The manifest's child-feasibility check invokes the production domain
planner only for child specifications actually present. An empty native
partial boot has none, but initial-root feasibility still requires its
production bootstrap plan and backend/ABI-bound charge evidence. A
source-declared baseline is not that evidence. Unavailable required
planning fails as unsupported; structural fixtures cannot mint an
admission token or enter the production publisher. The roadmap defines the
[M0 acceptance image and M1 planner gate](plan.md#m0-the-tree-the-toolchain-and-the-oracle)
without changing the complete target manifest or its admission rules.

The QEMU harness uses the pinned `virt-11.1` machine, an explicit accelerator,
serial logs, `-no-reboot` and named transcript deadlines. It terminates the
guest once its expected transcript is complete. Unsupported acceleration,
timeouts and incomplete transcripts are failures with retained evidence.

The invocation fixes the machine and interrupt-controller configuration,
memory, CPU count and accelerator; the CPU model is the platform's
declared TCG model or `host` for HVF. No guest network device is present
unless the test requests one. A transcript plan gives ordered expected
lines and deadlines by checkpoint name; a checkpoint may also verify the
content of its line. The boot transcript first checks bootstrap's memory
summary against the guest's RAM: bootstrap gets neither `-mem=` nor
`-sysalloc=`, so both its total and the memory it reports available for
itself, the kernel and `sigma0` must be exactly the RAM given to QEMU. A
missing, malformed or different summary fails the boot, and the
diagnostic quotes the guest's line only escaped and truncated. The
matcher consumes complete serial lines and preserves raw bytes in the log; it does not render guest
output directly to the host terminal. A matched prefix is insufficient
when a later checkpoint is missing. Reports include the guest image hash,
QEMU identity, resolved invocation and observed checkpoints.

The conformance harness (`tools/erx conformance`,
`tools/lib/erx/conformance.rb`) runs the roster `test/conformance/roster.txt`
over a matrix of configurations, HVF with one and four CPUs, one
guest boot per configuration. A roster line declares a case the guest runs,
with its share of the guest's deadline, or a pending case whose call does
not exist yet. The guest reports each case on the serial console as
`erx-test: case NAME passed|failed|skipped`, closes its report with
`erx-test: end COUNT`, and ends the machine, so that under `-no-reboot`
QEMU exits by itself. The harness separates that natural exit from a QEMU
that exits with an error and from a guest it kills at its deadline (the
boot allowance plus every running case's share), and kills the guest's
whole process group in every case. A case's status in a configuration is
the result the guest reported; `omitted` when the guest ended its report
without it, which fails the configuration; `unknown` when the report never
ended; `pending` as the roster says; and `unsupported` when the host's QEMU
lacks the accelerator. A configuration is `passed`, `failed`, `partial` (a
natural exit without an end line, or with a skipped case, since a skip did
not run), `timed_out` or `unsupported`, and the
matrix passes only when every configuration passed. Protocol lines are
bounded, a malformed, repeated, late or miscounted line fails its
configuration, and diagnostics quote guest bytes only escaped and
truncated. Each configuration's serial log and report and the whole
matrix stay under `build/conformance/`.

## Oracle and protocol models

Stock host OTP builds are separate from the imported target source. Both
interpreter and BeamAsm builds use the pinned release; suite reports retain
case identities, failures, skips and incomplete outcomes. Benchmarks carry
their host, tool, flavour, workload and baseline conditions.

Full stock builds and suites run in the
[offline host oracle context](design-host-oracle.md): a task-owned Linux
container with no external network interface, private startup configuration
and a lifetime that contains all stock child processes. Native macOS builds
remain separate bootstrap/compiler and performance inputs. Reports identify
which environment supplied each result; offline failures and skips retain
their actual case outcomes.

`tools/erx oracle build` creates a private writable source copy from the
verified OTP archive for each flavour in an owned native Linux volume.
Host reports and bounded exported artifacts live below `build/oracle/linux/`;
the stock build and its filesystem tests never execute on a macOS share. It invokes
OTP's supplied configure script with `--disable-jit` for `emu` and
`--enable-jit` for `jit`; optional application choices and every other
configure argument are explicit and recorded. The oracle never builds
from `otp/`. A build is accepted only after the resulting `erl` reports
OTP 29.1.2 and the requested `erlang:system_info(emu_flavor)`.

`tools/erx oracle run emulator`, `kernel` or `stdlib` invokes the pinned
tree's corresponding make test target. The ERTS target accepts its build
flavour; application targets use the verified configured primary runtime,
without the launcher's executable-suffix override. An interpreter reports
`emu` even when its installed primary executable is named `beam.smp`.
Each suite starts from a fresh verified source build, because test make
targets can rebuild emulator objects and must not consume a mutated tree
behind an otherwise valid installed-runtime receipt.
These targets perform OTP's test-environment installation and native
fixture preparation. Calling Common Test directly over a directory does
not replace those steps. Runs have private test/log directories and a
hard deadline inside the container as well as on its host client; no
simultaneous run shares OTP's writable test variables. The container owns
its `epmd`, test sockets and daemonized children. The adapter force-removes
its exact owned workload container before a short-lived exporter reads the
volume through a read-only mount. The exporter copies bounded reporting
evidence into an owned host directory. Completion requires verified cleanup
of both containers and their exact owned volume. The operator's Erlang name daemon is outside that
container's process and network namespaces.

The reporting copy of Common Test observes each case in
`test_server_ctrl:run_test_case1/10`, after its logfile is allocated and
after Common Test decides its final status. `skip_case/7` observes cases
skipped before execution. A fresh local reference joins each start to its
one immutable final record; full group names and group-instance references
come from the controller's actual `Mode`, including repeated and parallel
groups. Neither testcase configuration nor a shared current-case variable
owns this identity. The existing Common Test event manager serializes these
records alongside independent run-completion events and totals. Reports distinguish
passed, failed, user-skipped, automatically skipped and incomplete cases,
and preserve setup/teardown failures. A case that started without an end
event remains incomplete. Completion requires Common Test's completed-run
event, reconciled totals and the command outcome; missing evidence never
becomes an empty successful suite. Raw Common Test logs stay beside the
structured case report. XML is optional metadata, attached only when its
case identity is unambiguous; it never creates an execution. Missing or
contradictory starts, final records, group identities or completion events
remain incomplete, including aborted runs. Configuration callbacks remain
separate records; their failures still fail the suite, while independent
totals count testcases and Common Test's synthetic whole-suite skip markers.
The controller's existing totals pass declares and seals the selected job
roster before setup or execution. Actual admission consumes those exact
requests, retaining distinct IDs for duplicates. The worker records its ID
before setup, and successful return of its testcase-list traversal is
separate from its process exit. The controller records normal or aborted
selection closure. Completeness requires every selected job to be admitted,
traversed and normally exited, with normal closure and no abort. A completed
prefix cannot certify later queued jobs, and a setup failure cannot disappear
because no testcase started. Raw controller entrypoints without a sealed
roster remain incomplete.

Only reporting code and three guards differ from the pinned oracle. On a node
without distribution, as erXos's are in Phase 1, the controller answers a
node start (`start_node`) with `{error, not_alive}` to the case that asked,
where stock's `slave:start/5` would exit inside the controller and end the
whole run; it answers `is_release_available` with `false` and `find_release`
with `not_available`, because an old release runs only as a node this one
starts, and the search for one would also fail inside the controller on a
system with no PATH. A distributed node never reaches a guard. A checked-in copy of
the controller retains its upstream licence and change notice, with original
and modified hashes in its source record. The original archive remains
unchanged. The guest checks those hashes before replacing that one file;
runtime, library and testcase sources remain the archive's exact bytes.
Observer failures cannot change a testcase's return or Common Test's result;
missing observer evidence makes the report incomplete. Tests compare reporter
enabled/disabled outcomes and actual peer-case logs, repeats, crashes,
timetraps and pre-initialization skips.

The reporter streams each event as it is recorded, as raw bytes on standard
output, in one call that bypasses the io server so no device encoding can
refuse it. The frame is a newline, the prefix `erx-oracle-event `, the
JSON's length in bytes, its CRC-32 as eight lower-case hex digits, the
JSON, and a closing newline, with one space between the fields. The
leading newline makes the frame start a line even after a suite's own
unterminated print. The host takes the complete lines that start with the
prefix from output that may also carry a suite's prints or a console's boot
lines, and accepts a closing `\r\n`. A last line the run was cut off in is
ignored. A closed line whose length or checksum is wrong is skipped and
counted; a side with skipped lines is reported incomplete with that count,
never complete and never unreadable, and its open cases show as unknown.
A run killed at its deadline keeps every finished case with its result,
and only the cases that were open show as timed out.

`tools/erx oracle hosted` and `tools/erx oracle qemu` run OTP's
`emulator`, `kernel`, `stdlib` and `compiler` suites on erXos, as a macOS
process or in the system domain under QEMU, and on stock OTP 29.1.2 on
the development host, and compare them case by case. Each group runs on
its own, with its own compiled suites and helper modules, its two runs,
its report and its table of known differences
(`test/oracle/hosted_known_differences/<group>.txt`), because suite names
repeat across groups; both erXos sides read the same tables, so a case
that differs on one and not the other is a bug. `--suites` names groups,
`group/SUITE`s or `fast`, the subset `make check-oracle-hosted` and
`make check-oracle` run on every change. A table row
names a suite, a group path, `-` or `*`, a case or `*`, the status erXos
shows and the reason; a row naming a case wins over one naming only its
group path. Each reason is an explained difference, a "cannot run" cause
named as the plan's M3 names them, or a bug's `TODO.md` item. A `*` row
claims only the cases that differ, so a case it covers that agrees with
stock is the same; an exact row whose case agrees, and any row that
accounts for no difference in two finished runs, is stale and fails the
comparison, as does every unlisted difference and every unresolved case.

Each controller observation receives a bounded acknowledgement from the
writer before the controller announces completion, so the completed-run
event cannot overtake an accepted case record. Detailed arbitrary testcase
terms stay in raw Common Test logs; the structured report never copies or
pretty-prints an unbounded return value or skip reason.

The separate TLC gate verifies the pinned jar and checks the complete roster
before filtering. Each configuration runs in a private snapshot with a hard
deadline. Expected counterexamples require the exact named property and
exit status; parser errors and incomplete runs fail. Cached evidence binds
all model inputs, tools, options and expectations, and never caches failure.

`tools/erx check-tla` implements
[the model runner contract](design-verification.md#model-suite-and-runner).
It validates the entire roster before applying a requested filter,
including entries outside that filter. A jar-path override still requires
the pinned bytes. Private input snapshots, Java temporary directories and
TLC metadata isolate concurrent checks; the effective worker, heap and
deadline limits form part of the report and cache key. A deliberately
broken configuration succeeds only as an exact expected counterexample,
with the named property and pinned tool exit status. The runner's smoke
fixtures test this classification; they claim no protocol property of
erXos. The first update model lands at the roadmap's declared milestone.

## Verification

Host tests cover pure plan validation separately from effects. Seeded
violations exercise duplicate and unknown lock entries, archive hash and
path failures, missing provenance, changed imported files without notices,
excluded licences, stale/missing/orphaned generated outputs and unsupported
tools. Oracle fixtures cover repeated and grouped cases, both skip kinds,
fixture failures, interrupted runs and inconsistent totals. Harness
fixtures cover split serial reads, checkpoint order, early guest exit,
timeout and a bootstrap memory summary that disagrees with the guest's
RAM. TLC fixtures cover wrong properties, parser errors, resource failure,
incomplete searches, cache invalidation and empty filters.

Acceptance also uses the real tools: both stock OTP flavours and their
required suites, the frozen stopgap banner under HVF, clean
rebuilds with identical bytes for the archive, the single bootable file
and the two-file form, the single file's archive equal to the two-file
archive, both forms booting under the harness, and the boot validator's
configured sanitizer and fuzz budgets. `make check` is offline and runs
ordinary host checks and generation drift. `make check-tla` remains a
separate gate; a missing requested tool is an error rather than a skip.

### What the gates run

The gates run what the tree declares, so that adding a core, a test or a
fuzz target is adding files and parallel work never edits a shared list.
Each declaration lives with what it declares:

| Gate | Declared by | Fails when |
| --- | --- | --- |
| Chokepoint checks | `tools/lib/erx/chokepoint_rules/NAME.rb`, one group of rules; a core's group is named after its source and states its rules or why it has none | a `kernel/core` or `kernel/sched` source has no group, or a group file declares nothing, twice, or an empty group |
| `check-sanitizers` | the line `# erx-gate: sanitizers` in a test under `test/host` or `test/integration` | a comment resembles it but is not it, a test reads the sanitizer switch directly or through a helper without declaring, a core or `liberx` source is named by no declaring test, or nothing declares |
| Test pool (`check`, `check-sanitizers`) | every `*_test.rb` under `test/host` (and the declaring or non-excused integration tests); `# erx-gate: serial` on a file that cannot share the machine | a file's log has no Minitest summary or zero runs, a file fails or times out, a file is listed twice, or the verdicts differ from the file list |
| `check-qemu` | `tools/lib/erx/qemu_suites/NAME.rb`, one suite that boots the kernel under QEMU; a suite declares the cells it expects and a callable returning each cell (a configuration or a declared case) as `passed`, `failed`, `timed_out`, `partial`, `not_run` or `pending` | a suite is failed when a cell failed or timed out, or its file raised; it is incomplete when a cell was not run (an expected cell the suite did not report, which the gate marks `not_run`, or a configuration its harness could not run) or partial; a suite with no cell fails; only a pending suite, whose cases await their calls, does not fail the gate. Every suite runs under HVF; TCG runs only the production image's deterministic-mode transcript (`erx.det=1`, which needs TCG with instruction counting) and one boot of it to the shell at one CPU. A host whose QEMU lacks HVF or TCG fails the gate before anything is built, and the gate never falls back from one to the other. Linux hosts are not tested |
| `check-fuzz`, native targets | `tools/fuzz/KIND_target.rb` beside `tools/fuzz/KIND_fuzz.c`, naming sources, include paths and seeds | either file lacks the other, or a declaration is empty or malformed |

Discovery could otherwise make a security gate quietly run less, so
`test/host/gate_baseline_test.rb` holds a floor: a table of what must stay
in each gate, with each rule's and target's least seed count. Adding to a
gate does not touch that file; taking something away does, which makes the
removal a visible edit. `tools/erx gates` lists what each gate runs, one
line each, for a reader or a diff. An integration test runs in `make check`
unless `tools/erx` excuses it by name.

The test pool runs each test file as its own process, with its own log and
deadline, about half the CPUs at a time (`ERX_TEST_JOBS=N` overrides). A
file keeps its temporary directories and global state to itself, so a
failure names the file and its log, and a hang costs one file's deadline.
The pool refuses to pass a file that printed no Minitest summary, so a test
that forgets `require 'minitest/autorun'` cannot silently run nothing.

`TODO.md` and `docs/todo-performance.md` merge by line union
(`.gitattributes`), so concurrent additions to these lists never
conflict; an entry edited on both sides can stay in both forms, which the
next reader tidies. Generated ABI outputs are functions of their sources:
`tools/land COMMIT` cherry-picks one commit, and when only those outputs
conflict it removes them, runs `tools/gen_abi.rb`, proves the result with
`--check` and continues. Any other conflict stops the pick with the files
listed; `tools/land --continue` finishes it once they are resolved and added.
A clean pick whose outputs are stale has them regenerated into it. Edits
outside the index are refused, so what is generated from is what is committed.
