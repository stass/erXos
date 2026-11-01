# Research record: architecture evidence

This record collects source evidence for the subsystem designs. Sources
were inspected on 2026-10-31 and 2026-11-01; they have not been rechecked.
The target architecture is [design.md](design.md). Unadopted proposals
live in [todo-simplification.md](todo-simplification.md).

No erXos build, QEMU run, sanitizer run or performance measurement supports
this record. Secondary and unverified claims retain those labels. Dates,
versions and proof scopes apply only to the configurations described.

## Systems and mechanisms

| Work and source scope | What the source establishes |
| --- | --- |
| [LionsOS paper, 2025](https://trustworthy.systems/publications/papers/Heiser_VCJGNLDZAZWPDB_25.pdf), sections 5.2-5.4 | Small sequential components, explicit virtualizers, bounded SPSC queues and shared policy-independent state simplify concurrency and restart |
| [Microkit project](https://trustworthy.systems/projects/microkit/), including the 2.4.0 release announcement of 2026-10-30 | A small protection-domain/channel abstraction targets statically architected systems; work on dynamic lifecycle remains explicit |
| [seL4 MCS tutorial](https://docs.sel4.systems/Tutorials/mcs.html) and [Proofcraft's 2026 verification report](https://proofcraft.systems/news-2026/) | Scheduling contexts make CPU time explicit. MCS functional correctness was completed on RISC-V in June 2026; AArch64 MCS was a separate ongoing effort. AArch64 security proofs reported in August do not erase that configuration distinction |
| [Grouper, September 2026 preprint](https://arxiv.org/html/2609.14123v1) | Groups of isolated runtimes can pass execution capacity along a request path while an allocator retains overall control; members belong to one cooperating tenant, not mutually distrusting tenants |
| [Atmosphere, SOSP 2025](https://mars-research.github.io/doc/2025-sosp-atmo.pdf) | A microkernel can be designed around automated refinement proofs, with data structures chosen to make proof obligations tractable; its kernel uses a global lock, and the paper notes long-call latency limitations |
| [Frama-C WP](https://www.frama-c.com/fc-plugins/wp.html) and [CN's peer-reviewed C verification work](https://www.repository.cam.ac.uk/items/56a8433e-cd00-4fd2-b9db-20d344d1f0d5) | C contracts and separation-logic-based reasoning can express functional and ownership obligations |
| [Capability OS systematization, USENIX Security 2026](https://www.usenix.org/system/files/usenixsecurity26-mauthe.pdf), sections 2 and 6 | Security properties depend on the surrounding capability system, not merely on using unforgeable references; designation, authority, subject boundaries and revocation need precise definitions |
| [Time-protection research](https://trustworthy.systems/projects/timeprotection/home.pml) | CPU quota isolation and prevention of microarchitectural timing channels are separate goals; complete protection depends on hardware support |
| [CHERIoT concepts](https://cheriot.org/book/concepts.html) and the [Cambridge CHERI Research Centre](https://cheri.cst.cam.ac.uk/) | Hardware capabilities can support fine-grained memory safety and compartmentalization, including legacy native code |
| Linux `sched_ext` (6.12, 2024) and ghOSt (SOSP 2021) | Policy in user space or BPF, mechanism in the kernel; an internal error, a stalled runnable task or SysRq aborts the user scheduler and every task reverts to CFS, so "system integrity is maintained no matter what the BPF scheduler does"; a bypass mode runs FIFO while a scheduler is disabled. Meta's ads fleet moved to it in 2026 with p99 down 28 percent at launch and 3.28 MW saved. ghOSt delivers a scheduling message to a local agent in 725 ns, to a global one in 265 ns. |
| Composite: Slite (RTAS 2020) and TCaps (RTSS 2017) | A user-level scheduler dispatches threads in about 41 cycles through a dispatch control block the kernel resyncs on entry; the kernel still enforces slices through temporal capabilities. A TCap holds a cycle budget and per-subsystem priorities; delegation costs about 786 cycles, grows linearly with the number of subsystems, and is never revoked (secondary). |
| seL4 MCS (EuroSys 2018; seL4 16.0.0 and 17.0.0, 2026) | A scheduling context is budget per period with no admission test; exhaustion raises a timeout fault to a handler or the thread waits for replenishment; `Call` into a passive server is trusted because the server may never reply. RISC-V MCS functional correctness was completed in June 2026; AArch64 MCS is in progress; the MCS fast path is unverified, and 17.0.0 (2026-10-30) fixed a NULL write in it triggered by deleting an endpoint a passive server waits on. |
| Linux proxy execution (2023 to 2026) | A blocked donor's scheduling context runs the lock owner; mainline for same-CPU mutexes, incompatible with `sched_ext`, with crashes under stress still being investigated in 2026. |
| Nemesis (IEEE JSAC 1996) and self-paging (OSDI 1999) | "As much functionality as possible executes in the domain of the application"; a shared server working for many applications causes QoS crosstalk; self-paging requires every application to handle its own faults with its own resources, naming the shared external pager as the canonical offender. |
| Shenango (NSDI 2019), Caladan (OSDI 2020), Junction (NSDI 2024), Grouper (arXiv, September 2026) | Core reallocation every 5 to 10 us; reclaiming a core from a best-effort task takes 17.6 us at p50 and preemption is deferred while the runtime is in a critical section; Grouper passes execution capacity between isolated runtimes of one tenant in about 4 us and refuses 3 to 6 percent of requests to keep a hard concurrency bound. |
| Fuchsia Component Framework and Zircon | Every capability route is declared in manifests with `use`, `offer` and `expose`; `ffx scrutiny verify routes` checks the routes at build time, flags unused routes and keeps a per-type exceptions allowlist; dynamic parts of the tree are declared separately for verification; koids are 63-bit and never reused. |
| Hubris and Idol (Oxide, 2021 onward) | Tasks are fixed at build time and "can always be safely restarted because the resources associated with a task are available if that task itself has faulted"; the supervisor is a task and if it crashes the system reboots; Idol generates client stubs, an operation enum, server traits and error types from one definition, auto-retries idempotent operations on server death and returns a dead code carrying the new generation otherwise. |
| Tock grants (SOSP 2017), seL4 untyped, KeyKOS and EROS space banks, CapROS | Kernel state for a process lives in that process's memory and is reclaimed trivially at its death; seL4 creates every object from application-controlled untyped memory and needs a derivation tree to revoke; in EROS destroying a space bank frees its resources at once, and CapROS destroys sub-banks with their parent. |
| Genode resource trading (Foundations 24.05; releases 14.11, 17.05, 25.08) | Memory is donated per session and returned on close; a server that refuses to return quota is killed by the parent; capability quotas were added in 2017 after a misbehaving component could exhaust the global capability space; CPU quota by claims and fills (2014) was replaced in 2025 by a two-level scheduler because prioritization "was only effective when a CPU quota was assigned". No CPU is donated per request. |
| Theseus (OSDI 2020; state spill, PLOS 2017) | State spill is the lasting change of one component's state from handling another's request; Theseus's components keep runtime-persistent bounds "without holding states for each other", which is what makes live evolution and fault recovery tractable. |
| Singularity channel contracts (EuroSys 2006) | A contract names the messages and the protocol state machine of a channel; the compiler rejects a send in the wrong state; message data lives in an exchange heap with one owner per block. |
| LionsOS and sDDF (arXiv 2501.06234, 2025; Microkit 2.4.0, 2026-10-30) | Drivers, virtualisers and copiers connected by lock-free single-producer queues in shared memory and notifications; NIC drivers of 397 to 668 lines against 3,000 to 10,700 in Linux; 1 Gb/s UDP echo on an i.MX8 with a third of the CPU spare where Linux plateaus near 500 Mb/s; Microkit stops, restarts and resumes protection domains but creates none at run time, and 2.4.0 removed the parent's fault endpoint from children. |
| Capsicum (USENIX Security 2010; FreeBSD) | After `cap_enter` a process uses only delegated rights, `openat` is confined under the supplied descriptor, and `cap_rights_limit` can reduce rights but never expand them, failing with `ENOTCAPABLE`. |
| ERTS 29.1.2 sources (`erl_node_tables.c`, `external.c`, `bif.c`, `dist.c`) | `dist_table_cmp` compares the node name alone; every `ErlNode` of one name shares one `DistEntry`; `dec_is_this_node` requires the local creation; `do_send` to a same-name other-creation pid logs "Discarding message ... in an old incarnation" and returns as if sent; `erts_internal_create_dist_channel_3` refuses a channel to the node's own name; `dist.c` answers `noproc` or drops for the old-incarnation cases. `erts_prepare_dist_ext` creates atoms, so no safe mode exists on distribution channels today. |
| OTP alternative carriers (ERTS 17.1.1 guide) | A carrier is a `_dist` module with eight callbacks, a controller that is a port or a process, `dist_ctrl_*` BIFs, and the handshake through `dist_util` with `#hs_data{}`; only the atom cache and fragments flags can be rejected; OTP 29 added an arity-4 `f_handshake_complete` receiving creation and flags. |
| QEMU 9pfs on macOS (merged 2022-03-08, QEMU 7.0) and 9P variants | A macOS host serves a directory to a 9P2000.L guest over virtio-pci with the `local` driver; limits are `virtfs_proxy_helper`, `O_NOATIME`, `O_DIRECT` and device nodes. 9P2000 has 13 request types, 9P2000.L 28. FUSE-T mounts without a kernel extension; plan9port's `9pfuse` has an open Apple Silicon issue. |
| Erlang and OCaml network stacks (Erlang 2005; MirageOS 2013; Biscuit 2018) | A pure-Erlang stack in 2005 was reported at about a quarter of the native stack's efficiency (secondary, unverified); MirageOS's OCaml stack did 1.7 Gb/s receive in 2013; Biscuit's Go kernel was within 10 percent of Linux with its own stack. |
| The BEAM-on-bare-metal field in 2026 | AtomVM 0.7 beta adds OTP 28 and 29 on microcontrollers; GRiSP 2 runs OTP 29 on RTEMS with an arm32 JIT; Nerves ships Pi 5 systems on Linux; Lunatic is dormant; LING and HydrOS are gone; wasmCloud deprecated its Elixir host. |
| WebAssembly components (WASI 0.3, 2026-06-11) and Asterinas (ATC 2025) | WASI 0.3 is ratified with Wasmtime 46; no production system uses Wasm components alone as OS isolation, and Hyperlight wraps them in a micro-VM. Asterinas keeps 14 percent of its lines in the unsafe core. |

## Reproducible semantic probe

The probe ran offline on arm64 macOS 27.0.1 with OTP 28 / ERTS
16.0.2, one normal scheduler, one dirty CPU scheduler and one dirty I/O
scheduler, closed standard input, a log and a 30-second GNU timeout.
It is supporting evidence, not a pinned OTP 29.1.2 conformance run.

The following Erlang expression constructs two distinct external pid keys,
then the encoding produced if both creations become zero. It also checks
that a normal alias can receive two messages. Run it with `erl -noshell
-eval`, one normal scheduler, one dirty CPU scheduler and one dirty I/O scheduler, closed standard input, a log,
and a hard timeout. It does not execute erXos code or exercise cross-domain transport.

```erlang
Pair = fun(Creation, Value) ->
    <<88, 119, 7, "erx@box", 42:32, 7:32, Creation:32,
      119, 1, Value>>
end,
Original = <<131, 116, 2:32,
             (Pair(1, 97))/binary, (Pair(2, 98))/binary>>,
Rewritten = <<131, 116, 2:32,
              (Pair(0, 97))/binary, (Pair(0, 98))/binary>>,
io:format("original_map_size=~p~n", [map_size(binary_to_term(Original))]),
Result = try binary_to_term(Rewritten) of
    Map -> {accepted, Map}
catch
    error:Reason -> {rejected, Reason}
end,
io:format("rewritten_map=~p~n", [Result]),
Alias = alias(),
Alias ! first,
Alias ! second,
First = receive X -> X after 1000 -> timeout end,
Second = receive Y -> Y after 1000 -> timeout end,
io:format("ordinary_alias_receives=~p~n", [{First, Second}]),
unalias(Alias),
halt().
```

Observed output, installed host OTP 28 / ERTS 16.0.2:

```text
original_map_size=2
rewritten_map={rejected,badarg}
ordinary_alias_receives={first,second}
```

The corresponding OTP 29.1.2 expectations come from its linked format and
alias documentation. They still need execution in the project's pinned
oracle before an implementation fix is accepted.

## Sources

Primary sources inspected on 2026-11-01:

* Scheduling: https://faculty.cs.gwu.edu/gparmer/publications/rtas20slite.pdf ;
  https://faculty.cs.gwu.edu/gparmer/publications/rtss17tcaps.pdf ;
  https://docs.kernel.org/6.12/scheduler/sched-ext.html ;
  https://engineering.fb.com/2026/07/13/ml-applications/modernizing-the-meta-ads-service-with-an-open-source-kernel-scheduler/ ;
  https://cs.stanford.edu/~jhumphri/documents/ghost.pdf ;
  https://www.usenix.org/system/files/nsdi19-ousterhout.pdf ;
  https://www.usenix.org/conference/osdi20/presentation/fried ;
  https://www.usenix.org/conference/nsdi24/presentation/fried ;
  https://arxiv.org/abs/2609.14123 ; https://proofcraft.systems/news-2026/ ;
  https://github.com/seL4/seL4/blob/master/CHANGES.md ;
  https://raw.githubusercontent.com/seL4/seL4/master/manual/parts/threads.tex ;
  https://lwn.net/Articles/1030842/ ;
  https://www.cl.cam.ac.uk/research/srg/netos/projects/archive/pegasus/papers/jsac-jun97/node1.html ;
  https://static.usenix.org/events/osdi99/full_papers/hand/hand_html/hand.html
* Structure: https://fuchsia.dev/fuchsia-src/concepts/components/v2/capabilities ;
  https://fuchsia.dev/docs/development/verification/build_integration ;
  https://hubris.oxide.computer/reference/ ; https://github.com/oxidecomputer/idolatry ;
  https://www.tockos.org/documentation/design/ ;
  https://raw.githubusercontent.com/seL4/seL4/master/manual/parts/cspace.tex ;
  http://www.capros.org/design-notes/SpaceBank.html ;
  https://genode.org/documentation/genode-foundations/24.05/architecture/Resource_trading.html ;
  https://genode.org/documentation/release-notes/25.08 ;
  https://www.usenix.org/conference/osdi20/presentation/boos ;
  https://www.microsoft.com/en-us/research/publication/language-support-for-fast-and-reliable-message-based-communication-in-singularity-os/ ;
  https://arxiv.org/abs/2501.06234 ; https://docs.sel4.systems/releases/microkit/2.4.0 ;
  https://man.freebsd.org/cgi/man.cgi?query=capsicum&sektion=4 ;
  https://arxiv.org/html/2506.03876v1
* BEAM and Plan 9: https://raw.githubusercontent.com/erlang/otp/maint-29/erts/emulator/beam/erl_node_tables.c ;
  https://raw.githubusercontent.com/erlang/otp/maint-29/erts/emulator/beam/external.c ;
  https://raw.githubusercontent.com/erlang/otp/maint-29/erts/emulator/beam/bif.c ;
  https://raw.githubusercontent.com/erlang/otp/maint-29/erts/emulator/beam/dist.c ;
  https://www.erlang.org/doc/apps/erts/alt_dist.html ;
  https://www.erlang.org/doc/apps/erts/erl_dist_protocol.html ;
  https://erlang.org/pipermail/erlang-announce/2026-May/000353.html ;
  https://gitlab.com/qemu-project/qemu/-/commit/f45cc81911adc772 ;
  https://github.com/chaos/diod/blob/master/protocol.md ;
  https://github.com/macos-fuse-t/fuse-t ;
  https://www.github.com/9fans/plan9port/issues/641 ;
  https://anil.recoil.org/papers/2013-asplos-mirage.pdf ;
  https://github.com/atomvm/AtomVM/releases ; https://bytecodealliance.org/articles/WASI-0.3

## Additional primary-source pointers

These pointers accompanied the findings in the 2026-10-31 survey. Their
contracts are owned by the current designs; the links preserve the evidence
trail without retaining superseded findings as open work.

* [OTP 29.1.2 process flags](https://www.erlang.org/doc/apps/erts/erlang.html#process_flag/2).
* [Cortex-A72 r0p3 technical reference manual](https://documentation-service.arm.com/static/60368ce38f952d2e4134dc2e).
* [arm64 entry code](https://android.googlesource.com/kernel/common/+/02bd45a28bf32993e396fdcfd7d7c7cdc0847ed1/arch/arm64/kernel/entry.S).
* [OTP 29.1.2 external term specification](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#map_ext).
* [OTP process-alias contract](https://www.erlang.org/doc/system/ref_man_processes.html#process-aliases).
* [OTP's signal and process documentation](https://www.erlang.org/doc/system/ref_man_processes.html).
* [LionsOS paper, 2025](https://trustworthy.systems/publications/papers/Heiser_VCJGNLDZAZWPDB_25.pdf).
* [Microkit project](https://trustworthy.systems/projects/microkit/).
* [seL4 MCS tutorial](https://docs.sel4.systems/Tutorials/mcs.html).
* [Proofcraft's 2026 verification report](https://proofcraft.systems/news-2026/).
* [Grouper, September 2026 preprint](https://arxiv.org/html/2609.14123v1).
* [Atmosphere, SOSP 2025](https://mars-research.github.io/doc/2025-sosp-atmo.pdf).
* [Frama-C WP](https://www.frama-c.com/fc-plugins/wp.html).
* [CN's peer-reviewed C verification work](https://www.repository.cam.ac.uk/items/56a8433e-cd00-4fd2-b9db-20d344d1f0d5).
* [Capability OS systematization, USENIX Security 2026](https://www.usenix.org/system/files/usenixsecurity26-mauthe.pdf).
* [Time-protection research](https://trustworthy.systems/projects/timeprotection/home.pml).
* [CHERIoT concepts](https://cheriot.org/book/concepts.html).
* [Cambridge CHERI Research Centre](https://cheri.cst.cam.ac.uk/).
