# The stopgap's scheduling: stops, park and wake, and charging

This document binds three parts of erXos's kernel interface on the
modified Fiasco that stands in for erXos's kernel: the stop of a space
and its exit record (invariant K18 of
[design-kernel.md](design-kernel.md#invariants)), the park protocol of
runtime executors (S2 and S3 of
[design-scheduler.md](design-scheduler.md#invariants)), and the urgency
and charging of a server that serves a call (S5 and S6). The contracts
belong to those two documents; [design-stopgap.md](design-stopgap.md)
binds the rest of the interface on the fork and fixes what this document
relies on: the one trap, the common return path, the object header with
its one reference count, and the teardown order. Milestone M1 of
[plan.md](plan.md#m1-the-stopgap-speaks-erxoss-interface) builds all of
it in configuration C0. The decisions live in C17 cores shared with
erXos's kernel and built for the host; the C++ around them is thin glue
on Fiasco's mechanisms, named by file and line below.

## Context

**What the stopgap promises.** Development builds run trusted code
only, and the fork is never hardened. For trusted workloads this binding
commits to what M1 needs and its tests check: no memory error, no
deadlock, every stop finishing with its one exit record, the interface's
results, and exact accounting. Latency bounds, fairness and progress
against hostile load belong to erXos's kernel; on the fork they are
residuals, recorded in **Risks and open questions**, not built into
inherited code, and reviews of this binding check these commitments,
not the target design's.

**What erXos requires.** A stopped space's threads never return to user
mode, and its exit record arrives exactly once, only when none of them
can act, after each finishing thread has completed the call it is in or
left its wait, however little time the stopped group has left (K18,
[Threads and faults](design-kernel.md#threads-and-faults), [Execution
model and locking](design-kernel.md#execution-model-and-locking)). No
wakeup of a parked executor is lost (S2), an executor blocks only in
`erx_park` or a umtx wait on private memory (S3), a server serving a
caller never runs above its own group's ceiling and is charged to its
own group (S5, S6, [Service work](design-scheduler.md#service-work)).
M1's exit criteria state the cases: a space stopped while its threads
run, fault and call on every CPU posts exactly one exit record after its
last thread has died; a server whose group's ceiling is 15 runs at most
at 15 while serving a caller at 40 and on its own group's grant from its
next scheduling decision; the park protocol's exhaustive host model
passes; the park lock passes ThreadSanitizer; two hostile native domains
with threads on every CPU run for ten minutes under TCG and HVF with one
and four CPUs. Gate G1 measures `tools/erx bench stop`, park and wake on
one CPU and across CPUs, and an IPC round trip within and across spaces.

A waiting thread holds nothing across its sleep, and one function
completes every wait (K33, [A wait holds
nothing](design-kernel.md#execution-model-and-locking)): a call that
waits does its work first and keeps no counted reference, no lock and no
result still to translate, only its wait record, and whoever ends the
wait calls `erx_wait_complete`. The wait funnel below is K33 on the
fork, with the two departures the kernel design itself notes for the
stopgap ([Differences from erXos's kernel](#differences-from-erxoss-kernel)).

**What Fiasco does.** The fork's inherited mechanisms, as the sources
under `fiasco/kernel/src/kern/` have them:

* *The direct switch donates.* A call switches to the server by
  `Thread::activate_ipc_partner` (`thread-ipc.cpp:510`), which calls
  `switch_exec_locked(partner, Not_Helping)`: the execution context
  changes, the CPU's current scheduling context stays the caller's. Only
  `Context::schedule_switch_to_locked` (`context.cpp:1150`), the switch
  the scheduler makes, sets the CPU's current scheduling context to the
  thread it switches to. The ready queue's `deblock`
  (`sched_context.cpp:122`) decides whether a woken thread preempts by
  comparing it with the current scheduling context, so while a server at
  priority 15 runs on its caller's context at 40, a thread waking at 25
  is queued and does not run; with `lazy_q` it leaves a thread that
  preempts out of the queue, for the caller to switch to.
* *Cross-CPU requests wait for the target to run.* `Context::drq`
  (`context.cpp:1667`) defaults to `Drq::Wait` and `eager = false`. A
  request that is not eager is queued to the target context, which gets
  `Thread_drq_ready` and runs the request when its CPU next schedules it
  (`Context::handle_drq`, `context.cpp:1471`); an eager request runs in
  the inter-processor interrupt's handler on the target's CPU
  (`Context::Pending_rqq::handle_requests`, `context.cpp:2160`),
  whatever runs there. The answer is queued to the requester, never
  eagerly (`Drq_q::execute_request`, `context.cpp:1377`); the requester
  waits with `Thread_drq_wait` set, clearing its ready bits and calling
  `schedule()` until the answer is applied (`context.cpp:1696`). Both
  queue loops, `Drq_q::handle_requests` (`context.cpp:1395`) and
  `Pending_rqq::handle_requests`, run until their queue is empty.
  `Thread::kill` (`thread.cpp:677`) sends its remote kill as a waited
  request that is not eager, so a kill of a low-priority thread behind a
  busy higher-priority thread waits for that thread's turn.
  `Thread::remote_handshake_receiver` (`thread-ipc.cpp:1456`) sends its
  handshake eagerly only when the receiver looks ready, and
  `Thread::remote_ipc_send` (`thread-ipc.cpp:1393`) copies a message of
  words inside the request but hands a message with items back to the
  sender's thread context (`thread-ipc.cpp:1416`), since the item
  transfer takes locks.
* *A thread starts dead and dies after it leaves its task.* A new thread
  carries `Thread_dead` until a start writes
  `state_change_dirty(~Thread_dead, Thread_ready)` on its home CPU, which
  `Thread_object::ex_regs` does to resurrect a thread
  (`thread_object.cpp:651`); `Context::activate` (`context.cpp:1057`)
  only sets `Thread_ready`. `Thread::bind` (`thread.cpp:304`) takes a
  counted reference on the task, which the thread holds until
  `Thread::unbind` (`thread.cpp:334`) points the thread at the kernel
  task (`thread.cpp:348`) and drops it. `Thread::do_kill`
  (`thread.cpp:544`) waits out a transfer the thread is held in, drains
  its senders, calls `unbind()` and only then marks the thread
  `Thread_dead` (`thread.cpp:620`); it runs only on the thread's home
  CPU, as a continuation at the common return path, and
  `handle_kill_helper` (`thread.cpp:523`) drops the dying thread's own
  reference from the kernel's context after its last switch.
* *Helping is a lock's.* `Switch_lock::lock` (`switch_lock.cpp:184`)
  runs a preempted lock holder on the waiter's CPU through
  `Context::switch_exec_helping` (`context.cpp:1245`), which refuses a
  holder whose ready bits are clear and otherwise runs the holder's
  context on the helper's CPU; the holder's home CPU retries it at every
  preemption point until the help ends (`Context::schedule`,
  `context.cpp:895`). A thread helped on a foreign CPU must not write
  its own state word there, which Fiasco's state writers assert
  (`check_for_current_cpu`, `context.cpp:743`).
* *Time is a 1 ms tick.* `Thread::handle_timer_interrupt`
  (`thread.cpp:465`) charges `Config::scheduler_granularity()` to the
  running context, runs the CPU's timeouts and schedules; the slice
  timeout rotates the current scheduling context to the end of its level
  (`Ready_queue_fp::requeue`, `timeslice_timeout.cpp:44`), which is the
  round robin within a level. Priorities are 0 to 255 per
  `Sched_context`, the ready queue a list per priority with a bitmap of
  non-empty levels (`ready_queue_fp.cpp:103`); every other insertion
  goes through `ready_enqueue`, which puts the thread at the head of its
  level (`enqueue(sc, true)`, `sched_context.cpp:23`, and
  `ready_queue_fp.cpp:125`): a woken thread (`deblock`,
  `sched_context.cpp:146`), a preempted one and one whose priority
  `Thread::set_sched_params` changes (`thread.cpp:710`) alike.
* *Three inherited sleeps.* `do_receive_wait` (`thread-ipc.cpp:434`),
  `do_send_wait` (`thread-ipc.cpp:1348`) and `Ipc_gate::block`
  (`ipc_gate.cpp:400`), the wait of a sender at a gate bound to no
  thread, each clear `Thread_ready` and call `schedule()`.
* *The IRQ shortcut is off* in the fork (`Config::Irq_shortcut` zero,
  [design-stopgap.md](design-stopgap.md#ipc-gates-and-where-transfer-fits)):
  every wake out of a wait returns through the C++ frames of the call
  the thread is in and leaves through the common return path
  (`.Lret_from_exception`, `arm/64/ivt.S:151`), as does a thread's first
  entry (`__return_from_user_invoke`). A kill continuation therefore
  runs after the call's frame has returned, on a disposable stack.

## Requirements

1. **Exactly one exit record, after every thread is dead.** A stopped
   space's exit record is posted once, when no thread of the space is
   alive: none in user mode, none inside a call, none asleep in a wait,
   none that could still be started (K18, M1 exit criterion). When
   `erx_space_stop` returns, the record has been posted.
2. **No thread of a stopped space returns to user mode or sleeps
   again.** Its current call finishes, a wait it is in ends at once, and
   it dies at its return to user mode; nothing it or any other party does
   can keep it from dying or make it sleep (K18, K26).
3. **A stop never waits on another thread's turn.** Every request the
   stop makes of another CPU runs at that CPU's next interrupt, whatever
   thread runs there and at whatever urgency, every kernel-internal wait
   of a finishing thread is ended by kernel execution alone, and every
   stopper's own walk posts every kill its tree still lacks, so no stop
   relies on another stopper's thread running again.
4. **Finishing work is never held back by user threads or grants, and is
   paid for.** A finishing thread runs on its own CPU at a fixed priority
   above every user urgency, outside every quota, so no thread of any
   domain and no grant can hold an exit record back; its time is added,
   for the accounting alone, to the `finishing_ns` of the thread's own
   group path, kept in the groups' per-CPU records, as the kernel design
   charges it, in C1 as in C0
   ([Charging and quota](design-scheduler.md#charging-and-quota)). The
   fork bounds no further what finishing takes from a CPU's user
   threads: that is erXos's kernel's finishing share, and on the fork a
   recorded residual (**Risks and open questions**).
5. **No lost wakeup, and the executor rule.** `erx_park` and every wake
   of an executor follow [Park and wake](design-scheduler.md#park-and-wake)
   exactly (S2); an executor is refused every other wait of its own
   asking (S3), and a stop or a fault holds it at its boundary like any
   thread; an executor of a stopped space is passed over and dies.
6. **Ceilings hold while serving.** A server runs at its resolved
   urgency, never above its path's ceiling, from its next scheduling
   decision (S5); every tick is charged to the group of the thread whose
   scheduling context the CPU runs (S6).
7. **Decisions are pure.** The stop state, the wait outcome, the return
   check, the park protocol and the charge step are C17 functions with
   exhaustive host models; the glue applies their actions and reads no
   policy of its own.
8. **M5 fits without reshaping.** Sub-space trees (K27), the vCPU return
   and capability transfer at a rendezvous add events and rows to the
   same cores and the same request, and change no mechanism here. Pauses
   and copies of spaces are erXos's kernel's alone: `erx_space_pause`
   fails with `ERX_ENOTSUP` on the fork, and the return check's hold row
   never fires there ([the scope
   table](design-kernel.md#the-current-implementation-the-modified-fiasco)).
9. **No unbounded masked loop.** Every walk is in parts of at most
   `ERX_STOP_PART` (64) threads with a preemption point between parts,
   every entry that drains request queues, the request interrupt from
   its first instruction to its last and a pass in thread context, runs
   at most `ERX_REQUEST_BATCH` (32) steps, contexts visited and handlers
   run, before it yields, whatever contexts and queues they come from,
   and no stretch with interrupts masked grows with a space's thread
   count or runs for as long as other CPUs keep sending requests or
   wakes (K13). A masked loop that other CPUs can keep fed would stop
   its CPU's tick, and with it every timeout and the watchdog's pet, so
   this is a correctness rule on the fork, not a latency bound.
10. **No new allocation.** Every record this binding needs is a field of
    a thread, space, group or per-CPU record that the C17 allocation
    funnel already charges or the kernel owns from boot
    ([design-stopgap.md](design-stopgap.md#kernel-memory-and-the-root-budget)).
11. **What a stop or a wait leaves linked is owned.** A delivery keeps
    the object whose record it is until it is taken or withdrawn; a
    waiter touches the list it slept on only while it is still on it; a
    dying thread keeps every group of its own path, which its finishing
    is charged to, until its last switch; and every wait of the funnel ends
    at the waiter's own kill, so no stop waits on a death that waits on
    it.
12. **No continuation outlives its object, and no drain outlives its
    cohort.** A thread woken from a wait reaches the object it waited on
    only through a fresh capability lookup or while it is still linked
    to it: a sender woken at a gate bound to no thread starts its send
    over from its capability. A dying thread closes its request queue
    before it drains it, so the drain is of a finite cohort, in parts.

## Overview

One construction carries the stop, and the other two parts follow its
shape.

**The run word counts live threads.** Each space has one 64-bit word,
its **run word**, holding the space's run state, `LIVE`, `STOPPED` or
`EXITED`, and its **live count**: the number of its threads that have
been created and have not yet died. The word is written only under the
space's lock, by one pure function, `erx_stop_step`, and read anywhere
with one atomic load. A thread enters the count when it is created in
the space and leaves it at its **death edge**, the step of its teardown
that takes it off the space's thread list, before Fiasco's `unbind()`
detaches it; the reference `Thread::bind` took keeps the space through
that edge. The stopgap has no pauses and no copies of spaces, so "no
thread of the space can act" is exactly "no thread of the space is
alive", and the live count is the whole of the decision: the step that
takes it to zero while the word is `STOPPED` claims the exit, posts the
record, publishes `EXITED` and wakes every stopper waiting for it.
Nothing counts kernel entries, sleeps or wakes, so no wake site, no
sleep site and no state writer of Fiasco's takes part.

**One request per thread.** Everything that must happen to a thread on
its home CPU, killing it, ending its wait, stopping or starting it,
handing over its executor slot, reading its registers, is one request,
`Erx::thread_request`, carried by Fiasco's eager cross-CPU request so
that it runs at the target CPU's next interrupt whatever runs there, and
answered to the requester. Every entry that drains the queues that
carry requests has one budget for the whole entry, and a dying thread
closes its own queue before it drains it, so no drain grows with what
other CPUs send. Every stop walks the space's thread list and sends one
kill to each thread that has no answered kill yet, whether or not an
earlier stop walked before it; every death, a stop's, a deletion's, a
group destroy's or `erx_thread_exit`'s, is made by that kill, which
marks the thread dying, takes its dying reference and raises it to the
finishing priority, in one place.

**The wait funnel.** Every wait a request must be able to end sleeps
through one function, `Erx::wait_sleep`, whose decision is the C17
`erx_wait_step`. A wait is one of three classes: a **caller wait** the
thread asked for (an IPC wait, a umtx wait, a park), refused once the
thread's space has stopped or a kill or a `CONTROL` stop is posted to
it; a **boundary wait** at the thread's return to user mode (a `CONTROL`
stop, a fault record waiting at the gate, a stopped space's thread
waiting for its kill), ended only by a kill or `erx_thread_start`; and
a **stopper's wait** for another space's `EXITED`, refused once the
stopper's own space has stopped or a kill is posted to it. Every wait
of the funnel ends at the waiter's kill: that is what lets two spaces
stop each other. The only sleeps outside the funnel are three of
Fiasco's own that kernel execution alone ends within a bound, with no
user thread's turn needed: the wait for a request's answer, a dying
thread's wait for the transfer it is held in, and the grace-period
wait. Whoever ends
a wait writes its outcome through the one pure completion function,
`erx_wait_complete` (K33), applied by one compare-and-swap on the
record's outcome so that the first ender wins on any CPU, and makes
the thread ready; the thread reads the outcome on resume, touches
the list it slept on only while it is still on it, and reaches the
object it waited on afterwards only through a fresh lookup: a sender
woken at a gate bound to no thread starts its send over from its
capability, as the kernel design has it. So the stop needs no
list of wait kinds to cancel, a thread of a stopped space cannot
sleep by construction, and no woken thread holds a pointer that a
deletion could have outrun.

**Finishing at a fixed priority.** A thread marked dying runs at the
**finishing priority**, one above the highest priority any user urgency
maps to, from the kill on until it dies, on its own CPU and outside
every quota. No thread of any domain can run above it, so a spinner
cannot hold a stop, a later stopper at a higher urgency changes nothing,
and no finishing thread is ever refreshed. A dying thread's time is
added, for the accounting alone, to the `finishing_ns` of its own group
path, in the per-CPU records it holds until its last switch; no grant
throttles it, in C1 as in C0. The fork has no finishing share: what
finishing takes from a CPU is bounded by the stopped threads' remaining
work, which their budgets paid for, and a stream of kills is a recorded
residual.

**No direct switch.** A send makes the receiver ready and switches to
nothing; the scheduler picks the receiver at the sender's next decision,
which for a call is its reply wait, with the receiver's own scheduling
context. The server therefore runs at its own priority and on its own
group's grant from its first instruction, and S5 and S6 hold with no
special case. Gate G1's `ipc` benchmark decides whether an early pick is
worth adding later.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **ST1.** A space's exit record is posted exactly once, after every thread of the space has died, and before `EXITED` is published | the run word moves `LIVE` to `STOPPED` once, under the space's lock; from then on no thread is created or started, so the live count only falls; the step that takes it to zero, or the stop that finds it at zero, returns `CLAIM` exactly once, and the claimant posts the record, then publishes `EXITED`, then wakes the waiters ([Stop and exit](#stop-and-exit)) | a store to the run word outside the space's lock; a death edge applied after `unbind()`, to the kernel task; a publication before the post | the stop core's exhaustive host model; the chokepoint check on the run word's one store function; the K18 conformance cases with a seeded edge after `unbind()`, which never posts and fails the harness's deadline, and a seeded publication before the post, which the model rejects |
| **ST2.** A thread of a stopped space never sleeps in a caller wait again and never returns to user mode | `erx_wait_step` reads the run word under the CPU lock on the thread's home CPU and refuses a caller wait while the word is not `LIVE`; the kill request runs on that CPU under the same lock, so a wait begun before it is ended by it and none begins after it; every return to user mode passes `erx_return_check`, whose first two rows are death and the boundary wait ([design-stopgap.md](design-stopgap.md#ipc-gates-and-where-transfer-fits)) | a sleep outside the funnel; a return path that skips the check | the wait funnel's exhaustive host model; the stopgap's return-path check; a seeded return check that resumes a stopped thread, which the K18 case detects by a progress counter |
| **ST3.** Every wait a kill must end has a wait record, and the kill finds it | a thread sleeps with its ready bits clear only in `Erx::wait_sleep`, which writes the record, and in the three waits of Fiasco's own that kernel execution alone ends within a bound, with no user thread's turn needed: the answer wait of `Context::drq`, ended at the target CPU's next request interrupt; the dying thread's wait for its transfer in `do_kill`, ended by the sender's one bounded request; and the grace-period wait, ended once every active CPU has reported its quiescent states at its ticks and its CPU's record steps reach the item ([Death and the death edge](#stop-and-exit)); `Thread::halt`, the priority-inheritance wait and `Ipc_gate::block`'s own sleep are not built | a Fiasco-internal sleep added outside that list | the source check that a clearing of the ready bits followed by `schedule()` occurs only at the listed sites, with a seeded sleep elsewhere failing it; a debug assertion in the request handler that a sleeping target outside those sites has a wait record |
| **ST4.** No wakeup of an executor is lost (S2 on the fork) | the park core compares and lists under the group's park lock, a Fiasco spin lock taken under the CPU lock; the parker clears its ready bit under the CPU lock before the lock is dropped, and every wake completes the record under the park lock and sets the ready bit through the home CPU's serialized state writers, so a wake after the parker's listing always finds a sleeper to wake ([Park and wake](#park-and-wake)) | a compare outside the lock; a wake that writes thread state from another CPU directly | the park protocol's exhaustive host model (S2); the park lock under ThreadSanitizer; a seeded compare outside the lock, which the model finds as a lost wakeup |
| **ST5.** A thread runs at its resolved urgency and never above its path's ceiling, a finishing thread at the finishing priority, and every tick is charged to the group of the thread owning the CPU's current scheduling context | a thread's Fiasco priority is `erx_sched_resolve`'s result plus one, refreshed by every call that changes a base or a grant before that call returns, or the finishing priority once it is dying; the only switch that does not set the CPU's scheduling context is a lock holder's help; the tick's charge is one function reading the current scheduling context ([Server urgency and charging](#server-urgency-and-charging)) | a switch of execution context alone outside helping; a second charge site; a priority written outside the refresh | the S5 conformance case with a third thread at 25; the source check that `Not_Helping` switches happen only in `schedule_switch_to_locked`; the charge function's chokepoint check; a seeded donating switch in `activate_ipc_partner`, which lets the server run ahead of the thread at 25 and fails |
| **ST6.** No request of this binding, and no kernel-internal wait of a finishing thread, waits for another thread's turn on a CPU | every cross-CPU request this binding sends is eager, taken at the target CPU's next interrupt; the IPC glue's cross-CPU handshake, reply and abort are eager too; every entry that drains request queues runs a bounded number of steps and continues itself, so a request is run within a bounded number of interrupts of its CPU; the answer makes the requester runnable at its own CPU's next interrupt, at its own priority | a request sent with `eager = false`; a `Drq::Wait` whose handler needs the target to be scheduled; a lock held across a `Drq::Wait` | a source check that every `drq` call in the glue and in the IPC path passes `eager = true`; the flood case and the starved-receiver case of the conformance suite |
| **ST7.** Every wait of the funnel ends at the waiter's kill, so no death waits on a death | the kill request kicks whatever funnel wait it finds its target in, a stopper's wait included, and the funnel refuses every wait to a thread with a kill posted; the three sleeps outside the funnel end within a bound by kernel execution alone and need no thread's turn; a stopped space's record is posted by its own last death edge, which needs nothing of any stopper; so in a cycle of stops each stopper's wait ends at its own kill, each death takes its own space's count down, and every space of the cycle exits; erXos's kernel has the same rule, a stopper's call ending at its own kill once its walk is done ([Threads and faults](design-kernel.md#threads-and-faults)) | a wait the kill does not end; a post that waits for a stopper; a stopper's wait that outlives its walk's kill | the mutual-stop host model, two spaces each stopping the other, over every interleaving; the QEMU case of two domains stopping each other on four CPUs; a seeded stopper's wait the kill leaves alone, which the model finds as a trace where both words stay `STOPPED` forever and the QEMU case as a missed deadline |
| **ST8.** Nothing a stop or a wait leaves linked outlives what it is linked to or into | a delivery, an exit record's or an IRQ object's, holds `erx_object_ref` on its object from its post until the one step that takes or withdraws it, through every queue it sits in; a waiter's record names its list, the list's owner clears that name when it detaches the waiter at its own teardown, and the waiter reads it under the CPU lock before it touches the list, so it reaches the owner only while the owner's teardown has not run, which is before the owner's grace period and its free; a thread holds the counted references on every group of its own path from its creation until its last switch, after which `handle_kill_helper` drops them with its dying reference, so the path its finishing is charged to outlives every charge; the counts are kept in the groups' per-CPU records, and a group's teardown detaches its shared areas before it releases them, so a charge after the destroy publishes nothing (**A group's end**) | a delivery's reference dropped when its handler returns rather than when it is taken; a resume that unlinks without the membership check; a member's group references dropped at its teardown, before the grace-period wait and the last switch that are still charged; a charge or a status mirror stored into a group's shared area after the group's teardown has released it | the hosted suite under ASan: a space's record kept under a queued exit record until the record is taken, and a sender killed as its gate is destroyed, each with the seeded failure of the middle column, which ASan reports as a use after free; the group references and the released status area by the deletion case of [Verification and testing](design-scheduler.md#verification-and-testing), whose seeded early drop and seeded publish after the destroy fail it |
| **ST9.** A thread woken from a wait reaches the object it waited on only through a fresh lookup, or while it is still linked to it | a waiter's frames carry nothing of the object but its wait record; on resume the thread unlinks itself after the membership check and then either returns a status or, for a sender woken at a gate bound to no thread, returns to the dispatch, which runs the call again from `erx_cap_lookup` ([The wait funnel](#the-wait-funnel)); so the gate a sender was blocked at is never read after the sleep through a pointer the sleep outran, and Fiasco's unblocked queue, which kept a woken sender linked for that read (`ipc_gate.cpp:154`), is not built | a glue that reads the gate's binding after its block, as `Ipc_gate::invoke` does at `ipc_gate.cpp:489`; a wake that returns the thread to a frame holding an object pointer | the IPC core's host model of a gate send over every outcome with the gate deleted between the wake and the resume; the hosted ASan case of a sender woken by a binding as its gate is destroyed and reaped; the source check that `Ipc_gate::invoke` reads the binding once, before its block, and that `_unblocked_q` and `abort_all_unblocked` are absent from the image; a seeded second read after the block, which ASan reports as a use after free and the source check refuses |
| **ST10.** No entry that drains request queues grows with what other CPUs send, and a dying thread's drain is finite | the request interrupt's whole entry and a pass in thread context each run at most `ERX_REQUEST_BATCH` steps on one counter, contexts visited, handlers run and the current thread's own queue included, and requeue what is left before they return ([Bounded request queues](#stop-and-exit)); a dying thread writes its dead mark under its request queue's lock before it drains, so what it drains is the cohort accepted before the mark, in parts with a preemption point between them ([Death and the death edge](#stop-and-exit)) | a context visit, a remote state change or the interrupt's final `handle_drq` left outside the counter; a drain that closes the queue only once it finds it empty | the flood case's debug counter of the steps of one entry, with a wake flood of thousands of waiters homed on the flooded CPU; the racing-death case's counter of the drain's parts and its longest masked stretch under a flood of requests to the dying thread; the seeded failures of each: handlers alone counted, which the wake flood takes over the bound, and the mark written after the drain, whose part count grows for as long as the flood lasts |
| **ST11.** When any stop walk of a space returns, every thread of the space has had a kill answered, whatever became of other stoppers | every `STOP` that finds the word `STOPPED` walks, as a first stop does; a walk marks a thread `stop_visited` only after its kill has been answered, and moves it to the tail of `att_threads` in the same critical section, so the threads whose kill is still unanswered are a prefix of the list and every walk takes its parts from the front until the front is marked ([Stop and exit](#stop-and-exit)) | a `STOP` from `STOPPED` that only waits; a mark set before the kill is sent, which a walker that stops running between the two leaves on a thread no kill reached | the stop core's host model with a first stopper that stops for good after its mark, after any part's sends and before any part's marks, and a second stopper that must receive the record; a seeded `WAIT` for `STOP` from `STOPPED` and a seeded mark before the send, each leaving the second stopper asleep in a trace that the model reports |

## Data model

**The run word.** Internal to the kernel and the C17 core:

```c
typedef uint64_t erx_run_word_t;	/* bits 63..62: state; 61..31: children; 30..0: live */

typedef enum erx_run_state {
	ERX_RUN_LIVE,			/* threads may be created, started and may wait */
	ERX_RUN_STOPPED,		/* stopped; the exit record not yet published */
	ERX_RUN_EXITED			/* every thread dead; the record posted and published */
} erx_run_state_t;
```

`live` is the number of threads created in the space that have not
reached their death edge. `children` is the number of child spaces whose
exit records are still awaited, which K27 fills in M5 and which is zero
throughout M1; the claim needs both at zero. Thirty-one bits each exceed
any thread or space count a budget can pay for. The word is written only
under the space's lock, through one store function, and read with one
atomic load by the return check, the wait funnel, the park core and
`erx_object_info`, which reports the state and the count.

**A thread's scheduling fields**, added to `Thread_object` and
allocated with it:

```c
typedef enum erx_wait_kind {
	ERX_WAIT_NONE,
	ERX_WAIT_IPC_SEND, ERX_WAIT_IPC_RECV, ERX_WAIT_UMTX, ERX_WAIT_PARK,	/* caller waits */
	ERX_WAIT_STOPPED, ERX_WAIT_FAULTED,				/* boundary waits */
	ERX_WAIT_STOP							/* a stopper's wait, for EXITED */
} erx_wait_kind_t;

typedef enum erx_wait_outcome {
	ERX_WAIT_PENDING, ERX_WAIT_WOKEN, ERX_WAIT_CANCELLED,
	ERX_WAIT_TIMED_OUT,
	ERX_WAIT_ABORTED,			/* the partner of an IPC wait died: ERX_EDEAD */
	ERX_WAIT_STALE				/* the owner of the list the waiter was on was
						 * destroyed: ERX_ESTALE, as the kernel design
						 * answers a waiter whose object is deleted */
} erx_wait_outcome_t;

typedef struct erx_wait {
	uint8_t		kind;		/* erx_wait_kind_t; its class is a function of it */
	uint8_t		outcome;	/* erx_wait_outcome_t; written once, by the completion's
					 * compare-and-swap, from any CPU */
	uint8_t		asleep;		/* set between the funnel's sleep and its resume */
	uint8_t		armed;		/* the deadline is in the CPU's timeout queue */
	uint64_t	deadline;	/* absolute, monotonic; 0: none */
	void		*queue;		/* the head of the list the waiter is linked on, of the kind's
					 * own list type, or NULL; written only under that list's
					 * lock, by the listing and by the unlink */
} erx_wait_t;

typedef struct erx_thread_sched {
	erx_wait_t	wait;		/* the one wait record */
	uint32_t	flags;		/* ERX_THREAD_KILL | _DYING | _CONTROL_STOP; home CPU only */
	uint8_t		stop_visited;	/* a walk's kill to it was answered; under the space's lock */
	erx_dlist_t	stop_link;	/* on att_stoppers of the space it waits for */
} erx_thread_sched_t;
```

The thread's deadline is one `Erx_wait_timeout`, a Fiasco `Timeout`
embedded in the thread record, set and reset only on the thread's home
CPU. `flags`, `kind`, `asleep` and `armed` are written only on the home
CPU, by the thread and the request handler; `outcome` is written once
per wait, by the first ender's compare-and-swap, on whatever CPU that
ender runs; `queue` is written only under the lock of the list it
names, by the listing and by whoever unlinks the waiter (**The wait
funnel** below). For the IPC kinds `queue` is Fiasco's `Sender::_wq`,
which the fork keeps as that one field. `stop_visited` is written only
under the space's lock, by a stop walk once the thread's kill has been
answered, together with the thread's move to the tail of `att_threads`,
and cleared by nothing: a space stops once.

**A space's stop fields**, in the task record beside the run word.
Under the space's lock: the first stop's status and the stopper's object
id, written before the word moves to `STOPPED`, and the thread list
`att_threads`, joined at creation and left at the death edge. Under the
**stoppers lock**, a leaf spin lock of the task record taken with no
other lock held: `att_stoppers`, the stoppers waiting for `EXITED`. And
the exit record's sender, `Exit_sender`, a kernel sender in the shape of
Fiasco's `Irq_sender` whose message is the space's `erx_fault_t` of kind
`exit`, filled by the claimant alone and holding `erx_object_ref` on the
space while it is posted.

**A group's park record** is the scheduler design's `struct erx_group`
([Data model](design-scheduler.md#data-model)): the park lock, the
parked FIFO, the group epoch, the slots with their epochs, the ready list
and the two shared areas. On the fork the park lock is a Fiasco
`Spin_lock` taken under the CPU lock, the FIFO's links live in the
executors' thread records, the ready list's links in the IRQ objects, and
the shared areas are kernel-user memory of the group object. The
group's counters, `finishing_ns` among them, are in its per-CPU records,
as the scheduler design keeps them, and the status area only mirrors
them ([Data model](design-scheduler.md#data-model)).

**The cores.** `kernel/core/stop.c` holds `erx_stop_step`;
`kernel/core/wait.c` holds `erx_wait_step`, `erx_wait_complete` and
`erx_wait_class`; `kernel/core/return.c` holds `erx_return_check`;
`kernel/core/park.c` holds `erx_park_step`; `kernel/sched/sched.c` holds
`erx_sched_resolve` and `erx_sched_charge`, with the draw, throttle and
pick that C1 and erXos's kernel use, and the finishing share's step,
which erXos's kernel alone calls. Each is
a pure function of its arguments, builds for the host, and is the one
place its decision is made ([Interfaces](#interfaces)).

## Algorithms and behavior

### Stop and exit

**The step function.** `erx_stop_step(word, event)` returns the next
word and an action. The glue applies it under the space's lock and
performs the action; no other code writes the word.

| Event | From | To | Action |
| --- | --- | --- | --- |
| `CREATE` | `LIVE`, live `n` | live `n + 1` | `ADMITTED`: the thread joins `att_threads` |
| `START` | `LIVE` | unchanged | `ADMITTED` |
| `CREATE`, `START` | `STOPPED` or `EXITED` | unchanged | `REFUSE`: `ERX_EDEAD` |
| `STOP` | `LIVE`, `n > 0` | `STOPPED`, `n` | `WALK`: the caller kills every thread, then waits |
| `STOP` | `LIVE`, `n = 0`, `children = 0` | `STOPPED`, `0` | `CLAIM`: the caller posts and publishes |
| `STOP` | `STOPPED` | unchanged | `WALK`: the caller kills every thread no walk has killed, then waits |
| `STOP` | `EXITED` | unchanged | `DONE`: the record has been posted |
| `DEATH` | `LIVE`, `n > 1` | `n - 1` | none |
| `DEATH` | `LIVE`, `n = 1` | `STOPPED`, `0` | `CLAIM`: the last thread's exit stops the space |
| `DEATH` | `STOPPED`, `n > 1`, or `children > 0` | `n - 1` | none |
| `DEATH` | `STOPPED`, `n = 1`, `children = 0` | `STOPPED`, `0` | `CLAIM` |
| `PUBLISH` | `STOPPED`, `0` | `EXITED`, `0` | `WAKE`: every waiter on `att_stoppers` |
| `CHILD_PEND`, `CHILD_DONE` | any | `children +/- 1`, with the `CLAIM` rule above | M5 |

A `STOP` from `LIVE` records the status and the stopper's object id
before the step is applied, so whoever reads them after seeing `STOPPED`
reads the first stop's; a `DEATH` from `LIVE, 1` records status 0 for a
death by `erx_thread_exit` and `ERX_EXIT_NOTHREAD` for any other, the
dying thread as the stopper. `CLAIM` is returned by exactly one step in
the word's history, since the count is decremented once per thread and
`STOPPED, 0` is left only by `PUBLISH`; the claimant is the one poster
of the record. Between `CLAIM` and `PUBLISH` the word reads `STOPPED, 0`:
the record is being posted, a stopper arriving then waits, and a creation
is refused.

**The request.** `Erx::thread_request(t, req)` is the one way anything
acts on a thread's scheduling state from outside that thread. `req`
carries flags, `ERX_THREAD_KILL`, `CONTROL_STOP`, `CONTROL_START`,
`START`, `HANDOVER`, `READ` or `WRITE`, and their arguments: for a
handover, the new executor; for a register access, the buffer; a kill
carries none. Its handler runs on `t`'s
home CPU under the CPU lock, in the eager cross-CPU request's handler
when the caller is on another CPU (`Context::drq` with `Drq::Wait` and
`eager = true`, the request's structure the caller's own `_drq`) and at
once when the caller is on `t`'s CPU; the caller holds `erx_object_ref`
on `t` across it and no lock of any kind
([design-stopgap.md](design-stopgap.md#capabilities-in-fiascos-object-space)).
The handler:

1. **Kill.** If `t` is not yet dying: sets `ERX_THREAD_DYING`, takes the
   dying reference, and sets `t`'s priority to the finishing priority by
   the ready queue's dequeue, `set_prio` and enqueue, as
   `Thread::set_sched_params` does on the home CPU, a thread waiting on
   a throttled list in C1 taken off it and enqueued the same way; its
   slice is left as it was. From then on the tick charges `t`'s time to
   the `finishing_ns` of its own path, which it holds as a member, for
   the accounting alone (**Finishing priority and charging**). If `t` is
   dying already, by any earlier kill, all of that stays as the first
   kill set it. Sets
   `ERX_THREAD_KILL`. If `t` has never started, starts it with the
   resurrect write of `Thread_object::ex_regs`,
   `state_change_dirty(~Thread_dead, Thread_ready)` with `deblock`, so
   that its first entry, through `__return_from_user_invoke` and the
   common return path, is its death.
2. **Control.** `CONTROL_STOP` sets its flag; `CONTROL_START` clears it;
   `START`, after `erx_thread_start`'s `ADMIT` under the space's lock,
   does the resurrect write.
3. **End the wait.** If `t` sleeps in a wait this request's flag ends,
   any wait of the funnel under `KILL`, a caller wait under
   `CONTROL_STOP`, a boundary wait under `CONTROL_START` or `START`:
   completes its record with `KICK` by the completion's
   compare-and-swap, resets the armed deadline, and sets
   `Thread_cancel | Thread_ready`, so `t` resumes inside its wait and
   the wait returns; the kick unlinks nothing, since `t` unlinks itself
   on resume (**Resume** below). A thread in one of Fiasco's three
   internal waits is left to it: that wait ends within a bound, and `t`
   reads its flags after it. If `t` is running on this CPU, the
   interrupt that carried the request has already brought it into the
   kernel; if it is running inside a call elsewhere in this CPU's queue,
   nothing: it reaches the return check by itself.
4. **Handover, read, write.** As the park binding and K14 state below.
5. Answers the request. The requester sleeps meanwhile with
   `Thread_drq_wait` set, holding nothing but its reference on `t`; the
   answer makes it runnable at its own CPU's next interrupt and is
   applied when it next runs, at its own priority.

So a request never depends on `t`'s priority or on any other thread's
turn (ST6); one request per thread is enough whatever its cause, since
the return check reads the flags afresh; and the request is safe against
a migration of `t`, which Fiasco's request queue follows. A request
meets a dying target in one of two ways, decided under the target's
request queue's lock: queued before the target's **dead mark**, it is
run by the target's own drain of its closed queue (**Death and the
death edge** below); sent after it, it is refused there and answered
`ERX_EDEAD` on the requester's own CPU, since `do_kill` writes the mark
under that lock before it drains, and `enqueue_drq` reads it under the
same lock. The requester's `erx_object_ref` keeps the record meanwhile,
so neither way touches freed memory, and a refused delivery stays its
sender's, who resolves its object's binding again.

**Bounded request queues.** Both inherited loops drain until empty, and
Fiasco nests them: the request interrupt's pass over the CPU's pending
queue (`Pending_rqq::handle_requests`, `context.cpp:2160`) visits every
context queued there, applies its remote state change
(`context.cpp:2184`), migrates it, runs its eager queue inside its own
loop (`context.cpp:2206`) and readies it, and the interrupt then runs
the current thread's own queue once more (`handle_remote_requests_irq`,
`thread.cpp:1297` and `thread.cpp:1306`). A wake posted from another
CPU is such a visit with no handler in it, so a CPU's interrupt would
grow with the contexts other CPUs wake there as well as with the
requests they send, and a bound per loop, or on handlers alone, would
still multiply. The fork gives one **entry** one budget: the request
interrupt from its first instruction to its last, the pass over the
pending queue and the current thread's queue after it, and a pass of
`handle_drq` in thread context over a context's two queues, each run
at most `ERX_REQUEST_BATCH` **steps**, where a step is one context
visited, its state change and its migration included, or one handler
run, from whatever queue; one counter is handed to every loop the entry
enters, each step decrements it, and at zero every loop stops. With
work left, the interrupt's entry puts a context whose queues are not
yet empty back at the tail of the pending queue, under that queue's
lock, leaves the contexts it has not reached queued, readies what it
has made ready, and sends the request interrupt to its own CPU again
before it returns, so the timer and the devices are served in between
and the next entry resumes the work, the current thread's queue
included, with a fresh budget; in thread context, `handle_drq` leaves
`Thread_drq_ready` set and reports a reschedule, so the context is run
again after a preemption point. Every request is answered by the step
that runs it, as before. A thread has one request record and waits for
its answer, so a space's outstanding requests number at most its
threads; a context is on the pending queue at most once however many
wakes are posted to it, since `pending_rqq_enqueue` queues a context
that is already queued no second time (`context.cpp:2299`). The budget
keeps every entry finite however fast other CPUs send; how many entries
a CPU takes per tick follows the senders' rate, which the fork does not
bound (**Risks and open questions**). The tick charges an entry's work
to whoever runs on that CPU, a stopgap inaccuracy.

**`erx_space_stop(space, status)`**, with `STOP`:

1. Refuses a status of the kernel's own (`ERX_EXIT_PARENT`,
   `ERX_EXIT_RELEASED`, `ERX_EXIT_NOTHREAD`) with `ERX_EINVAL`.
2. Under the space's lock, records the status and its own object id when
   the word is `LIVE` and applies `STOP`, then releases the lock. On
   `CLAIM`, goes to step 5; on `DONE`, returns `ERX_OK`.
3. On `WALK`, from `LIVE` or `STOPPED` alike, kills every thread no walk
   has killed, in parts: under the space's lock, takes up to
   `ERX_STOP_PART` threads from the front of `att_threads` whose
   `stop_visited` is clear, takes `erx_object_ref` on each, and releases
   the lock; sends each its kill request and waits for the answers;
   under the space's lock again, marks each of them that is still on the
   list and unmarked and moves it to the tail; drops the references;
   passes a preemption point; repeats until the front of the list is
   marked or the list is empty. A thread is marked only once its kill
   has been answered, so a walker that stops running anywhere, its group
   throttled at a zero quota or its thread never scheduled again, leaves
   unmarked every thread whose kill it did not see answered, and the next
   stop's walk sends those kills itself; two walks may kill one thread,
   and the second kill changes nothing. The list only shrinks once the
   word is `STOPPED`, since `CREATE` is refused, and each pass marks every
   thread it took or finds it marked by another walk, so the walk ends.
   No lock is held across a request, so a thread waiting for the space's
   lock on another CPU can help the stopper only while the stopper runs,
   never while it waits for an answer. Then step 4.
4. Links itself on `att_stoppers` under the stoppers lock and, still
   holding it, loads the run word: `EXITED` already, it unlinks itself
   and returns `ERX_OK`; otherwise it releases the lock and sleeps in
   `ERX_WAIT_STOP`, a stopper's wait. The funnel refuses that wait with
   `ERX_EINTR` when the caller's own space is not `LIVE`, which covers a
   stop of its own space, or when a kill is posted to the caller, and a
   kill that arrives later kicks it. Refused or kicked, the caller
   unlinks itself unless the drain already has (**Resume** below) and
   returns `ERX_EINTR`, which no user code ever reads: a thread with a
   kill posted dies at its return check, and a thread of a stopped
   space holds there until its kill. Woken, it returns `ERX_OK`.
5. On `CLAIM`, posts and publishes (**Posting and publishing** below)
   and returns `ERX_OK`.

After step 3 of any walk every thread of the space has had a kill
answered, whatever became of other stoppers (ST11): a thread
asleep in any wait of the funnel was woken by it; a thread running,
preempted, in a transfer or in one of Fiasco's internal waits reaches
its return check with the flag set; a thread in user mode was brought into the
kernel by the interrupt that carried it; a thread never started was
started to die; no thread can be created or started, and none can begin
a caller wait (ST2). Each therefore reaches its death edge, and the edge
that takes the count to zero claims the exit (ST1).

**The return check.** `erx_return_check(run_state, flags, holds,
upcall)` is a pure function called from the common return path on the
thread's home CPU with interrupts masked, after the call's frames have
returned and before the user registers are restored, for every return: a
call's end, a wake, a first entry, an interrupt taken in user mode. It
loads the run word and the flags once and decides by the first row that
holds:

| Row | Condition | Decision |
| --- | --- | --- |
| 1 | `flags & ERX_THREAD_KILL` | `DIE` |
| 2 | `flags & ERX_THREAD_CONTROL_STOP`, or `run_state != LIVE` | `STOP`: sleep in `ERX_WAIT_STOPPED`, decide again on resume |
| 3 | the space is held | `HOLD`: erXos's kernel's pauses and copies; the fork's hold counts are always zero |
| 4 | `erx_vcpu_step` finds a delivery it can take | `UPCALL` (M5) |
| 5 | otherwise | `RESUME` |

Row 2's second condition closes the window between a stop and the
arrival of the thread's kill: a thread of a stopped space that reaches
its boundary before its kill holds there, in a boundary wait the kill
ends, so no thread of a stopped space returns to user mode from the
moment the word changes, and every death is made by a kill request, with
its dying reference and its priority set in one place.
`DIE` calls `Thread::do_kill`, which never returns, on the disposable
stack the common return path provides, where Fiasco's own
`leave_and_kill_myself` continuation runs.

**Death and the death edge.** The erXos part of the teardown runs
inside `do_kill`, after its wait for a transfer the thread is held in
and before `unbind()`, in this order. The thread withdraws a fault
record still waiting at the gate and the deliveries owed to it, each fed
to `erx_irq_step` as an unbind, unbinds the gates on `att_gates` and the
IRQ objects bound to it, and leaves its group's member list, which frees
its executor slot and keeps its references on the groups of its path,
since the rest of its teardown is still charged to them. It detaches its queued senders, a bounded part at a time, as
Fiasco's sender drain does: a thread sender is unlinked, its `queue`
cleared, and completed `ABORTED` (`ERX_EDEAD`); a delivery queued as a
sender, an IRQ object's or an exit record's, is withdrawn to its
object's next binding or held at the gate, its reference still held;
and its caller's reply wait is completed `ABORTED` through a request to
the caller's home CPU, where the handler checks that the caller still
waits for this thread. A sender's insert on the thread's home CPU
refuses a thread marked dying with `ERX_EDEAD`, as it refuses a closed
one, so no sender queues after the drain. Then, under the space's lock,
it leaves `att_threads` and applies `DEATH`, its death edge; if the
step returns `CLAIM`, it releases the lock and posts and publishes.
Then it closes its request queue: under the queue's lock it writes the
dead mark, the fork's own flag in the thread's request queue, after
which `Erx::request` and `Context::drq` refuse the thread with
`ERX_EDEAD` and nothing queues at it again (**The request** above). The
sender drain above makes the thread's last waited request, if it makes
any, and nothing after the mark waits for an answer, so the mark cuts
off no answer the thread needs. What the queue holds is then a finite
cohort, and the thread drains it in parts of at most
`ERX_REQUEST_BATCH` steps with a preemption point between parts, each
part under the CPU lock: a delivery, an IRQ object's or an exit
record's, is run, and its handler decides afresh from the object's
binding, the delivery's reference going with it; a waited request is
run and answered; any other is cancelled by dropping the request's
reference on the object it names
([design-stopgap.md](design-stopgap.md#stop-and-exit-the-binding)). A
delivery that arrives after the mark is refused to its sender, who
keeps its reference and resolves the binding again, where it finds the
next binding the teardown left or holds the record at the gate or the
IRQ object. The drain is therefore bounded by the requests that were
queued when the mark was written, each from a thread that waits for
its answer or a delivery whose object holds at most one, and no flood
from other CPUs can lengthen it: a request from another CPU meets the
mark and is refused.
Only then does Fiasco's `unbind()` drop the thread's reference on the
space and point it at the kernel task, after which Fiasco's own
`Thread_dead` state bit, which nothing of this binding reads, the
grace-period wait and the last switch follow as in Fiasco; the wake of
the grace-period wait and the final request to the kernel's context
(`kernel_context_drq`, `thread.cpp:643`) go through a remote state
change and the kernel thread's queue, neither through the closed one;
`handle_kill_helper` drops the dying
reference and the references on the groups of the thread's path from
the kernel's context. The grace-period wait is ended by kernel execution
alone: `rcu_wait` retires the thread's own grace item through
`erx_grace_retire`, which stamps it with the next period and appends it
to its CPU's stamped list, the one list the reaper's puts and record
frees wait on, with `rcu_unblock` as its callback
([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages));
Fiasco's `Rcu::call` and the three lists behind it are not built. The
item is mature once the completed period count reaches its stamp, which
every active CPU's tick advances by reporting its quiescent states
(`check_quiescent_state`, `rcupdate.cpp:391`; `cpu_quiet`,
`rcupdate.cpp:379`); the CPU's ticks then run its record step, which
runs the mature items at the head of the list, at most 64 a step, in
their order, each by its callback, the thread's readying it on its own
CPU (`rcu_unblock`, `context.cpp:2501`). The step is the same whether
an item is a put, a record free or a dying thread's, so a cohort of a
thousand dying threads costs its CPU sixteen steps of 64 and never one
masked pass over the thousand, and nothing in the wait needs a user
thread's turn.
The thread's FP state is inline in
its block, so neither the kill nor the teardown moves or frees any.
After its death edge a thread touches nothing of its space: it has left
every attachment, and what remains of its teardown is its own record's.
So "every thread dead" on the fork is "every thread past its death
edge", and the count reaches zero exactly then.

**Posting and publishing.** The claimant, a dying thread in its
teardown or the stopper of a space with no live thread, holds no lock
and performs three steps in this order:

1. **Post.** Makes `erx_space_exit_post`: a second post does nothing, and a
   post that finds the deletion begun drops the record, counted, taking
   no reference. Otherwise it fills the space's `Exit_sender` with the
   record, kind `exit`, the first stop's status and stopper, takes
   `erx_object_ref` on the space for the delivery, and sends it to the
   fault gate's bound thread as an IRQ delivery is sent: resolved under
   the gate's lock, where it asks `erx_space_exit_waits`, drops the
   record, counted, with its reference, when that says false, and
   records the place, at the receiver's home CPU through `Erx::request`, the
   unwaited request, when that is another CPU, taken at once by an open
   wait or queued at the thread as a sender of `ERX_URGENCY_MAX`. The
   delivery's reference goes with the record through every queue it
   sits in, the request queue, the receiver's sender list and an
   unbound gate's `att_blocked` list, and is dropped by the one step
   that takes the record, the receive that completes the send, or
   withdraws it: a receiver that dies with the delivery queued
   withdraws it in its kill continuation to the gate's next binding or
   holds it at the gate, the reference still held, by the same placement
   under the gate's lock; the space's deletion withdraws a record it
   finds posted, under that lock, through `Erx::request` to the thread the
   place names, on a node of its own, or off `att_blocked` itself
   ([Threads and faults](design-kernel.md#threads-and-faults)); a gate destroyed
   with the record on its list, or a space whose gate is gone, drops
   the record, counted, and its reference with it; the root space,
   which has no gate, takes the kernel design's route to `erx_panic`
   with the cause K31 names for the root task's end, and ends the
   machine (K31, [design-stopgap.md](design-stopgap.md#faults-and-the-fault-of-the-root-task)).
   So a space's record stays until its exit record has been received or
   dropped, as a fault record keeps its thread, and no queue points into
   a freed space. The sender is embedded in the space record, so the
   post allocates nothing and a gate's queue holds at most one record
   per space. The same rule carries Fiasco's `Irq_sender` on the fork,
   in place of its own send reference and send-state word
   (`Irq_sender::destroy`, `finish_send`, `reject_send`, `irq.cpp`).
2. **Publish.** Under the space's lock, applies `PUBLISH`, and releases
   it.
3. **Wake.** In parts: under the stoppers lock, takes at most
   `ERX_STOP_PART` waiters off `att_stoppers`, completing each record
   with `WOKEN` by the completion's compare-and-swap and clearing its
   `queue`; a waiter another ender completed first, a kicked stopper,
   is unlinked and not counted; releases the lock; makes each woken one
   ready through `Erx::wait_wake`; passes a preemption point; repeats
   until the list is empty. No waiter wakes another, so a waiter that
   is slow to run delays no one else. From M5, the claimant then
   applies `CHILD_DONE` to the parent's run word, under the parent's
   lock.

A stopper links before it reads the word, and the claimant writes
`EXITED` before it drains, everything but the write under the stoppers
lock: a stopper whose turn at the lock comes before the drain's is on
the list when the drain runs and is woken by it, whatever it read; one
whose turn comes after the drain's reads `EXITED`, since the lock
orders the write before that read, unlinks itself and returns. No
registration can be missed, nobody sleeps past the drain, and nobody
observes `EXITED` before the record has been posted.

**Interactions.** Each state a thread of a stopped space may be in, and
what its kill does to it:

| The thread is | The kill | How it ends |
| --- | --- | --- |
| running in user mode | the interrupt brings it into the kernel | the return check, row 1 |
| inside a call, running or preempted | nothing | the call finishes its parts at the finishing priority; its next caller wait is refused with `ERX_EINTR`; the return check |
| in an IPC wait (`do_send_wait`, `do_receive_wait`, the sender's wait at an unbound gate) | `KICK`: `CANCELLED`, `Thread_cancel \| Thread_ready`; the inherited loop sees the cancel and aborts the phase: a sender unlinks itself, if it is still listed, from the receiver's list on the receiver's home CPU through Fiasco's `abort_send`, or from the gate's blocked list under the gate's lock; the call returns `ERX_EINTR` | the return check |
| a receiver held in a transfer | nothing: the transfer is one bounded step in M1 (**Transfer ownership** below), and the sender's request that ends it makes the receiver ready | the return check |
| a sender waiting for a cross-CPU answer | nothing; the answer comes at the receiver CPU's next interrupts, since the IPC glue's requests are eager (ST6) | the handshake queues it as a sender, whose wait is refused, or fails; the return check |
| in a umtx wait | `KICK`; on resume the waiter unlinks itself from the bucket's list if it is still on it, returns `ERX_EINTR` | the return check |
| in `erx_park` | `KICK`; the executor unlinks itself from the parked FIFO if it is still on it, returns `ERX_EINTR` | the return check; its slot is freed in its teardown if it still holds it |
| at its boundary: a `CONTROL` stop, a fault record at the gate, or waiting for this kill | `KICK` of the boundary wait; `erx_return_check` decides again | row 1 |
| waiting as a stopper for another space | `KICK`: `CANCELLED`; on resume the stopper unlinks itself from that space's `att_stoppers` unless the drain has, and `erx_space_stop` returns `ERX_EINTR`, which nothing reads; that space's record is posted by its own last death, which needs nothing of the stopper | the return check, row 1 |
| not yet started | started to die | its first entry reaches the return check, row 1 |
| already dying, by a deletion or a release | nothing new: the flag is already set and the first kill set the rest | row 1 |
| a worker with IRQ objects bound to it | as its wait | its teardown unbinds them, and deliveries owed go to the next binding |

A thread deleted on its own, by `erx_object_destroy`, a release or its
group's destroy, takes the same kill request; `erx_thread_exit` is the
thread's own kill of itself; every one of them is charged to the
thread's own path.
`erx_thread_stop` sends `CONTROL_STOP` and returns when the request is
answered; `erx_thread_start` on a stopped or faulted thread sends
`CONTROL_START`, and on a never-started thread applies `START` under the
space's lock and then sends the start request. `erx_thread_read` and
`erx_thread_write` run as a request too, whose handler copies the
register set only if the thread sleeps in a boundary wait and otherwise
answers `ERX_EBUSY`, so a register is never read or written on a thread
that may run (K14).

**A space's teardown.** The space's destroy, from `erx_object_destroy`,
a release or its budget's destroy, runs this binding's part first:
`STOP` with `ERX_EXIT_RELEASED` when the word is `LIVE`, the walk, and,
on `CLAIM`, the post and publication, a record whose space's deletion
has begun being dropped and counted at its gate; then the deletion walk,
which withdraws a waiting exit record and empties the capability table of
each task it reaches in bounded parts through `erx_cap_slot_clear`; then the mapping teardown of
[design-stopgap.md](design-stopgap.md#deletion). The destroy does not
wait for `EXITED`: each thread dies on its own path, the record posts at
the last death, and the space's record stays until its last reference
goes, as K26 lays down. A destroy made from the kernel's own context, a
put run by the reaper that drops a last reference, kills the same way,
since a kill names nobody.

**Finishing priority and charging.** The finishing priority,
`ERX_PRIO_FINISHING`, is one above the priority the highest urgency maps
to (`ERX_URGENCY_MAX + 2`, 65): no user thread can be at it, finishing
threads of all spaces share it under Fiasco's round robin, and the
priority refresh leaves a dying thread at it, so a later change of a
base or a grant and a later stopper change nothing. A finisher runs
whenever no other finisher of its CPU is ahead of it, whatever any
grant says: a zero quota on the stopped group cannot hold the record
back, and nothing of the stopper, neither its grant, its spent period
nor its cpuset, is read. In C0 and C1 alike the priority is the whole
of the service rule: no path admits a dying thread, so the throttle
that C1 adds never applies to one. The thread's time is charged to its
own group path for the accounting alone: the tick adds it to the
`finishing_ns` of the per-CPU record of each group on that path and to
no pool, `used_ns` or `total_ns` (**Charging** under [Server urgency and
charging](#server-urgency-and-charging)). A finisher whose own group is
destroyed, with its budget or by its parent's destroy, goes on charging
the same path: it holds every group of it until its last switch, a
group's per-CPU records are freed only with its record, after its grace
period and its last counted reference ([Ownership and
lifetime](design-scheduler.md#ownership-and-lifetime)), and the destroy
detached the group's shared areas before it released them, so the
charge publishes nothing and no store reaches a released page (**A
group's end** under [Park and wake](#park-and-wake)).

**What the fork does not bound.** A finisher delays every other thread
of its CPU for the rest of its call: the remaining parts of that call,
each within the bound the ABI file declares for the call and separated
by preemption points where interrupts are taken, their number bounded
by the records the stopped space's budgets paid for. One finishing call
is bounded so; a stream of them is not. A domain whose threads on other
CPUs create threads homed on one CPU and kill them, for as long as its
budget pays for the records, keeps that CPU's user threads from
running, the root task's petting thread among them, so a long enough
stream ends the machine through the watchdog. Among finishers no order
is promised either: `ready_enqueue` puts a thread whose priority the
kill raises at the head of its level (**What Fiasco does**), so a newly
killed thread may run before an older one, and each keeps the slice it
had. erXos's kernel bounds both, with its finishing share and its FIFO
levels ([design-scheduler.md](design-scheduler.md#pick-and-dispatch));
on the fork they are the stream-of-kills residual of **Risks and open
questions**, and M1's tests check what the fork promises instead:
every stop's record comes within the harness's deadline in the
conformance cases and the M1 demo, and the finishing time lands on the
stopped threads' own paths (**Verification and testing**).

**Helping a dying holder.** A dying thread that holds a helping lock
may be helped by a waiter as Fiasco helps any preempted holder (**What
Fiasco does**): the help runs it on the waiter's CPU and scheduling
context, and the tick charges that time to the helper's path, as it
charges all help (**Charging** under [Server urgency and
charging](#server-urgency-and-charging)). That is correct: helping
moves only who runs and pays for the holder's bounded parts until it
releases the lock, and the holder still dies on its home CPU at its
return check. It differs from erXos's kernel, which never helps a dying
holder ([Differences from erXos's kernel](#differences-from-erxoss-kernel)).

**Transfer ownership.** A receiver held in a transfer is counted, since
it is alive, and its kill does nothing until the transfer ends; the
sender owns the transfer and ends it with one request to the receiver's
home CPU. M1 refuses messages with items (`ERX_EINVAL`), so a transfer
is one bounded step that passes no preemption point: on the sender's CPU
the copy of at most 63 words under the CPU lock, across CPUs the same
copy inside the receiver CPU's eager request. A stopped receiver is
therefore held for at most that step, by construction, and no starved
sender can hold it. M5 lifts the refusal and must keep that property:
Fiasco's item transfer runs in the sender's thread context and takes
helping locks (`thread-ipc.cpp:1416`), so a sender preempted inside it,
or starved behind a hostile thread on its CPU, would hold a stopped
receiver, and a kill of the receiver could not finish. M5's design must
state who owns a transfer with items and how it completes or is
abandoned within a bound that no sender's scheduling controls: the
recommendation is to plan the pass before the handshake, in the sender's
own context, so that the step that holds the receiver stays one bounded
step under the CPU lock, which also removes the item path's return to
the sender's context from the cross-CPU request. erXos's kernel has the
same exposure in its rendezvous and the same answer applies there.

### The wait funnel

`Erx::wait_sleep(kind, deadline)` is the one sleep of a thread the
kernel may need to end, and `erx_wait_step` its decision. The glue calls
it under the CPU lock on the thread's home CPU, after the kind's own
listing (on the parked FIFO, the umtx bucket, a receiver's sender list,
the gate's blocked list or `att_stoppers`) has been done, with the
record's `queue` naming the list, and its lock dropped; a receiver's
own wait lists it nowhere, and its `queue` stays `NULL`.

**Classes.** `erx_wait_class(kind)` maps each kind to one of three:

| Class | Kinds | Refused when | Ended by |
| --- | --- | --- | --- |
| caller | `IPC_SEND`, `IPC_RECV`, `UMTX`, `PARK` | the run word is not `LIVE`; `KILL` or `CONTROL_STOP` is posted (`ERX_EINTR`); the deadline has passed (`ERX_ETIMEDOUT`); an executor asks for anything but `PARK` or `UMTX` (`ERX_EWOULDBLOCK`, a second line behind the generated dispatch) | its own event, its deadline, a kick by any request, the death of its partner |
| boundary | `STOPPED`, `FAULTED` | `KILL` is posted (`ERX_EINTR`: the thread goes on to its return check and dies) | a kill, `erx_thread_start` |
| stopper | `STOP` | the run word of the stopper's own space is not `LIVE`; `KILL` is posted (`ERX_EINTR`, which the thread never carries to user mode) | the publication of `EXITED`, a kill |

A boundary wait is how a `CONTROL` stop, a fault and a stopped space's
thread wait at the return boundary, an executor's included: an executor
is held there like any thread, since S3 bounds what an executor asks
for, not what is done to it. A stopper's wait is the one wait for
another thread's death, and it ends at the stopper's own kill: so a
ring of stops, two spaces each stopping the other or any longer one,
ends, since each stopper's wait ends at its kill, each death takes its
own space's count down, and each record is posted by its space's last
death with nothing of the stopper (ST7). Fiasco's own three internal
waits, the answer wait of `Context::drq`, the dying thread's transfer
wait and the grace-period wait, stay outside the funnel. Each is ended
by kernel execution that needs no user thread's turn and has no funnel
record to find: the answer arrives at the requester's CPU from the
target CPU's next request interrupt, the transfer is ended by the
sender's one bounded request, and the grace period ends once every CPU
has passed a preemption point. They are the only sleeps outside the
funnel (ST3). The first is the stopgap's one departure from K33: the
requester holds `erx_object_ref` on its target across it, the one
holder the hosted suite's zero-reference check at a sleep excepts
([Differences from erXos's kernel](#differences-from-erxoss-kernel)).

**The decision.** On `SLEEP(kind, deadline)` the step returns `RETURN`
with a status when the class refuses, else `ARM` when a deadline is
given and `SLEEP`: the glue arms `Erx_wait_timeout`, clears
`Thread_ready` and calls `schedule()`. A refusal is handled as a resume
with that status, membership check and unlink included, since the
kind's listing has already been done. The sleeping thread holds no
reference and no lock, and its result is nothing but what its record
says.

**Completion.** `erx_wait_complete(wait, cause)` is the one pure
function every ender calls (K33): it returns the record with its
outcome set to `cause` when it was `PENDING`, and unchanged otherwise,
so the first ender wins; with the status that outcome maps to; and
with the action `READY` when this call completed the wait. The glue
applies it with one compare-and-swap on the record's `outcome` byte,
from `PENDING` to the cause; a swap that fails, because another
ender's succeeded first, is the function's unchanged result, and that
ender does nothing more to the thread. The swap is the whole of the
ordering between enders: they run on different CPUs, a receiver taking
a sender on the receiver's CPU while the kill kicks that sender on the
sender's, and no lock is common to them, but the outcome byte is. On
erXos's kernel the glue writes the result registers from that status
and runs the return check, so the woken thread's frames have nothing
left to do; on the fork Fiasco's IPC frames hold the call's state
across the sleep, so the glue makes the thread ready and the thread's
own frames return the status, as the kernel design notes for the
stopgap. An ender that walks a list unlinks every waiter it passes,
clearing its `queue` under the list's lock, whether or not its own
swap won, and readies only those it won; an ender that reaches the
waiter on its home CPU, without its list, unlinks nothing:

| Ender | Cause | Where | Unlinks |
| --- | --- | --- | --- |
| a waker walking a list: a wake by slot, a trigger or a handover taking a parked executor; a umtx wake; a receiver taking a queued sender, a binding taking a sender blocked at the gate, who then starts the send over (**After the resume** below); the exit's drain | `WOKEN` | under the list's lock: a leaf, on any CPU; the receiver's home CPU for its sender list | yes, in the same step |
| a dying receiver's sender drain, detaching every sender queued at it | `ABORTED` | under the list's lock, on the receiver's home CPU | yes |
| the owner of a list detaching every waiter at its own destroy: a destroyed gate's blocked list, a destroyed memory object's umtx buckets | `STALE` | under the list's lock, as above | yes |
| a sender's handshake or transfer ending a receiver's wait; a reply; a dying server's abort of its caller's reply wait | `WOKEN`; `ABORTED` | on the receiver's home CPU, in the eager request's handler when the ender is elsewhere, which checks that the receiver still waits for it | nothing listed |
| `Erx_wait_timeout::expired`, at the tick | `TIMED_OUT` | the home CPU | no |
| the kill, `CONTROL_STOP`, `CONTROL_START`, `START` requests | `CANCELLED` | the home CPU, in the handler | no |

An ender on the home CPU acts only on a thread whose `asleep` is set,
which the thread clears on resume under the CPU lock, and an ender
walking a list acts only on records it finds linked there; so no ender
completes a record the thread has reset for its next wait.

**Resume.** The thread wakes inside `Erx::wait_sleep` under the CPU
lock and applies `RESUME`: the step returns `DISARM` if the deadline is
still armed, and the status the completion recorded: `WOKEN` is
`ERX_OK`, `CANCELLED` `ERX_EINTR`, `TIMED_OUT` `ERX_ETIMEDOUT`,
`ABORTED` `ERX_EDEAD`, `STALE` `ERX_ESTALE`, the statuses the kernel
design gives a waiter whose partner died and one whose object was
deleted. Then the **membership check**, Fiasco's own
pattern at `Ipc_gate::block` (`ipc_gate.cpp:436`): still under the CPU
lock, the thread reads its record's `queue`. `NULL` means its waker or
the list owner's teardown has unlinked it already, and the thread
touches the list no further, whatever its outcome; the owner may be
gone by then, and nothing reaches it. A name means the owner's
teardown, which clears the name when it detaches every waiter, has not
run, and since a record is freed only after a grace period that begins
after its teardown, the owner stays alive for the rest of this stretch
under the CPU lock: the thread takes the list's lock, reads `queue`
again, and unlinks itself if it is still named; for a receiver's
sender list, whose lock is the receiver's home CPU, the same check and
unlink run there, through Fiasco's `abort_send` and its eager abort
request. FreeBSD's `umtxq_sleep` has the same shape. The record is
reset before the call returns, and `Thread_cancel`, which the kick also
sets so that the inherited IPC loops abort their phase, is cleared at
the thread's next kernel entry as Fiasco does.

**After the resume, a fresh lookup.** A woken thread's frames carry
nothing of the object it waited on but the record's `queue`, which the
membership check consumes; whatever it does next reaches that object,
if at all, through a fresh capability lookup (ST9). A sender woken at
a gate bound to no thread is the one waiter with an operation still to
make on the object it slept on, the send itself, and it starts that
operation over: on `WOKEN` the IPC core returns the dispatch's internal
retry action, the glue returns it from `Ipc_gate::invoke` without
reading the gate again, and the generated dispatch runs the call again
from `erx_cap_lookup` with the same arguments, which finds the gate
bound and sends, finds it unbound and blocks again with the same
absolute deadline, or finds the capability stale because the gate went
meanwhile (`ERX_ESTALE`), as the kernel design's send has it ([IPC
gates](design-kernel.md#ipc-gates)); on `STALE` it returns
`ERX_ESTALE` outright. So a gate deleted and reclaimed between a
sender's wake and its resume is never read. Fiasco keeps a woken sender
linked on the gate's unblocked queue for exactly that read:
`unblock_all` moves it there (`ipc_gate.cpp:154`),
`abort_all_unblocked` empties the queue at deletion
(`ipc_gate.cpp:179`), `block` rechecks its membership
(`ipc_gate.cpp:436`) and `invoke` then reads `_thread` a second time
(`ipc_gate.cpp:489`); the fork builds neither the queue nor the second
read. The retry action never reaches a result register, only the
send's glue returns it, which a chokepoint check holds, and the loop it
makes is one sleep per turn, ended by the deadline, the kill or the
gate's end, as the wait itself would be.

### Park and wake

The protocol is [design-scheduler.md](design-scheduler.md#park-and-wake)'s
and its decisions are the C17 `erx_park_step`, a pure function over the
group's park record and one event: a park with the caller's epochs and
deadline, a trigger of a bound IRQ object, a capacity change, a wake by
slot, a take of the ready list, a deadline, an executor's death, and an
executor's creation with a slot to take over. It returns the record's
next state and the actions to perform; the glue performs them on Fiasco
and reads no policy. Fiasco carries each action so:

| Action | Fiasco mechanism | Lock | CPU |
| --- | --- | --- | --- |
| compare and list, mirror the epochs and `ready` | the group's park lock, a `Spin_lock` taken under the CPU lock, which a trigger from an interrupt handler may take since every taker masks interrupts; the mirrors are release stores through `erx_shared_store_*` into the status area | the park lock | the caller's |
| sleep the executor | `Erx::wait_sleep(ERX_WAIT_PARK, deadline)`, a caller wait: under the CPU lock, after the park lock is dropped, the funnel clears `Thread_ready` and calls `schedule()`; the executor is on the parked FIFO from the listing on | the CPU lock | the executor's home CPU |
| wake an executor | under the park lock, the waker completes its record `WOKEN` by the swap and unlists it, clearing its `queue`; an executor whose record a deadline or a kick completed first is unlisted, not counted, and the next is taken; then `Erx::wait_wake(t)`: `xcpu_state_change(~0, Thread_ready)`, which sets the bit at once on the home CPU with the ready queue's `deblock`, or posts it to the home CPU's request queue with an inter-processor interrupt when the waker is elsewhere | the park lock, then none | the executor's home CPU |
| arm and disarm the deadline | `Erx_wait_timeout` set in the home CPU's timeout queue before the sleep and reset on resume; its `expired()` completes `TIMED_OUT` by the swap, with no lock, and sets `Thread_ready` with `deblock` when the swap won; the executor unlists itself on resume | none | the executor's home CPU, at the tick |
| take over a slot | the creation sends the old holder `thread_request(HANDOVER)` with the new executor named: the handler, on the old holder's home CPU, clears its slot field, names the new executor in `slot[s]`, completes the old holder `WOKEN` and unlists it from the FIFO under the park lock, and makes it ready; the creation waits for the answer in Fiasco's answer wait, which an executor may do | the park lock, inside the request | the old holder's home CPU |
| an IRQ object bound to a group fires | `Irq`'s hit path takes the park core's trigger step instead of Fiasco's delivery to a thread, in the interrupt handler, with bounded work and no indirect call; a software trigger takes it in `erx_irq_trigger` | the IRQ object's lock, then the park lock inside it, the one nesting the lock order allows | the firing CPU |
| pass over a stopped space's executor | the trigger's and the wake's steps read each candidate's run state from its space's run word; one of a stopped space leaves the FIFO and is woken to die, at most `ERX_GROUP_EXECUTORS_MAX` per trigger | the park lock | the caller's |
| `erx_group_take_ready` | the core's take step under the park lock, then the labels written into the caller's UTCB through the accessors with the lock dropped | the park lock | the caller's |

**The park's outcome.** An executor resumes in `Erx::wait_sleep`:
`WOKEN` is `ERX_OK`, whatever else fired; otherwise it removes itself
from the parked FIFO after the membership check, if it is still on it,
and returns `ERX_EINTR` for `CANCELLED` and `ERX_ETIMEDOUT` for
`TIMED_OUT`. A
deadline already passed returns `ERX_ETIMEDOUT` without sleeping, after
the epoch comparison, so a park with a passed deadline still sees a
wakeup that came before it.

**The executor rule (S3).** The generated dispatch refuses every call
declared `executor: refuse` to an executor with `ERX_EWOULDBLOCK` before
the call runs, `erx_space_stop` among them; `erx_park` refuses a worker
with `ERX_ETYPE`; `erx_umtx_wait` refuses an executor whose word is in a
shared object with `ERX_EWOULDBLOCK` once the key names the object; and
the funnel's caller class refuses an executor every kind but `PARK` and
`UMTX`, a second line behind the generator's check. An executor never
receives: binding a gate or an IRQ object to it fails with `ERX_ETYPE`,
and a thread's class never changes.

**Why no wakeup is lost on the fork (ST4).** The runtime's acquire
loads of the epochs pair with the kernel's release stores of the
mirrors, made under the park lock after the advance, exactly as the
scheduler design argues. The fork adds one step the argument needs:
between the listing under the park lock and the switch away, the
executor holds the CPU lock, so no wake can be applied on its CPU in
between, and a wake posted from another CPU is applied by the
inter-processor interrupt after the switch, when the executor is a
sleeper with `Thread_ready` clear; a wake from the same CPU runs only
after the switch, by the same lock. The ready bit is set only by the
home CPU's state writers, so a wake and a sleep never race on the bit,
and the outcome is written once, by the swap, so a wake and a deadline
never both take the executor: the one whose swap loses neither readies
it nor counts it, and the wake that lost takes the next executor or
stays recorded in the epochs.

**Timers.** Fiasco's timeouts are checked at the 1 ms tick, so a park
deadline and every other wait deadline on the fork have up to one tick
of slack, which the `timer` and `park` benchmarks measure and G1 judges.
A thread's deadline is armed and disarmed only on its home CPU; in M1 a
thread's home CPU is fixed when it starts, and a later binding of
`erx_thread_set_affinity` moves a thread only at a decision on its home
CPU, where an armed deadline moves with it.

**A group's end.** A released group keeps serving its members; a
destroyed group's teardown kills its members through the kill request,
each charging its finishing to its own path, unbinds the IRQ
objects on its `att_bound`, and withdraws its ready list's deliveries
through `erx_irq_step` as unbinds; `erx_park` on a closed group returns
at once and the caller dies at its return check ([Ownership and
lifetime](design-scheduler.md#ownership-and-lifetime)). The group's
teardown first clears the group's pointers to its shared areas, then
releases their pages through `erx_page_release`, so their charge ends
there. Every store the kernel makes into a status area, a mirror of
the epochs, the counts, a slot's state or the counters, goes through
`erx_shared_store_*` on the area that pointer names, under the CPU lock,
and stores nothing once it is clear; a released page waits out a grace
period, which no store made under the CPU lock before the clear can
outlast, since a CPU reports its quiescent state only at a tick or from
idle, never inside a stretch under the CPU lock. So a
killed member that goes on finishing adds its time to the group's
per-CPU records and publishes nothing, and no store reaches a page
another budget may have taken. The reaper frees the group's record and
its per-CPU records after the grace period and the last member's
death ([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages)).

### Server urgency and charging

Configuration C0: urgency levels, round robin within a level, no quota.

**Urgency to priority.** A thread's Fiasco priority is
`erx_sched_resolve(thread) + 1`, in 1 to 64 above Fiasco's idle
priority 0: its own base, or its group's until it has one, clamped to the
least ceiling on its group path; a dying thread's is
`ERX_PRIO_FINISHING`. The priority is written at the thread's creation,
by `erx_thread_set_urgency`, by the kill, and by `erx_group_configure`,
which refreshes every member of the group and of the groups below it in
bounded parts before it returns, each refresh a request to the member's
home CPU that dequeues, sets and enqueues its scheduling context. The
kernel design derives the value at every decision instead; on the fork
the value is stored and refreshed, so a ceiling change takes effect for
every thread by the time the configuring call returns rather than at
each thread's next decision, a difference the scope table records.

**Round robin.** A thread's time slice, `Sched_context::_quantum`, is
its group's `slice_us`, set with the priority; Fiasco's slice timeout
rotates the running thread to the end of its level and picks again, and
a thread preempted by a higher priority rejoins the head of its level,
and a woken thread joins the head as well, where S7 appends it
(**What Fiasco does**), a difference the fork keeps. The slice's end is
taken at the tick, so a slice is accurate to 1 ms. A dying thread keeps
its slice.

**No direct switch.** `Thread::activate_ipc_partner` on the fork makes
the receiver ready with `deblock` and switches to nothing; its
`do_switch` path and the `lazy_q` form of `deblock` are not built. A
caller then enters its reply wait through the funnel, whose `schedule()`
picks the highest ready thread, and a sender without a reply phase
reschedules at its return when `deblock` reported a preemption. Whoever
is picked is switched to by `schedule_switch_to_locked`, which sets the
CPU's current scheduling context to that thread's own, so the server
runs at its own priority and on its own group's grant from its first
instruction, its slice programmed from its own `left`, and no remaining
time of the caller is lent. A thread waking at 25 while a server at 15
serves a caller at 40 preempts the server at once, since `deblock`
compares it with the server's own context (S5). The only switch of
execution context that leaves the scheduling context alone is a lock
holder's help, which the kernel design charges to the helper as the fork
does.

**Charging.** At every tick, the fork's tick hook, in
`Thread::handle_timer_interrupt`, calls `erx_sched_charge(path,
1 ms)` once, for the charge path of the thread that owns the CPU's
current scheduling context: the running thread's own path, a helped lock
holder's helper's, and a dying thread's own path with the finishing
kind, where the charge goes to `finishing_ns` and to nothing else. The
charge function is the one writer of a group's usage and of its
`finishing_ns`, a chokepoint of the build; in C0 it keeps the per-group
statistics the inspector reports, `used_ns`, `total_ns` and
`finishing_ns`, in the groups' per-CPU records, and mirrors them into
the status area through the one publish path (**A group's end**); the
quota pool's draw and throttle, built and tested on the host, are not
called on the target until C1.

**What C1 adds, without reshaping.** The tick hook calls the draw when
a path's local slice is spent and moves the thread to the throttled list
the pick then skips, never a dying thread, whose charge admits nothing
and draws nothing, and the kill takes a throttled thread off its list
(**Stop and exit**); the refill
timers are Fiasco timeouts on the CPUs where threads wait. None of it
changes the request, the funnel, the finishing priority or the run word.

## Concurrency and failure behavior

* **Locks.** The order is the kernel's one order,
  `kernel/core/lock_order.h` ([Execution model and
  locking](design-kernel.md#execution-model-and-locking)), and this
  binding adds no level to that file: the one level it needs beyond
  the kernel's, for the fork's own queue locks, is a stopgap addition
  recorded here and in the fork's lock-order check alone, since erXos's
  kernel has no such locks: its ready queues are written by their CPU
  alone and its request queue is appended with release stores
  ([Cross-CPU requests](design-kernel.md#execution-model-and-locking)).
  The space's lock, a `Helping_lock` at
  the order's third position, orders every write of the run word, the
  thread list, creation and start, and the stop walk's marking; it is
  never held with a leaf, across a request or across a wait: the walk
  marks and references under it and sends with it released; the
  claimant posts with no lock held, publishes under it, releases it,
  and only then drains the stoppers list. The stoppers lock, the park
  lock, the umtx bucket lock, the gate's lock and a group's pool lock
  are leaves, each taken with no other lock held and with interrupts
  masked: a stopper registers under the stoppers lock alone, the exit
  record's post takes the gate's lock alone as any send does, and the
  request's handler holds the CPU lock and no leaf, since a kick
  completes by the swap and unlinks nothing. The two nestings the
  kernel's order allows, an IRQ object's lock around the park lock and
  a memory object's lock around a umtx bucket's, are the only ones
  here. Below every leaf lie the fork's own queue locks, the request
  queues' and the ready queue's, which Fiasco takes inside a leaf (an
  IRQ delivery readies its target, a queue edit, under the IRQ object's
  lock) and only for one edit of their queue, never across anything
  else.
  They are the one level the fork's lock-order check has that
  `kernel/core/lock_order.h` does not: the check places them beneath
  every leaf as the stopgap's own addition, and the kernel's order
  stays free of them. Every lock named here, the leaves and the fork's
  queue locks alike, is Fiasco's `Spin_lock`, which the fork rebuilds
  on the core's ticket lock
  ([Locks](design-stopgap.md#budgets-and-the-ownership-of-pages)), so
  takers are served in the order they arrived and no CPU waits at a lock
  for as long as others keep taking it.
* **Home CPUs (K14).** A thread's state word, flags, wait kind, deadline
  and scheduling context are written only on its home CPU: by the thread
  itself, by the request's handler, by a timeout's expiry on that CPU's
  queue, and by Fiasco's remote state change applied there. A wait's
  outcome is the one exception: whoever ends the wait writes it, on any
  CPU, by the completion's compare-and-swap, and its `queue` field is
  written under the list's lock by whoever unlinks the thread. Another
  CPU reaches the thread's other fields only through the request or
  through `xcpu_state_change`.
* **Interrupt context.** A trigger from an interrupt handler takes the
  park lock and posts wakes, bounded work; a request interrupt's whole
  entry runs at most `ERX_REQUEST_BATCH` steps, contexts visited and
  handlers run, and continues itself; the post of an
  exit record runs in thread context only, by the claimant, since a
  death edge happens only in a thread's own teardown and a claiming
  `STOP` in the stopper's call.
* **Migration.** Fiasco's request queue follows a thread whose home CPU
  changes, and `xcpu_state_change` re-reads the home CPU under the
  request queue's lock, so the request and the wake are correct whether
  or not M1 moves threads.
* **Unwaited requests.** A delivery queued at a thread through
  `Erx::request` may run after an eager abort of that thread's wait, or
  after its kill; its handler decides from its object's binding under
  the object's lock, and an exit record's from the placement made under
  its gate's lock, never from the order, and what is queued at a
  dying thread when it writes its dead mark is run or cancelled by its
  kill continuation's drain of the closed queue, in parts
  ([design-stopgap.md](design-stopgap.md#stop-and-exit-the-binding)).
  The delivery's reference on its object travels with it from the
  request queue to the sender list or the gate, and is dropped only
  where the record is taken or withdrawn (**Posting and publishing**).
* **Failure of a request's target.** A request to a thread that dies is
  run by the thread's own drain when it was queued before the dead mark
  and refused when it was sent after, decided under the thread's
  request queue's lock, where the mark is written before the drain
  (**The request**); the requester's reference keeps the
  record, and a handler that runs finds the thread dying and does
  nothing new but answer.
* **The stopper's own fate.** A stopper killed while it waits in
  `ERX_WAIT_STOP` is kicked like any waiter: it unlinks itself unless
  the drain already has, returns through its own return check and
  dies; its target's record is posted by that space's own last death.
  So two spaces stopping each other, or any ring of stops, end: each
  stopper's wait ends at its own kill, which the other's walk posted
  before that other waited, each death takes its own space's count
  down, and no post waits on a stopper (ST7). A stopper whose own
  space is stopped while it waits is kicked by that stop's kill; one
  that is `CONTROL`-stopped keeps waiting and holds at its boundary
  after the record, since its target's stop does not depend on it.
* **What cannot happen.** A record posted twice, or `EXITED` seen
  before the record is posted (ST1); a stopped thread in user mode or in
  a caller wait (ST2); a request or a stop waiting for another
  thread's turn (ST6); a lost park wakeup (ST4); a server above its
  ceiling (ST5); a stop waiting on a death that waits on it (ST7); a
  queue, a charge or a status store that reaches a freed record or a
  released page (ST8); a woken thread reading an object its sleep
  outran (ST9); a drain that other CPUs can replenish (ST10); a stop
  that waits for kills another stopper never sent (ST11); a CPU passed
  over at a lock for as long as others take it, since every lock serves
  its takers in order; a grace-period wait served by one masked pass
  over all callbacks, since the one grace list is served 64 items a
  step; a stretch with
  interrupts masked that grows with the thread count, the request
  count or the wake count, since every walk and every entry over the
  queues is in parts and every step does one thread's work.

## Refusals and error results

| Call | Refusal | Status |
| --- | --- | --- |
| `erx_space_stop` | a kernel-owned status; the caller lacks `STOP` | `ERX_EINVAL`; `ERX_ERIGHTS` |
| `erx_space_stop` | by an executor | `ERX_EWOULDBLOCK`, by the dispatch: the call waits for the finishing threads |
| `erx_space_stop` | the caller's own space has stopped, its own among the stops, or a kill is posted to the caller, before or while it waits | `ERX_EINTR`, which no user code reads: the caller dies at its return check |
| `erx_space_pause` | always, on the fork | `ERX_ENOTSUP` |
| `erx_thread_create`, `erx_thread_start` | the space's word is not `LIVE` | `ERX_EDEAD` |
| `erx_thread_read`, `erx_thread_write` | the thread does not sleep in a boundary wait | `ERX_EBUSY` |
| any caller wait | the caller's space has stopped, or a kill or a `CONTROL` stop is posted to the caller | `ERX_EINTR`, then death or the stop at the return check |
| `erx_park` | by a worker; a closed group | `ERX_ETYPE`; `ERX_OK` at once, then death |
| `erx_park`, `erx_umtx_wait`, IPC waits | the deadline passes first | `ERX_ETIMEDOUT` |
| IPC waits, umtx waits, `erx_park` | by an executor where the ABI file refuses it | `ERX_EWOULDBLOCK`, by the dispatch |
| `erx_umtx_wait` | by an executor on a word of a shared object | `ERX_EWOULDBLOCK` |
| `erx_gate_bind`, `erx_irq_bind` | to an executor | `ERX_ETYPE` |
| `erx_thread_set_urgency` | above `ERX_URGENCY_MAX` | `ERX_EINVAL`, by the generated type |
| an IPC send with items | always, in M1 | `ERX_EINVAL` |
| an IPC send blocked at a gate bound to no thread | the gate is destroyed while the sender waits; a binding woke the sender and the gate went before the sender ran again | `ERX_ESTALE`, from the detach or from the send's fresh lookup |
| `erx_umtx_wait` | the word's memory object is destroyed during the wait | `ERX_ESTALE` |
| a request to a thread: a kill, a `CONTROL` stop, a register access, a delivery | the thread has written its dead mark | `ERX_EDEAD` to the requester; a delivery's sender resolves the binding again |

Nothing here panics: a malformed request fails with a status, a dying
target answers and is left alone, and the one end of the machine, the
root space's exit, is the kernel design's K31 route.

## Interfaces

**The C17 cores**, built for the host and for the fork, with no Fiasco
name in them:

```c
/* kernel/core/stop.c */
erx_stop_result_t erx_stop_step(erx_run_word_t word, erx_stop_event_t event);
	/* events: CREATE, START, STOP, DEATH, PUBLISH, CHILD_PEND, CHILD_DONE;
	 * actions: ADMITTED, REFUSE, WALK, DONE, CLAIM, WAKE, NONE */

/* kernel/core/wait.c */
erx_wait_class_t erx_wait_class(erx_wait_kind_t kind);	/* CALLER, BOUNDARY, COMPLETION */
erx_wait_result_t erx_wait_step(erx_wait_t wait, erx_wait_event_t event, erx_wait_input_t in);
	/* events: SLEEP(kind, deadline), RESUME; inputs: the run state, the
	 * thread's flags, its class, the clock; actions: SLEEP, ARM, DISARM,
	 * RETURN(status) */
erx_wait_result_t erx_wait_complete(erx_wait_t wait, erx_wait_cause_t cause);
	/* causes: WOKEN, TIMED_OUT, KICK, ABORTED, STALE; the first ender wins; the
	 * glue applies the result by one compare-and-swap on the outcome; the
	 * result is the record, the status and READY when this call
	 * completed the wait */

/* kernel/core/return.c */
erx_return_t erx_return_check(erx_run_state_t run, uint32_t flags, uint32_t holds, erx_upcall_t upcall);

/* kernel/core/park.c: the scheduler design's protocol */
erx_park_result_t erx_park_step(erx_park_t *group, erx_park_event_t event);

/* kernel/sched/sched.c */
erx_urgency_t erx_sched_resolve(const erx_sched_thread_t *t);
void erx_sched_charge(const erx_sched_group_t *group, uint64_t ns);
	/* adds to the per-CPU records of each group on the path: usage, or
	 * finishing_ns from the thread's kill on */
```

**The glue**, C++ in the fork, applies actions and nothing else: the
run word's one store function under the space's lock; the stoppers
lock; `Erx::thread_request`, the one budget of each entry over the
request queues with its requeue, and the dead mark with the closed
queue's drain in the kill continuation; `Erx::wait_sleep`,
`Erx::wait_wake`, the completion's
swap at each ender, the membership check at each resume and the retry
action a send returns after a wake at an unbound gate;
`Erx_wait_timeout`; `Exit_sender` with its delivery reference; the
status area's one publish path and the group teardown's detach before
release; the IRQ hit path's call into the park core; and the priority
refresh with its finishing rule.

**What this binding relies on in [design-stopgap.md](design-stopgap.md)**,
each stated there:

* the common return path (`.Lret_from_exception`) is the one exit to
  user mode, reached by every call's return, every wake, every first
  entry and every interrupt taken in user mode, and it calls
  `erx_return_check` on the home CPU with interrupts masked after the
  call's frames have returned; the IRQ shortcut is off;
* `erx_object_ref` and `erx_object_put` are the one reference count; a
  thread's teardown walks `att_gates`; a thread holds a reference on its
  space from `Thread::bind` to `Thread::unbind`, and on the groups of
  its path from its creation until `handle_kill_helper` after its last
  switch;
* the IPC glue's three sleeps, `do_send_wait`, `do_receive_wait` and the
  sender's wait at an unbound gate, sleep through `Erx::wait_sleep` and
  are ended through `erx_wait_complete`; its cross-CPU handshake, reply
  and abort requests are eager; a message with items is refused in M1;
  `activate_ipc_partner` switches to nothing; a sender's insert on a
  thread's home CPU refuses a thread marked dying with `ERX_EDEAD`, as
  it refuses a closed one; `Ipc_gate::invoke` reads the gate's binding
  once, before its block, and after a `WOKEN` block returns the
  dispatch's retry action instead of reading it again, and Fiasco's
  unblocked queue is not built;
* the generated dispatch runs a call again from its lookup when the
  call's glue returns the retry action, which only the send's glue
  returns, under a chokepoint check;
* every `Spin_lock` of the fork, the request queues' and the ready
  queues' included, is the core's ticket lock, which serves its takers
  in order; and a dying thread's grace-period wait is
  an item of the one stamped grace list, served at most 64 items a
  step (**Locks** and **Grace items** there);
* `Context::drq`, through `Erx::thread_request`, is the one waited
  request and `Erx::request` the one unwaited one, which takes
  `erx_object_ref` on the object it names, a reference the delivery it
  carries keeps until the record is taken or withdrawn; both refuse a
  thread past its dead mark, read under the thread's request queue's
  lock where the mark is written; the exit record's cross-CPU delivery
  is an `Erx::request` naming the space; a queued delivery's handler
  decides from its object's binding, never from its order against an
  eager abort; the kill continuation writes the mark before it drains
  and then runs or cancels the cohort the mark closed, in parts, as
  the death order above places it;
* a thread's FP state is inline in its block, so the kill moves and
  frees none;
* the space's teardown runs this binding's stop and deletion walk before the
  mapping teardown, and the root space is the one without a parent;
* the generated dispatch marks `erx_space_stop`, the IPC waits,
  `erx_umtx_wait` and `erx_park` with their executor attribute,
  `erx_space_stop` as `executor: refuse`, and `erx_thread_stop`,
  `erx_thread_start`, `erx_thread_read`, `erx_thread_write` and the
  thread's destroy go through `Erx::thread_request`;
* every record this binding names is a field of a thread, space or
  group record charged by the C17 allocation funnel, and the conformance
  runs of the stop and park cases report Fiasco's stack-fill watermark.

## Security

The trust boundary and the threat model are the kernel design's
([design-kernel.md](design-kernel.md#security)); the fork is never
hardened, and development builds run trusted code only. This binding
adds one cost a holder can impose on others, which the fork leaves
unbounded per CPU.

**What a stop can cost.** A holder of `STOP` on a space, or of
`DESTROY` on a group or a thread, starts finishing work that no grant
caps, its own included: the killed threads run at the finishing
priority, above every user thread of their CPUs and outside every
quota, in C1 as in C0. In all the work is bounded by the parts the
stopped threads' calls have left, each within the bound the ABI file
declares for the call, their number by the records the stopped space's
budgets paid for, and the whole fixed at the stop, since a stopped space
starts no call and creates no thread. A CPU with none of the target's
threads loses nothing; a killer's own grant, cpuset or fate changes
nothing about what runs, and the finishing time is counted on the
stopped threads' own groups, apart from their usage, for the accounting
alone.

**The stream of kills, a stopgap residual.** The fork has no finishing
share, so a stream of kills homed on one CPU holds that CPU's user
threads back, the root task's petting thread among them, for as long
as the stream lasts; the bound is the stopped spaces' remaining work,
paid for by their budgets, and a domain that can create and kill
threads as fast as its budget allows can keep a CPU from its user
threads, and end the machine through the watchdog, for as long as it
goes on. That is acceptable only because development builds run
trusted code; erXos's kernel bounds it with the finishing share
([design-scheduler.md](design-scheduler.md#pick-and-dispatch)), and
`TODO.md` records it. The other rates this binding does not bound, a
request rate and an edge-triggered line's, are the residuals of
**Risks and open questions**.

## Verification and testing

Each check pairs with a seeded failure that proves the code under test
ran. The host models are exhaustive: each explores every interleaving of
its events by state-space search with duplicate states pruned, over the
bounds stated.

| Layer | Check | Passing case | Seeded failure |
| --- | --- | --- | --- |
| core, host | `erx_stop_step` and the stop protocol: three threads and two stoppers, one of them a thread of the space; per thread the events create, start, enter a call, caller wait, boundary wait, transfer hold and release, kill arrival, return check, death edge, `unbind`; per stopper `STOP`, walk parts of one and two threads, the sends and answers of each part, the marks after them, registration, resume, and a first stopper that stops running for good after its `STOP`, after any part's sends and before any part's marks; the claimant's claim, post, publish and drain in parts of one; a `CREATE` and a `START` attempted at every point | exactly one `CLAIM` and one post per trace, with every thread past its death edge at it; the post precedes `PUBLISH` and every waiter's wake; every waiter is woken by the claimant's drain alone; no `CREATE` or `START` admitted after `STOP`; every trace reaches `EXITED`, the second stopper's included when the first never runs again | the death edge applied after `unbind`, to another word, never reaches zero; `PUBLISH` before the post lets a waiter return with no record posted; a registration outside the lock loses a waiter; a wake chain, where each waiter wakes the next, leaves the rest asleep when the scheduler never runs the first; a run word written outside the lock lets two deaths both claim; a `STOP` from `STOPPED` that only waits, or a mark set before the kill is sent, leaves the second stopper asleep while a thread the first stopper never killed runs on |
| core, host | `erx_wait_step` and `erx_wait_complete`: one thread of each class, every order of sleep, wake, deadline, kick with each request flag, partner death and resume, with the run state live or stopped and the flags clear, `KILL` or `CONTROL_STOP` | exactly one outcome per wait, the first ender's; a caller wait refused while stopped or flagged, a boundary wait refused only under `KILL`, a stopper's wait refused once its own space has stopped or a kill is posted and kicked by a kill alone; an executor's caller wait only `PARK` or `UMTX`, its boundary wait allowed; the deadline disarmed on every resume; with the list owner's detach and the waiter's resume among the events, and the owner freed after its detach: every waiter unlinked exactly once, and none touching its list after the owner is freed | a boundary wait classified as a caller wait makes a `CONTROL` stop loop forever; a funnel reading the run word before the CPU lock sleeps after a stop; a second ender overwriting the outcome, which a plain store in place of the swap allows; a resume that skips the disarm fires a stale deadline into the next wait; a resume that unlinks without the membership check reaches a freed owner, which the model's freed flag catches |
| core, host | the IPC core's send at a gate bound to no thread, over every outcome of the wait, with the gate bound, unbound again, or deleted between the wake and the resume, and with and without a deadline | `WOKEN` restarts from the lookup, which sends, blocks again with the same absolute deadline, or returns `ERX_ESTALE`; `STALE` returns `ERX_ESTALE`; `CANCELLED` and `TIMED_OUT` return their statuses; the model's freed flag on the gate is never read after the wake | a resume that reads the binding its frames hold reaches the freed gate, which the model's freed flag catches |
| core, host | the mutual stop: two spaces of two threads each, a thread of each stopping the other, over every interleaving of walk parts, kill arrivals, the stoppers' waits and kicks, detachments, death edges, claims and drains; then a ring of three | every space reaches `EXITED` with exactly one record, each after its own last death edge; every stopper's wait ends at its kill; no trace waits forever | a stopper's wait the kill leaves alone, which leaves every word `STOPPED` in the trace where both stoppers wait |
| core, host | `erx_return_check` over every combination of run state, flags, holds and upcall state | the row table; holds never fire with zero counts | rows 1 and 2 swapped hold a killed thread instead of killing it; a stopped space's thread resumed instead of held |
| core, host | `erx_park_step` exhaustive model (S2), as the scheduler design states it: two executors, two IRQ objects triggered repeatedly, a capacity change, deadlines, epochs to depth 12, and an old executor of a stopped space dying while a new one holds its slot | no lost wakeup; every request resolved | a compare outside the lock loses one |
| concurrency, host | the park core under ThreadSanitizer with sixteen threads parking, triggering, waking by slot and taking the ready list for a million operations, under a host lock | no race report | the park lock removed from the trigger step reports a race on the epoch |
| hosted and debug builds | K33 on the fork: each thread's held locks and counted references are counted and asserted zero at the funnel's sleep, the answer wait of `Context::drq` excepted as the one holder | the stop, park, umtx and IPC cases pass | a park that keeps a reference across its sleep fails the hosted suite |
| hosted, ASan | the exit record's lifetime: a space whose last thread exits while its fault gate's thread is busy on another CPU, then every capability to the space closed before that thread receives; the same with the gate destroyed while the record is queued; and the receiver killed with the record on its list | the record is received intact, or dropped and counted, and the space's record is freed only after that; no report | the delivery's reference dropped at the handler's return frees the space under the queued record, which ASan reports |
| hosted, ASan | a waiter's lifetime: a sender blocked at an unbound gate is killed in the same step its gate is destroyed, a thousand times; a sender blocked at an unbound gate is woken by a binding and the gate is destroyed and reaped before the sender runs again, a thousand times; a sender queued at a receiver is killed as the receiver dies; a stopper is killed as the stopped space publishes | each waiter returns `ERX_EINTR`, `ERX_EDEAD` or `ERX_ESTALE` and is unlinked once; the woken sender's retry returns `ERX_ESTALE` from its lookup; no report | the membership check removed from the resume unlinks from a freed gate, which ASan reports; the glue reading the gate's binding after the wake, as Fiasco's `invoke` does, reaches the freed gate, which ASan reports |
| hosted, ASan | a group's status area after its destroy: a group destroyed while a member finishes a long range call, the area's pages taken by another budget's charge once their grace period has passed and filled with a marker, while the member goes on finishing and after it has left the member list | the marker stays whole; the member's time lands in the per-CPU records' `finishing_ns` and in the parent group's `erx_group_info`; no report | a publish that keeps the area's pointer after the destroy overwrites the marker, which the case checks, and with released pages poisoned ASan reports the store |
| build | `erx_wait_complete` is referenced from every ender listed in the completion table and nowhere else, by relocation | pass | a wake by slot that readies the executor without the completion fails |
| kernel, QEMU, 4 CPUs | a thread killed while IRQ deliveries and an exit record from another CPU are queued at it | each delivery reaches the gate's or the IRQ object's next binding or is held pending; the IRQ object's record is freed by the reaper once its last capability goes | the drain of the closed queue skipped leaks a delivery's reference, and the leak check on the IRQ object fails |
| build | the run word's one store function, with the chokepoint check that it is called only by the creation, the start, the stop, the death edge and the publication, each asserting the space's lock; a check that every `drq` call in the glue and the IPC path passes `eager = true`; a check that `switch_exec_locked(..., Not_Helping)` is called only in `schedule_switch_to_locked`; a check that a clearing of the ready bits followed by `schedule()` occurs only in `Erx::wait_sleep`, `Context::drq`, `do_kill`'s transfer wait and `rcu_wait`; the charge function's chokepoint; a check that a wait record's `outcome` is written only by the completion's swap and the resume's reset; a check that `Ipc_gate::invoke` reads `_thread` once, before `block`, and that `_unblocked_q` and `abort_all_unblocked` are absent from the image; a check that the dispatch's retry action is returned only by the send's glue; the absence of `Thread::halt`, `pi_mutex`, `Ipc_gate::block`'s own sleep, `Rcu::call` and `Rcu_data::do_batch` from the image | pass | a seeded store to the word in a glue file, a seeded `drq` without `eager`, a seeded donating switch in `activate_ipc_partner`, a seeded `state_del_dirty(Thread_ready); schedule();` in a glue file, a seeded second writer of usage, a seeded plain store to `outcome`, a seeded second read of `_thread` after `block`, a seeded retry returned from the umtx wait's glue, and `Thread::halt` compiled back in each fail |
| kernel, QEMU, TCG and HVF, 1 and 4 CPUs | K18: a space with threads on every CPU running user code, inside a long range call, in `erx_ipc_wait`, in `erx_ipc_call` to a server in another space on another CPU, mid-transfer as a receiver of a 63-word message, blocked at an unbound gate, in `erx_umtx_wait`, in `erx_park`, under a `CONTROL` stop, waiting at the fault gate after a fault, and never started; a thread created and one started during the stop; a second stopper, a self-stop and a thread of another space creating a thread in the stopped space, which takes the space's lock, racing on other CPUs | one exit record, received before the stoppers return; `erx_object_info` of the space reports `EXITED` with zero live threads after they return; no progress counter of the space moves afterwards; the creation and start fail `ERX_EDEAD`; the range call's object is gone | a kill that skips the umtx kind hangs the stop and the harness's deadline fails the case; a return check that resumes a stopped thread moves a counter after the record; the space's lock held across the kill request fires the home-CPU assertion of Fiasco's state writers when the creating thread helps the stopper on its CPU |
| kernel, QEMU, 4 CPUs | the starved receiver: a space is stopped while its thread calls a gate bound to a thread on another CPU behind a spinner of a higher urgency, and while a thread of it is a receiver in a transfer from a sender on another CPU | the stop completes within the harness's bound | a handshake sent with `eager = false` waits for the spinner's turn and fails the bound |
| kernel, QEMU, 4 CPUs | the request flood: threads of a space on three CPUs send requests to CPU 0 for sixty seconds, IPC sends to a receiver there that never waits, `erx_thread_stop` and `erx_thread_start` on their own threads homed there, and umtx wakes and park wakes of four thousand of its threads waiting on CPU 0, each wake a context visit with no handler in it, while a thread of another space at urgency 1 on CPU 0 counts progress and the root task pets | the pet never misses; the progress counter advances; a debug counter of the steps of one entry, contexts visited, handlers run and the current thread's queue included, stays at or below `ERX_REQUEST_BATCH`; the request entries CPU 0 takes per tick are recorded for G1 | the batch bound removed, kept as one counter per queue loop so that it multiplies across Fiasco's nesting, or kept to handlers alone so that the wake flood's context visits and the entry's final `handle_drq` go uncounted, makes the longest entry exceed the bound under the flood |
| kernel, QEMU, 4 CPUs | requests racing a death: threads on three CPUs send `erx_thread_stop`, `erx_thread_read` and kills to a thread on CPU 0 in the same tick it dies, a thousand times; then the same with the three CPUs flooding the dying thread with requests and IRQ deliveries throughout its drain | every request returns `ERX_OK`, `ERX_EBUSY` or `ERX_EDEAD` and none waits past the harness's bound; the drain runs at most `ceil(cohort / ERX_REQUEST_BATCH)` parts for the cohort the mark closed, and a debug counter of its longest masked stretch stays within one part; every delivery reaches the IRQ object's next binding or is held at it; the thread's record is freed, which the leak check shows | the dead mark read outside the request queue's lock lets a request queue after it, and its requester's wait fails the bound; the mark written after the drain, as a drain that closes only an empty queue would, lets the flood replenish the queue, the part count grows for as long as the flood lasts, and the case's bound fails |
| kernel, QEMU, 4 CPUs | the grace-period wait: a thousand threads die on CPU 0, with a thousand gates destroyed there meanwhile, while user spinners run on the other CPUs and a space on CPU 1 runs long range calls | the deaths complete within the harness's deadline; a debug counter of the longest stretch CPU 0 ran with interrupts masked stays within the bound of one record step | the tick's quiescent report (`inc_q_cnt`) removed on one CPU holds every death's wait, and the case's deadline fails; the step's limit of 64 removed runs the thousand wakes in one masked pass, which the masked-stretch counter catches |
| kernel, QEMU, 4 CPUs | mutual stops: a thread of A stops B while a thread of B stops A, each space with threads in calls and waits on every CPU; then a ring of four spaces each stopping the next | two, then four, exit records, each after its space's last death, within the harness's bound; `erx_object_info` of each space reports `EXITED` | a stopper's wait left out of the kill's kick leaves every word `STOPPED` and the deadline fails |
| kernel, QEMU, 4 CPUs | finishing: a stopper at urgency 10 whose group's quota is zero stops a space whose thread is inside a long range call on a CPU where a spinner of another space runs at urgency 40, the stopped thread's own group at zero quota as well, and a second stopper at 50, whose cpuset excludes that CPU, joins; then a stopped thread that holds its space's lock across a long range call while a thread of another space on another CPU waits for that lock and helps it | the record arrives within the harness's deadline whatever either stopper's quota or cpuset, and both stoppers return after it; the stopped thread's own path gains its finishing time in `finishing_ns`, no pool, `used_ns` or `total_ns` moves for it, and neither stopper's path gains anything; the helped holder's record comes as well, the time it ran on its helper in the helper's `used_ns`, as all help is charged | the finishing priority set to the first stopper's lets the spinner at 40 hold the record while it spins, and the case's deadline fails; a seeded throttle of the dying thread on its own path's zero grant holds the record forever, which the deadline catches the same way; a seeded charge of the finishing time to the first stopper's path, or to the stopped path's pool, fails the counters |
| kernel, QEMU | S5: a server at ceiling 15 serving a caller at 40 while a fourth thread wakes a third at 25 | the third runs before the reply, which it proves by a timestamp from the time page; the server's group's `used_ns` grows by the service and the caller's by its own spin alone | a donating `switch_exec_locked` restored in `activate_ipc_partner` lets the server finish first |
| kernel, QEMU | S3 and boundaries: every blocking call from an executor; `erx_space_stop` from an executor; a `CONTROL` stop of an executor inside `erx_park`, and an executor that faults | `ERX_EWOULDBLOCK` each; `erx_park` from a worker `ERX_ETYPE`; the stopped executor's park returns `ERX_EINTR` and the executor holds at its boundary until `erx_thread_start`, with its registers readable there; the faulting executor's record reaches the fault gate | a call declared without its attribute fails the generator; the funnel's boundary row removed for executors asserts instead of stopping |
| kernel, QEMU | deadlines: `erx_park`, `erx_umtx_wait` and an IPC call with deadlines of 2 ms, 0 and one already passed, with and without a wake racing them | `ERX_ETIMEDOUT` within 2 ms plus one tick; a wake before the deadline wins; a passed deadline after a wakeup returns `ERX_OK` | a disarm omitted makes the next wait return `ERX_ETIMEDOUT` at once |
| kernel, QEMU | the hostile demo of M1, then the stop of both domains with threads in calls, faults and waits on every CPU | every CPU of every domain progresses for ten minutes; one exit record per domain after the last death; the root task pets throughout | a seeded skipped return check lets a thread return and fails |
| kernel, QEMU | determinism: the K18 case in `erx.det=1` twice | byte-identical traces | |
| parity, M7 | the same cases on erXos's kernel | identical decisions on the cores' traces | |

The constructions this binding rests on each have a seeded failure
above: the live count (the edge after `unbind`), the walk every stop
makes (a `STOP` from `STOPPED` that only waits; the mark before the
send), the finishing priority (the stopper's urgency instead), the one
grace list (the step's limit removed), the status area's detach (the
publish that keeps its pointer), the
ordinary pick (the donating switch restored), the publication order
(`PUBLISH` before the post, and the wake chain), the wait that ends at
the kill (the stopper's wait left alone), the one swap on the outcome
(the plain store), the membership check (the unlink without it), the
fresh lookup after a wake (the binding read after the block), the one
budget of an entry (one counter per loop; handlers alone), the closed
queue (the mark after the drain), and the references a delivery and a
dying thread's own path hold (dropped at the handler's return; dropped
at the teardown). The stop and park conformance runs report the
stack-fill
watermark of every thread they ran, and the host cores run under ASan
and UBSan.

## Performance

Gate G1 times, under TCG and HVF, by the time page's counter:

* `tools/erx bench stop`: from the stopper's trap into `erx_space_stop`
  to its return, for a space with one thread per CPU in each of a long
  range call, `erx_park`, `erx_ipc_wait`, a umtx wait and a user-mode
  spin; from the trap to the exit record's receipt by the fault gate's
  thread, which timestamps it on return from `erx_ipc_wait`. The
  figures are measurements for G1, not bounds the fork promises.
* `park` and `wake`: a worker on the executor's CPU, and on another
  CPU, timestamps just before its `erx_executor_wake` trap; the executor
  timestamps just after `erx_park` returns; the difference is the wake
  latency, trap, park lock, request or `deblock`, switch and return path
  included.
* `ipc`: a round trip through a gate to a server in an open wait on
  the caller's CPU, within one space and across spaces, which takes the
  ordinary pick; and the same across CPUs, which shows the eager
  handshake's cost. G1 decides from it whether an early pick is worth
  adding; one that is added must take the scheduler's actual pick, with
  the server queued among the candidates, so that a tie at the server's
  level keeps the earlier thread's turn (S7).
* `timer`: a park with a deadline, from the deadline to the return,
  which shows the tick's slack.
* the request flood's throughput loss on the flooded CPU.

Each number states host, accelerator, QEMU version, compiler, flags and
workload, and TCG numbers are never compared with HVF numbers. G1
decides the timer slack and the default slice from them, and whether the
1 ms tick suffices until M7.

## Differences from erXos's kernel

Each documented, tested, and gone with the stopgap:

| Difference | On the fork | On erXos's kernel |
| --- | --- | --- |
| the count that gates the exit record | the live count: every thread from its creation to its death edge, with no pauses or copies to serve | the active count: every thread running or preempted inside a call, which pauses and copies also wait on; both are zero exactly when no thread of the space can act |
| what finishing may take from a CPU | no share: a killed thread runs at the fixed finishing priority above every user urgency on its own CPU, outside every quota, until its call is done, so a stream of kills holds that CPU's user threads back for as long as it lasts, bounded only by the stopped spaces' remaining work, which their budgets paid for; a stopgap residual (**Security**) | the finishing share, 4 of every 8 ticks, measured by `erx_sched_finishing_step` and armed as a one-shot deadline, a kill of the running thread being a decision that asks it ([design-scheduler.md](design-scheduler.md#pick-and-dispatch)); the finishing level and the charge to the thread's own path's `finishing_ns` are the same |
| order among finishers and of a woken thread | Fiasco's `ready_enqueue` puts a woken thread, and one whose priority the kill raises, at the head of its level; a finisher keeps the slice it had | FIFO levels: a woken thread joins the tail (S7), and finishers rotate one tick each |
| a dying lock holder | helped as Fiasco helps any holder, on the helper's CPU and charged to the helper | never helped: a waiter waits for it as for a holder running elsewhere |
| a thread of a stopped space at its return boundary before its kill | holds in a boundary wait until the stop's kill reaches it | dies there at once |
| urgency resolution | stored and refreshed by every change before that call returns | derived at every decision |
| slices, deadlines and charges | at the 1 ms tick; a request pass on a CPU is charged to whoever runs there | one-shot timers |
| the direct switch | none: the server is picked by the scheduler at the sender's next decision | the same pick, in the dispatch |
| K33, a wait holds nothing | the funnel's waits hold nothing, and every ender calls `erx_wait_complete`; but the requester of a waited request holds `erx_object_ref` on its target across its answer wait, and a woken thread's frames carry Fiasco's call state, so a wake returns through them and never resumes the thread straight to user mode | nothing held across any sleep; the completion writes the result registers and may resume the thread from an interrupt handler |
| pauses and copies of spaces | `ERX_ENOTSUP`; the hold row never fires | in full |

## Alternatives considered

* **Deriving the count from Fiasco's state word.** Rejected: the thread
  state word's writers lose their owner at death, since `do_kill` calls
  `unbind()` before it sets Fiasco's `Thread_dead` bit and the thread's
  space is the kernel task from then on, and whole-record
  initialization writes the word
  outside them; a count that follows the state word also needs a unit
  for the stopper's walk, since a sleeping thread is uncounted, and a
  row per Fiasco transition. The live count has one entry, the
  creation, and one exit, the death edge, both under the space's lock.
* **A compare-and-swap loop on the run word.** Rejected: every writer
  holds the space's lock anyway, to join or leave the thread list, and
  the status must be written before the word moves; one lock makes the
  single transition and the waiter registration trivial.
* **Adopting the stopper's urgency for finishing threads.** Rejected: a
  later stopper at a higher urgency would need every finishing thread
  refreshed, and between two stoppers' urgencies a spinner could hold
  the second stop; a fixed priority above every urgency needs no
  refresh and no stopper's identity.
* **Fiasco's helping for finishing threads.** Rejected: `Switch_lock`'s
  cross-CPU helping is bounded by a lock hold, and while it lasts the
  helped thread's home CPU retries it at every preemption point
  (`Context::schedule`, `context.cpp:895`), which for a long call is a
  CPU spinning for the call's length; a helped thread's death must still
  run on its home CPU, so helping would not even complete the death.
* **Migrating finishing threads to the stopper's CPU and helping there.**
  Rejected: Fiasco's migration is a multi-step request protocol with its
  own hazards, and the gain over the finishing priority is none.
* **An early pick in place of the direct switch.** Left to G1: the
  ordinary path is one `deblock` and one `schedule()`, and a pick made
  early must include its candidate in the scheduler's choice, which
  `deblock`'s lazy form does not; the `ipc` benchmark decides whether
  the queue pass costs enough to justify it.
* **Waking stoppers in a chain, each waking the next.** Rejected: a
  waiter that is slow to run, or killed, would hold every waiter after
  it; the claimant wakes all of them in bounded parts.
* **Killing a stopped space's thread at its boundary without a
  request.** Rejected: the dying reference and the finishing priority
  would then be set in two places; holding the thread at its boundary
  until its kill gives every death one maker.
* **A synchronous `Cpu_call` per CPU for the stop's interrupt.**
  Rejected: `Cpu_call` names a CPU, not a thread, so a thread moving
  between CPUs could be missed, and the per-thread request already
  interrupts the thread's CPU.
* **A kick that dequeues the waiter from its queue.** Rejected: it would
  give the request one branch per wait kind; the waiter's own unlink on
  resume, after the membership check, FreeBSD's `umtxq_sleep` pattern,
  leaves the request uniform.
* **A stopper's wait the kill never ends.** Rejected: two spaces
  stopping each other would each wait for the other's death forever,
  and no finishing priority resolves a wait on a wait; a wait the kill
  ends, with the record posted by the last death alone, ends every ring
  of stops.
* **A waiter holding a reference on what it waits on.** Rejected: K33
  forbids a counted reference across a sleep, and the membership check
  under the CPU lock, which Fiasco's gates already make, costs one load
  and reaches the owner only while its teardown has not run.
* **The outcome written under a per-kind ordering lock.** Rejected: a
  receiver takes a sender on the receiver's CPU and the kill kicks that
  sender on the sender's, with no lock both can take; a lock in the
  wait record would nest inside the list's lock, a level the kernel's
  order does not have; one compare-and-swap on the outcome orders every
  ender without a lock.
* **The finishing share on the fork.** Rejected by the owner: the share
  bounds what a stream of kills takes from a CPU's user threads, a bound
  against hostile load that development builds do not run, and on the
  fork it would need a per-CPU record, a hook in `set_current_sched`, a
  kill that ends the current slice, a decision forced at the tick, and
  more changes still to Fiasco's queue placement and its eager-request
  path before its bound held; erXos's kernel has it, and the fork
  records the stream as a residual.
* **Leaving the walk to the first stopper.** Rejected: a stop that
  finds the space stopped and only waits relies on the first stopper's
  thread running again, which a zero quota or a descheduled thread can
  prevent for good, while walking again costs the later stopper one
  pass over the threads still unmarked and needs no new state.
* **Fiasco's three callback lists for the dying thread's wait, beside
  the stamped list.** Rejected: the budgets need the stamped list for
  puts and record frees in any case, so Fiasco's lists would be a second
  grace-period service to keep correct, and they ran a completed
  batch's callbacks in one pass under the CPU lock, a masked loop as
  long as the cohort; one stamped list with one step of 64 serves puts,
  record frees and dying threads alike and keeps every masked stretch
  short.
* **Keeping Fiasco's racing `Spin_lock`.** Rejected: under contention
  one CPU can lose the race for as long as the others keep winning, a
  wait without end that no test of trusted workloads would reliably
  find; the core's ticket lock, the lock erXos's kernel uses, replaces
  `Spin_lock`'s two architecture functions in one file, is tested once
  on the host for both kernels, and leaves only the order to check.
* **Charging a dying thread's time to its killer's path.** Rejected by
  the owner: the kill would carry the killer's path and take a counted
  reference on each of its groups, held to the dying thread's last
  switch, a second path per thread whose lifetime needs its own tests;
  the thread's own path, which it holds anyway, takes the charge, and
  `finishing_ns` keeps it apart from the stopped groups' usage.
* **Fiasco's unblocked queue for a sender woken at an unbound gate.**
  Rejected: it keeps a woken sender linked so that the gate's deletion
  can still reach it before the sender reads the gate again, a second
  list, a second detach at deletion and a continuation that depends on
  a pointer its sleep may have outrun; a send that starts over from its
  capability needs none of it, and the kernel design's send already
  tries again after the wake.
* **Draining a dying thread's request queue until it is empty, then
  closing it.** Rejected: other CPUs replenish the queue for as long as
  they like, and the drain runs with interrupts masked; closing first
  makes the cohort finite and lets the drain run in parts.

## Risks and open questions

Decisions that are the owner's, each with a recommendation:

1. **The return check on erXos's kernel.** The fork holds a stopped
   space's thread at its boundary until the stop's kill reaches it, so
   every death has one maker; the kernel design kills it there at once
   and lets the stop walk wake only the waiters. The cores differ in
   that row. Recommendation: adopt the fork's rule in the kernel design
   too, since the stop walk visits every thread of the space anyway and
   the rule gives both kernels one return check; until then the parity
   tests compare the traces with that row mapped.
2. **Transfer ownership in M5.** Recommendation: plan the pass before
   the handshake so that the step that holds the receiver stays one
   bounded step, on both kernels (**Transfer ownership**).

Decided by the owner: request handling is not charged to its requester
on the fork. A request's handler runs on the target CPU and the tick
charges it to whoever runs there; a sender's cost to a CPU is
one bounded handler per request, and as many requests per tick as its
round trips allow. The fork enforces no limit on that rate and records
it as a residual below; the flood case measures it, and G1 decides from that measure
whether erXos's kernel charges request handling to the requester's
group.

Risks: the one-tick slack on every deadline and slice is a measured
difference, not a correctness one, until a runtime depends on sub-ms
timers before M7; the stored priority leaves a window inside
`erx_group_configure` during which a thread may run at a stale ceiling,
within one call's length; and `erx_thread_exit`'s teardown runs at the
finishing priority too, bounded by the senders and bindings the thread's
budget paid for.

Decided by the owner: the fork has no finishing share (**The finishing
share on the fork** in **Alternatives considered**).

Three residuals are recorded rather than bounded, each acceptable only
because development builds run trusted code. The first is the stream
of kills: a domain that creates threads homed on one CPU and kills
them, for as long as its budget pays for the records, holds that CPU's
user threads back, the root task's petting thread among them, for as
long as the stream lasts (**Security**); erXos's kernel bounds it with
the finishing share. The second is the number of device interrupts a
CPU takes per tick. Each is one bounded step of the hit
path, and a level-triggered line is masked at its hit until its holder
unmasks it, so its rate is its holder's; but an edge-triggered line
fires at its device's rate, which the configuration that gave the
domain the device and routed its line sets and nothing in this binding
bounds. A device whose edge-triggered line fires
faster than its CPU serves it takes that CPU from every thread on it.
This is the same on erXos's kernel; it is a property of the system
manifest, whose build check is where a bound on it belongs. The third
is the number of cross-CPU requests a CPU takes per tick. The queue
holds at most one request per thread and one visit per context, an
entry runs at most `ERX_REQUEST_BATCH` steps, and each step is
bounded; but a requester sends again as soon as it has its answer, so
the entries a CPU takes in a tick follow the requesters' round trips,
which nothing in this binding bounds. The flood case measures the
cost. It is the same on erXos's kernel unless G1 has that kernel charge
an entry to its requester's group.

## References

* [design-kernel.md](design-kernel.md): K12, K13, K14, K18, K26, K27,
  K30, K31; Execution model and locking; Threads and faults; IPC gates;
  IRQ objects; Umtx; Closing and deleting; the stopgap's scope table.
* [design-scheduler.md](design-scheduler.md): S1 to S9; Urgency
  resolution; Pick and dispatch; Charging and quota; Park and wake;
  Executor class enforcement; Ownership and lifetime; Verification.
* [design-stopgap.md](design-stopgap.md): Transport; Capabilities in
  Fiasco's object space; Deletion; IPC gates, and where transfer fits;
  Faults, and the fault of the root task; the benchmarks.
* [plan.md](plan.md#m1-the-stopgap-speaks-erxoss-interface): M1's
  scope, exit criteria and gate G1.
* Fiasco sources under `fiasco/kernel/src/kern/`: `context.cpp`,
  `thread.cpp`, `thread-ipc.cpp`, `thread_object.cpp`, `ipc_gate.cpp`,
  `ipc_sender.cpp`, `irq.cpp`, `sched_context.cpp`,
  `sched_context-fixed_prio.cpp`, `ready_queue_fp.cpp`,
  `switch_lock.cpp`, `timeout.cpp`, `ipc_timeout.cpp`,
  `timeslice_timeout.cpp`, `thread_state.cpp`, `arm/64/ivt.S`.
* FreeBSD's `_umtx_op`, `umtxq_sleep`: the waiter's own unlink on
  resume, after it checks that it is still queued.
