# Further research ideas for erXos

This record continues [Research ideas for erXos](research-os-ideas.md). It
looks for ideas that record does not cover, with attention to three kinds:
work that was too expensive in labor before LLM agents, forgotten operating
system papers whose mechanism fits an Erlang microkernel, and claims no
existing Erlang system has made.

These are unadopted research proposals, not architecture contracts or roadmap
commitments. [Design](design.md) and [Plan](plan.md) govern.

## Method and limits

Checked on 2026-11-04. A coordinating session drew up candidates, five
web-search subagents checked the citations and looked for work from 2023 to
2026, and one read-only search compared the candidates with the design
documents. Each citation carries one of three marks:

* **opened**: the page or paper text was fetched and read;
* **search**: seen only in a search result, so numbers are unconfirmed;
* **memory**: a well-known paper cited from memory and not looked up.

"No precedent found" means a handful of searches found none. It is absence
of evidence, not proof that a claim is open.

## What is already claimed

Several systems host the BEAM without Linux. Each one found runs ERTS as a
program over a kernel that knows nothing of Erlang. None integrates the
Erlang process model into the operating system as erXos does, so the bare
phrase "Erlang on its own kernel" is taken and the integration is not.

| System | How Erlang meets the kernel | Drivers and services | Status | Mark |
| --- | --- | --- | --- | --- |
| [Tyn](https://github.com/tyn-os/kernel) | Unmodified OTP 27 runs as one user-mode program over about 50 emulated Linux system calls. The kernel schedules threads; its README states no awareness of Erlang processes. | Drivers, network stack and file layer are Rust in kernel mode. One node per instance, no capability model stated. | Alive | opened |
| [Crazierl](https://github.com/russor/crazierl) | The BEAM runs over a roughly FreeBSD-compatible system call layer on 32-bit x86. Scheduling integration is not stated. | The TCP/IP stack is an Erlang library. Its README says most drivers "will be written in Erlang"; isolation and capabilities are not stated. | Alive, small | opened |
| [Kry10](https://www.kry10.com) | Announced as the BEAM as an application environment above seL4. Closed, so details are unknown. | Unknown | Commercial; current site does not mention the BEAM | opened |
| [HydrOS](https://www.erlang-factory.com/euc2017/sam-williams) | One BEAM per core on bare metal, for fault tolerance | Unknown; no code was found | Research, apparently inactive | search |
| [GRiSP](https://readme.hex.pm/grisp/1.1.6), Nerves, [LING](https://github.com/cloudozer/ling), [AtomVM](https://github.com/atomvm/AtomVM) | The BEAM on an RTOS, on Linux, on Xen, and a small VM for microcontrollers | The host system's | Alive, alive, dormant, alive | search |

What separates erXos from every row, with no precedent found:

* the kernel grants CPU time to runtime groups and each runtime schedules
  its own processes within its grants, so scheduling has two levels with one
  authority;
* drivers, the network stack, the file systems and the system services are
  supervised Erlang processes, each in a domain holding only its
  capabilities; Crazierl states the intent for drivers but not the isolation;
* one pid space, one message system and one inspector span every domain and
  every runtime;
* ERTS is taken apart and fitted to the kernel interface, where the others
  keep it unmodified behind an emulated Unix interface.

Further claims for which no precedent was found: exhaustive schedule
exploration of an operating system's own services; a BEAM heap or process
saved, restored or moved as a value; and machine-checked proofs of the kernel
under an Erlang system.

## Candidates and priorities

| Idea | Main attraction | Design today | Assessment |
| --- | --- | --- | --- |
| Agent-written proofs of the kernel | A machine-checked kernel at a cost a small project can pay | TLA+ models only | Strongest claim to fame |
| File systems and network stack written from specifications | The two largest bodies of work on the roadmap become specification work | Planned as hand-written Erlang | Strongest practical value |
| Searched policies with a safety check | Policies tuned per workload by search, admitted by a fixed checker | Absent | Strong, low risk |
| Runtime heap images and template domains | Shell in tens of milliseconds, a new isolated runtime in under one | Absent | Strong demonstration |
| A process as a value | One mechanism for checkpoint, migration and moving between instruction sets | Absent | Wow factor, real research |
| Nested erXos | Test a new system inside the running one | Absent | Good fit with the backend seam |
| Shadow versions and second implementations | Upgrade with evidence; cheap independent oracles | Absent | Practical, with one known limit |
| Formats from descriptions | No hand-written parser of untrusted input | Partly: ABI layouts only | Practical, by construction |
| Learned-model parity gate | A mechanical test for "the replacement behaves like the stopgap" | Parity rule exists, no method named | Small and useful |
| Exhaustive schedules for real services | Check the code, not a model of it | Models only | Open claim, tool work needed |
| Other runtimes as supervised processes | Any language gets pids, links and supervision | "None designed without a user" | Ecosystem bet |
| Model context as a memory object | Fork an agent's context by copy-on-write under a budget | Weights as a workload only | Speculative |
| Standing queries over system state | Supervision and alerts written as queries | Shell records, no standing queries | Modest |

## Agent-written proofs of the kernel

The cost of a verified kernel has been the proof. seL4's proof is reported at
about 200,000 lines of Isabelle for 8,700 lines of C and about 22
person-years (search, secondary source). Atmosphere, a Rust kernel verified
with Verus, reports under 2.5 person-years and a proof-to-code ratio of
3.32 to 1 ([SOSP 2025](https://mars-research.github.io/doc/2025-sosp-atmo.pdf),
search).

In September 2026 Kaashoek and Zeldovich reported verifying the xv6 kernel on
RISC-V with AI agents writing the proofs
([arXiv 2609.04043](https://arxiv.org/abs/2609.04043), opened). The numbers
from the paper's text:

| Measure | Value |
| --- | --- |
| Code verified | 6,657 lines of C and assembly, 8,725 RISC-V instructions |
| Proof | About 1.6 million lines of Rocq, 331,166 of them tool-generated |
| Elapsed time | 102 days, including building the proof framework |
| Human input | 6,058 prompts, median 13 words |
| Agent time | 2,153 hours summed over sessions |
| Stated cost | Under $3,000 in subscriptions, plus development machines |
| Found on the way | 11 bugs in xv6, one in the Sail RISC-V model, one in Sail's Lean extraction |

The proof is against the Sail model of the processor, below the compiler, and
covers page tables, traps, interrupts and DMA. The theorem is stated at the
console: what the system prints for a given input. Other results point the
same way: a coding agent proved all 4,257 lemmas of the Iris library
([arXiv 2607.06341](https://www.alphaxiv.org/abs/2607.06341.md), opened as a
summary), and an agent wrote a 7,800-line Rocq proof of a CertiCoq compiler
pass in about 96 hours ([arXiv 2602.20082](https://arxiv.org/abs/2602.20082),
opened). A search-based prover reaches 77.6% of a benchmark of seL4 theorems
([arXiv 2603.19715](https://arxiv.org/abs/2603.19715), OSDI 2026, opened).

erXos's kernel rules were written for review, and they also suit proof: pure
decision functions, pure state machines, plans validated whole before they
are applied, bounded kernel paths, no recursion except tail calls, and
generated register access. The "by construction" list in the working
agreement reads as a list of theorems: a stale capability never names a new
object, rights only shrink, a mapping never exceeds its ceiling, no mapping
is writable and executable at once.

Limits, all from the sources:

* **Specifications are the bottleneck.** The xv6 authors report that agents
  are "not at all good at" introducing abstractions and had to be forced to.
  A benchmark of specification writing for Hyperkernel found twelve models
  did poorly ([arXiv 2504.20964](https://arxiv.org/abs/2504.20964), opened).
  The statements to prove have to be ours.
* **The precedent is RISC-V.** An AArch64 proof needs the Sail model of that
  architecture, which is much larger. Nobody was found to have done this.
* **A proof of the binary is redone when the binary changes.** The paper
  reports a median of 35 minutes of agent time per recompile.
* **The proof says what the theorem says.** A console-level theorem is not a
  proof of isolation between domains. erXos would want the capability and
  budget invariants stated directly.

**First experiment:** take one pure state machine that already has a TLA+
model, such as the capability lookup with generation, type and rights, and
have agents prove in Rocq that the C17 function refines the model. Record
prompts, hours and proof size, as the xv6 paper does.

## File systems and network stack written from specifications

The roadmap ends with erXos's own F2FS and network stack in Erlang. Both are
large, and both have a stock implementation that can serve as an oracle.

SysSpec ([arXiv 2512.13047](https://arxiv.org/abs/2512.13047), opened;
listed at FAST '26, search) treats the specification as the source. It has
three parts: what each function does, how modules fit together, and the
concurrency rules. Agents generate the C. A change is a patch to the
specification, ordered as a graph, and the affected code is regenerated. The
resulting file system matches a hand-written one on hundreds of regression
tests, and ten Ext4 features were added by specification patches alone. It
runs in user mode over FUSE and is tested, not proven.

For protocols, SAGE generated ICMP code from the RFC that interoperated with
Linux and reported five ambiguities and six gaps in the text
([SIGCOMM 2021](https://arxiv.org/abs/2010.04801), search). RFCNLP extracted
state machines for TCP, SCTP, DCCP and BGP
([IEEE S&P 2022](https://arxiv.org/abs/2202.09470), search), and a 2025
benchmark measures LLMs on the same task
([PSMBench](https://papers.neurips.cc/paper_files/paper/2025/hash/521bd9583b3a39e92f662ee57e81e5ce-Abstract-Datasets_and_Benchmarks_Track.html),
search). No work was found that extracts a state machine from an RFC and then
uses it as a differential oracle against real stacks.

This fits rules erXos already has. A design document comes first, services
are pure state machines, and agreement with an independent oracle is the
correctness criterion. The proposal changes what is kept: the specification
and the oracle suite are the lasting assets, and the Erlang is regenerated
from them.

Limits: a specification and its code written by the same model can share a
mistake, so the oracle has to be independent (Linux's F2FS and TCP, driven by
the same inputs). SysSpec's result is one file system from one group.

**First experiment:** write the three-part specification for one small
existing Erlang service and regenerate it; compare against the hand-written
one on its existing tests, then apply one feature as a specification patch.

## Searched policies with a safety check

A line of work from 2023 to 2026 has a model rewrite a small function, runs
it against an evaluator, and keeps the best. AlphaEvolve reports a scheduling
heuristic for Google's cluster manager that recovers about 0.7% of fleet
compute (search). A Berkeley group reports up to 5.0 times better runtime or
50% lower cost across four systems problems, and names a cheap, reliable
evaluator as the precondition
([arXiv 2510.06189](https://arxiv.org/abs/2510.06189), opened). PolicySmith
searches cache-eviction scoring functions against traces and produces
congestion-control policies safe enough to load into Linux
([arXiv 2510.08803](https://arxiv.org/abs/2510.08803), HotNets 2025, opened).
Agents writing Linux scheduler policies report up to 1.79 times speedup
([arXiv 2509.01245](https://arxiv.org/abs/2509.01245), search).

Every paper says the result is only as good as the evaluator. erXos already
has the parts the papers build first: policy as pure Erlang functions, a
deterministic boot mode with byte-identical transcripts, and `tools/erx
bench`. Candidates are file cache eviction, readahead, memory trimming, and
how a runtime spends its CPU grant.

The addition proposed here is a fixed checker that admits a searched policy:
bounded cost per decision, no starvation on the recorded traces, and never
worse than the baseline by more than a stated margin. The checker is small
and reviewed once; the policies it admits need no review. No source was found
for this exact arrangement; PolicySmith's safety constraints and the
scheduler work's execution verifier are the nearest.

Limits: a policy tuned to recorded traces can overfit them. TCG numbers and
HVF numbers must not be mixed, as the working agreement already requires.

**First experiment:** search a file cache eviction function against recorded
access traces in deterministic mode, with the stock policy as baseline.

## Runtime heap images and template domains

A BEAM node takes seconds to start. Tyn reports about 5 s from boot to
serving HTTP and about 430 ms from kernel to BEAM handoff (opened). No
pre-initialized heap image for OTP was found, although Smalltalk, V8, GraalVM
and CRaC all start from one (memory).

Two steps are proposed.

* **A heap image in the boot image.** The build runs the system domain's
  startup once, in deterministic mode, and stores the resulting heap and
  loaded code in the boot image. Boot maps it instead of repeating the work.
  Byte-reproducible images make this checkable.
* **Template domains.** A started runtime is frozen as an immutable parent
  and each new domain is its copy-on-write child. The kernel rule already
  says a child's parent can never be written and that the child reserves
  every page it may copy. JIT code is immutable and executable, so children
  share it and no mapping becomes writable and executable.

Reported times for the same idea elsewhere: Catalyzer under 1 ms in the best
case, Faasm about 0.5 ms from a WebAssembly memory snapshot, Unikraft 3 to
40 ms to boot depending on the monitor (all search). REAP found that starting
from a snapshot is limited by page faults arriving one at a time, and that
recording the working set and loading it ahead cuts cold starts 3.7 times
([arXiv 2101.09355](https://arxiv.org/abs/2101.09355v3), search). erXos owns
its memory objects, so it can record and pre-map a template's working set.

Limits: a clone must not share what has to be unique. Random seeds, unique
references, node names and clocks need to be reset in each child. The design
today treats `fork` as an eager copy, with copy-on-write as a measured
option.

**First experiment:** in hosted mode, measure where ERTS startup time goes,
then save and restore the heap after the kernel and standard library
applications have loaded.

## A process as a value

An Erlang process has its own heap, its terms are immutable, and its code is
bytecode that does not depend on the processor. In principle a process can be
written out and read back somewhere else. No work doing this for the BEAM was
found; a mailing-list discussion lists the hard parts: stack, references to
shared binaries, links, monitors, ETS tables and ports
([erlang-questions, 2012](https://erlang.org/pipermail/erlang-questions/2012-July/068345.html),
search).

One mechanism would serve four uses: the heap image above, a checkpoint for
the durable actors of the earlier record, moving a live process to another
machine, and moving it to a machine with a different processor. The last is
where erXos has an advantage. Popcorn Linux moves native processes between
instruction sets by having the compiler emit metadata for every function and
rewriting the stack at marked points
([EuroSys 2015](https://www.ssrg.ece.vt.edu/papers/eurosys15.pdf), search). A
BEAM process has no native state except return addresses into JIT code, which
map back to a module, function and offset. Taos translated one portable code
to each processor at load time for the same reason (secondary source only).

The demonstration is a shell session, with its process tree, moving from an
AArch64 guest to a Raspberry Pi and continuing.

Limits: links, monitors and held capabilities name things on the old
machine, and a capability must never be in flight, so migration has to end at
a rendezvous on the new machine. NIF state and ports do not move. The earlier
record's Emerald and durable-actor sections cover the neighboring ground.

**First experiment:** write one suspended process with no links and no ports
to a file, restore it in a second hosted node, and resume it.

## Nested erXos

Fluke let any process act as the kernel for its children: memory, faults and
scheduling of a child are defined relative to its parent, so a debugger, a
checkpointer or a whole second system can sit in between. It measured 0 to
35% cost per layer, against 20 to 100% for a conventional nested virtual
machine
([OSDI 1996](https://www.usenix.org/legacy/publications/library/proceedings/osdi96/full_papers/hibler/hibler.txt),
opened).

erXos already has the two properties this needs. A space never outlives its
parent, and the kernel interface sits behind `liberx`, which has three
backends: erXos's kernel, Fiasco, and a hosted one. A fourth backend
implemented over erXos's own kernel calls would run a complete erXos inside a
domain.

Uses: boot the next version of the system inside the running one and feed it
copied traffic before switching; run the parity comparison of a stopgap and
its replacement on one machine; give the earlier record's speculative
branches a whole system to branch.

Limits: the nested system's guarantees are those of its parent's budget, not
its own. Whether this is worth doing before erXos's own kernel exists is an
open question, since the Fiasco backend already has the system domain serve
other tasks in much the same shape.

**First experiment:** run the hosted backend's test suite against a backend
that forwards each call to an outer hosted instance.

## Shadow versions and second implementations

Mx ran the old and new version of a program together and followed the more
reliable one when they diverged
([ICSE 2013](https://srg.doc.ic.ac.uk/publications/13-mx-icse.html), search).
It had to intercept system calls to do so. Between Erlang services the
messages are already structured values, so a shadow copy of a service can
receive the same messages in a separate domain and have its replies compared
and discarded. Hot code loading then switches with evidence instead of hope.

The same arrangement gives cheap second implementations. A June 2026
replication of the classic N-version experiment built 48 agent-written
versions and ran a million inputs
([arXiv 2606.20158](https://arxiv.org/abs/2606.20158), opened). Failures were
substantially correlated, mostly where the specification was ambiguous, and
neither a different language nor a different agent removed the correlation.
Majority voting still cut mean failures from 387 to 131. Galapagos builds
such variants and checks them for equivalence
([arXiv 2408.09536](https://arxiv.org/html/2408.09536v3), search).

The conclusion for erXos: use a second implementation as an oracle, not as a
vote. A disagreement is a finding to settle against the specification, and
disagreements cluster where the specification is unclear, which is itself
worth knowing. This is the rule the funnel already follows against
`binary_to_term/1`.

**First experiment:** run a second, independently written decoder beside one
existing parser in its fuzz target and file each disagreement.

## Formats from descriptions

The Ruby generators already produce parsers, input builders and fuzz entry
points from `abi/erx_abi.txt` and the register descriptions. Wire and disk
formats (9P, executable headers, the partition table, FAT, EROFS) are written
by hand.

EverParse generates verified, zero-copy parsers from a format description and
is used in production hypervisor code (memory). 3DGen has a model write those
descriptions from RFC text and checks them against an oracle; across 20
Internet formats, one generated description missed a constraint and symbolic
differential testing caught it
([arXiv 2404.10362](https://arxiv.org/abs/2404.10362), search).

The proposal is to extend the single-source rule to formats: each format has
one description, a Ruby generator emits the C and Erlang parser, the builder
and the fuzz target, and a drift check covers them. The property "no
hand-written parser of untrusted input" then holds by construction. Agents
draft the descriptions; the generator and the differential test are what is
trusted.

Limits: file system images are more than a grammar. Cross-references between
structures need checks a format description may not express.

**First experiment:** describe the partition table and 9P message framing,
generate both parsers, and compare them with the hand-written ones under
their existing fuzz corpora.

## Learned-model parity gate

The working agreement gates the replacement of a stopgap on parity over the
test corpus. Model learning offers a second method: drive a component with
inputs, learn a state machine of its visible behavior, do the same for the
replacement, and compare the two machines. Philips used this to check a
rewritten component against the legacy one
([Schuts, Hooman and Vaandrager, iFM 2016](https://www.cs.ru.nl/J.Hooman/IFM2016.html),
search). The same method found state-machine bugs in TLS implementations
(de Ruiter and Poll, USENIX Security 2015, memory).

For erXos the subject is the kernel interface as seen through `liberx`: the
Fiasco backend and erXos's kernel should show the same machine for the calls
both offer. Learning gives no completeness guarantee, so it adds to the
corpus comparison and does not replace it.

**First experiment:** learn the capability calls of the hosted backend and of
the Fiasco backend and compare.

## Exhaustive schedules for real services

Concuerror explores every meaningfully different interleaving of an Erlang
test ([repository](https://github.com/parapluu/Concuerror), opened). Its
supported range is listed as OTP 20.3 to 23.3, and no report of it being run
on supervisors or system services was found.

erXos checks its protocols with TLA+ models. Those check the model. The
services themselves are Erlang, and reduction counting gives the runtime
known preemption points, so the same exploration could run on the real boot
and service code in deterministic mode. The claim would be an operating
system whose service layer is checked over all schedules of a bounded
scenario, not over a model of it.

Limits: the tool needs porting to OTP 29, and the number of schedules grows
quickly, so scenarios must be small.

**First experiment:** explore the startup of three dependent services and
confirm it finds a seeded ordering bug.

## Other runtimes as supervised processes

The design leaves room for a second runtime and says none is designed without
a user. WebAssembly is the candidate that would bring one. Lunatic gives
WebAssembly instances their own heaps, preemption and supervision, as a
runtime on a host system
([repository](https://github.com/lunatic-solutions/lunatic), opened). WASI
0.3 with native asynchronous calls is reported released in June 2026
(search). No system was found in which WebAssembly modules have pids, links
and monitors that interoperate with Erlang processes.

On erXos a WebAssembly runtime would be a runtime group like ERTS, its
instances processes in the one pid space. A program in any language that
compiles to WebAssembly would be supervised, inspected and budgeted like an
Erlang process, without POSIX.

Limits: the language rule allows no Rust and no new C++, so the runtime would
be a C one fetched unmodified, or new C17. This is an ecosystem bet with no
user yet.

## Model context as a memory object

Large-file mapping and model weights are a recorded target workload. A model
that serves several agents holds, per conversation, a cache of attention
state that is expensive to rebuild. ForkKV splits that cache into a shared
base and small per-agent parts with copy-on-write and reports up to 3.0 times
throughput on GPU servers
([arXiv 2604.06370](https://arxiv.org/abs/2604.06370), opened). A proposed
Linux `branch()` call does the same for files and processes
([arXiv 2602.08199](https://arxiv.org/abs/2602.08199), opened). No work was
found that treats this cache as an operating system memory object charged to
a budget.

On erXos the cache would be a memory object: an agent's branch is a
copy-on-write child, its memory is charged to the agent's budget, and
deleting the budget frees it. That pairs with the confined AI workers and
speculative branches of the earlier record.

Limits: one paper, seen by title only, argues that keeping this cache breaks
rollback consistency for agents
([arXiv 2608.15939](https://arxiv.org/pdf/2608.15939)). The first boards have
no accelerator worth the name. This is the most speculative item here.

## Standing queries over system state

The shell already pipes records through stages such as `ps`, `where` and
`sort`. DBSP maintains the result of a query incrementally as its inputs
change, including recursive queries
([PVLDB 2023](https://www.vldb.org/pvldb/vol16/p1601-budiu.pdf), search).
PiCO QL exposed Linux kernel structures to SQL, on demand only
([EuroSys 2014](https://www.spinellis.gr/pubs/conf/2014-EuroSys-PicoQL-kernel/html/FSLB14.html),
search). No system was found that offers standing queries with triggers over
operating system state.

A shell pipeline left running would be such a query. A supervision or alert
rule ("restart when the mailbox stays above N") becomes a query with an
action. A searchable index of files, as in Gifford's Semantic File Systems
(SOSP 1991, memory), is one more maintained view. The earlier record's
BOOM section is about writing services as rules; this is about watching the
system with them.

## Smaller borrowings

* **State that survives its server.** CuriOS keeps each client's state in a
  region charged to the client and mapped into the server only while it
  serves that client; fault injection recovered 87 to 100% of manifested
  errors
  ([OSDI 2008](https://static.usenix.org/events/osdi08/tech/full_papers/david/david_html/paper.html),
  opened). The budget rule "what must outlive a party is charged to a budget
  that outlives it" is the same idea; CuriOS is a worked design for it.
* **Memory that survives a reset.** Rio protected the file cache through a
  crash and restored it after a warm reboot
  ([ASPLOS 1996](https://web.eecs.umich.edu/~pmchen/papers/chen96_1.pdf),
  search). A fault of the system domain resets the machine; domains' memory
  objects could be re-adopted afterwards instead of rebuilt.
* **A flow as one unit.** Scout made the path of one data flow through the
  system a first-class object
  ([OSDI 1996](https://www.usenix.org/conference/osdi-96/making-paths-explicit-scout-operating-system),
  search). In erXos a flow could be one supervised process tree with one
  budget, shown as one row in the inspector.
* **A standing adversary.** The results that hold up have a model write
  grammars and harnesses and a coverage-guided fuzzer find the bugs:
  KernelGPT, 24 new Linux bugs
  ([ASPLOS 2025](https://arxiv.org/abs/2401.00563), search), and ChatAFL
  ([NDSS 2024](https://ndss-symposium.org/ndss-paper/large-language-model-guided-protocol-fuzzing),
  search). erXos's call grammar already follows from the ABI source, so the
  new part is regenerating harnesses and failing the build when coverage
  drops.

## Considered and set aside

| Idea | Source | Reason |
| --- | --- | --- |
| Filters and wake-up predicates run by the kernel | DPF ([SIGCOMM 1996](https://vm-web.pdos.csail.mit.edu/~engler/dpf.html), opened); exokernel, SOSP 1997 (search); Synthesis kernel, SOSP 1989 (search) | The design rejects kernel-run programs, citing the eBPF verifier's history, and the kernel writes no machine code. Packet classification is Erlang in user mode and is compiled by the JIT there. |
| Every message handled as a transaction | VINO ([OSDI 1996](https://www.usenix.org/legacy/publications/library/proceedings/osdi96/full_papers/seltzer/seltzer.txt), opened); QuickSilver, TOCS 1988 (search); TxOS, SOSP 2009 (search) | Mostly duplicates supervision, budgets and the earlier record's speculative branches. |
| Restart in a changed environment | Rx, SOSP 2005 (search) | A cheap supervisor feature, not a direction. No recent work found. |
| A market among agents | Agoric Open Systems, Spawn, Telescript (memory); 2025 and 2026 preprints (search) | One 2026 study reports markets of LLM agents converge slowly or not at all. Hard caps and delegation already exist in the budget tree. |
| Energy as a budget | Cinder ([EuroSys 2011](https://dspace.mit.edu/handle/1721.1/67014), opened abstract) | The first boards have no per-core energy counters, so a budget would be modeled, not measured. No follow-up makes energy hierarchical. |
| Memory tagging or permission overlays per process heap | QEMU feature list ([opened](https://www.qemu.org/docs/master/system/arm/emulation.html)) | QEMU emulates memory tagging but not permission overlays. The Raspberry Pi 5's Cortex-A76 predates both (not confirmed against the processor manual). |
| Language safety in place of address spaces | Singularity, KaffeOS (search) | Conflicts with the rule that code of unknown provenance runs only in its own address space. No load-time BEAM verifier exists. |

## Suggested sequence

Three experiments are cheap, independent and use what exists: the policy
search against recorded traces, the second decoder beside one parser, and the
startup measurement that precedes a heap image. Each produces a number.

The kernel proof experiment is the one with the largest possible result and
belongs with erXos's own kernel, since the stopgap carries no erXos C17 code
to prove. Its first step, one pure state machine against its TLA+ model, can
run earlier on the host build.

Specification-first generation should be tried on one small service well
before the file system and network stack milestones, because its outcome
decides how those milestones are staffed.
