# Research: where a program's file call spends its time

A point-in-time report. Checked on 2026-11-26 against erXos master
`76540b79d`, on an Apple M3 Max (Mac15,9, 16 host CPUs, a one-minute
load of 5 to 7 from other work), QEMU 11.1.3 `virt` under HVF with 752
MiB, Homebrew clang 23.1.3, `erx_peer_bench posix` at the landing
profile (`-DERX_BENCH_FAST_SAMPLES=10000u`, 1,000 warm-up calls; the
record's `flags` list the rest). The program runs in root's session, so
its file calls go to Erlang in the system domain; `/tmp` is the
domain's own RAM file system (`erx_ramfs`), so no call here crosses to
another domain. Numbers are counter ticks at 24 MHz turned into
microseconds (one tick is 41.7 ns). TCG numbers are quoted only beside
TCG numbers.

## Why

Under TCG at 4 CPUs (history commit `539007f`,
`bench/qemu-tcg-Mac15,9-4cpu-erxos/20261126T064546Z-*`), erXos's `open`
is 1,065 us at the median against Genode's 72 us, `fstat` 582 us
against 16 us, and a 4 KiB `read` 516 us against 20 us, while `getpid`
(64 ns) and `clock_gettime` (192 ns) are fast. Every call that reaches
the session's Erlang pays about half a millisecond there. Under TCG,
erXos's own one-byte pipe round trip, which crosses no Erlang, is
already 93 us, 44 times its 2.1 us under HVF, about the ratio of the
file calls (a 4 KiB read is 39 times its HVF median); the breakdown below
is taken under HVF, where the same calls cost 13 to 50 us.

## The baseline under HVF

`tools/erx bench posix --systems erxos`, one boot per CPU count, history
commit `a4949c0`:
`bench/qemu-hvf-Mac15,9-1cpu-erxos/20261126T073333Z-76540b79db96-e3e516bd3c59`
and `bench/qemu-hvf-Mac15,9-4cpu-erxos/20261126T073827Z-76540b79db96-e3e516bd3c59`.

| Row (p50) | 1 CPU | 4 CPUs |
| --- | --- | --- |
| `open` | 50.6 us | 50.6 us |
| `close` | 21.6 us | 21.0 us |
| `fstat` | 16.1 us | 16.0 us |
| `read` 4 KiB | 13.1 us | 13.3 us |
| `write` 4 KiB | 13.8 us | 14.3 us |
| `pipe-rtt` 1 byte, same CPU | 2.1 us | 2.1 us |
| `cond-pingpong`, same CPU | 0.58 us | 0.58 us |
| `mmap` 1 page | 0.88 us | 0.88 us |
| `map-cycle` 64 pages | 73.3 us | 58.6 us |

A file call costs six to eight one-byte pipe round trips; an open,
twenty-four. One and four CPUs agree, for a reason the stamps show:
the program's doorbell hands its own CPU to the session.

## The path one call takes

From the code (`liberx/program/file.c`, `liberx/program/channel.c`,
`liberx/program/program.c`, `otp/erts/emulator/sys/erxos/erx_program_drv.c`,
`erlang/apps/erx/src/erx_prog_handler.erl`,
`erlang/apps/erx/src/erx_file_description.erl`,
`otp/erts/preloaded/src/erx_file_remote.erl`,
`erlang/apps/erx_files/src/erx_fs_grant.erl`,
`erlang/apps/erx_files/src/erx_ramfs.erl`), an `fstat`:

1. The requester encodes `{file, getattr, Open}` in ETF, takes a reply
   slot, puts the frame on the channel's outbound lane and triggers the
   session's doorbell (`l4_irq_trigger`).
2. The doorbell schedules the port's input task; the driver copies the
   record, passes it through the funnel's channel mode and ERTS's safe
   decode, and sends `{erx_channel, Port, Frame}` to the handler.
3. The handler's core steps and sends `{getattr, Slot}` to the
   open-file description process.
4. The description calls `file:read_file_info/2`: `erx_file_remote`
   checks the request against the 9P grammar, monitors the grant and
   sends it the request; the grant's funnel decodes it again and calls
   `erx_ramfs:getattr/2`, which monitors the tree process with an alias
   and sends it the request; the tree answers, the grant answers.
5. The description sends `{erx_file_done, Slot, Info}` to the handler.
6. The handler's core builds the reply, and `erx_program:send/2` writes
   it on the inbound lane and rings the program's doorbell.
7. The program's event executor wakes from `erx_park`, reads and decodes
   the reply into the slot and wakes the requester with `erx_umtx_wake`.

Seven Erlang messages (port to handler, handler to description,
description to grant, grant to tree and back, grant to description,
description to handler) and two monitors with aliases per call; three
kernel thread switches on the way (requester to session at the trigger,
session to executor at the session's park, executor to requester at the
umtx wake), and no timer: nothing waits for a periodic poll or a sleep
quantum, so no leg shows a flat millisecond.

## The legs

Throwaway stamps (not landed; the patch is
`bench/2026-11-26-file-call-path/instrument-hackA.patch` in the history
repository, without its two `hack_` lines for these rows) read one clock,
`erx_clock_ns`, which both `liberx` and ERTS's `os:perf_counter/0` read.
Each stamp adds its value to a per-operation sum (C atomics in the
program, an `atomics` array in the session), so a leg is the difference
of two means over the same calls; every stamp's count matched the
program's call count. The posix bench ran only `open`, `fstat` and
`read` 4 KiB. The stamps add about 0.7 us at the median (`fstat` 16.8
against 16.1 us). Runs: history commit `a6bf729`,
`bench/2026-11-26-file-call-path/instrumented/` (1 and 4 CPUs);
`legs.rb` beside them computes the table from each serial log.

Means, 1 CPU (4 CPUs within 0.2 us of each):

| Leg | `fstat` | `read` 4 KiB (`pread`) |
| --- | --- | --- |
| program: encode, lane, doorbell, session wakes, input task, funnel, decode, to the handler | 2.2 us | 2.3 us |
| handler's step and send to the description | 1.0 us | 0.9 us |
| description's file call: grant and tree (step 4) | **5.4 us** | **4.4 us** |
| description to the handler | 0.7 us | 0.7 us |
| handler's step to the reply (for `read`, the copy into the data slot) | 2.0 us | 1.1 us |
| `erx_program:send/2`: lane write and ring | 0.9 us | 0.6 us |
| session's tail and park, executor's wake, reply read and decoded | **3.4 us** | **2.6 us** |
| executor's umtx wake to the requester running | 0.5 us | 0.5 us |
| total | 16.2 us | 13.0 us |

The program's "sent" stamp, taken when `erx_irq_trigger` returns, lands
after the reply is already in the inbound lane on 4 CPUs as on 1: the
trigger makes the session's scheduler thread run on the program's own
CPU at once, and the program resumes only after the session parks. The
call is serial by construction, which is why the CPU count changes
nothing.

`open` (`lopen`), 52 us in total with the stamps:

| Leg | Mean |
| --- | --- |
| program to the handler | 2.7 us |
| handler's core step | 3.1 us |
| `erx_facets:program_table/1` | 1.2 us |
| spawning the description to its first instruction | 1.2 us |
| **`prim_file:erx_open_at/5`** (resolution, the grant's walk, lopen and the description's file record) | **38 us** |
| back to the program, as for `fstat` | 4.6 us |

That `erx_open_at` makes about seven grant conversations of the
`fstat` kind is an inference from 38 us over 5.4 us, not a count; the
count is the next stamp to take.

## Hacks

**A: the grant leg removed.** The description answers each `getattr`,
and each `pread` at the same offset and count, from its first answer,
so step 4 runs once per open (history commit `a6bf729`,
`bench/2026-11-26-file-call-path/hack-a/`, with the stamps):

| Row (p50) | stamps | stamps and hack A | gain |
| --- | --- | --- | --- |
| `fstat`, 1 CPU | 16.8 us | 10.5 us | 6.3 us, 37 % |
| `fstat`, 4 CPUs | 16.3 us | 10.8 us | 5.5 us, 34 % |
| `read` 4 KiB, 1 CPU | 14.0 us | 9.3 us | 4.7 us, 33 % |
| `read` 4 KiB, 4 CPUs | 14.0 us | 9.5 us | 4.5 us, 32 % |

The gain is a little larger than the leg (the description to handler leg
also halves, 0.73 to 0.40 us), so nothing else waits on the grant.

**B: the return wake.** Not tried as a hack: on one CPU the 3.4 us leg
is the session's own work after the send (the handler's loop, the
scheduler finding no work, `erx_park`) plus one switch and the reply's
decode, and no throwaway change removes it without redesigning who
reads the inbound lane. The one cheap lever, ERTS busy waiting, was
measured on 2026-11-22 (history `bench/2026-11-22-spin/`): with stock
spinning a 4 KiB read was 24.6 us against 13.5 us without, on one CPU,
because a spinning session scheduler keeps the program off its CPU.

## Recommendations, ranked

1. **One grant conversation per file call, and no tree process hop for
   a RAM tree** (expected 4 to 6 us per `fstat`, `read` and `write`, a
   third of each; most of `open`'s 38 us if the open's conversations are
   of the same kind). Step 4 costs two process round trips, two
   monitors with aliases and the 9P grammar checked on both sides of
   the grant, for a tree that answers from memory. Candidates: the
   description keeps what its open learned (the attributes a getattr
   right after the open would fetch), the grant calls a RAM tree's core
   in its own process for reads (the tree's data in an ETS table it
   owns or in `atomics`), and the client-side grammar check is dropped
   where the grant's funnel repeats it. Touches
   [design-files.md](design-files.md#serving-the-erx_fs-behaviour) and
   [design-tmp.md](design-tmp.md).
2. **Count and cut `erx_open_at`'s conversations** (expected up to 30 us
   of `open`'s 50): stamp each grant request an open makes, then resolve
   and open in one request where 9P2000.L allows it (walk and lopen of
   one name). Touches
   [design-programs.md](design-programs.md#descriptors-and-files) and
   [design-files.md](design-files.md).
3. **The handler's two steps** (expected 1 to 2 us per call): the core's
   step costs 1.0 us on the way in and 2.0 us building a getattr's
   reply. Profile `erx_prog_handler_core:step/2` and the reply's grammar
   check for a hot spot before any redesign. Touches
   [design-programs.md](design-programs.md#descriptors-and-files).
4. **The return wake** (expected 1 to 2 us): the reply crosses a park of
   the session, a wake of the program's executor and a umtx wake of the
   requester. A requester that reads its own reply from the lane would
   save the umtx hop (0.5 us) and the executor's switch; it is a change
   to the program layer's threading. Touches
   [design-programs.md](design-programs.md#the-channel).
5. **Under TCG, everything scales alike**: erXos's one-byte pipe round
   trip is 44 times slower under TCG than under HVF and a 4 KiB read 39
   times, so the TCG gap to Genode is the HVF gap magnified, not a
   separate TCG effect of the file path. Not a fix; a reason to compare
   the file path under HVF or on the Pi 4 once Genode has a cell there.

The Raspberry Pi 4 run was not taken in this report.
