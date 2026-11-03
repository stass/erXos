# Research record: OTP 29.1.2 host baselines

**Measurement date:** 2026-11-02 UTC. Each result below identifies its own
artifact; additional measurements add records rather than replacing numbers.
The oracle implementation and isolation contract are in
[design-host-oracle.md](design-host-oracle.md).

## Source and Linux execution profile

The reference is unmodified OTP 29.1.2 from its verified release archive,
SHA-256 `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`.
Each suite builds a fresh source copy in a native Linux volume. These results
describe stock OTP; target erXos parity is not measured here.

The local `orbstack` engine is Docker 29.8.2, Linux
`7.2.12-orbstack-00394-gbecdd6130068`, architecture `aarch64`, with 16 reported
CPUs and 16,818,020,352 bytes of engine memory. The immutable tool image is
`docker.io/library/ruby@sha256:1b4ee3a2e4d38a7c0d31d8736133ddf76ef3bf0e9a3054c544863cbb199cdf7e`,
platform `linux/arm64`, configuration SHA-256
`93f9731928321cb869b2f977598b05ce53fb213f0ed9d87ea8b84688f16c8e44`.
The compiler is Debian GCC/G++ 12.2.0-14+deb12u1, with `CFLAGS=-O2`,
`CXXFLAGS=-O2`, and empty `CPPFLAGS` and `LDFLAGS`. Configure selects the
requested interpreter or JIT and disables wx, Java and ODBC.

Each run has a four-CPU quota, no external network interface, a non-root
workload, private startup directories, 4,096 native tasks (processes and threads) and
256 MiB of shared memory. RAM limits are per record; swap allowance is zero.
The oracle does not invoke QEMU. Engine and guest identities are recorded
independently; the first emulator receipt does not record the parent host's
OS identity.
The completed emulator record below left OTP's optional platform label
unset. Records with `platform_label: Docker` identify that environment to
the stock suites, including their Docker-specific skips; skips remain skips.

## Completed full-suite records

`Complete` means the completion event, case lifecycle, XML and totals
reconcile. A complete record can contain failed cases. Skips retain their
stock user/automatic classifications.

| Flavour | Suite | RAM | OTP label | Passed | Failed | User skipped | Auto skipped | Complete | Result |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | --- | --- |
| emu | emulator | 8 GiB | unset | 2,121 | 4 | 63 | 14 | yes | [failed](../build/oracle/linux/emu/run-20261102-27400-1o2rj4p/suite-result.json) |
| emu | kernel | 8 GiB | unset | 1,097 | 13 | 779 | 58 | yes | [failed, rechecked](../build/oracle/linux/emu/run-20261102-20356-1jdn61y/reconciled-suite-result.json) |
| jit | emulator | 8 GiB | Docker | 2,124 | 4 | 60 | 14 | yes | [failed](../build/oracle/linux/jit/run-20261102-87422-mh0vf0/suite-result.json) |
| jit | kernel | 8 GiB | Docker | 1,099 | 13 | 777 | 58 | yes | [failed](../build/oracle/linux/jit/run-20261102-35850-1xx71sc/suite-result.json) |
| jit | stdlib | 8 GiB | Docker | 2,144 | 17 | 452 | 0 | yes | [failed](../build/oracle/linux/jit/run-20261102-29052-hvd6m4/suite-result.json) |

The emulator run began at `2026-11-02T18:32:14Z`. Its four failures are
`statistics_SUITE:scheduler_wall_time`,
`statistics_SUITE:scheduler_wall_time_all`,
`signal_SUITE:parallel_signal_enqueue_race_2`, and
`process_SUITE:spawn_request_link_parent_exit_compound_reason`.
Their recorded reasons are a half-load check, a scheduler-statistics match,
a timetrap, and a missing exit signal with a retained peer connection,
respectively. This run does not establish whether these are upstream bugs
or consequences of its execution conditions. Its artifact set is complete
and both container namespaces and the volume were removed.

The kernel result was rechecked from the unchanged XML and event files.
Common Test recorded a whole-suite skip for `logger_stress_SUITE`, while
the XML hook kept the preceding `logger_std_h_SUITE` name. The rechecked
report preserves that original name and records the unique, exact event
match used to correct it. The first report remains beside it.

The JIT emulator run began at `2026-11-02T21:08:55Z`. Its four failures are
`scheduler_SUITE:equal_and_high_with_part_time_max`,
`signal_SUITE:parallel_signal_enqueue_race_2`,
`statistics_SUITE:scheduler_wall_time`, and
`statistics_SUITE:scheduler_wall_time_all`. The recorded reasons are a
priority-ratio check, a timetrap and two scheduler wall-time checks. Its
memory counters report no memory-limit kills; all owned resources were
removed.

The JIT kernel run began at `2026-11-02T21:59:31Z` and took 2,671 seconds.
Its counts reconcile with Common Test. The report records the same unique
whole-suite `logger_stress_SUITE` correction described above. Failed
testcases concern UDP/TCP/socket operations and the resolver; a separate
`gen_tcp_socket_SUITE:init_per_suite` failure is preserved as setup evidence.
Several reasons explicitly report no usable address or unreachable/refused
network operations in the isolated namespace. The record does not classify
these as upstream bugs. Its memory counters report no out-of-memory kill,
all required logs were exported, and all owned resources were removed.

These completed reports retain their recorded XML/event reporter identity.
They are point-in-time results. The stdlib ambiguity below is excluded from
the completion table; its fresh runs use controller-owned case records.

The controller-reported JIT stdlib run began at `2026-11-02T22:48:45Z`
and took 1,772 seconds. Its 3,129 testcase/configuration records reconcile
with Common Test totals. Nine failures are in `gen_statem_SUITE`, seven
are date checks in `y2k_SUITE`, and one is `zip_SUITE:unzip_jar`. The
`gen_statem_SUITE:idle/3` callback also raises `timeout_value` for a
100-millisecond delayed answer in a separate JIT VM without Common Test
or the reporter. The cause is unresolved; this does not establish an
upstream bug.
The three `peer_SUITE:cntrl_channel_handler_crash_old_release` executions
are each recorded as user-skipped, with separate controller logfiles and
the actual `dist`, `tcp` and `standard_io` groups. No passed execution is
inferred from the XML hook's extra row.

Two short diagnostic VMs ran inside the same owned container. The first
had an incorrect beam-file glob and wrote a crash dump outside
the exported log roots; its error log is retained and the dump disappeared
with the owned volume. The second catches startup errors and disables
crash dumps. Their commands, result and limitations are recorded in
[probe analysis](../build/oracle/linux/jit/run-20261102-29052-hvd6m4/probe-analysis.json).
The suite records no memory-limit events and verifies all owned resources
removed. Only Common Test's reporting controller differs from the archive;
the runtime, tested libraries and testcase sources remain stock.

## Failed attempts and checks

The host-mounted workspace was refused as a Linux reference after the same
mode-0111 ELF failed to execute there and executed successfully on the native
Linux filesystem. The partial host-mounted run is retained as an
[invalid-baseline diagnostic](../build/oracle/linux/emu/run-20261102-77277-17gbgc0/diagnostic-results.json).

A 4 GiB kernel attempt had two processes killed by its memory limit. The stock large-file
tests read or allocate binaries exceeding 4 GiB. That attempt was stopped,
its resources removed and its partial evidence retained as a
[resource-limited diagnostic](../build/oracle/linux/emu/run-20261102-53218-1wwad59/resource-limit-diagnostic.json).
It is not a completed full-suite baseline.
The [4 GiB stdlib attempt](../build/oracle/linux/emu/run-20261102-45354-gayz9y/suite-result.json)
also ended with the engine's out-of-memory flag set, during the Zip64 group setup.
Its partial record is explicitly resource-exhausted. It also exposed the
reporter's documentation chunk to `shell_docs_SUITE:render_man`; the
private reporter compilation excludes documentation and debug chunks.

The [8 GiB stdlib event report](../build/oracle/linux/emu/run-20261102-25161-1gt1ao9/event-execution-analysis.json)
establishes a finished run with 2,153 passed, eight failed and 452 skipped
outcomes, without a memory-limit kill. Its XML adds an unsupported passed
record for an occurrence that the event stream records as skipped. The
three skipped occurrences also have ambiguous group/log associations.
The full result therefore remains incomplete; the event-only report does
not claim complete group, repeat or log information.

The native-volume [permission probe](../build/oracle/linux/emu/probe-20261102-11305-1u1s35j/result.json)
proved successful mode-0111 execution and denied ordinary reads as the
non-root workload. The exact stock
[`port_SUITE:port_program_with_path`](../build/oracle/linux/emu/run-20261102-11941-1bi1lpj/suite-result.json)
then passed with complete reporting. The
[detached-child cleanup proof](../build/oracle/linux/cleanup-proof.json)
checked the separate owned fixture's running namespace and increasing
heartbeat across another fixture's cancellation. The
[startup/proxy proof](../build/oracle/linux/startup-proof.json)
checked poisoned parent startup and proxy settings against a stock testcase.
All these proofs verified removal of their owned containers and volumes.

The controller-owned reporter was checked with three real parallel peer
cases, two executions of a repeated group, a crash, a timetrap, a group
skipped before testcase initialization, a large integer return and an
invalid-UTF-8 skip reason. Testcase-supplied group paths and logfiles agree
with the case records. Stock, observed and deliberately broken-observer
runs produce identical testcase outcomes. A separate fixture kills the job
controller after its first completed case, before the next begins; Common
Test closes normally, but the report remains incomplete because the job
traversal did not finish. These native fixtures passed three tests and
43 assertions. The isolated Linux
[reporter smoke run](../build/oracle/linux/jit/run-20261102-21987-1v92ugv/suite-result.json)
then passed `binary_SUITE:deep_bitstr_lists` with complete case records,
source hashes and cleanup checks.

## Native macOS microbenchmarks

These measurements use the native macOS stock OTP 29.1.2 builds on Apple
M3 Max, Darwin 27.0.0 `arm64`. QEMU is not applicable. Both builds use Apple
Clang/Clang++ 21.0.0 (`clang-2100.3.34.2`), `CFLAGS=-O2`, `CXXFLAGS=-O2`,
and empty preprocessor/linker flags. Configure selects the recorded runtime
flavour and disables wx, Java and ODBC.

Runtime flags are `+S 1 +SDcpu 1 +SDio 1 +A 1 +sbwt none -noshell -noinput
-boot no_dot_erlang`. Each sample has 10,000 operations; the table gives the
median of seven recorded samples. Ping-pong is a 64-byte forward message
and sequence reply, including one worker start/stop per sample. Spawn is
sequential spawn, monitor and `DOWN` receipt. The workload source is
[`bench/erx_otp_bench.erl`](../bench/erx_otp_bench.erl); each artifact records
its source hash, compiler identity, build record and all raw samples.

| Workload | Flavour | Median ns/operation | Artifact |
| --- | --- | ---: | --- |
| ping-pong | emu | 1,723.6 | [samples](../build/bench/otp-pingpong-emu-20261102-74469-4cgo1c/result.json) |
| ping-pong | jit | 1,750.2 | [samples](../build/bench/otp-pingpong-jit-20261102-75786-jadb14/result.json) |
| spawn/monitor | emu | 1,961.8 | [samples](../build/bench/otp-spawn-emu-20261102-75143-lqrl2w/result.json) |
| spawn/monitor | jit | 1,975.4 | [samples](../build/bench/otp-spawn-jit-20261102-77310-u8pbtq/result.json) |
