# Research ideas for erXos

erXos could become a computer whose execution can be interrogated, replayed,
branched into experiments and extended with small, bounded tools. Erlang's
messages, explicit process state, supervision and immutable values offer a
useful foundation; the microkernel supplies protection and resource boundaries.
Declarative programming and independently checked code generation could make
more of that behavior understandable and testable.

These are unadopted research proposals, not architecture contracts or roadmap
commitments. The cited work establishes the underlying techniques; their
combination and application to erXos are proposals. Novelty and performance
claims would require dedicated evaluation. The scope includes operating
systems, distributed systems, programming languages, compilers, databases and
interactive programming, with particular attention to work whose specification,
proof or integration costs might be reduced by LLMs.

The governing architecture and sequence remain [Design](design.md) and
[Plan](plan.md). Supervised drivers, live code loading and unified inspection
already belong to that design. The ideas below extend those foundations.

## Candidates and priorities

| Idea | Main attraction | Assessment |
| --- | --- | --- |
| Causal time travel across services | Follow a failure backward across application and OS boundaries | Strong flagship |
| Speculative execution branches | Test repairs against captured execution | Strong demonstration |
| Durable Erlang actors | Work survives power loss | Strong practical value |
| Confined AI workers | Useful autonomy with explicit authority and data boundaries | Distinctive application |
| Evidence-backed explanations | Ask why a request, permission or recovery behaved as it did | Good first visible feature |
| Generated conversation protocols | Specify message sequences, timeouts and failures once | Close fit with pure state machines |
| Driver synthesis from checked models | Reduce the cost of hardware support | Strong LLM engineering opportunity |
| Independently checked optimization | Search for faster implementations without trusting the generator | Strong compiler research |
| Directed fault experiments | Find small combinations of failures that break a service | Useful verification tool |
| Declarative system configuration | Derive dependency state and remove scattered coordination | Promising simplification |
| Computation near data | Send bounded jobs to the machines holding their input | Useful distributed extension |
| Disconnected federation | Continue selected work independently and reconcile later | Useful for appliances and edge systems |
| Selective intrusion recovery | Remove malicious effects while preserving legitimate work | Later payoff from history and replay |
| Programming by demonstration | Create personal tools from examples and intent | Strong LLM application |
| BOOM-style declarative OS services | Express service behavior as executable relations and temporal rules | Broad research direction |
| Hardware knowledge and configuration planning | Explain and validate whole resource assignments before applying them | Strong practical lesson from Barrelfish |
| Replaceable per-core kernels | Change kernel instances while applications continue | Distant architectural research |

## Causal time travel across the OS

Select a failed file operation and ask to move backward to the message that
caused it. The debugger follows the application into a file service and driver,
showing the relevant state transitions while excluding unrelated processes.

[CauDEr](https://www.cs.unibo.it/~lanese/newpublications/fulltext/debt2024-cauder.pdf)
provides direct Erlang precedent: causal reversible debugging permits an action
to be undone after its consequences have been undone. Its prototype supports a
subset of Erlang; covering full ERTS behavior is a substantial research task.

An erXos experiment would start with services expressed as pure transition
functions. Record input messages, selected receives, timer outcomes and external
results, then reconstruct execution in an isolated debugging domain. The
distinctive extension is a causal view spanning applications, services and
drivers through the same process model.

ETS, atomics, NIFs, code changes and nondeterministic inputs need explicit
treatment. A timestamped trace is insufficient for deterministic replay or
causal reversal. Physical effects remain outside the reversible environment.
Trace completeness and the authority of each reporter must remain visible.

**First experiment:** reproduce a message-order bug across three services,
step backward to its cause, and replay a corrected implementation.

## Speculative execution branches

Branch a service's execution and ask it to try several repairs against captured
traffic. Each branch receives recorded inputs, private state and simulated
effect endpoints. Compare behavior before authorizing a live change.

[Worlds: Controlling the Scope of Side Effects](https://tinlizzie.org/VPRIPapers/tr2011001_final_worlds.pdf)
made program state into first-class worlds whose changes could remain local or
be committed to a parent. It addressed language environments, not arbitrary OS
effects. An erXos version would therefore begin with a restricted service
contract: explicit state, messages and declared effects, contained by domains
and private namespaces.

LLMs could propose multiple repairs or configurations and evaluate them against
the same captured incident. The expensive infrastructure is shared across those
experiments.

Committing a branch is the hard boundary. Mailboxes, capabilities, sockets and
device state cannot be casually merged. Initially promote code or a validated
configuration; allow state replacement only under an explicit service contract.

**First experiment:** evaluate a queue-management repair against an overload
trace and present a behavioral diff, including proposed external effects.

## Durable Erlang actors

Selected actors could survive power loss by combining explicit state with a
durable inbox, transactionally recorded transitions and an outbox of pending
effects. Restart reconstructs the workflow from its last committed transition.

[EROS](https://sites.cs.ucsb.edu/~chris/teaching/cs290/doc/eros-sosp99.pdf)
explored transparent persistence in a capability OS.
[Netherite](https://www.microsoft.com/en-us/research/uploads/prod/2022/07/p1591-burckhardt.pdf)
provides complementary research on durable workflows and actors. An opt-in
Erlang behavior is a more manageable starting point than persisting arbitrary
BEAM heaps and native resources.

Applications include unattended appliances, downloads, configuration workflows,
build jobs, home automation and long-running agents. Durable actors need logical
identities distinct from pids. Reboot creates new pids and capabilities and
re-establishes authority; saved names do not revive authority. External effects
require idempotency or reconciliation, since a local transaction cannot ensure
exactly-once behavior from an arbitrary remote device.

**First experiment:** interrupt a multi-step file-processing workflow at each
transition and verify recovery, including uncertain external outcomes.

## Confined AI workers

A worker could analyze private documents while holding only read access to its
inputs, a local report destination and bounded resources. A stronger extension
would constrain how private information can flow through cooperating workers.

[HiStar](https://www.usenix.org/conference/osdi-06/making-information-flow-explicit-histar)
explored OS-enforced information flow through untrusted applications. For erXos,
the initial useful application is ordinary domain isolation with narrowly
granted files, budgets and output destinations. Tracking information-flow
policies across domains would be a separate architectural addition.

Capabilities alone do not stop a process that legitimately holds both private
input and an outbound channel from transmitting that input. A model can also be
tricked into making bad decisions within its authority. The useful guarantees
concern what it can access and affect. Remote inference is an external recipient
of data; confidential processing requires local inference or authorized
disclosure.

**First experiment:** run a document-analysis worker whose permitted effects
are limited to a local report, and test attempts to reach other resources once
the kernel's isolation guarantees are available.

## Evidence-backed explanations

The inspector could answer questions such as why a request took 400 milliseconds,
why a process can write a directory, or why a supervisor did not restart a
service. Answers would link to the observations and rules supporting them.

[Whyline](https://faculty.washington.edu/ajko/papers/Ko2008JavaWhyline.pdf)
investigated debugging through why and why-not questions.
[DBOS](https://people.eecs.berkeley.edu/~matei/papers/2022/cidr_dbos.pdf)
explored database representations of OS state and cross-layer history. The
erXos extension would connect messages, waits, grants, supervision, authority,
code identity and effects in a queryable relationship graph.

An LLM translates a question into constrained queries and explains their
results. Kernel observations and runtime reports retain their existing trust
distinctions. Missing events produce incomplete answers; an explanation must
not turn correlation into established causation or a compromised runtime's
report into authoritative evidence.

**First experiment:** a host tool explains a slow request using linked message,
service and scheduling records.

## Generated conversation protocols

An optional protocol description could specify legal conversations, including
reservation, transfer, acknowledgment, cancellation, timeout and participant
failure. Generate Erlang scaffolding, monitors, documentation and test scenarios
from that description.

Relevant work includes
[multiparty session actors in Erlang](https://arxiv.org/abs/1608.03321),
[TOAST's Erlang stubs and timeout monitors](https://kar.kent.ac.uk/107136/),
and [Maty](https://arxiv.org/abs/2602.24054), which studies multiple sessions and
Erlang-style supervision through a Scala implementation. These establish related
techniques, not a ready-made erXos toolchain.

LLMs could translate prose and examples into candidate protocols. Deterministic
analysis checks the formal artifact. Independent requirements and tests remain
necessary: generating both code and tests from the same mistaken model does not
provide independent verification.

**First experiment:** describe one service protocol and expose an omitted
timeout or cancellation path through a counterexample.

## Driver synthesis from checked models

The proposed pipeline is hardware manual and errata, candidate device model,
reviewed model, generated Erlang state machine and C accessors, then emulator
and hardware tests. erXos's separation between Erlang driver behavior and thin C
device access provides a natural boundary.

[Termite](https://cs.uwaterloo.ca/~brecht/courses/702/Possible-Readings/SOSP-2009/automatic-device-drivers-with-termite-ryzhyk-sosp09.pdf)
demonstrated driver synthesis from formal device and OS interface specifications.
Constructing those specifications is an important cost that LLM assistance
could reduce.

A model could propose register meanings, ordering requirements, reset sequences
and contradictions, attaching a manual reference to every claim. It could also
generate experiments that distinguish competing interpretations. Generated
hardware definitions must retain the architecture's single source of truth.

A proof against an incorrect device model establishes the wrong property.
Undocumented behavior, DMA ordering and errata need independent investigation.

**First experiment:** synthesize one small device protocol from a reviewed model
and inject missing acknowledgments and unexpected interrupts.

## Independently checked optimization

An agent on the development host could propose faster implementations of pure
parsers, queue operations, checksums or transition functions. Independent tools
check the relevant semantics; reproducible benchmarks decide whether a change
pays.

The research combines
[proof-carrying code](https://doi.org/10.1145/263699.263712),
[Alive2's bounded LLVM translation validation](https://users.cs.utah.edu/~regehr/alive2-pldi21.pdf),
[AlphaEvolve's evaluated algorithm search](https://deepmind.google/blog/alphaevolve-a-gemini-powered-coding-agent-for-designing-advanced-algorithms/),
and the [Trivet preprint](https://arxiv.org/abs/2609.19583), which combines LLMs
and Lean for checked LLVM transformation proofs. Their results do not establish
verification of arbitrary erXos code.

LLMs make candidate generation cheaper; reusable checking supplies the evidence.
Functional equivalence alone does not prove resource bounds or constant-time
behavior, and undefined behavior must be handled explicitly. Proof tooling
would be a separate development-tool decision, not a change to target languages.

**First experiment:** optimize one hot pure function with a stated equivalence
check, its limitations, and a reproducible performance comparison.

## Directed fault experiments

Given a successful operation, search for the smallest combination of failures
that would prevent its result.
[Lineage-driven fault injection](https://people.ucsc.edu/~palvaro/molly.pdf)
uses outcome dependencies to guide fault experiments; its MOLLY prototype
combines dependency information and satisfiability solving.

Recorded erXos interactions could guide experiments involving domain crashes,
delayed replies, timer races and device failures. An isolated environment would
execute the candidates and minimize failures into regression cases. Supervision
is a good target because multiple failures can interact with requests or
acknowledgments already in flight.

LLMs can propose semantic assertions and explain minimized counterexamples.
The execution engine establishes whether an experiment actually fails.
Completeness claims must name the fault model, execution bounds and supported
program subset.

**First experiment:** find a two-failure sequence that loses a request even
though either failure alone is handled correctly.

## Declarative system configuration

Represent selected observations as assertions owned by processes: a device is
present, a service offers an endpoint, a mount depends on that device, or a
session requires that service. Retracting an owner's assertions updates the
derived relationships.

[Syndicate](https://syndicate-lang.org/tonyg-dissertation/html/)
studies conversational programming with shared assertions and scoped lifetimes.
[Differential dataflow](https://www.microsoft.com/en-us/research/publication/differential-dataflow/)
offers techniques for maintaining derived results incrementally. They motivate
a small Erlang experiment in discovery and configuration; they do not require
adopting either implementation or replacing ordinary message passing.

The acceptance criterion is removal of existing coordination obligations.
Facts must remain scoped and authenticated. An assertion that a device exists
does not grant authority to access it. Retractions and failure observations need
explicit semantics.

**First experiment:** show the affected dependency graph when a device
disappears and the valid relationships when it returns. The declarative-service
proposal below develops this direction further.

## Computation near data

Submit a bounded computation to a machine holding its input instead of moving
all the data to the caller. A job carries code identity, serializable input, a
resource budget and requested authority. The destination admits it and grants
local resources.

[Emerald](https://web.cecs.pdx.edu/~black/publications/Emerald%20Mobility%20TOCS.pdf)
explored fine-grained object mobility.
[Unison](https://www.unison-lang.org/docs/the-big-idea/)
provides complementary ideas about content-addressed code. Content identity is
not execution permission.

LLMs could generate small specialized analysis jobs. Explicit jobs should come
before migration of arbitrary live Erlang processes, whose pids, monitors,
mailboxes, native resources and device ownership make migration substantially
harder.

**First experiment:** submit a query to several sensor appliances, evaluate
locally and return compact results.

## Disconnected federation

Several machines could share selected durable objects and workflows, continue
independently during partitions, and reconcile appropriate changes afterward.
[CALM](https://arxiv.org/abs/1901.01930)
connects monotonic computation with consistent coordination-free distributed
implementations: conclusions remain valid as information grows.

An opt-in service model would distinguish facts and operations that safely
accumulate from decisions requiring coordination, exclusive authority or
explicit conflict resolution. LLMs could propose classifications and merge
rules, which require independent checking.

Revocation, unique ownership and bounded shared quotas cannot simply be treated
as freely mergeable data. The research question is whether these distinctions
can be made understandable through Erlang service contracts.

**First experiment:** disconnected appliances continue recording observations
and running local tasks, then converge on shared history after reconnecting.

## Selective intrusion recovery

Reconstruct service state after excluding identified malicious operations while
preserving legitimate work that followed.
[RETRO](https://css.csail.mit.edu/6.566/2018/readings/retro.pdf)
explored dependency tracking, selective rollback and re-execution for intrusion
recovery. Durable transitions and causal history could support a narrower erXos
experiment.

LLMs could suggest suspicious activity, explain dependencies and propose repair
choices. Such suggestions remain hypotheses until corroborated. A compromised
service may falsify its own history, so guarantees depend on trustworthy record
capture. Leaked secrets, delivered email and physical effects cannot be undone.

**First experiment:** exclude a malicious configuration operation from a durable
service's history while retaining unrelated legitimate updates. This depends on
history and replay work rather than being an independent first project.

## Programming by demonstration

Demonstrate a task, describe its generalization and obtain a small persistent
tool. For example, repeated service restarts could trigger collection of recent
history, an isolated reproducer and a diagnostic report.

[Pygmalion](https://worrydream.com/refs/Smith_DC_1975_-_Pygmalion.pdf)
explored programming by demonstration.
[Bidirectional transformation research](https://doi.org/10.1145/2213556.2213568)
offers foundations for editable views whose changes map back to structured
state. erXos's consistent process, message, supervision and inspection interfaces
could make such tools easier to compose.

LLMs could make individually authored tools economical. The output should be
inspectable Erlang with tests, declared permissions and supervision. Examples
underdetermine intent; previews and counterexamples must expose incorrect
generalizations.

**First experiment:** teach a host-console diagnostic workflow using structured
records. This does not depend on a graphical desktop.

## Declarative OS services from BOOM and Dedalus

erXos's user-mode services are a message-passing system with separate owners,
asynchronous events and failures. That makes the
[BOOM research program](https://boom.cs.berkeley.edu/)
relevant to implementing OS services as executable rules over state and events.
BOOM Analytics used Overlog for its Hadoop and filesystem work. Dedalus supplied
a cleaner temporal foundation for Bloom, which explored a practical programming
interface. These names identify related but distinct contributions.

An ordinary Erlang handler receives an event, updates state, sends messages and
sets timers. A declarative service describes which requests and results exist,
what state persists, which conclusions follow and which actions are required.
[Dedalus](https://db.cs.berkeley.edu/papers/datalog2011-dedalus.pdf)
distinguishes deduction within a logical step, transitions to subsequent steps
and asynchronous communication. Logical steps are local to participants; they
do not imply a global clock.

### Application areas

| Area | Rule content | Suitability |
| --- | --- | --- |
| Boot and service dependencies | Prerequisites, eligibility and blocked services | Good first experiment |
| Device configuration | Compatible drivers, resource constraints and valid assignments | Direct OS precedent |
| Filesystem metadata | Namespace relationships, replication and outstanding operations | Substantial research project |
| Network control | Routes, reachability, neighbor state and policy | Natural fit |
| Service protocols | Requests, acknowledgments, retries and completion | High potential |
| Inspection | Dependencies, authority paths and failure impact | Useful early |
| Kernel operations | Dispatch, allocation and capability enforcement | Poor first target because execution bounds are harder |

[Barrelfish's device configuration work](https://barrelfish.org/publications/barrelfish_asplos11.pdf)
used constraint logic programming for PCI configuration, resource allocation and
interrupt assignment while keeping register operations in C. Constraint solving
differs from Dedalus's distributed rules, but provides direct evidence that
declarative logic can perform OS configuration work.
The [Barrelfish discussion](#barrelfish-and-declarative-hardware-management)
develops the hardware model, trust boundaries and possible erXos experiments.

### Example and the meaning of absence

Illustrative Datalog-like rules for startup dependencies are:

```text
blocked(Service, Dependency) :-
    requires(Service, Dependency),
    not ready(Dependency).

eligible(Service) :-
    desired(Service),
    not blocked(Service, _).
```

The same relations can explain why a shell has not started: its namespace
service depends on storage, which lacks a ready block device.

The rules require a defined local snapshot and a known dependency set. Absence
of a readiness report from an asynchronous participant does not establish that
the participant is unavailable. A delayed observation and a negative observation
must remain distinct. Readiness also needs an incarnation or other freshness
contract so a report from a dead instance cannot authorize work with its
replacement.

Eligibility is not a process creation operation. A lifecycle owner admits a
startup attempt, records it and handles its result. Repeated evaluation must
not repeatedly start the same service. The rules above illustrate a query, not
a complete lifecycle protocol.

### Integration with erXos

The proposed flow is:

```text
Validated messages and observations
                 |
                 v
      Service-owned relations
                 |
                 v
      Pure rule evaluation
                 |
                 v
      Next state and action plan
                 |
                 v
Erlang effects through existing interfaces
                 |
                 v
      Results become observations
```

Each service owns its relations. Cross-domain facts arrive through existing
authorized message paths. A globally shared database of authoritative OS state
is not required. The evaluator fits the functional core; effects retain their
existing owners and interfaces.

Several distinctions must remain explicit: a fact describing a capability is
not that capability; reported state is not necessarily authoritative; a proposed
allocation is not a grant; and a derived action is not a completed action.

A restricted representation compiled into readable Erlang is one possible
implementation. Erlang terms versus a separate source language is an explicit
design decision under the project's language rules. The historical Bud Ruby
runtime would not belong on the target. ABI layouts and constants retain their
existing source rather than being duplicated in a rule specification.

### Generated reclamation with Edelweiss

[Edelweiss](https://www.neilconway.org/docs/vldb2014_edelweiss.pdf)
lets supported programs accumulate and exchange immutable information, then
analyzes when that information can safely be reclaimed. It generates
acknowledgment and reclamation machinery for supported patterns, including
communication and replicated-storage examples.

The erXos research question is whether a service can describe the information
it needs while a compiler derives when request records, acknowledgments and
intermediate state may be discarded. This could remove cleanup obligations
spread across handlers, rather than merely shorten their code.

Explicit admission control and storage bounds remain necessary. Automatic
reclamation does not bound memory while peers stop responding. Reclamation
also needs to account for any separately promised replay or audit retention.

### Limits and verification

* **Order independence is conditional.**
  [Bloom's consistency analysis](https://dsf.berkeley.edu/jmh/calm-cidr-short.pdf)
  identifies logic that tolerates reordered information and points where
  coordination may be needed. It does not establish every service invariant.
* **Exclusive resources need an owner.** Device assignment and allocations
  require authoritative decisions. Distributed observations do not replace
  that authority.
* **Evaluation needs resource limits.** Recursive joins can create large
  intermediate relations. Finite evaluation is not a latency or memory bound.
  Incremental execution, request accounting, limits and failure behavior belong
  in the service contract.
* **Effects need explicit protocols.** Packets, disk writes and authority
  transfers require identities, outcomes and recovery behavior. Re-evaluation
  must not silently repeat irreversible actions.
* **Verification needs independent evidence.** A generated implementation and
  tests derived from the same wrong rule can agree. Separate invariants, models
  and behavioral comparisons remain necessary.

### LLM assistance and first experiment

A constrained rule artifact gives an LLM something inspectable to propose and
revise. Deterministic tools can report unsafe variables, unsupported recursion,
contradictory constraints and counterexample executions. A useful development
loop is requirements, candidate rules, analysis and fault experiments,
counterexamples, and revised rules.

The first experiment would derive boot and service eligibility from the existing
manifest and captured lifecycle observations, initially without controlling the
live machine. Compare the concepts, failure cases, cost and explanations with
a straightforward Erlang implementation. Extend to one bounded request protocol
only if the experiment removes coordination obligations and improves clarity.

## Barrelfish and declarative hardware management

Barrelfish explored organizing a multicore computer as a distributed system,
with explicit communication and hardware knowledge used to choose mechanisms
and configurations. Its research offers several separable ideas; adopting its
configuration techniques does not require adopting its kernel architecture.

### Multikernels and explicit ownership

[The Multikernel](https://barrelfish.org/publications/barrelfish_sosp09.pdf)
organizes OS state across cores using local ownership, explicit messages and
replication protocols. Its motivation is that shared-memory operations already
cause communication through cache coherence, but hide that communication behind
loads, stores and locks. Explicit protocols permit batching, pipelining and
communication patterns chosen for the hardware topology. Applications can still
share memory.

A microkernel separates privileged mechanisms from other services; a multikernel
separates OS state and execution across cores. These are distinct architectural
questions. For erXos, explicit ownership is useful guidance, while replicated
kernel state would be a major design departure requiring evidence that it pays.
Replication introduces consistency and revocation obligations of its own.

### Trust boundaries

Barrelfish's per-core privileged component is a CPU driver. User-mode monitors
coordinate cross-core operations. Those monitors are trusted: they can
reconstruct capabilities during transfers and participate in distributed
revocation. User-mode placement does not remove them from the trusted computing
base. [Barrelfish overview](https://barrelfish.org/publications/TN-000-Overview.pdf)

erXos's target architecture places mechanisms on which domain isolation depends
in the kernel. Barrelfish's monitor authority model therefore cannot be imported
as an ordinary service implementation. Its protocols remain useful comparative
research without changing erXos's trust placement or capability-transfer rules.

### System knowledge as explicit data

Barrelfish's System Knowledge Base combines discovered hardware information,
measured communication costs and supplied facts such as platform quirks. Its
queries support topology-aware choices about driver placement, transports and
memory. The initial implementation used ECLiPSe constraint programming.
[Multikernel paper, section 4.9](https://barrelfish.org/publications/barrelfish_sosp09.pdf)

An erXos experiment could represent devices, memory regions, resource
requirements, permitted placements and configuration constraints as data. Facts
would record their source and freshness. Measured performance would remain
distinct from hardware guarantees, and observed ownership would remain distinct
from authority to change it.

The knowledge service would help explain and plan operations; existing owners
would still authorize and execute them. In particular, the PCIe domain's
enumerator would retain exclusive configuration-space access. The model should
derive hardware definitions from their existing sources rather than introduce a
second register or ABI specification.

### Configuration as a complete plan

[Barrelfish's PCI configuration work](https://barrelfish.org/publications/barrelfish_asplos11.pdf)
expresses constraints such as alignment, non-overlap, fixed reservations and
bridge reachability, then separates solving the assignment from register
operations. The useful erXos extension is a complete candidate plan that can be
checked before any hardware changes occur.

| Technique | Question it answers |
| --- | --- |
| Dedalus or Bloom-style temporal rules | What state and messages follow from these events? |
| Constraint-based configuration | Which resource assignment satisfies the hardware and policy constraints? |
| Authorized effect execution | Is this plan still valid, and how is it applied or safely abandoned? |

These techniques could complement one another. A valid assignment alone does
not establish a safe transition from the running configuration. Hotplug,
concurrent ownership changes and device failures require revalidation, device
quiescence where necessary, and defined partial-failure handling. Solver
deadlines and explicit refusal are preferable to leaving configuration work
unbounded.

### Connecting hardware descriptions to accessors

[Mackerel](https://barrelfish.org/publications/TN-002-Mackerel.pdf)
generates C accessors and diagnostic formatting from device descriptions. Its
documentation covers register access properties and the portability problems of
its older C-bitfield representation.

erXos already requires generated accessors. A further experiment would connect
the descriptions to configuration facts and constraints:

```text
Hardware descriptions
          |
          v
Facts and configuration constraints
          |
          v
Independently validated configuration plan
          |
          v
Authorized owner applies it through generated accessors
```

Correct accessors do not compensate for an incorrect hardware model. LLMs could
propose model additions from manuals and errata, with source references;
deterministic checks and hardware experiments would establish their validity.
Diagnostic reads also need to respect device side effects, including registers
whose reads clear state.

### Replacing a running kernel instance

[Barrelfish/DC](https://barrelfish.org/publications/zellweger-decoupling-cores.pdf)
decouples physical cores, kernel instances and application state. It demonstrates
replacing kernel code on a core, moving kernel state and adding or removing
cores while applications continue. Explored uses include online kernel upgrades
and specialized kernels for temporary hard real-time execution.

For erXos this is a distant research option. Capability identity, interrupt
ownership, accounting and protection invariants must survive any replacement.
The kernel's single CPU authority must also remain intact. Service-level live
updates offer a cheaper first benefit; replaceable kernels would need a separate
design and a use that justifies their coordination costs.

### Scheduling across kernel and runtime

[End-to-End Multicore Schedulers](https://barrelfish.org/publications/barrelfish_hotpar10.pdf)
argues for scheduling that considers hardware, the kernel, runtimes and
applications together. This is relevant comparative work for erXos's two-level
scheduler. erXos's explicit choice remains kernel-enforced grants, runtime
scheduling within those grants, bounded hints and no arbitrary runtime re-entry.

### First experiment and evaluation

Build a host-side configuration planner for a small captured device topology.
Derive its inputs from existing descriptions, produce a complete assignment and
validate it independently. Explain a refused configuration by identifying the
conflicting constraints. Include fixed reservations, insufficient space and an
invalid proposed assignment in the evaluation.

Compare its concepts, ownership rules, validation effort and runtime cost with
a straightforward Erlang planner. Integrate live hardware effects only if that
comparison supports the additional machinery. This experiment complements the
boot-dependency query experiment without requiring a multikernel or a new
target-language runtime.

[Tackling OS Complexity with Declarative Techniques](https://barrelfish.org/publications/schuepbach-declarative-os.pdf)
provides deeper reading on the knowledge-base and configuration approach.

## Suggested experimental sequence

One connected sequence would begin with an evidence-backed inspector, add replay
and speculative branches for a single pure Erlang service, then let an agent
propose and demonstrate repairs in those branches. The flagship demonstration
is a failed request whose causal chain can be explained, reproduced, repaired
in isolation and subjected to fault variants before presenting the evidence
for a live change.

A separate small experiment in declarative dependency planning would test
whether BOOM-style rules simplify the service model. Success would justify a
bounded protocol experiment and investigation of generated reclamation.
The hardware configuration planner is another bounded experiment, with captured
topologies and independent plan validation before live device integration.

These experiments should preserve the working-system-first roadmap and existing
seams. Host tools and trusted Phase 1 workloads can establish usefulness early.
Claims about hostile-code confinement, enforced budgets and kernel guarantees
wait for the corresponding properties of erXos's own kernel. No proposal here
requires hardening a stopgap or deploying it outside the project's rules.
