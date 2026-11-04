# Stock OTP 29.1.2 reference runs

Recorded on 2026-11-04. This is the record that [plan.md](plan.md) (Track H)
requires before any ERTS edit: the complete `emulator`, `kernel` and `stdlib`
suites of stock OTP 29.1.2, each run in interpreter mode and in JIT mode. It
states what ran, where, what each run reported, and what is not known. It
does not diagnose failures. They are stock OTP's results in this
environment.

## Summary

All six runs finished. None timed out, none ended with incomplete records,
and Common Test's own run closed normally in each. Every run reports state
`failed` because at least one test case failed; that is the suite result,
not a runner fault. In every run the runner reports the case list as
complete, the selection sealed with a normal closure, and no partial events.

Across the three suites, the interpreter runs show 24 failed test cases and
the JIT runs 33. Of those, 23 test cases fail in both modes, 10 fail only in
JIT mode and 1 fails only in interpreter mode. One further failure, a
failed `init_per_suite` in `gen_tcp_socket_SUITE`, occurs in both kernel runs
and is counted separately below because the runner's totals count test
cases only.

## Environment

| Item | Value |
| --- | --- |
| Date | 2026-11-04, runs between 13:19Z and 17:30Z |
| Host | Apple M3 Max, 16 cores, 128 GiB; macOS 27.0.1 (build 26A434), Darwin 27.0.0, `arm64`; host Ruby 4.0.9 drives the runner |
| Linux engine | OrbStack 2.2.5, Docker engine 29.8.2, context `orbstack`; VM kernel 7.2.12-orbstack, `aarch64`, 16 CPUs and about 16 GiB visible to the VM |
| Container limits | 4 CPUs, 8 GiB memory, no swap, 4096 pids, 256 MiB `/dev/shm`; no external network interface (loopback only, IPv6 available); non-root user |
| Image pin | `docker.io/library/ruby@sha256:1b4ee3a2e4d38a7c0d31d8736133ddf76ef3bf0e9a3054c544863cbb199cdf7e`, `linux/arm64`; configuration digest `sha256:93f9731928321cb869b2f977598b05ce53fb213f0ed9d87ea8b84688f16c8e44` |
| Toolchain in the image | gcc and g++ 12.2.0 (Debian 12.2.0-14+deb12u1), `-O2` |
| OTP | 29.1.2, source archive SHA-256 `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049` (the same in both builds) |
| Configure arguments | `--prefix=/tmp/erx-oracle/install --without-wx --without-javac --without-odbc`, plus `--disable-jit` for the interpreter build and `--enable-jit` for the JIT build |
| Jobs | 4 (`--jobs 4`); per-suite deadline 14400 s |
| Reporter | `common_test_controller`, with the `cth_surefire` hook and an event handler that writes `events.jsonl` |

Why Linux and not macOS. [design-host-oracle.md](design-host-oracle.md)
puts the full stock oracle in a task-owned Linux container with no external
network, because the suites open sockets, listeners and fixed ports and start
peer nodes and daemons, and these stay inside the container. A Linux result
does not claim macOS behavior. No macOS run of these suites was made for this
record, so whether the failures below would also occur on macOS is unknown.

Host load. Unrelated jobs ran on the same host during these runs, among them
QEMU guests and builds. Their load was not measured here. It may affect the
timing-sensitive failures; this record does not claim that it does.

## Method

The driver is `tools/erx oracle`, called by a scratch script
(`trackh_runs.rb`) that runs, for each flavour `emu` (interpreter) and
`jit`: `tools/erx oracle build --docker-context orbstack --flavour F --jobs 4`;
then, for each suite in the order `stdlib`, `kernel`, `emulator` and each
flavour: `tools/erx oracle run SUITE --docker-context orbstack --flavour F
--jobs 4 --deadline 14400`. A failing step is logged and the next step still
runs. The step log marks all six runs "not completed (1)", which means the
suite ran and returned failures; each `suite-result.json` confirms
`complete: true` with no partial events.

Run selection. The build directory holds earlier attempts from before a
restart: eight attempts at 13:00Z to 13:02Z that ended in `artifact_error`
and have no `suite-result.json`, and a probe. They are not used. The six runs
here are the `run-*` directories whose `suite-result.json` exists and whose
start and finish times match the six `run-` lines of the step log
(each finish within a few seconds of its logged time). Directory names are
below `build/oracle/linux/` of the tree that ran them.

| Suite and mode | Run directory | Started (Z) | Finished (Z) | Wall time | Test command time |
| --- | --- | --- | --- | --- | --- |
| stdlib, interpreter | `emu/run-20261104-27380-6xwgn8` | 13:19:29 | 13:52:12 | 32 min 43 s | 1910 s |
| stdlib, JIT | `jit/run-20261104-76224-y4v8zq` | 13:52:20 | 14:21:50 | 29 min 30 s | 1712 s |
| kernel, interpreter | `emu/run-20261104-23646-j2e9x5` | 14:21:59 | 15:07:09 | 45 min 10 s | 2659 s |
| kernel, JIT | `jit/run-20261104-96249-gfoc6n` | 15:07:18 | 15:52:29 | 45 min 11 s | 2649 s |
| emulator, interpreter | `emu/run-20261104-89519-547dow` | 15:52:38 | 16:39:54 | 47 min 16 s | 2782 s |
| emulator, JIT | `jit/run-20261104-72247-ptotj6` | 16:40:03 | 17:30:11 | 50 min 08 s | 2945 s |

Wall time is the container's start to finish. Test command time is the
`make` invocation inside it. The two builds finished at 13:18:18Z
(interpreter) and 13:19:22Z (JIT), each recorded as about one minute of
container time; why a full OTP build took so little was not investigated.

## Totals

Counts are test cases only, as the runner reports them. Configuration
functions (`init_per_suite`, `end_per_group` and so on) are separate rows and
are listed after the table.

| Suite | Mode | Passed | Failed | User skip | Auto skip | Case rows |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| stdlib | interpreter | 2153 | 8 | 452 | 0 | 3129 |
| stdlib | JIT | 2144 | 17 | 452 | 0 | 3129 |
| kernel | interpreter | 1095 | 14 | 779 | 58 | 2405 |
| kernel | JIT | 1099 | 13 | 776 | 58 | 2405 |
| emulator | interpreter | 2123 | 2 | 63 | 14 | 2628 |
| emulator | JIT | 2125 | 3 | 60 | 14 | 2630 |
| all | interpreter | 5371 | 24 | 1294 | 72 | 8162 |
| all | JIT | 5368 | 33 | 1288 | 72 | 8164 |

Incomplete or timed out: none in any run. "Case rows" counts test cases and
configuration functions together, so it exceeds the sum of the four counts.
The configuration rows are: stdlib 468 passed and 48 user
skipped in both modes; kernel 440 passed, 16 user skipped, 1 failed and 1
auto skipped (interpreter) against 442, 14, 1 and 1 (JIT); emulator 416
passed and 10 user skipped (interpreter) against 418 and 10 (JIT). Two
runs, kernel interpreter and kernel JIT, also report one suite-level user
skip each, outside the table. What it refers to was not looked up.

Rows with an attempt number above 1 (17 in `stdlib`, 1 in `kernel`, the same
rows in both modes; for example the `stdlib_bench_SUITE` groups) are repeated
executions and are counted in the totals as the runner counts them. The
`suite-result.json` of the JIT stdlib run shows 3130 rows in its metadata
block against 3129 case entries; the extra row is unexplained.

## Failed cases

A case is `suite[:group path]:testcase`. "Both" means the same case failed in
both modes. The stored results keep each failure's identity and status; the
failure text itself is marked "detail retained in raw Common Test log", and
those logs are not stored (see below).

### stdlib

| Case | Interpreter | JIT |
| --- | --- | --- |
| `y2k_SUITE:date_1999_02_28`, `date_1999_09_09`, `date_2000_01_01`, `date_2000_02_29`, `date_2001_01_01`, `date_2001_02_29`, `date_2004_02_29` (7 cases) | failed | failed |
| `zip_SUITE:unzip_jar` | failed | failed |
| `gen_statem_SUITE:abnormal:abnormal1`, `abnormal1clean`, `abnormal1dirty` | passed | failed |
| `gen_statem_SUITE:abnormal_handle_event:abnormal1`, `abnormal1clean`, `abnormal1dirty` | passed | failed |
| `gen_statem_SUITE:send_request_receive_reqid_collection`, `send_request_wait_reqid_collection`, `send_request_check_reqid_collection` | passed | failed |

8 fail in both modes and 9 fail only in JIT mode.

### kernel

| Case | Interpreter | JIT |
| --- | --- | --- |
| `gen_tcp_misc_SUITE:inet_backend_default/close:close_with_pending_output` | failed | failed |
| `gen_tcp_misc_SUITE:inet_backend_default:delay_send_error` | failed | failed |
| `gen_tcp_misc_SUITE:tickets:otp_18357` | failed | failed |
| `gen_udp_SUITE:inet_backend_default:` `buffer_size`, `binary_passive_recv`, `read_packets`, `recv_poll_after_active_once`, `connect`, `reconnect`, `active_n` (7 cases) | failed | failed |
| `inet_res_SUITE:txt_record` | failed | failed |
| `socket_SUITE:ioctl/ioctl_simple:ioctl_nread` | failed | failed |
| `socket_api_SUITE:from_fd/ffd_tcp:api_ffd_open_connect_and_open_wd_and_send_tcp4` | failed | failed |
| `global_SUITE:simple_resolve2` | failed | passed |
| `gen_tcp_socket_SUITE:init_per_suite` (configuration, not in the totals) | failed | failed |

13 test cases fail in both modes, 1 fails only in interpreter mode
(`global_SUITE:simple_resolve2`), none fail only in JIT mode. The failed
`init_per_suite` fails in both.

### emulator

| Case | Interpreter | JIT |
| --- | --- | --- |
| `statistics_SUITE:scheduler_wall_time` | failed | failed |
| `statistics_SUITE:scheduler_wall_time_all` | failed | failed |
| `signal_SUITE:parallel_signal_enqueue_race_2` | passed | failed |

2 fail in both modes and 1 fails only in JIT mode.

Failures that occur in both modes: 23 test cases and one configuration
function. Failures that differ: 10 only in JIT mode and 1 only in
interpreter mode.

What is known: names, statuses and modes, as above. The network-related
failures (`gen_tcp_misc`, `gen_udp`, `inet_res`, `socket`, `socket_api`,
`global`) ran in a container whose only interface is loopback, with no route
and no external name resolution, as the container's own probe records.
Whether that or anything else causes any particular failure was not
checked. Likewise, whether host load explains the `statistics_SUITE`
scheduler wall time cases, the `signal_SUITE` race or the JIT-only
`gen_statem_SUITE` failures is unknown. The comparison with erXos's runs
treats all of these as stock results to be reproduced or explained, not as
bugs.

## Differences in which cases ran

The set of case rows is the same in both modes for `stdlib` and `kernel`
(3129 and 2405 rows). `emulator` has two rows only in JIT mode
(`jit_SUITE:perf` `init_per_group` and `end_per_group`, both user skipped).
Besides the failures above, rows with a different status between modes are:

* `kernel`: five rows of `code_coverage_SUITE` (`init_per_suite`,
  `toggle_modes`, `get_coverage`, `error_info`, `end_per_suite`) are user
  skipped in interpreter mode and passed in JIT mode.
* `emulator`: five rows are user skipped in interpreter mode and passed in
  JIT mode: `jit_SUITE` (`init_per_suite`, `jmsingle`, `named_labels`,
  `end_per_suite`) and `erl_debugger_SUITE:stack_frames:
  test_stack_frames_returns_y_regs_controlled_by_size`.

The skip reasons are in the raw logs and were not read for this record.

## Where the results are

Complete case-level results (every case's suite, group, name, attempt,
status, kind, duration and log pointer, plus the run's counts, build record,
host record and command record) are the `suite-result.json` of each run.
Logs and raw results stay out of the erXos repository. They are in the
separate local repository `~/erxos-history`, commit `fcc604ebdee27a68664a0bdf619ea0952a868653`, directory
`otp-reference-runs/otp-29.1.2/`, which has no remote. It holds one file per
suite and mode (`stdlib-interpreter.json.gz`, `stdlib-jit.json.gz`,
`kernel-interpreter.json.gz`, `kernel-jit.json.gz`,
`emulator-interpreter.json.gz`, `emulator-jit.json.gz`), about 1.4 MB
together, each the unmodified `suite-result.json`, gzip-compressed with a
zero timestamp. No erXos tool reads this location yet. The source files'
SHA-256 values:

| File | SHA-256 of the uncompressed `suite-result.json` |
| --- | --- |
| `stdlib-interpreter` | `07563d1cf1b6ca2d8f51952add8c14d3b6be4c9fed22e741caf63d6a4f816ca8` |
| `stdlib-jit` | `385743d997a740323ece84908f22303d88ee0dc8296d077579af5187c4af76a7` |
| `kernel-interpreter` | `0faa24fdc5b6e50de2bb62d2b59a9250b921d378be6e86b14e367e4a2981978e` |
| `kernel-jit` | `e089f012bd460bc21fd5bd34c0e2f4a42e5948bff15a5dbc1b58707151cb4d21` |
| `emulator-interpreter` | `ac6ec6f42a0274bb65f0d1b2cccbce758da020ddb19f85da3f58b1db29713609` |
| `emulator-jit` | `7959fe76da7c5fb060a1887de358ac65675390814e6a006508b9fad16c285fdc` |

The same directory's `raw-logs.tar.gz`, 50 MB, holds the oracle's whole
`build/oracle/linux` directory: the raw Common Test HTML logs, the JUnit XML,
`events.jsonl`, the container and step logs, and so the failure text of every
failed case. The result files' log pointers name paths inside it, below
`build/oracle/linux/`. Each `inputs/` directory is left out, since it held a
copy of the OTP source tree. Each `suite-result.json` also names the `make`
command, so a single suite can be rerun with the same tool and flags above.
