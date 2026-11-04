# erXos

erXos is an Erlang-native, cross-platform operating system. AArch64 is
its first architecture, and its first phase runs on a near-stock Fiasco
kernel until its own C17 kernel replaces it. The
[architecture](docs/design.md), [roadmap](docs/plan.md) and
[working agreement](CLAUDE.md) define the project.

## Host setup

Apple Silicon macOS is the primary host. Use the installed Ruby with
minitest and REXML, GNU make, GNU timeout (`gtimeout`), Perl, LLVM clang
23.1.3, lld and LLVM binary tools, AArch64 ELF GCC/binutils, QEMU 11.1
with `virt-11.1`, and a Homebrew JVM. Install missing development tools
through Homebrew. Full stock OTP suites also require a local Docker
engine/context; the [host oracle design](docs/design-host-oracle.md)
describes its pinned Linux image and isolation.

Select the compiler explicitly. Checks verify the reported clang/lld
versions and the compiler resource headers against
`config/provenance/llvm-23.1.3.json`; Apple's SDK clang is not that
toolchain. For a Homebrew installation at `/opt/homebrew`:

```sh
export ERX_CLANG=/opt/homebrew/opt/llvm/bin/clang
export ERX_LLD=/opt/homebrew/bin/ld.lld
export JAVA=/opt/homebrew/opt/openjdk/bin/java
export PATH=/opt/homebrew/bin:$PATH
```

Use the corresponding paths for another installation. No Ruby version is
required.

## Fetch, bootstrap and check

Fetch is the only step that downloads dependencies. Modified dependencies
live in `otp/`, `musl/` and `fiasco/`, with their recorded origins. Select
your existing local Docker context explicitly when fetching the oracle
image:

```sh
make fetch DOCKER_CONTEXT=NAME
make oracle-bootstrap
make check
```

The bootstrap builds stock native OTP 29.1.2 JIT from the already verified
archive, offline. To replace an existing native build, use
`tools/erx oracle build --backend native --flavour jit --clean`.
`make check` verifies this runtime, checks source provenance and ASCII,
checks every ABI/hardware/system-register/terminal generated artifact,
runs host tests, and compares terminal renderer bytes with stock OTP.
Native ELF and structural archive integrations also run. It does not launch
the full stock OTP suites or download missing prerequisites.
M0 requires focused test-runner checks. Full reference suites are required
before the ERTS port, rather than before early kernel work.

```sh
make check-reproducible
make check-sanitizers
make check-fuzz
make check-tla
```

Reproducibility retains both full `ERXPACK` structural test fixtures and a
report below `build/reproducible/`. Their structure, executable and
provenance are checked. Root startup and policy admission remain
`unsupported`, and there are zero child-plan instances. Production packing
refuses admission until M1 supplies the initial-root startup/charge plan.

Sanitizer checks run the implemented host C readers, ERXPACK validator and
ELF planner with ASan/UBSan, and the generated atomic accessor test with
TSan. Fuzzing runs the generated C ABI/manifest decoder,
ERXPACK and ELF C cores under libFuzzer/ASan/UBSan, the generated Erlang
reader's hostile corpus, and the implemented Ruby parser targets.
`tools/erx check-fuzz --seconds 5 --runs 100000 --seed 1` changes the
timed Ruby and execution-bounded C budgets. The supplied seed applies to
the generated C ABI and timed Ruby targets. Other Ruby targets use 20,000
iterations with seed 1; pack/ELF libFuzzer seeds are recorded in logs.
Target runtime/service
parsers and production startup proof remain unsupported. TLC is a separate
offline gate and verifies its jar pin; `TLA_TOOLS_JAR` selects another
location for those same bytes.

Sanitizer reports terminate their commands. ASan checks stack use after
return and permits allocation failure. Leak and initialization-order checks
require Linux; they are unsupported on macOS. `check-asan` and `check-tsan`
select this combined host gate. `check-ubsan` also runs the host gate, then
fails explicitly because its required kernel UBSan boot is unsupported
until erXos's kernel exists.

## Guest and stock oracle

```sh
make build
make run ACCEL=tcg
make run ACCEL=hvf
make oracle-build DOCKER_CONTEXT=NAME FLAVOUR=emu
make check-oracle-host DOCKER_CONTEXT=NAME FLAVOUR=emu
make bench FLAVOUR=jit
tools/erx status
```

Repeat oracle commands with `FLAVOUR=jit` for BeamAsm. Full stock suites
run inside the offline Linux container and retain failures, skips and
incomplete results. `make check-oracle` reports unsupported erXos parity
until target ERTS and libc-test domains exist. Native benchmarks are
labelled separately from Linux suite evidence. Interpreter benchmarks
require a separate native bootstrap built with
`tools/erx oracle build --backend native --flavour emu`.
The aggregate host oracle target stops at its first failed suite. To retain
all outcomes independently, run `tools/erx oracle run emulator`, `kernel`
and `stdlib` separately with the selected `--docker-context` and `--flavour`.

The guest demo checks the frozen Fiasco banner under an explicit
accelerator. It does not boot an admitted erXos image. Commands keep logs
and deadline records under `build/logs/`; test failures retain their
evidence. [Build design](docs/design-build.md) defines these boundaries.
