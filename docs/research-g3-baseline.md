# Gate G3 baseline: W1, footprint and boot time

A point-in-time report. Measured on 2026-11-06 from commit 344afe57 plus the
bench tooling of the commit that adds this file. The raw results (the
two `result.json` reports, each guest's serial log and QEMU report) are in the
separate history repository, `~/erxos-history`, at
`bench/g3/2026-11-06/{hvf,tcg}/`, commit 9b8fd6b. Gate G3 is in
[plan.md](plan.md#m3-the-shell-is-the-operating-system); W1 is defined in
[design-scheduler.md](design-scheduler.md) (E-S1).

## Conditions

| Item | Value |
| --- | --- |
| Host | Apple M3 Max (16 CPUs), macOS 27.0.1, nothing else running |
| Accelerators | HVF and TCG, two separate runs; their numbers are never compared with each other |
| QEMU | 11.1.3, `virt-11.1`, `-cpu host` under HVF, 1 CPU, 512 MiB |
| Guest | the development boot image (`tools/erx bench g3`), interpreter emulator (`emu`), one scheduler, ERTS from OTP 29.1.2 in the system domain |
| Guest compiler | Homebrew clang 23.1.3; ERTS flags `-O2 -g -D__erxos__ -DERX_TRACE_START` (C and C++), target `aarch64-none-elf` with `-fno-stack-protector -mno-outline-atomics`; full flag lines in each `result.json` (`erts_build_flags`) |
| Baseline | stock OTP 29.1.2, `emu` flavour, native on the host, built by Apple clang 21.0.0 (the oracle build, receipt in `result.json`), run with `+S 1 +SDcpu 1 +SDio 1 +A 1 +sbwt none -noshell -noinput -boot no_dot_erlang` |
| Workload source | `bench/erx_otp_bench.erl`, the same beam bytes on both sides (the guest loads them through the shell) |
| Size | HVF: 10,000 iterations, 7 samples; TCG: 1,000 iterations, 3 samples; the ring gets ten times the iterations. The stock side uses the same sizes as the guest of that run |

Each cell is the median of the samples, in nanoseconds per operation, with the
smallest and largest sample in parentheses. Ratio is guest over stock, so
below 1 means erXos takes less time.

## W1 (same-domain, entirely inside one ERTS)

Operations: pingpong is one 64-byte message and its reply; ring is one send in
a ring of 10,000 processes (set-up and tear-down excluded); spawn is a spawn,
monitor and DOWN receipt; switch is one `erlang:yield()` with two processes
alternating on one scheduler.

HVF:

| Workload | erXos ns/op | Stock OTP ns/op | Ratio |
| --- | --- | --- | --- |
| pingpong | 345 (338-356) | 2376 (2356-4869) | 0.15 |
| ring | 139 (130-149) | 864 (850-897) | 0.16 |
| spawn | 559 (555-568) | 2248 (2158-4465) | 0.25 |
| switch | 48 (46-52) | 748 (732-786) | 0.06 |

TCG (correctness-grade; the guest's instructions are emulated):

| Workload | erXos ns/op | Stock OTP ns/op | Ratio |
| --- | --- | --- | --- |
| pingpong | 5100 (5021-5166) | 1971 (1962-2211) | 2.59 |
| ring | 1878 (1867-2055) | 1005 (928-1064) | 1.87 |
| spawn | 21992 (12777-29073) | 2118 (2112-2697) | 10.38 |
| switch | 773 (746-795) | 924 (880-1113) | 0.84 |

The stock numbers are well above the guest's under HVF, which is not what one
expects of the same emulator on the same CPU. The cause is not investigated.
The stock `switch` cost is stable across `+sbwt` settings (about 700 to 1200 ns
in a spot check) and does not look like noise or load. Treat the HVF ratios as
"stock on macOS, as built here, is slow at these four operations", not as a
claim that erXos's ERTS is faster. The stock numbers may carry a macOS cost
(scheduler loop or I/O polling on each yield) that the guest has no
equivalent of.

## Boot time to the shell

Seconds from QEMU's start to the line `Eshell V...`, which the shell prints
just before its first `1>` prompt (the prompt has no newline, so the harness
cannot match it). One boot per accelerator. The harness reads the serial log
every 50 ms, so each value has about that resolution.

| Accelerator | Kernel banner | `Erlang/OTP 29` slogan | `Eshell V` line |
| --- | --- | --- | --- |
| HVF | 0.11 | 0.21 | 0.27 |
| TCG | 0.16 | 1.26 | 1.37 |

## Footprint at the idle shell

`erlang:memory()` in the system domain, read by the first line typed at the
shell, before the bench beam is loaded. Bytes.

| | erXos (HVF) | erXos (TCG) | Stock OTP |
| --- | --- | --- | --- |
| total | 30,044,008 | 29,972,016 | 44,800,016 |
| processes | 13,685,424 | 13,631,272 | 13,166,584 |
| system | 16,358,584 | 16,340,744 | 31,633,432 |
| code | 6,515,483 | 6,517,699 | 5,933,212 |
| atom | 303,879 | 303,888 | 295,841 |
| ets | 416,184 | 416,696 | 585,040 |
| processes (count) | 39 | 39 | 42 |
| loaded modules | 123 | 124 | 105 |

The stock run has no shell (`-noshell`) and a different module set, so its
rows describe a bare ERTS and kernel, not the same idle state.

## Not measured

* **Memory of the system domain as the kernel sees it** (pages mapped, budget
  in use). Unsupported: the inspector that reports it is M4, and the stopgap
  Fiasco has no equivalent per-domain counter. `erlang:memory()` is the only
  footprint value here, and ERTS's own view omits its text, stacks and the
  liberx root.
* **The hosted backend.** G3 compares against stock OTP on the host; the
  hosted runtime was not run.
* **The JIT flavour.** The guest is the interpreter, so the baseline is stock
  `emu`. The stock `jit` flavour was not compared.
* **Multi-CPU guests.** W1 is one scheduler; `+S` greater than 1 was not run.
* **Run-to-run variation.** One run per accelerator; the spread is the
  samples within it.

## Reproducing

```
tools/erx bench g3 --accel hvf
tools/erx bench g3 --accel tcg
```

Each builds the development image (or boots `--image PATH`), runs the guest,
then runs stock OTP at the guest's sizes and writes
`build/bench/g3-<accel>-*/result.json`.
