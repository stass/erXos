# TODO

* [Low] liberx hosted backend (`liberx/backend/hosted/`): macOS only (`os_sync_wait_on_address`, and the stack switches in `arch/*/switch_stack.S` use Darwin's symbol names); a Linux host skips `test/host/hosted_function_api_test.rb`.

Open work outside the roadmap in [docs/plan.md](docs/plan.md). Each item has
a `[Severity]` tag and a component pointer. When an item is closed, delete
it; git history is the record of completed work.

## Major initiatives

* [High] apps, [design-apps.md](docs/design-apps.md#packaging): design app packaging when Track A starts
  ([plan.md](docs/plan.md#track-a-apps), part 2): how an app reaches a machine after its image is built, as one
  file a person or developer adds, through the seam design-apps.md keeps (the start table keys on a principal with a
  session template and a `start` row, so a package adds those and nothing below changes). Its inputs:
  * an earlier design of **app classes**, cut from design-apps.md as premature, which this design may take up: the
    manifest declares classes (a session template, its principal and the facet rows granted to it); an app joins a
    class with a declaration (`class`, `needs` naming services of the class's rows, an EROFS `image` mounted at
    `/app` by an `erx_app` application of an `app` release, `applications` or `program`, `env`); one pure admission
    function, `erx_app_admit`, written in Erlang for the machine and in Ruby for the packer and tested on one corpus,
    answers the grants as set inclusion, so the build's proof over the classes covers every app and no checker runs on
    the machine; the principal service registers each admitted app with `register_app/1` and `unregister_app/1`;
    a session of an app is a session of its class's template, filtered to the declared grants in the domain service's
    one facet funnel;
  * the **pool**, part of that design: a domain record names the principal it acts for (the app's) and its pool (the
    class's principal), which pays; the domain library and the resource policy read the pool, and every scope by
    principal (mint, inspect scope, storage root, death record) reads the principal. Its review found that the
    inspect scope (design-live.md, "The inspect service") is computed from the grantee template's principal, so
    every app of a class saw the others' domains, and that the domain service added a grant record for every
    template row, not only the declared ones: both must read the app's principal and its declared grants;
  * **per-app identity**: two apps sharing a pool must still see nothing of each other: neither reads the other's
    directory, and neither's `/proc` shows the other's processes; test with two apps of one pool as the two
    principals;
  * **the atom bound**: an app's session name, `<app>_<n>`, is an atom in the system domain; with apps from
    packages, names come from untrusted declarations, so their count needs a bound that survives install and removal
    (a quota on the pool, or names recycled from a fixed set), not only the manifest-summed `names` quotas;
  * an earlier draft of packaging itself, whose external review found HIGH and MEDIUM gaps:
  * a code overlay persisted for an app's principal lets a storage domain that a crafted partition took over run
    unsigned code under the app; overlays of apps stay in memory, or are authenticated;
  * signer continuity: if an app's identity is its name alone, a storage domain can remove every package of signer A
    and put back one of the same name signed by B, which a scan then admits as the same principal with A's data;
    bind persistent identity to name and signer (for example a data directory keyed by both), or keep a record of
    signers where storage cannot rewrite it;
  * removal is several deletions (versions, start row, data directory); a crash between them resurrects an older
    version or leaves half an app; mark the removal durably first, finish it at the next boot, and keep the name
    reserved until every owner of the app's state is done;
  * an install must make the package file's data durable before the rename that publishes it, then sync the
    directories, so a crash never leaves a valid header over an incomplete image;
  * an app needs a grant of its own package to read it; make that grant implicit or required in every declaration,
    and fix the example and the admission tests to match;
  * fuzz the whole verification entry point (locating the header, key and signature in attacker-controlled bytes,
    truncations, bad lengths and bad signatures), not only the header's decoder;
  * a version floor holds only for an ordinary install, not for rollback or a scan's fallback, against a storage
    domain that puts back an older signed package; state it so.
  The decisions on that draft that apply here: `pkg delete` removes an app's data; the administrator
  approves an app's grants by installing it, within what the build proved, with no prompt; no fetch by name (a fetcher
  is a command in a person's session that holds `net` and hands the file to the installer).
* [Medium] runtime, `docs/design-shared-code.md`: build shared loaded code, one prepared copy of the
  preloaded modules and the applications every domain boots, mapped read-only into every domain that runs
  the interpreter. It is wanted long term. Its trigger, three adopting domains at once, is met: the
  development manifest runs root's session and the storage, network and web domains on the interpreter. Each
  domain loads its own `kernel` and `stdlib` at boot, and on one CPU an image that runs everything in the
  system domain still reaches root's shell about 3.2 times sooner under TCG (the measurement and the order
  of work are in [todo-performance.md](docs/todo-performance.md), "every domain loads its own kernel and
  stdlib"; raw logs in ~/erxos-history/boot-slow-2026-11-11 and boot-fast-2026-11-11).
* [Medium] architecture: evaluate the remaining
  [simplification candidates](docs/todo-simplification.md), recording for
  each the mechanism it removes, its cost and the evidence needed to adopt
  it: isolated parsing frontends, causal explanations in the inspector,
  and the open proposal
  on the scheduler's target configuration.
  Scheduled experiments live in the roadmap; these proposals do not
  silently replace established design decisions.
* [Medium] performance: measure the suspected costs on the
  [performance watch list](docs/todo-performance.md), each with the
  workload it names, and remove each item once a recorded number settles
  it: the kernel's portable-code hash of large boot image files at first
  use, the eager FP switch, and Phase 1's one service thread.
* [Medium] benchmarks (`tools/erx bench g3`, [research-g3-baseline.md](docs/research-g3-baseline.md)):
  repeat the G3 run for HVF and TCG on a quiet host, since the first run was
  taken at a load average of 44 to 55, and find why stock OTP on the host
  is slower than the guest at the same four operations under HVF.
* [High] network, the fast path
  ([docs/design-network-fastpath.md](docs/design-network-fastpath.md)): one connection over
  the FreeBSD test host's tap sends at 890 Mbit/s and receives at 1,143, against lwIP's 6,537 and 6,809 on the
  same tap, held there by the connection's per-segment step. The targets are two thirds of
  lwIP's bulk throughput each way over the same medium, and for request-reply a third of
  lwIP's rate at no more than three times its CPU per transaction. Each package lands with
  the FreeBSD bulk and request-reply numbers before and after it, and the HVF numbers when it
  changes erXos's code; the gains are estimates from the profile, to be replaced by those
  numbers:
  1. the benchmarks, `tools/erx bench net-freebsd` (bulk and request-reply on the FreeBSD test host, erx_net and
     lwIP, with its counters' hook: the interface's `runs`, `run_frames`, `units`,
     `unit_segments` and `frames_dropped` totals, reported unsupported until it keeps them)
     are in the tree; what remains is the bulk and request-reply benchmarks under HVF,
     which need a TCP peer on QEMU's medium (the Linux oracle guest is not built yet); no
     gain, it fixes the baseline;
     * [Medium] the bulk and request-reply benchmarks under HVF: no TCP peer on QEMU's
       medium yet (the Linux oracle guest is not built; the harness's virtio-net hub carries
       raw frames to a Ruby harness, and slirp's guest forward carries the `net_device`
       suite's TCP to a Ruby echo server over one host stream, which checks the guest's TCP
       but is no benchmark peer), and `bench/erx_net_bench.erl` has to be loaded into the guest shell as
       `BenchGuest` loads its module. The Linux-guest baseline stays unsupported until then.
     * [Medium] `erx_net_if_core` counters: the map keeps only counters that were
       incremented, so "kept, zero" reads as "unsupported" in `tools/erx bench net-freebsd`.
       The packages that add `runs`, `run_frames`, `units`, `unit_segments` and
       `frames_dropped` must make `admin(counters)` return every counter they keep, zeros
       included; the fast-path check is `--require-fast-path` until then and becomes the
       default (`docs/design-network-fastpath.md`, "Benchmarks and targets") once they exist.
     * [Medium] `net_bench_freebsd.rb`'s remote lock: a stale lock's takeover is check then
       act (two runners can both take it); an interrupted run releases it while its remote
       peer and client live on to their own deadlines; `run_deadline` leaves out the ssh kill
       grace, the conditions' remote calls and erlc and rsync, so a slow live run can be judged
       stale. FreeBSD `lockf(1)` held from one ssh for the whole run would remove all three.
     * [Low] `net_bench_freebsd.rb`: lwIP's source trees on the FreeBSD test host are not hash-checked per run;
       erlc, git and rsync run without a deadline; the peer's start is a fixed wait, not a ready line; the stacks' repeats
       run in blocks, not interleaved; the p99 is the nearest rank plus one in both
       clients; bulk send differs between the clients (nodelay and 64 KiB against Nagle and
       32 KiB), as the report's conditions state.
  2. one step per mailbox and a batch on every hop are in the tree; on the FreeBSD test host (median of 3,
     against the baseline) bulk receive went from 1,160 to 1,850 Mbit/s, while bulk send
     (903 to 900) and request-reply (64 B 15,661 to 15,521 txn/s, 1 KiB 14,574 to 15,132,
     64 B x16 81,376 to 78,159) did not move: the send side waits for the lean step
     (raw data: ~/erxos-history net-bench-freebsd-fast-p2-2026-11-09, commit d5bcd46);
  3. the lean step: `#tcb{}` split from `#tcb_conf{}`, header prediction finishing its two
     cases, the header template, the send log of runs with its extension rule: the
     connection's time per segment from 12.3 us to 3 to 4 us, and throughput about 1.3 to
     1.5 times until the driver binds;
     * the send log of runs and header prediction's finished cases are in the tree, and
       `erx_tcp_wire:add_options/1` writes a run's two option layouts (none, `NOP NOP TS`)
       directly instead of through `tcp_addoptions`' fold, which output, the frame layer and
       `encode/3` each ran for every segment. The `#tcb{}`/`#tcb_conf{}` split remains, and
       so does the header template itself, the IP and TCP headers with their options encoded
       once per connection: its full gain comes with the runs and the cut, when the frame
       layer writes no header bytes per run. Before them it would save per segment only the
       IP header's build (`erx_net_frame:output/6`'s map, `erx_ip4:output/4`'s checks and
       encoding) and the pseudo-header sum, which no measurement backs yet; measure a hack
       that skips them for a don't-fragment segment that fits the MTU before building the
       template ahead of the cut.
     * [Medium] `erx_tcp_input_ack_tests` (header prediction's property): its generator
       never sends in-order data larger than the receive space, so a header prediction
       that takes such data is not caught there; the precondition's seeded fault is the
       closed owner instead. Add data sizes past `rcv_space` to the generator.
  4. the tap transport, `erx_tap` and its NIF, replacing `erx_net_tap` and the pipe's
     `port` end, landed (against package 2's tree, the FreeBSD test host, median of 3): bulk send 900 to
     1,040 Mbit/s, bulk recv 1,850 to 1,837, rr 64 B 15,521 to 16,150 txn/s, 1 KiB 15,132
     to 17,596, 64 B x16 78,159 to 89,986. Its one-call receive batches exposed a stall in
     `erx_tcp:settle/3` (a waiting writer moved in after output), fixed with it (raw data:
     ~/erxos-history net-bench-freebsd-fast-p4-fix-2026-11-09, commit d5bcd46);
  5. checksums in the copy
     ([design-network-stack.md](docs/design-network-stack.md#checksums-in-the-copy)), built as part of the fast path, since the cut and the merge rest
     on it. The receive half is in the tree: `erx_inet_copy_sum` in `erx_inet_csum.c`, whose
     two-words-a-step loop `erx_inet_sum` shares and whose loads an empty assembly statement
     keeps single, with its harness cases, mutants and the `inet_csum` fuzz target's copy
     case; `erx_net_sum`; the sum argument of the decoders above IP; `erx_net_input`'s `{frame, Bytes, Sum}`, checked
     against the unsummed path by its EUnit cases and its fuzz target; and the tap NIF's
     `{sum, S, Frame}`. On the FreeBSD test host (median of 5, min-max) the receive half first
     cost bulk receive 1,907 (1,876-1,973) to 1,837 (1,823-1,877) Mbit/s; with the wide loop
     and the IPv4 header not read again it is 1,936 (1,926-1,968), bulk send 1,164 to 1,150
     and rr 64 B 16,927 to 17,110 txn/s, within their spreads (raw data:
     ~/erxos-history net-bench-freebsd-fast-p5b-2026-11-10, commit ea64849). The send half
     is in the tree for the tap: `erx_tcp_wire:encode/4`; `erx_net_frame`'s
     `{csum, Start, Field, Packet}`, with `finish/1` and `finishable/2`, the loopback's
     packets finished by `link/3`; `link_info`'s `finish`, written into the interface row;
     the tap NIF finishing a delayed frame in its `writev`; and the pipe's `process` end in
     its offload mode, which finishes with `finish/1` and hands frames up with their sum.
     On the FreeBSD test host (median of 5, min-max, against master the same hour) bulk send
     went from 1,151 (1,138-1,182) to 1,163 (1,146-1,206) Mbit/s, bulk receive 1,913 to 1,926
     and rr 64 B 16,619 to 16,941 txn/s, all within their spreads, where a hack that summed
     each sent segment twice had cost 2 to 4 percent (raw data: ~/erxos-history
     net-bench-freebsd-fast-p5c-2026-11-10). What remains is the other media:
     `erx_device:complete/3` and `post_frame/5`'s delayed frames, and `erx_virtio_net` on them with its start line
     naming the finisher; until then it declares `finish` `none` and drops a delayed frame.
     The netmap NIF takes the same core when it is built;
     * [Medium] `erx_net_input_fuzz`: its frames carry no Ethernet padding and its UDP lengths
       always fill the IP payload, so `erx_net_sum:span/4`'s bytes after the packet and
       `erx_udp_wire`'s datagram sum are checked only by EUnit cases
       (`erx_net_input_tests`' network sum cases and their seeds); pad some frames and cut some
       datagrams short, with the judge tolerating both.
     * [Low] `erx_net_input`: the loopback input `{frame, Zone, Bytes}` shares its tag and size
       with `{frame, Bytes, Sum}`, told apart only by the view's link, and `erx_net_if`'s
       `frame_input/1` does not map the driver's `{Zone, Bytes}` frame; give the loopback
       input its own tag when the loop transport is built.
  6. runs on send, toward 4.4 Gbit/s. Output's run rule is in the tree: `erx_tcp_output`
     sends whole segments of new data as one run in one pass, an outgoing segment with
     `seg`, and `erx_tcp_output:segments/1` cuts it into the segments per-segment output
     sends, which `erx_net_frame:tcp/3` encodes one by one; `output/3` with runs off is
     the oracle of the differential case and its seeded faults. On the FreeBSD test host (median of 5, min-max, against master the same hour) bulk send went from 1,141 (1,138-1,163) to 1,225 (1,216-1,238) Mbit/s, bulk receive 1,914 to 1,913, rr 64 B 16,596 (15,999-17,719) to 15,905 (15,779-16,266) txn/s and 64 B x16 90,075 to 89,739, within their spreads (raw data: ~/erxos-history net-bench-freebsd-fast-p6-2026-11-10, commit 87ecd53). The frame layer's runs are in the tree too: `erx_net_frame`'s `#run{}`
     over the template `template/2` builds and the connection caches (`tcp/4`), `cut/1` as
     the Erlang reference, judged against the run's segments encoded one by one,
     `run_tail/2`, the credits counting a run's frames (`frames/1`, `units/1`), and the
     driver's partial take `{ok, N}`. On the FreeBSD test host (median of 5, min-max,
     two rounds interleaved with master) the frame layer's runs took bulk send from 1,233
     (1,218-1,247) and 1,246 (1,239-1,264) to 1,434 (1,428-1,531) and 1,431 (1,421-1,476)
     Mbit/s, bulk receive and both request-reply workloads within their spreads (raw data:
     ~/erxos-history net-bench-freebsd-fast-p6b-2026-11-10, commit f706d25). The cut in C
     is in the tree too: `c_src/erx_tcp_cut.c` with its `tcp_cut` fuzz target, and the tap
     NIF's `send/2` cutting a run straight into one `writev` a frame, judged against
     `cut/1`. On the same host (median of 5, min-max, two rounds interleaved with master
     65589436) it took bulk send from 1,979 (1,931-2,287) and 1,982 (1,955-2,003) to 2,485
     (2,456-2,498) and 2,461 (2,376-2,521) Mbit/s; bulk receive (medians 3,558 to 3,647
     Mbit/s in all four rounds), rr 64 B (14,894 to 15,094 txn/s) and 64 B x16 (86,775 to
     87,474) stayed within their spreads (raw data: ~/erxos-history
     net-bench-freebsd-fast-p6c-2026-11-10, commit 83f7a0a). What remains:
     * [Low] the 64-binary run bound is two hand-kept constants, `RUN_PIECES` in
       `erx_net_frame.hrl` and `ERX_TCP_CUT_PIECES_MAX` in `erx_tcp_cut.h`; make it one
       fact (the NIF reports it at load), and fold output's `run` and `frames` fields into
       one `frames :: none | pos_integer()`;
     * [Low] the `tcp_cut` fuzz oracle checks each checksum by the frame's whole sum, so a
       field written as 0x0000 where 0xffff belongs passes it (the tap's byte-for-byte
       test against `cut/1` catches it); and the cut's seeded faults are listed twice, in
       `test/host/erx_tap_test.rb` and `erx_net_bytes_test.rb`;
     * `erx_device:post_frame/5` in the erXos device NIF and `erx_virtio_net` on it,
       with package 5's `erx_device:complete/3` and its delayed frames;
     * the interface's `runs` and `run_frames` counters, and design test 2's remaining
       parts: the property over event sequences with IPv6 and window scaling among its
       states (the single-pass differential has neither), the explorer's runs, and the
       seed that starts a run's RTT probe at its last frame;
     * [Low] condition 5 refuses a run while ECE is owed, though every frame would carry
       it and the ECN state would not change, so a congestion episode sends per segment;
  7. the merge on receive: receive toward 4.4 Gbit/s, and a sender's ACKs cut by the merged
     units' length. `erx_bytes:tcp_merge/1` with `tcp_merge_limit/0` is in the tree
     (`c_src/erx_tcp_merge.c`, the portable NIF and erXos's BIF, judged against
     `erx_tcp_merge_model` by the network primitives' probe and EUnit cases, with its
     `tcp_merge` fuzz target), and so is the driver's cut of every batch to that limit. So is
     TCP's side: `erx_tcp:merged/3` makes a unit's one segment, whose payload
     (`erx_tcp_payload`) stays in pieces through trimming, reassembly and the receive queue,
     each piece held, costed and copied out on its own, with its count handed to
     `cc_ack_received`; `erx_tcp_merged_tests` checks it against per-segment input (the
     design's test 5) and the TCP explorer's `merged` dimension in every state. What remains
     is the interface: merging each batch before it classifies (the loopback input left out),
     classifying a unit by its first frame, verifying its first and last, checking that the
     last names the first's flow and that `length(Payload) =< N =< 256`, and handing on the
     segment `erx_tcp:merged/3` makes; credit by segments; and the copy check, with the tests
     7, 8 and 12 of the fast path's design, the `net_device` bursts and the input fuzz target
     reaching merged units;
  6. runs on send: output's run rule, `erx_tcp_cut.c`, `erx_device:post_frame/5`, runs in
     the tap and netmap NIFs, and `erx_net_frame:cut/1` as the reference: send toward
     4.4 Gbit/s;
  7. the merge on receive is in the tree: the interface merges each batch
     (`erx_bytes:tcp_merge/1`), classifies a unit by its first frame, charges its N segments to
     the connection's credit, verifies its first and last frames and hands on the segment
     `erx_tcp:merged/3` makes; bulk receive on the FreeBSD test host went from 1,883 to 3,605
     Mbit/s (33 segments per unit) and bulk send from 1,148 to 1,438 (the peer's ACKs, 11 per
     unit). What remains of it: the design's test 11 (packet scripts through the pipe's
     offload mode, the merge's visible behaviour against FreeBSD); a unit no connection owns
     is taken as its last frame, which answers a closed port as FreeBSD does but would hand a
     listener the last frame's sequence number where FreeBSD's syncache takes the first's
     (latent while the core counts a listener's segment as unsupported: hand the listener
     the merged segment once the syncache joins the step); the credit a merged item takes
     back is read in two places (`erx_net_input:units/1`, `erx_tcp_conn:units/1`), which
     `{items, If, Items, Units}` would make one; a unit that finds less than N units of room
     is dropped whole where unmerged frames would deliver the first R, a cliff to measure
     under load; drop counters count a unit once, not its N frames; and request-reply with
     16 connections lost about 2% (89,306 to 87,513 transactions in 10 s), to profile;
  8. netmap with runs and merged batches, over VALE against lwIP over VALE;
  9. request-reply: the driver-to-interface hop and scheduler placement measured, and what
     their profiles name changed, toward the request-reply target;
  10. device finishing, on `VIRTIO_NET_F_CSUM` with `HOST_TSO4` and `HOST_TSO6` together, an
     extension, once a harness medium offers the three bits.
  Packages 6 and 7 build on the designs of the netmap transport and the socket process, whose
  push carries `{data, [binary()]}`, at most 64 binaries and one piece in all. Package 4 also
  ends the tap helper's items under Bugs by subsystem.

## Stopgap replacements

* [High] kernel: replace the stopgap Fiasco with erXos's own C17 kernel
  once it boots Phase 1's system and passes the conformance suite, at milestone
  M7 (gate GK3), before the security closure of M11
  ([plan.md](docs/plan.md)). Every stopgap build carries GPL-2.0 code,
  Fiasco's `kobject_rpc.h`, without which the kernel does not build, and
  the kernel debugger's `jdb_object.cpp`, so any distribution outside the
  project, in source or binary form, waits for this replacement
  ([design.md](docs/design.md#dependencies)). The import also records
  the link closure of L4Re's `bootstrap` and `sigma0`, their `drivers-frst`
  UART support, and the licence of each library in it.
* [Medium] kernel, Track K, shelved Phase 1 work: three pieces of code
  written for the earlier plan, which put erXos's kernel semantics inside
  the Fiasco fork, stay on branch `shelved-phase2-cores` for Track K: the capability
  binding into Fiasco with the first capability calls (12a, commit
  `e2492a64`), the entry classification core (R-a, commit `e90fe78b`) and
  the quota pool's pure core (WP58, commit `c38b3ada`). Phase 1 on a
  near-stock Fiasco does not use them. Track K reviews each against
  erXos's kernel's design and lands what it keeps.
* [Medium] storage: replace littlefs, which runs as a sub-space port of
  the storage domains of the data partition and of the vault's partition,
  with erXos's F2FS, written in Erlang, at parity over the file-semantics
  corpus, by gate G13. Nothing written under littlefs is converted: erXos's
  F2FS arrives by an installation, which creates both partitions afresh,
  and an update whose storage formats differ from the running system's is
  refused ([design-storage.md](docs/design-storage.md#system-updates),
  [plan.md](docs/plan.md)).
* [Medium] kernel, performance counters on the stopgap: the modified
  Fiasco builds with `CONFIG_PERF_CNT_USER=y`
  (`config/fiasco/kernel.defconfig`), so user mode reads the CPU's
  performance counters directly, and they count every thread and kernel
  mode too: one domain can observe another's activity. erXos's kernel
  leaves user-mode counters disabled
  ([design-kernel.md](docs/design-kernel.md#security)). The stopgap keeps
  them for profiling while development builds run trusted code only; they
  go with the stopgap at M7, or earlier once the profiling feature under
  Planned features gives a confined way to count.

* [Medium] kernel, Track K, the slot list's insert
  (`kernel/core/attach.c`, `kernel/core/cap.c`): `erx_attach_object_slots`
  writes only the list's head and leaves the slot's links to
  `cap_list_insert`, and its state check stands behind
  `erx_object_cap_add`'s under the same lock, so removing it alone changes
  nothing a test sees. No rule limits who calls it, and a caller that drops
  the old head loses the rest of the list. Either move the whole link into
  attach.c behind a capability-core helper only it calls, or call the count
  the field's gate and keep attach.c's check as an assertion; then add a
  caller rule on the insert (the Callers kind accepts only exported
  callers, and `cap_list_insert` is static).

* [Medium] verification, Track K, the CBMC gate (`tools/lib/erx/cbmc.rb`,
  `test/cbmc/roster.json`): if CBMC is adopted from the pilot's
  record, settle three things the pilot leaves open. Homebrew offers only
  the latest cbmc, so the pinned version cannot be installed on a fresh
  host once the formula moves on: fetch a pinned release or source by
  hash, as the TLA+ jar is, or document an upgrade step. The report does
  not record the host preprocessor CBMC runs (clang `-E`), which shapes
  what is checked. The runner merges CBMC's standard error into the log
  it parses, so a stray line that looks like a result makes the run a
  tool error rather than a reported warning. The record
  ([research-cbmc-pilot.md](docs/research-cbmc-pilot.md)) recommends
  keeping the seven single-decision harnesses in the gate and moving
  `page_funnel` and `cap_slot_list` out of it: they take about 2 h 27 min
  of the gate's 2 h 33 min and check what the fuzz targets already check.
  Until that is decided, the gate runs all nine. `cap_slot_list`
  checks a table whose page is cut to 4 slots, which its header argues
  checks what the ABI's 64-slot page would; on the Intel second
  development host with cbmc 6.11.0 it verifies in 214 s and its three
  mutants are caught in 219 s, 316 s and 290 s, where on the full page
  the harness and two mutants passed the 3,600 s deadline.

* [High] kernel, Track K, the one route from user mode: in erXos's kernel
  only the trap immediate of `abi/arch/<arch>.txt` reaches `erx_dispatch`,
  and the exception vectors and the synchronous entry from user mode are
  the kernel's own: `erx_user_sync_entry` over `erx_fault_classify` and
  `erx_entry_step` (`docs/design-kernel.md`), with a build check that no
  other route into the kernel exists (the pending `vector-route` rule).
  Phase 1 uses Fiasco's own routes and has none of this.
* [Medium] stopgap, untested glue paths: `erx_log_lock` has never run under
  contention, since the probe has one thread and no call makes another, and
  nothing exercises the alien and vCPU-user guard in `Thread::arm_esr_entry`.
* [Medium] stopgap, `erx_debug_log` on the target: until the root service
  lands, `liberx/backend/fiasco/log.c` runs the kernel's dispatch core in the
  root task with one static public UTCB, a hand-written copy of the generated
  stub, and `liberx/backend/fiasco/arch/aarch64/generated/trap.c` and `utcb.c`
  have no consumer; the service's request stub replaces them. The probe's
  calls run the same core in process on both backends, so its transcript shows
  the console path, the clock and the cross-compiled core, not a kernel entry.
  The test that a call keeps the caller's registers left with the trap route
  and returns with the `erx` backend's kernel.
* [Low] stopgap, `liberx/backend/fiasco`: own-task thread handles are still the bare index, not `ERX_FIASCO_THREAD_HANDLE_BASE` plus the index that design-stopgap.md's "Thread handles" names, so thread 0's handle equals `ERX_CAP_NULL` and `erx_gate_bind` reaches thread 0 only through `ERX_CAP_SELF_THREAD`. Move handles onto the base. Likewise the handle the root or a creator holds to a created space's first thread is the task above the index (`service_thread_handle` in `service.c`), not the handle-table entry "Thread creation" names, so it can equal one of the root's entries once the root holds 256 of them, and `erx_cap_close` or `erx_cap_dup` of it reaches that entry; give it a value no entry can bear, as the base does.
* [Low] stopgap, `liberx/backend/fiasco`: own-task thread handles are still the bare index, not `ERX_FIASCO_THREAD_HANDLE_BASE` plus the index that design-stopgap.md's "Thread handles" names, so thread 0's handle equals `ERX_CAP_NULL` and `erx_gate_bind` reaches thread 0 only through `ERX_CAP_SELF_THREAD`, and an `erx_cap_pass` item holding an own thread's handle is read as the handle table's entry of that number, so it may pass a memory object instead of being refused. Move handles onto the base.
* [Medium] stopgap, `liberx/backend/fiasco/vm.c`: the page index's size counts the window, contiguous and device pages but not the archive pages a slice adds, one index entry each per live slice, so enough live slices fill the index and `page_find` spins on the service thread. One slice per domain cannot reach it; before a session slices per command, count live slice pages against a cap and refuse past it with `ERX_ENOMEM`, as `vm_device_pages_used` does, and correct `vm_table.h`'s "committing never finds it full".
* [Low] stopgap, `liberx/backend/fiasco/service_wire.c`: the decoder copies a call's words into `decoded.request` without checking them against `ERX_FIASCO_WIRE_WORDS_MAX`; `erx_fiasco_mem_copy_request` fills all seven, so a longer layout would overflow it. Refuse past the maximum in the decoder, or assert every layout's size.
* [Low] stopgap, `fiasco/kernel/src/erx/erx_probe.cpp` and `erx_syscall.cpp`
  are reference text for erXos's kernel, out of the build: `erx_syscall.cpp`
  names `Space::erx_log`, which is gone, so it no longer compiles.
  `tools/lib/erx/glue_imports.rb`'s `OUT_OF_BUILD` repeats
  `Modules.generic` by hand.
* [Medium] stopgap, native boot's seeded failures: `user_ptr` left 0, the
  archive's sub-type removed and shutdown removed were each run by hand and
  failed as [the verification table](docs/design-stopgap.md#verification) says;
  nothing in the tree repeats them, as `check-qemu-mutant` does for the debug
  log, and nothing shows that a write to the archive faults. The same holds
  for the crash frame's write removed. `make check-native-seeds` keeps the threads
  and watchdog suites' seeds.
* [Low] stopgap, the crash suite's end-path row: `erx_machine_end` runs only with
  `ERX_END_OFF`; under `-no-reboot` both ends exit QEMU, so the suite cannot tell
  them apart, and the refusal of a bad `how` has no case.
* [Low] tooling, `tools/lib/erx/native_crash.rb`: the pc check asks only that the pc is at or
  above RAM's start, with no upper bound and nothing tying it to the crash root's image,
  whose range the guest could print beside its address; and `test/guest/native_threads`'s `QUEUE_SETTLE_NS` trusts a 50 ms sleep to order
  waiters, which a starved vCPU can break.
* [Low] stopgap, `liberx/backend/fiasco/service.c`, `erx_object_info`'s cpu topic: no CPU reports `idle_time`.
  Fiasco has `l4_scheduler_idle_time`, but erXos's Fiasco is built with `CONFIG_PERIODIC` and without
  `FINE_GRAINED_CPUTIME`, so each 1 ms tick is charged to the thread it interrupts and a short run between ticks
  counts as idle: the count bounds the idle time neither from below nor from above, and reporting it would give a
  wrong answer as a right one. The inspector shows the field `unsupported`. erXos's kernel, which accounts time at
  each switch, reports it.
* [Low] stopgap, Fiasco's `Ipc_gate_obj::unblock_all`, `fiasco/kernel/src/kern/ipc_gate.cpp:142-166`: the gate dequeues
  a blocked sender and activates it afterwards, the race `Semaphore` closes with `Thread_sem_woken`, so a timed send can
  return first and the activation land in what the thread blocks in next. The root's one gate is created bound
  (`service.c:161`), and a sender blocks only on an unbound gate, so nothing in `liberx` reaches it. Other runtimes unchecked.
* [Medium] BeamAsm, `test/guest/native_domain/jit_reload.erl`: the reload case shows no stale version on four CPUs,
  but nothing confirms that a load reused freed code memory, and no seeded fault (the code barrier's instruction
  barrier removed) has been shown to fail it. Record the probe's code address per load through a test hook, count
  the reusing rounds, and plant the fault.
* [Medium] BeamAsm, `beam/jit/asm_load.c` and `beam/beam_load.c`: the failure paths of edit 24 have no test: an
  encoding error's `badfile`, an exhausted code space's `{error, system_limit}`. Add a test hook that fails the next
  codegen each way and check `erlang:load_module/2`'s answer. `BeamModuleAssembler::codegen(char *, size_t)` (NIF
  stubs) still ignores flatten and fixup errors; route the three codegen variants through one checked helper and
  mark the result `[[nodiscard]]`. The design's inspector counter for an exhausted code space does not exist.
* [Low] BeamAsm, `sys/erxos/erx_jit_memory.c` (`erx_jit_memory_unmap`, `erx_jit_memory_map`): an unmap whose second
  release fails has already removed the first alias, against its header's "a refused call changes nothing", and a
  failed handle close after both maps loses the handle; the alias probe hand-encodes its return instruction.
* [Medium] stopgap, `liberx/backend/fiasco`, call table of `docs/design-stopgap.md`: `erx_cap_dup`, `erx_cap_close`,
  `erx_object_destroy`, `erx_budget_create` and `erx_log_read` have no body. Their consumers are the Erlang NIF handles, the launcher, the domain library's root
  entry and the Erlang log reader, which arrive with M3; each gets its body and a `test/guest/function_api` row then.
  The pool counts pages for the root's one budget only, which the budget topic names `ERX_CAP_SELF`; a count for
  each budget follows `erx_budget_create`'s body.
* [Low] stopgap, `test/guest/native_task/guest.c`, `request_against_exit`: no seed shows the dropped-request
  count can move, as the thread deletion seed stops the suite at its earlier `service` case.
* [Low] stopgap, `liberx/backend/fiasco`, fault gates: each space's `dropped` counter of records lost after its gate was
  destroyed has no reader until the inspector reads it at SV4.
* [Low] stopgap, `liberx/backend/fiasco/service.c` (`service_main`), fault gates: a fault posted to a space's
  gate is left unanswered in the service thread's one implicit reply capability, as `docs/design-stopgap.md`
  ("Faults") asks, so the service's next receive of a call overwrites it and Fiasco logs
  `Application bug: reply capability overwritten!` (`fiasco/kernel/src/kern/receiver.cpp`, `set_reply_cap`) at
  every fault posted to a gate: each end of the storage domain on a dead disk, the native_domain suite's fault
  cases. Nothing misbehaves: Fiasco empties the slot, and the faulting thread stays blocked until its space's
  stop deletes it, as designed. To silence it, receive into Fiasco's explicit reply capabilities
  (`l4_ipc_wait_ext`, `CONFIG_EXPLICIT_REPLY_CAPS`), keep the slot of each fault posted to a gate with its task,
  receive on into a free slot, and free the kept slots once the task's teardown has deleted its threads, whose
  cancelled calls empty them. A gateless fault or a thread that stops its own task (`ERX_FIASCO_NO_REPLY`) warns
  the same way when the killed thread has not yet emptied its slot by the service's next receive.
* [Low] stopgap, `tools/lib/erx/native_semaphore_race.rb`: the race runs under TCG at 4 CPUs only, as every
  seed under `make check-native-seeds` does, and no gate runs it under HVF.
* [Medium] stopgap, `test/fixtures/fiasco_park_driver.c`: the exhaustive model reads the core rather than
  the status mirror, so `parked` not mirrored and a slot epoch mirrored relaxed pass every mode. It has one waker in flight, and judges a lost wake only with
  no event or timeout left, so a stuck absorb with no work passes. A two-waker variant and a check of every
  quiet state passed the core by hand (623,596 and 287,527 states) and should replace them.
* [Low] stopgap, `test/guest/native_threads/guest.c` and `test/guest/function_api/cases.c`,
  `park_timeout_races_wake`: between its racing parks and its quiet ones the helper waits through `settle`,
  a umtx wait on the semaphore the park shares, so an up the race left over returns that wait early and is
  gone before the quiet park looks. The quiet park catches only an up arriving after `settle`; a wait that
  does not block on the semaphore, or a zero-deadline down right after the race, would catch both.
* [Medium] stopgap, `liberx/backend/fiasco/object.c`: a space handle is still the task's index, which the
  launcher turns into the ended semaphore's slot without the service (`launcher.c`). It moves onto records with
  BK5's space tree (the 1b-A package plan). Until then its value overlaps object handles, so `erx_cap_close` or
  `erx_object_destroy` given a space handle acts on whatever entry has that number.
* [Medium] security residual, `liberx/backend/fiasco/vm.c`: nothing records `ERX_MEM_JIT` on an object, so any
  object maps read-write at one address and read-execute at another, a protect moves RW to RX freely, and the
  root maps RX into a child made without `ERX_SPACE_JIT`. No single mapping is ever writable and executable,
  but code-making does not yet follow from the image.
* [Low] stopgap, `musl/src/internal/erxos/syscall.c`: `munmap` of part of an object's mapping is `EINVAL` and
  `mprotect` over one `ENOTSUP`, where FreeBSD does both; nothing reaches it until musl maps objects.
* [Medium] stopgap, `liberx/backend/fiasco/service_task.c` (`erx_fiasco_task_mem_dma_body`) and the contiguous
  object of `vm.c`: the object does not record `bus - cpu`, so `erx_mem_dma_addr` gives a device the CPU address
  of its memory, where [design-device-tree.md](docs/design-device-tree.md) ("The `given` record") and
  [design-device-dma.md](docs/design-device-dma.md) ("Device addresses and reach") have it give the bus address.
  Until it does, `erx_boot_dma_absent` (`liberx/backend/core/boot_manifest.c`) refuses a device whose DMA range has
  bus addresses unlike its CPU addresses, with the reason `offset`, and the device gets no DMA memory: the Raspberry
  Pi 4's EMMC2 (unit `sd`, config/platforms/raspi4b.json), whose bus addresses start at 0xc0000000, gets none of
  its 1 MiB and moves blocks by programmed I/O. Record
  the offset in the object the root makes from the tree's range, and drop `offset`.
* [Low] stopgap, `liberx/backend/fiasco/runtime_entry.c` (`tree_facts`): the root accepts the firmware's tree
  and joins its facts to the catalogue's entries once, before any give, but after step 8 of
  [Boot handoff](docs/design-stopgap.md#boot-handoff) rather than in step 4, because the catalogue is the domain
  library's view, which the program's start builds (`library_view`) and the root without a program
  (`root_no_program.c`, which shares `root.c`) never builds. Accepting in step 4 alone would only move a refused
  tree's stop earlier. Build the library's view in step 4, in `root_boot`, and accept the tree there with it.
* [Low] stopgap, `liberx/system/dom_apply.c` (`apply_give_step`): `erx_mem_create_contiguous_in` places a
  device's run only inside its DMA range, and a holder's give whose range does not cover the pool (`ERX_ERANGE`)
  fails, so the holder's domain is refused, where the root's own give (`device_memory` in
  `liberx/backend/fiasco/runtime_entry.c`) gives the device no memory with the reason `outside` and
  [design-device-tree.md](docs/design-device-tree.md) ("The `given` record") has the driver move blocks by
  programmed I/O. It fails safe, and does not happen on a supported board: the pool is the lowest RAM `sigma0`
  has free, inside every range the manifests' trees give. An object the check after creation still refuses
  stays unused for the boot's life, in the root's table or, unnamed by its record, in the holder's.
* [Medium] stopgap, `liberx/system/dom_apply.c` (`apply_memory_inside`, `apply_given_words`): a holder's
  memory refused after it is made (`outside`) prints no line, while `tree_facts` already printed the row's
  range, and a refused `erx_mem_dma_addr` reads as no memory rather than as the backend error the root's own
  give stops on; [design-device-tree.md](docs/design-device-tree.md) ("Concurrency and failure") wants one
  line naming the device and the reason. The holder's record is also assembled beside
  `erx_boot_device_given`, not by one pure function both gives call: move the record decision (facts, the
  memory's device address, the row) into one function in `liberx/backend/core/boot_manifest.c` with host
  tests for `outside`, MAC and COHERENT, and let the library report its refusal through it.
* [Low] stopgap, `liberx/backend/fiasco/vm.c`: a physical object's device window pages and a contiguous object's
  run are never given back, so a driver that makes and closes such objects in a loop uses the window or the
  contiguous pool up for good; each object, not each task, now holds them.
* [Medium] stopgap, `liberx/backend/fiasco/vm.c`: the page index's label map (`vm_label_take`, `vm_label_put`, and
  their use in `erx_fiasco_vm_task_open`, `_close` and `object_fill`) has no test, as `vm.c` builds only for the target and
  no suite makes more than a few tasks. A leaked or doubled label gives two tables one key. A host test should exhaust the
  4,096 labels and see the refusal, check a failed fill and a task's close return every label, and reopen a task index
  after its join; BK2's object records, which take over object labels, are the natural place for it.
* [Low] stopgap, `liberx/backend/fiasco/vm.c`, `erx_fiasco_vm_contiguous_create`: a run taken by `erx_fiasco_contig_take`
  is not given back when `object_fill` then refuses (no label left, or no pool page for the object's runs), so a
  refused create leaves the run held. The pool is sized to the devices' declared total, so a held run leaves that
  device's later give `ERX_ENOMEM` for the rest of the boot. No device learned the run's address, so clearing its
  bits on the failure path is safe.
* [Medium] erXos's kernel, [design-kernel.md](docs/design-kernel.md) (memory objects, "contiguous"): creation zeroes up to
  16 MiB in one kernel call, and the design leaves how that meets the bounded-path rule to the performance watch list.
  Decide it in the design: zero the `erx.dma_pool` once at boot and each range as it returns to the pool, or zero in
  preemptible steps, and keep only the measurement in `docs/todo-performance.md`.
* [Low] stopgap, `liberx/backend/fiasco/irq.c`: an IRQ object is unbound by a holder allowed in its group (the group's home, its creator or the root: `irq_group_allowed`) and freed with its last handle. Whether a restarted block driver can rebind its line through that is untested.
* [Low] stopgap, `liberx/backend/fiasco/entropy.c`: the generator starts from the counter alone, not yet the manifest's seed,
  though the root reads the manifest before it seeds the generator.
* [Medium] stopgap, `liberx/backend/fiasco/vm.c`, `liberx/backend/core/vm_table.c`: the range table sees an object's mapping as uncommitted, so
  `erx_space_protect` over mapped registers or a mapped run returns `ERX_OK` and puts a fresh pool page there, and a decommit or release leaves the
  mapping reachable. No caller does either. Nothing tests a task that ends holding a physical or contiguous object, so `vm_give`'s address check and
  the index's room for run pages stay untested. A restarted driver spends device window pages and contiguous runs each life, since neither comes back.
* [Low] stopgap, `liberx/backend/hosted/vm.c`: `erx_mem_create` and `erx_vm_map` have no hosted body, which the call table's row asks for, so
  `test/guest/function_api` holds no shared object's case and its device cases stay native alone.
* [Low] `otp/erts/emulator/beam/erl_process.c`: the safe point of `docs/design-runtime.md`, "Scheduling", handles the ready list only: its
  capacity and urgency steps land with the adapter that publishes them.
* [Medium] `otp/erts/emulator/beam/erl_crash_dump.c`, `beam/bif.c`, `sys/erxos/sys.c`: what `imports.txt` lists as `[stock_descriptors]`
  and the rest of `[stock_process]`: the system domain's crash dump file, which `open` refuses with `ENOSYS` (another domain's dump goes to its crash area),
  `erlang:display` and `halt`'s output, the terminal's `sys_get_key` and `ethread`'s signal masks. Each is answered as `ENOSYS` tracing shows it.
* [Medium] `otp/erts/emulator/sys/erxos/sys.c`, `beam/erl_crash_dump.c`, `beam/bif.c`: what `imports.txt` lists as
  `[stock_process]` and `[stock_descriptors]`, the UNIX process ERTS still assumes: the signal dispatcher, `sigaction` and the pipes of
  Darwin's main thread, `nice`, `alarm`, `uname` and the crash dump's descriptors (edit 34). The first native boot answers each,
  as `ENOSYS` tracing shows it;
* [Low] `test/fixtures/runtime_event_harness.c`: the sleep step's model copies the park core by hand and has no waker; driving
  `erx_backend_park_step` and a waker would pin the reason the epochs come before the flag.
* [Low] `erlang/apps/erx_net_client/src/erx_gen_tcp.erl`: `listen/2` answers `{error, enotsup}`, where
  `docs/design-runtime.md` says `{error, eacces}` without a grant. The answer changes when the network service offers
  listening sockets and checks the grant.
* [Low] `otp/erts/emulator/test/binary_SUITE.erl`: `make_port/0` is `hd(erlang:ports())`, and `ports()` is empty by design,
  so its term-ordering cases fail with `hd([])`. Opening `{spawn_driver, "ram_file_drv"}` there gives a real port (checked on
  hosted), and is the route when the suite is next run for its results.
* [Low] `otp/erts/emulator/test/process_SUITE.erl`: `max_heap_size_test/5` fails with `{badmatch, noproc}` under a runner
  with no common_test, because `ct:log` delays its monitor past the process's death. It needs a run under `ct_run` to tell
  whether this is the runner alone.
* [Medium] `tools/lib/erx/oracle_suites.rb`: the oracle runs each group's checked-in `*_SUITE.erl` only, on both
  sides. OTP's compiler test Makefile (`release_tests_spec`) also generates about a dozen variant families from them
  (`_no_opt`, `_post_opt`, `_inline`, `_r26`, `_no_ssa_opt`, `_no_type_opt`, `_cover`, `_dialyzer` and others), the
  `lfe_*_SUITE`s from `.core` files and `property_test/`, compiled with `+clint +clint0 +ssalint`; stdlib's installs
  `PropList.txt` and `DerivedCoreProperties.txt` into `unicode_SUITE_data`, `otp_version_tickets` into
  `stdlib_SUITE_data` and two doctest guides. A code generation bug that shows only under `no_opt` or `r26` passes
  the oracle. Building each group's suite directory from its own `release_tests_spec` would run the group as stock
  defines it, and replace `RELEASED_HEADERS`.
* [Medium] `tools/lib/erx/oracle_hosted.rb`: map_SUITE `t_tracing` fails on the hosted runtime
  with `dbg` undefined, although the oracle's hosted tree carries `runtime_tools`. The system domain under QEMU
  passes it, so `emulator.txt`, which the QEMU run holds to no stale row, has none for it. Trace why `dbg` is not
  found on the hosted runtime and fix it.
* [Medium] `test/oracle/hosted_known_differences/stdlib.txt`: stdlib differences not yet traced to a cause, each a row
  citing this item: edlin_expand_SUITE `filename_completion`, `function_parameter_completion`;
  escript_SUITE `archive_script`, `archive_script_file_access` (compilation
  error); filename_SUITE `absname`, `absname_bin` (`enoent`),
  `t_basedir_xdg` (`HOME` is unset on the erXos side); qlc_SUITE `evaluator`; shell_SUITE `otp_5435`, `records`;
  stdlib_SUITE `app_test`; rand_SUITE `doctests`.
* [Medium] `otp/lib/stdlib/src/shell.erl` (restricted shell): shell_SUITE `start_restricted_from_shell` is a
  known difference because `q()` is a shell-local command (design-shell.md, "Compatibility and migration"), so it
  stops at its local-function list and its later checks never run on erXos: that a restricted shell refuses each
  local function, `shell:stop_restricted/0`, and the cleared `restricted_shell` env. Add an erXos test that runs
  those checks with `q` in the list and pins `q()` in a restricted shell ending that shell unchecked by the
  restricted module.
* [Medium] `otp/erts/preloaded/src/prim_file.erl` (`read/2`) and the file server's read: `file:read(Fd, N)` with an
  absurd N (file_sorter_SUITE `misc` reads a 2^128-1 length field) answers data or `eof` where stock answers `einval` or
  `enomem`, so the case gets `premature_eof` instead of `bad_object`. Read the size path; refuse sizes past the limit
  with `einval`, with a regression test.
* [Low] upstream, `otp/lib/stdlib/test/y2k_SUITE.erl`: `tz_next_date/1` returns its argument when local time equals UTC,
  so seven cases fail wherever the time zone is UTC, as erXos's is; stock passes only off UTC.
* [Medium] `otp/erts/emulator/beam/erl_process.c`: schedulers are not pinned to the group's run, the default stays stock's
  `+sbwt`, and `+S` is not derived from `erx_group_info`'s capacity, which no one configures yet
  (`docs/design-runtime.md`, "Scheduling"). Each waits for a consumer of a capacity word in Phase 2's groups.
* [Low] `erlang/apps/erx_uart/src/erx_pl011.erl`, `wait_idle`: a boot that leaves the UART or its transmitter disabled with bytes in the transmit FIFO keeps `FR.BUSY` set, and the driver exits `pl011_busy` where clearing `FEN` would flush the FIFO (DDI 0183G 3-16); the wait is bounded by a count of reads, not a time.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, `find_open`: a page run (`find_run`), a line entry (`find_line`) and memory held by another record are told by comparing handle values, so one object given under two handles (a give that installs it twice, or the root's own `-erx given` records over slots it holds otherwise) passes: two records carve the same pages of one memory, and one IRQ object under two handles is two entries, whose second bind takes the first binder's deliveries. Compare the objects the backend resolves, or make one handle per object a promise of the domain library that the NIF states.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.h`: the physical form is the zero value of `erx_device_form_t`, so a spec whose form no decoder set makes physical objects; give 0 to a refused `ERX_DEVICE_FORM_NONE` and set the physical form explicitly in `decode_window`.
* [Low] `test/fixtures/erx_device_dma_harness.c`: nothing shows that `open` and `queue_create` read nothing from kept memory (`mprotect` it `PROT_NONE` until `negotiate` in `next_record`), and the harness's `erx_vm_map` takes offset 0 only, so a given window at a nonzero page of its object is not exercised.
* [Low] stopgap, `liberx/backend/fiasco/page_pool.c` (`erx_fiasco_contig_take`): a contiguous run is aligned only to a
  page, on the claim that no cache-writeback granule exceeds a page, which rests on "no writeback granule exceeds
  2 KiB" ([design-device-dma.md](docs/design-device-dma.md), "Open decisions" 1), unverified against the Arm
  Architecture Reference Manual's description of the cache type register's `CWG`. Read it and cite it in
  `page_pool.h` and design-stopgap.md's `erx_mem_create_contiguous` row, or align runs to the largest granule.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`: a failed `erx_device_open` keeps the window's mapping and any line objects it made (in the given form, the window's mapping and the memory's reservation), a retry takes another mapping from the shared device
  window and finds the line `ERX_EBUSY`. A boot's devices are few and a failure is a misconfiguration; the record's cleanup comes with the device service.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, queues: the NIF does not yet refuse `post/4` after the exit of a
  driver process that used the device until `negotiate/2` (`docs/design-runtime.md`, "The reset rule", R8); it needs the
  device's record to monitor the processes that post, as a line's binding does. A restarted driver's sequence
  (`queue_create/4`, `negotiate/2`) does not depend on it.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, queues: the queues run through the handoff sequencer
  ([design-device-dma.md](docs/design-device-dma.md)) and follow the record's coherence mark. The
  `net_device` suite's `noncoherent` cell runs the non-coherent path on QEMU `virt` under HVF and TCG
  ([design-device-tree.md](docs/design-device-tree.md), "The live tree on QEMU"), so user mode runs `DC CVAC`
  and `DC CIVAC` under the stopgap on both; QEMU's DMA is coherent, so the cell shows that the maintenance
  runs and costs no traffic, not that it is sufficient. A device whose DMA is not coherent has not run it: the
  Raspberry Pi 4's given devices have no queues yet. The host tests count the
  maintenance a non-coherent queue issues but do not run it. What is missing besides: the hosted
  stand-in running its plans over `erx_dma_model.c` (its maintenance is empty, `arch/host/erx_dma_arch.c`), so
  the NIF's non-coherent path has no host test with a cache that hides stores; a virtio-gpu region entry, which
  a post writes as an out segment's bytes, so the check does not see its address; the check tying a memory
  address's reach to a buffer the plan hands to the device, and a register-published address's to the rings;
  a register-held length (virtio's `QueueNum`) checked against the reaches the install publishes; a descriptor rewritten while its
  chain is posted, which no view expresses; field-level register ownership, and the ADMA2 (SDHCI)
  descriptor form. The hosted stand-in GENET's plans run on plain memory, not over
  `erx_dma_model.c`, and its engine sets no receive error flags, so design-device-dma.md's receive-flags case is not run over it; the register ring's effect layer is tested over a given GENET by
  `test/fixtures/erx_device_genet_harness.c`, coherent caches only. The maintenance step `L` is read from the current CPU's CTR_EL0 at each plan, so CPUs reporting different lines
  would need the smallest taken once. Test gaps: no NIF test drives a refused
  plan; the check's fuzz target runs at granule 1 only, and chains of three
  or four segments are not driven through the check.
* [Low] `hw/sysreg/aarch64.json`, CTR_EL0: the DMA architecture layer
  (`otp/erts/emulator/nifs/erxos/arch/aarch64/erx_dma_arch.c`) and `liberx/backend/fiasco/arch/aarch64/cache.c`
  each write CTR_EL0's field positions by hand. `tools/erx sysreg refresh` refuses CTR_EL0 ("unsupported Arm
  field attributes": its fields are `Fields.ConstantField`, which `extract_fields` does not take), and no
  generator makes C accessors from `aarch64.json` yet, so `clock.c`'s counter reads are written by hand too. The
  fix is ConstantField support in the refresh and a generator of C accessors that these files include.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, [The display device](docs/design-display.md#the-display-device):
  on the direct path a display driver maps a client's pixel area read-only into its device's DMA window; the device
  NIF cannot map an area into the window yet.
* [Medium] `erlang/apps/erx_fb/src/erx_virtio_gpu.erl`, [The display device](docs/design-display.md#the-display-device):
  the driver process runs on QEMU's virtio-gpu only in the `display_domain` suite, whose one boot brings the
  device up and shows the background; its failure paths have run only as its pure core's host tests. A host test
  of the process on stock OTP is cheap: stub modules `erx_device`, `erx_irq_line`, `erx_memdraw` and `erx_log` that script a
  device answering out of order, refusing a post as full, firing a spurious line, returning a stray completion
  between frames and staying silent past the deadline (a `-D` macro shortening it).
* [Medium] `erlang/apps/erx_fb/src/erx_virtio_gpu.erl`: the screen image's region is sized from the display size
  the device reports at each bring-up, and `erx_device:region/3` refuses the same index with other bytes, so a
  restart after the display's size changed leaves the domain without a screen until the next boot. Size the region
  from a bound that does not change between restarts and show any mode that fits it. The driver also acknowledges a
  configuration-change interrupt without reading `events_read` or writing `events_clear` (virtio 1.2, 5.7.4.2),
  so a change of display size is not followed.
* [High] the display domain's rows (`config/manifest/qemu-virt-development.txt`, `raspi4b-development.txt`;
  [design-stopgap.md](docs/design-stopgap.md#device-records)): the platform records carry the display unit
  (QEMU virt's virtio-gpu at `/virtio_mmio@a001e00`, 9 MiB of DMA memory) and the Pi's `framebuffer` unit, and no
  manifest of the tree places them; the `display_domain` suite boots a manifest of its own
  (`DisplayDomain.manifest`: the site manifest, an eighth of a CPU, 24 MiB and the unit). The domain release has
  the display boot script (`ReleaseFiles::RELEASE_SCRIPTS`); the development manifest's row needs a CPU grant,
  which the system share's reserve has no room for (storage, network and web take its 2,250 mcpu), and on QEMU
  virt room: the development manifest leaves 2.5 MiB of `root_memory` unpromised, the gpu's 9 MiB of DMA memory,
  charged to the system's budget, raises the contiguous pool from 2 MiB to 16 MiB, and the domain's own budget
  comes on top, so the machine's 256 MiB of RAM grows. The display domain holds its keyboard and tablet only
  once the give is per unit and the unit is the transport page (security residuals, `boot_devices`); QEMU
  virt's four transport pages are the spare's, the display's, the network device's and the disks'.
* [Medium] `tools/lib/erx/manifest.rb`, `check_framebuffer_windows`: a framebuffer window is checked against the
  platform record's register windows and RAM, not against the board tree's every `reg` and `ranges` (the GIC, the
  local peripherals, PCIe windows), which the record does not list; checking it against the board's own tree
  (`board_tree.rb`) would make the window's isolation hold by construction. `dom_boot_view.c` reads a framebuffer
  row's line 0 as a line, which only matters once another row records line 0.
* [High] the root's framebuffer record (`liberx/backend/fiasco/runtime_entry.c`, `liberx/backend/core/boot_manifest.c`,
  `liberx/system/dom_boot_view.c`; [design-device-tree.md](docs/design-device-tree.md#facts-into-records)): a
  `framebuffer` row is in no row of `erx_device_kinds`, so the root asks the tree nothing for it, prints no
  `framebuffer` line and writes no `-erx framebuffer` record. A configured domain that holds one would get no record
  and an IRQ object for line 0, which the view reads as a line (the `check_framebuffer_windows` item). The reader, `erx_dt_framebuffer`, is built and tested;
  what remains is the row's ask and line, the physical object over the framebuffer's pages, the record and its
  size in `include/erx/boot_words.h`, and its reader in `erx_device_record`.
* [Medium] `erlang/apps/erx_display/src/erx_screen.erl`: the overlay and the idle policy, whose times are the display
  domain's `display_idle_dim_s` and `display_idle_off_s` variables, are not built; the screen receives the input notice
  from `erx_winfs` and ignores it, so no idle clock runs
  ([The screen and its one path to the device](docs/design-display.md#the-screen-and-its-one-path-to-the-device)).
* [Low] `erlang/apps/erx_fb/src/erx_virtio_gpu_core.erl`: `mode/2` bounds scanout 0 only by the memory given;
  bound its width and height by `erx_memdraw`'s limits once `wrap/4` sets them.
* [Medium] chokepoints, regions ([design-display.md](docs/design-display.md), the `wrap/4` row of the chokepoint
  table): nothing in the build limits who calls `erx_region_view` (only `erx_memdraw_nif.c`) or
  `erx_device_region_memory` (only `erx_device_nif.c`), each a writable pointer into memory a device reads. Add both
  rules to `tools/lib/erx/chokepoint_rules/`, each with a seeded violation.
* [High] [design-apps.md](docs/design-apps.md): the code the design asks for, in the order
  [Track A](docs/plan.md#track-a-apps) builds it. Built: the `start` rows and property 17's structural clauses and
  its planning clause (root's console session and each enabled row's session planned by the domain library beside
  the configured domains);
  `erx_start_table` (`merge/3`, `rc.conf`'s and `ctl`'s parsers with their fuzz targets, `set/3`, the command check
  `apply_ctl/4`); `erx_starter` with its table, a supervisor and keeper per enabled row, and `rc.conf` read and
  written under `/data`; the `apps` tree (`erx_starter_fs`), which a session mounts at `/apps`;
  `erx_domain:start_session/2` with `display` and `default_display`, and the session mark.
  Not built: the session's default display handed on with the ready answer and its `display` variable
  (design-apps.md, "Starting a session", step 3), which the domain service keeps in the session's record and
  hands to nothing; a row that names a display started only once that display's domain has reported ready
  ("Keeping a session"), which waits for a display domain to run, and whose wait no design names: `erx_starter`
  learns only the system namespace (`erx_domain:system_namespace/0`), so the design must say how it learns that a
  display's domain has reported ready before the starter can wait for it; the reset count cleared by the first
  kept session.
* [Low] The start table's first `rc.conf` read waits for the system domain's namespace to be in place
  (`erx_domain:system_namespace/0`), but a storage domain that ends once during boot, or misses the mint
  deadline, settles that wait as failed: the read answers an error and the manifest's enabled rows start before
  `rc.conf` is known, so a row `rc.conf` disables runs until the read succeeds. Waiting through a storage
  restart within its intensity would close it (`erlang/apps/erx_starter/src/erx_starter.erl`).
* [Low] The `apps` tree (`erx_starter_fs`) is served once `erx_starter` starts, after `erx_domain`, whose start
  has the console ask for root's session: root's session gets `/apps` only because its boot outlasts the next
  application's start. A session that reported ready before then has no `/apps` until it restarts. Serving the
  start service's tree before the login (or the login after every application) makes it hold by construction.
  The grants of `apps` also end with a crash of `erx_starter_sup` itself, or of the tree's grants supervisor,
  and nothing grants a session no keeper kept (root's console session among them) a new one, as for every service
  the system domain serves.
* [Low] `apps` tree review residuals (A6, `erx_starter_fs`): the grant's heap bound in the development manifests
  (131,072 words) is not sized against its fids, each open of `rc.conf` holding the text (up to 64 KiB) until its
  clunk, so enough concurrent opens end the grant at its bound and the session has no `/apps` until it restarts;
  each refused `ctl` write logs a line with no rate bound, so a session writing refused lines in a loop fills the
  system log; and the QEMU checkpoint `session-apps-ctl-refused` (`tools/lib/erx/session_domain.rb`) passes on any
  failed write, so it cannot tell the `einval` it expects from `eacces` or `eio` (the shell prints no errno);
  `erx_start_table:ctl_errno/1` has a clause per refusal and no catch-all, but nothing checks it against
  `ctl_error()` (no dialyzer runs), so a new refusal without a clause ends the session's grant on its first
  write: returning the errno with the refusal from `apply_ctl/4` makes it hold by construction.
* [Low] Property 17 plans one root session for the console, but a development build's console also logs root in
  at the host link's `console` line when the host opens it, and a console's relogin after a session ends may
  overlap the old session's end; neither is counted, so a manifest that exactly fills the system principal's
  quota or memory can have that login refused at run time, and the line falls back to the system shell
  ([design-live.md](docs/design-live.md#the-console)). Counting each secure line's root session (and the
  relogin overlap, as `tools/lib/erx/apps.rb` budgets two sessions per kept row) would close it.
* [Medium] The `apps` QEMU suite (`tools/lib/erx/apps.rb`) has no reboot cells yet: `service clock disable` and a
  reboot of the same disk leave the row stopped, and `service clock enable` survives a reboot
  (docs/design-apps.md, "Verification and testing"; docs/plan.md, Track A's demo). Its boots each take a fresh
  copy of the release medium; the reboot cells boot one copy twice.
* [Medium] Manifest property 4 (`tools/lib/erx/manifest.rb`, `normalize_principals`) requires the principals' CPU
  grants together to fit within the `users` share, and every board manifest gives the system principal all of
  `users`, so docs/design-apps.md's own example app principal (`principal clock`, `grant @share.users`) fails the
  manifest check. The rule for dividing `users` among principals is undecided; the `apps` QEMU suite splits it in
  its own test manifest (`Erx::Apps::SPLIT`: root takes three quarters, the app the last quarter). Once decided,
  record it in docs/design-apps.md or docs/design-system.md, fix the example and put the split in the board
  manifests.
* [Low] `erx_starter` review residuals (A5): no deadline on the `rc.conf` process's file operations
    (`erx_starter_rc`), so a hung storage operation queues every later command and holds a restart of the keepers'
    branch and the application's stop, which wait for the operation in progress (a deadline needs a way to cancel a rename already sent,
    such as 9P's `Tflush`); a refused start and a row going down log no line naming the row; the keepers' branch has OTP's default intensity and
    `held/0` reads `restarting` as down; the one-off keeper is a temporary child of the keepers' branch, which
    design-apps.md calls "under no supervisor"; the rescue configuration starting no row is not checked (it is not
    built).
* [Medium] Start table (`erx_starter`, `docs/plan.md` M12): the table owes the reset count, cleared by the first
  kept session, and the rescue configuration starting no row, with their tests, once M12 builds the reset count and the
  rescue configuration; Track A's exit criteria no longer carry them.
* [Medium] The start table's display key (`tools/lib/erx/start_callers.rb`, start-display): the check that only
  `erx_starter` passes `display` or `default_display` to `erx_domain:start_session/2` reads the atoms in the
  calling module only, so a start map built in a helper module that never starts a session passes unseen (the
  keeper already passes a map built elsewhere). Make it hold by construction: a separate entry for a start at a
  display (`start_session/3`, or `start_display_session`) that only the keeper calls, and `start_session/2`
  refusing both keys; start-display then becomes a call-site rule like start-callers.
* [Medium] `erx_starter` review residuals (A5b): whether a held row changed rests on `erx_starter:kept/1` undoing
    `row/2` exactly, and no process test has a row with a display; comparing the stored `erx_starter_row:row()`
    with the one the table would start would make it hold by construction and delete both `kept/1`s.
* [Low] `erx_starter` review residuals (A5b): an enabled row with no record shows as `starting` (a crash between
    recording rc.conf's text and starting the row leaves one until the read answers); `enable` starting its row
    and `stop` recording a stopped row are decided in the process, not returned by `apply_ctl/4`; the rename over
    rc.conf is not followed by a sync of its directory; the process tests make their rc.conf directories in the
    current directory and the failed-read case races its retry by a few microseconds.
* [Low] `erx_starter` review residuals (A5c): a table killed while an `enable`'s write of `rc.conf` is in progress
    leaves the row's stopped mark, so the row stays stopped though the written `rc.conf` enables it, and
    `/apps/ctl` answered `eio`; another `enable` or a `start` runs it (clearing the mark before the write would
    instead let a failed `enable` unmark the row). A `start` of a row not enabled followed by `enable`
    leaves its `{once, Name}` keeper beside the row's supervisor, two sessions for one principal.
* [Low] `/proc/apps` and `service` (A7) leave out what the start service's read API does not expose: a row's
  `domain` and its `ends` within the period are `unsupported`, a down row's `reason` (its session's last end) is
  `unknown`, a session `onestart` started (an `{once, Name}` keeper) shows nowhere, so `onestatus` of a row that
  is not enabled cannot say whether one runs, and `service NAME status` of a configured domain says only that it
  is configured, not its state. `erx_starter_sup:held/0` returning each keeper's session domain, its row
  supervisor's recent ends and the once keepers would fill all but the last; a configured domain's state needs the
  domain service's attributes at `[domains, Id]`. `rows/0`'s skipped rc.conf lines are not shown either. A row is
  `running` while its supervisor lives, a keeper still starting its session included, against "nothing is shown
  as running that the domain service does not list"; a failed read of the manifest shows an empty, known table and
  boot order; and no test reads `manifest_table/1`'s boot order from a packed manifest, which the QEMU
  `service -e` checkpoint checks only by its exit status.
* [Low] `erx_starter_rc:read/1` treats `enoent` as a machine with no `rc.conf`. If the storage domain being down
  answers `enoent` under `/data` rather than another error, the first read finds no settings and is not tried
  again, so the manifest's rows stand until the next boot, and the read counts as answered, so a later `enable`
  or `disable` writes a file made from no settings over the real one once storage is back, losing its other
  settings. An absent `data` grant answers `eio` (`erx_path`), which is retried; check what a live but failing
  storage domain answers.
* [High] [design-display.md](docs/design-display.md): the code the design asks for that the tree does not have, in the
  order [Track D](docs/plan.md#track-d-windows-widgets-and-the-web) builds it. Nothing below is built; the cores named
  as landed are kept and changed as listed.
  * **The pixel area** ([The pixel area](docs/design-display.md#the-pixel-area)): the domain library makes it
    (`erx_dom_connect`'s `area`, `area_reader`), `connection_up` carries it, the connection agent maps it and
    unmaps it after the last image over it (`erx_area`, `erx_memdraw:wrap/4`), and the domain service makes it
    for every pair a `windows` grant joins (`erx_domain_mints:pair_area/3`); still missing is a QEMU case in
    which one domain writes an area's pixels and the other reads them, which needs a reader in the display domain
    (`erx_winfs`).
* [Low] `erx_domain_mints:pair_area/3`: two display domains each granted the other's `windows` service share one
  connection, which carries one area, so the pair takes the lower server row's grant and the other display's grant
  is installed without an area it writes. A nested display, a display that is another display's client, is the
  case; give a connection one area per direction, or have property 18
  refuse the pair, when one is configured.
* [Medium] `erx_connections` (`let_go/5`): a connection with an area is answered unmapped or lost only once
  every process that held the area or an image over it has collected; an idle holder that dropped it but never
  collects holds the connection, its objects and the display's budget for it. The design names only
  `erx_winfs` and `erx_screen`. A fix by construction: at let-go, the NIF replaces the area's range in place with
  private zero memory owned by the resource and the agent answers at once.
* [Medium] `erx_connections`: only the agent opens an `erx_lane` port over a connection's side, but no build check
  enforces it as `area-mappers` (tools/lib/erx/area_mappers.rb) does for `erx_area:map/4`; a side another process
  maps is not counted by the agent, which then answers unmapped while that mapping lives.
* [Low] `erx_memdraw_nif.c`: read-only images are refused as destinations by each writing NIF calling `get_dst`;
  carry the bit in the core or a separate resource type so a new writer cannot miss it, and cover poly,
  fill_poly, ellipse and arc in `wrap_read_only`. The stand-in area has no guard page before the area.
  * **The manifest** ([A display's session](docs/design-display.md#a-displays-session)): the `display` record in
    `abi/manifest.txt`, named after the `windows` service it describes, and its reader; property 18 of the manifest
    check (a template's `pixels` counted by its principal's `domains` quota, no facet row setting `session`) with its
    seeded violations; `abi/services/windows.txt` with the parameters `windows`, `pixels`, `snarf` and `session`; the
  * **The pixel area** ([The pixel area](docs/design-display.md#the-pixel-area)): `erx_dom_connect` with `area` and
    `area_reader`, the connection record's `area`, the grant-table rows and the Fiasco backend's row for an object two
    tasks map (`liberx/system`); `connection_up`'s `Area` and `ERX_LANE_CTL_SLOT`'s pinned length; the connection
    agent's mapping and unmapping of an area; the `erx_area` NIF and `erx_memdraw:wrap/4`, an image over memory the
    NIF did not allocate, which the agent unmaps only after the last image over it is gone.
  * **The display's session and grant** ([A display's session](docs/design-display.md#a-displays-session)): the
    display's session from a start row ([Track A](docs/plan.md#track-a-apps), part 1), with `session` carried by
    every mint of its grant from the session mark the domain service alone sets. A window's buffer at the screen's
    size, allocated once by `erx_win:open/2`, with
    `resized/1` allocating nothing; the grant defaults of 8 windows, 64 MiB and `snarf` off at the server.
  * **The reserved chord** ([The reserved chord](docs/design-display.md#the-reserved-chord)): its field in the
    `display` record, its source spelling and its key encoding, which land with the login design's choice of what
    the chord brings up ([Risks and decisions](docs/design-display.md#risks-and-decisions), 14). Until then no
    display has a chord, so every key reaches a window.
  * **Property 18 and the domain library** ([The pixel area](docs/design-display.md#the-pixel-area)): property 18
    sums each display grant's pixel area and the side the display reads against the display domain's `outer`, but
    the outer budget also pays for the crash area, bells, the system connection and every other side it reads, and
    the grants are not compared with the `connections` quota, so a manifest at the limit passes the build and the
    last session's connection is refused at run time. Plan the display grants' connections in the boot view of
    property 12, so the domain library's arithmetic is the one judge. And `session` is declared as a manifest
    parameter of `windows` that only property 18 refuses: carry the session mark only in the domain service's mint
    request, so no manifest can spell it.
  * **The screen and the allocator** ([The screen](docs/design-display.md#the-screen-and-its-one-path-to-the-device),
    [The pixel area](docs/design-display.md#the-pixel-area)): `erx_screen` sends frames with
    `gen_server:send_request/2` and keeps only pending state (the newest layout, one waiting present per live window,
    dropped at the window's end); presents and `erx_memdraw:wrap/4` refuse an offset off a page boundary.
  * **The display domain**: the display side gains `erx_winfs`, `erx_window`, the
    policies and `erx_wm_menu`, and the client side `erx_win`'s library, `erx_draw`, `erx_draw_conn`, `erx_font`,
    `erx_term` and `erx_ui` with its servers and renderers (docs/design-display.md, "What runs where"). The G9 build
    check (`tools/lib/erx/display_release.rb`) reads module names in the display script's sources; the design's xref
    check over the display release's beams, with its refusal of calls that start a port or a sub-space, is not built.
    `erx_screen_core` knows no buffer's size: a layout entry carries only the window's rectangle, so the plan
    cannot fill the background where a buffer smaller than its window does not reach, and the direct path's third
    condition, a buffer of the screen's size, cannot be judged. Since that size changes with each present, the
    path can change on a present, which `present/4`'s answer must then express (entering or leaving the direct
    path), not only a layout.
  * **The widget server** ([The widget server](docs/design-display.md#the-widget-server)): `erx_ui` with `open/1`,
    `tree/2`, `close/1`, the renderer behaviour and the toolkit's supervisor, and `erx_ui_server`, which validates a
    tree with `erx_ui_schema`, numbers it with `erx_ui_model:pair/3`, applies `delta/2` through the renderer and
    routes its hits through `erx_ui_model:hit/4`; `pair/3` and `hit/4` themselves, with their property tests
    ([Verification](docs/design-display.md#verification-and-testing)).
    `erx_screen_core` keeps its plan and takes the design's names: a present for a flush, and no expose, since
    `erx_screen` copies what a layout change uncovers from the windows' buffers.
  * **The widget server** ([The widget server](docs/design-display.md#the-widget-server)): `erx_ui`, `erx_ui_sup`,
    `erx_ui_server`, the `erx_ui_renderer` behaviour and `erx_ui_model:pair/3` and `hit/4` run on the host over a
    target the caller makes (`erx_ui:start/1`). Left: `erx_ui:open/1` answers `{error, enotsup}` for a display the
    domain holds and for `web` until the server opens its window as its holder (with the window stack, `erx_win`) and
    the web line; the server's `{ui_down, Window, display_down}`; `erx_ui_erlang`; and the seeded faults of the
    Verification bullets for `pair/3` and `hit/4` (keys paired across parents, every omitted property kept, the value
    taken from the report) as property tests under PropEr, which the tree does not have yet; the cases run as seeded
    EUnit in `test/erlang/erx_ui_model_tests.erl`. The opener's map from a window to its server keeps a stale
    entry after `ui_down` until the opener calls `close/1`. `erx_ui:open/1` takes any facet the domain holds as a
    display, where the design asks for a grant of a `windows` tree. Only the `client` boot row takes `erx_ui`; a
    session's script, which the design gives widgets, and a web-only domain's do not yet.
  * **`erx_ui_lvgl`** ([The widget server](docs/design-display.md#the-widget-server)): the shell
    (`erlang/apps/erx_ui/src/erx_ui_lvgl.erl`) performs `erx_ui_lvgl_core`'s actions over a port its `open`
    callback starts and a `present` callback, and `test/host/erx_ui_lvgl_test.rb` drives the real `erx-lvgl` with it
    on the host. Left: `open` on erXos, which starts the program in the session with the window's buffer as its
    `mem` descriptor 3 (the Programs item below), and `present`, `window/2` and `resize/3` bound to the window, with
    the display domain; the fault log names the window and the report's byte position, which the design asks for
    and the shell does not count yet. A window grown past its buffer is refused by the program and ends the UI as
    `renderer_down`, so the restart allocates a buffer at the new screen's size; the shell does not clamp. A fault
    fails a waiting `apply/2` only by the shell's exit. A program that stops reading its input blocks the shell in
    `port_command/2`, and with it `apply/2`, `close/1`, the window's input and the program's exit, a residual until
    writes are bounded (`nosuspend` and a busy event for the core, or a `close/1` that kills the program itself).
  * **Programs** ([The startup message](docs/design-programs.md#the-startup-message)): the profile, `liberx`'s
    decoder, its fuzz targets and the descriptor table (`erx_prog_fd_mmap`, `erx_prog_fd_fstat`) take the `mem`
    descriptor; `erx_program:start/1` takes a window buffer's lease, the driver maps it at the buffer place, and
    musl's descriptor seam routes a program's descriptor calls to the table. Left: a programs-suite case on erXos
    that lends a real buffer, so the driver's `LEASE_MAP`, a program's `fstat` and `mmap` of fd 3, a `MAP_FIXED`
    over it and the order of the anchor's destroy, the lease's return and `{erx_area_returned, N}` run on the
    target (only the take's refusal does, the `no_lease` case of `tools/lib/erx/programs.rb`); and `fstat`'s modes
    (a pipe end a FIFO of 0600, a mem range a regular file of 0600) checked against FreeBSD's `pipe_stat` and
    `shm_stat`, unverified, and a pipe end's size, 0 where FreeBSD reports the bytes readable.
  * **Input from another domain** ([The display device](docs/design-display.md#the-display-device)):
    `abi/formats/input.txt`, its generated reader and writer and their fuzz target.
  * **The web** ([UIs: the browser renderer](docs/design-web.md#uis-the-browser-renderer)): `erx_ui_server` and
    `erx_ui_browser` start in the application's session; `erx_web_line` keeps the table of open UIs and serves the
    `ui` and `uis` targets as views; `erx_web_conn` decodes an event's record and sends every `open` to the line,
    where it answers `ui`, `uis` and `event` as unsupported today.
* [Low] `tools/lib/erx/abi_emit_ui_wire.rb` and `abi_emit_ui_wire_ts.rb`, [Widget format](docs/design-abi.md#widget-format):
  the server's records are declared in `abi/formats/ui.txt` and their code generated, but the two reports' fields
  (event's node, event number and detail; damage's count and rectangles) and the report reader's six reasons are
  still fixed text in the Erlang encoder and `read/1`, the C writers and the TypeScript `readReport`, `writeEvent`
  and `writeDamage`, tied by the parity test. Give `report` lines fields (a `detail`, and a width, a height and a
  list of rectangles for `damage`) and generate them as the records are.
* [Medium] `tools/lib/erx/abi_emit_ui_fields.rb`, [Widget format](docs/design-abi.md#widget-format): a field type's
  code is spread beyond its `UIFields::CODE` row (the Erlang `read_props`/`read_removed`, the C `erx_ui_props`/
  `erx_ui_removed`, `kind_number/1`, the `input()` type, the TypeScript `nodeId`/`kindName`/`rune`/`writeRune`
  helpers, `?IS_I8`/`?IS_DIRECTION`, `c_locals`' and `c_members`' type lists), and much of it is emitted whether
  or not a field uses the type; so a ui.txt that drops every `removals`, `kind` or `input` field, or declares no
  input form, is accepted but fails `-Werror` or does not parse. Move each type's helpers into its row and emit
  them only when used. Lows from the same review: record and form names are not checked against generated C
  macros (`op_max` makes `ERX_UI_OP_MAX` twice), C keywords or Erlang reserved words; `insert_header` counts only
  fixed fields and props, so a `removals` or `input` field in insert would undercount `insert_max`;
  `encode({input, Bad}, _)` raises `{bad_value, Bad}` where other records raise `bad_record`; no refusal case pins
  that a key input with a bad direction and a truncated code is `bad_key_direction`.
* [Medium] web, the connection side of the line (`erlang/apps/erx_web/src/erx_web_conn.erl`, `perform/2`;
  `erlang/apps/erx_web/src/erx_web_relay_conn.erl`, `remember/2`): `erx_web_conn` is documented as a pure state
  machine but `perform/2` calls the line, monitors and sends; move it to a driver module of its own. The relay
  connection keeps a second map from view pid to view beside the core's, filled outside the core, and its close
  is an `exit(normal)` inside a closure; have the core own the lookup by pid (`update_from`, `ended_from`, `down`
  inputs) and make the close an explicit clause. `perform/2` also takes any pid the line answers as a view;
  require the line's domain (`erx:owner/1`).
* [Medium] `erlang/apps/erx_web_line/src/erx_web_value.erl`, [Values](docs/design-web.md#values): a huge integer's
  `leading/1` (a power of ten and a bignum division) costs 110-160 ms for the largest bignum and is charged only
  its 4 KiB print, so about 15 of them fit one projection, about 2 s of the session's CPU per update (13 copies
  measured at 1.5 s). Charge the work, or reuse one `10^Dropped` per byte length within a projection, and time
  15 separate huge integers in `erx_web_value_tests`.
* [Medium] `erlang/apps/erx_web_line/src/erx_web_value.erl`: a printed map's copy is rebuilt with `maps:from_list`, so
  its print order can differ from the term's: a map of more than 32 keys cut to 32 or fewer prints sorted where
  the term prints in hash order, and a huge integer key shortened by `leading/1` can sort before a smaller key.
  Copy a map as its pairs in the term's own print order, with a property test comparing the copy's print with
  the term's.
* [Low] `abi/protocols/web.txt`, [URLs](docs/design-web.md#urls): `web_segment_max` (256) bounds a path segment,
  which is an encoded `/proc` entry name, while `erx_procfs_core` admits names of up to 765 encoded bytes (255 bytes,
  each `%XX`); so an entry whose encoded name is longer than 256 bytes has no route or link in the client
  (`web/src/routes.ts`), and the browser cannot open it. Raise the bound to the longest encoded name, or state the
  limit in the design.
* [Medium] `test/host/erx_web_proto_test.rb`, [Web protocol](docs/design-abi.md#web-protocol): no test encodes a
  term one past each bound in both languages; every encoded term is in bounds or came from a decoder, so an
  encoder that stopped refusing an over-bound list, text or integer would pass. Erlang's encoder refuses
  over-long bytes and texts as `too_long` and over-count lists as `too_many`, as both decoders do, which
  `erx_web_conn` relies on to end a view `too_large`; the TypeScript encoder still answers `bad_term` there. Make
  it match, then a table-driven case over `type/1` and `TYPES` expecting the same reason from both closes it.
* [Medium] `tools/lib/erx/manifest.rb`, [The host tool's front end](docs/design-web.md#the-host-tools-front-end):
  the design says a release manifest that offers the host the `web` facet fails the manifest check. At run time
  the host link offers it only where the manifest's development flag is set and the system domain holds a facet of
  the `web` interface (`erx_hostlink_web:open/1`), but Phase 1's check refuses every release manifest, so the
  build-time rule has no site yet; with the release check (M11), refuse a release manifest that grants a facet of
  the `web` interface, with a seeded violation.
* [Medium] `config/manifest/qemu-virt-development.txt`, the web domain's row: its 24 MiB and its grant, a quarter
  of one CPU, are estimates, and so are the 256 MiB machine's `root_memory` (180.75 MiB) and the system
  principal's 131 MiB that make room for it; no boot-time or memory figure has been recorded for a boot with the
  web domain. Measure the domain with `Footprint` at rest and with the host tool's four connections open, the
  boot's time to the shell before and after the web domain (`tools/erx bench`), and size the row and
  `root_memory` from the figures.
* [Medium] `config/platforms/qemu-virt.json`, `config/manifest/qemu-virt-development.txt`: the boot archive
  outgrows the 256 MiB development machine. The archive and `root_memory` must fit RAM less `fiasco_reserve`
  less what the boot keeps (`RootStartup.check_archive`), and the programs suite's test archive, the largest on
  that machine, grows by about 1.2 MiB a day of landings (one day's measurement). Lowering `root_memory` again
  can take at most the 2.5 MiB it leaves unpromised before it takes memory from budgets, which the budget-sum
  check refuses, so that cut can be made only once more. The lasting fix is more RAM for QEMU virt's
  development machine: each 32 MiB gives the root about 30 MiB (Fiasco's kernel memory takes about 6%), so
  `ram_bytes`, `fiasco_reserve`, `root_memory` and the measured figures in the manifest comments and
  [design-stopgap.md](docs/design-stopgap.md#the-phase-1-manifest-check) move together.
* [Medium] `erlang/apps/erx_hostlink/src/erx_hostlink_web.erl`, `tools/lib/erx/web_server.rb`,
  [The host tool's front end](docs/design-web.md#the-host-tools-front-end): a restart of the web domain ends the
  system domain's facet with the relay (`exit(shutdown)`), and the session drops the facet's number without
  telling the host. The host tool keeps the dead number: every later call is answered `{error, noproc}`, a reply
  rather than a link failure, so each new WebSocket is refused with 503 until the host link breaks or `erx web`
  restarts, and an open one stays open while its browser answers the tool's pings. Give the host a signal (a
  cast of `{web_closed, C, down}` for each connection the facet relayed before it exits, and the host tool
  reopening the facet on `noproc`), with a host test that ends the relay under an open connection.
* [Medium] `erlang/apps/erx_web/src/erx_web_conn.erl`, W8 in [Requirements](docs/design-web.md#requirements): a
  browser's `event` messages have no flow control. Each becomes one message to the UI's renderer, so a hostile
  browser can fill the renderer's mailbox as fast as its connection carries bytes, while W8 bounds what one
  browser makes the machine hold. Bound the events in flight per UI view (the renderer acknowledges each, and
  the core drops an event while one is unacknowledged, or keeps a small credit), in the design first.
* [Medium] `tools/lib/erx/abi_emit_web.rb`, [The protocol](docs/design-web.md#the-protocol): the protocol hash
  covers the declarations, not the codec code (`abi_web.rb`, both emitters' interpreters, `web/src/wire.ts`), so a
  change to the interpreter alone keeps the hash and an old client passes `hello`. Fold the generator files'
  digests into the hash or hash the generated tables, and say which in design-web.md.
* [Low] `abi/protocols/web.txt`, [The protocol](docs/design-web.md#the-protocol): an `event`'s and an update's
  `ui_record` is any ui.txt record of its length; each consumer must run ui.txt's reader on it. Calling the
  generated event reader inside the codec would make "an accepted event is an event" hold by construction.
* [Low] `abi/protocols/web.txt`, [Interfaces](docs/design-web.md#interfaces): the fixed response headers and each
  file kind's content type, and the header table generated for Erlang and Ruby, are not declared yet. The host
  tool's front end holds their one copy (`Erx::Web::Http::SECURITY` in `tools/lib/erx/web_http.rb`,
  `Erx::Web::Inventory::TYPES` in `tools/lib/erx/web_inventory.rb`); declare them before `erx_web_cowboy` writes a
  header, and generate both front ends' tables.
* [Medium] `tools/lib/erx/web_server.rb`, [The host tool's front end](docs/design-web.md#the-host-tools-front-end):
  every call on the web facet (`connect`, `data`, `close`, and `open`'s hello) is a blocking `HostlinkClient#call`
  inside the one select loop, so a slow or rebooting machine stalls every connection for up to the call's 10 s
  (files, pings, the other WebSockets), and each browser message costs one host-link round trip during which the
  others wait. Send calls with `send_call`, match replies by id in the loop, and keep a pending-connect state per
  upgrade (the 101 goes out on the `connect` reply), so the loop never waits on the machine by construction. The
  same change removes the casts a call collects waiting up to 1 s for the next select.
* [Low] `tools/lib/erx/web_server.rb`: when the host link's socket itself ends (QEMU exited), every later upgrade
  fails with `Relay::Down` and prints a line, and the server serves files and 503 forever; exit with a diagnostic
  on the socket's end, or reconnect to `--socket PATH`, and rate-limit the line.
* [Low] `tools/lib/erx/web_http.rb`, `Http.file`: every file but `index.html` is sent `immutable`, on the
  design's rule that `make web` names each `<stem>-<first 16 hex digits of its SHA-256>`, which `Inventory` does
  not check; check it there, or send `no-store` for a name without the hash. A refusal of a request that carried bytes
  after its head (a 405 for a POST with a body) closes with unread input, so the kernel's reset may cost the
  client the answer; shut down writing and drain briefly before closing.
* [Medium] `web/src/connection.ts`, [Failure handling](docs/design-web.md#failure-handling-diagnostics-and-debuggability):
  a view the machine ends `closed` is not reopened, as the design's recovery says, until the socket drops; view
  numbers are fixed per target, so a reopen needs a per-connection counter of numbers, and a rule for which end
  reasons reopen and how often, so a view that crashes at once is not reopened at the network's pace.
* [Medium] `web/src/connection.ts`, W7: the browser sees no ping, and a record view is silent while its record does
  not change, so a half-open socket (a laptop's sleep, a dropped NAT entry) shows the last record as current with no
  "stale since"; the network front end needs a heartbeat the client sees and a client timer that ends the socket.
* [Low] `web/src/connection.ts`, [Failure handling](docs/design-web.md#failure-handling-diagnostics-and-debuggability):
  after `bye protocol` the design says the client reloads; the core reconnects, and a welcome resets its delay, so a
  disagreement on a rule reconnects every second. An update whose body is not the target's kind (`entries` for a
  `path`) is handed to the page, which ignores it and never asks again; check the kind in the core and close.
* [Low] `web/src/record.tsx`, [The client](docs/design-web.md#the-client): the record view has no unit column, and
  its presentations are text, not links; they need the inspection schema's units in the generated tables and the
  routes of presentations served by views.
* [Low] `tools/lib/erx/web_build.rb`, [The client](docs/design-web.md#the-client): the bundle's notices file
  holds esbuild's legal comments, and React's say only that the MIT licence is "found in the LICENSE file", which
  the bundle does not carry; add each bundled package's LICENSE text from the store before the client's files are
  distributed, by the web domain's release or the website's demo image.
* [Medium] `test/host/web_browser_test.rb`, [Verification and testing](docs/design-web.md#verification-and-testing):
  `deps.lock` pins Playwright's Chromium for macOS on arm64 only, as Playwright builds none for FreeBSD, so the
  browser tests are not run on the FreeBSD x86-64 check host that runs the landing gate's `make check`; run them
  in the gate's local step on macOS, or pin a FreeBSD Chromium (the `www/chromium` package) by its SHA-256.
* [Low] `web/test/browser`, W6 and W7: the client has no trace page and no view but the home record, so the URL
  test can only find that no form opens a trace, and the stale test covers one view; extend both as the views land
  (a reconnect with the trace page open, every open view marked stale, a ring overrun's gap).
* [Medium] `tools/lib/erx/web_build.rb`, `build`: esbuild and tsc resolve a bare import through any `node_modules`
  above the stage (the worktree, the home directory), so an import of a package missing from `web/package.json`
  can bundle an unpinned package found there. Run esbuild with `--metafile` and refuse any input outside the
  stage's `src/` and the lockfile's packages under `build/web-modules/node_modules/.pnpm/`.
* [Low] `web/test`'s install tests (`test/host/web_build_test.rb`): they install offline from `build/web-store`, which
  pnpm 12 allows only while its per-user `lockfile-verified.jsonl` holds a pass for the lockfile (an online fetch by
  the same user writes it); on a host or user without it they fail with `ERR_PNPM_NO_OFFLINE_META`. Use
  `trust-lockfile` in the tests' installs or install them online.
* [Low] `tools/lib/erx/web_build.rb`: the stage copies untracked files of `web/` (a stale `out/` whose files
  `build` would publish); stage only tracked sources and have esbuild write outside the stage. Two builds in one tree share `build/web-stage` and
  `build/web.next`; take a lock as `Generated` does.
* [Low] `docs/design-web.md`, Dependencies: React 19 ships no types, so the views' `.tsx` need `@types/react`
  and `@types/react-dom` (MIT, DefinitelyTyped) for `tsc --noEmit`; list them beside React when it lands.
* [Medium] `test/host/erx_ui_wire_test.rb`, [Widget format](docs/design-abi.md#widget-format): no test encodes
  each kind's largest `insert`, every property at its bound, and compares its size with the generator's
  `insert_max` (`tools/lib/erx/abi_ui.rb`'s sizes and the encoder's layout are two descriptions of one form).
* [Low] `abi/formats/ui.txt` and the generated readers: a `present` name is checked only as UTF-8 of at most 63
  bytes, while design-abi.md calls it "a presentation name of the inspection schema", which `abi/inspection.txt`
  declares: generate the name table into both readers, as `erx_ui_schema` checks it against `erx_present:marks/0`.
* [Medium] `erlang/apps/erx_display/src/erx_wm*.erl`, [Windows and the window
  system](docs/design-display.md#windows-and-the-window-system): settle this when `erx_winfs` is written, with a
  property case.
  * **Lost key ups.** A key whose up is lost (a keyboard unplugged mid-press) stays held in the chord's state; a
    lost up of the chord's completing key leaves it withheld, so its next downs are dropped as repeats and the chord
    does not fire again. Give `input()` a `repeat` direction (virtio-input reports one) so a `down` of a held key
    means its up was lost, and keep held keys per device, cleared when the device goes away.
* [Medium] `erlang/apps/erx_win/src/erx_vt.erl`, [The terminal
  emulator](docs/design-display.md#the-terminal-emulator): the core is built without `key/2`. The oracle test
  (`test/host/erx_vt_oracle_test.rb`, libvterm 0.3.3 with `test/vt/vterm_dump.c`) runs only the per-row cases
  and the open details of `test/vt/corpus.rb`: the exhaustive enumeration, the streams generated from the
  tables' grammar, the `prim_tty` and toybox recordings, `vttest`'s core (pin `vttest` 20251205, SHA-256
  `cd6886f9aefe6a3f6c566fa61271a55710901a71849c630bf5376aa984bf77cc` as Homebrew records it, and write the
  pseudo-terminal driver) and the coverage check of [Verification](docs/design-display.md#verification-and-testing)
  are not built. Three entries of `test/vt/differences.txt` keep `erx_vt`'s choice where the references read did
  not settle it, and want xterm's source or DEC STD 070 checked: HT at the last column with a wrap pending,
  U+00A0 inside a control sequence, and `CSI ? 1049 h` on the alternate screen. The dump holds no scrollback,
  so what DL and a resize save, and the scrollback's charge per row, are checked only by the EUnit cases.
  The terminal generator writes the width table for Erlang and `include/erx/vt_width.h`, not musl's
  `wcwidth` tables or `erx_width`.
* [Medium] `erlang/apps/erx_win/src/erx_vt.erl`, `full_reset/1`, `soft_reset/1` and `resize/3`: what RIS,
  DECSTR and a resize keep is a list of `#vt{}` fields at each site, so a new field (the link grammar's state,
  `key/2`'s) must be remembered at each. Nest what RIS resets (grids, cursor, pen, modes, margins, tabs,
  character sets, saved cursors, links) in a record of its own beside what lives as long as the terminal
  (scrollback, counters, decoder and parser states, the next link id), so RIS replaces the inner record with
  `new/2`'s and lists nothing. Also from the core's review: the `Wrapped` flag is set on a bottom row below the
  region that autowrap then overwrites, and ECH to the row's end leaves it set.
* [Medium] `abi/formats/ui.txt` validity and `erlang/apps/erx_ui/src/erx_ui_model.erl`, [Widget
  trees](docs/design-display.md#widget-trees): no rule bounds one node's children below the grant's `ui_nodes`, which
  has no value yet. `delta/2`'s longest kept run and its index bookkeeping, and `apply_ops/2`'s insert and move, are
  quadratic in a node's children (a reversed flat node of 16,000 children: 10 s for `delta/2`, 20 s to apply, on
  Homebrew erl), and an index above 65,535 does not fit `diff_op()` or the binary form. Add a per-node children
  limit to the validity rules (at most 65,536; 1,024 suggested), which bounds both by construction.
* [Low] `test/fixtures/erx_draw_codec_harness.c` and `tools/fuzz/draw_codec_target.rb`, the draw codec's C twin,
  [Draw messages](docs/design-display.md#draw-messages): the twin still frames a `Y` with the stand-in
  `erx_draw_cload_frame`, so the differential test of the codec against it compares `erx_draw_image` with the
  stand-in, not with 9front's decoder. Link `display/libmemdraw/cload.c` behind it and delete the stand-in.
  `cloadmemimage`'s `badrect` bounds are narrower than the stand-in's, so keep the harness's rectangles within them.
* [Medium] `display/memdraw/erx_memdraw.c`, [the pixel
  primitives](docs/design-display.md#verification-and-testing): the 9front build (unmodified 9front `libmemdraw`
  built for the host, the test tool of design.md's dependency table) does not exist yet, so `erx_memdraw` is checked
  only against `erx_draw_ref`. Build it, run `erx_memdraw`'s operations and the shapes against it, and treat each
  of erXos's edits listed in `display/libmemdraw/ORIGIN.md` as a documented difference with a test. One of those
  edits is an upstream bug (`readbyte`'s alpha-only read of a replicated grey-and-alpha mask wrote grey into the
  alpha buffer): the item below reports it.
* [Low] display, `display/libmemdraw/draw.c` (`readbyte`): report the upstream bug to 9front. Under an alpha-only read
  of a replicated grey-and-alpha mask, `readbyte` wrote each pixel's grey into the alpha buffer; erXos's copy fixes it
  (marked erXos, recorded in `display/libmemdraw/ORIGIN.md`).
  primitives](docs/design-display.md#verification-and-testing): the 9front build (`MemdrawBuild.oracle`) checks
  only the shapes, under `SoverD`. Run `erx_memdraw`'s draws and loads against it too, and treat each of erXos's
  edits listed in `display/libmemdraw/ORIGIN.md` as a documented difference with a test. One of those edits is an
  upstream bug (`readbyte`'s alpha-only read of a replicated grey-and-alpha mask wrote grey into the alpha
  buffer): a candidate report to 9front.
* [Medium] `display/memdraw/erx_memdraw_nif.c`, [Draw messages](docs/design-display.md#draw-messages): the move to a
  dirty scheduler counts only the clipped destination's bytes, so two calls that cost more stay on a normal scheduler:
  `alloc`, whose fill writes the whole image, and a draw whose mask, or replicated source, is the destination, which
  copies the whole destination image first (`snapshot`) however small the clipped rectangle. Count the bytes each call
  actually touches; measure a full-screen `alloc` and a 1-pixel self-masked draw on a 4K screen image to set the bound.
  `erx_memdraw_draw_bytes` also reads the live image headers, apart from the draw's own copy, so a concurrent `clip`
  can make a large draw count small (scheduling only; the draw itself is checked on its copy).
* [Medium] `display/memdraw/erx_memdraw.c`: `clip` rewrites `flags` and `clipr` in an image's shared `Memimage`
  while another process may be drawing from it, a C11 data race that is memory-safe only because
  `erx_memdraw_draw` and `shape_begin` each copy every header once and check the copy whole. Take the replicate
  bit and clip rectangle out of the shared header (kept by the image's owner and passed to each call, or a
  per-image record `clip` replaces whole), so the header is immutable after `alloc` and no copy is needed.
* [Medium] `display/memdraw/`, the chokepoints `memdraw-clip` and `memdraw-pixels`
  (tools/lib/erx/chokepoint_rules/memdraw.rb) are file-level: they admit every function of `erx_memdraw.c` and
  `draw.c`, where the design names `erx_memdraw_draw` and `memdraw` as `memimagedraw`'s only callers and
  `snapshot` as erx_memdraw's only pixel copy. Move the two funnels and the snapshot into a file of their own, or
  scope the rules by function.
* [Low] `display/memdraw/erx_memdraw_nif.c`, `get_points`: a failed `enif_alloc` of a shape's points answers
  `badarg`, not `enomem`.
* [Low] `display/memdraw/`, erx_memdraw's tests: nothing exercises a draw that moves to a dirty scheduler or an
  `enomem` answer (`alphadraw`'s buffer or the snapshot failing to allocate). Add a draw over 64 KiB and an
  allocation-failure seed to `test/erlang/erx_memdraw_tests.erl`.
* [Low] `display/libmemdraw/draw.c`, `alphadraw`: its per-call buffer comes from `mallocz(n, 0)`, not zeroed, as
  upstream's was not. Zero it (`mallocz(n, 1)`), or show that every byte is written before it is read and
  say so beside the call.
* [Low] `test/erlang/erx_draw_ref.erl` and `erlang/apps/erx_win/src/erx_draw_core.erl`: `supported_chan/2` is
  copied between the core and the reference, so a change to the channels `b` refuses must be made in both. Export it
  from the core, or keep the copy as the oracle's own and say so in it.
* [Low] `display/memdraw/erx_memdraw_nif.c`: `ERL_NIF_INIT` gives no `upgrade` callback, so reloading `erx_memdraw`
  while images are live fails rather than taking over the resource type. Add one (`enif_open_resource_type` with
  `ERL_NIF_RT_TAKEOVER`) when hot reload of the display domain is wanted.
* [Low] `tools/lib/erx/abi_emit_draw.rb`: design-display.md says the generator also produces the message table of its
  interface section from `draw.txt`; it does not, and the table in "Draw messages" is hand-written.
* [Medium] `display/lvgl/erx_lvgl.c`, [The widget server](docs/design-display.md#the-widget-server) and design-abi.md
  "Widget format": gaps the LVGL program had to fill. (1) An `input` key's `code` has no stated meaning; the program
  uses the rune alone, with keyboard(6)'s private-use runes for the cursor keys. (2) `align` `start`, `center` and
  `end` have no LVGL flex equivalent per child; the program gives such a node its own size at the start of the cross
  axis, so the parity test will differ there. (3) No source declares Plan 9 channel descriptors (`draw.txt` declares only
  the messages); the program computes the four it renders in (`r5g6b5`, `r8g8b8`, `x8r8g8b8`, `a8r8g8b8`) with draw(2)'s
  `CHAN` packing, and should take them from the generated table once it exists.
  (4) A `present` property is shown as LVGL glyphs without the line escape the design asks for, since no C twin of
  `erx_text:escape_line/1` is generated. Glyph rendering cannot inject terminal controls, but bidirectional overrides
  and invisible format characters still mislead, and LVGL's font draws U+F000-U+F8FF as its built-in icons; the
  simplest fix is for the widget server to escape the canonical text before encoding it.
* [Medium] `display/lvgl/erx_lvgl.c`, review findings left open. (1) A slider whose `max - min` exceeds a signed 32-bit
  integer overflows inside LVGL (`lv_bar.c`), which the sanitized build aborts on; scale such a range. (2) `set_slider`
  re-applies the last `value` the server sent on any set of the slider, undoing the user's drag, and `items` alone
  resets a list's selection to 0; which state value a set keeps is a question for `erx_ui_model:hit/4`'s design.
  (3) The focus ring follows LVGL's group, which orders nodes by creation, not tree order as design-display.md
  "Kiosks and glasses" asks; rebuild the group at commit. (4) A status shows as `[timeout]` with no milliseconds and
  no reporter, unlike `erx_render`'s tokens (G7). (5) A text holding U+0000 is cut there by LVGL. (6) The Makefile
  rebuilds LVGL's objects when `lv_conf.h` or a source or header they read changes, not when the compiler does.
* [Medium] `display/lvgl/lvgl` (the fork submodule), `make check`: erXos's own patches committed on the fork are not
  seen by `make check`'s ASCII and chokepoint scans, which skip the submodule as imported code, though CLAUDE.md (Forks as submodules) holds those patches to the
  same ASCII and review rules. Scan the fork's diff from the commit ORIGIN.md names to the gitlink; due with the
  first patch.
* [Low] `display/lvgl/ORIGIN.md`: nothing checks the commit it records against the superproject's gitlink.
* [Low] `display/lvgl/Makefile`: `-I$(LVGL)` exposes the whole checkout, so a header at its root could shadow a system
  header.
* [Low] `display/lvgl/Makefile`: a `.c` file deleted on a fork branch stays in `liblvgl.a`.
* [Low] `tools/lib/erx/lvgl.rb`: `git` duplicates `Checks.isolated_git_environment` instead of sharing it.
* [Low] `tools/lib/erx/lvgl.rb`, `Lvgl::Program::LICENSE`: the archive's licence expression is hand-kept against
  `display/lvgl/lv_conf.h` and LVGL's sources, so an option turned on there (an image decoder, another font) or a
  third-party file no option guards (as FrogFS's `decomp_raw.c`, which the Makefile leaves out) is not attributed
  until the expression is edited too. Per-file attribution would read blob hashes from the submodule's tree at the
  gitlink with a small path-to-licence map, or check the archive's defining members (`llvm-nm --defined-only`)
  against such a map. `src/misc/lv_lru.c` cites willcannings/C-LRU-Cache with no notice of its own; its upstream
  licence is unverified.
* [High] `erx_wm_rio` (desktop, not built; until it is, `erx_fb_sup` starts `erx_winfs` under the single policy whatever
  the display domain's `display_policy` says; the P7 version is on branch `disp-p7`, commit 5ea13441): rio's rule that
  the window taking the keyboard is the topmost shown one lets any client take the keyboard from another session's
  window by a `wctl` `top`, `hide` then `show`, or a `mkdir`, and so read what the user types next. Before the
  overlapping policy lands, its design keeps the current window in the policy's state and moves it only on the
  user's actions (a click, the menu), so a client's request only raises; `decorate/2` then needs that state.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device_nif.c`: a move of a bound edge line can lose the one delivery taken under the old label just before the old sink was unregistered, while a level
  line fires again at the bind's acknowledgement. A driver of an edge line looks at its device after binding. The PL011's line is level.
* [Medium] `erlang/apps/erx_blk/src/erx_blk_sd.erl` (`await/3`) and `erx_blk_sd_host.erl` (`issued/2`): both expect a
  command's events in one order, command complete before the buffer events, so a controller that raises buffer write
  ready before the response, in a separate interrupt word, fails the step and restarts the storage domain on every
  write. QEMU's raspi4b model does not: the `tcg-sd-card` cell identifies the card and writes two blocks
  (docs/research-sdhci-qemu-model.md, "erXos's SD driver on the model"); whether the BCM2711's EMMC2 does is
  unverified, and the board probe should record it. The fix by construction: track
  command done and data progress as independent facts, holding an early buffer event until command complete, and in
  the start take the events `sd_shape/1` names as a set.
* [Medium] `erlang/apps/erx_blk/src/erx_blk_sup.erl`: a line owner (`erx_irq_line:start_owner/2`) that fails to start
  fails the supervisor's start, so the permanent application ends the storage domain, and the same failure repeats on
  each restart until the domain row's intensity runs out, with no line from the driver. The owner child should refuse
  with one line and `ignore`, after which the device process's `attach/2` fails and it refuses too.
* [Medium] `erlang/apps/erx_blk/src/erx_blk_write.erl` (`sd_step/4`): a plan is built from the command index alone,
  so `{acmd, 13, ...}` is CMD13 and an ACMD issued without CMD55 first is the plain command (ACMD6 becomes CMD6 with
  any argument); that CMD55 always precedes an ACMD rests on the card core's phases. ACMD41's, CMD7's, CMD55's and
  CMD48's arguments are not checked. Make an app command one plan that issues CMD55 with the card's address, checks
  APP_CMD in its R1, then issues the ACMD.
* [Low] `erlang/apps/erx_blk/src/erx_blk_sd.erl`: events left in an interrupt word after a request is answered are
  handed to the next request, issued within the same word's fold; a stray buffer bit then fails it. Drop the rest of
  the word once a request is answered. A refusal partway through the start also leaves `irpt_en` set; clear it
  before `ignore`.
* [Medium] `tools/lib/erx/raspi4b_shell.rb`, the SD model tests of docs/design-storage.md ("Verification and testing"):
  the `tcg-sd-card` cell identifies the card, reads the partition table, mounts littlefs and writes and reads back two
  blocks outside every partition, on the packed card only, a 2 GiB standard-capacity card. Still to come: a file
  written and synced at `/data` and read back after the storage domain is killed and restarted, a 4 GiB
  high-capacity card, the seeded medium whose data partition holds a different file, and the recovery test under a write load.
* [Low] `erlang/apps/erx_blk/src/erx_blk_sd_host.erl`: OUT_OF_RANGE is type X in Physical Layer Table 4-42 (p.120), so a card may report the last-sector out of range of a CMD18 in the next command's R1 instead of Auto CMD12's; the transfer machine exempts only Auto CMD12's, so such a card would fail the next request and restart the storage domain. The board probe should record whether a card does this; if one does, exempt OUT_OF_RANGE alone in the first R1 after such a read.
* [Medium] `erlang/apps/erx_net/erxos/erx_virtio_net.erl`, `erlang/apps/erx_blk`: no test runs a real driver under a hostile device. `test/integration/runtime_device_test.rb` breaks a hosted stand-in's queue under a driver written in the test, so the drivers' own broken-queue path (`error({virtio_net, broken, rx})`), its supervision and restart, and that the crash ends only the driver process (the network driver; the block driver's crash ends the storage domain) are unchecked; plan.md's 1b-E exit criterion asks for it under QEMU. Running `erx_virtio_net` over a virtio stand-in hosted, or a hostile model device under QEMU, would settle it.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`, the hosted stand-in: its virtio model (`stand_in_preset`, `stand_in_stored`, a hook in `store()`) is a second model of a virtio-mmio transport beside `test/fixtures/erx_device_dma_harness.c`'s, which sits at the access seam and leaves `erx_device.c` untouched. A hosted-only `device_access` over the fixture's model would remove the hook and the duplicate, and keep `queue_ready` per selected queue, which the stand-in's one word cannot (so one queue still ready, `ERX_EBUSY`, is not expressible hosted).
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device_queue.c`, `erx_device_genet.c`, the round functions: no fuzz
  target drives `erx_device_queue_round` or `erx_device_genet_round`. `tools/fuzz/device_queue_fuzz.c` and
  `device_genet_fuzz.c` drive the cores beneath them, so the rounds' handling of the used index, the entries,
  GENET's statuses and `bytes_max` is tested only end to end through the stand-ins. Run each round function in a
  loop like `run_call`'s, with fuzzed observation values, and check that its steps and answers stay within the
  effect layer's arrays, every completion step is a copy, each answer's copies sum to its length, and the call
  ends within `ERX_DMA_ROUNDS_MAX`.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device_dma.h`, `erx_dma_round_t`: the round record says by flags
  which of its outputs count (`ends` or a plan, `keeps` or `after`, answers only in a completion, `value` only at
  IDLE's end), and its `steps` and `answers` carry no capacity: each form keeps within the effect layer's arrays
  by its own bounds, which `erx_device.c` asserts at build time. Give the record its capacities, refused at the
  write, or make its output a tagged variant: an end, an observation, or a plan with its answers.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`, `erx_device_complete`: the rule that a queue not ready
  answers `ERX_ECORRUPT` has two owners, the forms' posts and `erx_device_complete` before the completion's
  round. Give it one.
* [Low] build checks, `contiguous-create-callers` (`tools/lib/erx/chokepoint_rules/stopgap_seam.rb`): the rule
  limits which files call `erx_mem_create_contiguous`, not where the range comes from, so a hand-built
  `erx_mem_dma_range_t` in `runtime_entry.c` or `dom_apply.c` would pass, and `erx_boot_dma_range` is the one
  builder by convention. Forbid the type's initialisers outside `boot_manifest.c`, the backends and the guests.
* [Low] `tools/lib/erx/chokepoint_rules/device.rb`: "no loop over device-written bytes in the NIF" and "within `erx_device.c` only `write_address` writes a ring's address register" have no check: the first holds as `erx_device_complete` copies with `bcopy` alone, the second by reading the file; a check needs a function-level site.
* [Medium] `otp/erts/emulator/nifs/erxos/erx_device.c`, `negotiate/2`: `device_features` and `queue_num_max` stay readable through `read/2` though their selectors are the NIF's, so such a read returns whichever word or queue the NIF selected last; and a driver learns the offered features and a queue's maximum only through a negotiation, so a multi-queue device (virtio-blk with `MQ`) needs two. Refuse reads of selector-banked registers and have `negotiate/2` return the offered set, or design a read-only probe.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`, `negotiate/2`: the reset is read back once, so a device that finishes its reset asynchronously gets `{error, ebusy}`; a short bounded poll would serve it.
* [Low] `otp/erts/emulator/nifs/erxos/erx_device.c`, queues: the install zeroes the rings but not the pool, so a device that reports a used length beyond what it wrote returns an earlier request's bytes of the same driver; and the whole-plan install is tested with one queue only.
* [Low] stopgap, `liberx/backend/fiasco/thread.c`: a join can return before the index and executor slot are
  free, since the clear comes before the recycle and the marker later still, so a `pthread_create` right after
  a join on a nearly full table gets a transient `ERX_ENOMEM`. musl's port would report `EAGAIN`. A recorded
  stopgap residual, not fixed.
* [Low] stopgap, `liberx/backend/fiasco/service.c`, `service_thread_reap`: only the reaper should send this
  request, and nothing checks the caller; `watchdog_thread.c` and `service.c` also share the convention of fixed
  helper slots in the kernel-given UTCB page, which one small enum could own.
* [Low] abi, `abi/erx_abi.txt`: `group_executors` and `group_executors_max` hold the same value. Keep one, and
  update whichever of `design-kernel.md` and `design-scheduler.md` then disagrees.
* [Medium] stopgap, `liberx/backend/fiasco/thread.c`, `erx_fiasco_semaphore_down`: the
  wait, which the umtx and park effects share, retries every IPC error, including permanent
  ones such as a deleted semaphore, so such a thread spins in the kernel forever rather
  than reporting it.
* [Low] stopgap, `liberx/backend/fiasco/root.ld`: nothing checks whether an orphan section
  lands past `erx_fiasco_image_end`, which `sigma0`'s map of the root's image would then
  miss.
* [Medium] tooling, the pinned host builds `tools/lib/erx/fsimg.rb`,
  `tools/lib/erx/rc_oracle.rb` and `tools/lib/erx/herd.rb` each repeat the
  same protocol: the lock record, the build record of pin and recipe,
  `locate` with its MissingBuild and StaleBuild, and `publish`. fsimg's and
  rc_oracle's `publish` lose the previous build when the final rename fails
  (two builds racing), which herd.rb's moves back. Extract one owner of the
  protocol, parameterised by source id, required files and recipe file, so a
  fix lands once. No test of the race.
* [Medium] tooling, `tools/lib/erx/oracle_guest.rb`: nothing automatic runs
  `test/host/json_input_test.rb` inside the oracle's pinned image, which hid a two-day
  break under its older `json`. The oracle's `probe` operation should exercise a
  duplicate-key refusal there.
* [Medium] tooling, `tools/lib/erx/oracle_hosted.rb`: its hosted release (tree, placeholder
  root, pack rows, `PackWire`, runtime environment) is a second copy of
  `test/integration/runtime_prim_file_test.rb`'s. Extract one hosted-release builder that both use.
* [Low] stopgap, `liberx/backend/fiasco/root.c`: a refused `erx.` word ends the boot with a fixed
  reason that names no word, though `erx_boot_args_parse` gives it in `refused`. Printing it needs
  the console's escaping function, as it is text from the boot loader.
* [Low] tests, `test/host/erx_hostlink_session_test.rb`: the EUnit run takes 295 s alone on an Apple Silicon host
  and once passed its own 600 s deadline under `make check`'s parallel load, failing the check with every case
  shown passing. Find the slow case and bound it, or give the run a deadline that fits the load.
* [Low] tests, `test/integration/runtime_prim_file_test.rb`, `test_a_changed_byte_is_refused_at_open`: it
  compares the damaged image's lines with the intact run's and drops only a supervisor report's header
  line, so the report's `supervisor:` and `offender: [{pid,...}` lines fail it whenever the two runs
  number their processes differently (seen as `<0.77.0>` and `<0.78.0>` on two runs of one tree). Drop
  or normalize the whole report.
* [Low] tests, `test/integration/runtime_hosted_smoke_test.rb`,
  `test_a_module_reloaded_in_a_loop_on_four_schedulers_never_runs_stale_code`: its 60 s wait for the
  next prompt fails at a host load average near 80. Give the wait a deadline that fits the load.
* [Low] tooling, `tools/build_site.rb`: v64's Makefile runs Closure Compiler with the `java` on PATH, and macOS's
  `/usr/bin/java` stub fails with "Unable to locate a Java Runtime" when no JDK is registered. Find Homebrew's
  `openjdk` (or take `ERX_JAVA`) and pass it to the build, failing with a diagnostic naming it.
* [Low] tooling, `make check-reproducible`: both builds of OTP and musl run at one path, so a path
  of theirs that reached the image would not show.
* [Low] stopgap, `tools/lib/erx/native_root.rb`: musl's headers are system headers to the root's compile, so a compile record leaves them out and nothing audits them for the root's objects.
* [Low] stopgap, `fiasco/l4re-core/libgcc`: the root links `libgcc.a` for `long double`'s helpers, under GPL-3.0-only WITH GCC-exception-3.1. Replace it with compiler-rt's builtins.
* [Medium] stopgap, `liberx/backend/fiasco/root.c`: the root writes no `erx_boot_info` page for a test task, though [Boot handoff](docs/design-stopgap.md#boot-handoff) says it does, and it seeds no `rng.c`.
* [Medium] tooling, `tools/lib/erx/oracle_qemu.rb`: the suites' events reach the host on the
  console's serial line, which the kernel, the root and ERTS's C output also write, at any
  byte. No process holds `erx_tty_owner`, so `display_string` writes straight to the console, and
  `liberx/backend/fiasco/console.c` hands the kernel at most 488 bytes
  (`L4_VCON_WRITE_SIZE`) per call, so another thread's write can land inside an event line
  longer than that: a stdlib run on one CPU lost a peer_SUITE case start this way. The frame's
  length and CRC-32 then reject it, its sequence number's gap shows it lost, and the run is
  read as far as it can be and reports itself incomplete; a case whose start was lost is
  unknown, and so is every run of a case either side ran more than once, since the lost start
  would number its later runs one too low. Move the events to the host
  link (`/pl011@9040000`, M4), which only the host link's own sink writes.
* [Medium] tooling, `tools/lib/erx/pack.rb`, `pack_wire.rb`: `ERX_PACK_TEST_CODE` is set only
  by `ProductionImage#build_test_image`; other packers that carry test code (`BootImage#build`
  for libc-test and the native task suites, `OracleHosted#pack`) leave it clear, since
  `test_code:` defaults to false. The by-construction fix is to derive the header bit from
  per-entry test flags in the packer (ORed into the header, checked against the entries by
  `erx_index_check`); every packer then marks its test image, and the lexical
  `test-image-builder` check (`Checks::TEST_IMAGE_BUILDERS`) can go.
* [Medium] stopgap, `tools/lib/erx/production_image.rb`: the root's link attributes `libl4sys.p.a`,
  `libsigma0.a` and the boot cores whole, under a license the recipe states, and its dependency
  files leave out Fiasco's and the compiler's headers. The boot cores are stated as BSD-2-Clause
  though the root takes BLAKE3's objects from them (BLAKE3's text is present only through the
  audit and its header). `CoreArchive::Built.objects` maps cores to objects, so per-member records
  are within reach for them; this comes before any distribution.
* [Medium] stopgap, `tools/lib/erx/pack_provenance.rb`: an `assembled` receipt binds its artifact to
  its components only by being written. The image packs `users/bin/.../sigma0` while Fiasco's audit
  reads the unstripped `OBJ-.../sigma0`, so a stale installed `sigma0` would pass. The audit should
  record the installed file and how it derives from the audited one.
* [Medium] tooling, `tools/lib/erx/production_image.rb`: the device-path check dumps unversioned `virt`
  on `cortex-a72` with two serial ports, not the `virt-11.1` machine the harness boots. Build the dump
  from `QemuPlan`'s machine and CPU.
* [Medium] stopgap, `liberx/backend/fiasco/root.c`: `root_memory_fits` is a pure decision with no
  boundary test: the 512 and 256 MiB boots do not pin its formula. It belongs in a host-built core.
* [Low] tooling, `tools/lib/erx/pack_provenance.rb`: `attribute` takes a file with no inventory row at
  the audit's word and as `permanent`, whatever the audit's status, and `resolve_fiasco` picks out
  erXos's additions by their evidence text. The audit should emit each one's status and notices.
* [Low] stopgap, `liberx/backend/fiasco/vm.c`: the pool takes all of `sigma0`'s memory and only
  checks it against `root_memory`; nothing keeps the excess for a later budget, and nothing holds a
  domain to its own budget, which is a record (docs/design-stopgap.md, "Budgets and groups as
  records"): a configured row below its domain's use is admitted and runs (a storage row of 19 MiB
  admitted a domain that used 29.8 MiB), and only a measurement such as medium_boot's Footprint shows
  it. Footprint should measure each configured domain of the development manifest as it runs, so a
  row that falls below its use fails a suite. Enforcement is erXos's kernel's (Phase 2).
* [Low] musl, `liberx/backend/fiasco/arch/aarch64/task_start.S`: a task's 256 KiB first stack lies in `.bss` with no
  guard page, so a deep test overruns its own globals, possibly `t_status`, instead of faulting.
* [Medium] tooling, `tools/lib/erx/qemu.rb`, `Transcript#consume_lines`: a serial line past 64 KiB ends the boot, and a task's `write` can
  send one with no newline, so that test reads unknown and the rest of its batch not run. Skip an overlong line instead of raising.
* [Low] console, `kernel/core/crash_frame.c`: a crash frame after a task's output with no final newline starts mid-line, so
  `tools/lib/erx/crash_frame.rb` reads it as absent; the root's `end NAME fault` line still reports the fault. Write a newline ahead of the
  frame on the console path.
* [Low] log, `kernel/core/log.c`: a task that logs past the rate with `erx_debug_log` and then exits loses the dropped count, which only
  the next admitted record shows, so its log can read as whole when it is partial.
* [Low] musl, `tools/lib/erx/libc_test.rb`: `NEEDS` also holds back tests using `sigprocmask` and `pthread_sigmask`,
  which the seam answers with no effect; and `Dependencies`'s git fetch reads the user's git configuration, which
  the pinned hash catches only as a failed fetch.
* [Low] musl, `musl/src/internal/erxos/syscall.c`: the seam includes the Fiasco backend's private headers. Move
  it behind a neutral `liberx` header when the erx backend needs musl.
* [Medium] musl, `musl/src/internal/erxos/syscall.c`: the seam includes the Fiasco backend's headers and assumes
  the root (`erx_machine_end` for `exit_group`, a handle that is an index). A task needs the launcher's status path
  and handles with generations; the next part of the port settles it with `libc-test` in a task.
* [Low] stopgap, `liberx/backend/fiasco/group.c`, `irq.c`: a task's dispatcher index is never cleared, so a task
  that named an ordinary thread its dispatcher and let it exit would have later binds made to whatever thread takes
  the index. The backend's own dispatcher never exits. A waiting bind is made only because `erx_fiasco_group_join`
  and `erx_fiasco_dispatcher_set_body`, the two writers of a row's group and dispatcher, both call
  `erx_fiasco_irq_group_ready`; one setter for both would make that hold by construction.
* [Medium] watchdog, `liberx/backend/api.h`: `erx_watchdog_pet` takes no `POWER` resource as `design-kernel.md`'s does.
* [Medium] release comparison, `test/integration/runtime_release_test.rb`: the comparison of the hosted and production archives skips unless both were built from the same sources, and no gate builds both.
* [Medium] production image, `tools/lib/erx/production_image.rb`: OTP's and musl's archives are attributed whole, though `libz`, `libzstd`, `libepcre` and `libryu` carry their own licenses. `libbeam.a`'s littlefs objects (and, in the BeamAsm flavour, asmjit's) are the one exception, by a hand-written case in `emulator_license` (`EMULATOR_ARCHIVE`) that nothing checks against the build: moving `lfs.o` out of `OS_OBJS` drops or misplaces littlefs's notice silently, and the archive is recorded `permanent` though littlefs is a stopgap. Replace the case with one table of the imports each archive holds, take each import's grant and notice from `config/provenance/import-notices.json`, and check the archive's members at pack time, as `CoreArchive::Built.objects` does for the boot cores.
* [Low] musl, `musl/src/thread/erxos/clone.c`: the start takes three liberx calls in a required order, and the
  registers travel in the UTCB. One call taking the start state and the word to clear ends the order and the leak
  a failed clear-word call would leave, with the thread package's `erx_fiasco_reaper_start` as its second user.
* [Low] musl, `musl/Makefile`: `ARCH_CPU` layering reaches `lib/libc.a` only; `crt1.o`, the dynamic linker and
  `install-headers` still name `arch/$(ARCH)` and `crt/$(ARCH)`.
* [Low] musl, `musl/arch/erxos`: `docs/design-runtime.md` deletes `__syscallN` and the `SYS_` numbers; the seam
  keeps them as the tokens of one switch, so all of musl still compiles and refuses at run time. Delete them when
  the personality has replaced what they name.
* [Low] musl, `musl/src/misc/uname.c`: `uname(3)` reaches the seam as `SYS_uname`, which answers `ENOSYS`.
  It should fill `struct utsname` from `erx/abi.h`'s `ERX_UNAME_SYSNAME_STRING`, `ERX_UNAME_RELEASE_STRING` and
  `ERX_ARCH_MACHINE_STRING`, and the node name from the host part of the boot information's node name, which the shell's `uname`
  (`erlang/apps/erx_shell/src/erx_cmd_uname.erl`) reads as init's `-sname` or `-name`, with no value of its own; `docs/design-shell.md`, "Text commands".
* [Low] musl, `tools/lib/erx/native_musl.rb`: binary128 arithmetic comes from Fiasco's `libgcc.a`, built by GCC.
  Replace it with compiler-rt's builtins, the dependency table's row, with the rest of the BeamAsm image's runtime.
* [Low] musl, `musl/src/malloc/mallocng/glue.h`: `AT_RANDOM` is absent, so mallocng's secret comes from an address alone; `erx_entropy_read`
  can supply its 16 bytes at program start.
* [Medium] musl, `musl/src/thread/erxos/pthread_create_executor.c`, `musl/src/internal/erxos/syscall.c`: only the boot covers them. `test/guest/native_musl` needs the hosted
  driver's cases (no attribute, no free slot, the slot given back at exit).
* [Low] `otp/erts/emulator/sys/erxos/sys.c`, `beam/erl_process.c`, `beam/erl_driver.h`: what signals' deletion leaves unused: the break flag and `erts_do_break_handling`, `thr_create_sigmask`,
  the Darwin steal declarations, and the `ERTS_SYS_SUSPEND_SIGNAL` and `ERTS_HAVE_TRY_CATCH` blocks.
* [Low] `otp/erts/emulator/sys/erxos/sys.c`: on hosted a write to a closed pipe now ends the process with `SIGPIPE`, and a crash dump has no time limit; a dump says it could not read a process's stack, where it did not try.
* [Low] tooling, `tools/lib/erx/qemu.rb`'s `machine_end` cannot tell a power-off
  from a reset under `-no-reboot`, and ignores lines after the last checkpoint.
  Settle both with the `erx_machine_end` case.
* [Medium] tooling, `tools/lib/erx/qemu.rb`, `Qemu#run`: QEMU stopped by a signal from outside the run exits 0, so it is
  checked for only when the transcript is incomplete. With `machine_end:` a signal after the transcript is whole reads as a
  pass, and a stopped run raises a plain `Erx::Error`, which `OracleQemu.state_of` counts as an erXos crash instead of an
  unknown result. Check `SIGNAL_STOP_LINE` whenever QEMU exited by itself, and raise a subclass that reports read `cancelled`.
* [Medium] manifest, `tools/lib/erx/manifest.rb` (`device_clock`), `liberx/backend/core/boot_manifest.c`,
  `liberx/system/dom_boot_view.c`: "only a PL011 row carries a clock" is a rule on one compatible string, checked
  only by the Ruby manifest check; the C readers pass any 32-bit clock through, so a PL011 row with clock 0 is
  refused only when `erx_pl011` starts, and a clock below what `erx_pl011:baud_divisors/1` accepts (about
  1.83 MHz for 115200 baud) passes the build. Make "its driver reads a clock" a property of the device kind
  (`include/erx/device_kinds.h`'s table), read by the Ruby check, the C readers and `device_path_problems`,
  and check the divisor bound at build time.
* [Low] tooling, `tools/lib/erx/production_image.rb` (`device_path_problems`): the check of a platform record
  against a device tree reads QEMU virt's tree shape only, and runs only in the production image suite's
  device-path step, so a wrong `ram_first` or PL011 clock in a Raspberry Pi record is never checked against
  the board's tree. Pi package 3 writes `config.txt`'s `init_uart_clock` from the record; check the Pi's
  record against its device tree (nodes under `/soc`, the firmware's clocks) there.
* [Medium] tooling, `tools/lib/erx/fiasco_provenance.rb` (`image_objects`, `MAPS`): the provenance audit
  covers the main build's bootstrap only and skips `build/fiasco/users-*`, so the Raspberry Pi 4's bootstrap
  (`Fiasco#build_board_bootstrap`) and the 16550 and BCM2835 UART drivers it links have no build record. Make the
  audit take a users directory and run it once per bootstrap build, its object lookup scoped to that directory.
* [Low] tooling, the Raspberry Pi 4's medium (`BootPartition.boot_partition_medium?`, `Fiasco::BOARD_BOOTSTRAPS`,
  `BoardTree::BOARDS`, `QemuPlan::MACHINES`, `BootPartition::OVERLAY_PINS`): a board's facts sit in four tables keyed
  by platform name, and the medium is chosen by membership of one of them, so a board added to the others but not to
  `BoardTree::BOARDS` gets QEMU's release medium. Declare the medium, the load address and the board's tree in the
  platform record, checked when it loads, so a board without a medium is refused.
* [Low] tooling, `tools/erx pack` and the raspi4b suite share `build/production-image/raspi4b/`, cleared before
  each build: a suite run replaces the card last packed, two packs of one platform at once remove each other's
  files, and a failed pack leaves the directory partial. Build into a sibling directory and rename it into place.
* [Medium] liberx, the console handoff (`erx_fiasco_task_mem_physical_body`, `erx_boot_console_page`):
  the root hands the log to the console at the first physical object it creates at the console's
  page, whoever the object is for. On the Raspberry Pi 4 that page also holds the auxiliary SPI
  controllers, so a root-side driver or given record of an SPI there would hand the log over before
  the console starts. Tie the handoff to the console itself (its first `erx_log_take`, or a role its
  driver's open names) rather than to an address: [design-stopgap.md](docs/design-stopgap.md#the-console) ties it to
  the console's first take, which `erx_console` makes before it starts its driver.
* [Medium] erx_uart, `erx_pl011:console_uart/1` and `erx_mini_uart:console_uart/1`: the parse of
  `-erx console_uart` is copied in each driver, as are their fuzz targets. One parse of the four
  numbers, with each driver checking only its clock rule, and one fuzz target.
* [Medium] QEMU harness, `QemuPlan::MACHINES['raspi4b']` (`tools/lib/erx/qemu.rb`): the loader's
  addresses for BL31 (0) and the bootable file (0x200000) are not checked against the builds that
  fix them (TF-A's BL31 base, bootstrap's `DEFAULT_RELOC_arm64-arm_gen`); a change there hangs the
  model's boot with no diagnostic. Check them in `Raspi4bShell#build_inputs`, or derive them.
* [Low] erx_uart, `erx_mini_uart` and `erx_pl011`: one drain reads while the receive FIFO says it
  holds a byte, with no bound, so a wedged device grows the binary until the system domain runs out of
  memory; and `erx_mini_uart` does not check LCR.DLAB, with which its IER writes would change the
  divisor. Cap a drain at a few FIFO depths and refuse to start with DLAB set.
* [Low] production image, `ProductionImage#catalog`: the build record lists Fiasco's QEMU virt
  bootstrap even when the image's first stage is the board's (`Fiasco#first_stage_path`), and a build
  packs whatever board bootstrap is on disk.
* [Medium] Pi package 5 (docs/plan.md, 1b-I (a) 5), the board pass, the framebuffer
  (`liberx/backend/fiasco/runtime_entry.c`, `framebuffer_give`): unverified is whether sigma0 grants the
  VideoCore's memory, the `framebuffer` row's window in `config/platforms/raspi4b.json`, as I/O memory, which
  `erx_mem_create_physical` needs; if not, the root stops with "the backend refused the framebuffer's pages".
  The board's console shows the root's line: `framebuffer WxH STRIDE FORMAT`, or `framebuffer absent outside
  BASE SIZE`, which says where the firmware put the framebuffer, so the row's window is moved over it.
* [Medium] the display driver over the root's framebuffer record (`liberx/backend/fiasco/runtime_entry.c`,
  `framebuffer_give`, and its future Erlang driver): the framebuffer's object is device memory
  (`ERX_MEM_ATTR_DEVICE`). Unverified against the Arm Architecture Reference Manual: that an unaligned access or
  `DC ZVA` to device memory faults, so a `memset`, `memcpy` or the compiler's zeroing of a mapped framebuffer may
  fault where normal memory would not. Read the manual's device-memory rules before the driver writes to the
  mapping, and keep its bulk copies aligned or map the framebuffer as normal non-cacheable memory
  ([todo-performance.md](docs/todo-performance.md), the framebuffer mapped as device memory).
* [Medium] the framebuffer record's target paths (`liberx/system/dom_apply.c`, `apply_given_words` and
  `apply_unrecorded`; `liberx/backend/fiasco/runtime_entry.c`, `gather_args`, `framebuffer_facts`,
  `framebuffer_give`): only the pure core and the view are host-tested, and no shipped manifest gives a framebuffer
  to a configured domain. A check that a configured holder's boot page carries one `-erx framebuffer` record with a
  non-null handle for a placed framebuffer and none for an unplaced one would catch a dropped skip or a wrong
  installed index.
* [Low] the framebuffer format names exist in three hand copies (`kernel/core/dt.c`'s table,
  `erx_device_record.erl` `format/1`, the record fuzz target's `?FORMATS`), and `ERX_BOOT_FORMAT_WORD_MAX`
  (`include/erx/boot_words.h`) is sized by hand to the longest: a new or longer name makes the Erlang reader refuse
  every record, or the root print no line at all for an OK framebuffer. Check every `erx_dt_fb_format_name` against
  both in a host test, or generate them from one source, and print a fixed reason when an OK framebuffer has no
  usable format.
* [Low] `liberx/backend/core/boot_manifest.h`, `erx_boot_device_t`: `given` and `framebuffer` are two bools for
  one closed kind (physical, given, framebuffer), so `given && framebuffer` is representable and a consumer that
  forgets the framebuffer case reads a NULL `role`. One enum switched on exhaustively.
* [Low] `liberx/backend/core/boot_manifest.c`, `line_shared`: a framebuffer row is a device-tree row whose line
  field is 0 though it has no line, so a device of another row whose line is 0 is marked shared. Skip framebuffer
  rows.
* [Low] `erlang/apps/erx/src/erx_device_record.erl`, the `-erx framebuffer` reader: it accepts an OFFSET of a
  page or more, which the root never writes; refuse it, and teach the fuzz reference
  (`test/erlang/erx_device_record_fuzz.erl`) the same bound.
* [Low] [design-display.md](docs/design-display.md): the display design never names the root's `-erx
  framebuffer` record ([design-device-tree.md](docs/design-device-tree.md), "Facts into records"), from which a
  framebuffer domain's driver learns its framebuffer.
* [Low] Pi board pass, the storage domain's `sd` unit (docs/design-storage.md, "The SD controller's line"): no
  driver quiets the legacy SD controller `/soc/mmc@7e300000`, which shares EMMC2's line 158, so if the firmware
  leaves its interrupts enabled and it asserts the line, EMMC2's line owner is woken on every delivery. Check on
  the board that the line is quiet with EMMC2 idle; if not, the design must say who quiets the legacy controller.
* [Low] Pi board pass, the device tree's address (`tools/lib/erx/boot_partition.rb`, `config_txt`): the card's
  `config.txt` sets `kernel_address` from the QEMU harness's loads but no tree address, so the firmware chooses
  where it loads the tree and writes that address into BL31's stub header. Where it chooses for a development
  image of about 48 MB at `0x200000` is unverified; the QEMU harness loads the tree at `0x8000000`
  (`tools/lib/erx/qemu.rb`) because at `0x3000000` the image reached it. Read the address on the board (BL31's
  `Changed device tree` line, or `x0` at bootstrap's entry) and check it lies past the image's end; if it does
  not, pin it in `config.txt` to the harness's address, after checking in Raspberry Pi's `config.txt`
  documentation which setting does that.
* [Medium] domain library, a device of no kind (`liberx/system/dom_life.c`, `erx_dom_plan_device_give`;
  docs/design-shared-devices.md, "The unit rule"): that such a device gets no window, DMA window or memory rests
  on `driven` guards in the planner, and `erx_dom_device_check` cannot tell an unrecorded give from a driven one,
  so a new object kind that forgets the guard is installed. Carry the device's kind in `erx_dom_device_plan_t` and
  have the check refuse window, DMA, memory and kept installs on a give of no kind, so the plan validator enforces
  it; `apply_args` would then read the same flag. Simpler still: make a line's IRQ object in the first driven
  give that names it (`life_line_source` searching driven gives only), so a give of no kind makes only its
  resource, `life_line_driven` goes away and the check's rule is one line. Today a kindless give first on a line
  makes the object, which rests on `life_line_driven` answering alike for every device on a (unit, line) and only
  `dom_give_lines_ok` catches a disagreement; the change moves the native_domain `case_given` assertion that the
  kindless device 0 holds the line's object, and needs checking that an IRQ object made from the driven device's
  resource serves the line on Fiasco.
* [Low] domain library, PCIe functions on a configured row (`liberx/system/dom_boot_view.c`, `boot_devices`): only
  device-tree selectors get a role word and peripheral, so a PCIe function placed on a configured row would be of
  no kind and get no record, window or memory. No manifest places one; give the kind test a PCIe arm first.
* [Low] QEMU harness, `Raspi4bShell#check_loads` (`tools/lib/erx/raspi4b_shell.rb`): it refuses an image that
  reaches the tree, but the native root is linked at 64 MiB (`NativeRoot::DEVELOPMENT_ROOT_MIB`), so an image past
  about 62 MiB fails only at boot, in bootstrap's `place_overlap`. Refuse an image that reaches the root's place.
* [Low] Pi package 5 (docs/plan.md, 1b-I (a) 5), the board pass: confirm on silicon that the mini
  UART's receive interrupt needs IER's `RX_ERRATA` bits (`hw/svd/mini_uart/mini_uart.svd`), which
  `erx_mini_uart` sets as the BCM2835 errata asks and QEMU's model ignores, and drop them if not.
* [Medium] SD host controller, `hw/svd/sdhci/sdhci.svd` (docs/design-storage.md, "The SD host controller"), unnamed
  bits: the file names only the bits FreeBSD's `sdhci.h` names, so `write_field/4` writes every other bit of a word
  back as zero. In `CONTROL0` that is the block gap control byte, whose stop at block gap and continue requests
  the device NIF always owns: a driver's field write to `CONTROL0` clears them. The file also shows the four
  fields the NIF owns ([design-device-dma.md](docs/design-device-dma.md), "Register ownership"), `CONTROL0`'s
  `DMA_SELECT` and `CONTROL2`'s `ADMA2_LENGTH_MODE`, `HOST_V4_ENABLE` and `ADDRESSING_64BIT`, as plain fields,
  since the generator has no field mark (the field-ownership item). Programmed I/O sets none of them; the
  field marks, or the ADMA2 mode's design, settle how the driver changes these words.
* [Medium] GENET, `hw/svd/genet/genet.svd` (docs/plan.md, 1b-I (c)), unnamed bits: the file names
  only the bits FreeBSD's `if_genetreg.h` names. `write/3` refuses a word with any other bit set, and
  `write_field/4` writes every other bit back as zero, while FreeBSD reads, modifies and writes back
  `UMAC_CMD`, `EXT_RGMII_OOB_CTRL`, `RBUF_CTRL`, `RBUF_CHECK_CTRL`, `SYS_RBUF_FLUSH_CTRL` and
  `TBUF_CTRL` whole, keeping them. The transport, `erx_genet`, writes them by named fields
  (`erx_genet_core`), so it clears every unnamed bit of each where FreeBSD keeps its reset value;
  `UMAC_CMD` alone is written 0 first by both. The board pass reads each register's reset value,
  and the file gains the bits that turn out to be set.
* [Low] GENET, Erlang cores (`erx_mdio`, `erx_genet_rx`): both pack bits `genet.svd` names, the MDIO
  command word's fields and the receive status's flags, by hand, since the hardware generator
  (`tools/lib/erx/hardware.rb`) emits C alone. An Erlang header of each SVD's field offsets and widths
  from that generator would let both take their definitions from the source.
* [Medium] GENET, the bound on its DMA writes: the device NIF owns the descriptors and ring
  registers, but the frame length limit, the status block, the two-byte alignment and the burst
  sizes stay the driver's. The board pass confirms that a ring's buffer size bounds every byte the
  controller writes per descriptor whatever those say; if not, the NIF owns them too.
* [Medium] GENET, `hw/svd/genet/genet.svd`, `RX_DMA_STATUS` and `TX_DMA_STATUS` (`0x1048` past each
  direction's base), which the register ring's reset reads for its idle report: FreeBSD's
  `if_genetreg.h` does not name them, so their definition comes from the clean-room facts record
  alone (docs/research-genet-bcm2711.md, "The DMA status register"), its ring bit inferred. A source
  that is not Linux's driver would confirm them; the board pass reads them in any case.
* [Low] GENET, `test/fixtures/erx_device_genet_model_harness.c`, test gaps in the register ring's core:
  no case fills the receive ring to exactly 256, runs the 16-bit indexes past 0xffff, or has good
  frames before a too-long one; the stand-in's DMA status sets every ring bit at once, so a core that
  ignored ring 16's bit would pass; and `erx_device_genet_registers` keeps its names, `found[]` and
  `ring[]` in step by position, which one table of names and field offsets would replace.
* [Low] GENET, facts the board pass settles: the transmit length's width (`__BITS(27,16)` against
  the mask `0x7ff0000`, neither compiled by FreeBSD; until settled the transport sends less than
  2048 bytes per descriptor), what receive status bit 15 means, the interrupt mask registers'
  sense (FreeBSD writes all ones to set-mask and then to clear-mask to disable them), and whether
  the firmware leaves GENET's DMA stopped when the Pi netboots, since no domain resets a GENET no
  manifest places. The PHY's MDIO address, 1, and its RGMII mode are in no record; `erx_genet`
  holds them as constants, which the board pass confirms. Also: whether the UniMAC accepts its
  software reset when local loopback is set by one write before it (FreeBSD sets both in one
  write), whether short frames are padded to 60 bytes by the controller, and that the PHY answers
  at that address with the BCM54213PE's ID.
* [Low] liberx, `liberx/backend/fiasco/vm.h`, `vm.c`, `thread.c`: the backend's fixed addresses
  (`ERX_FIASCO_KIP_WINDOW`, the device window, the UTCB area, the VM window, the area start) are spread over
  three files, and only the KIP window's place below the device window is asserted. Gather them in one layout
  header with static asserts of their order.
* [Low] tooling, the native harnesses' `MEMORY_MIB = 512`, `tools/lib/erx/medium_boot.rb` (the block
  device's window, `virt.dtb`, the `qemu-virt/development` patterns), `tools/lib/erx/qemu.rb` (`cortex-a76`,
  the virtio-mmio bus arguments) and `ProductionImage::Run#check_device_paths` (`-cpu cortex-a72`) still hold
  QEMU virt's values. QEMU's `raspi4b` takes only its own 2 GiB and has no virtio-mmio; move each into the
  platform record or `QemuPlan::MACHINES` when Pi package 4 runs a suite on the model.
* [Low] tooling, `tools/lib/erx/native_root.rb` (`build_system_receipted`): the
  root's linked receipt does not name its place, the `--defsym` of
  `erx_fiasco_image_start` that `place_flags` adds; only the link map it binds
  by hash shows it. Record it, which needs a field in `PackProvenance`'s
  `linked` schema (`exact_keys`), or bind the place as a link input.
* [Medium] kernel, `kernel/core/debug_log.c` keeps the ring and its console
  buffers in file statics, and `tools/fuzz/dispatch_fuzz.c` a static UTCB and
  rate, so a fuzz crash can depend on earlier inputs. Make the log an object
  `erx_sys_caller_t` points to.
* [Low] stopgap, `liberx/backend/fiasco/service_task.c`: no test shows that a failed create of the console UART leaves the debug log on the line, and the native console suite counts no `l4_vcon_write` of a log record after the handoff; only the host core test counts console writes. A boot whose first create of the console window fails, and a counter the root prints at its end, would close the "Console handoff" row of `docs/design-stopgap.md`.
* [Medium] kernel design, `docs/design-kernel.md`, "Console, log and panic": the early console writes every record until the console driver carves the UART, but the design does not say how the log service's console and the early console share one position, so nothing keeps the console from printing a boot line again or missing one. On the stopgap the console's read is the drain: `erx_log_take` (`liberx/backend/api.h`) copies from the one position of what has been taken, which the early console moves as it writes, and moves it, while every other reader uses `erx_log_read` from a cursor of its own. Add the take to the section and its call table, and to `docs/design-live.md`, "Log lines and program output", which has `erx_console` read with `erx_log_read`.
* [Medium] stopgap, `liberx/backend/fiasco/service.c` `service_log_read`, `service_log_take`: no test shows that a task's `log_read` or `log_take` is refused with `ERX_ENOTSUP`; that check alone keeps a task from having the service write log bytes at an address of the root. Add the case to `test/guest/native_task/program.c` beside `task_write`'s refusals.
* [Medium] chokepoint, `erlang/apps/erx/src/erx_log.erl` `take/0`: only `erx_console` takes the kernel log (`docs/design-stopgap.md`, "The console"), but no build check says so, and any root process can call `erx_log:take()`; a second caller takes lines from the console for good, and no loss is counted. Add a check in the manner of `tools/lib/erx/device_callers.rb` that refuses `erx_log:take` outside `erlang/apps/erx/src/erx_console.erl`, and a C rule that keeps `erx_log_take` and `erx_debug_log_take` to the NIF, the two backends and the core, each with a seeded violation.
* [Low] runtime, `erlang/apps/erx/src/erx_console.erl`: the console takes one window of the kernel log per `LOG_POLL_MS`, so a burst it is still catching up on can be overwritten and cost a "records lost" line though the records were in the ring when the burst began. Take again at once while a take fills its window.
* [Low] runtime, `erx_log_nif.c` `read_lines`: a record that fails the reader's checks ends the window, and the console's line says so without saying how many records after it were dropped.
* [Low] stopgap, `liberx/backend/fiasco/end.c`: the watchdog's end skips the debug log's parked records, as the service may be mid-write, so a missed pet after the console handoff loses the records the console had not read. At any end, lines the console has read but its driver has not yet written are lost uncounted, and the end's own drain can interleave with the driver's bytes on the UART.
* [Low] stopgap, `tools/lib/erx/glue_imports.rb` reads what the compiler left
  out of line: a change of inlining can move a symbol such as
  `_ZN13Irq_chip_soft7sw_chipE` on or off the list and fail the build.
* [Medium] stopgap, the debug-log probe's report: `tools/erx check-debug-log`
  compares its own transcript, because the conformance guest's protocol
  needs lines that start with `erx-test:`, and a program's only output here
  is a log record with the kernel's prefix. `debug_log.statuses` stays `pending` in the
  roster until the conformance guest can report.
* [Medium] display, LVGL renderer: replace LVGL on panels with the Erlang
  renderer once the parity test passes and the Erlang renderer's frame
  times match LVGL's on a 240x240 panel
  ([design-display.md](docs/design-display.md#dependencies)).
* [Low] stopgap, the host link's boot word: the host link is opt-in through
  `erx.hostlink=1` (`liberx/backend/fiasco/boot_args.c`,
  `liberx/backend/core/boot_manifest.c`), because the root takes the host
  link's UART from the manifest's device-tree path without looking for it in
  the device tree, and a record for a UART the machine lacks faults the system
  domain at the driver's first read. The word goes once erXos's kernel finds
  the UART in the device tree and the root hands the record only for a UART
  that is there ([design-stopgap.md](docs/design-stopgap.md#the-command-line)).
* [Medium] network, `erx_net_admit` ([design-network-stack.md](docs/design-network-stack.md#the-grants-contract)):
  the admission path of grants and sockets is hand-written, with the
  generated module's exact signature, until the schema generator over
  `abi/services` exists; replace it with the module generated from
  `abi/services/net.txt` then. Until a network grant is an `erx_facet`, a grant on a host
  runs under `erx_net_local`'s loop.

## Bugs by subsystem

* [Medium] `erlang/apps/erx_display/src/erx_winfs.erl`: `start_link/1` given a service starts the single policy with an
  empty configuration; the window policy and its chord come from the display domain's manifest entry
  ([design-display.md](docs/design-display.md#windows-and-the-window-system)).
* [Medium] `erx_fs` and `erx_window` (`erlang/apps/erx_files/src/erx_fs.erl`): a waiting `mouse` or `kbd` read cannot
  be cancelled by the client's flush, since `erx_fs` has no helper mode, so the file's owner blocks and the flush
  waits; a client reading `kbd` on a hidden window hangs. design-display.md says these reads are helper-mode reads that
  wait for a record.
* [Medium] `erlang/apps/erx_display/src/erx_window.erl`: a `wctl` read answers at once; design-display.md ("The window
  tree") says it waits for a record.
* [Medium] `erlang/apps/erx_display/src/erx_window.erl`: held `ctl` writes and `mouse` and `kbd` readers are bounded
  only by `erx_fs`'s one request per open file; give them a cap of their own.
* [Low] `erlang/apps/erx_files/src/erx_fs_grants.erl`: the per-grant `Args` (`start_link/2`, `grant/4`) are not named by
  design-files.md; name them there or fold them into the grant's options.
* [Low] `erlang/apps/erx_display/src/erx_winfs.erl`: `/snarf` is not served, and the mint reads no `snarf` limit.
* [Low] `erlang/apps/erx_display/src/erx_window.erl`: `kbd` gives only `c` records; `k` and `K` are not produced.
* [Low] `erlang/apps/erx_display/src/erx_winfs.erl`: the window table carries no label, so a decorating policy cannot
  see it.
* [Low] `erlang/apps/erx_display/src/erx_screen.erl`: a present the core refuses (a rectangle past the coordinate limit
  once the window's origin is added) is answered ok and shows nothing.
* [Low] `erlang/apps/erx_display/src/erx_winfs.erl`: `readdir` offsets are positions, so an `rmdir` between reads can
  skip a window.
* [Low] `abi/protocols/9p.txt`: `error edquot 122` follows 9P2000.L and musl; check the POSIX layer's mapping if it
  follows FreeBSD's numbering (69).

* [Medium] programs, `PROT_EXEC` in a program's `mmap` or `mprotect` (`musl/src/internal/erxos/syscall.c`, `mmap_call`
  and `mprotect_call`; `liberx/backend/fiasco/program_task.c`, `erx_fiasco_libc_fd`): design-programs.md, "The
  POSIX-lite personality", says it fails with `ENOTSUP`, since only the loader maps code, but the descriptor seam takes
  only descriptor mmaps, `munmap` and the range check of `MAP_FIXED`, so an anonymous mapping or a protection change of
  anonymous memory reaches musl's own rows, which refuse only write and execute together (a protection change that
  meets a mapping, the window buffer's included, is refused by `liberx/backend/core/vm_table.c` already). Have the
  program's seam refuse `PROT_EXEC` in both with `ENOTSUP`, with a check in the programs suite's `args` program.
* [Medium] programs, `erx-lvgl` on the target (`display/lvgl/erx_lvgl.c`, built by `tools/lib/erx/lvgl.rb`,
  `Lvgl::Program`) needs two libc calls a program's seam does not offer: `poll(2)`, which musl makes `ppoll` and
  `erx_fiasco_libc_fd` (`liberx/backend/fiasco/program_task.c`) answers `ENOSYS`, so the program's first wait on
  standard input ends it with status 1; and `signal(SIGPIPE, SIG_IGN)`, whose `rt_sigaction` musl's switch
  (`musl/src/internal/erxos/syscall.c`) has no row for, answering `ENOSYS`, which the program ignores. With
  `erx_program:start/1` taking only a `mem` descriptor, it has no standard input or output pipe either, so the
  programs suite's `lvgl` case (`tools/lib/erx/programs.rb`) checks only that it reaches main's map of descriptor 3.
  When pipes reach programs and `ppoll` reaches the table, have the case give it a buffer and pipes and see it wait
  for the screen record.
* [Medium] programs, the descriptor seam offers a listed set of calls (`musl/src/internal/erxos/syscall.c`,
  `seam_offered`, and `liberx/backend/fiasco/program_task.c`, `erx_fiasco_libc_fd`, two lists that must agree):
  design-programs.md, "The POSIX-lite personality", says every call that names a descriptor reaches the table, but
  `dup`, `fsync`, `fdatasync`, `ftruncate`, `getdents64`, `preadv`, `pwritev`, `fchmod`, `fchown`, `fstatfs`,
  `flock` and the `*at` calls with a directory descriptor reach musl's default, `ENOSYS`, not `EBADF`. It fails
  safe: none reaches the console or the kernel. Make it hold by construction: offer the seam every call, the
  non-program seams answering false as they do, and have the program's seam hand back one closed list of calls that
  name no descriptor.
* [Low] programs, `writev` through the seam (`liberx/backend/fiasco/program_task.c`, `vector_call`) writes each entry
  separately, so entries that sum to at most `PIPE_BUF` are not one atomic write against another writer of the same
  pipe; gather them into one pipe write. `lseek` ignores `whence` and `ioctl` its request (`liberx/program/fd.c`), so
  a bad `whence` answers 0 and `FIONBIO` on a pipe answers `ENOTTY`.
* [Medium] device-tree reader, split DMA translations (`kernel/core/dt.c`, `range_read`): a translation written as
  several adjacent `dma-ranges` entries, as a full 32-bit identity map under a one-cell `#size-cells` must be,
  leaves several windows with RAM behind them, and the device gets `ranges` (no DMA range). It fails safe. Merge
  windows contiguous in both bus and CPU addresses before the RAM filter, with the design's "exactly one window"
  rule read after the merge. No tree of the manifests' devices does this.
* [Low] libfdt, a version 2 header read past (`fiasco/libfdt/lib/contrib/fdt.c:139-142`, `fdt_check_header`):
  the strings block's size, which version 3 added, is read and checked whatever the header's version, so
  `fdt_check_full` on a 32-byte buffer claiming version 2 reads 4 bytes past it (found by `dt_fuzz`).
  `erx_dt_accept` refuses a buffer shorter than the version 17 header first. Check the field only from version 3,
  in this copy and in Fiasco's `fiasco/kernel/src/lib/libfdt`.
* [Low] device-tree reader, duplicate sibling names (`kernel/core/dt.c`, `node_find`): `fdt_check_full` does not
  refuse two siblings of one name, and `fdt_path_offset_namelen` takes the first, so a tree the reader could see
  is wrong gives the first node's facts. Refuse a path that matches two nodes. The firmware is trusted.
* [Low] device-tree reader linked into no target (`tools/lib/erx/core_archive.rb`, `ROOT_TASK_SOURCES`): only the
  host tests and the fuzz target compile `kernel/core/dt.c`; the root task links it with the package that hands
  the tree over, and a target-only build break surfaces only then.

* [Medium] release slice, an empty `/data` (`include/erx/release_fs.h`, `liberx/release_fs.c`, `liberx/release.c`,
  `tools/lib/erx/pack.rb`, `tools/lib/erx/release_files.rb`): a domain the manifest grants no `data` facet has
  no `/data` mount and should find the root's empty, read-only `/data` directory there (design-files.md, "A
  facet's mount"), but the release slice cannot hold an empty directory: a directory is one only when some file
  path is below it, and a pack entry is a file or an image. So `/data` answers `enoent` and `ls /` does not show
  it. Give the pack index an entry kind for an empty directory (no data, prefix of no other path, which the open
  check already refuses), have the release file system's walk, lookup and listing answer it as a directory,
  extend the boot-image fuzz target and its corpus, and have the release write `system/data`.
* [Medium] network, Pi 4 Ethernet MDIO (`erlang/apps/erx_net/erxos/erx_mdio.erl`): `poll/3` decides
  each poll of the command register, up to 1,000 polls 10 us apart as FreeBSD does (`if_genet.c:1669,
  1684-1692`), but an Erlang timer cannot sleep 10 us, so `erx_genet` spins on the monotonic clock between
  polls, holding its scheduler for at most the bound, 10 ms, per operation: a link poll each second makes
  two or three. Measure it on the board; if it shows, run the loop in the device NIF, as the SD
  controller's command register is.
* [Low] network, Pi 4 Ethernet PHY (`erlang/apps/erx_net/erxos/erx_phy_c22.erl`): autonegotiation is
  started once after the reset and never restarted, where FreeBSD restarts it while no link comes up
  (`brgphy.c:356-383`), so a negotiation that sticks leaves the link down until the driver restarts.
  Restart it every few link polls without a link if the board shows a stuck negotiation.
* [Medium] hosted runtime test, network rows (`test/integration/runtime_hosted_smoke_test.rb`,
  `test_init_runs_from_the_archive_alone`): the rows `gen_tcp:listen(0, [])` (expects `{error,enotsup}`) and
  `gen_udp:open(0, [])` (expects an `erx_gen_udp` socket) assume the system release ships `erx_net`, but it has
  not since the stack left the system domain (`ReleaseFiles::SYSTEM_APPLICATIONS`), so the first answers `undefined
  function erx_gen_tcp:listen/2` and the test fails; `erx_gen_tcp` also exports `listen/2` now. Decide what
  gen_tcp and gen_udp answer in a domain that ships no network code (an undefined-function exception is no
  answer a caller can handle) and pin that, and move the backend rows to a domain that holds the network.
* [Medium] manifest fuzz harness (`tools/fuzz/manifest_fuzz.c`, `tools/fuzz/manifest_verdicts.c`): `view_build`
  runs `view_check` only when the domain library admits the manifest, and a refusal is silent, so the library
  refusing a valid seed (the development manifest) leaves the target and `test/host/manifest_fuzz_test.rb` passing
  with nothing checked. Print whether the library viewed each accepted manifest (`ok viewed`, `ok refused REASON`;
  `erx_manifest.rb` compares only the first word) and require `viewed` for the valid seeds.
* [Low] host tests, EUnit runs (`test/host/*_test.rb`): each test file starts `erl` for `eunit:test` on its
  own, and a logger report a case provokes can split EUnit's verbose line for that case on standard output.
  `erx_inspector_test.rb` sends the logger to standard error and matches verdicts on standard output alone;
  `erx_fs_test.rb` and `erx_ramfs_test.rb` silence the logger instead; the rest do neither. Give the host
  tests one EUnit runner that keeps the logger on standard error and returns the two streams apart, and move
  every suite onto it.
* [Low] ABI generator, frame profiles (`tools/lib/erx/abi_profile.rb`, `include/erx/profile.h`): the C
  check's bounds on depth and totals are written in both files, tied only by the generated table's static
  asserts, and the 64-key bound of a map or union (`ERX_PROFILE_KEYS_MAX`) has no model rule, so a protocol
  past it fails as a C compile error rather than at its declaration. Give the bounds one source and add the
  keys rule to the model.
* [Low] tests, `test/fixtures/prog_profile_mutations.rb`: the rule helpers pass `[rule, value, reason]`
  triples and `places` passes `[kind, value, path]` triples; name them with `Data.define`.
* [Low] ERTS start-up (`otp/erts/emulator/beam/erl_process.c`, the "hold executor slots" line): the scheduler
  count follows the manifest's CPU set, not the CPUs present. The system domain and the storage domain report
  4 schedulers on the website's 1-core v64 machine. Size them from the CPUs the kernel reports present.
* [Low] upstream, BeamAsm (`otp/erts/emulator/beam/jit/arm/ops.tab`, `jit/x86/ops.tab`): stock OTP 29.1.2's JIT
  turns the small-integer half of a `select_val` that also matches a bignum into a jump table whose gaps branch to
  the NIL immediate, so a small integer in a gap kills the emulator (SIGBUS on AArch64). erXos's copy gives such a
  select a search instead. `beam_SUITE:select_val_mixed/1` is skipped on stock's JIT, and the generator of
  `erx_prog:status/1` (`tools/lib/erx/abi_emit_erlang.rb`) keeps its signal clauses in a function of their own,
  since the host tests run that module on stock. Report it upstream.
* [Low] upstream, ERTS signals (`otp/erts/emulator/beam/erl_bif_info.c`, `is_process_alive_1`): a
  process monitor is held as its scheduler's pending signal until the monitoring process sends
  that target another signal, creates another process monitor or is scheduled out
  (`proc_queue_signal` in `erl_proc_sig_queue.c`), and `is_process_alive/1`'s fast path answers
  without sending it. `erlang:monitor(process, P)` followed by `is_process_alive(P)` can answer
  `true` and the monitor then report `noproc`, against the guarantee `is_process_alive/1`
  documents (every earlier signal from the caller reaches P before the check); seen on the stock
  OTP 29.1.2 oracle build. When the caller's pending signal is to P, take the trap path or send
  it first (`erts_proc_sig_send_pending`), and report it upstream.
* [Low] tests, EUnit cases under `test/erlang/` of this shape: after `monitor(process, P)` the
  case sends a third process a message or exit signal, with no signal to P, no other monitor and
  no blocking receive between, and then asserts P's exit reason. As in `erx_hostlink_tests`, P
  can end before the held monitor reaches it, and the case sees `noproc`. Candidates:
  `erx_console_master_tests.erl` (around line 330), `erx_domain_tests.erl` (around lines 179
  and 338). Wait for the monitor first, as `erx_hostlink_tests:monitor_in_effect/1` does; move
  that helper to a shared test module if more than one module needs it.
* [Low] tooling, `tools/lib/erx/erlang_apps.rb` (`check_modules`): an application's `.app.src`
  module list is compared with its `src/` only when a release is built, so `make check` passes a
  module added without its `.app.src` entry and every QEMU suite and `make check-boot-image`
  then fail. Run the same comparison for every application in `make check`, without building.
* [Medium] runtime, `otp/erts/emulator/sys/common/erl_mseg.c` (`mseg_alloc`): when the budget
  refuses the commit behind a new carrier, `mseg_alloc` fails without emptying the segment
  caches, so a domain near its budget can be refused a carrier while its own freed carriers
  (up to two per scheduler's instance, single-block ones of any size) stay committed in them.
  `erts_mseg_clear_cache` runs only on the `malloc` paths of `sys/erxos/sys.c`, and clears only
  two instances. On a refused commit, clear every instance's cache and retry once; the
  regression test frees a large binary in a domain held near its budget and then allocates.
* [Medium] oracle log tree test (`test/integration/oracle_log_tree_test.rb`, `tools/lib/erx/oracle_hosted.rb`): the
  test assumes a /tmp cap of 160 MiB (`TMP_CAP`), but the hosted oracle takes the system
  domain's cap from the development manifest, 4 MiB, and runs its suites in /tmp/ct on it. Give the
  oracle's work directory a tree of its own, or derive `TMP_CAP` from the manifest.
* [Medium] benchmarks, `tools/lib/erx/bench_guest.rb` (`exchanges`, `transcript`):
  `tools/erx bench g3` times out at its `footprint` checkpoint on the development image,
  whose console starts root's session at boot. The `erl` line typed at the development
  warning starts the system domain's Erlang shell, then root's session takes the UART and
  its command shell reads the footprint expression (`rc: syntax error`). G3 has to say
  whose shell it measures (the system domain's, or the session's `erl`) and wait for that
  prompt before typing.
* [Low] host tests on FreeBSD, `tools/lib/erx/runner.rb`: the seeded-fault (mutant) binaries
  that abort by design dump core into the tree root (`mutant-*.core`, `page.core`,
  `object.core`; FreeBSD's `kern.corefile` is `%N.core` in the working directory), 17 files
  per `make check`. Test commands should run with `RLIMIT_CORE` 0.
* [Medium] Fiasco build on a FreeBSD host, `tools/lib/erx/fiasco.rb`: the Kconfig step now builds with `cc`
  (`HostOs::HOST_CC`) and the users build is given `HOST_CC`/`HOST_CXX`, but `tools/erx build fiasco` has not been
  run through to an image there; run it on the FreeBSD test host and fix what stops it, then delete this item.
* [Medium] domains, mints (`erx_net_erxos` mint, `erx_driver_ctl` mint, `erx_lfs_mint`; design-system,
  "Facets a configured domain serves"): a mint answers its request only after the grant or
  facet is started and exported, and the domain service drops a reply that comes after the
  request's deadline or after it cancelled the request (`erx_domain_mints`). The grant or
  facet minted for a dropped reply stays alive and exported to its grantee until the
  connection between the two domains ends (the network grant, and a `data` grant of the
  storage domain to any domain but the system domain) or the serving domain ends (the
  storage domain's `storage_ctl` facet, which ends only with its mint, and its `data`
  grant to the system domain), since no
  message withdraws a mint's answer. Give the domain service a withdrawal it sends the mint
  for every request it stops waiting on, or have each grant end unless the grantee claims
  it within the deadline.
* [Medium] storage, `erx_lfs_mint` loop (`mint/3`): no host test drives the loop itself.
  `test/erlang/erx_lfs_mint_tests.erl` covers `mint_request/3`, `erx_fs_grants:grant_options/1` and the
  answers `grant/5` gives, refusals included, but not that the loop (`mint/3`,
  `mint_one/3`) sends each through `erx_facet:minted/2`; drive it with a stand-in of
  `erx_facet`, as the network mint's item below asks.
* [Medium] network, `erx_net_erxos` mint loop (`mint/2`, `count/2`, `mint_one/2`,
  `mint_counts/0`): no host test drives the loop itself. The tests cover
  `erx_net_admit:mint/2` and `erx_net:mint_grant/4`, but not that the loop answers a
  system-grantee refusal and a `noconnection` through `erx_facet:minted/2`, counts refused
  and unknown messages under the right keys, and answers `counts`. Move the loop's decision
  into a pure function returning the reply and the next counts, and test it, or run the loop
  on the host with stand-ins for `erx_facet`, `erx_connections` and `erx_kernel_records`.
* [Medium] network, `erx_net_grant:init/1` (design-network-stack, "The grant"): only
  `erx_net_admit:mint/2` refuses the system domain as a grantee; `erx_net:mint_grant/4` and
  the grant's own export check nothing about it, and the property holds because the mint is
  the only caller and `erx_connections:connection/1` answers `noconnection` for the system
  domain. Refuse a system-domain grantee in `init/1` before the export, so the grant is
  never exported there whoever calls, and keep the admit refusal for its count.
* [Low] network, `erx_net_erxos` mint: a grant start that crashes after the export answers
  `{error, {Reason, Stack}}` to the domain service unchanged, so the network domain's
  internal terms (its `Limits` among them) reach the system domain's refusal log. Map any
  answer other than `{error, atom()}` to a fixed `{error, start_failed}`.
* [Low] design-network-stack, "The grant" (with design-system, `connection_lost`): a grant
  ends with its connection, and the domain service grants a domain again only when either
  domain restarts, but a connection can end while both domains live (`malformed`,
  `no_memory`, `disconnect`). State whether the two domains are introduced and granted
  again then, or the client keeps a dead `net` facet until a restart.
* [High] network, `erx_net_client` (`erx_gen_tcp`; design-network-stack, "The socket
  process"): the TCP socket process lacks parts of the design.
  Still missing:
  `listen/2` and `accept` (the listener's socket process), local `controlling_process/2`
  (`enotsup`), the packet modes and the `buffer`, `exit_on_close` and `show_econnreset`
  options, the schema-generated request validators, `erxos/erx_net_client_erxos`'s
  `expose/2`, and the session template's `grant` key naming its `grant/0` once the grant is
  in another domain.
  The calls the socket process forwards (`sockname`, `peername`, `getopts`, `shutdown`) wait
  for the connection's reply with no deadline of their own, and within one domain a socket
  protocol message proves its sender only by its pid field. Differences from stock at
  the end: a setopts with forwarded options whose own options took
  effect answers `{error, closed}` when the connection closes under it (stock: `ok`);
  `{active, 0}` or a count that stays at or below 0 fails waiting recvs `einval` though the
  socket stays passive; only the first waiting recv gets a passive error's reason, the rest
  `closed` (stock's `async_error_am_all` gives all the reason); and re-arming after a recv
  met the end answers `{error, closed}` where stock sends `{tcp_closed, S}`.
* [Medium] network (the client side of `net`; design-domains, "Floors from a protocol"):
  the socket protocol's floors are not generated from `abi/services/net.txt`, and no client
  checks them at run time. The manifest check holds each `net` grantee's `max_frame` to
  `net_max_frame_min` (property 15), a limit set by hand in that file; nothing checks the
  serving domain's `max_frame` against it at build, as design-domains says the manifest
  check does, nor `max_message_heap` or `funnel_depth`. Generate the floors from the operation schema with
  the send-credit change, check them on the client before each call, and replace the
  hand-set limit with the generated `max_frame` floor.
* [Medium] network, `erx_net` and `erx_net_client` (`erx_udp_sock`, `erx_icmp_sock`,
  `erx_gen_udp_core`; design-network-stack, "Credit"): datagram memory is not bounded as
  the design says. A datagram socket's receive queue in the network domain is bounded in
  datagrams (`limit`, 64 by default; an echo socket's 16), not in bytes up to its receive
  buffer, so one socket may hold 64 datagrams of 65,527 bytes, about 4 MiB, of the network
  domain's memory. On the owner's side the credit charges a datagram `max(1, size)`, which
  bounds bytes but not memory: a peer sending 131,072 empty datagrams to a passive socket
  whose owner does not read makes its socket process hold about 14 words each, some 14 MiB,
  against the design's "at most the target per socket". Charge a fixed overhead per
  datagram on both sides, as FreeBSD's `sb_mbcnt` charges `MSIZE` per mbuf, bound the
  network side's queue by that cost at its receive buffer, and state the cost in the
  design's credit paragraph.
* [Medium] network, `erx_net_client` (`erx_sock_admit:result/2`; design-network-stack,
  "Untrusted input"): each request kind's closed list of errors is a hand-written copy of
  what the network side's paths (`erx_net_frame:path/3`, `udp/5`, `echo/5`, `erx_net_tx`)
  can return, and the `erx_net_admit` fuzz target checks it against a second copy, so an
  error missing from both closes the socket as a protocol break where stock answers the
  error (a broadcast send's `eacces` did). Have each network-side socket map its errors
  into the closed list at its one reply site, total over the specs it calls, or generate
  both from `abi/services/net.txt` with the request validators.
* [Low] network, `erx_net` and `erx_net_client` (`erx_udp_sock`, `erx_icmp_sock`,
  `erx_gen_udp`): the datagram and echo sockets and the datagram socket process count
  unknown and refused messages, but nothing reads the counts: no `counts` call or
  inspector view shows them. `erx_net_admit` also still admits up to 64 `udp_open`
  options, which the grant refuses unless the list is empty.
* [Medium] Fiasco backend, `liberx/backend/fiasco/service_task.c` (`erx_fiasco_task_create_body`):
  a create from a task other than the root is not refused, though the call table and the
  deferred table say `ERX_ENOTSUP` in 1b-A (docs/design-stopgap.md, `erx_space_create`), so a task with a fault
  gate of its own makes Fiasco tasks and spends the service's task rows; the child stays
  inert, since a thread or an image map into it is root only. Refuse it and add a
  `native_task` case. More widely, "root only" is a check in each body (`cap_pass`,
  `image_map`, `slice_create`, `task_join`, the thread and IRQ bodies, the physical and
  contiguous creates), and this one was missed: give each call a caller class in
  `erx_fiasco_wire_words`' table (`service_wire.c`), refuse wholly root-only calls in
  `erx_fiasco_wire_decode`, and hold the table to the call table's root-only rows with a
  host test, leaving only the partly root-only calls' checks in their bodies.
* [High] network and domains, the envelope (design-domains, "Risks and open questions"):
  every message from another domain arrives as `{erx_origin, D, Msg}`. A TCP socket's
  messages reach its owner through its socket process, which takes the envelope off, so
  only `gen_udp`'s active-mode deliveries remain wrapped for an owner outside the network
  domain (the `erx_gen_udp` item above).

* [Low] network, `erx_tcp_conn` (`perform({deliver, _})`): the receive queue
  counts payload bytes only, not the binary and list cell each queued
  segment costs, which `erx_tcp_reass` counts as `PIECE_OVERHEAD`. A peer
  sending one-byte in-order segments to a connection whose owner reads
  slowly, or to a waiting recv, makes its queue cost about 40 bytes of heap
  per byte, a few MiB per connection, where FreeBSD bounds the same with
  the mbuf limit `sb_mbmax`. Count the overhead against the receive buffer,
  or join small payloads as they are queued.
* [Low] Runtime, the envelope (edit 16; `erl_message.c`, `erts_msg_attached_data_size_aux`):
  the size estimate of an undecoded message from another domain leaves out the envelope's
  4 words, so the GC's heap need, `process_info`'s total heap size and the crash dump's
  sizes count each such message 4 words short; the decode itself reserves them.
* [Low] Runtime, the envelope (edit 16; `erts_proc_sig_decode_dist`):
  `make_small(edep->erx_origin)` takes a 32-bit domain id for a small integer, which holds
  only on a 64-bit build; a 32-bit port needs ids bounded below its small range.

* [Low] network, docs/design-network-stack.md ("Framing", step 3 of the output pass): "past
  SYN-RECEIVED" should read "once a SYN has been received" (`TCPS_HAVERCVDSYN`), as the code
  does; FreeBSD's connect also returns the first EHOSTUNREACH (`tcp_usrreq.c:540`), which
  the stack does not.

* [Medium] erx_net TCP explorer (`test/erlang/erx_tcp_explore.erl`): the sack run requires only
  hits a connection without SACK also gives. Add a property that judges a scoreboard hole (a
  hole is retransmitted before new data, say) and require it; a hole first appears at depth 4,
  past the landing depth of 3, so run sack at depth 4 in landing mode (about +0.5 s) or require
  it in `full` mode only. The model's `loss_dropped/3` reads from the connection whether
  `snd_wl1`/`snd_wl2` moved on a duplicate ACK rather than modelling the loss module's drop.
* [Low] erx_net TCP output (`erx_tcp_output`): a FIN-only range the send log marks lost at
  `snd_una` (NewReno, with only a separately sent FIN outstanding) waits for the RTO,
  since the FIN is resent only when `snd_nxt == snd_una`; FreeBSD moves `snd_nxt` to the
  acknowledgement first. And `enobufs/3` sizes the window with no SACK blocks where
  `tcp_maxseg` counts `rcv_numsacks`.
* [Low] erx_net TCP connection process: `erx_tcp_timewait` gives a peer on one of the
  machine's own addresses the 20 ms TIME-WAIT of `tcp_eff_msl` when the control block's
  `local_peer` is set, but nothing sets it yet: whoever builds the control block
  (`erx_tcp_user:new/1` for a connect, the syncache's completion for an accept) must
  pass `local_peer => true` when the route goes through the loopback interface, or
  loopback connections wear down the grant's `time_wait` limit.
* [Low] erx_net TCP ICMP (`erx_tcp_icmp`, `erx_tcp_input:tcp_mss`): an MTU a too-big
  report gives in SYN-SENT lowers the MSS until the SYN-ACK, which recomputes it from the
  path, so the first full-size segment is lost again; FreeBSD keeps it in the host cache
  (`tcp_hc_updatemtu`), which `erx_tcp_hostcache` will hold.
* [Low] erx_net TCP ICMP (`erx_tcp_icmp`): reports are sized by `#tcb.family`; check how a
  connection to an IPv4-mapped IPv6 address is represented, since FreeBSD sizes such a
  connection's headers as IPv4 (`inp_vflag`).
* [Low] erx_net TCP input (`erx_tcp_input`, `data`): the D-SACK block of a duplicate
  is recorded in the `data` stage, so it is lost when the segment ends earlier (the loss
  module's `drop`, CLOSING or LAST-ACK ending); FreeBSD records it in its trim.
  Recording it in `trim` needs the reassembly ranges held before the segment there.
* [Low] erx_net TCP core (`erx_tcp:respond/5`): it sets no ECE
  (`tcp_ecn_output_established`) on keepalives and challenge ACKs.
* [Low] erx_net TCP timers (`erx_tcp_timer`): path MTU black-hole detection, which the
  design says is translated (off by default, `tcp_pmtud_blackhole_detect`), is not.

* [Medium] runtime build, `tools/lib/erx/runtime_seam.rb` (`check_imports_of`): the BeamAsm image's import check counts
  what libc++ and libc++abi define as available to ERTS, but never checks their own undefined names (`malloc`, `abort`,
  pthreads) against `otp/erts/emulator/sys/erxos/imports.txt`, so the C library seam does not cover the C++ runtime. Add
  the two archives to the undefined-name pass.
* [Low] runtime build, `tools/lib/erx/libcxx.rb` and `tools/lib/erx/native_runtime.rb` (`build_sysroot`): the merged
  sysroot headers are copied with their original times, so a header dropped from an upper layer can leave an older time
  that ninja's libc++ build does not see as a change; and the libc++ configure stamp records the compiler's path, not its
  version, so a Homebrew upgrade of LLVM at the same path keeps the old objects (ERTS's stamp has the same gap). Stamp the
  merged headers' digest and `clang --version` instead.
* [Medium] network build checks, `tools/lib/erx/net_checks.rb` (seq-wrap, atoms): the checks scan text
  with a regex copy of Erlang's lexer and a list of literal spellings, so they miss the idiomatic wrap
  `<<D:32/signed>> = <<(A - B):32>>`, a mask defined by a macro in a non-TCP header and used in a TCP
  module, and an escaped quoted atom such as `'list\_to_atom'`. Tokenize with stock OTP's `erl_scan`
  (integer and `bsl` tokens by value, atoms after unescaping; DeviceCallers could share it), flag `:32`
  bit-syntax segments outside `erx_tcp_seq` and `erx_tcp_wire`, and consider refusing `file:consult`,
  `erl_scan`, `erl_parse` and `io:read` in erx_net too. The lifted-segment record remains the real guard.
* [Low] network, `erx_tcp_input:dropwithreset` and the connect path: only the link-cast half of
  `tcp_dropwithreset` is translated; its IP checks (`tcp_input.c:3452-3472`) are left to the rule
  that no connection has a multicast or broadcast foreign address, which FreeBSD enforces in
  `tcp_usr_connect` and erx_net does not yet (a connect to 224.0.0.1 is not refused). Refuse it at
  connect and say so in the comment.
* [Low] network, `erx_nd6_rtr:deprecation/2`: it also clears `deprecated` on a tentative address,
  which `nd6_timer` never reaches (`nd6.c:1041` is its final branch), and clears it at the RA's
  refresh rather than the next timer; name both as departures in the module documentation.
* [Medium] network, `erx_net_input`: looped multicast is checked against the loopback interface's
  `groups`, not the carried zone's interface, and a socket's `report` item holds the quote's raw
  addresses although the socket was found by its zoned key.
  Decide it when the interface process carries looped multicast.
* [Low] network, `erx_tcp:signal_state(rto_err, ...)` (review of P20d): undoing a spurious
  timeout rewrites the send log (`timeout_undone`) and moves `snd_nxt` to `snd_max` behind the
  loss module's back, so a module with per-range state would be stale after it. Route the undo
  through the loss module (a cause of `rewind/4` or a sibling callback) before a second module.
* [Low] network, `erx_net_input` provenance: NOTICE-freebsd's entry lacks `sys/netinet/tcp_subr.c`
  (`tcp_ctlinput`), which the design names as a source; and check whether `udp_common_ctlinput`
  looks up with `INPLOOKUP_WILDCARD`, which the design says it does not.
* [Medium] build, the Raspberry Pi 4's card (`tools/lib/erx/boot_partition.rb`, `tools/lib/erx/bl31.rb`):
  `LICENCE.tf-a` is TF-A's `docs/license.rst` alone, whose BSD-3-Clause text carries only TF-A's placeholder
  copyright, and none of the notices of the third-party code BL31 links (TF-A's libc, libfdt, compiler-rt's
  builtins). The website offers the card, so BL31's link closure needs its notices beside the armstub, as
  the packer gathers them for the boot image (`NOTICES`).
* [Medium] build, the Raspberry Pi 4's card (`tools/lib/erx/boot_partition.rb`): `docs/design.md` ("Licences
  and notices") says the same `NOTICES` sits beside the boot image in each slot's boot partition, but the
  card's layout has none beside `kernel8.img`; the production image's `NOTICES` is only inside the image
  (`system/NOTICES`). Write it into the boot partition, from the packer's notices, and have the card's test
  check it.
* [Low] build, `tools/lib/erx/source_revision.rb`, `tools/lib/erx/boot_partition.rb`: the `dirty` flag reads the
  tree by git's ignore rules, so a file that the checkout's `.git/info/exclude` hides but the build globs is not
  counted, and the card's record and the image's build facts read the revision at two times of one pack, so a
  file removed between them can leave a clean record. Derive the flag from the pack's own input catalog, read
  once per pack.
* [Low] build, the website (`.github/workflows/site.yml`, `tools/lib/erx/site.rb`): the card's record is checked
  against the commit the page links, but the demo image is not, though it carries the stopgap kernel's GPL-2.0
  files; check the image's receipt against that commit the same way.
* [Low] build, `tools/lib/erx/boot_partition.rb` (`lay_out`) and `tools/lib/erx/build_facts.rb`: the card's record
  and the image's build facts each read the source revision, so a commit or stash during a pack can leave them
  naming different revisions. Read it once in `ProductionImage` and pass it to both.
* [Medium] build, the packer's `NOTICES` and `docs/design.md` ("Licences and notices"): a file of
  erXos's counts as third-party for its notice when its SPDX line names a third-party licence, but
  `erx_tcp_cc`, `erx_tcp_cc_newreno` and `erx_tcp_cc_cubic` translate BSD-2-Clause FreeBSD files, so
  their SPDX line is erXos's own `BSD-2-Clause` and their FreeBSD copyright headers may be left out
  of `NOTICES`. Classify erx_net modules by their `%% FreeBSD:` header lines (or NOTICE-freebsd)
  instead, and say so in the design; check what the packer does today first.
* [Medium] network, `erlang/apps/erx_net/src/erx_nd6_rtr.erl`: the interface process must call
  `select_router/2` after every step that can change the router list or a router's reachability, and diff
  `addresses/1` and `routes/1` to republish, where FreeBSD reselects inside `defrtrlist_update`; until it
  does, a default route through a router that left the list is missing. When the interface process is
  written, pass erx_nd6's reachability into `ra/4`, `tick/2` and `dad_done/3`, select inside, and emit
  `{routes, Rows}` and `{addresses, Rows}` actions only on a change, so it holds by construction.
* [Medium] network, `erx_tcp_loss_dupack` (`prr/5`): in SACK recovery PRR measures the pipe after
  the acknowledgement, where FreeBSD's `tcp_do_prr_ack` computes `tcp_compute_pipe` with
  `snd_una` not yet advanced and sets `snd_cwnd = pipe - del_data + sndcnt`; whether that pipe
  already leaves out the bytes this acknowledgement newly SACKed (and so whether FreeBSD
  subtracts them twice) depends on `tcp_sack_doack`, which erXos does not read. Settle it from a
  FreeBSD 15.1 run: a SACK recovery in which one acknowledgement advances `snd_una` by A bytes
  and newly SACKs S bytes, once with the pipe above `ssthresh` and once below, recording
  `tcpi_snd_cwnd` (TCP_INFO) or the segments sent in reply, and compare with `pipe_after +
  sndcnt` and `pipe_after - S + sndcnt`, for both the window and the `pipe >= ssthresh` choice.
* [Medium] network, `erx_tcp_loss_dupack` (`episode/3`, `ended/2`): where a recovery episode
  ends is decided twice, by the connection (`erx_tcp_input` `end_recovery`, `erx_tcp`
  `signal_state`) and again by the module from the acknowledgement and its own `pending`
  value, and episodes it did not begin are inferred from the flags. Today the two agree; make
  it hold by construction with an episode number in `#ccv` that every entry and exit bumps, and
  record the one departure it brings (ECN's signal on the acknowledgement that ends recovery
  would start fresh counters, where FreeBSD carries them).
* [Low] network, `erx_tcp_loss_dupack` (`prr/5`): in the recorded departure where a partial
  acknowledgement without SACK blocks takes PRR's path, a scoreboard without holes credits
  `maxseg` delivered per acknowledgement, so a peer splitting one segment's acknowledgement
  front-loads PRR's sending (bounded by ssthresh); credit `min(maxseg, ack - snd_una)` there.
* [Low] network, `erx_ip6_wire` (`options/4`): a router alert whose length is wrong but which
  runs past its header is dropped silently, where FreeBSD's `ip6_process_hopopts` checks only
  that 4 bytes remain and answers with a parameter problem; a second departure in which ICMPv6
  error a packet draws, missing from the module's documentation, and the fuzz judge shares it.
* [Low] network, `erx_icmp6_wire` (`error_code/2`): as in FreeBSD, an incoming parameter problem of code 3
  (RFC 7112's incomplete header chain) is refused as `bad_code`, though `erx_ip6_wire` reports code 3 for
  erx_ip6 to send; decide with erx_icmp6 whether to accept it.
* [Medium] network, `erx_net_sup` (link restarts): the driver's one-second hold paces every end of a
  driver that ran, but not a transport whose `init` fails at a restart (the start fails and OTP retries
  at once, so a persistent failure, such as a `udp` end's vanished local address, ends the interfaces
  supervisor and then the stack), nor an `erx_net_if` or `erx_dhcp4` crashing past its link
  supervisor's intensity (reachable from a peer only through a crash bug). An `erx_tap` restart meets
  this too: FreeBSD's tap opens once, and an armed descriptor of the ended driver closes only when
  ERTS's poll set lets go of it, so the new `init` may find the device busy (`ebusy`); not yet seen
  on the FreeBSD test host. Pacing every link start in `start_link_sup/1`, not each way a driver ends, would close all
  three.
* [Medium] network, `erx_tap` (`fd => N`): every restart of the driver adopts the integer N
  again, so once N's holder closes it (an OTP socket closes with its controlling process), the
  next descriptor the node opens under that number (a connection, a file) is adopted, made
  non-blocking and written frames to. Adopt once into a resource a long-lived process owns and
  give each driver start a copy of that, or record `st_dev`/`st_ino` at the first adoption and
  refuse a restart whose descriptor differs.
* [Medium] network, `erx_tap_nif` (`adopt/2`): the copy shares its open file's flags, so any
  holder that clears `O_NONBLOCK` (OTP's `socket:close` does) makes the next `recv`/`send` block a
  normal scheduler. Check `F_GETFL` at each call and fail with `{error, blocking}`, or poll with a
  zero timeout before each read and write. Also refuse a descriptor not open for reading and
  writing at adoption.
* [Low] network tests, `erx_tap_tests:owner_end_closes_the_descriptor_test`: under a host load
  near 20 the FIFO's reader was still blocked 2 s after the owner's `DOWN` (`{value, blocked}`,
  line 138), and the same file passed alone at once. Find what closes the descriptor after the
  owner's end (the resource's down callback or its destructor) and wait on that, not on a fixed
  2 s.
* [Low] network, `erx_tap` (unprivileged runs): the privileged opener that hands the node a tap
  descriptor over `SCM_RIGHTS` ([design-network-stack.md](docs/design-network-stack.md), "The tap
  transport") is not built; it must hand the descriptor over close-on-exec, so no port program
  inherits it.
* [Low] network, `erx_net_sup`: a far end or device that stays dead logs a supervisor report about
  once a second per interface for as long as it stays dead; the log, not the stack, should fold
  repeated reports.
* [Low] network, `erx_net_driver` over `erx_virtio_net`: a device that stops completing transmits
  ends nothing; its backlog fills, senders are refused and the link stays stuck. FreeBSD's vtnet(4)
  reinitialises the interface when its transmit watchdog (`vtnet_watchdog`) expires after 5 seconds;
  a driver whose backlog has waited on `writable` that long could end, so that its restart resets
  the device.
* [Medium] network, name resolution (`erlang/apps/erx_net_client/src/erx_gen_tcp.erl`,
  `otp/lib/kernel/src/inet_res.erl`): a reply with the TC bit set makes `inet_res` ask again over
  TCP with `{packet, 2}`, which `erx_gen_tcp` refuses (it takes only `{packet, raw}`), so a name whose
  answer does not fit in 512 bytes fails to resolve. Give the connection `{packet, 2}` framing, or
  have `erx_gen_tcp` frame the two-byte length itself, and test a truncated reply against a name
  server on the host.
* [Medium] shell, `host` (`erlang/apps/erx_shell/src/erx_cmd_host.erl`, `run/2`): a name or server
  argument with an empty label or a label over 63 bytes (`host a..b`, `host .foo`, `host www .foo`)
  crashes the command with `function_clause` from `inet_dns:encode_labels`, which stock OTP 29.1.2
  raises too, where FreeBSD's host(1) writes `host: 'a..b' is not a legal name (empty label)`. Check
  each candidate and the server name (labels 1 to 63 bytes, 253 in all) before querying and write
  FreeBSD's line, with cases in `test/erlang/erx_cmd_host_tests.erl`. The same crash from
  `erx_gen_tcp:connect/4` through `inet:getaddrs_tm/3` is stock's and belongs with the upstream
  `inet_dns` report.
* [Medium] network, edit 62 (`otp/lib/kernel/src/inet_dns.erl`, `decode_data/3`): the fix's test (`inet_dns_tests`) calls
  `inet_dns:decode/1`, and the `dns` fuzz target reaches a formatless type only when a flip lands
  on a type or class field, and it calls `inet_dns:decode/1` where `inet_res` calls `decode_reply/3`.
  Make the test decode through `decode_reply/3` as well, and have the fuzz target call `decode_reply/3` with a matching query.
* [Medium] network, effect layer (E1, `erx_net_if`, `erx_udp_sock`, `erx_net_tables`): the first
  package runs ARP, ICMP echo, DHCP and UDP only. Not yet: `erx_net_vclock` and `erx_net_script` (the virtual clock is refused at
  start); `erx_net_loop`; grants, `erx_net_admit` and `erx_net_client` (`erx_udp_sock` has a
  provisional `gen_udp`-shaped interface, and `erx_net_tables:watch_holder/1` deletes a dead
  socket's entries in its grant's place); the listener, IPv6, reassembly and redirect paths of
  `erx_net_if_core` (counted `unsupported`); an `erx_net` application module and its `env` keys
  (the stack starts with `erx_net_sup:start_link/1`); the credit limits are fixed defines, not
  application keys; a datagram socket's credit counts datagrams, not bytes of its receive
  buffer. Build checks still to add: the clock chokepoint (`erlang:send_after`, `monotonic_time`
  and the rest only in `erx_net_clock`), `erx_net_bind` as the only demultiplexing inserter,
  `erx_net_if` as the only configuration writer and `erx_net_credit` as the only batch sender.
* [Medium] network, virtio-net transport (`erlang/apps/erx_net/erxos/erx_virtio_net.erl`): what the
  first package leaves. No host tests of its pure functions (`frame/3`, `mtu/2`, `lladdr/2`,
  `link_state/2`, `segments/1`, `erx_net_app:interfaces/1`): export them under `TEST` or move
  them to a pure module of `src/`'s, and test them with EUnit. Checksum offload, which the
  design asks for, is not negotiated. UDP echo is not tested on QEMU: it needs an echo service
  in the guest. No build check that only `erxos/` names erXos's own modules (`erx_device`,
  `erx_device_record`, `erx_log`, design-network-stack.md, "Two places, four seams"), with its
  seeded violation.
* [Low] network, virtio-net transport, small points: the manifest admits a network device held
  by any domain, not only the system domain or the network domain; `VIRTIO_NET_F_MTU` is
  negotiated even when the device's MTU is above 1,500, the most the receive buffers hold: the
  transport clamps the MTU and drops longer frames as `too_long`, but should not take the feature; a multicast or zero device MAC is
  taken as the interface's address; `refill/2`'s `{ok, T}` match after a completion batch ends
  the driver with a badmatch rather than a named reason; the harness (`net_device.rb`) does not
  check the IP and ICMP checksums of the guest's replies; `free_port` can race another process
  for the port it found, and `Link#await` takes a frame from any local sender; `Link#send`
  shadows `Object#send`; `tx_limit` is the queue size although a frame takes up to four
  descriptors, so `full` comes before the credit runs out; `init/1` turns any exception into
  `ignore`, a programming error included; the interrupt status bits are written by hand, as in
  `erx_blk`, not generated from `abi/formats/virtio.txt`; `erx_net_if` has no `format_status/1`
  that keeps queued packets out of a crash report, as `erx_net_driver` has.
* [Medium] network, TCP effect layer (E2, `erx_tcp_conn`, `erx_net_grant`, `erx_gen_tcp`): active
  opens over IPv4 only. Not yet: `listen`/`accept`, the syncache hand-off and a SYN reinjected from
  TIME-WAIT (E3, counted `reinject`); the grant's limits other than `buffers`, and its account (`erx_net_grant_core`
  holds only the buffer reservations); receive-buffer autosizing (`tcp_do_autorcvbuf`, a
  `reserve_buffer` for the receive side like the send side's); `exit_on_close` (a socket whose peer closed
  stays open until its owner closes it), `controlling_process/2` (`enotsup`), the packet modes,
  `getstat` and every option but `binary`, `list`, `mode`, `active` and `nodelay`; `local_peer`
  is never set, so a connection to one of the machine's own addresses keeps the full MSL; the
  connection's credit limit and buffer sizes are fixed defines, not application keys.
* [Medium] network, `erx_tcp_conn` (`guarded/2`): a raising step must end the connection
  ([design-network-stack.md](docs/design-network-stack.md#decisions), 15): from its
  state before the event, with a RST, `{error, econnaborted}` to its socket process and an exit with
  the exception, for a batch of drained messages as for one. `guarded/2` instead counts the raise
  and goes on with the state it had, after the effects of the step may already have run, and a raise
  outside a segment step crashes the process with no RST. Since the connection steps every
  queued `{items, ...}` together, a raise discards the whole batch, up to the credit's 256
  segments, so a segment that trips the bug once per batch stalls the connection. Change both, with a regression test that
  plants a raise in the step and checks the RST and the error the owner sees.
* [Medium] network, `erx_tcp_conn` (E2 review): a refused or timed-out connect in active mode still
  sends `tcp_error` and `tcp_closed` for a socket the caller never got; calls after `close` are
  served (a `recv` waits until the connection ends) where stock answers `{error, closed}`; a RST
  surfaces as `econnreset` where stock's `show_econnreset` false gives `closed`; the crash report's
  `reason` and queued messages can hold peer bytes despite `format_status`; a `recv` timeout past
  `send_after`'s range crashes the connection; `erx_tcp:answer_send` keeps filling the buffer after
  `snd_closed`; steps continue after `finish`; `watch_holder` runs after the claim, so a kill
  between them strands the entry; port exhaustion answers `eaddrinuse` where the design says
  `eaddrnotavail`. The socket's flags (`eof`, `ended`, `told`, `finished`, `connect`, owner `none`)
  want one closed phase value.
* [Medium] network, `erx_net_if` (`owned/4`): an interface that dies between reserving a holder's
  unit and the batch's end (a raise outside a frame's step, or its link supervisor's shutdown)
  leaves those units counted on credits that outlive it; trap exits and release the batch, or
  send each item at its reservation. A sender killed between `reserve` and `!` in
  `erx_net_credit:hand/4` leaks its units the same way.
* [Low] network, `erx_net_pipe` (`udp` end): any local user can send from the peer's loopback
  address and port, and strangers spend the `{active, 64}` window; a development host's
  residual.
* [Low] network, `erx_dhcp4`: a link that comes back up restarts the client from INIT with a
  fresh core, not INIT-REBOOT as the design's "The driver" says; the interface keeps the old
  lease until the new `configure` replaces it. INIT-REBOOT within one run needs only the core's
  last lease, not the stored state the item below waits for.
* [Low] network, `erx_dhcp4_core`: an ARP probe of the offered address before using it, and a
  DECLINE when another host answers (RFC 2131 4.4.1, RFC 5227), behind a setting of the
  interface's `dhcp` mode, off by default as in `dhclient`. Today the address is announced with a
  gratuitous ARP and a conflict is only reported by erx_arp. Part of the first host network package.
* [Low] network, `erx_dhcp4_core`: INIT-REBOOT (RFC 2131 3.2, 4.4.2), asking again for the last
  lease's address after a restart. It needs the lease kept across boots, as `dhclient` keeps
  /var/db/dhclient.leases. Part of the first host network package.
* [Low] network, `erx_dhcp4_wire_fuzz`: the fuzz target has no field oracle: pkt has no DHCP
  decoder, so its judge reads the options itself (joined bytes, and its own reading of options 15
  and 121) instead.
* [Medium] shell, `ping` (`erlang/apps/erx_shell/src/erx_cmd_ping.erl`): a ping without `-c` or `-t`
  runs until interrupted, and `Ctrl-C` ends it without its statistics, because an Erlang command gets
  no `SIGINT` to catch: FreeBSD's ping writes the statistics and exits on it. Deliver the interrupt to
  an Erlang command as a message it may handle, and have ping write its statistics then.
* [Medium] shell, `ping`'s loop (`erlang/apps/erx_shell/src/erx_cmd_ping.erl`, `loop/2`, `tick/2`, `due/2`):
  the schedule (next request, grace period, `-t` end) lives in an untyped map across three recursive
  functions that each read the clock, and only `-c 3` on QEMU and the reply-stream case test it. Make it a
  pure `next(Schedule, Now, Tally) -> {send, Seq} | {wait, Ms} | done` over a record, tested on the host for
  the count, the grace period, `-t` and exit status 2.
* [Medium] network, `erx_icmp_sock` (`erlang/apps/erx_net/src/erx_icmp_sock.erl`): no host case drives it:
  the 17th waiting reply dropped and counted by the interface, the identifier released on `close/1` and on
  the owner's end, `eaddrinuse` when every identifier is held, the `recv` deadline. Nor does one drive
  `erx_net:interfaces/0`'s conversion (IPv6 rows, `gateway => none`) and an interface ending while asked.
  Its waiter, deadline and credit-take code copies `erx_udp_sock`'s; one receive-queue module for both
  removes the second copy.
* [Medium] network and shell, ICMP errors to ping: an unreachable, time-exceeded or parameter-problem
  error quoting one of ping's echo requests is dropped as `no_socket` (`erx_net_input`, `quoted/4`), so
  ping prints nothing where FreeBSD's `pr_pack` prints `NN bytes from X: Destination Host Unreachable`
  and the like. Route an ICMP quote by its `{icmp_echo, inet, Ident}` key to the socket and print it.
* [Low] shell, `ping`: a reply whose slot of the 1024 a later sequence number took is ignored, so with
  `-i 0.001` and round trips over a second ping reports loss FreeBSD would not; and the grace period
  after the last request is `max(1 s, 2 * tmax)` in milliseconds, where FreeBSD truncates it to whole
  seconds. Pin both against ping.c.
* [Low] shell, usage errors: an Erlang command's `{error, usage}` gives the status `usage`, while ping's
  out-of-range values give 64, FreeBSD's `EX_USAGE`, which FreeBSD's `usage()` gives too
  (`erlang/apps/erx_shell/src/erx_shell_runner.erl`). Give `{error, usage}` status 64.
* [Medium] shell, the network commands in a session (`erlang/apps/erx_shell/src/erx_cmd_ifconfig.erl`,
  `erx_cmd_ping.erl`, `erx_cmd_host.erl`): each declares `-erx_needs([net])`, so a session without the net
  facet refuses it with `no_facet`, but one that holds the facet still runs code that works only where the
  stack runs: `ifconfig` and `ping` call erx_net and erx_icmp_sock, which a session's release does not ship,
  and `host` opens its sockets through erx_net_client, which it does not ship either, so each ends with
  `undef`. Reach the stack through the facet's value (`erx_cmd:facet(Ctx, net)`: `local` in the system
  domain, the facet's pid elsewhere), with erx_net_client and its erXos grant module in the session's
  release (docs/design-network-stack.md, "Two places, four seams"), and report a missing stack as
  `ping: socket: ...` and `ifconfig: network stack: ...` do. Then have `erx_shell_runner:command/4` hand
  each command only the facets it declares (`maps:with(Needs, Facets)`; `top` reads `inspect` without
  declaring it, so it needs a way to name a facet it uses when present), so a command that forgets its
  declaration holds no facet by construction, and shrink the command-needs build check
  (`tools/lib/erx/command_needs.rb`) to "no erx_shell module names a stack module": its list of OTP's
  network modules and functions is an enumeration that a new OTP call outside it gets past.
* [Medium] domains, two facets of no declared interface (`tools/lib/erx/facet_names.rb`, `UNDECLARED`;
  [design-abi.md](docs/design-abi.md#services-facets-and-their-parameter-schemas)): a session's `console`
  facet, which `erx_console` hands in its create spec and `erx_session_tty` reads with `erx:cap(console)`
  ([design-live.md](docs/design-live.md#the-console)), is of no interface, since `abi/services/console.txt`
  declares no service; and `web_line`, which `erx_web_line_app` provides through `erx_facet:provide/2` and the
  domain service hands the web domain ([design-web.md](docs/design-web.md#overview)), is an export of the
  session's line that rides the facet registry. Declare the console's interface in `abi/services/console.txt`
  with the tty's six messages, as design-live.md ("The tty") states, and take `web_line` off the registry,
  since design-web.md ("Overview") makes the line a name the login hands out rather than a facet, then drop
  both from `UNDECLARED` and lower `EXEMPTIONS_MAX` to match. Declaring `console` also deletes the funnel's
  literal `console` clause (`erx_domain_srv:facet/3`), so it waits for the attenuating hand-on of the
  facets item below, through which the console facet is then handed on like any recorded facet.
* [Low] domains, the facet table's manifest reader (`tools/lib/erx/facet_names.rb`, `records_of`): the
  facet-names check, and the funnel's table generated from it (`erx_facet_names.hrl`), read the manifest
  with a small parser of their own rather than `Erx::ABI::Syntax.parse`. Read it with the manifest's own
  syntax so the table and the image's manifest cannot disagree on a service's name.
* [Medium] domains, the inspect facet's scope wiring (`erlang/apps/erx_domain/src/erx_domain_srv.erl`,
  `system_facet/4`; `erlang/apps/erx/src/erx_build.erl`, `shell_principals/1`): no test checks the scope a
  session's minted inspect facet holds, so a `system_facet/4` that mints `all` for every grantee passes, and
  `shell_principals/1` is tested on no manifest that names a system-shell principal. The service tests' export
  stand-in has no `owner/1`, so a request cannot go through a facet the service minted. Give it one, mint with
  `inspect_policy => #{roots => [1], development => false}` for principal 1, expect `{error, scope}` for
  `[kernel, log]`, and seed `inspect_scope/3` replaced by `all`; test `shell_principals/1` on a packed manifest.
* [Low] facets, a request past `max_request` (`erlang/apps/erx/src/erx_inspector.erl`, `route/3`): the facet
  drops it unanswered, so the inspector waits `inspect_query_max` and a margin before `{error, failed}`. It can
  refuse such a request at once from the grant's `max_request` (`erx_facet:info/1`).
* [Low] inspection consumers, a busy facet (`erlang/apps/erx/src/erx_inspector.erl`, `route/3`): a request past
  the inspect facet's `in_flight` answers `{error, busy}` at once and no consumer retries it, so a browser with
  many views open can make the same session's `top` print `[inspector busy]` and its `/proc` files `[error]`.
  A facet that crashes, through a fault in its callback (`erx_facet:loop/1`), reads as one revoked: `no_facet`,
  so the session's `/proc` is `enoent` and `top` prints `[no inspect facet]` while its grant still names inspect.
* [Medium] inspection schema, `abi/inspection.txt`: design-live.md's path table and
  [The runtime agent](docs/design-live.md#the-runtime-agent) name `[processes, Pid, source]`, the source lines
  around a process's location from `erx_source`, but the schema declares no such path, so the inspector, and a
  domain's `erx_inspect_agent` through it, answer it `{error, scope}`. Declare the path and its collector.
* [Medium] query worker, `erlang/apps/erx/src/erx_inspect_worker.erl` (`given/2`): `[domains, D]` of a domain
  other than the system domain gives its runtime attributes from D's agent and every domain-service and kernel
  attribute `unsupported`, because the domain service's view (`erx_domain:inspect_view/1`) carries only each
  domain's agent. Carry those attributes in the view, or collect them in the worker from the domain service
  and the root's capabilities, as the system domain's own record is.
* [Medium] query worker, `erlang/apps/erx/src/erx_inspect_worker.erl`: an agent's answer the worker refuses is
  dropped but not counted where an operator can read it, which design-live.md ("The runtime agent") asks; a
  `{principal, P}` query whose view the domain service does not give answers `{error, scope}` for P's
  domains' paths rather than an unknown or failed status; `[domains, D]` of a domain the view lists as ended
  answers `{error, scope}` while its record is kept; an agent's `{error, scope | unsupported}` for its own
  `[domains, D]` becomes the whole answer rather than its runtime attributes' status; and `await/1` waits for
  the worker with no deadline of its own, trusting the worker's `inspect_query_max`.
* [Medium] inspect agent, `erlang/apps/erx/src/erx_inspect_agent.erl`: a session's agent does not relay its
  programs' and pipes' attributes ([The runtime agent](docs/design-live.md#the-runtime-agent),
  `[domains, Id, programs]`), and below `[domains, Self]` it asks `erx_inspector`, whose `collects_domain/2`
  collects a domain's paths only in the system domain, so those paths answer `{error, scope}`. In the
  session_domain QEMU cell, `top` in root's session (domain 8) prints
  `Domain 8 budget [not in scope]: - Used, - Guarantee, - Cap`, because the agent answers `[domains, 8, budget]`
  `{error, scope}`.
* [Medium] shell, the session_domain QEMU cell of session P6 (`tools/lib/erx/qemu_suites/session_domain.rb`, which
  session P5 brings with the session domain): `ifconfig` typed in a session prints `ifconfig: no_facet`
  and sets the status `no_facet`, and in the system shell lists the interfaces; `ps` lists the session's
  own processes there. The EUnit cases of `test/erlang/erx_shell_runner_tests.erl` run the same commands
  with a session's facets on the host.
* [Medium] liberx Fiasco backend, `test/guest/native_task` (`case_ends("service", ...)`): the first
  case hung once under HVF with one CPU, after `erx: task: cpus 1` and before the case's line, so
  `task-service` timed out; the rerun on the same tree passed on one and four CPUs. The task that
  `erx_fiasco_launch` starts with `ERX_SPACE_JIT` and `MODE_SERVICE` never ended, so the root's
  join waited for good. Find the wait it stuck in. The case's rewrite rounds yield on one CPU, and
  with the fork's yield (docs/design-stopgap.md, "Scheduling") the case takes well under a second
  of its 30 s, so a timeout there is a hang, not a slow run.
* [Medium] liberx Fiasco backend, `launcher.c` `erx_fiasco_task_join_until` and `object.c`
  `erx_fiasco_object_drain`: a task holding the last handle of its own space's budget is deleted in
  the request that ends it, its ended semaphore with it, so a root join that got `ERX_EBUSY` before
  the end waits on a deleted (or, after a new space takes the index, another task's) semaphore:
  `erx_fiasco_semaphore_down` retries the IPC error until its deadline, or for good. The domain
  library keeps its copy of every domain's budget, so only a caller that moves its last copy away
  meets it. Have the service up the joiner's own semaphore, as the other blocking stubs do.
* [Medium] liberx Fiasco backend, `service_task.c` `task_teardown`: a task's end defers only what its
  handle table's close frees or what it created (`object_later`); memory whose last mapping goes and
  the home group still end inside the teardown, safe only because neither kind's end stops a task.
  Route those ends through the mark too, so nothing ends inside a teardown, and drain once after
  `service_main`'s dispatch rather than in three arms.
* [Low] liberx Fiasco backend, `object.c` and `core/handles.h`: rename the record's `ending` word
  (`end_pending`) and `object_later` (`object_defer_end`), since `budget.c` uses "ending" for an end
  in progress, and word the core header's comment without naming the Fiasco backend.
* [Low] liberx Fiasco backend, `budget.c` `budget_sweep`: a budget's object sweep ends a group
  charged to it whose home task, charged to another budget, still has threads, which `erx_object_destroy`
  and a last close refuse ("a group never goes before its threads"). Skip such a group in the sweep, or
  stop its home first.
* [Low] liberx Fiasco backend, `object.c` `erx_fiasco_object_end`: it does not itself refuse a kept
  record (the time page, an image entry's slice); only `erx_fiasco_object_destroy_body` does. No caller
  reaches a kept record through an end today, so the guarantee rests on each end path. An end that did
  reach an image slice would also leave `service_task.c`'s slice cache (`task_image_slice`), which holds
  a bare record index, naming a freed or reused record, possibly another entry's slice. Make the end
  refuse a kept record, so the keep holds whatever calls it; no test destroys the time page's handle
  to check destroy's own refusal (`ERX_ERIGHTS`), so add one to `native_space` with it.
* [Medium] Image build, `tools/lib/erx/source_revision.rb` (`QUERIES` branch shape): a branch name
  git accepts but the shape refuses (`fix#123`, `stas@wip`, `_tmp`, over 100 bytes) fails the whole
  image build. Either leave such a branch out of the revision, as newvers.sh leaves out a detached
  head, or widen the shape in both `BuildFacts::SHAPES` and `erx_build`, since `uname` writes the
  revision through the field escape anyway.
* [Medium] liberx Fiasco backend, `liberx/backend/fiasco/service.h` (`erx_ipc_wait`): the stopgap's
  open wait returns design-kernel.md's tag and label, but only for fault and exit records, the one
  message its gates carry. Decide whether BK8b's IRQ deliveries share the same open wait before
  any thread other than the gate worker (`sys/erxos/erx_gate.c`), which binds only the domain's
  fault gate, waits in it.
* [Medium] ERTS, `sys/erxos/erx_program_drv.c` (`PROGRAM_POOL`): no session has a pool for programs
  yet, and the stopgap reports no budget's cap, so the driver checks a spec's cap against
  `UINT64_MAX` and only the carve of the program's budget bounds it. Give the session its pool, as
  docs/design-runtime.md, "Programs as ports", step 1 has it, and check against that.
* [Medium] ERTS, `sys/erxos/erx_program_drv.c`: a failed `erx_space_stop` of a program's anchor is
  not fed back to the core, so a program whose anchor did not stop leaves its port waiting for a
  close that only `port_close/1` or its owner's exit gives.
* [Medium] session domain, programs: a program's anchor is a sub-space of the session,
  but nothing yet ends a session's programs with the session domain. Until something does, no test ends a
  session while one of its programs runs.
* [Low] ERTS, `sys/erxos/erx_program_drv.c`: the driver does not refuse a spec whose pid a live
  program already has, and nothing reads a program's pid yet. The command server that names pids
  owns their uniqueness (docs/design-programs.md, a program's start, step 5) and makes it hold by
  never giving a pid twice; until it exists, a test's spec names the pid. The gate worker's 64 registrations
  (two a program) bound a session to 32 programs at once, each start past that refused with `elimit`.
* [Low] stopgap, `liberx/backend/core/park_table.h` (`listed`) and `park_table.c`: a group holds at
  most 64 IRQ objects, since `listed` is a 64-bit map with one bit per object and the file
  asserts `ERX_BACKEND_PARK_OBJECTS_MAX <= 64`. A group that would need a 65th doorbell is refused with an error:
  the session's group, which holds one per program port (`erx_program_drv.c`), the connections' bells and
  every end a session process holds, so a session runs about 30 programs with writers; or a program holding
  64 or more pipe ends and its channel bell. The 65-writer case therefore waits for erXos's kernel. Not worked around
  on the stopgap.
* [Low] stopgap, `liberx/backend/fiasco/thread.h` (`ERX_FIASCO_IRQS_MAX`, 256): the machine holds at most
  256 IRQ objects, one per program channel doorbell, one per pipe end and so on; an object past it fails
  with `ERX_ENOMEM`. Busy sessions with many programs and pipes can reach it. erXos's kernel has no such
  table.
* [Low] hosted backend, `liberx/backend/hosted/group.c` (`irq_objects`): the hosted backend holds 64 IRQ
  objects in total (`ERX_BACKEND_PARK_OBJECTS_MAX`), so a hosted run with many programs and pipe ends
  fails earlier than the QEMU runs do.
* [Low] liberx program layer, signals: until signals reach programs, a pipe write to a closed
  reader takes SIGPIPE's default action (the program ends with the signal) unless the start's
  `sigignore` names it, and a run-time `signal(SIGPIPE, SIG_IGN)` is not honoured. It fails safe,
  with a stop of the writing program, never a hang or a wrong answer; output the program would
  have written after the `EPIPE` is lost.
* [Low] liberx program layer, `liberx/program/wake.h`: P6 (docs/design-programs.md) says every
  wait of `liberx` sleeps on the thread's wake word, and no build check holds it. A chokepoint
  rule that lets only `liberx/program/wake.c` and the listed stop and startup waits of
  `program.c` call `erx_umtx_wait`, with a seeded site in its test, would.
* [Low] liberx program layer, signals: a waiter (`erx_prog_waiter_t`) lives on the waiting
  thread's stack while it sleeps, on a pipe end's list or the channel's. A signal design that
  lets a handler leave a wait without returning through it (`siglongjmp` from an upcall) would
  leave a dangling waiter; it must forbid that or take the thread's waiters off first.
* [Medium] session, `erx_pipe:step/2`: the second tier's events are not there: `{deposit}`, `{redeem}`,
  `{discard}`, `{withdraw}` and the collector of deposits no reader can reach
  (docs/design-pipes.md, "The second tier" and "Deposits"), and `holder()` has no
  `{deposit, Ticket}`. `test/erlang/erx_pipe_explore.erl` gains their events with them.
* [Medium] session, `erx_program.erl`, `erx_program_drv.c`, `erx_prog_handler`: no program holds an end of a
  session's pipe yet. The pipe NIF's hand-offs and holder entries and `erx_pipe_srv`'s side are built
  (docs/design-pipes.md, "Hand-offs"); what remains is the program's side: `start/1`'s
  `{N, {pipe_hand, Number, Descriptor}}` entries and the driver's take (`erx_pipe_hand_take`, erx_pipe.h, naming the program by its open command's pid),
  install with each copy's rights, bind of the doorbell with the hand-off's label, release, and
  `erx_pipe_holder_release` after the anchor's release; `erx_program:install/2` with its `driver_caller` check;
  `erx_prog_handler`, which makes the program's holder entry, asks for the ends on its starter's behalf,
  forwards the program's notices with `erx_pipe_srv:forward/1`, holds and writes its reports, and drops its
  hand-offs and hold after a failed start; and the QEMU tests of hand-offs between domains
  (docs/design-pipes.md, "Verification and testing").
* [Medium] session, `erx_pipe_nif.c` and `erx_event.c`: each ring of a session end's doorbell is one
  `{erx_pipe_ready, _, _}` message, uncoalesced, so while an end waits (bits set for that wait only) a
  co-reader that loops on the lock or a writer's repeated crossings can queue many messages before the
  owner reads again, and `erx_pipe_srv:retry/2` leaves the extras in the mailbox. Coalesce per end (a
  ready-sent flag the next `nif_read` re-arms), as a program's doorbell counts triggers once.
* [Low] session, `erx_pipe_nif.c`: when `enif_alloc_env` fails, a `closed`, `drained` or
  `pipe_server_lost` notice is dropped, so a closed end never reaches the server (no eof or `EPIPE`
  follows) or a drained lane is never forgotten. Out of memory only; retry from the next call or
  preallocate one environment per end.
* [Low] session, `erx_pipe_nif.erl`: `make_lock/1`, `make_lane/1`, `make_bell/3`, `hand_make/2` and
  `program_holder/1` are exported, so code that does not come from the tree (an expression at a session's `erl`
  shell, an app installed at run time) can make pipe objects outside the step's `pipes` quota, or make the holder
  entry of a program whose handler has not made it yet and so speak for that program; objects are collected
  with their terms. The build check `tools/lib/erx/pipe_callers.rb` keeps the tree's own modules from calling
  them; restrict them to `erx_pipe_srv`'s and the handlers' processes when `erx_policy` sets the quota.
* [Low] session, `erx_pipe_nif.c` (`end_broken`): the broken-lane line goes to stderr, not to the
  debug log as one escaped line (docs/design-pipes.md, "Failure handling"); it carries integers only.
* [Low] session, `erx_pipe_nif.c` (`get_obj`, `obj_keep`): for a session process's end, `closed` is
  read without `obj_mutex`, and a keep does not refuse a closed object; reachable only if the server
  passed an object after its own close. Check and count under `obj_mutex`, as `obj_keep_held` does
  for a hand-off.
* [Low] session, `erx_pipe_nif.c` (`erx_pipe_hand_take`, `erx_pipe_holder_release`): the NIF knows no
  port, so two ports of one program open at once would share the port's hold, and the first to end would
  send the program's gone while the other still runs; the handler opening one port per program is what
  prevents it. Pass the driver's port as an opaque token to both calls, record it at the first take,
  and refuse a take or ignore a release with another token.
* [Low] session, `erx_pipe.erl` (`copies/1`) and `abi/erx_abi.txt` (`pipe_hand_copies_max`): the
  build checks the limit's arithmetic, not that `copies/1` keeps to it. Add a pure test that fills a
  session's quota with one pipe's write ends and 64 read ends and checks that a read end's descriptor
  has exactly `?ERX_PIPE_HAND_COPIES_MAX` copies.
* [Low] session, `erx_pipe_nif.c` (`holder_gone`): when `enif_alloc_env` fails, the program's gone
  is not sent and the entry is forgotten, so the pipe server keeps the program's ends until it
  restarts and their peers never read the end of the stream. Make the message's env with the entry,
  so sending it cannot fail for memory.
* [Low] session, `erx_pipe_srv` (`retry/2`): each wake restarts the whole timeout, `write/3`'s spec
  leaves out `{error, eio}`, and a timeout after a partial write does not say how much was written.
* [Low] liberx, `erx_pipe_run.c`: the runner relies on its caller for a lane size that is a power of
  two of at least 16 and a mapping of `ERX_PIPE_RING_DATA` plus that size; P7's program ends must
  give the same. `test/host/pipe_run_test.rb` seeds no fault in `run_within` or `run_lane`'s check.
* [Medium] session, `erx_pipe:step/2` (`end_gone`, read end) and docs/design-pipes.md ("Ends and
  their holders"): the pipe server closes a gone read end's doorbell at its gone, while the handler
  may still have installs to make from an earlier step that name it: a child's write descriptor
  lists every read end's doorbell, a child's read descriptor every other read end's, and a
  `pipe_reader` report carries the new read end's. Such an install then fails, so a child's
  creation fails or a running holder loses its end, though nothing was wrong (a reader that exits
  while a sibling's write end is still being installed). The handler's merged join,
  `{pipe_reader, ..., gone}` (docs/design-pipes.md, the program protocol's reports), installs a
  copy of a read end's doorbell after that end went, so as written it can never succeed. A gone
  write end's doorbell avoids this by staying with the server until it forgets the write end.
  Two candidate fixes: a step's installs finish before the server takes its next event, or a
  doorbell closes only once no pending install can name it; either makes both kinds of doorbell
  follow one rule. The explorer applies a step's copies in that step, so it cannot see this; with
  the fix it keeps each holder's copies pending until a separate install event and checks
  `names_only_live` at the install, which shows the race on the unfixed tree.
* [Low] session, `erx_pipe:new/1` (`quota`): the `pipes` quota is a parameter, at most and by
  default `abi/erx_abi.txt`'s `pipes_quota` lanes, until `erx_policy` sets it with M10's principals.
  It counts lanes, so a pipe whose write ends have all gone and drained keeps its lock page and its
  read ends' doorbells outside it, bounded only by its holders' ends; and nothing checks that
  `pipes_quota` stays within the startup grammar's `writers` list (8,192), past which a read end's
  descriptor would outgrow it. Settle both when `erx_policy` sets the quota.
* [Low] session, `test/erlang/erx_pipe_explore.erl`: the exploration of `erx_pipe:step/2` is bounded by
  depth, 7 at the landing gate and 8 at `tools/erx check-fuzz`, not run to completion: a complete run
  with a quota of one lane, numbers up to 3 and two read ends did not finish in 3 minutes. A state key
  that identifies worlds equal up to renaming the two programs (symmetry reduction) may make a complete
  run, or a deeper one, affordable.
* [Low] QEMU harness, `tools/lib/erx/programs.rb`: the programs suite shows that `port_close/1` on a
  running program closes its port, reports nothing and gives back the gate worker's registrations,
  but not that the program's spaces stopped, since a close reports nothing to the session. Check
  the anchor's end with status `ERX_EXIT_SIGNAL` + SIGKILL from the session, through kernel trace's
  `space_end` (as `native_trace` reads a task's) or the inspector, once a session may read either.
* [Low] QEMU harness, `tools/lib/erx/programs.rb`: the suite packs its programs as file entries,
  which `erx_fiasco_task_image_map_body` copies into the space. docs/design-runtime.md, "Programs as
  ports", step 3 maps a boot-image program from its slice with its code shared, the image-entry path
  (`task_segment_share`), which no program of a session runs yet. Pack one as an image entry
  inside the domain release and run it.
* [Low] hosted backend, `liberx/backend/hosted/refused.c`: a hosted runtime runs no programs; the
  channel's first memory object is refused, so `erx_program:start/1` answers `{error, enotsup}`.
  Programs in hosted mode need the hosted backend to make spaces and pass handles.
* [Low] erx_program driver, `otp/erts/emulator/sys/erxos/erx_program_drv.c`: the session makes and
  installs the program's data area, but the session's own mapping of it waits for the handler's
  copier, its NIF, which copies the bytes of reads and writes (docs/design-programs.md, "Descriptors
  and files").
* [Medium] erx_program driver and core (`erx_program_drv.c` `channel_sides`, `install()`;
  `erx_program_core.c` `install_rights`): which channel side sits at which `program_arg` index, how
  the session maps it and what rights the program gets are three tables joined by index, and no
  host test checks that exactly one party may write each side; the `programs` suite's `bigargs`
  checks only what the program receives. Give the core one row per side (index, session
  protection, program rights) with a host check.
* [Medium] liberx program layer, `liberx/program/startup.c` (`erx_prog_startup_plan`): a startup
  message with a descriptor other than `null` or a pipe's read or write end ends the program with
  status 127 before `main`, because liberx sets up no socketpair, file, tty, directory, socket or
  `dup` yet. Each case replaces the refusal with its set-up when the file descriptors arrive
  (docs/design-programs.md, "Descriptors and files"). The table's slots keep no `FD_CLOEXEC` yet,
  which `exec` and `fcntl`'s `F_SETFD` need.
* [Medium] liberx program layer, `tools/fuzz/erx_prog_target.rb` and
  `test/fixtures/prog_profile_frames.rb`: no seed holds a socketpair, file, directory or socket
  descriptor, so a plan that wrongly accepts one of them passes `test/host/erx_prog_fuzz_test.rb`,
  and the harness's socketpair read branch has no seed to start from. Add a start-frame seed per
  kind as each case gets its set-up. The accepted set is also written in three places that must
  agree (`startup.h`'s prose, `find_unsupported_fd` in `startup.c`, `fd_setup_one` in `fd.c`);
  one predicate in `fd.h` that the plan and the set-up both use would make them agree by
  construction, with the harness keeping its own list as the oracle.
* [Low] liberx program layer, `liberx/program/fd.c` and `pipe.c`: a handler bug is trusted rather
  than refused. Two descriptors of one startup message naming the same pipe end make two end
  objects, the reports reach only one, and the second `{closed}` ends the program with `SIGSYS`;
  reports can add lanes to a read end without bound, each costing two mappings. Refuse a second
  descriptor of one end in `erx_prog_fd_setup`, and bound joins by the pipe's write-end quota.
  `erx_pipe_open` closes on failure only the capabilities it kept, which is enough while only the
  set-up calls it and stops the program; a `{pipe}` reply that opens ends in a running program
  must close the descriptor's other capabilities and say whether it owes `{closed}`.
* [Low] erx_program driver: each program costs the session about 304 KiB of its own budget (two
  24 KiB lane sides, the data area at 64 KiB a slot, 256 KiB by default, two IRQ objects) with no session-side bound, since
  `PROGRAM_POOL` is unbounded; many starts can exhaust the session's own budget.
* [Low] liberx program layer, `liberx/program/`: the build check that the layer's entry macro
  opens every function a program may call (docs/design-programs.md, "Verification and testing")
  is not built. Decide with it whether `erx_prog_startup_plan`, a pure function the layer exports
  for its own executor, counts as exported, or moves beside `elf_plan.c`.
* [Medium] liberx program layer, `liberx/program/channel.c` (`erx_prog_channel_send`): the send
  writes a frame whole under the lane's lock, so it refuses with `ERX_ERANGE` a frame whose record
  is larger than the 16 KiB outbound ring, while a spawn's arguments reach 131,072 bytes
  (`args_max`). How a request larger than the ring reaches the session is open for the request
  work: a frame streamed under the lock breaks the rule that the lock is never held across a wait.
* [Medium] liberx program layer, `liberx/program/channel.c`: design-programs.md has the event
  executor send `{waited}` reaps from slot 15 and never wait, but the channel's send may wait
  for outbound room, which only the executor announces. The reap work must give the executor a
  send that never waits (an owed reap it retries on the next channel label, for one).
* [Low] liberx program layer, `liberx/program/channel.c` (`whole_put`): a sender that finds room
  takes it even while others wait, so a large frame can wait behind a steady stream of small
  ones for as long as the stream lasts. A queue of waiters under the lock, whose head alone
  publishes a need, would serve them in order.
* [Low] liberx program layer, `liberx/program/program.c` (`executor_main`): the executor takes
  labels, and so announces outbound room, only once the inbound lane is empty, so a session that
  keeps the inbound lane busy delays every sender waiting for room.
* [Low] `tools/fuzz/lane_writer_fuzz.c`: the lane writer's fuzz target never puts an item marked
  `whole`; the channel's host test (`test/host/prog_channel_test.rb`) covers the all-or-nothing
  put, the whole-record need and the refusal of a record larger than the area.
* [Low] `abi/erx_abi.txt` (`program_arg`): the generator emits no count, so
  `ERX_PROGRAM_INSTALL_DATA` (`erx_program_core.h`) assumes `doorbell` is the last index.
* [Medium] ABI generator, `tools/lib/erx/abi_profile.rb` (`capability_fields`): the generated
  capability walk covers only a union a frame to the program carries. A capability in a
  to-program frame of another kind (a tuple, a map) is neither walked nor refused, which is
  right only for the startup message, since a refused start ends the program. A second
  to-program union holding capabilities would get a walk that no executor code calls, because
  `liberx/program/pipe.c` calls `erx_prog_report_caps` by name. Mark the startup frame, refuse a
  capability in any other to-program frame that is not a union, and refuse a second walked
  union until the executor dispatches walks by frame.
* [Medium] liberx program layer, `liberx/program/inbound.c` (`ERX_PROG_REPORT_MAX`): every frame
  after the startup message is bounded by `prog.txt`'s `prog_report_max`, 512 bytes, which
  `erx_program:send/2` does not enforce. A reply to a worker's request
  (`{erx_prog, 1, Slot, Reply}`), such as `pipe`'s, can carry a read end's descriptor far past it,
  and the header decision cannot tell a reply from a report. Have `send/2` refuse past it with
  `einval`, and size the executor's copy for replies before workers send requests.
* [Medium] docs/design-pipes.md ("Ends and their holders", "The program protocol"): the design
  does not say what a program does with a report for an end it no longer holds, though a
  `{pipe_writer}` can cross the program's `{closed}`. `liberx` closes the capabilities the report
  installed. Write the rule into the design, and say whether `{closed}` cancels the `{drained}`
  such a report made due in the port driver's credit.
* [Low] liberx program layer, `liberx/program/program.c` (`report_apply`): a refused later frame
  stops the program with 127 without the line design-abi.md and design-programs.md require
  (`erx: FRAME frame refused: REASON in KIND at byte N`), and `erx_prog_report_read` drops the
  refusal that names them. Return the refusal and write the line once a program has a standard
  error. The executor also closes whatever capability values a report names, its own channel,
  group, budget, doorbell or data area included; the session is trusted, but refusing a report
  that names one of `self.regs` or the data area is cheap.
* [Low] QEMU harness, `tools/lib/erx/programs.rb`: the inbound decision
  (`liberx/program/inbound.c`) is tested on the host only; no `programs` case sends a program a
  malformed later frame (a non-frame record, a nonzero zero word, a report past
  `ERX_PROG_REPORT_MAX` or one the profile refuses) and expects 127. Add one when the session can
  write a raw record to a program, or once `erx_prog_handler` sends reports.
* [Low] erx_program driver, `erx_program_drv.c`: a frame delivered as `{erx_channel, Port, Frame}`
  is queued with `erts_queue_message` and no `trace_port_send`, so a port traced for sends does not
  show it; trace it as `driver_output_term` does. `end_feed`'s answer to the owner picks the action
  by a list of kinds (THREAD_START, WRITE, BUSY, a STOP's STOP_ANCHOR); have the core name the
  action that answers each input instead. A STOP after the anchor ended answers `einval`, yet the
  program's end later reports the status the image ended with; say in `stop/3`'s doc that a
  refused stop changes nothing, and that STOP carries the session's own kills too.
* [Low] erx_program driver, `erx_program_drv.c` (`program_control`): `CONTROL_SEND` and
  `CONTROL_STOP` act before `answer` allocates the answer's binary, so when that allocation fails
  the owner gets `badarg` for a frame the driver took or a stop it applied. Allocate the answer
  first and fill it once the status is known.
* [Low] erx_program driver and `erx_program.erl`: the port-control wire constants, the command
  numbers, `CONTROL_SEND`'s reply byte for no reply (255), its grant kinds (1 and 2) and its
  13-byte grant layout, are written twice, as Erlang macros and as the driver's `#define`s, and
  `test/host/erx_program_grants_test.rb` copies the 255 once more, against the rule that the ABI has
  one source. `abi/` has no home for a driver's port-control interface;
  give it one in the generator and generate both sides.
* [Low] QEMU harness, `tools/lib/erx/programs.rb`: no programs case delivers a due notice as
  `{erx_channel, Port, Frame}`, since a frame that makes a notice due names a pipe end, which no
  program holds until `erx_prog_handler` installs one. The note cases cover the decode, the credit's refusals and a
  request's delivery, and the host credit test covers a notice's delivery; add a notice case with
  the first program that holds a pipe end.
* [Low] liberx program layer, `liberx/program/program.c` (`main_run`): design-programs.md's step 9
  has the first thread set its signal mask; the layer keeps `sigmask` and `sigignore` in
  `erx_prog_self_t` and applies neither until signals reach programs.
* [Medium] liberx Fiasco backend, `liberx/backend/fiasco/fault_gate.c` (`erx_fiasco_gate_fault`): a
  fault takes any free entry of its space's pool, since Fiasco's fault message names only the task, so
  its record's thread is unknown and design-stopgap.md's "a fault in its thread's record" does not
  hold. A task that reaps a faulted thread and faults again at that index can run its pool out, and
  later records are dropped. A Fiasco gate per thread, labelled with task and index, as each thread's
  pager would name the thread and make the bound hold by construction; decide whether that is worth it
  on the stopgap or a residual until erXos's kernel.
* [Low] liberx Fiasco backend, `liberx/backend/fiasco/fault_gate.c` (`gate_space.dropped`): records a
  gone gate drops are counted but nothing reports the count; the inspector's space report (SV4) should
  show it.
* [Low] liberx Fiasco backend, `liberx/backend/fiasco/budget.c` (`erx_fiasco_budget_named`): a
  create whose budget is `ERX_CAP_NULL` charges the caller's own budget, as `ERX_CAP_SELF` does, because
  about fifty callers (the launcher, `erx_device.c`, the function_api and native_space guests) still pass 0.
  `erx_budget_create`'s parent is read the same way. Move them to `ERX_CAP_SELF` and refuse `ERX_CAP_NULL`
  with `ERX_ETYPE`, on the hosted backend too.

* [Medium] stopgap, `liberx/backend/fiasco/budget.c` (`budget_takes`): a budget's end takes a group charged to it while the group's home task still runs, when that task's space is charged elsewhere, so the home loses its group and its doorbells stop delivering; design-stopgap.md's "Budgets and groups as records" says the first sweep stops the home task of every such group instead. Any task can now build this. Either stop the home in the spaces sweep, or refuse at `erx_fiasco_group_admit` a home whose space is not below the group's budget; add a native_space case first.
* [Low] stopgap, native_space and native_task suites: no case checks that a task's end frees the budgets, groups and doorbells it made (the drain path), since the root's checks count pool pages only, not IRQ slots or object records; add a root-side count of live IRQ slots and records.
* [Medium] liberx Fiasco backend, `liberx/backend/fiasco/task_refused.c`: in a task,
  `erx_vm_free_pages` reports 0 while commits through the service still succeed, an
  invented count that `api.h`'s exact contract does not allow; it should answer
  `ERX_ENOTSUP` (the call needs a status return) or the domain budget's room.
* [Medium] domain library, `liberx/system/dom_boot.c` (`erx_dom_boot_up`): each principal's
  group is a plain `erx_group_create(0, 0)`: no `users` group with the manifest's
  `users_share`, no principal group under it, and the principal's share never applied
  (docs/design-system.md, "The root task", step 2). The stopgap ignores the parent, so
  nothing notices yet.
* [Medium] domain library, `liberx/system/dom_apply.c`: two stopgap details reach permanent
  code: the fault thread's `erx_dom_lib_take` uses the stopgap's `erx_ipc_wait(deadline,
  *label)` before the target receive signature is settled (the `erx_ipc_wait` item above),
  and the boot image is named by 0, the root's name for the stopgap's whole archive, in `erx_image_slice` and
  `erx_image_map`;
  `erx_dom_held_t` should hold the image's handle.
* [Medium] domain library, `liberx/system/dom_apply.c` (`apply_pass`): design-system.md A7
  asks that every `erx_cap_pass` of the library go through one function, `erx_dom_install`,
  with a chokepoint rule in `tools/lib/erx/chokepoint_rules/` and its seeded violation;
  `apply_pass` is the one call, for a creation's and a connection's installs, but it takes a
  bare rights mask rather than the `erx_dom_grants` row, and no rule checks it.
* [Medium] domain library, `test/guest/native_domain` (`hook_step`): the hooked failure
  refuses a step before it is applied or after it completed, never between a step's two
  calls (a bell's create and bind, a group's create and configure), so a handle noted
  only after the second call would pass the undo cases. Put a hook point between the calls.
* [Low] domain library, `test/guest/native_domain` (`case_link`): the case checks each
  party's connection values only as present and its labels; no party maps its sides or
  triggers the other's bell, so a swapped side or peer side would pass.
* [Low] domain library, `liberx/system/dom_apply.c`: `apply_plan` and `erx_dom_lib_connect`
  repeat one apply loop (hooks, record, undo of the refused step included); the device give
  will be a third. One runner over a step list, or a core undo for "refused at step k",
  would keep the rule in one place. `link_value` also restates the connection rows of
  `erx_dom_grants`; a role carried in the row would remove that second list.
* [Low] stopgap, `liberx/backend/fiasco/object.c` (residual of K25): a destroyed object's
  entries in other tables stay stale until their holder closes them, so a refused connect
  leaves up to three stale entries in each party's table that the party never learns, and a
  disconnect leaves the party's three to close. erXos's kernel clears them at the delete;
  the stopgap is not to rebuild that. The library's own close after a destroy relies on the
  stopgap's stale entries too: under K25 that close names a freed slot, so the Phase 2
  library must not close what a delete already cleared.
* [Medium] domain library, `test/guest/native_domain`: no case fails a step after it made its
  object (a bell's bind, a group's configure), and none checks that the root's handle table
  returns to its starting occupancy after a retire or an undo, which would catch a handle the
  library forgot to close.
* [Medium] domain library, `tools/fuzz/dom_core_fuzz.c`: the planner's view has no devices, so
  `dom_plan_gives`, `ngives` and the GIVE-before-BOOTINFO order are never reached through
  `erx_dom_plan_configured`. Give the view fuzzed device entries with fuzzed rows, and check in
  `fuzz_check` that a configured plan gives every entry of its row once, to its own holder and
  slot, with its GIVE steps just before BOOTINFO.
* [Medium] domain library, `liberx/system/dom_apply.c` (`apply_keep_gives`, `lib_devices_end`):
  a device record's `holder` is a stored field that two effects outside the host-tested core keep
  in step, and ERX_EBUSY and `devices/0` read it. Only a domain of the entry's row holds the
  device and every living domain of the row holds all of its devices, so derive the holder from
  the living domains (`life_alive` and `erx_dom_from_row`) and keep only the handles the end
  needs in the record.
* [Low] domain library, `liberx/system/dom_core.c` (`erx_dom_plan_check`): the check has no
  view, so it cannot refuse a plan whose gives repeat a device index or name an entry of another
  row; `dom_apply.c` indexes `device_records` by `give->index` on the strength of plans coming
  only from the planner. Check distinct indices in the plan check, or re-check gives against the
  library's view in `erx_dom_lib_apply`.
* [Low] domain library, `liberx/backend/fiasco/runtime_entry.c` (`library_up`): the boot pair
  (`lib.boot`) and the writable `device_records` are set beside the view rather than by its
  constructor, so a constructor that forgets either fails a creation (an unnamed pair) or
  dereferences NULL (records); `erx_boot_pair_words` also writes a pair
  `erx_boot_pair_valid` would refuse. Pass both to `erx_dom_view_build`, and refuse an invalid
  pair there.
* [Low] domain library, `include/erx/device_kinds.h`: no check ties a kind's peripheral name to
  `ERX_BOOT_NAME_WORD_MAX`, so a kind with a longer name would make every creation of its holder
  fail with ERX_EINVAL. Refuse it in the view build or test the table.
* [Medium] domain library, `liberx/system/dom_core.c` (`dom_check_sizes`): every crash area is
  `ERX_CRASH_SIZE`, 16 KiB, not design-runtime.md's per-domain size with its 1 MiB default, so
  a full dump arrives truncated with its slogan intact, and the design's one-page crash area
  test cannot be written: `limits.crash` never reaches the view. Take the size from the
  startup limits and add that test.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl` (`slogan/3`): a
  crash's slogan reaches only the death record and its dump text is read and dropped, since
  no inspector exists to show either; design-runtime.md, "Crash handling", has the inspector
  show both through its escaping.
* [Low] console, `liberx/backend/fiasco/console.c` (`erx_fiasco_console_write`): once the console
  driver holds the UART, four writers still reach it through `l4_vcon_write` beside the driver, so
  their bytes can fall between the driver's at any byte: the system domain's own ERTS C output
  (`libc_root_write.c`, a byte per call for `erts_fprintf`), the park report (`park_report.c`), the
  root's fixed lines (`root.c`, `thread.c`, `vm.c`, `service*.c`) and a program's output through
  `task_write`. A domain's runtime already logs whole lines (`domain_entry.c`). Have each reach the
  console through `erx_console` too: the root's lines and the park report as debug log records, and
  program output by a raw form the ring does not have yet. The service also still answers
  `task_write` from a domain's task, which its runtime does not call: refuse it there, so a
  domain has no raw path to the console. A record `erx_console` writes still starts wherever the
  console's line stands, after a prompt with no newline included (`1> #0 ... debug space 0: erx_blk:`).
* [Low] ERTS, `otp/erts/emulator/sys/erxos/erx_crash_area.c`: a fatal end reaches the crash area
  only through `erts_exit`, `ERTS_EXIT_AFTER_DUMP`, `ERTS_SYS_ABORT` and `erl_assert_error`; any
  other direct `abort()` in ERTS ends the domain as a fault with no slogan. Give `abort` an
  `only_` section of `imports.txt` held by the crash path, so every fatal end goes through it.
* [Medium] domain library, `liberx/system/dom_install.c` (`erx_dom_install`): design-system.md
  A7 and "The grant table" have the install funnel take a row of `erx_dom_grants`, but it
  takes a step with a raw object, recipient and rights and checks only the step's kind. That
  the rights lie within the row and the recipient is the row's rests on `erx_dom_plan_check`
  having run first, and chokepoint `dom-install-funnel` checks only that every `erx_cap_pass`
  is spelled inside the funnel. Have the funnel take the row and the plan, derive the object
  and the recipient from them, and refuse rights outside the row's.
* [Medium] domain library NIFs, `otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c`
  (`fault_main`): an end is lost for good when no process is registered, as for a domain the
  root made before the domain service registered. The library has already torn the domain
  down, so its ended record keeps its view slot and its principal's domain count, and
  `retire/1` needs an id nobody heard. Keep a reported flag per record in the view, set when
  the report is sent, and have `register/0` send every ended record not yet reported.
* [Low] domain service, `erx_domain_srv:restart/4` and `liberx/system/dom_boot_view.c`: a
  configured domain the manifest marks `required` (`mf_domain_flags`, `abi/manifest.txt`) is
  left down beyond its restart intensity like any other, where design-system.md "Boot failure"
  ends the machine. The boot view's configured row carries no flags, so `erx_domain_lib`'s
  `configured()` cannot say `required`, and the service's `{no, Next}` answer logs "left down"
  for every domain. No manifest marks a domain `required` yet, and leaving it down fails safe.
  Carry the flag into the row and end the machine on it, with the end's reason in the log and a
  host test of the decision.
* [Low] domain service, `erx_domain_srv:session_start/3`: a start's `display` may name any
  service its template is granted, not only a display, since no `windows` service exists to
  check it against; the mint then carries `session` to a server that ignores it. Check the
  name against the manifest's displays once `abi/services/windows.txt` exists. Two starts
  naming one display both get the mark: only `erx_starter`'s keepers pass `display`, and
  design-display.md wants one display's session, so whether the domain service refuses a
  second is a design question for Track D.
* [Medium] system console, `erx_console:system_source/1`: the system domain's log records take
  the line's principal, which the console learns from the domain service at its first session
  start, so records before the service has built the boot's configured domains say `principal
  unknown`, and a release login will make the line's principal a user's. Give the system domain's log records the system principal
  apart from the line's principal, once the domain service has named it.
* [Low] manifest packer, `tools/lib/erx/manifest.rb`: a principal's name is checked to fit
  `<name>_<names>` in 63 bytes, but a session name may take a number past `names` when
  another principal holds a lower one, so a long name's later start is refused with
  `bad_identifier` rather than the library's quota. Bound the name by the domain service's
  names quota.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl` (`create/2`):
  `erx_domain:create/1` takes the domain library's own request fields (the boot image's
  runtime and release indexes, the budgets, the grant), where design-domains.md "Erlang
  interface" has a spec of a release name and a resource policy compute them. Replace the
  fields once release lookup by name and the resource policy exist. The runtime index goes
  with them: the domain service maps the spec's `flavour` (default `jit`) to `runtimes/jit` or
  `runtimes/emu` and, under `erx.det=1`, forces `runtimes/emu` for every domain, configured rows
  included, whatever it names (design-runtime.md, "BeamAsm"), once the boot's mode reaches the
  system domain. Until then a create names the BeamAsm image by its index and gets it in any boot mode.
  The release name replaces the stopgap's `boot` field too: once the library takes the
  release by name it binds `-boot` itself, and the two bindings in the manifest's packer
  (`Erx::Manifest#boot_args`) and the service (`boot_args/2`) go, with the gap
  design-domains.md records for system-domain code that calls `erx_domain_lib:create/1`
  directly and names its own `-boot`.
* [Low] domain library, `liberx/backend/core/boot_info.c` (`erx_boot_argv_fill`): the node
  flag (`-sname` or `-name` and the domain's node name) follows the boot page's args, so args
  that end in `-extra`, or in a `-S` with no later `--`, make it a plain argument and the
  domain boots without its node name. Place it right after the args' first `--`, as the
  packer and the domain service place `-boot`.
* [Medium] lane driver's finish, `otp/erts/emulator/sys/erxos/erx_lane_drv.c` and the
  system_domain QEMU suite: the finish's decisions are tested on the host
  (`test/host/erx_lane_core_test.rb`, with the cut record, the full answers bound and their
  seeded failures), but no QEMU test runs the driver through them end to end. A peer that
  halts with half of a long record published, and a finish whose outbound lane is full with
  the bound on unsent answers reached, each ending with `{domain_down, D, Info}` and the cut
  record counted as dropped, cannot be reached on purpose from the shell, and a port's counts
  are gone once it ends, so each needs a test hook that holds the system side's input task.
  The burst cell's seeded failure (an agent that ends the port without the finish) does not
  fail either: the domain service is suspended while erts halts, so the system side has read
  the whole burst before the side ends; the same hook would hold the input task until the
  service ends the side. The same hook would show that `close_side` keeps a ready report
  still in the lane when a domain reports and ends at once (medium_boot's halting
  domains), which only the finish guarantees.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_pid.erl`: a domain can
  fill its domain pid's mailbox as fast as its lane delivers, and the pid passes each
  answer-shaped message after the ready report on to the domain service, which every domain
  shares, and which drops and counts each one no connection expects (design-system.md "What
  a domain sends the domain service"). A count is one integer per domain, but the time
  each message costs the pid and the service is not bounded. Bound what a domain can make
  the pid and the service spend.
* [Medium] facets, `erlang/apps/erx/src/erx_facet.erl` and `erx_domain_srv.erl`
  (`grant_facets/3`, `facets/2`): the facet behaviour checks the origin, the reply target, the
  encoded size against `max_request` and the limit in flight, and nothing else of
  design-domains.md "Facets". Stopgap residuals, of fairness and memory rather than
  authority: no admission by the grantee's measured share of reductions, no queue quota and
  no heap limit, so a grantee can fill its facet's mailbox and the facet's heap as fast as its
  lane delivers; `max_request` is checked by the facet once the message is decoded and
  queued, not by the funnel before, and likewise a query worker (`erx_inspect_worker.erl`)
  drops an agent's answer past `inspect_message_heap_min` words by its decoded size once it
  is queued, not the funnel before it; and admission is hand-written, not the generated path
  from the service's operation schema. The funnel (`facets/2`) hands on only `console`,
  a literal clause of `facet/3` beside its TODO.md item, and refuses every other
  name with `{bad_spec, facets}`, a name of the table included (`attenuated/2`), since
  handing on the starter's own recorded facet would pass it on unattenuated. Phase 1
  residual: `console` takes any local process the system domain
  hands, which only trusted system-domain code can do; it goes with the console item above,
  which declares it. Build the
  attenuating hand-on of design-domains.md "Handing a facet on", which mints a facet in
  front of the starter's within its grant record, and let `attenuated/2` hand recorded
  names on through it. Attenuation alone does not keep design-system.md's "The manifest"
  property 8 (only the system domain holds a facet of driver control): design the rule
  that ties a hand-on to the manifest's facet rows for the new domain first, in
  design-domains.md "Handing a facet on". The facets `grant_facets/3` starts in front of a spec's grants and of
  the system domain's served ones need grant records of their own for a starter other than
  the system domain to hand one on. Until then the funnel's table lookup (`declared/2`)
  decides nothing a test can see, since `attenuated/2` refuses every name of the table too.
  Missing besides: `erx_domain:grant/4`. Init waits at most 5 s for the answer and then
  runs with none.
* [Medium] domain service and manifest check, `erx_domain_core:restart/5` and `tools/lib/erx/manifest.rb`
  (`normalize_domains`): a configured row may restart `restarts` times within `restart_period_s`, and
  a boot that hangs is stopped only after its `boot_timeout_s`, so a row with `restarts` above 0 and
  `restart_period_s` at most `restarts` times `boot_timeout_s` never reaches its limit and restarts a
  hung boot without end. Refuse such a row in the manifest check; the test rows derived from
  MediumBoot's with `restarts 1` and `restart_period_s 5` (`system_domain_regrant.rb`,
  `device_give.rb`) then need a longer period.
* [Medium] domains, `liberx/system/dom_life.c` (`life_connections`) and design-domains'
  limits table: the table says a domain's `connections` counts the system connection,
  and `life_connections` leaves it out of the quota, which the development manifest's
  counts follow (storage 2, root's session 3). Make the two agree, and check whether
  `ctl_slots = connections` (`dom_apply.c`) then needs a slot for the system connection;
  write the derivation of the machine's `max_connections 8` beside it in the manifest.
* [Medium] facets, `erlang/apps/erx/src/erx_facet.erl` (`provide/2`) and `erx_domain_srv`: that a
  mint's end ends its domain, so its restart provides again and the grants are made anew, is each
  server's duty (a permanent application whose process the mint is), and nothing enforces it: a
  mint under a supervisor is restarted, `provide/2` refuses it, and its service grants nothing
  until the domain restarts; `init:restart/0` erases the provides and the domain pid takes no
  second report. Make it hold by construction: the domain service monitors each accepted mint and
  stops the incarnation at its end (or init halts the node at a reported mint's end).
* [Low] facets, `test/erlang/erx_domain_mints_fuzz.erl`: the mint fuzz target sends no
  session events (`session_ready`, `session_ended`); the exhaustive explorer covers them, and
  their fields are the domain service's own, but the fuzz oracle should hold session grants too.
* [Medium] tests, `tools/lib/erx/system_domain_regrant.rb`: the re-grant boot's connection room
  has no slack (`MORE_CONNECTIONS = 2`, root_1's session limits `connections 1`). After erts
  halts, each introduced pair row is freed only when its survivor lets go, so erts's next
  incarnation is introduced only because its boot outlasts that release; a slow survivor on a
  loaded multi-CPU cell would leave a grant at `none` and fail the cell. Wait for the old pair
  rows to go (or give the room one row of slack) if the cell flakes.
* [Medium] facets, `erx_facet_mint` and configured servers' mints
  (`test/erlang/apps/erx_echo_test`): the mint request names the grantee by its domain id only, so
  a configured server has nothing to put in the facet's `ends_with` for the grantee, and a facet
  minted for an incarnation that ended lives on until its server ends, one per grantee restart,
  and one per session for each grant to a session template, so per login.
  It admits only that grantee's id, which no later domain takes, so it grants nothing; it is a
  leak, and design-system.md's "ends with its grantee" has no mechanism behind it for configured
  servers. Give the mint a handle that ends with the grantee's incarnation, and have the
  re-grant boot check the old facet ends.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl`: the names
  quota is fixed at 64 per principal, not the manifest principal's own field, which the
  library's view does not expose yet. Expose it in `configured/0` (or a principal entry) and
  use it.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl`
  (`start_configured/2`, `restart/2`): a configured domain that fails to start, or ends
  beyond its restart intensity, is only logged, also when the manifest marks it `required`,
  which `configured/0` does not report yet; design-system.md has a required domain end the
  machine as a fault would. Report the mark and end the machine on it.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl`: the service
  trusts every system-domain process. It acts on any `{domain_ended, Id, End, Record}` and
  on a plain `{'EXIT', DomainPid, _}` message, so a forged one retires or stops a domain,
  and a malformed forged report (an end kind `erx_domain_core:info/1` has no clause for, an
  id that is not an integer) crashes the service, which ends the machine. Other domains cannot send either: their messages
  arrive in the `erx_origin` envelope. Tag the library's reports with a secret the NIF
  hands the registrant.
* [Medium] watchdog, `erlang/apps/erx/src/erx_watchdog.erl`: the process pets unconditionally
  and makes no liveness calls, where design-system.md (A6, and the failure table's row for a
  domain service that stops answering) has it pet only after every listed service answers
  within the period, and kill a domain service that does not, whose end then ends the
  machine. A deadlocked domain service therefore leaves the machine up. Make the calls.
* [Medium] domain service, `test/erlang/erx_domain_tests.erl`: nothing tests the `ebusy`
  and `erights` answers, which the stand-in library never gives. Add a stand-in that
  refuses.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl`, `erx_ident.erl`: pooled names are
  `<principal>_<n>` ([Identifiers](docs/design-system.md#identifiers)), so stock net_kernel accepts them, but
  an identifier still may hold `.`, which net_kernel refuses in a node name. Build the name pool, and make a
  domain's node name refuse a `.` before the domain boots with an `-sname` its own distribution refuses.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl`: the name pool
  (`<principal>_<n>`, [Identifiers](docs/design-system.md#identifiers)) is not built. Build it.
* [Low] domain library, `liberx/backend/core/boot_info.c` (`node_flag`), `boot_info.h`,
  `test/fixtures/boot_info_driver.c`, `docs/design-runtime.md`: a host is an identifier and has no
  `.`, so the `-name` branch for a dotted host is unreachable; always pass `-sname`, delete
  `BOOT_FLAG_DOTTED` and its test case and sentence, and have `erx_boot_info_read` refuse a node
  whose two parts are not identifiers.
* [Low] ABI, `abi/manifest.txt` and `tools/lib/erx/abi_contracts.rb`: the identifier rule has
  seven hand-written copies (`erx_ident.erl`, `erx_etf.c` `node_ok`, `dom_core.c` `dom_name`,
  `abi_binary.rb`, the emitters `abi_emit_erlang.rb` and `abi_emit_reader.rb`, `manifest.rb`
  `IDENTIFIER`). Define the `identifier` string class once in the ABI source and generate the C
  predicate, the Erlang predicate and the Ruby pattern from it.
* [Low] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl` (`admit/4`): a
  request name of the pooled form (`<ident>_<digits>`) is not refused with `name_taken`, as
  design-system.md "Identifiers" says; where the root built no library the service still
  admits a name under an empty host and makes an atom such as `'web@'` before the create is
  refused; and `restart_period_s 0` reads as no limit. Refuse the pooled form, refuse before
  admission when there is no library, and decide the meaning of period 0.
* [Low] domain library, `include/erx/dom_lib.h` (`ERX_DOM_HOST_MAX`): the host bound is 64
  bytes and `dom_boot_view.c` checks only its length, where design-system.md has the host an
  identifier of at most 63. Check the host with the identifier rule and bound it at 63.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_ident.erl`: identifiers are an
  opaque type checked at `erx_ident:new/1`, and Dialyzer is the only check that no other
  module builds one. design-system.md "Identifiers" has a build check over the system
  domain's syntax trees fail on a record expression that builds a named record outside its
  owning module; add it (as `tools/lib/erx/ns_writers.rb` checks its Erlang rules).
* [Medium] domain library NIFs, `otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c`
  (`fault_main`): the fault thread waits at the gate with `ERX_WAIT_FOREVER`, while
  design-system.md A3 has its wait time out to check the ending record's deadline; add the
  timeout once `erx_dom_end_begin` keeps a deadline. The thread also ends without a
  diagnostic on a take refused for any reason but a message that is not a record, after which
  no domain's end is handled; report that to the registered process or the log.
* [Medium] domain library NIFs, `erlang/apps/erx` and `test/guest/native_domain`: no test
  reaches the module's paths with a library present: a real create's decoding refusals (an
  unknown key, a u32 overflow, strings beyond the boot page), the lock, the fault thread's
  bind handshake and the `{domain_ended, ...}` message. medium_boot's `domain-lib`
  checkpoint covers only the shape refusals that come before the library. Add them to the
  end-to-end create, start, stop, `domain_ended` and retire cell once the library's boot
  view exists (DL2d).
* [Low] domain library, `liberx/system/dom_apply.c` (`apply_install`): it takes its rights
  from an `erx_dom_grants` row but is neither so named nor checked by a rule.
* [Medium] domain library, `liberx/system/dom_core.c` (`erx_dom_plan_record`): the record
  fills only the plan-made fields and leaves the capability fields of a reused slot for
  the applier, so one function should write the whole record from the plan and the
  apply's made objects; dropping `const` on the view's tables lets every planner write
  them, so give the record functions their own writable tables and keep the planners'
  view const; and a stale partial-boot plan (no connection number) passes record's
  re-checks, which a view generation stamped into each plan would refuse whole. The host
  planner records each plan at once and meets none of these. Found by MF1b's review.
* [Low] domain library, `liberx/system/dom_apply.c` (`erx_dom_lib_record`): the record
  enters `ERX_DOM_ENDED` whatever `teardown_apply` and its own-budget destroy returned,
  and `dom_system_reserve` stops counting an ended configured domain's grant because its
  group went with that budget; a failed destroy would leave the group under `system`
  uncounted, so a restart of its row could pass the reserve. Enter ENDED only on a
  destroy that succeeded, or keep such a record counted.
* [Low] domain library fuzz target, `tools/fuzz/dom_core_fuzz.c`: the planning view's
  records are always `fuzz_domains`, so the input never chooses a living, ended or
  garbage record for `dom_system_reserve` to sum; seed them from the input and check an
  accepted configured plan against an independent sum of the counted rates.
* [Low] manifest check, `tools/host/dom_plan.c`: a refusal of property 12 names the
  status alone (`inval` covers a grant past `system`, the reserve, files and limits),
  so the operator cannot tell which sum failed; and the fuzz target's
  "a second plan of one id is refused" holds by the full table (`max_domains` 2 in
  `tools/fuzz/dom_core_fuzz.c`), not by the duplicate-id check. Have the planner print
  the refusing check, and give the fuzz view a third record.
* [Low] docs, `docs/design-domains.md` ("connections" quota): it counts the system
  connection in a domain's `connections` quota; the library (`life_connections`) and
  design-system.md do not, and property 12 enforces the library's reading.
* [Medium] packer, `tools/lib/erx/production_image.rb` (`build_test_image`): a test
  image's `domains:` is checked against no manifest row, since the test manifest is the
  development one grown. Build test images' domain boot scripts from their manifest's
  rows, as the production image does.
* [Medium] manifest check, `tools/lib/erx/manifest.rb` (`Stopgap#check_and_place`):
  facet records are refused (`unsupported`, naming M5) after properties 2, 10 and 11
  are proved over them, because a facet's operations and parameters resolve against its
  service's generated declarations and grant checker (design-abi.md, "Services, facets
  and their parameter schemas"), which the packer does not read; so no admitted
  manifest has a facet and the boot order is name order. A service's `interface` is a
  number, not the qualified ABI service name, and the server's release is not checked to
  supply it. design-stopgap.md lists `facet` among the records the check accepts.
* [Medium] manifest check, `tools/lib/erx/manifest.rb` (`Stopgap#check_facets_supported`):
  a facet that names an operation or a parameter is refused (`unsupported`, naming M5),
  because those resolve against its service's generated declarations and grant checker
  (design-abi.md, "Services, facets and their parameter schemas"), which the packer does
  not read; the boot view refuses one too, so an admitted facet grants its whole service.
  A service's `interface` is a number,
  not the qualified ABI service name, and the server's release is not checked to supply
  it.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl` (`served/2`): a
  configured domain's facet of a service the system domain serves ends with the process
  behind it, and when that service restarts and names a new process (`erx_facet:serve/2`)
  nothing grants the domain a new facet, so the domain finds the facet dead until it
  restarts itself. Re-grant through the installation path (`{erx_facets_install, ...}` and its
  acknowledgement) when a served name gets a new process, with a host test.
* [Low] manifest check, `tools/lib/erx/manifest.rb`: a facet row's `max_request` and
  `in_flight` may be 0, which makes a facet that refuses everything (the domain service leaves
  a system-served one out), and `max_request` is not held to the grantee's `max_frame`
  (design-domains.md, "Facets"). Refuse both at the check, with tests.
* [Low] manifest check, `tools/lib/erx/manifest.rb`: `system_reservation` is 0, so the
  system domain's reservation for `max_domains` admitted domains (property 4) is not
  counted against `root_memory`; design-abi.md has the production admission planner
  derive it, and nothing on the stopgap enforces it. The system domain's `max_frame` of 512 KiB,
  `inspect`'s frame floor, makes each connection's term of it (a record buffer and a funnel scratch
  kept at its high-water mark, about twice the frame) four times what 128 KiB made it, and a
  `max_request` up to 512 KiB is not held to its server's `max_frame`; an `inspect` holder adds
  `in_flight` times `inspect_worker_heap`, 32 MiB per holder at `in_flight` 2 (design-live.md, "The query worker");
  nothing reserves it, and the enforced bounds are the worker's `max_heap_size`, `in_flight` 2 and
  `inspect_query_max`.
* [Medium] manifest check, `tools/lib/erx/manifest.rb` (`Stopgap#normalize_domains`): a
  configured domain's limits record (memory, outer, lane, connections, crash, flags,
  peer-held bounds) is not held to its principal's `ceiling_limits`, which design-abi.md
  ("Domain identity and placement") asks; only the runtime limits are, by the planner.
  Data and FAT windows may be held by any configured domain, since nothing identifies a
  storage domain (property 8); the slot writer's windows are the system domain's.
* [Medium] manifest check, `liberx/system/dom_boot_view.c`, `tools/host/dom_plan.c`: the
  host planner builds the boot view from the packed manifest with the root's own builder,
  but three things still rest on two sides. (1) The boot order and the introductions come
  from Ruby's rows as plan lines, not from the packed `boot_order` and `introductions`
  tables, and a domain's id (`ERX_DOM_SYSTEM_ID + 1 +` its place) and each party's lane
  side are the planner's rule alone; put the walk of both tables in one pure function the
  boot sequencer will call too. (2) Each file's `offset` and `size` are 0 on the host while
  the root reads the entry's span, so a release slice's `STEP_MAP` size differs between
  the plan checked and the plan applied; pass the spans once the pack is laid out. (3)
  Whether an entry starts with an image manifest is `row['image']` in `plan_file` and
  `row.key?('plan')` in `PackWire#write_image`; one helper should give an entry's head
  for both.
* [Medium] manifest check, `tools/lib/erx/manifest.rb` (`Stopgap#check_plans`),
  `tools/lib/erx/pack.rb`: a manifest with no configured domains is planned, and the
  domain library's boot view built, only when the caller passes a planner, so a pack
  built without one admits a principal `erx_dom_principal_check` refuses, or two units
  sharing a register page, which the root then refuses at boot. Every pack in the tree
  passes one; make the planner a required argument of `Pack.new` and `Manifest.admit`,
  pass `accepting_planner` in the tests, and delete the nil branch.
* [Low] manifest check, `tools/lib/erx/manifest.rb` (`Manifest.release_names`): the image
  builds the releases its rows name before the manifest is checked, so a release named
  like another artifact fails as an artifact clash, not a manifest diagnostic.

* [Low] liberx Fiasco backend, `liberx/backend/fiasco/service_task.c` (around line 354): `erlang:halt/1`
  with a slogan in the system domain writes no crash record, since the root task's own stop takes the end
  path with no fault; [design-system.md](docs/design-system.md) "The crash record" gives a halt the cause
  `halt`. musl's `abort()` meanwhile ends in a store to address 0, because `tkill` answers `ENOSYS`
  (`musl/src/internal/erxos/syscall.c:290`), so an abort reads as a fault rather than as an abort.
* [Medium] domain library, `liberx/system/dom_core.c`: a specification
  with `ERX_DOM_SECRET`, or a release file marked `ERX_ENTRY_SEAL`, is
  refused with `ERX_EINVAL` until the vault exists (M11); the plan then
  needs the sealing-page mapping and install of
  [design-system.md](docs/design-system.md#creating-a-domain), step 5.
* [Low] domain library, `dom_core.c`: `ERX_DOM_SPACES` is not gated by
  the principal's policy, which design-system.md requires for an ordinary
  domain; add the policy bit with the principal work after Phase 1b-A's
  one built-in principal.
* [Low] domain library, `include/erx/dom.h`: `ERX_DOM_BELL_BYTES` (a page
  per bell) is a hand-chosen bound; it should be the kernel's IRQ object
  cost.
* [Low] domain library, `dom_core.c`: `erx_dom_plan_check` checks a
  plan's structure (order, charges, grants) but not the fields derivable
  from its specification (slice index and count, carve and object sizes,
  the parent); cross-check them so a wrong field fails before apply.
* [Low] domain library, `dom_core.c` `dom_grant_rate`: rates round up,
  the parent's too, so a child within a thousandth of a CPU of a tiny
  parent fits it; compare quota over period exactly.
* [Low] domain library, `dom_core.c` `dom_check_files`: a runtime image
  flagged `ERX_ENTRY_SYSTEM` is refused; confirm against the boot image's
  layout for domain releases (IM1) that service domains never run the
  system release's ERTS entry.
* [Low] domain library, `liberx/system/dom_life.c`
  `erx_dom_plan_device_give`: it plans a device-tree entry (its resource,
  a window per range, an IRQ object per line, a DMA window or contiguous
  memory); a PCIe function's give, with its BARs carved inside the
  bridge's windows, its MSIs and its requester id's stream
  ([design-system.md](docs/design-system.md#devices)), lands with the PCIe
  enumerator.
* [Low] domain library, `liberx/system/dom_boot_view.c` and
  `erx_dom_plan_device_give`: the catalogue has an entry per device, so a
  unit of several devices that share a register page (the Raspberry Pi 4's
  mini UART and auxiliary SPI controllers, two of QEMU `virt`'s virtio-mmio
  transports, 0x200 apart) cannot be given to a configured domain: each
  entry's window covers the shared page and the give refuses overlapping
  entries, so the boot view, and with it the build, refuses such a unit on a
  configured row. A shared line is one IRQ object per creation, made in the
  first give that names it, which later gives of the unit name through
  `erx_dom_give_line_t`. Make the give the unit's, with one window per page
  run and one IRQ object per distinct line, as
  [design-shared-devices.md](docs/design-shared-devices.md#the-unit-rule)
  has it, before a board places such a unit outside the system domain; that
  deletes `erx_dom_give_line_t` and its cross-give checks.
* [Medium] drivers, `erlang/apps/erx_blk` (and `erx_net`, `erx_fb`): no
  configured domain's driver starter calls `erx_irq_line:start_owners/1`, so a
  driver on a line its unit shares, which the domain library now marks
  shared in a configured domain's records, fails its start with
  `{error, unbound}`. `erx_blk_sup` starts the owners before the device
  process, `rest_for_one`, as
  [design-storage.md](docs/design-storage.md) "The SD controller's line"
  has it; land it with the Raspberry Pi 4's SD transport, the first driver
  on such a line.
* [Low] fuzzing, `tools/fuzz/dom_core_fuzz.c`: `erx_dom_plan_device_give` is
  fuzzed with an empty holder, so `life_line_source`'s walk of the earlier
  gives never runs. Seed the holder's gives from the input and check every
  plan the planner returns against `erx_dom_device_check` and the
  creation's line rules (`dom_give_lines_ok`).
* [Medium] domain library, `liberx/system/dom_boot_view.c`, `boot_devices`:
  the refusal of a split unit says which relation met (a register page or an
  interrupt line) but not which two devices or which line, where
  [design-shared-devices.md](docs/design-shared-devices.md#refusals) names
  both devices. Record the pair's two entry indices in the view, print them
  from `tools/host/dom_plan.c`, map them to device paths and the line in
  `Manifest` `check_plans`, and have the root's log line print both paths from
  the manifest's strings; assert the names in `test/host/dom_planner_test.rb`.
* [Medium] device service, `erlang/apps/erx_domain/src/erx_devices.erl`: the
  boot view relates only the devices the manifest places, and the platform
  records list a few of the machine's devices (QEMU `virt`'s record lists 3 of
  its 32 virtio-mmio transports), so a holder's page can cover, and its line
  carry, devices no record names. They go to no domain, so no page or line is
  held twice, but the device service's boot check of
  [design-shared-devices.md](docs/design-shared-devices.md#the-unit-rule),
  which relates the catalogue to the kernel's listing and gives a unit the
  machine splits differently to no domain, does not exist, and
  `Erx::Platform` does not check that a record's own units, placed or not,
  are closed under sharing a page and a line.
* [Low] domain library, `dom_core.c` request planning: a requested
  domain's args and env are checked against `ERX_BOOT_STRINGS_MAX` alone,
  while its boot page also holds both node names, so a request that
  leaves no room for them is planned and fails at `apply_bootinfo` after
  its objects are made (the undo clears them). Hold requests to the boot
  view's reserve (`boot_strings_fit` in `dom_boot_view.c`, both node names
  at `ERX_DOM_NODE_MAX`) so the plan refuses them.
* [Medium] domain library, `dom.h`: the apply phase's rules are not
  written down: who sets a connection's `closing`; that `labels` and
  `next_connection` advance only after a successful apply, and
  `next_connection` becomes 0 past `UINT32_MAX`; that plan and apply
  run under the one library lock, so two gives of a device never both see
  it free; and that a device record's `holder` and `memory` are written
  only after the give's last step. Return the counters' next values in
  the plans, or state them in the plan comments.
* [Medium] docs, `docs/design-system.md` "The domain library's records"
  and the entry table: the record and view lack `connections`, `labels`,
  `next_connection`, `system_space` and the device catalogue, and
  `erx_dom_connect`'s `ERX_ELIMIT` lists only a full table, not the
  quota, spent numbers or spent labels.
* [Low] domain library, `dom_life.c`: connect allows a second connection
  between the same pair, which the domain service's "the connection that
  joins D and that peer" assumes away (refuse with `ERX_EEXIST`);
  disconnect frees a living domain's system connection; `erx_dom_plan_stop`
  lists the kernel's exit statuses one by one; and the charging rule is
  stated twice, in the planner's steps and in `life_step_ok`.
* [Low] domain library tests, `test/host/dom_core_test.rb`: a mutant is
  caught by any difference in the driver's output rather than by the line
  its seed must change (`dom_life_test.rb` judges by the line), and the
  origin rule has no `chokepoints_dom_test.rb` showing its allowed sites
  pass.

* [Medium] live, `erx_source` (`erlang/apps/erx/src/erx_source.erl`): nothing ties a module's `src` file to
  its beam, so an edited, unrecompiled source shows lines the module was not compiled from, and a location in
  an included file is looked up by base name in the module's own `src` and `include`, so a header of another
  application with the same base name shows its lines. Have the build record the source's digest in the beam
  and refuse a mismatch, and accept an included file only when its directory is the module's own; record the
  rule in design-live.md, "From a process to its source".
* [Medium] live, `erx_source`: a reload and purge between the process's location read and the module's
  version read shows the old version's line against the new source; lines/1 rechecks the version and old code
  around the source read, which narrows the window without closing it. A `process_info` item that returns the
  current location with the identity of that module instance closes it, as the design's process record
  ("its module's version") implies.
* [Medium] live, the shortcuts' collision test (`test/erlang/erx_shortcut_tests.erl`): the shell's commands
  come from `shell:local_func/0`, which leaves out `ft`, `td` and `exit` that `local_func/8` handles before
  `shell_default`; derive the names from `local_func/8`'s clauses, in the collision check and in the
  resolution test's names.
* [Low] live, the shortcuts' resolution (`otp/lib/stdlib/src/edlin_expand.erl`, `erx_shortcuts/0`): the
  shortcuts reach `edlin_expand` through `shell_default`'s `erx_shortcuts` attribute, read at each call, and
  `beam_lib:strip` drops the attribute chunk, so a stripped `shell_default` would silently resolve
  `trace(P, true, [send])` in a function defined at the prompt to `shell_default:trace/3`. Nothing strips
  beams today; a compile-time single source shared by `shell_default`'s export and `edlin_expand` (an
  `.hrl` cannot serve both, since `-export` takes `F/A` and the resolver tuples) would remove the read.
* [Low] live, `erx_source`: the source read follows symbolic links and checks the size before reading rather
  than reading at most the cap, and a rendered line is not cut at a width, so a 4 MiB line (32 MiB of
  expanded tabs) reaches the console whole. Read with `file:read(Fd, Max + 1)` after `read_link_info`, and cut
  each line with a visible marker.
* [Low] live, the QEMU check of `erx:source/1`: the release ships no `src`, so a console point must compile a
  module into a `src`/`ebin` tree on a writable file system and show a waiting process's line; it also needs
  OTP's `otp_SUITE:undefined_functions` under `check-oracle` to accept `shell_default`'s call of
  `erx:source/1`.

* [Low] files, `erx_9p` codec (`tools/lib/erx/abi_emit_wire.rb`, `abi/protocols/9p.txt`): a packed list's
  per-element size (`packed @p9_dirent_fixed`, 24) is declared rather than derived from the dirent tuple's wire
  widths, so a change to `dirent` would make the grammar's `packed_dirents/1` disagree with the bytes the codec
  writes; derive it in the generator or refuse a mismatch. `decode/2` also accepts T and R messages alike, so a
  bridge must itself refuse a reply from its client and a request from its server; split it into
  `decode_request/2` and `decode_reply/2` when the first bridge is written. The wire emitter subclasses
  `ProtocolEmitter` and reaches into its private renderers; extract a kind-check renderer parameterised by the
  alias's form if the grammar emitter's internals change.

* [Medium] `docs/design-abi.md` [Inspection schema](docs/design-abi.md#inspection-schema): `[kernel, crash]` and
  `[kernel, trace]` repeat the fields of the crash-record and trace-record layouts, and the grammar has no form
  that takes a kind's attributes from a root `layout`, so they would be copied by hand. Add one (`fields @layout`)
  before those kinds are declared.
* [Medium] `erlang/apps/erx/src/erx_inspector.erl` [Inspection records](docs/design-live.md#inspection-records):
  `record()`'s `entries` is answered only for `[kernel, log]`; a domain's pids, also marked `entries`, are still
  a listing's children, and no query takes `limit`, so a page is always erx_schema's 1,000. Answer every
  `entries` path with entries and take `limit` in `erx_inspector:inspect/3`.
* [Low] `erlang/apps/erx_shell/src/erx_render.erl`, `erlang/apps/erx_web_line/src/erx_web_value.erl`: neither shows a
  record's `entries`, so `erx:i([kernel, log])` prints an empty record and the web's log view
  ([design-web.md](docs/design-web.md#views-on-the-line)) has nothing to read; `/proc/kernel/log` and `dmesg`
  are the only readers.
* [Low] `docs/design-live.md` [The /proc tree](docs/design-live.md#the-proc-tree): the name encoding writes "every
  byte outside `A`-`Z`, `a`-`z`, `0`-`9` and `_+,:=@-`, and a leading `.`" as `%XX`; `.` is outside that set, so
  the leading-`.` clause says nothing, unless `.` was meant to stay plain after the first byte. `erx_schema`
  follows the letter (every `.` is `%2E`); settle it before `erx_procfs` writes names.
* [Low] inspection bindings (`tools/lib/erx/abi_emit_inspection.rb`): `erx_schema` and the host tool's table
  (`build/gen/tools/generated/abi_inspection.rb`) are generated; the bounded C record builders of
  [design-generation.md](docs/design-generation.md#inspection-and-diagnostics) are not, since their consumer is
  erXos's kernel, and the host table has no Ruby validators yet. Generate each with its first consumer.
* [Medium] inspection, `erx_schema` (`tools/lib/erx/abi_emit_inspection.rb`): `validate_record/1` ignores an
  attribute's `build` (a release record may carry a `development` attribute). `cpu_index`'s bound 63 is written
  beside `@cpu_limit` because the grammar has no `@limit - 1`. The domain kind lacks design-live's death record and
  group usage.
* [Medium] kernel reports, tests and collector (`erlang/apps/erx/src/erx_kernel_records.erl`,
  `liberx/backend/core/object_info.c`): design-live's host test that every bit of each backend's `erx_info_partial`
  names an attribute listing a stopgap for `kernel` (seeded on `guarantee`) is missing, as are design-stopgap's
  Kernel reports seeds for `capacity_mcpu`'s bit and for a failed `l4_scheduler_info` through a test hook, and any
  mutant of the Fiasco-only `service_object_info` and `erx_fiasco_task_thread_map`. `derive/2` restates the budget's
  derived formulas apart from `abi/inspection.txt`'s `derived` inputs; emit them from the schema, or at least test
  every derived attribute with all-ok inputs. `erx_fiasco_pool_put` holds `held_pages` at 0 on a put of a page never
  taken, a liberx bug it hides rather than reports. The group topic maps every `erx_group_info` failure to
  `ERX_ENOTSUP`, not `ERX_EINVAL` alone; a CPU listing ends at the first gap in the map; the root's window to
  `service_object_info` and `service_log_read` is checked only for 0 and wrap (trusted root). The QEMU check that
  calls `erx_kernel_records` from `erl` at the console is not written yet.
* [Medium] inspector (`erlang/apps/erx/src/erx_inspector.erl`, `erx.erl`, `erx_process_records.erl`):
  the inspector run in a domain other than the system domain lists that domain's own processes
  (`runtime_domain/0`, from `erx_dist:boot/0`), but names its kernel records and domain record as the system
  domain's (`erx_kernel_records:system_domain/0`, a constant 4), so the scope `{principal, P}` of a session's inspect
  facet, which the query worker resolves to that principal's domains, reaches none of them: `erx:i` there answers `{error, scope}` for them and
  `top`'s header prints `-`. Read the kernel records of the caller's group, budget and threads, and collect
  `[domains, Id | _]` for the runtime's own domain. A process listed in a session links to
  `/proc/processes/<pid>` in the browser, which names it; `[domains, Id, processes]`, declared with paginated
  entries rather than children, needs the web client's entries view (W3) before a browser shows it. `erx_inspector:runtime_domain/0`
  reads the boot page, and `collect/2`, `entries/2` and `proc_id/1` each call it, and `is_system_runtime/0` reads it too; read the
  domain's (`erx_kernel_records:system_domain/0`, a constant 4), so the local scope `[Id]` a session's inspect
  facet has (`erx:cap(inspect)`) reaches none of them: `erx:i` there answers `{error, scope}` for them and
  `top`'s header prints `-`. Read the kernel records of the caller's group, budget and threads, and collect
  `[domains, Id | _]` for the runtime's own domain. A process listed in a session links to
  `/proc/processes/<pid>` in the browser, which names it; `[domains, Id, processes]`, declared with paginated
  entries rather than children, needs the web client's entries view (W3) before a browser shows it. `runtime_domain/0`
  reads the boot page, and `collect/2` calls it after the scope decision; read the
  domain once at the edge (one exported reader) and pass it in. The system domain's runtime is the node
  `system@<host>` at creation 4 (`tools/lib/erx/system_domain.rb`), yet `erx_process_records:proc_id/2` still
  names a pid of its own runtime by the runtime's domain rather than by the creation the pid carries; drop that
  special case wherever the creation already is the domain. The browser shows a
  process's links and monitors, lists of `proc_id()`, as tuples (`erx_web_value`), not as pid presentations.
  The listing page (1,000) and the scoped machine paths (`[]`, `[processes]`) are written
  in `erx_inspector`; have `erx_schema` export the page and the schema mark which machine paths a scoped facet
  reads. A thread past a partial listing's end is answered `{error, scope}`, as one that does not exist.
  Not collected yet: `[groups]`, `[budgets]`, `[domains]` and a domain's record, modules, exports, connections
  and paginated `[domains, Id, processes]`; `erx:inspect/2`, and `erx:ps/0` and `erx:domains/0` with their
  `shell_default` shortcuts, which `test/erlang/erx_shortcut_tests.erl` lists as pending.
* [Medium] /proc (`erlang/apps/erx_files/src/erx_procfs.erl`, `erx_procfs_core.erl`; design-live's
  [The /proc tree](docs/design-live.md#the-proc-tree)): `kernel_safe_sup` starts the tree at boot in every
  runtime, in the system domain over a local query worker at scope `all`; the system shell's tree should instead
  start with the console, presenting the system-shell facet, and be mounted only in the system shell's namespace.
  The design leaves open: a text entry spelled `status`, a module of that
  name, which the directory's `status` file shadows; how many entries `.partial` says were left out, which the
  inspector does not count (the file says `left_out [unknown]`); and what the `status` file of a path the inspector
  answers `{error, unsupported}` holds (one line, `[unsupported]`). Not built: `source`, `crash`
  and `/proc/kernel/crash`, which have no inspector path yet. `/proc/kernel/log` keeps a file's oldest lines when
  its 64 KiB cut applies, as every file does, so a full ring whose escaped lines pass 64 KiB ends in `[partial]`
  where the newest lines would be, which are the ones `dmesg` is read for; cut a log file at its start, after a
  `[missing N]` line, instead. An open asks the inspector in the
  grant's process, so a slow query holds the grant's other requests, and each walk step collects a record (or, for
  a CPU or thread, the listing) only to learn that it exists; the machine record is asked once per status open for
  the build's projection. The tree's grant is a direct child of `kernel_safe_sup` and shares its restart budget
  with `erx_ns` and `/tmp`; give it a supervisor of its own. The 256-snapshot bound counts a directory like a
  status file, but a `/proc/processes` snapshot is a list of about 17 words an entry, so 256 of them over about
  1,000 processes pass the grant's heap limit (estimated); weigh snapshots by size or pack listings into one
  binary. A scoped tree cannot walk `[domains]`, which the inspector closes to scoped callers, so its own domain's
  subtree is unreachable; make the inspector list a scoped caller's own domains there. Smaller: a listing's
  `status` file is empty; an open `.unknown` whose listing has since come whole still reads `[unknown]`; statfs
  says `namelen` 255 while an encoded name reaches 765 bytes; `erx_fs_grant`'s lopen does not clunk a handle whose
  reply its check rejects, as lcreate does; and `erx_file_remote`'s read of a size-0 file takes a short piece as
  its end, so an error after the first unit of a piece reads as end of file where stock answers the error.
* [Medium] kernel reports, `liberx` and `abi/erx_abi.txt` (design-abi's
  [Inspection schema](docs/design-abi.md#inspection-schema)):
  `erx_info_budget` declares `kind`, `guarantee`, `cap`, `used`, `carved`, `lent` and
  `threshold` but not `pinned`, which design-kernel's [Budgets](docs/design-kernel.md#budgets)
  and the budget core's `erx_budget_counters` report. Add the field; until then the
  inspector shows `pinned` as `unsupported`. `erx_info_machine` has no field for `development` or `dma_profile`, since the
  design does not say how a boolean or a closed atom set travels in a report, so both read as clear bits; and the
  `group` kind declares only the five attributes `erx_info_group` carries, not design-live's throttling,
  executors, child groups or the policy's intent. `tools/lib/erx/abi_inspection.rb`'s report check compares
  names only: nothing ties `erx_info_cpu`'s `ready_threads` count 64 to `urgency_counts`' 64 (both copies of
  `@urgency_max + 1`), the `capacity` type's 64000 to `@cpu_limit * 1000`, a field's width to its integer type's
  range, or says how `build`'s 8 raw bytes render as `text build_id`; require an array field exactly for a list
  attribute, with its count, and a scalar wide enough. The check exempts a field named `id` in any report layout,
  wider than design-abi's counting topics. design-kernel's [Threads](docs/design-kernel.md#threads) declares
  `erx_thread_state_t` and `erx_wait_kind_t` with `ERX_TS_*` names that clash with the generated ABI's typedefs and
  `ERX_THREAD_STATE_*`; it should use the ABI's. `erx_backend_group_report`'s reported bits are pinned only by the
  `function_api` guest case, not by a host test in `test/host/group_report_test.rb`.
* [Low] `docs/design-live.md` [The /proc tree](docs/design-live.md#the-proc-tree): an Erlang module named `status`
  encodes to the entry `status`, the same name as the `status` file of `/proc/domains/N/modules`. Encode a name equal
  to a file the tree itself writes (for example as `%73tatus`).
* [Low] test, `test/host/sanitizer_environment_test.rb`: TSan reports nothing for the racing program in about one run
  in five hundred with 16 runs at once, even with the two increments ordered in time and both threads alive; the
  test retries up to three times. Why TSan misses a plain unordered write pair is not known; find out before
  relying on a single TSan run to show a race.
* [Medium] sanitizer environment of host tests, `test/fixtures/sanitizer_environment.rb`: a test run directly with
  `ruby` gets the sanitizer policy and llvm-symbolizer only if it requires that fixture (through `generated_tree.rb`
  or directly) or passes `Erx::SanitizerEnvironment.call` itself. A new test that runs a failing sanitized program
  without either falls back to macOS's `atos`, which can hang until the test's deadline. Load the fixture from one
  place every test loads, or add a check that fails on a test with `-fsanitize` that reaches neither.
* [Low] QEMU gate cell placement, `tools/lib/erx/qemu_cells.rb`: only native_task declares `offload`, from its
  measured 4-CPU HVF cell (about 42 s). Measure every suite's multi-CPU cell under HVF and declare `offload` where
  one takes 30 s or more. The suites whose runs do not go through `QemuCells::Placement` (conformance,
  native_libc_canary, medium_boot, production_image, block_device, net_device) never boot their local cells
  side by side; move the ones that only boot `Qemu#run` without a disk or host link onto it.
* [Medium] QEMU gate cell placement, `tools/lib/erx/qemu_cells.rb`: `QemuCells.lanes` stops a lane with
  `Thread#kill`, which can land between `Process.spawn` and the pid's assignment in `Runner#run` or inside a
  cleanup ensure, leaving a local QEMU to its deadline or a remote one to the remote timeout. Give every lane a
  shared cancellation flag passed to `Runner#run`'s `cancelled:` instead. Cell names are agreed by string: each
  Run spells `"#{accel}-#{count}cpu"` (boot_image adds its case after it) and the gate parses declared names
  with `CELL_CASE_NAME`; have suites declare `QemuCells::Cell` values and `Placement#each` yield the `Cell`, so
  names have one source. A moved cell is placed before reuse is consulted: with the default `--busy-load` a
  load that crosses it turns a stored HVF pass into a fresh TCG boot; with `--busy-load 0` placement does not
  depend on load, and only an HVF pass `make check-qemu` stored goes unused by the landing gate. Nothing
  sweeps run directories a failed remote cleanup leaves under the remote work directory.
* [Medium] build memo, `tools/lib/erx/build_memo.rb`: a warm `check-qemu --suite medium_boot` still runs the native
  runtime builds (OTP make walks, about 25 s of steps: `runtime-emulator`, `runtime-preloaded`, the Erlang apps),
  the pack-time Fiasco audit (70 `fiasco-audit-member` steps) and about 40 s of the orchestrator's own Ruby
  (FiascoInputs hashes all 338 MB of `fiasco/` and its private copy on every build, `Runtime.source_digest` hashes
  `otp/` three times per image build, CompileMemo digests the system header trees once per `compile_all`). Key the
  runtime builds on `Runtime.source_digest`, musl, the sysroot's inputs, the host OTP and the compiler; cache file
  digests by (path, size, mtime, inode) with a racy-time check; run independent steps (the two runtime flavours,
  compiles) in parallel.
* [Medium] stopgap Fiasco build, `tools/lib/erx/fiasco_inputs.rb`: every file under `liberx/` is an input of the user
  build, so an edit to any native-root source (`liberx/backend/fiasco/console.c`, which the user build does not
  compile) discards `build/fiasco/users` and rebuilds it from scratch, about 75 s of a 300 s `medium_boot` run on a
  loaded host. Capture for each component only the C17 sources its cores read (CoreArchive), so such an edit reruns
  only the native compiles that read it.
* [Low] build memo, `tools/lib/erx/compile_memo.rb`: a quoted include that climbs out of its includer's directory
  (`#include "../x.h"`) and was found through an `-I` directory is not keyed against a file of that name appearing
  above the includer, which would then come first; the native sources use none. Key each quoted include's name
  relative to its includer, or refuse to store a compile whose dependency names `..`.
* [Low] build memo, `tools/lib/erx/build_memo.rb`: `build/memo` grows by one entry per distinct compile and is never
  pruned. Drop entries no build has restored for some number of builds, or keep a bounded number per source.
* [Medium] build memo on Linux hosts, `tools/lib/erx/build_memo.rb` `REUSE`: the operating system's directories
  (`/usr/bin`, `/bin`) are named by the kernel's release, which on Linux does not change with a package upgrade, so
  on Linux the memo reuses nothing and every step runs (its reuse tests then fail). Name those programs by identity
  or by the package database's state, then enable reuse there.
* [Medium] build memo, `tools/lib/erx/build_memo.rb` `program_identity`: a program is named by its own install's
  `lib` directory, not by the libraries it loads from other packages (`cc1` loads Homebrew's isl, mpc, mpfr, gmp,
  zstd), and `/usr/bin`'s Xcode shims (`gcc`, `cc`, `m4`; the Fiasco kconfig's `HOSTCC = gcc`) are named only by
  the macOS release, not by the active developer directory. Key each program's load-command closure (`otool -L`,
  `ldd`) and `xcode-select -p` with its clang, or point the inherited build's host compiler at the keyed clang.
* [Low] build memo, `tools/lib/erx/compile_memo.rb`: clang leaves out of `-MMD` a header included under
  `#pragma GCC system_header` and an `-I` header a system header probes with `__has_include`; the system trees are
  digested once per `compile_all` and a dependency's change during a compile is caught by mtime only; two builds
  storing one key race (`Errno::ENOTEMPTY`). Switch the memo to `-MD`, re-digest before storing, and treat a lost
  rename as success; none of these arise in the tree today.
* [Medium] stopgap, `test`: the `medium_boot` suite's `release-shell` checkpoint timed out on the first run after a
  fresh tree twice (master ee3bfe47 and branch mb-incr), the 1-CPU boot's serial log showing the shell's banner
  interleaved with the domain ERTS's "hold executor slots" line; the next runs passed. Find whether the checkpoint
  needs a whole line that concurrent console writers can split.
* [Medium] build tree of generated files, `tools/lib/erx/generated.rb`: `tools/erx`'s entry `ensure` releases
  `build/gen.lock` before any compiler runs, so the long readers that follow do not hold it: the hosted liberx
  compiles and OTP's make with `-I$(ERX_GEN)` in `runtime.rb`, the fuzz compiles, the test pool's compilers, the
  Fiasco input capture, and `Checks#generated_sources`, which lists the tree after its `ensure` returned. With a build
  running in one terminal, an edit to a generator's input followed by any `tools/erx` command in another regenerates
  the tree under it, and `swap`'s two renames leave no `build/gen/` between them: a compile fails with `ENOENT`, or,
  silently, the chokepoint listing finds no or few generated files and `Chokepoints.enforce` passes having checked
  less. A translation unit that opened one generated header before the swap and resolves another after it compiles
  against two trees at once, which still builds while the two agree on types. The Ruby loaders
  (`Erx::Generated.require_ruby`) already read under the lock. Fix: have `ensure` return a tree value that the
  libraries take, over versioned, never-rewritten trees (`build/gen.d/<digest>` behind a link replaced by rename,
  each resolved once per build), or have long readers take the lock shared (a `Generated.reading(root:) { |tree| ... }`
  section); and take the chokepoint listing from the stamp's outputs, refusing a missing file.
* [Medium] build tree of generated files, `tools/lib/erx/generated.rb`: whether `build/gen/` is current when a
  compiler reads it rests on the process entry having run `Generated.ensure` (tools/erx before it loads its
  libraries, `test/fixtures/generated_tree.rb` in tests, each standalone script), because `Generated.path` and
  `include_flags` are pure functions of a root. A test or script that skips it compiles against a stale tree. Make it
  hold by construction: ensure returns a tree value (output root, paths, include flags, the stamp's outputs) that
  build libraries take instead of a root, or readers check the stamp (no regeneration) and refuse a stale tree.
* [Low] build tree of generated files, `tools/lib/erx/runtime.rb`, `core_archive.rb`, `test/host/*_test.rb`: the
  generated tree's include directories are spelled out by hand in each FLAGS constant (`-I build/gen -I
  build/gen/include ... -I build/gen/kernel/generated`) and in host tests beside `Generated.include_flags`. No file
  of the tree sits at a generated path (`Generated.ensure` refuses one), so their order decides nothing; derive
  every list from `Generated.include_flags` and drop the repetition.
* [Low] host tooling, `tools/lib/erx/` (QEMU suites and harnesses, e.g. `medium_boot.rb`, `native_irq.rb`,
  `deterministic_transcript.rb`): about a dozen error and verify messages quote guest text with `String#inspect`
  instead of `Erx::Terminal.escape`, the host terminal's one escaping function. `inspect` escapes control bytes, so
  nothing reaches the terminal raw, but the one-escaper-per-sink rule holds only by convention; route them through
  `Terminal.escape` and add a chokepoint check.
* [Low] `otp/erts/emulator/beam/erl_proc_sig_queue.c` (`handle_cla`), reasoning only, not reproduced: if a process's
  message queue switches to off-heap between `handle_cla` answering `need_gc` and the literal collection, an on-heap
  message whose term refers to the literal area may be copied off heap with its literal pointers kept
  (`copy_struct_litopt`), and so outlive the area. Probe it as `test/fixtures/literal_token_probe.erl` probes the token.
* [Medium] `otp/erts/emulator/beam/erl_process.c`, hosted runtime: `statistics_SUITE:scheduler_wall_time_all` fails
  where stock passes: under the case's full load one of 42 schedulers reports 0% wall time
  (`{badmatch, {true, [100,100,100,100,0,...]}}`), so one scheduler never ran the load or its wall-time counter
  missed it, perhaps a scheduler left parked in `erx_park`; `scheduler_SUITE` `few_low` and `equal_and_high_with_part_time_max` fail the same way (`low_min_ratio 0.0`).
  The system domain on QEMU's one CPU passes all three, so `emulator.txt` has no row for them.
* [Medium] `otp/erts/emulator/beam/erl_process.c` (scheduler wall time), system domain on QEMU HVF with one CPU:
  `statistics_SUITE:msb_scheduler_wall_time` fails at `true = 0.9 < WSU andalso WSU < 1.1` (line 542) where stock
  run with as many schedulers passes (WSU 0.99): with multi-scheduling blocked and ten low-priority hogs, the
  schedulers' weighted wall-time utilization is not about one busy thread. The hosted runtime's run shows no
  difference there. It was seen once, on a host running other QEMU guests and `make check-asan`
  (erxos-history `oracle-qemu/emulator/2026-11-07`), so it may depend on host load; if a quiet run passes it, its
  row in `emulator.txt` turns stale and fails `make check-oracle`, which then names it. The value is only in the
  guest's HTML case log, which the run does not print; print the case's `SU` and `WSU` lines, then trace whether
  the blocked schedulers' wall-time counters, the one CPU's other threads or host load cause it.
* [Medium] `tools/lib/erx/oracle_hosted.rb`, `test/oracle/hosted_known_differences/emulator.txt`: both erXos sides
  read one table (design-build.md), but the hosted runtime runs about 42 schedulers and the QEMU guest one, and
  stock runs as many as each, so some cases differ on one side only for that reason. `make check-oracle` holds the
  table to the guest; `tools/erx oracle hosted --suites emulator` then shows unlisted differences: the three bugs
  above, map_SUITE `t_tracing`, and scheduler_SUITE `scheduler_threads` and `poll_threads` and z_SUITE
  `node_container_refc_check`, which start a peer at many schedulers and skip or pass at one. Run the hosted side
  at the guest's scheduler count (`+S 1:1`), so both sides are the same configuration, or give a row the side it
  holds for.
* [Low] `otp/erts/emulator/beam/erl_port_task.c`: `port_SUITE:mon_port_bad_remote_on_local` fails: `erlang:monitor(port, P)` of a fake remote port does not raise the exception stock raises. Unexplained.
* [Low] `otp/erts/emulator/beam/erl_trace.c`, hosted runtime and system domain: `trace_call_count_SUITE:combo` fails in the
  `dynamic_pre_post` group only, with a `badmatch` on trace messages that include `erlang:trace_info/2`'s own
  call, `return_from` and `return_to`; the `legacy_pre_post` run of the same case passes. Unexplained.
* [Medium] storage, `erx_driver_ctl` and `erx_lfs`: a `stop` or `restart` of the
  block unit through `storage_ctl` while `/data` is in use leaves `/data` failed until
  the domain restarts, and the facet still answers `ok`. Between the stop and the start
  `erx_blk` answers `no_device`, a request it was serving exits, the window answers
  `eio`, and littlefs fails the volume on any failed block request
  (`erx_lfs.erl`, "unavailable until reboot"). A restart fails it too, by design: each
  window is bound to the device process it first reached and answers `eio` once that
  process has ended (design-stopgap.md, "littlefs in the storage domain"). Decide whether the holder's
  units name what depends on each driver, so the facet refuses a stop while it is
  mounted, or remounts after the start; the block_device cell checks only a raw read.
* [Low] storage and network, `erx_storage_sup` and `erx_net_erxos:children/1`: the
  driver-control facets' units tables, `#{block => {erx_blk_sup, erx_blk}}` and
  `#{net => {erx_net_interfaces, Name}}`, repeat the manifest's unit names by hand, and
  nothing checks them against the units the domain holds; a renamed unit is refused as
  `badarg` while the stale name works. The network's link name is the transport's, and
  `net` names a link only while the stack has one interface, so a unit of several
  network devices cannot be stopped or started. Derive each from the domain's installed
  units, or check each key at start.
* [Medium] devices, `erx_devfs`: only the system domain's namespace mounts `/dev`,
  the control tree. Administrator sessions do not get the read-only tree, and no
  device-service control facet serves the control tree to a session
  ([design-system.md](docs/design-system.md#devices), "The `/dev` tree"). Mount
  `erx_devfs`'s `ro` tree from the session namespace setup, and serve the control
  tree through the facet when a session needs it. Decide then how the device tree
  shares `/dev` with the session's own `/dev/null`, `/dev/tty` and the rest
  (design-files.md, "Narrowing for a program"), and that a program started from the
  system shell does not inherit the control tree; `erx_devfs:start_link/0` unmounts
  whatever is at `/dev` before it mounts.
* [Medium] devices, `erx_devfs`: it is a permanent child of `erx_domain_sup` (default
  intensity, 1 restart in 5 s), so a bug that crashes the `/dev` grant twice within 5 s
  ends the system domain and resets the machine. Move it under a supervisor whose end
  the domain service survives, when the device service gets its own.
* [Low] devices, `erx_devfs`: `/dev` shows only the block device. Its `status` has no
  `path` line, because the catalogue that reaches Erlang has no device-tree path, and
  its `driver` line is `[unknown]`, because no facet says which process drives a unit.
  Show every catalogue entry, export the path from the boot view, and add a driver
  query to the driver-control interface.
* [Medium] storage, `erx_lfs`: any process of the system domain can send the owner
  `{erx_lfs_block, ...}` or `{erx_lfs, Worker, done, _}`. A forged block message fails the
  volume or, with a request of a volume of its own, writes any sector of the data window;
  a forged `done` answers one client's request with another's result. Tie each request to
  its volume in the NIF and tag each run with a fresh reference.
* [Medium] storage, littlefs: a crafted image whose directory tail points back at itself,
  off the list mount checks, makes `lfs_dir_find` and `lfs_dir_read` loop forever on a
  dirty I/O thread, and every caller of `/data` waits with it (`erx_lfs` calls have no
  timeout). Not reproduced; add a seed to `tools/fuzz/lfs_image_target.rb`. littlefs's
  `LFS_ASSERT`s on disk state stay live, so one reachable from a damaged image resets the
  machine, at every boot if it is reached at mount.
* [Medium] storage, `erx_lfs`: once the qid table is full, `listing/4` leaves out entries it
  cannot draw a qid for and numbers the next offset from the entries kept, so a listing
  repeats entries or ends early instead of answering `enfile`.
* [Low] storage, `erx_lfs`: a make whose qid draw fails leaves the new file open in its
  slot; the owner traps exits and ignores its supervisor's abnormal end; `remove/3` ignores
  the node unlink names, so it removes whatever entry has the name now; a 65,537-byte write
  (msize 65560) and a readdir offset of 2^32 or more answer `eio`.
* [Medium] storage, block service: a window has no `flush` (design-storage.md, Interfaces):
  `erx_lfs` answers littlefs's sync itself (`erlang/apps/erx_storage/src/erx_lfs.erl:249-263`) and
  `erx_blk_window` has no `flush` handler, so nothing reaches the transport's `flush/0`; the transport
  split's implementation forwards it (design-storage.md, "The transport contract"), and on the SD card it
  is durable only because the start turns the card's cache off. A write is answered once the device has
  completed it, which holds across a QEMU kill but not across a power cut on a medium with a
  write cache. `erx_blk_window` answers no `flush` and the driver negotiates no
  `VIRTIO_BLK_F_FLUSH`, so a file system cannot order its writes against the medium's cache.
* [Low] storage, `erx_littlefs_nif.c`: `deadline_after` ignores `clock_gettime`'s result, and
  the hosted build's `CLOCK_REALTIME` is the wall clock, so a clock step fails a block wait
  or stretches it. Waiting with `erx_umtx_wait` against an `erx_clock_ns` deadline fixes both
  and empties `imports.txt`'s `[only_erx_littlefs_nif]`.
* [Medium] storage, `tools/lib/erx/data_volume.rb` and the medium writers: a data volume and its
  partition's length travel separately (`ReleaseMedium.write`, `Site.fresh_medium`,
  `BlockDevice::Run#fresh_medium`), and each writer must remember to place the volume, since
  `MediumImage.create` accepts a medium without one. A volume formatted for another length, or a
  writer that forgets it, gives a /data that never mounts. `MediumImage.create` should require the
  volume, or format it itself from `data_sectors`, so every medium has one by construction.
* [Medium] storage, `erx_storage`: a data volume that fails every mount ends the whole storage
  domain after its row's restarts, so the block driver, its windows and `storage_ctl` go with
  `/data` until a reboot. Serving the domain without `/data` (erx_lfs answering a failed mount
  with an unmounted state) would keep the rest, and design.md's "served read-only or not at all"
  row wants an operator's repair or reformat path.
* [Medium] tests, `test/host/erx_littlefs_test.rb`: the NIF runs uninstrumented in the stock
  runtime. A loaded NIF under AddressSanitizer needs `DYLD_INSERT_LIBRARIES`, which the
  development host's sandbox strips from every child; on a host that passes it, build the
  library with `-fsanitize=address,undefined` and run `beam.smp` directly with the runtime
  inserted. littlefs itself runs under both sanitizers in `tools/fuzz/lfs_image_fuzz.c`.
* [Low] storage, `erx_lfs`: the qid table is keyed by path, not by littlefs's metadata pair
  and id, and has no `forget`, so it shrinks only at a remove and fills at 65,536 paths met
  (`enfile`), unlike design-storage.md's "littlefs and FAT".

* [Low] tooling, `tools/lib/erx/oracle_comparison.rb:104`, `oracle_qemu.rb:203-213,232,239`: the
  oracle comparison's host side has gaps. (1) A repeated sequence number keeps the first copy
  (`frames.compact.uniq(&:first)`), so a stray or forged frame wins over the real one; the CRC is
  integrity, not authentication, and a frame appended after the last real event goes undetected
  by the sequence logic (state it next to the event-frames residual above). (2) `boot_guest`
  catches errors from `qemu.run` only; an unreadable `report.json` (`JsonInput.parse`) or a
  serial log over 256 MiB (`BoundedFile.read`) raises out of `OracleQemu#run` and aborts
  check-oracle mid-loop; map both to a host state, or to `failed` when the guest booted. (3)
  A `CommandError` from `qemu --version` timing out maps to `timed_out`, and a QEMU or HVF crash
  after the bootstrap memory line maps to `failed`, so host problems read as erXos's; the
  `cancelled` branch (line 208) is unreachable from `run_guest`, which passes no `cancelled:`.
* [Low] tooling, `tools/lib/erx/libc_test.rb`: libc-test's tasks link liberx's clock
  (`liberx/backend/fiasco/arch/aarch64/clock.c`) through their own generated Makefile with
  `--strip-all`, not through `NativeRoot#build`, so `CounterReads` never reads them and
  could not name the function in a stripped program. Link them through `NativeRoot`, or
  run the check before stripping.
* [Low] tooling, fetched source paths: `tools/lib/erx/libc_test.rb:24` spells libc-test's
  unpacked directory (`libc-test-63e36e9`) by hand, so a pin bump in `deps.lock` fails it with
  a missing-file error, and it reads the tree without checking its provenance record. Route
  it through `Dependencies#fetched_tree`, which has no other caller until then;
  `RcOracle::Build#source_tree` repeats the same check by hand.
* [Low] tooling, `tools/lib/erx/libc_test.rb:158,270-279,454-457`, `tools/lib/erx/setup.rb`: (1)
  Every serial line between a test's run and end lines that matches `FILE.c:N: ` is
  attributed to that test, including kernel or root C output; a spurious disagreement, never a
  false pass. Require the `src/` path form `t_error` prints. (2) The libc-test make rules
  depend on sources only, and `forget_programs` deletes only `.elf`, so objects built under old
  `FLAGS` are reused; hash the flags into the rule or delete the objects when they change.
  (3) `setup.rb`: the source steps' `deadline: 300` is never used. (4)
  `leftovers` reads the flavour out of `step.argv`;
  store it on `Step`. `ERX_SOURCE_CACHE` names `build/third_party` but setup reads the sibling
  `build/downloads` (`archive_directory`); name the directory actually read.
* [Low] `test/oracle/common_test/test_server_ctrl.erl` (`file:set_cwd` in `run_test_case` and three other sites),
  `tools/lib/erx/oracle_suites.rb` (`ERXOS_LOG_CAP`): on erXos Common Test's logs have a RAM file system of their own
  (`/ct-logs`, 256 MiB), apart from `/tmp` where each `priv_dir` and `data_dir` is, so a suite that fills `/tmp` fails
  only its own cases. Suites still reach the log tree two ways: each case runs with its current directory set to the
  `ct_run.*` directory, as on stock, so a relative path a suite writes lands there (stock's kernel group leaves a 1.7 MB
  `hostnames_nodedir/erl_crash.dump`), and what a case prints goes to its case log (stock's heart_SUITE prints 144 MB
  into `node_start_soon_after_crash`'s). A group that writes or prints more than the cap there still stops the run.
  Moving the current directory to the suites' tree also needs Common Test's own relative writes found first
  (`start_log_file` writes `last_test.html` through `filename:absname/1`). The other way round, what a suite leaves on
  `/tmp` outside its `priv_dir` (files in its `data_dir` copy or straight in `/tmp`, or a `priv_dir` whose deletion
  failed, which is only noted) stays there, and once that fills `/tmp`, every later suite's job ends in
  `start_log_file`, where `filelib:ensure_path/1` cannot make its `priv_dir` (the hosted run answered `enoent`). Making
  a `priv_dir` that cannot be made fail only its suite would close that. And since the `priv_dir` is not below the
  case's current directory on erXos, as it is on stock, a suite that names its `priv_dir` relative to that directory
  (tar_SUITE:borderline strips the current directory's prefix) fails on erXos for that alone; moving the current
  directory into the `priv_dir` tree would close that too.
* [Medium] `tools/lib/erx/oracle_qemu.rb` (`command_line`): the guest's runtime still gets `-pa /lib/<app>/ebin`
  for the stock applications, which its code server also lists from `/lib`, as the hosted runtime's did. Check
  `code:get_path()` on the guest and drop the `-pa` words (`OracleHosted.erxos_command` is the model), and its
  code_SUITE `set_path`, `add_path` and `add_paths` cases.
* [Medium] `tools/lib/erx/oracle_comparison.rb` (`skipped_group_function`): a group function that erXos never
  recorded shows as `auto_skip`, inferred from the skipped cases under its group, and the report prints it like
  a status Common Test recorded. Give the inferred status its own name in the report and the table.
* [Medium] `test/oracle/hosted_known_differences/kernel.txt`, `emulator.txt`: their rows come from runs that booted the
  oracle's tree from OTP's `bootstrap/bin/start.boot`, whose kernel and stdlib versions (11.0.3, 8.0.4) are not the
  shipped ones (11.0.4, 8.1.1). The tree boots its own start_clean (`OracleHosted.write_boot_script`), and the
  compiler and stdlib tables and kernel.txt's rows for the suites before `sendfile_SUITE` are refreshed from runs
  that boot it. Rerun the emulator group and the kernel suites from `sendfile_SUITE` on (`seq_trace_SUITE`, the
  socket suites, `standard_error_SUITE`, `wrap_log_reader_SUITE`, `zlib_SUITE`, `zzz_SUITE`) and the group functions of `gen_tcp_socket_SUITE`,
  `interactive_shell_SUITE`, `net_SUITE` and `prim_net_SUITE` that an incomplete run leaves unresolved, and refresh
  their rows.
* [Medium] `tools/lib/erx/oracle_comparison.rb`: the tables of known differences cannot name a case whose stock
  result is not stable, so such a case fails `make check-oracle` in some runs. file_SUITE's bench cases
  `tiny_writes` and `tiny_reads` (524,288 one-byte calls each within a 60 s timetrap) failed on stock with
  `{timetrap_timeout,60000}` in `prim_file:write_1` and `read_1` in a kernel-group run on a host with load
  average 15 to 30, where erXos passed them (erxos-history `oracle-qemu/kernel/2026-11-07-whole`), and the sides
  agreed in an earlier run whose host load was not recorded (`oracle-qemu/2026-11-07-kernel-no-sendfile`).
  gen_tcp_misc_SUITE `bidirectional_traffic` below and statistics_SUITE `msb_scheduler_wall_time` above may be the
  same kind. Give the table a row that accepts either stock result for a named cause, or run the stock side's
  timing-bound cases on an idle host.
* [Medium] ERTS, process signals (`erl_bif_info.c` `ERTS_PI_IX_STATUS`): process_SUITE
  `process_info_status_handled_signal` failed once on erXos in a whole emulator-group QEMU run (HVF, one CPU,
  `+S 1:1`) with `{badmatch,[{status,running},{messages,[]}]}` at line 1332, where stock passed: the idle target
  answered `running` to a `[status, messages]` request, which ERTS reports only when the target, while it handles
  the request, is also active or has another signal or a non-priority system task pending. The branch carried no
  ERTS change near signals or scheduling. The earlier whole-group run passed it (erxos-history
  `oracle-qemu/emulator/2026-11-07`); process_SUITE alone passed it three times out of three, and a copy of the case
  that repeats its body 2,000 times in one run failed none on either side, so the pending work comes from what the
  earlier suites of the group leave running, not from the case. Not a known-differences row: the cause is
  unexplained. Rerun the whole emulator group with a diagnostic in the status branch that prints the target's
  `ACTIVE`, `SIG_Q`, `NMSG_SIG_IN_Q` and `SYS_TASKS` flags and the kind of the next pending signal or task, and
  find who sent it.
* [Low] `test/integration/runtime_prim_file_test.rb` (`build_fixture`): its tree boots OTP's `bootstrap/bin/start.boot`,
  whose kernel and stdlib specifications are the bootstrap's (11.0.3, 8.0.4), not the release's. The transcript it
  compares does not read them; boot it from `OracleHosted.write_boot_script` so no hosted tree carries them.
* [Low] `/tmp` (`erx_file_remote`, `erx_ramfs_core`): a `list_dir` or a `[read, directory]` open of a directory that a
  rename of another directory replaces between the client's walk and its `lopen` answers `enoent`, where FreeBSD
  answers the old listing or the new one; the tree refuses to open a removed directory, and cannot tell that open from
  a later re-open of a narrowed namespace root, which must answer `enoent` (docs/design-tmp.md). Files no longer have
  this window, since an `lopen` of a file with no name opens it. The cure by construction is a walk and an open that
  reach the tree as one step. Not reproduced; found by reading the code.
* [Medium] `otp/erts/preloaded/src/prim_file.erl` (`?ERX_FILE`), `erx_erofs_file`: prim_file forwards each open-file
  operation on a descriptor of `erx_file_remote` or `erx_erofs_file` to that module, but only the `/tmp` half is tested
  (`tmp_prim_file_handle` in `test/integration/prim_file_compare.erl`); add the same steps on an image file (`/img/big`).
  `erx_erofs_file` has no `ipread_s32bu_p32bu/3` and no `copy/3`, so `prim_file:` and `file:ipread_s32bu_p32bu` and
  `file:copy` on an image descriptor raise `undef` (DETS lookups through `dets_utils` on an image); `prim_file:copy/3`, `get_handle/1` and
  `internal_get_nif_resource/1` do not forward. Make the two lists (the modules `open/2` returns, the operations that
  forward) one source, with a host check that each module exports every forwarded function.
* [Medium] `test/oracle/hosted_known_differences/kernel.txt`: kernel results that change with the run are unexplained. file_SUITE bench
  `tiny_writes` failed on stock and passed on erXos in the group run (stock's failure, not rerun). logger_std_h_SUITE
  `rotate_on_start_compressed`, whose row names a peer, failed on both sides of a rerun of selected suites with `undef`
  in file_SUITE's helpers, which that selection did not compile; its row's os_mon reason is read from the source.
  logger_disk_log_h_SUITE `sync`, `disk_log_full`, `disk_log_wrap`, `disk_log_events` and `op_switch_to_sync` failed on
  erXos in the group run and agree with stock when run with fewer suites; inet_res_SUITE's 8 lookup cases failed on
  erXos in the group run and auto_skip on both sides with fewer suites (their rows were deleted); gen_tcp_misc_SUITE
  `bidirectional_traffic` failed on stock in the group run and skips on both sides with fewer suites. A result that
  depends on which suites ran before it in the runtime may be an erXos bug. Rerun the whole group (the item on
  rerunning every group) and explain each. Reports: erxos-history `oracle-hosted/2026-11-06-kernel` and `2026-11-06-kernel-2`.
* [Low] `test/oracle/hosted_known_differences/kernel.txt`: stock's result of gen_tcp_misc_SUITE `bidirectional_traffic`
  varies between runs (failed, user_skip, passed; erxos-history `oracle-hosted/2026-11-06-kernel`, `2026-11-06-kernel-2`,
  `2026-11-06-kernel-boot`), while erXos skips it in every run that reaches it for want of a local address. Its row is stale whenever
  stock skips too. Find what decides stock's result on the development host.
* [Low] `test/oracle/hosted_known_differences/kernel.txt`: logger_disk_log_h_SUITE `sync`, `disk_log_full`,
  `disk_log_wrap`, `disk_log_events`, `op_switch_to_sync` and inet_res_SUITE's 8 lookup cases failed on erXos in a
  group run that booted OTP's bootstrap `start.boot` (erxos-history `oracle-hosted/2026-11-06-kernel`) and agree with
  stock in one run that boots the tree's start_clean (`2026-11-06-kernel-boot`); file_SUITE bench `tiny_writes`
  failed on stock once. No cause is established; if any recurs, trace it before giving it a row.
* [Medium] `tools/lib/erx/oracle_suites.rb` (`run_stock`), `test/oracle/hosted_known_differences/kernel.txt`: stock's
  distributed peers do not always start on the development host. In hosted kernel runs (erxos-history
  `oracle-hosted/2026-11-06-kernel-boot`, stock's `events.jsonl.gz`) init_SUITE `get_arguments`, `get_argument`, `boot_var`,
  `get_plain_arguments`, `dot_erlang`, `boot/boot1`, `boot/boot2`, logger_filters_SUITE `remote_gl` and every
  rpc_SUITE case that starts a peer failed with `timeout` from `peer:start_it`, and global_SUITE `names` skipped; in the QEMU kernel run
  of 2026-11-07 they all passed, but stock failed rpc_SUITE `call`, `block_call` and `async_call` with
  `{badrpc,nodedown}`, so those three are never compared. Where stock fails a case erXos cannot run, its exact row is
  reported stale. Find what stops stock's peers (host load is a guess), so stock gives a result for these cases.
  QEMU report: erxos-history `oracle-qemu/kernel/2026-11-07`.
* [Medium] `tools/lib/erx/oracle_comparison.rb`, `erx_oracle_events`: a row names a case and erXos's status, not why
  the case fails, so a `*` row accepts any failure of any case it covers. global_SUITE's `*` row (no distribution)
  would also accept a failure of `bad_input`, `otp_5737` or `re_register_name`, which pass on erXos and need no peer;
  heart_SUITE's, global_group_SUITE's and error_logger_warn_SUITE's rows are the same. Carry a failure class (such as
  `not_alive`, or `badarg` from `open_port`) in the case events and let a row name the class it expects, so a
  different failure is reported.
* [Medium] `tools/lib/erx/production_image.rb`, QEMU suite: M3's demo has an idle machine show every executor
  parked, and only the hosted suite checks it (`test/integration/runtime_hosted_smoke_test.rb`, through
  `ERX_HOSTED_GROUP_REPORT`). On Fiasco the park table keeps the count in the group status page
  (`liberx/backend/core/park_table.c`), but nothing reads it out: no BIF, and no reporter like the hosted
  backend's `group_report_main`. Add a user-mode reporter to `liberx/backend/fiasco` behind a kernel command-line
  word, and a checkpoint of `parked N of N` at the shell.
* [Low] `tools/lib/erx/interpreter_image.rb`: the check reads the linked program's symbol table, so a link that
  discards locals (`-x`, hidden visibility turned local) could hide C++ while keeping `erl_start`. The root's link
  strips debug information only. Check the lld link map's input members as well, which no stripping changes.
* [Medium] `erlang/apps/erx_files/src/erx_fs.erl` (`MAX_HEAP_WORDS`, 4 Mi words with shared binaries): one
  `file:write_file("/tmp/big", binary:copy(<<1>>, 16777216))` at the shell kills `/tmp`'s grant process on
  `maximum heap size reached`; the caller gets `{error, eio}` and the supervisor restarts the grant. On FreeBSD a
  single 16 MiB `write` to tmpfs succeeds. The same 16 MiB in 1 MiB writes succeeds. Split a large write into
  bounded jobs (or bound the binary a grant holds per request) so a write within the cap never kills the grant, and
  add the one-call 16 MiB write as a regression test.
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: a fid's path has no depth bound, and `repath/3` counts every
  step of it, so a clone, clunk or walk in place of a fid at depth D costs O(D) and building the path by walks in place
  O(D^2); renames of two directories grow a path without bound. Cap a fid's path length (a walk past it refuses), or
  count steps per shared path suffix so a clone is one increment ([todo-performance.md](docs/todo-performance.md)).
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: the grant's hold bookkeeping (`held`, `steps`, `loose`) has
  no test of its own: `erx_fs_test_tree` has no `forget`, so a rejected walk reply's holds (`tree_holds/2`), `remove`
  and `owner_down` with walked fids are seen only end to end, or not at all. Give the test tree `forget`, check in
  `fid_table_model_test_` that the tree holds exactly the walked nodes the fids name after every step, and consider
  making the forget an effect `{forget, Node}` the shell performs, so the core sends nothing.
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: an open file's owner process is one per grant, keyed by the node,
  where `docs/design-files.md` starts one per open file on any grant; a file open through two grants of one tree has
  two owners, so its requests are ordered against each other only by the tree. /tmp serves one grant per tree. Add
  a per-tree registry of owners before a tree is served on more than one grant.
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: no read helper exists, so an open file's owner calls `read` itself
  whatever the module's `read_mode/0` says, and a read that waits for a medium holds up the file's other requests.
  Build the helper of `docs/design-files.md` (state-stamped results the owner's core accepts or retries) with the
  first tree that answers `helper`.
* [Medium] `erlang/apps/erx_files/src/erx_fs_grant.erl`: a clunk of an opened fid is answered at once and its file process
  leaves `files` when its last clunk is queued, so a tree whose `clunk` is slow can gather file processes still
  draining clunks, beyond the pool and outside the in-flight bound, and two processes of one file can run at once.
  /tmp's clunk is one in-memory step. Defer the clunk's answer to the file process (counted in flight), or keep the
  file in a closing state that new opens join, before a tree with a slow `clunk` is served.
* [Low] `erlang/apps/erx_files/src/erx_fs_grant.erl`: `add_fid` and `end_fid` push effects into the grant's state, which
  every exported step must drain, and an owner's monitor is `pending` until the shell hands its reference back with
  `monitored/3`, as an open file's owner is until `file_started/4`. Thread the effects through the step's return instead, so a step that both makes and ends one
  owner's fid can never emit `{demonitor, pending}`.

* [Medium] `abi/manifest.txt`: the `devices[].selector` choice does not make `base`, `size` and `line` inactive for
  selector 2, so a PCIe row with any of them nonzero is admitted, where `docs/design-abi.md` says they are zero; and
  nothing refuses a device-tree row whose `base + size` wraps. Add the three fields to the choice's `dt` case, decide
  the overflow rule, and give each refusal a fixture case in `test/host/abi_binary_test.rb` and
  `test/host/manifest_reader_test.rb`.
* [Medium] `test/guest/native_irq/guest.c`: the line's unbind and rebind come before the first typed character, so
  nothing checks that a line still fires after it was delivered, acked, detached and attached again. Type a third
  character after the rebind and add its checkpoint to `tools/lib/erx/native_irq.rb`.
* [Medium] `erlang/apps/erx_uart/src/erx_pl011.erl`: QEMU 11.1's PL011 writes each byte straight to its backend, so `FR.TXFF`
  never sets, and it forces the receive interrupt level to one byte, so the receive timeout never has a byte below the
  level to report; a character also arrives whole, never in flight. The `production_image` suite therefore still passes
  with the TXFF check before each `DR` write removed, with `RTIM` left masked, or with the character wait after
  disabling the UART removed. Run the real `erx_pl011` against a host register model behind `erx_device` that holds
  `TXFF` set for a while, delivers input below the level only through the receive timeout, counts `DR` reads and
  refuses a control register write while a received character is in flight, and require each of those mutations to fail.
* [Low] `test/guest/function_api/cases.c`: the hosted function-API binary exits 0 when a case prints `FAILED`, so only
  `hosted_function_api_test.rb`'s comparison against the expected lines catches a failure. Exit nonzero when any case fails.
* [Medium] `liberx/backend/fiasco/runtime_main.c`: `liberxroot.a` holds a `main`, and OTP links a tool with the archive ahead of its
  objects, so any member a libc reference reaches that comes to `runtime_entry.c` collides with the tool's `main`. The host test guards only
  `libc_root_write.c`. Moving `main` out of the archive, into ERTS's own `erl_main.o`, which is linked explicitly, removes the rule.
* [Medium] `tools/lib/erx/runtime_seam.rb`: `check_elf_objects` reads only the emulator's objects and six named libraries, unlike the hosted
  check, which reads the executable, so a library added only to the native link can import an unlisted name. Derive the list from the root's link map.
* [Low] `tools/lib/erx/fiasco.rb`: `Fiasco#build` records the audit report again before pack audits it, so a build output edited after the build, which `make` leaves alone, is recorded as built rather than refused. (From reading the code; not run.)
* [Low] `test/fixtures/runtime_event_harness.c`: the sleep step's waker is a single-threaded model of `sched_set_park_flag` and the wake in `erl_process.c`, at fixed points, and the
  `scheduler_wait` exit test (`erx_event_leave_wait_ready`) pins the call by source text, so the real crossing of a scheduler and its waker is not run.
* [Low] `tools/fuzz/boot_build_target.rb`: the boot fuzz targets do not require that any input is accepted, so a target that
  refuses everything passes, and the script copies the limits layout by hand rather than from `abi/erx_abi.txt`.
* [Low] `otp/erts/lib_src/Makefile.in`: `depend.mk` has no prerequisites and is made once per build copy, so a header that a lib_src source
  includes after that is no dependency of its object, and an edit to that header alone leaves the object stale. Use `-MMD -MP`.
* [Medium] `tools/lib/erx/runtime.rb` (`copy_sources`): `rsync -a` gives each copied source its time in `otp/` or
  build/gen, and make decides staleness from times, so a source whose new bytes carry a time older than its beam (an
  edit during a build, a file restored with `cp -p`, `tar` or `rsync -a`) is never recompiled, and the record, taken
  over the bytes, still says current. Copy with `rsync -rlpc`, so a file whose bytes changed gets the copy's time.
* [Medium] `tools/lib/erx/runtime.rb` (`build_application`): the build copy keeps each shipped application's
  `lib/<app>/ebin` from one build to the next, and OTP's beam rule (`otp/make/otp.mk.in`) names only the `.erl`, so a
  module of `otp/lib/*/src` that includes a generated header (none does) would keep its old beam over a change to
  that header alone, as would every module over a flags-only edit of its application's Makefile, while the record
  says current. The preloaded modules are compiled again on every build for this reason; for the applications, have
  erlc write dependency files (`+makedep`) that their makefiles include, or a build check, with its test, that refuses
  a `generated/` include under `otp/lib`.
* [Low] `otp/erts/preloaded/src`: the runtime build compiles the preloaded modules without OTP's
  `ERL_COMPILE_WARNINGS_AS_ERRORS=yes`, because the generated `erx_9p_grammar.erl` has no `-spec` for its documented
  request functions (`statfs_request/1` and others, from `tools/lib/erx/abi_emit_protocol.rb`). Emit the specs and pass it.
* [Low] `otp/lib`: OTP's source release ships some generated sources, which the import keeps: compiler's
  `beam_opcodes.erl`, `beam_opcodes.hrl`, `OPCODES-GENERATED` and `core_parse.erl`, stdlib's `erl_parse.erl` and
  `unicode_util.erl`, kernel's `inet_dns_record_adts.hrl`, tools' `xref_parser.erl` and each application's
  `src/deps/deps.mk`. Generate them in the runtime build from their inputs (`genop.tab`, the `.yrl` grammars,
  `uc_spec`) and delete them.
* [Low] `otp/erts/emulator/Makefile.in`: `erlang:system_info(compile_info)` answers `N/A` on erXos (edit 49 of
  `docs/design-runtime.md`), which no test pins until the oracle comparison runs.

* [Medium] `libc-test` on native Fiasco, `tools/lib/erx/libc_test.rb`:
  `regression/malloc-brk-fail` passes at 4 CPUs and runs past 60 s at 1 CPU
  under TCG, cause not found, so it is out of the canary set, and
  `check-libc-test tcg 1` would fail on it. Every test has a verdict at 4 CPUs
  under TCG (`test/conformance/libc-test-verdicts.txt`; `~/erxos-history`
  `f6d3e4a`, `libc-test/2026-11-05-tcg-4cpu`); runs at 1 CPU and under HVF
  have not been held to the table.
* [Low] musl, `musl/src/regex/regexec.c`, `src/math/powf.c`, `src/math/jn.c`:
  upstream bugs that `libc-test` pins as `upstream` verdicts. A back
  reference after a multibyte character compares the wrong bytes
  (`regexec.c:785`, `regression/regex-backref-oob`), `\(.\{1,3\}\)\1` finds
  no match in "foo" (`regression/regexec-backref`), `powf(x, 1)` raises
  INEXACT with OVERFLOW or UNDERFLOW (`math/powf`), and `yn` is 3.2 ulp off
  (`math/yn`). None is fixed on musl's master. Fix them in erXos's musl, or
  take upstream's fixes when they land, and drop their verdict lines.
* [Low] ERTS memory, `otp/erts/emulator/sys/common/erl_mmap.h`: stock turns off physical reservation, and with it the literal mapper, under `ADDRESS_SANITIZER`, and erXos's `erl_mmap` keeps it on. No ASan flavour of ERTS has run; settle whether literals stay in the mapper's range when one first does.
* [Low] ERTS memory, `erl_mmap.h`, `beam/erl_alloc_util.c`: `erts_madvise_discard_advice` lost its definition, and its declaration and uses stay behind `HAVE_MADVISE`, which both cross-compile files pin off. Delete them.

* [Medium] runtime, `make check-runtime-seam`: the name checks read `sys/erxos/imports.txt`, still wide, on the hosted objects by `make check-runtime-seam` and `make check-runtime-hosted`, and on the native objects in `Erx::NativeRuntime#build`, not before each link. The `__erx_syscall` number check, the comparison of the
  two `config.h` files, the source check for `__APPLE__` and the like, and the own lists of `erx_output.c` and
  `erx_stdio_nif.c` wait for `sys/erxos` to shrink
  ([design-runtime.md](docs/design-runtime.md#what-erts-imports)).
* [Medium] runtime, `tools/lib/erx/runtime.rb`: the build record covers neither the pack's own inputs (`tools/lib/erx/release.rb`, `pack*.rb`, `manifest.rb`, `config/platforms`, `config/provenance`) nor the archive's bytes, and is written before the pack runs, so a test run alone can read an older `system.pack`. Wants a release record written after the pack.
* [Medium] tools, `tools/lib/erx/pack_provenance.rb`: a `compiled` receipt declares its sources and names no `.hrl`; nothing ties a beam to them, and a `release` pack accepts it. Derive them with `erlc -M`, and hold them under a registered import.
* [Medium] tools, `tools/lib/erx/release.rb`: `boot_file` puts paths into an Erlang expression, so a checkout path holding `"` or `\` breaks or changes it. Pass them with `-extra`.
* [Medium] tools, `tools/lib/erx/production_image.rb`: `Run.checkpoints` predicts the root's device records from unit names (`RECORD_UNITS`), while the root keys on the unit's holder, each device's role and compatible string, and `machine.hostlink`, and a placement may hold several devices. A unit named otherwise, a unit held by another domain or a two-device placement fails the boot suites falsely. Take the count from the root's own record walk over the manifest (the host build `boot_manifest_test.rb` runs prints the records) and delete the list.
* [Low] tools, `tools/lib/erx/boot_image.rb`: `BootImage#build` removes its directory before `OutputDirectory.prepare` checks the path, so a `build/` that links out of the tree has the linked directory removed. Clear it through a check first, as `ProductionImage.clear_directory` does, with a test like `production_image_test.rb`'s link test.
* [Medium] runtime, `liberx/backend/fiasco/runtime_entry.c`, `device_give`: the root's own give and the domain library's (`liberx/system/dom_apply.c`, `apply_give_step` and `apply_given_words`) each build a device's objects and its `-erx given` record from the manifest row, and the register pages are computed three times (`erx_boot_device_window`, `dom_boot_view.c`'s `boot_pages`, the NIF's `erx_device_window_pages`); they agree today, but nothing compares them. Give the record one producer: build the root's records from the library's catalogue entries (a system give in the library, with the view built before the boot arguments), and keep one pure page function in a shared core header.
* [Medium] runtime, `liberx/backend/core/boot_manifest.c`: `peer_held` and `peer_held_total` stay zero on the page, and the projection is hand-written where the design generates it. No reader yet.
* [Medium] runtime, `liberx/backend/core/boot_info.c` and `liberx/system/dom_core.c`: a startup
  limit ERTS cannot keep (`processes` not a power of two or below 1,024, `atoms` below 8,192) is
  accepted by the manifest check and by domain creation and refused only when the domain's ERTS
  starts, through ERTS's usage text for the minimums. One C predicate used by the argv plan,
  `dom_limits_within` and the manifest reader would refuse it before anything is applied.
* [Medium] runtime, `otp/erts/emulator/beam/erl_init.c`: no test runs ERTS through
  `erx_runtime_settings_check`; the pure check is tested by `test/host/boot_info_test.rb` only.
  A hosted test (`beam ARCHIVE -P <twice the limit>` exits 1, `-SP 200:200` likewise, `-P <half>`
  starts) with a seeded wrong argument would cover the call.
* [Low] runtime, `otp/erts/lib_src/common/erl_misc_utils.c`: ERTS's own scheduler baseline is the
  cpuset's uncapped CPU count, so a relative `+S :M` or `+S -N` resolves against it rather than the
  plan's `-S`, and on a cpuset over 32 CPUs, or with capacity below the cpuset, a flag meant to
  lower a count is refused. Taking configured, online and quota from the plan's limits would let
  the leading `-S`/`-SDcpu` and `ProductionImage::Run.schedulers` go.
* [Low] runtime, `docs/design-runtime.md`, "Starting a runtime": a specification may lower `+t`
  below its own `foreign_atoms`; once `foreign_atoms` is enforced the lowering should be bounded by it.
* [Medium] runtime, `tools/fuzz/boot_manifest_fuzz.c`: the target compares the page with the reader's own result, so a swapped limit or a wrong host byte in `erx_boot_manifest_read` passes. Compare with `erx_manifest_open` and `erx_manifest_runtime_limits_at` called directly, field by field.
* [Low] runtime, `liberx/backend/fiasco/runtime_entry.c`: an `erx.arg` word of the kernel command line reaches ERTS's flag diagnostics unchecked, where the reader in `boot_manifest.c` holds `system_args` to printable ASCII. The command line is the operator's own.
* [Medium] runtime, `erlang/apps/erx/src/erx_device_record.erl`: `erx.arg` words of the kernel command line can spell `-erx device ...` or `-erx given ...` and add a device record the manifest never assigned, which a driver opens like the root's own; on the stopgap the command line is the operator's, but the manifest should stay the one source of which domain holds a device. Carry the records in a boot-information field only the root writes, or have the system domain's Erlang select them from the manifest through `erx_manifest`.
* [Medium] runtime, `erx_prim_file.c`: that a release file's bytes reach a read only after `erx_release_check` rests on `erx_copy_out` being ERTS's one user of `erx_release_addr`, with no build check. One call, `erx_release_open`, returning the bytes after the verdict with the cache inside `liberx`, removes the import and ERTS's flag, and Phase 2 then changes only what is behind it.
* [Low] runtime, `erx_prim_file.c`: a refused file is hashed and reported again at each open; `docs/design-kernel.md` has later uses fail at once.
* [Low] runtime, `liberx/backend/core/boot_manifest.c`: the printable rule for `system_args` lives in the reader, so `Manifest.admit` packs a manifest that then fails at boot, and `domains[].args`, the same string class, is not covered. The rule belongs in the `args` class of the ABI generator.
* [Low] runtime, `tools/fuzz/release_fuzz.c`: does not call `erx_release_check` or compare `erx_release_fs_lookup`'s index with the entry's, and has no seed at the longest path; its `fix_index` is a copy of `pack_fuzz.c`'s.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl`: the `Ctrl-G` menu (`erx_console_menu`) lists, connects and detaches; interrupting and killing a session, lock and log out (`docs/design-live.md`, "Job control") come with logins (M10), and `erx:console_size/2` is not built.
* [Medium] session, how the console learns a session's tty (`docs/design-live.md`, "Between domains"): the design has the console learn the tty from a `tty` agent in the session domain's ready report, but the relay needs `erx:cap(console)`, which init sets only after that report, so a relay started by the boot script has no master and one started after the report is not in it. Edit 65's `tty` agent, the domain pid's check that every agent is a pid of the domain's node, and a way for the session's creator to read the agents are not built; `erx_console:add_session/2` takes the tty from whoever creates the session. Settle the order when root's session starts at boot.
* [Low] tests, `test/integration/runtime_console_test.rb` (`make check-runtime-hosted`): the cases that start the Erlang shell wait for `1> ` at the start of a line, but the hosted system domain is a named node and its shell prompts `(system@erxos)1> `, so every `with_erxos` case times out before it begins. Match the prompt with its node name, or make the patterns node-agnostic as the `Ctrl-G` case is.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_core.erl`: the names quota is the constant `NAMES_QUOTA`, 64, for every principal; the manifest's per-principal `names` is read by no one. Take each principal's from its row, as the domain quota is.
* [Low] session memory, `config/manifest/qemu-virt-development.txt`: re-measure one session at its command shell under the lane driver's frame-sized funnel scratch (at most about 132 KiB a connection) and lower the session's 36 MiB budget, the principal's memory and its `max_message_heap` of 131,072 words if the numbers allow; they were sized for a scratch of 16 bytes a word of `max_message_heap`.
* [Medium] CPU grants, `config/manifest/qemu-virt-development.txt`: the storage and network domains each take a whole CPU of the users share, 2,000 of the 2,250 mcpu that the system share's reserve leaves configured domains (`dom_system_reserve`, `liberx/system/dom_core.c`), so a third configured domain (a web domain) has 250 mcpu of room. Size each service domain's grant from its measured use, or grow the reserve's bound, before a third configured domain is added.
* [Medium] tooling, configured-domain ids in the QEMU harnesses: `MediumBoot` (`NETWORK_ID`, `STORAGE_ID`, `DOMAIN_IDS`, `FREE_ID` and the catalogue rows of `DlControl` and `DlDevices`), `SystemDomain`, `SessionDomain::FIRST_SESSION`, `Regrant` and `DeviceGive::RESTART_ID` each re-derive by hand that configured domains boot in name order and that each later create spends an id, so adding a configured domain edits six files. Derive every id and row from one helper that sorts the manifest's configured domain names with the cell's added rows.
* [Medium] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl`: a domain whose pid died and whose stop the library refused never ends, so `ending/2` counts it for good and every later create and session start of its principal waits the full `release_wait` (10 s); record the refused stop and leave such a domain out of the hold.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl`: a login's session that has had the line and keeps ending (a shell that dies at its first input) is started again without limit, a domain build each round; throttle it as FreeBSD's init throttles a getty that keeps failing, and say so on the line.
* [Medium] session, `erlang/apps/erx_session/src/erx_session_sup.erl`: a restarted tty relay names itself with a new pid, which the console refuses (`tty_opened/4`), so the session is cut off from its line while its domain lives and holds the principal's one domain; make the relay's end end the session domain, or accept a new tty of the same domain once the old one is dead.
* [Medium] runtime, `erlang/apps/erx/src/erx_console.erl`: the login's life (`none`, `starting`, `{started, D}`, `{connected, D}`) moves in eight functions on five kinds of event, and only the session_domain QEMU suite covers it; make it a pure `login_next(Event, Login) -> {Login, Actions}` tested over every event in every state.
* [Low] runtime, `erlang/apps/erx/src/erx_console.erl`: a session whose console facet ends before its domain is dropped as ended, and the login started again is refused while the old domain lives; take only the domain pid's end as the session's, or stop the domain when its facet ends.
* [Low] domain service, `erlang/apps/erx_domain/src/erx_domain_srv.erl`: a held start runs even if its caller died while it was held, and a start invalid on its face (a bad name, no template) waits out the hold before its refusal; monitor the caller while held and check the request before holding it.
* [Low] domain library, `include/erx/dom.h`: `erx_dom_template_t` repeats `erx_dom_configured_t`'s resolved limits field by field, and `dom_spec_session` copies `dom_spec_configured` (`liberx/system/dom_core.c`); one resolved-limits record embedded in both, filled by one function, would leave a new limit one place to add.
* [Low] runtime, `erlang/apps/erx/src/erx_console.erl`: at boot the system domain's command shell prints its banner and prompt at the UART before the login's session takes the line, so a person sees two banners. Hold the system shell's first draw until the login has started or failed.
* [Medium] domain library, `tools/host/dom_plan.c`: the build's planner plans the configured domains but no session template, so a template whose limits pass property 14 but not its principal's ceilings, share, budget or domain quota is refused only when a session starts, and the console logs `a session did not start: einval`. Plan each template once there with `erx_dom_plan_session`, unrecorded, beside the configured domains.
* [Low] runtime, `erlang/apps/erx/src/erx_console.erl`: the console never sends `tty_hangup`, which ending a session from the menu or a log-out sends, and a repeated answer would carry.
* [Low] runtime, `otp/lib/kernel/src/prim_tty.erl`: `init_term/1`, the reader and the writer stay as stubs for `user_drv`'s stock paths, which `load/0` keeps unreachable; they go when `user_drv` itself leaves the release.
* [Low] runtime, `otp/lib/stdlib/src/io_ansi.erl`: with no terminfo a shell's `io_ansi` is plain text where stock on an xterm has colour. A fixed table of the ANSI sequences would answer it.
* [Medium] runtime, `otp/lib/stdlib/src/io_ansi.erl`: fix in erXos's OTP four upstream OTP 29.1.2 bugs in the ANSI fallback strings, which erXos always uses since it has no terminfo: `cursor_home` is `ESC H` (HTS, a tab stop) for `CSI H` (`:2614`); `scroll_forward` and `scroll_backward` are `ESC S` and `ESC T` for `CSI S` and `CSI T` (`:2646-2649`); `tab_backward` is `ESC I` for `CBT`, `CSI Z` (`:2684`); `hyperlink/2` writes the URI before the parameters, the reverse of OSC 8's `OSC 8 ; params ; URI ST` (`:2788-2790`). The fix lands with a test that each string is the standard form `erx_vt` implements ([design-display.md](docs/design-display.md#the-terminal-emulator)), and is a documented difference from stock OTP for `make check-oracle`.
* [Medium] shell and programs, several ttys in one session: a display's session runs a shell on a tty per terminal ([design-display.md](docs/design-display.md#the-terminal)), but [design-shell.md](docs/design-shell.md#job-control) and [design-programs.md](docs/design-programs.md#the-terminal) speak of "the session's tty" in the first tier. State that the terminal relay serves each of the session's ttys, that each runs its own command shell and job table, and that a program's `/dev/tty`, standard streams and `ps` `TT` are those of the tty its shell started it from.
* [Low] runtime, `shell:start_interactive/0` calls `user_drv`, which does not run: it exits with `noproc` where stock answers `{error, already_started}`.
* [Medium] runtime, `otp/erts/emulator/sys/erxos/sys.c`: `kill -INT` runs the break menu while `erx_stdio`'s reader still reads standard input, so a key can go to either; on this port SIGINT should leave through the exit path. No test.
* [Medium] runtime, `erx_console.erl`: `get_terminal_state` reports standard input's answer for all three streams and `tty_geometry` answers 80 by 24 with no terminal, where stock asks each descriptor and refuses. A start failure of the driver loses its step and reason in `user_sup`'s ten-second wait, and `erx_stdio_nif.c` reports every IRQ failure as `eagain`.
* [Low] runtime, `tools/lib/erx/runtime_seam.rb`: the executable check drops an own list's names, so a library missing from the object list that calls them passes.
* [Low] runtime, `erx_stdio_nif.c`: a fatal signal or SIGKILL leaves the terminal raw; `start_nif`'s failure paths leave what they made; a stalled standard output delays input, which one process handles; and `SIGWINCH`'s `sigaction` skips `sys_signal`'s `SA_ONSTACK`.
* [Low] runtime, `standard_error.erl`: a failed write crashes the server with no log, which a later `set_unicode_state` carries into `erx_console`.
* [Medium] runtime, `liberx/backend/fiasco`: the native root does not read the release's manifest: its page takes
  `erx.arg=WORD` alone, with `system_args`, `limits`, `pack_flags` and `release_addr` empty, and no archive holds
  a native root with these release files. `liberx/backend/core/boot_manifest.c` is the reader to link, and
  `Erx::Release.differences` the comparison `test/integration/runtime_release_test.rb` runs over two hosted packs
  until then.
* [Medium] runtime, `erx_erofs`: `erx_ns:mount({erofs, Window}, To, [])` mounts an image from a block
  service window and `prim_file` reads it, but nothing in the running system mounts one: the block
  service serves no window on an image inside a slot (the slot's images follow the boot image, whose
  layout the slot parser reads), and the runtime mounts no image at domain creation from the boot
  image's grants ([design-files.md](docs/design-files.md#building-binding-and-mounting)), so the boot
  table holds none. `erx_verity:open/2` takes only the tree `unchecked` until the packer writes each
  image's hash tree and the boot image records its root hash, salt and layout (M11).
* [Low] runtime, EROFS mounts: `erx_erofs_file` opens no directory (`[directory]` answers `enotsup`) and
  exports no `copy/3` or `ipread_s32bu_p32bu/3`, so `file:copy/3` from an image's open file and
  `disk_log`'s positioned reads of one fail; `set_cwd` on an image checks no search bit; every image
  reports device 0, so two images' files can share a device and inode pair; and `erx_ns` monitors no
  image's window, so a window pid the runtime later gives another process would receive the image's
  reads. No test.
* [Medium] runtime, `erx_ns`: an image's mount reads the image in `erx_ns`'s own process, so a window
  that does not answer, or any local pid passed as one, holds every mount, bind and unmount of the
  domain for up to 40 s a read (three reads a mount); the mount belongs in a monitored worker whose
  result the process applies once it checks the point again. No test.
* [Medium] runtime, `erx_verity`: blocks pass through unchecked until the image's hash tree is written and
  checked in `checked/1` (M11); there is no cache, neither of checked blocks nor the reader's ETS table
  of 256 metadata blocks per image ([design-storage.md](docs/design-storage.md#reading-erofs-images)
  step 4), so every lookup reads its inode and directory blocks again; a log of a failed read goes only
  to the reader's mount log function.
* [Low] test, `erx_erofs`: the fixtures fsimg writes hold no hard link (fsimg writes none), no chunk-based
  file (incompatible bit 0x4, which the reader refuses) and no regular file in the plain layout with a
  partial last block, so no case reads a shared inode (nlink 2) or checks the chunked refusal or that
  tail; each can be made by patching `compact.img` in the EUnit cases and fixing its superblock checksum.
* [Low] test, dm-verity: the hash tree the packer writes is checked only by `erx_verity`, erXos's own
  code; no outside implementation such as `veritysetup` checks the tree format.
* [Low] runtime, `erx_erofs`: the superblock's CRC-32C is computed bit by bit in Erlang, not by the
  per-byte primitive `erx_bytes:crc32c/2`: the reader's EUnit cases and fuzz target run it on stock
  OTP, which has no `erx_bytes` BIFs, so moving it needs an Erlang stand-in for those runs (at boot
  only `erx_ns`, in the same `erx` application as the primitive, mounts an image). The reader's form
  is Linux's, seeded with all ones and not inverted at the end, so over the covered bytes it is
  `erx_bytes:crc32c(0, Covered) bxor 16#FFFFFFFF`. Device, FIFO and socket inodes answer `enotsup`, which the
  packer's trees never hold.
* [Low] runtime, `erx_erofs`: a walk that fails inside an operation (`eio`, `enotsup`, `enametoolong`) answers
  `{[], Error}`, dropping the kinds it passed, so `erx_path` places the error at the first name; a superblock
  claiming more blocks than the window holds fails later as a read failure, not at mount as malformed; the
  fixtures give every entry one mode and one time (the manifest's modes 0644 and 0755 and time 0), and only
  `extended.img` varies the owner (uid and gid 70000), so no case checks the mode-bit and mtime offsets
  with other values; fsimg's manifests can write them.
* [Medium] test, F2FS oracle: erXos's F2FS is checked against Linux's, which needs a Linux guest under QEMU
  with a pinned kernel that has F2FS (Debian's generic arm64 kernel is the candidate to check) and
  f2fs-tools. Neither the guest nor its pins exist.
* [Medium] runtime, `otp/erts/preloaded/src/erx_file_remote.erl`: `file:ipread_s32bu_p32bu/3` on an open
  file of a grant has no implementation, so it raises `undef`.
* [Medium] runtime, `otp/lib/kernel/src/file.erl`: `file`'s name calls (`copy`, `delete`,
  `rename`, `read_file_info` and the rest of `check_and_call/2`) still send the path to
  `file_server_2`, which then talks to a 9P server itself, where design-files.md (the
  file server paragraph) says `file` resolves the path first and sends only local paths
  there. A slow or stuck server stalls every name call in the runtime, and a server that
  called `file:` name functions while serving would deadlock. Resolving in the caller
  removes both.
* [Medium] runtime, `file:copy_opened_int/4`: a short read is taken as end of file, and
  `erx_file_remote:read/2` may answer fewer bytes than asked, so a copy from a remote
  file into a local one could stop early and still answer `{ok, N}`. Unreachable today
  (the `/tmp` server answers whole units and the release tree is read-only). Either the
  loop reads until `eof` or `erx_file_remote` fills each read.
* [Medium] runtime, `erx_file_remote`: the read buffer's differences from stock have no pins in
  `prim_file_compare`'s `tmp_ahead`: a `pwrite` through the read-ahead file itself (stock then skips the
  bytes read ahead, an upstream bug to record), an error after buffered bytes (erXos answers the bytes,
  stock the error), and a `{read_ahead, X}` that is not a count (erXos reads none ahead, stock's read
  raises). Unpinned paths too: read-only, write-only and append files with `read_ahead`, a `pread` then
  a `read`, a line longer than 256 bytes and the read-ahead. A server that answers every request in full
  makes one read hold up to 0x7ffff000 bytes in the caller's heap.
* [Low] runtime, `erx_file_remote`: the read buffer agrees with the offset only because every call that
  moves the offset other than the reads goes through `emptied/2`; keeping the buffer's start offset in
  the cells would make it hold by construction. A read whose new offset passes 2^63 - 1 answers eio
  after the buffer has changed, leaving it out of step. `read_file` flattens a large file twice
  (`read_in_units` and `contents`), about three times its size at peak.
* [Medium] runtime, `erx_file_remote`: `read_file` keeps up to the size a server's `getattr` answers and
  `read_line` reads until a server sends a `"\n"`, so a hostile server can make the caller, perhaps the code
  server, hold as much as it sends until the node dies; stock fails such a size up front with `enomem`. A
  bound per call would make the caller's heap the client's to limit.
* [Medium] runtime, `erx_file_remote`: `exchange/2`'s refusal of a writing request through rights other
  than `rw` has no seeded test of its own, since every operation refuses first (`created/4`, `if_writable/3`,
  the descriptor's access), and no build check keeps `sent/2` the module's only send; a seed that drops
  `created/4`'s read-only clause, watched by the tree's observer, and a send-site count in
  `test/host/erx_file_remote_test.rb` would make it a chokepoint as CLAUDE.md asks.
* [Medium] test, `test/integration/runtime_prim_file_test.rb`: the open-file cases (`OPEN_FILES`) are
  hand-written expectations rather than the same calls run on stock over a local directory, which the
  oracle rule asks for. Known differences from stock: `position(Fd, {bof, 1 bsl 64})` answers `einval`
  where stock answers `badarg`; a `pread` at a negative offset through a write-only descriptor answers
  `ebadf` where Linux answers `einval`; `read_file` of a file whose `getattr` size is 0 answers `<<>>`
  where stock reads to the end.
* [Low] runtime, `erx_file_remote`: `list_dir` of a directory on a grant lists only the server's entries,
  not the mount points directly below it ([Resolving a path](docs/design-files.md#resolving-a-path),
  listings across mounts), which needs the namespace's table from the NIF.
* [Low] runtime, `erx_file_remote`: `#file_info.major_device` is a hash of the grant's pid and tree where the
  design has a number the namespace gives each mounted tree; two trees can collide.
* [Low] runtime, `otp/erts/preloaded/src/prim_file.erl`: `delete/1` answers every `einval` as `eperm`, a
  server's answer to `unlinkat` included, where FreeBSD's `kern_funlinkat` turns only `namei`'s `EINVAL`
  and lets `VOP_REMOVE`'s stand ([Errors](docs/design-files.md#erlang-clients-prim_file-and-erx_file_remote),
  step 2); the resolver's answer needs to reach `delete/1` apart from the server's for the translation to
  apply to it alone.
* [Low] runtime, `erx_file_remote`: `del_dir`, `delete` and `rename` of a mount point answer `ebusy` only
  when the point is the tree's root; a bind of a directory below the root is removed or renamed through the
  bind where Linux answers `ebusy`; the remote answer's place says so (`Names =:= Root`), so the check is one
  comparison in `remove`, `renamed` and `make` once `Try` receives the place.
* [Low] runtime, `erx_file_remote`: a relative symbolic link among a bind's root names (a bind made
  through a link) answers `enoent`, since the bind fixed its root as names and the link's directory lies
  above the entry's point; resolving `From`'s links when `erx_ns:bind` binds would remove the case.
* [Medium] runtime, `erx_file_remote`: on a read-only entry `erofs` is answered once the last name's directory is
  reached, before the last name is looked at, where Linux answers `eexist` or `enotdir` for the last name
  first (`make_dir` of an existing name on a read-only bind answers `erofs`, stock `eexist`).
* [Medium] runtime, `erx_file_remote`: the server's replies, the client's untrusted input, have hand-written
  hostile cases in `test/integration/prim_file_compare.erl` but no fuzz target; the fuzz target covers the
  caller's path text only.
* [Low] runtime, `test/integration/runtime_prim_file_test.rb`: no seeded fault shows the /tmp transcript
  catches a missing turn of the error steps (`enotempty` to `eexist`, `einval` and `eisdir` to `eperm`),
  which live in preloaded `prim_file`, which a seed cannot replace after boot; and none shows it catches an
  executor that never hands a stopped walk to its resumption. Seed `erx_file_remote:passed/2` to answer
  `true`, and the turns through a hosted build of their own, or name the transcript lines that cover them.
* [Low] runtime, `erx_file_remote`: `list_dir` opens without `O_DIRECTORY`; a partial walk answers `enoent` for any refusal;
  negative times answer `einval`; an empty symlink target is sent; a listing may hold up to 2^20 names of
  255 bytes; the xref check exempts every call through a variable.
* [Low] runtime, `tools/fuzz/release_names_fuzz.c`: the oracle does not check that an accepted name is valid
  UTF-8, and walks only an empty release, so the walk's cursor past the first name is not fuzzed.
* [Low] runtime, `erx_prim_file.c`: `efile_set_cwd` is dead since stock `set_cwd_nif` went;
  `efile_ns_set_cwd_nif` keeps `ns` in its name; a symlink's text marshals to an empty name list, the
  release top, so a future NIF that used it as a path would act on `/`; docs/design-files.md still names
  `erx_get_cwd_nif/0` and a mutex where the code uses `get_cwd_nif` and an rwlock.
* [Low] runtime, `erx_path.erl`: a run's names are checked against `ERX_NAME_MAX` before its earlier names are
  walked, so `missing/<256-byte name>` answers `enametoolong` where FreeBSD answers `enoent`; and a link's text
  is bounded against the names left to read rather than the bytes, so doubled slashes are not counted. Check
  each name as it is reached and count the path's own bytes, or record both as differences.
* [Low] runtime, `erx_path.erl`: on a read-only provider's entry, a create of a missing last name with a trailing
  `/` (`open("new/")` with `O_CREAT`) answers `enoent` where FreeBSD answers `erofs` before the trailing-`/` check,
  because the resolver does not know which entries are read-only. Give the table's entries their read-only flag,
  as the empty root already answers `erofs`, or record it as a difference.
* [Low] runtime, `erx_path.erl`: a parent's resumption accepts a reply whose kinds are all directories and that
  ends in an error, answering the error where the design says `eio`. Accept only the directory's kinds plus one
  `link`.
* [Low] `test/erlang/erx_path_fuzz.erl`: no seeded fault shows the root-prefix property catches anything, seeds
  are matched by `mismatch` rather than by the case the design names, the differential never reaches
  `enametoolong`, and every entry lies over one tree.
* [Low] runtime, `erx_ns`: `which/1` and `list/0` of
  [design-files.md](docs/design-files.md#interfaces) are not written.
* [Low] test, `test/host/space_test.rb`: `test_the_drops_of_a_hold_race_under_thread_sanitizer` fails on this host:
  the seeded relaxed drop exits with an error, but its log holds no `ThreadSanitizer: data race` line (the
  assertion reads an empty log). Seen twice in a row on Apple Silicon macOS with Homebrew LLVM 23.1.3, under
  `make check` and alone. Find whether the log path or TSan's report is missing before trusting the seeded race.
* [Low] /tmp, `test/host/erx_ramfs_test.rb`: `test_seeded_fault_2_is_caught` expects the mutant to fail
  `a_dead_owners_open_file_gives_back_what_it_held_test`, but under load (a full `make check`) the mutant runs into
  EUnit's timeout in `wait_free/3` first and the case reads `*timed out*`, so the seeded-fault test fails though the
  fault was caught; it passes run alone. Accept a timeout as caught, or bound `wait_free/3` below EUnit's timeout.
* [Low] /tmp, `erx_ramfs_sup` under `kernel_safe_sup`
  ([design-tmp.md](docs/design-tmp.md#starting-and-mounting)): a crash of the tree process that recurs
  on every restart, such as one a request reproduces, passes `kernel_safe_sup`'s restart intensity, which
  ends `kernel` and halts the node. A Phase 1 residual: `/tmp` is the domain's own, so the domain ends
  with it. The restart test of [/tmp's verification](docs/design-tmp.md#verification) covers one crash,
  not a recurring one; a recurring crash would want `erx_ramfs_sup` to give up on `/tmp` alone.
* [Low] /tmp, `erx_ramfs_serving`: the serving set's `xref` closure follows only calls it can
  name, so a module a serving process reaches through `apply/3` or a fun value it was handed is
  not in it. Two seeded faults of [/tmp's verification](docs/design-tmp.md#verification) are not caught by
  the hosted tests (the concurrency case also does not run `erx_ramfs_core:check/1` afterwards, which
  docs/design-tmp.md's Verification lists): the rename split into two steps (the client unlinks the destination, then renames)
  passes the concurrency case with 0 misses in 1,608 stats over 800 renames, so that case does not yet
  show it runs the interleaving it exists for (one scheduler may starve the statters; a case run with
  schedulers online or with the statters sending ahead of the renamers would settle it); and a grant that
  does not clunk a dead owner's fids passes the hosted killed-process case, probably because the runtime's own handle
  release clunks first, so only `test/host/erx_ramfs_test.rb` catches it. The cold case's seeded start that skips one module of the generated list is not run: no module the
  serving processes need is found unloaded at the cold steps in the one tried (`epp` is loaded by io formatting
  alone), so the choice of module wants a trace of the first calls of the unseeded cold steps, and the
  deadline path (a deadlocked code server) wants the later cold steps under a deadline too. The walk-in-place seed of that section
  breaks every open in the /tmp transcript, so it ends the run before the `victim` case; it is run only against the
  test grant (`test_seeded_walk_removes_the_victim`), and for /tmp it needs a fault confined to the path operations.
  "Held is back" is read through `bfree`, whole 4,096-byte blocks, so a leak of one node's charge goes unseen.
* [Low] runtime, `erx_prim_file.c`: `file:sendfile` on a release file answers `einval`, since `efile_get_handle`'s
  empty binary fails `prim_inet`'s length check, and so misses `file`'s fallback on `enotsup`; the check belongs
  in `prim_file:sendfile`. Two concurrent relative `set_cwd` calls can store an answer no serial order gives:
  the resolve and the store want one hold of the write lock. On a grant a `getattr` exchange lies between
  them, so there the store wants to check that the working directory is still the one the path was
  resolved against.
* [Low] runtime, `liberx/release.c`: `erx_release_entry`'s `ERX_ERANGE` also stands for a failed decode, which
  the kernel's backend must tell apart.
* [Low] runtime, `otp/erts/configure`: edited by hand, because the tree holds autoconf 2.72's output and the
  installed autoconf is 2.73, whose output differs throughout. Each edit is also in `configure.ac`.
* [Medium] runtime, the native boot page: the comparison of the two entries' pages waits for a native release that boots, and so does the range check on `limits`, of which `erx_boot_info_build` and `erx_boot_info_read` check only the reserved word ([design-stopgap.md](docs/design-stopgap.md#boot-information)).
* [Medium] runtime, the log sink (`erlang/apps/erx/src/erx_log_h.erl`): no domain holds a console facet, since the domain service makes no connections, so a domain's logger proxy writes each record into the kernel log, which escapes it and labels it with the domain's space, and not to `erx_console`. The console's shape and rate checks and its line under the domain's id, principal and name (`erx_console_log`) therefore serve the system domain's records alone, and a domain's records are held to the log's rate for its space ([design-live.md](docs/design-live.md#the-console)). The proxy sends to the facet once the domain service hands one out with the domain's connections. The proxy is not the domain's `erx_tty_owner` either, which edits 35 and 42 need. When the facet comes, it must hand `erx_console_log` each record with the source of the lane it arrived on and never pass a bare `{log, Level, Text}` to `erx_console`, which shows a bare record as the system domain's.
* [Medium] runtime, the log sink (`erlang/apps/erx/src/erx_log_h.erl`, `erlang/apps/erx/src/erx_console.erl`): no overload protection. `logger_std_h`, which `erx_log_h` replaces, runs `logger_olp`'s sync, drop and flush modes; `log/2` sends unconditionally, so a flood of events (a crash loop with large reports) grows `erx_console`'s queue in the system domain, ahead of console input, and the proxy's elsewhere. A queue-length check in `log/2` that drops and counts past a bound, or `logger_olp`, would bound both ([todo-performance.md](docs/todo-performance.md)).
* [Medium] runtime, the log sink (`otp/lib/kernel/src/logger.erl` `log_remote`, the default `remote_gl` filter): an event of a process whose group leader is in another domain, such as one an rpc from the system shell spawned, is sent to `{logger_proxy, Node}` on the group leader's node, which never leaves the domain (edit 27), and the local default handler's `remote_gl` filter drops it, so it reaches no sink. A domain's events are its own: drop the forward and the filter in erXos, after checking which OTP suites depend on them.
* [Low] runtime, `otp/lib/kernel/src/logger.erl`: with edit 57 the `default` handler is `erx_log_h`, so OTP's logger suites that expect `logger_std_h` there (`logger_env_var_SUITE` among them) are expected to differ from stock; `make check-oracle` has not run with the edit, and `test/oracle/hosted_known_differences/kernel.txt` wants the cases it finds.
* [Low] runtime, `erlang/apps/erx/src/erx_console.erl` `system_source/0`: the system domain's principal (1) and name (`system`) are written by hand, as `erx_kernel_records` writes its id; the domain service's table should give all three.
* [Medium] runtime, a domain's standard I/O (`otp/lib/kernel/src/user_sup.erl`): a domain has no tty yet, and `-noshell` or `-noinput` start `user_drv`, whose `prim_tty` NIF is gone, so a domain started with them fails at `user`; `native_domain`'s ERTS domain starts with `-nouser` and writes with `erlang:display`. A domain with a user will also need `erx_shell` in its release (`erx.app.src`), beyond `ReleaseFiles::DOMAIN_BASE`. A domain's groups and tty ([design-live.md](docs/design-live.md#the-tty)) replace that.
* [Medium] runtime, `otp/lib/kernel/src/dist_util.erl`: `gen_challenge/0` calls `statistics(runtime)`, which fails with `notsup`, so a distribution handshake ends there. No `1>` reaches it; the first carrier does.
* [Low] runtime, `liberx/backend/hosted/start.c`: six names of the host's environment reach the page for the stock fd, spawn and forker ports and the stock terminal driver, where the design's page holds none. They go with those layers. The forker exits when `BINDIR` is unset and runs `erl_child_setup` from that host directory, so a boot is not yet free of host files.
* [Low] runtime, `beam/erl_time_sup.c`: edit 20 of the design is open. The stock correction runs over `erx_clock_ns`, and stays idle since system time moves with it by one offset; deleting it changes nothing a shell sees.
* [Low] runtime, `otp/erts/emulator/sys/erxos/sys_time.c`: `os_monotonic_time_source` and `os_system_time_source` report the nanosecond unit as the resolution, where macOS's clock ticks by the microsecond; a backend call for the granularity would make it true.
* [Low] runtime, `otp/lib/tools`, `otp/erts/etc`, `otp/erts/start_scripts`: not buildable from the imported
  tree (`public_key.hrl`, `ei.h`, `lib/os_mon/vsn.mk`). The runtime does not need them; `lib/tools` is to ship
  or leave the import when the release's application list is settled.
* [Low] Lane reader and writer, `liberx/erx_lane.c`: each record state
  machine (open, copy, close) is inline in `erx_lane_take` or
  `erx_lane_put` rather than a pure step the effect layer applies;
  `phase` and `fault` are a pair that must agree; `erx_lane_reader_init`
  and `erx_lane_writer_init` fix the connection side layout, so a pipe's
  or channel's reader or writer and an end that resumes at a position
  need separate pointers and a start position. Settle with the pipe
  server and the channel client.
* [Medium] Lane writer, `liberx/erx_lane.c` `lane_write_header`: the record
  header is packed by hand from the generated offsets, because the ABI
  generator emits only `_decode` for `wire_le` layouts; a field whose width
  changed in `abi/erx_abi.txt` would be written at its old width. Emit an
  `_encode` for `wire_le` layouts and call `erx_lane_rec_encode`.
* [Medium] Lane driver test between two domains, `test/guest/native_domain`:
  the `connection` cell drives the driver over one domain's system
  connection, with the root as the system party. Two domains connected by
  `erx_dom_lib_connect` cannot open their ports until `connection_up`
  (RT6b) tells a runtime the connection's values; that cell lands with RT6b.
* [Medium] Runtime, export table, `erx_exports.c`: what the table does not do yet.
  (1) The spawner's boot exports (`spawn` on the domain, `send` on init) are not written:
  the boot page names no spawner, only the system domain. (2) A holder of a connection that
  has ended holds nothing, but keeps its entry, counted against the bound, until its name
  ends or the next write for that peer on the name replaces it; a long-lived process handed
  to many peers that have since ended keeps their entries. Drop them at the next write to
  the set, or at the connection's end. (3) The bound is the constant 16,384, not a manifest or
  `-erx exports` value. (4) The hold's `request_words` is 0 until edit 12 (RT8). (5)
  `ERX_FUNNEL_DELIVER_IF_LINKED` is answered `noproc`, which is wrong when the target already
  holds a link with the sender (one a process of this domain made toward the peer's
  process): the peer's process then gets an exit of `noproc` for a live link; it needs a link
  record the input task can read.
* [Medium] Runtime, export table, `erl_process.c` `erl_create_process` and
  `erx_exports_spawned`: a spawn from another domain when the table is full still creates
  the child, and `erx_exports_spawned` only counts the full answer, so the spawner holds nothing
  on it. Its exit toward the child is unheld, so the parent's death never ends a
  `spawn_link`ed child, and the parent gets a pid it cannot message. Refuse the spawn with
  `system_limit` in the `SPAWN_REPLY`, or reserve the entry before the child is made.
* [Medium] Runtime, export table, `erx_exports.c` `EXPORTS_MAX` and `live`: one bound for
  every peer, so a peer that can make this domain create processes or hand out new pids
  (a spawn, or a server that starts a worker per request and answers from it) fills the
  16,384 entries for all of them, and pids handed to the system domain afterwards behave
  as dead. design-domains says a domain that fills its table hurts only its own
  correspondence. Needs a quota per peer within the bound.
* [Medium] Runtime, export table, `erx_exports.c` `EXPORTS_MAX`: pids and handed-out
  aliases share the 16,384 entries, so a domain holding many handed-out names leaves no
  room for the alias of its next cross-domain `gen_server:call`, and that call times out,
  its reply reaching no one (design-runtime, "Representation and aliases"), however few
  aliases the domain itself has active. A quota per peer (the item above) bounds what one peer
  can make it hold; a separate bound for aliases would only move the limit.
* [Low] Inspector, `erlang/apps/erx/src/erx_inspector.erl`: no path shows a runtime's
  `erx_dist:exports_refused/0` (hand-outs and spawns the full export table refused) or
  `erx_dist:names_dropped/0`; both are BIFs only. Give each domain's runtime counters a
  record under `[domains, D]`.
* [Low] Runtime, alias registry, `erl_monitor_link.c` `erts_monotor_tree_lookup_insert` (stock
  OTP's spelling): it does not keep the registry, and it has no caller; delete it, or hook it
  as the tree's insert is. `erts_monitor_tree_replace` keeps it: its callers (`bif.c`,
  `erl_proc_sig_queue.c`) move an alias state to a monitor of the same key and owner, or
  swap node monitors, which hold no alias; an ASSERT there that key and alias state match
  would keep it so.
* [Medium] Runtime, references, `erl_bif_unique.c` `erts_sched_make_ref_in_array`: each
  source is used by its own thread only because every caller passes the calling thread's
  esdp, and a dirty scheduler's `thr_id` gets its offset only in
  `sched_dirty_*_thread_func` (`erl_process.c`), so a call before it, or with another
  thread's esdp, draws from another thread's source. Make it hold by construction: write
  the final `thr_id` once in `init_scheduler_data`, and read the scheduler data from
  thread-local storage instead of an argument.
* [Low] Runtime, export table, `erx_exports.c` `holder_add` and `erx_exports_close`: `live`
  is incremented before the bound check and rolled back after, and a close subtracts only
  after unlocking, so a hand-out racing them near the bound is refused, and counted, while
  the table has room. Refuse at the bound with a compare-and-swap that never overshoots,
  and subtract under the lock.
* [Low] Runtime, alias registry and reference comparison, `erx_alias.c` `entry_cmp` and
  ERTS's reference compares: words a peer sends are compared with live identities by
  `sys_memcmp` and word by word, which may stop at the first differing byte. The timing
  says how many leading bytes of a guess match a live identity in the same bucket; a
  constant-time compare of the four words removes the question.
* [Medium] Runtime and domain service, introduced connections, QEMU cases still to write
  (`tools/lib/erx/system_domain.rb`): design-domains' delayed-ready case (a domain whose init
  delays its ready report while its creator writes a spawn request into their connection, with
  the seeded domain service that hands the domain pid the record before the report) and
  introduce's `system_limit` refusal run on the host only (`erx_domain_tests`). Both need a
  third domain created at run time, which the suite cannot make cheaply: its two configured
  domains, 160 MiB each (`MediumBoot::DOMAIN_MEMORY`), fill the medium machine
  (`MediumBoot::MACHINE`, 768 MiB, room for two), and init sends its report before any `-eval`
  (edit 65), so nothing delays it. Grow the machine or shrink the domains, give the suite an
  `erx_domain:create/1` of a third domain, and give the delayed case a way to hold the report.
* [Low] Domain service, `erx_domain_srv.erl` `retire/2` and `act/2`: a refusal of
  `Lib:retire/1` (a system connection whose disconnect was refused, or counts that do not
  hold the domain, each a bug) is only logged, leaving the record in the library, and a
  refusal of `Lib:disconnect/1` is only logged, leaving the connection's objects and any
  remains; nothing tries again. Decide whether either ends the service, as `close_side/4`
  does on `noproc`.
* [Medium] Runtime, `erx_connections.erl` `records/3`: the agent serves every record in
  turn and waits inside a finish, which may pause on a process of the domain at its queue
  quota (design-runtime, "Closing"), the agent itself included when a peer handed its pid
  floods it, so one paused finish holds the domain's answers about every other peer, and
  with them those connections' objects and quota. No queue quota is set by default, so
  nothing pauses yet; before edit 15 lands, exempt the agent from the quota or make the
  finish asynchronous (a finishing phase in `Held`, `erx_lane_finished` and the `DOWN`
  matched in `records/3`). The test hold (control command 4) can also be set again during
  a finish, which then never ends; refuse it on a finishing port.
* [Low] Lane driver, a test hook: the lane driver's control command 4 (`erx_lane_drv.c`,
  `control_hold`, allowed only under `-erx test_lane_hold`) holds a port's ring takes so the
  system_domain suite can fill the lane from the system domain, and so its connection_down
  step's burst waits in an introduced lane for the finish. Edit 15's queue quota fills a ring
  and pauses a port by design; once it lands, drive both steps from it and delete the hook,
  with the flag and `DOMAIN_ARGS`'s use of it.
* [Medium] Lane control table, `liberx/erx_lane.c` `erx_lane_ctl_take`: the reader loads a
  slot's `seq`, then copies its frame, and does not load `seq` again after the copy, so a
  writer that rewrote the slot during the copy (one that broke "A slot is rewritten only
  after its last record is answered") yields a torn frame taken as one record. Load `seq`
  again after the copy and report a change as a rewritten slot, with a host test that
  rewrites between the two loads.
* [Medium] Lane driver, `erx_lane_drv.c`: a side's part in its control table (writer,
  reader, none) is read from which of `ctl_seq` and `ctl_in` are NULL at each site
  (`table_step`, `control_record`, `control_hold`, the open). Give the connection an
  explicit role enum set once at open, so each site matches on it.
* [Low] ERTS distribution (`beam/dist.c`, `beam/erl_process.c`): where `erts_link_dist_insert` fails (dist.c's DOP_LINK and spawn paths, a remote spawn's link in `erl_process.c`), the link's `dist` stays NULL and `erts_proc_sig_send_link_exit_noconnection` dereferences it; stock, and thought unreachable on erXos, whose lane port holds the port lock across input and `erts_do_net_exits`, but not traced on every input path.
* [Low] OTP kernel, `global_group` (edit 64 of design-runtime): `continue_handle_info/2`'s config-check `DOWN` takes `noconnection` as no contact and every other reason as a sync error, so with `global_groups` configured a domain's end, `{domain_down, D, Info}` (edit 56), puts the node in `sync_error`; erXos configures no global groups, but the guard is one line.
* [Low] Oracle, pid text (edit 18): OTP cases that write a local pid as `"<0.N.S>"` get `badarg` in a runtime
  that is alive with a nonzero creation: compiler `core_fold_SUITE:coverage`, emulator `guard_SUITE:guard_bifs`
  and a case of stdlib `qlc_SUITE`. The hosted runtime is not alive, so they agree there; give them rows in
  `test/oracle/hosted_known_differences/` once an oracle run's runtime is a node.
* [Low] Domain library, `liberx/system/dom_core.c` `dom_strings` and `boot_info.c`: the plan admits
  arguments and environment up to `ERX_BOOT_STRINGS_MAX`, but the boot page counts the node and the system
  node against the same limit, so a request within the plan's bound fails at apply (step 23, `ERX_EINVAL`)
  instead of being refused by the plan. Count the names in the plan, or give them their own bound.
* [Low] Runtime, `otp/erts/emulator/beam/bif.c` (`list_to_ref_1`): report the upstream bug to OTP. In stock
  OTP 29.1.2, a reference text whose six numbers each end in `.` (`"#Ref<4.1.2.3.4.5.>"`) leaves the parse loop
  with `i` at 6, so the copy into `refn` reads `ints[6]` past its six entries and writes `refn[5]` past its five:
  a stack overflow on any text a caller passes to `list_to_ref/1`. erXos's copy refuses that text with `badarg`
  (edit 18; native_domain's connection case checks it).
* [Low] Domain service, `erx_domain_core.erl`, `erx_ident`, the manifest check: nothing reserves
  the name `system`, so a request or a configured row named `system` is admitted, spends an
  id and is refused only when the boot page is built (its node would be its own peer,
  `ERX_BOOT_INFO_PEER`), as `einval`. Reserve the name where names are bound, so the answer
  is `name_taken`, and refuse it in the manifest check.
* [Low] Runtime, `net_adm:ping/1` (edit 28) decides by `erx_dist:select/1` whether
  the carrier is in use; a node of this kernel under another `-proto_dist` answers
  `pang` for an unconnected node at its own host without trying.
* [Medium] Runtime and domain service, `erx_connections.erl` (`close/2`),
  `erx_domain_srv.erl` (`ended/3`): the agent answers `close_side`, and a domain's agent
  answers `connection_unmapped` and `connection_lost` (`records/3`), on the port monitor's
  `DOWN`, which ERTS fires (`erts_deliver_port_exit`, `io.c`) before `terminate_port` calls
  the lane driver's stop, so when the exit ran on another scheduler the domain service's
  `Lib:disconnect` can destroy the connection's objects before `lane_stop` has released the
  answering domain's mappings of them. No driver callback runs in that window. Whether the
  Fiasco backend's destroy also removes the system domain's mapping was not checked; if it
  does not, the pages can be reused while still mapped. Make the unmap the signal: the
  finish (control command 2) or a synchronous close unmaps both sides before it answers.
* [Low] Runtime, `erx_event_table.h`: the system domain binds one connection sink per
  live domain, at most `ERX_EVENT_CONNECTIONS` (64), and nothing ties the manifest's
  `max_domains` to it, so creates past it, or earlier while slots stay unsettled, fail
  with `{system_side, _}`. Bound `max_domains` in the manifest reader, or size the sinks
  from the manifest.
* [Low] Domain library, `liberx/system/dom_core.c` (connection numbers): `next_connection`
  runs to `UINT32_MAX`, but the system domain's bell takes the number as its label, and
  labels at or above `ERX_LABEL_SPLIT` belong to the runtime's half of the event table, so
  the lane driver refuses such an open once the objects are built. Refuse the number in the
  plan with `ERX_ELIMIT`, as a link's label is (`dom_life.c`).
* [Low] Runtime, `erx_dist.erl` (the system connection's owner): a domain's own ordered
  end, `init:stop()`, shuts `net_kernel` down, which takes the system connection's owner
  with it, and the owner halts the domain with status 69 rather than 0. Let the owner
  follow an ordered stop of `net_kernel` quietly, as `erx_connections` does, or have the
  domain's ordered end halt with its own status first.
* [Medium] Runtime, `erx_connections.erl` (`kernel_ended/1`): the agent ends quietly on
  any `shutdown` of `net_kernel`, which is safe only while `net_sup` and `kernel_sup` stay
  `one_for_all` with intensity 0: a local `supervisor:terminate_child` of `net_sup` or
  `net_kernel` with no restart leaves the runtime running with no agent, and in the
  system domain no side reports reach the domain service. Make it hold by construction:
  quiet only when the runtime's ordered end is under way (a mark written on that path),
  halt otherwise. Also tighten `{system_side_ended, Id}`, which any local process can send
  to the service: carry the side's monitor reference, or check the sender is the agent.
* [Low] Lane driver, `-erx lane_batch`: the allowance is
  `ERX_LANE_BATCH_DEFAULT` (64); `erl_init.c` does not parse the flag yet.
* [Medium] Lane driver review residuals, `otp/erts/emulator/sys/erxos/erx_lane_drv.c`
  and `test/guest/native_domain`: (1) one run of the input task is bounded by
  frames, not bytes, so 64 frames of `max_frame` each hold a scheduler for one
  run; bound it by bytes too, or charge reductions per byte. (2) The
  `ERX_FUNNEL_TOO_LARGE`, malformed-record, failed-grow, allowance-reschedule
  and port-stop paths have no QEMU case; the connection cell covers output
  pause and resume, an answer and the answers bound only; no case delivers a
  right-0 frame (`PAYLOAD_EXIT`, `UNLINK_ID`). (3) The step's sequencing
  (plan, grow or take, took, check, the answer gate, deliver, next) lives in
  `input_step`, which does not build for the host, so "DELIVER only with the
  record whole" and the answer gate have no unit test; design-domains.md's
  `erx_funnel_step` is that step as a pure function in `liberx` returning the
  next action, with host tests and a fuzz target, and the driver only carries
  the action out. Until then the asm fuzz target should feed several records
  through one grown buffer and assert no `DELIVER` while `held < frame`; no
  landing-gate host test drives `erx_funnel_asm` either. (4) The party's and
  the driver's frame headers are packed by hand until the generator emits
  `erx_frame_header_encode` (see the `wire_le` item above); until then the
  driver should use `ERX_FRAME_HEADER_OFF_*`, and output relies on the
  header's last byte doubling as the pass-through byte. (5) `answers_unsent` measures `total_qsize -
  qsize`, which also counts this domain's own sends with no process and its
  `async_dist` processes' sends, so a healthy connection can end; and an
  `UNLINK_ID` to a live target is acked later by the target, past the check.
  Count the answers at their source in `erts_net_message`'s `ERX_NET_*` path
  and take the bound from the boot page's `peer_held` (design-domains.md,
  "Flow control"), which deletes `op_answered`; `ERX_LANE_ANSWERS_MAX` stands
  in for it. (6) The connection case can end the port between two of the
  domain's 50 ms polls, and `domain_run` does not stop a domain whose end it
  did not see; `party_flood` does not tell a stall from a refusal. (7) No case
  streams between two domains (the deadlock the busy gate could cause); it
  lands with RT6b's two-domain cell. (8) `erx_funnel_asm_ungrown` and its
  `funnel.h` contract are used only by the fuzz target, and
  `erx_funnel_asm_took` treats a `GROW` plan as a skip rather than refusing
  it. (9) The open command (`lane_open_parse`) takes raw capability slots, a
  label and the peer's node name from any Erlang caller in the domain: open
  by an opaque connection id the runtime recorded from `connection_up` or
  the boot page instead, with the node name from the same record, and map
  the sides where that record is made, so the driver leaves the
  `device-memory-mapping` rule's sites; a table of
  {field, maximum} would also replace the positional `words[7]`. (10)
  `erts_net_message`'s result is ignored, so a frame the funnel accepted and
  ERTS refused does not end the port; output drops a frame with a control
  term of length 0 or past the limit but keeps the connection. Both should
  end the port. (11) The generic `erx_event_unregister` resolves a label below
  `ERX_LABEL_SPLIT` to a connection slot and frees it without aborting its
  tasks; no caller passes one, but it should refuse them. (12) `erx_funnel_asm_t`'s `held` and `hold` differ by a
  letter and mean different things; rename `hold` to `keep`.
  `connection_schedule` finds its handles by pointer arithmetic on the
  global table; keep them in the slot or pass the index. (13) A peer can grow
  a live process's signal queue without limit with right-0 signals
  (`UNLINK_ID`, `DEMONITOR_P`, `PAYLOAD_EXIT`); the queue quota covers only
  undecoded messages, and no design text bounds these.
* [Medium] Funnel authority, design-domains.md "The funnel" step 5: a
  `LINK` without `link` to a live process that holds no link with the
  sender is answered `noproc` by the target process when it handles the
  signal, while one to a process that does not exist is answered at once
  by the distribution input, so the answer's delay can tell a sender which
  guessed pids are alive. The step's timing argument covers only the case
  where a link exists. Such a `LINK` is also never held to the queue
  quota, so a sender can queue them on any live process it can guess. One
  change closes both: the drain answers `noproc` at once unless the target
  holds a link with the sender (a bit of `erx_funnel_hold_t` from the same
  lookup), and only then queues the conditional `LINK` for the target to
  re-judge. The ERTS side has no edit yet either: stock
  `ERTS_SIG_Q_OP_LINK` always inserts, so design-runtime.md's edit table
  needs a LINK signal that creates nothing unless a link (in any state)
  exists and otherwise sends the `noproc` exit, which the lane driver
  (RT6a) uses for `ERX_FUNNEL_DELIVER_IF_LINKED`.
* [Low] Lane layouts, `abi/erx_abi.txt` `erx_lane_hdr.need` and
  `erx_lane_rpage.wake`: the ABI loads them with acquire order, where
  design-domains.md "Publishing is a release" says relaxed; the litmus tests
  model the design's relaxed loads. Make the ABI relaxed, or the design
  acquire with the litmus twins' comments saying so.
* [Low] Lane tests, `test/fixtures/lane_driver.c`: the armed take and the
  producer's publication are each one step of the exploration, and the TSan
  race polls instead of parking, so the handshakes' orderings rest on the
  M5 herd7 litmus tests; add a threaded mode in which both parties park on
  `need` and `wake` under a deadline.
* [Low] stopgap bootstrap, `fiasco/bootstrap/server/src/erx_image.cc` (`erx_boot_args_cut`): a command line over
  `ERX_BOOT_STRINGS_MAX` (2,048 bytes) is cut at its last whole word without a word on the console, where
  docs/design-kernel.md ("Configuration") says the boot reports the cut. Handed a 2,375-byte line naming every stdlib
  suite, the QEMU oracle's guest ran only the suites named in its first 2,048 bytes, and its serial log said nothing. Print the cut, with both lengths, and
  check the line in a boot transcript test.
* [Low] stopgap bootstrap, overlapping RAM regions:
  `Region_list::optimize` (`fiasco/bootstrap/server/src/region.cc`)
  merges a region into its predecessor by setting the predecessor's end to
  the region's end, so a region wholly inside its predecessor shrinks the
  predecessor and drops RAM. Only the EFI memory-map path adds RAM with
  overlaps allowed (`efi-support.cc`, `ram->add(..., true)`), so QEMU
  `virt` booted from a device tree is unaffected. Found by reading, not
  reproduced; fix with a regression test before any EFI boot path is used.
* [Medium] Kernel page funnel, `kernel/core/page.c` and
  `kernel/core/page_impl.h`: a page record holds only its link and stamp,
  so nothing says where a page is. `erx_page_release` checks counts, not
  which pages its in-use chain holds, and `erx_plist_push` cannot see a
  page already on a chain, so a kernel path that releases a page twice or
  another reserve's page corrupts the released list silently. Add the
  design's owner and a place tag to the record, set by every push, pop and
  splice, and refuse a release or push whose pages are not where it says
  with `ERX_EINVAL` before anything changes.
* [Medium] Kernel page funnel, `include/erx/page.h`: `erx_backing_step`
  leaves to each caller the duties of stepping to `ERX_BACKING_DONE` or
  `ERX_BACKING_CANCELLED` (a caller that stops early leaks its hand and an
  admission stays counted) and of reading its existence locks for
  `closed`. Give the stepper one caller, the backing loop that owns the
  preemption points, with a call-graph chokepoint, and the same for
  `erx_released_free` and the reaper's step. The members of `erx_plist_t`
  and `erx_backing_t` are public in the header with no rule keeping other
  files out of them; add one with P6's cross-cutting chokepoints.
* [Low] docs/design-kernel.md, **Backing a charge**: `erx_kalloc`'s
  dead-budget path releases a cache page "under the budget's lock", while
  **The record cache** in [Budgets](docs/design-kernel.md#budgets) has the
  free hand the page out and its caller release it through the page
  funnel after dropping the budget's lock, since `erx_page_release`
  takes the owner's lock and the refund the budget's chain. Reword the
  `erx_kalloc` passage to match.
* [Low] Page funnel tests, `test/host/page_test.rb` and
  `tools/fuzz/page_fuzz.c`: the drivers cannot see a reserve's pool chain,
  so they count pooled pages by exclusion and never walk the chain; and
  neither drives a take or release of a reserve while its own backing is
  under way, or a release the reserve cannot cover (refused before the
  core in the fuzz target). `erx_page_release` repeats
  `erx_reserve_refund`'s count checks so that the refund cannot fail after
  the append; one predicate exported by the budget core would keep them
  one.
* [Medium] Kernel budget core, `kernel/core/budget.c` and
  `kernel/core/budget_impl.h`: the record carries its own `parent`
  pointer and takes its lock through `erx_effect_budget_lock`, standing
  in for the object header's budget field and the core's ticket lock
  (`erx_spinlock_t`), and the reserve record holds the pool's count
  beside the chain that `kernel/core/page.c` moves, so
  the two agree because only `page.c` calls the steps (its call-graph
  chokepoints) and checks them in host and debug builds. When the object
  header and the ticket lock land, embed them in the records, drop the
  lock effect, and give `erx_reserve_fill`, `erx_reserve_use` and
  `erx_reserve_refund` the chain itself, so the pooled count is the
  chain's length by construction. A record embeds the header in its
  header area (`ERX_OBJECT_HEADER_BYTES`, `erx_object_body`), as the
  child budget's record in its parent's cache already does; the budget's
  own `parent` then becomes its header's `budget`.
* [Medium] Kernel deletion core, `kernel/core/delete.c`: a budget's own
  object finishes its destroy (its put handed out) before the
  budget-death walk empties its `att_charged`, so for a budget the put
  does not wait for every attachment field as the teardown contract
  says; the record is freed only at its object's last put, after the
  walk's reference and the one its counters hold until the tombstone's
  put, so nothing is freed early. Making the walk the teardown's last part for `ERX_K_BUDGET`, a
  part `erx_delete_step` hands out, would make the order hold by
  construction. The carve's caller puts the child's header on the
  parent's list in a second hold of the parent's lock, so a parent
  destroyed in between leaves the caller to close the child; passing the
  object store to `erx_budget_carve` would put both in one hold. The
  deletion model (`test/fixtures/delete_model.c`) does not yet walk a
  child budget or a space's tables.
* [Medium] Kernel cores, `att_charged` (`kernel/core/delete.c`,
  `kernel/core/attach.c`, `kernel/core/budget.c`): three caller duties
  have no check yet. A destroy's runner must call `erx_delete_uncharge`
  at the drain (recording it in the `erx_delete_t` and trapping in
  `erx_delete_step` when the destroy leaves CLOSED without it would make
  a forgotten unlink loud); a record on a list must never be freed
  outside a destroy (the record-free funnel should trap on a member); and
  the carve's caller must take the reference the child's counters hold.
  `erx_kcache_take` has no caller now that the carve takes its own
  record: delete it, or refuse `ERX_KCACHE_BUDGET`, until a second record
  kind exists. Tests: the deletion model's publication actors P and U
  move only model state (no core runs, and `DU` shows the same
  violation as the seed `KU`); a second object charged to B, attached by
  an actor racing K through `erx_attach_budget_charged`, would make the
  seed exercise the insert's dead check. No test pins the walk's take
  (its unlink or its counted reference) by a named diagnosis, nor the
  driver's `put` between walk steps. `erx_object_init` accepts a NULL
  budget, which `erx_delete_uncharge` dereferences; the design text names
  `erx_dlink_t`/`erx_dlist_t` where the code has `erx_charged_list_t`.
* [Medium] Kernel mapping-record core, `kernel/core/map.c`: `erx_map_apply`
  takes no proof that the caller charged a part's `charge_pages`, and
  `erx_map_edges` no proof that it runs after the apply, though it reads the
  records as they stand. A caller that gets either order wrong makes a
  read-write record with no pages behind it, or keeps a table past its
  promise. The reserve plans of `erx_vm_plan` should take both into the one
  plan, so no caller orders them.
* [Medium] Kernel space creation, `docs/design-kernel.md` ("Virtual memory"):
  the placement base has no stated range. The design needs its window (the top
  part of the user half, below fixed-address images and `liberx`'s fixed
  placements, with a build check that they do not meet), its alignment and
  entropy, its deterministic-mode value, and that kernel-user pages and the
  random base of a position-independent image draw from the same window.
* [Medium] Kernel private memory objects, callers of `erx_map_plan_insert` and
  `erx_map_plan_part`: `include/erx/map.h` names `erx_vm_commit`, `erx_image_map`
  and `erx_space_copy` as the only makers of a space's private objects, which
  the core cannot check since it never dereferences a handle. When they land: a
  chokepoint rule holds those three sites; a trim takes its object through the
  kind-checking accessor, so a shared object fails loudly; a writable image
  segment keeps its source on the object as slice, slice offset and first page;
  and the private page tree splits by offset range, so a part's trim goes to the
  reaper as one subtree.
* [Medium] Kernel range calls, callers of `erx_map_plan_part` and
  `erx_map_mark_deleted`: a protect's part and a deletion clear translations in
  place, and must do so through the table step of the edge rule, one table
  between preemption points, since the core's part spans a whole record. A
  deletion's table step is what the core's `ERX_MAP_DELETED` record assumes.
* [Critical] Kernel memory design, `docs/design-kernel.md` ("Virtual
  memory"): the map core's design review (branch
  `worktree-agent-a613090776683a3d8`, commits `8f893069` and `58d89236`,
  not landed) left three findings open for Phase 2's memory design.
  (Critical) A release's private pages leave the page tree after the
  range is reusable, so a racing commit can map a page that the release
  then frees. (High) The step machine plans outside the lock and has no
  result for a stale plan. (High) The deletion walk's lookup of a
  record's space is not designed. The reviewing agent recommends that a
  fragment inherit its origin's attachment, which removes most of the
  mechanism of the core's third item, and that the boot-image slice's
  rights become (MAP, READ); both still need checking.
* [Low] Kernel mapping-record core, `kernel/core/map.c`: `erx_map_check` judges
  a node's summary with the core's own `map_update`, so a bug in that function
  shows only through the behaviour tests, not the check; and `MapModel` shares
  the core's choice of which record a split reuses. Compute the summary a second
  way in the check.
* [Medium] Kernel space core, `kernel/core/space.c`: the core keeps a
  space's place in the tree and its run state, and decides creations
  and the steps of the stop and deletion walks; what the design puts
  beside it in `erx_space_t` is the integration's (WP16, WP25, WP39).
  Each space's count of children whose exit records are not posted
  belongs in `erx_space_attach`, the one place a child joins, and its
  decrement beside the exit record's posting. A deletion's first
  critical section must also invalidate the space's existence lock and
  set the table's emptied flag
  (`erx_cap_table_set_emptied`): the core unlinks the space under the
  parent's lock and returns `ERX_DELETE_SPACE`, so the caller takes the
  table's lock inside the parent's, which the lock order allows (a
  space's lock at 3, a table's at 4), and sets the flag before dropping
  either. It then empties the table through `erx_cap_slot_clear`, and
  runs the destroy of any space whose last capability a clear removed
  only after the table's lock is dropped, since that destroy takes a
  space's lock. The walks' counted
  references (each walk's root and held space), `erx_space_record_init` after
  the allocation, the reaper's two free steps (`erx_space_free_ready`,
  which runs exactly once, and `erx_space_unhold_parent`:
  the object core should trap a second, and a counted reference rising from
  zero, in debug and host builds), the threads' kill
  list (`test/fixtures/space_driver.c` stands in for all of these) and
  `erx_space_stop`'s refusal of the kernel's exit statuses are the call
  layer's. The values of `ERX_EXIT_PARENT`,
  `ERX_EXIT_RELEASED` and `ERX_EXIT_NOTHREAD` (`abi/erx_abi.txt`,
  INT64_MIN + 1 to + 3) were chosen here, where the design names them
  without values; confirm them before a runtime relies on them.
* [Medium] Kernel space core, `kernel/core/space.c`: K27 asks that every
  stop of a space be made by, or start, one of the two walks, but
  `erx_space_stop` stops one space and leaves starting the walk to each
  caller (the stop call, the last thread's exit, `ERX_EXIT_NOTHREAD`,
  the destroy). Fold the root's stop into `erx_stop_walk_begin(walk,
  root, status, stopper)`, reporting whether it stopped the root, and
  drop the single-space stop, so every stop has its walk by
  construction. Likewise the threads' order (new threads at the front,
  killed ones at the end) is the caller's, and `erx_stop_step` trusts
  the caller's report of the first thread; move the thread list into the
  core with WP25.
* [Medium] Kernel space integration (WP25, WP39), `include/erx/space.h`:
  the core decides the walks and the exit word, and the space destroy is
  the integration's. Split it into one space's own teardown (drain, empty
  its table, detach its mapping records, withdraw its exit record, queue its
  put), which `ERX_DELETE_SPACE` runs for each space and which starts no walk
  and reads no close result, and the destroy (close, drain, stop, stop walk,
  `erx_delete_walk_begin` and the step loop; a close that says `ERX_ESTALE`
  or a begin that says DONE stops there, queuing no put). Add a chokepoint:
  that one function is referenced only from the `ERX_DELETE_SPACE` handler,
  with a test seeding a second caller. The queue of exit records and the
  gate's `exits_dropped` are stand-ins in `test/fixtures/space_driver.c`
  until the integration exists, and `erx_space_clear_caps` has no host test,
  so K27's domain tests are what prove them: the fixture has one queue, so
  it cannot show a record moved between receivers. The word's orders are
  explored single-threaded; add a race when the post has its real path.
* [Medium] Kernel exit records, `docs/design-kernel.md` ("A deletion takes the
  record with it"): the withdrawal needs a place for each record, one ordering
  lock and a word, because the record lives in the space it reports. Weigh
  keeping a posted record in a small fixed record charged to the creator: it
  pins no space, so the withdrawal, the word and the count go, the creator
  learns of every end, and only a party that refuses to receive pays.
* [Medium] Kernel space lifetime, `docs/design-kernel.md` ("Who owns a
  deletion"): a deletion below a space rests on the thread of the call that
  unlinked it, and that thread's group may be unscheduled, leaving the spaces
  below stopped but undeleted and their capabilities answering, one chain
  per stalled call (Security states it). Decision needed before the security
  closure milestone: run the rest of a begun deletion at the finishing level;
  or keep a space listed until its parts end, so a second walker shares them
  and descends, as stop walks do (recommended, since it removes the
  dependence on another's thread); or keep the stated limit.
* [Medium] Kernel objects, `docs/design-kernel.md` ("Closing and deleting"):
  a deleted IRQ object leaves one last delivery at its target, and a posted
  delivery holds a counted reference on its object until it is taken, so a
  target that never receives keeps the IRQ object's record, on whatever
  budget paid for it. Decide it as a space's exit record is decided
  (withdraw and count at the target) or state the bound in Security.
* [Low] Program end, `docs/design-runtime.md` and `docs/design-programs.md`
  ("A program's end"): the runtime has the handler destroy the anchor, and
  the programs design has it destroy the program's budget. Both delete the
  tree; one should be the stated step.
* [Low] Kernel space status, `abi/erx_abi.txt`: `ERX_EXIT_RELEASED` is seldom
  received, since a destroy withdraws or drops the record of a space it
  stops. Decide whether it still earns its place in the status set.
* [Low] Space core tests, `test/fixtures/space_model.rb`: the model cannot
  represent a table emptied by `erx_space_clear_caps` before its space's
  deletion, since it holds `emptied` equal to deleting; add a `clear` command
  when the call exists.
* [Medium] Space core tests, `test/host/space_test.rb`: the
  acquire/release claims on a space's run word and the publication of
  the first stop's status and stopper are exercised single-threaded
  only; add a ThreadSanitizer race of stops, walks and `erx_space_read`
  and list it in `tools/erx check-sanitizers`. The state assertions match
  regular expressions over the driver's positional state line, and the
  refusal table spells raw `plan` commands; parse the line into named
  fields and give the refusals a keyword helper. Untested: a
  `parent_self` request naming another record, `erx_space_init_first`'s
  refusals, `erx_space_attach` with object 0, and the ancestry check
  ahead of the depth limit (no case has a parent outside the tree at the
  deepest level).
* [Medium] Space core tests, `test/host/space_test.rb`
  (`test_the_drops_of_a_hold_race_under_thread_sanitizer`): the mutant
  with the drop's `memory_order_acq_rel` relaxed, built from
  `test/fixtures/space_holds_race.c` under ThreadSanitizer, printed
  nothing and hit its 300 s deadline in two runs on an Apple Silicon host
  under a load average of 13 to 20, while the unmutated program finished
  in about 2 s; the test then fails with an empty log and fails
  `make check`. Find why the relaxed program hangs instead of reporting
  the race, and make it end with the report.
* [Medium] Kernel invalidation planner, `kernel/core/tlb_plan.c`: a
  cleared table entry carries its span in bytes, and the planner accepts
  any aligned power of two of at least two pages, so a range call that
  reports a level-2 table entry with too small a span gets a valid plan
  that leaves walk-cache copies in the rest of the span (K9). When the
  range call's plan is written, have each entry carry its table depth and
  the removal the table geometry, so the planner derives the span, and use
  the page-number and IOVA types of the data model instead of bare
  `uint64_t` bytes; let the removal also carry the target's ASID width and
  address limit, since an IOMMU's may differ from the CPU's.
* [Medium] Kernel invalidation planner, `include/erx/tlb_plan.h`:
  `erx_tlb_plan_t` is 1544 bytes, a fifth of an 8 KiB kernel stack. Keep
  it in the range call's plan storage rather than on the stack, or shrink
  `erx_tlb_inval_t` to 16 bytes (page number, log2 page count, reach).
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`: the
  sequence-counted accessor rule does not exist yet and is not in the
  registry. It reads the syntax trees as the `Chokepoints::Writers`
  rules do (`tools/lib/erx/syntax_tree.rb`), counting reads as well as
  writes, for every record the ABI file declares sequence-counted.
* [Medium] Kernel chokepoints, the syntax-tree rules
  (`tools/lib/erx/syntax_tree.rb`): they read only the cores
  `CoreArchive` compiles, in the archive's configuration, so the glue's
  C++ (a `reinterpret_cast` of an `erx_budget_t *` there), liberx and
  code under another configuration's `#ifdef` are not read. A guarded
  member's uses are a closed set (a load, an atomic load's pointer,
  sizeof, a cast to void; any other use is a write), but a record
  pointer's are not: a pointer passed through `...` or a union of
  pointers, a declaration that disagrees with its definition in another
  file, and an embedded record zero-filled by its container's
  initializer still pass. Closing them means inverting the pointer's
  uses too: outside the sites, allow a record pointer only as the base of
  `->`, a parameter, variable or return value of the same record pointer
  type, and an operand of a comparison, and count everything else as a
  write.
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`: the
  text rules match whole names, so a name a macro pastes together
  (`erx_cap_slot_ ## clear`, `erx_ ## cap_slot`) gets past
  `cap-slot-clear-named`, `budget-records-private`, `cap-table-private`
  and `cap-slot-private`. The syntax-tree rules (`budget-counters`,
  `cap-table-writers`, `cap-slot-writers`, `object-state-writers`,
  `rights-built-in-cap`) see through macros and refuse a cast of a
  pointer to a guarded record outside its writers, so no pasted name or
  hand-copied offset writes one; a pasted call of `erx_cap_slot_clear`
  from outside the cores, or a pasted definition of a private record,
  still passes. Localize every symbol of `erx_cores.a` not on its API
  list. The design: the API list is what the seam headers
  (`include/erx/core/*.h` and their generated twins) declare, read from
  the syntax tree of a source that includes them all, so a new seam
  declaration needs no entry; `CoreArchive.build` links the members
  into one object with `ld.lld -r`, keeps only that list global with
  `llvm-objcopy --keep-global-symbols`, and archives the one object,
  while the stack proof keeps reading the members. It needs `ld.lld`
  passed to the core build (it is not beside clang), and the Fiasco
  build audit (`FiascoProvenance#audit_executable`) to accept a member
  whose construction record is the members' compiles, so it lands with
  a Fiasco build that proves the link. Have the object leg also read the
  cores' debug information (a `-g` compile with `-fdebug-prefix-map`,
  so the archive stays reproducible), so no object but its core's
  defines a private record. The text rules also miss an include through
  a macro in inherited Fiasco, which `include-form` does not read, and a
  `-include` flag in a build file. Nor does any rule stop a caller that
  keeps its own untyped pointer to a table, its directory or a page it
  handed to the core from writing their bytes; the space core should
  allocate them from memory nothing else maps.
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`:
  `cap-slot-clear-callers` reads only the cores' call graph, so
  `cap-slot-clear-named` keeps `erx_cap_slot_clear` out of the Fiasco glue
  altogether. When the glue (WP12) gives the close and the space's
  emptying their callers, extend the caller check to the glue's objects
  and add the deletion walk's slot-clearing effect by name.
* [Medium] Object store, `kernel/core/object.c`: `erx_object_init` writes
  the state word and the counts of any record it is given, so a call on a
  published record would move it back to LIVE; add a `Callers` rule that
  only the allocation funnel calls it once that funnel exists, and a
  syntax-tree rule that within `object.c` only `erx_object_init`,
  `erx_object_cap_remove` and `erx_object_close` write `state`.
* [Medium] Object store, `kernel/core/object.c`: no test runs two threads,
  so the memory orders of `erx_object_put`, `erx_object_close` and the id
  counter are unchecked. Add a pthread host test under TSan and ASan:
  refs and puts racing a final put that frees the record, a close racing
  the last `erx_object_cap_remove` (one close returns true, the state ends
  DELETED), and concurrent creations on one store (distinct ids).
* [Medium] Security residual, object ids (`kernel/core/object.c`,
  `oid_round`): the Feistel round function is murmur3's finalizer keyed
  by one XOR, not a keyed PRF, so the claim that ids say nothing about how
  many objects anyone created rests on obscurity; the design names no
  round function or threat model. Choose a keyed PRF round (SipHash-1-3
  or HalfSipHash) and state the threat model in design-kernel.md.
* [Low] Object store, `kernel/core/object.c`: the reserved object id
  (zero) is hand-written in `oid_reserved`; declare the reserved encodings
  in `abi/erx_abi.txt` and generate the set. `ERX_KERNEL_DEBUG`, which
  turns on the epoch check in a target build, is defined by no build yet.
* [Medium] Capability core, `kernel/core/cap.c`: the table's owner hands
  `erx_cap_table_add_page` each page's storage, so the core can refuse a
  page that overlaps its own table, directory or pages, but not one that
  another table already holds, and the check scans the whole directory
  under the table's lock on every page added. Have the core take its
  directory and pages itself through the budget-charging allocation
  effect, so no caller supplies a page pointer and both the scan and the
  aliasing go away
  ([design-kernel.md](docs/design-kernel.md#objects-and-capabilities)).
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoint_rules/`: two
  mechanisms keep a core's records private. Each private ABI layout's
  rule is built from the ABI file, while `budget-records-private`,
  `cap-table-private` and the core-to-header sites of
  `core-records-private` are written by hand for the hand-written
  `kernel/core/STEM_impl.h` headers. Build all of them with one helper
  from one table, the private layouts plus every `kernel/core/STEM_impl.h`
  owned by `kernel/core/STEM.c`. While at it, have the model expose a
  private layout's stem and refuse a private layout whose generated
  header shares its base name with a hand-written one (`erx_cap_table`,
  `erx_budget`), and narrow `host_tests`, whose `test/fixtures/STEM_*.c`
  also admits the drivers of a later `kernel/core/STEM_x.c`, with a check
  that no build input lies under `test/` or `tools/fuzz/`.
* [Medium] Kernel chokepoints, the pending syntax-tree leg: no `Pending`
  rule awaits the syntax-tree reader for the capability records, so
  nothing fails when it lands without them. Declare one that refuses,
  from syntax trees, a definition of `struct erx_cap_slot` or
  `struct erx_cap_table` outside their headers however its tag is
  spelled, a member access through either type outside
  `kernel/core/cap.c` and its host tests, and a cast from either
  pointer type there
  ([design-kernel.md](docs/design-kernel.md#chokepoint-checks)).
* [Medium] Capability core, `include/erx/cap.h`: a pass's route is a closed
  enum the plan records with both tables, but the caller still states it,
  so a rendezvous that passes `ERX_PASS_OWN_TO_CREATED` by mistake plans
  under the creator's rule. Derive it by construction: a rendezvous entry
  point that takes no route, and `erx_cap_pass` deriving the route from the
  tables' owning spaces, which needs an owner word in the table.
* [Medium] Capability core, `kernel/core/cap.c`: `erx_cap_install_copy`
  shrinks a fork's copy by a mask its caller passes, so K24 for
  `erx_space_copy` rests on that caller passing the type's pass set; and
  `erx_cap_install_kind` accepts any creation kind of the object's type,
  so a budget installs as a root or a carved budget at the caller's
  choice. Record the creation kind in the object's header at
  `erx_object_init` and install from it, and give the copy a purpose (dup
  or fork) that applies the pass set inside the core; decide whether a
  fork skips a type with no pass set.
* [Medium] Capability core, `kernel/core/cap.c` and design-kernel.md's
  chokepoint rows: the design says only `kernel/core/attach.c`'s insert
  functions link onto an object, but the slot list's insert is cap.c's
  `cap_list_insert`, and a pass counts at its take and links at its
  install, correct only while its caller holds every object's capability
  lock from planning to install, which nothing checks. Reconcile the row
  with P3's attach core and assert the lock in debug builds.
* [Low] Capability core, `kernel/core/cap.c`: a taken plan that is never
  installed keeps its counts, so its objects are never released; nothing
  but the caller's sequence enforces the install. Assert it in host and
  debug builds with the other pass preconditions. No concurrent test
  races `erx_cap_install_copy`'s lockless source read against a writer of
  the source table.
* [Medium] Capability core, `kernel/core/cap.c`, for the deletion core: a
  teardown walks its object's slot list and must clear each slot through
  `erx_cap_slot_clear`, which takes the slot's table and value; a listed
  slot holds its table and generation but not its index, and its 64 bytes
  have no room for one, so the index is found by scanning the table's
  directory. Decide between that scan, a clear by slot address that stays
  the one clearing function, and pages that record their first index.
* [Medium] Capability core, `kernel/core/cap.c`: a pass is read sources,
  plan, take, install and release the reservation, and growth is
  `erx_cap_table_pages_needed`, allocate and `erx_cap_table_add_page`,
  each a sequence the caller strings together (the plan's stage already
  makes take and install run once each, in order). When the Fiasco glue
  (WP12) gives them their callers, give each operation one effect-edge
  function around the pure plan so no caller can reorder or skip a step.
* [Medium] Kernel chokepoints, `tools/lib/erx/chokepoints.rb`: a `Callers`
  rule counts only direct calls and tail jumps, not every relocation that
  names its callee, so a core that takes the address of
  `erx_cap_slot_clear` goes unseen (outside the cores
  `cap-slot-clear-named` refuses any mention). Count every reference and
  test an address-taken one.
* [Low] Capability core, `kernel/core/cap.c`: `erx_pass_take` and
  `erx_pass_install` return `ERX_EINVAL` for a plan or reservation that
  breaks their preconditions (a kernel bug, never a domain's input); make
  that an assertion in host and debug builds as well.


* [High] storage and platforms, the Pi 4's boot image: the Pi 4's secure
  boot checks `boot.img` at about 2.6 MB/s under a firmware watchdog fixed
  at 4 s, and the boot image holds the kernel, the runtime image and the
  whole system release, tens of megabytes with ERTS, so the check alone
  outruns the watchdog. Decide what the signed boot image holds: the
  kernel, `liberx` and a root image that mounts the release's EROFS image
  from the slot under its hash tree, with the slot image's root hash in
  the signed part, or a boot image sized to the firmware's checking rate
  measured by the boot probe; restate "the boot image stays small" and
  "the boot image holds the release" so one of them goes
  ([design-storage.md](docs/design-storage.md#data-model),
  [design-platforms.md](docs/design-platforms.md#trust-in-the-boot)).
* [High] runtime, references on the Raspberry Pi 4: every reference is an
  AES-128 permutation over an image key, and the Pi 4's Cortex-A72 has no
  cryptography extension, so every `make_ref/0`, alias and
  `gen_server:call` pays a bit-sliced AES block where stock pays tens of
  nanoseconds, on the hottest path of the first board, against the 1.2x
  local budget. Decide the fallback: a cheaper permutation for references
  that stay inside their domain, with the full AES-128 applied only where
  a reference crosses a connection, or a cheaper keyed permutation
  everywhere with its unguessability argument restated; measure both with
  `tools/erx bench erts-local` on the Pi 4 at G12. Confirm the A72's
  feature set from Arm's documentation and from the ID registers read at
  the boot probe, since the present evidence is a forum thread
  ([design-runtime.md](docs/design-runtime.md#unguessable-references),
  [design-platforms.md](docs/design-platforms.md)).
* [Medium] runtime, the reference permutation's hardware path:
  `erx_ref_permute` (`otp/erts/emulator/sys/erxos/erx_ref.c`) is ctaes's
  portable AES-128 alone. Write the hardware path the design names (the
  Arm cryptography extension's AES instructions where the CPU has them),
  settle how a user-mode runtime learns that the CPU has them, test it
  against the portable path over `test/host/erx_ref_test.rb`'s vectors,
  and record both paths with `tools/erx bench erts-local`
  ([design-runtime.md](docs/design-runtime.md#unguessable-references)).
* [Medium] runtime and live, standard I/O across domains: every other
  domain's standard I/O goes through Erlang's I/O protocol to a group
  leader in the system domain, whose requests carry the writing domain's
  atoms, which D5 refuses. State which requests cross, with their text
  rendered to binaries in the writing domain, as trace records are
  rendered in the traced domain
  ([design-runtime.md](docs/design-runtime.md#the-console-and-standard-io),
  [design-live.md](docs/design-live.md#tracing)).
* [Medium] scheduler, the pick core is configuration C0's
  (`kernel/sched/sched.c`, `erx_sched_pick`): it has no finishing level,
  no throttled lists and no published urgency yet, which the design's
  Pick and dispatch names and erXos's own kernel needs. The stopgap keeps
  Fiasco's ready queue until it leaves, so nothing on the target calls
  `erx_sched_wake`, `erx_sched_remove` or `erx_sched_pick` before Track K's
  kernel does. The pick also has no way to give back a thread whose switch is
  refused because a helper runs it, which the design's finishing level asks for.
* [Medium] scheduler, who refreshes (`include/erx/sched.h`,
  `erx_sched_group_configure`): S5 rests on every caller that changes a base
  or a ceiling walking the threads below it. Have the configure report what
  changed, or the core own the walk's plan, when the first caller lands.
* [High] scheduler, Track K, the cross-CPU protocol has no model and no code
  ([Concurrency](docs/design-scheduler.md#concurrency), `include/erx/sched.h`).
  It does not block M1: the stopgap keeps Fiasco's dispatch, and nothing on
  the target calls the core's pick. The first deliverable is the model the
  design's Verification names, with the stack switch as separate steps; no
  code calls `erx_sched_pick` across CPUs before it passes. Then transcribe
  Fiasco's `Pending_rqq::handle_requests`, `Context::drq`, `migrate_away`,
  `migrate_to`, `kernel_context_drq` and the kill's request wait into C17
  against it.
* [Medium] scheduler, `erx_sched_thread_init` and `erx_sched_root_init` on a
  live record (`kernel/sched/sched.c`): a second call re-parents a thread,
  changing the group it is charged to (S6), or clears a group's parent,
  removing every ancestor's limit (S5). Add a build check that thread
  creation alone calls the one and kernel boot alone the other, with the
  work that adds those callers.
* [Low] scheduler tests, the model follows the core's order of operations
  (`test/fixtures/sched_model.rb`): it shares no code, but one misreading
  of Pick and dispatch could pass in both; only the literal-value tests of
  `test/host/sched_test.rb` stand apart from it. "Resolved once per pick"
  has no test, since no single-threaded script can observe it. Add the
  decision traces the parity test of
  [design-scheduler.md](docs/design-scheduler.md#verification-and-testing)
  names, when the stopgap can produce them.
* [Medium] scheduler, S4: a deferred preemption lets an executor run
  `grace_us` past exhaustion as debt, so a period can reach the quota plus
  one quantum plus the grace per CPU, where S4 promises one quantum.
  Post the yield request a grace before exhaustion, or restate S4 with the
  grace ([design-scheduler.md](docs/design-scheduler.md#invariants)).
* [Medium] kernel and scheduler, wake fan-out: one trigger of a
  device's IRQ object bound to a group may wake every parked executor of
  the group, up to 64 threads, outside K13's bound on a stretch with
  interrupts masked. Bound the fan-out of one trigger, or wake one executor
  per trigger and let the runtime wake the rest
  ([design-kernel.md](docs/design-kernel.md#invariants),
  [design-scheduler.md](docs/design-scheduler.md#park-and-wake)).
* [Medium] system, devices: a bus abort or a fault inside the device NIF
  ends the whole domain that holds the device, the devices domain with
  every slow device on it. Decide whether the NIF's register access runs
  in a per-device sub-space shim, so an abort ends one device's shim, or
  whether the per-device-domain rule extends to devices that can abort
  ([design-system.md](docs/design-system.md#drivers),
  [design-runtime.md](docs/design-runtime.md#the-device-nif)).
* [Medium] storage, the default configuration: the block driver and the
  data partition's file system share the storage domain, so a storage
  domain's restart drops every window on the medium and a logic bug in the
  file system runs beside the device NIF. Decide whether the release
  configuration gives the block device a domain of its own, and measure
  the extra connection's cost with `tools/erx bench blk`
  ([design-storage.md](docs/design-storage.md#risks-and-open-questions)).
* [Medium] storage and platforms, the boot-selection record: the slot
  writer sees the record as one sector, while the Pi firmware reads it
  through FAT metadata in the same partition, so a damaged directory entry
  leaves erXos seeing a valid record while the firmware boots its default
  forever. Have the slot writer verify the record through the FAT
  structures the firmware walks, and test a damaged entry on the board
  ([design-storage.md](docs/design-storage.md#system-updates),
  [design-platforms.md](docs/design-platforms.md#slots-and-the-boot-selection-record)).
* [Medium] arch-aarch64, boot: the Pi firmware may ignore `image_size` and
  place the initial RAM disk right after the kernel file, and the entry
  zeroes `.bss`. Check at entry that the boot image and the device tree do
  not overlap the kernel image, instead of relying on a one-time probe
  ([design-arch-aarch64.md](docs/design-arch-aarch64.md)).
* [Medium] live, host-link handles: the handles of the host link's calls
  on facets (console, code, inspect, trace, install, update and domain),
  `{'$host_cap', N}`, `{'$pid', Text}` and `{'$ref', Text}`, are tuples
  inside term payloads, so a domain's agent can emit a literal one that
  the host tool cannot tell from a facet. Carry them out of band, as
  kernel capabilities pass as typed items. File access over 9P carries no
  such handle, its handles being 9P's fids
  ([design-live.md](docs/design-live.md#the-host-link)).
* [Medium] live, host-link payload check (`erlang/apps/erx_hostlink/src/erx_hostlink_payload.erl`):
  until `liberx`'s `erx_etf` (`liberx/erx_etf.c`) is reachable from the
  system domain's Erlang, a control payload from the host
  is checked by a size bound, `binary_to_term/2` in safe mode and a walk
  that refuses pids, references, ports and funs, not by the host grammar,
  and it is decoded onto the heap before the resident limit sees its
  size: a 16 MiB payload of empty lists builds about 256 MiB. Replace
  `erx_hostlink_payload:measure/1` with `erx_etf`'s check with the host
  grammar, which gives the decoded size before decoding; until then the
  effect layer may run the check in a process whose `max_heap_size` is the
  room left ([design-live.md](docs/design-live.md#the-host-link)).
* [Medium] live, host-link resident bound
  (`erlang/apps/erx_hostlink/src/erx_hostlink_session.erl`): the design's
  "The host link" says the credit, the call window and the resident limit
  together bound what a host can make the target hold, but a hello forgets
  the replaced session's executing calls and a cast holds no reservation
  once handed on, so a host that fills the window, sends a new hello and
  repeats holds up to 32 MiB more each round. Count a replaced session's
  outstanding calls, matched by their serial, against the next session's
  room until their `call_done` arrives, and give a cast a reservation
  until its handler has taken it.
* [Medium] live, host-link session (`erlang/apps/erx_hostlink/src/erx_hostlink_session.erl`):
  choices the design leaves open, to settle in design-live.md's "The host
  link":
  * Funs and ports in a reply are rendered `{'$fun', Text}` and
    `{'$port', Text}` beside the design's `'$pid'` and `'$ref'`, and a reply
    that fails the host grammar or the message limit becomes
    `{error, system_limit}`; `message_max` bounds both directions, so a
    release build's 8 KiB limit also bounds replies.
  * The root (`erlang/apps/erx_hostlink/src/erx_hostlink.erl`) answers
    `{open, Name}` for a facet the design lists whose service does not
    exist yet with `{error, unsupported}`, and any other request, an
    unlisted name included, with `{error, badarg}`.
* [Medium] security, host-link session identifiers
  (`erlang/apps/erx_hostlink/src/erx_hostlink.erl`, `entropy/0`): no Erlang
  entry reaches `erx_entropy_read`, so a session identifier is `rand:bytes/1`
  under the seed `rand` takes from the time and the node, which the design
  accepts only in trusted development modes. Draw it from
  `erx_bytes:entropy/1`
  ([design-runtime.md](docs/design-runtime.md#per-byte-primitives)) once
  that call is written.
* [Medium] live, host-link sink check: "only the host link's own sink
  writes its UART" holds because erx_hostlink alone asks for the `hostlink`
  device record and owns its erx_pl011, but no build check refuses another
  module that names that record, and erx_pl011 writes whatever any process
  sends it as `{erx_console_output, From, Bytes}`, so the rule rests on no
  other process learning the driver's pid. Have the driver take output only
  from its owner (an alias the owner holds, since `From` is the console's
  reply token), which makes the rule hold for both lines by construction,
  and add the record check beside `DevicePosters`.
* [Medium] live, host-link facets in a release build
  (`erlang/apps/erx_hostlink/src/erx_hostlink.erl`, `root/2`): the root offers
  the install facet and takes 16 MiB messages whatever the build, where
  design-live.md gives a release build's host only the facets its manifest
  lists, by default none, and an 8 KiB message limit. Take both from the
  manifest (its `development` flag or a facet list) once the system domain
  can read it.
* [Medium] live, `tools/erx watch` (`tools/lib/erx/code_watch.rb`,
  `tools/lib/erx/code_commands.rb`): after the guest reboots, its installs are
  gone (design-live.md, "The code store": "the host installs again"), but the
  watch sends only sources that change from then on. Remember what the watch
  loaded and send it all again when a hello finds a new boot (the build's
  session history or a boot counter in the hello would tell). Also: a module
  whose bytes did not change is loaded again, and a second such load purges,
  ending processes still in its old code; skip a module whose hash equals the
  last one loaded.
* [Low] live, `tools/erx load` (`tools/lib/erx/code_load.rb`): the store may
  free a blob that `missing` reported as held, to make room for a later blob
  of the same batch (erx_code_store.erl), and the load then answers
  `{error, {missing, Hashes}}`; send the named blobs, when all are of the
  batch, and load again once.
* [Low] live, `tools/erx load` and `watch`: they reach only QEMU's UNIX
  socket (`--socket`); a board's serial line needs a raw-mode tty opener.
* [Low] live, host-link client (`tools/lib/erx/hostlink_client.rb`): it has no
  host tests of its own, only the production image's host link boot; drive it
  against `erx_hostlink_session` on stock OTP or a scripted IO (credit, hello
  repeats, stale grants). It keeps replies to calls nobody awaits without a
  bound, and a payload it refuses loses the rest of that read's frames.
* [Low] live, host link (`erlang/apps/erx_hostlink/src/erx_hostlink.erl`): the
  terminal stream's bodies are dropped uncounted until a console session
  consumes them, so the inspector cannot see the loss.
* [Low] live, host link's 9P bridge (`erlang/apps/erx_hostlink/src/erx_hostlink_9p.erl`):
  its counts (discarded, stray replies) reach no inspector record yet; and
  `tools/erx files` serves one client at a time and reaches only QEMU's UNIX
  socket, like `load` and `watch`.
* [Low] live, host link's files stream (`erlang/apps/erx_hostlink/src/erx_hostlink_files.erl`): a
  `files_trees` configuration that is not a list of atoms is refused at each session's bridge start, one
  crash report per session, and the host's 9P client hears nothing until its deadline; check it once when
  `erx_hostlink` starts and refuse to start, as a bad build word does.
* [Low] live, 9P client (`tools/lib/erx/ninep_client.rb`, `version`): an agreed msize has no lower bound, so
  below 24 `read_file`'s read size reaches zero or goes negative and packs as a 4 GiB count; refuse an agreed
  msize below 4096, as the bridge refuses one offered. `max_bytes` is not validated either.
* [Low] live, `erx:trace/1` (`erlang/apps/erx/src/erx_trace.erl`, `await_start/3`): `{error, {failed, Why}}`
  returns the trace process's raw exit reason, which the shell prints with printable Unicode unescaped and
  keeps in its history, a fault's reason with the trace's buffers included; return a bounded, escaped
  reason, or `killed` or `fault`, and log the whole reason, before traces are scoped (M5).
* [Low] live, host link (`erlang/apps/erx_hostlink/src/erx_hostlink.erl`, `bounded_measure/1`): a fault of
  `erx_hostlink_payload:measure/1` is refused as `{failed, Why}` but counted with malformed payloads as
  `bad_payload` and its reason dropped; count it apart or log it once.
* [Low] live, host link's 9P bridge (`erlang/apps/erx_hostlink/src/erx_hostlink_9p.erl`),
  review findings open: the namespace entry's `ro` is not applied; the bridge's own clunk replies
  count as stray; the tree lookup reads the namespace table on each attach;
  no `proc` tree is mounted yet; and the system manifest has no field for
  the trees a release build lists, so a release build serves none.
* [Low] live, host link's 9P bridge (`erlang/apps/erx_hostlink/src/erx_hostlink_9p.erl`):
  the bridge reads the whole manifest at each session's start;
  design-live.md still says the host tool counts credit from its hello's
  first byte, where it now counts from the hello's reply.
* [Medium] files, `erx_fs_grant` (`erlang/apps/erx_files/src/erx_fs_grant.erl`,
  `admit/4`): a flush of a deferred request only waits behind it, and no
  grant abandons a request at a flush, as design-files.md's Flush allows;
  so a deferred request whose file process never answers (a stuck job, a
  waiting lock once locks are served) holds its slot at the grant, and its
  tag at the host link bridge, until the session ends. Abandoning at a
  flush (answer only the flush, drop the file process's late answer) lets
  a flush free both.
* [Medium] security residual, host link's 9P bridge
  (`erlang/apps/erx_hostlink/src/erx_hostlink_files.erl`, `tree_grant/3`):
  the bridge uses the system domain's own grants and its tags bound, 64,
  equals a grant's whole 64 requests in flight, so a host that keeps 32
  slow reads and their flushes at the `data` grant makes that grant refuse
  the system domain's own processes with `emfile`; a grant of the bridge's
  own, or a per-grant cap below 64, closes it.
* [Low] live, host-link driver (`erlang/apps/erx_uart/src/erx_pl011.erl`):
  the design's driver buffers at most 64 KiB of received bytes and drops
  and counts beyond that (design-system.md, "Drivers"); erx_pl011 sends
  every drain to its owner's mailbox, which only the host's keeping to its
  credit bounds. The console's line has the same gap.
* [Low] shell, parser choices to settle against plan9port's rc once its
  oracle runs: `|[a=b]` is read as descriptor a of the left command to b of
  the right one, which may be the reverse of rc's lex.c; an empty operand
  of `|`, `&&` or `||` is refused, where rc's grammar takes one; and
`` `split{cmd} `` is accepted; a here document's body starts after the
next newline, even inside braces, where plan9port may wait for the whole
command; `>>{`, `<>{` and `>[2]{` are refused; and a NUL byte is a word
byte, which the evaluator refuses in a program's arguments and a file
name but hands the runner in a variable's value and name (`$n = 1` with
`n=a=b` exports `a=b=1`), in a `whatis` name (whose `not found` then
writes the NUL to descriptor 2) and in a glob's text; the evaluator
should build the environment it exports itself, of valid names and
values without a NUL, and refuse a NUL in `whatis` and glob requests,
so no runner has to remember them; and a keyword joins no word that touches it,
where rc's hand-written parser joins one in an argument (`echo for=x`
prints `for=x` in rc, `for =x` here), and the same holds after a
subscript's `)` and the `}` of `` `{...} `` and `<{...}` (`echo
$x(1)=2`), while a list followed directly by a word or `(` is refused in rc
(`echo (a)=b`, `x=(a)b`, `x=(a b)(1)`: "No free carats around parens")
and accepted here; `not=1`
and `in=x` are assignments in rc and refused here; and `cat <<=` takes `=`
as its tag in rc. The joining rules would hold by construction if the
lexer marked each token with whether a blank came before it and the
parser joined as rc's yyword does, in place of inserted carets and `sub`.
Add each
to the corpus and follow rc
  (`erlang/apps/erx_shell/src/erx_shell_lex.erl`,
  `erlang/apps/erx_shell/src/erx_shell_parse.erl`).
* [Low] shell, `whatis` of a function: rc prints `fn name {body}` as its
  parser deparses the body; the evaluator has no printer of syntax trees
  and says it cannot show the body, status `not supported`. Write the
  printer, following rc's pcmd.c, and drop the corpus's pinned
  difference `whatis-function.rc` (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Medium] shell, the evaluator's builtins to come: `.`, `wait`
  and `flag` (rc's), and `erl`, `within`, `jobs`, `fg`, `bg` and `kill`;
  each is an effect, so each goes behind the runner of `erx_shell_eval`
  with the command and job pieces of Track S (`cd` is the runner's,
  `erx_shell_runner`). Until then their names
  reach the runner as commands and give `not found`. `.` runs a file's units in the current
  shell, which `{run, Argv, Vars}` cannot express: it needs a request that
  reads the file for run_source/2; `flag`'s `-e`, `-x` and `-v` are
  evaluator state, which the evaluator does not hold
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Medium] shell, here documents: rc substitutes a template's variables
  when it reads the line (here.c), so a function's here document is fixed
  at its definition and `x=new; cat <<EOF` sees the old `$x`; the
  evaluator substitutes when it runs the redirection. Decide which the
  design wants and record it in design-shell.md, give the fake runner a
  `cat` that reads standard input, and add corpus cases
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Low] shell, the evaluator's smaller differences from rc, each to follow
  rc or record with a corpus case: `shift -1` empties `$*` in rc and
  shifts nothing here; `builtin builtin echo` runs a program `builtin` in
  rc; a copy's status is `1` in rc
  (`@{exit foo}`, a faulting pipeline stage gives `1|`) and the copy's own
  status here; and rc runs `fn sigexit` when the shell exits
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Low] shell, one reader of a source's units: `run_source`, `eval` and
  the parser's fuzz target each step through units by hand, threading
  the rest, the lines read and whether an `if not` may follow; the
  interactive layer's loop (`erx_shell`) is a fourth. A cursor in erx_shell_parse that
  `next_bounded` takes and returns, with diagnostics already counted from
  the source's start, would hold that state in one place; split
  `outcome()` then into a unit's and a source's, since `run_unit` never
  gives `syntax_error` (`erlang/apps/erx_shell/src/erx_shell_parse.erl`).
* [Medium] shell, a job's processes are found by group leader, not by
  job tag: until the runtime's job tags exist (docs/design-shell.md,
  "Jobs and their tags"), `erx_shell` runs each line and each `&` job
  under a group leader of its own that forwards io to the shell's group;
  stopping a job pauses every process that leader leads with
  `erlang:suspend_process/1`, in passes, and `Ctrl-C`, `kill`, the heap
  limit or a crash kill them (`pause/2`, `terminate/2`, `end_line/3`).
  The group leader is a field any process can change, so a process that
  sets its own escapes its job's stop and end, one whose leader code in
  the job re-points to the job's is stopped and killed with it, and work
  done by servers outside the job is not the job's. Each pass looks at
  every process of the runtime. Replace it with the job tag
  (`erlang/apps/erx_shell/src/erx_shell.erl`).
* [Medium] shell, a script's processes when its evaluator is killed:
  `erx_shell_script:run/2` runs a source in an evaluator process with a
  heap limit, and when the limit kills it the stages, commands and pipes
  it started run on. The interactive layer ends a line's processes
  through the line's own group leader (`erx_shell:end_line/3`); the
  script runner should do the same, sharing that code
  (`erlang/apps/erx_shell/src/erx_shell_script.erl`).
* [Medium] shell, what a done job leaves running is out of reach: a job
  is done, reported and gone from the table when its first process ends,
  and the processes it started that still run stay with its leader,
  unlisted, so `jobs` does not show them and `kill` and `Ctrl-C` cannot
  reach them until the session ends, where docs/design-shell.md keeps an
  inner `&` block in its job. Keeping the job listed as running until its
  leader leads nothing would make them its own; a foreground line would
  then wait for them too (`erlang/apps/erx_shell/src/erx_shell.erl`,
  `release/2`).
* [Low] shell, `&` inside a piece run apart ends with an interrupted
  line: a block that a pipeline's stage or a subshell of the foreground
  line puts in the background stays in the line's job, as in a UNIX
  subshell, so `Ctrl-C` ends it, where POSIX starts such a block with
  `SIGINT` ignored. Only `&` on the shell's own line starts a job that
  runs on (`erlang/apps/erx_shell/src/erx_shell_runner.erl`).
* [Low] shell, a stopped line finishes as a job and what it changed is
  dropped: a line that `Ctrl-Z` stopped and `fg` brought back ends as a
  job, so its assignments and `cd` do not reach the shell, where a UNIX
  shell has made them already. Taking a line's outcome when it ends in
  the foreground through `fg` would keep them
  (`erlang/apps/erx_shell/src/erx_shell.erl`).
* [Low] shell, the reading loop has no byte bound of its own: the parser
  caps a unit at 4 KiB, but the group's line and the shell's `Line`
  binary, in a process with no `max_heap_size`, hold whatever is typed or
  pasted, as stock's shell does; SH2 bounds a line at 64 KiB
  (`erlang/apps/erx_shell/src/erx_shell.erl`, `read/3`).
* [Low] shell, the command shell's lines go to the Erlang shell's history
  file when `kernel`'s `shell_history` is on, since its group uses the
  same `group_history`; start its group with `{line_history, false}` or
  give it a history of its own. `erx_shell:start/0` also hands the
  operator the shell process's raw exit reason, which a crash in the
  runner's `new/1` or the terminal's `write` would fill with their state
  (`erlang/apps/erx_shell/src/erx_shell.erl`, `erlang/apps/erx/src/erx_console.erl`).
* [Low] console, which requests of a hidden group are answered is a list
  in `from_hidden_group`: a group request it does not name leaves that
  group waiting for a reply, and a hidden group's `set_unicode_state`
  still changes the shared `prim_tty` state. Sending every group message
  through the one request path and discarding a hidden group's bytes at
  the output edge would make hiding one decision
  (`erlang/apps/erx/src/erx_console.erl`).
* [Low] console, a group's shell that exits with reason `kill` kills the
  console: OTP's `group` passes the shell's reason on with `exit(Drv, R)`,
  which cannot be trapped when `R` is `kill`, as with stock `user_drv`;
  have `group` send the reason as a message instead
  (`otp/lib/kernel/src/group.erl`).
* [Low] test, `runtime_console_test.rb`'s nested shells rest on a 300 ms
  sleep for which `run_shell` call comes first; under load the inner
  shell may start first and the case checks inner-first ending instead
  of outer-first. Have the first shell's start function tell the
  evaluator it runs before the second starts
  (`test/integration/runtime_console_test.rb`).
* [Low] shell, a line outlives its shell: the line's process is
  monitored, not linked, so a shell killed outright leaves a running line
  spinning. The line's group leader already monitors the shell and ends
  with it; killing every process it leads at that moment, as `end_line/3`
  does, would end the line too (`erlang/apps/erx_shell/src/erx_shell.erl`,
  `run/3`, `forward/2`).
* [Low] shell, the 4 MiB heap limit counts the variables a line starts
  with: once they near it, every later line passes its limit, even
  `x=()`; bound what the shell keeps, or limit a line to its starting
  state plus 4 MiB (`erlang/apps/erx_shell/src/erx_shell.erl`).
* [Low] shell, whether a diagnostic that names a command is program
  output or text attributed to a source: the evaluator writes `Name: not
  found` and `whatis`'s `Name=value` raw, and so does the runner's `Name:
  not found`, while erx_render escapes what it shows; a substitution
  carries a program's output into those names. Decide in
  docs/design-shell.md and make them agree
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`,
  `erlang/apps/erx_shell/src/erx_shell_runner.erl`).
* [Medium] shell, `Ctrl-D` does not end the command shell at the console:
  edlin binds it to forward delete, and a group in edlin mode that is sent
  `eof` ends the edited line without a newline and waits for more, so
  `get_line` never answers `eof`. An edlin action that deletes forward or,
  on an empty line, ends the input, bound for the command shell's group
  alone, would give rc's `Ctrl-D`; `exit` ends it meanwhile
  (`otp/lib/stdlib/src/edlin.erl`, `otp/lib/kernel/src/group.erl`).
* [Low] shell, `$status` after `Ctrl-C` ends a running line: the shell
  keeps the state it had before the line, where the design sets `$status`
  to say the line was interrupted; it needs a way to set a variable through erx_shell_eval
  (`erlang/apps/erx_shell/src/erx_shell.erl`).
* [Medium] console, a first shell started again while a shell above it has
  the input writes its banner through `erx_console:write/1`, which is shown,
  over the shell above, while its prompt goes through its hidden group and
  is dropped, so when the shell above ends the line shows no prompt; a unit
  of the old shell left waiting in `erl` writes its diagnostic when that
  shell ends. Starting the fresh shell only once the input reaches the first
  group again fixes both. A first shell that fails at its start is started
  again at once, with no limit and no message, so a broken release spins
  where it should halt with the reason; the restart decision wants a rate
  (`erlang/apps/erx/src/erx_console.erl`,
  `test/integration/runtime_console_test.rb`
  `test_a_crash_of_the_first_shell_starts_a_fresh_one`, which kills the
  shell 300 ms after `q()` and so depends on timing).
* [Low] console, typeahead past a line that starts a shell (`erl`,
  `erx_shell:start().`) stays in the group that read the line, which runs it
  once the new shell ends, where on UNIX the program the line started reads
  it: input arriving in one read goes to the group that has the input then,
  and `group` keeps what one `get_line` did not take. Handing a group's unread
  input to the group that takes the console needs a request `group` does not
  have (`erlang/apps/erx/src/erx_console.erl`, `lib/kernel/src/group.erl`).
* [Low] shell, a runner's reply of the wrong shape: `with_redirs`, a
  substitution's capture and `whatis` match the reply directly, so a
  runner that breaks its contract crashes the evaluator with the whole
  shell, its variables included, in the error reason; answer such a
  reply with a language fault that names only the request
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Low] shell, escaping the shell's own diagnostics: `whatis`'s `not
  found` and a runner's fault text name what may come from a shared file
  system and reach descriptor 2 raw, as in rc. Decide whether the runner
  applies the line escaper to the shell's `{write, 2, _}` text
  ([design-shell.md](docs/design-shell.md)).
* [Low] shell, bodies handed to the runner: each turns the evaluator's
  throws into values by hand (`apart` through run_unit/2, `with_redirs`);
  build every body through one constructor that does it
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl`).
* [Medium] shell, the command catalog is read at run time: `erx_shell_namespace:from_applications/1`
  loads the shell application's modules and reads their `-erx_command`, `-erx_usage` and
  `-erx_needs` attributes each time `erx_shell:run/2` starts, where the design has a generated,
  checked catalog bound to each module's blob hash and republished around code replacement
  ([design-generation.md](docs/design-generation.md#configuration-and-command-catalogs)). A module
  with malformed metadata is left out with a problem that `run/2` drops unshown; the generator
  should refuse it at build time (`erlang/apps/erx_shell/src/erx_shell_namespace.erl`).
* [Low] shell, the terminal's table measures a value by its characters (`string:length/1`), so an
  East Asian wide character, which takes two columns, misaligns the rest of its row; measure display
  width from the terminal tables (`erlang/apps/erx_shell/src/erx_render.erl`).
* [Low] shell, the text commands' gaps against docs/design-live.md and docs/design-shell.md
  (`erlang/apps/erx_shell/src/erx_cmd_ps.erl`, `erx_cmd_grep.erl`, `erx_cmd_wc.erl`): `ps` prints `-`
  for `TT` because the session's tty has no name a command can read, leaves out the `+` of a
  foreground job's `STAT`, and lists no programs until programs run in sessions; `grep -r` is not
  offered; `wc`'s status is its first error's text where FreeBSD's is 1; and a usage error's
  status is `usage` where FreeBSD's `sort` and `grep` exit 2 and `top` 1
  (`erx_shell_runner:outcome/3`).
* [Low] shell, the runner's pieces not done yet: `<{...}` and `>{...}` are refused, since the
  namespace has no path that names a pipe; a background block's redirected files close when the
  redirection's request ends, so `{cmd &} > f` loses what `cmd` writes after that; a substitution's
  output is bounded by the evaluator's heap alone; the first Erlang commands lack `i`,
  `bind`, `unmount` and `mount` with arguments, which change the namespace through `erx_ns`
  (`erlang/apps/erx_shell/src/erx_shell_runner.erl`).
* [Medium] shell, the Erlang file utilities (`erlang/apps/erx_shell/src/erx_cmd_*.erl`): `echo`, `cat`, `ls`,
  `pwd`, `mkdir`, `rm`, `mv` and `cp` are erXos's own and replace toybox's applets of those names, but each takes
  only a few of FreeBSD's flags (`ls -l`, `mkdir -p`, `rm -rf`; no `ls -a`, `cp -R`, `mv -i` and the like). Grow each toward
  FreeBSD's utility, flag by flag, with FreeBSD's manual page as the reference and a test per flag.
* [Medium] shell, the stage heap limit (`erlang/apps/erx_shell/src/erx_shell_runner.erl`, `MAX_HEAP_WORDS`):
  the runner sets `8 bsl 20` words, 64 MiB on a 64-bit runtime, where design-shell.md's "One evaluator per
  stage" gives 4 MiB and an allowance of eight stages in 32 MiB; settle one figure in both.
* [Medium] shell, the runner's review findings left open (`erlang/apps/erx_shell/src/erx_shell_runner.erl`):
  a stream has no direction, so `` x=`{cat >[0=1]} `` reads the write end of its own pipe and hangs the
  session; give `{pipe, Pid}` a direction and answer `ebadf` to a read of a write end. Stage, command and
  evaluator processes are monitored, not linked, so a killed evaluator or stage leaves its children
  running and `{while(){}} &` runs until reboot; link each to its starter. A substitution's output has
  no bound but the evaluator's heap, so `` x=`{cat big} `` ends the whole source rather than one stage;
  cap it and record the bound in design-shell.md. The runner's and commands' diagnostics (`not found`,
  `cd`, `can't open`, `erx_cmd:report/3`, crash text) carry file names raw to the terminal; decide in
  design-shell.md whether they pass the line escape. Glob keeps a non-directory before `/` (`echo */`
  lists files) and resolves `f/..` by name. Stages and background blocks are admitted with no stage
  allowance at all (see pipeline admission below). A pump treats a read error as end of input, so `grep` of a
  directory finds nothing where FreeBSD's warns; `ls` and glob skip names that are not UTF-8
  (`list_dir_all`).
* [Medium] shell, pipeline admission: each pipeline stage is admitted at
  its full `max_heap_size`, 16 MiB, against an eighth of the session's
  budget, so a 128 MiB session admits one stage and `ps | where | sort`
  fails. Admit stages against their expected heap, or share the eighth
  among a pipeline's stages ([design-shell.md](docs/design-shell.md)).
  The 8 MiB child each evaluator parses a unit in is admitted nowhere,
  so SH2's claim that stages stay within the allowance leaves it out:
  charge it with its evaluator or admit it against the allowance.
* [Medium] shell, recovery after a refused unit: after `line too long`
  `erx_shell_parse:next/2` resumes nothing it was handed, but the lines
  of the unit that the terminal has not delivered yet (the rest of a
  pasted `fn`, or of a line still being read) would run at the top
  level, and after a syntax error inside a multi-line unit the lines
  after the fault run, as in rc. Decide what the interactive loop
  discards: the terminal's pending input, input up to a newline, or
  input until the open constructs close
  ([design-shell.md](docs/design-shell.md#the-language)).
* [Medium] shell and programs, command domains: `system`, `popen` and
  every Erlang command a program starts begin a command domain, at an
  estimated 0.15 to 0.3 s each, and `wak`'s `system()` pays it per call.
  Make one command domain per image, lazily, which holds the same
  authority by construction. Command domains take their names from the
  per-principal pool of reusable names that
  [design-system.md](docs/design-system.md#identifiers) defines
  ([design-shell.md](docs/design-shell.md),
  [design-programs.md](docs/design-programs.md#what-a-program-can-start)).
* [Medium] shell and programs, what `/bin/sh` and `system()` mean for
  ported programs: `system` and `popen` run `rc`, so a FreeBSD program
  that calls `system("cmd 2>/dev/null")` or similar sh syntax breaks,
  against the goal of running FreeBSD programs ported at the source
  level; a POSIX sh exists only in the second tier. Decide before Track
  S's programs part; the interactive shell stays rc
  ([design-shell.md](docs/design-shell.md#rc-as-a-program),
  [design-programs.md](docs/design-programs.md#toybox)).
* [Medium] programs, signals to self: a signal a program sends itself has
  three delivery paths, so `killpg(getpgrp(), SIGTERM)` in the second tier
  can deliver twice. Make the handler the one path for every signal a
  program sends, its own included
  ([design-programs.md](docs/design-programs.md#signals-in-liberx)).
* [Medium] live code, overlay publication: specify reconciliation when a
  domain loads a candidate but its acknowledgement is lost, and make the
  inspector distinguish the running module set from the published overlay
  used at restart. Ordinary domains may retain a partial candidate after
  failure; evaluate atomic module loading for eligible batches and a fresh
  domain for changes requiring new application state. Loading an older
  hash does not restore application state or undo external effects
  ([design-live.md](docs/design-live.md#code-from-the-host)).
* [Low] architecture, security claims: distinguish immutable executable
  memory from the stronger file-source claim: no grant carries `rw` and
  `rx` together, but a program may hold both on one file through two
  grants, so "a program never runs what it could rewrite" holds per grant,
  not per file ([design.md](docs/design.md#trust-placement),
  [design-files.md](docs/design-files.md#invariants)).
* [Low] programs, compatibility: `daemon()`, the double fork, toybox's
  `setsid` and `nohup x &` cannot outlive their starter under "a program's
  tree ends with it", and only "no `SIGHUP`" is in the compatibility
  table. List them there as documented differences with tests
  ([design-programs.md](docs/design-programs.md#a-programs-end)).
* [Low] system, principals: a principal can be created but never resized
  or removed. Add both to the principal service, with what happens to its
  sessions, domains, overlays and vault files
  ([design-domains.md](docs/design-domains.md#principals-sessions-and-quotas)).
* [Low] domains, naming: a name binds to the principal whose domain first
  takes it, so a principal can take a name before the principal or the
  configured domain meant to hold it. The design recommends first-use
  binding with the configured domains' names held from boot; the
  alternative is names the administrator assigns to each principal in the
  system manifest, which closes squatting at the cost of a configuration
  step per name. The user decides
  ([design-domains.md](docs/design-domains.md#risks-and-open-questions),
  [design-system.md](docs/design-system.md#identifiers)).
* [Low] domains, retirement: a survivor that never answers
  `connection_down` keeps a dead domain's outer budget and its record in
  the domain library until it unmaps or ends, bounded by the survivor's
  `connections` quota. Leave headroom in `max_domains` for such records,
  and state how much
  ([design-system.md](docs/design-system.md#risks-and-open-questions)).
* [Medium] domains, edit 66 (`beam/bif.c` `link_opt` and `monitor`,
  docs/design-runtime.md): the asker answers a link or monitor of a pid of another run of a
  peer's node only while its entry for the name is connected. One made while the entry is
  pending, in the short window of an introduction or of a stock auto-connect that an
  introduction takes over, is queued as stock queues it and sent once the peer is
  connected; the peer's `noproc` answer names that pid, the asker's sender rule refuses
  it, and the connection ends. The pid need not be real: any domain that can send the
  asker a term can forge one with the peer's name and another creation, so a service
  that monitors pids its clients hand it can be made to lose its connection to a third
  domain, in that window. A pending entry does not know the peer's id; the complete fix
  answers the frame where it is written to the lane port, whose id is known, which would
  also hold edit 66 for every operation by construction. Related: a pid with a creation
  newer than a connected entry's, a later domain while the asker has not yet taken the
  ended one's `connection_down`, gets `noproc` where stock would give `noconnection`.
* [High] domains, the funnel's sender rule (`liberx/erx_funnel.c` `sender_rule`,
  docs/design-domains.md "The funnel", step 4): a link or monitor of a pid of an ended
  domain, sent once a later domain of its name is connected, ends the connection. The later
  domain's funnel finds the target dead and has ERTS answer noproc, and ERTS's answer
  (`PAYLOAD_EXIT`, or `PAYLOAD_MONITOR_P_EXIT` from `erts_dsig_send_m_exit`) names the dead
  pid as its sender, as stock ERTS does; that pid carries the ended domain's id, so the
  asker's sender rule finds a sending pid of another creation and refuses the frame as
  malformed. A client that keeps a monitor on a service domain's process and monitors it
  again after the service's domain was replaced is enough. Seen in the system_domain
  suite's later-domain step with a monitor in place of its message. Two fixes: the asking
  runtime answers a link or monitor of a pid whose creation is not its connected entry's
  itself, with noproc and no frame, as stock ERTS does for its own node's earlier runs
  (recommended: no rule changes, and nothing a stock test sees); or the sender rule admits,
  in those two answers alone, a pid of the lane's node name with an earlier id, which lets a
  later domain report deaths of its name's ended domains. The user decides.
* [Low] kernel ABI generator, `tools/lib/erx/abi_model.rb`: a private
  layout stays out of every public declaration by three separate
  refusals (embedding as a field, as a tail, and projection), so a new
  construct that names a layout (a reader table, a call argument) must
  remember a fourth. Walk every type reference of the schema once, after
  parsing, and refuse each one from a public declaration to a private
  layout, so the property holds for any construct
  ([design-abi.md](docs/design-abi.md#source-grammar)).
* [Medium] kernel ABI generator, `tools/lib/erx/abi_model.rb`: a
  record's `version` field is tied to its `*_version` limit only by
  naming, and the names differ (`erx_boot_info` uses `boot_version`,
  `erx_image_manifest` uses `image_version`), so nothing refuses a
  versioned layout without its constant or a writer that stores another
  value. Add a layout member naming the field's constant (`value version
  @time_page_version`, as `reader ... value root.version
  @manifest_version` already does), have the generator emit the encoder's
  store and the decoder's check from it, and refuse a `version` field
  without one ([design-abi.md](docs/design-abi.md#numeric-assignment-and-versions)).
* [Low] kernel ABI, status codes: `ERX_EDEAD` carries two meanings (a
  dropped caller and a dead target). Split it, or state why one code
  serves both
  ([design-kernel.md](docs/design-kernel.md#calling-convention-and-status-codes)).
* [Low] kernel and arch-aarch64, `ERX_DMA_MSI_IOVA`: the constant is a
  GICv2m fact in a generic name. Move it to the platform layer's MSI frame
  description ([design-kernel.md](docs/design-kernel.md#dma-and-the-iommu),
  [design-platforms.md](docs/design-platforms.md#msi-frames)).
* [Low] kernel, `ERX_MEM_INHERIT`: the flag is the remembered creator mark
  that the copy table of `erx_space_copy` says it avoids. Reconcile the
  two
  ([design-kernel.md](docs/design-kernel.md#copy-on-write-children-and-copies-of-spaces)).
* [Low] kernel and platforms, store tracking: measure which accelerators
  and boards report `FEAT_HAFDBS` (`ID_AA64MMFR1_EL1.HAFDBS`), so that
  store tracking uses hardware dirty-state management where it exists
  and write-protect faults elsewhere
  ([design-arch-aarch64.md](docs/design-arch-aarch64.md#translation)).
* [Low] runtime, dirty I/O threads: every Erlang domain gets ERTS's
  default of ten idle dirty I/O schedulers. Size the default for a domain
  of a few megabytes, or start them lazily
  ([design-runtime.md](docs/design-runtime.md#scheduling)).
* [Low] runtime, the text of other machines' pids: a pid of another
  machine's node prints with a creation that can equal one of this
  machine's domain ids. The design recommends keeping the one rule,
  resolving `list_to_pid` to this machine's domain on a collision, and
  showing a pid's node name beside its text in the inspector; the user
  decides
  ([design-runtime.md](docs/design-runtime.md#risks-and-open-questions)).
* [Low] platforms, the real-time clock: neither board has the PL031 the
  kernel's device table takes as its real-time clock. Name each board's
  clock, or read wall time from the firmware
  ([design-platforms.md](docs/design-platforms.md)).
* [Low] platforms, panic output: the board port measures whether the
  kernel's polled early-console writes at a panic complete after the
  console driver has reconfigured the UART, on each board
  ([design-platforms.md](docs/design-platforms.md#uarts)).
* [Low] platforms: the Pi 4's VL805 USB host sits behind a PCIe bridge no
  domain drives, so the Pi 4 has no USB; decide whether a PCIe domain
  drives the bridge on the Pi 4
  ([design-platforms.md](docs/design-platforms.md)).
* [Low] live, the host tree over virtio-9p: QEMU's 9p server on Darwin
  and FreeBSD hosts translates only six errnos to Linux numbering (its
  `errno_to_dotl` has a FIXME), so an error from `/host` on a macOS host
  may carry a host errno. The host-tree bridge treats an errno outside
  the codec's list as `eio`. Record it as QEMU's upstream defect and
  re-check it at each QEMU pin
  ([design-live.md](docs/design-live.md#files-between-the-host-and-the-machine)).
* [Low] storage, the boot-selection record: a torn record leaves the
  update service refusing every update until an installation writes the
  record afresh, since no normal boot may rewrite it. Consider a repair
  through a trial, on the boards whose firmware can request one
  ([design-storage.md](docs/design-storage.md#risks-and-open-questions),
  [design-platforms.md](docs/design-platforms.md#slots-and-the-boot-selection-record)).
* [Low] storage, FAT and littlefs: a file closed and reopened may get a
  new qid path, since those formats draw paths from the domain's counter;
  stable paths across a close would need a persistent identity the formats
  lack ([design-storage.md](docs/design-storage.md#data-model)).
* [Low] build, stack proof: confirm that lld's `--emit-relocs` keeps the
  call and jump relocations that the stack proof decodes
  ([design-arch-aarch64.md](docs/design-arch-aarch64.md)).
* [Medium] build, stack proof: LLVM 23 resolves a `bl` to a static
  function in the same section without a relocation, which the proof
  refuses, so the proven C must be compiled with `-ffunction-sections`
  (and no shared `section` attribute). The stack-proof passages of
  [design-kernel.md](docs/design-kernel.md#stack-proof),
  [design-arch-aarch64.md](docs/design-arch-aarch64.md#stack-proof) and
  the cores' build flags in [design-stopgap.md](docs/design-stopgap.md)
  name neither the flag nor that `tools/lib/erx/stack_graph.rb` reads
  relocations from `llvm-readobj`'s JSON listing of each object; the owner
  decides between requiring the flag and accepting a relocation-less
  in-section call whose decoded target is a function start.
* [Medium] build, stack proof: `tools/lib/erx/stack_graph.rb` pairs each
  object with its `.su` file by name, so a stale `.su` left by an earlier
  build gives wrong frames silently. Read frames from the object itself
  (`-fstack-size-section`'s `.stack_sizes`, bound to symbols by
  relocations), or have the build delete the `.su` before each compile.
  The build's own proof (`tools/lib/erx/stack_proof_run.rb`) compiles into
  a fresh directory on every run; other callers are exposed.
* [Medium] build, stack proof: the graph does not record which functions
  have their address taken (non-branch relocations naming a function), so
  `kernel/stack_targets.txt` cannot be checked against the functions an
  indirect call may reach: `tools/lib/erx/stack_proof.rb` takes the listed
  targets as given. Record them, and refuse an address-taken function that
  a listed indirect call could reach but the list omits. The same record
  must make every function whose address leaves the cores (a callback
  handed to Fiasco) an entry: today the proof judges only what the
  exported functions reach, so such a callback's frame and callees go
  unchecked.
* [Medium] build, stack proof: a `switch` that clang lowers to a jump
  table ends in an indirect branch that stays inside its function, which
  `kernel/stack_targets.txt` cannot declare (it lists functions, taken as
  tail jumps), so the first such switch in a core fails the proof or
  invites a wrong declaration. The choice is between
  `-fno-jump-tables` for every proven object (the proof's flags in
  `tools/lib/erx/stack_proof_run.rb`, the archive's in
  [design-stopgap.md](docs/design-stopgap.md) and
  [design-arch-aarch64.md](docs/design-arch-aarch64.md#stack-proof)) and
  teaching `stack_graph.rb` to recognize a jump table's branch whose
  targets lie in its own function.
* [Low] build, stack proof: declarations that nothing uses are accepted
  silently: a `kernel/stack_targets.txt` line whose function holds no
  indirect site at either level, and a `leaf` of `kernel/stack_fiasco.txt`
  that a core defines itself. Report them after both levels have run.
* [Low] docs/design-stopgap.md, the stack proof: the bullet names only the
  `erx_effect_*` calls as leaves of declared cost; the proof also counts
  Fiasco's `memcpy` and `memset`, the archive's two other allowed
  undefined symbols, that way. The reading needs confirming; the
  bullet then says so.
* [Medium] build, stack proof: the stopgap proof's entries are every
  exported function of the cores' archive (`tools/lib/erx/core_archive.rb`),
  a superset of the ones the kernel image references
  ([design-stopgap.md](docs/design-stopgap.md)). Read the entries from the
  linked kernel's references to the archive instead, which needs the proof
  to run after the link as well as before it.
* [Medium] kernel, boot image: `erx_image_slice` needs the verdict table and
  hashing in parts of 64 KiB, which `erx_pack_file_check`, hashing a run in one
  call, cannot give it. Make it a pure stepper the core owns, computing the
  digest itself, not a digest the caller passes in, so that function stays the
  one check. The slice also needs `pack.c` in the kernel's archive and its stack
  proof as well as in `bootstrap`, and must decide what a run of only empty
  files, an object of no pages, returns. Until it lands nothing checks a file
  `bootstrap` does not place, so a file cut short inside `system/root` boots,
  though [design-kernel.md](docs/design-kernel.md#the-bootable-file) counts it as
  refused. `tools/erx pack` stays refused until the M1 root startup, so
  `--two-file` and the slot refusal wait for it.
* [Medium] boot image, `kernel/core/boot_place.c`: Phase 1 keeps the two
  roles `boot/sigma0` and `boot/stopgap-root`, since Fiasco starts sigma0
  and a root task from its information page, and sigma0 pages that root
  with read, write and execute over its whole range, gaps between segments
  included, which nothing zeroes; Phase 1 accepts this
  ([design-stopgap.md](docs/design-stopgap.md#boot-handoff)). erXos's
  kernel maps the root task from the startup plan, so Track K decides
  whether the image keeps the two entries, which that kernel would ignore,
  or drops them with their ABI paths and the recipe in
  `tools/lib/erx/boot_image.rb`. `tools/lib/erx/boot_image.rb` builds on
  the structural fixture's unadmitted manifest until production packing
  lands.
* [Medium] kernel boot, `kernel/core/boot_place.c`: the handoff record's
  `pool_usable`, `pool_heap` and `pool_regions` are zero in Phase 1, which
  has no reader for them
  ([design-stopgap.md](docs/design-stopgap.md#boot-handoff)). Track K
  gives them values from `erx_pool_plan` (`docs/design-kernel.md`) and a
  reader in erXos's kernel, and settles where `kip_size` and the kernel's
  alignment live; they are limits of `abi/erx_abi.txt` today.
* [Medium] stopgap boot, `kernel/core/boot_place.c`: `bootstrap` places two
  entries the target design does not have, `boot/sigma0` and `boot/stopgap-root`,
  because the kernel still starts sigma0 and a root task from its information
  page; sigma0 pages that root with read, write and execute over its
  whole range, since one range cannot tell its segments apart, gaps between
  segments included, which nothing zeroes. Delete both roles, their ABI paths and the record of the recipe in
  `tools/lib/erx/boot_image.rb` when the kernel maps the root task from the
  startup plan. `tools/lib/erx/boot_image.rb` builds on the structural fixture's
  unadmitted manifest until production packing lands.
* [Medium] stopgap boot, `kernel/core/boot_place.c`: the handoff record's
  `pool_usable`, `pool_heap` and `pool_regions` are zero and `kmemsize` keeps
  Fiasco's default until `erx_pool_plan` and `abi/backend/fiasco.txt` land; the
  kernel does not read them yet. `kip_size` and the kernel's alignment are limits
  of `abi/erx_abi.txt` until that backend file exists to hold them.
* [Medium] stopgap boot, `fiasco/bootstrap/server/src/init_kip.cc`: `init_kip_md`
  writes the memory descriptors at the offset the kernel image's information page
  names, unchecked against the view's size or its count, though
  [design-stopgap.md](docs/design-stopgap.md#boot-handoff) says within the view.
  Only a kernel image whose hash matched gets there, and a kernel image already
  runs in kernel mode, so this is a crash on a bad build and no gain. Check the
  offset and count in the plan or just before the write, with a fixture.
* [Medium] stopgap boot, `tools/lib/erx/boot_image_check.rb`: two cases of the
  verification table are not run on QEMU: a single file whose header asks QEMU to
  place it away from `bootstrap`'s link address, and a boot with the validator
  removed. The first needs the harness to expect a deadline, the second a seeded
  first stage.
* [Low] stopgap boot, `fiasco/bootstrap`: the inherited image tools and module
  code (`build.pl`, `exec.cc`, `module.cc`, `boot_modules.cc`, `mod_info.cc`,
  `uncompress.cc`, `mk/tool/imagebuilder`) are unbuilt and the other platforms'
  sources still name them. Delete them or fix those platforms with the first
  port that needs one.
* [Medium] build, stopgap bootstrap: `kernel/core/pack.c` is left out of
  the kernel's archive (`CoreArchive::BOOTSTRAP_SOURCES`) but is not yet
  linked into `bootstrap`, since nothing there calls it until the boot
  handoff ([design-stopgap.md](docs/design-stopgap.md#boot-handoff)) is
  written. That package builds a second archive of `pack.c`, the image
  planner `liberx/image_plan.c` it checks image entries through, BLAKE3's
  portable C and `liberx/generated/abi_reader.c` for `bootstrap`'s position-independent
  link (`-fPIE`, `-z text` in `fiasco/bootstrap/server/src/Make.rules`),
  adds the seam header `include/erx/core/pack.h` (`erx/pack.h` reaches
  `erx/abi.h`, which is C only), and audits `bootstrap`'s map like the
  kernel's.
* [Medium] build, cores' archive (`tools/lib/erx/core_archive.rb`): the
  compile's argument vector is not recorded beside each object, so the
  Fiasco audit sees a core object's sources (`.NAME.o.d`) but not its
  flags; record it as Fiasco's `.cmd` files do and have the audit compare
  it with `CoreArchive::FLAGS`.
* [Medium] build, Fiasco audit of erXos sources
  (`tools/lib/erx/fiasco_provenance.rb`, `erxos_notice?`): its test is a
  substring in the first eight lines, so `BSD-2-Clause AND GPL-2.0-only`
  is recorded as `BSD-2-Clause`. Use `Attribution.erxos_addition?`, or a
  test of the same strength, once the audit's real inputs can be run
  against it.
* [Low] build, import inventory (`tools/lib/erx/origin.rb`, `Origin#check`,
  and `PackProvenance#imported_item`): a `changes` row whose hash no longer
  matches still supplies the file's licence when the file has an erXos
  header; a stale row should be refused.
* [Medium] build, notice check (`tools/lib/erx/pack_provenance.rb`,
  `attribute`; `tools/lib/erx/import_notices.rb`, `select`): the check that
  a selected import grant has a notice document looks at the whole
  expression, so `<covered> AND <uncovered>` passes with no document for the
  second grant. ChaCha20's `LicenseRef-DJB-public-domain` passes this way,
  rightly, since its notice is the header `leading_notice` keeps; a
  per-grant check must state what a file's own header counts for, and may
  find other imports short of rows.
* [Low] build, notice check (`tools/lib/erx/pack_provenance.rb`,
  `attribute`): a file of erXos's own that declares `BSD-2-Clause AND
  Unicode-3.0` (`build/gen/erlang/apps/erx/src/erx_text_tables.erl`,
  `build/gen/tools/generated/terminal_tables.rb`) takes the non-import branch, which
  attaches only `LICENSE` and the file's header and never reads the notice
  profile, so the checked `Unicode-3.0` document does not reach its notice.
  Unverified that these files reach a packed image's records; if they do,
  look up the profile for the selected grants other than erXos's own.
* [Low] build, licence selection (`tools/lib/erx/license_expression.rb`,
  `PERMISSIVE`, and `PackProvenance#attribute`): the entry for ChaCha20's
  public-domain statement is global, so a file outside any import that
  declares `LicenseRef-DJB-public-domain` passes a release pack with
  erXos's `LICENSE` as its notice. Refuse it outside an import.
* [Low] build, notices (`tools/lib/erx/pack_provenance.rb`,
  `leading_notice`): `#` counts as a comment leader in every language, so a
  C file's leading `#include` and `#define` lines, and comments after them,
  reach `system/NOTICES`. Choose the leaders by file suffix.
* [Medium] build, Fiasco audit of imported cores
  (`tools/lib/erx/fiasco_provenance.rb`, `erxos_source` and
  `attribute_erxos`): a file under `kernel/` or `include/` is attributed
  as erXos source, `BSD-2-Clause`, whenever its first eight lines carry
  the SPDX line, so FreeBSD's SHA-256 and ChaCha20 in `kernel/crypto/`
  enter the build record without their `ORIGIN.md` files, their recorded
  licences (ChaCha20's public domain) or Colin Percival's notice, and
  BLAKE3 (`Apache-2.0 WITH LLVM-exception`, no BSD-2-Clause line) blocks
  the record as soon as the stopgap kernel links it. Attribute
  every file under a directory with an `ORIGIN.md` through that origin's
  inventory, as the fork parts are, never through the header rule, and
  test it with a captured-inputs fixture.
* [Medium] build, compiler identity: several paths that build Fiasco, an
  image or a QEMU guest read `ERX_CLANG` (and `ERX_LLD`) themselves
  instead of taking what `host_environment` resolved: `tools/erx build
  fiasco` and `BootImageCheck` in `tools/erx`, `Fiasco`'s default compiler
  (`tools/lib/erx/fiasco.rb`), `interactive_boot.rb`, `medium_boot.rb` and
  the `native_*.rb` harnesses. Have them take one toolchain value from
  `host_environment` (absolute clang and lld and the LLVM header
  registry) in place of raw `compiler:` and `linker:` strings, so the
  seven `-print-resource-dir` lookups become one. Separately, the
  recorded clang hash is the driver's, not `libclang-cpp` and `libLLVM`,
  which hold the code generator; hash the linked libraries.
* [Low] build, supported compilers: decide which compilers and versions
  erXos supports (LLVM for erXos's code, `aarch64-elf-gcc` for the
  stopgap Fiasco) and state them in README's Host setup. Nothing checks a
  compiler's version until then; release images are built with exactly
  LLVM 23.1.3 (docs/plan.md, M11).
* [Medium] build, glue seam: the glue's include path is a copy of
  `include/erx/core/` under `build/fiasco/cores/seam/`, and the audit
  (`FiascoProvenance#erxos_source`) maps any path below `seam/` back to
  `include/`, wider than the copy. A layout whose seam directory is itself
  captured (for example `include/seam/erx/core/`) would delete the copy and
  the remap; at least restrict the remap to `erx/core/`.
* [Medium] build, tests: the audit's erXos attribution
  (`erxos_source`, `attribute_erxos`, `erxos_addition`), `llvm_registry`,
  `StackProofRun.call(archive:)`'s mismatch refusal, and the archive's
  replacement of an existing output have no host tests; the real build's
  complete audit is their only check. `erxos_notice?` also accepts any
  SPDX expression containing `BSD-2-Clause`; parse it with
  `Attribution`'s parser instead.
* [Medium] build, stopgap glue: the design compiles the glue with GCC's
  `-fstack-usage` and checks it (B2, B3, B9, B11, the import allowlist);
  `fiasco/kernel/src/erx/erx_handoff.cpp`, the one glue module built, gets only
  `ERX_GLUE_CXXFLAGS` (`fiasco/kernel/src/Makeconf`). The glue checks
  package adds the flag beside the include path.
* [Medium] stopgap kernel, FP state: the fork switches FP state eagerly,
  and nothing runs it. No QEMU case holds distinct vector registers in two
  threads of different spaces across switches and a migration, or reads a
  fresh thread's registers as zero (the FP case of the "every exception
  class" row of [design-stopgap.md](docs/design-stopgap.md)), and no
  `tools/erx bench` workload times the kernel's context switch, so the
  eager switch's cost is unmeasured. `Context::spill_fpu_if_owner`
  (`context.cpp`), which turns the unit on to save a current vCPU that
  disabled its FPU, has no case that reaches it, and the eager
  `Thread::transfer_fpu` (`thread.cpp`) still saves and restores the
  current thread's registers without turning the unit on; the design
  does not build it.
* [Low] build, configuration check: `tools/lib/erx/fiasco.rb` checks the
  resolved `globalconfig.out` before the kernel make, whose own rules can
  rerun `oldconfig` or `syncconfig` (`fiasco/kernel/src/Makefile`). Today
  a changed source recreates the build directory, so nothing rewrites the
  checked file; check the configuration the built kernel embeds
  (`.debug.fiasco_config`, `Makeconf`) after the make as well.
* [Medium] build, stack proof: `kernel/stack_targets.txt` declares no stack
  use of assembly routines, and the proof checks no declared use against
  the routine's stack-pointer adjustments
  ([design-kernel.md](docs/design-kernel.md#stack-proof)). The cores have no
  assembly; erXos's kernel needs both.
* [Medium] liberx, generated ABI reader: `erx_manifest_open`
  (`liberx/generated/abi_reader.c`) has a 2048-byte frame at -O0 and a
  992-byte one at -O2, and `erx_crash_record_decode` a 976-byte one at -O0
  (clang 23.1.3, `aarch64-none-elf`, measured 2026-11-03). The boot
  validator calls the first, so wherever it runs on a proven stack the
  1 KiB frame cap refuses it. Decode into caller-supplied scratch instead
  of stack locals.
* [Low] build, stack proof: `kernel/stack_fiasco.txt` lists its `tick`
  entries by hand; derive them from the glue's tick hook once the glue
  exists, and have the glue's `static_assert` and the conformance suite's
  watermark check read the allowances from that file.
* [Medium] build, stack proof: frames and tail jumps are taken as the
  compiler made them; inline assembly that writes the stack pointer or the
  link register is not accounted for. The inline-assembly chokepoint must
  also refuse either write in its listed functions.
* [Low] build, stack proof: refusal paths of `stack_graph.rb` with no test
  of their own: an instruction outside every function, overlapping or
  weak function symbols, a relocation into a section where no function
  starts, a section symbol plus addend into a function's middle, SHT_REL
  sections, two relocations at one offset, and duplicate executable
  section names. Most need only hand-made tool output fed to
  `StackGraph.build`.
* [Low] docs/research-baselines.md: the experiments behind the record (the
  boot and exception probe and its generators, the ERTS round-trip
  benchmark, the restricted decoder, the decompiled device trees) live
  outside the tree in `~/erxos-scratch/`. Bring them into `bench/` and check
  them against the SHA-256 prefixes the record gives, so the record can be
  reproduced from the repository. Its numbers do not state the compiler
  flags, which CLAUDE.md requires of every performance number; re-measure
  them with the flags recorded, in a new dated record.

* [Low] host tooling, the build memo (`tools/lib/erx/build_memo.rb`):
  records are reused only on macOS, whose sealed system volume the
  system release names; on FreeBSD every step runs, so a second Fiasco
  build of an unchanged tree runs its commands again. FreeBSD's base
  programs change with a world install or pkgbase upgrade under the
  same `uname` and `freebsd-version -u` on a -CURRENT host; reuse there
  needs the base programs and their libraries named by content, and the
  helpers a package runs by unversioned path (`/usr/local/libexec/gcc/...`
  cc1, `/usr/local/lib/perl5`), which `directory_identities` does not name;
  Homebrew's versioned Cellar paths name them by path.
* [Low] host tooling, the Fiasco build (`tools/lib/erx/fiasco.rb`, `memo_key`): a
  perl that is a version-manager shim (plenv, mise) goes on the build's PATH
  as such, so the key names the shim, not the interpreter it picks, and
  switching the global perl leaves a stale hit on macOS.
* [Medium] host tooling, the source check (`tools/lib/erx/checks.rb`):
  `Runner` writes a child's stdout and stderr to one log, so the check
  finds a git warning only because it breaks the NUL-terminated listing.
  That catches every warning git prints, but a git that skipped an
  unreadable directory without a warning would shrink the file set
  silently; git 2.50 warns, and the oldest git that does is unconfirmed.
  Give `Runner` a separate stderr log and require it to be empty, so the
  guarantee holds whatever git version is installed.
* [Low] host tooling, the pack-tool recipe (`tools/lib/erx/pack_tool_recipe.rb`):
  project inputs are refused by private directory name
  (`Erx::PrivateState`). Requiring each to be a file the source check's git
  listing names would make that hold by construction. Compiler metadata
  outside the project is likewise judged by name; checking it against the
  compiler's own roots (SDK path, resource directory) would also refuse
  credential files whose directory is not on the list.
* [Low] website, `.github/workflows/site.yml` and `tools/lib/erx/site_v64.rb`:
  the tools that build v64 are not pinned: the workflow installs whatever
  clang, lld, Java, Ruby and Rust the runner's apt and rustup give, and
  `setup-node` takes the newest Node 22, so two runs of the same inputs
  can ship different `libv86.mjs` and `v86-arm64.wasm`. Pin each to a
  version (a Rust toolchain file or `rustup toolchain install` of an exact
  release, exact apt package versions or a pinned container image).
* [Low] website, `site/terminal.js`: `machine.boot()` and `machine.reset()`
  catch their own errors, but the `import()` of v64's module and
  `load_xterm()` start before the manifest and image downloads they are
  awaited after, so when a download fails first, a later failure of either
  promise is an unhandled rejection in the console. Attach a handler where
  each starts.
* [Low] website, `site/terminal.js`: "Try again" after a failed boot
  downloads the image again even when the image arrived and checked out
  and only xterm.js or v64 failed to load; keep a checked image across
  retries.
* [Low] website, `tools/lib/erx/site.rb` (the QEMU virt download): the page
  offers the gzip-compressed image for QEMU's `-kernel`, which unpacks it
  as it loads it. QEMU may stop unpacking a gzipped kernel above a size
  ceiling (unverified: read QEMU 11.1's `hw/arm/boot.c` and
  `include/hw/loader.h`); if it does, the download stops booting once the
  unpacked image outgrows the ceiling while the browser console keeps
  working. Check the ceiling and refuse a larger image in `Erx::Site`.
* [Low] website, `tools/lib/erx/site.rb`: the card's SHA-256 is taken in
  `inventory` and xz reads the card again in `publish`, so a card changed
  in between is published under a digest and a record that do not
  describe it. Hash the bytes xz reads.
* [Medium] build gates, `test/integration/fiasco_reproducible_test.rb`: it is the
  test that builds the stopgap kernel twice and compares the results, and
  `make check` skips it as a standalone test, but no make target runs it,
  and `make check-reproducible` builds the kernel once and packs that one
  build twice. Give it a gate, or make `check-reproducible` rebuild the
  kernel.

## Security residuals

* [Medium] `liberx/system/dom_boot_view.c`, `boot_devices`: a give windows a device's whole register page, and the
  library checks a page's sharing only among the platform record's device rows, so a device the machine has on
  that page but the record does not list is reachable through the holder's window, with no manifest row giving
  it. On QEMU virt, `QemuPlan::Display` by default puts the virtio-keyboard and virtio-tablet on the gpu's page
  (`DISPLAY_TRANSPORTS`, buses .14 and .13), so a manifest that places the display unit gives the display
  domain both input devices unseen, each able to drive unconfined DMA; the `display_domain` suite moves them to
  the unplaced spare's page (`DisplayDomain::DISPLAY_BUSES`). Make the record's unit on QEMU virt the transport
  page, with every transport the board's tree has on it, so what a window reaches is what the unit lists by
  construction.
* [Medium] [The pixel area](docs/design-display.md#the-pixel-area), zero before reuse: an `erx_memdraw:wrap/4` image
  over a range is not tied to the range, so an image handed to a process that outlives the range's owner writes the
  range after its zero and after it is handed out again. The design takes same-client overlap as the client's own
  affair; either tie `wrap/4` over an area to a range `erx_pixels` issued or state the limit in the design.
* [Medium] `tools/lib/erx/chokepoint_rules/memdraw.rb`, `memdraw-pixels`: the rule names `erx_area:zero/3` as the
  area NIF's one writer, but its pattern (`bdata`, `byteaddr`, `wordaddr`) does not see a store through an area's
  `addr` or `erx_area_view`'s `base`; add a check that only `map_nif`, `zero_nif` and `erx_area_view` read them,
  with a seeded violation.
* [Low] `tools/lib/erx/area_mappers.rb`, C half: it catches a slip, not evasion. Not refused: a macro over
  `erx_vm_map` defined inside `erx_area_lease_map`, a redefined `ERX_CAP_SELF`, token pasting, a column-0 call
  `erx_area_lease_map(` that moves the body's start, C++ digit separators and raw strings that desync the literal
  blanker, and `.hpp`/`.inc` files, which it does not scan.

* [Medium] device NIF, virtio-gpu requests on an unconfined device
  ([design-runtime.md](docs/design-runtime.md#the-device-nif), Regions): the NIF writes the region entries a request
  names, but does not parse GPU commands, so a driver can still put any 64-bit address in a payload, as an
  `{out, Binary}` entry address or an overstated `nr_entries`, and the device will read it. On Phase 1's unconfined
  devices that reaches any memory; it closes with confinement, when the device's window bounds what it reads.
* [Medium] apps, the reset count ([design-apps.md](docs/design-apps.md#keeping-a-session)): the first session a
  start row keeps clears the count when it reports ready, which can come before its applications have done any
  work, so a system fault that follows every boot by a little never reaches the rescue configuration. Move the
  clearing to a point after the app has started, or after it has run a while, and test resets on both sides of it.
* [Medium] apps, `rc.conf` on the stopgap ([design-apps.md](docs/design-apps.md#phase-1)): `data` grants are not
  yet rooted by principal, so every domain holding `data` reaches the system domain's directory and can rewrite
  `start/rc.conf`, enabling or disabling declared rows and moving a display among rows whose templates are granted
  it. It cannot add a row or widen a grant. Closed by rooting each `data` grant at its principal's or service's
  directory, with the test that a session holding `data` finds no `start/rc.conf`.
* [Low] login at a display, the enrolment gap ([design-display.md](docs/design-display.md#risks-and-decisions), 14):
  a principal that a start row names, an app's or a person's, and that never enrolled can be enrolled by whoever
  first reaches a secure console line, as any principal can, and then logged in to with its authority. Settle it in
  the login design, which covers every place a person meets the system.
- [Low] session, a failed install into a running program (`erx_program_drv.c`, docs/design-pipes.md, "Hand-offs"): the copies the driver passed before the failure stay in the image unnamed until it ends. For a reply that fails, the ends are closed, so a hostile program that finds an unnamed `WRITE` copy of a closed write end's ring in its own table, as a failed `redeem` of a write end leaves, can append records that the pipe's readers, which read a gone writer's lane until it drains, take as data. Close the passed copies on failure if erXos's kernel gives a creator a close in a sub-space's table.
- [Low] program channel on the stopgap (`liberx/backend/fiasco/object.c`): the Fiasco backend records no rights per handle, so a program can map the session's lane side read-write. It can bind or unbind only IRQ objects it holds in its own group: it holds no handle to its channel doorbell, and `irq_group_allowed` refuses the session's doorbell, which is also the gate worker's IRQ for the program's port. A program also holds `TRIGGER` copies of its own pipe ends' doorbells, bound in its own group, and can rebind them to any label, label 1 included; that costs it only its own wakes. Any task can create IRQ objects up to the machine-wide 256 (`ERX_FIASCO_IRQS_MAX`) and starve every other domain's doorbells. erXos's kernel enforces the rights the install grants (`erx_program_core.c` `install_rights`).

* [Low] inspect service, the runtime agent leg ([design-live.md](docs/design-live.md#the-runtime-agent)): a
  domain's inspection agent takes questions one at a time, so a holder of scope `all` that asks without pause
  keeps the agents busy and another holder's runtime attributes read `{timeout, 500}`, and a domain can answer
  slowly on purpose to the same effect, so that a listing at scope `all` waits 500 ms for each stalled domain
  and ends `partial` at `inspect_query_max`. Development builds run trusted code only; settle it with the
  scheduling of service work on erXos's own kernel.
* [Medium] Web view scope, root's session through the host link's `web` facet
  (`erlang/apps/erx_web_line/src/erx_web_line.erl`, `export/2`; [design-web.md's
  Security](docs/design-web.md#security)): once the system domain exports root's session's line to the web
  domain, every view a browser opens reads at scope `all`, so a browser reaches the machine-wide paths
  (`/proc/kernel`, `/proc/cpus`, the kernel log, the machine record's `all` attributes), as the session's own
  `/proc` does: the system domain's query worker answers each of them through the session's inspect facet, at
  that facet's scope.
  Development builds run trusted code only. The wide scope is accepted; narrowing it to root's own
  domains, or removing it, changes design-live.md ("Scopes"), design-web.md (W1) and design-domains.md
  (property 9) with it, and needs a test that a browser's view of `/proc/kernel` ends `scope`. The line
  exports itself to Web when the system domain calls it with `{export, Web}`, and today only the host link's `web` facet
  sends one, for root's development session: the network login (`erx_web_login`) must not export its sessions'
  lines through the same call. Not yet consistent at `all` in a
  lines through the same call. The facet the session item under Bugs mints, taken by `erx:cap(inspect)`,
  is the better source of the scope; with it the line's own `scope` goes. Not yet consistent at `all` in a
  session's runtime: `[domains, 4, threads]` through `entries/2` is gated only on the domain, not on the runtime
  (`erx_inspector:collects_domain/2` covers `collect/2` alone), and `/proc/cpus` answers a partial empty
  listing where the stopgap refuses a task's `erx_object_info`, which `erx_kernel_records:listing/6` should
  answer `unsupported`.

* [Low] liberx Fiasco backend, `service.c` (`service_thread_handle`): the handle
  of a first thread created in another space is that task above the index (`task << 8 | index`),
  not a slot of the caller's handle table, so the erx_program driver's `erx_cap_close` of it at
  `ERX_PROGRAM_THREAD_CLOSE` names no slot of a table of up to 256 handles and closes nothing, and
  in a larger table could close an unrelated capability. On the stopgap only; erXos's kernel gives
  every thread a capability slot.
* [Medium] Host link, the web facet's casts (`erlang/apps/erx_hostlink/src/erx_hostlink_web.erl`,
  `erx_hostlink.erl`): each `{web, C, Bytes}` the web domain sends the facet becomes a `facet_cast` to the host
  link's process, which queues it for the host outside the output bound that holds back input (`OUTPUT_BACKLOG`),
  so a compromised web domain can grow the system domain's memory by sending faster than the host link drains
  (the facet's and the host link's queues have no heap limit), until the system domain runs out of memory,
  which resets the machine. Phase 1 runs trusted code only (M11). Count casts against the same output bound,
  dropping or ending the facet when it is full, with a host test that floods the facet.

* [Medium] Storage domain, littlefs's and the block driver's failures end the whole domain
  (`erx_lfs.erl`, `erx_lfs_sup.erl`, `erx_storage_sup.erl`, `erx_blk_sup.erl`): any end of
  littlefs's owner, worker or `/data` grant, and any end of the block driver's device or
  partition process, a malformed completion (a broken queue) included, ends the storage
  domain, the block driver and every window it serves with it, and after `restarts 5`
  within `restart_period_s 600` the domain stays down. The system domain and root's
  session reach `/data` through the `data` facet, so a client whose requests can end
  littlefs's owner or worker, or break the volume, six times in a minute takes down
  every partition's driver, not only `/data`. The facet's design bounds what a client can make the grant do (its own lane),
  or littlefs moves into a sub-space port whose end the domain survives
  (design-storage.md), which waits for track S's port driver (1b-B), so no build
  yet ends only a port on a littlefs crash. A device that fails six times in ten minutes
  keeps the domain down too.
* [Low] Domain service, a refused restart is not retried (`erx_domain_srv.erl`
  `start_configured/2`): a configured domain's restart that the library refuses, such as
  `no_memory` while more than one ended domain's outer budget still waits for its peer's
  disconnect (the system principal reserves one, `config/manifest/qemu-virt-development.txt`),
  is only logged, so the storage domain stays down and `/data` answers `eio` until the
  next boot. Retry it once the remains are disconnected, within its restart intensity.
* [Medium] Storage domain, file data in crash dumps (`erx_blk_window.erl`, `erx_blk.erl`,
  the `erx_fs` grant): a littlefs failure halts the storage node, whose crash dump goes to
  the domain's crash area (design-runtime.md). `erx_lfs`'s owner and worker are
  `sensitive`, so the dump shows no heap, stack or messages of theirs, but the windows,
  the block driver and the grant are not, and their heaps and queues can hold sectors of
  `/data`. Mark them sensitive, or keep file data out of the crash area, and test that a
  dump after a write holds none of its bytes.

* [Medium] Storage domain's write authority (`erlang/apps/erx_blk/src/erx_blk_service.erl`
  `serve/1`, `config/manifest/qemu-virt-development.txt`): the block driver starts a writable
  window on every partition role of the layout (record, `slot_a`, `slot_b`, vault, data)
  whatever the manifest's window rows say, so the storage domain, which holds the block unit
  and also runs the littlefs NIF over medium data, can rewrite the boot slots and the
  boot-selection record that the manifest gives the system domain (property 8) and the vault
  that PW1 gives only the vault's storage domain. A fault in that domain, say through a crafted
  littlefs image, could persist across reboots. Have the driver serve only the windows the
  domain library names for its own domain (data and the image), refusing slot, record and
  vault roles outside the slot writer's domain, with a test that a request for them fails.
* [Medium] Forged pids and `erx:owner/1` (erx.erl `owner/1`, erx_dist, the funnel): a pid's creation is a field its maker writes, while ERTS sends to a remote pid over the connection its node names, so a pid with domain A's creation and domain X's node passes an `erx:owner(Pid) =:= A` check and a send to it goes to X's connection, handing every local pid in the frame out to X (external.c's encoder) before X's funnel drops the frame as one to a dead name. erx_facet's caller check and the `erx:owner/1` doc's "a reply sent to a forged name goes to no third domain" rely on the creation alone. erx_domain_mints checks node and creation both. The fix by construction: the funnel refuses, at decode, a pid, reference or port whose node is a domain of this machine and whose creation is not that domain's, so `erx:owner/1` is authoritative for every caller; then the node check in erx_domain_mints can go.
* [Medium] Session tty input (erx_session_tty, erx_tty_link): each `{tty_input, Bytes}` is checked at 4 KiB, but what waits unread in the shell's group has no bound; a master that types faster than the session reads grows the session's heap. erx_tty's `input/2` bound (docs/design-live.md, "Between domains") closes it when the line discipline lands.
* [Low] Console line and terminal reports (erx_console.erl, erx_console_keys.erl): a terminal that reports text a session chose, such as xterm's title report where it is allowed, lets the session type anything at the line, `Ctrl-G` included, which no rule over the bytes can tell from typing. The menu drops the rest of the read that opened it and takes only one-byte reads, which stops a reply that arrives in one read; one the line driver splits into single bytes could still choose an entry, the system shell included. Settle it when logins come (M10): the system shell entry asks for the line's login again, or the host tool's console refuses terminal reports the session did not ask for. A terminal that sends 8-bit controls as raw bytes (0x9D, not U+009D written as UTF-8) is not recognized either, since such a byte is a UTF-8 continuation byte; recognizing it needs the rule to track UTF-8 lead bytes.
* [Medium] Console line and keyboard modes (erx_console.erl, erx_console_keys.erl): a session's output reaches the operator's terminal unchanged, so it can switch on the kitty keyboard protocol (`ESC [ > 1 u`), xterm's modifyOtherKeys level 2 (`ESC [ > 4 ; 2 m`) or keyboard lock (KAM, `ESC [ 2 h`), after which `Ctrl-G` arrives as `ESC [ 103 ; 5 u` or `ESC [ 27 ; 5 ; 103 ~`, or not at all, and the operator cannot reach the menu until they reset their terminal; `docs/design-live.md` says Ctrl-G always reaches it. Teach `erx_console_keys` those encodings of `Ctrl-G` (a terminal sends neither unasked), and have the console reset the terminal's keyboard modes whenever it takes the line from a session.
* [Medium] Console line after it comes back (erx_console.erl, `to_groups/2`): a session's output already sent to the line driver, up to 4 KiB, still reaches the line after `Ctrl-G`, `detach/0` or the session's end, after the console's notice, so it can draw a false prompt. Give the line back once the outstanding write is written, holding the groups' output until then.
* [Low] Console and lost-output lines (erx_console.erl, erx_tty_master.erl): each empty resend of a tty's next output logs one line under the system domain's own source, so a session that sends `{tty_output, Next, <<>>}` in a loop spends the system domain's 16 KiB/s log budget and drops its records. Charge the line to the session's source, or count losses in the master and log the count at most once an interval.
* [Medium] Console and a restarted relay (erx_console.erl, erx_tty_master.erl): `erx_session_sup` restarts `erx_session_tty`, whose numbering starts again at 0, so once the master has taken an output the new tty's first output fails the checks and the session is detached for good; `add_session/2` naming a new tty keeps the old master. Reset the master when the tty changes, with a test of a relay's crash.
* [Low] Facet limits in a create spec (erx_domain_srv.erl, `facet/1`): any positive `max_request` and `in_flight` are taken; every creator is a system-domain process, but nothing intersects them with a ceiling or the creator's own grant, as "attenuated for it" says.
* [Low] erx_console:terminal/0 (erx_console.erl): the domain's line is a persistent_term each console writes at start, so two consoles in one runtime see the last one, and a stopped session relay leaves its name behind. Deriving the terminal from the caller's group leader would remove the shared state.

* [High] Runtime, origins (edits 58-61 of design-runtime, design-domains D18): edit 16
  wraps every message from another domain, and `gen` and `io` take call and io replies
  in their envelopes, but nothing serves a request from another domain yet. `gen` and
  `io` take a reply with no check of its domain, since the call's reference, four
  unguessable words (edit 17), was handed only to the callee. What remains, in order:
  1. the io servers' request unwraps (edit 61), without which io from a process spawned
     into another domain waits forever;
  2. `file`'s `file_request` and `file_reply`, which neither edit 60 nor edit 61 covers:
     a positioned operation (`file:pread/3`, `pwrite/3`, `position/2`) on a file server
     of another domain waits forever for its reply, which arrives in its envelope. The
     design needs an edit for it;
  3. `{erx_serve, any}` (edit 59), with `erx:owner/1` to check a request's domain,
     without which no `gen_server` or `gen_statem` serves another domain;
  4. the tests of design-domains' "Origins" and hostile-runtime cases between two ERTS
     domains (a message to an alias arrives wrapped, which waits on aliases holding their
     exports; the served calls; `sys` on a `gen_statem`, a `gen_event` and a plain `sys`
     loop), and the oracle's differing cases recorded per case;
  5. the other stock protocols one ERTS domain speaks to another, which arrive wrapped
     and so go unanswered: net_kernel's `is_auth` call of `net_adm:ping/1` (it lands in
     `handle_info`, and the caller waits forever), `global`'s connect, lock and sync
     messages (`global:sync/0` and `register_name/2` stall on another domain's node),
     `peer`'s own `io_reply` receive and `proc_lib`'s start acks. Each needs its owner's
     unwrap, or a design note that it does not cross domains.
* [Low] Runtime, origins (`gen.erl` and `io.erl`, edits 58 and 60): a reply needs no
  check of its domain only while the call's reference reaches no third domain. A call
  with timeout `infinity` replies to the caller's pid with a plain monitor reference;
  a callee that logs or prints its `From` in full (a crash report, a log record) shows
  the four words to whoever reads that log, and a domain that holds `send` on the caller
  can then forge the reply. Print references short in records another domain reads, or
  check the reply's `D` against `erx:owner/1` of the callee.
* [Medium] Runtime, local decode of an echoed reference, `external.c` `dec_term` with no
  connection: a local `binary_to_term/1` promotes the words of a table or resource
  reference to the live table or resource, as stock does (design-runtime, "Representation
  and aliases"). A peer that was given a table id, or learned its words, can send them
  back inside a binary; local code that decodes that binary with `binary_to_term/1` then
  acts on the live table on the peer's behalf, a confused deputy. A service must not
  `binary_to_term/1` a binary another domain sent and then use a reference in it as a
  table or resource; nothing enforces that.

* [Medium] `tools/erx web --open`, [The host tool's front end](docs/design-web.md#the-host-tools-front-end): not
  built, because handing the URL to the host's opener (`open`, `xdg-open`) puts the token in an argument vector,
  which `ps` shows to every user of the host. A channel that keeps it off the command line is needed first, for
  example an owner-only file whose page forwards to the URL, opened by its path.

* [Medium] `display/memdraw/` and `display/libmemdraw/`, the shapes, G3: a shape's cost follows from its geometry,
  not from the pixels it writes, and every shape runs on the display domain's one pool of dirty CPU schedulers, so
  one client can delay every other's dirty work (composes included). A very thick, skinny ellipse is brushed with
  a disc of up to (2*2^10+1)^2 pixels at each of up to about 2^16 steps, minutes of one scheduler; a `p` of
  thickness 2^10 builds two 2049 by 2049 brushes a vertex; a disc end's brush (up to 2049 by 2049 bits) is
  allocated from the domain's heap and not charged to the window's quota. Bound the work a shape may do (steps
  times the brush's area, vertices times brushes) and refuse past it, or charge it to the window's grant; cache
  the brush in the thread's shape record.
* [Medium] erx_net TCP input (`erx_tcp_input:dropafterack`): an out-of-window segment that
  knows only the four-tuple draws an ACK with no rate limit, as in FreeBSD
  (`tcp_input.c:3384-3395`), so a blind sender gets one ACK per segment it sends. Decide
  whether these ACKs share the challenge-ACK limit (`erx_tcp:challenge_ack/3`); RFC 5961
  section 10 leaves it open.

* [Medium] network, `erlang/apps/erx_net/src/erx_lltable.erl` (`room/1`): a learnt sender takes
  only free room, but an on-link sender whose spoofed packets draw a reply (an echo request, a
  segment to a closed port) makes this host resolve each source through `lookup_or_create/3`,
  which evicts the oldest unresolved entry (the default router's pending resolution among them),
  else in ARP a resolved neighbour in use, since only an entry in `verify` is ever hinted. And
  with the table full of learnt entries, this host's own resolutions push each other out, and a
  reply arriving after its entry went is no longer learnt. Ranking published entries never used
  ahead of this host's unresolved ones when making room, and an `erx_nd6` regression test beside
  `erx_arp_tests:learnt_sender_evicts_nothing_test/0`, are the next step; the gain is mainly for
  IPv6, as an on-link attacker can already overwrite ARP entries.

* [Low] network, `erlang/apps/erx_net/src/erx_nd6_rtr.erl`: an on-link sender that passes the hop-limit
  rule and fills the prefix list first with 16 autonomous prefixes of infinite valid lifetime holds the list
  until reboot, since only an advertisement of the same prefix shortens its addresses' lifetimes; later
  prefixes are ignored and counted. The design accepts that the lists can be filled first (requirement N4);
  RA Guard on the switch or a per-sender share of the list would bound it.
* [Low] liberx, `liberx/backend/core/boot_info.c` (`node_valid`): a boot page's node name is checked only for
  no NUL and one `@` inside it. Every name today comes from the manifest's checked identifiers, so `uname -n` and
  anything else that shows a node's host write it unescaped; require both parts to be system identifiers here, so
  that holds whichever path builds the page.
* [Medium] network, `erx_net_if_core` and `erx_lltable` (`docs/design-network-stack.md`, Residuals,
  "Resolution is shared between clients"): a client sending to many unresolved on-link addresses makes the
  interface hold up to 16 packets for each and, once the neighbour table's 1,024 entries are full, evict
  other clients' entries in resolution; the sender credit bounds only the rate of hand-overs. Bound it per
  grant: tag each hand-over with its grant, count the entries each grant's packets started, and drop a
  grant's hand-overs past a cap as lost frames.
* [Medium] network, sockets (`erlang/apps/erx_net/src/erx_net_grant.erl`, `erx_net_bind`,
  `erx_net_input:udp/3`): a socket bound to a specific address and a port takes that address's
  datagrams from a socket another domain bound to `any` on the same port, since input tries the
  specific binding first and the bind asks nothing of who holds the wildcard one; FreeBSD's
  `in_pcbbind_setup` refuses such a bind with `EADDRINUSE` when the wildcard socket belongs to
  another user. And a grant opens any number of sockets, since `erx_net_grant_core`'s limits are not
  built, so one domain can hold every ephemeral port, or every ICMP echo identifier by repeated
  `icmp_open`. Refuse a specific bind over another grant's wildcard one, as FreeBSD does across
  users, and cap each grant's sockets with the grant's limits.
* [Medium] tests, the system_domain suite's 4-CPU cell under TCG on the second host
  (`tools/lib/erx/system_domain.rb`): under that host's load (load average about 25) the
  service-kill boot failed at `echo-facet` with the system's Erlang shell ended at 31 s: `group` called
  `shell:prompt_width/1`, which passed `{error, timeout}` from the terminal's options to
  `proplists:get_value/3` (function_clause), so the shell died under the long typed line. The cell
  passes under HVF. Make the shell take an options timeout (stock OTP's `shell.erl` has the same
  code, so check it against stock first).
* [Low] shell, `ping` (`erlang/apps/erx_shell/src/erx_cmd_ping.erl`): every session is root's, so ping
  takes `-s` up to 65507 and `-i` down to 1 ms for everyone. Once sessions have users, a non-root
  session gets FreeBSD's limits: `-s` at most 56 bytes and `-i` at least 1 s (ping.c's `uid` checks).

* [Medium] stopgap, Phase 1b's deferred guarantees: every guarantee the
  user-facing system on the stopgap rests on but does not get is a row of
  [What Phase 1 defers](docs/design-stopgap.md#what-phase-1-defers),
  with the milestone that closes it; that table is the one list. Those that
  untrusted input reaches: unconfined DMA (M9's kernel part, M11), where a
  device can write any page, so every driver domain (storage, network,
  display) is in the trusted base, beside the network domain's packet parsers
  and the display domain's draw clients, and no bounce buffer, software IOMMU
  or address filter is built in user mode; the network domain's CPU grant and
  per-interface ingress budget, which are records on the stopgap, so a flood
  from the wire can take CPU from other domains (M5's kernel part, M8); no wall around any domain, the browser-facing
  web domain included (M5's kernel part); and nothing stopping a domain or
  program that bypasses `liberx` (M5's kernel part, M7); and, on the
  Raspberry Pi 4 (1b-I), the boards' platform items: no hardware watchdog
  backs a hang of Fiasco, no crash region, no trial request, no device
  secret and no random generator (M12). Development
  builds run trusted code only until M11.

* [Medium] code service, atoms from loads (`erlang/apps/erx_code/src/erx_code.erl`):
  `activate/1` makes each manifest name an atom before ERTS's loader checks it
  against the module's bytes, so a load the loader refuses still leaves up to
  1,024 atoms of at most 255 bytes, with no bound across loads; a holder of the
  install facet can exhaust the system domain's atom table, sized by the
  manifest's `atoms` (65,536 in the development manifest), and reset the
  machine. A successful load also makes every atom of each module's atom table.
  The fix reads the module name from the blob's atom chunk with a bounded pure
  parser, with a fuzz target, and compares it as a binary before any atom is
  made; the install facet's holders can already run code in the system domain.

* [Low] shell and console, who may take the console: any process of the
  system domain may call `erx_console:run_shell/1`, which gives a group
  of its choosing the operator's keystrokes, or `erx_console:write/1`,
  which puts raw bytes on the line past `prim_tty`, the escaping and
  the hidden groups' policy (a command shell under another one still
  writes). Acceptable while development builds run trusted code only;
  tie both to the current group, and add a chokepoint check of
  `write/1`'s callers, before the security closure
  (`erlang/apps/erx/src/erx_console.erl`).

* [Medium] ABI, the manifest's image records (`abi/manifest.txt`): only the
  packer's Phase 1 check (`tools/lib/erx/manifest.rb`, `normalize_images`)
  holds an image record's rules; the generated C and Erlang readers check
  `format` and `hash_algorithm` each alone, so a malformed boot image can
  pair `erofs_verity` with hash algorithm `none` and zero tree fields, give
  `erofs_unchecked` a root hash, use format 2 in a release manifest, carry
  unsorted or overlapping extents, or a window whose `image` disagrees with
  its role. Express the format's rules as reader rules in
  `abi/manifest.txt`. The block service checks only what it serves
  (`erx_blk_image:place/2`): one extent of whole sectors inside the slot,
  as long as the image's data.
* [Low] storage, the slot's image area: the packer's extent check bounds an
  image by the whole slot, so an extent may cover the slot's FAT and
  bootable file; the images' start (128 MiB) and alignment (1 MiB) live in
  `ReleaseMedium` and prose, not in `abi/medium.txt`, where both the check
  and the medium writer should take them. The medium and the manifest also
  place the release image by two calls of `ReleaseMedium.image_extents`
  over the same list; keep the placed extents in `ProductionImage::Built`
  so there is one placement.

* [Medium] storage, `erx_verity` (Phase 1): the EROFS reader reads blocks
  unchecked until M11 adds the hash check inside `erx_verity:read/3`
  ([design-storage.md](docs/design-storage.md), E1), so a swapped medium or a
  flipped bit reaches the parser.
* [Medium] system domain, the reset count
  ([design-system.md](docs/design-system.md)): any successful login clears the
  count, including a web login, so a machine with a boot fault that lets
  the network come up can be kept out of rescue. Clear it only on a login at
  a secure line, or only after a login has lasted a while. Related: in a
  default release build no principal may open the system shell, so the
  rescue texts' "the operator can inspect the crash record"
  (design-system.md, design-platforms.md) holds only when the manifest names
  a system-shell principal; state that there.


* [Medium] display, layout work in `erx_screen`
  ([G3](docs/design-display.md#the-screen-and-its-one-path-to-the-device)):
  `erx_screen_core:layout/2` costs O(L^2 log L) for L window and decoration
  rectangles across every grant on the display, and runs in `erx_screen`, not
  in the client's window processes, so a client that moves its windows with
  `wctl` spends shared time that its grant does not bound. A weave of 64
  windows with four border rectangles each (about 4,300 tiles) costs about
  90 ms per move, 128 windows about 430 ms, 256 about 2 s (Homebrew OTP 28
  JIT on the Apple Silicon development host, 4096x4096 screen; an
  unrecorded spot measurement). `erx_screen` keeps only the newest pending
  layout, so layouts cost at most one per frame; cap the rectangles of a
  layout or charge them to the grant that placed them.
  `flush/4` also costs a window's visible tiles times its 16 dirty
  rectangles.

* [Low] `erlang/apps/erx_files/src/erx_fs.erl`: a grant takes an open file's answer `{erx_fs_file, Tag, Alias, Reply}` and an
  owner's `DOWN` by matching Erlang references, which a process that can guess one can forge (`list_to_ref/1` on the
  server's node, a crafted external term from a client node). A forged answer can only answer the client's own request
  in flight early, and a forged `DOWN` clunk a fid early. Bind both to the sender when erXos's kernel carries a
  sender with each message.

* [Low] scheduler and budgets, a group's charge
  ([per-CPU records](docs/design-scheduler.md#ownership-and-lifetime)): a group
  charges one `erx_group_cpu` record per CPU to its creator's budget, so a domain
  that creates groups and reads its spending through `erx_budget_watch` or a
  carved budget may learn roughly how many CPUs the machine has, which a grant
  read back does not tell it. When the records are written, charge every group
  for `ERX_CPUSET_BITS` records, or state that the count is not a secret.
* [Medium] scheduler, Track K and M11: request batches bound an interrupt's
  length, not how much of a remote CPU a sender consumes
  ([Concurrency](docs/design-scheduler.md#concurrency)). A runtime that
  posts wakes and refreshes in a loop spends another party's time on the
  home CPUs of its threads, charged to whoever runs there, and a configure of
  a group whose threads a hostile child created takes as long as those threads,
  on the parent's time. The stopgap accepts this. Charge the receiver's work to the requester's path, as the finishing
  share's approach to kills does.
* [Medium] Entropy generator's burn on the kernel's objects
  (`kernel/core/rng.c`, `test/host/rng_test.rb`): the residue test runs
  the host build, whose frames differ from the kernel's, and the stack
  proof holds only the depth, so a flag or compiler change that moves a
  frame's padding onto a message word in the kernel's objects goes
  unseen. Run the residue check on objects built with the core archive's
  flags, under QEMU or reassembled for the host. An assembly leaf that zeroes
  downward from the stack pointer would leave no padding to check and no
  frame cap to meet.
* [Low] Entropy generator's registers (`kernel/core/rng.c`): secrets stay
  in the registers a callee may change until they are overwritten, and an
  interrupt taken in kernel mode in that window saves them to the stack,
  below any burn. Reading them needs another kernel bug.
* [Medium] The kernel log has no reader gate on the stopgap (`erlang/apps/erx/src/erx_log_records.erl`,
  `liberx/backend/fiasco/service.c`): `erx_log_read` takes a resource with the `TRACE` right on erXos's kernel
  ([design-kernel.md](docs/design-kernel.md#console-log-and-panic)), but the Phase 1 service ignores it and reads
  for the root, so `[kernel, log]`, `/proc/kernel/log` and `dmesg` show every domain's log text to any caller
  whose inspect facet has scope `all`. Every such caller is root code today. A less-trusted session, once there
  is one, needs a policy gate on that path, as FreeBSD's `security.bsd.unprivileged_read_msgbuf` gates `dmesg`.
* [Medium] The kernel log's limit is per space, and the ring is shared
  (`kernel/core/log.c`, `erx_log_rate_t`): 16 KiB per second lets one space
  push every record, the kernel's included, out of the 64 KiB ring in about
  four seconds, N spaces in a fraction of that, and a domain that creates
  and ends sub-spaces gets a fresh allowance with each one. Nothing is lost
  silently, since a reader is told how many records it lost, but a space that
  floods and then ends never reports its own drop count. Charge the rate at
  the domain, a sub-space drawing on its parent's state, and show a space's
  count through inspection, when the kernel handler and spaces land.

* [Medium] Lane reader chokepoint, `lane-pages-reader` in
  `tools/lib/erx/chokepoint_rules/`: a text rule over the names of a
  lane's layouts, so untyped pointer arithmetic on a side's address (the
  public `peer_side` and `own_side` of `erx_lane_reader_t` and
  `erx_lane_writer_t`, or the mapping a runtime made) escapes it, as does a
  name a macro pastes together (`erx_lane_ ## hdr`), and inside
  `liberx/erx_lane.c` that only `erx_lane_take`'s path loads from the
  producer's side and only `erx_lane_put`'s from the consumer's is held by
  review.
  It reads a listed set of inherited trees (OTP, musl, the stopgap
  kernel), so a new in-tree import that runs in a domain, such as toybox,
  is outside it until listed; read every listed file less named
  exclusions instead. Close it by construction once the mapping calls
  exist: `erx_lane.c` maps a lane's sides itself, the reader record
  becomes opaque with a test-only constructor for a start position, and
  the syntax-tree leg checks loads.
* [Medium] The pipe's shared-page chokepoint, `pipe-pages-accessor` and
  `pipe-pages-raw-load` in `tools/lib/erx/chokepoint_rules/pipe.rb`: text
  rules over the pipe layouts' generated load accessors and the atomic
  load primitives. A plain dereference of a pointer into a pipe's page (a
  seq_cst load, since every generated field is `_Atomic`), a `memcpy`
  from one, and an atomic load in a liberx file outside the pipe's files,
  typed or not, escape them; the lock's compare-and-swap and the bit-set
  read-modify-writes on `owner`, `waiters` and `sleepers` read the page
  too and match no pattern, as design.md's row allows, so that they touch
  only those words is held by review, as is that only write ends call
  `erx_pipe_rpage_rpos_load` and only read ends `erx_lane_hdr_wpos_load`,
  and that no pipe file reads `wpos` through a relaxed `erx_shm_copy`. Close it
  with the lane reader's item: the syntax-tree leg checks every load whose
  address derives from a pipe end's mapping.
* [Medium] The pipe core's exploration (`test/fixtures/pipe_explore.c`)
  covers one write end with one or two read ends and two write ends with
  one read end. Still to come: three write ends with one read end, where
  the second look covers two lanes the first found empty (with one-byte
  records it did not finish in 25 minutes at -O2 on an Apple Silicon
  host, nor in 400 s with one read, so it needs a further reduction); the shapes with several
  write ends and several read ends at once; the co-readers' loss with
  bytes to read (`coread-lost` explores it with nothing written: with a
  byte, the loss report pending at each party keeps every step of the
  others in play, and the run did not finish in minutes); the bound of
  PI6, that another writer delays a record by at most two lanes'
  capacity, which the model's lengths never reach and no property
  checks; a merge shape with a read shorter than a record, so that a
  partly claimed record of one write end must beat a smaller key in
  another lane; a check at each landing of a reader's `rpos` or `cur`
  store that the reader holds the lock, which the reduction treating
  their loads as local assumes, and claims checked against the owner as
  the claimer sees it, its own buffered release included; renumbering
  the steps' private clock readings in `forget` instead of zeroing them,
  which holds only while the core reads them where it does now; the
  look's order, the clock read before the acquire copy of `wpos`, on
  which the mark rests: an acquire load does not hold an earlier counter
  read before it on AArch64, so `erx_clock_ns` as `liberx/program/pipe.c`
  calls it needs checking for the barrier, and a litmus test; and the instrumented
  `erx_shm_copy` that fails on a second read of one field in one step,
  which belongs to the effect layers that copy (`liberx/program/pipe*`,
  the pipe NIF), since the steps read no page.
* [High] pipes, PI6 and equal clock readings: the merge's argument
  ([design-pipes.md](docs/design-pipes.md#reading-and-merging)) needs a
  reading taken after a record's publication to exceed the stamp read
  before it. A nanosecond clock derived from a slower counter can return
  equal readings, and on equal keys the lower write end goes first, so a
  record written after another's publication can be read before it, a
  wrong order returned as a right one. The
  exploration's clock advances at every reading and never shows it.
  Decide whether the time page promises a strictly advancing reading
  across a publication, or the order key breaks such ties another way,
  and give the model a clock that may repeat a reading.
* [High] DMA platform evidence: the SMMUv3 specification and QEMU
  v11.1.2 source audit is recorded in
  [research-hardware-contracts.md](docs/research-hardware-contracts.md).
  Close each platform's outstanding evidence gate for loader/device and
  SMMU queue quiescence and drain, valid-abort and ATS rejection, completed
  invalidation visibility, failed-reset handling and stale-event retirement.
  Source inspection is not executable conformance evidence. Keep unknown
  handoffs and completions closed, a confined device's memory held until
  its window's invalidation completes and an unconfined device's for the
  boot, until the exact supported platform meets the contract
  ([design-platforms.md](docs/design-platforms.md),
  [plan.md](docs/plan.md#m11-security-closure)).
* [Medium] kernel, attributing asynchronous errors: on a board with PCIe,
  a device error caused by a posted write can be reported after the window
  that would attribute it, and then ends the wrong domain; one the
  processor reports as uncontainable panics the kernel. Use the
  processor's error records where it keeps them, and run an
  error-injection test on each board before drivers run on it. M12, which
  brings the boards, closes this or records the user's acceptance
  ([design-kernel.md](docs/design-kernel.md#interrupts-time-and-entropy)).
* [Low] platforms, QEMU `virt`'s fw-cfg device: check whether its node,
  `qemu,fw-cfg-mmio`, offers the DMA interface on the pinned QEMU. If it
  does, list it among the bus masters of the DMA contract; the system
  manifest gives it to no domain
  ([design-platforms.md](docs/design-platforms.md#dma)).
* [Medium] website, `site/index.html`: the page has no Content Security
  Policy. It loads scripts only from itself and jsDelivr (with
  Subresource Integrity) and styles and fonts from Google Fonts, so a
  `<meta http-equiv="Content-Security-Policy">` naming exactly those
  origins, `'wasm-unsafe-eval'` for v64's core and `worker-src` for its
  workers would bound what an injected script could load.
* [Low] website, `site/index.html` and `site/style.css`: the fonts load
  from Google Fonts, so every visit hands the visitor's address and the
  page's address to Google before any consent. Self-host Archivo and IBM
  Plex Mono (both SIL Open Font License 1.1) beside the page, fetched at a
  pinned version and hash like any other dependency.

Every other risk the design accepts is stated in its
[threat model](docs/design.md#threat-model) and in each subsystem
document's "residual risks accepted" paragraph.

* [Low] erx_net TCP ICMP and TIME-WAIT, inherited from FreeBSD: one forged too-big report
  that guesses a sequence number in flight (odds of the flight over 2^32) lowers the MSS for
  good, down to 216, and a sender stepping the MTU down by one byte per report forces a
  resend of the flight each time (RFC 5927 section 7 suggests further checks); a blind SYN
  with an older timestamp still recycles TIME-WAIT about half the time, as FreeBSD ORs
  RFC 6191's timestamp rule with the sequence rule; and a sender that knows the sequence
  numbers keeps TIME-WAIT alive with retransmitted FINs, within the grant's `time_wait`
  limit (`erx_tcp_icmp`, `erx_tcp_timewait`).

* [Medium] domains, the funnel (`liberx/erx_funnel.c`, `otp/erts/emulator/sys/erxos/erx_lane_drv.c`): until RT8
  adds the queue quota (design-runtime.md edit 15), the funnel delivers every authorised frame whatever the target
  process already holds queued, so a peer can grow any process's queue it can name without bound, and two domains
  that send toward each other in a cycle grow each other's queues with nothing to stop them. RT8's quota leaves the
  next frame in the lane at a process at its quota; the stopgap has no bound here. The lane driver's finish
  pauses there too, as at any time (design-runtime.md, "Connections in ERTS"); until the quota lands that clause
  of the finish has nothing to act on.
* [Low] domains, control records (`erlang/apps/erx_domain/src/erx_domain_links.erl`, the system
  domain's control writer): a domain that answers a record before reading it, such as
  `connection_unmapped` before its `connection_down`, lets the domain service send its next
  record while the earlier one is still in the domain's lane from the system domain, so that
  lane can hold more control records than its reserve, up to two per connection the domain
  holds. Only the liar's own lane is affected; the writer must then neither block the system
  domain nor drop a record, and its design has to show how.
* [Low] stopgap, entropy (`liberx/backend/fiasco/service_stubs.c`, `erx_entropy_read`, and the
  generator service it calls): the bytes of a read stay in the Fiasco UTCB message registers of
  the reading thread and of the service until a later message long enough overwrites those
  words (a read's own one-word request does not), in the CPU registers and stack spill slots
  the compiler used on both sides, which no erasure in C reaches, and wherever the service's
  code leaves them. liberx erases its stack copy and, after a failed read, the erXos UTCB;
  erXos's kernel puts the bytes in the reader's UTCB itself, so the UTCB and service copies
  go with Fiasco.
* [Low] network, the portable `erx_bytes:siphash24/2` (`erlang/apps/erx_net/c_src/erx_bytes_nif.c`):
  a key at a bit offset is copied by `enif_inspect_binary` into a temporary block that ERTS
  frees without erasing, and the NIF API offers neither a way to erase it nor one to read the
  key in place. erXos's BIF erases its copy. The key term itself, in the caller's heap, is no
  more erased than any Erlang term, so the fix belongs with how keys are held in Erlang.

* [Medium] Origins from other machines (edit 16 of design-runtime, `erx_fs_grant.erl`
  `decode/2` and `of_client/2`, gen_server's `{erx_serve, any}` check): an envelope's
  `D` is the creation of the distribution entry a message came on, and
  `erx_dist:owner/1` the creation a name carries, neither with its node name. A node
  of another machine connected to an exposed domain chooses its own creation in the
  handshake, so once a network carrier exists it can present a domain's id as `D`
  and in the names it builds, and an `erx_fs` grant for that domain admits its frames.
  Checking the node name beside the id does not close it, since such a node can build
  names at any node. Settle it before the network carrier lands: give envelopes from
  network entries a `D` no domain id can equal, and add the test that a remote node of
  creation equal to a client's id is refused at its grant.
* [Medium] File clients (`erx_file_remote.erl`, `collect/3`): an alias stays active
  until its reply arrives and the wait while the server lives has no deadline, so a
  server of another domain can hold a request open and send its alias, or the
  caller's pid it was handed as the owner, messages of any other shape without limit;
  they stay in the caller's mailbox, the code server's included, and each receive
  rescans them. Bound what a caller keeps from a server (a deadline, or dropping what
  arrives at the alias that is not its reply) with a test of a flooding server.
* [Medium] Namespace, a facet's mount (`erx_path:with_facets/2`, design-files.md, "A facet's
  mount"): every lookup under a facet's mount, `/data` among them, goes to whatever pid the
  domain's registry holds for the facet, which a server domain minted, so a server that stalls,
  floods or answers as no file server holds its clients as the two `erx_file_remote` items above
  describe. Deferred to Phase 2 with them, when domains other than trusted ones serve facets.
* [Medium] Namespace, raw and resolved tables (`prim_file:erx_mounts/0` and `erx_table/0`): only
  `erx_ns` may read the raw mounts and every resolution must read the resolved table, and nothing
  checks either; a resolution of the raw table meets `{facet, _, _}` and fails with `function_clause`
  in `erx_on/2`. Add a build check that only erx_ns.erl calls `erx_mounts/0`, as
  test/host/ns_writers_test.rb does for the term's writers, and a facet case in
  test/integration/prim_file_compare.erl through the real `prim_file`. `erx_table/0` also rebuilds
  the table's list at every lookup, facets or not; return it unchanged when it holds no facet. The
  `mount` command shows a facet as the grant it resolved to, or `ended`, never by its name.
* [Medium] erx_fs grant fuzz (`test/erlang/erx_fs_grant_fuzz.erl`): every sequence
  runs a grant for its own domain, and the model's "a reply goes only to the client's
  domain" is stated by node, so the funnel's path for another domain's client
  (`decode/2`'s envelope clause, `of_client/2` by id) has only the unit cases of
  `erx_fs_tests.erl`. Run part of the sequences with an integer client, its frames in
  its envelope and its names built with that creation.
* [Low] erx_fs grant client (`erx_fs_grant:new/1`): a grant whose `client` is the
  server's own domain id, not `own`, drops every frame, since its own domain's frames
  arrive bare; nothing refuses that option. Refuse it, or take it as `own`, in
  `erx_fs:init/2`.

## Planned features

* [Medium] `kernel/core/dt.c`, the DMA walk ([design-device-tree.md](docs/design-device-tree.md#the-reader),
  [design-kernel.md](docs/design-kernel.md#dma-and-the-iommu)): a level whose addresses take three cells, a PCI
  bus's, gives the device no DMA range, since the Devicetree Specification leaves those cells to the PCI bus
  binding (v0.4, section 2.4.4, p. 22). An unconfined PCIe function that needs DMA, the Pi 5's RP1 devices
  first, needs the binding read from its specification and the walk extended to its encoding, with a fixture of
  the BCM2711's and the BCM2712's bridge `dma-ranges`.
* [Medium] erx_domain boot order (`erlang/apps/erx_domain/src/erx_domain_srv.erl`, `handle_continue/2`;
  [design-system.md](docs/design-system.md#boot)): the domain service starts every configured domain at once
  in the manifest's boot order, so on one CPU the runtimes slow each other and the login waits for the slowest.
  Two rules of the boot-order proposal are deferred: (A) a start waits for the
  configured domains serving its `files` grants to settle, each bounded by its row's boot timeout, and (B)
  configured domains that no start needs are held until the boot is quiet. Measured under TCG on 1 CPU, once
  storage and network run on the interpreter, ordering gives 0.5 s to the prompt and 1.3 s to `/data`; on JIT
  images it gives 2.9 s (raw data: ~/erxos-history commit 34d0390, `boot-slow-2026-11-11`). Rule C, a session
  taking the console only with its namespace in place, is the design
  ([design-system.md](docs/design-system.md#a-session-takes-the-console)).
* [Medium] musl, `musl/arch/aarch64/bits/signal.h`, `abi/signals.txt`,
  `erlang/apps/erx_shell/src/erx_shell_jobs.erl`: give erXos's musl FreeBSD's signal numbers from the signal
  table of the ABI file ([design-programs.md](docs/design-programs.md#signal-numbers)). The table holds each
  signal's name, number and default action, and generates the `ERX_SIG` constants, `erx_sig_name`,
  `erx_sig_action` and `erx_sig_valid` in `erx/abi.h` and the Erlang `erx_abi_signals`; its numbers are compared
  with FreeBSD 15.1's `sys/sys/signal.h`. Today musl keeps Linux's
  numbers (`bits/signal.h`, `SIGSTOP` 19, `SIGCONT` 18, `SIGPWR` 30, `_NSIG` 65), its real-time range starts at
  35 (`musl/src/signal/sigrtmin.c`), and the shell's `?SIGNALS` writes
  FreeBSD's numbers by hand. The work: the table's descriptions (`sys_siglist`'s text) and number 34 as reserved,
  the comparison with the names of `sys_signame` in FreeBSD's `lib/libc/gen/siglist.c`, and musl's number header
  and set of valid signals generated from it; `erx_prog`, the protocol's grammar and the shell on
  `erx_abi_signals`; in musl, the
  generated header in place of the Linux block, `SIGRTMIN` 65 and `SIGRTMAX` 126 as constants, `_NSIG` 128,
  the generated predicate in `sigaddset`, `sigdelset`, `sigismember`, `sigaction` and `pthread_kill`,
  `sigfillset`'s generated set, `strsignal` on FreeBSD's text, `sysconf(_SC_RTSIG_MAX)` 62, and new
  `sig2str`, `str2sig`, `sys_signame`, `sys_siglist` and `sys_nsig`; the shell's table read from the generated
  one; the `difference` kind in `test/conformance/libc-test-verdicts.txt` and `tools/lib/erx/libc_test.rb`;
  the tests of design-programs.md's "Signal numbers" bullet. The package also carries the errno numbers as
  a table of the ABI file, and lands before the Track P ports.
* [Low] shell and programs, `Ctrl-T` (`SIGINFO`, [design-programs.md](docs/design-programs.md#the-terminal),
  [design-shell.md](docs/design-shell.md#ctrl-t-status-and-the-info-request)): the status line and the info
  request, right after the signal and errno table package, which gives `SIGINFO` its number.
* [Low] live inspection, `ps` and `top` ([design-live.md](docs/design-live.md)): the `time` and `pcpu` columns of an
  Erlang process show its reductions, labelled as reductions, instead of `-`; real CPU time per process comes
  later as an opt-in scheduler flag.
* [Low] shell, `ping` (`erlang/apps/erx_shell/src/erx_cmd_ping.erl`): it does not compare a reply's data
  with what it sent, so FreeBSD's `wrong data byte` report of a corrupted reply is missing; the
  checksum check in `erx_icmp4_wire` still drops a reply corrupted on the wire.
* [Low] shell, `ifconfig` (`erlang/apps/erx_shell/src/erx_cmd_ifconfig.erl`): it shows no `lo0`, since
  the stack runs no loopback interface process, and no `inet6` lines or `nd6` options: it
  writes only the IPv4 rows of `erx_net:interfaces/0`. Add `lo0` once a loopback interface
  process exists, and the IPv6 rows in FreeBSD's layout (`prefixlen`, `scopeid`).

* [Low] website, `site/terminal.js` (`FAULTS`, [site/README.md](site/README.md)): what the fault menu still lacks.
  It is tested under Node against a stand-in for v64's objects only: drive each entry in a browser, where the
  site's image reaches the shell, and check that it does under v64 at the development machine's RAM. RAM fail is disabled: v64's bus
  maps RAM as one region and `register_mmio` refuses a range over it, so it needs a change inside v64
  (a list of failed RAM ranges that `AddressSpace::lookup` in `src/rust/aarch64/bus.rs` checks before its RAM
  case, set by a new export that also bumps the bus generation and drops the range's compiled code, as
  `a64_bus_written` does). Clock jump is disabled until erXos reads a wall clock; CPU freeze stops v64's machine
  clock too, so erXos's time does not jump (advancing it would need v64's `MachineClock.set_time`, unchecked
  against its clamp). Make the power cut a new machine on the same disk buffer, and
  take the machine's end from v64's `cpu.powered_off()`: `session.repairs`, `pausing` and `rewatch` then go
  away, and the fault table no longer does lifecycle work. Once drivers run in their own domains (M9, 1b-E), the
  disk faults end only the driver's domain, and the menu's notes should say so.

* [Medium] website, `site/terminal.js` ([site/README.md](site/README.md)): the page's pure helpers
  (`site_url`, `read_bounded`, `fetch_checked`, `SparseDisk`, `make_disk`) have no test in the tree, since the
  script runs `init()` against `document` when it loads and the tree has no JavaScript test runner for the
  site. Moving them into a module that Node can import, with a test beside `test/host/site_test.rb`, needs the
  language question settled first (CLAUDE.md lists TypeScript for the web client only).

* [Low] website, `site/index.html`: a `Content-Security-Policy` meta tag (`connect-src 'self'`, `script-src
  'self' https://cdn.jsdelivr.net 'wasm-unsafe-eval'`, styles and fonts likewise) would make "the machine's
  files come only from the page's origin" hold for v64's own fetches too, not only for the names `site_url`
  checks. GitHub Pages sets no headers, so it has to be the meta tag. `connect-src` also bounds the guest's
  HTTP, which v64's fake router turns into the page's own `fetch()` calls
  ([site/README.md](site/README.md#the-network)): `'self'` alone lets the guest reach only the site.

* [Low] website, `site/terminal.js` ([site/README.md](site/README.md#the-network)): nothing in the tree boots
  the site's machine. A check that loads a built `build/site` under Node, starts v64 with the page's own
  settings (`virtio_disks`, `NET_DEVICE`) and waits for the guest's DHCP lease from the fake router, its
  gratuitous ARP and an echo reply, would catch a v64 or driver change that the placement test cannot; it
  needs the built image and v64, so it belongs at the milestone gate.

* [Medium] hosted backend, `liberx/backend/hosted/` ([design-stopgap.md](docs/design-stopgap.md#the-hosted-backend),
  [plan.md](docs/plan.md#track-h-hosted-mode)): the multi-process form, in which each space other than the
  first is a macOS process, so domains, connections and sessions run under the sanitizers and E-D1 can be
  measured between hosted domains. It waits until the Fiasco backend's rows between tasks have settled;
  until then the hosted backend is one process with the rows 1b-A needs where they are cheap. Its design
  is written and reviewed before its code.

* [Medium] network, the effect layer ([design-network-stack.md](docs/design-network-stack.md#the-effect-layer)):
  the pure core is in `erlang/apps/erx_net/src`; the effect layer is not
  written. In order, host first: `erx_net_credit`, `erx_net_clock`,
  `erx_net_if_core`, `erx_net_driver` with `erx_net_pipe` and
  `erx_net_loop`, `erx_net_runtime` with `erx_net_local`, the processes,
  then `erx_net_vclock`, `erx_net_script`, `erx_net_impair` and
  `erx_net_relay` in the app's `test/`; `erx_virtio_net` and `erx_net_erxos`, which run in the
  network domain. Three things to confirm on
  the FreeBSD test host before its runs: that the test user can open `/dev/tapN` (a devfs rule) and
  the tap comes up on open (`net.link.tap.up_on_open`), that the bridge
  can put two jails behind separate tap devices for the relay's FreeBSD
  baseline, and that a stock OTP 29.1.2 builds there for the stack's
  host runs (29.1.1 is installed).
* [Low] network, the checks of `erx_bytes:inet_csum/2`'s starting sum, `siphash24/2`'s key and
  `inet_csum_update/3`'s binaries are written twice in C, in erXos's BIFs
  (`otp/erts/emulator/nifs/erxos/erx_bytes_bif.c`) and in the portable NIFs
  (`erlang/apps/erx_net/c_src/erx_bytes_nif.c`); the iodata walk has one copy. The shared probe
  (`test/fixtures/erx_net_bytes_probe.erl`) judges both, but a check its contract cases do not
  cover could make the builds disagree. Give the scalar checks one copy as pure helpers in
  `c_src` that both term layers call.
* [Medium] network, `erx_net` as a package of its own (N12 of
  [design-network-stack.md](docs/design-network-stack.md#requirements)):
  lay `erlang/apps/erx_net` out by seam (`src/`, `erxos/`, `portable/`,
  `c_src/`, `test/`); move the stack's tests, fuzz targets and explorer
  from `test/erlang`, and the harnesses of `c_src/`'s cores from
  `test/fixtures`, into the app's `test/`, runnable on stock OTP from the
  app alone; drop `erx` from `erx_net.app.src`'s applications; put erXos's licence notice beside `NOTICE-freebsd`; create
  `erlang/apps/erx_net_client`; and add the build check of N12, which
  covers `c_src/`'s `#include` lines too, with its seeded violation.
* [Low] upstream OTP, `erlc` (stock OTP 29.1.2, the oracle's): run from a directory whose
  path is a string prefix of a source's absolute path without being its parent, it strips
  that prefix and fails: from `/Users/stas/erxos`, `erlc -o /tmp/x
  /Users/stas/erxos-scratch/a.erl` reports `-scratch/a.erl: no such file or directory`. The
  prefix test is `shorten_filename/1` in `otp/lib/compiler/src/compile.erl`: it keeps the rest
  of the name when that rest does not start with `/`, where it should keep the whole name. Fix
  it in the tree's copy with a test, and report it upstream.
* [Low] upstream OTP, `otp/erts/emulator/beam/bif.c` (`list_to_ref_1`): report to OTP that in
  stock OTP 29.1.2 `list_to_ref/1` of a text whose six numbers each end in `.` (`"#Ref<4.1.2.3.4.5.>"`) leaves its
  parse loop with `i` at 6, so the copy into `refn` reads `ints[6]` past its six entries and writes `refn[5]` past
  its five: a stack overflow on any text a caller passes. erXos's copy refuses it with `badarg`. Send it with a
  reproduction run against stock OTP.
* [Low] upstream OTP, `otp/lib/kernel/src/inet_dns.erl` (`decode_data/3`): report to OTP that in stock OTP 29.1.2 a DNS reply carrying a record of type UINFO, UID, GID or UNSPEC (100 to
  103), IXFR, AXFR, MAILB, MAILA or ANY (251 to 255), or an A, AAAA or WKS record of a class other than IN,
  fails `inet_dns:decode/1` with `function_clause`, since those types map to atoms that no clause of
  `decode_data/3` names and its last clause takes only an integer type; `inet_res`'s `decode_reply` does not
  catch it, so a forged reply crashes the resolver's caller. erXos keeps their data raw (edit 62);
  `test/erlang/erx_net_resolver_fuzz.erl`'s `dns` target found it. Send it with a reproduction run against
  stock OTP.
* [Medium] network, name resolution (`erlang/apps/erx_net/src/erx_net_if_core.erl`, `erx_net_grant`): the
  grant's `resolver` answer holds only what DHCP leases gave. Add static name servers and a search list to an
  interface's configuration, as rc.conf's resolver settings and `resolvconf` give FreeBSD, merged ahead of
  the leases' within the same limits, and router advertisements' RDNSS and DNSSL (RFC 8106) once IPv6's
  configuration runs.
* [Low] network, `erx_gen_udp` and `erx_gen_tcp` (`erlang/apps/erx_net_client/src`): where stock OTP 29.1.2
  takes `{ip, any}` and `{ip, loopback}` as a local address, the backends pass them to the socket's options,
  which refuse them with `einval`; and an IPv6 address given to `connect` or `send` on an IPv4 socket answers
  `einval` where stock answers `eafnosupport`. Take both local forms and answer `eafnosupport`, with a case
  each against stock's answers.
* [Low] network, `erx_gen_udp` (`erlang/apps/erx_net_client/src/erx_gen_udp.erl`): stock `inet` and
  `gen_udp` dispatch `setopts/2`, `getopts/2`, `peername/1` and `send/5` to the backend, which exports none
  of them, so `inet:setopts(S, [{active, once}])` on an `erx` socket raises `undef` in the caller, and
  `send/3` with a sockaddr map raises `function_clause`. Answer `{error, enotsup}` as
  `controlling_process/2` does, and `einval` for `send/3`'s other shapes, with a case each.
* [Low] network, edit 63 (`otp/lib/kernel/src/inet_db.erl`, `erx_rand_range/1`): `error:undef` stands for
  "stock OTP", so an erXos node whose `erx_bytes` failed its `on_load` would go back to the counter's
  guessable query IDs silently. Decide erXos by `os:type() =:= {unix, erxos}`, as `inet_config.erl` does,
  and raise on erXos for `undef` as for any failed read.
* [Low] network, `erx_udp_sock` (`erlang/apps/erx_net/src/erx_udp_sock.erl`, `from_peer/2`): an ICMP report
  passes the connected socket's peer filter and holds receive credit until a `recv` drops it, so a host that
  knows the port can fill the socket's 64 units between queries; drop reports on arrival, since the socket
  never delivers them.
* [Low] network, name resolution (`erlang/apps/erx_net_client/src/erx_inet.erl`): `erx_net_client` starts the
  resolver loader on every node that runs it, a node outside erXos beside erx_net included, where it empties
  `resolv_conf` and replaces the host's name servers with the stack's leases'. Start the loader only where
  the grant is the node's resolver: on erXos, or where an `erx_net_client` key asks for it.
* [Low] shell, `host` (`erlang/apps/erx_shell/src/erx_cmd_host.erl`, `search/4`): a candidate whose A query
  answers no records (NODATA) ends the search, where `res_search(3)` notes it and tries the rest of the
  search list, answering NODATA only when no candidate has the name. Go on past NODATA as `res_search`
  does, with a case for a search list whose first domain has the name without an address.
* [Medium] network, edit 54's rest (`otp/lib/kernel/src/inet.erl`,
  [design-runtime.md](docs/design-runtime.md)): `inet:getifaddrs/0` and `inet:gethostname/0` take the
  `inet` backend's path, which `inet_backend/0` maps `erx` to, and answer from ERTS's own calls rather than
  ask the domain's network grant. Add the grant operations and the `erx` clauses, with tests on the host.
* [Medium] network, `erx_gen_tcp:listen/2`: it answers `{error, enotsup}`, since the grant opens no
  listening socket, so `gen_tcp:listen/2` fails on erXos. Add the grant's listen and accept operations
  over the stack's listener and `erx_gen_tcp:accept/1,2`, with the same tests as active open.
* [Low] shell, `host` (`erlang/apps/erx_shell/src/erx_cmd_host.erl`): FreeBSD's host(1) also asks for MX
  records and writes `name mail is handled by N exchange.`; erXos's asks only A, AAAA and PTR. Add the MX
  query and its line, with a case in `test/erlang/erx_cmd_host_tests.erl`.
* [Low] network, `erlang/apps/erx_net/NOTICE-freebsd` and `erx_net_frame`'s header: they
  name `arpresolve_addr` of `sys/netinet/if_ether.c`, which neither the release nor the pin
  has; the broadcast and multicast link addresses `link_addr/2` translates are
  `ether_resolve_addr` of `sys/net/if_ethersubr.c` with the `ETHER_MAP_*` macros of
  `sys/netinet/if_ether.h`. Fix the entry and the module's FreeBSD headers to match.
* [Low] network, the interface's own frames on transmit
  ([design-network-stack.md](docs/design-network-stack.md#residuals)):
  ARP and neighbour-discovery answers, RSTs and SYN-ACKs share the
  driver's transmit credit with clients' data, so a sender that keeps it
  full delays resolution and handshakes. A small share of the credit
  reserved for the interface's own frames would bound it.
* [Low] docs, the FreeBSD guest: [plan.md](docs/plan.md) (the network
  stage, "packetdrill tests and a FreeBSD guest" and "in a FreeBSD 15.1
  guest") still names a FreeBSD guest for the network stack, whose
  oracle is the FreeBSD test host; and
  [design-shell.md](docs/design-shell.md)'s oracle cases link the
  FreeBSD 15.1 oracle guest to design-network-stack.md, which no longer
  has one. Point plan.md at the test host, and either link the shell's
  guest to design.md's dependency row or move the shell's oracle to the
  test host.
* [Medium] network, `docs/design-network-stack.md`: the design does not yet
  settle sockets with several holders, which [design.md](docs/design.md#networking)
  leaves to it; settle them before the POSIX socket protocol's code.
* [Low] live, the `trace/1` shortcut ([design-live.md](docs/design-live.md#erlang-in-every-domain)): the
  shell resolves each call in a function defined at the prompt by name alone (`shell.erl` `reconstruct1/3`,
  through `edlin_expand:shell_default_or_bif/1`), and argument completion does too (`edlin_context`), so an
  exported `trace/1` would make `trace(P, true, [send])` there call `shell_default:trace/3` instead of
  `erlang:trace/3`. Resolve by name and arity in both (an OTP edit for design-runtime's table), then add
  `trace/1` to `shell_default` and move it from `?PENDING` to `?SHORTCUTS` in
  `test/erlang/erx_shortcut_tests.erl`, whose `shell_name_resolves_like_stock_test` then checks resolution by
  name and arity instead of by name.

* [Medium] tracer, `erx:trace` ([design-live.md](docs/design-live.md#tracing),
  [design-stopgap.md](docs/design-stopgap.md#the-trace-ring)), in four packages. P1's remainder:
  a test that the
  park core's `trace` effect writes one `park` and one `wake` per sleeping park, none for one that
  returns at once, with the returned status (`test/fixtures/fiasco_park_driver.c`'s is a no-op);
  and the hosted ring through the function API. P2's remainder: `erx_tracer:erts/5` takes the
  system domain's own trace messages, which `erx_trace:classify/2` checks for shape, so P4's
  relay records need their own validation before they reach it; the BIF's 32 KiB buffer comes
  from `erts_alloc`, which ends the VM when memory runs out, where `erts_alloc_fnf` and
  `{error, nomem}` would not; and the generated `erx_status_name` table is sized by the most
  negative status, so a sparse status would need a bound in the model or a switch. P3's
  remainder: the `native_trace` suite's test task started and stopped, with its `space_start`
  and `space_end`; the merger's `unsupported` and `error` entries go out at once without moving
  its latest sent time, so a held entry with an earlier time prints after them unmarked
  (`erx_tracer:ring/4`); the kernel rings are counted from ERTS's `logical_processors`, which
  falls back to one CPU when unknown and on erXos's kernel may disagree with the kernel's
  count, where `liberx` or the boot information should give it; a well-formed `trace_ts`
  tuple any system-domain process sends the trace process is shown as the runtime's event,
  and the alias that is a trace's reference is its stop authority, though a reference can be
  forged inside a node, which both matter once a trace's receiver or caller is in another
  domain (P4); ERTS delivers session messages without flow control, so a session over many
  busy processes on several schedulers can outpace the one trace process, which its
  `max_heap_size` then kills, ending the trace with `killed`, rather than discarding the
  excess; and `check/3` and the session message's shape need fuzz
  targets once Specs and relayed records come from other domains. The window's review left
  these open: a forged far-future `trace_ts` is held until it is 100 ms older than the
  clock, so it ends the trace only through the heap bound; the merger's `lists:merge` over
  the held list after every read belongs on the performance watch list; a forged
  `{erx_trace_ack, Ref}` can open a stuck receiver's window, and since ERTS stamps no
  sender on a message, only an acknowledgement alias given to the receiver alone would tie
  it to the receiver (P4); a trace that ends after a stop before the printer first ran
  leaves the printer a `noproc` it ignores, so a fault in that window prints no failure
  line; the trace process's 2 Mi-word heap bound is an estimate: measure a heavy trace's
  peak with `kill => false` and size it from that, or bound the held list by count into
  the window's counters, and measure the cost of its on-heap mailbox's lock under many
  senders; `{erx_untraced, true}` rests on every ungated reader of a tracer ref's flags
  using `ERTS_IS_P_TRACE_HIDDEN`, not `ERTS_IS_PROC_SENSITIVE`, which a chokepoint check
  listing the allowed `ERTS_IS_PROC_SENSITIVE` sites would enforce; a kill of the trace
  process during its start raises in the caller of `start/3` instead of returning an
  error; `expect()`'s `session` boolean shares a name with the session handle; and
  `park_then_wake?` mutates a set inside `any?`. P4 (the trace facet served across domains,
  the relay, frame tracing and trace records on the host link's events stream) lands with
  M5's kernel part ([plan.md](docs/plan.md#m5-a-wall-around-some-processes)); until then the
  trace view of track D's part 1 (1b-C) traces its session's own domain.
* [Medium] code service, installed storage (`erlang/apps/erx_code/src/erx_code.erl`):
  the install arena, `erx_code:install_beam/2` and the runtime's
  `ERX_BOOT_INSTALLED_ONLY` refusal with `{error, not_installed}`
  ([design-runtime.md](docs/design-runtime.md#code-in-the-system-domain), V5 of
  [design-live.md](docs/design-live.md#invariants)) wait for M5, where the flag
  first takes effect. Until then `erx_code` loads the verified bytes from its own
  heap with `code:prepare_loading/1` and `code:finish_loading/1`, and any code in
  the system domain can still load bytes with `code:load_binary/3`. One package
  lands them together, tested in medium_boot: setting the flag alone would refuse
  `erx_code`'s own loads, the harness's probes (`code:load_binary` in
  `test/integration/runtime_literal_token_test.rb`, `prim_file_compare.erl`,
  `runtime_hosted_smoke_test.rb`, `tools/lib/erx/bench_guest.rb`,
  `production_image.rb`), which must go through the install facet, and even release
  code, since `prim_file`'s `read_file` copies a release file to the heap
  (`erx_prim_file.c`, `erx_copy_out`) instead of returning a binary over the mapped
  slice; the refusal itself goes in `erts_internal_prepare_loading_2`. The
  chokepoint check that only `erx_code` calls `install_beam/2` lands with it.
* [Medium] code service, other domains and principals
  (`erlang/apps/erx_code/src/erx_code_store.erl`): the store is one in-memory
  store for the system domain's installs. Per-principal hot stores in memory
  objects from the principal's budget, code facets and the code server's fetch
  of pieces into other domains, overlays per supervised specification with
  their revisions and release hash, overlays persisted on the data partition
  and the bounded decoder of what is read back, with its fuzz target, are not
  built ([design-live.md](docs/design-live.md#code-from-the-host)). The host
  link and `root`'s session share the one store, so one holder's uploads can
  drop or free the other's.
* [Low] code service, load timeout (`erlang/apps/erx_code/src/erx_code.erl`): a
  caller of `erx_code:call/1` waits 60 s; a load still running then goes on and
  may finish, while the caller exits with a timeout. The install facet must
  report such a call's outcome as unknown, not as failed.
* [Low] code service, scope (`erlang/apps/erx_code/src/erx_code.erl`):
  `erx_code:history/2` checks no inspect facet: any caller in the system domain
  reads the system domain's history, and every other domain id answers
  `{error, scope}`. It goes through the caller's inspect facet once facets
  exist.
* [Low] code service, start (`erlang/apps/erx_code/src/erx_code_app.erl`): the
  release starts `erx_code` as an application, so every runtime that boots the
  system release runs one; it belongs to the system release's supervisor
  ([design-system.md](docs/design-system.md#system-services)) once ordinary
  domains boot releases of their own.

* [Medium] storage, the release medium for QEMU (`tools/lib/erx/medium_image.rb`,
  `tools/erx pack --medium`): its slots and the boot-selection record's
  partition hold no FAT: the bootable file lies at `medium_slot_boot_start`
  after 4 MiB of zeros, where
  [design-platforms.md](docs/design-platforms.md#slots-and-the-boot-selection-record)
  places it inside the FAT's file; and the record partition holds the
  record's sector (`BootRecord.sector`) without the FAT whose
  `autoboot.txt` file is that sector, which the Raspberry Pi's firmware
  needs and nothing on QEMU reads. The EROFS image in the slot holds a copy
  of the whole system release, its manifest excepted, which no domain
  mounts while the storage domain holds the block unit (next item), and the boot
  image holds the release too, from which the system domain starts, until
  the boot from the medium decides which releases leave the boot image
  ([design-storage.md](docs/design-storage.md#data-model)).
* [Medium] Raspberry Pi card (`tools/lib/erx/pi_medium.rb`, `boot_partition.rb`, `site.rb`): the data volume is formatted for `PiMedium.data_sectors` by the
  caller and nothing ties its length to the card's partition; the finished card is not read back through
  `BootRecord.read` and `extract`; `release.erofs` and `data.lfs` are not scanned for the build path (the EROFS
  files are, through `image.boot`); an oversized `kernel8.img` fails in fsimg rather than with a diagnostic;
  `FatVolume::Layout` keeps a root offset and a root cluster for both FAT types where each means something for one.
* [Medium] storage, the reset count's encoding (`abi/medium.txt`, `tools/lib/erx/pi_medium.rb`): no encoding of the
  count is defined, so the Pi card's writer leaves its sector the zeros fsimg writes in the reserved area instead of
  the count's first value (design-platforms.md, "Slots and the boot-selection record"), as the QEMU medium does.
  Define the encodings in the layout file when M12 builds the count, preferably with an all-zero sector reading as
  zero so a fresh medium needs no write, and have both medium writers write the first value.
* [Low] Raspberry Pi boot, residual: a damaged record partition, or a slot without valid boot files, lets the
  bootloader's `PARTITION_WALK` boot a partition the record does not name, or leaves the card unbootable until it is
  reinstalled, as the external design review reads the bootloader documentation
  (https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#PARTITION_WALK), not yet checked. The board pass
  records the board's EEPROM configuration (`BOOT_ORDER`, `PARTITION_WALK`) and what a card with a damaged record
  partition boots.
* [Low] storage, the release image across domains (`liberx/system/dom_apply.c`,
  `erlang/apps/erx_blk/src/erx_blk_service.erl`, `erx_blk_image.erl`): with the block
  unit held by the storage domain, no image window is served
  ([design-stopgap.md](docs/design-stopgap.md#image-windows)): the storage domain's
  namespace holds no manifest, and `erx_blk_image` picks only windows the system domain
  holds. Nothing outside tests reads `/images/release` yet. When a reader appears, have
  the domain library write each image window's placement (image name, format, extent)
  into the holder's boot page beside `-erx boot`, and have `erx_blk_image` read those
  words instead of the manifest file.
* [Low] storage, log lines at every boot (`erlang/apps/erx_blk/src/erx_blk_service.erl`
  `image_windows/0`, `mount_images/0`): in the storage domain the driver logs that the manifest
  cannot be read and that no image is served or mounted on every normal boot, which reads as an
  error. Skip the manifest read outside the system domain, or log it once as information,
  until the image placement reaches the holder's boot page (the release image item above).
* [Low] storage, slot windows (`config/manifest/qemu-virt-development.txt`,
  `tools/lib/erx/manifest.rb` property 8): the four slot-writer windows (`slot_a`,
  `slot_b`, `boot_selection`, `reset_count`) are held by the system domain, as property
  8 requires of the slot writer, but their driver runs in the storage domain and no
  grant carries slot writes from the storage domain to the system domain, so the rows
  describe a grant nothing implements. The slot writer needs that grant (a facet of the
  storage domain's driver, or the device service's window grants, PW1) before it writes.
* [Low] storage, image windows (`erlang/apps/erx_blk/src/erx_blk_service.erl`):
  a restart of the block service starts new windows, but the image mounts
  made at boot (`mount_images/0`, a supervisor child that runs once) are not
  made again, so `/images/NAME` answers `eio` until the next boot.
* [Medium] storage, window rights (`erlang/apps/erx_blk/src/erx_blk_window.erl`):
  a window is read-only because its role is `{image, _}`, not because it
  carries the manifest window's `rights`; the slot windows over the same
  sectors stay writable for any caller in the system domain. Carry `ro | rw`
  from the manifest in the window and let a write require `rw`, so read-only
  holds by construction (PW1's grants bring the per-client half).
* [Low] storage, image names (`erx_blk_image:windows/2`): two images of one
  name would start two windows of which the service keeps one; refuse the
  second by name, or let the manifest's reader refuse duplicate image names.

* [Low] storage, the boot-selection record (`abi/medium.txt`): the record and
  the reset count each have a MiB of their own, the layout's alignment taken as
  the erase unit; SD cards commonly erase 4 MiB, under which the record
  partition's FAT, the record and the count share one unit, against the
  isolation of [design-storage.md](docs/design-storage.md#system-updates).
  Measure or look up the boards' cards before the slot writer writes the count
  at every boot; the reset count's own encoding is undefined until then too.

* [High] logging: a central system log service that every source writes
  to, with routing to the UART and other readers and per-reader access,
  needs its design; it replaces the console's role as the kernel log's
  reader and decides which log lines each console line shows, the UART's
  and the host link's
  ([design-live.md](docs/design-live.md#the-console)).
* [Medium] console, log lines at console lines: until the log design
  settles routing, state in
  [design-live.md](docs/design-live.md#the-console) the access rule it
  must keep, that a line shows only log lines of domains its principal
  may inspect, and reconcile the **Logs** bullet, which still makes
  `erx_console` the sink, with design-kernel's log service.
* [Medium] console, leftovers of the one-line model: the overview
  diagram and the paragraph after it in
  [design-live.md](docs/design-live.md#overview) describe one serial
  console; the host tool reads `[kernel, crash]`, which only the system
  shell's facet reaches, so either the host link gets its own crash
  reading grant or the tool reads it through the system shell; and the
  system-shell facet, which only the console and the system shell hold,
  may read more simply as the console's per-line login record.
* [Low] console, residuals to state: processes the system shell starts
  are system-domain processes and outlive its login; a development
  manifest does not have to mark the UART secure, though development
  builds assume it; host-link login failures count in the UART's class
  and can lock a name out there
  ([design-live.md](docs/design-live.md#security)).
* [Low] console, moving a session: an explicit detach and attach, as
  screen and tmux offer, run by the session's own user, so a terminal
  can move from one console line to another; connecting a terminal
  already connected at another line is refused
  ([design-live.md](docs/design-live.md#the-console)).
* [Low] display, plan9port compatibility: check against plan9port's source
  that acme and sam allocate no screens and reach the screen image only
  through `libdraw`'s `getwindow`, as
  [design-display.md](docs/design-display.md#compatibility-and-migration)
  assumes.

* [Low] POSIX-lite personality, `sysctl(3)` and `sysctl(8)`: build them
  when a ported FreeBSD program first needs them, as a reader of
  `/proc/status` through the program's own namespace that maps
  `hw.ncpu`, `hw.physmem`, `hw.pagesize`, `kern.boottime` and the names
  that program asks for onto the inspector's attributes and answers
  `ENOENT` for a value that is not `ok`; read-only, with no `sysctl`
  facility behind it
  ([design-live.md](docs/design-live.md#system-values-one-tree-many-views)),
  and listed in the C library seam's table of
  [design-runtime.md](docs/design-runtime.md#the-c-library-seam).
* [Low] POSIX-lite personality, FreeBSD programs: survey what FreeBSD
  programs ported at the source level need beyond the planned layer
  (BSD libc extensions, `sysctl`, `kqueue` and the like) and which of
  them the layer should offer; programs brought in come from FreeBSD or
  are BSD-licensed where possible (CLAUDE.md, principle 5;
  [design-programs.md](docs/design-programs.md#the-posix-lite-personality)).
* [Medium] shell, the rc oracle's corpus: import Byron Rakitzis's `trip.rc`
  (zlib, `github.com/rakitzis/rc`, SHA-256 in
  [research-boards-storage.md](docs/research-boards-storage.md#the-command-shells-oracle))
  beside plan9port's `test.rc` in `test/shell/rc/`, pinned like any
  source, with the cases for that implementation's extensions set apart;
  build toybox for the host and put it first in the oracle's `$path`; and
  compare the Erlang shell with `Erx::RcOracle` script by script
  ([design-shell.md](docs/design-shell.md#verification-and-testing)).
* [Low] shell, the rc oracle on Linux: `Erx::RcOracle::Build` links the
  lib9 members rc pulls on macOS; check the list and the flags on Linux
  hosts when the plan reaches them.
* [Low] shell, the rc oracle runner's residuals (`tools/lib/erx/rc_oracle.rb`), for
  trusted corpus scripts: rc stays in the operator's session, so a script
  can open `/dev/tty`; a program that leaves rc's process group escapes the
  kill at the end, and a writer killed mid-write can add bytes after it;
  a script that replaces `sigexit` can write a status report itself; the
  build inherits the host's compiler environment (`CPATH`, `SDKROOT`),
  which its record does not hold; `TZ` and the umask come from the host;
  and programs see `fn#sigexit` and `PLAN9`, which the comparison with the
  Erlang shell must leave out.
* [Medium] liberx, `erx` backend, `erx_utcb_self`: the generated trap
  wrappers of calls with UTCB parameters
  (`liberx/backend/erx/arch/aarch64/generated/calls.c`) reach the calling
  thread's UTCB through `erx_utcb_self`, which nothing defines yet. On
  AArch64 it reads `TPIDRRO_EL0`, so it lands as a listed
  system-register function generated from the system-register source,
  with the first shipped call that takes a UTCB parameter
  ([design-abi.md](docs/design-abi.md#kernel-calls-and-bindings)).
* [Medium] fuzzing, UTCB call decoding: `fuzz/generated/abi.c` decodes
  every shipped call with a UTCB built from the input, but no shipped call
  takes a UTCB parameter yet, so the decoder's word copy, uncovered-byte
  checks and aggregate field checks reach libFuzzer only through the
  host probe of `test/fixtures/abi_call_marshal.txt`. Have `check-fuzz`
  also build the generated harness against that fixture, or land the
  first UTCB call with its fuzz run
  ([design-abi.md](docs/design-abi.md#kernel-calls-and-bindings)).
* [Medium] kernel dispatch, the effect loop: `erx_dispatch`, which decodes
  the shape, performs the admission core's actions (`kernel/core/admit.c`)
  with `erx_cap_lookup`, `erx_object_lock_existence` and
  `erx_object_unlock_existence`, and
  calls the handler, lands with the object store those functions belong
  to, with the build check that only the dispatch takes admission's lock,
  with the handlers' `erx_object_lock_existence2`, its refusal of two
  references to one object and the one wrapper each such handler has, and with `erx_cap_lookup`'s reading of the calling
  thread's space and thread for `erx_cap_read`'s `erx_cap_self_t`;
  `erx_cap_lookup`'s design signature takes an `erx_rights_t` where
  the plan and `erx_cap_read` hold a mask, which the loop reconciles. Until
  then the plan and the core are driven only by the host probe of
  `test/fixtures/abi_call_marshal.txt`, since no shipped call takes a
  capability ([design-kernel.md](docs/design-kernel.md#system-call-dispatch)).
* [Medium] ABI call grammar, capability forms the design's call table needs
  and the schema cannot declare yet, each of which the admission plan must
  express rather than the dispatch working around its lookup: a nullable
  argument (`erx_budget_watch`, `erx_irq_create`, since a lookup of
  `ERX_CAP_NULL` is stale), either of two types (`erx_irq_bind`), any type
  (`erx_cap_dup`, `erx_cap_close`, `erx_object_destroy`, `erx_object_info`),
  rights that follow a flag (`erx_mem_create_paged`), and typed items in the
  UTCB checked by the pass plan (`erx_cap_pass`, IPC), which
  `carries_capability?` refuses as a plain aggregate
  ([design-abi.md](docs/design-abi.md#kernel-calls-and-bindings)). The
  `call erx_object_info` declaration waits on the any-type form; its topic
  enum, `reported` flags and report layouts do not
  ([design-abi.md](docs/design-abi.md#inspection-schema)).
* [Low] crash record, the brief form's promise: `fault` keeps `addr`, `pc` and
  `status`, so a wild dereference or an exit status can carry 8 bytes of what
  the root task held, against [design-kernel.md](docs/design-kernel.md#the-root-task)'s
  "nothing the root task held". Narrow the promise or the fields.
* [Medium] boot records, their writers and readers: the ABI file declares
  `erx_machine_page`, `erx_device_secret_page` and `erx_boot_root_extension`,
  and no code writes or reads them yet. The kernel's writers land with the root
  task's construction, and with them the kernel's command-line parser, its
  report of an unknown `erx.` key and their fuzz target. `liberx`'s root-task
  entry reads them, refuses a boot
  value and slot outside the pairs the design lists, treats a status outside
  its enum as no secret, and derives only from a status of present. With it
  land its fuzz targets, known-answer vectors for both HMACs, and the link
  check that only the entry's one derivation function reads the device-secret
  page or references its slot
  ([design-kernel.md](docs/design-kernel.md#the-root-task),
  [design.md](docs/design.md)).
* [Medium] kernel dispatch, the retry action: the generator gives only a
  call declared `retry` a handler that takes `erx_sys_action_t`. The
  generated dispatch loop that runs such a call again from its capability
  lookup, and the build check that only the send's path returns
  `ERX_SYS_ACTION_RETRY`, with a seeded second returner failing it, land
  with erXos's kernel's dispatch and IPC send path (Track K).
* [High] chokepoints, the pending M1 rules of
  `tools/lib/erx/chokepoint_rules/`: the object leg (no liberx target
  object outside the fiasco backend references an `l4_` symbol or holds a
  trap but the ABI's, read with `llvm-nm` and `llvm-objdump`; it also
  closes the include-path gap the text rules cannot see, an `-I` flag
  reaching l4sys's headers); the linked-kernel call-site reader the raw
  allocator and pmem converter rules need; the glue-imports allowlist over
  the glue's GCC objects (`erx_handoff.cpp` already exists, and its imports
  are unchecked until then); and the vector route. Each fails the check as
  soon as a file it awaits lands, except the files it lists as existing
  ([design-kernel.md](docs/design-kernel.md#chokepoint-checks)).
* [Medium] chokepoints, gaps of the text rules until the object leg
  closes them (`tools/lib/erx/chokepoints.rb`): rules match names, so they
  do not follow includes (a `kernel/core/cap.h` allowed to include
  `cap_impl.h` can be included by the glue), and they do not see token
  pasting or `L4_` macros; files ignored by an exclude rule are not
  scanned though a build file could name them; the glue, inside an
  imported tree, gets no directory-alias or link-name check; and an
  Elsewhere rule checks only that its test file exists, not its named
  check or seeded case. `include-form` reads only erXos's files and the
  glue, so in Fiasco's inherited kernel sources, which
  `budget-records-private` and `seam-only-from-glue` also read, a computed
  include, a climbing path (`../../../../kernel/core/budget.c`) or a
  header outside the C-family extensions passes them. The C view keeps the
  comments of `.S` files, so `# /**/ include "x_impl.h"` there hides the
  directive from every include rule. A differential test of the C view
  against `clang -E` would prove that it never drops code.
* [Low] conformance harness details (`tools/lib/erx/conformance.rb`): hash
  and boot one copy of the image, so a rebuild during the matrix cannot
  mix images; show each failed configuration's reasons on the terminal,
  not only in its report; split protocol lines on single spaces exactly.
* [Medium] conformance, the guest side: a `liberx` reporter that prints
  `erx-test:` lines and ends the machine through `erx_machine_end`, and the
  roster's first cases with their calls; the harness gives one deadline per
  configuration, not per case ([design-build.md](docs/design-build.md#images-and-guests)).
* [Medium] bench, G1's guest workloads (`tools/erx bench timer`, `stop`,
  the null call, IPC, park and wake, boot time): they reuse the conformance
  harness's boot, deadline and guest endings, with results kept per
  accelerator ([plan.md](docs/plan.md#m1-the-system-boots-on-fiasco)).

* [High] kernel memory, file-backed memory objects with evictable clean
  pages, so that large-file `mmap` (LMDB, SQLite in mmap mode) and ML
  weights larger than free RAM work; needs a revised K6 (a fault may wait
  only on a party that already controls the faulting space) and a K6
  wording that separates guaranteed anonymous memory from evictable file
  memory ([design-kernel.md](docs/design-kernel.md#invariants),
  [design-kernel.md](docs/design-kernel.md#virtual-memory)).
* [Medium] vault, the TPM 2.0 client: choose between tpm2-tss as a NIF, a
  small C client, and a client of erXos's own with Erlang framing and the
  session cryptography in the vault's NIF; the design recommends the last,
  behind `erx_seal`
  ([design-system.md](docs/design-system.md#risks-and-open-questions)).
* [Low] vault, anchoring under `tpm`: a TPM NV counter that versions the
  machine's file and the set of enrolled principals, so a deleted or
  rolled-back principal file reads as tampering; needs a recovery path for
  a tampered medium
  ([design-system.md](docs/design-system.md#risks-and-open-questions)).
* [Medium] vault, credential slots: FIDO2 slots through `hmac-secret`
  and recovery-code slots, beside the passphrase slot, each wrapping the
  principal's master key ([design-system.md](docs/design-system.md)). A
  recovery slot needs its own policy, since its protection can become the
  easiest route to the master key.
* [Medium] logins over the network: SSH public-key logins, optionally
  backed by a hardware key, before any password login over the network.
* [Medium] boot security on the Raspberry Pis: secure boot as an
  installation option with each slot's measurement; anti-rollback where a
  board offers a counter that its trust root checks before the kernel
  (neither Pi does), the counter taking the committed slot's security
  version at each commit and the spare allowed below it, while without one
  the floor is the running system's security version, which rises only at
  commit; and a TPM 2.0 driver over SPI for add-on modules, an Erlang
  driver in the vault's domain
  ([design-platforms.md](docs/design-platforms.md)).
* [Low] vault: key facets constrained to a destination, in the style of
  OpenSSH's restricted agent, which need authenticated session evidence;
  and a TEE backend for the sealing interface.
* [Low] files, fid pools: a root grant's fid pool is shared by the
  session and every program under it, with a quarter kept back for the
  root ([design-files.md](docs/design-files.md)). Give each derived
  grant a pool carved from its parent's, so one program cannot exhaust a
  sibling's opens.
* [Medium] storage, FAT: a FAT file server in Erlang, in a storage domain
  that holds only its own partition's window, for removable media and for
  exchanging files with other machines. Booting and updates need none: the
  firmware reads the slots' FAT, and an update writes whole slot images
  ([design-storage.md](docs/design-storage.md)).
* [Low] storage, F2FS per-file encryption: erXos's F2FS implements the
  `encrypt` (fscrypt) feature flag, so a principal's files are encrypted
  at rest under a key the vault hands the storage domain through a key
  facet, with Linux as the oracle for the on-disk format. Until then the
  flag is refused, as every unimplemented feature is
  ([design-storage.md](docs/design-storage.md#read-write-storage)).
* [Low] storage, F2FS compression: the `compression` feature flag, when a
  consumer needs it, with its per-cluster work in a per-byte primitive.
  Until then the flag is refused, as every unimplemented feature is
  ([design-storage.md](docs/design-storage.md#read-write-storage)).
* [Low] toybox: at import, verify the `vfork` and `exec` call sites of
  toybox 0.8.15 and the list of applets left out
  ([design-programs.md](docs/design-programs.md)).
* [Low] tools/erx, mounting an erXos server on the Mac: the 9P2000.L
  mount of the machine's namespace needs a FUSE layer on macOS (macFUSE or
  FUSE-T) for Finder, editors and `grep` to reach `/proc` and the
  machine's files ([design-live.md](docs/design-live.md#the-host-link)).
* [Low] kernel and platforms, isolation groups: confine a board whose
  fabric keeps requester identities only within a bus by isolation groups
  that span several streams ([design-kernel.md](docs/design-kernel.md)).
* [Medium] kernel, profiling with hardware performance counters: give a
  thread confined access to the CPU's counters through a capability, so
  programs and runtimes can count cache misses, branch mispredictions and
  cycles without seeing anyone else. Design first: a counter object
  granted by whoever holds the profiled space's authority; the kernel
  counts only the holder's user-mode execution, saving and restoring the
  counters on every switch so nothing leaks between threads or domains;
  sampling by overflow interrupt delivered as an IRQ object to the
  profiler; the events and counter widths from the architecture's
  specification, generated like other system registers; what the
  inspector shows; the cost on the switch path, measured with
  `tools/erx bench`. Decide whether ERTS's `perf` support and
  `erlang:statistics` use it. Replaces the stopgap's direct user access
  (Stopgap replacements above).
* [Medium] erx_blk, `tools/lib/erx/device_posters.rb`: the rule "only `erx_blk_write` calls `erx_device:post/4`" is
  tree-wide, but every virtio driver will post; once a second poster joins `SITES`, the write path's argument also
  needs "only the block driver's device process (`erx_blk_virtio`) opens a block record", which no check holds. Scope the rule per device class. Rename
  `erx_blk_write`, which now posts reads too, to what it is (for example `erx_blk_post`).
* [Low] erx_blk, `tools/lib/erx/device_posters.rb`: the check that only `erx_blk_write` posts sees only literal
  calls, and holds `erx_device:command/2` to `erx_blk_write` the same way: a call whose module comes from a macro,
  a variable or `apply/3` escapes it. design-storage.md's U4 extends it over the driver applications: `erx_device`
  never a value (only the module of a literal remote call), and no atom made from data, with the seeded violations
  of design-storage.md's verification (`M:command/2`, `list_to_existing_atom/1`).
* [Medium] runtime, `otp/erts/emulator/nifs/erxos/erx_device.c`: a device record maps the pages that hold its window
  (`erx_device_window_pages`), and an open of another window in one of those pages answers `ebusy`, so only one of
  QEMU `virt`'s eight virtio-mmio slots per page can be driven at a time (the QEMU plan's second disk, on
  `virtio-mmio-bus.30`, shares the first one's page, so its open would be refused). The console handoff
  (`liberx/backend/fiasco/service_task.c`, `erx_fiasco_task_mem_physical_body`) compares the request's base with the
  console's exactly, which holds for a page-aligned UART only; test containment instead. Let records whose windows share a page share its one mapping, each still
  reaching only its own window through the register table
  ([design-shared-devices.md](docs/design-shared-devices.md#pages-inside-a-domain)), and test two slots of one page in
  `test/fixtures/erx_device_harness.c`.
* [Medium] runtime, the device records' writers (`liberx/backend/core/boot_manifest.c`'s `-erx device`, the root's
  `-erx console_uart`, the domain library's and `runtime_entry.c`'s `-erx given`, and `erx_device_record`): no record
  carries the page run its unit's windows cover, which
  [design-shared-devices.md](docs/design-shared-devices.md#pages-inside-a-domain) gives it. The device NIF maps each
  record's own pages as its run (`erx_device.c`, `take_window`), so records over one page share its mapping, but a
  record whose pages meet a run without equalling it is `ebusy`. Write the run from the boot view's unit relation
  into every record form, and read it in `erx_device_record`.
* [Low] runtime, the console handoff (`liberx/backend/fiasco/service_task.c`,
  `erx_fiasco_task_mem_physical_body`) compares the request's base with the console's exactly, which holds for a
  page-aligned UART only; test containment instead.
* [Medium] drivers, shared interrupt lines, who may reach a line
  ([design-shared-devices.md](docs/design-shared-devices.md#invariants), SD3 and SD4): the line-call check
  (`tools/lib/erx/device_callers.rb`) reads source tokens, so an atom spelled with escapes passes it; the BEAM-file
  pass the design names is not built. Any module may call `erx_irq_line`, so `attach/2` of a guessed record moves a
  direct line's binding, `ack/1` of a forged direct handle acknowledges a shared line behind its owner, and
  `start_owner/2` through the owner's record takes the line silently; `irq_ack/2` checks neither the caller nor
  the mark (`erx_device_bif.c`). A forged `{erx_irq, ...}` to a driver or a forged join to an owner can likewise
  acknowledge a line early or hold it masked. Fix by construction: `irq_ack/2` accepts only the line's binder, and
  a naming rule holds `erx_irq_line` to drivers and their starters.
* [Low] drivers, shared interrupt lines
  ([design-shared-devices.md](docs/design-shared-devices.md#failure-handling)): a line owner keeps no deadline per
  firing (`erlang/apps/erx/src/erx_irq_line.erl`), so a hung driver holds its sharers masked until the unit is
  restarted; a deadline after which the owner restarts the slow driver belongs with the hostile-driver work.
* [Medium] erx_blk, the block driver: the device process's backlog, reply and reset decisions
  (`erlang/apps/erx_blk/src/erx_blk_virtio.erl`, `submit/3`, `resume/1`, `broken/2`) are tested only end to end, by the
  `block_device` QEMU suite's good path; they should move into a pure module whose full, held and broken cases are
  tested on the host.
* [Medium] erx_blk: a device that stops completing leaves its callers to time out in `gen_server:call` (an exit, not
  `{error, timeout}`), and a timed-out write still lands later. design-storage.md's transport contract gives every
  request a wait limit of 10 s from its acceptance and an in-flight bound of 18 s, past which the device process ends,
  below `call/1`'s 30 s; the device process implements neither, and `call/1` should return `{error, _}`.
* [Medium] erx_blk: a virtio device that stops completing leaves its callers to time out in `gen_server:call` (an exit, not
  `{error, timeout}`), and a timed-out write still lands later; the driver needs a per-request deadline that ends the
  device process (as a broken queue does), `call/1` should return `{error, _}`, and held requests of a caller that has gone should be dropped.
* [Medium] erx_blk, SD register spacing (`erx_blk_sd_regs`; docs/design-storage.md, "The SD host controller"): the
  6 us spacing between non-`data` writes holds only while every such write goes through `erx_blk_sd_regs` with the
  latest handle; spacing in the device NIF for `sdhci` records, or a chokepoint check, would make it hold by
  construction.
* [Medium] erx_blk: U4's trial rule is not applied in `erx_blk_write:write/6` or `erx_blk_write:sd_write_plan/3`, and `erx_blk`'s reads and writes (`read/2`, `write/2`,
  and their pid forms `read/3`, `write/3`) still let any process of the system domain reach any sector: the block service's windows (`erx_blk_window`) check
  their sectors, but nothing yet confines clients to them. The device service, which names each client's windows by
  role and hands their pids out as grants (PW1), replaces `erx_blk_service:window/1`, which hands any role's window to
  any caller, slot and record windows included.
* [Medium] erx_blk_table, `tools/lib/erx/medium_image.rb`: the extended boot records' encoding (first entry relative
  to its own record, link entry relative to the extended partition and spanning the next record and its partition) is
  checked only by copies written from one reading of the format; list a `MediumImage` medium with an independent
  reader (FreeBSD's `gpart` on an md device, or util-linux `sfdisk --json`) and compare every start and length.
* [Medium] erx_blk_window, erx_blk_service: beyond the window's binding to one device process
  (`test/erlang/erx_blk_window_tests.erl`), tested only by the QEMU suite's admitted medium. Host EUnit cases over a
  stub `erx_blk` should cover the window's error mapping and argument checks, and the service's refused, no-device and
  failed-read paths and its restart; a QEMU medium with one corrupted entry should show "blk: no windows".
* [Medium] docs/design-storage.md, failure handling: a device reset in the target design breaks the volumes over
  the device, since each window is bound to one device process's life, but nothing names how a file system that
  restarts after the reset gets a window bound to the new process: the device service would name new windows and
  grant them again, or the reset would end what holds the old windows, as the storage domain's end does in Phase 1.
* [Low] erx_blk_window: a request that waits in a window's mailbox behind another client's stuck request can time
  out at its caller and still be posted later, a second way into the timed-out-write item above.
* [Low] abi/formats/mbr.txt: `erx_mbr_entry` declares alignment 4, but entries lie at 446 + 16i on the medium;
  declare 1 if the generator accepts it, so no C reader casts a sector buffer to the struct.
* [Low] erx_blk_table: a data partition past 2 TiB, which an MBR cannot describe, is refused as `{mbr, 4, sectors}`
  rather than as a data length the table cannot hold.
* [Low] erx_blk_window: a request for more sectors than one device request carries (`erx_blk_request:max_sectors/0`)
  is refused with `einval` rather than split, so every client splits its own.
* [Medium] abi/medium.txt: the medium layout's sizes (the record's partition 8 MiB, each slot 512 MiB, the vault's
  partition 64 MiB, the data partition at least 128 MiB, every boundary on 1 MiB) are settled, but not yet checked
  against the slot images' sizes (the plan's decision gate on uncompressed slots) or the Pi firmware's needs of the
  record's and the slots' FAT partitions; each slot's signature window is not in the layout yet.
* [Low] erx_blk_virtio: an interrupt storm costs a scheduler, bounded by the device's rate (Phase 1 residual).
