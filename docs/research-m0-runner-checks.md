# M0 reference-runner checks

Measured on 2026-11-02. Native checks used Apple Silicon macOS (Darwin
27.0.0), stock OTP 29.1.2 JIT and the installed Ruby. Linux checks used
the pinned ARM64 Ruby/Bookworm tool image in OrbStack's Linux container
engine, with no external network, a non-root user and a native Linux volume.
These are runner checks, not evidence that erXos runs ERTS.

| Check | Platform | Result and evidence |
| --- | --- | --- |
| Controlled pass, failure, skip and actual 100 ms timetrap; three parallel peer groups and repeated-case identities | Native macOS, stock JIT | Passed: [3 tests, 45 assertions](../build/logs/m0-controlled-reporter-tests.log). Testcase-supplied groups/logfiles match the reporter; stock, reporting-enabled and broken-observer runs return identical outcomes. The [raw case output](../build/logs/oracle-controller-run-observed-7512-76107ac9925bb8c8.log) records `timetrap_timeout,100`. |
| Interrupted report after one completed case, before the next starts | Native macOS, stock JIT | Passed within the controlled checks: the [controller-abort fixture](../build/logs/oracle-controller-run-abort-7512-f5ae80ce6d813e84.log) reaches Common Test shutdown but remains incomplete without job completion. |
| Actual stock testcase with the controller reporter | Isolated Linux ARM64, stock JIT | [`binary_SUITE:deep_bitstr_lists`](../build/oracle/linux/jit/run-20261102-21987-1v92ugv/suite-result.json): one passed, complete case/configuration records and verified cleanup. |
| Native-filesystem and network conditions | Isolated Linux ARM64 | [Probe passed](../build/oracle/linux/emu/probe-20261102-11305-1u1s35j/result.json): mode-0111 executable runs while ordinary reads are denied; IPv4 TCP/UDP loopback works; only `lo` exists, no IPv4 external route exists, and the numeric external connection is unreachable. IPv6 evidence covers socket binding only, not full conformance. The exact stock [`port_program_with_path`](../build/oracle/linux/emu/run-20261102-11941-1bi1lpj/suite-result.json) case also passed. |
| Descendant cleanup and unrelated control fixture | Isolated Linux ARM64 | [Cleanup proof passed](../build/oracle/linux/cleanup-proof.json): cancelling a detached-child invocation removes its containers/volume; a separately owned control container remains running and its heartbeat increases. The proof then removes that control fixture itself. |
| Private startup and proxy settings | Isolated Linux ARM64 | [Startup proof passed](../build/oracle/linux/startup-proof.json): poisoned parent settings do not execute operator startup code; the selected stock case passes and owned resources are removed. |
| Malformed/partial events, case/group consistency, timeout/cancellation results and bounded export | Native macOS, synthetic inputs to production Ruby code | [Reader: 24/63](../build/logs/m0-oracle-reader-tests.log), [lifecycle: 31/141](../build/logs/m0-oracle-lifecycle-tests.log), [export: 26/90](../build/logs/m0-oracle-export-tests.log), all passed. [Command runner: 14/33](../build/logs/m0-command-runner-tests.log) includes a real subprocess deadline and child cleanup. [Parser fuzz](../build/logs/m0-oracle-parser-fuzz.log): 14,323 mutations, seed 1, no unexpected exception. These engine-response fixtures do not claim additional real Docker executions. |

The checked-in reporting copy retains its upstream notice and original
hash. Its source test recovers the exact original controller by removing
only the enumerated observation statements. Detailed testcase reasons stay
in raw Common Test logs; missing evidence stays incomplete.

A final check on 2026-11-02 exercised the sealed selection of jobs, normal
two-job completion, aborting before a queued job, and a worker ending before
suite setup. Together with repeated-case identities, skips, timetraps,
invalid UTF-8 and source verification, the
[focused reporter checks](../build/logs/m0-final-reporter-tests.log) passed
8 tests and 67 assertions. The final Linux
[`binary_SUITE:deep_bitstr_lists` run](../build/oracle/linux/jit/run-20261102-10918-sazx94/suite-result.json)
passed with complete case/configuration records and verified cleanup.

The [final combined M0 checks](../build/logs/m0-final-verification.log)
passed on the same host: 488 host tests with 1,655 assertions, eight native
integration tests with 59 assertions, and 53 sanitizer tests with 239
assertions. Generated-file drift checks, structural-image reproducibility
and all implemented fuzz targets passed. The four TLC runner configurations
matched their expected results through the verified cache. The separate
[schema regression run](../build/logs/m0-final-schema-tests.log) passed
39 tests with 51 assertions after adding rejection of unknown table-order
entries in a reader with no tables. macOS leak and initialization-order
sanitizers, target parsers and initial-root startup remain unsupported as
described in the README.

Complete-suite measurements and unresolved stock/environment failures are
separate [research records](research-otp29-baselines.md). They do not gate
M0; full reference suites are required before ERTS port changes. No target
ERTS parity or complete IPv6 conformance is claimed here.
