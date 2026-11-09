# Gate G5: BeamAsm against the interpreter in ordinary domains

A point-in-time report. Measured on 2026-11-09 with `tools/erx bench g5 --accel
hvf` from commit 0d7f29ee of the JT3 branch (the bench tooling of the commit that
adds this file). The raw results (`result.json`, the guest's serial log and
QEMU's report) are in the separate history repository, `~/erxos-history`, at
`bench/g5/2026-11-09/hvf/`, commit bb61130. Gate G5 is in
[plan.md](plan.md); BeamAsm's place in the system is in
[design-runtime.md](design-runtime.md#beamasm).

This covers only the BeamAsm part of G5 on the stopgap: BeamAsm's speedup over
the interpreter, each flavour's footprint, and the time to load a release when
a domain starts. E-D1 and E-D2 (`xdomain-pingpong`, `xdomain-throughput`) and
the speedup on OTP's benchmarks and the oracle's suites are not measured here.

## Conditions

| Item | Value |
| --- | --- |
| Host | Apple M3 Max (16 CPUs), macOS 27.0.1, load average 5.8 to 8.8 before and after the guest |
| Accelerator | HVF only; there is no TCG run |
| QEMU | 11.1.3, `virt`, `-cpu host`, 1 CPU, 768 MiB (MediumBoot's machine) |
| Guest | the production image with MediumBoot's manifest (one configured domain row, room for two domains), booted from its single file; ERTS from OTP 29.1.2 |
| Domains | created from the system domain's Erlang shell through `erx_domain:create`, one at a time after the configured domain ended, each with a 160 MiB budget, a grant of CPU 0 at 1000 mcpu and one scheduler, booting the domain release (`erts`, kernel and stdlib) in embedded mode |
| Flavours | `runtimes/emu` (the interpreter) and `runtimes/jit` (BeamAsm, in a space made with `ERX_SPACE_JIT` because its manifest carries `ERX_IMAGE_JIT`); each flavour's `emu_flavor` is checked in its own output |
| Compiler | Homebrew clang 23.1.3; ERTS `CFLAGS` `-O2 -g -D__erxos__ -DERX_TRACE_START`, `CXXFLAGS` `-O2 -g -D__erxos__ -fno-exceptions -fno-rtti`, target `aarch64-none-elf` with `-fno-stack-protector -mno-outline-atomics`; full lines in `result.json` (`build`) |
| Baseline | the interpreter domain on the same image, release and workload |
| Rounds | two domains of each flavour, interpreter and BeamAsm alternating; five samples of each workload in each domain |

## Workload

Each domain's `-eval` runs compiled code of its own release, the same beam bytes
in both flavours, because a domain has no connection to load another module
through. Each sample is one call, timed with `timer:tc`, so the interpreted
`-eval` stays outside the timed calls.

| Workload | The call |
| --- | --- |
| sort | `lists:sort/1` of a list of 100,000 integers |
| json_encode | `json:encode/1` of that list |
| json_decode | `json:decode/1` of its encoding |
| scan | `erl_scan:string/1` of the same text |

## Speed

Each cell is the median over both domains' ten samples, in microseconds. The
speedup is the interpreter's median over BeamAsm's.

| Workload | Interpreter | BeamAsm | Speedup |
| --- | --- | --- | --- |
| sort | 15,217 | 13,225 | 1.15 |
| json_encode | 2,269 | 1,957 | 1.16 |
| json_decode | 15,469 | 9,780 | 1.58 |
| scan | 61,126 | 47,872 | 1.28 |

The samples spread widely within each domain (json_decode under BeamAsm: 3,179 to
31,701), and the spread follows garbage collection of the 100,000-element terms
each call builds, which is C code in both flavours. The fastest samples give
larger ratios (json_decode 3.7, scan 1.55, sort 1.23, json_encode 1.14). So these
workloads bound BeamAsm's gain on allocation-heavy library code from below; they
are not a measurement of the "up to four times" figure in design-runtime.md,
which needs OTP's benchmarks.

## Start and translation

Medians of the two domains of each flavour.

| | Interpreter | BeamAsm |
| --- | --- | --- |
| runtime start to `-eval` (`start_us`), us | 92,262 | 188,028 |
| modules loaded, with object code on the code path | 244 | 244 |
| their beam bytes | 10,819,392 | 10,819,392 |
| `erlang:prepare_loading` of all of them again (`prepare_us`), us | 52,803 | 109,981 |

In embedded mode the start loads every module of the release, so the 96 ms
difference in `start_us` is what BeamAsm's translation adds to a domain's start
for this release. `prepare_us` repeats the loading of the same modules from bytes
in memory without starting anything: decoding, plus translation under BeamAsm,
57 ms more than the interpreter's own load-time preparation.

## Footprint

`erlang:memory()` in each domain right after its boot, in bytes. The two domains
of each flavour agree within a few kilobytes.

| | Interpreter | BeamAsm |
| --- | --- | --- |
| total | 37,888,480 | 36,949,755 |
| code | 11,938,778 | 11,031,390 |
| system | 23,304,128 | 22,393,687 |
| processes | 14,584,352 | 14,556,068 |

## Not measured

* **A domain's memory as the kernel sees it** (pages mapped, budget in use).
  Unsupported on the stopgap: the domain library does not report a domain's
  budget use, and the stopgap Fiasco has no per-domain counter.
  `erlang:memory()` is the only footprint value here. It does not count what
  sits outside ERTS's allocators: BeamAsm's generated code lives in JIT objects
  mapped twice, and whether ERTS's `code` figure covers them was not checked, so
  the lower `code` figure for BeamAsm does not show that BeamAsm's code takes
  less memory.
* **TCG.** Not run. TCG numbers are never compared with these.
* **OTP's benchmarks and the oracle's suites under BeamAsm.** These are G5's
  measure of the speedup, and they need a module loaded into a domain from
  outside its release (VF3 and VF5 of the 1b-A package plan).
* **More than one CPU or scheduler per domain.**
* **Run-to-run variation.** One run; the two domains of each flavour are the
  only repeat.

## Reproducing

```
tools/erx bench g5 --accel hvf
```
