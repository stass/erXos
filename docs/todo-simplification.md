# Simplification candidates

These are proposals to evaluate, not changes to the target architecture.
An adopted decision belongs in its design document; an experiment with a
scheduled gate belongs in [the roadmap](plan.md#simplification-experiments).
Remove an item here when its decision is recorded. Existing limitations
are not implementation tasks merely because a different design is possible.

* **[Medium] privileged frontends: isolate host and interactive parsing.**
  A frontend with narrow grants to policy can reduce the authority exposed
  to a parser defect. Measure its extra runtime footprint and round trips;
  retain the existing host-link and console protocols. Owner:
  [live machine](design-live.md).

* **[Low] inspection: causal explanations.**
  Derive explanations of waits, quota exhaustion, retained resources and
  unknown outcomes from the inspector's existing schema. Shell, host UI
  and `/proc` should expose the same evidence, with reporter provenance and
  scope checks. Include the effective DMA protection profile. The decision
  test is whether an operator can diagnose a failed operation without
  reconstructing its protocol. Owner: [inspection](design-live.md#inspection).

* **[Medium] the plain scheduler configuration as the target.** Specify C1 with
  park and wake and S1 to S4 as the target and keep C2's features as
  proposals until G8; five grant fields instead of ten; a kernel-set
  ready bitmap in place of the ready list; synchronous signal delivery at
  library boundaries in place of vCPU upcalls. Owner:
  [the scheduler](design-scheduler.md#performance),
  [signals](design-programs.md#signals-in-liberx).
  Also evaluate a runtime fallback to the plain configuration, freeing
  executor slots at space stop, and machine-wide slice and grace values.
  Synchronous signals lose delivery to a thread computing without library
  calls; test that compatibility cost against the named application corpus.

* **[Medium] request lifetimes: reuse a small pure protocol core.**
  Compare file flushes, program replies, host-link windows and code
  activation for common commit, retry and abandonment semantics. Reuse
  only where the states and ownership obligations agree; do not add a
  universal RPC layer. The benefit is fewer independent lifetime rules;
  the cost is coupling otherwise separate protocols. Owner:
  [system services](design-system.md).

* **[Medium] protocol schemas: generate repetitive protocol tables.**
  Evaluate small Ruby-generated transition tables only
  where they make a protocol easier to read than its handwritten pure core.
  Service stubs and wire codecs follow [the generation design](design-generation.md).
  TLA+/TLC independently models the contract; generation never supplies both the implementation and its sole
  expected answers. The cost is a generator and another representation to
  review; no general protocol language is assumed. Owner:
  [protocol verification](design-verification.md).

* **[Medium] rings: one bounded queue primitive.** Evaluate a common ring
  and doorbell core for connections, pipes and driver queues, using sDDF's
  ownership model. It could reduce publication and wakeup mechanisms but
  must preserve each protocol's distinct ordering and holder semantics.
  Decide from conformance tests and matched workload measurements. Owner:
  [connections](design-domains.md#connections), [pipes](design-pipes.md).

* **[Medium] C verification beyond the budget and capability pilot.**
  Evaluate the funnel's verdict over a bounded export table if the CBMC
  pilot demonstrates useful assurance at maintainable cost. State input,
  compiler and concurrency assumptions, retain an independent oracle, and
  report bounded results as bounded. The benefit is checking the actual
  admission code; the cost is a larger harness and model-to-code maintenance.
  Owner: [protocol verification](design-verification.md#focused-tool-evaluations).

* **[Medium] authority oracle: Capsicum's API and test corpus.** Evaluate
  FreeBSD Capsicum as an independent reference for descriptor confinement
  and rights reduction in the POSIX personality. It could expose authority
  gaps that functional libc tests miss; classify differences against
  erXos's explicit authority model rather than adopting an API wholesale.
  Review fixture licences before importing tests. Owner:
  [native programs](design-programs.md).

* **[Medium] pipes: a broker for multiple holders.** Compare a bounded
  user-space broker with the direct rings' ordering and reader-lock
  machinery on shell and build workloads. Keep the single-reader,
  single-writer fast path. The broker costs copies and scheduling but
  could remove shared-state recovery. Owner: [pipes](design-pipes.md).

* **[Low] identity exhaustion: structural incarnation identity.** Evaluate
  a complete identity and OTP encoding design before promising indefinite
  uptime. Safe exhaustion remains the contract; widening a C field alone
  cannot change the external term format's 32-bit creation. The cost is
  changes across identity, stale-reference checks and distribution. Owner:
  [domain identity](design-domains.md#domain-ids-pids-and-references).

* **[Medium] fork maintenance: advisory comparison without upstream merges.**
  Evaluate a reproducible source-to-origin map and an inventory of modified
  subsystems for comparing security advisories with owned forks. This
  preserves ordinary in-tree edits while reducing the chance of missing a
  relevant upstream fix; it adds development tooling and recurring review.
  Owner: [dependencies](design.md#dependencies).

* **[Low] design scope: a smaller core and separate gated proposals.**
  Evaluate whether mechanisms awaiting experimental gates should live here
  as proposals instead of in the target design. The benefit is fewer
  conditional contracts to keep consistent; the cost is less detail in
  subsystem designs until a gate decides. This does not change the target
  or move any mechanism without a decision. Owner:
  [decision gates](plan.md#decision-gates).

* **[Medium] secrets: a stronger placement and cache-sharing profile.**
  Evaluate optional placement restrictions for secret-bearing workloads
  against time-protection research. CPU quotas and cpusets alone do not
  establish timing confidentiality. Require supported hardware and an
  explicit threat model before claiming a stronger property. Owner:
  [threat model](design.md#threat-model).

* **[Low] inspection: report the trusted-base fraction.** Report kernel,
  trusted runtime and library code as a fraction of the whole image, with
  the trust boundary and counting method stated. This could make changes
  to the trusted base visible; line counts alone are not a security proof.
  Owner: [inspection](design-live.md#inspection).

The roadmap owns the hosted measurements of E-D1 and gate GP.
[TODO](../TODO.md) separately tracks live-code activation, security
wording and POSIX gaps; those items are not duplicated here.
Application compatibility is decided against a named corpus at the
personality's gates.

Longer-range research includes execution-capacity handoff within one
principal and capability hardware for native compartments. The [architecture
evidence](research-architecture.md)
records their sources and limitations. They become experiments only when a
measured bottleneck or a supported hardware target supplies a reason; they
are not prerequisites for the working system.
