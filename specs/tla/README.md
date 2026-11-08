# Model gate

`make check-tla` runs TLC separately from ordinary host checks. Run
`make fetch` first; checks never download tools. `TLA_TOOLS_JAR` selects a
jar location, whose bytes must match the `tla-tools` pin in `deps.lock`.
`JAVA` selects the installed JVM executable. On a Homebrew host whose JVM
is not on PATH, set it to the installed `openjdk/bin/java` path.

`TLA_JOBS` controls independent configurations and `TLA_WORKERS` each TLC
process. `TLA_JVM_MEM` accepts MiB (an integer or `m` suffix) and GiB (`g`);
the default is 512 MiB, with at most 8 GiB of aggregate configured Java
heaps. Native JVM/fingerprint-table overhead is additional. Every run has
its own metadata and Java temporary directory and a hard deadline.

Use `tools/erx check-tla --filter TEXT` to select matching configuration
ids; an empty selection is an error. The complete roster is validated
before filtering, including unselected entries. Each configuration occurs
exactly once. `TLA_NO_CACHE=1` or `--no-cache` forces a fresh check.

Cached results bind all snapshotted model/configuration/roster bytes, the
expectation, flags, runner code, jar hash and JVM identity. Original inputs,
command records and raw logs remain evidence. Missing or changed evidence
causes a fresh check. Failed, incomplete, expired and cancelled checks
never become successful cache entries.

The runner classifies the pinned tool's framed diagnostics and exact exit
status. An expected safety counterexample names its invariant exactly.
TLC does not say which temporal property a behaviour violates, so an
expected temporal counterexample names its property and the runner
requires the configuration to declare exactly that one. An expected
deadlock names nothing and needs deadlock checking and no temporal
property, so no liveness check can report the same stall first. Every
configuration that declares a temporal property runs with deadlock
checking ([design-verification.md](../../docs/design-verification.md)),
and its model has an explicit terminal step for the one state where
stopping is correct. A parser error, wrong invariant, other diagnostic,
memory failure or interrupted search fails the gate.
Initial-state and transition violations have distinct tool diagnostics.
Reports retain declared finite or constrained scope; completing a bounded
model is evidence about that model, not execution of erXos code.

`RunnerSmoke` checks the runner itself. Its variable ranges over three
states in the good configuration, four before the broken configuration's
counterexample, and an intentionally bad initial state. The reachability
configuration falsifies `NotReached` at state 2. These fixtures establish
classification, completion and cache behavior; they assert no operating
system protocol property.

## Connection models

Three models check the connection protocol of
[design-domains.md](../../docs/design-domains.md) before connections run
under QEMU. Each has a good configuration, configurations that seed one
defect each and must fail on the named property or the deadlock check,
and a reachability witness for a path that could otherwise go
unexercised. Each model's terminal step accepts only the state where
everything owed is done, so a stop anywhere else fails the deadlock
check. Fairness covers only the steps the protocol owes; what a peer, a
process or a policy chooses to do is never assumed to happen. `MAPPING.md`
maps every property to the code and tests that carry it.

Each scope is a constant of its model (the records, the frames, the
initiating steps), not a TLC state constraint, so TLC explores every
behaviour of the bounded model and the roster reports the scope as
finite. A pass is evidence about that bounded model only.

**`Lane`**, a mechanism model of one lane: every load and store of `wpos`,
`rpos`, `wake` and `need` is a step of its own, under sequentially
consistent interleaving. A missing fence is modelled as the load that
follows a store performed before it, the one reordering a full fence
forbids here; whether the hardware keeps the fences' order is herd7's
question, not TLC's. Positions count 16-byte units. Each party's program
counter (`ppc`, `cpc`) names its next step; the module lists the values.
Scope: an eight-unit lane, three records of one, ten and two units (the
second longer than the lane, so it is written and read in parts across
the wrap), the producer writing and the consumer copying any number of
units per step, and a producer that waits for room for the rest of its
record or a quarter of the lane. The good configuration checks that
`rpos` never passes `wpos`, nothing is overwritten unread, what is copied
in parts is what was written, no wait is lost (both parties at rest only
once every record is through), a party rings only on a crossing (at most
once for each wait the other stored), and, under weak fairness of each
party, that every record is eventually copied. Seeds drop each of the four
fences, ring only on a strict crossing, ring after every store, or count
one unit too much room; `lane-stall` shows the deadlock check alone
catches a lost wake.

**`Connection`**, an abstract protocol model of domain A and two
incarnations of one peer node name, the later one started once the first
has ended. A lane is a count of frames. The domain service queues the
control records about the name for A and sends them one at a time, each
once A answered the last, and a later domain's `connection_up` only once
the earlier connection's `connection_down` has gone out. It tells the
peer its own `connection_up` and `connection_down`, and deletes a
connection's objects once each party has let go or ended. A connection
ends when the peer ends, when either runtime ends it, or by the service's
policy while the peer may still be writing; A drains, fires, unmaps and
answers. Each peer step reads only the peer's own state and the records
sent to it. Scope: two frames each way on each connection. It checks that
A acts on an ended peer only after every frame it published, delivers
nothing after the down and in order, that no party maps a deleted object,
at most one control record is outstanding, A never has two connections up
for the name, the types of every variable, and, under weak fairness of
the service and of A alone, that A and the service settle. Seeds fire
before draining, delete without A's answer, send without waiting for the
answer, answer before unmapping, let a later `connection_up` overtake the
earlier `connection_down`, drain to a frame an ended peer may never write,
wait for the peer's unmap, answer a record never sent, and deliver after
the down.

**`Links`**, an abstract protocol model of three domains with one process
each, a FIFO lane per ordered pair, messages, links, monitors, `exit/2`,
process deaths, a domain's end, a connection ended from inside, and forged
answers about another domain's process. Scope: three initiating steps,
with process 3 exported to nobody, and three steps over the one-way pair
alone (`links-half-link`). Frames carry stamps, so the check that every
answer about a process arrives after everything that process sent the
holder before the answer was made is a state invariant; under weak
fairness of every runtime's receive and drain, every live holder of a link
or monitor of a dead process is eventually answered. `Receive`'s comment
lists what a runtime does with each kind of frame. A runtime answers a
`LINK` with `noproc` only when its process holds no link with the sender,
so a link two processes make towards each other is never left with one
half; the lane's order puts a refusal ahead of any `LINK` the target
writes afterwards, so the holder drops its half and then makes it again.
Seeds fire before draining, accept an answer from another domain's lane,
put `noproc` ahead of queued frames, drop a link or monitor of a dead or
unexported process, and answer `noproc` to a `LINK` from a process the
target already holds a link with.
