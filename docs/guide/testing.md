# Testing

How to run the checks, in plain words: the two gates, and how to run one
QEMU suite, one host test or one fuzz target. What each check covers, and
where its limits are, is in the README's
[Correctness and testing](../../README.md#correctness-and-testing), and the
rules for what counts as evidence are in
[design-verification.md](../design-verification.md).

## The two gates

* **The landing gate** is for every commit: `make check`, and the QEMU
  suites the change touches. It is fast on purpose, because iteration speed
  comes first.
* **The milestone gate** is for declaring a milestone reached or merging a
  large branch, and runs in the background on a spare host: `check-oracle`,
  the sanitizers, the fuzz budgets, `check-reproducible`, `check-cbmc`,
  `check-tla`, `check-litmus` and the full QEMU suite. A failure there is
  fixed forward with a regression test; it holds back nothing that already
  landed unless it also breaks the landing gate.

While developing, run only what your change can affect, and the whole set
once when the change is complete ([CLAUDE.md](../../CLAUDE.md), "Tests and
sanitizers").

## `make check`

```sh
export ERX_CLANG=/opt/homebrew/opt/llvm/bin/clang
export ERX_LLD=/opt/homebrew/bin/ld.lld
make check
```

(The variables are in [Host setup](../../README.md#host-setup).) It
regenerates `build/gen/`, checks that every authored file is ASCII and every
import matches its `ORIGIN.md`, runs the build checks (architecture terms,
chokepoints, the stack proof), builds the web client, runs Dialyzer over
erXos's Erlang, then runs every
`test/host/*_test.rb` and the integration tests of `test/integration/`
except those that boot QEMU, need the hosted runtime, the stock suites'
runtime or OpenSSL. It never downloads and never boots a guest. A new
checkout needs `make setup` first ([Fresh worktree](../../README.md#fresh-worktree)).
It ends with `offline source, generation, Dialyzer, host and native
integration checks passed`, and names any test it could not run on this host.
Dialyzer is strict: any warning of its default set fails the run, and its
log names each one. It reads its table of OTP's types (the PLT) from the
tree's own OTP, compiled into `build/dialyzer/` and kept until those
sources change. How to fix a warning is in the
[style guide](../style.md#erlang).
`make check-arch-terms` runs the architecture-terms scan alone, which is
the check to run after a change to documents.

## One host test

Each host test is a Ruby Minitest file. Run it alone, or one case of it:

```sh
ERX_CLANG=/opt/homebrew/opt/llvm/bin/clang ruby test/host/line_escape_test.rb
ruby test/host/line_escape_test.rb --name test_NAME
```

A test that compiles Erlang, such as `test/host/erx_virtio_test.rb`, needs
`ERX_ERL` and `ERX_ERLC`, which `make check` sets to the stock OTP oracle's
`erl` and `erlc`. After `make oracle-bootstrap` they are under
`build/oracle/jit/install/bin/`. The Erlang unit tests (EUnit) in
`test/erlang/*_tests.erl` run through such a host test, which compiles the
application and runs the module. Integration tests in `test/integration/`
run the same way, `ruby test/integration/NAME_test.rb`; the ones `make check`
leaves out are listed in `STANDALONE_INTEGRATION_TESTS` in `tools/erx`, and
`make check-runtime-hosted` runs the hosted runtime's.

`tools/erx gates` lists what the gates discover: the sanitizer tests, the
test pool, the QEMU suites, the native fuzz targets and the chokepoint
rules. `ERX_TEST_JOBS` sets how many test files run in parallel.

## One QEMU suite

```sh
tools/erx check-qemu --suite native_trace
tools/erx check-qemu --suite native_task --suite native_irq --fresh
make check-qemu
```

A suite is a file of `tools/lib/erx/qemu_suites/`, named after the suite;
`tools/erx gates` prints the names. `--suite` repeats. The gate needs QEMU
to offer both HVF and TCG, builds the kernel, boots each suite's cells,
and prints a table whose statuses are passed, failed, timed out, partial,
not run or pending. It fails when any cell failed or is incomplete, and a
pending suite, declared before the call it tests exists, is listed without
failing it. A boot that already passed on the same inputs is skipped and
its stored log replayed, so a rerun after an unrelated change is cheap;
`--fresh` boots every cell. `make check-qemu` runs all suites fresh,
`--one-at-a-time`. `--remote DEST` moves the multi-CPU cells of suites that
declare it to another host over ssh when this one is busy. The Raspberry
Pi 4 suite runs under TCG alone. The stored results are in
`build/qemu-results` (`ERX_QEMU_RESULTS` names another place).

To see the guest, read the suite's serial log: the harness writes each boot's
to `build/qemu/ACCEL-PID-RANDOM/serial.log`. To boot by hand,
[Debugging](debugging.md#the-boot-transcript-and-the-console).

## One fuzz target

`make check-fuzz` (`tools/erx check-fuzz`) runs every target for its budget:
`--seconds N` for the timed Ruby targets (1 to 60), `--runs N` for the C
libFuzzer targets and `--seed N`. The tool has no way to select one target.
To run one Ruby target by hand, run its driver under the environment
`make check-fuzz` provides (`ERX_ERL`, `ERX_ERLC`, `ERX_CLANG`):

```sh
ruby tools/fuzz/erx_manifest.rb --seed 1
```

Each C target is a `tools/fuzz/NAME_fuzz.c` with a `NAME_target.rb`; the
rule is that every parser of untrusted input gets a target when the parser
lands ([CLAUDE.md](../../CLAUDE.md), "Tests and sanitizers").

## The slower gates

```sh
make check-sanitizers      # also check-asan, check-tsan, check-ubsan
make check-reproducible
make check-tla
make check-cbmc
make check-litmus
make check-oracle
```

What each does is in the README's
[Fetch, bootstrap and check](../../README.md#fetch-bootstrap-and-check) and
[Guest and stock oracle](../../README.md#guest-and-stock-oracle).
`make check-oracle` runs six to seven hours. `check-cbmc` needs the CBMC
version pinned in `test/cbmc/roster.json`, and `check-litmus` builds herd7
the first time.

## Where the logs are

* Every command `tools/erx` runs writes `build/logs/NAME-PID-RANDOM.log`
  and a `.json` record of its arguments, deadline and state. A command has
  a hard deadline and its subprocesses end with it. `tools/erx status` lists
  commands recorded as running.
* QEMU boots: `build/qemu/`. Reusable passes: `build/qemu-results/`.
* Benchmarks: `build/bench/`. CBMC: `build/cbmc/`. Reproducibility:
  `build/reproducible/`, with a `result.json` naming any part that differs.

## When you add a test

* A fix for a non-trivial bug starts with a regression test that you see
  fail on the unfixed tree, then pass.
* A check that guards something subtle gets a seeded fault: plant it and
  confirm the check fails. `make check-native-seeds` and `make
  check-qemu-mutant` do this for the native suites and the QEMU gate.
* Where code does not touch hardware, it also builds for the host, so its
  unit tests, fuzz targets and sanitizers run there.
