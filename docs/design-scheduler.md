# The scheduler: CPU grants and runtime schedulers

erXos schedules in two levels. The kernel's scheduler, the first level,
decides which thread runs on each CPU and charges every nanosecond to a
**group**, a kernel object that holds a **grant**: a CPU-time quota per
period, a set of CPUs, an urgency ceiling and an advised capacity. A
runtime, the second level, owns the threads of a group that run its
lightweight processes, the **executors**, and decides which of its
processes runs on each of them. ERTS is the first runtime; a native
program or a device shim in a sub-space has worker threads in a group of
its creator's tree and needs no runtime. The kernel never sees an Erlang
process, never calls into a runtime, and never runs a runtime's scheduler
on a stack it interrupted: it preempts an executor like any thread and
later resumes it exactly where it stopped. Everything it tells a runtime
is a value in a shared page that the runtime reads at its own safe
points. Grants are therefore an accounting and concurrency-control
mechanism, not scheduler activations, and plain one-to-one scheduling of
executors is the same mechanism with every group feature switched off. The
architecture is in [design.md](design.md); kernel objects, capabilities and the
kernel-call conventions are in [design-kernel.md](design-kernel.md); ERTS
as a runtime is in [design-runtime.md](design-runtime.md); cross-domain
messages, whose wakeups this document delivers, are in
[design-domains.md](design-domains.md).

Decisions every reader of this document needs:

* **One CPU-time authority, many runtime schedulers.** The kernel alone
  decides which thread runs on a CPU and for how long. Each runtime
  decides which of its lightweight processes runs on the executors the
  kernel runs. There is no kernel object per Erlang process.
* **Executors are ordinary preemptible threads.** A kernel preemption
  saves an executor's registers and later restores them; no runtime code
  runs at preemption. Wakeups, capacity changes and yield requests are
  values in shared pages, read by the runtime at its safe points. No
  executor ever takes an upcall: a worker of a POSIX program takes its
  signals through Fiasco's vCPU interface, and the kernel refuses to arm
  an executor for it.
* **An executor never waits on anything outside its own domain.** The only
  blocking call an executor may make is `erx_park`, which waits until an
  IRQ object bound to its group fires, its group's capacity changes or
  its runtime wakes it. Every other blocking kernel call fails on an executor
  with `ERX_EWOULDBLOCK`, except a umtx wait on the domain's private
  memory. Blocking work runs on **worker** threads. So no runtime loses an
  executor to a slow server, a device or another domain, and no wait-for
  cycle can connect executors of different domains.
* **IRQ objects are the only doorbells.** A frame on a connection's lane, a
  pipe, a program's channel or a device rings a runtime through an IRQ
  object bound to the runtime's group with a label, as Fiasco binds an IRQ
  object to a thread. Triggering one lists it on the group's ready list,
  advances the group's epoch and wakes one parked executor. Apart from a
  capacity change, which the kernel announces the same way, nothing else
  wakes a group from outside.
* **Budgets are enforced; hints are not trusted.** A group's quota caps
  the CPU time of every thread in it, across all CPUs, whatever its
  runtime reports. What a runtime publishes (urgency, deferral) is
  clamped or bounded by limits the runtime cannot change.
* **A group never exceeds its parent.** Groups form a tree of at most
  eight levels. A thread runs only while every group on its group's path
  has quota left; its CPUs are the intersection of the cpusets along that
  path; and its urgency never exceeds the lowest ceiling along it.
* **There is no donation: every thread is charged to its own group.** A
  thread's time goes to the group it was created in and to every group
  above it, whoever the thread works for. A server answering a call
  through an IPC gate runs on its own group's grant and at its own
  urgency; a service that serves other domains runs on its own group's
  grant, which policy caps and sizes for the domains it serves. No kernel
  call, IPC transfer or shared-page field names another group to charge,
  so a decision resolves nothing but the thread's urgency, and no thread
  ever falls back from someone else's quota to its own
  ([Service work](#service-work)).
* **Enforcement, admission and attribution are three contracts.** The
  kernel enforces: no group spends beyond its grant, and every thread
  spends its own group's, whatever a runtime does. A policy admits: a
  service's facet process for a client admits that client's requests only
  while the reductions they cost, measured by the service's runtime, are
  within the client's share per period, and the client's lane bounds what
  it has in flight. A runtime attributes: the same per-client account,
  which the service's runtime reports to the inspector; the kernel
  enforces none of it.
* **Every cooperation feature has an off switch.** Published urgency,
  deferred preemption, executor status words and idle-first wake placement
  are flags of each group, masked by a boot argument. With all of them off
  and no quotas, the kernel schedules executors one to one at fixed
  urgencies: the baseline every feature is measured against
  ([Performance](#performance), [plan.md](plan.md)).

## Context

A machine running erXos holds three kinds of work:

* **Lightweight processes.** Erlang processes in ERTS domains, the
  system services and the drivers among them. Their runtime switches
  between them without entering the kernel: an Erlang process's state
  lives on its heap, and a switch is a few loads and stores
  ([research](research-erts-internals.md)).
* **Native threads.** Programs in sub-spaces of their sessions, device
  shims in sub-spaces of their driver's domain, and the helper threads of
  runtimes (ERTS's dirty I/O schedulers among them).
* **Kernel work.** System calls and interrupt entries, each run on the
  kernel stack of the thread that made the call or was interrupted and
  charged to it; a thread that waits in the kernel sleeps on its own
  stack, as in Fiasco's preemptible kernel
  ([design-kernel.md](design-kernel.md#execution-model-and-locking)).

The user's requirement is "make real kernel threads and internal light
erlang threads visible to the main scheduler and have it schedule across
all of them", and the architecture states the means: "The kernel allocates
CPU time to native threads and to runtime groups, and each runtime, ERTS
first, schedules its own lightweight processes within its grants." The
kernel therefore schedules threads, of which executors are one class, and
a runtime schedules processes inside the time its executors receive. The
kernel sees a runtime's demand through its executors: an executor that is
not parked has work.

This is two-level scheduling, and its history argues for care. Scheduler
activations (Anderson et al., 1991) let the kernel allocate virtual
processors to an address space and upcall the runtime whenever one blocked,
woke or was preempted. NetBSD implemented them and replaced them with
one-to-one threads in 5.0; FreeBSD's related KSE lost to its one-to-one
`libthr`, which became the default in 7.0, and kernel KSE was removed from
its development branch on 2008-03-12.
The implementers name the costs: upcalls that re-enter a user-level
scheduler while it is inside a critical section, replacement activations
that must be preallocated so that blocking cannot recurse, signal delivery
across two schedulers, and a joint ownership of every execution context by
two schedulers
([research](research-hierarchical-scheduling.md#negative-evidence)).

erXos keeps the structure that works and drops the mechanism that failed.
ERTS already multiplexes many processes over a few native threads on every
host operating system; what erXos adds is a kernel that knows which threads
belong to which runtime, charges them to grants, and lets cooperation be
measured feature by feature. The rules that keep it clear of the historical
failures are the user's, adopted whole:

1. Every runtime executor is an ordinary, preemptible kernel thread.
2. A kernel preemption never invokes a user-level scheduler on the
   interrupted executor's stack.
3. Wakeups and resource-allocation changes are delivered as queued events
   that runtimes process at safe points.
4. Executors use nonblocking communication; potentially blocking
   operations run on separate native threads.
5. The kernel enforces CPU budgets independently of runtime hints.
6. There is no donation: every thread is charged to its own group.

The price of keeping lightweight processes invisible to the kernel is real
and accepted: the kernel cannot give a single Erlang process a deadline or
a priority that its runtime does not publish. erXos narrows the gap one
way: an executor publishes the urgency of the most urgent work it holds,
and the kernel honours it within the group's ceiling
([Algorithms and behavior](#algorithms-and-behavior)). How a runtime
orders its own processes is its own policy within its own grant. Strict
per-process deadlines across untrusted runtimes are a non-goal, and so is
a client's progress through a service whose own grant is spent: the
policy that sizes grants prevents that, the kernel does not repair it
([Service work](#service-work)).

**Mechanisms this design builds on.**

* Fiasco's scheduler: per-CPU fixed-priority ready queues with round robin
  within a level (`Ready_queue_fp`, `src/kern/ready_queue_fp.cpp`), a
  scheduling context per thread, and per-CPU requests for cross-CPU
  operations, at commit `50bbe8a9`
  ([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)).
* Fiasco's IPC gates, each bound to one thread, at which callers queue by
  priority (`Receiver::_sender_list`, a priority list), and its IRQ
  objects, each bound to a thread with a label; erXos also binds an IRQ
  object to a group
  ([design-kernel.md](design-kernel.md#ipc-gates),
  [design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)).
* Fiasco's vCPU interface, through which a worker of a POSIX program takes
  its signals; no executor is ever armed for it
  ([design-kernel.md](design-kernel.md#vcpu-upcalls)).
* The scheduling constraints of the L4Re microkernel, which cap groups of
  threads conjunctively, and Resource Containers' separation of the
  resource principal from the protection domain, which lets a domain hold
  more than one group ([research](research-hierarchical-scheduling.md)).
* Genode's split of resource accounting: memory per session, CPU by quota
  and priority per component, and no CPU donated per request ([research
  record](research-architecture.md#systems-and-mechanisms)).
* ERTS's own scheduler, which stays the scheduler of Erlang processes: run
  queues with four priorities, reductions, work stealing, dirty schedulers
  and thread progress ([design-runtime.md](design-runtime.md#scheduling)).
* The measured costs of crossings on the primary host: about 22 ns for a
  minimal trap from user mode and return and about 31 ns with an
  address-space switch under HVF
  ([research](research-baselines.md#exception-and-address-space-switch-costs)),
  and Fiasco's null system call at 29 ns and vCPU round trip at about 140 ns
  on the same host
  ([research](research-hierarchical-scheduling.md#fiasco-under-hvf)).

## Requirements

Functional requirements:

1. **Every ready thread runs.** Within an urgency level and within its
   group's quota, no ready thread waits forever. Sustained work at a higher
   level can starve a lower one; that is what levels mean, and quotas bound
   it.
2. **Isolation between groups.** A group's CPU time per period, summed over
   all CPUs, never exceeds its quota by more than one accounting quantum
   per CPU, whatever its threads or its runtime do.
3. **Hierarchy.** A group's limits never exceed its parent's: quota,
   cpuset and ceiling are intersected along the path to the root.
4. **Runtime contract.** A runtime can create executors, park and wake
   them without losing a wakeup, learn which IRQ objects bound to its
   group fired and what capacity it has, and learn when the kernel wants
   an executor back, all without an upcall into an executor.
5. **Executors never block outside their domain.** The kernel refuses
   every blocking call on an executor other than `erx_park` and a umtx
   wait on private memory.
6. **Urgency.** A runtime may publish, per executor, the urgency of its
   most urgent work; the kernel honours it within the group's ceiling. A
   thread made ready at a higher urgency than the thread running on its
   CPU preempts it at once.
7. **Own-group charging.** Every nanosecond a thread runs is charged to
   the thread's own group and to every group above it, whoever the thread
   works for, so a service's grant bounds what its clients together can
   make it spend, and a client's grant is spent only by the client's own
   threads.
8. **Capacity.** A policy holder can tell a runtime how many CPUs of
   sustained concurrency to expect, and the runtime learns of a change at
   its next safe point.
9. **Off switches.** Each cooperation feature can be disabled per group and
   machine-wide, and the scheduler with all features disabled is plain
   fixed-priority round robin over threads.
10. **Observability.** Per group and per thread: CPU time, throttling,
    preemptions, grace overruns, parked and ready executors, all visible
    to the inspector as kernel-reported values
    ([design-live.md](design-live.md#inspection)).
11. **Determinism.** In deterministic mode the sequence of dispatches is a
    function of the inputs.

Non-functional requirements:

* **Decision cost.** A pick or an enqueue costs at most 150 ns on one CPU
  under HVF, including the walk of a group path of four levels (a budget
  from the cost model in [Performance](#performance)).
* **Wake latency.** An executor woken for an idle CPU starts within 20
  microseconds under HVF (an estimate: an inter-processor interrupt plus
  the exit from the CPU's wait for an interrupt; [plan.md](plan.md)
  measures it).
* **No allocation on the scheduling path.** Pick, enqueue, charge, park,
  trigger and wake allocate nothing. Per-group, per-CPU state is allocated
  when a group is created and charged to the creator's budget.
* **Scale.** Up to 64 CPUs, 64 executors per group, eight group levels,
  and as many groups and threads as budgets allow.
* **Host-testable core.** Pick, charge, throttle, replenish, the park
  protocol and deferred preemption are pure functions or pure state
  machines over plain data, built for the host. The park and wake
  protocol and deferred preemption are explored exhaustively on small
  configurations.

Non-goals:

* Per-process deadlines or priorities enforced by the kernel inside an
  untrusted runtime.
* Kernel load balancing. Threads move between CPUs only when they wake
  (placement) or when their affinity changes.
* Weighted proportional sharing between groups at one urgency level.
  Quotas cap and policy sizes capacity; weights are an alternative kept
  in [Alternatives considered](#alternatives-considered).
* Core scheduling against SMT side channels: the supported platforms have
  no SMT.
* Gang scheduling of a runtime's executors. ERTS has no stop-the-world
  phase, since it collects each process's heap alone; its thread-progress
  and code-loading barriers wait for every executor to pass a safe point,
  which a preempted executor delays but never breaks, and capacity advice
  keeps a domain's executors within the CPUs it is given, so that they are
  rarely preempted. Experiment X7 of
  [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md#further-experiments)
  measures barrier latency under oversubscription and would reopen this.
* CPU donation: a thread running on another group's time, whether a
  server on its caller's grant or a service on a client's. Kept in
  [Alternatives considered](#alternatives-considered).
* CPU hotplug.

## Overview

```text
   domain "web" (ERTS)                         sub-space: a program of a session
  +-----------------------------------+       +------------------------+
  | ERTS scheduler (L2): run queues,  |       | worker threads         |
  | priorities, reductions, stealing  |       | (may block: IPC gates, |
  |   executor 0   executor 1  ...    |       |  IRQ objects, umtx)    |
  |   dirty I/O workers               |       |                        |
  +----+-----------+------------------+       +-----------+------------+
       |  control area (runtime writes: urgency, defer)
       |  status area  (kernel writes: epochs, ready count, capacity,
       |                executor states, yield requests, usage)
       v           v                                      v
  +--------------------------------------------------------------------+
  | kernel scheduler (L1), per CPU: ready queues by urgency 0..63,     |
  | round robin within a level; quota check up the thread's group     |
  | path; one-shot timer at the earliest of slice end, quota           |
  | exhaustion and timer expiry; park and wake; deferred preemption    |
  |                                                                    |
  | group tree:  machine -> principal "alice" -> domain "web" -> erts  |
  |                                          \-> session "sh" -> ...   |
  +--------------------------------------------------------------------+
```

**Threads, groups and runtimes.** Every thread belongs to one space and
one group. Its space is its domain's address space and capability table,
or a sub-space that its domain created
([design-kernel.md](design-kernel.md#creating-spaces)), whose threads the
creator places in groups it holds, so they run within the domain's grants:
a session's programs run in the session's group tree
([design-programs.md](design-programs.md#a-program-is-a-port)). A thread
is an **executor** or a **worker**, fixed when it is created. A runtime
owns its group's executors and maps the group's two shared areas: the
**control area**, which the runtime writes, and the **status area**,
which only the kernel writes. A group's position in the tree carries its
limits: the system domain creates one group per domain under the
domain's principal ([design-system.md](design-system.md#creating-a-domain)),
and a domain may hold more than one group when its parts need different
grants, such as an ERTS runtime and a native helper, or a runtime of its
own in a sub-space. A group serves one runtime: its executors at any
moment belong to one space, since `erx_thread_create` refuses an executor
for a group whose executors belong to another space that has not stopped,
and only executors take its ready list, so a sub-space's runtime never
takes its creator's wake-ups. A group whose executors' space stopped
serves the next runtime at once, as `exec` needs: from the stop on, the
old executors count for no rule, take no wake-up and give up their slots
to the next runtime's executors ([Park and wake](#park-and-wake)).

**What the kernel decides.** On each CPU the kernel keeps ready queues by
**urgency**, a level from 0 to 63. It runs the most urgent ready thread
whose group path has quota left, round robin within a level, for at most
one slice. It charges the elapsed time to the thread's own group and to
every group above it. When a group's quota for the period is spent, its
threads on that CPU, and those of the groups below it, wait until the
next period starts.

**What the runtime decides.** Which lightweight process runs on each
executor, when to park an executor that has no work, how many executors to
keep active, and which urgency to publish for each executor. It reads the
kernel's values at its safe points: ERTS reads them each time it returns
to its scheduler loop, between processes.

**End-to-end flows.**

* *A message arrives for an idle domain.* The sending domain writes a
  frame into its lane of the connection between the two domains and triggers
  the lane's **doorbell**, an IRQ object bound to the receiving domain's
  group ([design-domains.md](design-domains.md#connections)). The kernel lists
  the doorbell on the group's ready list, advances the group's epoch and
  wakes one parked executor. The executor returns from `erx_park`, finds
  the lane's new records, drains them through the funnel and runs the
  receiving process.
* *A message arrives for a busy domain.* The same trigger finds no parked
  executor. A running executor finds the records at its next safe point,
  where it looks at its lanes anyway, and drains them. No executor is
  interrupted.
* *A higher-urgency thread wakes.* It preempts the running thread on its
  CPU at once. The preempted thread keeps its place at the head of its
  level and resumes exactly where it stopped.
* *A slice ends or a quota runs out.* The kernel preempts the executor at
  once, unless its group enables deferred preemption and the runtime has
  marked the executor as inside a critical section. Then the kernel posts
  a yield request in the status area and arms a short grace timer; the
  runtime calls `erx_yield` when it leaves the critical section, and if the
  grace expires first, the kernel preempts it anyway and counts an
  overrun.
* *A native client calls a native server* through an IPC gate bound to a
  thread of the server. The call is a rendezvous: the client waits, the
  server's thread runs on its own group's grant and at its own urgency
  until it replies, and the reply wakes the client. The client's quota is
  not touched while it waits; the server's pays for the serving.
* *An Erlang service answers another domain.* The frame arrives on the
  client's lane; the service's runtime runs the client's facet process
  on its own executors, charged to the service's group, and ERTS shares
  those executors among the facets of every client as it shares them
  among any processes. The facet counts the reductions spent on the
  client's requests and admits them while the client's share for the
  period lasts; the runtime reports that count to the inspector
  ([Service work](#service-work)).

**The configuration ladder.** Every feature beyond plain scheduling can be
switched off, so the same kernel runs three configurations, each a strict
superset of the one before. The boot argument `erx.sched=` caps what any
group may enable; a group's own flags select within that cap.

| Configuration | Quotas | Published urgency, deferred preemption, status words, idle-first wake | What it is |
| --- | --- | --- | --- |
| C0, plain | none | off | one-to-one fixed-priority round robin over threads: the baseline |
| C1, isolated | enforced | off | groups as accounting and isolation only |
| C2, cooperative | enforced | each switchable | runtimes and kernel exchange hints and state |

Own-group charging is not a feature of the ladder: it is what charging
means, in every configuration, and there is no flag for anything else.

C0 is the first configuration the plan builds and the reference every
other is measured against; [plan.md](plan.md) keeps a feature only when its
measurement shows that it pays.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **S1.** The kernel never runs runtime code on a preemption, and never transfers control into an executor | preemption saves the thread's user registers into its thread record and later restores them; the kernel enters user mode only by resuming a thread's saved state or, for a worker armed with `erx_vcpu_control`, by Fiasco's vCPU upcall ([design-kernel.md](design-kernel.md#vcpu-upcalls)); `erx_vcpu_control` refuses an executor, and a thread's class is fixed at creation; wake-ups and status are written to memory, never delivered to an executor as a control transfer | an upcall into an executor; a path that arms an executor or changes a thread's class; a resumption at an address other than the saved one | the kernel's only exception-return paths are listed in the chokepoint table ([design-kernel.md](design-kernel.md#chokepoint-checks)); a domain test that `erx_vcpu_control` on an executor fails with `ERX_ETYPE`; a domain test preempts an executor at every instruction of a loop in deterministic mode and checks its registers on resumption |
| **S2.** No wakeup is lost | `erx_park` compares the caller's group and slot epochs with the kernel's under the group's park lock and sleeps only if both match; every trigger of an IRQ object bound to the group, listed already or not, every capacity change and every executor wake advances an epoch under the same lock before choosing whom to wake; whoever publishes work does so before it triggers; the runtime reads the epochs before it looks for work | a park that compares outside the lock; a trigger that skips the advance because its IRQ object is already listed; a runtime that reads epochs after checking for work | the park protocol's state machine explored exhaustively on the host for two executors, two IRQ objects with repeated triggers, a capacity change, a timeout, and an old executor of a stopped space dying while a new one holds its slot; a stress test with random triggers and parks requires every trigger to be followed by a return from `erx_park` or by the runtime finding the work at a safe point |
| **S3.** An executor never blocks except in `erx_park` or a umtx wait on private memory | every blocking call in `abi/erx_abi.txt` declares whether an executor may make it, and the generated dispatch checks the caller's class before the call can block; the umtx wait refuses an executor on a shared memory object; a thread's class is fixed at creation | a blocking call without the declaration, or a path that blocks before the check | the ABI generator rejects a blocking call without the attribute; a domain test calls every blocking call from an executor and requires `ERX_EWOULDBLOCK`, with a seeded call lacking the attribute failing the generator |
| **S4.** A group's usage per period exceeds its quota by at most one accounting quantum per CPU | every charge goes to every group on the running thread's group path; a dispatch requires local quota from every finite-quota group on that path; the CPU's one-shot timer is armed no later than the earliest local exhaustion; overruns are debts repaid from the next draw, and replacing a grant carries the debt into the period the replacement starts | a dispatch that skips the path check, a charge that skips a level, a timer armed past an exhaustion, or a replacement that forgives a debt | a host property test over random trees, charges, draws and grant replacements; a domain test with a spinning group at 10% on four CPUs measuring its usage per period, with a seeded charge that skips one level failing it |
| **S5.** No group exceeds its parent | quota caps are conjunctive along the path (every level is charged and checked); a thread's CPUs are the intersection of its affinity with every cpuset on the path; a published urgency is clamped to the minimum ceiling along the thread's path, and a thread's base never exceeds its own ceiling; none of these is stored per thread, all are derived at decision time from the current grants | storing a derived limit and missing an update | host tests that change an ancestor's grant and check the next decision of every descendant thread |
| **S6.** Every interval a thread runs is charged to the thread's own group and to no other | the group a thread is charged to is the `group` field of its thread record, written at creation and by nothing else; no kernel call, IPC transfer or control-area field names a group to charge; the charge function is the one writer of a group's usage and derives its path from that field alone | a path that charges a group other than the running thread's; a call or shared-page field through which a runtime names a group to charge | the charge function is a chokepoint ([design-kernel.md](design-kernel.md#chokepoint-checks)): a seeded second writer of usage fails the build; a native server serving callers of several groups and a service runtime serving clients of several domains, each with usage per group against a cycle-counter ground truth under QEMU, with a seeded charge to the caller's group failing the test |
| **S7.** A ready thread waits for at most the threads ahead of it at its level and above | each level is a FIFO; a thread is appended on wake, on slice end and on yield, and a preempted thread returns to the head of its level; throttled threads leave the queues and return when their group replenishes | a requeue at the head on slice end, or an unbounded repositioning loop | the pick core's model-based test against a reference queue; the bound on repositioning in [Pick](#pick-and-dispatch) |
| **S8.** In deterministic mode the dispatch sequence is a function of the inputs | the core reads no clock or global state, only its arguments; with one CPU there are no cross-CPU requests; timers fire at instruction counts | a decision that reads the counter or an address | replay tests of the core; the deterministic transcript test of [plan.md](plan.md) |
| **S9.** A client cannot make a service spend beyond the service's own grant, nor beyond its own share of it per period by more than the cost of the requests it has in flight when the share runs out | the service's threads are charged to the service's group (S6), which never exceeds its quota (S4) or its parent (S5); the client's facet admits its requests only while the reductions they cost, read from the service's runtime, are within the client's share for the period ([Service work](#service-work), [design-domains.md](design-domains.md#facets)); a single request is finite because the generated decoder bounds its input, and its cost reaches the account only with its reply, while the facet takes requests up to the grant's limit in flight, so the overrun is at most that limit times the costliest request's cost, which the facet carries into the next period as a debt; no fault is a request, since every fault resolves from its object or ends the thread | a kernel path that charged a client's work to anyone but the service; a facet that admits without its account, or accounts from anything but what the runtime measured; a serving path that returns no cost with its reply | a flooding client against a capped service under QEMU: the service's usage stays within its quota per period, the flooder's lane fills and blocks the flooder, the reductions spent on the flooder per period stay within its share plus the cost of the requests it had in flight when the share ran out, and the overrun is repaid in the next period, and a second client's requests are answered within the policy's bound; a client whose requests grow costlier with state it built in the service is held to its share the same way; a seeded facet that skips the account fails the test |

## Data model

Every type, constant and layout below that a domain can see is defined in
`abi/erx_abi.txt` and generated
([design-kernel.md](design-kernel.md#the-abi-file)); the sketches show
their shape.

**Urgency and classes.**

```c
typedef uint8_t erx_urgency_t;		/* 0 .. ERX_URGENCY_MAX, higher runs first */
#define ERX_URGENCY_MAX		63

typedef enum erx_thread_class {
	ERX_THREAD_WORKER,		/* may make every blocking call */
	ERX_THREAD_EXECUTOR		/* blocks only in erx_park and on private umtx words */
} erx_thread_class_t;
```

A thread's class and its group are fixed when it is created. A worker's
urgency is set by a holder of the thread's capability with the `CONFIGURE`
right and clamped at each decision; an executor's comes from its control
slot or its group's base. Bases, ceilings and published urgencies share
the one generated type, so none can name a level above `ERX_URGENCY_MAX`.

**Grants.** A grant is the policy a group carries:

```c
typedef struct erx_grant {
	uint64_t	quota_ns;	/* CPU time per period over all CPUs; ERX_QUOTA_NONE: uncapped */
	uint64_t	period_ns;	/* ERX_PERIOD_MIN (1 ms) .. ERX_PERIOD_MAX (1 s) */
	uint64_t	cpuset;		/* bit n allows CPU n; intersected with the parent's */
	uint32_t	capacity_mcpu;	/* advised sustained concurrency, thousandths of a CPU */
	uint32_t	capacity_first;	/* position in the cpuset of its run's first CPU */
	uint32_t	slice_us;	/* round-robin slice of the group's threads */
	uint32_t	grace_us;	/* deferred-preemption grace */
	erx_urgency_t	base;		/* urgency of member threads that publish none */
	erx_urgency_t	ceiling;	/* highest urgency its threads run at */
	uint16_t	flags;		/* ERX_GROUP_HINTS | _DEFER | _STATUS | _PLACE */
} erx_grant_t;
```

| Field | Default (policy, [design-system.md](design-system.md#resource-policy)) | Kernel rule |
| --- | --- | --- |
| `quota_ns`, `period_ns` | uncapped; 10 ms | `period_ns` is clamped into its range; every positive quota draws a positive slice ([Charging and quota](#charging-and-quota)); a quota of zero gives the group no time: it is exhausted from the start of every period, so its threads, and those of the groups below it, wait on its throttled lists, at a cost of one failed draw per period on each CPU where they wait, however many they are, as any exhausted group's do; changing the quota or the period starts another period at once ([Charging and quota](#charging-and-quota)). No grant stops a program: job control pauses the program's space instead ([Interaction with other subsystems](#interaction-with-other-subsystems)) |
| `cpuset` | the parent's | intersected with the parent's effective cpuset at each decision; an empty intersection means the parent's |
| `capacity_mcpu` | the CPU count of the cpuset | published as given, clamped to the group's own cpuset size and quota per period |
| `capacity_first` | 0 | published modulo the size of the group's effective cpuset; with the capacity, it names the group's run ([Status words and capacity](#status-words-and-capacity)) |
| `slice_us` | 5,000 | clamped to 500 .. 50,000 |
| `grace_us` | 50 | clamped to 5 .. 1,000 |
| `base`, `ceiling` | 16; 31 | `base` is clamped to `ceiling`; both are clamped to the parent's effective ceiling at each decision |
| `flags` | the features the default `erx.sched=` enables | masked by the machine-wide cap from `erx.sched=` |

The defaults of slice, grace and period are estimates for the experiments
of [plan.md](plan.md) to confirm or replace.

**The shared areas.** Each group owns two memory objects of three pages,
created with the group and charged to its budget. The runtime maps the
**control area** read-write and the **status area** read-only; their
ceilings, fixed at creation, make any other mapping impossible
([design-kernel.md](design-kernel.md#memory)). Each is one header line
followed by one line per executor slot; a line is 128 bytes, the larger of
the cache-line sizes of the supported cores, so no two executors write the
same line.

```c
#define ERX_GROUP_EXECUTORS_MAX	64
#define ERX_SHARED_LINE		128

typedef struct erx_exec_ctl {		/* written by the runtime */
	_Atomic uint8_t		urgency;	/* published urgency; read if ERX_GROUP_HINTS */
	uint8_t			pad0[3];
	_Atomic uint32_t	defer;		/* non-zero inside a critical section; read if ERX_GROUP_DEFER */
	uint8_t			pad1[120];
} erx_exec_ctl_t;

typedef struct erx_group_ctl {
	uint8_t			reserved[ERX_SHARED_LINE];	/* zero: no group-wide control field */
	erx_exec_ctl_t		exec[ERX_GROUP_EXECUTORS_MAX];
} erx_group_ctl_t;

typedef enum erx_exec_state {
	ERX_EXEC_NONE,			/* slot unused */
	ERX_EXEC_RUNNING,		/* on a CPU */
	ERX_EXEC_READY,			/* ready, waiting for a CPU (preempted or woken) */
	ERX_EXEC_PARKED,		/* in erx_park */
	ERX_EXEC_BLOCKED,		/* in a umtx wait */
	ERX_EXEC_THROTTLED,		/* its group has no quota until the next period */
	ERX_EXEC_PAUSED			/* its space is paused (design-kernel.md) */
} erx_exec_state_t;

typedef struct erx_exec_stat {		/* written by the kernel */
	_Atomic uint32_t	state;		/* erx_exec_state_t; kept if ERX_GROUP_STATUS */
	_Atomic uint32_t	cpu;		/* CPU it runs or last ran on */
	_Atomic uint64_t	epoch;		/* mirror of the slot's wake epoch */
	_Atomic uint32_t	yield_req;	/* 1 while the kernel asks for the CPU back */
	uint8_t			pad0[4];
	_Atomic uint64_t	preemptions;	/* involuntary preemptions so far */
	_Atomic uint64_t	overruns;	/* grace periods that expired */
	_Atomic uint64_t	run_ns;		/* CPU time so far */
	uint8_t			pad1[80];
} erx_exec_stat_t;

typedef struct erx_group_stat {
	_Atomic uint64_t	epoch;		/* mirror of the group's epoch */
	_Atomic uint64_t	capacity;	/* sequence << 32 | run's first << 24 | milli-CPUs */
	_Atomic uint64_t	period_start_ns;
	_Atomic uint64_t	used_ns;	/* this period over all CPUs, updated at each draw */
	_Atomic uint64_t	total_ns;	/* since creation, updated at each draw */
	_Atomic uint32_t	parked;		/* executors in erx_park */
	_Atomic uint32_t	throttled;	/* CPUs on which the group waits for its next period */
	_Atomic uint32_t	ready;		/* IRQ objects on the group's ready list */
	uint8_t			pad[76];
	erx_exec_stat_t		exec[ERX_GROUP_EXECUTORS_MAX];
} erx_group_stat_t;
```

**Labels.** Every IRQ object bound to a group carries the label its binder
gave it, which `erx_group_take_ready` reports ([Park and
wake](#park-and-wake)). The binder is the runtime that reads what the
object stands for: it binds the doorbell of each lane it reads
([design-domains.md](design-domains.md#connections)), of each program
channel it serves ([design-programs.md](design-programs.md#the-channel)),
of its pipe ends ([design-pipes.md](design-pipes.md#the-ring)) and of its
devices ([design-system.md](design-system.md#drivers)) to its group with
labels it chooses from the half of the group's label space at or above
`ERX_LABEL_SPLIT`; the half below it is the system domain's, for the
doorbells of the connections it makes
([design-domains.md](design-domains.md#connections)). The kernel returns
a label in the taker's UTCB and never interprets it
([design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)). A
capacity change needs no IRQ object: the kernel advances the group's
epoch, and the runtime finds the new capacity sequence.

**The kernel's records.** These are internal to the kernel and change
freely with it:

```c
struct erx_group {
	struct erx_object	obj;		/* type, budget, reference count */
	struct erx_group	*parent;	/* on the parent's att_children;
						 * NULL only for the root */
	uint8_t			depth;		/* < ERX_GROUP_DEPTH_MAX (8) */
	erx_dlist_t		att_members;	/* its member threads */
	erx_dlist_t		att_children;	/* its child groups */
	erx_dlist_t		att_bound;	/* the IRQ objects bound to it */
	erx_grant_t		grant;		/* as configured; limits are derived at use */
	uint64_t		period_origin_ns;
	uint64_t		origin_index;	/* the period that began at period_origin_ns */
	erx_spin_t		pool_lock;	/* protects pool, the two fields above and
						 * the grant's quota and period */
	struct {
		uint64_t	index;		/* the period the remainder belongs to */
		int64_t		remaining_ns;	/* negative while a debt is outstanding */
	} pool;
	_Atomic uint64_t	throttled_on;	/* CPUs whose throttled list or cohort holds threads */
	erx_spin_t		park_lock;	/* protects epoch, slot_epoch, the two
						 * attachment fields below, ready */
	uint64_t		epoch;
	uint64_t		slot_epoch[ERX_GROUP_EXECUTORS_MAX];
	struct erx_tqueue	att_parked;	/* FIFO of executors in erx_park */
	struct erx_irq		*att_ready_head; /* bound IRQ objects triggered and */
	struct erx_irq		*att_ready_tail; /* not yet taken (design-kernel.md) */
	uint32_t		nready;		/* their number, mirrored in ready */
	struct erx_thread	*slot[ERX_GROUP_EXECUTORS_MAX];
	struct erx_mem		*ctl, *stat;	/* the shared areas */
	struct erx_group_cpu	*cpu;		/* one per CPU, owned by that CPU */
};

struct erx_group_cpu {
	int64_t			local_ns;	/* quota drawn on this CPU and not yet used */
	uint64_t		index;		/* the period local_ns belongs to */
	struct erx_tqueue	throttled;	/* threads waiting for the next period */
	struct erx_tqueue	cohort;		/* threads of a period begun, being released */
	erx_timer_t		refill;		/* armed while either queue holds threads */
	uint64_t		used_ns;
};

struct erx_thread_sched {
	erx_thread_class_t	class;
	uint8_t			slot;		/* executors only */
	_Atomic erx_urgency_t	base;		/* workers: as configured */
	uint64_t		affinity;
	uint16_t		cpu;		/* the CPU whose queues hold it */
	struct erx_group	*group;		/* member of, and charged to; on its
						 * att_members; written at creation only */
	struct erx_decision	last;		/* urgency at the last decision */
	uint64_t		charged_to_ns;	/* time up to which it has been charged */
	uint64_t		slice_left_ns;
	erx_defer_t		defer;		/* deferred-preemption state */
};

struct erx_decision {
	uint64_t		pick;		/* the pick it was made in */
	erx_urgency_t		urgency;
};
```

**Locking.** A group's per-CPU records are touched only by their CPU, with
interrupts masked; its pool and park state are protected by the two
spinlocks above, which are leaf locks taken with interrupts masked, so no
preemption lands while one is held. Its grant is written only by
`erx_group_configure`, under the pool lock, and the fields that decisions
read without that lock are atomic ([Charging and
quota](#charging-and-quota)).

**Memory.** At 64 CPUs a group costs about 30 KiB: the object, 64 per-CPU
records of 80 bytes, and two shared areas of 12 KiB. A thread's scheduling
record is under 100 bytes inside its thread record. Nothing is allocated
after creation.

### Ownership and lifetime

A group is charged to the budget it was created from and dies with it:
destroying that budget deletes the group, as it deletes every object
charged to it ([design-kernel.md](design-kernel.md#budgets)). The system
domain charges each domain's group to the domain's own budget, so the
group ends when the domain does. Otherwise a group's life follows the
kernel's ([design-kernel.md](design-kernel.md#closing-and-deleting)),
with two rules of its own: a released group lives on while it has a
member thread or a child group, and a destroyed group takes its members
and its children with it. A thread is a member from its creation until
it dies, and a child counts until it is destroyed.

| State | Entered when | What holds in it |
| --- | --- | --- |
| live | `erx_group_create` returns | its capabilities reach it; threads are created in it and groups under it |
| released | its last capability goes while it has a member or a child | no capability reaches it, so nothing joins it; its members run on under its grant, park in it and take deliveries from the IRQ objects already bound to it, since `erx_park` and `erx_group_take_ready` act on the caller's own group and need no capability, and its children keep their place under it |
| destroyed | it is deleted, by `erx_object_destroy` with `DESTROY`, by the destruction of the budget that pays for it or by the destruction of its parent group; or, released, its last member and child go | it is closed: every capability to it fails and nothing joins it; its teardown destroys its child groups, kills its member threads, unbinds the IRQ objects bound to it and withdraws the deliveries on its ready list, each owed to that object's next binding unless it is a level-sensitive line ([design-kernel.md](design-kernel.md#irq-objects)) |
| freed | its destruction's grace period has passed and its last counted reference has gone | the reaper frees its record, its per-CPU records and its shared areas, and their charge returns to its budget, or to that budget's parent once the budget is destroyed ([design-kernel.md](design-kernel.md#the-reaper)) |

Three facts follow by construction:

* **No executor is ever left in a group it cannot park in.** A released
  group keeps its members, and a destroyed group kills them, and a killed
  thread never returns to user mode
  ([design-kernel.md](design-kernel.md#closing-and-deleting)). So
  `erx_park` has no failure for a destroyed group: a park that finds its
  group closed returns at once, and its caller dies before it reaches user
  mode. A runtime never has to spin.
* **No charge reaches a freed group.** Every member thread holds a counted
  reference to each group on its path, from its creation until it dies,
  and a thread is charged to nothing but that path (S6). A killed member
  finishes its call on its own stack and on its own path's quota, charged
  to its path as before, and a destroyed group's records go on charging,
  throttling and releasing it by the same rules until its last member is
  gone. So no decision checks for a destroyed group on the path it
  charges.
* **A destroy never waits on a member nobody will run.** When a killed
  member's path has no quota left, the call that destroyed the group
  runs it to its end on its own time, by the helping rule a stop follows
  (Finishing and reclamation, in [Charging and
  quota](#charging-and-quota)).

Counted references keep a group's record, never its state:

| Holder | Takes its reference | Drops it |
| --- | --- | --- |
| the group itself | at creation | after its destruction's grace period |
| each member thread, on every group of its path | when it is created in the group | when it dies |

Only threads count references, as everywhere in the kernel: a child group
and an IRQ object bound to a group are on the group's attachment lists,
which its teardown empties
([design-kernel.md](design-kernel.md#objects-and-capabilities)). So a
destroyed group's record waits only for its grace period and for its
killed members, each of which finishes one call.

## Algorithms and behavior

The scheduler's functional core is a set of pure functions and state
machines: `erx_sched_resolve` (urgency), `erx_sched_charge` and
`erx_sched_draw` (quota arithmetic), `erx_sched_pick`, and the park and
deferred-preemption state machines. Each takes plain values and returns a
decision or the next state and the actions to perform. The effect layer
reads the clock and the shared areas, calls the core, and performs what
it returns: queue operations, timer programming, context switches,
cross-CPU requests and stores to the status area. The core lives in
`kernel/core/sched/`, builds for the host, for erXos's kernel and for the
stopgap, and is the same file in all three
([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)).

### Urgency resolution

At every decision about a thread (dispatch, wake, preemption, slice end,
yield, and each accounting point) the effect layer resolves the thread's
urgency once and caches the result in `last` for the rest of that
decision:

* An executor whose group enables `ERX_GROUP_HINTS` contributes the
  `urgency` byte loaded once from its slot; any other thread contributes
  its base.
* A published value is clamped to the minimum ceiling along the thread's
  group path; the thread runs at the greater of that value and its base,
  which its own group's ceiling bounds.

As one expression, with `ceil(g)` the minimum ceiling on group `g`'s
path:

```text
published = ERX_GROUP_HINTS ? slot.urgency : base
urgency   = max(min(published, ceil(own)), base)      base <= ceil(own)
```

Every term is read at the decision, so a ceiling lowered or a base
changed anywhere on the path takes effect at the thread's next decision,
and nothing derived is stored (S5). The group a thread is charged to is
not resolved at all: it is the `group` field of its thread record, fixed
at creation (S6).

A value a runtime writes between two decisions takes effect at the next
one. A runtime that raises an executor's urgency while the executor runs
gains nothing until it is preempted or calls `erx_yield`; one that lowers
it keeps the higher urgency until the next decision, at most one slice or
one accounting quantum. Neither direction needs a kernel call.

The shared areas are read only through the accessors `erx_shared_load_u8`,
`erx_shared_load_u32` and `erx_shared_load_u64`, one per field width: one
relaxed atomic load into a local, after
which only the local is used. This is the kernel's single funnel for
runtime-writable memory it owns, a chokepoint enforced at build time
([design-kernel.md](design-kernel.md#chokepoint-checks)). Every value
loaded is valid input: urgency is clamped, and `defer` only delays a
preemption for at most the group's grace.

### Pick and dispatch

Each CPU owns its ready queues: 64 FIFO lists, one per urgency, and a
64-bit bitmap of non-empty levels. Only that CPU touches them, with
interrupts masked; other CPUs reach them through cross-CPU requests
([Concurrency](#concurrency)).

`erx_sched_pick` runs when the current thread blocks, parks, yields,
exhausts its slice or quota, or is preempted by a more urgent wake:

1. Take the highest non-empty level from the bitmap. If there is none, the
   CPU idles, waiting for an interrupt, until an interrupt or a cross-CPU
   request.
2. Take the head thread `t` of that level. If `t` was not resolved in this
   pick, resolve it. If its urgency differs from the level, move it to the
   tail of the level of its urgency and go back to step 1. A thread is
   resolved at most once per pick, so each moves at most once.
3. Check `t`'s group path ([Charging and quota](#charging-and-quota)). If
   a group on it cannot supply quota on this CPU, move `t` to that group's
   throttled list on this CPU, and go back to step 1.
4. Dispatch `t`: program the CPU's one-shot timer for the earliest of
   `t`'s slice end, the first exhaustion of local quota on its group path,
   and the CPU's next timer-wheel deadline; switch to `t`'s kernel stack
   and space, from which `t` continues the kernel call it waited in or
   returns to user mode; record `t` as running in its status slot when its
   group enables `ERX_GROUP_STATUS`.

**A bounded pick.** A pick moves at most `ERX_PICK_MOVES` (8) threads, to
another level or to a throttled list. One that reaches the bound before it
finds a thread to dispatch dispatches the CPU's idle thread instead, which
takes pending interrupts at once and picks again, so the pick's work
between preemption points never grows with the number of ready threads,
whatever a runtime publishes and however many threads a spent quota leaves
to throttle (K13 of [design-kernel.md](design-kernel.md#invariants)). A
thread joins a group's throttled list at most once per period of that
group ([Charging and quota](#charging-and-quota)), and the moves are
kernel work, charged as every kernel entry is.

**Placement in the queues.** A woken thread joins the tail of its level. A
thread whose slice ends joins the tail with a fresh slice. A thread
preempted by a more urgent one rejoins the head of its level with the rest
of its slice, so preemption by urgency never costs it its turn. A thread
that calls `erx_yield` joins the tail; if no other thread is ready at its
level or above, `erx_yield` returns at once.

**Preemption.** When a wake makes a thread ready at a higher urgency than
the resolved urgency of the thread running on that CPU, the running thread
is preempted at once, in user mode or in the middle of a kernel call,
except inside the short sections that hold the CPU's lock or a spinlock
([design-kernel.md](design-kernel.md#execution-model-and-locking)).
Urgency preemption is always immediate; only slice ends and quota
exhaustion may be deferred.

### Charging and quota

**Accounting points.** The kernel charges a thread whenever it stops
running (block, park, yield, preemption), at every timer interrupt on its
CPU while it runs, and when a decision about it needs fresh numbers. A
charge is `now - charged_to_ns`, added to every group on the thread's
group path. The **accounting quantum** is 1 ms, the largest draw quantum.
A thread whose group path has a finite quota meets an accounting point at
least once per draw, since its CPU's timer is armed for the first local
exhaustion. Kernel entry costs are charged to the thread that was
running, whether the entry was its own call or an interrupt; the runtime
that owns a device does the work an interrupt signals on its own
executors, which its own group pays for. What an interrupt costs the
thread it lands on is bounded by actions that someone paid for: a line
stays masked from its fire until its driver takes or acknowledges the
delivery, an IRQ object counts once while a delivery is queued, an
IOMMU's fault records are drained at most `ERX_IOMMU_FAULTS` a period, a
cross-CPU request is posted by a call that pays for it, and a refill
timer's release is charged to the group it releases.

**Local quota.** A group with a finite quota keeps a pool per period and,
on each CPU, a local slice drawn from the pool. `erx_sched_charge`
subtracts the charge from the local slice of every finite-quota group on
the path. `erx_sched_draw` refills a local slice that has reached zero:

1. Under the group's pool lock, if the pool's period index is older than
   the current period, `origin_index` plus the whole periods elapsed since
   `period_origin_ns`, carry any debt forward and refill:
   `remaining = quota - debt`, `index = current`.
2. Take `min(draw quantum, remaining)` from the pool into the local slice.
   The draw quantum is the quota divided by the number of CPUs in the
   group's effective cpuset at this draw, clamped to between
   `ERX_DRAW_MIN` (50 microseconds) and 1 ms, so every positive quota
   draws a positive slice, and a quota too small to share among all its
   CPUs runs on fewer of them at once.
3. A local slice left at zero or below means the group is exhausted on
   this CPU until its next period.

**Period indexes.** Each local slice records the index of the period it
was drawn in. A CPU returns its slice, under the pool lock, before it
draws again and whenever it finds the pool's index newer than its
slice's. The remainder's sign and the period it was drawn in decide what
happens to it:

| The slice's remainder | drawn in the pool's current period | drawn in an older period |
| --- | --- | --- |
| positive | added back to `remaining` | lapses, as unused quota does |
| negative, an overrun | added to `remaining`, which it lowers | added to `remaining`, which it lowers |

So an overrun is paid from the period in force when it is returned, and a
pool left below zero carries its debt into the next refill. The slice is
zero once returned, so no remainder is counted twice, and a refill by
another CPU in between changes only which case applies. Time overrun by a
grace period or a timer's latency is never forgiven.

**Throttling.** A thread whose group path has an exhausted group moves to
that group's throttled list on its CPU, and the
CPU arms the group's per-CPU refill timer for the start of the group's
next period. The group's status records the CPU as throttled, and its
`throttled_on` mask names the CPU while the list or the cohort there holds
a thread. When the timer fires at that start, the CPU moves the whole list
to the end of the group's **cohort** on that CPU, the threads that wait
for a period that has begun, and the list, left empty, takes the threads
that throttle from then on, which wait for the next period. A thread
therefore joins a group's list at most once per period of that group, and
a cohort being released never gains a thread. The CPU releases the cohort
oldest first, at most `ERX_REFILL_BATCH` (32) threads per expiry, arming
the timer again at once while threads remain in it, so a long cohort
returns in short stretches with interrupts taken between them. It releases
a batch only while the group can supply quota on this CPU, from its local
slice or a draw, and a release is a decision about each thread, as a wake
is: the thread joins its ready queue only if every group on its group path
can supply quota on this CPU, and otherwise joins the list of the first
group that cannot. Once the group cannot supply quota there, the rest of
the cohort goes back to the head of the list, in the same order, and waits
for the next period untouched. The time the CPU spends releasing is
charged to the group whose cohort it releases, from its local slice and as
a debt beyond it, rather than to the thread it interrupted. So a group
whose quota is zero, or whose debt exceeds its quota, costs each CPU where
its threads wait one expiry and one failed draw per period, however many
they are, and releasing a large cohort is paid for from the quota of the
group it serves.

**Finishing and reclamation.** Stopping a space is a kernel call like any
other and is charged to its caller: what the stopped threads' own grants
leave undone of finishing their calls, the stopper's thread takes over,
on the stopper's group's grant, and emptying and destroying the stopped
space run in the calls that ask for them
([design-kernel.md](design-kernel.md#execution-model-and-locking)). The
system domain stops domains and a session stops its programs, each with
quota of its own, so the finishing of a stopped party never waits for
the renewal of that party's grant, and nothing is set aside for it: a
stopper that has spent its own quota waits for its own next period, as
it does for any of its calls. A stopped thread's remaining kernel work
cannot start another user request, since it never returns to user mode
([design-kernel.md](design-kernel.md#threads-and-faults)). Destroying a
group follows the same rule: destroying it kills its members, a killed
member finishes its current kernel call on its own path's quota, and
when that quota is zero the call that destroyed the group runs it to its
end on its own time, by helping, as a stopper runs a finishing thread
([design-kernel.md](design-kernel.md#closing-and-deleting)). So a
destroy never waits on a member nobody will run. The reaper's steps,
which free what the stop and the destroys leave, run on idle time or in
the call whose charge needs the memory
([design-kernel.md](design-kernel.md#the-reaper)).

**Replenishment** is lazy: no timer refills a pool. The first draw of a new
period refills it, and the refill timers exist only on CPUs where threads
wait. A group whose threads never run costs nothing per period.

**Replacing a grant.** `erx_group_configure` writes the grant under the
group's pool lock. Changing the quota or the period starts another period
at once: the period's origin becomes the time of the call, and its index
the current index plus one, so indexes only grow. The records follow by
the rules above, with no transition of their own: the pool's next draw
finds its index older, keeps the pool's debt and drops a positive
remainder; each CPU returns its local slice at its next draw or decision,
a positive remainder lapsing and an overrun carried into the pool of the
period the change started; and the call posts a request, with an
inter-processor interrupt, to each CPU that the group's `throttled_on`
mask names, which re-arms that CPU's refill timer for the start of that
period, the present, so its cohort is released under the changed grant at
once. Every other field takes effect at each thread's next decision and
leaves the accounting records alone, so changing a cpuset, a capacity, a
ceiling or a flag never refills a pool. The fields that decisions read
without the pool lock, the cpuset, slice, grace, base, ceiling and flags,
the kernel keeps as atomic values that the call stores and each decision
loads once, so a decision sees each field from before a replacement or
from after it, never a torn value.

**A quota caps; it reserves nothing.** A group with quota left runs only
when the kernel picks one of its threads, and higher urgencies come
first, so a quota promises no minimum. A group's progress is promised
only by the policy that writes grants leaving room for it, the quotas of
the groups above its urgency on its CPUs leaving those CPUs time
([design-system.md](design-system.md#resource-policy)).

### Park and wake

The park protocol is the runtime's one way to wait, and it is a monitor
over two epochs: the group's epoch, advanced by every trigger of an IRQ
object bound to the group and by every capacity change, and each executor
slot's epoch, advanced by every `erx_executor_wake` of that slot. Both are
authoritative in the kernel and mirrored into the status area with
release stores.

An executor never waits in an IPC, so its group keeps for it what an open
wait gives a worker: a **ready list** of the IRQ objects bound to the
group that fired since an executor last looked, each listed once however
often it fired, with their number mirrored in the status area's `ready`.
A pool of threads that takes turns at one doorbell is therefore a group's
executors: the IRQ object is bound to the group, and whichever executor is
parked takes it. A worker waits only for what is bound to itself, in an
open wait, as any Fiasco thread does
([design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)).

The runtime's side, in every executor:

```c
	g = atomic_load_explicit(&stat->epoch, memory_order_acquire);
	s = atomic_load_explicit(&stat->exec[me].epoch, memory_order_acquire);
	if (atomic_load_explicit(&stat->ready, memory_order_relaxed) != 0)
		take_ready();		/* erx_group_take_ready until it runs dry */
	if (sources_have_work() || runtime_has_work())
		return;			/* handle the work; park again later */
	error = erx_park(g, s, deadline);	/* ERX_OK or ERX_ETIMEDOUT */
```

`sources_have_work` looks at what the runtime's IRQ objects stand for:
its lanes' and rings' positions and the capacity sequence, one load each.

The kernel's side:

* `erx_park(g, s, deadline)`: refused with `ERX_ETYPE` for a worker. Under
  the group's park lock, if the group's epoch differs from `g` or the
  slot's epoch differs from `s`, return `ERX_OK` at once. Otherwise append
  the executor to the group's parked FIFO, record it as parked, arm the
  deadline on its CPU, and switch away. It returns `ERX_OK` when woken and
  `ERX_ETIMEDOUT` when the deadline passes first. A group closed by its
  destruction refuses the append and the call returns at once; its
  caller, killed with the group, dies before it reaches user mode
  ([Ownership and lifetime](#ownership-and-lifetime)).
* **A trigger** of an IRQ object bound to the group, by software holding
  its `TRIGGER` right or by the device line behind it
  ([design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)):
  under the park lock, list the object unless it is listed, mirror
  `ready`, advance the group's epoch, mirror it, and take one executor
  from the parked FIFO (the longest parked, or with `ERX_GROUP_PLACE` the
  first whose CPU is idle), passing over the executors of a stopped space
  (below). Wake it after releasing the lock. With no parked executor the
  trigger ends there, and a running executor finds the work at its next
  safe point. The list's links live in the IRQ objects, so a trigger
  allocates nothing, and the list holds a counted reference to each object
  on it. Unbinding an object takes it off the list, as does its deletion.
* **No stopped space's executor is chosen.** A trigger and a capacity
  change never choose an executor whose space has stopped: one met in
  the parked FIFO leaves it and is woken, to die at its return to user
  mode, and the choice goes on to the next, at most
  `ERX_GROUP_EXECUTORS_MAX` of them; `erx_executor_wake` treats such an
  executor's slot as empty. So no delivery goes to an executor that
  cannot run user code again.
* `erx_group_take_ready(max)`, by an executor, on its own group, as
  `erx_park` acts on it, so the members of a released group, which no
  capability names, still take their deliveries; a worker is refused with
  `ERX_ETYPE`, since it waits only for what is bound to itself. Under the
  park lock, remove up to `max` objects from the list, at most
  `ERX_MSG_WORDS` (63), and mirror `ready`; then, with the lock released,
  write their labels into the caller's UTCB, one message word each, and
  return their number. It never blocks.
* `erx_group_configure`, after it publishes a capacity: advance the
  group's epoch and wake one parked executor, as a trigger does.
* `erx_executor_wake(slot)`, by a thread of the same group: under the park
  lock advance the slot's epoch, mirror it, and if the executor is parked,
  remove it from the FIFO and wake it.

**Why no wakeup is lost.** Whoever publishes work, a lane's producer or
the policy changing a capacity, stores it before the trigger, and the
trigger advances the epoch under the lock that `erx_park` holds while it
compares. If the runtime read `g` before the advance, `erx_park` sees a
different epoch and returns. If it read `g` after, its acquire load
synchronises with the mirror's release store, so it sees `ready` and the
work published before the trigger. A trigger of an object that is already
listed still advances the epoch, so an executor that has not yet taken the
list never parks past it. The same argument covers slot epochs. This is
invariant S2, explored exhaustively on the host for two executors, two IRQ
objects with repeated triggers, a capacity change, deadlines, and an old
executor of a stopped space that dies while a new one holds its slot.

**Executor slots.** Slot `s` of a group has at most one holder, the thread
that `slot[s]` names, which is written only under the park lock. An
executor takes the lowest free slot at its creation, and a slot is free
when it names no thread or when its thread's space has stopped. A creation
that takes a slot whose holder's space has stopped first makes the old
holder let go of it:

1. `erx_thread_create` makes every allocation and check of the new
   thread first, so nothing after the handover can fail, and finds slot
   `s` held by a thread whose space has stopped.
2. It posts a request to the old holder's home CPU, which alone changes
   that thread's scheduling record (K14 in
   [design-kernel.md](design-kernel.md#invariants)), and spins at a
   preemption point, applying its own CPU's requests meanwhile, until the
   request has been applied. The home CPU applies it at its next kernel
   entry or preemption point, so the spin lasts at most the longest
   stretch with interrupts masked (K13), as Fiasco's `Thread::kill` waits
   for its request to a thread on another CPU. The spin keeps no wait
   record, so the call never waits, and an executor may make it.
3. The home CPU applies the request's four effects: it clears the old
   holder's `slot` field; under the park lock, it names the new executor
   in `slot[s]` and takes the old holder off the parked FIFO; and it wakes
   the old holder, to die.
4. The creation installs the new thread and returns its slot.

A creation always completes once started, as every call finishes the
bounded work it began; if its caller's space stops meanwhile, the new
thread's capability goes with the caller's table, the thread, released,
dies without having run, and its teardown frees slot `s`, which names it.
From step 3 on the old holder's decisions read no control slot and write
no status line, and its teardown frees no slot, since a thread frees slot
`s` only while `slot[s]` still names it. So a reused slot's epoch and
status line belong to its new holder alone, and S2's argument for slot
epochs holds for it. An old executor that finished `erx_group_take_ready`
as its space stopped may have taken deliveries that the next runtime
never sees; that runtime reconciles with its sources when it starts, as a
program's next image does, rather than waiting for their triggers.

**Why the runtime picks which executor to wake.** ERTS keeps one run queue
per scheduler and wakes the scheduler whose queue gained work. A trigger
from outside the runtime cannot know that, so it wakes any parked
executor, which then steals work as ERTS's executors already do; a wake
from inside names the slot.

**Relation to Fiasco.** Fiasco binds an IRQ object to one thread, whose
open wait receives it with its label. erXos also binds one to a group,
because executors never wait in an IPC: they park on their group, so a
doorbell must wake whichever executor of the group is parked. The ready
list is the open wait's counterpart for a group, and the label is
Fiasco's ([design-kernel.md](design-kernel.md#l4-lineage)).

### Deferred preemption

An executor preempted while it holds one of its runtime's locks makes the
runtime's other executors wait for a thread that is not running: the
lock-holder preemption that two-level systems keep meeting. For an
executor whose group enables `ERX_GROUP_DEFER`, the runtime keeps a count
in the executor's control slot, `defer`, which it raises while it holds a
lock or runs another short critical section and lowers when it leaves
it. The kernel consults the count only when it wants the CPU back for a
reason that is not urgent: a slice end with another thread ready at the
executor's level, or an exhausted group on its path. The per-executor
state machine, `erx_defer_step`:

| State | Event | Next state | Actions |
| --- | --- | --- | --- |
| `NONE` | slice end with a competitor, or group exhausted, with `defer` zero | `NONE` | preempt and requeue at the tail, or throttle |
| `NONE` | the same, with `defer` non-zero | `ASKED` | set `yield_req` to 1; arm the grace timer for `grace_us` |
| `ASKED` | the executor calls `erx_yield`, `erx_park`, or blocks | `NONE` | clear `yield_req`; requeue at the tail, park, block, or throttle |
| `ASKED` | grace timer fires | `NONE` | count an overrun; clear `yield_req`; preempt and requeue at the tail, or throttle |
| `ASKED` | a more urgent thread wakes on its CPU | `NONE` | clear `yield_req`; preempt at once; rejoin the head |
| `ASKED` | slice end or exhaustion again | `ASKED` | none |

The runtime checks `yield_req` each time it lowers `defer` to zero, and
calls `erx_yield` if it is set. The executor is the only writer of its
`defer`, and the kernel reads it only on the executor's own CPU, in an
interrupt or call taken there; a CPU sees its own earlier stores, so a
plain store with a compiler barrier is enough and no atomic
read-modify-write is needed. `yield_req` is written by the kernel and read
with an acquire load after `defer` returns to zero, so a request made by an
interrupt between the two is never missed: either the load sees it, or the
interrupt saw `defer` at zero and preempted at once. Preemption at any
other point needs no deferral: the kernel resumes the executor where it
stopped, and nothing of the runtime runs meanwhile. The count is a hint the
kernel bounds: an executor that keeps it raised gains at most one grace
period per request, which its own group pays for, and every expiry is
counted. Linux's restartable-sequence time-slice extension and Solaris's
preemption control solve the same problem; Linux grants 5 microseconds by
default and at most 50
([research](research-hierarchical-scheduling.md#lock-holder-preemption)).
The default grace is that maximum, 50 microseconds, because ERTS's
critical sections are longer than the short sections Linux's extension
targets (an estimate). Experiment E-S3 ([Performance](#performance))
measures how long ERTS holds its locks and sets the default; E-S6 measures
whether deferral pays at all.

### Status words and capacity

With `ERX_GROUP_STATUS`, the kernel writes each executor's state and CPU
into its status slot at every transition, and increments `preemptions` at
every involuntary preemption. A runtime reads these at its safe points to
avoid spinning on a lock whose holder is not running and to steal at once
from the run queue of a preempted executor. The values are facts the
kernel recorded, never requests, and a runtime that ignores them is merely
slower.

**Capacity** is advice from the policy: how many CPUs of sustained
concurrency the group can expect, in thousandths, and where. Its place is
the group's **run**: the CPUs of its cpuset taken in order from the one at
position `capacity_first`, wrapping around, as many as the capacity
rounded up and at least one, the CPU an executor of a group advised no
capacity keeps to. `erx_group_configure` publishes both as one 64-bit
store of a sequence number, the run's first position and the value,
clamped to the group's own cpuset size and quota per period, then advances
the group's epoch and wakes one parked executor ([Park and
wake](#park-and-wake)). A runtime adjusts the number of executors it keeps
active, and pins them to its run, at its next safe point; ERTS changes
`schedulers_online` and `dirty_cpu_schedulers_online` and pins its online
normal schedulers one to each CPU of the run
([design-runtime.md](design-runtime.md#scheduling)). The policy changes
capacity on the scale of seconds, never per slice, so allocations stay
stable and no slice involves a negotiation. A runtime that keeps more
executors busy than its capacity is throttled by its quota; one that keeps
fewer leaves CPUs to others.

The policy places the runs so that on each CPU the shares of the runs that
include it, each group's capacity spread evenly over its run, sum to at
most what that CPU can give
([design-system.md](design-system.md#resource-policy)). A runtime that
keeps its active executors, normal and dirty alike, on its run therefore
meets no executor of another domain there in steady state, and the problem
of several runtimes each sized to the whole machine does not arise. The
run is advice, as the capacity is: the cpuset alone limits where a group's
threads may run, and a runtime that strays from its run only contends,
within its quota.

### Placement and affinity

Every thread has an affinity mask; its effective CPUs are the mask
intersected with each cpuset on its group path, falling back to the
group's effective cpuset when the intersection is empty. Placement happens
only at a wake:

1. the CPU it last ran on, if allowed and idle;
2. otherwise the lowest-numbered allowed idle CPU;
3. otherwise the CPU it last ran on, if allowed, else the lowest-numbered
   allowed CPU.

A running thread whose CPU leaves its effective set, because an affinity
or a cpuset changed, moves at its next decision. There is no periodic
balancing. ERTS's adapter pins each online normal scheduler to one CPU of
its group's run ([Status words and capacity](#status-words-and-capacity)),
so its own work stealing does the balancing between them, as `+sbt`
binding does on a host, and leaves dirty CPU schedulers unpinned within
the run, so wake placement finds them an idle CPU of it
([design-runtime.md](design-runtime.md#scheduling)).

### Service work

A **shared service** is a runtime that serves requests from other
domains: the system domain's services, a file server, a storage or
network domain, a driver domain. It runs on its own group's grant, which
the policy caps and sizes for the domains it serves
([design-system.md](design-system.md#resource-policy)), and its threads
are charged to that group whatever they do and whoever they do it for
(S6). The kernel contributes nothing else to the service's isolation
from its clients; the rest is how the service admits and shapes its work,
and that is the same for every service.

**Admission is the client's facet, by measured reductions.** A service
admits each client's requests in that client's **facet process**, the
process in the service's domain that acts only for that client
([design-domains.md](design-domains.md#facets)). The facet's own loop is
the admission. It accounts, per period, the reductions spent on the
client's requests, read from the runtime: its own, and those the
service's processes spend serving each request it forwarded, which the
service's generated serving path reads around the request and returns
with the reply. While the client's **share** for the period lasts, the
facet takes the client's requests, each within its size and within the
grant's limit in flight; once the share is spent, it takes none until
the next period and leaves the rest where they are. A request's cost
reaches the account only with its reply, and the facet may take up to
the grant's limit in flight before any reply returns, so a client
overruns its share by at most the cost of the requests in flight when
the share ran out: that limit times the costliest of them. The facet
carries the overrun into the next period as a debt, as the kernel
carries a group's overrun (S4), so over periods the client gets its
share. erXos states this bound rather than admit one unaccounted request
at a time per client, which would serialize each client's requests
through the service and spend its concurrency on a bound the debt
already repays. What the facet holds for the client is bounded by its
queue quota for the requests it has not yet decoded and by its
`max_heap_size`, off-heap binaries counted. What the client has in
flight is bounded by the client's **lane**: once the facet holds its
quota, the funnel leaves the client's next frame for it in the lane
([design-domains.md](design-domains.md#flow-control)), so a client that
sends faster than its facet admits fills its own lane and blocks in its
own runtime, and a flooder slows itself and costs the service nothing
beyond its share. Nothing else takes part: the facet's
account, its queue quota and heap limit, and the lane are the whole of
admission, and the kernel knows nothing of them.

**No service work arises from another domain's faults.** A fault is
never a request: the kernel resolves every fault from the faulting
mapping's object or ends the thread, and calls no one
([design-kernel.md](design-kernel.md#virtual-memory)). A file that a
session's programs map shared is a memory object the session holds and
fills with ordinary reads through the file protocol, so their faults on
it are the session's own, resolved by the kernel from that object, and
what the session reads and writes back for it reaches the file's server
as ordinary requests, admitted like any other
([design-files.md](design-files.md#shared-mappings)).

**A single step is finite.** The work a service does on its own
executors for one request, from taking a frame to replying, is a step,
and three rules keep each step finite:

* a frame is decoded by a generated decoder whose grammar carries its
  schema bounds, so decoding a request costs at most what its schema
  allows, and a frame outside the schema is refused at the decoder
  ([design-domains.md](design-domains.md#the-funnel));
* no code outside the decoder loops over client-sized data: a request
  names objects by handle and sizes by number, and a service that must
  walk a client's bytes does so in the decoder, within the schema's
  bounds, or not at all;
* work that grows with the client's input runs in one of two places: in
  the client's own domain, as preparation whose result the service
  validates completely before it acts on it, or in the service's own
  domain within its own grant, as a process the service's runtime
  schedules among its clients' processes as it schedules any processes,
  by priority and reductions, and whose reductions count toward the
  client's share, so no client's heavy work starves another's steps.

A step's work may still grow with state the client built in the service,
within the grant's quotas, so the shape of the code bounds one step and
not what a client's steps add up to; admission by measured reductions
bounds that, with no declared worst case per step and no admission
arithmetic, and the service's quota bounds the service.

**Attribution is the same account.** Which client a piece of the
service's work was for, the service's runtime knows: ERTS counts
reductions and time per process, and each facet is one client's. The
account each facet keeps for its admission is what the service reports
per client to the inspector, as runtime-reported values beside the
kernel's per-group figures ([design-live.md](design-live.md#inspection)).
The kernel enforces none of it: a service that misaccounts misleads its
own admission and the inspector, and still spends no more than its grant
(S6).

**What it costs.** A service's quota is one pool for all its clients,
and each client's facet draws from it at most the client's share per
period, give or take what the client had in flight when its share ran
out. When the shares the policy admitted
add up to more than the quota, the quota runs out before every client
has drawn its share, and then every client of that service waits for the
service's next period together, the urgent with the idle. The remedy is
policy, not mechanism: the system domain sizes a service's grant to
cover the shares it admits, with the headroom its urgency band needs,
and then no client within its share waits for the next period because
of another.

**The system domain's configuration headroom.** Configured service groups
are children of `system`; the system runtime's threads belong directly
to `system` and have no separate quota. The manifest's `system_reserve`
leaves a normalized share of the aggregate grant unassigned to those
children. Configuration and live service-grant changes use the same
rate and CPU-set predicate
([design-system.md](design-system.md#resource-policy)). This is admission
headroom, not a CPU-supply or deadline guarantee: independent periods,
bursts and urgency still determine when parent quota is available to the
runtime. The shipped workload and hostile-load tests check watchdog and
control latency separately. The scheduler implements no reservation
mechanism for this configuration field.
Genode has shipped on this split for
fifteen years: memory accounted per session, CPU by quota and priority
per component, and no CPU donated per request
([research record](research-architecture.md#systems-and-mechanisms)).
What donation would add, and what it would cost, is in
[Alternatives considered](#alternatives-considered).

**Calls through IPC gates.** A call from a worker `c` through an IPC gate
makes the thread `s` that the gate is bound to serve `c` until it replies
([design-kernel.md](design-kernel.md#ipc-gates)). The call is a
rendezvous and nothing more: `c` waits; `s` runs on its own group's grant
and at its own urgency, its base as whoever holds its `CONFIGURE` set it
with `erx_thread_set_urgency`, within its group's ceiling; the reply
wakes `c`. Callers queue at `s` by urgency, then in arrival order, as
Fiasco's sender list orders them by priority, and nothing raises `s` for
the callers queued at it, as nothing raises a Fiasco receiver for its
senders. A server that serves callers of different urgencies is given a
base at their highest, within its ceiling; a server whose grant is spent
makes its callers wait for its next period, which the policy that sized
its grant accepted. Executors neither call nor wait to receive, so calls
through gates are a mechanism between native threads, such as a program
calling a device shim in a sub-space of the same domain, or a dirty I/O
scheduler of ERTS calling a native server; no gate is bound to an
executor ([Executor class enforcement](#executor-class-enforcement)).

**Relation to Fiasco.** A Fiasco call switches to the server directly and
runs it on the caller's scheduling context until the server's next
scheduling decision, where the donation lapses
(`Thread::activate_ipc_partner` in `thread-ipc.cpp` switches the
execution context alone; `Context::schedule_switch_to_locked` switches
both). erXos's own kernel charges every interval to the running thread's
group, so a server never runs on its caller's time at all. The stopgap
does not take the direct switch: a send makes the server ready, and the
scheduler picks it at the sender's next decision through
`schedule_switch_to_locked`, which switches both contexts, so there too
the server runs at its own urgency and on its own grant from its first
instruction
([design-stopgap-scheduling.md](design-stopgap-scheduling.md#server-urgency-and-charging)).
Neither kernel carries a
donation across a preemption or down a chain of calls, and neither
resolves anything at a decision but the running thread's own group
([design-kernel.md](design-kernel.md#l4-lineage)).

### Executor class enforcement

Every blocking kernel call in `abi/erx_abi.txt` carries the attribute
`executor: allow` or `executor: refuse`, and the generator rejects a
blocking call without one. The generated dispatch refuses a call marked
`refuse` from an executor with `ERX_EWOULDBLOCK` before it can block. The
calls an executor may make are `erx_park` and `erx_umtx_wait` on private
memory. The umtx wait takes the word's address, which the kernel
translates through the caller's own translation tables and reads through
its own mapping of the page, never through the address itself
([design-kernel.md](design-kernel.md#umtx)); the translation names the
memory object that owns the word, and the wait refuses an executor whose
word lies in a shared memory object, because a waker in another domain
could hold it indefinitely. An IPC call or wait is refused like every
other blocking call, while triggering an IRQ object never blocks and is
allowed.

An executor is never a receiver either. Every call that would make a
thread one, binding a gate or an IRQ object to it or arming it for
upcalls with `erx_vcpu_control`, checks the target's class and refuses an
executor with `ERX_ETYPE`; an executor receives only through its group's
ready list, and nothing the kernel delivers ever enters it (S1).

A runtime's own locks, which wait on umtx words in its private memory,
keep working. A native function that blocks on an executor fails with a
status instead of silently removing an executor from its runtime; in
ERTS such a function must run on a dirty I/O scheduler, which is a
worker ([design-runtime.md](design-runtime.md#nifs-and-blocking)). Faults
never make an executor wait: memory is committed before it is used, and
the kernel resolves every fault from the faulting mapping's object or
stops the thread with a fault record, so no fault waits on another party
([design-kernel.md](design-kernel.md#virtual-memory)).

### Timers, ticks and deterministic mode

erXos's kernel has no periodic tick. Each CPU keeps a timer wheel of
deadlines (park deadlines, IPC timeouts, umtx deadlines, refill timers,
grace timers) and programs its timer one-shot for the earliest of the
wheel's next deadline and the running thread's slice end and quota
exhaustion. A CPU with nothing to do waits for an interrupt with only its
wheel's next deadline armed.

In deterministic mode (`erx.det=1`) the machine has one CPU and TCG counts
instructions, so timer interrupts arrive at instruction counts and every
decision is a function of the inputs (invariant S8). Group periods and
deadlines are measured in the same virtual time.

### Concurrency

* **Per-CPU state** (ready queues, per-CPU group records, timer wheel, the
  running thread) is touched only by its CPU, under the CPU's lock, which
  masks interrupts, so nothing else runs on that CPU meanwhile. The rest
  of the scheduler runs preemptibly, as Fiasco's kernel does
  ([design-kernel.md](design-kernel.md#execution-model-and-locking)).
* **Cross-CPU operations** (waking a thread whose CPU is another, moving a
  thread, preempting a remote CPU) are requests posted to the target CPU's
  request queue followed by an inter-processor interrupt when the target
  must act at once, as Fiasco's cross-CPU requests are. The target applies
  them in order when it takes the interrupt or at its next kernel entry. A
  wake from CPU A therefore never touches CPU B's queues, and the order of
  two requests from one sender is preserved.
* **Shared group state**: the pool, under `pool_lock`, touched at most once
  per draw quantum per CPU; the park state, under `park_lock`, touched by
  park, trigger, take ready and executor wake. Both are leaf locks taken
  with interrupts masked: nothing else is taken while either is held, and
  a wake's cross-CPU request is posted after the lock is released.
* **Waiting in the kernel.** A thread that waits, in `erx_park`, an IPC, a
  umtx wait, a pause or on a throttled list, sleeps on its own kernel stack
  with its call in progress, and the scheduler switches stacks; woken, it
  continues where it stopped. No scheduling decision unwinds or restarts a
  call.
* **Shared areas**: the kernel writes the status area with release stores
  where a runtime pairs them with acquire loads (the epochs) and relaxed
  stores elsewhere; the runtime writes the control area, which the kernel
  reads with single loads.
* **Ordering guarantees.** A trigger's listing, and whatever its
  triggerer published before it, are visible to any executor that
  observes the epoch advance it made (S2). A runtime observes capacity
  changes in the order the policy made them, because each is one store of
  a larger sequence number. Requests between two CPUs are applied in the
  order they were posted.

### Complexity

| Operation | Time | Memory |
| --- | --- | --- |
| pick | O(1) for the bitmap, plus O(d) path checks for each thread examined; each thread is examined at most twice per pick (once to reposition, once to throttle), and at most `ERX_PICK_MOVES` threads move between preemption points | none |
| charge | O(d), d the thread's group path's depth, at most 8 | none |
| resolve | one load of the control slot and a walk of the thread's group path, at most 8 | none |
| draw | O(1) under a leaf lock, once per draw quantum per CPU per group | none |
| park, trigger, executor wake | O(1) under a leaf lock, plus a cross-CPU request for a wake | none |
| take ready | O(k) under a leaf lock for the k objects taken, at most 63 | none |
| replenish | per expiry, one splice and one draw, and for each of at most `ERX_REFILL_BATCH` threads released O(d) to resolve it and check its path; charged to the group released | none |
| a call through an IPC gate | the rendezvous and two context switches; no scheduling work beyond the pick on each side | none |
| configure a grant | O(k) cross-CPU requests, k the CPUs that hold the group's throttled threads; a changed quota or period starts another period, and every other limit takes effect at the next decision of each thread | none |

No operation looks a capability up or walks a second group's path: the
only path the scheduler ever walks is the running thread's own.

### A worked example

Domain A is an ERTS domain running a file service with the default band
(base 16, ceiling 31) and a quota the policy sized for its clients. Two
sessions use it: B runs a build that reads thousands of small files, and
C runs an editor whose user has just pressed save. Each has a connection to A,
with a lane into A and a doorbell bound to A's group, and a facet process
in A that acts only for it.

1. B's processes send read requests over B's lane as fast as they can.
   B's facet in A admits its count per period; beyond that, requests stay
   in B's lane, and when the lane is full B's senders block in B's own
   runtime, as a busy port blocks in stock ERTS. B's own quota is not
   spent while they wait, and A is asked for no more than B's facet
   admits.
2. A's executors run B's facet and the file processes it spawns, charged
   to A's group and to the groups above it. Every nanosecond of this is
   A's, whatever B sends (S6), and A's quota per period caps it (S4).
3. C's save arrives on C's lane; C triggers the lane's doorbell. The
   kernel lists it on A's ready list, advances A's epoch and wakes a
   parked executor of A, or, if all of A's executors are running, a
   running one finds it at its next safe point (S2).
4. A's ERTS runs C's facet beside B's. Both are ordinary processes of A:
   ERTS shares A's executors between them by priority and reductions,
   and B's admission bounds how much work B's facet can have in A at
   once, so C's request is decoded and committed within a few of A's
   scheduling rounds rather than behind B's whole backlog. The control
   step for C's request costs what its schema allows, no more.
5. If A's quota for the period is spent, A's executors are throttled
   until A's next period, at most `period_ns`, and C waits with B. That
   is the cost this design accepts: the policy prevents it by sizing A's
   grant for the clients it admits, and the inspector shows A's time per
   client, as A reports it, so an operator sees that B was the reason.
6. A's own urgency is A's: B's and C's ceilings never raise or lower A's
   executors, and A's executors publish at most A's ceiling. A client
   never lifts a server above the server's own grant, and never pays for
   the server's work.

A native case runs the same way: a dirty I/O scheduler of A calling a
native server through an IPC gate waits at the rendezvous while the
server runs on the server's own grant, and A's quota is untouched until
the reply.

Step 3 needs one executor of A to run at all, and step 5 is what happens
when none can. Experiment E-S8 of [plan.md](plan.md) measures C's latency
through a busy and through a throttled A, with A's grant sized by the
policy's rule and undersized, so that the rule is confirmed by numbers
rather than by argument.

## Interfaces

### Kernel calls

The calling convention, capability rules and status codes are those of
[design-kernel.md](design-kernel.md#calling-convention-and-status-codes).
Every call below is bounded; only `erx_park` blocks.

| Call | Authority | Contract | Errors |
| --- | --- | --- | --- |
| `erx_group_create(budget, parent)` -> group, control, status | `budget`: `ALLOC`; `parent`: `CONFIGURE` | creates a group under `parent` with the grant in the caller's UTCB, its per-CPU records and its two shared areas, all charged to `budget`; returns a group capability with every right and two memory capabilities whose ceilings are read-write (control area) and read-only (status area) | `ERX_ENOMEM` (budget), `ERX_ELIMIT` (depth 8), `ERX_EINVAL` (grant), capability errors |
| `erx_group_configure(group)` | `CONFIGURE` | replaces the grant with the one in the caller's UTCB: a changed quota or period starts another period at once, and every other limit applies at each thread's next decision ([Charging and quota](#charging-and-quota)); publishes capacity and run, advances the group's epoch and wakes one parked executor | `ERX_EINVAL`, capability errors |
| `erx_group_info(group)` | `INSPECT` | writes into the caller's UTCB the grant, the usage, the throttling and the parked and ready counts; the per-slot counters are in the status area | capability errors |
| `erx_group_take_ready(max)` -> count | the caller's own group; the caller an executor | removes up to `max` IRQ objects, at most `ERX_MSG_WORDS` (63), from the caller's group's ready list and writes the labels they were bound with into the caller's UTCB; never blocks, and serves the members of a released group as well ([Park and wake](#park-and-wake)) | `ERX_ETYPE` (a worker) |
| `erx_thread_create(budget, space, group, class)` -> thread, slot | `budget`: `ALLOC`; `space`: `THREADS`; `group`: `ATTACH` | creates a stopped thread of `class` in `space`, a domain's space or a sub-space ([design-kernel.md](design-kernel.md#creating-spaces)), with its starting registers in the caller's UTCB, and in `group`, which is the group it is charged to for life; the thread holds a counted reference to each group on `group`'s path until it dies ([Ownership and lifetime](#ownership-and-lifetime)); an executor takes the lowest free slot of the group ([Park and wake](#park-and-wake)) and returns it as `slot` (a worker gets `ERX_SLOT_NONE`), and must be of the space of the group's executors whose space has not stopped, if it has any; a slot whose holder's space has stopped is first handed over, by a bounded spin until the holder's home CPU has applied the request, which keeps no wait record, so the call never waits and an executor may make it | `ERX_ELIMIT` (no free slot), `ERX_EBUSY` (an executor for a group whose executors belong to another space that has not stopped), `ERX_ENOMEM`, capability errors |
| `erx_thread_set_affinity(thread, mask)` | `CONFIGURE` | sets the affinity; takes effect at the thread's next decision | capability errors |
| `erx_thread_set_urgency(thread, urgency)` | `CONFIGURE` | sets a worker's base urgency, clamped at each decision; for an executor, sets the value used when hints are off | `ERX_EINVAL` above `ERX_URGENCY_MAX`, capability errors |
| `erx_park(group_epoch, slot_epoch, deadline)` | the caller's own group | the [park protocol](#park-and-wake); `deadline` is absolute in the kernel clock, `ERX_TIME_NEVER` for none | `ERX_ETYPE` (worker), `ERX_ETIMEDOUT` |
| `erx_executor_wake(slot)` | caller in the same group | advances the slot's epoch and wakes it if parked | `ERX_EINVAL` (empty slot), `ERX_ETYPE` (caller not in the group) |
| `erx_yield()` | none | requeues the caller at the tail of its level unless it is the only ready thread there; clears a yield request | none |

The rights `CONFIGURE`, `INSPECT`, `SIGNAL` and `ATTACH` are a group's,
beside the generic `DUP`, `GIVE` and `DESTROY`; deleting a group, with
`erx_object_destroy` or by destroying the budget that pays for it,
destroys its child groups and kills its member threads
([Ownership and lifetime](#ownership-and-lifetime)).
`SIGNAL` is the right to bind an IRQ object to the group, which is the one
way to signal it; the binding also needs `BIND` on the IRQ object
([design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)).
`ATTACH` is the right to create a thread in the group, and so to spend
its grant: a domain's own group is handed to its runtime with `ATTACH`
and `SIGNAL`, and only the policy holds `CONFIGURE`. No right lets a
holder charge a group it creates no threads in. The policy may give a
domain `CONFIGURE` on a child of the domain's own group, so that the
domain divides its grant among its sub-spaces, as a session does among
its programs ([design-system.md](design-system.md#sub-spaces)); S5 keeps
every child within its parent.

### The runtime contract

A runtime that runs on executors:

1. **Owns its executors.** It creates them with `erx_thread_create` in its
   group, at most 64, and pins those it wants pinned with
   `erx_thread_set_affinity` within the group's cpuset.
2. **Reads epochs before looking for work, and parks only through
   `erx_park`** with the epochs it read. It never spins on the kernel's
   values at length; a short spin before parking is its own choice and its
   own expense.
3. **Takes wake-ups at safe points.** It looks at its own sources, its
   lanes' and rings' positions and the capacity sequence, and, when the
   status area's `ready` is not zero, takes the group's ready list with
   `erx_group_take_ready` and handles each label it took. Labels it does
   not recognise are ignored.
4. **Checks at each safe point**, where it holds no lock and its current
   process is consistent: the capacity sequence (and adjusts its active
   executors) and its lanes. With deferred preemption, it raises `defer`
   around its critical sections and checks `yield_req` whenever `defer`
   returns to zero.
5. **Publishes what it chooses to publish**: each executor's urgency, as
   the urgency of the most urgent work that executor holds. It is
   optional and clamped.
6. **Never blocks an executor** on anything but `erx_park` and its own
   private umtx words. Blocking work goes to workers.
7. **Expects nothing else.** The kernel resumes a preempted executor where
   it stopped, never transfers control to the runtime, and refuses to arm
   an executor for upcalls.

What a runtime gets in return: its executors run within its group's grant
and spend no one else's; its wakeups are never lost; it learns about
capacity changes and yield requests in the order they were made; and its
peers' states are visible to it when its group enables status words.

ERTS's adapter is in [design-runtime.md](design-runtime.md#scheduling).
The second implementation the contract is tested with is the test
runtime of the kernel's QEMU suite, a small C program on executors that
the hostile-runtime tests drive ([Verification and
testing](#verification-and-testing)).

### Configuration

* `erx.sched=c0`, `c1` or `c2` caps the features any group may enable, as
  in the [configuration ladder](#overview); `erx.sched=` may also list
  flags (`hints,defer,status,place`) and `quota`. The default is `c2`,
  every feature allowed, with each group's own flags choosing among them;
  a feature that gate G8 drops on its numbers ([plan.md](plan.md)) is off
  in groups' default flags and stays available behind its flag for
  measurement. The cap has no exception: nothing is on in a group that
  its flags and the cap do not both allow.
* Group grants are policy, set by the system domain's resource policy
  ([design-system.md](design-system.md#resource-policy)).

### Interaction with other subsystems

| Subsystem | Interaction |
| --- | --- |
| Kernel objects and capabilities | groups are objects charged to budgets, each dying with its budget; a thread's group is fixed at its creation and is the only group the scheduler ever charges for it ([design-kernel.md](design-kernel.md#objects-and-capabilities)) |
| IPC gates | a call is a rendezvous; the server runs on its own grant and at its own urgency, and callers queue by urgency ([Service work](#service-work)); binding a gate refuses an executor ([design-kernel.md](design-kernel.md#ipc-gates)) |
| IRQ objects | one bound to a group lists itself on the group's ready list and wakes a parked executor, whether software or a device line triggers it, so a runtime's event loop takes frames on its lanes, pipe wake-ups, channel messages and device interrupts alike ([design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)) |
| Connections | the system domain creates a connection's lanes and doorbells when it introduces two domains; the domain that reads a lane binds its doorbell to its own group ([design-domains.md](design-domains.md#connections)) |
| Drivers | a driver is an Erlang process in a domain that holds its device; the device's IRQ object is bound to that domain's group and reaches the driver through the runtime's event loop, and the driver's time is its domain's ([design-system.md](design-system.md#drivers), [design-runtime.md](design-runtime.md#the-device-nif)) |
| Signals | a worker of a POSIX program takes its signals as upcalls through Fiasco's vCPU interface; arming refuses an executor ([design-kernel.md](design-kernel.md#vcpu-upcalls), [design-programs.md](design-programs.md#signals-in-liberx)) |
| Sub-spaces and programs | a sub-space's threads run in groups its creator holds with `ATTACH`, so they spend the creator's grants; a session's programs run in the session's group tree ([design-programs.md](design-programs.md#a-program-is-a-port)); a runtime in a sub-space has a group of its own, since a group's executors belong to one space, which its creator creates under a group it holds `CONFIGURE` on ([design-kernel.md](design-kernel.md#creating-spaces), [design-system.md](design-system.md#sub-spaces)) |
| Pausing | a held space's threads go on running kernel code, woken, preempted and helped as usual, and wait in `ERX_WAIT_PAUSED` at their return to user mode, off the ready queues and the throttled lists, until the last hold goes; its executors read `ERX_EXEC_PAUSED` meanwhile. Since a group's executors share one space, a pause holds all of them, and a trigger meanwhile is handled after the resume. A pause never changes a grant, so job control and `fork` leave the policy the one writer of grants ([design-kernel.md](design-kernel.md#threads-and-faults)); the copy of a space for `fork` runs on the thread that asks for it and is charged to that thread's group, never to the child's, which may have no grant yet ([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces)) |
| ERTS | the adapter replaces scheduler sleep and wake, the poll set, and binds executors ([design-runtime.md](design-runtime.md#scheduling)) |
| System domain | creates a group for each domain under its principal, owns the group tree, grants and capacity, and sizes every shared service's grant for the domains it serves ([design-system.md](design-system.md#creating-a-domain), [design-system.md](design-system.md#resource-policy)) |
| Inspector | reads `erx_group_info` and shared areas as kernel-reported values, and a service's per-client attribution as runtime-reported ones ([design-live.md](design-live.md#inspection)) |

## Compatibility and migration

Nothing outside erXos depends on this interface. Inside erXos, the
interface is versioned with the native ABI
([design-kernel.md](design-kernel.md#the-abi-file)), and the shared
areas' layouts are part of it. Until a release promises compatibility, a
change to a call or a layout replaces the old form outright and is a new
ABI version: no field is kept for an earlier runtime, and a runtime
checks the ABI version that the kernel reports at startup and refuses to
run against another.

Erlang code sees stock behaviour with three documented differences, each
with a test ([design-runtime.md](design-runtime.md#erlang-visible-behaviour)):
`erlang:system_info(schedulers_online)` follows the group's capacity;
scheduler binding (`+sbt`) is the adapter's pinning and cannot be changed
from Erlang; and a NIF that blocks on a normal scheduler fails instead of
stalling it.

The stopgap implements the part of this interface that the plan's vertical
slice uses on the modified Fiasco, configurations C0 and C1: groups,
shared areas, park and wake and urgency resolution are a Fiasco kernel
object around the same C17 core; an IRQ object bound to a group is
Fiasco's IRQ object with the group in place of a thread as its target;
Fiasco's IPC rendezvous carries erXos's IPC calls as
[design-stopgap.md](design-stopgap.md#ipc-gates-and-where-transfer-fits)
binds them, and what a server runs on from its first instruction, with
no direct switch, is
[design-stopgap-scheduling.md](design-stopgap-scheduling.md#server-urgency-and-charging)'s;
accounting runs at Fiasco's
timer interrupts, a 1 ms periodic tick, so quota enforcement there is
accurate to 1 ms per CPU per period instead of to the one-shot timer.
C2's features are erXos's kernel's alone; the stopgap's scope table lists
each difference
([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)).

## Failure handling, diagnostics and debuggability

| Failure | Detection | State left | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A runtime ignores yield requests | the grace timer | none; the executor is preempted | the kernel | the slot's `overruns`; a trace event |
| A runtime spins instead of parking | quota | its group is throttled each period | nobody needs to | throttle counts and usage in the inspector |
| A runtime writes garbage into its control area | every load is validated | none | the kernel clamps | nothing: an urgency is clamped and a `defer` count only delays within the grace |
| An executor makes a blocking call | the generated dispatch | none | the caller | `ERX_EWOULDBLOCK`; in ERTS, an error from the NIF and a trace event naming the call ([design-runtime.md](design-runtime.md#nifs-and-blocking)) |
| A service's quota is spent while it serves | path check | the service's threads are throttled until its next period; every client of the service waits | the kernel releases them at the period's start | throttle counts and usage under the service's group; the service's per-client attribution names who spent it |
| A caller's reply deadline passes while a server serves it | the IPC state machine | the server's reply finds no caller | the kernel | the caller's `ERX_ETIMEDOUT`; the server's `ERX_ENOCALLER` ([design-kernel.md](design-kernel.md#ipc-gates)) |
| A gate or an IRQ object is bound to an executor, or an executor is armed for upcalls | the binding call's class check | nothing bound or armed | the caller | `ERX_ETYPE` |
| A group's budget cannot pay for creation | the charging funnel | nothing created | the caller | `ERX_ENOMEM` |
| A group is deleted while it has member threads or child groups | `erx_object_destroy`, or the destruction of the budget that pays for it | its child groups destroyed and its member threads killed, each finishing its call on its own path's quota, or on the destroying call's time when that quota is zero, and dying before it returns to user mode; its record kept until the last of them is dead ([Ownership and lifetime](#ownership-and-lifetime)) | the kernel | the group gone from the inspector, with its members' deaths |
| A park deadline passes | the timer wheel | the executor is removed from the parked FIFO | the kernel | `ERX_ETIMEDOUT` |
| An executor dies parked or queued | its space's stop, its deletion or its group's destruction | its references dropped; its slot freed by its own teardown if it still holds it, or already taken over by a new executor ([Park and wake](#park-and-wake)) | the thread's own teardown, then the reaper for its record | the slot reads `ERX_EXEC_NONE`, or the state of the executor that took it over |
| An internal inconsistency in the scheduler's records | assertions in debug builds; the core's model tests | a debug build stops with the record dumped | developers | a panic report in debug builds only |

**Inspection.** `erx_group_info` and the status area expose everything the
kernel knows: grant, usage per period and in total, throttling per CPU,
parked and ready executors, per-slot preemptions and overruns. The
inspector shows these as kernel-reported; what a runtime says about its
processes, a service's time per client included, is shown as
runtime-reported ([design-live.md](design-live.md#inspection)).

**Tracing.** The kernel's trace ring records dispatches, preemptions,
yield requests, overruns, throttles, refills, parks and wakes with the
thread and group involved ([design-kernel.md](design-kernel.md#trace-ring)),
and the host tool shows them on one timeline with the runtime's events.

## Security

**Trust boundaries.** Every runtime is untrusted by the kernel; so is every
value in a control area and every argument of the calls above. The policy
that sets grants is the system domain's, which holds `CONFIGURE`.

**Untrusted inputs and their validation.**

| Input | Validation |
| --- | --- |
| published urgency | one load; clamped to the minimum ceiling of the thread's group path |
| `defer` | one load at each preemption decision; any non-zero value only defers a preemption for at most the group's grace, after which the kernel preempts and counts an overrun |
| labels | chosen by whoever binds an IRQ object to the group, which needs `SIGNAL`: the system domain below `ERX_LABEL_SPLIT`, the group's own runtime at or above it; the kernel copies them out and never interprets them |
| `erx_park` epochs and deadline | compared, not trusted; deadline clamped to the clock's range |
| grants | from `CONFIGURE` holders only; every field clamped; limits derived along the path |

**Resource limits.** Groups, threads and shared areas are charged to
budgets; a group tree is at most eight deep; a group has at most 64
executors. A runtime can make the kernel do bounded work per decision: one
urgency load and a walk of at most eight groups along the thread's own
path. A decision touches no group off the thread's own path, whose
records the thread's counted references keep for as long as the thread
exists.

**What a hostile runtime can do.** Waste its own quota; delay its own
processes; make its executors fail blocking calls. It cannot exceed its
group's grant, raise its urgency above its group's ceiling, charge any
group but its own, block another domain's executors, or make the kernel
run its code.

**What a hostile client can do to a service.** Send what its facet admits
and its lane holds; fill its own lane and block itself. It cannot make
the service spend more than the service's grant, because the service's
threads are charged to the service's group whatever they do (S6); it
cannot take more than its share of the service per period, give or take
what it had in flight when the share ran out, since its facet stops
admitting its requests once the
reductions they cost reach the share, however costly the state it built
makes them; and it cannot raise or lower the service's urgency. What it
can do is take its share of the service's grant and, when the service's
quota is spent, slow every client of that service together; the policy
sizes the grant and the shares for that ([Service work](#service-work)),
and the inspector names the client.

**Information leaks.** The status area of a group is visible only to
whoever maps it: the runtime and the inspector. Other domains learn about
a group's usage only through timing, which the
[residual risks](design.md#residual-risks) accept.

**Residual risks accepted.** A service's quota is shared by its clients,
so a client within its share can slow the others when the shares
admitted exceed the quota; the mitigation is policy (a grant sized to
cover the shares it admits) and the inspector's attribution, which names
the client. A doorbell ring that finds nothing costs the receiving
runtime one pass on its own grant (a wake, which may cross CPUs, one
`erx_group_take_ready` and one `erx_park`) against the one
`erx_irq_trigger` the ringer pays; the ringer holds `TRIGGER` on exactly
the doorbells of the lanes it writes, so it can ring only parties that
agreed to read from it, and a receiver that is rung for nothing may stop
reading that lane and tell the system domain, which takes the connection down
([design-domains.md](design-domains.md#connections)). E-S5 measures the ratio.

## Verification and testing

| Layer | Test | Oracle |
| --- | --- | --- |
| Pure core, host | unit and property tests of `erx_sched_resolve`, `_charge`, `_draw` and `_pick`: random trees, grants, charges and decisions | a reference model in Ruby over the same inputs; a seeded charge that skips a level, and one that charges a second thread's group, each fail |
| Protocols, host | exhaustive exploration of the park protocol (two executors, two IRQ objects triggered repeatedly, a capacity change, deadlines, epochs to depth 12) and of `erx_defer_step` (every event in every state) | no lost wakeup; every request resolved; a seeded park that compares outside the lock loses one |
| Concurrency, host | the park lock and pool under ThreadSanitizer with many threads | TSan |
| Build | the chokepoint checks: the charge function is the one writer of a group's usage; the shared-area accessors are the one reader of the control area | a seeded second writer of usage and a seeded direct load from the control area each fail the build |
| Kernel, QEMU | hostile runtimes: random control-area writes, executors calling every blocking call, gates and IRQ objects bound to executors, executors armed for upcalls, executors that never yield, groups that spin | invariants S1 to S7; no group but the runtime's own charged |
| Kernel, QEMU | quota accuracy: one group spinning at 10% and 30% on one and four CPUs, measured per period | S4's bound |
| Pure core, host | draws with quotas from 1 ns to the whole machine over cpusets of one to 64 CPUs, and slices returned across period boundaries in every order against refills by other CPUs | every positive quota draws a positive slice; no remainder is counted twice; every overrun is charged once |
| Pure core, host | refill: cohorts of one to 1,000 threads on a CPU under quotas of zero, of one draw quantum and uncapped, below exhausted ancestors, with threads that throttle again during a release, and grants replaced at every step of a release | no thread joins one group's list twice in one of its periods; no batch released while the group cannot supply quota; a zero quota costs one expiry and one failed draw per period and CPU; the release's time charged to the group released; after a replacement, every slice returned once, every debt carried and every cohort released under the changed grant at once |
| Kernel, QEMU | populations: a domain's whole own budget spent on ready threads on one CPU, whose group is then exhausted and refilled, while its executors churn their published urgencies | every stretch with interrupts masked on that CPU within K13's 20 microseconds; another domain's wake latency there unchanged beyond one pick's moves |
| Kernel, QEMU | ceilings: a server whose group's ceiling is 15 serving a caller at 40, with a second caller queued; a runtime publishing 63 in every slot under a ceiling of 31 | the server never above 15; no raise for the queued caller; every executor clamped to 31 |
| Kernel, QEMU | own-group charging: a native server serving callers of three groups through one gate and through a gate per caller; a service runtime serving clients of three domains over lanes; usage per group against a cycle-counter ground truth around each unit of work | every nanosecond of serving on the server's group, none on a caller's (S6); a seeded charge to the caller's group fails |
| Kernel, QEMU | a flooding client: one client sends as fast as it can to a capped service while a second client sends one request per period | the service's usage within its quota per period (S9); the flooder's lane full and its senders blocked in its own runtime; the reductions spent on the flooder per period within its share plus the cost of the requests it had in flight when the share ran out, the overrun repaid in the next period, also when its requests grow costlier with state it built in the service; the second client's requests answered within the policy's bound while the service has quota, and every client waiting together once it has none; a seeded facet that skips its account failing the test |
| Kernel, QEMU | finishing: a stopper with a capped group stops a space whose threads are in calls, in `erx_park`, throttled and paused, and a stopper whose quota is spent stops one | the finishing work charged to the stopper's group and to no other; the stopped threads never return to user mode; the spent stopper's stop completes at its next period and nothing else waits for it |
| Kernel, QEMU | deletion: `DESTROY` on a group whose executors run, park, sit throttled under a spent quota and serve calls, with a child group whose members do the same; the destruction of the budget that pays for such a group; a group whose last capability closes while its executors run and park and IRQ objects bound to it wait on its ready list; an IRQ object bound to a group fired while the group's teardown runs | every member of the group and of its child killed, none returning to user mode, each finishing its call charged to its own path, with a seeded teardown that frees the record while a killed member still runs failing the test; a group destroyed while its quota is zero and a member is inside a long range call, whose member the destroying call runs to its end, so that the member is dead when the destroy returns, with a seeded destroy that leaves the member to its own spent grant failing the test; the released group's executors park and wake until the last one ends, then its waiting deliveries are owed to their objects' next bindings, or dropped for a level-sensitive line; the record freed after the grace period and the last member's death, and the creator's budget, or its parent once the budget is destroyed, back at its baseline |
| Kernel, QEMU | pause: a group's executors running, parked and serving calls while their space is paused and resumed, with triggers during the pause; an executor of another space created in the group; a worker that takes the ready list | none returns to user mode while paused, and slots read `ERX_EXEC_PAUSED`; every trigger is handled after the resume (S2); `ERX_EBUSY`; `ERX_ETYPE` |
| Kernel, QEMU | a stopped space's executors parked in a group when a new space creates executors in it before the old ones have died, with triggers in between | the new executors created with free slots, every trigger delivered to one of them, each old executor dead once woken, and a slot taken over from an old executor that dies afterwards still held by its new executor, whose wakes by slot all arrive (S2) |
| Kernel, QEMU | determinism: a fixed workload in `erx.det=1` twice | byte-identical traces |
| Runtimes | ERTS's adapter and the test runtime against the contract: wakeups under storms, capacity changes, yield requests | the runtimes' own tests and OTP's suites |
| Runtimes | runs: four ERTS domains on eight CPUs with the same cpuset and a capacity of two each, normal and dirty CPU schedulers busy, runs placed by the policy | each domain's executors only on its own run; no CPU shared by two domains' executors in steady state |
| Runtimes | attribution: a service serving three clients with known work per request, its per-client report against a cycle-counter ground truth | the report within the budget E-S5 sets; shown as runtime-reported in the inspector, with a seeded misreport changing nothing outside the service: its group's usage stays within its quota |
| Parity | the stopgap and erXos's kernel run the same scheduler tests over C0 and C1 | identical decisions on the core's traces; documented accuracy differences, the stopgap's tick and its stored priorities among them |

Every test runs under TCG and HVF; a test that passes under only one is a
bug until explained. The host builds run under ASan and UBSan, and the
concurrency tests under TSan.

## Performance

**Cost model.** Measured figures are cited; the rest are estimates from
counting memory accesses and crossings, to be replaced by `tools/erx bench`
results.

| Step | Cost | Basis |
| --- | --- | --- |
| kernel entry from user mode and exit | 22 ns; 31 ns with an address-space switch | measured under HVF on the M4 ([research](research-baselines.md#exception-and-address-space-switch-costs)) |
| Fiasco's null system call; one-way IPC within and between address spaces | 29 ns; about 51 and 89 ns | measured under HVF on the M4; the IPC figures are converted from an emulated cycle counter ([research](research-hierarchical-scheduling.md#fiasco-under-hvf)) |
| pick | 30 to 80 ns warm: the bitmap, the head thread, one or two loads from the control area, a path walk of four groups | estimate |
| charge | 10 to 20 ns: one counter read and a subtraction per group on the path | estimate |
| draw | one leaf lock and a few arithmetic operations, once per draw quantum (at most 1 ms) per CPU per group | estimate |
| park and wake on one CPU | about one IPC round trip: 150 to 300 ns | estimate from the IPC figures above |
| wake of an executor on an idle CPU | a cross-CPU request, an inter-processor interrupt and the exit from the wait for an interrupt: 2 to 20 microseconds | estimate; never measured under HVF |
| urgency preemption of a thread inside a kernel call | the longest section that holds a CPU's lock or a spinlock; for comparison, Fluke's fully preemptible process model kept a 1 ms periodic thread's worst latency at 19.6 microseconds, against 7.4 ms without preemption points, at a cost of 5 to 20% of throughput | unmeasured on erXos; the Fluke figures are cited, on a 200 MHz Pentium Pro ([research](research-hierarchical-scheduling.md#kernel-execution-models)) |
| status words | one store per transition, a cache miss when the runtime has read the line: 10 to 100 ns | estimate |

**Budgets.** These are requirements, confirmed or revised by the
experiments below:

* a pick or an enqueue costs at most 150 ns;
* a park and a wake on the same CPU cost at most 1 microsecond together;
* an executor woken for an idle CPU runs within 20 microseconds;
* accounting, draws and status words cost at most 1% of CPU time at the
  default slice;
* quota enforcement is accurate to one draw quantum per CPU per period on
  erXos's kernel and to one 1 ms tick per CPU per period on the stopgap;
* a shared service's per-client attribution, as its runtime reports it,
  is within a stated fraction of a cycle-counter ground truth, the
  fraction set by E-S5.

**Experiments.** Each runs under HVF on the primary host (Apple M4 Max,
macOS) with QEMU 11.1.2 (`virt-11.1`, `-cpu host`, configured as
[design-platforms.md](design-platforms.md#qemu-virt) describes), erXos built with
the release flags of [design.md](design.md#build-and-toolchain), and is
repeated under TCG for correctness only; TCG numbers are never compared
with HVF numbers. Results are recorded with host, load, accelerator, QEMU
version, compiler, flags, workload and baseline. [plan.md](plan.md) places
each where it gates work.

| Id | Hypothesis | Method | Measurement | Decision it informs |
| --- | --- | --- | --- | --- |
| E-S1, the ladder | each step of C0 to C2 pays for itself on erXos's workloads | workloads W1 to W7 below under C0, C1 and C2 (each flag alone and all together), which `tools/erx bench ladder` runs | throughput, p50 and p99 latency, CPU per message, kernel entries per message, preemptions, throttles, overruns | which cooperation features stay enabled by default, and whether any is removed |
| E-S2, dispatch models | lightweight processes scheduled by their runtime beat a kernel thread per process on erXos's messaging patterns, and per-process kernel dispatch is not needed | the same ping-pong, ring and fan-out benchmarks as Erlang processes in one ERTS domain, as Erlang processes in two domains over a connection, as kernel threads in one space and in two spaces over IPC gates and IRQ objects, and on stock OTP on the host | round-trip time, spawn and exit time, memory per process, context switches | whether any kernel object per lightweight process is justified, as the proposal asks |
| E-S3, critical sections | ERTS leaves every deferred critical section within 50 microseconds in 99.9% of cases | instrument the adapter to record how long `defer` stays raised and the time from each yield request to `erx_yield`, over OTP's suites and the benchmarks | the distribution of deferred windows and their tail by lock | the default `grace_us`, and which ERTS locks raise `defer` |
| E-S4, wake latency | idle-first wake placement lowers wake latency on a loaded machine | trigger an IRQ object bound to a group with parked executors while other groups load some CPUs, FIFO against `ERX_GROUP_PLACE` | trigger to first instruction of the woken executor, p50 and p99 | whether `ERX_GROUP_PLACE` stays; the wake budget |
| E-S5, shared services | a flooding client slows a capped service's other clients by no more than its admitted share, a service never exceeds its grant, its per-client report tracks a cycle-counter ground truth, and a doorbell ring that finds nothing costs the receiver at most one pass | one client flooding and one sending one request per period against a service at several quotas and admissions; ground truth from the cycle counter around each unit of work; a domain ringing a lane's doorbell with an empty lane at controlled rates | the second client's latency p50 and p99 against the service's quota and the flooder's admission; the service's usage per period; attribution error per client; the receiver's cost per empty ring against the one trigger the ringer pays | the policy's rule for sizing a service's grant and admissions; the attribution budget; whether a receiver needs a limit on empty rings |
| E-S6, lock holders | deferred preemption reduces lock-holder preemption under oversubscription | two ERTS domains on four CPUs, each with four executors, hammering a shared ETS table and process locks, with and without `ERX_GROUP_DEFER` | spin time, umtx waits, throughput, overruns | whether `ERX_GROUP_DEFER` stays |
| E-S7, quota accuracy | quotas are enforced within one draw quantum per CPU per period, with replenishment per period sufficient | a spinning group capped at 10% and 30% on one and four CPUs; periods of 10 and 100 ms on the stopgap, whose 1 ms tick bounds its resolution, and of 1, 10 and 100 ms on erXos's kernel; bursts that straddle a period boundary; a group that leaves CPUs holding local quota | usage per 10 ms, 100 ms and 1 s window, and in any window of one period; quota stranded on CPUs a group left; overhead | the default period and draw quantum; whether idle CPUs hand local quota back to the pool, and whether sporadic replenishment replaces refill per period |
| E-S8, a busy service | an urgent client's latency through a busy or throttled service stays within the policy's bound when the service's grant is sized by the policy's rule, and the rule's headroom is enough | the worked example: an ERTS file service with one flooding client and one urgent client, its grant sized by the rule and undersized, busy and throttled | the urgent client's request latency p50 and p99; the service's own throughput; time spent throttled | the sizing rule's headroom, and whether a service needs a child group per client class ([Risks and open questions](#risks-and-open-questions)) |
| E-S9, capacity | capacity and runs keep several runtimes from oversubscribing the machine or crowding onto the same CPUs | four ERTS domains on eight CPUs with the same cpuset, each started with eight schedulers and busy on normal and dirty CPU schedulers together, with and without capacity advice, and with runs placed by the policy against runs all at position 0 | throughput, context switches, run-queue lengths, each CPU's occupancy by domain and the time each domain's executors wait behind another's, time for a runtime to adapt | the policy's capacity and placement rules |
| E-S10, blocking refusal | refusing blocking calls on executors breaks no OTP application erXos ships | run OTP's suites with the refusal and count refusals by call site | refusals per NIF and BIF | which NIFs must move to dirty schedulers, recorded as documented differences |

The workloads of E-S1:

* **W1**, same-domain ping-pong and a ring of 10,000 processes (entirely
  inside one runtime);
* **W2**, cross-domain ping-pong between two ERTS domains over a connection;
* **W3**, native call round trip through an IPC gate, same space and cross
  space;
* **W4**, two ERTS domains with eight executors each on four CPUs running
  a message-heavy benchmark, plus one `high` process measuring timer
  latency;
* **W5**, a domain spinning on every executor beside a victim domain
  measuring latency (isolation, C0 against C1);
* **W6**, the lock-holder workload of E-S6;
* **W7**, the busy-service workload of E-S8.

## Portability

The core is portable C17 with no architecture dependency. The effect
layer uses the architecture layer's timer, its wait for an interrupt and
its inter-processor interrupts
([design-kernel.md](design-kernel.md#port-contract)). A board
with a CPU topology may extend placement beyond "last CPU, then idle CPU"
behind the same placement function. The 128-byte shared line covers every
supported core; a core with larger lines changes one ABI constant.

## Dependencies

No new dependencies. The scheduler is erXos's code built from the design of
Fiasco's scheduler (MIT, at commit `50bbe8a9`) and of ERTS's scheduler
(Apache-2.0), both already in the tree, and from published designs cited
below.

## Alternatives considered

**CPU donation: a server on its caller's time, a service on its
client's.**

* *How it works.* A call through an IPC gate lends the server the
  caller's grant and urgency for the whole call, down a chain of nested
  calls, as seL4's scheduling contexts and passive servers do and as CPU
  inheritance scheduling bills a donor; a service that serves another
  domain names, in a word of its control area, a group the client's
  policy carved from the client's grant, and the kernel charges that
  group while the service works for that client. Priority bands for a
  runtime's processes are the same mechanism turned inward: child groups
  per band, named per process. The kernel resolves a payer at every
  decision, through the one capability lookup, and falls back to the
  thread's own group when the payer is spent, deleted or out of the call.
* *What it buys.* Two things that nothing else gives. Per-client CPU
  attribution that the kernel enforces, so a service's clients pay for
  what they cause and a flooder spends its own quota. And the progress of
  a paying client through a service whose own quota is spent: the
  service's executor keeps running on the client's donation when the
  service's grant would have throttled it.
* *What it costs.* A payer per thread, resolved at every decision; a loan
  with a lifetime that spans preemptions, chains of calls and the ends of
  callers, held by counted references to another thread and another
  group; a fallback that puts a service on its own grant in the middle of
  a client's request, which the service must survive, so it needs a
  bounded return point, a set-aside list per spent client and a report of
  when the client can pay again; an admission inequality over per-step
  CPU bounds, which for BEAM code with garbage collection nobody can
  produce; a kernel entry per client switch where attribution must be
  exact; a donated group per binding, created and deleted with it; a
  separate reservation for the kernel work of finishing stopped threads,
  whose payer may be gone; and, once a trigger can carry a payer, a second
  way to set one. Each of these is a list that grows by one at every
  review.
* *Why it lost.* The two guarantees are had otherwise. Attribution is a
  count the service's runtime already has per process, which the
  service's facets use to hold each client to its share and the
  inspector shows; the kernel need not enforce it. A paying client's
  progress through a spent service is a sizing problem: the policy caps
  and sizes every shared service's grant for its clients, and a trusted
  service that is sized right is not spent. What remains is the cost that
  every client of a spent service slows together, which Genode has
  accepted for fifteen years with memory per session and CPU by quota and
  priority per component, no CPU donated per request ([research
  record](research-architecture.md#systems-and-mechanisms)).
  Deleting donation deletes the payer, the loan, the fallback, the
  reservation and the arithmetic at once, and leaves a scheduler whose
  only path is the running thread's own group. The stopgap's Fiasco keeps
  its direct switch, which lapses at the next scheduling decision and
  needs no change ([Service work](#service-work)).

**Scheduler activations and other upcall interfaces.**

* *How they work.* The kernel tells the runtime about every block, wake and
  preemption by an upcall onto a fresh context, and the runtime decides
  what runs. Nemesis resumed a domain only while its activation bit was
  clear and otherwise upcalled it; Barrelfish dispatchers distinguish
  enabled and disabled execution; L4Re's vCPU delivers events by upcall
  ([research](research-hierarchical-scheduling.md#kernel-runtime-interfaces)).
* *Why they lost.* Each needs machinery so that an upcall never re-enters
  a runtime's scheduler inside its critical section: an activation bit
  plus two save slots and an atomic return, or a disabled flag with
  critical-section recovery. The systems that shipped them for general
  threads abandoned them. erXos's runtimes have nothing to gain from an
  upcall that a value in a shared page and a safe point do not give them,
  and Fiasco's vCPU round trip costs about 140 ns on the primary host,
  about 4.5 times a crossing with an address-space switch
  ([research](research-hierarchical-scheduling.md#fiasco-under-hvf)). The
  user's rules exclude them for executors. erXos uses Fiasco's vCPU
  interface only where an upcall is the point: a POSIX program's signal,
  delivered to a worker that runs no lightweight processes, whose
  events-enabled flag plays the activation bit's role
  ([design-kernel.md](design-kernel.md#vcpu-upcalls)).

**A kernel thread per lightweight process.**

* *How it works.* Every Erlang process is a kernel-scheduled entity, so the
  kernel sees every priority and can preempt one process for another.
* *Why it lost.* A spawn becomes a kernel object and a kernel call, a
  message wake becomes a kernel decision, and ERTS's process switch, a few
  loads and stores, becomes a context switch. The proposal asks not to add
  one unless experiments prove it necessary; E-S2 is that experiment. The
  cost of Fiasco's IPC, about 50 to 90 ns one way (measured, converted
  from an emulated counter), makes the comparison worth running rather
  than obvious.

**One kernel stack per CPU, the event model.**

* *How it works.* A thread that waits in the kernel leaves no kernel stack
  behind: its record is its whole state, a long call is cut into bounded
  parts that each end done, waiting, to be restarted or stopped, and the
  kernel is never preempted, so a CPU changes threads only on its way back
  to user mode. seL4 and Fluke's interrupt model work this way.
* *Its merits.* A thread costs a record instead of a stack, 300 bytes in
  Fluke's interrupt model against 6,491 to 8,832 in process-model kernels
  (cited); a stopped thread can be read, copied or destroyed at any
  moment; a kernel that is never preempted needs no helping locks, and the
  stack proof covers one stack per CPU. Every scheduling decision would
  fall at a kernel exit, where nothing of a call is in progress.
* *Why it lost.* The user chose Fiasco's process model, and the scheduler
  is simpler for it: a wait sleeps on the thread's own stack and continues
  where it stopped, so no call needs a restart protocol and no decision
  unwinds one, and the stopgap and erXos's kernel run the same model, so
  the core's effects are the same on both. Latency favours the process
  model too: Fluke's fully preemptible process model kept a periodic
  thread's worst latency at 19.6 microseconds, against 7.4 ms in either
  model without preemption points, at 5 to 20% of throughput (cited, on a
  200 MHz Pentium Pro), and the event model approaches that only with a
  preemption point wherever a part could run long
  ([research](research-hierarchical-scheduling.md#kernel-execution-models),
  [design-kernel.md](design-kernel.md#alternatives-considered)).

**Weighted proportional sharing between groups.**

* *How it works.* Start-time fair queuing over a group tree (Goyal, Guo and
  Vin), or a virtual-deadline scheduler such as EEVDF, shares each urgency
  level by weight and is work-conserving.
* *Why it lost.* Simplicity. Quotas cap, capacity advice sizes runtimes
  and places them, and pinning to those places keeps executors of
  different domains from contending in steady state; round robin within a
  level suffices. If E-S1 or E-S9 shows contention at one level that
  quotas cannot fix, a fair queue replaces round robin behind
  `erx_sched_pick`.

**Reservations with deadlines.**

* *How it works.* Nemesis' Atropos gave each domain a slice per period
  scheduled by earliest deadline, with admission control below 100%; seL4
  MCS attaches budget and period to scheduling contexts.
* *Why it lost.* erXos has no hard real-time requirement, and fixed
  urgencies with quotas give drivers low latency and domains isolation with
  less machinery. A group's quota per period is already a reservation's
  budget; deadline scheduling of groups remains possible behind the same
  pick function.

**Core allocation.**

* *How it works.* Akaros grants whole cores to processes and tells a
  process about revocations, though its two theses differ on whether a
  warning precedes them; Arachne, Shenango and Caladan reallocate cores
  among runtimes every few microseconds from a central arbiter.
* *Why it lost.* Whole-core grants waste cores at erXos's scale (a few to
  64 CPUs, many small domains) and need revocation protocols with warning
  periods. Capacity advice, whose runs place each runtime, gives the same
  steady state without revocation, and the policy can still dedicate CPUs
  to a group through its cpuset.

**Delegated kernel scheduling policy.**

* *How it works.* ghOSt and sched_ext let a user-level agent or a loaded
  program decide what each CPU runs, with the kernel enforcing a watchdog.
* *Why it lost.* erXos's policy is small and stable enough to be the
  kernel's own code, and its runtimes already make the fine-grained
  decisions. The principle survives: the kernel delegates to runtimes and
  enforces with deadlines (grace timers, quotas).

**Flattening onto Fiasco's fixed priorities.**

* *How it works.* Map every group to a priority band and every thread to a
  priority, and use the L4Re microkernel's scheduling constraints to cap
  groups.
* *Why it lost.* That is close to C1 already. erXos's own kernel owns its
  scheduler, so the group tree is a first-class object rather than an
  encoding, and the stopgap carries the same core.

**One scheduler for every process, with ERTS as the kernel.**

* *How it works.* A kernel-resident ERTS would hold a scheduling record
  for every process of every domain, and one scheduler would pick
  processes of every domain directly.
* *Why it lost.* It requires ERTS in kernel mode and makes every process
  switch in a user domain a kernel dispatch. With every runtime in user mode
  the kernel stays generic: it need not know Erlang's process model, and it
  can host another runtime.

**A retire call for groups.**

* *How it works.* A group with no member threads is retired: its per-CPU
  records and shared areas are freed, and its object stays until the
  last capability to it closes, so a holder that never closes its
  capability keeps one object record of the creator's budget.
* *Why it lost.* Deleting the group with its delete right, as Fiasco
  deletes a kernel object, does the same and more: it takes the group from
  every holder at once, so the whole record returns, and it needs no call
  of its own. The one rule a group adds, that it outlives its last
  capability while it has a member or a child, as a mapped memory object
  outlives its own, keeps every executor of a released group in a group it
  can park in ([Ownership and lifetime](#ownership-and-lifetime)).

**Refusing to delete a group that has members.**

* *How it works.* `erx_object_destroy` on a group with a member thread or
  a child group fails and changes nothing, so a group is deleted only
  once it is empty.
* *Why it lost.* Destroying a budget deletes every object charged to it
  at once ([design-kernel.md](design-kernel.md#budgets)), and a deletion
  that can be refused would leave a destroyed budget holding a live group,
  or make the budget wait for the threads of another party to end. A
  deletion that kills the members, as a space's stop kills its threads,
  needs no such case: a killed member never returns to user mode, so no
  executor is left in a group it cannot park in either way.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| a shared service at its quota slows every client together, the urgent with the flooder | medium | an urgent request waits up to `period_ns` (10 ms by default) behind a spent service | the policy sizes every shared service's grant for its clients and admits per client; E-S5 and E-S8 measure the rule's headroom; the inspector's attribution names the client; a service may be given a child group per client class if E-S8 shows one is needed |
| lock-holder preemption remains frequent because ERTS holds some locks longer than the grace | medium | spinning and latency inside a runtime under oversubscription | E-S3 and E-S6 measure it; capacity advice avoids oversubscription; `ERX_GROUP_DEFER` is switchable per group |
| refusing blocking calls on executors breaks NIFs in OTP or in user code | medium | applications fail where stock OTP only slows | E-S10 counts refusals over OTP's suites; the refusal is a documented difference; dirty schedulers are the remedy |
| cross-CPU wakes under HVF are slow | unknown | wake latency above budget, felt as messaging latency | E-S4; executors stay pinned and a busy runtime finds work without wakes |
| quotas at 10 ms periods make a throttled domain's latency jumpy | medium | p99 latency for capped domains | E-S7 tunes periods and draw quanta; policy prefers capacity over tight caps |
| refill once per period lets a burst that straddles a boundary use up to twice the quota in one period's span, and local slices strand quota on CPUs a group left | medium | short-term isolation between groups | E-S7 measures both and decides whether a CPU that goes idle returns its local quota to the pool; sporadic replenishment, as in seL4's scheduling contexts, is the fallback |
| accounting at the stopgap's 1 ms tick misattributes short runs | high on the stopgap | coarse statistics there | documented accuracy differences; erXos's kernel uses one-shot timers ([design-stopgap-scheduling.md](design-stopgap-scheduling.md#server-urgency-and-charging)) |
| two runtimes in one space share a group | low | contention and taken wake-ups inside one space | the kernel keeps a group's executors in one space and its ready list to executors; a space that runs two runtimes gives each a group of its own |

Open questions:

* **How does the policy size a shared service's grant?** Each client is
  admitted within its share of measured reductions per period, so the
  service's demand per period is at most the sum of the shares it
  admits, each plus what its client had in flight when the share ran
  out, repaid the next period, with reductions converted to time at the
  rate E-S5 and E-S8 measure. Recommended: size from that sum with
  headroom, confirm the headroom by E-S5 and E-S8, and record the rule in
  [design-system.md](design-system.md#resource-policy); the scheduler
  needs nothing for it.
* **Should a service get a child group per client class?** A service
  whose urgent clients must not wait behind its bulk clients could run
  their facets on executors of a child group with its own quota and
  ceiling, a group of the service's own, created by the policy under the
  service's group. Recommended: not until E-S8 shows that one service's
  grant and ERTS's own priorities cannot keep an urgent client within
  the bound, since it adds a second group per service and a second
  executor pool for the runtime to balance.
* **Is round robin within a level enough?** Recommended: yes, with quotas,
  capacity and pinning; E-S1 and E-S9 decide. The alternative is a fair
  queue behind the same pick function.
* **Default slice, grace and period.** Recommended: 5 ms, 50 microseconds
  and 10 ms until E-S3 and E-S7 report.

## References

* T. E. Anderson, B. N. Bershad, E. D. Lazowska and H. M. Levy,
  "Scheduler Activations: Effective Kernel Support for the User-Level
  Management of Parallelism", SOSP 1991; ACM TOCS 10(1), 1992.
* M. Rasiukevicius, "Thread scheduling and related interfaces in NetBSD
  5.0", 2009; N. J. Williams, "An Implementation of Scheduler Activations
  on the NetBSD Operating System", USENIX ATC 2002, FREENIX track; the
  FreeBSD 7.0 announcement (27 February 2008) and `UPDATING` entry
  20080312, with J. Roberson's commit `6617724c5fb1`. Details and access
  dates in
  [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md#negative-evidence).
* B. Ford and S. Susarla, "CPU Inheritance Scheduling", OSDI 1996.
* G. Banga, P. Druschel and J. C. Mogul, "Resource Containers: A New
  Facility for Resource Management in Server Systems", OSDI 1999.
* P. Goyal, X. Guo and H. M. Vin, "A Hierarchical CPU Scheduler for
  Multimedia Operating Systems", OSDI 1996.
* I. M. Leslie et al., "The Design and Implementation of an Operating
  System to Support Distributed Multimedia Applications", IEEE JSAC 14(7),
  1996; T. Roscoe, "The Structure of a Multi-Service Operating System",
  Cambridge TR-376, 1995.
* A. Lyons, K. McLeod, H. Almatary and G. Heiser, "Scheduling-context
  capabilities: a principled, light-weight operating-system mechanism for
  managing time", EuroSys 2018.
* Genode Labs, "Genode Foundations" 24.05, the chapter on resource
  trading, and the Genode release notes 14.11, 17.05 and 25.08, as read
  for
  [research-architecture.md](research-architecture.md#sources).
* Fiasco, `src/kern/ready_queue_fp.cpp`, `sched_context.cpp`,
  `context.cpp`, at commit `50bbe8a9`, https://github.com/kernkonzept/fiasco.
* Fiasco as shipped in the L4Re snapshot 26.09.0, read 2026-10-31:
  `src/kern/receiver.cpp` (the sender list), `sender.cpp` and
  `prio_list.cpp` (senders queued by priority, in arrival order within
  one), and `context.cpp` (`Context::schedule`, where a helped thread
  gives up its helper).
* Fiasco's master branch as surveyed for erXos's research, read
  2026-10-31: `src/kern/thread-ipc.cpp`, `Thread::activate_ipc_partner`,
  whose direct switch to a receiver changes the execution context and
  keeps the sender's scheduling context, and `context.cpp`,
  `Context::schedule_switch_to_locked`, where a scheduling decision
  switches both.
* B. Ford, M. Hibler, J. Lepreau, R. McGrath and P. Tullmann, "Interface
  and Execution Models in the Fluke Kernel", OSDI 1999, as read for
  [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md#kernel-execution-models).
* OTP 29.1.2, `erts/emulator/beam/erl_process.c` (`erts_schedule`,
  `scheduler_wait`, `wake_scheduler`, `try_steal_task`),
  https://github.com/erlang/otp, tag `OTP-29.1.2`.
* Every other source, with editions, access dates and the ideas taken and
  rejected:
  [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md).
