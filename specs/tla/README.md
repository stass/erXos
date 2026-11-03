# Model gate

`make check-tla` runs TLC separately from ordinary host checks. Run
`make fetch` first; checks never download tools. `TLA_TOOLS_JAR` selects a
jar location, whose bytes must match the `tla-tools` pin in `deps.lock`.
`JAVA` selects the installed JVM executable. On a Homebrew host whose JVM
is not on PATH, set it to the installed `openjdk/bin/java` path.

`TLA_JOBS` controls independent configurations and `TLA_WORKERS` each TLC
process. `TLA_JVM_MEM` accepts MiB (an integer or `m` suffix) and GiB (`g`);
the default is 512 MiB, with at most 8 GiB of aggregate configured Java
heaps. Native JVM/fingerprint-table overhead is additional. Every run has
its own metadata and Java temporary directory and a hard deadline.

Use `tools/erx check-tla --filter TEXT` to select matching configuration
ids; an empty selection is an error. The complete roster is validated
before filtering, including unselected entries. Each configuration occurs
exactly once. `TLA_NO_CACHE=1` or `--no-cache` forces a fresh check.

Cached results bind all snapshotted model/configuration/roster bytes, the
expectation, flags, runner code, jar hash and JVM identity. Original inputs,
command records and raw logs remain evidence. Missing or changed evidence
causes a fresh check. Failed, incomplete, expired and cancelled checks
never become successful cache entries.

The runner classifies the pinned tool's framed diagnostics and exact exit
status. An expected counterexample names its invariant exactly. A parser
error, wrong invariant, memory failure or interrupted search fails the gate.
Initial-state and transition violations have distinct tool diagnostics.
Reports retain declared finite or constrained scope; completing a bounded
model is evidence about that model, not execution of erXos code.

`RunnerSmoke` checks the runner itself. Its variable ranges over three
states in the good configuration, four before the broken configuration's
counterexample, and an intentionally bad initial state. The reachability
configuration falsifies `NotReached` at state 2. These fixtures establish
classification, completion and cache behavior; they assert no operating
system protocol property. Protocol models and their implementation
mappings follow the roadmap.
