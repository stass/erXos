# Domains, processes and messages

A protection domain is a wall around some processes. Inside the wall, the
domain's runtime (ERTS, or `liberx` for native code) runs its processes and
passes messages among them exactly as ERTS always has, without the kernel.
Across the wall, one pid space, one message system and one set of failure
semantics span every domain. This document specifies how: a pid names its
owner domain by construction, so no registry is consulted to spawn; two
domains that have been introduced share a **connection**, two one-way lanes
of shared memory on which every signal between them travels, with no third
party in between; each runtime validates what arrives with one **funnel**
and checks it against its own **export table**, which says which of its
processes each peer may signal; links, monitors and exits keep Erlang's
semantics across domains with no record per process outside the owning
runtime; and every page a domain reads is paid for by that domain. The
architecture is in [design.md](design.md); runtimes and the ERTS adapter in
[design-runtime.md](design-runtime.md); the kernel's objects in
[design-kernel.md](design-kernel.md); CPU groups and grants in
[design-scheduler.md](design-scheduler.md); the system domain, the domain
library and domain creation in [design-system.md](design-system.md); the
inspector and the console in [design-live.md](design-live.md).

Decisions every reader of this document needs:

* **Every domain is a node, and a pid carries its owner.** Each domain is
  an Erlang node named by its identifier at the machine's host name,
  `web@erxos` or `system@erxos`, with its domain id as the node's
  creation. A connection between two domains is a stock distribution
  connection between their nodes, so `node()`, `nodes()`,
  `monitor_node/2`, `erpc` and the `rpc` calls that spawn keep stock
  semantics, within the authority the two domains export to each other;
  registered names, and with them `global`, `pg` and the tools that send
  to `rex`, stay within each domain, and no tick
  supervises a connection. A pid is its owner's node name and creation
  with a number and a serial; domain ids are never reused within a boot,
  so a pid never names two processes, and a runtime allocates pids from
  its own process table with no call to anyone. The one difference in how
  identity looks is the user's decision: a pid prints as `<D.N.S>`, with
  its owner's domain id, in every domain. A domain that other machines
  reach keeps its node name on the network
  ([design.md](design.md#networking)).
* **Introduced domains share a connection; nothing stands between them.** A
  connection is two lanes, one per direction. A lane is a ring that the
  sending domain alone writes, a reader page that the receiving domain alone
  writes, and a doorbell, an IRQ object bound to the receiver's group that
  the sender may only ring. The system domain creates a connection when it
  introduces two domains, in the cases [Introduction and connection
  down](#introduction-and-connection-down) lists, and it alone can delete
  one. Every page of a connection between two domains is charged to a
  child budget, one per connection, of the outer budget of the domain
  that reads it, so a sender never makes a receiver pay for what the
  receiver is willing to take, and the receiver's policy sizes the lane
  it reads; a domain's connection to the system domain is charged
  wholly to the domain's.
* **Identity is the lane.** A receiver knows the sending domain by the lane
  a frame arrived on; no field of a frame is trusted for identity, and a
  frame whose sending pid names another domain is malformed.
* **The funnel is the receiver's.** Each runtime copies a frame out of the
  lane once, into private memory, before it looks at it; validates its
  structure with a bounded, iterative, positive grammar and its authority
  against the domain's own export table; and decodes it, in the system
  domain in ERTS's safe mode, which never creates an atom. The funnel is one
  C17 library in `liberx`, linked by every runtime.
* **A pid is a name, not an authority.** Who may message, link to, monitor,
  exit or spawn into a domain's processes is that domain's export table,
  which its own runtime alone writes, in exactly three cases: when it
  encodes one of its own pids or aliases into a frame for a peer, which
  gives the peer `send`, enough to message, call and monitor the process;
  when a peer spawns a process into it, which gives the spawner every right
  on the child; and when one of its processes exports a name explicitly,
  the only way a peer comes to hold `link` or `exit` on any other process.
  No peer widens what it holds, and a peer that passes a name on gives the
  third party nothing. To a peer, a process it holds no export of behaves
  exactly like a dead one, answered by the target's own runtime behind
  everything that runtime sent before. A privileged service acts on a
  target only through a handle its facet minted from the facet's own scope,
  never from a name a request carries.
* **A domain speaks only for its own processes.** A runtime can report the
  exit only of its own processes, and a receiving runtime acts on an exit or
  `DOWN` only for a link or monitor it holds. When a domain ends, the system
  domain tells each of its peers, and each peer drains what the dead domain
  published before it fires its own links and monitors.
* **Flow control is the ring.** A sender whose lane is full waits in its own
  runtime, in its own memory; in ERTS that is the busy rule stock
  distribution already has, so a call to a stalled peer blocks the caller
  and nobody else. A receiver drains a lane at its own pace and spends its
  own CPU validating what it drains. A malformed frame ends the connection
  from the receiver's side, and the peer sees `noconnection` on everything
  it had across that connection; a domain whose connection to the system
  domain ends is stopped, since it has no services without it. That is the
  whole protocol-error rule.
* **Stopping a domain never needs its runtime.** The kernel stops a domain
  whatever it is doing, and the kernel's rule that a space never outlives
  its parent ends every domain with the system domain. A `kill` of one
  process is carried to the target's runtime, which honours it as ERTS does;
  stopping the domain is the enforcement that depends on nothing the runtime
  says.
* **Nobody runs on another's CPU.** A receiver validates and decodes on its
  own grant; a facet in the system domain runs on the system domain's grant,
  capped by policy, and admits its grantee's requests only within the
  grantee's share of measured reductions per period. What the system domain
  holds for a domain is a sum fixed when it admits the domain: the lane it
  reads from the domain, the one record it is reading, its queue to the
  domain, what it holds for the domain's processes and each facet's queue
  quota and `max_heap_size` ([Flow control](#flow-control)).
* **Four transports, one model.** Messages inside a runtime never leave it;
  messages between domains are frames on connections; native code that
  needs no Erlang semantics calls through the kernel's IPC gates, within
  one domain and its sub-spaces, since no domain holds a gate of another;
  and a program's channel and its pipes are rings of the same layout as a
  lane, between a session and its sub-spaces
  ([design-programs.md](design-programs.md#the-channel),
  [design-pipes.md](design-pipes.md#the-ring)). Only frames carry pids.
  Every wake-up between spaces is an IRQ object, bound to the side that
  waits and rung by the other.
* **A sub-space belongs to its domain.** A domain may build address spaces
  of its own ([design-kernel.md](design-kernel.md#creating-spaces)). A
  sub-space has no domain id, pid, export table, facet or connection; what
  runs in it is paid for by its domain and ends with it. A native program is
  a sub-space of its session and a port of the session's runtime
  ([design-programs.md](design-programs.md#a-program-is-a-port)).

## Context

The architecture runs every runtime in user mode in a domain of its own,
with the system services in the system domain, also in user mode
([design.md](design.md)). The kernel schedules threads within groups'
grants, and each runtime schedules its own processes
([design-scheduler.md](design-scheduler.md)). The architecture still
promises one process space, one message system and one view of identity,
supervision and inspection, with no kernel thread, kernel object or kernel
call per process and no system call between processes of one domain. And
it makes every domain an Erlang node of its own, so an application placed
across domains behaves as one placed across connected nodes.

ERTS was not written for this. Nearly every naming and identity space in it
is node-global: atoms, loaded code, exports and funs, registered names, ETS
names, persistent terms and the process table, several of them limited
tables whose exhaustion stops the emulator
([research](research-erts-internals.md#census-of-node-global-state)). A
local pid is forgeable from bare numbers and is the only credential that
`exit/2`, `process_info/2`, `suspend_process/1` and their kind check
([research](research-erts-internals.md#inspecting-and-controlling-another-process)).
Loaded code is trusted completely
([research](research-erts-internals.md#loader-trust)). A domain is therefore
the unit of trust, and its boundary must sit where ERTS's global state
cannot leak across.

Three facts of ERTS shape that boundary. ERTS has no single local enqueue
funnel: messages, non-message signals, NIF sends and timers reach a
receiver's queue through different functions
([research](research-erts-internals.md#sending-and-copying)). By contrast,
every operation on a remote pid, port or alias already goes through one
function, `erts_dsig_send` in `dist.c`, as a control tuple whose first
element names one of a closed set of operations
([research](research-erts-internals.md#distribution)), and every byte a
remote node sends enters through one function, `erts_net_message`. And ERTS
already gives every pid, reference and port a node and a creation, and
decides locality by comparing them with its own
([research](research-erts-internals.md#pids)). erXos puts the domain
boundary where ERTS already has one, puts domain identity where ERTS already
keeps node identity, and puts a lane where ERTS has a socket.

Prior systems bound the choices. Safe Erlang made pids into capabilities
with rights and gave each subnode its own tables; KaffeOS charged each
process for the kernel memory used on its behalf; Zircon removed ambient
authority; Singularity measured crossing costs that make a chatty boundary
expensive ([research](research-prior-art.md#lessons)). The proposal this
design follows asks for a process registry in trusted services, "without a
kernel TCB or syscall for every lightweight spawn", with "PID ranges and
lifecycle events ... delegated and batched"
([research](research-hierarchical-scheduling.md#identity-and-lifecycle)):
here the range is a whole domain id, delegated once at creation, and a
domain's death is one event per connection.

## Requirements

Functional requirements:

1. **One pid space.** Any process can hold the pid of any other process. A
   pid prints, compares, hashes and orders identically in every domain, and
   never names a second process.
2. **Every domain is a node.** `node()` is the domain's own node name,
   `nodes()` lists the domains it is connected to, and `monitor_node/2`,
   `erpc` and the `rpc` calls that spawn behave as between connected
   stock nodes, within the authority the domains export to each other.
3. **Erlang message semantics across domains.** Sends are asynchronous and
   never fail at the sender. Signals from one process to another arrive in
   the order sent. Selective receive, aliases and `receive ... after` work
   unchanged inside each domain.
4. **Erlang failure semantics across domains.** Links, monitors, exit
   signals, `trap_exit`, `exit/2` and `kill` behave as between two connected
   nodes, with exit reasons preserved.
5. **Spawning into another domain**, with `link` and `monitor` established
   atomically with the spawn, as ERTS's distributed spawn promises.
6. **Domain lifecycle.** A principal creates domains within its quotas and
   stops them. When a domain dies for any reason, every link and monitor to
   its processes fires with `{domain_down, D, Info}`, and its resources
   return to the budget that funded them.
7. **Per-domain runtime state.** Each domain has its own atoms, loaded code,
   ETS tables, registered names, persistent terms and unique integers;
   nothing a domain does to them is visible in another domain.
8. **Capability discipline.** Authority over another domain's process comes
   only from that domain's own runtime, by spawning, by handing out a name,
   or by an explicit export, and never grows in transit.
9. **Inspection.** The system domain can inspect every domain; other domains
   inspect what their facets allow. A session inspects its principal's own
   domains, except that in a development build `root`'s session inspects
   every domain, as the host link does; in a release build machine-wide
   inspection is the system shell's, at a secure line
   ([design-live.md](design-live.md#inspection)).
10. **Accounting.** Memory, CPU time, exports and queued frames are bounded
    per domain and charged to principals' budgets.
11. **Native domains** take part in sends, links, monitors and exits without
    an Erlang heap, through the same lanes and the same funnel.

Non-functional requirements:

* **Same-domain cost is stock ERTS's.** A message between two processes of
  one domain involves no one but the runtime, apart from waking a parked
  executor.
* **Cross-domain cost is one copy, one hop and at most one kernel call.** A
  frame is written once into a lane and copied out once; it crosses one
  thread boundary, from the sender's executor to the receiver's; and it
  costs a kernel call only when the receiver is waiting for it. The budgets
  in [Performance](#performance) are targets that experiments E-D1 to E-D4
  confirm or revise.
* **No peer's input can crash, wedge or exhaust a runtime beyond what that
  runtime allowed.** Every frame is validated with bounded work and bounded
  memory in the receiver, the memory it holds for a peer is bounded by its
  own limits, and a malformed frame costs the receiver nothing but the
  connection.
* **No receiver can hold up a sender's traffic to other receivers.** A full
  lane stalls only the senders to that lane.
* **Compatibility.** OTP applications run unmodified inside one domain, and
  an application placed across domains behaves as one placed across
  connected nodes. The differences visible across domains form a closed,
  tested list ([Compatibility](#compatibility-and-migration)).

Non-goals:

* Distribution to other machines, which builds on the network service: a
  domain that other machines reach keeps its node name on the network,
  under the rules of [An exposed domain](#domain-ids-pids-and-references),
  and [design-network-stack.md](design-network-stack.md#distribution-to-other-machines)
  defines the carrier that serves those connections, OTP's TLS carrier
  in release builds ([design.md](design.md#networking)).
* Moving a live process between domains.
* Sharing ETS tables, persistent terms or reference-counted binaries across
  domains. Cross-domain data, bulk data included, is copied through
  connections; no domain maps another's memory but a connection's.
* Confidentiality between processes of one domain. Mutually distrusting code
  belongs in separate domains, because no boundary inside one address space
  survives speculative side channels
  ([research](research-prior-art.md#other-systems)).
* Per-process enforcement inside a domain by anyone but its runtime. A
  domain's processes are as trustworthy as its runtime.

## Overview

```text
  domain "web", node web@erxos, id 7                 domain "db", node db@erxos, id 9
 +-------------------------------+                          +-------------------------------+
 | ERTS                          |   connection 7 <-> 9     | ERTS                          |
 |  Q <7.300.0>:  R ! Msg        |                          |  R <9.41.0>:  receive Msg     |
 |  R is remote: the peer        |   lane 7 -> 9            |                               |
 |  encodes {22, Q, R} and Msg   |  web's ring ------------>|  funnel: copy once, grammar,  |
 |  into web's ring, stores      |  (db pays for it)        |  sender rule, db's exports,   |
 |  wpos, rings db's bell only   |  ---- bell(db) ------->  |  decoded size; then           |
 |  if db said it waits          |                          |  erts_net_message, queued on R|
 |                               |   lane 9 -> 7            |                               |
 |  funnel <---------------------|<------------ db's ring   |  db's peer writes replies,    |
 |  (web pays for it)            |  <------ bell(web) ----  |  exits and DOWNs here         |
 +-------------------------------+                          +-------------------------------+
     the system domain made the connection, holds its delete right, and carries none of its frames
```

A message from Q in domain `web` to R in domain `db`:

1. Q executes `R ! Msg`. R's pid carries node `db@erxos`, not `web`'s own
   name, so ERTS takes its remote path: `erts_dsig_send` builds the
   control tuple `{SEND_SENDER, Q, R}` on `web`'s distribution entry for
   `db@erxos`, whose controller is the connection. The peer encodes it and
   `Msg` into a frame in `web`'s ring of the lane to `db`, publishes it by
   storing the ring's write position, and rings `db`'s bell only if
   `db`'s reader page says `db` is waiting for that position. Encoding Q,
   a pid of `web`'s own, into the frame writes an export of Q toward `db`
   with `send` in `web`'s export table, so R can answer and monitor Q, and
   nothing more. Without room in the lane, the frame waits in the entry's
   queue in `web`'s runtime, and Q is suspended as a sender to a busy
   connection only when that queue is long.
2. The bell schedules the input task of `db`'s lane port, which copies
   the frame out of the lane once, into `db`'s private memory, and runs the
   funnel on the copy: the lane's positions and the record's header, the
   control grammar, the sender rule (Q carries `web@erxos` and 7, the
   lane's domain), the target (R is a process of `db`, and `db`'s export
   table gives `web` the send right on R, or R was never exported and the
   frame is dropped as for a dead process), and the payload's structure
   and decoded size against `db`'s limits.
3. The funnel hands the frame to ERTS's distribution input,
   `erts_net_message`, on the connection's entry, which queues it on R
   encoded. R completes the funnel's semantic stage, including exact map-key
   checks, when its `receive` reaches the payload and decodes it.
4. `db` stores the lane's read position past the frame, which returns the
   room to `web`, and rings `web`'s bell only if `web`'s ring header says
   `web` is waiting for that much room.

A message between two processes of one domain never leaves the runtime; if
the receiver's scheduler is parked, the runtime wakes it with one kernel
call ([design-runtime.md](design-runtime.md#liberx)).

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **D1.** A pid never names two processes | a pid is (node name, creation, number, serial), and a domain's node has its domain id as creation, which the domain service never reuses within a boot; within a domain, ERTS's process table never hands out a live (number, serial) twice ([Domain ids, pids and references](#domain-ids-pids-and-references)) | a domain id reused; a domain's node started with a creation other than its id; a runtime that reuses its own pids, which confuses only that domain's own correspondents about that domain's own processes | a test that creates and destroys domains in a loop and checks that ids increase and that each domain's `erlang:system_info(creation)` is its id; ERTS's own process-table tests |
| **D2.** A node name at the machine's host name belongs to one live domain at a time and is reached only through that domain's connection; a runtime treats a pid or reference as its own exactly when it carries the runtime's node name and creation | the domain service gives a name to no domain while a live domain holds it; the connection agent alone serves node names at the machine's host, and makes an entry for one only from the system domain's `connection_up`; the sender rule requires every sending pid on a lane to carry the lane's node name and domain id; the network carrier refuses a remote node that presents a name at the machine's host ([An exposed domain](#domain-ids-pids-and-references)); ERTS's decoder and constructors already compare both name and creation with the local node's | two live domains with one name; an entry for a name at the machine's host made from anything but `connection_up`; a remote node admitted under such a name; a constructor that ignores creation | a property test: for random pids and references of other domains, `list_to_pid(pid_to_list(P)) =:= P` and `list_to_ref(ref_to_list(R)) =:= R` in every domain, and both stay remote; a test that creating a domain under a live domain's name fails, and that a later domain of an ended domain's name gets a new creation, under which the earlier pids behave as dead; the network service's test that a remote node presenting a name at the machine's host is refused |
| **D3.** Every frame a runtime accepts passed its funnel | a runtime reads a lane's ring only through the funnel's reader, `erx_lane_take`, which copies a frame out once before anything looks at it, and every path into ERTS's distribution input or a native domain's mailboxes is a return from the funnel's check | a second reader of a lane's ring; a path that queues a frame the funnel did not return | a build check that a lane's pages are read only by `erx_lane_take`, in `erx_lane.c`, with a negative fixture, and one that only the lane driver calls `erts_net_message`, with a seeded violation; the fuzz target drives the funnel with every record and term shape |
| **D4.** A name alone conveys no authority | an operation on a process is authorised by the target domain's own export table, which its runtime alone writes, in three cases, each an act of the owner: encoding its own name into a frame for that peer, which gives `send` alone; a spawn into it, which gives the spawner every right on the child; and an explicit export, the only source of `link` and `exit` otherwise and of `introduce` on a domain pid ([Exports](#exports)); a registered name is never exported, and the sender's runtime keeps every operation on another node's registered name to itself ([Frames](#frames)); nothing a peer does widens what it holds; a missing export gets dead-process semantics; a name a third domain passes on exports nothing; a privileged service's helpers take only handles its facet minted from its own scope ([Authority](#authority)) | an export written by anyone but the owning runtime, or from a name in a received frame; an encoding that gives more than `send`; an operation that takes a raw pid as authority; a helper that acts on a request's name | the three writers of the export table are the only callers of its insert, which a build check enforces; hostile-runtime tests that forward names, forge senders, name unexported pids, and link to, exit and set the group leader of pids they were handed in replies; a build check that service callbacks reach authority-consuming effects only through generated helpers, with a negative fixture |
| **D5.** The system domain's atom table grows only within bounds its own policy sets: no frame creates an atom, and the domain service makes an atom only of a domain's node name, within the creating principal's `names` quota | the grammar for frames to the system domain has no fun or export tag, and the system domain's peer decodes every frame in ERTS's safe mode, which never creates an atom; the domain service binds a name to one principal for the boot, counts it against that principal's `names` before it makes the atom, and reuses the atom for every later domain of that name ([Domain ids, pids and references](#domain-ids-pids-and-references)) | a decode of another domain's bytes in the system domain outside the peer, or without safe mode; a service that turns request data into atoms, a name made into an atom before its quota check included | a test that a frame with a fresh atom leaves the system domain's atom count unchanged; the fuzz target checks the count after every input; a test that a principal past its `names` creates no domain under a fresh name and leaves the count unchanged; a build check that system-domain code calls atom-creating functions only from an allowlist |
| **D6.** A domain reports deaths only of its own processes | the receiver knows the sender by the lane; the sender rule requires every frame's sending pid to carry the lane's node name and domain id; a receiving runtime acts on a link exit or `DOWN` only for a link or monitor it holds, which ERTS already checks | a frame accepted with another domain's sending pid | hostile-runtime tests that forge exits and `DOWN`s for other domains' processes and for processes they are not linked to |
| **D7.** Stopping a domain never needs its runtime | the kernel's `erx_space_stop` stops every thread of a space at once, and the spaces below it stop with it ([design-kernel.md](design-kernel.md#creating-spaces)); a holder of the exit right on the domain pid stops the domain through the system domain, which needs nothing from the domain | a stop path that waits for the runtime | tests that stop a domain whose runtime never returns, runs a long NIF, or never drains its lanes |
| **D9.** Signals from one process to another arrive in the order sent | a runtime writes each sending process's frames for one peer into one lane in send order; a lane is a single-producer, single-consumer ring, read in order; `erts_net_message` keeps order per connection; every answer about a process comes from its own runtime, on the same lane behind what it sent before | a path that reorders one pair's frames; an answer about a process written by anyone but its runtime | a property test that interleaves sends, links, monitors of dead and unexported processes, links to processes held without `link`, and exits between three domains and checks per-pair order |
| **D12.** What a peer can make a runtime hold is bounded by the runtime's own limits, and what a domain can make the system domain hold is a sum fixed when the domain is admitted | the lane a receiver reads is sized by its own `lane`; an open record's private buffer grows as its bytes arrive, up to the receiver's own `max_frame`, never allocated whole on a header's word; a decoded term by its `max_message_heap`, or by the target process's own request limit; what its processes keep queued and undecoded by their queue quotas, past which the funnel leaves the next frame for them in the lane, and, for a process without one, by its own `max_heap_size`; the links and monitors it holds with a peer's processes, and the signals it queues for them, by its `peer_held`, past which it ends the connection; its queue to a peer that does not drain by ERTS's busy limit, past which its senders wait, and in the system domain by `system_queue`, past which a message is dropped and any other signal ends the connection; its export table by its `exports`; atoms, funs and exports by its `foreign_atoms`; the system domain's sum per domain is [Flow control](#flow-control)'s | a delivery path that skips a check; a buffer the receiver allocates on a peer's say-so without a bound of its own; a queue in the system domain that grows while a domain does not drain; a funnel that queues a frame on a process at its quota | floods past every limit from many peers at once, and records whose bytes trickle in; the receiver's memory stays within its budget, and the system domain's within the sum per admitted domain |
| **D13.** A stale export costs nothing to find | an export's holders live on its name's own record, the process or the active alias, and go with it, at the transition that ends the process or deactivates the alias; a peer's holders end when the connection goes down; a pid names its process by number and serial, so a lookup that finds no live record finds no holder | holders kept anywhere but on their name's own record; an entry keyed in a way a later process can match | a soak test of a million alias exports and deactivations from one live process, with every OTP alias mode, and of pids handed out by processes that then exit; the export table stays at its live names |
| **D16.** Every page of a connection has one writer, is charged to a child budget of an outer budget, one child per connection, that the system domain destroys only once both parties have let go: the reader's outer budget for a connection between domains, the domain's for its system connection; and only the system domain deletes it | each party writes exactly one memory object of a connection and maps the other's read-only; the system domain carves the connection's children and creates both sides and both bells from them, and gives each party its capabilities without `DESTROY` ([Connections](#connections)); it deletes a connection's objects and destroys its children only once each party has unmapped them or ended, never on a timer while a party lives, and destroys an ended domain's outer budget only once none of its children remains | a page both parties write; a capability with the delete right in a party's table; a lane charged to its writer, to the budget its reader alone maps, to the system domain's own budget, or to an outer budget directly; a deletion while a party that has not answered still maps it | a test that each party's table holds no delete right on a connection's objects; budgets return to their baselines after every test; a hostile peer that rewrites its pages while the other reads them disturbs nothing but its own frames; a survivor that never answers `connection_down` keeps the connection's objects, counted against its own `connections`, never faults on them, and keeps of the ended domain's outer budget only that connection's child, which a test that reads the budget's charge after the end checks; seeded failure: a connection charged to the outer budget directly, under which the survivor keeps the whole outer budget |
| **D17.** A domain's end reaches each peer behind everything the domain published on their lane | the kernel posts a space's exit record only when no thread of it can run, so the dead domain's write position is final; a runtime told that a connection is down first drains that lane to the position it reads then, waiting on nothing the dead domain would have to do, and only then fires its links and monitors with the peer's processes | a runtime that acts on a connection down before draining; a stop reported while a thread can still run | a test that kills a domain mid-burst on every CPU and checks that each peer sees the burst, then the death |

## On the stopgap

Until erXos's kernel is written, domains and their connections run on the
stopgap Fiasco behind the same kernel interface
([design-stopgap.md](design-stopgap.md)). Everything this document
specifies above `liberx` is the same code on both: the domain service, the
funnel, the peer, exports, introductions, the wake handshake and the
domain library's creation plan. What stands behind the kernel calls is a
row of [the stopgap's call table](design-stopgap.md#the-call-table) each:

* a connection's sides are memory objects of the root task's pool, which
  the domain library creates and passes; each party's `liberx` maps its
  own side writable and the peer's read-only, a request the root service
  performs at the rights asked for, and destroying a side revokes it in
  every task that maps it
  ([Sharing memory between tasks](design-stopgap.md#sharing-memory-between-tasks));
* a bell is an IRQ object that the domain library creates and binds to
  the consumer's group, whose deliveries reach the consumer task's
  readiness dispatcher, and any holder triggers it
  ([Interrupts and readiness](design-stopgap.md#interrupts-and-readiness));
* the domain library installs a connection's objects into both parties
  with `erx_cap_pass` from its own table into a space it created
  ([Passing a handle](design-stopgap.md#passing-a-handle)); passing at an
  IPC rendezvous stays refused, and no connection needs it;
* a domain's space is a Fiasco task that the root service creates with its
  parent recorded and ends with its sub-spaces, children first; its exit
  record carries the exit status, or `crash`
  ([Spaces, parents and exit records](design-stopgap.md#spaces-parents-and-exit-records));
* budgets and groups are records with nothing charged or enforced, and
  every field of a domain's budgets, `used` included, reports `unsupported`
  ([Budgets and groups as records](design-stopgap.md#budgets-and-groups-as-records)).

D1 to D7, D9, D13 and D17 hold on the stopgap for every domain whose
runtime goes through `liberx`. D1 to D6, D9 and D13 rest on user-mode code.
D7 and D17 rest on the stop, which the root service carries out without
the runtime: it deletes every thread of the space and of the spaces below
it, and posts the exit record only after the last deletion has returned,
so a dead domain's write position is final when its end is reported. What
the stopgap lacks there is a bound on how long a stop takes, since the one
service thread carries it out among every other request (K18); that bound
and the tests under hostile load are erXos's kernel's
([What Phase 1 defers](design-stopgap.md#what-phase-1-defers)). D12's
limits are the runtime's own and hold, but the memory they bound is
charged to budgets that are records, so D12's assertions about budgets
report `unsupported`. D16 holds in part: each side has one writer because
the reader's `liberx` maps it read-only, and only the system domain
deletes a connection's objects, since only an object's creator may destroy
it; its charging to child budgets is recorded, not enforced. Nothing on the
stopgap holds a domain that bypasses `liberx` and calls Fiasco itself, or
maps a side writable it should only read; development builds run trusted
code only.

The tests of [Verification and testing](#verification-and-testing) run on
the stopgap with three limits. The hostile runtimes run, and their verdicts
on frames (what the funnel accepts, refuses and decodes, and what a forged
sender or name gets) count; their bounds on memory charged to a budget, on
CPU grants and on an innocent peer's latency report `unsupported` and are
checked on erXos's kernel. The check that no party can delete a
connection's objects passes through the creator-only destroy, since a
handle on the stopgap carries no rights; it proves the root service's
rule, not a kernel's. Lane and wake timings are provisional: a bell on the
stopgap is an IRQ object behind the root service, which serves the whole
machine on one thread, so no code above `liberx` may depend on a bell's
latency, and no decision is taken from those numbers. The hosted backend
carries the rows between tasks too, each domain a macOS process, so the
lane, connection and funnel tests also run there under the sanitizers
([design-runtime.md](design-runtime.md#hosted-mode)).

## Data model

### Domain ids, pids and references

A **domain id** is a 32-bit number, never reused within a boot. Ids start
at 4, because a domain's id is its node's creation and stock ERTS gives
no node a creation below 4 (`erlang:setnode/2`): the system domain is 4,
every other domain takes the next unused id from the domain service, and
creating a domain after the last id fails with `system_limit`
([design-system.md](design-system.md#creating-a-domain)). Programs take
no id: a program is a sub-space of its session
([design-programs.md](design-programs.md#a-program-is-a-port)), so ids are
spent only by domains, which a principal's quota bounds.

**Every domain is a node.** A domain's **node name** is its name, an
identifier ([design-system.md](design-system.md#identifiers)), at the
machine's host name: `web@erxos`, `system@erxos`. Its node's
**creation**, the 32-bit field that ERTS and the external term format use
to tell one run of a node from the next, is its domain id. The runtime
starts its node under that name and creation, both from its boot
information, before it reads its first frame, so `node()` is the domain's
own name from the start and `erlang:system_info(creation)` its id.
Domain identity therefore is ERTS's own node identity, used as stock
ERTS uses it:

* **Names.** At most one live domain holds a name at a time. A name
  belongs to the principal whose domain first takes it, for the rest of
  the boot: only that principal's domains take it again, one at a time,
  and each later domain of the name is a new run of the same node, with a
  new creation. The configured domains are created first at boot, so they
  hold their names before any principal can take one. Sessions and command
  domains take numbered names from their principal's pool instead,
  `<principal>_<n>@<host>`, free again at each domain's end
  ([design-system.md](design-system.md#identifiers)). Each principal binds
  at most `names` names in a boot ([Principals, sessions and
  quotas](#principals-sessions-and-quotas)), which bounds the atoms the
  system domain makes for node names (D5): the domain service makes a
  name's atom once, when the name is first bound, and every later domain
  of the name reuses it.
* **Pids.** A pid is ERTS's: a number and a serial, with a node name and a
  creation ([research](research-erts-internals.md#pids)). Its node is its
  owner domain's node, and its creation its owner's domain id. A
  runtime's own pids are ERTS internal pids; every other pid is an
  external pid of another node. ERTS orders pids by serial, number, node
  name and creation, and hashes them by number alone in `phash/2` and
  `phash2/1`, so order and hashes agree in every domain. A pid of an
  ended domain carries that domain's id, which no later domain of the
  same name has, so it names no process of the later one: a signal to it
  is answered as for a process that does not exist ([The
  funnel](#the-funnel), step 4), as stock ERTS treats a pid of an earlier
  run of a node.
* **References.** A reference carries its creator's node name and
  creation in the same way, so references of different domains never
  collide, and a runtime recognises its own. Every reference has four
  opaque 32-bit words, drawn so that no domain can guess another's
  ([design-runtime.md](design-runtime.md#unguessable-references)). An
  alias has the same representation as an ordinary reference; only its
  owner's local metadata associates it with a process, and only its
  owner's export table says who may send through it.
* **Text.** The one difference in how identity looks, and the user's
  decision: pids print as `<D.N.S>`, references as `#Ref<D.a.b.c.d>` and
  ports as `#Port<D.N>`, with `D` the owner's domain id, its node's
  creation, in every domain, where stock ERTS prints 0 for its own node
  and an index of the node name for another. A pid therefore reads the
  same wherever it is printed and names its owner. `list_to_pid/1`,
  `list_to_ref/1` and `list_to_port/1` read the same forms: `D` names the
  domain's own node when it is its own id, and otherwise the node of a
  connection whose creation is `D`; a `D` that is neither is `badarg`, as
  stock ERTS answers a number that names no connected node. `D` is the
  creation of the node the term itself carries, so a pid of an ended
  domain keeps printing that domain's id after a later domain of its name
  has connected. In ERTS that is the channel-number macros and the parsing
  BIFs ([design-runtime.md](design-runtime.md#connections-in-erts)); it is
  a documented difference from stock OTP, with a test, and the oracle's
  comparison accounts for it.
* **No magic reference crosses a domain.** ERTS calls a reference to an ETS
  table, a NIF resource or prepared code a magic reference. Every runtime
  decodes a reference from a frame as a plain reference, so outside its
  domain it is only a number, even when it comes back.

**An exposed domain.** A domain that other machines reach keeps its node
name and creation on the network ([design.md](design.md#networking));
[design-network-stack.md](design-network-stack.md#distribution-to-other-machines)
defines the carrier that serves those connections, OTP's TLS carrier in
release builds, and the port mapper that resolves the domain's name
there. Two rules hold whatever
it chooses:

* a node name at the machine's host name is reached only through a lane:
  the connection agent alone serves those names, and only for connections
  the system domain made, and the network carrier refuses a remote node
  that presents one, so no other machine stands in for a domain of this
  one (D2);
* a pid, reference or alias of another machine never crosses a lane: the
  funnel's grammar admits only node names at the machine's host, so a
  frame that carries one is malformed, and an exposed domain that hands
  another domain work for a remote process stands a local process in for
  it. Lanes therefore carry one shape of name, whose references all have
  four words, and a domain that is not exposed never holds a name it
  cannot reach.

A runtime needs no permission to create a process: its pid space is its
node's creation, delegated once when the domain is created.

### Connections

A **connection** joins two domains that the system domain has introduced. It
is two **lanes**, one in each direction, and nothing else: no record of it
exists anywhere but in the system domain, which made it, and in the two
runtimes, which use it.

A connection is all two domains share, and no capability passes between
two domains. The kernel lets spaces that share an IPC gate pass
capabilities at a rendezvous, within each type's pass set
([design-kernel.md](design-kernel.md#passing-capabilities)), and within a
domain's tree, a domain and its sub-spaces or a session and its programs,
that is the ordinary way to hand one over. Between domains no gate is
shared: the domain library, the one installer of capabilities into a
domain, installs connections, resources and the sealing page, and never a
gate of another domain
([design-system.md](design-system.md#the-domain-library)), and no system
manifest introduces a gate that two domains share. So every cross-domain
signal is a frame on a connection, and every page two domains both map is
an object the system domain created and charged to an outer budget.

**A lane** carries frames from its producer to its consumer. It has:

* a **ring**: a header page and a data area, in memory the producer alone
  writes and the consumer maps read-only;
* a **reader page**, in memory the consumer alone writes and the producer
  maps read-only;
* a **bell**: an IRQ object that the system domain binds to the consumer's
  group, with a label it tells the consumer, and that the producer holds
  with `TRIGGER` alone, which is exactly what the IRQ object's pass set
  conveys ([design-kernel.md](design-kernel.md#passing-capabilities)).
  `BIND` never passes (K24), so the consumer holds no capability to its own
  bell and needs none: it takes the bell's deliveries from its group's ready
  list.

**A group's labels.** The ABI splits every group's label space in two at
`ERX_LABEL_SPLIT` (2^31). Labels below it are the system domain's: it
assigns a bell's label from a per-domain counter it keeps, for the
doorbells it binds into the domain's group (a connection's lanes), and
tells the domain the label in `connection_up`. Labels at or above it are
the domain's own runtime's, for the doorbells it binds itself (channels,
pipes and devices). The halves never meet, so the system domain and the
runtime choose labels without asking each other, and the consumer keys
its connection records by the label it was told, so a delivery from its
group's ready list names the connection exactly
([design-scheduler.md](design-scheduler.md#park-and-wake)).

**A delivery is a hint to look.** Every sink treats a delivery as a reason
to read its source, never as an event in itself: a bell's ring makes the
runtime read the connection's lanes, a doorbell of a channel or a pipe
makes it read that ring, and an interrupt makes a driver read its device's
status. What the sink acts on is what it finds. So a label is free again
once the object bound with it is unbound: a delivery that reaches a later
sink of the same label costs one look, which finds nothing or what the
sink's next look would have found. The system domain reuses a connection's
label once the connection's objects are deleted, the runtime reuses its
own once it has unbound the object, and neither half runs out
([design-runtime.md](design-runtime.md#the-event-table)).

The two lanes of a connection share their memory objects pairwise, so that
each party writes exactly one object and reads exactly one. Party X's
**side** of a connection is one memory object:

```text
side of X on the connection X <-> Y: X writes it, Y maps it read-only, Y pays for it
  page 0        ring header of the lane X -> Y          erx_lane_hdr_t
  page 1        reader page of the lane Y -> X          erx_lane_rpage_t
  pages 2 ..    data area of the lane X -> Y            Y's `lane` bytes
```

Every page of a connection is therefore written by one party and read by
the other. It is charged to a **child budget** for that connection, carved
from the **outer budget** of the party that reads it (D16). A domain's
outer budget is the part of its budget for what another domain maps, the
crash area charged to it directly; the domain holds no capability to it or
to any of its children, and only the system domain charges to them and
destroys them ([design-system.md](design-system.md#ending-a-domain)). The
system domain destroys a connection's child once both parties have let go
of the connection (`erx_dom_disconnect`), and an ended domain's outer
budget once no child remains and its crash record is read
(`erx_dom_retire`), so an object never vanishes under a peer that still
maps it, and a survivor that never lets go keeps one connection's child
budget and the outer budget it was carved from, but no other
connection's lanes. X's side is created from Y's child and sized
by Y's `lane` limit, since Y is who reads the ring in it; and the bell
bound to X's group is created from X's child, since X is who waits on it.
Per object:

| Object | Its pages | Written by | Read by | Charged to |
| --- | --- | --- | --- | --- |
| X's side | ring header and data area of X -> Y; reader page of Y -> X | X | Y | Y's child for the connection |
| Y's side | ring header and data area of Y -> X; reader page of X -> Y | Y | X | X's child for the connection |
| X's bell | none: an IRQ object bound to X's group | rung by Y | taken by X | X's child for the connection |
| Y's bell | none: an IRQ object bound to Y's group | rung by X | taken by Y | Y's child for the connection |

A domain's connection to the system domain is the one exception to
charging the reader: both sides and both bells are charged to the domain's
child for that connection, so no object of a domain's connection is
charged to the system domain's budget, and the lane it reads from the
domain, which its own `system_lane` sizes, is the domain's to pay for
([Flow control](#flow-control)).

The system domain carves a connection's children and creates all four
objects of a connection, two sides and two bells, with `ALLOC` on the
children, from the two domains' outer budgets, which it holds as their
creator; binds each bell to its consumer's group, on which it holds
`SIGNAL` as the group's creator; and gives each party three capabilities:
its own side with `READ`, `WRITE` and `MAP`; the peer's side with `READ`
and `MAP`; the peer's bell with `TRIGGER`. No capability it gives carries
`DESTROY`, which no pass conveys anyway
([design-kernel.md](design-kernel.md#passing-capabilities)), so neither
party can delete anything of the connection and neither can make the other
fault on a mapping; the system domain alone deletes a connection's
objects, and only once each party has unmapped them or ended, never on a
timer while a party lives ([Introduction and connection
down](#introduction-and-connection-down)). This is the kernel's rule for
servers, that a space never maps memory another space can delete
([design-kernel.md](design-kernel.md#closing-and-deleting)), applied to
two equals.

```c
/*
 * A lane's ring header: page 0 of its producer's side.  The producer
 * alone writes it; the consumer copies each field once and validates the
 * copy before it uses it.
 */
typedef struct erx_lane_hdr {
	_Atomic uint64_t	wpos;		/* bytes published since creation, a
						 * multiple of 16; stored with release
						 * order, loaded by the consumer with
						 * acquire order */
	_Atomic uint64_t	need;		/* the consumer's position the producer
						 * waits for: ring the producer's bell
						 * when a store of rpos moves from
						 * below need to need or past it */
} erx_lane_hdr_t;				/* then zeros to 4 KiB */

/*
 * A lane's reader page: page 1 of its consumer's side.  The consumer
 * alone writes it; the producer copies each field once and validates it.
 * A use may append fields after these two, ahead of the zeros; these two
 * and the wake handshake do not change.
 */
typedef struct erx_lane_rpage {
	_Atomic uint64_t	rpos;		/* bytes consumed since creation, a
						 * multiple of 16; stored with release
						 * order, loaded by the producer with
						 * acquire order */
	_Atomic uint64_t	wake;		/* the producer's position the consumer
						 * waits for: ring the consumer's bell
						 * when a store of wpos moves from
						 * below wake to wake or past it */
} erx_lane_rpage_t;				/* then zeros to 4 KiB */

/* A record in a lane's data area: this header, then len bytes padded to 16. */
typedef struct erx_lane_rec {
	uint32_t		len;		/* bytes of the body */
	uint32_t		kind;		/* the kinds a use defines; ERX_REC_FRAME
						 * on a connection or a channel */
	uint64_t		zero;		/* zero on a connection; a use may define
						 * it (a pipe's write-order stamp) */
} erx_lane_rec_t;				/* 16 bytes */
```

Positions count bytes since the lane was created and never wrap in practice
(2^64 bytes); a position's offset in the data area is the position masked by
the area's size, a power of two from `ERX_LANE_MIN` (4 KiB) to
`ERX_LANE_MAX` (16 MiB). Positions, record headers and the area are
multiples of 16, so a header never straddles the end of the area, and only a
body continues at offset 0; the funnel's copy of a body handles the wrap,
since it copies the body out before it looks at it. A ring has no padding:
its free room is exactly its size less its unread bytes. Each party takes
the data area's size from the system domain's word when the connection comes
up, never from a page the other party writes.

**A record is read as it is published.** A record's body may be longer than
the room its producer has when it starts writing it, and longer than the
whole lane. The producer writes the header, then as much of the body as
fits, publishes that by storing `wpos`, and writes the rest as room returns;
the consumer reads the header as soon as it is published, validates it, and
copies the body out as its bytes arrive, advancing `rpos` behind what it has
copied so the room returns at once. So a lane of 64 KiB carries a frame of 1
MiB, in as many turns as the lane's size divides it, and no frame is ever
split into pieces that need reassembling: there is one record, read from one
place, in order. The only state either party keeps for an open record is
where it is in that one record, in its own memory.

**Publishing is a release, reading an acquire.** Each party publishes its
position with a release store and reads the other's with an acquire load:
the consumer acquire-loads the producer's `wpos`, and the producer
acquire-loads the consumer's `rpos`. Each release store pairs with the
acquire load that reads it, so every byte a producer wrote below the `wpos`
it published is visible to a consumer that has read that `wpos`, and a
consumer has finished copying every byte below the `rpos` it published
before a producer that has read that `rpos` writes over them. Every other
load from the other party's pages, of a record's header and body and of
`wake` and `need`, is a relaxed atomic load: what is copied is validated
before it is used, and the wake handshake below orders its own loads with
its fences.

**The wake handshake.** Each party waits only on its own bell, and each bell
says one thing: look at this connection, both lanes. A party that has
nothing to do on a connection publishes the position it waits for and parks
on its group; the other party rings when its own position reaches it:

| Party | Waits for | Publishes | The other rings when |
| --- | --- | --- | --- |
| the consumer, with nothing to read | the next record | `wake = rpos + 1` in its reader page | its store of `wpos` moves from below `wake` to `wake` or past it |
| the producer, with a frame that does not fit | room for the rest of the record, or for a quarter of the lane, whichever is less | `need = wpos + bytes - size` in its ring header | its store of `rpos` moves from below `need` to `need` or past it |

Each follows one pattern: the waiter stores the position it waits for,
executes a full fence, reads the other's position once more and waits only
if it is still short; the mover stores its position, executes a full fence,
reads the waited-for position and rings only if its store crossed it. The
two fences close the window in which each side reads the other's old value:
at least one of them sees the other's store, so no wait is lost. A party
that moves its position without crossing the published value rings nothing,
so a busy lane costs no kernel call at all; a party that publishes a
position already crossed is never rung and is not waiting. Triggers that
come before a wait count once, and a trigger never waits
([design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)), so a
peer that rings needlessly costs the waiter at most one wake for each of its
waits and costs itself one kernel call for each ring. A delivery names the
bell's label, so a runtime with many connections learns exactly which rang
from its group's ready list, without polling any of them
([design-scheduler.md](design-scheduler.md#park-and-wake)).

**Lane sizes.** A domain's `lane` limit sizes the data area of every lane
it reads ([Principals, sessions and
quotas](#principals-sessions-and-quotas)), 64 KiB by default: enough that
a sender of small frames and a receiver that drains at each bell
rarely meet a full lane, and small enough that a domain's connections cost
it tens of kilobytes each. The system domain sizes the lane it reads from
each domain by its own `system_lane` (16 KiB by default) when it admits
the domain, and charges it to the domain's child for the system connection
([Connections](#connections)): that lane carries requests to facets, spawn
replies, log records and console output, each small. The system domain's
mappings of that lane are one term of a fixed sum, which is everything one
domain can make the system domain hold ([Flow control](#flow-control)). A
domain that wants more throughput from a peer raises its own `lane` within
its principal's ceiling, at its own cost. Experiment E-D1 sets both
defaults.

**The reserve.** The lane a domain reads from the system domain also holds
a **reserve** for the connection protocol: room for one connection-control
record ([Messages between the domain service and a
runtime](#messages-between-the-domain-service-and-a-runtime)) for each
connection the domain's `connections` quota allows, each a few hundred
bytes, whose bound the longest node name fixes. Its data area is the
smallest power of two that holds the domain's `lane` and the reserve, and
the domain pays for it, as for both lanes of its system connection. The
system domain never lets an ordinary frame take the reserve: it writes an
ordinary record, or the next part of a long one, only into room beyond the
reserve, and a connection-control record into any room. It tells the two
apart by sender: a message whose sender is the domain's domain pid, which
the system side's port is given when it opens, is a control record, and
every other frame is ordinary. The domain pid sends its domain nothing
but the records the domain service hands it, so only the domain
service's records reach the reserve, whatever any other process sends,
and no record's shape is read to class it. The domain service sends a
domain the control records about one peer node name one at a time,
through its domain pid, each once the domain has answered the last: a
connection's
`connection_down` waits for the answer to its `connection_up`, and the
`connection_up` of a later domain of the same name waits for the answer to
the earlier connection's `connection_down`. So at most one record per peer
name is ever outstanding, every one fits, since a closing connection still
counts against `connections`, and a runtime never sees a connection come
up for a node name whose entry is still up. A control record that comes
while a long ordinary record is being written in parts goes in right
behind that record, so the system domain holds at most one per peer name
meanwhile, and it never drops one.

### Frames

A **frame** is one signal crossing a domain boundary, the body of one lane
record:

```text
frame
  u32  ctl_len      bytes of the control term, at most ERX_CTL_MAX (4 KiB)
  u32  payload_len  bytes of the payload term, 0 when the operation has none
  ctl_len bytes      control term: external term format, version byte 131
  payload_len bytes  payload term: external term format, version byte 131
```

The control term is the control tuple of OTP 29.1.2's distribution protocol
for the operation (`erts/doc/guides/erl_dist_protocol.md`), and the payload
is the message, exit reason or argument list that the protocol sends after
it. Frames are encoded with the **peer's flags**: the mandatory set of OTP
29 (`DFLAG_DIST_MANDATORY`) plus `DIST_MONITOR`, `DIST_MONITOR_NAME`,
`EXIT_PAYLOAD`, `SEND_SENDER`, `SPAWN`, `ALIAS`, `UNICODE_IO` and
`NATIVE_RECORDS`, with `PUBLISHED`, so every connection is visible
([The peer](#the-peer)), and none of the atom caches,
`FRAGMENTS`, `ALTACT_SIG` or `BIG_SEQTRACE_LABELS`. ERTS sends
`MONITOR_P`, `DEMONITOR_P` and the monitor exits only to a peer that has
both `DIST_MONITOR` and `DIST_MONITOR_NAME`; without both it reduces every
monitor of a remote process to a watch on the connection
(`beam/dist.c:1504`, `:1533`, `:1559`), so the flag set carries both.
ERTS encodes a native record as `RECORD_EXT` whatever the peer's flags
(`erts/emulator/beam/external.c:4006-4025`), so the grammar admits it.
Two consequences of the flag set are deliberate:

* **Trace tokens.** ERTS still sends a sequential-trace token with a small
  label to a peer without `BIG_SEQTRACE_LABELS` (`beam/dist.c:1573-1589`).
  The peer strips tokens, so no `_TT` operation appears and a traced
  process's cross-domain sends arrive untraced.
* **No alternate actions.** Without `ALTACT_SIG`, a priority send to another
  domain arrives as an ordinary message, and an exit signal sent to an alias
  of another domain's process has no effect (`beam/dist.c:1646`,
  `:1809-1813`).

The operations a domain may send, with the right the receiver's export table
must give the sender on the target:

| Operation (number) | Target | Right needed |
| --- | --- | --- |
| `SEND_SENDER` (22), payload message | `ToPid` | send |
| `ALIAS_SEND` (33), payload message | `Alias` | send on the alias |
| `LINK` (1) | `ToPid` | link, or none when `ToPid` already holds a link with `FromPid`, which the frame then creates nothing |
| `UNLINK_ID` (35), `UNLINK_ID_ACK` (36) | `ToPid` | none |
| `MONITOR_P` (19) | `ToProc`, a pid | send |
| `DEMONITOR_P` (20) | `ToProc`, a pid | none |
| `PAYLOAD_MONITOR_P_EXIT` (28), payload reason | `ToPid` | none |
| `PAYLOAD_EXIT` (24), payload reason | `ToPid` | none |
| `PAYLOAD_EXIT2` (26), payload reason | `ToPid` | exit |
| `GROUP_LEADER` (7) | `ToPid` | exit; `FromPid`, the new leader, is a process of the sender's domain |
| `SPAWN_REQUEST` (29), payload arguments | the receiving domain | spawn, on the domain's name |
| `SPAWN_REPLY` (31) | `To` | none: must match a pending spawn of `To` |

**Registered names stay inside their domain.** A registered name is a
name anyone can guess, not one its owner handed out, so no export covers
it, and a name registry that spans domains would let one domain register
or join names in another; names across domains are the exports the
owner's runtime writes. The sender's peer therefore never writes the two
operations that address a registered name of another node: `{Name, Node}
! Msg`, OTP's `REG_SEND`, is dropped and counted in the sender's runtime,
as a message to a name not registered there, and
`monitor(process, {Name, Node})`, a `MONITOR_P` of a name, is answered at
once by the sender's runtime with `DOWN` and reason `noproc`, as for a
name not registered (toward a domain whose connection is not up, with
`noconnection`, as stock answers for a node it cannot reach). A frame
that carries either anyway is malformed.
`global` and `pg` therefore stay within each domain, and `rpc` and `erpc`,
which spawn their calls, reach a domain that exports `spawn` to the
caller's.

**Signals that need no right.** An unlink, its acknowledgement, a demonitor,
a link exit and a `DOWN` each change only a relation between their target
and the sending process, which the sender rule makes the sender's own, and
none produces anything the sender could observe: the receiving runtime acts
on a link exit or a `DOWN` only for a link or monitor it holds, and ERTS
acknowledges an unlink whether or not its target lives or holds the
connection (`beam/erl_proc_sig_queue.c:2707-2729`, `:6663-6694`). Asking a
right for them would let a full export table leave a link or a monitor that
can never be answered; needing none, they convey nothing either. Names in
their reasons remain inert data. A `LINK` to a process that already holds a
link with its sender changes nothing and needs no right either: `link`
guards making a link, and a runtime answers a `LINK` with `noproc` only
when its process holds no link with the sender, so a `noproc` never ends a
link whose other half exists, as in stock OTP, where only a process that
does not exist, and so holds no links, answers one. Creating nothing, such
a `LINK` takes no room within `peer_held` and is never answered with a
`system_limit` exit ([The peer](#the-peer)); that limit applies only to a
`LINK` that creates a link.

A `SPAWN_REQUEST` is OTP's own, `{29, ReqId, From, GroupLeader, {Module,
Function, Arity}, OptList}`; the lane names the domain it is for, so the
term needs no domain field, and the target runtime serves it with ERTS's own
spawn code. Every other operation, including `SEND` without a sender,
`REG_SEND`, a `MONITOR_P` or `DEMONITOR_P` of a registered name, `EXIT`,
`EXIT2` and `MONITOR_P_EXIT` without payloads, the `_TT` forms and
`ALTACT_SIG_SEND`, is outside the grammar.

### Exports

A domain's **export table** says which of its names each peer may act on. It
is private to the domain's runtime, which alone reads and writes it; no
other domain and no service maps it. It is not a structure of its own: a
name's **holders**, the peers given the name and what each holds on it,
live on the name's own record in the runtime, a pid's on its process, an
alias's on the alias's local state, and the domain's name on the runtime's
record of the domain:

```c
#define ERX_RIGHT_SEND	0x1	/* messages, alias sends, monitors */
#define ERX_RIGHT_LINK	0x2	/* links */
#define ERX_RIGHT_EXIT	0x4	/* exit/2 including kill, group_leader/2 */
#define ERX_RIGHT_SPAWN	0x8	/* on the domain name: spawn into the domain */
#define ERX_RIGHT_INTRODUCE	0x10	/* on a domain pid: introduce its domain */

typedef struct erx_export_holder {
	uint32_t	peer;		/* a domain that was given the name */
	uint8_t		rights;		/* ERX_RIGHT_*: what it holds on it */
	uint8_t		pad[3];
} erx_export_holder_t;

/*
 * A name's holders: one field of the record that owns the name, a
 * process, an alias's local state or the domain's own record, and freed
 * with that record.  Private to the runtime.
 */
typedef struct erx_exports {
	uint16_t		nholders;
	uint16_t		cap;		/* holders allocated */
	uint32_t		pad;
	erx_export_holder_t	*holders;	/* one per peer given the name */
} erx_exports_t;
```

An export therefore exists only while its name does: a process's exit and
an alias's deactivation clear the field at the transition that ends the
process or deactivates the alias, so no holder outlives what it names, and
none has to be found and removed. The funnel reaches a target's holders
through the record ERTS already looks up to deliver to it, and a name with
no live record has none; a peer that was never given a name finds nothing.
The runtime writes holders in exactly three cases, each an act of the
domain that owns the name (D4):

1. **Handing out a name.** When the peer's encoder puts one of the domain's
   own pids, or one of its own active aliases, into a frame bound for peer
   P, in the control term or the payload, and P holds nothing on the name
   yet, it adds P with `send` alone, which covers messages, alias sends
   and monitors. The sender of every control term is a name handed out
   this way, never with more. So a peer can message, call and monitor a
   process whose name it was handed, which is what answering a call and
   `gen_server:call/3`'s monitor need, and cannot link to it, kill it or set
   its group leader. A name encoded again toward a peer that already holds
   it changes nothing.
2. **A spawn into the domain.** When a peer's `SPAWN_REQUEST` makes a
   process, the runtime adds the spawner to the child's holders with
   `send`, `link` and `exit` before the child runs, so a parent keeps over
   a child in another domain, a sandbox included, what ERTS gives it over
   any child: it can message and monitor the child, link to it and kill
   it, and `spawn_link` and `spawn_monitor` keep their meaning.
3. **An explicit export.** `erx:export(Name, Rights, Peer)`, called by a
   process of the domain, sets what `Peer` holds on one of the domain's
   own names to exactly `Rights`, widening or narrowing what it held. It
   is how a peer comes to hold `link` or `exit` on a name other than a
   child it spawned. `Name` may be the domain's own name, `{domain, Id}`,
   with `spawn`, which is how a domain lets a peer spawn into it, and so
   call it with `rpc` and `erpc`. It is also the only source of
   `introduce`, which means something only on a domain pid: the domain
   service, which owns every domain pid, has the domain pid write it. So neither an encoded
   domain pid, such as one in an inspector's listing, nor a
   `connection_up`, which names the peer by its id, carries the authority
   to introduce that domain.

Holders end on the path that ends what they name (D13): a pid's when the
process exits, in ERTS's exit path, before the exit signals go out; an
alias's when the alias is deactivated, at the same transition as its local
alias state, under OTP's own rules (`unalias/1`, process exit, the first
reply through a `reply` alias, the removal of a `demonitor` alias's
monitor); a holder of any name when `erx:export/3` sets its rights to none;
and every holder toward a peer when the connection with that peer goes
down. A pid export therefore lasts as long as the process: the revocable
name is an alias, as in stock OTP. An **entry** is one peer's hold on one
name, and the table holds at most `exports` entries (16,384 by default),
every one of them live. Handing out a name past that writes no entry and
counts the failure, so the name behaves at the peer as a dead process, and
an explicit export past it fails with `system_limit`. A domain that fills
its own table hurts only its own correspondence.

The table answers two questions. The funnel asks whether a peer holds a
right on a target, one bounded lookup per frame, in the receiver's own
memory. A service asks what it has exported, with `erx:exports(Name)`, which
returns the peers and rights of one of its own names; the domain service
uses it to check that a caller holds a domain pid before it acts on the
caller's word ([Authority](#authority)). Nothing else reads the table: in
particular, a sender keeps no record of what it may do. It sends, and an
operation on a name it was never given comes back as an operation on a dead
process.

### Domains

The system domain's record of a domain is Erlang state of the domain
service, sized for what Erlang needs; the C that creates and ends the domain
is the domain library, which keeps the kernel capabilities
([design-system.md](design-system.md#the-domain-library)):

```erlang
-record(domain, {id          :: pos_integer(),   % its node's creation
                 node        :: node(),          % Name@Host
                 principal   :: pos_integer(),
                 pid         :: pid(),              % the domain pid
                 spec        :: erx_domain:spec(),
                 limits      :: #{atom() => non_neg_integer()},
                 handle      :: reference(),        % the domain library's
                 connections :: #{pos_integer() => connection_id()},
                                                    % by peer domain id
                 facets      :: [grant_record()],
                 state       :: booting | running | ending}).

-record(connection, {id      :: connection_id(),
                     a       :: pos_integer(),      % the two domains
                     b       :: pos_integer(),
                     objects :: reference(),        % the four objects, held
                                                    % by the domain library
                     state   :: up | {closing, [pos_integer()]}}).
                                                    % peers still to unmap
```

A runtime's record of a connection is in `liberx`, one for each connection
the domain has, indexed by the bell's label:

```c
typedef struct erx_connection {
	uint32_t		peer;		/* the other domain's id */
	uint32_t		label;		/* the label the system domain bound this
						 * domain's bell with; the record's index */
	erx_cap_t		side;		/* this domain's side: READ, WRITE, MAP */
	erx_cap_t		peer_side;	/* the peer's side: READ, MAP */
	erx_cap_t		peer_bell;	/* the peer's bell: TRIGGER */
	erx_lane_hdr_t		*hdr;		/* own ring header, writable */
	uint8_t			*data;		/* own data area, writable; out_size bytes */
	erx_lane_rpage_t	*rpage;		/* own reader page, writable */
	const erx_lane_hdr_t	*peer_hdr;	/* the peer's ring header, read-only */
	const uint8_t		*peer_data;	/* the peer's data area; in_size bytes */
	const erx_lane_rpage_t	*peer_rpage;	/* the peer's reader page, read-only */
	uint64_t		out_size, in_size;	/* from the system domain's word */
	uint64_t		wpos;		/* own write position, the one copy
						 * that is ever stored to hdr->wpos */
	uint64_t		rpos_seen;	/* the peer's rpos as last validated */
	uint64_t		rpos;		/* own read position */
	uint64_t		wpos_seen;	/* the peer's wpos as last validated */
	erx_open_rec_t		writing;	/* the record being written, if any */
	erx_open_rec_t		reading;	/* the record being read, if any:
						 * its header, bytes copied, and its
						 * private buffer or discard mode */
	erx_funnel_state_t	funnel;		/* the explicit stack of the payload pass */
	void			*entry;		/* ERTS's distribution entry, or the
						 * native mailbox binding */
	uint8_t			state;		/* UP, or DOWN with its reason */
	erx_connection_counters_t	counters;	/* frames, bytes, drops by reason */
} erx_connection_t;
```

Every value a runtime reads from the peer's pages is validated against its
own copy before use: the peer's `wpos` must satisfy `rpos <= wpos <= rpos +
in_size` and be a multiple of 16, and its `rpos` must satisfy `rpos_seen <=
rpos <= wpos` and be a multiple of 16. A value outside its bounds is
malformed input, and the runtime ends the connection ([The
funnel](#the-funnel)). A party keeps its own positions in private memory and
only ever stores them, so nothing the peer writes moves them.

The **domain pid** stands for a domain in Erlang: an ordinary process in
the system domain, created by the domain service with the domain and
linked to the domain service, which traps exits. The domain and its domain
pid end together. Monitoring the pid watches the domain; an exit signal
from a holder of the exit right stops the domain; the domain service ends
the pid with the domain's exit reason when the domain dies; and when the
pid dies first, by an exit signal that it cannot trap, a `kill`, or by a
fault of its own, the domain service takes the connection's exit as a stop
and stops the domain ([Domain lifecycle](#domain-lifecycle)). The domain
service's own end is the system domain's: the domain service is the
system release's significant child, so its end ends the system domain
and with it every domain and every domain pid
([design-system.md](design-system.md#system-services)). The domain pid is
a proxy built from ordinary processes, so nothing in the kernel knows
about it, and it exports itself, as the domain service directs, to the
domain's creator with `send`, `link`, `exit` and `introduce`; any other
domain the system domain hands it to holds `send` on it, enough to
monitor the domain and nothing more, and gets `introduce` only from an
explicit export by the domain service's policy.

The domain pid is also its domain's **correspondent**: the one process of
the system domain the domain knows from its start, since its boot
information names it and it exports itself to the domain with `send`
before the domain's first thread runs. Init reports ready to it, naming
the domain's agents; the domain pid keeps the connection agent's pid from
that report for the domain's life, which is the agent's life too
([design-runtime.md](design-runtime.md#connections-in-erts)), and passes
the report on to the domain service. From then on it relays the
connection protocol: it sends the agent each connection-control record
the domain service hands it, and passes each of the agent's answers to the
domain service ([Messages between the domain service and a
runtime](#messages-between-the-domain-service-and-a-runtime)). It keeps
no state about any connection: the domain service alone keeps each
connection's state and decides when each record goes. It sets
`erx:origins(true)` and acts on a message from another domain only when it
arrives as `{erx_origin, D, Msg}` with `D` its own domain, so the creator
and every other holder of `send` on it can message it but not speak for
the domain.

## Algorithms and behavior

### The funnel

The funnel is the one reader of a lane's ring and the one path by which a
frame from another domain reaches a runtime (D3). It is a C17 library in
`liberx`, `erx_funnel`, linked by ERTS and by native runtimes alike, built
for the host, fuzzed, and checked differentially against `binary_to_term/1`.
It has two parts and a driver. `erx_lane_take` is the reader: it copies the
next record, or the part of it that is published, out of the lane into
private memory, and is the only function that loads from a lane's pages.
It lives in `erx_lane.c`, the one file that names a lane's shared layouts,
apart from the check and the driver in `erx_funnel.c`, so the build check
that keeps every other file off a lane's pages also keeps them out of the
pure check.
`erx_funnel_check` is pure: given the copied frame, the receiver's limits
and its export table, it returns the verdict (deliver, drop with a reason,
answer as for a dead process, or malformed) and reads no shared memory, so
it builds for the host and is fuzzed and explored there.
`erx_funnel_step(connection, allowance)` drives both: it consumes records up
to an allowance of bytes and records and returns, so the lane port's input
task reschedules itself instead of looping under an arrival flood. The funnel
runs in that task, on a scheduler of the receiving domain and its own grant:
a receiver spends its own CPU validating what it drains, bounded by its own
drain rate, as every network stack does. Its work is linear in the bytes it
reads, plus the sorting of each native record's field names.

Two outcomes are distinguished throughout. **Malformed** is what no correct
runtime writes: a position out of bounds, a header that does not add up, an
unknown tag, a sending pid of another domain. It ends the connection
([Introduction and connection down](#introduction-and-connection-down)).
**Over a limit** is what the receiver's own policy declines, which a correct
sender cannot know in advance: a frame past `max_frame`, a term past
`max_message_heap` or a facet's request limit, nesting past `funnel_depth`,
an atom past `foreign_atoms`. It is dropped and counted, as ERTS drops an
undecodable distribution message, with the substitutions below for signals
that must not vanish.

For each record between the lane's `rpos` and the `wpos` it read once:

1. **Positions.** Copy the peer's `wpos` once, with an acquire load that
   pairs with the producer's release store
   ([Connections](#connections)), and check it: a multiple of 16, at
   least `rpos`, at most `rpos + size`. Every later load from the lane is
   made by `erx_lane_take` with relaxed atomic loads into private memory,
   so a peer that writes concurrently can change what is copied but never
   makes the copy undefined behaviour, and the acquire makes every byte a
   correct producer wrote below that `wpos` visible to those loads; a
   pipe's reader follows the same rule
   ([design-pipes.md](design-pipes.md#the-ring)). A build
   check requires that `erx_lane_take` is the only reader of a lane's pages,
   with a negative fixture.
2. **Record header.** Copy the 16-byte record header and check it: `kind` is
   `ERX_REC_FRAME`, `zero` is zero, `len` is at least 8 and at most
   `ERX_FRAME_MAX` (16 MiB), and `len` rounded up to 16 is what the body
   occupies. Then copy the frame's 8-byte header and check, with checked
   arithmetic, that `8 + ctl_len + payload_len == len`, that `ctl_len` is at
   least 2 and at most `ERX_CTL_MAX`, and that each term starts with the
   version byte 131. A body longer than what is published is read as its
   bytes arrive ([Connections](#connections)); the header and the control
   term are complete before anything below runs.
3. **Payload size.** A `payload_len` past the receiver's `max_frame`, or a
   private buffer the receiver cannot allocate for it, puts the record in
   **discard mode**: the funnel still reads the control term, skips the
   payload's bytes as they arrive, advancing `rpos` behind them, and
   performs step 7's substitution. The buffer for a payload within the limit
   is the receiver's own and grows as the payload's bytes arrive, never
   allocated whole on the header's word, so a sender that publishes a
   header and trickles the bytes makes the receiver hold what it has sent
   and no more; a growth the receiver cannot allocate puts the rest of the
   record in discard mode. Step 3 decides only how the payload is read;
   whether a frame is over a limit counts only once step 5 has found it
   authorised.
4. **Control term.** The control grammar admits only the operations of
   [Frames](#frames), each with its exact arity and element types: pids are
   `NEW_PID_EXT` and references `NEWER_REFERENCE_EXT` of four words, each
   with a node name at the machine's host; unlink identifiers are
   integers from 1 to 2^64 - 1; a spawn request's arity is an integer
   of ERTS's small range and a spawn reply's flags an integer below
   2^27, as ERTS's distribution input reads them; spawn options are a
   proper list of options in the shape of every option ERTS's spawn
   takes, an atom or `{Atom, Value}` with `Value` an atom, an integer
   or a map from atoms to atoms and integers, so no option names a pid,
   a reference or a fun, and ERTS's spawn answers a well-shaped option
   it does not know with `badopt`. Stock ERTS's sender passes any other
   option through, so the sender's peer checks a spawn request's control
   term with the funnel's own grammar before writing it, as it does for
   `REG_SEND`: an option of another shape is answered at once with
   `badopt`, and a control term past `ERX_CTL_MAX` with `system_limit`,
   by the sender's runtime. The control term is read whole, within
   `ERX_CTL_MAX`, so it also gets the semantic stage below: an accepted
   control term is one ERTS's distribution input decodes to the same
   term, except for the receiving domain's own pids and references,
   which ERTS rebuilds as local ones, so the target rule also bounds a
   target pid's number and serial to ERTS's internal range. Every
   refusal of a control term is malformed, since its limits are the
   grammar's own and the sender's peer keeps them. **The target rule:** every target pid
   or reference, the receiver's own (`ToPid`, `ToProc`, `To`, the alias
   of `ALIAS_SEND`, the reference of `PAYLOAD_MONITOR_P_EXIT` and the
   request identifier of `SPAWN_REPLY`), carries the receiving domain's node name, since a lane
   carries frames for its consumer and no one else; one whose creation is
   not the receiving domain's id names a process of an ended domain of
   the same name, which no longer exists, and goes to step 7 as a frame
   whose target is dead. **The sender rule:** every pid of the sender's
   own in a control term carries the lane's node name and domain id:
   `FromPid`, `FromProc`, `From` of a `SPAWN_REQUEST`,
   the child in a successful `SPAWN_REPLY` and the new leader of
   `GROUP_LEADER`; so does every reference the sender creates in a
   control term: the reference of `MONITOR_P` and `DEMONITOR_P` and the
   request identifier of `SPAWN_REQUEST`. Every pid a control term
   carries is therefore its target, which the target rule checks, the
   sender's own, which the sender rule checks, or the `GroupLeader` of a
   spawn request, which stays data as a pid in a payload does. The
   receiver knows the sender by the lane; the frame only has to agree
   (D6).
5. **Authority.** An operation that needs a right is **authorised** when the
   export table holds the target's name toward the lane's domain with
   that right; an operation that needs none always is. Apart from the
   one case below, nothing else is consulted: neither whether the target process lives nor anything the
   frame says about who asks, so neither the outcome nor its timing
   reveals whether a process the sender was never given exists. A
   `LINK` without `link` is the one case decided past the table: the
   receiving runtime accepts it when its process already holds a link with
   the sender, which reveals nothing the sender's domain was not told when
   that link was asked for (Signals that need no right, in
   [Frames](#frames)). The target process decides it, when it handles
   the `LINK` in order with the signals the sender sent before it; the
   funnel only returns such a `LINK` for it to judge. Judged when the
   funnel reads the frame, a link that an `UNLINK_ID` from the same
   sender, still queued at the target, is about to remove would let the
   `LINK` make a link without the right. Nor is the answer's timing new information: the
   sender's own runtime holds the half that the target's earlier `LINK`
   created, which the lane delivers ahead of any answer, so the answer
   reveals only a relation the sender's side already knows of. An
   unauthorised operation is handled in step 7 exactly as one on a
   process that does not exist, whatever its size: authority is decided before limits, and only an
   authorised frame is measured against them, so an `exit/2` without the
   exit right has no effect even when its reason is over a limit.
6. **Payload.** First the **queue quota** ([Flow control](#flow-control)):
   when an authorised frame's target process has reached its quota of
   queued undecoded frames, the step stops here and the funnel takes
   nothing more from the lane until that count falls below the quota. The
   frame stays in the lane, the connection's open record keeps only its
   header and control term, and the lane fills behind it and holds back
   its sender. The runtime keeps the count per process: ERTS in the
   process (edit 15 of
   [design-runtime.md](design-runtime.md#the-edits-outside-syserxos)),
   a native runtime in its mailbox. An unauthorised frame never waits
   here, so the pause reveals nothing of a process the sender holds no
   right on. The payload grammar is chosen by the receiving domain: the
   system grammar for the system domain, the domain grammar otherwise; both
   are below. The pass is iterative, with an explicit stack in the
   connection's funnel state of at most `funnel_depth` entries. A term that
   ends a tuple, list, map or record (its last element, or a list's tail)
   takes no stack entry, so long lists and right-nested tuples cost nothing;
   only nesting in other positions does, and inside a map key every
   container takes an entry until it ends, since the receiver's semantic
   stage computes a key's identity from all of it. Every pid and reference remains
   byte-for-byte unchanged and grants nothing. The pass computes the term's
   decoded heap size exactly as ERTS's decoder does
   ([research](research-erts-internals.md#external-term-format)). A term
   past `max_message_heap`, or past the request limit of the target process
   when it has one ([Facets](#facets)), or nested past `funnel_depth`, is
   over a limit; a tag outside the grammar is malformed. This stage checks
   wire structure and size; semantic acceptance is completed by the
   receiving decoder, below.
7. **Act.** For an authorised, in-limit frame: hand the control term and the
   payload to ERTS's distribution input, `erts_net_message`, on the
   connection's entry, or to the native mailbox, which queues a message
   encoded on its target until a `receive` examines it. For a
   `SPAWN_REQUEST`, write the child's export toward the lane's domain before
   the child runs ([Spawning](#spawning)). Otherwise, as the receiving
   runtime itself and in order with what it sent before (D9):

   | The frame | Unauthorised, or its target is dead | Over a limit |
   | --- | --- | --- |
   | a message or an alias send | dropped and counted, as ERTS drops a message to a dead process | dropped and counted |
   | a link or a monitor | answered with the exit or `DOWN` of reason `noproc` that ERTS sends for a process that does not exist, on this lane's reverse, behind everything sent earlier | not applicable: no payload |
   | an exit signal | dropped: a dead process receives none | delivered with reason `{erx_reason_too_large, Bytes}`, `Bytes` the payload's length, or `{erx_foreign_reason, Bin}` ([Links, monitors and exits](#links-monitors-and-exits)) |
   | `exit/2` or `group_leader/2` | no effect | an `exit/2` reason over the limit: delivered as `{erx_reason_too_large, Bytes}` |
   | a spawn request | answered with `SPAWN_REPLY` of `noconnection`, what a spawn into a domain that has died gets | answered with `SPAWN_REPLY` of `system_limit` |
   | a spawn reply | dropped if it matches no pending spawn, as ERTS drops a stale reply (`beam/erl_proc_sig_queue.c:5708-5724`) | not applicable |

   A frame both unauthorised and over a limit takes the first column
   (step 5).

8. **Release.** Store `rpos` past the record with release order, execute a
   full fence, read the peer's `need`, and ring the peer's bell if the store
   crossed it ([Connections](#connections)). For a long record the store and
   the check happen after each copied part, so the room returns as the body
   is read.

**Malformed input.** A frame or a position that fails steps 1, 2 or 4, a tag
outside the grammar in step 6, or a term the semantic stage below refuses,
ends the connection from the receiver's side: the runtime stops reading the
lane, counts and logs the reason once, and takes the connection down as
[Introduction and connection down](#introduction-and-connection-down) says.
A domain has no services without its connection to the system domain
([Domain lifecycle](#domain-lifecycle)), so that connection's end is the
domain's end. A runtime whose funnel finds a malformed frame on its
connection to the system domain can tell no one, so it halts its own
domain, and the end reaches the system domain's fault gate like any
other. A domain whose system connection ends for any other reason, a
malformed frame that the system domain's runtime found and the system
domain's `peer_held_total` among them, is ended by the system domain.
Three cases are not malformed:

* a well-formed frame is never malformed because of its target;
* a frame to a process the sender was never given is dropped or answered as
  for a process that does not exist, so a domain cannot probe which pids are
  alive;
* a frame over any of the receiver's limits is dropped and counted.

**The grammars**, as a positive list; any tag not listed is refused:

```text
term      = integer / float / atom / binary / bitstring / tuple / list / map
          / record / pid / reference / fun / export   ; fun, export: domain grammar only
integer   = SMALL_INTEGER_EXT (97) / INTEGER_EXT (98)
          / SMALL_BIG_EXT (110) / LARGE_BIG_EXT (111), at most ERTS's
            BIG_ARITY_MAX digits
float     = NEW_FLOAT_EXT (70), finite
atom      = SMALL_ATOM_UTF8_EXT (119) / ATOM_UTF8_EXT (118), valid UTF-8,
            at most 255 characters
binary    = BINARY_EXT (109)
bitstring = BIT_BINARY_EXT (77), trailing bits 1 to 8
tuple     = SMALL_TUPLE_EXT (104) / LARGE_TUPLE_EXT (105), arity below 2^24
list      = NIL_EXT (106) / STRING_EXT (107) / LIST_EXT (108), any tail
map       = MAP_EXT (116)
record    = RECORD_EXT (67): at most 65,535 fields, flags byte 0 or 1,
            module, name and field-name atoms, field names distinct, then
            one term per field
pid       = NEW_PID_EXT (88): node atom is an identifier, "@" and the
            machine's host name; any creation, which the sender and
            target rules fix in a control term
reference = NEWER_REFERENCE_EXT (90), exactly 4 opaque words;
            node atom and creation as for pids
fun       = NEW_FUN_EXT (112), at most 255 free variables; the old index
            and old uniqueness fields are integers; the creator is a pid
export    = EXPORT_EXT (113): module and function atoms, an integer arity
```

Excluded by construction: ports of every format, old pid, reference, fun and
float formats, `LOCAL_EXT`, compressed terms, distribution headers,
atom-cache references and ERTS's internal tags. The system grammar also
excludes `fun` and `export`, and the system domain's peer decodes atoms
without creating them, which is invariant D5. Fixing the integer fields of
`fun` and `export` as integers keeps ERTS's decoder, which reads each of
them with a nested call, one level deep. The funnel checks that a record's
field names are distinct by sorting an index of them, at most 65,535 entries
of 4 bytes, in the connection's scratch, as ERTS's decoder refuses
duplicates (`beam/external.c:5338-5348`).

**Semantic acceptance.** The funnel's structural pass is the first stage; an
encoded queue entry is pending validation, never an accepted term. At the
receiver, ERTS's decoder, or the native `erx_etf` decoder, completes the
funnel before exposing a term to application code: it checks every remaining
semantic constraint, including map-key uniqueness under Erlang exact
equality and complete consumption of the payload bytes. Equal keys with
different permitted encodings are duplicates too; comparing wire bytes is
insufficient, and nested maps and compound keys use the same rule. The
native decoder finds equal keys by a digest of each key's canonical form,
built as the key is read, so equal keys always share a digest and two
different keys share one only by a collision of the hash, which can make
it refuse a term but never accept a repeated key. It judges pids and
references as a node other than theirs does; ERTS reads its own node's
references by three of their four words, so ERTS's decoder alone refuses
a map whose keys are two such references differing in the fourth. Every
accepted term equals the term `binary_to_term/1` decodes from the same bytes
on the pinned stock OTP. Decoding is lazy, at the receive that first
examines the message (`erts_proc_sig_decode_dist`,
`beam/erl_proc_sig_queue.c:5551`), so a message nobody reads costs the
receiver its encoded bytes and nothing more. A semantically malformed term
is malformed input: the runtime counts and diagnoses it and ends the
connection, so a malformed exit or `DOWN` reason never silently loses the
relation's terminal signal; the relation ends with `noconnection`. An atom
the system domain lacks is a safe-mode refusal, not a malformed term: a
message is dropped and counted, and an exit reason becomes
`{erx_foreign_reason, Bin}`. No decoder failure may panic the runtime or
enter an unchecked allocator failure path.

### The peer

The peer is the runtime's side of the boundary: for ERTS, a distribution
layer in `sys/erxos` that gives each connection its own distribution entry,
with the peer's flags, and the lane as the carrier beneath it
([design-runtime.md](design-runtime.md#connections-in-erts)); for a native
domain, `liberx`'s lane writer and funnel used directly ([Native processes
and drivers](#native-processes-and-drivers)).

* **Connections.** A runtime starts with one connection, to the system
  domain, whose capabilities, label, sizes, node name and id are in its
  boot information. Every other connection arrives as a `connection_up`
  message from its domain pid on the system connection ([Messages
  between the domain service and a
  runtime](#messages-between-the-domain-service-and-a-runtime)). The
  domain's node runs `net_kernel` with `erx_dist` as its distribution
  carrier for every node name at the machine's host, OTP's interface for
  an alternative carrier; the network service's carrier serves the names
  of other machines in an exposed domain. In ERTS the **connection agent**
  is `erx_connections`, an application of the domain's `kernel` and the
  carrier's acceptor: it maps the two sides, records the label the system
  domain bound the domain's bell with, opens a port on the `erx_lane`
  linked-in driver for the connection, and hands the port to `net_kernel`
  as an accepted connection to the peer's node name, with the peer's
  domain id as creation and the peer's flags, and no handshake and no
  cookie, since the introduction names the peer
  ([design-runtime.md](design-runtime.md#connections-in-erts)). ERTS's
  node table, its distribution entries and its send path are stock's: one
  entry per peer node name, connected while the connection is up, so
  `monitor_node/2` and `net_kernel:monitor_nodes/1` report the peer up and
  down. Every connection is visible, the system domain's included, so
  `nodes()` lists every domain the domain is connected to. erXos's
  releases set `kernel`'s `connect_all` to `false`, since the machine's
  domains form no fully connected network, and `global` and `pg` stay
  within each domain, since registered names never cross one
  ([Frames](#frames)). The carrier sets up no connection of its own:
  `net_kernel:connect_node/1` and ERTS's automatic connection toward a
  node of the machine succeed only for a connection the system domain
  made, and otherwise fail at once, so a pid of a node the runtime has no
  connection with behaves as a pid of a node that cannot be reached.
  `erlang:disconnect_node/1` ends a connection from the domain's side, as
  a malformed frame does. No tick supervises a connection: `erx_dist`
  reports no ticks, and `net_kernel`'s tick timer does not apply to its
  connections, since a silent peer is only silent and a domain starved of
  CPU must not be disconnected and so ended; a peer's end arrives as
  `connection_down` ([Introduction and connection
  down](#introduction-and-connection-down)).
* **Output.** `erts_dsig_send` encodes each signal into the entry's queue
  and strips trace tokens; as it encodes, it writes an export with `send`
  for every pid and active alias of the domain's own that the control term
  or the payload contains and the peer does not hold yet
  ([Exports](#exports)). The peer moves queued frames into the lane
  as room allows, each as one record, a long one in parts, and publishes
  each part by storing `wpos` with release order; after each store it
  executes a full fence, reads the peer's `wake` and rings the peer's bell
  if the store crossed it. When a frame does not fit, it stores `need`,
  fences, reads `rpos` once more and, if still short, leaves the frame at
  the head of the queue and goes on with other connections. A frame longer
  than `ERX_FRAME_MAX` is never written: the send fails with `system_limit`
  in the sender, since no lane carries it.
* **Busy.** A sender whose lane is full keeps the frames for it in the
  entry's queue in its own runtime, in its own memory. ERTS suspends a
  process that sends on an entry whose queue exceeds its busy limit, 1 MiB
  (`ERTS_DE_BUSY_LIMIT`, `beam/dist.h:213`), as it suspends senders to any
  busy distribution connection; `erlang:send/3` with `nosuspend` returns
  `nosuspend`; processes sending to other domains carry on. That is the
  whole of flow control ([Flow control](#flow-control)).
* **Input.** A lane has one consumer by construction: the lane port's
  input task, which the connection's bell schedules and ERTS runs on a
  normal scheduler under the port's lock
  ([design-runtime.md](design-runtime.md#connections-in-erts)); no
  executor drains a lane directly. The task runs `erx_funnel_step` up to
  its allowance and reschedules itself when it reached the allowance or
  the peer's `wpos` moved since its last read, unless the lane is paused
  at a queue quota; a paused lane's task is scheduled again by the
  decode or exit that ends its pause ([Flow
  control](#flow-control)). Each step is `erx_lane_take`, then
  `erx_funnel_check`, then `erts_net_message` on the connection's entry,
  which keeps order per connection, or the funnel's own answer, queued on
  that same entry so it keeps its place behind what the runtime sent
  before ([The funnel](#the-funnel)). An executor learns which connections rang from its group's ready list,
  each once, and schedules their ports' input tasks.
* **Origins.** To a process that asked with `erx:origins(true)`, as every
  facet does, the peer delivers each message from another domain, sent to
  the process's pid or to an alias of it, and no signal, as `{erx_origin, D,
  Msg}`, with `D` the domain of the lane the message arrived on, so no
  sender chooses it. An Erlang tuple that imitates the envelope arrives
  wrapped, as every message from another domain does, so a process cannot be
  fooled by one; a message without an envelope comes from a process of the
  receiver's own domain.
* **What it holds for other domains.** A runtime also holds state because of
  another domain's processes: the links and monitors they hold with its
  processes, and the signals ERTS queues for them on behalf of no running
  process, link exits, `DOWN`s and unlink acknowledgements, which ERTS
  queues whatever the busy state (`beam/dist.c:3224-3228`). The runtime
  counts each link or monitor as 256 bytes and each queued signal as its
  bytes, and keeps the sum within `peer_held` (4 MiB) per connection and
  `peer_held_total` (64 MiB) in all. Past `peer_held`, it answers a new
  `MONITOR_P`, or a `LINK` that would create a link, from that domain at once
  with a `DOWN` or an exit of reason `system_limit`, and ends the connection
  when a signal does not fit. A `LINK` to a process that already holds a
  link with its sender creates nothing, takes no room and is never refused
  for the limit, so the limit never ends a link whose other half exists.
  Past `peer_held_total`, it ends the connection that holds the most. The
  bound counts what the other domain caused and the end never waits, so no
  domain, and no set of domains, can make a runtime hold more, and the
  domains that hold little are the last an end reaches.
* **The system domain's peer** decodes in ERTS's safe mode, distinguishes a
  safe-atom refusal from a semantically malformed encoding, turns an exit
  reason refused only by that policy into `{erx_foreign_reason, Bin}`, where
  `Bin` is the reason's encoding, so exits are never lost, and sets no busy
  limit on its own senders that a domain could exploit: a message from the
  system domain to a domain whose lane from the system domain is full waits
  in the system domain's queue up to `system_queue` (16 KiB by default)
  for that connection, and past it the system domain's peer drops the
  message and counts it on the receiver rather than suspend a system
  process. Any other signal that does not fit, a link exit, a `DOWN` or an
  exit among them, ends the connection instead, since none may vanish, and
  so stops the domain ([The funnel](#the-funnel)). A connection-control
  record is never dropped and never waits behind queued frames: it goes
  into the lane's reserve ([Connections](#connections)). A domain that
  never drains what the system domain sends it loses the system domain's
  messages, and holds no more of the system domain than
  `system_queue`.

### Flow control

Flow control is the ring. A frame is written only into room the lane has,
room returns as the receiver copies the frame out, and a sender with no room
waits in its own runtime, in its own memory, for its own lane alone. There
is no credit, no allowance and no exemption; the lane the receiver sized is
the whole of what a sender can place in it, and the one room set aside in a
lane is the reserve for connection-control records in each domain's lane
from the system domain ([Connections](#connections)).

What a sender's full lane does, from the sender's side, is ERTS's busy rule:
processes that send to that domain are suspended once the entry's queue is
long, told `nosuspend` if they asked, and processes sending to other domains
carry on. What it does from the receiver's side is nothing: a receiver that
stops reading a lane holds back only the senders writing to it.

**The queue quota** bounds what the funnel moves into one process. The
funnel keeps, for each process of its runtime, the bytes of the frames it
has queued on that process and the process has not yet decoded; the count
falls as the process's receive takes or examines them, which decodes them,
and when the process exits. When an authorised frame's target has reached
its quota, the funnel leaves that frame in the lane and takes nothing more
from it until the count falls below the quota (step 6 of [The
funnel](#the-funnel)): the lane fills and holds its sender back in the
sender's own runtime by the busy rule above, and nothing is held past the
quota but the one frame that crossed it. The decode or exit that brings
the count below the quota schedules the paused lane's drain again, so a
paused lane costs no polling. In the system domain every process has a
quota: the one its facet's grant names, or the manifest's `system_queue`
([Facets](#facets)). Elsewhere a process has the quota its runtime's
`-erx queue_quota` sets, none by default
([design-runtime.md](design-runtime.md#configuration)), and a target
without one queues, as in stock OTP, until its own `max_heap_size`, with
off-heap binaries counted, ends it, and the domain's budget bounds the
rest. Queued frames count toward `max_heap_size` too, which is what the
process sees. A paused lane holds back every frame behind the one it
holds, whatever process it is for; only that lane's sender waits, as when
a receiver stops reading a lane.

**No process waits at its quota.** Before a process waits in `receive`
while its count is at its quota, its runtime decodes every frame queued
on it. They are its own messages, and from then on they count toward its
`max_heap_size` alone, so the count falls and the paused lane drains on.
So a process never waits behind a pause its own backlog made, a call
whose `receive` skips the messages older than its reference, as
`gen_server:call` does, included: its reply cannot be stuck behind
frames it skipped.

So each frame meets one of six defined outcomes, and none waits anywhere
but in its sender or its lane:

* **delivered**: copied out of the lane into its target's queue, in order,
  where it stays encoded until taken; an exit signal whose reason is over
  a limit is delivered with the reason substituted, and an authorised
  spawn request starts its child ([The funnel](#the-funnel), step 7);
* **answered as for a dead process**: a link, a monitor or a spawn request
  that the receiver does not authorise, or whose target is dead, is
  answered by the receiving runtime on the reverse lane, behind everything
  it sent before, and a spawn request over a limit is answered with
  `system_limit`;
* **waits in its sender's queue**, in the sender's own memory, until the
  lane has room, its process suspended as ERTS suspends a sender to a busy
  distribution connection, or told `nosuspend`; or in the lane, while the
  process it is for, or the process of a frame ahead of it, is at its
  queue quota; a connection-control record
  from the system domain waits for nothing but a long record being written
  ahead of it, since the lane reserves room for it
  ([Connections](#connections));
* **dropped and counted**, as ERTS drops an undecodable distribution
  message: at the receiver, a frame over its `max_frame`, a message past
  its `max_message_heap` or the target's request limit, a message to the
  system domain with an atom it lacks, a spawn reply that matches no
  pending spawn, and a message, a link exit, an `exit/2` or a
  `group_leader/2` that the sender holds no right for or whose target is
  dead; at the system domain as a sender, a message past
  `system_queue`;
* **refused at its sender**: a frame longer than `ERX_FRAME_MAX`, which no
  lane carries, is never written, and the send fails with `system_limit`;
* **lost with its connection**, with `noconnection` at both ends: a
  malformed frame, a signal past `peer_held`, a signal of the system
  domain's other than a message past `system_queue`,
  `erlang:disconnect_node/1`, or a domain's end take the connection down,
  and what the lane still held of the dead side is discarded, except what
  a dead domain published,
  which its peer drains first (D17).

**What a domain can make the system domain hold.** The system domain is
the one receiver every domain reaches, so what one domain can make it hold
is a sum fixed when the domain is admitted, with these terms per domain:

| Term | Bound |
| --- | --- |
| its mappings of the domain's system connection and the capability slots that name its objects, whose pages are charged to the domain's child for that connection | the mappings and slots alone: the lane it reads, `system_lane` bytes with its ring header and reader page, is the domain's to pay for ([Connections](#connections)) |
| the one record it is reading from that lane, in a private buffer that grows as the record's bytes arrive and is never allocated whole on the header's word | the system domain's `max_frame`, which is the largest `max_request` a grant may name ([Principals, sessions and quotas](#principals-sessions-and-quotas)) |
| its queue to the domain while the domain's lane from it is full | `system_queue`: past it a message is dropped and counted, and any other signal ends the connection instead |
| what it holds because of the domain's processes: their links and monitors with system processes, and the signals queued for them | its own `peer_held` |
| each facet granted to the domain, with the requests queued on it | that facet's queue quota for the requests queued on it undecoded, plus the one frame that crossed it, and its `max_heap_size` for what it decodes and keeps ([Facets](#facets)) |
| its frames queued undecoded on system processes that are not its facets, such as the domain service | each such process's quota, `system_queue`, plus one frame; every domain that reaches such a process shares that quota, so the system domain reserves it once per process, in its baseline, and not per domain |
| connection-control records held behind a long record being written into the domain's lane from it | one for each connection the domain's `connections` quota allows |

The domain service reserves that sum in the system domain's own budget
when it admits a domain, and admits it only when the budget holds the sum
for every admitted domain, the new one included
([design-system.md](design-system.md#resource-policy)), so no admitted
domain, and no set of them, can make the system domain hold more than it
reserved. No kernel object of a domain's is charged to the system domain's
budget: the terms are the system domain's runtime's own memory. Every
other connection-control record goes straight into the room the domain's
own lane from the system domain reserves for it, which the domain pays
for.

Nothing reorders what Erlang orders: links, monitors, exits and `DOWN`s are
frames of their lane, in send order (D9). The guarantee is the one
distribution gives: a frame arrives or fails at a defined point, and no
unrelated traffic stops its lane. It proves nothing about deadlocks between
applications: a server that leaves a peer's casts untaken while it waits for
that peer's answer to its own call stalls only if the peer's lane to it is
full of those casts, since the server's runtime drains the lane into the
server's queue whatever the server takes; a peer that fills a lane while it
answers has made the choice stock Erlang lets it make.

### Introduction and connection down

**Making a connection.** The system domain introduces two domains in four
cases, and every connection exists because of one of them; this is the
one list of when connections are made:

| Case | Who asks | What the domain service checks |
| --- | --- | --- |
| a domain's creation | `erx_domain:create/1` from a process of domain A | A's principal and quotas ([Domain lifecycle](#domain-lifecycle)); the new domain B gets a connection to the system domain and a connection to A, its creator |
| a configured domain's introduction in the system manifest | the domain service at boot, as it creates the configured domains in the manifest's boot order ([design-system.md](design-system.md#the-manifest)) | nothing at run time: the manifest's build check proved the introduction, and the domain service makes it once both domains exist |
| a spawn right or a facet of one domain granted to another | the domain service's own policy: a session's facet granted to a domain it starts, a facet of a service in domain S granted to G where the facet runs in S ([Facets](#facets)) | the grant's record; the connection joins the facet's domain and the grantee |
| an explicit introduction | `erx_domain:introduce(D1, D2)`, or `introduce(D)` for the caller's own domain and `D` | the caller's domain holds `introduce` on each domain pid named, which `erx:exports/1` on each answers from the domain service's own export table ([Domains](#domains)) |

A facet in the system domain needs no new connection: its grantee reaches it
on the system connection, and the facet reaches its service on the system
domain's connection with the service's domain. A connection that already
joins the two domains is reused; a domain at its `connections` limit refuses
the introduction with `system_limit`, and so does a domain whose outer
budget cannot fund its child for the connection.

The domain library builds a connection as one plan validated whole before
anything is applied
([design-system.md](design-system.md#the-domain-library)): it carves a
child for the connection from each domain's outer budget, or from the
domain's alone on its connection to the system domain; creates both sides,
each from the reader's child and sized by the reader's `lane`, and both
bells, each from the child of the domain that waits on it, or all four
from the domain's child on its system connection; binds each bell to that
domain's group with the next label below `ERX_LABEL_SPLIT` from the
counter the domain service keeps for that domain
([Connections](#connections)); gives each party its three capabilities,
without `DESTROY`; and only then the domain service records the
connection and tells each party `connection_up`, through the party's
domain pid, naming the peer's id and node name, the slots, the label and
the two sizes, in the order of [The reserve](#connections) for that party
and peer name. It tells a domain nothing before the domain's init has
reported ready, since only that report gives the domain pid the agent's
pid, so a connection made with the domain, its creator's included, waits
in the domain service's record until then; a domain's system connection
needs no record on the
domain's side, which opens it from its boot information, and on the
system domain's side the domain service has its own agent open it before
the domain's first thread runs. Each runtime's connection agent maps,
opens its port and answers `connection_mapped`, and the connection is up
when both have answered; frames written before the peer has mapped simply
wait in the lane. A failure anywhere in the plan undoes what was built,
so no half connection exists.

**Connection down.** A connection goes down for one of three reasons, and
all three end the same way:

* **a runtime ends it**: it found a malformed frame or position ([The
  funnel](#the-funnel)), a signal past `peer_held`, or its policy called
  `erlang:disconnect_node/1`;
* **the system domain ends it**: a domain's end ([Domain
  lifecycle](#domain-lifecycle)), or a policy decision;
* **a peer stops cooperating**: the other cases cover it, since nothing a
  peer does or omits needs an answer. A peer that never drains stalls its
  senders and no one else; a peer that never writes is silent.

The sequence, with D17 and the one-writer rule as its only ordering
constraints:

1. **The runtime that ends it** marks the connection down, stops reading its
   lane and writing the other, takes the distribution entry down as stock
   ERTS takes down a lost connection, which fires every link and monitor
   it holds with the peer's processes with `noconnection`, fails its
   pending spawns there, discards the entry's output queue and reports
   `nodedown`, ends every export toward the peer, unmaps both sides,
   closes its three capabilities to the connection's objects, and tells
   its domain pid `connection_lost` with the reason. The system
   connection is the exception: a runtime that finds it malformed halts
   its own domain, and the domain service learns of the end through the
   fault gate. Messages the funnel already queued on its processes stay,
   as ERTS keeps what a connection delivered before it went down.
2. **The domain service**, on `connection_lost` from either party or on a
   domain's end, marks the connection closing and tells the other party
   `connection_down` through that party's domain pid, with `{domain_down,
   D, Info}` as the reason when the peer ended and `noconnection`
   otherwise. It sends it once the party has answered the connection's
   `connection_up`, so the
   party has at most one control record about that peer name outstanding,
   which the reserve of its lane from the system domain holds
   ([Connections](#connections)); the record is never dropped and never
   waits behind other frames. When the other party is the system domain,
   at a domain's end, the domain service asks its own agent instead.
3. **The other party**, on `connection_down`, first has the port finish:
   it takes every whole record before the `wpos` it reads then, through
   the funnel as always, waiting on nothing the peer would have to do; a
   dead peer's position is final, and a live peer's frames after that
   position are lost with the connection
   ([design-runtime.md](design-runtime.md#connections-in-erts)). Then it
   ends the port with the reason it was given, and the entry goes down as
   in step 1, except that a reason `{domain_down, D, Info}` naming the peer
   fires its links, monitors and pending spawns with that reason in place
   of `noconnection` (edit 56 of
   [design-runtime.md](design-runtime.md#the-edits-outside-syserxos)); it
   answers `connection_unmapped`.
4. **The domain service deletes the four objects** once each party has
   unmapped them or ended, and never on a timer while a party lives, by
   destroying the connection's children; the memory returns to the outer
   budgets they were carved from. Then it removes the connection from both
   domains' records. A party that answered `connection_unmapped` while it
   still maps an object faults on its next access, in its own domain and
   nowhere else.

A dead domain never answers step 3; its lanes are deleted after its
surviving peers have drained and unmapped them. The side the dead domain
read is charged to its child for that connection, which the system domain
destroys only once the survivor has let go, and the dead domain's outer
budget outlives every child
([design-system.md](design-system.md#ending-a-domain)), so a side never
vanishes under the survivor that writes it. A survivor that never answers
keeps the connection's objects as they were charged, and with them that
one child of the dead domain's outer budget and the outer budget itself,
with its crash area, but no other connection's child;
the connection counts against the survivor's own `connections` until it unmaps
or ends, so what a survivor that never lets go can keep of another's
memory is bounded by its own quota, and the inspector shows each such
connection as closing, with the party that holds it. A frame a domain
writes for a peer after the peer has ended waits in the lane until the
writer learns of the end, and is lost with the connection, as a message to
a dead node is. No frame is re-sent or acknowledged, and no epoch
distinguishes one life of a connection from another: a connection that
goes down is gone, and two domains introduced again get a connection of
fresh objects, which start empty.

### Links, monitors and exits

Each runtime keeps its own processes' links and monitors with remote
processes, as ERTS keeps them for any distribution connection. Nobody else
keeps any.

* **A process exits.** Its runtime's exit path removes the process's
  exports, then sends `PAYLOAD_EXIT` to each linked remote process and
  `PAYLOAD_MONITOR_P_EXIT` to each remote monitor, on the same lanes and
  after every frame the process sent earlier, so its last messages arrive
  before its exit signal. These need no right, so a full export table never
  leaves a link or monitor unanswered ([Frames](#frames)).
* **Nobody else can report it.** The sender rule admits a link exit or a
  `DOWN` only from the lane's own domain's processes, and the receiving
  runtime ignores a link exit for a link it does not hold and a `DOWN` for a
  monitor it does not hold, as ERTS already does. A runtime can therefore
  lie only about the deaths of its own processes, which it can cause anyway
  (D6).
* **Exit reasons have bounded failure outcomes.** An exit signal whose
  reason is longer than the receiver's `max_frame`, or decodes past its
  `max_message_heap`, is delivered with the reason `{erx_reason_too_large,
  Bytes}`, where `Bytes` is the payload's length; the funnel reads the
  control term, which names the relation, and skips the reason's bytes. An
  exit reason the system domain cannot decode without creating an atom is
  delivered there as `{erx_foreign_reason, Bin}`. A reason that fails the
  grammar or the semantic stage is malformed input and ends the connection,
  so the relation ends with `noconnection`; no unaccepted reason becomes an
  application term, and no relation's terminal signal is silently lost.
* **A domain dies.** The system domain learns of the end through the fault
  gate ([Domain lifecycle](#domain-lifecycle)) and takes each of the
  domain's connections down with `{domain_down, D, Info}` as the reason.
  Each peer drains the dead domain's lane to its final position, so every
  frame the domain published arrives, and then fires every link and monitor
  it holds with a process of that domain with `{domain_down, D, Info}`,
  fails its pending spawn requests there, and unmaps (D17). A frame for the
  dead domain written before its peer learnt of the end is lost with the
  connection.

`Info` is `{halt, Status}`, `crash`, `{fault, Kind}` or `stopped`. The
domain pid exits with the same `{domain_down, D, Info}`; the detail behind
it, such as a crash slogan, a fault record or the reason a policy stopped
the domain, is in the domain's crash area
([design-system.md](design-system.md#ending-a-domain)).

The exit reaches a linked process behind every message the dead domain's
process sent it, as ERTS orders signals from one sender, but an exit with
a reason other than `normal` kills a linked process that does not trap
exits at once, with those messages still unread in its queue. So a
process that must act on what a domain sent last, the console facet with
the domain's last log records and console output among them, traps exits
or monitors the domain's processes instead of linking without trapping;
then the exit or `DOWN` arrives as a message behind the tail and is taken
after it. Every facet traps exits, since the `erx_facet` behaviour does
([Facets](#facets)), so a facet that links its grantee's processes gets
the domain's tail whole.

### Killing a process

`exit(Pid, kill)` from another domain needs the exit right and reaches the
target's runtime as `PAYLOAD_EXIT2` with reason `kill`. ERTS kills the
process at once, unless it is running a NIF, in which case it dies when the
NIF returns. Nothing watches a kill from outside the runtime: a runtime that
does not comply is either broken or hostile, and a runtime that lied about a
kill, clearing the process while its work went on, could equally carry on
that work under another pid, so no mechanism outside the runtime could tell
the difference. The enforcement that depends on nothing the domain says is
stopping the domain, which the kernel does whatever the runtime does (D7),
through the exit right on the domain pid. A caller that needs a process gone
for certain holds that right, or holds nothing worth waiting for.

### Spawning

**Within a domain**, a spawn is ERTS's own and involves no one else: the
domain's pid space is its own.

**Into another domain**, a spawn is ERTS's distributed spawn toward the
domain's node: `spawn_opt(Node, M, F, A, Opts)`, `spawn_request/5`, and
`erpc` and `rpc`, which run each call as a process they spawn there:

1. The caller's runtime starts ERTS's spawn request on its entry for the
   target node, whose controller is their connection; with no connection,
   the request fails as toward a node that cannot be reached, with
   `noconnection`. The peer
   encodes OTP's `SPAWN_REQUEST`, and encoding the parent and the group
   leader, pids of the caller's domain, exports them toward the target with
   `send`, as handing out any name does, so the child can message and
   monitor its parent and its leader, and nothing more.
2. The target's funnel checks that its export table gives the caller's
   domain `spawn` on the domain's name. A domain's runtime exports that
   right to the system domain and to its creator, the `spawner` its boot
   information names, before it reads its first frame ([Domain
   lifecycle](#domain-lifecycle)), and a domain gives it to anyone else by
   `erx:export({domain, Id}, [spawn], Peer)`. Without it, the funnel answers
   `SPAWN_REPLY` with `noconnection`, what a spawn into a domain that has
   died gets, and starts nothing.
3. The target runtime spawns the child with ERTS's spawn-serving code, which
   sets up the child's half of the link or monitor before the child runs;
   before the child runs it also writes the child's export toward the
   caller's domain with every right ([Exports](#exports)). It answers
   `SPAWN_REPLY` to the parent on the same lane.
4. The parent's runtime matches the reply to the pending spawn, as ERTS
   does, and completes the request, creating its own half of the link or
   monitor.

Spawn and link are therefore atomic as ERTS promises across nodes. If the
target domain dies first, its end fails the request with `{domain_down, D,
Info}`; if the connection goes down for any other reason, with
`noconnection` (`beam/erl_proc_sig_queue.c:4864-4870`). A request the target
leaves unanswered waits as it would at a connected node that does not
answer; `spawn_request/5` with a monitor and `receive ... after`, or
`spawn_request_abandon/1`, are the caller's timeout, as in stock OTP. A
target whose export table cannot take the child's entry answers
`system_limit` and starts no child, so no child is ever linked to or
monitored by a name that reaches no process. A pid among the arguments
remains unchanged data to the child's domain, since it is a pid of the
caller's domain, which exported it by encoding it, or of a third domain,
which did not; a child that needs authority on a third domain's process gets
it only from that process's own domain.

### Domain lifecycle

**Create.** `erx_domain:create(Spec)` asks the domain service in the system
domain, which checks the caller's principal and quotas and the spec's
name ([Domain ids, pids and references](#domain-ids-pids-and-references)),
and has the domain library build the domain as one plan: its budget,
space and group, its crash area, its runtime image and release mapped
from the boot image, its connection to the system domain, and its
connection to the caller's domain
([design-system.md](design-system.md#creating-a-domain)). The boot
information names the domain's node name and id, the system domain's
node name, id and connection, the domain's domain pid, which the domain
service created before the plan and ends if the plan fails, and the
creator's domain as `spawner`. The domain service then has its own agent
open the system domain's side of the system connection, and the domain
pid exports itself to the new domain with `send` and to the caller's
domain with `send`, `link` and `exit`. Only then does the library start
the domain's first thread.

The runtime boots, starts its node under its name and id, and spawns the
domain's init process, and before it reads its first frame it exports
init with `send` and the domain's name with `spawn` to the system domain
and to its spawner, both named in its boot information, so no frame
either sends from the start is dropped as one to a name never exported. Init then runs the domain's boot
script: a small release with `kernel` and `stdlib`, `kernel`'s
`erx_connections` being the connection agent; the
code server, which loads the release's modules from the domain's slice and
the modules that arrive through the domain's code facet
([design-live.md](design-live.md#the-code-store)); a `user` that writes with
`erlang:display_string/2`, which reaches the domain's tty or, where it has none,
its log ([design-runtime.md](design-runtime.md#the-console-and-standard-io)); a
logger proxy, which sends the domain's log records to
the console facet ([design-live.md](design-live.md#the-console)); and the
domain agent that answers inspection ([design-live.md](design-live.md)).
Init reports ready to the domain pid, naming the agents, the connection
agent among them, which exports them to the system domain by that
message; the domain pid keeps the connection agent's pid, the one process
that does, and passes the report to the domain service, which from then
on sends the domain, through the domain pid, the connection-control
records its connections need, the `connection_up` of its creator's
connection first.
The domain service answers init with the facets the spec's `facets`
names, minted for this domain, which that message exports to it, and
`erx:cap(Name)` returns them. The spec's `env` is
the domain's environment, which `os:getenv/1` reads. `create/1` returns
`{ok, Domain}` when init has reported ready, or `{error, Reason}` if the
runtime fails or the spec's boot timeout passes first; in every error case
nothing of the domain remains.

**Stop.** A holder of the exit right on the domain pid stops the domain with
`erx_domain:stop(Domain, Reason)`, which is `exit(DomainPid, Reason)`: the
domain pid traps exits and asks the domain service to stop the domain. A
`kill`, which no process can trap, ends the domain pid at once with reason
`killed`, and the domain service, which links to every domain pid and traps
exits, takes the death of a domain pid whose domain still runs as a stop; so
`stop(Domain, kill)`, a supervisor's brutal kill of a domain pid and a fault
in one all stop the domain ([Domains](#domains)). A domain also ends when
its runtime halts or crashes, when a thread faults and the domain's policy
ends it, and when its connection to the system domain ends. A runtime
whose funnel finds a malformed frame on that connection halts its own
domain, an end like any other that reaches the system domain's fault
gate; the system domain takes any other end of the connection as a stop
([The funnel](#the-funnel)).

**Death.** Every domain's space names the system domain's fault gate at
its creation, so the domain library learns of every end from that gate
([design-kernel.md](design-kernel.md#creating-spaces)); the domain's
sub-spaces stop with it, since their spaces lie below its space. The
domain service classifies the end as `{halt, Status}`, `crash` (the crash
status), `{fault, Kind}` or `stopped`, and then, in this order: takes each
of the domain's connections down, which delivers the end to each peer
behind what the domain published ([Introduction and connection
down](#introduction-and-connection-down)); ends the domain pid with
`{domain_down, D, Detail}`; records the death (the last 16 per principal,
with fault records and crash dumps); and destroys the domain: its own
budget at once, with every object charged to it, each child of its outer
budget once both parties of that connection have let go, and the outer
budget once no child remains and the crash record is read
([design-system.md](design-system.md#ending-a-domain)). The lanes the dead
domain read are deleted after its peers have drained and unmapped them, so
nothing of the dead domain lingers but what a peer that never unmaps
keeps, within that peer's own `connections`. The domain's node name stays
bound to its principal, and a later domain of that name is a new run of
the node, with a new creation.

### Sub-spaces and programs

A domain that holds `SPACES` may build **sub-spaces**, address spaces of its
own that it fills and runs
([design-system.md](design-system.md#sub-spaces)). The protocols of this
document never see them:

* **No identity.** A sub-space has no domain id, no pids, no node identity,
  no export table, no facet and no connection. It reaches nothing but the
  memory its creator mapped into it and the channel its creator gave it, a
  ring pair of the same layout as a connection's lanes
  ([design-programs.md](design-programs.md#the-channel)). Everything a
  sub-space asks of the world is a message on its channel to a process of
  its creator, which acts with the creator's authority after checking its
  own records for that sub-space.
* **Paid for by its domain.** Its memory, threads and objects are charged to
  budgets the domain holds, and its threads run in groups the domain holds,
  within the domain's grants.
* **Ended with its domain.** Its parent is its creator's space or one of
  that space's sub-spaces, so it stops when the domain stops. Its faults go
  to a gate its creator serves, so a fault in it ends only what the creator
  decides, and the system domain sees none of its records.
* **Seen inside its domain.** The inspector shows sub-spaces nested under
  their domain's path, and the domain's accounting includes them
  ([Accounting](#accounting)).

A **program** is a sub-space of its session's domain and a port of the
session's runtime: owned by a process, linked, closed with its owner, spoken
to by messages, reporting `{exit_status, N}`. Its handler, an Erlang process
of the session, is its process table, namespace, file server and signal
source ([design-programs.md](design-programs.md#the-handler)). A program
holds exactly what its starter handed it, which is confinement by
construction: it cannot message any domain, because it has no lane to one,
and it cannot be a confused deputy for a file server, because it never holds
a grant's pid. Programs appear in the inspector under their session as
ports, never as domains.

An Erlang command that a program or a shell starts narrowed, or within
another principal's authority, needs a runtime of its own, so `within` and a
narrowed command start a **command domain**: an ordinary domain created
through `erx_domain:create/1` by the session, with the facets the starter
names, attenuated for it, and ended with the command
([design-shell.md](design-shell.md#invariants)). For a program's command
domain the system domain monitors the program's handler, since a port
cannot cross a domain boundary and the handler owns the program's port and
exits when it closes, and it ends the command domain when the handler
exits. It is the one way a program's tree ever contains a domain.

### Authority

Authority over another domain's process is a right in that domain's export
table, and it moves in exactly the ways [Exports](#exports) lists: the
owning runtime hands a name out by encoding it, writes a child's export at a
spawn, or exports a name explicitly. Three consequences hold by
construction, and they are the whole of the authority model (D4):

* **Only the owner grants.** The rights a peer holds on a name are those
  the owner's runtime wrote: `send` for a name it handed out, every right
  on a child the peer spawned, or exactly what an explicit export set. No
  operation on the wire adds a right; a peer that passes a name on gives
  the third party nothing, since the third party's frames arrive on a lane
  the owner never exported the name toward. So no flow in the system grants
  a name its granter does not own: delegation of a process is the owner
  handing its name out, and delegation of a service is a facet.
* **A pid export lasts as long as its process.** It cannot be revoked,
  because revoking it would make a live pid behave dead to some and alive to
  others. The revocable name is an alias, which its owner deactivates under
  OTP's rules, and the revocable service is a facet, which exits.
* **A missing right is a dead process.** The target's own runtime answers an
  operation it does not authorise exactly as it answers one on a process
  that does not exist, behind everything it sent before, so a domain can
  neither probe for processes it was never given nor tell a refusal from a
  death.

**What a creator holds.** `erx_domain:create/1` gives the caller's domain
`send`, `link`, `exit` and `introduce` on the domain pid, exported
explicitly by the domain service; `spawn` on the domain's name and `send`
on its init, exported by the new domain's runtime to its spawner and to
the system domain before it reads its first frame; and `send` on the
facets the spec names, exported by the frame that delivers them. A domain
that holds `introduce` on two domain pids may introduce their domains to
each other ([Introduction and connection
down](#introduction-and-connection-down)); holding a domain pid with
`send` alone, as anyone it was handed to does, introduces nothing. Nothing
else is ambient: the system domain holds no right on a domain's processes
beyond what that domain's runtime exports to it, and its power over a
domain is the kernel's, to stop it, and the domain service's, to take its
connections down.

**Services and facets.** A service is reached through a facet, a process
bound to one grantee, and the facet is the one admission boundary: it checks
who asks by the lane, never by what a request says, and admits only the
operations and arguments the grant allows, and only within the grantee's
share of measured reductions per period ([Facets](#facets)). A privileged
service helper, one that acts on a process, a file, a device or a domain
with the service's authority, takes a **handle**, a runtime-owned object
that cannot be serialised, bound to the facet's grant, the target and the
right. The facet mints a handle only from its own scope: an inspect facet
whose grant covers all processes may authorise inspection of a pid a request
names, because the scope supplies the authority, not the pid. A facet whose
scope does not cover the target mints nothing, and a callback that records a
pid as data acquires no handle for it. The build generates the admission
functions and the privileged helpers from one operation schema per service,
which states each operation's source of authority, its input bounds and its
result bound; a build check rejects any other caller of an
authority-consuming effect, with a seeded violation as its fixture, so a
service callback cannot act on a bare request name even by mistake.
Narrowing a handle is an intersection; a service cannot recover a right by
looking up a request's pid anywhere.

Each service's operation schema is an included `abi/services/<name>.txt`
fragment. It generates client stubs in C and Erlang, Ruby stubs for the
host-exposed operations, server behaviour declarations and dispatch,
request/reply validators and scoped-handle helpers. The generated serving
path is the facet's admission path below; it calls handwritten scope and
resource policy before invoking a handler. Clients grant no authority and
a timeout never implies an automatic retry. Generated replies are held
to the request's variant and declared bounds. Reference tables and fuzz
scaffolding come from the same declarations, with independent hostile
fixtures checking origin, scope and reply mismatches
([design-generation.md](design-generation.md#service-interfaces)).

**Spawners.** By the user's decision, a parent keeps over a child in another
domain, a sandbox included, what ERTS gives it over any child: it can
message the child, link to it and kill it.

### Facets

A facet is a process that stands for one grant of one service to one grantee
domain. The grantee is introduced to the facet and never to the service. The
facet admits only the operations and arguments the grant allows, within the
grant's limits, and forwards them. Most facets are processes of the system
domain, in front of its services and of services in other domains; a session
serves facets of its own from its own domain. Every facet, wherever it runs,
is an instance of the one `erx_facet` behaviour, bound to its grantee when
it is minted, so the rules below hold for each by construction. Revoking the
grant is the facet's exit; attenuating a grant is a facet in front of a
facet, except for a file tree, whose grants are derived at the server, each
rooted and restricted there
([design-files.md](design-files.md#the-file-protocol)).

**What a facet costs its domain.** A facet runs on its own domain's grant,
the system domain's for a system facet, which policy caps and sizes for the
domains it serves ([design-scheduler.md](design-scheduler.md#service-work)).
A grant names `max_request`, the requests it admits in flight, the
grantee's **share** of reductions per period, the facet's heap limit and,
where it needs another than the manifest's `system_queue`, the facet's
queue quota.

* **Admission by measured reductions.** The facet accounts, per period,
  the reductions spent on its grantee's requests, read from the runtime:
  its own, and those the service's processes spend serving each request it
  forwarded, which the service's generated serving path reads around the
  request and returns with the reply, and those of the processes it
  starts to act for the grantee (below). While the share lasts, the facet
  takes the grantee's requests; once it is spent, the facet takes none
  until the next period, and the rest wait in the facet's queue and then
  in the grantee's lane. A request's cost reaches the account only with
  its reply, and the facet may take up to the grant's limit in flight
  before any reply returns, so a grantee overruns its share by at most the
  cost of the requests in flight when the share ran out, that limit times
  the costliest of them; the facet carries the overrun into the next
  period as a debt. A single request's cost is finite because
  the generated decoder bounds its input; what the grantee's requests add
  up to is bounded by the share, however their cost grows with state the
  grantee built in the service. When a service's grant is spent even so,
  every client of that service slows together
  ([design-scheduler.md](design-scheduler.md#service-work)).
* **Memory.** What the system domain holds because of one grantee is the
  sum of [Flow control](#flow-control), and the facet's part of it is its
  queue quota and its `max_heap_size`. The frames copied out of the lane
  and not yet decoded are held to the queue quota, past which the funnel
  leaves the grantee's next frame for the facet in the grantee's lane, so
  a facet that stops taking requests, its share spent or its loop stuck,
  holds its quota and one frame and its grantee waits on its own full
  lane. Those frames are off-heap binaries that count toward
  `max_heap_size` too, and so does what the facet decodes and keeps, with
  shared binaries counted, so OTP ends a facet whose grantee's requests
  outgrow the grant.
  Lazy decode makes a request cost its encoded bytes until the facet
  examines it, and the funnel checks a message's decoded size against the
  facet's `max_request` (4 KiB by default) before it is queued. One commit
  funnel keeps a facet from ever copying a client's term into a shared
  service process: it decodes and validates in its own heap and hands the
  service a bounded, validated result.

**Processes a facet starts.** A facet may start processes of its own
domain that act for its grantee alone, as the network service's grant
starts a socket process for each of its grantee's sockets
([design-network-stack.md](design-network-stack.md#sockets-act-for-one-domain)).
Such a process runs the facet's generated admission path on every
request, exported toward the grantee with `send` alone, and charges the
facet's account, for work that has no reply as well as for requests:
the account is an `atomics` array the facet hands each such process,
holding the reductions spent in the period and the period's number. The
process adds the reductions of each of its steps as soon as the step
ends, and before it takes its next message compares the account with
the share. While the share is spent it tells the facet it has paused and
takes only the facet's resume message and the exits of its links, by a
selective receive, until the period turns. At each turn the facet
subtracts the share from the spent count, never below zero, so an
overrun is a debt carried into the next period, and resumes every
process that paused; a pause reported after a turn it missed is resumed
at once. Each process checks before a step and charges after it, so the
account exceeds the share by at most one step per such process, which
the grant's limit on them bounds, and the debt repays it.

**Who asks.**
 A facet acts only for its grantee, and never on a pid only
because a request names it. The behaviour exports the facet's pid toward its
grantee with `send` alone when the facet starts, before the domain service
hands the pid out, so the grantee can message and monitor its facet and
nothing more; and the funnel already drops a frame to the facet from any
domain the facet's pid was never exported toward, which is every domain but
the grantee, since the facet's pid reached the grantee in a frame to the
grantee alone ([Exports](#exports)). The behaviour checks again, from the
envelope: the peer hands a facet each message from another domain as
`{erx_origin, D, Msg}`, where `D` is the lane's domain ([The
peer](#the-peer)), and a request whose `D` is not the grantee is refused and
counted. A facet's pid is a name like any other, which its grantee can pass
on; a domain that learns it gets nothing from it. The peer wraps every
message from another domain, whether sent to the facet's pid or to an alias
of it, and wraps no signal, so a message without an envelope comes from a
process of the facet's own domain. The `erx_facet` behaviour uses one
generated admission path, derived from the service's operation schema,
before its callback sees a request:

* **a reply to one of its own forwards**: a `{Tag, Reply}` whose tag is the
  alias of a forward still outstanding and which comes from that forward's
  service: wrapped, with the service's domain as its origin, or without an
  envelope when the service is a process of the facet's own domain. The
  behaviour forwards each admitted request itself, with a fresh alias as its
  tag, and a forward stops being outstanding at its reply, so a reply from
  any other party, or a second reply, matches nothing and counts as a
  request. A facet's callback makes no plain OTP call into another domain,
  whose reply, wrapped, `gen:call` would never match;
* **a signal**: links, monitors and exits are signals, which ERTS handles,
  and the behaviour takes every `'DOWN'` and `'EXIT'` message that ERTS
  makes from one, matches it against the monitors and links the facet set
  up, and drops the rest, so none reaches the callback; the exit of the
  facet behind an attenuating facet ends the attenuating one (Composition,
  below). A wrapped one is a message some domain sent, and so a request;
* **a request**: every other message. Admission checks the lane's domain
  against the grantee, the operation and argument schema, the scope, the
  request's size, the requests in flight and the grantee's remaining share
  of reductions; for each authority-consuming target
  it mints a handle from the facet's scope, or refuses. The reply target
  must be a name of the grantee's, a pid or an alias the grantee's own
  runtime exported to the facet's domain by encoding it; it names where the
  result goes, never who asks.

A request that fails a check is refused with `{error, badarg}` and counted,
so a service behind a facet cannot be made a confused deputy: a domain that
has learnt a facet's pid, its grantee's pids and a reply alias of its
grantee's gets nothing from the facet.

**A facet for a service in another domain** forwards the admitted request on
its own domain's connection with the service's domain, as itself, with a
fresh alias as the reply tag; the service answers to the alias, which the
forward exported. The service sees the facet's domain as origin and trusts
it as it trusts that domain. A session's facet runs in the session's domain,
and granting it to another domain introduces the two: the grantee gets a
connection to the session, on which the facet is the only name the session
exported toward it.

**Handing a facet on.** Passing a facet's pid delegates nothing, by the
user's decision: the facet acts for its grantee alone. A domain hands a
facet to a command domain it starts by naming the facet in the spec; the
domain service mints, as it creates the command domain, a facet granted to
it in front of the starter's, which it accepts only when that facet's
grantee is the starter. The attenuating facet ends with the command domain
and admits no more than the facet behind it.

**Grant records.** The domain service keeps a **grant record** for each
facet it creates: the grantee's domain, the service, for an attenuating
facet the facet behind it, the operations and scope the grant allows, its
limits, and whether it is live.

**Composition.** The domain service mints an attenuating facet only within
the record of the facet behind it, so an attenuated grant is checked once
against its ancestry. Each attenuating facet is linked to the facet behind
it, and the behaviour, which traps exits, turns the link into revocation in
one direction alone: a facet whose facet behind exits exits with the same
reason, so revoking a grant revokes every grant attenuated from it, and a
facet behind lets the exit of an attenuating facet pass, so a command
domain's end, which ends its facets, leaves its starter's facet running.

**Revocation.** Revoking a grant is its facet's exit. The promise is that no
request is admitted after the exit, since a message to a dead process is
dropped; a revocation does not wait for the requests the facet forwarded
before, which run to their end at the service or fail there, and it undoes
nothing a finished request did. It also reaches only what goes through the
facet: a name the service handed the grantee in a reply, a pid or an alias,
stays as usable as it was, so a service that must take back what it handed
out hands names that it checks against the grant on each use, or aliases
that end with the grant.

The services of the live machine are reached through facets: console, code,
domain, inspect, trace and install ([design-live.md](design-live.md)).

**Lineage.** Facets come from the object-capability tradition. A facet is a
forwarder that admits part of what its target accepts, which is Redell's
caretaker, revoked by cutting the forwarder, and E's facets and attenuating
forwarders (Miller 2006, sections 6.2 and 9.3); KeyKOS told an object's
facets apart by the data byte that each of its start keys carried (Hardy
1985). In that tradition a facet is a bearer capability, usable by whoever
holds it; an erXos facet is bound to its grantee and acts for no one else,
as a sender-constrained token differs from a bearer token (RFC 9449, section
2), because an Erlang pid is a name that anyone it reaches can pass on.

### Operations on another process

What a process can do to a process of another domain, given what that
domain's runtime has exported to the caller's domain:

| Operation | Exported with the right | Otherwise |
| --- | --- | --- |
| `Pid ! Msg`, a send to an alias | delivered (send) | dropped, as for a dead process |
| `monitor(process, Pid)` | `DOWN` on death (send) | `DOWN` with `noproc` at once |
| `{Name, Node} ! Msg`, `monitor(process, {Name, Node})` | never leaves the sender's runtime: no right covers a registered name | dropped, as for a name not registered; `DOWN` with `noproc` at once |
| `link(Pid)` | linked (link) | exit `noproc` to the caller, unless `Pid` already holds a link with it |
| `unlink(Pid)`, `demonitor(Ref)` | delivered: they need no right | delivered |
| `exit(Pid, Reason)` | delivered (exit) | no effect |
| `group_leader(GL, Pid)` | set (exit), `GL` a process of the caller's domain | no effect; `badarg` when `GL` is of a third domain |
| `spawn_opt(Node, ...)`, `spawn_request(Node, ...)`, `erpc:call/4`, `rpc:call/4` | a child, linked or monitored as asked, or the call run in one (spawn, on the domain) | fails with `noconnection`, as a spawn into a domain that has died; `rpc:call/4` returns `{badrpc, nodedown}` |
| `is_process_alive/1`, `process_info/2`, `suspend_process/1`, `garbage_collect/1`, `register/2`, `erlang:trace/3` | `badarg`, as for a pid of another node | `badarg` |
| `erx:inspect([processes, Pid])` | what the caller's inspect facet allows | refused |

A name handed out in a frame carries `send` alone, so a process can call
and monitor a server of another domain whose pid it was given, and links to
it, kills it or sets its group leader only when the server's domain
exported that right explicitly, or when it spawned the server.

The system domain is no exception: its processes hold on another domain's
processes what that domain exported to it. The inspector reaches a process
through its domain's agent, which the domain exported to the system domain
when it reported ready, and marks those values `reported_by => runtime`
([design-live.md](design-live.md)).

### Atoms, code, ETS and names

Each runtime has its own atom table, sized by the domain's `atoms` limit
(ERTS's `+t`; 262,144 by default).

* **Foreign entries.** Decoding frames may create at most `foreign_atoms`
  atoms over the domain's life (16,384 by default), and frames from any one
  peer at most a sixteenth of that, counted by the lane. Beyond either
  count, a message with an unknown atom is undecodable: the runtime drops it
  at `receive`, as ERTS drops an undecodable distribution message, and
  counts it. The fun and export tables have the same lifetime counts. Atoms
  are never freed, so lifetime counts are what bound what others can make a
  domain hold, and the share per peer keeps one peer from spending what the
  others' frames need.
* **The domain's own atoms.** Its own code can create atoms up to the full
  table; if it exhausts the table, the runtime stops as a node would, and
  only that domain dies.
* **The system domain** creates none from frames (D5); its only atoms
  made from another domain's request are domain node names, within each
  principal's `names`. A message to a system-domain process carrying an
  atom it lacks, a fun or an export is dropped at decode and counted. A domain can learn whether an atom exists
  in the system domain this way; atoms are names, not secrets, and this is
  accepted ([Security](#security)).

Code is per domain: the domain's code server loads its release's modules
from the domain's slice and the modules its code facet delivers, and hot
loading inside a domain is OTP's own. ETS tables, registered names,
persistent terms, unique integers, counters and atomics are per domain.
`register/2` accepts only the domain's own processes, and registered
names never resolve across domains ([Frames](#frames)); a domain finds
its services through `erx:cap/1`.
Every runtime reads the same clock, so monotonic and system time agree
across domains ([design-runtime.md](design-runtime.md#liberx)).

### Accounting

A domain's budget pays for its space and its sub-spaces, every page mapped
into them ([design-kernel.md](design-kernel.md#budgets)), and every object
created because of it:

| Object | Created by | Charged | Released when |
| --- | --- | --- | --- |
| the runtime's memory | the runtime's commits | the pages | decommitted, or the domain ends |
| the peer's side of each of its connections: the ring it reads and the reader page the peer writes | the domain library, at the introduction | pages of its child for the connection, carved from its outer budget: 8 KiB and the domain's `lane`, and on the connection to the system domain the reserve besides | the system domain deletes the connection and destroys the child, once each party has unmapped it or ended |
| its bell on each connection | the domain library, at the introduction | the IRQ object's record, in the same child | with the connection |
| on its connection to the system domain, its own side, which the system domain reads, and the system domain's bell | the domain library, at creation | pages and records of its child for that connection: 8 KiB and the system domain's `system_lane`, and the bell | with the connection, at the latest when the outer budget is destroyed |
| its group | the domain library, at creation | the kernel's group record | once its threads are gone ([design-system.md](design-system.md#ending-a-domain)) |
| sub-spaces, with everything in them, a session's programs included | the domain, holding `SPACES` | their translation tables, capability tables, threads and memory, from budgets the domain holds | the domain closes them, or with the domain's budget at its end |
| crash area | the domain library, at creation | its outer budget's pages | with the outer budget, once the system domain has read the dump ([design-system.md](design-system.md#ending-a-domain)) |
| a frame in transit | its sender's write | its bytes in the lane, which the receiver paid for | the receiver copies it out |
| another domain's message or signal in a receiver's queues | the receiver's funnel | the receiver's memory, within its processes' `max_heap_size` | a process takes or drops it, or handles the signal |
| another domain's links and monitors, and signals queued for it | the receiver's runtime | the receiver's memory, within its `peer_held` | the relation ends, or the signal is sent |
| its export table | its runtime | its memory, within `exports` | entries end with what they name |

Everything is reserved when its object is created, so a charge never fails
in the middle of an operation: a domain that cannot afford the side it reads
is not introduced, and a frame that its lane does not admit waits in its
sender's runtime ([Flow control](#flow-control)).

**CPU time** follows the same principle, with no exception. A domain's
runtime runs in its group; a receiver's work to validate, decode and queue a
frame, and a process's work to handle a signal, run on the receiver's own
grant; a facet's work runs on its own domain's grant, which policy caps
([design-scheduler.md](design-scheduler.md#service-work)). No thread ever
runs on another group's time, so there is nothing to charge across a
connection: a sender buys the receiver's attention only with frames the
receiver agreed to drain, and a receiver spends on a sender at most its own
drain rate.

### Principals, sessions and quotas

A **principal** is an identity known to the system domain's principal
service. It has:

* a name, and an identifier checked once when the principal is created
  ([design-system.md](design-system.md#identifiers));
* in release builds, credentials, which the vault checks: a passphrase is
  right when it opens one of the principal's credential slots, each of which
  wraps, with AES-256-GCM, the master key that seals the principal's keys,
  under a key derived from the passphrase by Argon2id and from the machine's
  sealing backend. The sealed file is the only check and a secret, kept on
  the vault's own partition, never in the release or the boot image, and the
  vault answers a login only with matched, did not match, limited or
  unavailable ([design-system.md](design-system.md#the-vault));
* a budget and a group sized by the administrator;
* quotas: the number of domain slots its domains may hold; `names`, the
  number of domain names it may bind in a boot ([Domain ids, pids and
  references](#domain-ids-pids-and-references)), 64 by default, which the
  administrator sets so that the sum over all principals stays within the
  system domain's atom table; and for each domain the defaults and
  ceilings of its limits.

A **session** is what a principal starts by a login at a console line
(the UART or the host link,
[design-live.md](design-live.md#the-console)), by a login through the web
front end ([design-web.md](design-web.md)), or from the menu of a line
that has the principal; the domain service also starts, with no login,
the session a display's manifest entry names
([design-display.md](design-display.md#a-displays-session)). A session
is its facets and its session domain, created when it starts, in which
the principal's shells run, at its own line and in its terminals on a
display, and whose sub-spaces are the principal's programs.
Every domain belongs to one principal, and its budgets are children of
that principal's budget. A requested domain's CPU group is a child of
its principal's group under `users`; a configured service domain's group
is a child of `system`, from its checked manifest origin. The
domain library derives that placement from the creation source, never
from a requester-selected parent. Each spends only the memory and CPU
its own parent grants
([design-system.md](design-system.md#resource-policy)).

A domain's limits, fixed at creation within its principal's ceilings:

| Limit | Meaning | Enforced by | Default |
| --- | --- | --- | --- |
| `memory` | bytes its budget may hold | the kernel | 256 MiB |
| `cpu` | its group's grant: quota per period, cpuset, ceiling | the kernel | the principal's share |
| `lane` | the data area of each lane it reads, a power of two from 4 KiB to 16 MiB; the lane from the system domain holds the reserve besides ([Connections](#connections)) | the domain library, which sizes the object | 64 KiB |
| `connections` | connections it may have at once, the system connection included | the domain service, at an introduction | 256; for the system domain, the manifest's `max_domains` ([design-system.md](design-system.md#the-manifest)) |
| `max_frame` | the largest payload it takes into a buffer of its own, which grows as the bytes arrive; a longer one is dropped as it passes | its own runtime | 1 MiB, at most `ERX_FRAME_MAX`; for the system domain, the largest `max_request` its configuration lets a grant name |
| `max_message_heap` | the largest decoded message it accepts | its own runtime | 8 MiB, at most 256 MiB |
| `funnel_depth` | nesting outside tail positions in a frame it accepts | its own runtime | 16,384 |
| `exports` | entries in its export table | its own runtime | 16,384 |
| `peer_held`, `peer_held_total` | what its runtime holds because of other domains' processes, each link or monitor counted as 256 bytes and each queued signal as its bytes, for one connection and for all; past them it answers `system_limit` and ends the connection | its own runtime | 4 MiB; 64 MiB; for the system domain's own `peer_held`, 64 KiB per connection, the manifest's `peer_held` ([design-system.md](design-system.md#the-manifest)) |
| `tmp` | bytes its RAM file system may hold | its own runtime | an eighth of `memory` |
| `overlay` | bytes of blobs its specification's overlay may name | the code service | 16 MiB |
| `atoms`, `foreign_atoms` | atom table; atoms, funs and exports decoding may create, a sixteenth of them per peer | its own runtime | 262,144; 16,384 |
| `processes` | ERTS's `+P` | its own runtime | 65,536 |

Every limit a receiver enforces protects the receiver itself, which is why
its own runtime may enforce it; the limits that protect someone else, a
domain's memory and CPU, are the kernel's. The system domain's own
values are fields of the system manifest
([design-system.md](design-system.md#the-manifest)): `system_lane`
(16 KiB), the size of the lane it reads from each domain, which that
domain pays for; `system_queue` (16 KiB),
what it queues for a domain whose lane from it is full; `peer_held`, what
it holds for one connection; and `max_domains`, the domains it admits,
one connection to each.

A session's programs are its sub-spaces, within quotas the session's handler
and the domain service keep
([design-system.md](design-system.md#resource-policy)): the programs a
session has alive at once, the children of any one program, the pipes its
pipe server keeps and the objects of the files its programs map shared
([design-programs.md](design-programs.md#the-second-tier)), each
charged to the session's budget. Development builds have one principal,
`root`, whose session at the UART holds every facet a session can hold;
the system-shell facet, which no session holds, belongs to `root`'s
login there and at the host link's `console` line. Policy is Erlang in the
system domain; the kernel supplies budgets, groups and capabilities, and
each runtime the limits above.

### Native processes and drivers

A **native domain** is a domain whose runtime is `liberx` alone, with no
Erlang heap. It speaks the same frames as an ERTS domain and is held to the
same rules: `liberx` gives it the lane writer, the funnel and the `erx_etf`
encoder and decoder, which applies the domain grammar and the same limits as
the funnel's semantic stage, and it names its own processes with pids of its
own node name and domain id, so it takes part in sends, links, monitors, exits and domain
deaths exactly as an Erlang domain does, through the same funnel, exports
and budgets. It runs plain threads: one or more executors that take its
group's ready list and drain its lanes, and workers for blocking calls.
Native domains are test domains, which the hostile-runtime suite is made of
([Verification and testing](#verification-and-testing)), and native stopgap
services where the roadmap allows one; drivers and programs are not among
them.

A **driver** is an Erlang process under a supervisor, in a domain that holds
its device's capabilities, over the device NIF
([design-system.md](design-system.md#drivers),
[design-runtime.md](design-runtime.md#the-device-nif)). Which domain holds a
device is configuration: the device service gives a device to exactly one
domain, and a driver's messages to its clients are frames on connections
like any other process's. Bulk data between a driver and its clients moves
through memory objects the driver's domain supplies, as a file server's does
([design-files.md](design-files.md#the-file-protocol)): like a pipe, such
memory carries bytes, never pids, and its delete right stays with the system
domain, which created it, so neither party can make the other fault. A
**native shim**, any native driver code other than the device NIF, a
stopgap or third-party driver included, runs as a sub-space port of the
driver's domain, holding the device's capabilities and a channel to its
owner, exactly as a program is a port of its session
([design-system.md](design-system.md#the-driver-table)). For a confined
device its bugs cannot touch the Erlang heap; for an unconfined device it
is in the trusted base, as the device is.

Native code that needs no Erlang semantics, a native shim and its
domain's threads among them, talks through the kernel's IPC gates within
its own domain, each serving thread running on its own group's grant
([design-kernel.md](design-kernel.md#ipc-gates)); no gate crosses a
domain ([Connections](#connections)).

## Interfaces

### Lanes and frames in the ABI

The ring header, reader page, record and frame layouts are fixed binary
layouts and live in `abi/erx_abi.txt`, from which `liberx` and the peer's C
code are generated ([design-kernel.md](design-kernel.md#the-abi-file)),
pinned with `_Static_assert`, so every runtime agrees on them by
construction. The same lane layout serves a program's channel, which
carries frames as a connection does
([design-programs.md](design-programs.md#the-channel)), and a pipe's ring
([design-pipes.md](design-pipes.md#the-ring)). A use extends the layout in
three places and nowhere else: the record's `kind` carries the kinds the
use defines, the record's `zero` word, which a connection leaves zero,
carries what the use defines (a pipe's stamp, the write order a read end
merges several writers' lanes by), and a use may append fields after those
of `erx_lane_rpage_t` on the reader page (a pipe's `erx_pipe_rpage_t` is
`erx_lane_rpage_t` followed by its `sleepers` word). The lane's fields,
its checks and its wake handshake do not change. The constants:

| Name | Value | Meaning |
| --- | --- | --- |
| `ERX_LANE_MIN`, `ERX_LANE_MAX` | 4 KiB, 16 MiB | the range of a lane's data area; a `lane` limit lies in it |
| `ERX_LANE_SIDE_RPAGE`, `ERX_LANE_SIDE_DATA` | 4 KiB, 8 KiB | the offsets in a side of its reader page and its data area; the ring header is at 0 |
| `ERX_FRAME_MAX` | 16 MiB | the longest record body any lane carries; a `max_frame` limit lies below it, and a runtime never writes more |
| `ERX_CTL_MAX` | 4 KiB | the longest control term; the funnel reads it whole before anything else |
| `ERX_REC_FRAME` | the record kind of a frame, on a connection and on a program's channel | |
| `ERX_LABEL_SPLIT` | 2^31 | splits every group's label space: labels below it are the system domain's, for connection bells; labels at or above it are the domain's own runtime's |

The system domain picks each connection bell's label below
`ERX_LABEL_SPLIT` ([Connections](#connections)), tells the consumer in
`connection_up`, and the consumer keys its connection records by it, so a
delivery from its group's ready list names the connection exactly
([design-scheduler.md](design-scheduler.md#park-and-wake)).

### Messages between the domain service and a runtime

The domain service decides, and each domain's domain pid relays its
decisions to that domain's connection agent, in plain Erlang messages on
the system connection; nothing of the connection protocol travels on any
other path. Neither side needs an export written for the protocol alone:
the domain pid exports itself to its domain before the domain starts and
the boot information names it, and the agent's pid reaches the domain pid
in init's ready report, whose encoding hands it out with `send` (edit 8 of
[design-runtime.md](design-runtime.md#the-edits-outside-syserxos)). The
domain service sends a domain no record before that report. The system
domain's own agent takes the same two records from the domain service as
calls, for the system domain's side of each system connection, and
answers each as the call's result.

| Message | Direction | Meaning |
| --- | --- | --- |
| `{erx_connection_up, Peer, PeerNode, Side, PeerSide, PeerBell, Label, OutSize, InSize}` | domain pid to agent | a connection to domain `Peer`, node `PeerNode`, exists: the capability slots of the domain's side, the peer's side and the peer's bell, the label the domain's own bell is bound with, and the data areas' sizes, the domain's own lane first; the agent maps, opens the port, brings the entry up and answers `connection_mapped` |
| `{erx_connection_mapped, Peer}` | agent to domain pid | the domain has mapped the connection's objects and its entry is up |
| `{erx_connection_down, Peer, Reason}` | domain pid to agent | the connection is going away, `Reason` being `{domain_down, D, Info}` or `noconnection`; the agent has the port finish at the lane's current position, ends it with `Reason`, which fires its links and monitors with it, unmaps, closes and answers `connection_unmapped` |
| `{erx_connection_unmapped, Peer}` | agent to domain pid | the domain has unmapped the connection's objects and closed its capabilities |
| `{erx_connection_lost, Peer, Reason}` | agent to domain pid | the domain ended the connection from its side: `{malformed, Code}`, `{peer_held, Bytes}`, `{map, Status}` when it could not map it, or `disconnect`; it has already unmapped |

The two messages to the agent are the **connection-control records**. The
domain service sends the records about one peer node name one at a time,
each once the agent has answered the last, so at most one per peer name
is outstanding, and the reserve of the domain's lane from the system
domain holds every one ([Connections](#connections)). It hands each to the
domain pid tagged with the secret the two share, and the domain pid sends
it to the agent at once; the domain pid passes each answer to the domain
service tagged with the same secret, and keeps nothing of either. Every
answer is built of atoms the system domain's code already holds, so the
safe decoder creates none. Of its domain's messages the domain pid
passes on only the three answers and init's ready report, by their
shapes, and drops and counts any other; the domain service applies an
answer only to a connection of the domain in the state that expects it,
and drops and counts the rest ([design-system.md](design-system.md#ending-a-domain)).

A runtime that receives a message of this shape from any lane but the system
connection ignores it: the envelope the peer puts on every message from
another domain names the lane, `{erx_origin, 4, Msg}` for the system
domain's (edit 16), and the agent acts only on the system domain's.

### Erlang interface

```erlang
-opaque domain() :: {erx_domain, Id :: pos_integer(), Node :: node(), Pid :: pid()}.
-type right() :: send | link | exit | spawn | introduce.
-type name() :: pid() | reference() | {domain, pos_integer()}.
-type spec() :: #{name := binary(),            % an identifier; the domain's node is
                                               % Name@Host, at most one live domain
                                               % per name
                  release := binary(),         % a boot script in the boot image
                  flavour => jit | emu,        % default jit; deterministic mode forces emu
                  facets => #{atom() => pid()},
                                               % facets the domain starts with, each
                                               % one the caller holds, attenuated for it
                  files => #{binary() => atom()},
                                               % mount point => the name of one of
                                               % its facets that serves a tree
                  restart => temporary | transient | permanent,
                                               % default temporary; the others make
                                               % it supervised (design-live.md)
                  env => #{binary() => binary()},
                                               % its environment; with the runtime's
                                               % arguments, at most 2,048 bytes
                  limits => #{atom() => non_neg_integer()},
                                               % within the principal's ceilings
                  boot_timeout => timeout()}.  % default 10,000 ms

-spec erx_domain:create(spec()) -> {ok, domain()} | {error, term()}.
-spec erx_domain:stop(domain(), Reason :: term()) -> ok.
-spec erx_domain:grant(domain(), Name :: atom(), SourceFacet :: pid(),
                        Limits :: map()) -> {ok, pid()} | {error, term()}.
-spec erx_domain:introduce(domain(), domain()) -> ok | {error, term()}.
-spec erx_domain:introduce(domain()) -> ok | {error, term()}.
-spec erx_domain:id(domain()) -> pos_integer().
-spec erx_domain:node(domain()) -> node().
-spec erx_domain:pid(domain()) -> pid().
-spec erx:export(name(), [right()], Peer :: pos_integer()) -> ok | {error, term()}.
-spec erx:exports(name()) -> [{Peer :: pos_integer(), [right()]}].
-spec erx:cap(Name :: atom()) -> pid() | undefined.
-spec erx:origins(boolean()) -> ok.
```

* `create/1` returns `{error, quota}` when the principal's domains hold all
  its slots or the name would bind one past its `names`, `{error,
  name_taken}` when a live domain holds the name or another principal has
  bound it, `{error, {limit, Name}}` when a limit exceeds the principal's
  ceiling, `{error, no_memory}` when the principal's budget cannot fund the
  domain, `{error, system_limit}` when domain ids are exhausted or the
  caller's domain is at its `connections`, `{error, bad_identifier}` when
  the name is not an identifier
  ([design-system.md](design-system.md#identifiers)), `{error, {boot,
  Reason}}` when the runtime fails to boot, and `{error, timeout}` when
  `boot_timeout` passes first.
* `erx_domain:node/1` returns the domain's node name, toward which stock
  calls address it: `spawn_opt/5`, `spawn_request/5`, `erpc`, `rpc`,
  `monitor_node/2`. A missing spawn right, a dead
  domain and a failure in the target reach a spawning caller as ERTS's
  distributed spawn reports them: through the link or monitor the caller
  asked for, and otherwise as a pid that behaves as a dead process.
* `stop/2` is `exit(erx_domain:pid(Domain), Reason)`; it has effect only for
  a holder of the exit right on the domain pid. With `kill` it ends the
  domain pid at once, and the domain service then stops the domain ([Domain
  lifecycle](#domain-lifecycle)).
* `erx_domain:grant/4` mints a facet for a running domain, in front of a
  live facet the caller holds, within that facet's scope and `Limits`
  ([Facets](#facets)); `{ok, FacetPid}` means the facet runs and its pid has
  been delivered to the domain, which exported it.
* `introduce/2` makes a connection between two domains whose pids the
  caller's domain holds with `introduce`; `introduce/1` between the
  caller's own domain and one whose pid it holds so. Both return `ok` when
  the connection is up at both ends, `{error, system_limit}` when either
  domain is at its `connections` or cannot fund its side, and `{error,
  badarg}` when the caller does not hold `introduce` on one of the pids,
  which is also the answer for a domain that does not exist, so the call
  reveals nothing. A domain ends one of its own connections with
  `erlang:disconnect_node/1`, as a malformed frame would, with
  `noconnection` at both ends; ending its connection to the system domain
  ends the domain.
* `erx:export/3` sets what `Peer` holds on one of the calling domain's own
  names to exactly the rights given, widening or narrowing what it held:
  the owner's act, and the only way a peer comes to hold `link` or `exit`
  on a name other than a child it spawned. With `[]` it leaves the peer
  holding nothing, which is what a peer that was never given the name
  has. It returns `{error, badarg}` for a name of another domain, a
  process that has exited or an inactive alias, and `{error,
  system_limit}` when the table is full.
* `erx:exports/1` lists what the calling domain has exported one of its own
  names toward, and is how a service checks that a peer holds a name before
  it acts on the peer's word about it.
* `erx:origins(true)` makes the domain's peer deliver each message from
  another domain to the calling process, sent to its pid or to an alias of
  it, as `{erx_origin, D, Msg}`, with `D` the domain of the lane it arrived
  on ([The peer](#the-peer)); `erx:origins(false)` turns that off. It exists
  in every domain, so the facets a session serves run the same behaviour as
  the system domain's.

A facet implements the `erx_facet` behaviour, which calls
`erx:origins(true)` when the facet starts, sets its process's request limit
for messages from other domains to the grant's `max_request` and its heap
limit as the grant says, and takes its grantee from the grant it is minted
with. Before it calls `admit/3`, the behaviour sorts what arrives by its tag
first, takes the replies to its own forwards and the messages that signals
make, accounts the reductions each forward's reply reports, enforces the
grant's limit in flight and the grantee's share, and makes the origin check
of [Facets](#facets); it forwards each request `admit/3` admits itself,
tagged with a fresh alias:

```erlang
-callback init(Grant :: map()) -> {ok, State :: term()}.
-callback admit(Request :: term(), From :: pid(), State :: term()) ->
              {forward, Service :: pid(), Request1 :: term(), State1 :: term()}
            | {reply, Reply :: term(), State1 :: term()}
            | {refuse, Reason :: term(), State1 :: term()}.
```

### Interaction with other subsystems

| Subsystem | Interaction |
| --- | --- |
| Kernel | memory objects for the sides of connections, charged to child budgets of their readers' outer budgets, one per connection, mapped writable by their writer and read-only by their reader; IRQ objects as bells, bound to groups and taken from each group's ready list; `erx_space_stop`, the fault gate and exit records for domain ends, the sub-spaces below a domain's space stopping with it ([design-kernel.md](design-kernel.md)) |
| Scheduler | every runtime validates, decodes and queues on its own grant; a facet runs on its domain's grant, capped by policy; wake-ups between domains are IRQ objects on groups ([design-scheduler.md](design-scheduler.md#park-and-wake), [design-scheduler.md](design-scheduler.md#service-work)) |
| Runtimes | every domain is a node, its creation its domain id; the peer in ERTS, with stock distribution, `erx_dist` as the carrier and one distribution entry per peer node whose controller is a port on the `erx_lane` driver, and `liberx`'s lane writer and funnel in a native domain implement the domain side; the funnel is one `liberx` library ([design-runtime.md](design-runtime.md#connections-in-erts)) |
| System domain | the domain library builds and ends domains and connections and serves every domain's fault gate; the domain service, principals and facets are Erlang in the system domain ([design-system.md](design-system.md#the-domain-library)) |
| Programs and pipes | a program's channel and a pipe's ring use the lane's layout between a session and its sub-spaces; the session's handler is the only party a program speaks to ([design-programs.md](design-programs.md#the-channel), [design-pipes.md](design-pipes.md#the-ring)) |
| Live machine | domain agents answer inspection; each runtime's connection counters are read through its agent; `erx:trace/1` with the `frames` flag traces a domain's own frames ([design-live.md](design-live.md)) |

## Compatibility and migration

Inside one domain, OTP applications run unmodified, and code compiled by
the host's OTP 29.1.2 `erlc` loads in every domain. Across domains, a
process sees every other domain as another node, reached through a
connection the system domain made: `node/0,1`, `nodes/0,1`,
`erlang:is_alive/0`, `erlang:system_info(creation)`, `monitor_node/2`,
`net_kernel:monitor_nodes/1` and `erlang:disconnect_node/1` behave as on
stock nodes, and `erpc` and `rpc` wherever the caller may spawn in the
target domain. One difference is in how identity looks, the text of a pid;
one is in naming, since registered names, and with them `global`, `pg` and
the `rpc` calls that address `rex`, stay within each domain; one is in
liveness, since no tick supervises a connection; the others follow from
authority, which a stock node does not have, and from the limits each
receiver sets. They form this closed list, each with a test. They describe
the machine from inside; toward other machines an exposed domain behaves
as a stock node does ([An exposed
domain](#domain-ids-pids-and-references)):

| Behaviour | Across domains |
| --- | --- |
| A pid's, reference's or port's text | `<D.N.S>`, `#Ref<D.a.b.c.d>` and `#Port<D.N>` with the owner's domain id, local ones included, where stock ERTS prints 0 for its own node and an index of the node name for another; `list_to_pid/1` and its kin read `D` the same way, and a `D` that is neither the domain's own nor a connected domain's is `badarg` |
| `net_kernel:connect_node/1`, and a send, link, monitor or spawn toward a node of the machine the domain has no connection with | fails as toward a node that cannot be reached: only the system domain makes connections, by introduction; no cookie or handshake plays a part |
| A pid, reference or alias of another domain | carries no authority of its own: one the owning domain never exported toward the holder's domain behaves as a dead process |
| A pid a third domain passed on | behaves as a dead process until its own domain hands it out or exports it |
| A pid, reference or alias of another machine in a frame to another domain | the frame is malformed and ends the connection; an exposed domain stands a local process in for a remote one ([An exposed domain](#domain-ids-pids-and-references)) |
| `process_info/2`, `is_process_alive/1`, `suspend_process/1`, `garbage_collect/1`, `register/2`, `erlang:trace/3` on another domain's pid | `badarg`, as for a pid of another node, in every domain the system domain included |
| Registered names | per domain: `{Name, Node} ! Msg` toward another domain is dropped and counted in the sender's runtime, as a message to a name not registered there, and `monitor(process, {Name, Node})` gets `DOWN` with `noproc` at once, or `noconnection` toward a domain whose connection is not up, as stock answers for a node it cannot reach; `global` and `pg` therefore span no two domains |
| `rpc:call/4,5`, `rpc:cast/4`, `rpc:multicall`, `rpc:async_call/4` and `erpc` | work through `spawn_request` wherever the caller's domain may spawn in the target, and fail as such a spawn does elsewhere |
| `net_adm:ping/1` toward a node of the machine | answers from `nodes()`: `pong` for `node()` and every connected domain, `pang` for any other, with no call to the peer and no disconnect, since a connection exists only by introduction ([design-runtime.md](design-runtime.md#the-edits-outside-syserxos)); `erlang:disconnect_node/1` of the system domain's node keeps its meaning, and the domain's system connection ends and with it the domain |
| `rpc:block_call/4,5`, `rpc:abcast/2,3`, `rpc:sbcast/2,3`, `rpc:server_call/4` and `rpc:multi_server_call/2,3` toward another domain | each sends to a registered name (`rex` or the caller's), which never crosses: `block_call` returns `{badrpc, {'EXIT', {noproc, _}}}`; `abcast` writes no frame; `sbcast` and `multi_server_call` list the domain among the bad nodes; `server_call` returns `{error, nodedown}` |
| `net_ticktime` and tick supervision | no tick supervises a connection between domains: a peer silent past `net_ticktime`, or starved of CPU that long, stays connected, and no connection ends with `net_tick_timeout` |
| A link, monitor or pending spawn toward a process of a domain that dies | fires, or fails the spawn, with `{domain_down, D, Info}` instead of `noconnection` (edit 56 of [design-runtime.md](design-runtime.md#the-edits-outside-syserxos)) |
| A link or monitor to a process of a domain the holder has no connection with, or that has died | fires with `noconnection`, as toward a node that cannot be reached |
| A link or monitor of a process of another domain that was never exported to the holder, or a link to one exported without `link` that holds no link with the holder | an exit or `DOWN` with reason `noproc` from the target's runtime, as for a process that does not exist |
| `exit/2` or `group_leader/2` on a process of another domain exported to the caller without `exit` | no effect, as on a process that does not exist |
| An exit reason longer than the receiver's `max_frame` or past its `max_message_heap` | `{erx_reason_too_large, Bytes}` |
| An exit reason the system domain cannot decode without creating an atom | system-domain processes see `{erx_foreign_reason, Bin}` |
| A message to a system-domain process carrying an atom it lacks, a fun or an export | dropped and counted, as ERTS drops an undecodable distribution message |
| A message whose decoding would create atoms, funs or exports beyond the receiving domain's `foreign_atoms` count, in all or for the sender's lane | dropped at `receive` and counted |
| A message carrying pids of the sender's domain | each the receiver does not yet hold is exported toward it with `send`, which covers messages and monitors; `link`, `exit` and `group_leader/2` on it need an explicit export by its owner, where stock Erlang lets a process link to and exit any pid it knows; pids of other domains in it stay data |
| A pid or alias of the sender's domain beyond the sender's `exports` | travels, and behaves at the receiver as a dead process; `erx:export/3` returns `{error, system_limit}` |
| `group_leader(GL, Pid)` with `Pid` in another domain and `GL` in a third | `badarg`; the leader must be a process of the caller's domain |
| A spawn, `erpc` call or `rpc` call into a domain that has not exported `spawn` to the caller's domain | fails with `noconnection`, as a spawn into a domain that has died; `rpc:call/4` returns `{badrpc, nodedown}`; no child runs |
| A spawn into a domain whose export table is full | fails with `system_limit`, and no child runs |
| A spawn request the target leaves unanswered | waits, as at a connected node that does not answer; the caller's timeout is `spawn_request/5`'s monitor or `spawn_request_abandon/1` |
| A message larger than `ERX_FRAME_MAX` | the send fails with `system_limit`; larger data goes in chunks or through a memory object |
| A message larger than the receiver's `max_frame` or `max_message_heap` | dropped, as for a dead process, and counted on the receiver |
| A message to a facet past its grant's `max_request` | dropped before it is decoded, and counted |
| A term nested more than the receiver's `funnel_depth` levels outside tail positions | dropped and counted |
| A malformed frame, position or term from a peer | the connection goes down: every link and monitor between the two domains fires with `noconnection`, and the peer's later frames are lost |
| Sequential-trace tokens | stripped at the boundary; a traced process's cross-domain sends arrive untraced |
| A priority message (`erlang:send/3` with `priority`) to another domain | arrives as an ordinary message |
| An exit signal to an alias of another domain's process | no effect |
| A NIF resource, ETS table or prepared-code reference that leaves its domain | a plain reference, even when it returns |
| A sender whose lane to a domain is full | suspended as for a busy connection once its entry's queue exceeds the busy limit, until the receiver drains; senders to other domains carry on |
| `erlang:send/3` with `nosuspend` | returns `nosuspend` when the destination domain is busy for the sender |
| What a runtime holds because of another domain, its links and monitors and the signals queued for it without a sender, past `peer_held` for the connection or `peer_held_total` in all | a link or monitor beyond `peer_held` is answered at once with an exit or `DOWN` with reason `system_limit`; a signal that does not fit, or the total passed, ends a connection: links and monitors between the two domains fire with `noconnection` |
| A message from the system domain to a domain whose lane from it is full past `system_queue` | dropped and counted on the receiver; no system process suspends |
| Any other signal from the system domain to such a domain | the connection ends, and with it the domain |
| A fun from another domain | travels, and runs if the receiving domain has its module loaded, as between nodes |

Nothing here owes compatibility to its own earlier forms: until a release
promises it, a change to a layout or a protocol of this document replaces
the old form outright, with no conversion and no reader for an old version.
The lane, record and frame layouts are part of the ABI: the kernel and every
runtime come from one tree, and the domain library refuses a runtime image
built for another ABI version
([design-kernel.md](design-kernel.md#image-manifests)), so a mismatch fails
loudly and a frame carries no version field. Nothing in this document
persists across a boot: export tables, connections and domain ids live as
long as the machine runs.

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A malformed frame, position or term from a peer | the receiver's funnel, or its semantic stage at `receive` | messages the funnel had already queued stay; the lane's rest is lost | the receiver ends the connection; the domain service tells the peer and deletes the connection | `noconnection` on every link and monitor between the two domains; a diagnostic with the reason code, logged once per reason; a counter on the receiver |
| A frame over the receiver's `max_frame`, `max_message_heap`, `funnel_depth` or a facet's `max_request` | the funnel | nothing | the funnel | the message is dropped, an exit delivered as `{erx_reason_too_large, Bytes}`, or a spawn answered with `system_limit`; a counter |
| A frame to a dead or unexported process | the funnel's authority step, or the target's runtime | nothing | the target's runtime | messages and exit signals vanish; links and monitors get `noproc` from the target's runtime, as for a dead remote process |
| A frame to a domain that has died | the connection down that follows the death | nothing: the lane is deleted with the connection | the domain service | links and monitors fire with `{domain_down, D, Info}` when the end arrives, or `noconnection` toward a domain already gone |
| A receiver slow to drain | the lane's room | frames waiting in the sender's runtime, in its own memory | the sender's runtime, as room returns | processes sending there are suspended, as for a busy connection |
| A receiver that never drains | nothing: it holds back only its own senders | its senders' queues, in their own memory, up to each entry's busy limit, and in the system domain up to `system_queue` | nobody; the senders' processes wait or use `nosuspend`, and the system domain drops a message it cannot queue and ends the connection, and so the domain, for any other signal | suspended senders; a counter on the system domain |
| What a runtime holds for another domain past `peer_held` or `peer_held_total` | the runtime | nothing: the ended connection's queue is discarded | both runtimes, at the connection down | links and monitors between the two domains fire with `noconnection` |
| An export refused by `exports` | the runtime | the name travels; no entry | nobody | the name behaves as a dead process at the peer; `erx:export/3` returns `{error, system_limit}`; a counter |
| A domain halts, crashes or faults | the fault gate the domain library serves | the domain's crash area, until the system domain has read the dump | the domain service: connections down, the domain pid ended, the domain destroyed | links and monitors fire with `{domain_down, D, Info}`; the domain pid exits with the detail |
| A party that never answers `connection_down` | the domain service, which holds the connection closing | the connection's objects, charged as before, counted against the party's `connections` | the domain service, once the party unmaps or ends | the inspector shows the connection closing and the party that holds it |
| An introduction's plan fails | the domain library | nothing: the plan is undone | the domain library | `create/1` or `introduce/2` returns an error |
| Domain boot fails or times out | the domain service | the domain, stopping | the domain service | `create/1` returns `{error, {boot, Reason}}` or `{error, timeout}` |

Every domain's inspector record shows its connection counters: for each
connection, frames and bytes sent and received, drops by reason (unexported
target, over a limit, foreign atom), dead-process answers, rings sent and
taken, and the connection's state; and for the domain, connections made and
ended with their reasons, and exports held and refused. `erx:trace/1` with
the `frames` flag shows every cross-domain signal a domain sends or
receives, as `{frame, From, To, Operation, Bytes}`, from the domain's own
runtime, which is the only party that sees them.

## Security

**Trust boundaries.**

| Boundary | Input | Validated by |
| --- | --- | --- |
| peer to receiver | the peer's ring header, data area and reader page | the funnel: positions against the receiver's own copies and the system domain's sizes; one copy of each record into private memory; header arithmetic; the positive grammar; the target rule; the sender rule against the lane; the export table; decoded size |
| peer to receiver | its bell | nothing to validate: a ring puts the bell's label on the receiver's ready list once, however often it is rung, and the receiver's look at the connection finds nothing or finds frames it would have drained anyway |
| peer to receiver | the positions it says it waits for, `need` and `wake` | nothing: a value is compared, never used as an address or a length; a wrong one costs at most one needless ring per crossing |
| system domain to runtime | `connection_up` and `connection_down`, the boot information | the runtime trusts its creator, which built its space and holds its budget; a message of that shape on any other lane is ignored |
| domain to system domain | frames | the system domain's funnel with the system grammar, safe decode, facets' admission, each facet's `max_request`, `max_heap_size` and share of reductions |
| client to a system service | request data | the facet's generated admission: the lane against the grantee, the operation schema, the scope, the rates; handles minted only from the facet's scope |
| sub-space to its domain | whatever its creator shares with it, its channel and its faults | its creator, which built it and serves its fault gate; no lane is ever written for a sub-space |

**Properties that hold by construction.** A pid names its owner, and
owners are never reused (D1). A node name of the machine names one live
domain and is reached only through its lane, so neither another domain nor
another machine can stand in for it (D2). Who may signal a domain's
processes depends on the kernel, which keeps every other domain's hands
off the domain's memory, and on the domain's own runtime, which alone
writes the export table and alone reads the lanes, and on nothing else:
every domain's isolation, memory, CPU and messages alike, depends on the
kernel and itself. A domain cannot tell an unexported process from a dead
one: the funnel consults neither a process's liveness nor anything the
frame says (step 5), the target's runtime answers an unauthorised link or
monitor exactly as for a process that does not exist, and the signals that
need no right produce nothing the sender can observe. Authority never
grows in transit: an export is written only by the name's owner, with
rights only the owner sets, a name handed out in a frame carries `send`
alone, and a name passed on by a third party conveys nothing (D4). The
system domain's atom table never grows from another domain's input (D5). A
domain speaks only for its own processes, because the lane says who it is
(D6). Stopping a domain needs nothing from it (D7). Every page a domain
shares with a peer has one writer, is paid for by its reader, or on a
domain's system connection by the domain, and can be deleted by neither
(D16). The funnel never recurses: it walks terms with an explicit stack in
the receiver's memory, and its structural work is linear in the frame's
length; ERTS's decoder, which completes acceptance of pending encoded
terms, is iterative apart from one nested call for each integer field of
`NEW_FUN_EXT` and `EXPORT_EXT`, which the grammar fixes as integers.

**What a hostile peer can do, and what it costs.** A hostile peer holds a
connection with the receiver, so it was introduced by the system domain's
policy. It can:

* write any bytes into its ring: the receiver spends CPU validating them,
  bounded by its own drain rate and allowance per step, and a malformed
  record ends the connection at the first bad byte, after which the peer
  costs nothing;
* flood frames at processes the receiver exported to it: each is queued
  encoded on its target until the target's queue quota pauses the lane,
  after which the peer waits on its full lane, or, for a target without a
  quota, until the target's `max_heap_size`, with shared binaries counted,
  ends it, which is OTP's own answer to a process that does not keep up;
  the receiver's drain spends what one funnel step costs per frame, and
  the peer waits whenever the lane is full;
* ring its peer's bell without pause: each ring costs the hostile peer a
  kernel call and the receiver at most one wake per wait, since triggers
  coalesce;
* publish wait positions it does not wait for: at most one needless ring per
  crossing, a kernel call of the receiver's that never waits;
* never drain the lane the receiver writes: the receiver's senders to it
  wait or take `nosuspend`, and no one else notices;
* never unmap after `connection_down`: the connection's objects stay as
  they were charged and count against the peer's own `connections`, so
  what it keeps of another's memory is bounded by its own quota, and the
  inspector shows it;
* message, call and monitor the receiver's processes whose names the
  receiver handed it in frames;
* lie about its own processes' deaths and exits, which it could cause anyway
  (D6), and rewrite its published bytes while they are copied, which changes
  only its own frames.

It cannot: name another domain's process as a sender or a target; reach a
process the receiver never exported toward it, or learn whether one exists;
link to, kill or set the group leader of a process whose name it was only
handed in a frame, a server that answered its call included, unless the
receiver exported that right or the peer spawned the process;
widen a right; make the receiver pay for any page, since the receiver paid
only for the lane it chose to read; make the receiver fault, since it holds
no delete right and writes no page the receiver executes or trusts without a
copy; or make the receiver's decoder see a tag outside the grammar.

**What a hostile runtime costs its peers.** Each peer paid for the lane it
reads from the hostile domain, sized by the peer's own `lane`; each peer
holds, for the hostile domain's processes, at most `peer_held`; each peer's
processes hold what their own `max_heap_size` allows; the system domain
holds for it at most the sum of [Flow control](#flow-control) and spends
on its requests at most its facets' shares; and each peer spends on the
hostile domain's frames at most its own drain rate. A hostile system
domain is the trusted base, as the kernel is.

**Information leaks.**

* A domain learns the node names and ids of the domains it has
  connections with, which it must, and nothing about domains it is not.
  A name refused as taken at creation tells a principal that some
  principal has bound it in this boot.
* A lane's positions reveal that a peer is slow, to a domain already allowed
  to send to it.
* `{erx_foreign_reason, Bin}` exposes only what the exiting process put in
  its reason.
* A domain can learn whether an atom exists in the system domain. Atoms are
  names, not secrets; this is accepted.
* A link or monitor of an unexported process tells the target's runtime that
  the sender knows the pid of one of its processes, and gives it the sending
  process's pid, which it can answer and nothing more.
* References are unguessable
  ([design-runtime.md](design-runtime.md#unguessable-references)), so a
  domain that can send to a process cannot forge a reply to a call that
  process made elsewhere without having been given its reference.

**Residual risks accepted.**

* **A defect in ERTS's decoder** that a well-formed frame reaches
  compromises the receiving domain, or the system domain if it is the
  receiver. The funnel's positive grammar admits only the listed encodings
  before any decoder sees them, the funnel and the decoder are fuzzed
  together, and the funnel is checked against `binary_to_term/1`.
* **A defect in a system service or its facet** acts with the system
  domain's authority. Facets confine every grant, mint handles only from
  their scope, and are tested with hostile clients. A service that passes
  another domain's message on to a facet as its own sends it without an
  envelope, as a request of the system domain, so relaying a message
  unchanged is such a defect.
* **Handing out a pid exports it for sending.** A domain that puts one of
  its pids in a message gives the receiver `send` on it, so the receiver
  can message and monitor the process until it exits, and pass the name on
  to no effect; a domain that wants a name back uses an alias.
* **A receiver that stops draining suspends the processes that send to it**,
  a server's replies to it included, as a busy distribution connection does
  in stock ERTS. Only the lane to that receiver is affected; a service
  shared by distrusting domains replies through facets or with `nosuspend`.
* **A peer can fill a process's queue** until the process's own
  `max_heap_size` ends it, if the process never takes its messages and has
  no queue quota; a domain that admits distrusting peers sets
  `-erx queue_quota` or its processes' limits, as a node that admits
  distrusting nodes must. A process at its quota pauses instead the lane
  its domain reads from that peer, and only that lane: the peer's frames
  to the domain's other processes wait behind it until the process takes
  its messages, while the peer's traffic to every other domain, and every
  other peer's to this one, flows on ([Flow control](#flow-control)).
* **Side channels**: speculative execution between domains sharing a CPU,
  and the timing of a receiver's runs, which reveals that it received
  something.

## Verification and testing

Every check below is paired with a seeded failure, a mutation of the code
under test kept beside the test that the check must catch, so a check that
passes proves the code it covers ran. Build checks have a negative fixture
for the same reason.

* **Unit and property tests, host build, under ASan and UBSan:** the lane's
  position checks against every out-of-range `wpos` and `rpos`, including
  values that overflow when added to the size; the record and frame header
  arithmetic with overflowing lengths; a record read as it is published, cut
  at every 16-byte boundary and across the data area's end, against the same
  record published whole; the grammar's acceptance and refusal of every tag;
  the target rule and the sender rule, with the new leader of `GROUP_LEADER`
  and `From` of a `SPAWN_REQUEST` as sending pids, and a third domain's
  `GroupLeader` in a spawn request kept as data; the decoded-size
  computation against ERTS's own size pass; the explicit stack's tail
  positions; the funnel's verdict table, each row driven from a frame that
  has, and one that lacks, the right it names, each over-limit
  substitution, and an `exit/2` that both lacks the right and is over a
  limit, which has no effect; a payload buffer that grows only as bytes
  arrive; `erx_funnel_check` as a pure function over the corpus, with no
  shared memory in reach; the export table: the three writers, encoding
  giving `send` alone, a control term's sender included, a spawn giving
  every right, encoding a name toward a peer that already holds it, which
  changes nothing, `erx:export/3` widening and narrowing, the end of
  holders at process exit, at every OTP alias deactivation mode, and at a
  connection's end, and a table at `exports` live entries; the busy rule
  at the entry's queue limit and the system domain's drop and end at
  `system_queue`; the reserve of a domain's lane from the system
  domain, filled with ordinary frames and then given one control record
  per connection, and given as well, while full to the reserve's edge, a
  record of a control record's shape from a sender other than the domain
  pid, which waits as an ordinary frame; seeded failure: a writer that
  classes records by shape, under which that record takes the reserve and
  a later control record does not fit; the runtime's `peer_held`
  accounting and its choice of the connection to end; the domain
  service's introduction checks against `erx:exports/1` of each domain
  pid.
* **Exhaustive exploration of the protocols**, as pure state machines in
  `liberx`'s functional core. An independent TLA+/TLC model checks the
  connection's lifetime and ordering contract, with every invariant mapped
  to concrete implementation checks under
  [Protocol verification](design-verification.md). Host exploration compares
  the actual cores with independent expected outcomes:

  * one lane, with every interleaving of writes of one, two and partial
    records, reads, wake positions published and crossed, and the two
    fences, checking that no wait is lost, that a record read in parts
    equals the record written, that `rpos` never passes `wpos`, and that a
    party rings only when its store crossed the published position;
  * one connection between a domain and a peer that ends, followed by a
    later domain of the peer's name introduced to the same domain, with
    every interleaving of frames in both lanes, the peer's stop, the
    domain service's `connection_up` and `connection_down` and their
    answers, the finish and the deletion, checking D9, D16 and D17: every
    frame the dead peer published is delivered, nothing is delivered
    after the `{domain_down, D, Info}`, no object is deleted while a live
    party that has not answered maps it, every connection whose parties
    have let go is deleted, at most one control record per peer name is
    outstanding, the later `connection_up` never reaches the domain while
    its entry for the name is up, and a runtime that answers
    `connection_unmapped` never touches a deleted page; seeded failures:
    a domain service that sends a connection's `connection_down` before
    the answer to its `connection_up`, under which two records about one
    peer name are outstanding, and a finish that reads the write position
    again after it starts, under which a live peer's later frame is
    delivered after the `connection_down`;
  * cross-domain links and monitors between three domains with every signal
    kind, links and monitors of dead and unexported processes, a death and a
    connection ended by a malformed frame, checking that every answer about
    a process arrives after everything that process sent first.
* **Weak memory.** The two wake handshakes, the producer's store of `wpos`,
  fence and load of `wake` against the consumer's store of `wake`, fence and
  load of `wpos`, and the consumer's store of `rpos`, fence and load of
  `need` against the producer's store of `need`, fence and load of `rpos`,
  are litmus tests checked with herd7 under the memory model of each
  architecture erXos runs on, AArch64's first, each together with the same
  protocol without its fences, which must fail. So are the two
  publications, the producer's writes of a record then its release store
  of `wpos` against the consumer's acquire load of `wpos` then its loads of
  the record, and the consumer's loads of a record then its release store
  of `rpos` against the producer's acquire load of `rpos` then its writes
  over that room, each together with the same protocol with its acquire
  load made relaxed, which must fail by showing a byte that is stale or
  overwritten. The first is checked under the C11 model (RC11) as well;
  the second's relaxed form is load buffering, which RC11 forbids for
  every access order, so it is checked under each architecture's model
  alone. `make check-litmus` runs them (`test/litmus/`). A
  host test under
  ThreadSanitizer runs a producer and a consumer over one lane while a third
  thread rewrites the producer's pages, and checks that the consumer's
  copies are whole or refused and that no read races a write.
* **Differential tests.** Every payload the complete two-stage funnel
  accepts decodes with `binary_to_term(Bin, [used])` to the same term from
  its unchanged original bytes and uses exactly its length. The corpus
  includes distinct pid and reference map keys, nested compound keys,
  duplicate semantic keys encoded differently, empty and deeply nested maps,
  and records at every part boundary of a lane. Structural acceptance alone
  is never counted as success. Native semantic acceptance and rejection are
  compared case by case with the pinned OTP oracle. A scenario suite of
  sends, links, monitors, exits with every reason shape, spawns with link
  and monitor, aliases, group leaders and unlink races runs between two
  domains on erXos and between two stock OTP 29.1.2 nodes on the host; every
  difference outside the compatibility table is a bug.
* **Fuzz targets** (`make check-fuzz`): the funnel over a corpus of valid
  frames and their mutations, fed whole and in parts at random boundaries,
  checking that the verdict is one of the table's and that budgets return to
  their baselines; the lane reader over mutated ring headers, record headers
  and reader pages; `liberx`'s `erx_etf` decoder; the system domain's safe
  decode, checking that its atom count never changes; and the facets'
  generated admission over mutated requests.
* **Hostile runtimes** under QEMU, with HVF. Each is a native
  test domain that holds a connection with the domain under test and does
  one of these:
  * floods frames at a facet, at a process that never reads, and at many
    destinations at once: the receiver's memory stays within each target's
    queue quota and one frame where it has one, its `max_heap_size` where
    it has none, and its own budget; the flooder blocks on its own lane,
    and an innocent peer's latency to the same receiver holds; a facet
    that never reads holds at most its quota and one frame, measured
    before any collection, and its grantee's lane fills. Seeded failure: a
    funnel that ignores the quota, under which the facet's undecoded bytes
    pass that bound before its next collection;
  * fills a process of the receiver with casts up to its queue quota while
    that process makes a `gen_server:call` to the hostile domain, whose
    reply comes behind the casts: the call returns the reply, and the
    casts are decoded into the process's queue and count toward its
    `max_heap_size`. Seeded failure: a runtime that waits without
    decoding, under which the call times out;
  * forges senders, pids, aliases, references and domain ids, in control
    terms and in payloads: every frame with a sending pid of another domain
    ends the connection, and every name of another domain in a payload stays
    data;
  * forges link exits, `DOWN`s, unlinks and spawn replies;
  * names pids and aliases of the receiver's that were never exported to it,
    and ones a third domain passed it: each is answered as a dead process,
    in order with what the receiver sent before, and the timing matches a
    dead process's;
  * writes positions out of range, records with bad headers, unknown tags,
    terms with duplicate map keys, and frames past every limit: the
    malformed ones end the connection at the first bad byte, the over-limit
    ones are dropped and counted, and a frame after an over-limit one is
    delivered;
  * rewrites its ring header and published bytes while the receiver reads
    them: the receiver's copies are whole or refused, and nothing else
    changes;
  * rings its peer's bell without pause, from many domains on every CPU,
    while another domain ends: the end is handled within a bounded number of
    the receiver's steps, and each ring costs the receiver at most one look;
  * publishes wake positions it never waits for, and never publishes them
    while it waits: at most one needless ring per crossing, and a waiter
    that follows the handshake is always rung;
  * never drains the lane the receiver writes: the receiver's senders to it
    suspend at the busy limit, `nosuspend` returns `nosuspend`, senders to
    other domains carry on, and a system-domain process never suspends;
    the system domain holds at most `system_queue` for it, drops its
    messages past that, ends its connection, and so the domain, at the
    first other signal past it, and still writes every connection-control
    record into the reserve;
  * opens a record of the receiver's `max_frame` and trickles its bytes, on
    many connections at once: the receiver holds what has arrived and no
    more;
  * ignores `connection_down`: the connection stays closing and counted
    against the hostile domain's `connections` until it ends, and nothing
    else changes; one that answers `connection_unmapped` and keeps its
    mappings faults on its next access, in its own domain;
  * holds many processes of the receiver with links and monitors, and floods
    unlinks at it, until `peer_held` and `peer_held_total` end its
    connection and not an innocent domain's;
  * sends facets requests with dense lists, compound maps and large decode
    scratch requirements, and requests past their grant's `max_request`,
    from many domains at once: the oversized ones are dropped undecoded,
    each facet stays within its `max_heap_size`, and the system domain's
    memory, measured at its peak before each collection, stays within the
    sum of [Flow control](#flow-control) for each admitted domain;
  * sends a facet requests whose cost grows with state it built in the
    service: the reductions spent on its requests per period stay within
    its share plus the requests it had in flight when the share ran out,
    the overrun is repaid in the next period, and another grantee's
    requests are served meanwhile;
  * links to, exits and sets the group leader of processes of the receiver
    whose pids it was handed in replies: the link is answered with
    `noproc`, the exit and the group leader have no effect, and a monitor
    of the same process works;
  * spawns into a domain that has not exported `spawn` to it, into one whose
    export table it has filled, and into one that never answers: the first
    fails with `noconnection`, the second with `system_limit` and no child
    runs, and the third waits until the caller's own timeout;
  * stops with frames published and unread in its lane: every one arrives at
    each peer, then the death;
  * monitors and links processes it was never given, and processes that sent
    it messages and then died, and checks that every answer arrives after
    those messages.
* **Hostile clients** of each system service send requests naming pids they
  do not hold and reply targets in other domains; they expect refusals, and
  other clients' requests are served on time. A domain H that grantee G
  introduced to G's facet, to G's pid and to a reply alias of G's asks the
  facet, with `From` set to G's pid and that alias, for an exit signal to a
  process that H holds with send and G holds with exit: H's frame never
  reaches the facet, since the facet's pid was exported to G alone, and when
  the test exports it to H as well the facet refuses the request as not from
  its grantee, so the process lives either way. A reply to one of a facet's
  forwards that comes from a domain other than the service's, or comes
  twice, and a `'DOWN'` tuple sent as a message, are refused as requests not
  from the grantee; an attenuating facet's request through the facet behind
  it, and a request to a facet of a service in the system domain, are each
  answered, the reply coming without an envelope and taken by its tag; the
  facet behind an attenuating facet exits, and the attenuating facet exits
  with the same reason, while a command domain's end, which ends its facets,
  leaves its starter's facet serving; a session's own facet, run by the same
  behaviour, refuses every domain but its grantee; a revoked facet, whose
  attenuating facets end with it, whose queued requests get no answer and
  whose caller's monitor fires, while a request it forwarded before
  completes at the service; a callback that reaches an authority-consuming
  effect without a handle fails the build check.
* **Node identity**, under QEMU and in the hosted build, each with its
  seeded failure:
  * two domains the system domain connects: each one's `node()` is its
    name at the machine's host and `erlang:system_info(creation)` its
    id; `nodes()` lists exactly the domains connected to it before an
    introduction, after it and after the connection ends, and
    `monitor_node/2` and `net_kernel:monitor_nodes/1` deliver `nodeup`
    and `nodedown` for each; `net_kernel:connect_node/1` toward a domain
    it has no connection with returns `false`. Seeded failure: a carrier
    whose setup reports success, under which the connect returns `true`
    and a send waits on a node that never comes up;
  * a monitor of a process of another domain fires `DOWN` with the
    process's own exit reason when the process exits while the
    connection stays up. Seeded failure: the peer's flag set without
    `DIST_MONITOR_NAME`, under which ERTS never sends `MONITOR_P` and
    the monitor fires only when the connection ends;
  * a domain ends and a later domain of the same name is introduced to
    the same peer: the later one has a new creation, `nodedown` then
    `nodeup` reach the peer in that order, and a frame from the peer to
    a pid of the ended domain is answered as for a dead process, the
    connection staying up. Seeded failure: a target rule that requires
    the receiver's creation, under which that frame ends the
    connection;
  * creating a domain under a name a live domain holds, or one another
    principal bound earlier in the boot, fails with `name_taken`, and a
    principal past its `names` gets `quota` and leaves the system
    domain's atom count unchanged. Seeded failure: a domain service
    that makes the name's atom before its quota check, under which the
    count grows;
  * `{Name, Node} ! Msg` toward another domain leaves no frame in the
    lane and counts a drop, and `monitor(process, {Name, Node})` gets
    `DOWN` with `noproc` at once; a hostile runtime that writes a
    `REG_SEND` ends its connection. Seeded failure: a peer that writes
    the `REG_SEND`, under which a correct sender's connection ends;
  * `rpc:call/4`, `rpc:cast/4` and `erpc:call/4` into a domain that
    exported `spawn` to the caller's run the call, and `rpc:call/4` and
    `erpc:call/4` into one that did not return `{badrpc, nodedown}` and
    raise `{erpc, noconnection}`; `rpc:block_call/4`, `rpc:abcast/2`,
    `rpc:sbcast/2`, `rpc:server_call/4` and `rpc:multi_server_call/2`
    toward a connected domain give the answers the compatibility table
    lists and leave no frame in the lane. Seeded failure: a sender without
    the drop of registered-name operations, under which `block_call`'s
    request reaches the lane and the receiving funnel ends the connection;
  * `net_adm:ping/1` returns `pong` for the creator's node and the system
    domain's and `pang` for a domain with no connection, and every
    connection stays up. Seeded failure: stock `ping/1`, under which the
    ping of the system domain's node returns `pang` and ends the domain;
  * `pid_to_list/1` of a local pid, a peer's pid and a pid of an ended
    domain prints each with its own domain id, the last also once a later
    domain of the ended one's name is connected, and `list_to_pid/1` of
    the first two returns the same pid while the third, whose domain no
    connection names, is `badarg`. Seeded failures: the stock printing of
    the channel number, under which the local pid prints as `<0.N.S>`, and
    printing the distribution entry's creation, under which the ended
    domain's pid prints the later domain's id;
  * a domain starved of CPU for twice `net_ticktime`, with `net_ticktime`
    at its minimum in it, in its creator and in the system domain, keeps
    both connections and runs on once it gets CPU again. Seeded failure:
    an `erx_dist` whose connection owner acts on `net_kernel`'s ticks as
    `dist_util` does, under which the starved domain's system connection
    ends and the domain stops.
* **Connections:** a domain created by another gets exactly two
  connections, to the system domain and to its creator, and each party's
  capability table holds no `DESTROY` on any of their objects; an
  introduction by a domain that holds `introduce` on one of the two domain
  pids and not the other, or holds both with `send` alone, as a domain pid
  read from an inspector's listing gives it, is refused with `badarg`, as
  is one naming a domain that does not exist (seeded failure: a domain
  service that checks `send`, under which the holder of `send` alone
  introduces the two); `erlang:disconnect_node/1` and a malformed frame
  end a connection the same way, with `noconnection` at both ends and the
  objects deleted after both parties unmapped; a domain whose connection
  to the system domain ends, by either party, is stopped; two domains
  introduced again get fresh lanes that start empty, with no holder of the
  earlier connection left; a domain at `connections` is refused an
  introduction with `system_limit`; a domain whose creator sends to its
  init and spawns into it at once has none of those frames dropped.
* **Domain pids:** `erx_domain:stop(Domain, kill)`, a supervisor's brutal
  kill of a domain pid and a fault in one each stop the domain, and its
  monitors see the domain pid's exit; a domain pid ended any other way ends
  its domain too; a holder of the domain pid without the exit right cannot
  stop the domain.
* **Soak:** a million `gen_server` calls into another domain from
  short-lived processes, and as many from one long-lived process, a tenth of
  whose calls time out, and as many short-lived callee processes that each
  hand their pid out once and exit; every answered call returns, and the
  callee's export table stays at its live names (D13).
* **Invariant tests:** D1 by creating and ending domains in a loop; D2 with
  the `list_to_pid` property, the name-taken refusals and the later
  domain of an ended domain's name; D3 with the build check on readers of a lane's pages; D4 with
  the hostile runtimes that forward names and forge senders, and the build
  check on service callbacks; D5 with a fresh-atom frame and the `names`
  quota; D6 with forged
  exits; D7 with runtimes that never return or never drain; D9 with
  three-domain interleavings; D12 with floods past each receiver limit; D13
  with the soak; D16 with the capability-table check, the budget
  baselines and a survivor that never answers `connection_down`; D17 by killing a domain mid-burst on every CPU.
* **The connection protocol under QEMU:** a domain whose init delays its
  ready report while its creator writes a spawn request into their
  connection: the domain's `connection_up` waits in the domain service's
  record, the spawn runs once the domain has reported ready and mapped,
  and `create/1` returns first; seeded failure: a domain service that
  hands the domain pid the record before the report, which the domain
  pid, knowing no agent yet, cannot send, so the spawn never runs. The
  creator sends the domain pid `{erx_connection_lost, Peer, disconnect}`
  for the domain's live connection to `Peer`, and a peer that was handed
  the agent's pid sends the agent `{erx_connection_down, Peer,
  noconnection}`: both are dropped and counted, and the connection
  carries frames on; seeded failures: a domain pid without its origin
  check and an agent without its origin check, under each of which the
  connection goes down.
* **Sub-spaces and programs:** a domain that ends with sub-spaces nested
  three deep while its connections carry traffic, whose peers see one death,
  for the domain, behind everything it sent; a program that tries to write a
  frame finds no lane to write it in.
* **Transcript tests:** a domain's lifecycle from the shell; a spawn with a
  link into a domain that then crashes, delivering `{domain_down, D,
  crash}`; forged pids inside a domain doing nothing.
* **Concurrency:** the lane protocol and the funnel on the hosted build
  under ThreadSanitizer, with every executor of a domain ringing one connection's bell at once.
* **Determinism:** a deterministic-mode transcript of a domain's life is
  byte-identical across runs.

## Performance

**Cost model.** A message within a domain is an ERTS local send; waking a
parked receiver adds one `erx_executor_wake` call. A message across domains
adds the encode into the lane, one copy out of the lane into the receiver's
private memory with the funnel's linear pass over it, and the decode at the
receive that examines it; it crosses one thread boundary, from the sender's
executor to the receiver's, and costs a kernel call only when the receiver
published a wake position the write crossed, in which case the receiver's
wake adds the kernel's wake latency. A full lane adds the producer's wait
and one ring when room returns. There is no third party, no second copy and
no per-frame bookkeeping anywhere but in the two runtimes.

**Budgets**, targets until E-D1 to E-D4 measure them:

| Measure | Budget | Basis |
| --- | --- | --- |
| Round trip of a small message between two domains, both runtimes busy, HVF | 1 us | two encodes into lanes, two copies of a few hundred bytes, two funnel passes and two decodes, with no kernel call (target) |
| The same with both runtimes parked | 1 us plus two wake latencies | the above, each direction adding one ring and one wake; wake latency is experiment E-S4 (target) |
| Throughput of 512 KiB binaries between two domains, HVF | 2 GB/s | one copy of each byte plus the receiver's structural pass, through a 64 KiB lane refilled as the receiver drains, with one ring per lane's worth when the sender waits (target) |
| Spawn into another domain, round trip, HVF | 10 us | a request frame, ERTS's spawn and a reply frame (target) |
| Domain creation to a ready init process, HVF | 300 ms | an embedded boot of a small release takes 0.13 s on the host and translating a module 0.8 to 2.4 ms (both measured, [research](research-baselines.md)), plus the space, two connections and the first frames (target) |
| Memory of one connection | 2 x (8 KiB + the reader's `lane`), plus two IRQ objects: 144 KiB at the default, 72 KiB paid by each party | arithmetic on the layout and the defaults |
| What the system domain pays per live domain | no kernel object: its mappings of the domain's system connection and the slots that name it, and at most its `max_frame`, `system_queue`, its `peer_held` and the facets' heap limits, which it reserves at admission ([Flow control](#flow-control)) | arithmetic on the layout and the defaults |
| What a domain pays for its connections | 72 KiB each at the default, at most `connections` times that: 18 MiB at 256; and its system connection, both sides: 16 KiB, `system_lane`, and the data area of its lane from the system domain, the smallest power of two that holds its `lane` and the reserve; all from its outer budget, through one child per connection | arithmetic on the layout and the defaults |
| A runtime's export table | `exports` entries of a few dozen bytes each: under 1 MiB at 16,384 with the table's overhead | arithmetic on the layout and the default |

For comparison, on the development host, a same-node ERTS ping-pong measured
410 ns (a second, noisier run gave 1,734 ns) and distribution over TCP
loopback 57 us ([research](research-baselines.md)).

**Experiments.**

| Experiment | Hypothesis | Method | Measurement | Decision it informs |
| --- | --- | --- | --- | --- |
| **E-D1**, messaging cost | small-message round trips meet 1 us busy under HVF, and a 64 KiB lane carries large frames within a factor of two of a lane that holds them whole | `tools/erx bench xdomain-pingpong` and `xdomain-throughput` between two domains, at lane sizes of 16 KiB, 64 KiB and 1 MiB, against same-node and loopback-distribution baselines on the host | round-trip distribution, throughput by frame size and lane size, rings per megabyte, CPU per frame in each runtime | the default `lane` and `system_lane`, the producer's wait rule, and whether ERTS encodes straight into the lane |
| **E-D2**, many connections | a domain with `connections` peers all active drains fairly, and a ring costs the receiver one bounded look | many domains sending small frames to one receiver, with skewed load | latency per peer against load; the receiver's CPU per frame and per ring | the funnel's allowance per step, and whether the ready list's order needs a fairness rule |
| **E-D3**, death | a domain's death reaches every linked process within 1 ms of the stop, and a kill within one reduction slice when the runtime complies | `tools/erx bench domain-lifecycle`: kill domains with many cross-domain links; kill processes busy in Erlang code and in NIFs | time from stop to the last death handled; kill latency | the death path's batching |
| **E-D4**, receivers that stop draining | at the defaults, a sender keeps its throughput and latency to responsive receivers however many of its other receivers stop draining, and a busy domain never falls behind the system domain's queue | `tools/erx bench xdomain-stall`: one sender streams small and 512 KiB frames to N receivers, of which K stop draining; a responsive receiver measures what it gets; domains busy at their quotas receive the system domain's replies and signals | the responsive receiver's throughput and latency against K and frame size; the system domain's queue per domain at its peak | the busy limit's default, `system_queue`, and the facets' `max_request` and heap limits |

Each result records host, accelerator, QEMU version, compiler, flags,
workload and baseline; TCG numbers are never compared with HVF numbers.

## Portability

Nothing here depends on a board. The lane and record layouts are
little-endian, as the machine is; terms inside frames are the external term
format. The funnel, the lane writer, the export table and `erx_etf` are
portable C17 and build for the host, where their unit tests, fuzz targets,
exhaustive models and the hosted build run them.

## Dependencies

No new dependencies: the boundary reuses ERTS's distribution layer, part of
OTP 29.1.2, and `liberx`; the lane follows the single-producer,
single-consumer shared-memory queue that the seL4 Device Driver Framework
uses between components, as a model and nothing imported.

## Alternatives considered

**A router between domains.** A native service in a domain of its own would
carry every cross-domain frame: each domain writes into an outbox ring the
router reads, the router validates the frame, checks that the sender was
introduced to its target against tables the router keeps, and writes the
frame into the receiver's inbox ring. It buys two things. Ring memory per
domain is constant, an outbox and an inbox, against two lanes for each pair
of domains that have been introduced; and a parser crash ends the router, a
small program that can be restarted, rather than the receiving runtime.
erXos does not take it, for four reasons. Each frame costs three copies,
outbox to router to inbox and once more into the receiver, and up to three
thread hops with two to four kernel calls, against one copy, one hop and at
most one call on a lane. It puts a trusted base for messaging outside the
domain: a defect in the router delivers a frame to a process its sender was
never given, so every domain's isolation depends on a third party as well as
on the kernel and itself. It is a star: the router's deadline is
machine-wide, so one missed deadline on one control call is a net split that
fires every cross-domain link and monitor on the machine, and everything
that keeps the star honest, status pages, per-direction epochs,
acknowledgements of down events, executor ownership rules, grace-period
reclamation, inbox room reserved per domain, exists only because the star
exists. And its one distinctive power, a third party introducing names on a
sender's behalf, is unused: no flow in the design grants a name its granter
does not own, since delegation of a process is its owner handing the name
out and delegation of a service is a facet. What the router validated at the
sender, the receiver validates anyway, since it must defend its own decoder;
doing it once, at the receiver, deletes the second pass and the service that
ran it. The memory the router saved comes back in a weaker form: lanes are
created only for pairs that are introduced, and sized by the reader, so a
domain with few peers pays for few lanes, and each domain pays for the
small lane the system domain reads from it.

**Domains as stock nodes over stock distribution.** Each domain would
run a whole ERTS node that finds its peers through a port mapper,
authenticates them with cookies and a handshake, and talks to them over
sockets, with every connected node trusted with everything. The user
rejected this as "a glorified container runtime". erXos keeps the node,
its name, its creation and ERTS's own distribution layer, and changes
what lies under and around them: the system domain introduces domains
instead of discovery and handshakes, a lane stands where a socket would,
authority is the export table each domain's own runtime keeps, one CPU
authority schedules every runtime's executors within grants, and
supervision and inspection span domains.

**One node name for every domain, with the domain id as creation.**
Every runtime would run under the machine's one node name, so `node()`
would be the same atom everywhere and a domain would differ from another
only by its creation. It saves a node name per domain and keeps pids of
every domain under one name. erXos does not take it: stock ERTS takes a
pid of its own name and another creation as one of an earlier run of
itself, so the design would need edits to ERTS's node table, to the
same-name handling of its send path and to `create_dist_channel`, which
refuses the own name; and `node()`, `nodes()`, `monitor_node/2`, `rpc`
and `net_kernel` would mean nothing across domains, since every domain
would be the same node.

**Registered names exported across domains.** A domain would export a
registered name as it exports a pid, so `{Name, Node} ! Msg`, monitors
by name, `global` and `pg` would span the domains that export their
names to each other. erXos does not take it: a registered name is one
anyone can guess, not one its owner handed out, and `global` and `pg`
are registries whose members register and join names on each other's
behalf, so a domain that exported their names would let its peers write
its name tables. Names across domains are the exports the owner's
runtime writes, and services are facets.

**Process records in a kernel-resident runtime.** ERTS would run in the
kernel and give every process of every domain a record there holding its
pid, links, monitors and run state. It loses with ERTS as the kernel: the
kernel would carry a runtime, every spawn would create a kernel object, and
the proposal asks for neither.

**A registry of pid blocks.** A service would hand each domain blocks of pid
numbers and keep a table from block to owner. Using the domain id as the
creation gives the same uniqueness with no registry and no table, and it
removes the stale-pid problem of reusing a block after its owner died.

**The funnel in the kernel.** The kernel would parse the external term
format on every cross-domain message. It loses: the kernel would carry a
term grammar and the export tables that only Erlang's semantics need, and
every runtime would pay a kernel entry per message.

**One inbox per domain with many producers.** Every peer would write into
one ring of the receiver's. A ring with several distrusting producers needs
either a kernel call per write to serialise them or a lock they share, which
any one of them can hold forever; and the receiver could not tell its
producers apart or charge them separately. A lane per pair has one producer
by construction, so the sender's identity is the lane and the lane's cost
falls on the party that chose its size.

**Frames as pieces with reassembly.** A frame longer than a record would
travel as fragments with first and last marks, and the receiver would
reassemble them, with an abort record for a frame that failed midway. On a
lane with one producer and one consumer, in order, a record read as it is
published is the same thing with no marks, no abort and no reassembly state
anywhere but the reader's place in the one record.

**Wait flags cleared by the ringer.** A waiter would set a flag and the
party that rings it would clear the flag by an exchange, which is how a
pipe's ends wake each other. That needs the ringer to write a word the
waiter owns, so the two parties would share a page both write. A published
wake position that the mover only compares keeps every page of a connection
with one writer, and gives the mover a rule, ring when the store crossed it,
that cannot ring twice for one wait.

**Lanes that hold the largest frame.** Each lane would be at least as large
as the largest frame a domain may send, so a frame always fits whole. At a
megabyte per lane that is two megabytes per connection and a gigabyte for
the system domain at a thousand domains, most of it empty. Reading a record
as it is published lets a lane be as small as the receiver likes.

**The sender bounding frame sizes.** A sender would learn each receiver's
limits and refuse to send what the receiver would not accept. The receiver
must bound what it buffers anyway, since it cannot trust what a sender
learnt, so the receiver's own `max_frame` is the one bound that matters, and
a frame past it is dropped as a message past `max_message_heap` is, which
stock ERTS does for an undecodable message.

**An ingress allowance per peer.** The receiver would count the bytes of
each peer's frames its processes have not yet taken and stop draining that
peer's lane past one bound per peer. It charges every process's backlog to
the peer, so one slow process holds back the peer's frames to every other
process whatever their own queues hold, and a bound per peer says nothing
of the process whose memory grows. erXos bounds each process instead, by
its queue quota ([Flow control](#flow-control)): the count is charged to
the process that does not keep up, a pause starts only at a frame for that
process, and a process decodes everything queued on it before it waits
at its quota, so it never holds a pause while it waits for a peer's
answer. OTP's own bound alone, each
process's `max_heap_size` with queued frames counted, is not one: OTP
checks it only when the process collects, and a process that does not run
does not collect while the funnel drains into it.

**Imports kept by the sender.** Each domain would keep a table of the names
it holds and refuse at the sender what it does not hold. It would be a copy
of the truth the receiver keeps, drifting from it at every process exit and
alias deactivation, and a hostile sender would ignore it. The receiver's
table is the one that is enforced, so it is the only one.

**Pids that carry authority.** Safe Erlang made pids unforgeable
capabilities. In ERTS, pids are forgeable by design (`list_to_pid/1`),
printed and compared everywhere; exports keep names and authority apart, as
Zircon does with handles.

**Every right on a handed-out pid.** Stock Erlang lets a process link to
and exit any pid it knows, so handing a pid out in a reply would give
`link` and `exit` with it, and a client could kill a server it called, or
redirect its group leader. erXos narrows this on purpose, since a pid is a
name, not an authority: handing a pid out gives `send`, which covers what
answering a call and monitoring a server need, a spawn gives the spawner
what ERTS gives a parent, and every other `link` or `exit` is the owner's
explicit export. The cost is a documented difference: a process that links
to a pid of another domain it was only handed gets `noproc`, so code that
links to its clients across domains monitors them instead, unless that
process has already linked it, in which case the link exists.

**Revocable pid exports.** A domain would withdraw a right it handed out. A
withdrawn pid would behave dead to one peer and alive to another, which no
Erlang program expects; facets give revocation by exiting and aliases by
deactivation, so pid exports stay for the life of the process.

**Synchronous cross-domain calls.** A call primitive would make request and
reply one operation. Erlang's semantics are asynchronous messages with links
and monitors, and native code that wants calls has IPC gates inside its
own domain.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Cross-domain messaging costs too much for real applications | low | medium | E-D1 before user domains build on it; one copy and no third party leave little to remove; ERTS encoding straight into the lane if E-D1 shows the encode copy matters |
| Small lanes throttle large frames into many turns | medium | low | a record is read as it is published, so a large frame costs turns, not failure; E-D1 sets the default and a domain raises its own `lane` |
| A domain with many connections spends too much on draining and ringing | medium | medium | E-D2; the ready list names only the lanes that rang; the allowance per step bounds each look |
| Code that links to a pid of another domain it was only handed fails with `noproc` | medium | low | the compatibility table states it; OTP's own cross-node calls monitor rather than link; a server that links to its clients monitors them across domains, or its clients' domains export `link` to it |
| A busy domain falls behind the system domain's queue and is stopped by a signal past `system_queue` | low | high | the system domain sends a domain few signals; E-D4 sizes `system_queue`; the inspector counts the system domain's queue per domain |
| A peer fills a process's queue until `max_heap_size` ends it | medium | low | stock Erlang's exposure to a connected node; a domain that admits distrusting peers sets `-erx queue_quota` or its processes' limits; the receiver's budget bounds the rest |
| A distribution entry per peer costs a domain with many connections more than its frames do | low | medium | entries are stock ERTS's and exist only for introduced pairs; E-D2 measures |
| Stock tools that assume a fully connected network or names that span nodes, `global`, `pg` and code that sends to `{Name, Node}`, misbehave across domains | medium | medium | `connect_all` is `false` in erXos's releases; a named send leaves no frame and is counted at the sender; the compatibility table states it; services are reached through facets and `erx:cap/1` |
| One principal takes a name before the principal or the configured domain meant to hold it, since names bind by first use | medium | low | configured domains are created first at boot; names confer no authority, since exports are by domain id; the domain service's naming policy may reserve names ([design-system.md](design-system.md#identifiers)) |
| The sum of the principals' `names` outgrows the system domain's atom table | low | high | the administrator sets `names`; the domain service makes an atom only within it, so the system domain's atom growth is a sum fixed by configuration |
| The peer's flag set changes semantics in a way tests miss | medium | medium | the two-node differential suite; a closed compatibility table with a test per entry |
| Printing local pids as `<D.N.S>` breaks code that parses pid text | low | low | OTP's suites find it; each case is a documented difference |
| A frame admitted by the funnel crashes ERTS's decoder | low | high | the positive grammar; fuzzing funnel and decoder together; the differential against `binary_to_term/1` |
| A runtime that never answers `connection_down` keeps a dead peer's lane memory | low | low | bounded by that runtime's own `connections` quota; the inspector shows the connection closing and the party that holds it |
| The domain service is on the path of every introduction | low | low | introductions happen at creation and at grants, not per message; the domain library's plan is bounded work |

Open question for the user: how a principal comes to hold a domain name.
The design binds a name to the principal whose domain first takes it, for
the boot, within that principal's `names` (sessions and command domains
take pooled names instead,
[design-system.md](design-system.md#identifiers)), which keeps the system
domain's atom table bounded and keeps a node name meaning one principal's
domains; the alternative is names the administrator assigns to each
principal in the configuration, which closes squatting and makes the atom
bound exact at the cost of a configuration step per name. The
recommendation is binding by first use, with the configured domains' names
held from boot. The user's decisions on every domain being a node,
spawners' rights, pid text and names as exports are recorded where they
apply: every domain is a node named by its identifier at the machine's
host, its creation its domain id ([Domain ids, pids and
references](#domain-ids-pids-and-references)); a spawner holds every right
on its child in another domain ([Authority](#authority)); every pid prints
as `<D.N.S>`, local pids included, a documented difference from stock OTP
([Domain ids, pids and references](#domain-ids-pids-and-references)); and
a process's own pid, placed in a frame by its owner, exports it, with
`send` alone ([Exports](#exports)).

## References

* The research records:
  [research-erts-internals.md](research-erts-internals.md) (sections
  Distribution, Sending and copying, Links and monitors, Pids, Spawn
  atomicity, Mailbox limits and accounting, External term format, Census of
  node-global state, Inspecting and controlling another process, Loader
  trust), [research-prior-art.md](research-prior-art.md) (Lessons, Other
  systems), [research-baselines.md](research-baselines.md) and
  [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md)
  (Identity and lifecycle).
* Erlang/OTP 29.1.2: `erts/doc/guides/erl_dist_protocol.md` (operations and
  flags; `SPAWN_REQUEST`), `erts/doc/guides/erl_ext_dist.md` (`RECORD_EXT`),
  `erts/emulator/beam/external.c:4006-4025` (native record encoding) and
  `:5338-5348` (duplicate record field names refused),
  `erts/emulator/beam/utils.c:1715-1810` (pid order by serial, number and
  node), `erts/emulator/beam/erl_term_hashing.c:273-278` and
  `:1464-1467,1499-1502` (`phash` and `phash2` of pids by number),
  `erts/emulator/beam/erl_node_container_utils.h:100-116` (the channel
  number printed in pids),
  `erts/emulator/beam/erl_proc_sig_queue.c:2707-2729` and `:6663-6694` (an
  unlink acknowledged whatever its target's state), `:4864-4870` (a spawn
  request failed by a connection going down), `:5551` (lazy decode of a
  distributed message) and `:5708-5724` (a stale spawn reply dropped),
  `erts/emulator/beam/dist.c:3224-3228` (signals without a process ignore
  the busy state) and `dist.h:213` (the busy limit),
  `lib/stdlib/src/gen.erl:252-283` and `:549-552` (calls through a monitor
  alias, demonitored when answered or timed out, and replies through the
  alias); read 2026-10-29 and 2026-10-30.
* M. S. Miller, "Robust Composition: Towards a Unified Approach to Access
  Control and Concurrency Control", PhD dissertation, Johns Hopkins
  University, May 2006, sections 2.2 (Attenuating Authority), 6.2
  (Composites and Facets) and 9.3 (Selective Revocation: Redell's Caretaker
  Pattern),
  <https://papers.agoric.com/assets/pdf/papers/robust-composition.pdf>; read
  2026-10-31. Section 9.3 credits the caretaker to D. D. Redell, "Naming and
  Protection in Extensible Operating Systems", PhD thesis, University of
  California, Berkeley, November 1974.
* N. Hardy, "The KeyKOS Architecture", Operating Systems Review, September
  1985; Key Logic's eighth edition, December 1990, section Domain service (a
  start key's data byte, delivered with each message sent through that key),
  <https://pdos.csail.mit.edu/6.828/2008/readings/keykos-osr.pdf>; read
  2026-10-31.
* D. Fett, B. Campbell, J. Bradley, T. Lodderstedt, M. Jones and D. Waite,
  "OAuth 2.0 Demonstrating Proof of Possession (DPoP)", RFC 9449, September
  2023, section 2 (sender-constrained and bearer tokens).
* Safe Erlang (Brown and Sahlin, ICICS 1999), KaffeOS (Back, Hsieh and
  Lepreau, OSDI 2000), Singularity (Hunt and Larus, ACM SIGOPS OSR 41(2),
  2007) and Zircon's handles and rights, as summarised in
  [research-prior-art.md](research-prior-art.md).
* The seL4 Device Driver Framework 0.7.0, as surveyed in
  [research-kernel-bases.md](research-kernel-bases.md#sddf), for the
  single-producer, single-consumer queue between components.
